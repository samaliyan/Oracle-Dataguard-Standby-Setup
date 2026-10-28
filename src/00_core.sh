#!/usr/bin/env bash
#==============================================================================
#  dg_standby_setup.sh  -  Oracle Data Guard physical standby builder (12.1 - 23ai)
#
#  Run ONLY on the STANDBY server, as root.
#  You give: the primary IP, the primary OS user password (typed into ssh),
#  the sys password (and an ASM password if Grid is installed here).
#  Everything else is read from the primary (read-only) and shown to you.
#
#  Every step:  1) checks the current state (read-only)
#               2) says what it will do, with which information, and asks
#               3) does it (standby only) and checks again
#               4) reports the result. You can skip a step and do it yourself.
#
#  Safety contract for the PRIMARY server:
#    * Commands sent over ssh come from a fixed list of read-only probes
#      (cat, id, stat, ls, md5sum, date, orabase, lsnrctl status, tnsping, sqlplus).
#    * SQL sent to primary must be a single-line SELECT (readonly_guard).
#    * Changes needed on primary are only PRINTED; you run them, the script
#      checks them again with SELECT.
#    * The only process that works against primary is RMAN active duplicate
#      (reads datafiles, normal log switches) after a typed confirmation.
#==============================================================================

set -o pipefail
# Unset variables are errors on bash 4.4 and newer. Bash 4.2 (Oracle Linux 7) also
# treats an EMPTY list as unset, which would stop the script for no reason, so
# there this check is left off. The script itself never relies on it.
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then set -u; fi
umask 022

num() { [[ -n "${1:-}" && "${1:-}" != *[!0-9]* ]]; }   # plain non-negative integer (no regex: keeps BASH_REMATCH)

readonly SCRIPT_VERSION="5.1"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
MODE="run"                     # run | check
FROM_STEP=""
ONLY_PHASE=""
REVIEW_SETTINGS=0
PROMPT_IN="${DG_PROMPT_IN:-/dev/tty}"
LOG_DIR="${DG_LOG_DIR:-/var/log/dg_standby_setup}"
STATE_DIR="${DG_STATE_DIR:-/var/lib/dg_standby_setup}"
RUN_ID=$(date '+%Y%m%d_%H%M%S')
RUN_START=$(date +%s)
LOG_FILE=""
ACTIONS_FILE=""
JOB_FILE=""
WARN_COUNT=0
SYS_PW=""
ASM_PW=""
SQL_OUT=""
RUN_OUT=""
CUR_STEP=""
HELP_STEP=""
CLEANUP_FILES=()
SSH_CTL=""
SSH_OPEN=0
FATAL_SEEN=0
RESUME_STEP=""            # the step a later run should start from (set when a message names it)
PROGRESS_FILE=""          # STATE_DIR/progress: last result of every step, across runs
LASTRUN_FILE=""           # STATE_DIR/last_run: when the last run was, how it ended
LONG_ADVICE_SHOWN=0
# Optional passwords from the environment (for unattended tests): copied into
# non-exported variables and removed from the environment at once, so no child
# process (runuser, root.sh, installers, ssh) can see them.
ENV_SYS_PW=${DG_SYS_PASSWORD:-}; ENV_ASM_PW=${DG_ASM_PASSWORD:-}
unset DG_SYS_PASSWORD DG_ASM_PASSWORD
# seconds; a hung sqlplus never blocks the script forever (also sent to the primary, so it must be a number)
SQL_TIMEOUT=${DG_SQL_TIMEOUT:-600}
num "$SQL_TIMEOUT" && (( 10#$SQL_TIMEOUT >= 10 && 10#$SQL_TIMEOUT <= 86400 )) || SQL_TIMEOUT=600
SQL_TIMEOUT=$((10#$SQL_TIMEOUT))
OS_RELEASE_FILE=${DG_OS_RELEASE_FILE:-/etc/os-release}
OS_ID=""; OS_MAJOR=""; PKG=""

#------------------------------------------------------------------------------
# Output and logging
#------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1;34m'; C_C=$'\e[36m'; C_M=$'\e[35m'; C_D=$'\e[2m'; C_W=$'\e[1m'; C_N=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_M=""; C_D=""; C_W=""; C_N=""
fi
# Symbols: real ones on a UTF-8 terminal, plain ASCII otherwise (each one is one column wide)
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) S_OK='✔'; S_WARN='!'; S_BAD='✘'; S_TODO='→'; S_WAIT='…'; S_ASK='?'; S_END='›'; S_HR='─'; S_HR2='━'; S_DOT='·' ;;
  *) S_OK='+'; S_WARN='!'; S_BAD='x'; S_TODO='>'; S_WAIT='.'; S_ASK='?'; S_END='>'; S_HR='-'; S_HR2='='; S_DOT='-' ;;
esac
rule() { local n=$1 c=${2:-$S_HR} out="" i; for ((i = 0; i < n; i++)); do out+=$c; done; printf '%s' "$out"; }   # $1 width, $2 character

ts() { date '+%Y-%m-%d %H:%M:%S'; }

mask_pw() {
  # Replace every occurrence of the sys and ASM passwords with *****
  if [[ -n "$SYS_PW" || -n "$ASM_PW" ]]; then
    DG_MASK1="$SYS_PW" DG_MASK2="$ASM_PW" awk '
      function mask(s, p,   out, i) {
        if (p == "") return s
        out = ""
        while ((i = index(s, p)) > 0) { out = out substr(s, 1, i - 1) "*****"; s = substr(s, i + length(p)) }
        return out s
      }
      BEGIN { p1 = ENVIRON["DG_MASK1"]; p2 = ENVIRON["DG_MASK2"] }
      { print mask(mask($0, p1), p2); fflush() }'
  else
    cat
  fi
}

_log() {
  [[ -n "$LOG_FILE" ]] || return 0
  printf '%s | %-6s | %s\n' "$(ts)" "$1" "$2" | sed 's/\x1b\[[0-9;]*m//g' | mask_pw >> "$LOG_FILE"
}

log_block() {
  [[ -n "$LOG_FILE" ]] || { cat > /dev/null; return 0; }
  {
    printf '%s | OUT    | --- %s ---\n' "$(ts)" "$1"
    sed 's/^/          /'
    printf '%s | OUT    | --- end ---\n' "$(ts)"
  } | mask_pw >> "$LOG_FILE"
}

# Screen layout of a step:   "  Step 1.5  Title"  then 4 spaces + symbol + text; more lines of a message at 6 spaces
say()  { printf '      %s\n' "$*"; _log INFO "$*"; }
_mark() { # $1 color $2 symbol $3 log tag, rest = text (first line after the symbol, other lines under it)
  local col=$1 sym=$2 tag=$3 l first=1; shift 3
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ $first -eq 1 ]]; then printf '    %s%s%s %s\n' "$col" "$sym" "$C_N" "$l"; first=0
    else [[ -n "$l" ]] && printf '      %s\n' "$l"; fi
  done <<< "$*"
  _log "$tag" "$*"
}
ok()   { _mark "$C_G" "$S_OK" OK "$*"; }
WARN_LIST=()
warn() {
  _log WARN "$*"
  local w="[${CUR_STEP:-start}] $*" x
  for x in "${WARN_LIST[@]+"${WARN_LIST[@]}"}"; do [[ "$x" == "$w" ]] && return 0; done   # same warning again (a re-check): shown and listed once
  local l first=1
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ $first -eq 1 ]]; then printf '    %s%s %s%s\n' "$C_Y" "$S_WARN" "$l" "$C_N"; first=0
    else [[ -n "$l" ]] && printf '      %s%s%s\n' "$C_Y" "$l" "$C_N"; fi
  done <<< "$*"
  WARN_COUNT=$((WARN_COUNT + 1)); WARN_LIST+=("$w")
}
bad()  { _mark "$C_R" "$S_BAD" FAIL "$*"; }
todo() { _mark "$C_M" "$S_TODO" TODO "$*"; }
wait_msg() { _mark "$C_D" "$S_WAIT" WAIT "$*"; }

hint() {
  # explanations and advice: plain text under the message they belong to
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '      %s\n' "$line"
    _log HINT "$line"
  done
}

block() {
  # $1 = label (Status / Plan / Details / Fix; old names Now: Plan: Using: are mapped), stdin = lines
  local label=$1 line first=1
  case "$label" in "Now:") label="Status" ;; "Plan:") label="Plan" ;; "Using:") label="Details" ;; "Fix:") label="Fix" ;; esac
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ $first -eq 1 ]]; then
      printf '    %s%-8s%s %s\n' "$C_D" "$label" "$C_N" "$line"; first=0
    else
      printf '             %s\n' "$line"
    fi
    _log "${label^^}" "$line"
  done
}

primary_note() {
  # what was done on the primary by this run (the duplicate is the only thing that works against it)
  # what THE SCRIPT did there; the commands the admin ran are listed with the changes ("You changed the primary yourself")
  if [[ ${DUP_RAN:-0} -eq 1 ]]; then printf 'The script itself ran only read-only checks and the RMAN copy on the primary.'
  else printf 'The script itself changed nothing on the primary.'; fi
}

user_stop() {
  # the user chose to stop: not an error (fatal prints "Stopped by you." once at the end)
  [[ "$*" == "Stopped by you" ]] || printf '      %s\n' "$*"
  _log STOP "$*"
  STOPPED_BY_USER=1
  fatal "$*"
}
STOPPED_BY_USER=0
fatal() {
  [[ -n "${BATCH_TTY:-}" ]] && { exec 1>&"$BATCH_TTY" 2>&1; BATCH_TTY=""; }
  [[ $STOPPED_BY_USER -eq 1 ]] || bad "$*"
  _log FATAL "$*"
  if [[ $FATAL_SEEN -eq 0 ]]; then
    FATAL_SEEN=1
    if [[ ${#STEP_ORDER[@]} -gt 0 ]] && declare -F summary >/dev/null; then CUR_STEP_SAVE=$CUR_STEP; summary; CUR_STEP=$CUR_STEP_SAVE; fi
  fi
  if [[ $STOPPED_BY_USER -eq 1 ]]; then printf '\n  %sStopped by you.%s  %s\n' "$C_Y" "$C_N" "$(primary_note)"
  else printf '\n  %sStopped.%s  %s\n' "$C_R" "$C_N" "$(primary_note)"; fi
  local rs=${RESUME_STEP:-$CUR_STEP}
  [[ "$rs" == *.x ]] && rs="${rs%.x}"
  if [[ -n "${UNDO_STEP:-}" ]]; then
    # an undo that stops half-way: what it did is in the journal; the step counts as not done when anything was undone
    if [[ ${UNDO_N_DONE:-0} -gt 0 ]] && declare -F record >/dev/null; then
      NOW="partly undone with --undo"; STEP_TITLE[$UNDO_STEP]=${STEP_TITLE[$UNDO_STEP]:-step}; record "$UNDO_STEP" UNDONE
    fi
    printf '  The undo stopped part-way. To see what is left:\n      %s --show-changes %s\n' "$SELF" "$UNDO_STEP"
  elif [[ -n "$DETACHED_JOB" ]]; then
    printf '  %s. Do NOT start it again by hand.\n' "${DETACHED_JOB^}"
    printf '  To see it:          %s --status\n' "$SELF"
    printf '  When it has ended:  %s   (records the result and continues)\n' "$SELF"
  elif [[ ${NEXT_PRINTED:-0} -eq 1 ]]; then :
  elif [[ -n "$rs" && "$rs" != 1.* && "$rs" != *.* ]]; then
    printf '  To continue later:   %s --from %s\n' "$SELF" "$rs"
  elif [[ -n "$rs" && "$rs" != 1.* ]]; then
    printf '  To continue later:   %s --from %s\n  To do it by hand:    %s --help-step %s\n' "$SELF" "$rs" "$SELF" "$rs"
  elif [[ -n "$rs" ]]; then
    printf '  To do it by hand:    %s --help-step %s\n' "$SELF" "$rs"
  fi
  [[ -n "$LOG_FILE" ]] && printf '  Log:                 %s\n' "$LOG_FILE"
  declare -F write_last_run >/dev/null && write_last_run "stopped"
  exit 1
}

on_signal() {
  # the terminal was closed (ssh session dropped) or the script was told to stop
  _log FATAL "Signal $1 received"
  trap '' HUP TERM INT
  [[ -n "$TAIL_PID" ]] && { pkill -P "$TAIL_PID" 2>/dev/null; kill "$TAIL_PID" 2>/dev/null; }
  if job_alive; then
    _log INFO "The job '$JOB_TITLE' (pid $JOB_PID) keeps running in its own session; output $JOB_OUT"
    DETACHED_JOB="'$JOB_TITLE' keeps running (session $JOB_PID, output $JOB_OUT)"
    # the step of the job (not the step this run was in, for example with --only 4) is the one that runs
    [[ "$MODE" == "run" && -n "${JOB_STEP:-}" && "$JOB_STEP" =~ ^[0-9]+\.[0-9]+$ ]] && declare -F record >/dev/null \
      && { NOW="$JOB_TITLE still running (session $JOB_PID)"; STEP_TITLE[$JOB_STEP]=${STEP_TITLE[$JOB_STEP]:-$(step_title_of "$JOB_STEP" 2>/dev/null)}; record "$JOB_STEP" RUNNING; }
  fi
  fatal "The terminal was closed, or the script was stopped (signal $1).
A running installer, root script or RMAN copy goes on by itself. Run the script again later."
}

cleanup() {
  local f
  for f in "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}"; do
    [[ -n "$f" ]] || continue
    # a response file of a job that still runs is removed by the job itself when it ends
    [[ -n "$JOB_KEEP" && ",$JOB_KEEP," == *",$f,"* ]] && job_running "$JOB_PID" && continue
    rm -f -- "$f"
    [[ "$(dirname "$f")" == /tmp/dg_rsp.* ]] && rmdir -- "$(dirname "$f")" 2>/dev/null
  done
  if [[ $SSH_OPEN -eq 1 && -n "$SSH_CTL" ]]; then
    ssh -o ControlPath="$SSH_CTL" -O exit "${PRIMARY_SSH_USER:-x}@${PRIMARY_IP:-x}" >/dev/null 2>&1 || true
    rm -f -- "$SSH_CTL"
  fi
}
trap cleanup EXIT
trap 'on_signal HUP' HUP
trap 'on_signal TERM' TERM
trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT

#------------------------------------------------------------------------------
# Prompts  (typing h at any question shows the manual commands of the step)
#------------------------------------------------------------------------------
ask() {
  # $1 = question. Result in ANSWER.  Typing h shows the help of the current step.
  while true; do
    printf '    %s%s %s%s %s ' "$C_C" "$S_ASK" "$1" "$C_N" "$S_END"
    if ! IFS= read -r ANSWER < "$PROMPT_IN"; then
      printf '\n'; fatal "No answer could be read for: $1
This script asks questions. Run it in an interactive terminal, for example:  ssh -t root@$(hostname -s 2>/dev/null)"
    fi
    _log ASK "$1  -> $ANSWER"
    case "${ANSWER,,}" in
      h|"?"|help) if [[ -n "$CUR_STEP" ]]; then show_help "$CUR_STEP" || true
                  else say "No help for this question. All options:  $SELF --help"; fi ;;
      *) return 0 ;;
    esac
  done
}

ask_default() {
  # $1 question, $2 default. Result in ANSWER (default when Enter).
  ask "$1 [$2]"
  [[ -n "$ANSWER" ]] || ANSWER=$2
}

confirm() {
  ask "$1  [y] Yes   [N] No"
  [[ "${ANSWER,,}" == "y" || "${ANSWER,,}" == "yes" ]]
}

confirm_word() {
  # $1 question, $2 the word to type. Spaces around the answer are ignored; a word in capital letters
  # (DUPLICATE, IGNORE) is accepted in any case; a device name must be typed exactly. Three tries.
  local n a
  for n in 1 2 3; do
    ask "$1  Type $2 to continue, or n to stop"
    a=${ANSWER//[[:space:]]/}
    [[ "$a" == "$2" ]] && return 0
    [[ "$2" =~ ^[A-Z]+$ && "${a^^}" == "$2" ]] && return 0
    [[ "${a,,}" == "n" || "${a,,}" == "no" ]] && return 1
    # an Enter by mistake does not stop an important step: it asks again
    if [[ -z "$a" ]]; then [[ $n -lt 3 ]] && say "Nothing was typed. Type $2, or n to stop."; continue; fi
    if [[ $n -lt 3 ]]; then
      if [[ "$2" =~ ^[A-Z]+$ ]]; then say "You typed \"$a\". Type $2 (capital or small letters), or n to stop."
      else say "You typed \"$a\". Type exactly $2, or n to stop."; fi
    fi
  done
  return 1
}

ask_secret() {
  # $1 prompt. Result in SECRET.
  printf '    %s%s %s%s %s ' "$C_C" "$S_ASK" "$1" "$C_N" "$S_END"
  IFS= read -rs SECRET < "$PROMPT_IN" || fatal "No answer could be read for: $1  (run the script in an interactive terminal, for example ssh -t)"
  printf '\n'
  _log ASK "$1  -> (hidden)"
}

#------------------------------------------------------------------------------
# Running commands as oracle / grid with a clean environment (from cwd /)
#------------------------------------------------------------------------------
ORA_ENV=()
GRID_ENV=()

home_of() { getent passwd "$1" | cut -d: -f6; }

distid_for() {
  # $1 release of a home (19, 21, ...). The 19c installer does not know Oracle Linux 8 or newer: without a
  # Release Update it stops at the OS check (INS-08101) unless it is told the OS is OL7.8; on Oracle Linux 9
  # even with a database RU applied it needs OL8. Other releases know their OS.
  # a value that worked for an installer on this server (saved after an INS-08101 retry) is used for every home
  if [[ -n "${STATE_DIR:-}" && -s "$STATE_DIR/distid" ]]; then
    local sv; sv=$(head -n 1 "$STATE_DIR/distid"); [[ "$sv" =~ ^(OL[0-9]+|OEL[0-9.]+)$ ]] && { printf 'CV_ASSUME_DISTID=%s' "$sv"; return 0; }
  fi
  [[ "${1:-0}" == "19" && "${OS_MAJOR:-0}" =~ ^[0-9]+$ ]] || return 0
  if [[ ${OS_MAJOR:-0} -ge 9 ]]; then printf 'CV_ASSUME_DISTID=OL8'
  elif [[ ${OS_MAJOR:-0} -ge 8 && -z "${RU_DIR:-}" ]]; then printf 'CV_ASSUME_DISTID=OEL7.8'; fi
  return 0
}
build_envs() {
  local oh gh dx=() gx=() v
  oh=$(home_of "$ORACLE_USER"); gh=$(home_of "$GRID_USER")
  v=$(distid_for "${DB_MAJOR:-0}"); [[ -n "$v" ]] && dx=("$v")
  v=$(distid_for "$(rel_major "${GRID_REL:-${DB_MAJOR:-0}}")"); [[ -n "$v" ]] && gx=("$v")
  ORA_ENV=( "HOME=${oh:-/}" "USER=$ORACLE_USER" "LOGNAME=$ORACLE_USER" "LANG=C" "LC_ALL=C"
            "PATH=$DB_HOME/bin:$DB_HOME/OPatch:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            "ORACLE_HOME=$DB_HOME" "ORACLE_BASE=$ORACLE_BASE" "ORACLE_SID=$STANDBY_SID"
            "TNS_ADMIN=$DB_HOME/network/admin" "NLS_LANG=AMERICAN_AMERICA.AL32UTF8" "${dx[@]+"${dx[@]}"}" )
  GRID_ENV=( "HOME=${gh:-/}" "USER=$GRID_USER" "LOGNAME=$GRID_USER" "LANG=C" "LC_ALL=C"
             "PATH=$GRID_HOME/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
             "ORACLE_HOME=$GRID_HOME" "ORACLE_BASE=$GRID_BASE" "ORACLE_SID=+ASM"
             "TNS_ADMIN=$GRID_HOME/network/admin" "NLS_LANG=AMERICAN_AMERICA.AL32UTF8" "${gx[@]+"${gx[@]}"}" )
}

# fd 9 is the lock of this script: no child (listener, instance) may keep it
as_oracle() { ( cd / && runuser -u "$ORACLE_USER" -- env -i "${ORA_ENV[@]}" "$@" 9>&- ); }
as_grid()   { ( cd / && runuser -u "$GRID_USER"   -- env -i "${GRID_ENV[@]}" "$@" 9>&- ); }
# The standby listener runs from the Grid home when there is Grid, else from the database home.
# Its name is always LISTENER: Grid creates ora.LISTENER.lsnr, and only the port has to match the primary.
readonly SB_LSNR=LISTENER
lsnr_home() { if use_grid; then printf '%s' "$GRID_HOME"; else printf '%s' "$DB_HOME"; fi; }
lsnr_user() { if use_grid; then printf '%s' "$GRID_USER"; else printf '%s' "$ORACLE_USER"; fi; }
as_lsnr()   { if use_grid; then as_grid "$@"; else as_oracle "$@"; fi; }

os_info() {
  # OS_ID (ol, rhel, ...), OS_MAJOR (7, 8, 9), PKG (yum or dnf)
  OS_ID=$( . "$OS_RELEASE_FILE" 2>/dev/null; printf '%s' "${ID:-unknown}")
  OS_MAJOR=$( . "$OS_RELEASE_FILE" 2>/dev/null; v=${VERSION_ID:-0}; printf '%s' "${v%%.*}")
  if command -v dnf >/dev/null 2>&1 && [[ "$OS_MAJOR" != "7" ]]; then PKG=dnf; else PKG=yum; fi
}

run_logged() {
  # $1 = title; rest = command. Output -> RUN_OUT and log. Returns command rc. stdin is not passed on.
  # The output goes through a file: a daemon the command starts (lsnrctl start -> tnslsnr) may keep
  # its stdout open, and reading a pipe would then wait for ever.
  local title=$1; shift
  local rc=0 tmp
  tmp=$(mktemp /tmp/dg_out.XXXXXXXX) || { RUN_OUT="cannot create a temporary file"; return 1; }
  CLEANUP_FILES+=("$tmp")
  "$@" > "$tmp" 2>&1 < /dev/null 9>&- || rc=$?
  RUN_OUT=$(cat "$tmp"); rm -f -- "$tmp"
  printf '%s\n(exit code %s)\n' "$RUN_OUT" "$rc" | log_block "$title"
  return "$rc"
}

#------------------------------------------------------------------------------
# Long jobs (installers, root scripts, RMAN duplicate)
#   They run in their own session (setsid): a closed terminal, a dropped ssh
#   session or Ctrl+C does not kill them half-way. The output is written to a
#   file and shown live. A later run of the script sees a job that still runs.
#------------------------------------------------------------------------------
JOB_PID=""; JOB_TITLE=""; JOB_OUT=""; JOB_KEEP=""; JOB_STEP=""; TAIL_PID=""; JOB_LEFT_WARNED=""
job_running() { num "${1:-}" && pgrep -s "$1" >/dev/null 2>&1; }   # any process of the job's session (setsid)
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
job_alive() {
  # 0 = a long job (of this or an earlier run) still runs. A job that ended while no run of the
  # script was watching is finished here (its result is recorded, its output masked).
  [[ -n "$JOB_FILE" && -f "$JOB_FILE" ]] || return 1
  local jboot=""
  IFS='|' read -r JOB_PID JOB_TITLE JOB_OUT JOB_KEEP jboot JOB_STEP < "$JOB_FILE" || true
  # after a reboot the pid may belong to another program: then the job is gone
  if [[ -n "$jboot" && "$jboot" != "$(boot_id)" ]]; then
    [[ "$MODE" == "run" ]] || { JOB_ENDED_UNRECORDED="$JOB_TITLE|$(cat "$JOB_OUT.rc" 2>/dev/null || printf 'stopped by a reboot')"; JOB_PID=""; JOB_KEEP=""; return 1; }
    if [[ -n "$JOB_OUT" && -f "$JOB_OUT.rc" ]]; then
      JOB_PID=""; job_finish_late        # it ended before the reboot: its result counts (the old pid means nothing now)
    else
      _log JOB "the job '$JOB_TITLE' was stopped by a reboot"; say "The job '$JOB_TITLE' of an earlier run was stopped by a reboot. Output: $JOB_OUT"
      job_remove_keep
    fi
    rm -f -- "$JOB_FILE"; JOB_PID=""; JOB_KEEP=""; return 1
  fi
  if job_running "$JOB_PID"; then
    # the command itself has ended (its exit code is written); only programs it left behind still run
    [[ -n "$JOB_OUT" && -f "$JOB_OUT.rc" ]] || return 0
    if [[ "$JOB_LEFT_WARNED" != "$JOB_PID" ]]; then
      JOB_LEFT_WARNED=$JOB_PID
      warn "The job '$JOB_TITLE' has ended, but programs it started still run: $(pgrep -s "$JOB_PID" -l 2>/dev/null | head -n 5 | tr '\n' ' ')"
    fi
  fi
  [[ "$MODE" == "run" ]] && job_finish_late
  [[ "$MODE" == "run" ]] && rm -f -- "$JOB_FILE"
  # check mode records nothing: the steps of that job are judged only after a normal run has recorded it
  [[ "$MODE" == "check" ]] && JOB_ENDED_UNRECORDED="$JOB_TITLE|$(cat "$JOB_OUT.rc" 2>/dev/null)"
  JOB_PID=""; JOB_KEEP=""
  return 1
}
JOB_ENDED_UNRECORDED=""
job_remove_keep() {
  # the response files of the job (they may hold the ASM password)
  local f; IFS=',' read -ra _jk <<< "$JOB_KEEP"
  for f in "${_jk[@]+"${_jk[@]}"}"; do [[ -n "$f" ]] && { rm -f -- "$f"; rmdir -- "$(dirname "$f")" 2>/dev/null; }; done
  return 0
}
job_finish_late() {
  # the job ended while the script was not running (terminal closed, script stopped)
  local rc=""
  job_remove_keep
  [[ -n "$JOB_OUT" && -f "$JOB_OUT" ]] || return 0
  rc=$(cat "$JOB_OUT.rc" 2>/dev/null); rm -f -- "$JOB_OUT.rc"
  _log JOB "finished while no run was watching: $JOB_TITLE rc=${rc:-unknown} output $JOB_OUT"
  # the output is masked only when nothing of the job writes to it any more
  # a new file (rename): programs that still write keep writing to the old one, which is then gone
  if [[ -n "$SYS_PW$ASM_PW" ]]; then ( umask 077; mask_pw < "$JOB_OUT" > "$JOB_OUT.m" ) && mv -f -- "$JOB_OUT.m" "$JOB_OUT"; rm -f -- "$JOB_OUT.m"; fi
  chmod 640 "$JOB_OUT" 2>/dev/null
  say "The job '$JOB_TITLE' has ended with exit code ${rc:-unknown}. Output: $JOB_OUT"
  # the passwords may not be known yet (the job is finished before step 1.5): mask again later
  [[ -z "$SYS_PW$ASM_PW" ]] && { install -d -m 700 "$STATE_DIR"; printf '%s\n' "$JOB_OUT" >> "$STATE_DIR/unmasked"; chmod 600 "$STATE_DIR/unmasked"; chmod 600 "$JOB_OUT" 2>/dev/null; }
  # the step that started the job records what the job did (journal lines carry that step)
  local cs=${CUR_STEP:-}; CUR_STEP=${JOB_STEP:-$cs}
  local jok=0; [[ "$rc" == "0" || ( "$rc" == "6" && ( "$JOB_TITLE" == *installer* || "$JOB_TITLE" == "Grid configuration tools"* ) ) ]] && jok=1
  case "$JOB_TITLE" in
    "RMAN duplicate")
      if grep -q 'Finished Duplicate Db' "$JOB_OUT" && ! grep -qE '^RMAN-0(3002|3009|3015)' "$JOB_OUT" && declare -F dup_success_record >/dev/null; then
        dup_success_record; say "The RMAN copy had finished. Its result is recorded."; jok=1
      else
        jok=0; install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/dup_attempt"
        say "The RMAN copy did NOT finish: $(grep -m1 -E '^(RMAN|ORA)-[0-9]+' "$JOB_OUT" 2>/dev/null || printf 'see its output')"
        say "Step 7.2 of a normal run shows how to clean up this server."
      fi ;;
    "Grid installer"*|"Grid configuration tools"*|"Database installer"*)
      if [[ "$rc" == "0" || "$rc" == "6" ]] && declare -F installer_done_record >/dev/null; then
        installer_done_record "$JOB_TITLE"; say "'$JOB_TITLE' had finished without error. Its result is recorded."
      fi ;;
    "root script $GRID_HOME/root.sh")
      if [[ "$rc" == "0" ]]; then
        install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/grid_root.done"
        journal GRIDCONFIG "$GRID_HOME" "root.sh: Oracle Restart configured (ohasd, /etc/oracle, /etc/oraInst.loc)"
      fi ;;
    "root script $DB_HOME/root.sh")
      [[ "$rc" == "0" ]] && journal ROOTSH "$DB_HOME" "root.sh of the database home (/usr/local/bin/oraenv, coraenv, dbhome; /etc/oratab)" ;;
    unzip\ *)
      # the marker was written before the unzip started (unpack_media); it goes only when the unzip worked
      if [[ "$rc" == "0" ]] && declare -F unzip_marker_clear >/dev/null; then
        local ud=""; ud=$(grep -F -- "|$JOB_OUT|" "$(unzip_marker)" 2>/dev/null | head -n 1 | cut -d'|' -f3) || true
        unzip_marker_clear "$JOB_OUT"
        [[ -n "$ud" ]] && journal UNZIP "$ud" "from ${JOB_TITLE#unzip }"
      fi ;;
  esac
  # the progress board: the step of the job is done, or failed (its next run shows what to do)
  # (an unzip is only a part of its step: the step itself is judged by its next check)
  if [[ "$JOB_TITLE" != unzip\ * && -n "${JOB_STEP:-}" && "$JOB_STEP" =~ ^[0-9]+\.[0-9]+$ ]] && declare -F record >/dev/null; then
    STEP_TITLE[$JOB_STEP]=${STEP_TITLE[$JOB_STEP]:-$(step_title_of "$JOB_STEP" 2>/dev/null)}
    if [[ $jok -eq 1 ]]; then NOW="$JOB_TITLE ended without error (recorded later)"; record "$JOB_STEP" DONE
    else NOW="$JOB_TITLE ended with exit code ${rc:-unknown}"; record "$JOB_STEP" FAILED; fi
    unset "STEP_RESULT[$JOB_STEP]"      # this run checks the step again itself
  fi
  CUR_STEP=$cs
  return 0
}

DETACHED_JOB=""
job_detach_question() {
  # Ctrl+C while a long job runs: the job goes on in any case; the script either keeps watching or stops
  say "The job goes on in any case. A later run of the script waits for it."
  ask_choice "[w] Keep watching   [d] Leave it running and stop the script" "wd"
  [[ "$ANSWER" == "d" ]] || return 0
  [[ -n "$TAIL_PID" ]] && { pkill -P "$TAIL_PID" 2>/dev/null; kill "$TAIL_PID" 2>/dev/null; wait "$TAIL_PID" 2>/dev/null; TAIL_PID=""; }
  trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT
  # JOB_KEEP stays: the response files are removed by the job itself when it ends (cleanup keeps them while it runs)
  DETACHED_JOB="'$1' keeps running (session $2, output $3)"
  [[ -n "$CUR_STEP" ]] && declare -F record >/dev/null && { NOW="$1 still running (session $2)"; record "$CUR_STEP" RUNNING; }
  RESUME_STEP=""
  user_stop "Left running: $1"
}

run_long() {
  # $1 title, $2 output file, $3 filter regex for the screen ("" = every line),
  # $4 who (root | oracle | grid), rest = command. The command reads the stdin of run_long.
  # JOB_KEEP (comma list): files the job needs (response files); the job removes them when it ends.
  # Returns the exit code of the command. The full output is in $2 (and in the log).
  local title=$1 out=$2 filt=$3 who=$4; shift 4
  local -a pre=()
  case "$who" in
    oracle) pre=(runuser -u "$ORACLE_USER" -- env -i "${ORA_ENV[@]}") ;;
    grid)   pre=(runuser -u "$GRID_USER" -- env -i "${GRID_ENV[@]}") ;;
    *)      pre=(env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME=/root LANG=C LC_ALL=C) ;;
  esac
  rm -f -- "$out" "$out.rc" "$out.pid"
  ( umask 077; : > "$out" ) || { bad "Cannot write $out."; return 1; }
  # fd 9 (the lock of this script) is closed for the job: a job that outlives the script must not block the next run
  # the job removes its JOB_KEEP files only when the script is gone (else the script still needs them, e.g. for a retry)
  setsid bash -c 'cd / || exit 1; echo $$ > "$1.pid"; f=$1; k=$2; sp=$3; shift 3
    "$@" > "$f" 2>&1; echo $? > "$f.rc"
    kill -0 "$sp" 2>/dev/null || { IFS=,; for x in $k; do [ -n "$x" ] && { rm -f -- "$x"; rmdir -- "${x%/*}" 2>/dev/null; }; done; }' dg_long_job "$out" "$JOB_KEEP" "$$" "${pre[@]}" "$@" <&0 9>&- &
  local bg=$! n=0 jpid=""
  while [[ ! -s "$out.pid" && $n -lt 100 ]]; do sleep 0.1; n=$((n + 1)); done
  jpid=$(cat "$out.pid" 2>/dev/null); rm -f -- "$out.pid"
  num "$jpid" || jpid=$bg
  printf '%s|%s|%s|%s|%s|%s\n' "$jpid" "$title" "$out" "$JOB_KEEP" "$(boot_id)" "${CUR_STEP:-}" > "$JOB_FILE" \
    || warn "Cannot write $JOB_FILE.
If this run stops, the next run will not know that $title is still running."
  JOB_PID=$jpid; JOB_TITLE=$title; JOB_OUT=$out; JOB_STEP=${CUR_STEP:-}
  _log JOB "start pid=$jpid $title -> $out"
  say "$title is running (process $jpid). Output: $out"
  if [[ $LONG_ADVICE_SHOWN -eq 0 ]]; then
    LONG_ADVICE_SHOWN=1
    say "It runs in its own session. A closed terminal does not stop it, and the next run waits for it."
    say "Ctrl+C asks if you want to keep watching. The job itself goes on in any case."
    say "To stop the job itself:  pkill -s $jpid"
    [[ "${title:-}" == RMAN* ]] || say "A stopped installer or root script leaves a half-configured home."
  fi
  RL_INT=0; trap 'RL_INT=1' INT
  # the output is shown by a background pipeline; waiting for it can be interrupted by HUP/TERM at once
  if [[ -n "$filt" ]]; then
    { tail -n +1 -f --pid="$jpid" -- "$out" 2>/dev/null | grep --line-buffered -E -- "$filt" | sed -u 's/^/        /'; } 9>&- &
  else
    { tail -n +1 -f --pid="$jpid" -- "$out" 2>/dev/null | sed -u 's/^/        /'; } 9>&- &
  fi
  TAIL_PID=$!
  local t0=$SECONDS hb=0
  while kill -0 "$TAIL_PID" 2>/dev/null; do
    sleep 5
    if [[ $RL_INT -eq 1 ]]; then
      RL_INT=0; printf '\n'
      job_detach_question "$title" "$jpid" "$out"
    fi
    if (( SECONDS - t0 >= 600 * (hb + 1) )); then
      hb=$((hb + 1))
      if [[ "$title" == "RMAN duplicate"* ]]; then
        # progress of the copy: datafiles RMAN has finished so far
        say "$title still running after $(( (SECONDS - t0) / 60 )) minutes. Datafile lines done: $(grep -cE 'restoring datafile|datafile copy complete|copying datafile' "$out" 2>/dev/null)"
      else
        say "$title still running after $(( (SECONDS - t0) / 60 )) minutes. Output so far: $(du -h -- "$out" 2>/dev/null | cut -f1)"
      fi
    fi
  done
  TAIL_PID=""
  wait "$bg" 2>/dev/null
  # the wrapper may have been killed while its command goes on: wait for the whole job
  n=0
  while job_running "$jpid"; do
    [[ $n -eq 0 ]] && say "Waiting for the rest of the job (session $jpid) to end."
    n=$((n + 1)); sleep 2
    if [[ $RL_INT -eq 1 ]]; then RL_INT=0; printf '\n'; job_detach_question "$title" "$jpid" "$out"; fi
    # the command has ended and only programs it started still run: do not wait for them
    if [[ -f "$out.rc" && $n -ge 30 ]]; then
      warn "$title has ended, but programs it started still run: $(pgrep -s "$jpid" -l 2>/dev/null | head -n 5 | tr '\n' ' ')"
      break
    fi
    if (( n % 300 == 0 )); then
      say "Programs of the job still run after $((n * 2 / 60)) minutes: $(pgrep -s "$jpid" -l 2>/dev/null | head -n 5 | tr '\n' ' ')"
      ask_choice "[k] Keep waiting   [c] Continue without them (they keep running)" "kc"
      [[ "$ANSWER" == "c" ]] && break
    fi
  done
  n=0; while [[ ! -f "$out.rc" && $n -lt 50 ]]; do sleep 0.1; n=$((n + 1)); done
  local rc; rc=$(cat "$out.rc" 2>/dev/null); rm -f -- "$out.rc" "$JOB_FILE"; JOB_PID=""
  num "$rc" || { rc=1; bad "$title was stopped before it finished."; }
  trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT
  JOB_KEEP=""
  # the output file may contain the passwords only if a tool printed them; mask it to be sure
  if [[ -n "$SYS_PW$ASM_PW" ]]; then ( umask 077; mask_pw < "$out" > "$out.m" ) && mv -f -- "$out.m" "$out"; rm -f -- "$out.m"; fi
  chmod 640 "$out" 2>/dev/null
  RUN_OUT=$(cat "$out")
  printf '%s\n(exit code %s)\n' "$RUN_OUT" "$rc" | log_block "$title (full output: $out)"
  _log JOB "end pid=$jpid rc=$rc $title"
  return "$rc"
}

#------------------------------------------------------------------------------
# Files: backups and writes that never follow a symbolic link, done as the owner
#------------------------------------------------------------------------------
backup_file() {
  # $1 file, $2 user (empty = root). Keeps <file>.bak_<run id> once per run.
  local f=$1 u=${2:-} b="$1.bak_$RUN_ID"
  [[ -f "$f" && ! -L "$f" ]] || return 0
  [[ -e "$b" || -L "$b" ]] && return 0
  if [[ -n "$u" && "$u" != "root" ]]; then runuser -u "$u" -- cp -p -- "$f" "$b" || return 1
  else cp -p --remove-destination -- "$f" "$b" || return 1; fi
  say "Backup: $b"
}
append_as() {
  # $1 user (empty or root = root), $2 file; stdin = text to add at the end (a missing final newline is added first)
  local u=${1:-root} f=$2 txt before=0 after=0 lead=0
  txt=$(cat)
  [[ -L "$f" ]] && { bad "Not changed: $f is a symbolic link."; return 1; }
  if [[ -s "$f" && -n "$(tail -c 1 -- "$f")" ]]; then txt=$'\n'"$txt"; lead=1; fi
  [[ -f "$f" ]] && before=$(stat -c '%s' -- "$f")
  if [[ "$u" != "root" ]]; then printf '%s\n' "$txt" | runuser -u "$u" -- tee -a -- "$f" > /dev/null || return 1
  else printf '%s\n' "$txt" >> "$f" || return 1; fi
  after=$(stat -c '%s' -- "$f" 2>/dev/null)
  declare -F journal_file_appended >/dev/null && journal_file_appended "$f" "$before" "$txt"$'\n' "$((after - before))" "$lead"
  return 0
}
write_as() {
  # $1 user, $2 file, $3 mode; stdin = the whole new content (written as that user)
  local u=$1 f=$2 m=$3 existed=0
  [[ -L "$f" ]] && { bad "Not changed: $f is a symbolic link."; return 1; }
  [[ -e "$f" ]] && existed=1

  if [[ "$u" == "root" ]]; then
    local t; t=$(mktemp "$(dirname "$f")/.dgtmp.XXXXXX") || return 1
    cat > "$t" && chmod "$m" "$t" && mv -f -- "$t" "$f" || { rm -f -- "$t"; return 1; }
  else
    runuser -u "$u" -- sh -c 'cat > "$1" && chmod "$2" "$1"' sh "$f" "$m" || return 1
  fi
  declare -F journal_file_written >/dev/null && journal_file_written "$f" "$existed"
  return 0
}

first_line() {
  local l=${SQL_OUT%%$'\n'*}
  l="${l#"${l%%[![:space:]]*}"}"
  l="${l%"${l##*[![:space:]]}"}"
  printf '%s' "$l"
}

norm() { printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'; }
ora_errors() {
  # the first error with its text (so the admin sees what it means), then the other codes
  local first rest
  first=$(grep -m1 -oE '(ORA|SP2|TNS|RMAN|CRS|INS|PRCD|PRVF|PRVG)-[0-9]+:? ?[^|]{0,90}' <<< "$1" | head -n 1 | sed 's/[[:space:]]*$//')
  rest=$(grep -oE '(ORA|SP2|TNS|RMAN|CRS|INS|PRCD|PRVF|PRVG)-[0-9]+' <<< "$1" | sort -u | grep -vxF -- "${first%%[: ]*}" | grep -vx 'SP2-0640' | paste -sd' ' -)
  printf '%s%s' "$first" "${rest:+; also $rest}"
}
users_ok() { id "$ORACLE_USER" >/dev/null 2>&1 && id "$GRID_USER" >/dev/null 2>&1; }
db_sw_ok() { users_ok && [[ -x "$DB_HOME/bin/sqlplus" ]]; }
grid_sw_ok() { use_grid && users_ok && [[ -x "$GRID_HOME/bin/crsctl" ]]; }
lsnr_sw_ok() { users_ok && [[ -x "$(lsnr_home)/bin/lsnrctl" ]]; }

human_min() {
  # minutes -> "45 minutes" / "6 hours" / "2.5 days"
  local m=${1:-0}
  if [[ $m -eq 1 ]]; then printf '1 minute'
  elif [[ $m -lt 120 ]]; then printf '%s minutes' "$m"
  elif [[ $m -lt 2880 ]]; then printf '%s hours' "$(( (m + 30) / 60 ))"
  else printf '%s.%s days' "$(( m / 1440 ))" "$(( (m % 1440) * 10 / 1440 ))"; fi
}
human_mb() {
  # $1 MB -> "1.2 TB" / "350 GB" / "800 MB" for messages (the log keeps MB)
  local mb=$1
  num "$mb" || { printf '%s MB' "$mb"; return 0; }
  if   (( mb >= 1048576 )); then printf '%s.%s TB' $(( mb / 1048576 )) $(( (mb % 1048576) * 10 / 1048576 ))
  elif (( mb >= 10240 ));    then printf '%s GB' $(( mb / 1024 ))
  else printf '%s MB' "$mb"; fi
}
mask_pending() {
  # job outputs that ended before the passwords were known: masked now that they are
  [[ -n "$SYS_PW$ASM_PW" && -s "$STATE_DIR/unmasked" ]] || return 0
  local f done_all=1
  # the list is kept until every password that a job could have printed is known (sys, and ASM with Grid)
  [[ -n "$SYS_PW" ]] || done_all=0
  { declare -F use_grid >/dev/null && use_grid; } && [[ -z "$ASM_PW" ]] && done_all=0
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    ( umask 077; mask_pw < "$f" > "$f.m" ) && mv -f -- "$f.m" "$f"; rm -f -- "$f.m"
    [[ $done_all -eq 1 ]] && chmod 640 "$f" 2>/dev/null
  done < "$STATE_DIR/unmasked"
  [[ $done_all -eq 1 ]] && rm -f -- "$STATE_DIR/unmasked"
  return 0
}
