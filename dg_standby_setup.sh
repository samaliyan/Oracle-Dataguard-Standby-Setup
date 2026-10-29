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

readonly SCRIPT_VERSION="5.3"
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
    # (once the job's command has ended, its .rc file exists: the response file is no longer needed and goes now)
    [[ -n "$JOB_KEEP" && ",$JOB_KEEP," == *",$f,"* ]] && job_running "$JOB_PID" && [[ ! -f "${JOB_OUT:-/nonexistent}.rc" ]] && continue
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

# empty, or only the lost+found folder that a new file system has at its top (a fresh mount point counts as empty)
dir_empty() { [[ -z "$(ls -A -- "$1" 2>/dev/null | grep -vx 'lost+found')" ]]; }
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

#------------------------------------------------------------------------------
# Step engine
#
#   run_step ID KIND "Title" check_fn [do_fn]
#
#   check_fn (read-only) sets:  NOW  = current state (one or more lines)
#                               PLAN = what will be done (lines)      [rc 1]
#                               USING= information that will be used  [rc 1]
#            returns 0 = already correct, 1 = action needed, 2 = cannot check
#            may set KIND_NOW=primary|manual|check when this time the action
#            cannot be done by the script (for example a file that must be
#            edited by hand), so the step only prints the commands.
#            NEED_SYS=1 (with rc 2): the step needs the sys password, which is
#            not known yet; the user can type it now.
#   do_fn    performs the action on THIS (standby) server, sets DONE_MSG.
#            returns 0 = done, 1 = failed, 3 = not started (the user said no)
#
#   KIND  auto     the script does it (asks first)
#         primary  you run printed commands on PRIMARY, the script checks again
#         manual   you do it on this server (cannot be automated safely)
#         check    read-only verification only
#         ask      like auto, but the do function asks its own question
#------------------------------------------------------------------------------
declare -a STEP_ORDER=()
declare -A STEP_RESULT=() STEP_TITLE=() STEP_NOW=() LAST_RESULT=() LAST_WHEN=() LAST_REASON=()
PHASE4_FIRST=0           # the admin chose to do phase 4 (primary) right after phase 1
NEXT_PRINTED=0           # the summary printed the "Next:" line (fatal does not print a second one)
DO_FAIL_STOP_ONLY=0      # set by a do function: after its failure only [q] is offered (RESUME_STEP says where to go on)
JOB_BUSY_TEXT=""
JOB_BUSY_PHASE=""        # check mode with a long job running: steps of this phase and later are not judged
declare -A AUTO_WAIT=()   # "step X" / "phase N" -> 1: not done in this run and you went on (its waiters are not asked again)
# steps that only the script can do: there is no [s] skip for them
readonly NO_SKIP_STEPS=" 1.2 1.3 1.4 "
no_skip() { [[ "$NO_SKIP_STEPS" == *" $1 "* ]]; }
NOW=""; PLAN=""; USING=""; DONE_MSG=""; QUIET_PLAN=0; KIND_NOW=""; NEED_SYS=0; MANUAL_WHERE=""

step_num() { local a=${1%%.*} b=${1#*.}; printf '%d' $(( 10#$a * 1000 + 10#$b )); }

step_in_range() {
  local id=$1
  [[ "${id%%.*}" == "1" ]] && return 0          # phase 1 (connect/settings) always runs
  if [[ -n "$ONLY_PHASE" ]]; then [[ "${id%%.*}" == "$ONLY_PHASE" ]]; return; fi
  [[ -z "$FROM_STEP" ]] && return 0
  [[ $(step_num "$id") -ge $(step_num "$FROM_STEP") ]]
}

phase_header() {
  local t="Phase $1 of 10 $S_DOT ${PHASE_TITLES[$1]:-$2}" w   # one name per phase, the same everywhere
  w=$((66 - ${#t})); [[ $w -lt 2 ]] && w=2
  printf '\n\n  %s%s %s %s%s\n' "$C_B" "$(rule 2 "$S_HR2")" "$t" "$(rule $w "$S_HR2")" "$C_N"
  _log PHASE "$1  $2"
}
# words shown for the result codes kept in the progress file
result_label() {
  case "$1" in
    OK) printf 'ok' ;; DONE) printf 'done' ;; DONE_BY_YOU) printf 'done by you' ;; SKIPPED) printf 'skipped' ;;
    SKIPPED_OPTIONAL) printf 'skipped (optional)' ;; FAILED_SKIPPED) printf 'failed, skipped' ;; FAILED) printf 'failed' ;;
    WAITS) printf 'waiting' ;; RUNNING) printf 'running' ;; TODO) printf 'to do' ;; PROBLEM) printf 'problem' ;;
    UNDONE) printf 'undone' ;; NOT_FINISHED) printf 'stopped here' ;; *) printf '%s' "$1" ;;
  esac
}
result_color() {
  case "$1" in OK|DONE|DONE_BY_YOU) printf '%s' "$C_G" ;; SKIPPED_OPTIONAL|WAITS) printf '%s' "$C_D" ;; RUNNING) printf '%s' "$C_C" ;;
    TODO) printf '%s' "$C_M" ;; SKIPPED|UNDONE) printf '%s' "$C_Y" ;; *) printf '%s' "$C_R" ;; esac
}

ok_lines() {
  # ok for the first line, the other lines indented under it
  local l first=${1%%$'\n'*} rest=""
  [[ "$1" == *$'\n'* ]] && rest=${1#*$'\n'}
  ok "$first"
  [[ -n "$rest" ]] && while IFS= read -r l; do [[ -n "$l" ]] && say "$l"; done <<< "$rest"
  return 0
}

record() {
  # the result of a step: in memory, in the log, and in the progress file (so the next run can show
  # how far the last run got, and which steps are done)
  STEP_RESULT[$1]=$2; STEP_NOW[$1]=${NOW%%$'\n'*}
  _log RESULT "[$1] $2  ${STEP_TITLE[$1]}"
  [[ -n "$PROGRESS_FILE" ]] || return 0
  # check mode cannot judge a waiting step: a step proven earlier keeps its result in the progress file
  if [[ "$MODE" == "check" && "$2" == "WAITS" ]] && grep -qE "^$1\|(OK|DONE|DONE_BY_YOU)\|" "$PROGRESS_FILE" 2>/dev/null; then return 0; fi
  install -d -m 700 "$STATE_DIR" 2>/dev/null
  { grep -v "^$1|" "$PROGRESS_FILE" 2>/dev/null; printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$(ts)" "$RUN_ID" "${STEP_NOW[$1]//|/ }"; } > "$PROGRESS_FILE.n" 2>/dev/null \
    && mv -f -- "$PROGRESS_FILE.n" "$PROGRESS_FILE"
  chmod 600 "$PROGRESS_FILE" 2>/dev/null
  return 0
}
load_progress() {
  # results of earlier runs (LAST_RESULT / LAST_WHEN per step)
  LAST_RESULT=(); LAST_WHEN=(); LAST_REASON=()
  [[ -n "$PROGRESS_FILE" && -s "$PROGRESS_FILE" ]] || return 0
  local id r t run why
  while IFS='|' read -r id r t run why; do [[ "$id" =~ ^[0-9]+\.[0-9]+$ ]] && { LAST_RESULT[$id]=$r; LAST_WHEN[$id]=$t; LAST_REASON[$id]=$why; }; done < "$PROGRESS_FILE"
  return 0
}
PHASE_TITLES=("" "Connect to the primary" "Prepare this server" "Install the Oracle software" "Prepare the primary" "Listener and tnsnames.ora" "Password file and TDE wallet" "Start the empty instance (NOMOUNT)" "Copy the database (RMAN)" "Start redo apply and transport" "Health check")
phase_done_result() {
  # overall result of a phase from the progress file: DONE | PARTLY | OPEN | - (never ran)
  local p=$1 i n=0 ok=0 bad=0
  for i in "${HELP_IDS[@]}"; do
    [[ "${i%%.*}" == "$p" ]] || continue
    n=$((n + 1))
    case "${LAST_RESULT[$i]:-}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL) ok=$((ok + 1)) ;; "") ;; *) bad=$((bad + 1)) ;; esac
  done
  if [[ $ok -eq $n ]]; then printf 'DONE'
  elif [[ $ok -eq 0 && $bad -eq 0 ]]; then printf '-'
  elif [[ $bad -gt 0 ]]; then printf 'OPEN'
  else printf 'PARTLY'; fi
}
print_progress_board() {
  # where the earlier runs got to: one line per phase, then the steps that are not done
  load_progress
  local p r col i open="" first="" word
  printf '\n  %sProgress%s\n' "$C_W" "$C_N"
  for p in 1 2 3 4 5 6 7 8 9 10; do
    r=$(phase_done_result "$p")
    case "$r" in DONE) col=$C_G; word="done" ;; OPEN) col=$C_Y; word="needs attention" ;; PARTLY) col=$C_C; word="in progress" ;; *) col=$C_D; word="not started" ;; esac
    printf '    %2s  %-28s %s%s%s\n' "$p" "${PHASE_TITLES[$p]}" "$col" "$word" "$C_N"
  done
  local nopen=0
  for i in "${HELP_IDS[@]}"; do
    case "${LAST_RESULT[$i]:-}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|"") ;;
      *) nopen=$((nopen + 1))
         if [[ $nopen -le 8 ]]; then
           open+="$(printf '      %-5s %s%-16s%s %s' "$i" "$(result_color "${LAST_RESULT[$i]}")" "$(result_label "${LAST_RESULT[$i]}")" "$C_N" "$(step_title_of "$i" 2>/dev/null | cut -c1-44)")"$'\n'
           [[ -n "${LAST_REASON[$i]:-}" ]] && open+="            ${C_D}${LAST_REASON[$i]:0:100}${C_N}"$'\n'
         fi
         [[ -n "$first" || "$i" == 1.* ]] || first=$i ;;
    esac
  done
  [[ $nopen -gt 8 ]] && open+="      ... and $((nopen - 8)) more"$'\n'
  if [[ -s "$LASTRUN_FILE" ]]; then
    local lr; lr=$(cat "$LASTRUN_FILE" 2>/dev/null)
    printf '\n  Last run:  %s\n' "$lr"
  fi
  # a long job that still runs by itself (read-only look: pid and boot of the job file)
  if [[ -n "$JOB_FILE" && -s "$JOB_FILE" ]]; then
    local jp jt jo jk jb js
    IFS='|' read -r jp jt jo jk jb js < "$JOB_FILE" || true
    if [[ "$jb" == "$(boot_id)" ]] && job_running "$jp"; then
      printf '\n  %sRunning now:%s %s  (step %s, session %s)\n' "$C_C" "$C_N" "$jt" "${js:-?}" "$jp"
      printf '  Output: %s (%s). Do NOT start it again by hand. When it has ended, run the script.\n' "$jo" "$(du -h -- "$jo" 2>/dev/null | cut -f1)"
    else
      printf '\n  %s%s (step %s) has ended%s.%s Run the script to record the result.\n' "$C_Y" "$jt" "${js:-?}" "$( [[ -f "$jo.rc" ]] && printf ', exit code %s' "$(cat "$jo.rc" 2>/dev/null)")" "$C_N"
    fi
  fi
  if [[ -n "$open" ]]; then
    printf '\n  Steps not done yet:\n%s' "$open"
    [[ -n "$first" ]] && printf '  %sA normal run checks every step again. To start at the first open step:  %s --from %s%s\n' "$C_D" "$SELF" "$first" "$C_N"
  elif [[ ! -s "$PROGRESS_FILE" ]]; then
    printf '\n  Nothing is set up yet. You will be asked for:\n'
    printf '    - the primary IP address, its Oracle OS user and its ssh password\n'
    printf '    - the sys password (step 1.5)\n'
    printf '    - with ASM: the disks to use (step 2.13) and a new ASM password (step 3.2)\n'
    printf '    - the word DUPLICATE before the copy starts (step 8.2)\n'
  fi
  return 0
}
step_ok_anywhere() {
  # 0 when step $1 is done: in this run, or (when it did not run now) in an earlier run
  case "${STEP_RESULT[$1]:-}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL) return 0 ;; "") ;; *) return 1 ;; esac
  # started in this run but not finished (the run stopped inside it): not done
  [[ " ${STEP_ORDER[*]+${STEP_ORDER[*]}} " == *" $1 "* ]] && return 1
  case "${LAST_RESULT[$1]:-}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL) return 0 ;; esac
  return 1
}
next_cmd() {
  # The one "Next" rule (summary, last_run): prints the command to run next, or nothing when all is done.
  # The step: RESUME_STEP (set by a step that knows where to go on), else the lowest step number that is not done
  # in this run (phase 1 runs every time). A --from that would skip an earlier step that is not done yet (phase 4
  # done first, a step that never ran) is not printed: then the plain command is the right one.
  local id nx="" best=999999 n
  [[ -n "$DETACHED_JOB" ]] && return 0
  for id in "${STEP_ORDER[@]+"${STEP_ORDER[@]}"}"; do
    [[ "$id" == 1.* ]] && continue
    step_ok_anywhere "$id" && continue
    n=$(step_num "$id"); [[ $n -lt $best ]] && { best=$n; nx=$id; }
  done
  [[ -n "$RESUME_STEP" && "$RESUME_STEP" != 1.* ]] && nx=$RESUME_STEP
  [[ -n "$nx" ]] || return 0
  if [[ -n "$ONLY_PHASE" && "$ONLY_PHASE" != "1" ]]; then printf '%s --only %s' "$SELF" "$ONLY_PHASE"; return 0; fi
  local lim; lim=$(step_num "$([[ "$nx" == *.* ]] && printf '%s' "$nx" || printf '%s.0' "$nx")")
  for id in "${HELP_IDS[@]}"; do
    [[ "$id" == 1.* ]] && continue
    [[ $(step_num "$id") -lt $lim ]] || break
    is_optional "$id" && continue
    step_ok_anywhere "$id" || { printf '%s' "$SELF"; return 0; }
  done
  printf '%s --from %s' "$SELF" "$nx"
}
write_last_run() {
  # $1 how the run ended
  [[ -n "$LASTRUN_FILE" ]] || return 0
  [[ -n "${UNDO_STEP:-}" ]] && return 0     # an undo is not a run of the steps (the journal holds what it did)
  local nc=""; [[ "$MODE" == "run" ]] && nc=$(next_cmd)
  if [[ -n "$DETACHED_JOB" ]]; then
    printf '%s  mode %s  left running at step %s: %s\n' "$(ts)" "$MODE" "${CUR_STEP:-?}" "$DETACHED_JOB" > "$LASTRUN_FILE" 2>/dev/null
    chmod 600 "$LASTRUN_FILE" 2>/dev/null; return 0
  fi
  printf '%s  mode %s  %s%s%s\n' "$(ts)" "$MODE" "$1" "${CUR_STEP:+ at step ${CUR_STEP%.x}}" "${nc:+; next: ${nc/#$SELF/run the script}}" > "$LASTRUN_FILE" 2>/dev/null
  chmod 600 "$LASTRUN_FILE" 2>/dev/null
  return 0
}

# Steps that are useful but not needed for a working standby (switchover preparation)
readonly OPTIONAL_STEPS=" 4.8 4.10 4.11 "
is_optional() { [[ "$OPTIONAL_STEPS" == *" $1 "* ]]; }
skip_record() {
  # (phase 1: the waiters ask once anyway, for example to type the sys password with [p])
  [[ "$1" == 1.* ]] || AUTO_WAIT["step $1"]=1
  if is_optional "$1"; then say "Skipped. This step is optional: the standby works without it."; record "$1" SKIPPED_OPTIONAL
  else warn "$2"; record "$1" SKIPPED; fi
}

waits_for() {
  # the earlier step a "cannot continue" message points to, for example "(step 2.2)" -> 2.2 ; "(phase 3)" -> 3
  local re='\((step|steps) ([0-9]+\.[0-9]+)' re2='\(phase ([0-9]+)\)'
  if [[ "$1" =~ $re ]]; then printf 'step %s' "${BASH_REMATCH[2]}"; return 0; fi
  if [[ "$1" =~ $re2 ]]; then printf 'phase %s' "${BASH_REMATCH[1]}"; return 0; fi
  return 1
}

how_by_hand() {
  # After a failure: the manual commands of this step, so the user can finish it by hand
  if no_skip "$1"; then say "To do this step by hand (then answer r to check again):"
  else say "To do this step by hand (then answer r to check again, or s to go on):"; fi
  show_help "$1" || true
}

print_commands() {
  # $1 where, $2 run as ("user  ->  env ; program" or a user name), stdin = commands.
  # The commands have no frame at the start of the line, so they can be copied as they are.
  local where=$1 how=$2 line cmds who prep="" note="" t
  cmds=$(cat)
  who=${how%%  ->  *}
  [[ "$how" == *"  ->  "* ]] && prep=${how#*  ->  }
  # the environment lines are commands too; anything else after the arrow is a note (shell, edit /etc/hosts, ...)
  if [[ -n "$prep" && "$prep" != export* ]]; then note=${prep#shell}; note=${note# }; prep=""; fi
  case "$where" in
    "ON PRIMARY ("*") - you run it") where="Run on the PRIMARY ${where#ON PRIMARY }"; where=${where% - you run it} ;;
    "ON THIS SERVER ("*") - you do it") where="Run on this server ${where#ON THIS SERVER }"; where=${where% - you do it} ;;
  esac
  t="$where, as $who"
  local w=$((64 - ${#t})); [[ $w -lt 2 ]] && w=2
  printf '\n    %s%s %s %s%s\n' "$C_M" "$(rule 2)" "$t" "$(rule $w)" "$C_N"
  # remarks in a shell box are shell comments (# ...), in an SQL or RMAN box they stay "-- ..."
  local shellbox=1; [[ "$how" == *sqlplus* || "$how" == *rman* ]] && shellbox=0
  [[ -n "$note" ]] && printf '      %s%s%s\n' "$C_D" "$note" "$C_N"
  if [[ -n "$prep" ]]; then
    while IFS= read -r line; do line=${line# }; [[ -n "$line" ]] && printf '      %s\n' "$line"; done <<< "${prep// ; /$'\n'}"
    printf '\n'
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "-- "* ]]; then [[ $shellbox -eq 1 ]] && line="# ${line#-- }"; printf '      %s%s%s\n' "$C_D" "$line" "$C_N"
    elif [[ "$line" == "#"* ]]; then printf '      %s%s%s\n' "$C_D" "$line" "$C_N"
    else printf '      %s\n' "$line"; fi
  done <<< "$cmds"
  printf '    %s%s%s\n\n' "$C_M" "$(rule 70)" "$C_N"
  printf '%s\n' "$cmds" | log_block "commands for: $where ($how)"
  if [[ -n "$ACTIONS_FILE" ]]; then
    { printf '\n# ===== %s | step %s | %s | run as: %s\n' "$(ts)" "$CUR_STEP" "$where" "$how"; printf '%s\n' "$cmds"; } | mask_pw >> "$ACTIONS_FILE"
  fi
}

# How to run SQL on the primary by hand. The exact home and SID are given, so the
# commands never depend on the environment (.bash_profile) of the user there.
PRIMARY_HOW="oracle  ->  sqlplus / as sysdba"
set_primary_how() {
  PRIMARY_HOW="$ORACLE_USER  ->  export ORACLE_HOME=$DB_HOME ORACLE_SID=$PRIMARY_SID ; \$ORACLE_HOME/bin/sqlplus / as sysdba"
}
prim_grid_how() { printf '%s  ->  export ORACLE_HOME=%s ORACLE_SID=+ASM ; PATH=$ORACLE_HOME/bin:$PATH' "$GRID_USER" "$GRID_HOME"; }

ask_choice() {
  # $1 prompt, $2 allowed answers (letters, e.g. "rshq"). Repeats until one of them is typed.
  while true; do
    ask "$1"
    ANSWER=${ANSWER,,}; ANSWER=${ANSWER//[[:space:]]/}
    [[ -n "$ANSWER" && ${#ANSWER} -eq 1 && "$2" == *"$ANSWER"* ]] && return 0
    say "Please type one of: $(sed 's/./& /g' <<< "$2")"
  done
}

job_wait_step() {
  # a long job from an earlier run is still running: wait for it before any step
  local tp
  JOB_ENDED_UNRECORDED=""
  job_wait_loop
  if [[ "$MODE" == "check" && -n "$JOB_ENDED_UNRECORDED" ]]; then
    local jt=${JOB_ENDED_UNRECORDED%%|*} jr=${JOB_ENDED_UNRECORDED#*|}
    warn "The long job '$jt' has ended (exit code ${jr:-unknown}); a normal run records its result first."
    case "$jt" in "RMAN duplicate"*) JOB_BUSY_PHASE=7 ;; *) JOB_BUSY_PHASE=3 ;; esac
    JOB_BUSY_TEXT="'$jt' has ended but is not recorded yet: run the script (without --check) first"
  fi
  return 0
}
job_wait_loop() {
  local tp
  while job_alive; do
    wait_msg "Still running: $JOB_TITLE (session $JOB_PID)"
    say "Output:    $JOB_OUT"
    say "Programs:  $(pgrep -s "$JOB_PID" -l 2>/dev/null | head -n 5 | awk '{print $2}' | tr '\n' ' ')"
    say "${C_D}To stop it: pkill -s $JOB_PID  (an installer stopped half-way leaves a broken home)${C_N}"
    if [[ "$MODE" == "check" ]]; then
      # the steps the job works on (and all after them) cannot be judged while it runs: their clean-up plans would hit the job
      case "$JOB_TITLE" in "RMAN duplicate"*) JOB_BUSY_PHASE=7 ;; *) JOB_BUSY_PHASE=3 ;; esac
      JOB_BUSY_TEXT="'$JOB_TITLE' is still running (session $JOB_PID): checked after it has ended"
      say "Check mode: phase $JOB_BUSY_PHASE and later are checked after the job has ended (shown as waiting)."
      return 0
    fi
    local main_prog
    main_prog=$(pgrep -s "$JOB_PID" -l 2>/dev/null | awk '{print $2}' | grep -E '^(rman|java|perl|unzip|runInstaller|gridSetup|root\.sh|sqlplus|opatch|opatchauto|oracle|setup)' | sort -u | paste -sd' ' -)
    if kill -0 "$JOB_PID" 2>/dev/null || [[ -n "$main_prog" ]]; then
      [[ -n "$main_prog" ]] && say "It is still working ($main_prog)."
      ask_choice "[w] Watch until it ends (Ctrl+C stops watching)   [r] Check again   [q] Quit (it keeps running)" "wrq"
    else
      # the leader of the job is gone, other programs of its session remain
      ask_choice "[w] Watch until it ends (Ctrl+C stops watching)   [r] Check again   [c] Continue without it   [q] Quit (it keeps running)" "wrcq"
    fi
    case "$ANSWER" in
      w) WATCH_STOP=0; trap 'WATCH_STOP=1' INT
         { tail -n 20 -f --pid=$$ -- "$JOB_OUT" 2>/dev/null | sed -u 's/^/        /'; } 9>&- &
         tp=$!; TAIL_PID=$tp
         while [[ $WATCH_STOP -eq 0 ]] && job_running "$JOB_PID" && [[ ! -f "$JOB_OUT.rc" ]]; do sleep 2; done
         sleep 1; pkill -P "$tp" 2>/dev/null; kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null; TAIL_PID=""
         trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT ;;
      c) if confirm_word "Continue without '$JOB_TITLE'?" "CONTINUE"; then
           _log JOB "user continues without the job $JOB_TITLE (session $JOB_PID)"
           job_finish_late; rm -f -- "$JOB_FILE"; JOB_PID=""; JOB_KEEP=""; return 0
         fi ;;
      q) DETACHED_JOB="'$JOB_TITLE' keeps running (session $JOB_PID, output $JOB_OUT)"; CUR_STEP=${JOB_STEP:-$CUR_STEP}
         user_stop "Stopped by you. The job keeps running; run the script again when it has finished." ;;
    esac
  done
}

run_step() {
  local id=$1 kind0=$2 kind=$2 title=$3 checkfn=$4 dofn=${5:-}
  step_in_range "$id" || return 0
  STEP_ORDER+=("$id"); STEP_TITLE[$id]=$title; CUR_STEP=$id
  printf '\n  %sStep %s%s  %s%s%s\n' "$C_B" "$id" "$C_N" "$C_W" "$title" "$C_N"
  _log STEP "[$id] $title"
  local rc drc acted=0 helped=0 opts w
  # (phase 4 needs nothing of this server: it is judged also while a job runs)
  if [[ -n "$JOB_BUSY_PHASE" && "${id%%.*}" -ge "$JOB_BUSY_PHASE" && "${id%%.*}" != 4 ]]; then
    NOW=$JOB_BUSY_TEXT
    wait_msg "$NOW"; STEP_NOW[$id]=$NOW; record "$id" WAITS; return 0
  fi
  while true; do
    NOW=""; PLAN=""; USING=""; DONE_MSG=""; QUIET_PLAN=0; PRIMARY_HOW_STEP=""; MANUAL_HOW=""; MANUAL_WHERE=""; KIND_NOW=""; NEED_SYS=0; PLAN_UNDO=""
    "$checkfn"; rc=$?
    kind=${KIND_NOW:-$kind0}
    if [[ $rc -eq 0 ]]; then
      local pend; pend=$(primary_pending_get "$id")
      if [[ $acted -eq 1 || -n "$pend" ]]; then
        ok_lines "Done by you. ${NOW}"; record "$id" DONE_BY_YOU
        # the commands printed for the primary (in this run or an earlier one) are done now: journal them with their undo
        if [[ -n "$pend" ]]; then
          [[ "$pend" == "-" ]] && pend="(nothing to take back; see --help-step $id)"
          local phow; phow=$(primary_pending_how "$id")
          journal PRIMARY "$id" "${phow:+[as $phow] }$pend"; primary_pending_del "$id"
        fi
      else ok_lines "${NOW:-Already correct}"; record "$id" OK; fi
      return 0
    fi
    if [[ $rc -eq 2 ]]; then
      # cannot be checked yet, or cannot be done automatically
      w=$(waits_for "$NOW" || true)
      local wid=${w#* }
      # a step that names an earlier step which IS done: the problem is in this step, not a wait
      if [[ "$w" == step* ]]; then
        case "${STEP_RESULT[$wid]:-}" in
          OK|DONE|DONE_BY_YOU) w="" ;;
          "") case "${LAST_RESULT[$wid]:-}" in OK|DONE|DONE_BY_YOU) w="" ;; esac ;;     # done in an earlier run
        esac
      fi
      if [[ "$MODE" == "check" ]]; then
        if [[ "$NOW" == *"only in a normal run"* ]]; then wait_msg "$NOW"; record "$id" WAITS
        elif [[ -n "$w" ]]; then wait_msg "Checked after $w is done. $NOW"; record "$id" WAITS
        else bad "${NOW:-Problem (no details)}"; [[ -n "$PLAN" && "$PLAN" != "$NOW" ]] && printf '%s\n' "$PLAN" | block "Fix:"; record "$id" PROBLEM; fi
        return 0
      fi
      # the earlier step (or phase) was not done in this run and you went on: the waiters do not ask again
      if [[ -n "$w" && -n "${AUTO_WAIT[$w]:-}" ]]; then
        wait_msg "Waiting for $w, which was not done in this run. $NOW"; record "$id" WAITS; AUTO_WAIT["step $id"]=1; return 0
      fi
      if [[ -n "$w" ]]; then
        bad "Not possible yet. $NOW"
        if [[ $NEED_SYS -eq 1 ]]; then say "This step needs the sys password. Answer p to type it now."
        elif [[ "$w" == step* && "$wid" == 1.* ]]; then say "Only the script can do step $wid. Answer q and run the script again."
        elif [[ "$w" == step* && -n "${STEP_RESULT[$wid]:-}" ]]; then say "Step $wid is not done in this run (result: $(result_label "${STEP_RESULT[$wid]}")). Do it first, then answer r. Or answer s to go on without it."
        elif [[ "$w" == step* ]] && ! step_in_range "$wid"; then say "Step $wid is not done and is not part of this run. Answer q, then run:  $SELF --from $wid"
        elif [[ "$w" == step* ]]; then say "Step $wid must be done first. Then answer r. Or answer s to go on without it."
        else say "Phase $wid is not done. Answer s to go on (steps that need it will wait), or q and run:  $SELF --from $wid"; fi
      else
        bad "This cannot be done automatically. ${NOW:-}"
        if [[ -n "$PLAN" ]]; then printf '%s\n' "$PLAN" | print_commands "${MANUAL_WHERE:-Run on this server ($(hostname -s))}" "${MANUAL_HOW:-root}"
        elif [[ $helped -eq 0 ]]; then how_by_hand "$id"; helped=1; fi
      fi
      opts="[r] Check again   [s] Skip   [h] Help   [q] Quit"; local allowed="rshq"
      no_skip "$id" && { opts="[r] Check again   [h] Help   [q] Quit"; allowed="rhq"; }
      if [[ $NEED_SYS -eq 1 ]]; then opts="[p] Type the sys password   $opts"; allowed+="p"; fi
      ask_choice "$opts" "$allowed"
      case "$ANSWER" in
        p) if d_1_5; then record 1.5 DONE; fi; continue ;;
        s) [[ -n "$w" ]] && AUTO_WAIT[$w]=1
           skip_record "$id" "Skipped. Do it before the steps that need it."; return 0 ;;
        q) [[ -n "$w" && -z "$RESUME_STEP" ]] && RESUME_STEP=$wid
           user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
        *) continue ;;
      esac
    fi
    # rc 1: something must be done
    is_optional "$id" && say "${C_D}Optional: needed only for switchover and the broker, not to build the standby.${C_N}"
    [[ -n "$NOW" ]] && printf '%s\n' "$NOW" | block "Now:"
    if [[ "$kind" == "primary" || "$kind" == "manual" ]]; then
      local where how
      if [[ "$kind" == "primary" ]]; then where="Run on the PRIMARY ($PRIMARY_HOST)"; how=${PRIMARY_HOW_STEP:-$PRIMARY_HOW}
      else where=${MANUAL_WHERE:-"Run on this server ($(hostname -s))"}; how=${MANUAL_HOW:-root}; fi
      [[ -n "$USING" ]] && printf '%s\n' "$USING" | block "Using:"
      [[ "$kind" == "primary" ]] && primary_pending_add "$id" "$PLAN_UNDO"
      { printf '%s\n' "$PLAN"; [[ -n "$PLAN_UNDO" ]] && printf -- '-- Undo, if ever needed: %s\n' "$PLAN_UNDO"; } | print_commands "$where" "$how"
      if [[ "$MODE" == "check" ]]; then todo "To do in a normal run"; record "$id" TODO; return 0; fi
      [[ $PRIMARY_BOX_NOTE -eq 0 ]] && { PRIMARY_BOX_NOTE=1; say "${C_D}All commands for you are also saved in:${C_N}"; say "${C_D}  $ACTIONS_FILE${C_N}"; }
      if is_optional "$id"; then ask_choice "[r] Done, check it   [s] Skip (optional)   [h] Help   [q] Quit" "rshq"
      else ask_choice "[r] Done, check it   [s] Skip for now   [h] Help   [q] Quit" "rshq"; fi
      case "$ANSWER" in
        s) skip_record "$id" "Skipped."; return 0 ;;
        q) user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
        r) acted=1; continue ;;
      esac
    fi
    if [[ "$kind" == "check" ]]; then
      [[ -n "$PLAN" ]] && printf '%s\n' "$PLAN" | block "Fix:"
      if [[ "$MODE" == "check" ]]; then bad "Problem found. See Fix above."; record "$id" PROBLEM; return 0; fi
      [[ $helped -eq 0 && -z "$PLAN" ]] && { how_by_hand "$id"; helped=1; }
      ask_choice "[r] Check again   [s] Skip   [h] Help   [q] Quit" "rshq"
      case "$ANSWER" in
        s) skip_record "$id" "Skipped."; return 0 ;;
        q) user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
        *) continue ;;
      esac
    fi
    # kind auto (or ask: the do function asks its own question)
    printf '%s\n' "$PLAN" | block "Plan:"
    [[ -n "$USING" ]] && printf '%s\n' "$USING" | block "Using:"
    if [[ "$MODE" == "check" ]]; then todo "To do in a normal run"; record "$id" TODO; return 0; fi
    if [[ "$kind" != "ask" ]]; then
      ask_choice "[y] Yes, do it   [s] Skip   [h] Help   [q] Quit" "yshq"
      case "$ANSWER" in
        y) ;;
        s) skip_record "$id" "Skipped. To do it by hand:  $SELF --help-step $id"; return 0 ;;
        q) user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
      esac
    fi
    _log DO "[$id] start"
    JOURNAL_STEP_ENTRIES=0
    drc=0; "$dofn" || drc=$?
    if [[ $drc -eq 3 ]]; then skip_record "$id" "Not started. To run it later:  $SELF --from $id"; return 0; fi
    if [[ $drc -eq 0 ]]; then
      NOW=""; "$checkfn"; rc=$?
      if [[ $rc -eq 0 ]]; then
        ok_lines "Done. ${DONE_MSG:-$NOW}"
        record "$id" DONE
        local pend2; pend2=$(primary_pending_get "$id")
        if [[ -n "$pend2" ]]; then
          [[ "$pend2" == "-" ]] || journal PRIMARY "$id" "$pend2"
          primary_pending_del "$id"
        fi
        return 0
      fi
      if [[ $rc -eq 1 && "$KIND_NOW" == "manual" ]]; then
        # the action did its part; one more thing must be done by hand (shown next, then checked)
        say "Done so far. One more thing must be done by hand:"; acted=1; continue
      fi
      bad "The action ran, but the check still fails. ${NOW:-}"
    else
      bad "The action did not finish."
    fi
    if [[ $DO_FAIL_STOP_ONLY -eq 1 ]]; then
      # a retry here would build on what the failed action left: the clean-up is in an earlier step
      DO_FAIL_STOP_ONLY=0
      record "$id" FAILED
      say "The script cannot go on from here. The next run first shows how to clean up this server (step 7.2)."
      while true; do ask_choice "[h] Help   [q] Quit" "hq"; [[ "$ANSWER" == "q" ]] && break; show_help "$id" || true; done
      user_stop "Stopped after the failed step $id"
    fi
    [[ $helped -eq 0 ]] && { how_by_hand "$id"; helped=1; }
    opts="[r] Try again   [s] Skip   [h] Help   [q] Quit"; local allowed2="rshq"
    no_skip "$id" && { opts="[r] Try again   [h] Help   [q] Quit"; allowed2="rhq"; }
    [[ "$id" == "1.2" ]] && { opts="[r] Try again   [i] Other IP address or user   [h] Help   [q] Quit"; allowed2="rihq"; }
    ask_choice "$opts" "$allowed2"
    case "$ANSWER" in
      s) warn "Skipped after an error."; record "$id" FAILED_SKIPPED; [[ "$id" == 1.* ]] || AUTO_WAIT["step $id"]=1; return 0 ;;
      q) user_stop "Stopped by you" ;;
      h) show_help "$id" || true; continue ;;
      i) reenter_primary; continue ;;
      *) continue ;;
    esac
  done
}

summary() {
  local id r col n_ok=0 n_opt=0 n_done=0 n_skip=0 n_bad=0 n_todo=0 n_wait=0 n_prob=0 first_bad=""
  local t="Summary"
  printf '\n\n  %s%s %s %s%s\n' "$C_B" "$(rule 2 "$S_HR2")" "$t" "$(rule $((66 - ${#t})) "$S_HR2")" "$C_N"
  printf '  %sok = was already correct   done = done by the script   done by you = you did it, the script checked it%s\n\n' "$C_D" "$C_N"
  for id in "${STEP_ORDER[@]}"; do
    r=${STEP_RESULT[$id]:-"NOT_FINISHED"}
    case "$r" in
      OK) n_ok=$((n_ok + 1)) ;;
      SKIPPED_OPTIONAL) n_opt=$((n_opt + 1)) ;;
      DONE|DONE_BY_YOU) n_done=$((n_done + 1)) ;;
      SKIPPED) n_skip=$((n_skip + 1)) ;;
      TODO) n_todo=$((n_todo + 1)) ;;
      WAITS|RUNNING) n_wait=$((n_wait + 1)) ;;
      PROBLEM) n_prob=$((n_prob + 1)) ;;
      *) n_bad=$((n_bad + 1)) ;;
    esac
    col=$(result_color "$r")
    printf '    %-5s %s%-18s%s %s\n' "$id" "$col" "$(result_label "$r")" "$C_N" "${STEP_TITLE[$id]}"
    case "$r" in
      OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|TODO) ;;
      *) [[ -n "${STEP_NOW[$id]:-}" ]] && printf '          %s%s%s\n' "$C_D" "${STEP_NOW[$id]:0:100}" "$C_N"
         [[ -n "$first_bad" ]] || first_bad=$id ;;
    esac
    _log SUM "$id $r ${STEP_TITLE[$id]}"
  done
  local el=$(( $(date +%s) - RUN_START ))
  printf '\n'
  if [[ "$MODE" == "check" ]]; then
    printf '  %s ok, %s to do, %s waiting, %s problems, %s warnings\n' "$n_ok" "$n_todo" "$n_wait" "$((n_prob + n_bad))" "$WARN_COUNT"
    printf '  %sCheck mode changes nothing, so on a new server most steps are "to do" or "waiting". That is normal.\n' "$C_D"
    printf '  Only "problem" steps need your attention: see the Fix lines above.%s\n' "$C_N"
  else
    printf '  %s already ok, %s done in this run, %s skipped, %s not ok, %s warnings%s\n' \
      "$n_ok" "$n_done" "$((n_skip + n_opt))" "$((n_bad + n_todo + n_wait + n_prob))" "$WARN_COUNT" "$( [[ $el -ge 60 ]] && printf '   (run time %s)' "$(human_min $((el / 60)))")"
    [[ $n_wait -gt 0 ]] && printf '  %s"waiting" steps need a step that was not done in this run. They are checked again next time.%s\n' "$C_D" "$C_N"
  fi
  if [[ ${#WARN_LIST[@]} -gt 0 ]]; then
    printf '\n  Warnings:\n'; local x xl xf
    for x in "${WARN_LIST[@]}"; do
      xf=1
      while IFS= read -r xl || [[ -n "$xl" ]]; do
        if [[ $xf -eq 1 ]]; then printf '    %s%s%s %s\n' "$C_Y" "$S_WARN" "$C_N" "$xl"; xf=0; else [[ -n "$xl" ]] && printf '      %s\n' "$xl"; fi
      done <<< "$x"
    done
  fi
  declare -F journal_run_summary >/dev/null && journal_run_summary
  printf '\n  Log:        %s\n' "$LOG_FILE"
  [[ -s "$ACTIONS_FILE" ]] && printf '  Commands:   %s\n' "$ACTIONS_FILE"
  printf '  %s\n' "$(primary_note)"
  if [[ "$MODE" == "check" ]]; then
    [[ $((n_todo + n_prob + n_bad)) -gt 0 ]] && printf '\n  %sNext:%s fix the "problem" steps (if any), then run without --check:  %s\n' "$C_W" "$C_N" "$SELF"
  else
    local nc; nc=$(next_cmd)
    if [[ -n "$nc" ]]; then
      NEXT_PRINTED=1
      if [[ "$nc" == *" --from "*.* ]]; then printf '\n  %sNext:%s  %s\n         %sTo do step %s by hand:  %s --help-step %s%s\n' "$C_W" "$C_N" "$nc" "$C_D" "${nc##* }" "$SELF" "${nc##* }" "$C_N"
      elif [[ "$nc" == "$SELF" ]]; then printf '\n  %sNext:%s  %s\n         %sEvery step is checked again; finished steps pass quickly.%s\n' "$C_W" "$C_N" "$nc" "$C_D" "$C_N"
      else printf '\n  %sNext:%s  %s\n' "$C_W" "$C_N" "$nc"; fi
    fi
  fi
  return 0
}

PRIMARY_BOX_NOTE=0
BATCH_TTY=""
# commands printed for the primary, not yet seen done: step|undo text (journaled as PRIMARY when the check passes)
primary_pending_file() { printf '%s/primary_pending' "$STATE_DIR"; }
primary_pending_add() {
  # $1 step, $2 undo text of the plan just printed. A step can need several rounds (part done, the rest later):
  # every distinct undo is kept, an empty one never replaces a stored one. Line: step|undo|how (who runs it)
  [[ "$MODE" == "run" && -n "$STATE_DIR" ]] || return 0
  local f old u=${2:-} how=${PRIMARY_HOW_STEP:-$PRIMARY_HOW}; f=$(primary_pending_file); install -d -m 700 "$STATE_DIR"
  u=${u//|/;}; how=${how//|/;}
  old=$(grep -m1 "^$1|" "$f" 2>/dev/null | cut -d'|' -f2)
  if [[ -n "$old" && "$old" != "-" ]]; then
    if [[ -z "$u" || "$old" == *"$u"* ]]; then u=$old; else u="$old ; $u"; fi
  fi
  { grep -v "^$1|" "$f" 2>/dev/null; printf '%s|%s|%s\n' "$1" "${u:--}" "$how"; } > "$f.n" 2>/dev/null && mv -f -- "$f.n" "$f"; chmod 600 "$f" 2>/dev/null
  return 0
}
primary_pending_get() { [[ -n "$STATE_DIR" ]] || return 0; grep -m1 "^$1|" "$(primary_pending_file)" 2>/dev/null | cut -d'|' -f2; return 0; }
primary_pending_how() { [[ -n "$STATE_DIR" ]] || return 0; grep -m1 "^$1|" "$(primary_pending_file)" 2>/dev/null | cut -d'|' -f3; return 0; }
primary_pending_del() {
  [[ "$MODE" == "run" ]] || return 0
  local f; f=$(primary_pending_file); [[ -f "$f" ]] || return 0
  grep -v "^$1|" "$f" > "$f.n" 2>/dev/null; mv -f -- "$f.n" "$f"; return 0
}
batch_primary_steps() {
  # $@ step ids of kind primary that follow each other. Their checks are run first (read-only) and every
  # plan is printed in ONE box, so the admin goes to the primary once. Then the steps run as usual: the
  # ones that were done pass at once, the others ask again one by one.
  [[ "$MODE" == "run" ]] || return 0
  local id cf rc all="" n=0 how="" BATCH_ERR
  # the connection is opened visibly first: the checks below run quietly
  need_ssh || return 0
  BATCH_ERR=$(mktemp /tmp/dg_batch.XXXXXX) && CLEANUP_FILES+=("$BATCH_ERR") || BATCH_ERR=/dev/null
  exec {BATCH_TTY}>&1      # a stop inside a quiet check (Ctrl+C, safety stop) still reaches the screen (fatal)
  local in41=0 in47=0 wbefore=${#WARN_LIST[@]}
  for id in "$@"; do
    step_in_range "$id" || continue
    cf="c_${id//./_}"; declare -F "$cf" >/dev/null || continue
    # a lost connection is opened again here, on the screen (the checks below run quietly)
    need_ssh || break
    NOW=""; PLAN=""; PLAN_UNDO=""; USING=""; KIND_NOW=""; PRIMARY_HOW_STEP=""; NEED_SYS=0; CUR_STEP=$id
    "$cf" >/dev/null 2>"$BATCH_ERR"; rc=$?
    [[ -s "$BATCH_ERR" && "$BATCH_ERR" != /dev/null ]] && log_block "quiet check $id (stderr)" < "$BATCH_ERR"
    [[ $rc -eq 1 && -n "$PLAN" && "${KIND_NOW:-primary}" == "primary" ]] || continue
    primary_pending_add "$id" "$PLAN_UNDO"
    [[ "$id" == "4.1" ]] && in41=1; [[ "$id" == "4.7" ]] && in47=1
    n=$((n + 1))
    [[ -n "$how" ]] || how=${PRIMARY_HOW_STEP:-$PRIMARY_HOW}
    all+="-- Step $id: ${STEP_TITLE_HINT[$id]:-}"$'\n'"$PLAN"$'\n'"${PLAN_UNDO:+-- Undo, if ever needed: $PLAN_UNDO}"$'\n\n'
  done
  CUR_STEP=""
  exec {BATCH_TTY}>&-; BATCH_TTY=""
  # warnings of the quiet checks are shown here (the steps do not repeat them)
  local wi wl wf
  for ((wi = wbefore; wi < ${#WARN_LIST[@]}; wi++)); do
    wf=1
    while IFS= read -r wl || [[ -n "$wl" ]]; do
      if [[ $wf -eq 1 ]]; then printf '    %s%s %s%s\n' "$C_Y" "$S_WARN" "$wl" "$C_N"; wf=0; else [[ -n "$wl" ]] && printf '      %s%s%s\n' "$C_Y" "$wl" "$C_N"; fi
    done <<< "${WARN_LIST[$wi]#\[*\] }"
  done
  [[ $n -ge 2 ]] || return 0
  printf '\n  %s%s steps need commands on the primary. They are shown together below, in order.%s\n' "$C_W" "$n" "$C_N"
  if grep -q '^shutdown immediate' <<< "$all"; then
    printf '\n    %s%s Step 4.1 restarts the primary database (shutdown immediate, startup mount).%s\n' "$C_Y" "$S_WARN" "$C_N"
    printf '      %sPlan a short downtime, or choose [o] and run the steps one at a time.%s\n\n' "$C_Y" "$C_N"
  fi
  say "The first two lines start SQL*Plus; the rest runs inside SQL*Plus (a line marked SHELL runs in a shell)."
  say "Afterwards the script checks every step again."
  say "Changes to files on the primary (steps 4.9 to 4.11, if needed) follow one by one."
  CUR_STEP="${1%%.*}.x"
  printf '%s' "${all%$'\n\n'}" | print_commands "Run on the PRIMARY ($PRIMARY_HOST)" "$how"
  CUR_STEP=""
  PRIMARY_BOX_NOTE=1; say "${C_D}The same commands are saved in $ACTIONS_FILE${C_N}"
  if [[ $in41 -eq 1 && $in47 -eq 1 ]]; then
    if grep -q 'create spfile from memory' <<< "$all"; then say "Run step 4.1 first, with its restart. The scope=spfile lines of the other steps need the spfile."
    else say "Steps 4.1 and 4.7 both need a restart of the primary. Run the 4.7 line before the shutdown of 4.1: then one restart covers both."; fi
  fi
  ask_choice "[r] Done, check all steps   [o] Show the steps one at a time   [q] Quit" "roq"
  case "$ANSWER" in
    q) [[ $PHASE4_FIRST -eq 0 && -z "$ONLY_PHASE" ]] && RESUME_STEP=$1; user_stop "Stopped by you" ;;
  esac
  return 0
}
declare -A STEP_TITLE_HINT=()
LAST_PLAN_UNDO=""

#------------------------------------------------------------------------------
# Change journal and undo
#
#   Every change this script makes on THIS server is written to STATE_DIR/changes.log
#   (one line: seq|time|run|step|kind|object|detail). The journal is the base of:
#     --show-changes [STEP]   what was changed, by which step, and how each change is undone
#     --undo STEP             walks the changes of one step backwards and undoes them one by
#                             one, asking before each. Files are put back from their backups
#                             (or an appended block is cut off again), services and
#                             registrations are removed; things that a program must not undo
#                             by itself (disks, software, users, the copied database) are only
#                             printed with the exact commands.
#   Commands the admin ran on the primary are recorded too (kind PRIMARY) with their undo
#   command, so --show-changes also lists what was changed there and how to take it back.
#   Nothing here touches the primary server.
#------------------------------------------------------------------------------
JOURNAL_FILE=""
JOURNAL_STEP_ENTRIES=0
JOURNAL_WARNED=0
declare -A UNDONE_SEQ=()
PLAN_UNDO=""          # set by a check function next to PLAN: how the printed change is taken back

file_md5() { md5sum -- "$1" 2>/dev/null | cut -d' ' -f1; }
text_md5() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }

journal() {
  # $1 kind, $2 object, $3 detail (optional). Only in a normal run (never in check mode).
  [[ "$MODE" == "run" && -n "$JOURNAL_FILE" ]] || return 0
  local seq o=${2//|/_} d=${3:-}
  o=${o//$'\n'/ }; d=${d//$'\n'/ }
  seq=$(journal_next_seq)
  install -d -m 700 "$STATE_DIR"
  [[ -s "$JOURNAL_FILE" ]] || printf '#journal v1 (seq|time|run|step|kind|object|detail)\n' >> "$JOURNAL_FILE" 2>/dev/null
  if ! printf '%s|%s|%s|%s|%s|%s|%s\n' "$seq" "$(ts)" "$RUN_ID" "${CUR_STEP:-start}" "$1" "$o" "$d" >> "$JOURNAL_FILE" 2>/dev/null; then
    [[ $JOURNAL_WARNED -eq 1 ]] || { JOURNAL_WARNED=1; warn "Cannot write the change journal $JOURNAL_FILE. Is the disk full?
Changes of this run may be missing from --show-changes and --undo."; }
    return 0
  fi
  chmod 600 "$JOURNAL_FILE" 2>/dev/null
  JOURNAL_STEP_ENTRIES=$((JOURNAL_STEP_ENTRIES + 1))
  _log CHANGE "[$1] $2${3:+ ($3)}"
  return 0
}
journal_next_seq() {
  local m=0 s
  [[ -s "$JOURNAL_FILE" ]] && m=$(cut -d'|' -f1 "$JOURNAL_FILE" | grep -E '^[0-9]+$' | sort -n | tail -n 1)
  num "$m" || m=0
  printf '%s' $((m + 1))
}
journal_has_file_this_run() {
  # 0 when this run already recorded a change of file $1 (then an EDIT has no exact backup of its own)
  [[ -s "$JOURNAL_FILE" ]] || return 1
  awk -F'|' -v r="$RUN_ID" -v f="$1" '$3 == r && ($5 == "NEW" || $5 == "EDIT" || $5 == "APPEND") && $6 == f { found = 1 } END { exit !found }' "$JOURNAL_FILE"
}
journal_internal_file() {
  # files of the script itself are not changes of the server
  case "$1" in "$LOG_DIR"/*|"$STATE_DIR"/*|*/.dg_duplicate_done_*|/tmp/dg_rsp.*|/tmp/dg_sql.*|*.bak_[0-9]*) return 0 ;; esac
  return 1
}
journal_file_written() {
  # called by write_as after a successful whole-file write: $1 file, $2 existed before (0/1)
  local f=$1 existed=$2 b="$1.bak_$RUN_ID"
  journal_internal_file "$f" && return 0
  if [[ $existed -eq 0 ]]; then journal NEW "$f" "md5=$(file_md5 "$f")"
  elif [[ -f "$b" ]] && ! journal_has_file_this_run "$f"; then journal EDIT "$f" "bak=$b md5=$(file_md5 "$f")"
  else journal EDIT "$f" "bak=- md5=$(file_md5 "$f")"; fi
  return 0
}
journal_file_appended() {
  # called by append_as: $1 file, $2 size before, $3 the text that was added (with its final newline)
  journal_internal_file "$1" && return 0
  # len in bytes (the size difference), lead=1 when a missing final newline was added in front of the block
  local len=${4:-}; num "$len" || len=$(printf '%s' "$3" | wc -c)
  journal APPEND "$1" "off=$2 len=$len md5=$(text_md5 "$3") md5all=$(file_md5 "$1") lead=${5:-0}"
  return 0
}

#---- reading ---------------------------------------------------------------
journal_load_undone() {
  UNDONE_SEQ=()
  [[ -s "$JOURNAL_FILE" ]] || return 0
  local seq kind obj
  while IFS='|' read -r seq _ _ _ kind obj _; do
    [[ "$seq" =~ ^[0-9]+$ && "$kind" == "UNDONE" && "$obj" =~ ^[0-9]+$ ]] && UNDONE_SEQ[$obj]=1
  done < "$JOURNAL_FILE"
  return 0
}
journal_entries() {
  # prints the active (not undone) entries, optionally of one step ($1) or one run ($2), oldest first
  [[ -s "$JOURNAL_FILE" ]] || return 0
  local l seq run step kind
  while IFS= read -r l; do
    IFS='|' read -r seq _ run step kind _ <<< "$l"
    [[ "$seq" =~ ^[0-9]+$ ]] || continue          # the version line, or a damaged line
    [[ "$kind" == "UNDONE" ]] && continue
    [[ -n "${1:-}" && "$step" != "$1" ]] && continue
    [[ -n "${2:-}" && "$run" != "$2" ]] && continue
    [[ -n "${UNDONE_SEQ[$seq]:-}" ]] && continue
    printf '%s\n' "$l"
  done < "$JOURNAL_FILE"
  return 0
}
detail_field() {
  # $1 detail text "k=v k=v", $2 key -> value (empty when absent)
  local w
  for w in $1; do [[ "$w" == "$2="* ]] && { printf '%s' "${w#*=}"; return 0; }; done
  printf ''
}
later_steps_active() {
  # 0 when a step after $1 has active entries (the undo of $1 would pull the ground from under them)
  local l step
  while IFS= read -r l; do
    local kind; IFS='|' read -r _ _ _ step kind _ <<< "$l"
    [[ "$step" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    case "$kind" in SERVICE|ROOHCTL|SETTING|DUPLICATE_DONE) continue ;; esac     # nothing to undo there
    [[ $(step_num "$step") -gt $(step_num "$1") ]] && return 0
  done < <(journal_entries)
  return 1
}

undo_text() {
  # $1 kind, $2 object, $3 detail -> one line: how this change is undone ("auto:" = --undo does it)
  local kind=$1 obj=$2 det=$3 b
  case "$kind" in
    NEW)        printf 'auto: remove the file %s' "$obj" ;;
    APPEND)     printf 'auto: cut the %s added bytes off the end of %s' "$(detail_field "$det" len)" "$obj" ;;
    EDIT)       b=$(detail_field "$det" bak)
                if [[ -n "$b" && "$b" != "-" ]]; then printf 'auto: put back the copy %s' "$b"; else printf 'by hand: there is no exact backup. Compare %s with its .bak_ copies and fix it.' "$obj"; fi ;;
    RENAME)     printf 'auto: rename %s back to %s' "$(detail_field "$det" to)" "$obj" ;;
    DIR)        printf 'auto: remove the folder %s if it is empty' "$obj" ;;
    GROUP)      printf 'by hand: groupdel %s   (only if no file and no user uses it)' "$obj" ;;
    USER)       printf 'by hand: userdel -r %s   (this also removes its home folder)' "$obj" ;;
    USERMOD)    printf 'by hand: the groups of %s were changed (%s). Set them back with usermod if needed.' "$obj" "$det" ;;
    PKG)        printf 'by hand, usually not wanted: %s remove %s' "$PKG" "$obj" ;;
    FWPORT)     printf 'auto: firewall-cmd --permanent --zone=%s --remove-port=%s ; firewall-cmd --reload' "${obj%%:*}" "${obj#*:}" ;;
    SERVICE)    printf 'nothing: %s was enabled and started. Every server should have a time service.' "$obj" ;;
    ASMCFG)     printf 'by hand: oracleasm configure -d ; systemctl disable oracleasm   (only if no ASM disk uses ASMLib)' ;;
    SETTING)    printf 'in the settings file: %s' "$det" ;;
    PART)       printf 'by hand, NOT while the disk is in an ASM disk group: wipefs -a %s ; wipefs -a %s   (%s)' "$(part_name "$obj")" "$obj" "$det" ;;
    ASMLABEL)   if [[ "$(asm_method 2>/dev/null)" == "asmlib" ]]; then printf 'by hand, only after +%s is dropped: oracleasm deletedisk %s' "${obj%_*}" "$obj"
                else printf 'by hand, only after +%s is dropped: remove the line with SYMLINK+="oraasm/%s" from %s ; udevadm control --reload-rules ; udevadm trigger' "${obj%_*}" "$obj" "$UDEV_RULES"; fi
                printf '   (also remove the line %s| from %s)' "$obj" "$(asm_disks_file 2>/dev/null)" ;;
    UNZIP)      printf 'by hand, only after the SOFTWARE undo of this home, or if it was never installed: rm -rf %s' "$obj" ;;
    SOFTWARE)   if [[ "$obj" == "${GRID_HOME:-/nonexistent}" ]]; then printf 'by hand, after the GRIDCONFIG undo (step 3.3), as %s:  %s/deinstall/deinstall' "$GRID_USER" "$obj"
                else printf 'by hand, as the owner:  %s/deinstall/deinstall   (removes the home %s from the inventory and the disk)' "$obj" "$obj"; fi ;;
    ROOTSH)     printf 'nothing separate: it goes with the SOFTWARE undo (deinstall) of the home %s' "$obj" ;;
    GRIDCONFIG) printf 'by hand, as root:  %s/crs/install/roothas.sh -deconfig -force   Then the SOFTWARE undo of the Grid home.' "$obj" ;;
    ASMINST)    printf 'by hand: the GRIDCONFIG undo (roothas.sh -deconfig -force) removes the ASM instance and +%s. The disks keep their ASM headers.' "$obj" ;;
    DISKGROUP)  printf 'by hand, this destroys all data in it: as %s  export ORACLE_HOME=%s ORACLE_SID=+ASM ; $ORACLE_HOME/bin/sqlplus / as sysasm  ->  drop diskgroup %s including contents;' "$GRID_USER" "$GRID_HOME" "$obj" ;;
    ROOHCTL)    printf 'nothing: the home %s was made read/write (roohctl -disable). roohctl -enable makes it read-only again.' "$obj" ;;
    LSNRRES)    printf 'auto: srvctl stop listener -listener %s ; srvctl remove listener -listener %s   (as %s)' "$obj" "$obj" "$GRID_USER" ;;
    LSNRPORT)   printf 'auto: srvctl modify listener -listener %s -endpoints TCP:%s ; then stop and start the listener (the old port)' "$obj" "$(detail_field "$det" old)" ;;
    LSNRSTART)  printf 'auto: lsnrctl stop %s   (as %s)' "$obj" "$(lsnr_user 2>/dev/null || printf '%s' "$ORACLE_USER")" ;;
    INSTANCE)   printf 'auto: shut down the instance %s (srvctl stop database if it is registered, else shutdown immediate)' "$obj" ;;
    DUPLICATE)  printf 'by hand: shutdown abort, then remove the files of %s on this server only, NEVER those of the primary. Details:  %s --help-step 8.2' "$obj" "$SELF" ;;
    DUPLICATE_DONE) printf 'nothing separate: the copied standby %s goes with the DUPLICATE line' "$obj" ;;
    SRVCTL)     printf 'auto: srvctl stop database -db %s ; srvctl remove database -db %s -noprompt   (the database files stay)' "$obj" "$obj" ;;
    SRL)        printf 'auto: drop the standby log group(s) %s on this server (apply is stopped for it)' "$det" ;;
    MRP)        printf 'auto: alter database recover managed standby database cancel' ;;
    UNIT)       if [[ "$obj" == *.timer ]]; then printf 'auto: systemctl disable --now %s   (the nightly clean-up stops)' "$obj"
                else printf 'auto: systemctl disable %s   (a running standby keeps running)' "$obj"; fi ;;
    OPATCH)     printf 'by hand, only if wanted: rm -rf %s ; mv %s %s   (puts back the OPatch of the media)' "$obj" "$(detail_field "$det" old)" "$obj" ;;
    SRVCTL_OLD) printf 'by hand: the old registration of %s is in the log of that run (srvctl config). Add it again with srvctl add database.' "$obj" ;;
    RMANCFG)    local ov; ov=$(detail_field "$det" old); ov=${ov//\~/ }
                if [[ -z "$ov" || "$ov" == "-" ]]; then printf 'by hand, usually not wanted: as %s  rman target /  ->  CONFIGURE ARCHIVELOG DELETION POLICY CLEAR;' "$ORACLE_USER"
                else printf 'by hand, usually not wanted: as %s  rman target /  ->  CONFIGURE ARCHIVELOG DELETION POLICY %s;' "$ORACLE_USER" "$ov"; fi ;;
    PRIMARY)    printf 'by hand on the primary, only after this standby no longer receives redo: %s' "$det" ;;
    *)          printf '%s' "$det" ;;
  esac
}

show_changes_cli() {
  # $1 step or empty
  local l seq t run step kind obj det n=0 last_step=""
  [[ -s "$JOURNAL_FILE" ]] || { printf '\n  No change is recorded yet (%s).\n' "$JOURNAL_FILE"; return 0; }
  journal_load_undone
  printf '\n  %sChanges made by this script%s\n' "$C_W" "$C_N"
  printf '  Journal         %s\n' "$JOURNAL_FILE"
  printf '  undo auto       %s --undo STEP does it for you\n' "$(basename "$SELF")"
  printf '  undo by hand    you run the command shown\n'
  while IFS= read -r l; do
    IFS='|' read -r seq t run step kind obj det <<< "$l"
    [[ "$step" != "$last_step" ]] && { printf '\n  %sStep %s%s  %s\n' "$C_B" "$step" "$C_N" "$(step_title_of "$step")"; last_step=$step; }
    printf '    %4s  %s  %-10s %s\n' "$seq" "${t:0:16}" "$kind" "$obj"
    printf '          %sundo %s%s\n' "$C_D" "$(undo_text "$kind" "$obj" "$det")" "$C_N"
    n=$((n + 1))
  done < <(journal_entries "${1:-}")
  if [[ $n -eq 0 ]]; then [[ -n "${1:-}" ]] && printf '\n  No change is recorded for step %s.\n' "$1" || printf '\n  No change is recorded, or every change was undone.\n'; fi
  return 0
}
change_word() {
  # a short word for each kind of change (the journal keeps the kind codes)
  case "$1" in
    NEW) printf 'new file' ;; APPEND) printf 'file' ;; EDIT) printf 'file' ;; RENAME) printf 'renamed' ;; DIR) printf 'folder' ;;
    GROUP) printf 'group' ;; USER|USERMOD) printf 'user' ;; PKG) printf 'package' ;; FWPORT) printf 'firewall' ;;
    SERVICE|UNIT) printf 'service' ;; ASMCFG|ASMLABEL|ASMINST|DISKGROUP) printf 'ASM' ;; SETTING) printf 'setting' ;;
    PART) printf 'disk' ;; UNZIP|SOFTWARE|ROOTSH|GRIDCONFIG|ROOHCTL|OPATCH) printf 'software' ;;
    LSNRRES|LSNRPORT|LSNRSTART) printf 'listener' ;; INSTANCE|DUPLICATE|DUPLICATE_DONE|SRL|MRP) printf 'database' ;;
    SRVCTL|SRVCTL_OLD) printf 'restart' ;; ASMGID) printf 'program' ;; DELETED) printf 'deleted' ;; CONFIRM) printf 'confirmed' ;; RMANCFG) printf 'RMAN' ;; *) printf '%s' "${1,,}" ;;
  esac
}
journal_run_summary() {
  # the changes of THIS run, under the summary
  [[ "$MODE" == "run" && -s "$JOURNAL_FILE" ]] || return 0
  journal_load_undone
  local l seq t run step kind obj det n=0 lines="" prim=""
  while IFS= read -r l; do
    IFS='|' read -r seq t run step kind obj det <<< "$l"
    # the commands you ran on the primary are listed apart (they are yours, not changes of this server)
    if [[ "$kind" == PRIMARY ]]; then prim+="${prim:+, }$step"; continue; fi
    n=$((n + 1))
    [[ $n -le 12 ]] && lines+="$(printf '    %-6s %-9s %s' "$step" "$(change_word "$kind")" "$obj")"$'\n'
  done < <(journal_entries "" "$RUN_ID")
  [[ $n -gt 0 || -n "$prim" ]] || return 0
  if [[ $n -gt 0 ]]; then
    printf '\n  Changes on this server in this run (%s):\n%s' "$n" "$lines"
    [[ $n -gt 12 ]] && printf '    ... and %s more\n' "$((n - 12))"
  fi
  [[ -n "$prim" ]] && printf '\n  You changed the primary yourself in steps: %s\n' "$prim"
  printf '\n  All changes, with their undo:  %s --show-changes\n' "$SELF"
  printf '  Undo one step:                %s --undo STEP\n' "$SELF"
  return 0
}

#---- undo ------------------------------------------------------------------
_undo_file_ok() {
  # $1 file, $2 recorded md5 of the whole file: 0 when the file is unchanged since the script wrote it (or the user accepts)
  local cur; cur=$(file_md5 "$1")
  [[ -n "$2" && "$cur" == "$2" ]] && return 0
  warn "$1 was changed after this script wrote it."
  confirm "Undo it anyway and lose the later change"
}
_hint_after_restore() {
  case "$1" in
    */network/admin/listener.ora) say "Then reload the listener as $(lsnr_user 2>/dev/null || printf '%s' "$ORACLE_USER"):  lsnrctl reload" ;;
    /etc/security/limits.d/*)     say "The limits apply at the next login of the users." ;;
    /etc/udev/rules.d/*)          say "Then run:  udevadm control --reload-rules ; udevadm trigger" ;;
    /etc/systemd/system/*)        systemctl daemon-reload 2>/dev/null || true ;;
    */.bash_profile)              say "This applies at the next login of that user." ;;
  esac
  return 0
}
_db_registered() { use_grid && [[ -x "$DB_HOME/bin/srvctl" ]] && run_logged "srvctl config" as_oracle "$DB_HOME/bin/srvctl" config database -db "$STANDBY_UNIQUE" >/dev/null 2>&1; }
_undo_obj_ok() {
  # the journal is root-only, but its fields are checked again before anything is run with them
  local kind=$1 obj=$2 det=$3 x
  case "$kind" in
    NEW|APPEND|EDIT|RENAME|DIR)
      [[ "$obj" == /* ]] && v_path "$obj" || { bad "Not undone: the journal line has an unusual path: $obj"; return 1; }
      [[ "$obj" == *"/../"* || "$obj" == *"/./"* || "$obj" == *"//"* || "$obj" == */.. || "$obj" == */. || "$obj" == */ ]] && { bad "Not undone: the journal line has an unusual path: $obj"; return 1; }
      [[ "$kind" != DIR && -L "$obj" ]] && { bad "Not undone: $obj is now a symbolic link."; return 1; }
      case "$obj" in /|/etc|/usr|/usr/*bin|/bin|/sbin|/lib*|/var|/opt|/home|/root|/boot|/dev|/proc|/sys|/tmp|/u0[0-9]) bad "Not undone: $obj is a system folder."; return 1 ;; esac
      [[ "$kind" != DIR && -d "$obj" && ! -L "$obj" ]] && { bad "Not undone: $obj is a folder, but the journal line is for a file."; return 1; }
      if [[ "$kind" == EDIT ]]; then x=$(detail_field "$det" bak); [[ "$x" == "-" || ( "$x" == "$obj".bak_* && "${x#"$obj".bak_}" =~ ^[0-9]{8}_?[0-9]{6}$ ) ]] || { bad "Not undone: the backup $x does not belong to $obj."; return 1; }; fi
      if [[ "$kind" == RENAME ]]; then x=$(detail_field "$det" to); [[ ( "$x" == "$obj".pre_duplicate_* && "${x#"$obj".pre_duplicate_}" =~ ^[0-9_]+$ ) || ( "$x" == "$obj".failed_* && "${x#"$obj".failed_}" =~ ^[0-9_]+$ ) ]] || { bad "Not undone: the renamed file $x does not belong to $obj."; return 1; }; fi ;;
    FWPORT) [[ "$obj" =~ ^[A-Za-z0-9_-]+:[0-9]+/tcp$ ]] || { bad "Not undone: invalid firewall entry $obj"; return 1; } ;;
    UNIT)   [[ "$obj" =~ ^[A-Za-z0-9_.@-]+\.(service|timer)$ ]] || { bad "Not undone: invalid unit name $obj"; return 1; } ;;
    LSNRRES|LSNRPORT|LSNRSTART) v_name "$obj" || { bad "Not undone: invalid listener name $obj"; return 1; } ;;
    SRVCTL) v_name "$obj" || { bad "Not undone: invalid database name $obj"; return 1; } ;;
    INSTANCE|MRP|SRL)
      # the line is for the standby of the current settings only (after a rename or a rebuild it is another database)
      [[ "$obj" == "$STANDBY_SID" ]] \
        || { bad "Not undone: this line is for the instance $obj, but the settings are now for $STANDBY_SID.
Do it by hand if it is still wanted."; return 1; } ;;
  esac
  return 0
}
_srl_drop() {
  # $1 groups. standby_file_management=AUTO refuses the drop (ORA-01275): MANUAL for the drop, AUTO again in any case
  local g rc=0 have
  sql_local "select group#||'|'||status from v\$standby_log;" || { bad "Cannot read the standby logs: $(ora_errors "$SQL_OUT")"; return 1; }
  have=$SQL_OUT
  local sfm="AUTO"; sql_local "select upper(value) from v\$parameter where name='standby_file_management';" && [[ "$(first_line)" == "MANUAL" ]] && sfm=MANUAL
  sql_local "alter system set standby_file_management=manual scope=memory;" || { bad "Cannot set standby_file_management=manual: $(ora_errors "$SQL_OUT")"; return 1; }
  for g in $1; do
    num "$g" || continue
    grep -q "^$g|" <<< "$have" || { say "Group $g is already gone."; continue; }
    if grep -qE "^$g\|(ACTIVE|CURRENT|CLEARING)" <<< "$have"; then
      bad "Group $g is in use: redo from the primary is written into it.
Stop the redo transport first (the undo of step 9.5). On the primary:
  alter system set log_archive_dest_state_<N of step 4.4>=defer scope=both;
Then run this undo again."
      rc=1; continue
    fi
    local mem=""; sql_local "select member from v\$logfile where group#=$g and member like '/%' and rownum=1;" && mem=$(first_line)
    if sql_local "alter database drop standby logfile group $g;"; then
      say "Standby log group $g dropped."
      [[ "$mem" == /* && "$mem" != */o1_mf_* && -e "$mem" ]] && { say "Its file is still in the folder. To remove it, as $ORACLE_USER:"; say "  [ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && rm -f $mem"; }
    else bad "Dropping group $g failed: $(ora_errors "$SQL_OUT")"; rc=1; fi
  done
  if [[ "$sfm" == AUTO ]]; then
    sql_local "alter system set standby_file_management=auto scope=memory;" || warn "standby_file_management is still MANUAL in memory. To fix it:
  alter system set standby_file_management=auto scope=memory;"
  fi
  return $rc
}
_state_or_2() {
  # local_state that is not readable means "cannot check": never treated as done
  local_state
  case "$LSTATE" in NOSW|ERROR|"") bad "Cannot check the instance: settings or software not found ($LSTATE)."; return 2 ;; esac
  return 0
}
undo_one() {
  # $1 kind, $2 object, $3 detail. 0 = undone, 1 = failed, 2 = printed only / skipped
  local kind=$1 obj=$2 det=$3 b m
  _undo_obj_ok "$kind" "$obj" "$det" || return 2
  case "$kind" in
    NEW)
      [[ -e "$obj" || -L "$obj" ]] || { say "$obj is already gone."; return 0; }
      m=$(detail_field "$det" md5); _undo_file_ok "$obj" "$m" || return 2
      rm -f -- "$obj" || return 1
      say "Removed $obj"; _hint_after_restore "$obj"; return 0 ;;
    APPEND)
      [[ -f "$obj" ]] || { say "$obj is already gone."; return 0; }
      local off len md5 cur_len tail_md5 u tmp
      off=$(detail_field "$det" off); len=$(detail_field "$det" len); md5=$(detail_field "$det" md5)
      num "$off" && num "$len" || return 1
      cur_len=$(stat -c '%s' -- "$obj")
      if [[ $cur_len -lt $((off + len)) ]]; then say "$obj is shorter than when the block was added. Fix it by hand."; return 2; fi
      tail_md5=$(tail -c +$((off + 1)) -- "$obj" | head -c "$len" | md5sum | cut -d' ' -f1)
      if [[ "$tail_md5" != "$md5" ]]; then say "The block added to $obj is gone, because the file was edited. Fix it by hand."; return 2; fi
      # the udev rule of a disk that a disk group still uses must stay (the disk group would not mount any more)
      if [[ "$obj" == "${UDEV_RULES:-/nonexistent}" ]]; then
        local lab used_by=""
        for lab in $(tail -c +$((off + 1)) -- "$obj" | head -c "$len" | grep -oE 'SYMLINK\+="oraasm/[A-Za-z0-9_]+"' | sed 's#.*/##; s#"##'); do
          # removed only when proven unused: ASM must answer 0 (no answer = kept)
          if grid_sw_ok 2>/dev/null && sql_asm "select count(*) from v\$asm_disk where path like '%/$lab' and group_number > 0;" && [[ "$(first_line)" == "0" ]]; then :
          elif ! grid_sw_ok 2>/dev/null && [[ ! -e "$(asm_disk_dir 2>/dev/null)/$lab" ]]; then :
          else used_by+=" $lab"; fi
        done
        [[ -z "$used_by" ]] || { bad "ASM disk(s)$used_by may be in a disk group, or ASM cannot tell now. Their udev rule stays.
Drop the disk group first (see the ASMLABEL lines), with ASM running."; return 2; }
      fi
      u=$(stat -c '%U' -- "$obj")
      backup_file "$obj" "$u" || return 1
      # exactly the added bytes go; text before and after them stays (the newline added in front of the block stays
      # when more text follows it, so two lines are not glued together). The file is rewritten as its owner.
      [[ -L "$obj" ]] && { bad "Not changed: $obj is now a symbolic link."; return 2; }
      local lead keep_nl=0; lead=$(detail_field "$det" lead)
      [[ "$lead" == "1" && $cur_len -gt $((off + len)) ]] && keep_nl=1
      tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
      { head -c "$off" -- "$obj"; [[ $keep_nl -eq 1 ]] && printf '\n'; tail -c +$((off + len + 1)) -- "$obj"; } > "$tmp" || { rm -f -- "$tmp"; return 1; }
      if [[ "$u" == "root" ]]; then cat "$tmp" > "$obj" || { rm -f -- "$tmp"; return 1; }
      # root reads the private temp copy; the owner writes its own file (the copy is never made readable for others)
      else runuser -u "$u" -- sh -c 'cat > "$1"' sh "$obj" < "$tmp" || { rm -f -- "$tmp"; return 1; }; fi
      rm -f -- "$tmp"
      if [[ $off -eq 0 && ! -s "$obj" ]]; then rm -f -- "$obj"; say "Removed $obj. It held only the added block."
      else say "Removed the block that was added to $obj."; fi
      _hint_after_restore "$obj"; return 0 ;;
    EDIT)
      b=$(detail_field "$det" bak); m=$(detail_field "$det" md5)
      [[ -n "$b" && "$b" != "-" ]] || { say "There is no exact backup for this change. Compare $obj with its .bak_ copies and fix it by hand."; return 2; }
      [[ -f "$b" ]] || { bad "The backup $b is gone. Fix $obj by hand."; return 2; }
      _undo_file_ok "$obj" "$m" || return 2
      cp -p --remove-destination -- "$b" "$obj" || return 1
      say "Put back $obj from $b"; _hint_after_restore "$obj"; return 0 ;;
    RENAME)
      local to; to=$(detail_field "$det" to)
      [[ -f "$to" ]] || { say "$to is gone. Nothing to rename back."; return 0; }
      [[ -e "$obj" ]] && { say "$obj exists again. The renamed copy $to is left as it is."; return 2; }
      mv -f -- "$to" "$obj" || return 1
      say "Renamed $to back to $obj"; return 0 ;;
    DIR)
      [[ -d "$obj" ]] || { say "$obj is already gone."; return 0; }
      if rmdir -- "$obj" 2>/dev/null; then say "Removed the empty folder $obj"; return 0; fi
      say "$obj is not empty. It is left as it is."; return 2 ;;
    FWPORT)
      run_cmds <<< "firewall-cmd --permanent --zone=${obj%%:*} --remove-port=${obj#*:}
firewall-cmd --reload" ;;
    UNIT)
      if [[ ! -f "/etc/systemd/system/$obj" ]] && ! systemctl cat "$obj" >/dev/null 2>&1; then say "$obj is already gone."; return 0; fi
      if [[ "$obj" == *.timer ]]; then
        # a timer is stopped too (it would fire every night); its files are removed by their own lines
        run_cmds <<< "systemctl disable --now $obj" || return 1
        systemctl daemon-reload 2>/dev/null || true
        say "$obj is stopped and disabled."; return 0
      fi
      run_cmds <<< "systemctl disable $obj" || return 1
      systemctl reset-failed "$obj" 2>/dev/null || true
      say "$obj is disabled: it no longer starts at boot. The running standby was not stopped."; return 0 ;;
    LSNRRES)
      run_logged "srvctl config listener" as_grid "$GRID_HOME/bin/srvctl" config listener -listener "$obj" >/dev/null 2>&1 || { say "Listener $obj is not registered. It is already gone."; return 0; }
      run_logged "srvctl stop listener" as_grid "$GRID_HOME/bin/srvctl" stop listener -listener "$obj" || true
      run_logged "srvctl remove listener" as_grid "$GRID_HOME/bin/srvctl" remove listener -listener "$obj" || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      say "Listener $obj removed from Oracle Restart."; return 0 ;;
    LSNRPORT)
      local old; old=$(detail_field "$det" old); num "$old" || return 2
      run_logged "srvctl modify listener" as_grid "$GRID_HOME/bin/srvctl" modify listener -listener "$obj" -endpoints "TCP:$old" || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      run_logged "srvctl stop listener" as_grid "$GRID_HOME/bin/srvctl" stop listener -listener "$obj" || true
      run_logged "srvctl start listener" as_grid "$GRID_HOME/bin/srvctl" start listener -listener "$obj" || true
      say "Listener $obj is back on port $old."; return 0 ;;
    LSNRSTART)
      if run_logged "lsnrctl stop" as_lsnr timeout 120 "$(lsnr_home)/bin/lsnrctl" stop "$obj"; then say "Listener $obj stopped."; return 0; fi
      grep -qE 'TNS-12541|TNS-12560|TNS-00511|No listener' <<< "$RUN_OUT" && { say "Listener $obj was not running."; return 0; }
      bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1 ;;
    INSTANCE)
      _state_or_2 || return 2
      [[ "$LSTATE" == "IDLE" ]] && { say "Instance $obj is not running."; return 0; }
      if [[ "$LSTATE" == "MOUNTED" ]] && mrp_running; then
        warn "The standby is mounted and applying redo. A shutdown stops the apply until the standby is started again."
        confirm "Shut it down anyway" || return 2
      fi
      if _db_registered; then
        run_logged "srvctl stop database" as_oracle timeout 1800 "$DB_HOME/bin/srvctl" stop database -db "$STANDBY_UNIQUE" -stopoption immediate || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      else
        sql_local_long "shutdown immediate" || { bad "shutdown immediate failed: $(ora_errors "$SQL_OUT")
Trying shutdown abort."; sql_local "shutdown abort" || return 1; }
      fi
      say "Instance $obj is down."; return 0 ;;
    SRVCTL)
      run_logged "srvctl config" as_oracle "$DB_HOME/bin/srvctl" config database -db "$obj" >/dev/null 2>&1 || { say "$obj is not registered. It is already gone."; return 0; }
      run_logged "srvctl status" as_oracle "$DB_HOME/bin/srvctl" status database -db "$obj" || true
      grep -q 'is running' <<< "$RUN_OUT" && { run_logged "srvctl stop" as_oracle timeout 1800 "$DB_HOME/bin/srvctl" stop database -db "$obj" -stopoption immediate || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }; }
      run_logged "srvctl remove" as_oracle "$DB_HOME/bin/srvctl" remove database -db "$obj" -noprompt || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      say "$obj removed from Oracle Restart. The database files are not touched."; return 0 ;;
    SRL)
      _state_or_2 || return 2
      [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { bad "The standby must be mounted to drop standby logs (step 9.2)."; return 2; }
      local was_mrp=0
      if mrp_running; then was_mrp=1; sql_local "alter database recover managed standby database cancel;" || { bad "Cannot stop the apply first."; return 1; }; fi
      local src=0; _srl_drop "$det" || src=1
      if [[ $was_mrp -eq 1 ]]; then
        warn "Redo apply was stopped for the drop and is NOT running now. Start it again:
  $SELF --from 9.4
or in sqlplus:  alter database recover managed standby database disconnect;"
      fi
      return $src ;;
    MRP)
      _state_or_2 || return 2
      [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { say "The standby is not mounted, so apply is not running."; return 0; }
      sql_local "alter database recover managed standby database cancel;" || { grep -q 'ORA-16136' <<< "$SQL_OUT" && { say "Apply was not running."; return 0; }; bad "Stopping the apply failed: $(ora_errors "$SQL_OUT")"; return 1; }
      say "Apply (MRP) stopped."; return 0 ;;
    *)  return 2 ;;
  esac
}

UNDO_QUIT=0; UNDO_N_DONE=0
undo_cli() {
  # $1 step id. Walks the journal of that step backwards. Needs the settings (no primary connection).
  # Returns 0 when every line was handled, 1 when a line failed or was left.
  local step=$1 l seq t run step2 kind obj det n=0 rc n_done=0 n_left=0
  [[ -s "$JOURNAL_FILE" ]] || { printf '\n  No change is recorded yet (%s).\n' "$JOURNAL_FILE"; return 0; }
  job_alive && { bad "A long job of an earlier run is still running: $JOB_TITLE. Wait for it to end, then try again."; return 1; }
  journal_load_undone
  local -a lines=(); mapfile -t lines < <(journal_entries "$step" | tac)
  [[ ${#lines[@]} -gt 0 ]] || { printf '\n  No change is recorded for step %s.\n' "$step"; return 0; }
  printf '\n  %sUndo of step %s%s  %s\n' "$C_B" "$step" "$C_N" "$(step_title_of "$step")"
  printf '      The changes are undone newest first, one at a time. Nothing on the primary is touched.\n'
  if later_steps_active "$step"; then
    local later; later=$(journal_entries | awk -F'|' -v s="$step" '$4 ~ /^[0-9]+\.[0-9]+$/ && $5 !~ /^(SERVICE|ROOHCTL|SETTING|DUPLICATE_DONE)$/ {split($4,a,"."); split(s,b,"."); if (a[1]*100+a[2] > b[1]*100+b[2]) print $4}' | sort -t. -k1,1n -k2,2n -u | paste -sd' ' -)
    warn "Later steps have changes that build on this one: $later.
Undo them first, the last one first:  --undo ${later##* }"
    confirm_word "Undo step $step anyway?" "UNDO" || { printf '      Undo not started.\n'; return 1; }
  fi
  CUR_STEP=$step
  for l in "${lines[@]}"; do
    IFS='|' read -r seq t run step2 kind obj det <<< "$l"
    n=$((n + 1))
    printf '\n    %s%s) %s  %s%s   %srun %s%s\n' "$C_W" "$n" "$kind" "$obj" "$C_N" "$C_D" "$run" "$C_N"
    printf '       undo %s\n' "$(undo_text "$kind" "$obj" "$det")"
    case "$kind" in
      NEW|APPEND|EDIT|RENAME|DIR|FWPORT|UNIT|LSNRRES|LSNRPORT|LSNRSTART|INSTANCE|SRVCTL|SRL|MRP)
        ask_choice "[y] Undo it   [s] Skip   [q] Quit" "ysq"
        case "$ANSWER" in
          s) n_left=$((n_left + 1)); continue ;;
          q) UNDO_QUIT=1; n_left=$((n_left + 1)); break ;;
        esac
        rc=0; undo_one "$kind" "$obj" "$det" || rc=$?
        if [[ $rc -eq 0 ]]; then journal UNDONE "$seq" "$kind $obj"; ok "Undone"; n_done=$((n_done + 1)); UNDO_N_DONE=$n_done
        else
          [[ $rc -eq 1 ]] && bad "Could not undo this change. The log has the details."
          if confirm "Mark it as undone by you, so it is no longer listed"; then journal UNDONE "$seq" "$kind $obj (by you)"; n_done=$((n_done + 1)); UNDO_N_DONE=$n_done
          else n_left=$((n_left + 1)); fi
        fi ;;
      SERVICE|ROOHCTL|SETTING|DUPLICATE_DONE)
        say "Nothing to do for this line." ;;
      *)
        say "Undo this change by hand, with the command above."
        if confirm "Mark it as undone by you"; then journal UNDONE "$seq" "$kind $obj"; n_done=$((n_done + 1)); else n_left=$((n_left + 1)); fi ;;
    esac
  done
  # the progress board shows the step as not done any more
  if [[ $n_done -gt 0 ]] && declare -F record >/dev/null; then
    NOW="undone with --undo ($n_done change(s)$([[ $n_left -gt 0 ]] && printf '; %s left' "$n_left"))"; STEP_TITLE[$step]=$(step_title_of "$step"); record "$step" UNDONE
  fi
  if [[ $UNDO_QUIT -eq 1 ]]; then printf '\n  Undo of step %s stopped by you. To see what is left:\n      %s --show-changes %s\n' "$step" "$SELF" "$step"
  elif [[ $n_left -gt 0 ]]; then printf '\n  Undo of step %s finished: %s undone, %s left. To see what is left:\n      %s --show-changes %s\n' "$step" "$n_done" "$n_left" "$SELF" "$step"
  else printf '\n  Undo of step %s finished. Every change of the step is undone.\n' "$step"; fi
  [[ $n_done -gt 0 ]] && printf '  Step %s now counts as not done. The next run does it again, or:  %s --from %s\n' "$step" "$SELF" "$step"

  _log INFO "undo of step $step: $n_done undone, $n_left left"
  [[ $n_left -eq 0 ]]
}

step_title_of() {
  # title of a step from the help texts (the engine fills STEP_TITLE only for steps that ran)
  local t=${STEP_TITLE[$1]:-}
  [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
  if declare -F help_text >/dev/null && t=$(help_text "$1" 2>/dev/null | sed -n 's/^TITLE  //p' | head -n 1) && [[ -n "$t" ]]; then printf '%s' "$t"; return 0; fi
  printf 'step %s' "$1"
}

#------------------------------------------------------------------------------
# Settings: discovered from primary + derived for standby.
# Stored in $STATE_DIR/settings.conf as KEY=VALUE. The file is PARSED and every
# value is validated; it is never executed.
#   Primary values are read again from the primary at every run (a change in the
#   file is not kept). Standby values may be changed by the user.
#   The values the user accepted are kept in settings.accepted; only an accept
#   writes that file.
#------------------------------------------------------------------------------
PRIMARY_HOW_STEP=""; MANUAL_HOW=""

# key:type   (types: name opt_name ip path opt_path num port list locs yesno opt_paths opt_loc dbname asmmethod)
readonly SETTING_SPECS="
PRIMARY_IP:ip PRIMARY_SSH_USER:name PRIMARY_HOST:name PRIMARY_SID:name DB_NAME:name PRIMARY_UNIQUE:name
PRIMARY_CDB:name PRIMARY_VERSION:name DB_MAJOR:num GRID_REL:opt_name PRIMARY_DOMAIN:opt_name PRIMARY_SERVICE:name
PORT:port LISTENER_NAME:name PRIMARY_LISTENER_HOME:path
DB_HOME:path ORACLE_BASE:path USE_GRID:yesno GRID_HOME:opt_path GRID_BASE:opt_path INVENTORY_DIR:path
ORACLE_USER:name GRID_USER:name INSTALL_GROUP:name GRID_PGROUP:name ORACLE_UID:num GRID_UID:num
ORACLE_GROUPS:list GRID_GROUPS:list GROUP_GIDS:list
LOCS:locs DATA_DG:opt_name FRA_LOC:opt_loc FRA_MB:num ARCH_LOC:opt_loc PRIMARY_DB_MB:num
STANDBY_HOST:name STANDBY_IP:ip STANDBY_UNIQUE:dbname STANDBY_SID:name STANDBY_SERVICE:name
PRIMARY_TNS:name STANDBY_TNS:name ASM_METHOD:asmmethod GRID_MEDIA:opt_paths DB_MEDIA:opt_paths RU_DIR:opt_path OPATCH_ZIP:opt_path AUX_CHANNELS:num
"
# may be empty
readonly OPTIONAL_KEYS=" PRIMARY_DOMAIN GRID_REL ORACLE_GROUPS GRID_GROUPS GRID_HOME GRID_BASE DATA_DG FRA_LOC ARCH_LOC ASM_METHOD GRID_MEDIA DB_MEDIA RU_DIR OPATCH_ZIP "
# values the user may change (everything else is read from the primary at every run)
readonly DERIVED_KEYS=" STANDBY_HOST STANDBY_IP STANDBY_SID STANDBY_SERVICE PRIMARY_TNS STANDBY_TNS AUX_CHANNELS "
readonly STANDBY_KEYS=" STANDBY_HOST STANDBY_IP STANDBY_UNIQUE STANDBY_SID STANDBY_SERVICE PRIMARY_TNS STANDBY_TNS ASM_METHOD GRID_MEDIA DB_MEDIA RU_DIR OPATCH_ZIP AUX_CHANNELS "
# settings files of version 3.x had these keys; they are converted or dropped
readonly OLD_KEYS=" FRA_DG DATA_DISK FRA_DISK GRID_ZIP DB_ZIP "
SETTINGS_FILE=""; ACCEPTED_FILE=""
SETTINGS_UPGRADED=0; LOAD_ERR=""; DROPPED_KEYS=""

all_setting_keys() { local s; for s in $SETTING_SPECS; do printf '%s\n' "${s%%:*}"; done; }
is_standby_key() { [[ "$STANDBY_KEYS" == *" $1 "* ]]; }

init_settings() {
  local k
  for k in $(all_setting_keys); do printf -v "$k" '%s' ""; done
  AUX_CHANNELS=4
}

valid_value() {
  # $1 type, $2 value
  local t=$1 v=$2
  case "$t" in
    name)      [[ "$v" =~ ^[A-Za-z0-9_.+-]+$ && "$v" != -* ]] ;;
    opt_name)  [[ -z "$v" || ( "$v" =~ ^[A-Za-z0-9_.-]+$ && "$v" != -* ) ]] ;;
    dbname)    [[ "$v" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] ;;
    asmmethod) [[ -z "$v" || "$v" == "asmlib" || "$v" == "udev" ]] ;;
    ip)        if [[ "$v" =~ ^[0-9.]+$ ]]; then
                 # an IPv4 address: four numbers 0-255 (10.0.0 or 999.1.1.1 are refused)
                 [[ "$v" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
                   && (( 10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 && 10#${BASH_REMATCH[3]} <= 255 && 10#${BASH_REMATCH[4]} <= 255 ))
               else
                 # a host name: letters, digits, dots and dashes, at least one letter, no empty label
                 [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$v" =~ [A-Za-z] && "$v" != *..* ]]
               fi ;;
    num)       [[ "$v" =~ ^[0-9]{1,9}$ ]] ;;
    port)      [[ "$v" =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )) ;;
    list)      [[ "$v" =~ ^[A-Za-z0-9_.,:+-]*$ ]] ;;
    yesno)     [[ "$v" == "yes" || "$v" == "no" ]] ;;
    path)      [[ "$v" =~ ^/[A-Za-z0-9_./-]+$ ]] ;;
    opt_path)  [[ -z "$v" || "$v" =~ ^/[A-Za-z0-9_./-]+$ ]] ;;
    opt_paths) [[ -z "$v" || "$v" =~ ^/[A-Za-z0-9_./,-]+$ ]] ;;
    locs)      [[ "$v" =~ ^([+/][A-Za-z0-9_./-]*:[0-9]+)(,[+/][A-Za-z0-9_./-]*:[0-9]+)*$ ]] ;;
    opt_loc)   [[ -z "$v" || "$v" == "USE_DB_RECOVERY_FILE_DEST" || "$v" =~ ^[+/][A-Za-z0-9_./-]+$ ]] ;;
    *) return 1 ;;
  esac
}

settings_file_safe() {
  local owner perm
  owner=$(stat -c '%U' "$1"); perm=$(stat -c '%a' "$1")
  [[ ! -L "$1" && "$owner" == "root" && "${perm: -1}" =~ ^[0145]$ && "${perm: -2:1}" =~ ^[0145]$ ]]
}

load_settings() {
  # Parses $SETTINGS_FILE. $1 = soft: problems are returned in LOAD_ERR (rc 1) instead of stopping.
  # Keys of the 3.x settings file are converted (GRID_ZIP, DB_ZIP) or dropped; unknown keys are dropped.
  local soft=${1:-} line key val spec t
  LOAD_ERR=""; DROPPED_KEYS=""
  [[ -f "$SETTINGS_FILE" ]] || return 1
  if ! settings_file_safe "$SETTINGS_FILE"; then
    LOAD_ERR="$SETTINGS_FILE must be a file owned by root that others cannot write"
    [[ "$soft" == "soft" ]] && return 1; fatal "$LOAD_ERR"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$line" != *=* ]]; then LOAD_ERR="This line is not KEY=VALUE: $line"; break; fi
    key=${line%%=*}; val=${line#*=}
    case "$key" in
      GRID_ZIP) key=GRID_MEDIA; SETTINGS_UPGRADED=1 ;;
      DB_ZIP)   key=DB_MEDIA;   SETTINGS_UPGRADED=1 ;;
    esac
    if [[ "$OLD_KEYS" == *" $key "* ]]; then DROPPED_KEYS+=" $key"; SETTINGS_UPGRADED=1; continue; fi
    spec=""
    for t in $SETTING_SPECS; do [[ "${t%%:*}" == "$key" ]] && spec=${t#*:}; done
    if [[ -z "$spec" ]]; then DROPPED_KEYS+=" $key"; continue; fi
    # values that are derived again when empty (the settings file says so for a new standby name)
    if [[ -z "$val" && "$DERIVED_KEYS" == *" $key "* ]]; then printf -v "$key" '%s' ""; continue; fi
    if ! valid_value "$spec" "$val"; then
      # a typo in a value you may edit is an error; it is never ignored silently
      if is_standby_key "$key" || assumed_key "$key"; then LOAD_ERR="Invalid value: $key=$val"; break; fi
      continue        # a primary value is read again from the primary anyway
    fi
    printf -v "$key" '%s' "$val"
  done < "$SETTINGS_FILE"
  if [[ -n "$LOAD_ERR" ]]; then
    [[ "$soft" == "soft" ]] && return 1
    fatal "$SETTINGS_FILE: $LOAD_ERR
Fix or delete the file, then run the script again."
  fi
  return 0
}

save_settings() {
  [[ "$MODE" == "check" ]] && return 0
  local k tmp
  install -d -m 700 "$STATE_DIR"
  tmp="$SETTINGS_FILE.tmp.$$"
  {
    printf '# dg_standby_setup.sh %s settings - written %s\n' "$SCRIPT_VERSION" "$(ts)"
    printf '# Format KEY=VALUE, no spaces, no quotes.\n\n'
    printf '# ---- Standby values. You may change these. ----\n'
    printf '# To rename the standby: change STANDBY_UNIQUE and leave STANDBY_SID, STANDBY_SERVICE and\n'
    printf '# STANDBY_TNS empty; they are derived again. ASM_METHOD: asmlib or udev (or empty = automatic).\n'
    printf '# GRID_MEDIA / DB_MEDIA: installer zip files (comma list). RU_DIR: an unzipped Release Update\n'
    printf '# that the installer applies (needed for 19c on Oracle Linux 9; with Grid use the GI Release Update,\n'
    printf '# it covers both homes). OPATCH_ZIP: the newest OPatch (p6880880_*.zip), needed with RU_DIR.\n'
    printf '# AUX_CHANNELS: 1-16 (RMAN channels of the copy). STANDBY_HOST / STANDBY_IP: this server, as the primary\n'
    printf '# must reach it. PRIMARY_TNS / STANDBY_TNS: alias names written into tnsnames.ora on both servers.\n'
    for k in $STANDBY_KEYS; do printf '%s=%s\n' "$k" "${!k}"; done
    printf '\n# ---- Connection (change with --primary / --user, or here between runs) ----\n'
    printf 'PRIMARY_IP=%s\nPRIMARY_SSH_USER=%s\n' "$PRIMARY_IP" "$PRIMARY_SSH_USER"
    if [[ ${LSNR_ASSUMED:-0} -eq 1 ]]; then
      printf '\n# ---- Assumed (no running listener on the primary offered the service): you may correct these ----\n'
      printf 'PORT=%s\nLISTENER_NAME=%s\nPRIMARY_SERVICE=%s\n' "$PORT" "$LISTENER_NAME" "$PRIMARY_SERVICE"
    fi
    printf '\n# ---- Read from the primary at every run (the standby uses the same paths, users and names). A change here is NOT kept. ----\n'
    for k in $(all_setting_keys); do
      is_standby_key "$k" && continue
      [[ "$k" == PRIMARY_IP || "$k" == PRIMARY_SSH_USER ]] && continue
      [[ ${LSNR_ASSUMED:-0} -eq 1 && ( "$k" == PORT || "$k" == LISTENER_NAME || "$k" == PRIMARY_SERVICE ) ]] && continue
      printf '%s=%s\n' "$k" "${!k}"
    done
  } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SETTINGS_FILE" || { rm -f -- "$tmp"; bad "Cannot write $SETTINGS_FILE. Is the disk full?"; return 1; }
  # values the script itself sets after you accepted (ASM method, installer files) stay accepted
  [[ ${SETTINGS_ACCEPTED:-0} -eq 1 ]] && save_accepted
  return 0
}

# ---- accepted values (only an accept by the user writes them) ----
settings_lines() {
  # the values that matter for the decision (sizes change every day and are left out)
  local k v
  for k in $(all_setting_keys); do
    case "$k" in PRIMARY_DB_MB|FRA_MB) continue ;; LOCS) v=$(tr ',' '\n' <<< "$LOCS" | cut -d: -f1 | sort | paste -sd, -) ;; *) v=${!k} ;; esac
    printf '%s=%s\n' "$k" "$v"
  done
}
save_accepted() {
  [[ "$MODE" == "check" ]] && return 0
  local tmp="$ACCEPTED_FILE.tmp.$$"
  settings_lines > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$ACCEPTED_FILE" || { rm -f -- "$tmp"; bad "Cannot write $ACCEPTED_FILE"; return 1; }
}
accepted_diff() {
  # prints "KEY: old -> new" for every value that differs from the accepted ones; rc 1 = no accepted file
  [[ -f "$ACCEPTED_FILE" ]] && settings_file_safe "$ACCEPTED_FILE" || return 1
  local line k v old
  while IFS= read -r line; do
    k=${line%%=*}; v=${line#*=}
    old=$(grep -m1 "^$k=" "$ACCEPTED_FILE" | cut -d= -f2-)
    if ! grep -q "^$k=" "$ACCEPTED_FILE"; then printf '%s: (new) -> %s\n' "$k" "$v"
    elif [[ "$old" != "$v" ]]; then printf '%s: %s -> %s\n' "$k" "${old:-<empty>}" "${v:-<empty>}"; fi
  done < <(settings_lines)
  return 0
}

validate_settings() {
  # Cross checks. Prints problems, returns 1 if any.
  local bad_n=0 v t s
  for s in $SETTING_SPECS; do
    v=${s%%:*}; t=${s#*:}
    if [[ "$OPTIONAL_KEYS" != *" $v "* ]]; then
      [[ -n "${!v}" ]] || { bad "$v is empty."; bad_n=1; continue; }
    fi
    valid_value "$t" "${!v}" || { bad "$v has an invalid value: ${!v}"; bad_n=1; }
  done
  for v in DB_HOME ORACLE_BASE GRID_HOME GRID_BASE INVENTORY_DIR; do
    case "${!v}" in /|/usr|/usr/*|/etc|/etc/*|/var|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/root|/home|/proc|/sys|/dev|/dev/*|/tmp)
      bad "$v is a system folder: ${!v}"; bad_n=1 ;; esac
  done
  if [[ "$USE_GRID" == "yes" ]]; then
    [[ -n "$GRID_HOME" && -n "$GRID_BASE" ]] || { bad "GRID_HOME and GRID_BASE are needed, because the primary uses ASM."; bad_n=1; }
    # the standby uses the same paths as the primary: a layout that works on the primary is kept (only noted)
    [[ "$GRID_HOME/" != "$GRID_BASE/"* ]] || warn "The Grid home $GRID_HOME is inside the Grid base $GRID_BASE. This is the same on the primary, so it is kept."
    [[ "$GRID_HOME/" != "$ORACLE_BASE/"* ]] || warn "The Grid home $GRID_HOME is inside the Oracle base $ORACLE_BASE. This is the same on the primary, so it is kept."
    [[ -n "$DATA_DG" ]] || { bad "DATA_DG (the first ASM disk group) is empty."; bad_n=1; }
  elif all_locs | grep -q '^+'; then
    bad "USE_GRID must be yes, because the primary keeps files in ASM."; bad_n=1
  fi
  [[ "$DB_NAME" =~ [\$#] || "$PRIMARY_UNIQUE" =~ [\$#] ]] && { bad "This script does not support database names with \$ or # ($DB_NAME, $PRIMARY_UNIQUE)."; bad_n=1; }
  [[ -n "$STANDBY_IP" && "$STANDBY_IP" != 127.* ]] || { bad "STANDBY_IP must be the network address of this server. It cannot be empty or 127.x."; bad_n=1; }
  [[ "$STANDBY_IP" != "$PRIMARY_IP" ]] || { bad "STANDBY_IP is the IP address of the primary."; bad_n=1; }
  [[ "${STANDBY_HOST,,}" != "${PRIMARY_HOST,,}" ]] || { bad "STANDBY_HOST must differ from the host name of the primary."; bad_n=1; }
  if [[ "$STANDBY_IP" =~ ^[0-9.]+$ ]] && command -v ip >/dev/null 2>&1 && ! grep -qFw -- "$STANDBY_IP" <<< "$(ip -o addr show 2>/dev/null)"; then
    bad "STANDBY_IP $STANDBY_IP is not an address of this server."; bad_n=1
  fi
  [[ "${PRIMARY_UNIQUE^^}" != "${STANDBY_UNIQUE^^}" ]] || { bad "STANDBY_UNIQUE must differ from the db_unique_name of the primary."; bad_n=1; }
  [[ "${PRIMARY_TNS,,}" != "${STANDBY_TNS,,}" ]] || { bad "PRIMARY_TNS and STANDBY_TNS must differ."; bad_n=1; }
  [[ ${#STANDBY_SID} -le 12 ]] || { bad "STANDBY_SID '$STANDBY_SID' is longer than 12 characters."; bad_n=1; }
  [[ "$STANDBY_SID" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || { bad "STANDBY_SID must start with a letter and use only letters, digits and _."; bad_n=1; }
  [[ ${#STANDBY_UNIQUE} -le 30 ]] || { bad "STANDBY_UNIQUE is longer than 30 characters."; bad_n=1; }
  [[ "$AUX_CHANNELS" =~ ^[0-9]+$ && "$AUX_CHANNELS" -ge 1 && "$AUX_CHANNELS" -le 16 ]] || { bad "AUX_CHANNELS must be a number from 1 to 16."; bad_n=1; }
  [[ -z "$RU_DIR" || -d "$RU_DIR" ]] || { bad "RU_DIR $RU_DIR is not a folder."; bad_n=1; }
  if [[ -n "$RU_DIR" ]]; then
    [[ -n "$OPATCH_ZIP" && -f "$OPATCH_ZIP" ]] || { bad "RU_DIR needs OPATCH_ZIP, the newest OPatch zip (p6880880).
The OPatch in the base media is too old."; bad_n=1; }
  fi
  [[ -z "$OPATCH_ZIP" || -f "$OPATCH_ZIP" ]] || { bad "OPATCH_ZIP $OPATCH_ZIP is not a file."; bad_n=1; }

  return $bad_n
}

derive_standby_settings() {
  # Fills standby-side values that are still empty.
  local ls
  ls=$(hostname -s 2>/dev/null || hostname)
  [[ -n "$STANDBY_HOST" ]] || STANDBY_HOST=$ls
  if [[ -z "$STANDBY_IP" ]]; then
    # the address this server uses to reach the primary; never a loopback address
    STANDBY_IP=$(ip -o route get "$PRIMARY_IP" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)
    [[ "$STANDBY_IP" == 127.* ]] && STANDBY_IP=""
    [[ -n "$STANDBY_IP" ]] || STANDBY_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -v '^127\.' | head -n 1)
  fi
  if [[ -z "$STANDBY_UNIQUE" ]]; then
    local u=${PRIMARY_UNIQUE^^}
    u=${u%%.*}
    if [[ ${#u} -le 7 ]]; then STANDBY_UNIQUE="${u}_STBY"     # e.g. PRODDB_STBY (max 12)
    else STANDBY_UNIQUE="${u:0:9}_SB"; fi                     # ORACLE_SID limit is 12 characters
  fi
  [[ -n "$STANDBY_SID" ]] || { STANDBY_SID=${STANDBY_UNIQUE%%.*}; STANDBY_SID=${STANDBY_SID:0:12}; }
  [[ -n "$STANDBY_SERVICE" ]] || STANDBY_SERVICE="${STANDBY_UNIQUE,,}${PRIMARY_DOMAIN:+.$PRIMARY_DOMAIN}"
  [[ -n "$PRIMARY_TNS" ]] || PRIMARY_TNS="${PRIMARY_UNIQUE,,}"
  [[ -n "$STANDBY_TNS" ]] || STANDBY_TNS="${STANDBY_UNIQUE,,}"
  [[ -n "$AUX_CHANNELS" ]] || AUX_CHANNELS=4
}

# ---- helpers on LOCS ("+DATA:120000,/u02/oradata/X:5000") ----
loc_list() { tr ',' '\n' <<< "$LOCS" | grep -v '^$'; }                    # loc:MB lines
all_locs() {
  # every storage location the standby needs: database files, recovery area, archive destination
  loc_list | cut -d: -f1
  [[ -n "$FRA_LOC" ]] && printf '%s\n' "$FRA_LOC"
  [[ -n "$ARCH_LOC" && "$ARCH_LOC" != "USE_DB_RECOVERY_FILE_DEST" ]] && printf '%s\n' "$ARCH_LOC"
  return 0
}
asm_dgs() { all_locs | grep '^+' | sed 's#^+##; s#/.*##' | tr '[:lower:]' '[:upper:]' | sort -u; }   # disk group names
fs_dirs() { all_locs | grep '^/' | sort -u; }                                                          # directories
fra_need_mb() {
  # space the recovery area needs HERE: the primary size, but at most what is sensible for a standby
  # (archived logs of some days). Step 8.1 sets db_recovery_file_dest_size to the space that is free.
  local want=$FRA_MB min=$(( PRIMARY_DB_MB / 10 )); [[ $min -lt 10240 ]] && min=10240
  [[ $want -gt $min ]] && want=$min
  printf '%s' "$want"
}
dg_need_mb() {
  # MB the disk group $1 must hold: database files in it, plus the recovery area when it is there
  local dg=${1^^} total=0 l loc mb
  while IFS= read -r l; do
    loc=${l%%:*}; mb=${l##*:}; loc=${loc#+}; loc=${loc%%/*}
    [[ "${loc^^}" == "$dg" ]] && total=$((total + mb))
  done < <(loc_list | grep '^+')
  local f=${FRA_LOC#+}; f=${f%%/*}
  [[ "$FRA_LOC" == +* && "${f^^}" == "$dg" ]] && total=$((total + $(fra_need_mb)))
  printf '%s' "$total"
}
loc_mb() { loc_list | awk -F: -v l="$1" '$1==l {s+=$2} END {print s+0}'; }  # MB needed in one location
single_owner() { [[ "$ORACLE_USER" == "$GRID_USER" ]]; }
use_grid() { [[ "$USE_GRID" == "yes" ]]; }

show_settings() {
  # two short sections; the names of the keys are in the settings file (the editor shows them)
  local fmt='        %-17s %s\n' l first=1
  printf '\n      %sPrimary%s  %s(read from %s at every run)%s\n' "$C_W" "$C_N" "$C_D" "$PRIMARY_IP" "$C_N"
  printf "$fmt" "Host" "$PRIMARY_HOST"
  printf "$fmt" "Database" "$DB_NAME, unique name $PRIMARY_UNIQUE"
  printf "$fmt" "ORACLE_SID" "$PRIMARY_SID"
  printf "$fmt" "Version" "$PRIMARY_VERSION, CDB $PRIMARY_CDB"
  if [[ ${LSNR_ASSUMED:-0} -eq 1 ]]; then
    printf "$fmt" "Service" "$PRIMARY_SERVICE  (assumed)"
    printf "$fmt" "Listener" "$LISTENER_NAME, port $PORT  (assumed)"
    printf "$fmt" "" "${C_Y}No running listener offers this service. Check these two lines.${C_N}"
  else
    printf "$fmt" "Service" "$PRIMARY_SERVICE"
    printf "$fmt" "Listener" "$LISTENER_NAME, port $PORT"
  fi
  printf "$fmt" "Size" "$(human_mb "$PRIMARY_DB_MB")"
  [[ -n "${DB_EDITION:-}" ]] && printf "$fmt" "Edition" "$DB_EDITION"
  printf "$fmt" "Storage" "$(use_grid && printf 'ASM (Oracle Restart will be installed here)' || printf 'File system (no Grid needed here)')"
  while IFS= read -r l; do
    printf "$fmt" "$([[ $first -eq 1 ]] && printf 'Data files')" "${l%%:*}  ($(human_mb "${l##*:}"))"; first=0
  done < <(loc_list)
  printf "$fmt" "Recovery area" "${FRA_LOC:-not set}${FRA_LOC:+  ($(human_mb "$FRA_MB") on the primary)}"
  printf "$fmt" "Archive logs" "${ARCH_LOC:-not set}"
  printf "$fmt" "Database home" "$DB_HOME"
  use_grid && printf "$fmt" "Grid home" "$GRID_HOME"
  printf "$fmt" "Oracle base" "$ORACLE_BASE"
  use_grid && printf "$fmt" "Grid base" "$GRID_BASE"
  printf "$fmt" "Inventory" "$INVENTORY_DIR"
  if single_owner; then printf "$fmt" "Owner" "$ORACLE_USER ($ORACLE_UID), owns all Oracle software"
  else printf "$fmt" "Users" "$ORACLE_USER ($ORACLE_UID), $GRID_USER ($GRID_UID)"; fi
  local gl="" gn=0 g lab="Groups"
  for g in ${GROUP_GIDS//,/ }; do
    gl+="${gl:+, }$g"; gn=$((gn + 1))
    [[ $gn -eq 4 ]] && { printf "$fmt" "$lab" "$gl"; lab=""; gl=""; gn=0; }
  done
  [[ -n "$gl" ]] && printf "$fmt" "$lab" "$gl"
  printf '        %sThis server gets the same homes, users and paths.%s\n' "$C_D" "$C_N"

  printf '\n      %sThis server (standby)%s  %s(change with e)%s\n' "$C_W" "$C_N" "$C_D" "$C_N"
  printf "$fmt" "Host" "$STANDBY_HOST, $STANDBY_IP"
  printf "$fmt" "db_unique_name" "$STANDBY_UNIQUE"
  printf "$fmt" "ORACLE_SID" "$STANDBY_SID"
  [[ "$STANDBY_UNIQUE" == *_SB ]] && printf "$fmt" "" "${C_D}_SB, not _STBY: an ORACLE_SID has at most 12 characters${C_N}"
  printf "$fmt" "Service" "$STANDBY_SERVICE"
  printf "$fmt" "TNS aliases" "$PRIMARY_TNS (primary), $STANDBY_TNS (standby)"
  printf "$fmt" "Listener" "$SB_LSNR, port $PORT"
  if [[ -n "$GRID_MEDIA$DB_MEDIA" ]]; then
    local lab="Installer files"
    for l in ${GRID_MEDIA//,/ } ${DB_MEDIA//,/ }; do printf "$fmt" "$lab" "$l"; lab=""; done
    [[ -z "$DB_MEDIA" ]] && printf "$fmt" "" "database files: found later (step 3.1)"
  else printf "$fmt" "Installer files" "found later (step 3.1)"; fi
  [[ -n "$RU_DIR" ]] && printf "$fmt" "Release Update" "$RU_DIR"
  [[ -n "$OPATCH_ZIP" ]] && printf "$fmt" "OPatch" "$OPATCH_ZIP"
  use_grid && printf "$fmt" "ASM disk method" "${ASM_METHOD:-decided in step 2.12}"
  printf "$fmt" "RMAN channels" "$AUX_CHANNELS"
  printf '\n'
  _log SETTINGS "$(for k in $(all_setting_keys); do printf '%s=%s ' "$k" "${!k}"; done)"
}

group_gid() {
  # $1 group name -> gid from GROUP_GIDS
  local e
  IFS=',' read -ra _gg <<< "$GROUP_GIDS"
  for e in "${_gg[@]}"; do [[ "${e%%:*}" == "$1" ]] && { printf '%s' "${e#*:}"; return 0; }; done
  return 1
}

#------------------------------------------------------------------------------
# Primary access (READ-ONLY)
#   One ssh master connection (you type the OS password into ssh itself),
#   then a fixed list of read-only probes over that connection.
#------------------------------------------------------------------------------
DISCOVERED=0
SETTINGS_ACCEPTED=0
SYS_VERIFIED=0
PRIMARY_TNS_ADMIN=""

v_name() { [[ "$1" =~ ^[A-Za-z0-9_.+-]+$ && "$1" != -* ]]; }
v_path() { [[ "$1" =~ ^/[A-Za-z0-9_./-]+$ ]]; }

ssh_alive() {
  [[ -n "$SSH_CTL" && -e "$SSH_CTL" ]] || return 1
  ssh -o ControlMaster=no -o ControlPath="$SSH_CTL" -O check "$PRIMARY_SSH_USER@$PRIMARY_IP" >/dev/null 2>&1
}

prim_ssh() {
  # $1 = remote command built by prim_probe / prim_sql only. stdin is passed through.
  # A stuck remote command (a hung NFS path, a wedged listener) ends after PROBE_TIMEOUT seconds (exit 124).
  # ControlMaster=no: a ControlMaster setting in root's ~/.ssh/config must not turn this call into a new master
  timeout --foreground "${PROBE_TIMEOUT:-300}" ssh -o ControlMaster=no -o ControlPath="$SSH_CTL" -o BatchMode=yes -o ConnectTimeout=15 "$PRIMARY_SSH_USER@$PRIMARY_IP" "$1"
}
PROBE_TIMEOUT=300

prim_probe() {
  # Fixed list of read-only commands. Arguments are validated before use.
  # (No tool that writes files is run on the primary: for example the patch list is read
  #  from the folder names in <home>/inventory/oneoffs, not with opatch, which writes logs.)
  local p=$1 cmd
  shift
  local a
  for a in "$@"; do
    [[ "$a" == "/" && ( "$p" == lsdir || "$p" == canlook ) ]] && continue
    [[ "$a" != -* ]] && { v_name "$a" || v_path "$a"; } || fatal "Safety stop: invalid value for the primary check $p: $a"
  done
  case "$p" in
    host)        cmd='hostname -s; hostname -f' ;;
    oratab)      cmd='cat /etc/oratab' ;;
    orainst)     cmd='cat /etc/oraInst.loc' ;;
    olr)         cmd='cat /etc/oracle/olr.loc' ;;
    ps)          cmd='ps -eo pid,user:32,args' ;;
    exe)         num "$1" || fatal "Safety stop: invalid process id $1"; cmd="readlink /proc/$1/exe" ;;
    environ)     num "$1" || fatal "Safety stop: invalid process id $1"
                 cmd="tr '\\0' '\\n' < /proc/$1/environ | grep -E '^(ORACLE_HOME|ORACLE_SID|ORACLE_BASE|TNS_ADMIN)='" ;;
    ids)         cmd="id $1; id $2" ;;
    owner)       cmd="stat -c '%U %G' $1" ;;
    statx)       cmd="stat -c '%U|%G|%a|%F|%Y' $1" ;;
    # only a real answer of test counts (0 = YES, 1 = NO); a timeout or any other end gives no answer ("not proven")
    # (sh -c: the login shell of the ssh user may be csh)
    exists)      cmd="sh -c 'timeout 120 test -e $1; r=\$?; [ \$r -eq 0 ] && echo YES; [ \$r -eq 1 ] && echo NO; true'" ;;
    canlook)     cmd="sh -c 'timeout 120 test -d $1 -a -x $1; r=\$?; [ \$r -eq 0 ] && echo YES; [ \$r -eq 1 ] && echo NO; true'" ;;
    fsid)        cmd="findmnt -n -o SOURCE,UUID --target $1" ;;
    mounts)      cmd="sh -c 'findmnt -rn -o SOURCE,UUID | while read -r s u; do case \"\$s\" in /dev/*) echo \"M|\$s|\$u\"; lsblk -nsP -o TYPE,WWN,SERIAL \"\${s%%\\[*}\";; esac; done; echo __DG_MOUNTS_END__'" ;;
    now)         cmd='date +%s' ;;
    gridver)     cmd="grep -o 'NAME=\"oracle.crs\" VER=\"[0-9.]*\"' $1/inventory/ContentsXML/comps.xml" ;;
    md5)         cmd="md5sum $1" ;;
    lsdir)       cmd="ls -1A $1" ;;
    profile)     cmd="grep -sE '^[[:space:]]*(export[[:space:]]+)?(ORACLE_HOME|ORACLE_SID|ORACLE_BASE|TNS_ADMIN)=' \$HOME/.bash_profile \$HOME/.bashrc" ;;
    orabase)     cmd="env ORACLE_HOME=$1 $1/bin/orabase" ;;
    orabasehome) cmd="env ORACLE_HOME=$1 $1/bin/orabasehome" ;;
    lsnr)        cmd="env ORACLE_HOME=$1${3:+ TNS_ADMIN=$3} timeout 120 $1/bin/lsnrctl status $2" ;;
    invxml)      cmd="cat $1/ContentsXML/inventory.xml" ;;
    tnsping)     cmd="env ORACLE_HOME=$1 TNS_ADMIN=$2 $1/bin/tnsping $3 1" ;;
    hosts)       cmd="getent ahostsv4 $1" ;;
    *) fatal "Safety stop: unknown primary check $p" ;;
  esac
  # commands that read files or devices end on the primary itself after 120 s (a hung NFS path must not leave
  # a stuck process there for every probe)
  case "$p" in owner|statx|fsid|md5|lsdir|gridver|invxml|tnsping|orabase|orabasehome) cmd="timeout 120 $cmd" ;; esac
  # A marker line separates our output from anything a login script on primary prints;
  # stderr goes to the log only, never into the parsed output.
  local out err rc=0
  err=$(mktemp); CLEANUP_FILES+=("$err")
  # a stuck remote command (a hung NFS path, a wedged listener) must not stop the script for ever
  out=$(prim_ssh "echo $PROBE_MARK; $cmd" < /dev/null 2>"$err") || rc=$?
  PROBE_TIMED_OUT=0; PROBE_ERR=""
  [[ $rc -eq 124 ]] && { printf 'no answer from the primary within %s s (%s)\n' "$PROBE_TIMEOUT" "$p" >> "$err"; PROBE_TIMED_OUT=1; warn "The primary did not answer in time ($p). The result of this check is unknown.
Time limits: 120 s on the primary, $PROBE_TIMEOUT s here."; }
  { printf '%s\n' "$out"; printf -- '--- stderr ---\n'; cat "$err"; printf '(exit code %s)\n' "$rc"; } | log_block "PRIMARY probe $p: $cmd"
  PROBE_ERR=$(head -c 2000 "$err" 2>/dev/null)
  rm -f "$err"
  if [[ "$out" == *"$PROBE_MARK"* ]]; then RUN_OUT=${out#*"$PROBE_MARK"}; RUN_OUT=${RUN_OUT#$'\n'}
  else RUN_OUT=""; [[ $rc -eq 0 ]] && rc=1; fi
  return $rc
}
readonly PROBE_MARK="__DG_PROBE_OUTPUT__"
PROBE_TIMED_OUT=0; PROBE_ERR=""

prim_scp() {
  # Copy ONE file FROM primary to this server over the existing connection (read-only on primary).
  local src=$1 dst=$2
  v_path "$src" || fatal "Safety stop: invalid path on the primary: $src"
  run_logged "scp from primary: $src -> $dst" timeout --foreground 600 scp -q -o ControlMaster=no -o ControlPath="$SSH_CTL" -o BatchMode=yes "$PRIMARY_SSH_USER@$PRIMARY_IP:$src" "$dst" < /dev/null && return 0
  local rc=$?
  # OL9 scp uses the SFTP protocol; a primary without the sftp subsystem needs the old protocol (-O)
  if [[ ${OS_MAJOR:-0} -ge 9 ]] && grep -qiE 'subsystem|sftp|connection closed' <<< "$RUN_OUT"; then
    run_logged "scp (old protocol) from primary: $src -> $dst" timeout --foreground 600 scp -O -q -o ControlMaster=no -o ControlPath="$SSH_CTL" -o BatchMode=yes "$PRIMARY_SSH_USER@$PRIMARY_IP:$src" "$dst" < /dev/null && return 0
    rc=$?
  fi
  [[ $rc -eq 124 ]] && RUN_OUT+=$'\n'"no answer from the primary within 600 s"
  return $rc
}

readonly SQL_MARK="__DG_SQL_OUTPUT__"
sql_result() {
  # $1 raw sqlplus output, $2 rc. SQL_OUT = only the lines after the marker
  # (so login banners, glogin.sql output, "Session altered." are ignored).
  local raw=$1 rc=$2
  if [[ "$raw" == *"$SQL_MARK"* ]]; then SQL_OUT=${raw#*"$SQL_MARK"}
  else SQL_OUT=$raw; [[ $rc -eq 0 ]] && rc=1; fi
  SQL_OUT=$(printf '%s\n' "$SQL_OUT" | sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d')
  if [[ $rc -ne 0 ]] || grep -qE '(ORA|SP2|TNS)-[0-9]+' <<< "$raw"; then
    # keep the error text visible to the caller
    [[ "$raw" == *"$SQL_MARK"* ]] || SQL_OUT=$(printf '%s\n' "$raw" | sed -e '/^[[:space:]]*$/d')
    grep -qE '(ORA|SP2|TNS)-[0-9]+' <<< "$SQL_OUT" || SQL_OUT=$(printf '%s\n%s' "$SQL_OUT" "$(grep -E '(ORA|SP2|TNS)-[0-9]+' <<< "$raw")")
    # a failed connect prints its error BEFORE the marker; after it there is only "SP2-0640: Not connected"
    if [[ "$raw" == *"$SQL_MARK"* ]]; then
      local pre=${raw%%"$SQL_MARK"*} pe
      pe=$(grep -E '(ORA|TNS)-[0-9]+' <<< "$pre")
      [[ -n "$pe" ]] && SQL_OUT=$(printf '%s\n%s' "$pe" "$SQL_OUT")
    fi
    return 1
  fi
  return 0
}

readonly SQL_HEADER='set heading off feedback off pagesize 0 verify off echo off trimspool on linesize 4000 tab off
whenever sqlerror exit 3'

readonly_guard() {
  # 0 only for a single-line, single SELECT without data-changing/procedural keywords.
  local q=$1 l body
  [[ "$q" == *$'\n'* || "$q" == *$'\r'* ]] && return 1
  l=${q,,}
  l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
  [[ "$l" =~ ^select[[:space:]] ]] || return 1
  [[ "$l" == *";" ]] || return 1
  body=${l%;}
  [[ "$body" == *";"* ]] && return 1
  [[ "$l" == *"&"* || "$l" == *"--"* || "$l" == *"/*"* || "$l" == *"@"* ]] && return 1
  if grep -Eq '(^|[^a-z0-9_$#])(insert|update|delete|merge|upsert|alter|drop|create|grant|revoke|truncate|rename|comment|begin|declare|exec|execute|call|commit|rollback|savepoint|lock|shutdown|startup|host|spool|connect|into|nextval|for[[:space:]]+update|dbms_[a-z0-9_]*|utl_[a-z0-9_]*|sys\.[a-z0-9_]*)([^a-z0-9_$#]|$)' <<< "$l"; then
    return 1
  fi
  return 0
}

_prim_sqlplus() {
  # $1 connect line, $2 query (already guarded), $3 title. Runs sqlplus ON PRIMARY over ssh.
  local out rc=0
  v_name "$PRIMARY_SID" && v_path "$DB_HOME" && { [[ -z "$PRIMARY_TNS_ADMIN" ]] || v_path "$PRIMARY_TNS_ADMIN"; } && num "$SQL_TIMEOUT" \
    || fatal "Safety stop: invalid SID, home or TNS_ADMIN of the primary"
  # TWO_TASK / LOCAL in the profile of the primary user would send "connect / as sysdba" over the network
  out=$(printf 'set define off\n%s\n%s\nprompt %s\n%s\nexit\n' "$1" "$SQL_HEADER" "$SQL_MARK" "$2" \
        | PROBE_TIMEOUT=$((SQL_TIMEOUT + 30)) prim_ssh "env -u TWO_TASK -u LOCAL -u SQLPATH -u ORACLE_PATH -u ORACLE_PDB_SID ORACLE_HOME=$DB_HOME ORACLE_SID=$PRIMARY_SID TNS_ADMIN=${PRIMARY_TNS_ADMIN:-$DB_HOME/network/admin} timeout $SQL_TIMEOUT $DB_HOME/bin/sqlplus -S /nolog" 2>&1) || rc=$?
  [[ $rc -eq 124 ]] && out+=$'\n'"SP2-0000: sqlplus on primary did not answer within $SQL_TIMEOUT seconds (stopped)"
  [[ $rc -eq 255 ]] && out+=$'\n'"SP2-0000: ssh connection to primary lost (ssh exit 255)"
  { printf 'SQL> %s\n' "$2"; printf '%s\n(exit code %s)\n' "$out" "$rc"; } | log_block "$3"
  sql_result "$out" "$rc"
}

prim_sql() {
  # READ-ONLY query on primary (OS authentication of the primary oracle user).
  local q=$1
  readonly_guard "$q" || { _log SAFETY "Blocked: $q"; fatal "Safety stop: this statement is not read-only, so it was NOT sent to the primary: $q"; }
  _prim_sqlplus "connect / as sysdba" "$q" "PRIMARY (read-only): ${q:0:150}"
}

prim_sql_as_sys() {
  # READ-ONLY query on primary, logging in as sys through the network ($1 = target).
  local target=$1 q=$2
  readonly_guard "$q" || fatal "Safety stop: this statement is not read-only, so it was NOT sent to the primary: $q"
  [[ "$target" =~ ^(//[A-Za-z0-9_.-]+:[0-9]+/[A-Za-z0-9_.-]+|[A-Za-z0-9_.-]+)$ ]] || fatal "Safety stop: invalid connect target $target"
  _prim_sqlplus "connect sys/\"$SYS_PW\"@$target as sysdba" "$q" "PRIMARY sqlplus as sys@$target (read-only): ${q:0:120}"
}

ssh_diagnose() {
  # $1 = ssh error file. Says what is wrong and prints the commands that fix it.
  local e; e=$(cat "$1" 2>/dev/null)
  local u=$PRIMARY_SSH_USER ip=$PRIMARY_IP
  case "$e" in
    *"Permission denied"*)
      print_commands "Check on the PRIMARY ($ip)" "root  ->  shell" <<EOF
# The password of $u was refused, or password login is turned off.
grep -iE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|AllowUsers|DenyUsers)' /etc/ssh/sshd_config
# PasswordAuthentication must be yes. After a change:
systemctl restart sshd
# To unlock the user or set its password:
passwd $u
EOF
      ;;
    *"Connection refused"*)
      print_commands "Check on the PRIMARY ($ip)" "root  ->  shell" <<EOF
# Nothing listens on port 22: sshd is stopped.
systemctl enable --now sshd
systemctl status sshd
EOF
      ;;
    *"timed out"*|*"No route to host"*|*"Network is unreachable"*)
      print_commands "Check on the PRIMARY ($ip)" "root  ->  shell" <<EOF
# The network or a firewall blocks port 22 between the servers.
firewall-cmd --list-services
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload
EOF
      ;;
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
      print_commands "Run on this server ($(hostname -s))" "root  ->  shell" <<EOF
# The saved host key of $ip is old, for example after a reinstall. Remove it and try again:
ssh-keygen -R $ip
ssh $u@$ip hostname
EOF
      ;;
    *"Could not resolve hostname"*)
      say "The name $ip cannot be resolved here. Start the script with the IP address:"
      say "  $SELF --primary <IP>" ;;
    *)
      print_commands "Test on this server ($(hostname -s))" "root  ->  shell" <<EOF
ssh -v $u@$ip hostname
EOF
      ;;
  esac
}

open_ssh() {
  install -d -m 700 "$STATE_DIR"
  SSH_CTL="$STATE_DIR/ssh_ctl"
  # an old master (busy or broken) is closed first: once its socket is removed nothing could close it
  [[ -e "$SSH_CTL" ]] && timeout 10 ssh -o ControlPath="$SSH_CTL" -O exit "$PRIMARY_SSH_USER@$PRIMARY_IP" >/dev/null 2>&1
  rm -f -- "$SSH_CTL"
  local elog="$STATE_DIR/ssh_error.log"
  : > "$elog"; chmod 600 "$elog"
  say "Type the password of $PRIMARY_SSH_USER on $PRIMARY_IP when ssh asks. Only ssh sees it."
  say "If ssh asks to accept the host key of the primary, answer yes."
  # Only options that every OpenSSH since 6.7 knows (Oracle Linux 7 has 7.4, OL8 has 8.0).
  # -E: ssh writes its own error messages to a file, so they can be shown and logged.
  if ssh -E "$elog" -o ControlMaster=yes -o ControlPath="$SSH_CTL" -o ControlPersist=12h \
         -o ServerAliveInterval=60 -o ConnectTimeout=15 -o NumberOfPasswordPrompts=3 \
         -fN "$PRIMARY_SSH_USER@$PRIMARY_IP" < "$PROMPT_IN" 9>&-; then
    SSH_OPEN=1
  else
    bad "The ssh connection to $PRIMARY_SSH_USER@$PRIMARY_IP failed."
    if [[ -s "$elog" ]]; then printf 'ssh said:\n'; sed 's/^/  /' "$elog"; fi | hint
    ssh_diagnose "$elog"
    log_block "ssh error output" < "$elog"
    return 1
  fi
  ssh_alive || { bad "The ssh connection is not usable."; sed 's/^/  /' "$elog" | hint; return 1; }
  DONE_MSG="Connected to $PRIMARY_SSH_USER@$PRIMARY_IP."

}


#------------------------------------------------------------------------------
# Discovery of the primary (read-only). Nothing here depends on the environment
# (.bash_profile) of the user on primary: the database is found by its running
# processes, its home by /etc/oratab or by the program the process runs.
# A program found this way is used only when it belongs to the user that runs
# the process and nobody else can change it.
#------------------------------------------------------------------------------
PS_OUT=""; DB_PMON_PID=""; ASM_PMON_PID=""; AUDIT_DEST=""; DIAG_DEST=""; TDE_INFO=""; WALLET_ROOT=""; TDE_CONFIG=""
PRIM_CLOCK_OFFSET=0    # primary clock minus this server's clock (seconds)
DISC_NOTES=()          # things worth telling the user (oratab differs, env missing, ...)

parse_id_line() {
  # "uid=54321(oracle) gid=54321(oinstall) groups=54321(oinstall),54322(dba)"
  # -> sets PID_UID PID_PGROUP PID_GROUPS(name:gid,...)
  local line=$1
  PID_UID=$(sed -n 's/^uid=\([0-9]*\).*/\1/p' <<< "$line")
  PID_PGROUP=$(sed -n 's/.* gid=[0-9]*(\([^)]*\)).*/\1/p' <<< "$line")
  PID_GROUPS=$(sed -n 's/.*groups=//p' <<< "$line" | tr ',' '\n' | sed -n 's/^\([0-9]*\)(\([^)]*\))$/\2:\1/p' | paste -sd, -)
}

home_of_pid() {
  # $1 pid -> ORACLE_HOME of the program it runs (empty if it cannot be read)
  prim_probe exe "$1" || return 1
  local exe; exe=$(head -n 1 <<< "$RUN_OUT")
  [[ "$exe" == */bin/oracle ]] || return 1
  printf '%s' "${exe%/bin/oracle}"
}

trusted_prog() {
  # $1 program path on primary, $2 expected owner (empty = any Oracle owner seen so far).
  # 0 when it is a regular file, owned by that user, not writable by group or others.
  v_path "$1" || return 1
  prim_probe statx "$1" || return 1
  local u g m t
  IFS='|' read -r u g m t _ <<< "$(head -n 1 <<< "$RUN_OUT")"
  [[ "$t" == "regular file" ]] || return 1
  [[ -z "$2" || "$u" == "$2" ]] || return 1
  [[ "$m" =~ ^[0-7]+$ ]] || return 1
  local gd=${m: -2:1} od=${m: -1}
  (( (8#$gd & 2) == 0 && (8#$od & 2) == 0 ))
}
home_ok() { v_path "$1" && trusted_prog "$1/bin/oracle" "${2:-}"; }    # it is an Oracle home on primary

ARCH_N=""; P_DG_CONFIG=""
norm_loc() {
  # "+data/X/..." -> "+DATA" ; "/u02/oradata/X/" -> "/u02/oradata/X"
  local v=$1
  if [[ "$v" == +* ]]; then v=${v%%/*}; printf '%s' "${v^^}"; else printf '%s' "${v%/}"; fi
}

read_arch_params() {
  # recovery area, archive destination, folders of the instance (read-only).
  # Sets FRA_LOC FRA_MB ARCH_LOC ARCH_N AUDIT_DEST DIAG_DEST CFD. The local archive destination is the lowest
  # log_archive_dest_N with a LOCATION (not always 1).
  prim_sql "select name||'|'||nvl(value,'-') from v\$parameter where name in ('db_create_file_dest','db_recovery_file_dest','db_recovery_file_dest_size','log_archive_dest','audit_file_dest','diagnostic_dest') or (name like 'log_archive_dest__' or name like 'log_archive_dest___') and upper(value) like '%LOCATION%';" \
    || return 1
  local pn pv d1="-" lad="-" dn
  CFD="-"; FRA_LOC=""; FRA_MB=0; ARCH_LOC=""; ARCH_N=""; AUDIT_DEST=""; DIAG_DEST=""
  while IFS='|' read -r pn pv; do
    case "$pn" in
      db_create_file_dest) CFD=$pv ;;
      db_recovery_file_dest) [[ "$pv" != "-" ]] && FRA_LOC=$(norm_loc "$pv") ;;
      db_recovery_file_dest_size) num "$pv" && FRA_MB=$(( pv / 1048576 )) ;;
      log_archive_dest_[0-9]*) dn=${pn#log_archive_dest_}
        # a destination that works only in the standby role (left from an earlier role change) is not the local one
        if num "$dn" && [[ -z "$ARCH_N" || $dn -lt $ARCH_N ]] && [[ "${pv^^}" == *LOCATION* && "$(tr -d ' ' <<< "${pv^^}")" != *",STANDBY_ROLE)"* ]]; then ARCH_N=$dn; d1=$pv; fi ;;
      log_archive_dest) lad=$pv ;;
      audit_file_dest) [[ "$pv" =~ ^/[A-Za-z0-9_./-]+$ ]] && AUDIT_DEST=${pv%/} ;;
      diagnostic_dest) [[ "$pv" =~ ^/[A-Za-z0-9_./-]+$ ]] && DIAG_DEST=${pv%/} ;;
    esac
  done <<< "$SQL_OUT"
  [[ "$FRA_LOC" =~ ^[+/][A-Za-z0-9_./-]+$ ]] || FRA_LOC=""
  [[ -n "$FRA_LOC" ]] || FRA_MB=0
  OLD_ARCH_DEST=""
  local d1u=${d1^^}
  if [[ "$d1u" =~ LOCATION[[:space:]]*=[[:space:]]*[\"\']?USE_DB_RECOVERY_FILE_DEST ]]; then ARCH_LOC=USE_DB_RECOVERY_FILE_DEST
  elif [[ "$d1" =~ [Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn][[:space:]]*=[[:space:]]*[\"\']?([+/][A-Za-z0-9_./-]+) ]]; then ARCH_LOC=$(norm_loc "${BASH_REMATCH[1]}")
  elif [[ "$lad" =~ ^[+/][A-Za-z0-9_./-]+$ ]]; then ARCH_LOC=$(norm_loc "$lad"); OLD_ARCH_DEST=$ARCH_LOC
  elif [[ -n "$FRA_LOC" ]]; then ARCH_LOC=USE_DB_RECOVERY_FILE_DEST
  else ARCH_LOC=""; fi
  [[ -n "$ARCH_N" ]] || ARCH_N=1
  return 0
}

pick_from_list() {
  # $1 prompt, $2 count -> ANSWER = 1..count; q stops the script. No default: the order of ps means nothing.
  while true; do
    ask "$1  (q to stop)"
    [[ "${ANSWER,,}" == "q" ]] && user_stop "Stopped by you"
    [[ "$ANSWER" =~ ^[0-9]{1,3}$ ]] && (( 10#$ANSWER >= 1 && 10#$ANSWER <= $2 )) && { ANSWER=$((10#$ANSWER)); return 0; }
    say "Please type a number from 1 to $2, or q."
  done
}

discover_primary() {
  local l
  DISC_NOTES=()
  [[ "$PRIMARY_SSH_USER" != "root" ]] || fatal "Do not use root for ssh. Use the Oracle software owner, for example:  --user oracle"
  # ---- host
  prim_probe host || { bad "Cannot run commands on the primary."; return 1; }
  PRIMARY_HOST=$(sed -n '1p' <<< "$RUN_OUT" | tr -d '[:space:]')
  v_name "$PRIMARY_HOST" || { bad "The primary returned an unexpected host name: $PRIMARY_HOST"; return 1; }
  local ls; ls=$(hostname -s 2>/dev/null || hostname)
  if [[ "${PRIMARY_HOST,,}" == "${ls,,}" ]]; then
    fatal "The primary has the same host name as this server: $PRIMARY_HOST. Data Guard needs two names.
If this server is the primary, run the script on the standby server instead.
If this server is a clone of the primary, give it its own name first:
  hostnamectl set-hostname <new name>
Then fix /etc/hosts and run the script again."
  fi
  ok "Primary host: $PRIMARY_HOST"
  if prim_probe now && num "$(head -n 1 <<< "$RUN_OUT")"; then
    PRIM_CLOCK_OFFSET=$(( $(head -n 1 <<< "$RUN_OUT") - $(date +%s) ))
    [[ ${PRIM_CLOCK_OFFSET#-} -gt 300 ]] && DISC_NOTES+=("The clock of the primary is $PRIM_CLOCK_OFFSET seconds off from this server.
Fix the time synchronization: step 2.10 here, chronyd on the primary.")
  fi

  # ---- running instances and listeners
  prim_probe ps || { bad "Cannot list the processes on the primary."; return 1; }
  PS_OUT=$RUN_OUT
  local -a pm=()
  ASM_PMON_PID=""
  local pid user args
  while read -r pid user args; do
    if [[ "$args" =~ ^ora_pmon_([A-Za-z][A-Za-z0-9_]*)$ ]]; then
      local psid=${BASH_REMATCH[1]}
      num "$pid" && v_name "$user" && pm+=("$psid:$pid:$user")
    fi
    [[ "$args" =~ ^asm_pmon_\+ASM[0-9]*$ ]] && num "$pid" && ASM_PMON_PID=$pid
  done <<< "$PS_OUT"
  local oratab=""
  prim_probe oratab && oratab=$RUN_OUT

  if [[ ${#pm[@]} -eq 0 ]]; then
    bad "No database instance is running on the primary (no ora_pmon_<SID> process)."
    printf 'The primary database must be open for this script.\nStart it on the primary as oracle:\n  sqlplus / as sysdba\n  startup\n' | hint
    return 1
  fi
  local pick=1 i saved_sid=$PRIMARY_SID
  if [[ ${#pm[@]} -gt 1 ]]; then
    pick=""
    # the database chosen in an earlier run is used again (--settings or a new primary IP start over)
    if [[ -n "$saved_sid" && $REVIEW_SETTINGS -eq 0 ]]; then
      for i in "${!pm[@]}"; do [[ "${pm[$i]%%:*}" == "$saved_sid" ]] && pick=$((i + 1)); done
      [[ -n "$pick" ]] && ok "Database $saved_sid, chosen in an earlier run
To choose another one:  $SELF --settings"
    fi
    if [[ -z "$pick" ]]; then
      say "Running databases on the primary:"
      for i in "${!pm[@]}"; do say "  $((i + 1))) ${pm[$i]%%:*}   user ${pm[$i]##*:}"; done
      pick_from_list "Number of the database for the standby, 1 to ${#pm[@]}" "${#pm[@]}"
      pick=$ANSWER
    fi
  fi
  local e=${pm[$((pick - 1))]} pmon_user
  PRIMARY_SID=${e%%:*}; e=${e#*:}; DB_PMON_PID=${e%%:*}; pmon_user=${e#*:}
  v_name "$PRIMARY_SID" || { bad "Unexpected SID: $PRIMARY_SID"; return 1; }

  # ---- database home: the program of the running process, else oratab, else ask.
  #      The home is accepted only when its bin/oracle belongs to the user that runs the instance.
  local tab_home="" run_home=""
  tab_home=$(awk -F: -v s="$PRIMARY_SID" '$1==s {print $2; exit}' <<< "$(sed 's/#.*//' <<< "$oratab")")
  tab_home=${tab_home%/}
  run_home=$(home_of_pid "$DB_PMON_PID" || true)
  if [[ -n "$run_home" ]] && home_ok "$run_home" "$pmon_user"; then
    DB_HOME=$run_home
    if [[ -z "$tab_home" ]]; then DISC_NOTES+=("/etc/oratab on the primary has no line for $PRIMARY_SID. Suggested line:  $PRIMARY_SID:$DB_HOME:N")
    elif [[ "$tab_home" != "$run_home" ]]; then DISC_NOTES+=("/etc/oratab on the primary says $tab_home for $PRIMARY_SID,
but the database runs from $run_home."); fi
  elif [[ -n "$tab_home" ]] && home_ok "$tab_home" "$pmon_user"; then
    DB_HOME=$tab_home
  else
    # the environment of the running process (readable as its owner), then the inventory, then ask
    local eh="" ih
    if prim_probe environ "$DB_PMON_PID"; then eh=$(sed -n 's/^ORACLE_HOME=//p' <<< "$RUN_OUT" | head -n 1); eh=${eh%/}; fi
    if [[ -n "$eh" ]] && home_ok "$eh" "$pmon_user"; then DB_HOME=$eh
    else
      for ih in $(inventory_homes); do home_ok "$ih" "$pmon_user" && { DB_HOME=$ih; break; }; done
    fi
    [[ -n "$DB_HOME" ]] && DISC_NOTES+=("/etc/oratab on the primary has no usable line for $PRIMARY_SID. Its home was found another way.
Suggested oratab line:  $PRIMARY_SID:$DB_HOME:N")
  fi
  if [[ -z "$DB_HOME" ]]; then
    warn "The Oracle home of $PRIMARY_SID was not found.
It is not in /etc/oratab or the inventory, and the process cannot be read."
    say "Example of a home:  /u01/app/oracle/product/19.0.0/dbhome_1"
    while true; do
      ask "Full path of the database ORACLE_HOME on the primary (q to stop)"
      [[ "${ANSWER,,}" == "q" ]] && user_stop "Stopped by you"
      ANSWER=${ANSWER%/}
      if home_ok "$ANSWER" "$pmon_user"; then DB_HOME=$ANSWER; break; fi
      say "$ANSWER/bin/oracle is not on the primary, or it does not belong to $pmon_user (the owner of the instance)."
    done
  fi
  ok "Instance: ORACLE_SID=$PRIMARY_SID  home=$DB_HOME"

  # ---- environment of the running database (true TNS_ADMIN); readable only as the DB owner
  PRIMARY_TNS_ADMIN=""
  if prim_probe environ "$DB_PMON_PID"; then
    PRIMARY_TNS_ADMIN=$(sed -n 's/^TNS_ADMIN=//p' <<< "$RUN_OUT" | head -n 1); PRIMARY_TNS_ADMIN=${PRIMARY_TNS_ADMIN%/}
    v_path "$PRIMARY_TNS_ADMIN" || PRIMARY_TNS_ADMIN=""
  fi

  # ---- edition: Data Guard needs Enterprise Edition (checked here, before anything is installed)
  prim_sql "select banner from v\$version where banner like 'Oracle%';" \
    || { bad "Cannot query the database on the primary: $(ora_errors "$SQL_OUT")"; printf 'The ssh user %s must be able to run  sqlplus / as sysdba  (it must be in the dba group).\n' "$PRIMARY_SSH_USER" | hint; return 1; }
  local ban; ban=$(first_line)
  if [[ "$ban" == *"Enterprise Edition"* ]]; then DB_EDITION=EE
  elif [[ "$ban" == *"Standard Edition"* ]]; then DB_EDITION=SE2
  else DB_EDITION=EE; DISC_NOTES+=("The edition in '$ban' is not known. Enterprise Edition is assumed."); fi
  [[ "$DB_EDITION" == "EE" ]] || fatal "The primary is Standard Edition: $ban
Data Guard needs Enterprise Edition, so this script cannot build a standby for it."

  # ---- Grid home (only if there is Grid/ASM)
  GRID_HOME=$(awk -F: '$1 ~ /^\+ASM[0-9]*$/ {print $2; exit}' <<< "$(sed 's/#.*//' <<< "$oratab")")
  if [[ -z "$GRID_HOME" ]] && prim_probe olr; then GRID_HOME=$(sed -n 's/^crs_home=//p' <<< "$RUN_OUT" | head -n 1); fi
  if [[ -z "$GRID_HOME" && -n "$ASM_PMON_PID" ]]; then GRID_HOME=$(home_of_pid "$ASM_PMON_PID" || true); fi
  GRID_HOME=${GRID_HOME%/}
  [[ -z "$GRID_HOME" ]] || home_ok "$GRID_HOME" || GRID_HOME=""

  # ---- inventory
  INVENTORY_DIR=""
  prim_probe orainst && INVENTORY_DIR=$(sed -n 's/^inventory_loc=//p' <<< "$RUN_OUT" | head -n 1)
  INVENTORY_DIR=${INVENTORY_DIR%/}
  v_path "$INVENTORY_DIR" || INVENTORY_DIR="$(dirname "$(dirname "$DB_HOME")")/oraInventory"

  # ---- owners, ids, groups
  ORACLE_USER=""; GRID_USER=""
  prim_probe owner "$DB_HOME/bin/oracle" && ORACLE_USER=$(awk '{print $1; exit}' <<< "$RUN_OUT")
  if [[ -n "$GRID_HOME" ]] && prim_probe owner "$GRID_HOME/bin/oracle"; then GRID_USER=$(awk '{print $1; exit}' <<< "$RUN_OUT"); fi
  v_name "$ORACLE_USER" || ORACLE_USER=oracle
  v_name "$GRID_USER" || GRID_USER=$ORACLE_USER
  prim_probe ids "$ORACLE_USER" "$GRID_USER" || { bad "Cannot read the user ids on the primary."; return 1; }
  parse_id_line "$(grep -m1 "^uid=[0-9]*($ORACLE_USER)" <<< "$RUN_OUT")"
  ORACLE_UID=$PID_UID; INSTALL_GROUP=$PID_PGROUP; local og=$PID_GROUPS
  parse_id_line "$(grep -m1 "^uid=[0-9]*($GRID_USER)" <<< "$RUN_OUT")"
  GRID_UID=$PID_UID; GRID_PGROUP=$PID_PGROUP; local gg=$PID_GROUPS
  num "$ORACLE_UID" && num "$GRID_UID" && [[ -n "$INSTALL_GROUP" ]] || { bad "Cannot understand the output of 'id' on the primary."; return 1; }
  # Only Oracle OS groups are copied (not wheel, docker, LDAP groups and so on)
  local ora_re="^(${INSTALL_GROUP}|${GRID_PGROUP}|oinstall|dba|oper|backupdba|dgdba|kmdba|racdba|asmadmin|asmdba|asmoper):"
  og=$(tr ',' '\n' <<< "$og" | grep -E "$ora_re" | paste -sd, -)
  gg=$(tr ',' '\n' <<< "$gg" | grep -E "$ora_re" | paste -sd, -)
  GROUP_GIDS=$(printf '%s\n%s\n' "$og" "$gg" | tr ',' '\n' | grep -v '^$' | sort -u -t: -k1,1 | paste -sd, -)
  ORACLE_GROUPS=$(tr ',' '\n' <<< "$og" | cut -d: -f1 | grep -vx "$INSTALL_GROUP" | paste -sd, -)
  GRID_GROUPS=$(tr ',' '\n' <<< "$gg" | cut -d: -f1 | grep -vx "$GRID_PGROUP" | paste -sd, -)
  if [[ "$ORACLE_USER" == "$GRID_USER" ]]; then ok "Owner: $ORACLE_USER ($ORACLE_UID) owns the database${GRID_HOME:+ and the Grid} software"
  else ok "Users: $ORACLE_USER ($ORACLE_UID), $GRID_USER ($GRID_UID)"; fi

  # ---- Oracle bases, network admin folder
  ORACLE_BASE=""; GRID_BASE=""
  prim_probe orabase "$DB_HOME" && ORACLE_BASE=$(grep -m1 -E '^/' <<< "$RUN_OUT")
  ORACLE_BASE=${ORACLE_BASE%/}
  v_path "$ORACLE_BASE" || { bad "Cannot read the ORACLE_BASE of $DB_HOME (orabase failed)."; return 1; }
  if [[ -n "$GRID_HOME" ]]; then
    prim_probe orabase "$GRID_HOME" && GRID_BASE=$(grep -m1 -E '^/' <<< "$RUN_OUT")
    GRID_BASE=${GRID_BASE%/}
    v_path "$GRID_BASE" || GRID_BASE=""
  fi
  if [[ -z "$PRIMARY_TNS_ADMIN" ]]; then
    local obh=""
    prim_probe orabasehome "$DB_HOME" && obh=$(grep -m1 -E '^/' <<< "$RUN_OUT")   # 18c and newer only
    obh=${obh%/}
    if v_path "$obh"; then PRIMARY_TNS_ADMIN="$obh/network/admin"; else PRIMARY_TNS_ADMIN="$DB_HOME/network/admin"; fi
  fi

  # ---- database facts (version-neutral SQL, works on 12.1 and newer)
  prim_sql "select d.name||'|'||d.db_unique_name||'|'||d.database_role||'|'||d.cdb||'|'||i.version||'|'||nvl((select value from v\$parameter where name='db_domain'),'-')||'|'||nvl((select upper(value) from v\$parameter where name='cluster_database'),'FALSE')||'|'||d.open_mode from v\$database d, v\$instance i;" \
    || { bad "Cannot query the database on the primary: $(ora_errors "$SQL_OUT")"; printf 'The ssh user %s must be able to run  sqlplus / as sysdba  (it must be in the dba group).\n' "$PRIMARY_SSH_USER" | hint; return 1; }
  local role ver dom rac omode
  IFS='|' read -r DB_NAME PRIMARY_UNIQUE role PRIMARY_CDB ver dom rac omode <<< "$(first_line)"
  [[ "$role" == "PRIMARY" ]] || fatal "Database $PRIMARY_SID on $PRIMARY_HOST has the role $role, not PRIMARY.
Run the script against the primary database."
  [[ "$rac" != "TRUE" ]] || fatal "The primary is a RAC database (cluster_database=TRUE).
This script supports only a single-instance primary."
  v_name "$DB_NAME" && v_name "$PRIMARY_UNIQUE" || { bad "The primary returned an unexpected database name: $DB_NAME, $PRIMARY_UNIQUE"; return 1; }
  [[ "$dom" == "-" ]] && dom=""; [[ -z "$dom" ]] || v_name "$dom" || dom=""; PRIMARY_DOMAIN=$dom
  DB_MAJOR=${ver%%.*}; num "$DB_MAJOR" || { bad "The primary returned an unexpected version: $ver"; return 1; }
  [[ $DB_MAJOR -ge 12 ]] || fatal "The primary runs Oracle $ver. This script supports 12.1 and newer."
  PRIMARY_VERSION=$ver
  if [[ $DB_MAJOR -ge 18 ]] && prim_sql "select version_full from v\$instance;"; then PRIMARY_VERSION=$(first_line); fi
  v_name "$PRIMARY_VERSION" || PRIMARY_VERSION=$ver
  [[ "$omode" == READ\ WRITE* ]] || warn "The primary is open as $omode, not READ WRITE."

  # ---- storage: every place with database files (also the standby redo logs) and how much is there
  local c="case when name like '+%' then upper(regexp_substr(name,'^[+][^/]+')) else substr(name,1,instr(name,'/',-1)-1) end"
  local cm="case when f.member like '+%' then upper(regexp_substr(f.member,'^[+][^/]+')) else substr(f.member,1,instr(f.member,'/',-1)-1) end"
  prim_sql "select loc||':'||round(sum(b)/1048576) from (select $c loc, bytes b from v\$datafile union all select $c, bytes from v\$tempfile union all select $cm, l.bytes from v\$logfile f, v\$log l where f.group#=l.group# union all select $cm, s.bytes from v\$logfile f, v\$standby_log s where f.group#=s.group# union all select $c, block_size*file_size_blks from v\$controlfile) group by loc;" \
    || { bad "Cannot read the locations of the database files: $(ora_errors "$SQL_OUT")"; return 1; }
  LOCS=$(grep -E '^[+/][A-Za-z0-9_./-]*:[0-9]+$' <<< "$SQL_OUT" | paste -sd, -)
  [[ -n "$LOCS" ]] || { bad "Unexpected answer for the file locations: $(head -n 3 <<< "$SQL_OUT")"; return 1; }
  PRIMARY_DB_MB=$(loc_list | awk -F: '{s+=$2} END {print s+0}')
  # block size of the online logs (512 or 4096): the standby logs and their disks must support it
  PRIMARY_REDO_BS=512
  prim_sql "select max(blocksize) from v\$log;" && PRIMARY_REDO_BS=$(first_line | cut -d'|' -f1)
  num "$PRIMARY_REDO_BS" || PRIMARY_REDO_BS=512

  # ---- recovery area, archive destination, folders used by the instance
  read_arch_params || { bad "Cannot read the parameters of the primary database."; return 1; }

  # ---- ASM or file system
  DATA_DG=""
  if [[ -n "$(asm_dgs)" ]]; then
    USE_GRID=yes
    [[ -n "$GRID_HOME" ]] || { bad "The primary uses ASM ($(asm_dgs | paste -sd' ' -)), but its Grid home was not found."; return 1; }
    [[ -n "$GRID_BASE" ]] || { bad "Cannot read the ORACLE_BASE of $GRID_HOME (orabase failed)."; return 1; }
    if [[ "$CFD" == +* ]]; then DATA_DG=$(norm_loc "$CFD"); DATA_DG=${DATA_DG#+}
    else DATA_DG=$(loc_list | grep '^+' | sort -t: -k2,2nr | head -n 1 | cut -d: -f1); DATA_DG=${DATA_DG#+}; fi
    # only the recovery area / archive destination in ASM: Grid is installed with that disk group
    [[ -n "$DATA_DG" ]] || DATA_DG=$(asm_dgs | head -n 1)
    # the Grid release may be newer than the database release (for example Grid 19c with a 12.2 database)
    GRID_REL=""
    if prim_probe gridver "$GRID_HOME"; then
      local gv; gv=$(grep -oE 'VER="[0-9.]+"' <<< "$RUN_OUT" | head -n 1 | grep -oE '[0-9.]+')
      if [[ "$gv" =~ ^([0-9]+)\.([0-9]+) ]]; then
        if [[ ${BASH_REMATCH[1]} == 12 ]]; then GRID_REL="12.${BASH_REMATCH[2]}"; else GRID_REL=${BASH_REMATCH[1]}; fi
      fi
    fi
    if [[ -z "$GRID_REL" ]]; then
      GRID_REL=$(want_rel db)
      DISC_NOTES+=("The Grid release of the primary could not be read from $GRID_HOME/inventory/ContentsXML/comps.xml.
Grid $GRID_REL is assumed, the same as the database.")
    fi
  else
    USE_GRID=no; GRID_REL=""
    # no ASM on the standby: no Grid; the listener runs from the database home
    GRID_HOME=""; GRID_BASE=""; GRID_USER=$ORACLE_USER; GRID_UID=$ORACLE_UID; GRID_PGROUP=$INSTALL_GROUP; GRID_GROUPS=""
  fi
  ok "Database: $DB_NAME, unique name $PRIMARY_UNIQUE, $PRIMARY_VERSION, CDB $PRIMARY_CDB, $(human_mb "$PRIMARY_DB_MB")"
  local sl="" l; for l in $(tr ',' ' ' <<< "$LOCS"); do sl+="${sl:+, }${l%:*} ($(human_mb "${l##*:}"))"; done
  ok "Storage: database files in $sl${FRA_LOC:+
Recovery area: $FRA_LOC}"

  # ---- listener: the running tnslsnr that offers this database's service.
  #      Only a tnslsnr that runs as an Oracle owner from a program of that owner is asked.
  local want="${PRIMARY_UNIQUE}${PRIMARY_DOMAIN:+.$PRIMARY_DOMAIN}" lu lh ln lp found=0 p svc lta
  local sv_port=$PORT sv_ln=$LISTENER_NAME sv_svc=$PRIMARY_SERVICE sv_lh=$PRIMARY_LISTENER_HOME
  LISTENER_NAME=LISTENER; PORT=1521; PRIMARY_LISTENER_HOME=${GRID_HOME:-$DB_HOME}; PRIMARY_SERVICE=$want; LSNR_ASSUMED=0
  while read -r lp lu lh ln; do
    v_path "$lh" && v_name "$ln" && v_name "$lu" && num "$lp" || continue
    [[ "$lu" == "$ORACLE_USER" || "$lu" == "$GRID_USER" ]] || continue
    trusted_prog "$lh/bin/lsnrctl" "$lu" || continue
    # the listener may read its listener.ora from a TNS_ADMIN of its own (readable only as its owner)
    lta=""; if prim_probe environ "$lp"; then lta=$(sed -n 's/^TNS_ADMIN=//p' <<< "$RUN_OUT" | head -n 1); lta=${lta%/}; v_path "$lta" || lta=""; fi
    # its own TNS_ADMIN; else its home's network/admin (no TNS_ADMIN); a listener of the database home may
    # also use the TNS_ADMIN of the database
    local tries=() t; [[ -n "$lta" ]] && tries=("$lta") || tries=("-")
    [[ -z "$lta" && "$lh" == "$DB_HOME" && -n "${PRIMARY_TNS_ADMIN:-}" ]] && tries+=("$PRIMARY_TNS_ADMIN")
    svc=""
    for t in "${tries[@]}"; do
      if [[ "$t" == "-" ]]; then prim_probe lsnr "$lh" "$ln" || continue; else prim_probe lsnr "$lh" "$ln" "$t" || continue; fi
      svc=$(grep -oE 'Service "[^"]+"' <<< "$RUN_OUT" | cut -d'"' -f2 | grep -ix -- "$want" | head -n 1)
      [[ -n "$svc" ]] && { PRIMARY_LISTENER_TNS_ADMIN=${t#-}; break; }
    done
    [[ -n "$svc" ]] || continue
    p=$(norm "$RUN_OUT" | grep -oE '\(PROTOCOL=TCP\)\(HOST=[^)]*\)\(PORT=[0-9]+\)' | head -n 1 | grep -oE '[0-9]+\)$' | tr -d ')')
    LISTENER_NAME=$ln; PRIMARY_LISTENER_HOME=$lh; PRIMARY_SERVICE=$svc; num "$p" && PORT=$p; found=1; break
  done < <(awk '{ for (i = 3; i <= NF; i++) if ($i ~ /\/bin\/tnslsnr$/) { h=$i; sub(/\/bin\/tnslsnr$/, "", h); print $1, $2, h, $(i+1); break } }' <<< "$PS_OUT")
  if [[ $found -eq 1 ]]; then ok "Listener $LISTENER_NAME on port $PORT, service $PRIMARY_SERVICE
Listener home: $PRIMARY_LISTENER_HOME"
  else
    LSNR_ASSUMED=1
    # values the admin corrected in the settings of an earlier run are kept
    if [[ -n "$sv_port" && -n "$sv_ln" && -n "$sv_svc" && ( "$sv_port" != "1521" || "$sv_ln" != "LISTENER" || "$sv_svc" != "$want" ) ]]; then
      PORT=$sv_port; LISTENER_NAME=$sv_ln; PRIMARY_SERVICE=$sv_svc; [[ -n "$sv_lh" ]] && PRIMARY_LISTENER_HOME=$sv_lh
      warn "No running listener on the primary offers the service $want.
Using your settings: $LISTENER_NAME, port $PORT, service $PRIMARY_SERVICE."
    else
      warn "No running listener on the primary offers the service $want.
Assuming LISTENER, port $PORT, service $want."
      say "If that is wrong, correct it in step 1.4 (choose e), or later with  $SELF --settings"
    fi
  fi

  # ---- TDE (12.1+ view; an empty answer means no wallet). 18c+: wallet_root / tde_configuration
  TDE_INFO=""; WALLET_ROOT=""; TDE_CONFIG=""
  # wallet_type (12.1.0.2+): LOCAL_AUTOLOGIN wallets open only on the host that made them
  if prim_sql "select wrl_type||'|'||nvl(wrl_parameter,'-')||'|'||status||'|'||nvl(wallet_type,'-') from v\$encryption_wallet;"; then TDE_INFO=$SQL_OUT
  else prim_sql "select wrl_type||'|'||nvl(wrl_parameter,'-')||'|'||status from v\$encryption_wallet;" && TDE_INFO=$SQL_OUT; fi
  if [[ $DB_MAJOR -ge 18 ]] && prim_sql "select name||'|'||nvl(value,'-') from v\$parameter where name in ('wallet_root','tde_configuration');"; then
    local wn wv
    while IFS='|' read -r wn wv; do
      case "$wn" in wallet_root) [[ "$wv" != "-" ]] && WALLET_ROOT=${wv%/}; [[ -z "$WALLET_ROOT" ]] || v_path "$WALLET_ROOT" || { DISC_NOTES+=("wallet_root on the primary is '$WALLET_ROOT', which is not a folder.
Copy the TDE wallet by hand in step 6.3.");WALLET_ROOT=""; } ;; tde_configuration) [[ "$wv" != "-" ]] && TDE_CONFIG=$wv ;; esac

    done <<< "$SQL_OUT"
  fi

  local n; for n in "${DISC_NOTES[@]+"${DISC_NOTES[@]}"}"; do warn "$n"; done
  set_primary_how
  DISCOVERED=1
  DONE_MSG="Primary configuration read"
}

inventory_homes() {
  # the Oracle homes registered on the primary (read-only: cat of inventory.xml), newest first
  local inv=${INVENTORY_DIR:-}
  [[ -n "$inv" ]] || { prim_probe orainst && inv=$(sed -n 's/^inventory_loc=//p' <<< "$RUN_OUT" | head -n 1); }
  v_path "$inv" || return 0
  prim_probe invxml "$inv" || return 0
  grep -oE 'LOC="[^"]+"' <<< "$RUN_OUT" | cut -d'"' -f2 | tac
  return 0
}
LSNR_ASSUMED=0; PRIMARY_LISTENER_TNS_ADMIN=""
assumed_key() { [[ $LSNR_ASSUMED -eq 1 && ( "$1" == PORT || "$1" == LISTENER_NAME || "$1" == PRIMARY_SERVICE ) ]]; }

#------------------------------------------------------------------------------
# Local SQL (standby) and TNS checks
#------------------------------------------------------------------------------
_sql_exec() {
  # $1 connect line, $2 sql text, $3 log title, $4 runner (as_oracle|as_grid), $5 home, $6 timeout (s)
  local connect=$1 sql=$2 title=$3 runner=$4 home=$5 tmo=${6:-$SQL_TIMEOUT} out rc=0 tmp
  # output through a file: background processes of a started instance must not keep a pipe open
  tmp=$(mktemp /tmp/dg_sql.XXXXXXXX) || { SQL_OUT="SP2-0000: cannot create a temporary file"; return 1; }
  CLEANUP_FILES+=("$tmp")
  printf 'set define off\n%s\n%s\nprompt %s\n%s\nexit\n' "$connect" "$SQL_HEADER" "$SQL_MARK" "$sql" \
    | "$runner" timeout "$tmo" "$home/bin/sqlplus" -S /nolog > "$tmp" 2>&1 || rc=$?
  out=$(cat "$tmp"); rm -f -- "$tmp"
  [[ $rc -eq 124 ]] && out+=$'\n'"SP2-0000: sqlplus did not answer within $tmo seconds (stopped)"
  { printf 'SQL> %s\n' "$sql" | sed '2,$s/^/     /'; printf '%s\n(exit code %s)\n' "$out" "$rc"; } | log_block "$title"
  sql_result "$out" "$rc"
}

sql_local() { _sql_exec "connect / as sysdba" "$1" "STANDBY sqlplus: ${1:0:150}" as_oracle "$DB_HOME" "${2:-}"; }
sql_local_long() { _sql_exec "connect / as sysdba" "$1" "STANDBY sqlplus: ${1:0:150}" as_oracle "$DB_HOME" 1800; }   # startup / shutdown
sql_asm()   { _sql_exec "connect / as sysasm" "$1" "ASM sqlplus: ${1:0:150}" as_grid "$GRID_HOME"; }

sql_standby_tns() {
  # standby through its listener / TNS alias (sys password)
  _sql_exec "connect sys/\"$SYS_PW\"@$STANDBY_TNS as sysdba" "$1" "STANDBY via $STANDBY_TNS: ${1:0:150}" as_oracle "$DB_HOME"
}

sql_primary_tns() {
  # PRIMARY through the TNS alias that RMAN will use. READ-ONLY.
  readonly_guard "$1" || fatal "Safety stop: this statement is not read-only, so it was NOT sent to the primary: $1"
  _sql_exec "connect sys/\"$SYS_PW\"@$PRIMARY_TNS as sysdba" "$1" "PRIMARY via $PRIMARY_TNS (read-only): ${1:0:150}" as_oracle "$DB_HOME"
}

local_state() {
  # LSTATE = IDLE | STARTED | MOUNTED | OPEN | ERROR | NOSW
  if ! db_sw_ok; then LSTATE=NOSW; return; fi
  if sql_local "select status from v\$instance;"; then
    LSTATE=$(first_line)
  elif grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    LSTATE="IDLE"
  else
    LSTATE="ERROR"
  fi
}

dg_proc_count() {
  # $1 = MRP or RFS. v$managed_standby (12.1-21c); v$dataguard_process where it no longer exists.
  local k=$1 q
  if [[ "$k" == "MRP" ]]; then q="select count(*) from v\$managed_standby where process like 'MRP%';"
  else q="select count(*) from v\$managed_standby where process like 'RFS%';"; fi
  if ! sql_local "$q"; then
    grep -q 'ORA-00942' <<< "$SQL_OUT" || return 1
    if [[ "$k" == "MRP" ]]; then q="select count(*) from v\$dataguard_process where upper(name) like 'MRP%';"
    else q="select count(*) from v\$dataguard_process where upper(role) like 'RFS%';"; fi
    sql_local "$q" || return 1
  fi
  num "$(first_line)" || return 1
  DGP_COUNT=$(first_line)
}
mrp_running() { dg_proc_count MRP && [[ $DGP_COUNT -ge 1 ]]; }
rfs_running() { dg_proc_count RFS && [[ $DGP_COUNT -ge 1 ]]; }

#------------------------------------------------------------------------------
# PHASE 1  Connect to primary and read its configuration
#------------------------------------------------------------------------------
c_1_1() {
  [[ $EUID -eq 0 ]] || { NOW="The script is not running as root"; PLAN="Run the script as root"; return 1; }
  local t missing=()
  for t in runuser getent awk sed grep stat timeout install useradd groupadd usermod lsblk blkid cmp ssh scp paste md5sum df du comm mktemp setsid tail ip flock pgrep pkill unzip; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    NOW="These tools are missing: ${missing[*]}"
    PLAN="${PKG:-yum} install -y util-linux coreutils shadow-utils openssh-clients gawk sed grep iproute diffutils procps-ng unzip"
    return 1
  fi
  local os="unknown"; os=$(. "$OS_RELEASE_FILE" 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")
  NOW="Running as root on $(hostname -s). All needed tools are present."$'\n'"$os, bash ${BASH_VERSION%%(*}, packages with $PKG"
  if ! [[ "$OS_MAJOR" =~ ^[0-9]+$ && $OS_MAJOR -ge 7 ]]; then
    NOW+=$'\n'"This is not Oracle Linux or RHEL 7 or newer. Packages and kernel settings may need work by hand."
    warn "$os is not Oracle Linux 7, 8 or 9. The script goes on."
  fi
  return 0
}

c_1_6() {
  # Oracle version and Oracle Linux version must be a supported pair (checked when the version is known)
  [[ $DISCOVERED -eq 1 ]] || { NOW="Primary configuration not read (step 1.3)"; return 2; }
  [[ "$OS_MAJOR" =~ ^[0-9]+$ ]] || { NOW="Operating system version unknown; not checked"; return 0; }
  local v=$PRIMARY_VERSION why="" r w
  # the database release, and the Grid release when there is Grid (Grid may be newer)
  local -a rels=("$(want_rel)")
  [[ -n "$GRID_REL" && "$GRID_REL" != "${rels[0]}" ]] && rels+=("$GRID_REL")    # the same release is checked once
  for r in "${rels[@]}"; do
    w=""
    case "$r" in
      12.1) [[ $OS_MAJOR -ge 8 ]] && w="12.1 is certified on Oracle Linux 7 only."
            [[ "$v" == 12.1.0.1* && $OS_MAJOR -eq 7 ]] && w="12.1.0.1 is not certified on Oracle Linux 7. Only 12.1.0.2 is." ;;
      12.2|18) [[ $OS_MAJOR -ge 8 ]] && w="$r is not certified on Oracle Linux $OS_MAJOR. Its installer stops there."$'\n'"Use Oracle Linux 7 for this standby." ;;
      19)   [[ $OS_MAJOR -ge 9 && -z "$RU_DIR" ]] && w="19c on Oracle Linux 9 must be installed together with Release Update 19.19 or newer."$'\n'"1. Unzip that Release Update on this server. Also get the newest OPatch zip (p6880880)."$'\n'"2. Answer s here. In step 1.4 choose e, then set RU_DIR and OPATCH_ZIP." ;;
      21)   ;;
      *)    [[ $OS_MAJOR -le 7 ]] && w="$r needs Oracle Linux 8 or newer." ;;
    esac
    [[ -n "$w" ]] && why+="$w"$'\n'
  done
  if use_grid && [[ -n "$GRID_REL" ]]; then
    local gm dm; gm=$(rel_major "$GRID_REL"); dm=$DB_MAJOR
    if [[ $gm -lt $dm || ( $gm -eq 12 && $dm -eq 12 && "${GRID_REL#12.}" < "${PRIMARY_VERSION:3:1}" ) ]]; then why+="Grid $GRID_REL is older than the database ($v). Grid must be the same release or newer."$'\n'; fi
  fi
  why=${why%$'\n'}
  if [[ -n "$why" ]]; then NOW="Oracle $v${GRID_REL:+ (Grid $GRID_REL)} on Oracle Linux $OS_MAJOR: not supported as it is. ${why%%$'\n'*}"; PLAN="$why"; return 1; fi
  NOW="Oracle $v${GRID_REL:+ (Grid $GRID_REL)} on Oracle Linux $OS_MAJOR: supported"
  [[ "$DB_MAJOR" == "19" && $OS_MAJOR -ge 8 && -z "$RU_DIR" ]] && NOW+=$'\n'"The 19c installer runs with CV_ASSUME_DISTID=OEL7.8 (19.3 needs it on Oracle Linux 8+)."
  return 0
}

c_1_2() {
  if [[ -n "$PRIMARY_IP" ]] && command -v ip >/dev/null 2>&1 && grep -qFw -- "$PRIMARY_IP" <<< "$(ip -o addr show 2>/dev/null)"; then
    fatal "$PRIMARY_IP is an address of this server, but you gave it as the primary.
Run the script on the standby server."
  fi
  if ssh_alive; then NOW="Connected to $PRIMARY_SSH_USER@$PRIMARY_IP"; return 0; fi
  if [[ "$MODE" == "check" ]]; then open_ssh && { NOW="Connected to $PRIMARY_SSH_USER@$PRIMARY_IP"; return 0; }; NOW="The ssh connection failed. The reason is shown above."; return 2; fi
  NOW="Not connected to the primary yet"
  PLAN="Open one ssh connection to $PRIMARY_SSH_USER@$PRIMARY_IP (read-only commands only)."
  return 1
}
d_1_2() { open_ssh; }

c_1_3() {
  if [[ $DISCOVERED -eq 1 ]]; then NOW="Primary configuration read: $PRIMARY_UNIQUE on $PRIMARY_HOST"; return 0; fi
  need_ssh || { NOW="No ssh connection to the primary (step 1.2)"; return 2; }
  if [[ "$MODE" == "check" ]]; then discover_primary && { NOW="Primary configuration read"; return 0; }; NOW="Reading the primary failed. The reason is shown above."; return 2; fi
  NOW="The primary configuration is not read yet"
  PLAN="Read the primary configuration. Nothing is changed there:
  running instances and listeners, and the home of the database
  /etc/oratab, /etc/oraInst.loc, the Oracle users and groups, the Oracle bases
  name, role, version, storage and size of the database (SELECT only)
  listener port and service (lsnrctl status)"
  return 1
}
d_1_3() { discover_primary; }

SETTINGS_DIFF=""
c_1_4() {
  [[ $DISCOVERED -eq 1 ]] || { NOW="The primary configuration is not read yet (step 1.3)"; return 2; }
  derive_standby_settings
  if [[ $SETTINGS_ACCEPTED -eq 1 ]]; then NOW="Settings accepted ($SETTINGS_FILE)"; return 0; fi
  local d rc=0
  d=$(accepted_diff) || rc=1
  # 1.6 found a value that must be set in the settings (for example RU_DIR): show them, do not accept silently
  if [[ $rc -eq 0 && -z "$d" && $REVIEW_SETTINGS -eq 0 && $SETTINGS_UPGRADED -eq 0 && "${STEP_RESULT[1.6]:-OK}" == OK ]] && validate_settings >/dev/null 2>&1; then
    SETTINGS_ACCEPTED=1
    NOW="Same settings as you accepted before ($SETTINGS_FILE)"$'\n'"To see or change them:  $SELF --settings"
    return 0
  fi
  SETTINGS_DIFF=$d
  show_settings
  [[ $rc -eq 0 && -n "$d" ]] && { printf 'Changed since you last accepted the settings:\n%s\n' "$d" | hint; _log INFO "settings changed: $(tr '\n' ';' <<< "$d")"; }
  if [[ $SETTINGS_UPGRADED -eq 1 ]]; then
    warn "The settings file came from an older version of the script and was converted.
Check the values above.${DROPPED_KEYS:+
No longer used:$DROPPED_KEYS. Disks are now chosen in step 2.13.}"
  elif [[ -n "$DROPPED_KEYS" ]]; then
    warn "Unknown keys in $SETTINGS_FILE were ignored:$DROPPED_KEYS"
  fi
  if [[ "$MODE" == "check" ]]; then validate_settings && { NOW="Settings worked out; check mode does not save them"; return 0; }; NOW="The settings have problems. They are shown above."; return 2; fi
  NOW="The settings above are not accepted yet"
  PLAN="Save these settings and use them in all later steps
File: $SETTINGS_FILE"
  return 1
}
pick_editor() {
  local e
  for e in "${EDITOR:-}" vi vim nano; do [[ -n "$e" ]] && command -v "${e%% *}" >/dev/null 2>&1 && { printf '%s' "$e"; return 0; }; done
  return 1
}
d_1_4() {
  local ed
  while true; do
    ask_choice "[a] Accept   [e] Edit   [h] Help   [q] Quit" "aeq"
    case "$ANSWER" in
      a)
        validate_settings || { bad "Fix the settings first: choose e."; continue; }
        [[ ${ED_KEEP_FILE:-0} -eq 1 ]] && warn "Your last edit was not valid, so it is not used. The values from before that edit are saved."
        save_settings; save_accepted; SETTINGS_ACCEPTED=1; SETTINGS_UPGRADED=0
        _log INFO "settings accepted"
        DONE_MSG="Settings saved to $SETTINGS_FILE"; return 0 ;;
      e)
        ed=$(pick_editor) || { bad "No editor found (vi, vim, nano). Edit $SETTINGS_FILE by hand, then run the script again."; continue; }
        [[ ${ED_KEEP_FILE:-0} -eq 1 ]] || save_settings
        ED_KEEP_FILE=0
        say "The settings file opens in $ed. Change only the lines under 'Standby values'."
        say "Each line is NAME=VALUE, for example STANDBY_UNIQUE is the db_unique_name."
        [[ $LSNR_ASSUMED -eq 1 ]] && say "PORT, LISTENER_NAME and PRIMARY_SERVICE were assumed. You may correct them too."
        [[ "$ed" == vi* ]] && say "In vi: i to type, Esc then :wq to save and close, Esc then :q! to close without saving."
        # what the primary told us: an edit of these values is not accepted
        local k snap="" old_unique=$STANDBY_UNIQUE old_sid=$STANDBY_SID old_svc=$STANDBY_SERVICE old_tns=$STANDBY_TNS
        for k in $(all_setting_keys); do is_standby_key "$k" || assumed_key "$k" || snap+="$k=${!k}"$'\n'; done
        $ed "$SETTINGS_FILE" < "$PROMPT_IN" || true
        # check the edited file first (a typo must not stop the script)
        local -A keep=(); local line
        while IFS= read -r line; do [[ -n "$line" ]] && keep[${line%%=*}]=${line#*=}; done <<< "$snap"
        local save_vals=""; for k in $STANDBY_KEYS PORT LISTENER_NAME PRIMARY_SERVICE; do save_vals+="$k=${!k}"$'\n'; done
        if ! load_settings soft; then
          bad "The edited file has an error: $LOAD_ERR"; say "Your edits are still in $SETTINGS_FILE."
          while IFS= read -r line; do [[ -n "$line" ]] && printf -v "${line%%=*}" '%s' "${line#*=}"; done <<< "$save_vals"
          for k in "${!keep[@]}"; do printf -v "$k" '%s' "${keep[$k]}"; done
          say "Choose e to open it again and fix the error."
          ED_KEEP_FILE=1
          continue
        fi
        local changed="" refused=""
        for k in "${!keep[@]}"; do
          if [[ "${!k}" != "${keep[$k]}" ]]; then refused+=" $k"; printf -v "$k" '%s' "${keep[$k]}"; fi
        done
        [[ -n "$refused" ]] && warn "These values come from the primary and cannot be changed here:$refused
The values read from the primary are kept."
        if [[ "$STANDBY_UNIQUE" != "$old_unique" ]]; then
          # values that were derived from the old name are derived again from the new one
          [[ "$STANDBY_SID" == "$old_sid" && ( "$old_sid" == "$old_unique" || "$old_sid" == "${old_unique:0:12}" ) ]] && STANDBY_SID=""
          [[ "$STANDBY_SERVICE" == "$old_svc" ]] && STANDBY_SERVICE=""
          [[ "$STANDBY_TNS" == "$old_tns" ]] && STANDBY_TNS=""
        fi
        derive_standby_settings
        while IFS= read -r line; do
          k=${line%%=*}; [[ -n "$k" && "${!k}" != "${line#*=}" ]] && changed+=" $k=${!k}"
        done <<< "$save_vals"
        _log INFO "settings edited:${changed:- nothing changed}"
        [[ -n "$changed" ]] && say "Changed:$changed"
        save_settings
        show_settings ;;
      q) user_stop "Stopped by you" ;;
    esac
  done
}

sys_needed() {
  # the sys password is used only by the steps 7.4 - 8.2 (login tests and the duplicate)
  [[ "$MODE" == "check" ]] && return 0
  if [[ -n "$ONLY_PHASE" ]]; then [[ "$ONLY_PHASE" == "7" || "$ONLY_PHASE" == "8" ]]; return; fi
  [[ -z "$FROM_STEP" ]] && return 0
  [[ $(step_num "$FROM_STEP") -le $(step_num 8.2) ]]
}
c_1_5() {
  if [[ $SYS_VERIFIED -eq 1 ]]; then NOW="The sys password works on the primary"; return 0; fi
  [[ $DISCOVERED -eq 1 ]] || { NOW="The primary configuration is not read yet (step 1.3)"; return 2; }
  sys_needed || { NOW="Not needed in this run. Only the login tests (steps 7.4 to 7.6) and the RMAN copy use it."; return 0; }
  if [[ "$MODE" == "check" ]]; then d_1_5 && { NOW="The sys password works on the primary"; return 0; }; NOW="The sys password is not verified. The reason is shown above."; return 2; fi
  NOW="The sys password is not given yet"
  PLAN="Ask for the sys password. It is hidden while you type and kept only in memory.
Test it on the primary, through its listener:
  sqlplus sys@//$PRIMARY_HOST:$PORT/$PRIMARY_SERVICE  (select 1 from dual)"
  return 1
}
d_1_5() {
  if [[ -n "$ENV_SYS_PW" ]]; then SECRET=$ENV_SYS_PW; ENV_SYS_PW=""; say "Using DG_SYS_PASSWORD from environment"
  else ask_secret "sys password of the primary (hidden while you type)"; fi
  if [[ -z "$SECRET" ]] || ! sys_pw_ok "$SECRET"; then
    SECRET=""
    bad "This password cannot be used. It is empty, or it has a space, a quote,
one of @ / & ; # \\ \$ \` or a non-ASCII character."
    printf 'The script cannot pass such a password to sqlplus and RMAN.\nChange it on the primary first, as %s in sqlplus / as sysdba:\n  alter user sys identified by "<new password>";\nFrom 12.2 on, this also updates the password file. Then answer r.\n' "$ORACLE_USER" | hint
    return 1
  fi
  SYS_PW=$SECRET; SECRET=""
  local tgt
  for tgt in "//localhost:$PORT/$PRIMARY_SERVICE" "//$PRIMARY_HOST:$PORT/$PRIMARY_SERVICE" "//$PRIMARY_IP:$PORT/$PRIMARY_SERVICE"; do
    if prim_sql_as_sys "$tgt" "select 1 from dual;"; then
      SYS_VERIFIED=1; DONE_MSG="The sys password works on the primary"
      mask_pending
      if [[ ${#SYS_PW} -lt 8 ]] || grep -qiF -- "$SYS_PW" <<< "$ORACLE_USER $GRID_USER $DB_HOME $ORACLE_BASE $PRIMARY_SID $STANDBY_SID"; then
        warn "The sys password is short, or it is part of a name or path.
The log replaces it with ***** everywhere, so some names in the log look odd."
      fi
      return 0
    fi
    # only a network problem is a reason to try the next address
    grep -qE 'ORA-12541|TNS-12541|ORA-12514|ORA-12170|ORA-12545' <<< "$SQL_OUT" || break
  done
  local errs; errs=$(ora_errors "$SQL_OUT")
  bad "The sys login on the primary failed: ${errs:-no error text}
The test ran on the primary itself, through its listener."
  {
    [[ "$errs" == *ORA-01017* ]] && printf 'ORA-01017: wrong sys password, or SYS is not in the password file of the primary.\nTo set it on the primary, in sqlplus / as sysdba:\n  alter user sys identified by "<password>";\n'
    [[ "$errs" == *ORA-12514* ]] && printf 'ORA-12514: the listener on the primary does not know the service %s.\nCheck it on the primary, as the listener owner:\n  ORACLE_HOME=%s %s/bin/lsnrctl status %s\nThe service must be listed. If it is not, check service_names of the database.\n' "$PRIMARY_SERVICE" "$PRIMARY_LISTENER_HOME" "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME"
    [[ "$errs" == *12541* ]] && printf 'ORA-12541: no listener on port %s on the primary. Start it there, as the listener owner:\n  ORACLE_HOME=%s %s/bin/lsnrctl start %s\n' "$PORT" "$PRIMARY_LISTENER_HOME" "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME"
    [[ "$errs" == *ORA-12170* || "$errs" == *ORA-12545* ]] && printf 'ORA-12170/12545: the host name or port cannot be reached from the primary itself.\n'
    [[ "$errs" == *ORA-28000* ]] && printf 'ORA-28000: the SYS account is locked.\n'
    true
  } | hint
  SYS_PW=""
  return 1
}

sys_pw_ok() {
  # characters that cannot travel safely to sqlplus / RMAN (connect strings, quotes, comments) are refused,
  # and so are non-ASCII characters (the two servers may use different character sets)
  local LC_ALL=C
  [[ "$1" =~ ^[[:print:]]+$ ]] || return 1
  [[ "$1" =~ [[:space:]\"\'@/\&\;#\\\$\`] ]] && return 1
  return 0
}

phase_1() {
  phase_header 1 "Connect to the primary"
  run_step 1.1 check "Root and tools on this server" c_1_1
  # 1.2, 1.3 and 1.5 only read (or ask a password): no [y] question for them
  run_step 1.2 ask   "Connect to the primary over ssh" c_1_2 d_1_2
  run_step 1.3 ask   "Read the primary configuration (read-only)" c_1_3 d_1_3
  # without the primary configuration no other step can do anything
  [[ $DISCOVERED -eq 1 ]] || fatal "Nothing else can run without steps 1.2 and 1.3 (ssh connection, primary configuration).
Fix the problem shown above, then run the script again."
  # [i] at 1.2 gave another address: another database there means another standby (its records are set aside)
  if [[ -n "$OLD_PRIMARY_UNIQUE" && -n "$PRIMARY_UNIQUE" && "${OLD_PRIMARY_UNIQUE^^}" != "${PRIMARY_UNIQUE^^}" ]]; then
    set_aside_state "${OLD_PRIMARY_UNIQUE}_$RUN_ID"; say "This is another primary database: $PRIMARY_UNIQUE (before: $OLD_PRIMARY_UNIQUE)."; say "The records of the old setup are set aside, not deleted."
  fi
  OLD_PRIMARY_UNIQUE=""
  run_step 1.6 check "Oracle version supported on this Oracle Linux" c_1_6
  run_step 1.4 ask   "Standby settings" c_1_4 d_1_4
  # a 1.6 problem that the new settings solved (RU_DIR set in 1.4): checked again, quietly
  if [[ -n "${STEP_RESULT[1.6]:-}" && "${STEP_RESULT[1.6]}" != OK && "$MODE" == "run" ]] && c_1_6 >/dev/null 2>&1; then
    ok_lines "Step 1.6 is fine now with the new settings"; record 1.6 OK
  fi
  run_step 1.5 ask   "sys password" c_1_5 d_1_5
  # nothing below works without these
  if [[ $DISCOVERED -ne 1 || $SETTINGS_ACCEPTED -ne 1 ]]; then
    [[ "$MODE" == "check" && $DISCOVERED -eq 1 ]] || fatal "Nothing else can run without steps 1.2, 1.3 and 1.4 (connection, primary configuration, settings).
Run the script again."
  fi
  build_envs_if_possible
  # (only useful while the long installs of phase 3 are still ahead)
  if [[ "$MODE" == "run" && -z "$ONLY_PHASE" && -z "$FROM_STEP" ]] && ! phase4_all_done && [[ "$(phase_done_result 3)" != "DONE" ]]; then
    say "Phase 4 (on the primary) needs nothing from this server."
    say "You can do it now, before the long software installs."
    CUR_STEP=""
    ask_choice "[4] Do phase 4 (primary) first   [c] Continue in order (phase 4 after the software)   [q] Quit" "4cq"

    case "$ANSWER" in 4) PHASE4_FIRST=1 ;; q) user_stop "Stopped by you" ;; esac
  fi
}
phase4_all_done() { local i; load_progress; for i in 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.9; do case "${LAST_RESULT[$i]:-}" in OK|DONE_BY_YOU) ;; *) return 1 ;; esac; done; return 0; }

build_envs_if_possible() { users_ok && build_envs; return 0; }

#------------------------------------------------------------------------------
# PHASE 2  Standby OS (users, groups, packages, folders, hosts, ASM disks)
#------------------------------------------------------------------------------
in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx -- "$2"; }

run_cmds() {
  # stdin: one command per line (built by this script from validated values only). Stops at first error.
  local c
  while IFS= read -r c || [[ -n "$c" ]]; do
    [[ -z "$c" ]] && continue
    if ! run_logged "$c" bash -c "$c"; then bad "Failed: $c"; printf '%s\n' "$RUN_OUT" | tail -n 5 | hint; return 1; fi
    [[ "$PLAN" == *"$c"* ]] || say "Ran: $c"      # a command the Plan already shows is not repeated
  done
  return 0
}

# ---- 2.1 groups ----
G_TODO=""
c_2_1() {
  local e name gid cur miss="" diff="" fix=""
  IFS=',' read -ra _ge <<< "$GROUP_GIDS"
  for e in "${_ge[@]}"; do
    name=${e%%:*}; gid=${e#*:}
    cur=$(getent group "$name" | cut -d: -f3)
    if [[ -z "$cur" ]]; then
      local other; other=$(getent group "$gid" | cut -d: -f1)
      if [[ -n "$other" ]]; then
        diff+="Group id $gid is needed for $name, but group $other uses it here"$'\n'
        fix+="groupmod -g <a free gid> $other"$'\n'"groupadd -g $gid $name"$'\n'
      else miss+="groupadd -g $gid $name"$'\n'; fi
    elif [[ "$cur" != "$gid" ]]; then
      diff+="Group $name has id $cur here and $gid on the primary"$'\n'
      fix+="groupmod -g $gid $name"$'\n'
    fi
  done
  if [[ -n "$diff" ]]; then
    NOW="${diff%$'\n'}"
    MANUAL_HOW="root  ->  shell Do this only while no Oracle software is installed here."
    PLAN="${fix%$'\n'}
-- The group ids must be the same on both servers, for ASM and the password file.
-- Files of the old id keep it. To list them: find / -xdev -gid <old gid>"
    return 2
  fi
  if [[ -z "$miss" ]]; then NOW="All ${#_ge[@]} groups exist with the same ids as on the primary"; return 0; fi
  G_TODO=${miss%$'\n'}
  NOW="Missing groups: $(grep -oE '[^ ]+$' <<< "$G_TODO" | paste -sd' ' -)"
  PLAN="$G_TODO"
  USING="Group names and ids from the primary"
  return 1
}
d_2_1() {
  # each command is journaled as soon as it worked (a later failure does not hide an earlier change)
  local c; while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    run_cmds <<< "$c" || return 1
    [[ "$c" =~ ^groupadd\ -g\ ([0-9]+)\ ([A-Za-z0-9_.-]+)$ ]] && journal GROUP "${BASH_REMATCH[2]}" "gid ${BASH_REMATCH[1]}"
  done <<< "$G_TODO"
  return 0
}

# ---- 2.2 users ----
U_TODO=""
c_2_2() {
  local spec name uid pg supp g miss_g todo="" err="" fix="" why="" ge
  # the users need their groups: without them useradd fails
  for ge in ${GROUP_GIDS//,/ }; do
    getent group "${ge%%:*}" >/dev/null 2>&1 || { NOW="The group ${ge%%:*} does not exist yet (step 2.1)"; return 2; }
  done
  local -a specs=("$ORACLE_USER|$ORACLE_UID|$INSTALL_GROUP|$ORACLE_GROUPS")
  single_owner || specs+=("$GRID_USER|$GRID_UID|$GRID_PGROUP|$GRID_GROUPS")
  for spec in "${specs[@]}"; do
    IFS='|' read -r name uid pg supp <<< "$spec"
    if ! id "$name" >/dev/null 2>&1; then
      local other; other=$(getent passwd "$uid" | cut -d: -f1)
      if [[ -n "$other" ]]; then
        err+="User id $uid is needed for $name, but user $other uses it here"$'\n'
        fix+="usermod -u <a free uid> $other"$'\n'; continue
      fi
      todo+="useradd -m -s /bin/bash -u $uid -g $pg${supp:+ -G $supp} $name"$'\n'; why+="$name does not exist yet"$'\n'; continue
    fi
    [[ "$(id -u "$name")" == "$uid" ]] || { err+="User $name has id $(id -u "$name") here and $uid on the primary"$'\n'; fix+="usermod -u $uid $name"$'\n'; continue; }
    [[ "$(id -gn "$name")" == "$pg" ]] || { todo+="usermod -g $pg $name"$'\n'; why+="$name has another primary group than on the primary ($pg)"$'\n'; }
    miss_g=""
    IFS=',' read -ra _gl <<< "$supp"
    for g in "${_gl[@]}"; do [[ -n "$g" ]] && ! in_group "$name" "$g" && miss_g+="$g,"; done
    [[ -n "$miss_g" ]] && { todo+="usermod -a -G ${miss_g%,} $name"$'\n'; why+="$name is missing groups it has on the primary: $(sed 's/,$//; s/,/, /g' <<< "$miss_g")"$'\n'; }
  done
  if [[ -n "$err" ]]; then
    NOW="${err%$'\n'}"
    MANUAL_HOW="root  ->  shell Do this only while no Oracle software is installed here."
    PLAN="${fix%$'\n'}
-- Files of the old id keep it. To list them: find / -xdev -uid <old uid>"
    return 2
  fi
  if [[ -z "$todo" ]]; then
    if single_owner; then NOW="$ORACLE_USER ($ORACLE_UID) exists with the same groups as on the primary"
    else NOW="$ORACLE_USER ($ORACLE_UID) and $GRID_USER ($GRID_UID) exist with the same groups as on the primary"; fi
    return 0
  fi
  U_TODO=${todo%$'\n'}
  NOW="${why%$'\n'}"
  PLAN="$U_TODO"
  USING="Id, primary group and other groups of each user, from the primary"
  return 1
}
d_2_2() {
  local c; while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    run_cmds <<< "$c" || return 1
    [[ "$c" =~ ^useradd\ .*\ ([A-Za-z0-9_.-]+)$ ]] && journal USER "${BASH_REMATCH[1]}" "$c"
    [[ "$c" =~ ^usermod\ .*\ ([A-Za-z0-9_.-]+)$ ]] && journal USERMOD "${BASH_REMATCH[1]}" "$c"
  done <<< "$U_TODO"
  return 0
}

# ---- 2.3 packages ----
P_TODO=""
preinstall_pkg() {
  # Oracle preinstall package for the primary version (sets kernel parameters, limits, oracle user defaults)
  case "$DB_MAJOR" in
    12) if [[ "$PRIMARY_VERSION" == 12.1* ]]; then printf 'oracle-rdbms-server-12cR1-preinstall'; else printf 'oracle-database-server-12cR2-preinstall'; fi ;;
    18) printf 'oracle-database-preinstall-18c' ;;
    19) printf 'oracle-database-preinstall-19c' ;;
    21) printf 'oracle-database-preinstall-21c' ;;
    *)  printf 'oracle-database-preinstall-%sai' "$DB_MAJOR" ;;
  esac
}
need_pkgs() {
  printf '%s\n' "$(preinstall_pkg)" unzip chrony parted bc
  use_grid && [[ "$(asm_method)" == "asmlib" ]] && printf '%s\n' oracleasm-support
  return 0
}
P_MISS=()
c_2_3() {
  command -v rpm >/dev/null 2>&1 || { NOW="rpm is not found. This server is not Oracle Linux or RHEL."; return 2; }
  local p; P_MISS=()
  while IFS= read -r p; do rpm -q "$p" >/dev/null 2>&1 || P_MISS+=("$p"); done < <(need_pkgs)
  if [[ ${#P_MISS[@]} -eq 0 ]]; then NOW="Required packages are installed"; return 0; fi
  NOW="Missing packages: ${P_MISS[*]}"
  PLAN="Install with $PKG, one package at a time:
  ${P_MISS[*]}"
  USING="Oracle Linux $OS_MAJOR, database $DB_MAJOR
$(preinstall_pkg) sets kernel parameters and limits for the user oracle.
It does not change existing users."
  return 1
}
d_2_3() {
  local p failed=()
  for p in "${P_MISS[@]}"; do
    if run_logged "$PKG install -y $p" "$PKG" install -y "$p" && rpm -q "$p" >/dev/null 2>&1; then say "Installed: $p"; journal PKG "$p"
    else failed+=("$p"); bad "Not installed: $p ($(grep -iE 'no package|unable to find|error' <<< "$RUN_OUT" | head -n 1))"; fi
  done
  [[ ${#failed[@]} -eq 0 ]] && return 0
  local repo
  case "$OS_MAJOR" in 7) repo="ol7_latest ol7_addons" ;; 8) repo="ol8_baseos_latest ol8_appstream ol8_addons" ;; *) repo="ol${OS_MAJOR}_baseos_latest ol${OS_MAJOR}_appstream ol${OS_MAJOR}_addons" ;; esac
  {
    printf 'Usually a repository is not enabled, or there is no internet or local repository.\n'
    printf 'Check:   %s repolist   (needed: %s)\n' "$PKG" "$repo"
    if [[ "$PKG" == "yum" ]]; then printf 'Enable:  yum-config-manager --enable <repo>\n'; else printf 'Enable:  dnf config-manager --set-enabled <repo>\n'; fi
    printf 'Some preinstall packages do not exist for every release, for example 12c on OL8 or OL9.\n'
    [[ " ${failed[*]} " == *" oracleasm-support "* ]] && printf 'Without oracleasm-support, the ASM disks can use udev rules instead.\nTo do that, skip this step. Step 2.12 then offers udev.\n'
    printf 'Then install them yourself and answer r:\n  %s install -y %s\n' "$PKG" "${failed[*]}"
  } | hint
  return 1
}

# ---- 2.4 limits ----
LIMITS_FILE=/etc/security/limits.d/oracle-grid.conf
limit_users() {
  # the preinstall package sets limits only for the user named "oracle"; every other Oracle owner needs its own
  [[ "$ORACLE_USER" != "oracle" ]] && printf '%s\n' "$ORACLE_USER"
  use_grid && ! single_owner && [[ "$GRID_USER" != "oracle" ]] && printf '%s\n' "$GRID_USER"
  return 0
}
LIM_TODO=()
c_2_4() {
  local u miss=()
  LIM_TODO=()
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    grep -qsE "^[[:space:]]*$u[[:space:]]+hard[[:space:]]+nofile" /etc/security/limits.d/*.conf /etc/security/limits.conf 2>/dev/null || miss+=("$u")
  done < <(limit_users)
  if [[ -z "$(limit_users)" ]]; then NOW="Not needed: the only Oracle owner is oracle, and $(preinstall_pkg) sets its limits"; return 0; fi
  if [[ ${#miss[@]} -eq 0 ]]; then NOW="Limits are set for: $(limit_users | paste -sd' ' -)"; return 0; fi
  LIM_TODO=("${miss[@]}")
  NOW="No limits are set for: ${miss[*]}
The preinstall package sets limits only for the user named oracle."
  PLAN="Add limits for ${miss[*]} to $LIMITS_FILE:
nofile 1024/65536, nproc 16384, stack 10240/32768, memlock unlimited"
  [[ "$ORACLE_USER" != "oracle" ]] && ! id oracle >/dev/null 2>&1 && \
    PLAN+=$'\n'"The preinstall package may create a user named oracle (uid 54321). This standby does not use it."
  return 1
}
d_2_4() {
  backup_file "$LIMITS_FILE" || return 1
  local u txt=""
  for u in "${LIM_TODO[@]}"; do
    txt+="$u  soft  nofile   1024"$'\n'"$u  hard  nofile   65536"$'\n'"$u  soft  nproc    16384"$'\n'"$u  hard  nproc    16384"$'\n'
    txt+="$u  soft  stack    10240"$'\n'"$u  hard  stack    32768"$'\n'"$u  soft  memlock  unlimited"$'\n'"$u  hard  memlock  unlimited"$'\n'
  done
  # other lines in the file (limits of other users on a shared server) stay
  printf '# added by dg_standby_setup.sh %s\n%s' "$RUN_ID" "$txt" | append_as root "$LIMITS_FILE" || return 1
  chmod 644 "$LIMITS_FILE"
  printf '%s' "$txt" | log_block "added to $LIMITS_FILE"
}

# ---- 2.5 folders ----
make_dir() {
  # $1 path, $2 owner. Creates missing components owned by $2 (group INSTALL_GROUP, 775).
  # Changes the owner of an existing directory only when it is empty. Never recursive, never through a link.
  local path=$1 owner=$2 p="" comp
  local -a parts=()
  case "$path" in /etc/ORACLE|/etc/ORACLE/*) ;;   # Oracle's default wallet location
    /|/usr|/usr/*|/etc|/etc/*|/var|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/root|/tmp)
    bad "$path is a system folder. It is not created or changed."; return 1 ;; esac
  IFS='/' read -ra parts <<< "${path#/}"
  for comp in "${parts[@]}"; do
    [[ -n "$comp" ]] || continue
    p+="/$comp"
    if [[ -L "$p" ]]; then
      local lo; lo=$(stat -c '%U' "$p")
      [[ "$lo" == "root" ]] || { bad "$p is a symbolic link owned by $lo. It is not used."; return 1; }
    fi
    if [[ ! -e "$p" ]]; then install -d -o "$owner" -g "$INSTALL_GROUP" -m 775 "$p" || return 1; say "Created $p"; journal DIR "$p" "owner $owner"; fi
  done
  [[ -L "$path" ]] && { warn "$path is a symbolic link. Its owner is not changed."; return 0; }
  if dir_empty "$path"; then chown -h "$owner:$INSTALL_GROUP" "$path" && chmod 775 "$path"; fi
}
dir_specs() {
  if use_grid; then printf '%s\n' "$GRID_BASE:$GRID_USER" "$GRID_HOME:$GRID_USER"; fi
  printf '%s\n' "$INVENTORY_DIR:$GRID_USER" "$ORACLE_BASE:$ORACLE_USER" "$DB_HOME:$ORACLE_USER"
}
existing_parent() { local p=$1; while [[ ! -e "$p" && "$p" != "/" ]]; do p=$(dirname "$p"); done; printf '%s' "$p"; }
mnt_of() { df --output=target -- "$(existing_parent "$1")" 2>/dev/null | tail -n 1; }
free_mb_of() { local f; f=$(df -m --output=avail -- "$(existing_parent "$1")" 2>/dev/null | tail -n 1 | tr -d ' '); num "$f" && printf '%s' "$f" || printf '0'; }
c_2_5() {
  users_ok || { NOW="The users do not exist yet (step 2.2)"; return 2; }
  local d own miss="" wrong="" fixw=""
  while IFS=: read -r d own; do
    if [[ ! -d "$d" ]]; then miss+="  $d  (owner $own)"$'\n'; continue; fi
    local cur; cur=$(stat -c '%U' "$d")
    if [[ "$cur" != "$own" && ! ( "$cur" == "root" && "$d" == "$GRID_HOME" ) ]]; then
      if dir_empty "$d"; then miss+="  $d  (owner $cur, becomes $own)"$'\n'
      else wrong+="$d is not empty and belongs to $cur, not $own"$'\n'; fixw+="chown $own:$INSTALL_GROUP $d"$'\n'; fi
    fi
  done < <(dir_specs)
  if [[ -n "$wrong" ]]; then
    NOW="${wrong%$'\n'}"
    MANUAL_HOW="root  ->  shell Only if these files belong to this standby setup."
    PLAN="-- First check what is in the folder (ls -la).
-- Change the owner only if that is right:
${fixw%$'\n'}"
    return 2
  fi
  # an empty home needs room for the software (about 15 GB each)
  local short="" h
  for h in "$DB_HOME" ${GRID_HOME:+"$GRID_HOME"}; do
    dir_empty "$h" || continue
    use_grid || [[ "$h" != "$GRID_HOME" ]] || continue
    [[ $(free_mb_of "$h") -ge 15360 ]] || short+="$(mnt_of "$h") has $(human_mb "$(free_mb_of "$h")") free for $h. It needs about 15 GB."$'\n'
  done
  [[ -n "$short" ]] && warn "Little free space for the software:"$'\n'"${short%$'\n'}"
  if [[ -z "$miss" ]]; then NOW="The folders exist and have the right owners"; return 0; fi
  NOW="Some folders are missing, or an empty folder has the wrong owner"
  PLAN="Create these folders, or set their owner (group $INSTALL_GROUP, mode 775):
${miss%$'\n'}
Folders that are not empty keep their owner."
  USING="Same paths as on the primary"
  return 1
}
d_2_5() { local d own; while IFS=: read -r d own; do make_dir "$d" "$own" || return 1; done < <(dir_specs); }

# ---- 2.6 /etc/hosts on standby ----
# The script fixes /etc/hosts itself (a backup is kept, --undo puts it back):
#   a name that does not resolve gets a line; a name on a 127.x line or on a wrong address is taken off
#   that line and gets its own correct line (lines of other names are never changed).
H_TODO=""; H_FIX=""
v4_of() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }
host_fq() {   # the full name of this server when it is <short name>.<domain>
  local fq; fq=$(hostname 2>/dev/null)
  [[ "$fq" == *.* && "${fq%%.*}" == "$STANDBY_HOST" ]] && printf '%s' "$fq"
}
c_2_6() {
  local todo="" fix="" h ip want why=""
  H_TODO=""; H_FIX=""
  for h in "$PRIMARY_HOST|$PRIMARY_IP" "$STANDBY_HOST|$STANDBY_IP"; do
    IFS='|' read -r h want <<< "$h"
    ip=$(v4_of "$h")
    local fq=""; [[ "$h" == "$STANDBY_HOST" ]] && fq=$(host_fq)
    if [[ -z "$ip" ]]; then
      [[ "$want" =~ ^[0-9.]+$ ]] || { NOW="$h does not resolve, and its IP address is not known"; return 2; }
      todo+="$want    ${fq:+$fq }$h"$'\n'
    elif [[ "$want" =~ ^[0-9.]+$ && "$ip" != "$want" ]]; then
      if [[ "$ip" == 127.* ]]; then why+="$h resolves to $ip (loopback). The primary could not reach this server's listener."$'\n'
      else why+="$h resolves to $ip here, but it is $want"$'\n'; fi
      fix+="$h|$want"$'\n'; todo+="$want    ${fq:+$fq }$h"$'\n'
    fi
  done
  if [[ -z "$todo" ]]; then NOW="Names resolve: $PRIMARY_HOST = $(v4_of "$PRIMARY_HOST"), $STANDBY_HOST = $(v4_of "$STANDBY_HOST")"; return 0; fi
  H_TODO=${todo%$'\n'}; H_FIX=${fix%$'\n'}
  if [[ -L /etc/hosts ]]; then
    NOW="${why:-The host names do not resolve on this server}"$'\n'"/etc/hosts is a symbolic link, so the script does not change it."
    KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
    PLAN="-- Correct the names in DNS or in the file /etc/hosts points to:"$'\n'"$H_TODO"
    return 1
  fi
  if [[ -n "$why" ]]; then
    NOW="${why%$'\n'}"
    PLAN="Correct /etc/hosts (a backup is kept; --undo puts it back):"
    local f; while IFS='|' read -r h want; do [[ -n "$h" ]] && PLAN+=$'\n'"  take $h off the lines with another address"; done <<< "$H_FIX"
    PLAN+=$'\n'"  then add:"$'\n'"$(sed 's/^/    /' <<< "$H_TODO")"
    grep -qE '^hosts:.*dns.*files' /etc/nsswitch.conf 2>/dev/null && PLAN+=$'\n'"Note: /etc/nsswitch.conf asks DNS before /etc/hosts. Correct DNS too."
  else
    NOW="The host names do not resolve on this server"
    PLAN="Add these lines to /etc/hosts (a backup is kept):"$'\n'"$H_TODO"
  fi
  return 1
}
d_2_6() {
  backup_file /etc/hosts || return 1
  local tmp h want fq
  tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
  cp -- /etc/hosts "$tmp" 2>/dev/null || : > "$tmp"
  # take each name (and this server's full name) off every line whose address is not the right one
  while IFS='|' read -r h want; do
    [[ -n "$h" ]] || continue
    fq=""; [[ "$h" == "$STANDBY_HOST" ]] && fq=$(host_fq)
    awk -v n="$h" -v f="$fq" -v w="$want" '
      /^[[:space:]]*(#|$)/ { print; next }
      {
        if ($1 == w || index($1, ":")) { print; next }      # the right line, and IPv6 lines, stay as they are
        out = $1; kept = 0
        for (i = 2; i <= NF; i++) {
          if (substr($i, 1, 1) == "#") { for (j = i; j <= NF; j++) out = out " " $j; break }
          if (tolower($i) == tolower(n) || (f != "" && tolower($i) == tolower(f))) continue
          out = out " " $i; kept++
        }
        if (kept > 0 || NF == 1) print out
      }' "$tmp" > "$tmp.n" && mv -f -- "$tmp.n" "$tmp" || return 1
  done <<< "$H_FIX"
  # a last line without its newline gets one first (else the new line would be glued to it)
  [[ -s "$tmp" && -n "$(tail -c 1 -- "$tmp")" ]] && printf '\n' >> "$tmp"
  local l; while IFS= read -r l; do [[ -n "$l" ]] && ! grep -qxF -- "$l" "$tmp" && printf '%s\n' "$l" >> "$tmp"; done <<< "$H_TODO"
  # written in place: the file keeps its owner, mode and SELinux label; a failed write puts the backup back
  cat -- "$tmp" > /etc/hosts || { [[ -f "/etc/hosts.bak_$RUN_ID" ]] && cat -- "/etc/hosts.bak_$RUN_ID" > /etc/hosts; bad "/etc/hosts could not be written. The old content was put back."; return 1; }
  rm -f -- "$tmp"
  journal_file_written /etc/hosts 1
  say "Corrected /etc/hosts."
  return 0
}

# ---- 2.7 primary resolves standby ----
c_2_7() {
  need_ssh || return 2
  if prim_probe hosts "$STANDBY_HOST" && [[ -n "$(awk '{print $1; exit}' <<< "$RUN_OUT")" ]]; then
    local pip; pip=$(awk '{print $1; exit}' <<< "$RUN_OUT")
    if [[ "$pip" == "$STANDBY_IP" ]]; then NOW="The primary resolves $STANDBY_HOST to $pip"; return 0; fi
    NOW="The primary resolves $STANDBY_HOST to $pip, but this server is $STANDBY_IP"
    PRIMARY_HOW_STEP="root  ->  shell"
    PLAN="-- In /etc/hosts on the primary (or in DNS), change the line for $STANDBY_HOST to:
$STANDBY_IP    $STANDBY_HOST"
    PLAN_UNDO="put back the line '$pip    $STANDBY_HOST' in /etc/hosts on the primary"
    return 1
  fi
  NOW="The primary does not resolve $STANDBY_HOST"
  PRIMARY_HOW_STEP="root  ->  shell"
  PLAN="echo '$STANDBY_IP    $STANDBY_HOST' >> /etc/hosts"
  PLAN_UNDO="remove the line '$STANDBY_IP    $STANDBY_HOST' from /etc/hosts on the primary"
  return 1
}

# ---- 2.8 network to primary listener ----
c_2_8() {
  if timeout 5 bash -c "exec 3<>/dev/tcp/$PRIMARY_IP/$PORT" 2>/dev/null; then NOW="$PRIMARY_IP:$PORT is reachable"; return 0; fi
  NOW="Cannot connect to $PRIMARY_IP:$PORT
A firewall on the primary, or in the network, blocks it."
  KIND_NOW=primary; PRIMARY_HOW_STEP="root  ->  shell Only if the primary runs firewalld. Otherwise ask the network team."
  # added only when it is not open yet, and without a reload (a reload would drop rules the primary admin added at runtime)
  PLAN="firewall-cmd --query-port=$PORT/tcp || { firewall-cmd --add-port=$PORT/tcp ; firewall-cmd --permanent --add-port=$PORT/tcp ; }
# If the port was already open, the network blocks it: ask the network team."
  PLAN_UNDO="only if the port was NOT open before (else clients of the primary lose it): firewall-cmd --remove-port=$PORT/tcp ; firewall-cmd --permanent --remove-port=$PORT/tcp"
  return 1
}

# ---- 2.9 firewall here ----
FW_ZONE=""
c_2_9() {
  if ! systemctl is-active --quiet firewalld 2>/dev/null; then NOW="firewalld is not active"; return 0; fi
  local ifc; ifc=$(ip -o addr show 2>/dev/null | awk -v a="$STANDBY_IP" '{split($4, x, "/"); if (x[1] == a) {print $2; exit}}')
  FW_ZONE=""
  [[ -n "$ifc" ]] && { FW_ZONE=$(firewall-cmd --get-zone-of-interface="$ifc" 2>/dev/null) || FW_ZONE=""; }
  [[ -n "$FW_ZONE" ]] || FW_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
  [[ "$FW_ZONE" =~ ^[A-Za-z0-9_-]+$ ]] || FW_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
  [[ "$FW_ZONE" =~ ^[A-Za-z0-9_-]+$ ]] || FW_ZONE=public
  if firewall-cmd --zone="$FW_ZONE" --query-port="$PORT/tcp" >/dev/null 2>&1; then NOW="Port $PORT/tcp is open (zone $FW_ZONE)"; return 0; fi
  NOW="Port $PORT/tcp is closed in firewalld (zone $FW_ZONE${ifc:+, interface $ifc})"
  PLAN="firewall-cmd --permanent --zone=$FW_ZONE --add-port=$PORT/tcp
firewall-cmd --reload"
  return 1
}
d_2_9() {
  local c; while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    run_cmds <<< "$c" || return 1
    [[ "$c" =~ --zone=([A-Za-z0-9_-]+)\ --add-port=([0-9]+/tcp) ]] && journal FWPORT "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
  done <<< "$PLAN"
  return 0
}

# ---- 2.10 time ----
c_2_10() {
  if systemctl is-active --quiet chronyd 2>/dev/null; then
    if grep -q 'Leap status.*Normal' <<< "$(chronyc tracking 2>/dev/null)"; then NOW="chronyd is running and the clock is in sync"; else NOW="chronyd is running; the sync is not confirmed yet"; fi
    return 0
  fi
  if systemctl is-active --quiet ntpd 2>/dev/null; then NOW="ntpd is running"; return 0; fi
  NOW="No time sync is running (neither chronyd nor ntpd)"
  PLAN="systemctl enable --now chronyd"
  return 1
}
d_2_10() { run_cmds <<< "systemctl enable --now chronyd" && journal SERVICE chronyd; }

# ---- 2.11 profiles ----
PROF_TODO=()
login_env() {
  # what the user really gets after login (the profile is run in a login shell on THIS server)
  timeout 20 runuser -l "$1" -s /bin/bash -c 'printf "%s|%s|%s\n" "${ORACLE_SID:-}" "${ORACLE_HOME:-}" "${ORACLE_BASE:-}"' < /dev/null 2>/dev/null 9>&- | tail -n 1
}
profile_specs() {
  printf '%s\n' "$ORACLE_USER|$ORACLE_BASE|$DB_HOME|$STANDBY_SID"
  if use_grid && ! single_owner; then printf '%s\n' "$GRID_USER|$GRID_BASE|$GRID_HOME|+ASM"; fi
}
profile_block() { printf '# Added by dg_standby_setup.sh (Data Guard standby %s)\nexport ORACLE_BASE=%s\nexport ORACLE_HOME=%s\nexport ORACLE_SID=%s\nexport PATH=$ORACLE_HOME/bin:$PATH\n' "$STANDBY_UNIQUE" "$2" "$3" "$4"; }
c_2_11() {
  users_ok || { NOW="The users do not exist yet (step 2.2)"; return 2; }
  local entry usr base home sid cur csid chome cbase todo=() report="" okl="" over=""
  while IFS= read -r entry; do
    IFS='|' read -r usr base home sid <<< "$entry"
    cur=$(login_env "$usr"); IFS='|' read -r csid chome cbase <<< "$cur"
    if [[ "$csid" == "$sid" && "${chome%/}" == "$home" && "${cbase%/}" == "$base" ]]; then okl+="${okl:+, }$usr ($sid)"; continue; fi
    local prof; prof="$(home_of "$usr")/.bash_profile"
    if [[ -f "$prof" ]] && grep -qxF "export ORACLE_SID=$sid" "$prof" && grep -qxF "export ORACLE_HOME=$home" "$prof" && grep -qF "dg_standby_setup.sh" "$prof"; then
      over+="$usr: the lines are in $prof, but after login the values are:"$'\n'"  ORACLE_SID=${csid:-<not set>}  ORACLE_HOME=${chome:-<not set>}"$'\n'
      continue
    fi
    todo+=("$entry")
    report+="$usr now has: ORACLE_SID=${csid:-<not set>}  ORACLE_HOME=${chome:-<not set>}  ORACLE_BASE=${cbase:-<not set>}"$'\n'
  done < <(profile_specs)
  if [[ -n "$over" ]]; then
    NOW="${over%$'\n'}"
    KIND_NOW=manual; MANUAL_HOW="the Oracle user  ->  shell"
    PLAN="-- A file read after ~/.bash_profile sets other values, often ~/.bashrc or /etc/profile.d/*.sh.
-- To find the lines:
grep -n 'ORACLE_' ~/.bashrc /etc/profile.d/*.sh
-- Remove or correct them, then answer r."
    return 1
  fi
  if [[ ${#todo[@]} -eq 0 ]]; then NOW="Environment is correct: $okl"; return 0; fi
  PROF_TODO=("${todo[@]}")
  NOW="${report%$'\n'}"
  PLAN="Add these settings to ~/.bash_profile of each user (a backup is kept):"
  local others; others=$(grep -vE '^\s*(#|$|\+ASM)' /etc/oratab 2>/dev/null | cut -d: -f1 | grep -vx -- "$STANDBY_SID" | paste -sd' ' -)
  [[ -n "$others" ]] && USING="/etc/oratab lists other databases here: $others
After this, the default ORACLE_SID of $ORACLE_USER is $STANDBY_SID."
  for entry in "${todo[@]}"; do
    IFS='|' read -r usr base home sid <<< "$entry"
    PLAN+=$'\n'"  $usr:"
    PLAN+=$'\n'"    ORACLE_BASE=$base"$'\n'"    ORACLE_HOME=$home"
    PLAN+=$'\n'"    ORACLE_SID=$sid"$'\n'"    PATH=\$ORACLE_HOME/bin:\$PATH"
  done
  PLAN+=$'\n'"Existing lines stay; the new lines come last, so they win."
  return 1
}
d_2_11() {
  local entry usr base home sid prof
  for entry in "${PROF_TODO[@]}"; do
    IFS='|' read -r usr base home sid <<< "$entry"
    prof="$(home_of "$usr")/.bash_profile"
    [[ -L "$prof" ]] && { bad "$prof is a symbolic link. It is not changed."; return 1; }
    backup_file "$prof" "$usr" || return 1
    profile_block "$usr" "$base" "$home" "$sid" | append_as "$usr" "$prof" || { bad "Cannot write $prof"; return 1; }
    profile_block "$usr" "$base" "$home" "$sid" | log_block "added to $prof"
  done
}

# ---- 2.12 ASM disk method ----
# asmlib: Oracle ASMLib (oracleasm), disks in /dev/oracleasm/disks
# udev:   a udev rule per partition, keyed on the GPT partition UUID, disks in /dev/oraasm
#         (works on every kernel; used when ASMLib is not usable, for example Oracle Linux 9 or a non-UEK kernel)
asm_method() {
  if [[ -n "$ASM_METHOD" ]]; then printf '%s' "$ASM_METHOD"; return; fi
  if [[ "$OS_MAJOR" =~ ^[78]$ && "$(uname -r)" == *uek* ]]; then printf 'asmlib'; else printf 'udev'; fi
}
asm_disk_dir() { if [[ "$(asm_method)" == "asmlib" ]]; then printf '/dev/oracleasm/disks'; else printf '/dev/oraasm'; fi; }
# the OSASM group: owner group of the ASM disks, OSASM in the Grid installation, group of the oracle binary
asm_owner_group() { grp_or asmadmin dba "$GRID_PGROUP"; }
readonly UDEV_RULES=/etc/udev/rules.d/99-oracle-asmdevices.rules
A212_MODE=""
c_2_12() {
  use_grid || { NOW="Not needed (the primary does not use ASM)"; return 0; }
  local m; m=$(asm_method); A212_MODE=""
  if [[ "$m" == "udev" ]]; then
    NOW="ASM disks use udev rules, with devices in /dev/oraasm
Rules file: $UDEV_RULES"
    if [[ "$ASM_METHOD" != "udev" && "$MODE" == "run" ]]; then ASM_METHOD=udev; save_settings; journal SETTING ASM_METHOD "ASM_METHOD=udev"; NOW+=$'\n'"This choice is saved in the settings."; fi
    return 0
  fi
  if ! command -v oracleasm >/dev/null 2>&1; then
    if [[ -n "$(asm_labels_all)" ]]; then NOW="oracleasm is not installed, but earlier ASM disks were made with it (step 2.3)"; return 2; fi
    NOW="ASMLib (oracleasm-support) is not installed"
    PLAN="Use udev rules for the ASM disks instead of ASMLib. They work on every kernel.
To use ASMLib instead: answer s, install oracleasm-support (step 2.3), then run the script again."
    A212_MODE=to_udev
    return 1
  fi
  local cfg st need="" ag; ag=$(asm_owner_group)
  cfg=$(oracleasm configure 2>/dev/null); st=$(oracleasm status 2>/dev/null)
  if ! grep -qx "ORACLEASM_UID=$GRID_USER" <<< "$cfg" || ! grep -qx "ORACLEASM_GID=$ag" <<< "$cfg" || ! grep -qx 'ORACLEASM_ENABLED=true' <<< "$cfg"; then
    need+="oracleasm configure -u $GRID_USER -g $ag -e -s y"$'\n'
  fi
  [[ $(grep -c ': yes' <<< "$st") -ge 2 ]] || need+="oracleasm init"$'\n'
  systemctl is-enabled --quiet oracleasm 2>/dev/null || need+="systemctl enable oracleasm"$'\n'
  if [[ -z "$need" && "$ASM_METHOD" == "asmlib" ]]; then NOW="ASMLib is configured for $GRID_USER:$ag, loaded, and starts at boot"; return 0; fi
  if [[ "$need" == "systemctl enable oracleasm"$'\n' ]]; then NOW="ASMLib is configured and loaded, but does not start at boot"
  elif [[ -z "$need" ]]; then NOW="ASMLib is configured and loaded, but not yet chosen for the ASM disks"
  else
    local nl=""
    [[ "$need" == *"oracleasm configure"* ]] && nl+="${nl:+; }not configured for $GRID_USER:$ag"
    [[ "$need" == *"oracleasm init"* ]] && nl+="${nl:+; }not loaded"
    [[ "$need" == *"systemctl enable"* ]] && nl+="${nl:+; }does not start at boot"
    NOW="ASMLib (oracleasm): $nl"
  fi
  PLAN="${need%$'\n'}"
  [[ -n "$PLAN" ]] || PLAN="Use ASMLib for the ASM disks"
  A212_MODE=asmlib
  return 1
}
d_2_12() {
  case "$A212_MODE" in
    to_udev|save) ASM_METHOD=udev; save_settings; return 0 ;;
  esac
  if [[ -n "$PLAN" && "$PLAN" != "Use ASMLib"* ]]; then
    journal ASMCFG oracleasm "$(tr '\n' ';' <<< "$PLAN")"
    if ! run_cmds <<< "$PLAN"; then
      warn "ASMLib does not work on this kernel ($(uname -r)). udev rules are used instead."
      run_logged "oracleasm configure -d" oracleasm configure -d || true
      run_logged "systemctl disable oracleasm" systemctl disable oracleasm || true
      ASM_METHOD=udev; save_settings; return 0
    fi
  fi
  ASM_METHOD=asmlib; save_settings; journal SETTING ASM_METHOD "ASM_METHOD=asmlib"
}

# ---- 2.13 ASM disks ----
# Labels are <DISKGROUP>_<n> (DATA_1, DATA_2, FRA_1). Disks this script made (or that you confirmed)
# are listed in $STATE_DIR/asm_disks as LABEL|partition.
part_name() { if [[ "$1" =~ [0-9]$ ]]; then printf '%sp1' "$1"; else printf '%s1' "$1"; fi; }
asm_disks_file() { printf '%s/asm_disks' "$STATE_DIR"; }
asm_labels_all() {
  if [[ "$(asm_method)" == "asmlib" ]]; then command -v oracleasm >/dev/null 2>&1 && oracleasm listdisks 2>/dev/null
  else ls -1 /dev/oraasm 2>/dev/null; fi
}
asm_labels_any() {
  # every existing label that belongs to disk group $1: DG_<n>, or DG<n> made by an older version
  local dg=${1^^} l other skip
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    if [[ "$l" =~ ^${dg}_[0-9]+$ ]]; then printf '%s\n' "$l"; continue; fi
    [[ "$l" =~ ^${dg}[0-9]+$ ]] || continue
    skip=0
    for other in $(asm_dgs); do
      [[ "$other" != "$dg" && "$other" == "$dg"* && "$l" =~ ^${other}[0-9]+$ ]] && skip=1
    done
    [[ $skip -eq 0 ]] && printf '%s\n' "$l"
  done < <(asm_labels_all) | sort -V
}
asm_label_known() { [[ -f "$(asm_disks_file)" ]] && grep -q "^$1|/" "$(asm_disks_file)"; }        # used by this standby
asm_label_declined() { [[ -f "$(asm_disks_file)" ]] && grep -qx "$1|-" "$(asm_disks_file)"; }       # you said no
asm_labels() {
  # the disks of disk group $1 that this standby uses (made by this script, or confirmed by you)
  local l
  while IFS= read -r l; do [[ -n "$l" ]] && asm_label_known "$l" && printf '%s\n' "$l"; done < <(asm_labels_any "$1")
  return 0
}
asm_foreign() { local l; while IFS= read -r l; do [[ -n "$l" ]] && ! asm_label_known "$l" && ! asm_label_declined "$l" && printf '%s\n' "$l"; done < <(asm_labels_any "$1"); return 0; }
asm_label_exists() {
  if [[ "$(asm_method)" == "asmlib" ]]; then oracleasm listdisks 2>/dev/null | grep -qx -- "$1"; else [[ -e "/dev/oraasm/$1" ]]; fi
}
asm_label_free() { ! asm_label_exists "$1"; }
label_device() {
  # partition behind a label
  # the live mapping first (sd names can change after a reboot), the recorded one only as a fallback
  local l=$1 d
  if [[ "$(asm_method)" == "asmlib" ]]; then d=$(oracleasm querydisk -p "$l" 2>/dev/null | grep -oE '^/dev/[^:]+' | head -n 1)
  else d=$(readlink -f "/dev/oraasm/$l" 2>/dev/null); [[ -b "$d" ]] || d=""; fi
  [[ -n "$d" ]] || d=$( [[ -f "$(asm_disks_file)" ]] && grep -m1 "^$l|/" "$(asm_disks_file)" | cut -d'|' -f2)
  printf '%s' "$d"
}
label_mb() { local d; d=$(label_device "$1"); [[ -n "$d" ]] || { printf '0'; return; }; printf '%s' "$(( $(lsblk -dbn -o SIZE "$d" 2>/dev/null | head -n 1 || echo 0) / 1048576 ))"; }
dg_have_mb() { local l t=0; while IFS= read -r l; do [[ -n "$l" ]] && t=$((t + $(label_mb "$l"))); done < <(asm_labels "$1"); printf '%s' "$t"; }
dg_min_mb() { printf '%s' "$(( $(dg_need_mb "$1") * 11 / 10 + 1024 ))"; }
record_label() { install -d -m 700 "$STATE_DIR"; printf '%s|%s\n' "$1" "$2" >> "$(asm_disks_file)"; chmod 600 "$(asm_disks_file)"; }

disk_is_free() {
  # $1 /dev/xxx. 0 = whole local disk, not mounted, not in use, no partitions, no signature and an empty
  # first MiB (an ASM disk of another server, also one without ASMLib, always has a header there). Sets DISK_WHY.
  local disk=$1 sig pt wf rc n
  DISK_WHY=""
  [[ "$disk" =~ ^/dev/(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] || { DISK_WHY="unsupported name"; return 1; }
  n=${disk#/dev/}
  [[ "$(lsblk -dn -o TYPE "$disk" 2>/dev/null)" == "disk" ]] || { DISK_WHY="not a whole disk"; return 1; }
  [[ "$(lsblk -dn -o RM "$disk" 2>/dev/null | tr -d ' ')" != "1" ]] || { DISK_WHY="removable disk"; return 1; }
  [[ -z "$(lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -v '^[[:space:]]*$')" ]] || { DISK_WHY="mounted"; return 1; }
  [[ "$(lsblk -n -o NAME "$disk" 2>/dev/null | tail -n +2 | wc -l)" -eq 0 ]] || { DISK_WHY="has partitions or is in use (LVM, multipath, RAID)"; return 1; }
  [[ -z "$(ls -A "/sys/block/$n/holders" 2>/dev/null)" ]] || { DISK_WHY="in use by $(ls -A "/sys/block/$n/holders" | paste -sd' ' -)"; return 1; }
  rc=0; sig=$(blkid -p -o value -s TYPE "$disk" 2>/dev/null) || rc=$?
  [[ $rc -eq 8 ]] && { DISK_WHY="has data (more than one signature)"; return 1; }
  pt=$(blkid -p -o value -s PTTYPE "$disk" 2>/dev/null || true)
  [[ -z "$sig" && -z "$pt" ]] || { DISK_WHY="has data (${sig}${pt:+ partition-table:$pt})"; return 1; }
  if command -v wipefs >/dev/null 2>&1; then
    # util-linux 2.23 (OL7) prints "offset type [description]"; newer versions print columns. The type is field 2.
    # util-linux 2.29+ (OL8/9): table with an OFFSET column -> ask for TYPE only; 2.23 (OL7): "offset type" lines
    # (-O is the column list; -o would be an offset)
    if wipefs --help 2>&1 | grep -q -- '--output'; then wf=$(wipefs -n -O TYPE --noheadings "$disk" 2>&1 | tr '\n' ' ') || wf="wipefs failed: $wf"
    else wf=$(wipefs -n "$disk" 2>/dev/null | tail -n +2 | grep -v '^-' | grep -v '^[[:space:]]' | awk '{print $2}' | tr '\n' ' ' || true); fi
    [[ -z "${wf// /}" ]] || { DISK_WHY="has signatures ($wf)"; return 1; }
  fi
  if command -v pvs >/dev/null 2>&1 && pvs --noheadings -o pv_name 2>/dev/null | awk -v d="$disk" '$1==d {f=1} END {exit !f}'; then DISK_WHY="LVM"; return 1; fi
  grep -qE "^${disk}[0-9p]*[[:space:]]" /proc/swaps 2>/dev/null && { DISK_WHY="swap"; return 1; }
  cmp -s -n 1048576 -- "$disk" /dev/zero || { DISK_WHY="the first MiB is not empty (old data, or an ASM disk of another server)"; return 1; }
  return 0
}
free_disks() {
  # prints "/dev/x SIZE_MB" for every free whole disk, biggest first. A disk seen twice (same WWN: two paths
  # to one LUN without multipath) is never offered.
  local n w dupw
  dupw=$(lsblk -dn -o WWN 2>/dev/null | tr -d ' ' | grep -v '^$' | sort | uniq -d)
  for n in $(lsblk -dn -o NAME 2>/dev/null); do
    w=$(lsblk -dn -o WWN "/dev/$n" 2>/dev/null | tr -d ' ')
    [[ -n "$w" && -n "$dupw" ]] && grep -qx -- "$w" <<< "$dupw" && continue
    disk_is_free "/dev/$n" && printf '/dev/%s %s\n' "$n" "$(( $(lsblk -dbn -o SIZE "/dev/$n" 2>/dev/null || echo 0) / 1048576 ))"
  done | sort -k2,2nr
}

A213_FOREIGN=""
c_2_13() {
  use_grid || { NOW="Not needed (the primary does not use ASM)"; return 0; }
  [[ "$(asm_method)" == "udev" ]] || command -v oracleasm >/dev/null 2>&1 || { NOW="oracleasm is not installed (step 2.12)"; return 2; }
  local dg have="" miss="" short="" l foreign="" min hv ready="" x fl xm
  for dg in $(asm_dgs); do
    ready+=" +$dg"
    l=$(asm_foreign "$dg")
    if [[ -n "$l" ]]; then
      fl=""; for x in $l; do xm=$(label_mb "$x"); fl+="${fl:+, }$x$([[ $xm -gt 0 ]] && printf ' (%s)' "$(human_mb "$xm")")"; done
      foreign+="  +$dg: $fl"$'\n'
    fi
    min=$(dg_min_mb "$dg"); hv=$(dg_have_mb "$dg")
    if [[ -z "$(asm_labels "$dg")" ]]; then miss+=" +$dg"
    elif [[ $hv -lt $min ]]; then short+=" +$dg"; have+="  +$dg: $(asm_labels "$dg" | paste -sd' ' -)  ($(human_mb "$hv"), needs $(human_mb "$min"))"$'\n'
    else have+="  +$dg: $(asm_labels "$dg" | paste -sd' ' -)  ($(human_mb "$hv"))"$'\n'; fi
  done
  A213_FOREIGN=${foreign%$'\n'}
  if [[ -z "$miss$short$foreign" ]]; then NOW="ASM disks are ready for:$ready"$'\n'"${have%$'\n'}"; return 0; fi
  local fd; fd=$(free_disks)
  NOW=""
  if [[ -n "$miss" ]]; then
    local -a mw=(); read -ra mw <<< "$miss"
    local ml=${mw[${#mw[@]}-1]}
    [[ ${#mw[@]} -gt 1 ]] && ml="$(printf '%s, ' "${mw[@]:0:${#mw[@]}-1}")"; [[ ${#mw[@]} -gt 1 ]] && ml="${ml%, } and ${mw[${#mw[@]}-1]}"
    NOW+="No disks are assigned yet to $ml."$'\n'
  fi
  [[ -n "$short" ]] && NOW+="Too small, more disks are added for:$short"$'\n'
  [[ -n "$foreign" ]] && NOW+="Existing ASM disks found (not created by this script):"$'\n'"$A213_FOREIGN"$'\n'
  [[ -n "$have" ]] && NOW+="ASM disks:"$'\n'"$have"
  [[ -n "$foreign" && -z "$fd" ]] && NOW+="No empty disk was found, so no disk will be partitioned."
  NOW=${NOW%$'\n'}
  PLAN=""
  [[ -n "$foreign" ]] && PLAN="Ask you, for each disk group, whether to use its existing ASM disks."
  if [[ -n "$fd" || -z "$foreign" ]]; then
    [[ -n "$foreign" ]] && PLAN+=$'\n'"Then, for each disk group that still needs disks:"
    PLAN+=$'\n'"Choose one or more empty disks for each disk group (list below)
Each chosen disk gets a GPT label and one partition"
    if [[ "$(asm_method)" == "asmlib" ]]; then PLAN+=$'\n'"Then: oracleasm createdisk <DG>_1, <DG>_2 ..."
    else PLAN+=$'\n'"Then a udev rule makes /dev/oraasm/<DG>_1, owner $GRID_USER:$(asm_owner_group), mode 0660"; fi
    PLAN+=$'\n'"All chosen disks are checked first. Disks with any data are refused."
    PLAN+=$'\n'"You type each disk name to confirm it."
  fi
  PLAN=${PLAN#$'\n'}
  USING="Size needed (database files of the primary + 10%, plus the recovery area):"
  for dg in $(asm_dgs); do USING+=$'\n'"  +$dg  at least $(human_mb "$(dg_min_mb "$dg")")"; done
  if [[ -n "$fd" ]]; then
    USING+=$'\n'"Empty disks found:"
    while read -r l; do USING+=$'\n'"  ${l%% *}  $(human_mb "${l##* }")"; done <<< "$fd"
  else
    [[ -n "$foreign" ]] || USING+=$'\n'"No empty disk was found on this server."
    USING+=$'\n'"Multipath devices are not offered; see --help-step 2.13"
  fi
  return 1
}

udev_uuid() {
  # GPT partition UUID as udev sees it (blkid -p -s PART_ENTRY_UUID prints nothing on OL7 for an empty partition)
  local p=$1 u
  u=$(udevadm info --query=property --name="$p" 2>/dev/null | sed -n 's/^ID_PART_ENTRY_UUID=//p' | head -n 1)
  [[ -n "$u" ]] || u=$(blkid -p -o udev "$p" 2>/dev/null | sed -n 's/^ID_PART_ENTRY_UUID=//p' | head -n 1)
  [[ -n "$u" ]] || u=$(blkid -p -o value -s PART_ENTRY_UUID "$p" 2>/dev/null | head -n 1)
  printf '%s' "$u"
}

make_asm_disk() {
  # $1 label, $2 disk (already validated and confirmed)
  local label=$1 disk=$2 part
  part=$(part_name "$disk")
  disk_is_free "$disk" || { bad "$disk can no longer be used: $DISK_WHY. Nothing was erased."; return 1; }
  journal PART "$disk" "GPT with one partition for ASM disk $label"
  run_cmds <<< "parted -s $disk mklabel gpt mkpart primary 1MiB 100%
partprobe $disk" || return 1
  command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null
  local n=0
  until [[ "$(lsblk -dn -o TYPE "$part" 2>/dev/null)" == "part" ]]; do
    n=$((n + 1)); [[ $n -gt 10 ]] && { bad "Partition $part did not appear"; return 1; }; sleep 1
  done
  if [[ "$(asm_method)" == "asmlib" ]]; then
    if ! run_cmds <<< "oracleasm createdisk $label $part
oracleasm scandisks"; then
      printf 'The disk now has an empty GPT partition, with no data on it.\nTo try again later, clear it first:\n  wipefs -a %s ; wipefs -a %s\n' "$part" "$disk" | hint
      return 1
    fi
  else
    local uuid; uuid=$(udev_uuid "$part")
    if ! [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      bad "Cannot read the partition UUID of $part"
      printf 'The disk now has an empty GPT partition, with no data on it.\nTo try again later, clear it first:\n  wipefs -a %s ; wipefs -a %s\n' "$part" "$disk" | hint
      return 1
    fi
    install -d -m 755 "$(dirname "$UDEV_RULES")" || return 1
    backup_file "$UDEV_RULES" || return 1
    # a retry after a slow udev must not add the same rule twice
    if ! grep -qsF -- "ENV{ID_PART_ENTRY_UUID}==\"$uuid\"" "$UDEV_RULES"; then
      printf 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_UUID}=="%s", SYMLINK+="oraasm/%s", OWNER="%s", GROUP="%s", MODE="0660"\n' \
        "$uuid" "$label" "$GRID_USER" "$(asm_owner_group)" | append_as root "$UDEV_RULES" || return 1
    fi
    chmod 644 "$UDEV_RULES"
    run_cmds <<< "udevadm control --reload-rules
udevadm trigger --action=change --sysname-match=${part#/dev/}
udevadm settle" || return 1
    n=0; until [[ -e "/dev/oraasm/$label" ]]; do n=$((n + 1)); [[ $n -gt 10 ]] && break; sleep 1; done
    local perm; perm=$(stat -L -c '%U:%G:%a' "/dev/oraasm/$label" 2>/dev/null)
    [[ "$perm" == "$GRID_USER:$(asm_owner_group):660" ]] || { bad "/dev/oraasm/$label has owner and mode '$perm', but needs $GRID_USER:$(asm_owner_group):660"; return 1; }
  fi
  asm_label_exists "$label" || { bad "ASM disk $label was created, but it is not visible"; return 1; }
  record_label "$label" "$part"
  journal ASMLABEL "$label" "on $part"
  say "Created ASM disk $label on $part"
}

next_label() {
  # $1 disk group, $2 labels already chosen in this run (space list): the next label that is free everywhere
  local dg=$1 i=1
  while ! asm_label_free "${dg}_$i" || grep -qs "^${dg}_$i|" "$(asm_disks_file)" || [[ " ${2:-} " == *" ${dg}_$i "* ]]; do i=$((i + 1)); done
  printf '%s_%s' "$dg" "$i"
}
asm_header_group() {
  # disk group name in the ASM disk header of label $1 (empty = no ASM header / not in a disk group)
  local d; d=$(label_device "$1"); [[ -n "$d" ]] || { printf '?'; return; }
  # kfdhdb starts at byte 32; its grpname is at +0x48 = byte 104 (dskname is at byte 72)
  dd if="$d" bs=1 skip=104 count=32 2>/dev/null | tr -d '\0 ' | tr -cd 'A-Za-z0-9_$#'
}
asm_group_mounted_here() { use_grid && grid_sw_ok && sql_asm "select name from v\$asm_diskgroup where state in ('MOUNTED','CONNECTED');" && grep -qix -- "$1" <<< "$SQL_OUT"; }

d_2_13() {
  local fd dg i min have total pick n sel=() used=" " def nums l
  # 1) disks that exist but were not made by this script: use them only when you say so
  for dg in $(asm_dgs); do
    l=$(asm_foreign "$dg")
    [[ -n "$l" ]] || continue
    local ok_l="" refused="" reflab="" g
    while IFS= read -r i; do
      [[ -n "$i" ]] || continue
      # a disk that already belongs to a disk group is used only when THIS server's ASM has that group
      # mounted (a disk of the primary, seen here through a shared SAN, must never be taken)
      g=$(asm_header_group "$i")
      if [[ "$g" == "?" ]]; then refused+=$'\n'"  $i: device not found"
      elif [[ -n "$g" ]] && ! asm_group_mounted_here "$g"; then refused+=$'\n'"  $i: in disk group $g, which is not mounted here"; reflab+=" $i"
      else ok_l+=" $i"; fi
    done <<< "$l"
    if [[ -n "$refused" ]]; then
      warn "These existing ASM disks are not used:$refused"$'\n'"They may belong to another server, for example the primary."
      install -d -m 700 "$STATE_DIR"; for i in $reflab; do printf '%s|-\n' "$i" >> "$(asm_disks_file)"; done; chmod 600 "$(asm_disks_file)"
    fi
    [[ -n "$ok_l" ]] || continue
    say "Answer y only if no other database uses$ok_l."
    if confirm "Use the existing ASM disks$ok_l for +$dg"; then
      for i in $ok_l; do record_label "$i" "$(label_device "$i")"; done
    else
      for i in $ok_l; do install -d -m 700 "$STATE_DIR"; printf '%s|-\n' "$i" >> "$(asm_disks_file)"; done; chmod 600 "$(asm_disks_file)"
      say "Not used:$ok_l. This answer is remembered."
      say "New disks are chosen for +$dg instead."
    fi
  done
  # 2) new disks for every disk group that has none or too little space
  fd=$(free_disks)
  local -a disks=(); [[ -n "$fd" ]] && mapfile -t disks <<< "$fd"
  for dg in $(asm_dgs); do
    min=$(dg_min_mb "$dg"); have=$(dg_have_mb "$dg")
    [[ -n "$(asm_labels "$dg")" && $have -ge $min ]] && continue
    local need_more=$(( min - have ))
    [[ ${#disks[@]} -gt 0 ]] || { bad "No empty disk on this server for +$dg. Nothing was erased."$'\n'"Add disks to this server, then try again."; return 1; }
    if [[ $have -gt 0 ]]; then say "+$dg needs at least $(human_mb "$min"). Its disks have $(human_mb "$have"). Empty disks:"
    else say "+$dg needs at least $(human_mb "$min"). Empty disks:"; fi
    def=""
    for i in "${!disks[@]}"; do
      if [[ "$used" == *" ${disks[$i]%% *} "* ]]; then say "  $((i + 1))) ${disks[$i]%% *}  $(human_mb "${disks[$i]##* }")   (chosen)"
      else say "  $((i + 1))) ${disks[$i]%% *}  $(human_mb "${disks[$i]##* }")"; [[ -z "$def" ]] && def=$((i + 1)); fi
    done
    [[ -n "$def" ]] || { bad "Not enough empty disks for +$dg. Nothing was erased."; return 1; }
    local left=0
    for i in "${!disks[@]}"; do [[ "$used" == *" ${disks[$i]%% *} "* ]] || left=$((left + ${disks[$i]##* })); done
    if [[ $left -lt $need_more ]]; then
      bad "The empty disks left have $(human_mb "$left") in total, but +$dg needs $(human_mb "$need_more") more."$'\n'"Add disks to this server. Nothing was erased."
      return 1
    fi
    while true; do
      ask_default "Disk numbers for +$dg, separated by spaces (q = stop, nothing is erased)" "$def"
      [[ "${ANSWER,,}" == "q" ]] && { say "Stopped. Nothing was erased."; return 3; }
      nums=" "; total=0; pick=""
      local -a picks=(); read -ra picks <<< "$ANSWER"
      for n in "${picks[@]}"; do
        if ! [[ "$n" =~ ^[0-9]{1,3}$ ]] || (( 10#$n < 1 || 10#$n > ${#disks[@]} )); then pick="bad"; say "Not a disk number: $n"; break; fi
        n=$((10#$n))
        [[ "$nums" == *" $n "* ]] && continue
        [[ "$used" == *" ${disks[$((n - 1))]%% *} "* ]] && { pick="bad"; say "${disks[$((n - 1))]%% *} is already chosen"; break; }
        nums+="$n "; total=$((total + ${disks[$((n - 1))]##* }))
      done
      [[ "$pick" == "bad" || "$nums" == " " ]] && continue
      if [[ $total -lt $need_more ]]; then bad "These disks have $total MB, but +$dg needs $need_more MB more. Choose more or bigger disks."; continue; fi
      break
    done
    for n in $nums; do
      local lab chosen="" x; for x in "${sel[@]+"${sel[@]}"}"; do chosen+=" ${x%%|*}"; done
      lab=$(next_label "$dg" "$chosen")
      sel+=("$lab|${disks[$((n - 1))]%% *}"); used+="${disks[$((n - 1))]%% *} "
    done
  done
  [[ ${#sel[@]} -gt 0 ]] || return 0
  local p d
  # validate and confirm ALL chosen disks before anything is erased
  for p in "${sel[@]}"; do
    d=${p#*|}
    disk_is_free "$d" || { bad "$d cannot be used: $DISK_WHY. Nothing was erased."; return 1; }
    # online logs with 4096-byte blocks need disks with 4096-byte physical sectors (else ORA-01378 for the standby logs)
    local sb="/sys/block/$(basename "$(readlink -f "$d")")/queue" pbs lbs
    pbs=$(cat "$sb/physical_block_size" 2>/dev/null); lbs=$(cat "$sb/logical_block_size" 2>/dev/null)
    if [[ "${PRIMARY_REDO_BS:-512}" == "4096" ]]; then
      [[ -n "$pbs" && "$pbs" -lt 4096 ]] && { bad "The redo logs of the primary use 4096-byte blocks, but $d has $pbs-byte sectors."$'\n'"The standby logs could not be created (ORA-01378). Use disks with 4K sectors."$'\n'"Nothing was erased."; return 1; }
    else
      [[ -n "$lbs" && "$lbs" -ge 4096 ]] && { bad "$d is a 4K-native disk, but the redo logs of the primary use 512-byte blocks."$'\n'"The standby and online logs could not be created (ORA-01378)."$'\n'"Use disks with 512-byte or 512e sectors. Nothing was erased."; return 1; }
    fi
  done
  for p in "${sel[@]}"; do
    d=${p#*|}
    confirm_word "ALL data on $d ($(lsblk -dn -o SIZE "$d" | tr -d ' ')) will be erased to make ASM disk ${p%%|*}." "$d" \
      || { say "Not confirmed. Nothing was erased."; return 3; }
  done
  for p in "${sel[@]}"; do make_asm_disk "${p%%|*}" "${p#*|}" || return 1; done
}

# ---- 2.14 database folders (file system storage) ----
fs_need_lines() {
  # "dir|MB" for every file system location (database files; recovery area: what a standby needs)
  local d mb
  while IFS= read -r d; do
    mb=$(loc_mb "$d")
    [[ "$d" == "$FRA_LOC" ]] && mb=$((mb + $(fra_need_mb)))
    printf '%s|%s\n' "$d" "$mb"
  done < <(fs_dirs)
}
FS_TODO=()
c_2_14() {
  [[ -n "$(fs_dirs)" ]] || { NOW="Not needed (all database files are in ASM)"; return 0; }
  users_ok || { NOW="The users do not exist yet (step 2.2)"; return 2; }
  local d mb mnt free used missing=() short="" report="" notmine=""
  declare -A need_by_mnt=() free_by_mnt=()
  while IFS='|' read -r d mb; do
    mnt=$(mnt_of "$d"); [[ -n "$mnt" ]] || { NOW="Cannot read the free space of $d (df failed)"; return 2; }
    free=$(free_mb_of "$d")
    # files that are already there (an earlier duplicate) already use their space
    used=0; [[ -d "$d" ]] && used=$(du -smx -- "$d" 2>/dev/null | awk '{print $1+0}'); num "$used" || used=0
    mb=$(( mb > used ? mb - used : 0 ))
    need_by_mnt[$mnt]=$(( ${need_by_mnt[$mnt]:-0} + mb ))
    free_by_mnt[$mnt]=$free
    if [[ -d "$d" && "$(stat -c %U "$d")" == "$ORACLE_USER" ]]; then report+="$d exists (on $mnt)"$'\n'
    elif [[ -d "$d" ]] && ! dir_empty "$d"; then notmine+="$d is owned by $(stat -c %U "$d") and is not empty"$'\n'
    else missing+=("$d"); report+="$d is missing (on $mnt)"$'\n'; fi
  done < <(fs_need_lines)
  if [[ -n "$notmine" ]]; then
    NOW="${notmine%$'\n'}"; MANUAL_HOW="root  ->  shell Check the files first (ls -la)."
    PLAN="$(while IFS= read -r d; do [[ -n "$d" ]] && printf 'chown %s:%s %s\n' "$ORACLE_USER" "$INSTALL_GROUP" "${d%% is owned*}"; done <<< "$notmine")"
    return 2
  fi
  for mnt in "${!need_by_mnt[@]}"; do
    local want=$(( ${need_by_mnt[$mnt]} * 11 / 10 ))
    [[ ${free_by_mnt[$mnt]} -ge $want ]] || short+="File system $mnt has $(human_mb "${free_by_mnt[$mnt]}") free, but needs about $(human_mb "$want")"$'\n'
  done
  if [[ -n "$short" ]]; then
    NOW="${report}${short%$'\n'}"
    MANUAL_HOW="root  ->  shell"
    PLAN="-- Give the database folders enough space, for example a new disk with a new file system.
-- Find an empty disk. Below it is called /dev/<empty disk>.
lsblk
mkfs.xfs /dev/<empty disk>
mkdir -p <mount point, for example $(fs_dirs | head -n 1 | cut -d/ -f1-2)>
echo \"UUID=\$(blkid -s UUID -o value /dev/<empty disk>)  <mount point>  xfs  defaults  0 0\" >> /etc/fstab
mount <mount point>
-- Then answer r. The paths must stay the same as on the primary."
    return 2
  fi
  if [[ ${#missing[@]} -eq 0 ]]; then NOW="${report%$'\n'}"; return 0; fi
  FS_TODO=("${missing[@]}")
  NOW="${report%$'\n'}"
  PLAN="Create these folders (owner $ORACLE_USER:$INSTALL_GROUP, mode 775):"
  for d in "${missing[@]}"; do PLAN+=$'\n'"  $d"; done
  return 1
}
d_2_14() { local d; for d in "${FS_TODO[@]}"; do make_dir "$d" "$ORACLE_USER" || return 1; done; }

# ---- 2.15 storage is not shared with the primary ----
STORAGE_SHARED=""; STORAGE_KEYS=()
disk_ids() {
  # ids of the physical disks below a block device, from lsblk -P output on stdin: W:<wwn> and S:<serial>.
  # Serial numbers that many disks share (QEMU default QM00001, all zeros) are left out.
  grep 'TYPE="disk"' | grep -oE '(WWN|SERIAL)="[^"]+"' | sed -E 's/^WWN="/W:/; s/^SERIAL="/S:/; s/"$//' \
    | grep -vE '^S:(QM[0-9]{5}|0+)$' | sort -u
  return 0
}
storage_clone_file() { printf '%s/storage_clone_ok' "$STATE_DIR"; }
mnt_uuid() { local u=""; [[ "$1" == *" "* ]] && u=${1##* }; [[ "$u" =~ ^[0-9A-Fa-f-]{8,}$ ]] && printf '%s' "$u"; return 0; }
P_MNT_UUIDS=""; P_MNT_COMPLETE=0; P_MNT_RAW=""
read_primary_mounts() {
  # Every file system mounted on the primary from a device, with its UUID and the ids of the disks below it
  # (read-only: findmnt, lsblk; run with sh, whatever the login shell of the user is). Read again at every test.
  # P_MNT_COMPLETE=1 only when every such file system shows a UUID (else a UUID that is not listed proves nothing).
  P_MNT_UUIDS=""; P_MNT_COMPLETE=0; P_MNT_RAW=""
  prim_probe mounts || return 1
  grep -q '^__DG_MOUNTS_END__$' <<< "$RUN_OUT" || return 1
  P_MNT_RAW=$RUN_OUT
  P_MNT_UUIDS=$(awk -F'|' '$1 == "M" && $3 ~ /^[0-9A-Fa-f-]+$/ && length($3) >= 8 { print toupper($3) }' <<< "$RUN_OUT" | sort -u)
  awk -F'|' '$1 == "M" && !($3 ~ /^[0-9A-Fa-f-]+$/ && length($3) >= 8) { bad = 1 } END { exit bad }' <<< "$RUN_OUT" && P_MNT_COMPLETE=1
  return 0
}
primary_ids_of_uuid() {
  # the disk ids below the primary file system(s) with UUID $1
  awk -F'|' -v u="${1^^}" '$1 == "M" { on = (toupper($3) == u); next } on' <<< "$P_MNT_RAW" | disk_ids
}
primary_ids_all() { grep -v '^M|' <<< "$P_MNT_RAW" | disk_ids; }
STORAGE_NET_DONE=" "
storage_not_shared() {
  # Proves for every database folder here that it is not the storage of the primary (same paths on both
  # servers). Only read-only probes run on the primary: test, findmnt, lsblk.
  #   shared:      a network file system from the same source; the test file is seen on primary;
  #                the same file system UUID on the same disk (WWN) as on primary
  #   not shared:  network file system: the test file is not seen after 65 s and the sources differ;
  #                other file systems: the UUID here is known, the primary shows the UUID of every file system
  #                it mounts, and this UUID is not one of them (and no disk of this folder is a disk of the primary)
  #   else not proven: the duplicate is refused until the user confirms exactly that disk.
  # rc 0 = not shared, 1 = shared, 2 = not proven. A folder found shared outranks one that is not proven.
  local d m fst ans lid pid lsrc psrc luuid net lids wcom key ok why plan np=0 info2="" plan2=""
  STORAGE_SHARED=""; STORAGE_INFO=""; STORAGE_PLAN=""; STORAGE_KEYS=()
  read_primary_mounts || { STORAGE_INFO="Cannot read the file systems mounted on the primary (findmnt and lsblk over ssh)"; return 2; }
  for d in $(fs_dirs); do
    ok=0; why=""; plan=""; key=""
    [[ -d "$d" ]] || { [[ -z "$info2" ]] && info2="Folder $d does not exist yet (step 2.14)"; np=1; continue; }
    fst=$(df --output=fstype -- "$d" 2>/dev/null | tail -n 1 | tr -d ' ')
    net=0; case "$fst" in nfs*|cifs|smb*|fuse.*|ceph|glusterfs|9p|lustre|afs) net=1 ;; esac
    # this server: device or export (without a [subvolume] part), file system UUID, disk ids
    lid=$(findmnt -n -o SOURCE,UUID --target "$d" 2>/dev/null | head -n 1); lsrc=${lid%% *}; lsrc=${lsrc%%\[*}
    luuid=$(mnt_uuid "$lid")
    [[ -z "$luuid" && "$lsrc" == /dev/* ]] && { luuid=$(blkid -s UUID -o value -- "$lsrc" 2>/dev/null | head -n 1); [[ "$luuid" =~ ^[0-9A-Fa-f-]{8,}$ ]] || luuid=""; }
    lids=""; [[ "$lsrc" == /dev/* ]] && lids=$(lsblk -nsP -o TYPE,WWN,SERIAL "$lsrc" 2>/dev/null | disk_ids)
    # the primary, same path
    ans=""; prim_probe canlook "$d" && ans=$(head -n 1 <<< "$RUN_OUT")
    [[ "$ans" == "YES" || "$ans" == "NO" ]] || { [[ -z "$info2" ]] && info2="Cannot test $d on the primary (no answer over ssh)"; np=1; continue; }
    pid=""; prim_probe fsid "$d" && pid=$(head -n 1 <<< "$RUN_OUT"); psrc=${pid%% *}; psrc=${psrc%%\[*}
    # 1) a network file system mounted from the same source on both servers
    if [[ $net -eq 1 && -n "$lsrc" && "$lsrc" != /dev/* && "$lsrc" == "$psrc" ]]; then STORAGE_SHARED+="$d ($fst, same source $lsrc on both servers) "; continue; fi
    # 2) a test file written here (as the database owner) must not be visible on the primary
    if [[ "$ans" == "YES" ]]; then
      m="$d/.dg_standby_test_$(hostname -s)_${RUN_ID}_$$"
      CLEANUP_FILES+=("$m")
      runuser -u "$ORACLE_USER" -- sh -c 'umask 077; : > "$1"' sh "$m" 2>/dev/null || ( umask 077; : > "$m" ) 2>/dev/null \
        || { [[ -z "$info2" ]] && info2="Cannot write a test file in $d"; np=1; continue; }
      ans=""; prim_probe exists "$m" && ans=$(head -n 1 <<< "$RUN_OUT")
      if [[ "$ans" == "NO" && $net -eq 1 && "$STORAGE_NET_DONE" != *" $d|$lsrc "* ]]; then
        # a network file system client may cache folder contents for up to a minute: ask again after that (once per run)
        say "$d is $fst. Testing again in 65 seconds, as the primary may cache the folder contents ..."
        sleep 65
        ans=""; prim_probe exists "$m" && ans=$(head -n 1 <<< "$RUN_OUT")
        [[ "$ans" == "NO" ]] && STORAGE_NET_DONE+="$d|$lsrc "
      fi
      rm -f -- "$m"
      case "$ans" in
        YES) STORAGE_SHARED+="$d ($fst, the test file is seen on the primary) "; continue ;;
        NO)  ans=SEEN_NO ;;
        *)   [[ -z "$info2" ]] && info2="Cannot test $d on the primary (no answer over ssh)"; np=1; continue ;;
      esac
    fi
    # 3) the same file system UUID as a file system of the primary (at any path)
    if [[ -n "$luuid" ]] && grep -qxF -- "${luuid^^}" <<< "$P_MNT_UUIDS"; then
      wcom=$(comm -12 <(grep '^W:' <<< "$lids") <(primary_ids_of_uuid "$luuid" | grep '^W:') | sed 's/^W://' | paste -sd' ' -)
      if [[ -n "$wcom" ]]; then STORAGE_SHARED+="$d (file system $luuid on the same disk $wcom as on the primary) "; continue; fi
      key=$luuid
      why="$d has the same file system UUID ($luuid) as a file system of the primary."$'\n'"It is a copy of the primary's disk, or the same disk mounted on both servers."
    elif [[ -n "$lids" ]] && wcom=$(comm -12 <(grep '^W:' <<< "$lids") <(primary_ids_all | grep '^W:') | sed 's/^W://' | paste -sd' ' -) && [[ -n "$wcom" ]]; then
      # 4) a disk of this folder is a disk under a file system of the primary (another partition, or a copied disk id)
      key="disks:$(paste -sd, - <<< "$lids")"
      why="A disk of $d (WWN $wcom) is also under a file system of the primary."$'\n'"It is another partition of the same disk, or a virtual disk copied with its id."
    elif [[ $net -eq 1 ]]; then
      # 5) network file system: only the test file can prove it
      if [[ "$ans" == "SEEN_NO" ]]; then ok=1; STORAGE_INFO+="$d: $fst, the test file is not seen on the primary after 65 seconds ($lsrc here, ${psrc:-?} there)"$'\n'
      else
        why="$d ($fst): the user $PRIMARY_SSH_USER cannot read this folder on the primary, so the test file cannot be used."$'\n'"It cannot be proven that this is not the storage of the primary."
        plan="-- For $d: run the script again with the owner of the database files on the primary:
$SELF --user $ORACLE_USER"
      fi
    elif [[ -n "$luuid" && $P_MNT_COMPLETE -eq 1 ]]; then
      # 6) the primary shows every file system it mounts, and this one is not among them
      ok=1; STORAGE_INFO+="$d: ${fst:-?}, file system $luuid is not mounted on the primary$([[ "$ans" == "SEEN_NO" ]] && printf '; the test file is not seen there')"$'\n'
    else
      if [[ -n "$luuid" ]]; then key=$luuid; elif [[ -n "$lids" ]]; then key="disks:$(paste -sd, - <<< "$lids")"; else key="device:$lsrc"; fi
      if [[ -z "$luuid" ]]; then why="$d: the file system UUID on this server cannot be read."
      else why="$d: the primary does not show the UUID of every file system it mounts."$'\n'"The user $PRIMARY_SSH_USER may not be allowed to read them."; fi
      why+=$'\n'"It cannot be proven that this is not the storage of the primary."
    fi
    [[ $ok -eq 1 ]] && continue
    # not proven: a confirmation for exactly this disk counts
    if [[ -n "$key" && -f "$(storage_clone_file)" ]] && grep -qxF -- "$key" "$(storage_clone_file)"; then
      STORAGE_INFO+="$d: ${fst:-?}, you confirmed it is a separate disk of this server ($key)"$'\n'; continue
    fi
    if [[ -n "$key" ]]; then
      plan="-- $d: do NOT change or format anything until you know which disk this is.
-- Compare the disks on both servers. On this server:
lsblk -s -o NAME,TYPE,WWN,SERIAL,SIZE \$(findmnt -n -o SOURCE --target $d)
-- On the primary:
lsblk -o NAME,TYPE,WWN,SERIAL,SIZE,MOUNTPOINT
-- Or check in the storage or virtualization console whether it is the same volume.${plan:+
$plan}
-- If it is a separate disk of this server, the script asks you to confirm it next."
      STORAGE_KEYS+=("$d|$key")
    fi
    [[ -z "$info2" ]] && { info2=$why; plan2=$plan; }
    np=1
  done
  STORAGE_INFO=${STORAGE_INFO%$'\n'}
  [[ -n "$STORAGE_SHARED" ]] && return 1
  if [[ $np -eq 1 ]]; then STORAGE_INFO=$info2; STORAGE_PLAN=$plan2; return 2; fi
  return 0
}
c_2_15() {
  [[ -n "$(fs_dirs)" ]] || { NOW="Not needed: there are no database folders. ASM disks are checked in step 2.13."; return 0; }
  [[ "$(marker_kind 2>/dev/null)" == "duplicate" ]] && { NOW="The RMAN copy already ran. The storage was checked before it started."; return 0; }
  if [[ "$MODE" == "check" ]]; then NOW="Tested only in a normal run, because it writes a small test file"; return 2; fi
  need_ssh || return 2
  local rc=0; storage_not_shared || rc=$?
  if [[ $rc -eq 2 && ${#STORAGE_KEYS[@]} -gt 0 ]]; then
    # not proven by the script: you compare the disks, then confirm each one here (your answer is kept)
    NOW=$STORAGE_INFO
    PLAN="Compare the disks first:"$'\n'"$STORAGE_PLAN"
    KIND_NOW=ask; return 1
  fi
  if [[ $rc -eq 2 ]]; then NOW=$STORAGE_INFO; [[ -n "$STORAGE_PLAN" ]] && PLAN=$STORAGE_PLAN; return 2; fi
  if [[ $rc -eq 0 ]]; then NOW="Each database folder is on storage of this server only:"$'\n'"$STORAGE_INFO"; return 0; fi
  NOW="DANGER: these folders are the SAME storage as on the primary: $STORAGE_SHARED"$'\n'"The RMAN copy would overwrite the files of the primary database."
  KIND_NOW=manual; MANUAL_HOW="root  ->  storage and mount"
  PLAN="-- Give this server its own storage for these paths.
-- Do not use the NFS export or SAN volume of the primary.
-- Mount it at the same path, then answer r.
-- The RMAN copy (step 8.2) is refused until this is fixed."
  :
  return 1
}

d_2_15() {
  # your confirmation for each disk the script could not prove (written only after you typed it)
  local e d key
  for e in "${STORAGE_KEYS[@]+"${STORAGE_KEYS[@]}"}"; do
    d=${e%%|*}; key=${e#*|}
    confirm_word "Is $d ($key) on a separate disk of this server, NOT the storage of the primary?" "SEPARATE" || { say "Not confirmed. The RMAN copy stays refused for $d."; return 3; }
    install -d -m 700 "$STATE_DIR"; printf '%s\n' "$key" >> "$(storage_clone_file)"; chmod 600 "$(storage_clone_file)"
    _log CHANGE "storage confirmed by the admin as separate: $d ($key)"
    journal CONFIRM "storage_clone_ok" "by hand: remove the line $key from $(storage_clone_file)   (your confirmation that $d is a separate disk)"
  done
  return 0
}

phase_2() {
  phase_header 2 "Prepare this server"
  run_step 2.1  auto    "Groups (same names and ids as primary)" c_2_1 d_2_1
  run_step 2.2  auto    "Users (same ids as primary)" c_2_2 d_2_2
  run_step 2.3  auto    "Required packages" c_2_3 d_2_3
  run_step 2.4  auto    "Limits for the Oracle owners" c_2_4 d_2_4
  run_step 2.5  auto    "Software folders (same paths as primary)" c_2_5 d_2_5
  run_step 2.6  auto    "Host names on this server" c_2_6 d_2_6
  run_step 2.7  primary "Primary resolves the standby host name" c_2_7
  run_step 2.8  check   "Network to the primary listener" c_2_8
  run_step 2.9  auto    "Firewall on this server" c_2_9 d_2_9
  run_step 2.10 auto    "Time synchronization" c_2_10 d_2_10
  run_step 2.11 auto    "Environment (.bash_profile) of the Oracle users" c_2_11 d_2_11
  run_step 2.12 auto    "ASM disk method (ASMLib or udev)" c_2_12 d_2_12
  run_step 2.13 auto    "ASM disks" c_2_13 d_2_13
  run_step 2.14 auto    "Database folders and free space (file system)" c_2_14 d_2_14
  run_step 2.15 check   "Database folders are not shared with the primary" c_2_15 d_2_15
  build_envs_if_possible
}

#------------------------------------------------------------------------------
# PHASE 3  Oracle software on the standby
#   Grid (Oracle Restart) only when the primary uses ASM. Database software always.
#   Works with: image media (12.2+ Grid, 18c+ DB), staged media (12.1 Grid, 12.x DB,
#   may be several zip files) and gold images made on the primary (same patches).
#   Response files are made from the template shipped in the media.
#------------------------------------------------------------------------------
GSTATE=""; GSTATE_OUT=""; DSTATE=""; DB_EDITION=""; DATA_FREE_MB=0

inventory_dir() {
  local loc=""
  [[ -f /etc/oraInst.loc ]] && loc=$(grep -E '^inventory_loc=' /etc/oraInst.loc | head -n 1 | cut -d= -f2-)
  printf '%s' "${loc:-$INVENTORY_DIR}"
}
in_inventory() {
  local inv; inv="$(inventory_dir)/ContentsXML/inventory.xml"
  [[ -f "$inv" ]] && grep -q "LOC=\"$1\"" "$inv" && ! grep -q "LOC=\"$1\"[^>]*REMOVED=\"T\"" "$inv"
}
grp_or() {
  # first group of the list that exists on this server
  local g
  for g in "$@"; do [[ -n "$g" ]] && getent group "$g" >/dev/null 2>&1 && { printf '%s' "$g"; return 0; }; done
  printf '%s' "$INSTALL_GROUP"
}

#------------------------------------------------------------------------------
# Media (installer zip files)
#------------------------------------------------------------------------------
ZIP_DIRS=(/stage /software /install /tmp /root /home /opt /u01 /mnt /media)
media_kind() {
  # $1 zip -> grid_image | grid_staged | db_image | db_staged | db_staged_part | grid_staged_part | other
  local l; l=$(unzip -Z1 "$1" 2>/dev/null)
  if grep -qx 'gridSetup.sh' <<< "$l"; then printf 'grid_image'
  elif grep -qx 'grid/runInstaller' <<< "$l"; then printf 'grid_staged'
  elif grep -qx 'runInstaller' <<< "$l" && grep -q '^install/response/' <<< "$l"; then printf 'db_image'
  elif grep -qx 'database/runInstaller' <<< "$l"; then printf 'db_staged'
  elif grep -q '^database/stage/' <<< "$l"; then printf 'db_staged_part'
  elif grep -q '^grid/stage/' <<< "$l"; then printf 'grid_staged_part'
  else printf 'other'; fi
}
media_major() {
  # release from the Oracle file name: 12102 -> 12.1, 12201 -> 12.2, 193000 -> 19; for a 12.x zip from
  # edelivery (V12345-01.zip) from products.xml inside it; empty if unknown (gold image)
  local b; b=$(basename "$1")
  if [[ "$b" =~ (LINUX\.X64|linuxx64|linuxamd64)_([0-9]{5,6}) ]]; then
    local d=${BASH_REMATCH[2]}
    if [[ "$d" == 12* ]]; then printf '12.%s' "${d:2:1}"; else printf '%s' "${d:0:2}"; fi
    return 0
  fi
  local px v=""; px=$(unzip -Z1 "$1" 2>/dev/null | grep -m1 -E '^(database|grid)/stage/products\.xml$')
  if [[ -n "$px" ]]; then
    # OUI writes the release as VER="..." (older files VERSION="...")
    v=$(unzip -p "$1" "$px" 2>/dev/null | grep -oE 'NAME="oracle\.(server|crs)" VER(SION)?="1[0-9]\.[0-9]+' | head -n 1 | grep -oE '[0-9]+\.[0-9]+$')
    # older files: the first release attribute of the file
    [[ -n "$v" ]] || v=$(unzip -p "$1" "$px" 2>/dev/null | grep -oE ' VER(SION)?="1[0-9]\.[0-9]+' | head -n 1 | grep -oE '[0-9]+\.[0-9]+$')
  else
    # an image zip (also from edelivery, V982063-01.zip) has its inventory inside
    # VER directly after NAME (the same tag also has REP_VER, ACT_INST_VER, DEINST_VER)
    v=$(unzip -p "$1" inventory/ContentsXML/comps.xml 2>/dev/null | grep -oE 'NAME="oracle\.(server|crs)" VER="[0-9]+\.[0-9]+' | head -n 1 | grep -oE '[0-9]+\.[0-9]+$')
  fi
  case "$v" in 12.*) printf '%s' "$v" ;; 1[89].*|2[0-9].*) printf '%s' "${v%%.*}" ;; esac
  return 0
}
media_is_gold() {
  # a gold image made on the primary: neither an Oracle download name (LINUX.X64_193000_...) nor an edelivery name (V982063-01.zip)
  local b; b=$(basename "$1")
  [[ ! "$b" =~ (LINUX\.X64|linuxx64|linuxamd64)_[0-9]{5,6} && ! "$b" =~ ^[Vp][0-9]+(-[0-9]+|_.*)?\.zip$ ]]
}
want_rel() {
  # release the media must have: $1 = db (default) or grid (Grid may be newer than the database)
  if [[ "${1:-db}" == "grid" && -n "$GRID_REL" ]]; then printf '%s' "$GRID_REL"; return; fi
  if [[ "$DB_MAJOR" == "12" ]]; then printf '%s' "${PRIMARY_VERSION:0:4}"; else printf '%s' "$DB_MAJOR"; fi
}
rel_major() { printf '%s' "${1%%.*}"; }
media_trusted() {
  # an installer runs as oracle/grid and its root.sh as root: only files that root, oracle or grid own
  # and that nobody else can change are used
  local f=$1 u m
  u=$(stat -c '%U' -- "$f" 2>/dev/null); m=$(stat -c '%a' -- "$f" 2>/dev/null)
  [[ "$u" == "root" || "$u" == "$ORACLE_USER" || "$u" == "$GRID_USER" ]] || return 1
  [[ "$m" =~ ^[0-7]+$ ]] || return 1
  (( (8#${m: -2:1} & 2) == 0 && (8#${m: -1} & 2) == 0 ))
}
MEDIA_SCAN=""; MEDIA_REFUSED=""
scan_media() {
  # MEDIA_SCAN lines: kind|release|size|path   (only usable zip files)
  local d f k
  MEDIA_SCAN=""; MEDIA_REFUSED=""
  for d in "${ZIP_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -f "$f" && ! -L "$f" ]] && v_path "$f" || continue
      k=$(media_kind "$f"); [[ "$k" == "other" ]] && continue
      if ! media_trusted "$f"; then MEDIA_REFUSED+="$f (owner $(stat -c '%U' -- "$f"), mode $(stat -c '%a' -- "$f"))"$'\n'; continue; fi
      MEDIA_SCAN+="$k|$(media_major "$f")|$(du -h "$f" | cut -f1)|$f"$'\n'
    done < <(find "$d" -maxdepth 3 -type f -name '*.zip' 2>/dev/null)
  done
  MEDIA_SCAN=$(sort -u <<< "$MEDIA_SCAN" | grep -v '^$')
}
media_desc() { local f; IFS=',' read -ra _md <<< "$1"; for f in "${_md[@]}"; do printf '%s (%s, owner %s)  ' "$f" "$(du -h -- "$f" | cut -f1)" "$(stat -c '%U' -- "$f")"; done; }
pick_media() {
  # $1 = grid | db : prints the comma list of files for one installation (staged media may be 2 files)
  local want=$1 k mj f img="" stg="" parts="" allparts="" wr; wr=$(want_rel "$want")
  local imgu=""
  while IFS='|' read -r k mj _ f; do
    # the second zip of a staged pair has no release of its own: it is matched to the first by its name below
    [[ "$k" == "${want}_staged_part" ]] && { allparts+="$f"$'\n'; continue; }
    [[ -n "$mj" && "$mj" != "$wr" ]] && continue
    [[ -z "$mj" && "$k" == *_staged ]] && continue
    case "$k" in
      # an image whose release could not be read (a gold image) is only a last choice
      "${want}_image")  if [[ -n "$mj" ]]; then [[ -z "$img" ]] && img=$f; else [[ -z "$imgu" ]] && imgu=$f; fi ;;
      "${want}_staged") [[ -z "$stg" ]] && stg=$f ;;
    esac
  done <<< "$MEDIA_SCAN"
  # 12.1 databases exist only as staged media; elsewhere an unknown-release image is used when nothing better is there
  [[ -z "$img" && -z "$stg" && "$wr" != "12.1" ]] && img=$imgu
  if [[ -n "$stg" ]]; then
    local pre=${stg%_[0-9]of[0-9].zip}
    while IFS= read -r f; do [[ -n "$f" && "${f%_[0-9]of[0-9].zip}" == "$pre" && "$f" != "$stg" ]] && parts+=",$f"; done <<< "$allparts"
  fi
  if [[ -n "$img" ]]; then printf '%s' "$img"
  elif [[ -n "$stg" ]]; then
    # the first zip of a pair without its second one cannot be installed
    if [[ "$stg" == *_1of[2-9].zip && -z "$parts" ]]; then printf 'MISSING:%s' "${stg%_1of*}_2of${stg##*_1of}"; return 0; fi
    printf '%s%s' "$stg" "$parts"
  fi
}
media_ok() {
  # $1 comma list -> every file exists and may be used
  local f; IFS=',' read -ra _mf <<< "$1"
  [[ ${#_mf[@]} -gt 0 ]] || return 1
  for f in "${_mf[@]}"; do [[ -f "$f" ]] && media_trusted "$f" || return 1; done
}
media_is_staged() { local k; k=$(media_kind "${1%%,*}"); [[ "$k" == *_staged ]]; }

# ---- 3.1 installer files ----
F_GRID=""; F_DB=""
c_3_1() {
  users_ok || { NOW="The Oracle users do not exist yet (step 2.2)"; return 2; }
  local need_g=0 need_d=0
  if use_grid; then grid_state; [[ "$GSTATE" == "NEED_UNZIP" ]] && need_g=1; fi
  db_state; [[ "$DSTATE" == "NEED_UNZIP" ]] && need_d=1
  if [[ $need_g -eq 0 && $need_d -eq 0 ]]; then NOW="Not needed: the software is already unpacked or installed"; return 0; fi
  if { [[ $need_g -eq 0 ]] || media_ok "$GRID_MEDIA"; } && { [[ $need_d -eq 0 ]] || media_ok "$DB_MEDIA"; }; then
    NOW="Installer files are known"
    [[ -n "$GRID_MEDIA" ]] && NOW+=$'\n'"Grid:      $GRID_MEDIA"
    [[ -n "$DB_MEDIA" ]] && NOW+=$'\n'"Database:  $DB_MEDIA"
    return 0
  fi
  scan_media
  F_GRID=""; F_DB=""
  [[ $need_g -eq 1 ]] && F_GRID=$(pick_media grid)
  [[ $need_d -eq 1 ]] && F_DB=$(pick_media db)
  # the first file of a staged pair without the second one
  local miss2=""
  [[ "$F_GRID" == MISSING:* ]] && { miss2+=" ${F_GRID#MISSING:}"; F_GRID=""; }
  [[ "$F_DB" == MISSING:* ]] && { miss2+=" ${F_DB#MISSING:}"; F_DB=""; }
  if [[ -n "$miss2" ]]; then
    NOW="The second installer file is missing:$miss2"$'\n'"It must be in the same folder as the first file."
    KIND_NOW=manual; MANUAL_HOW="root"; PLAN="-- Copy$miss2 next to the first file (owner root, mode 644). Then answer r."
    return 1
  fi
  if [[ ( $need_g -eq 1 && -z "$F_GRID" ) || ( $need_d -eq 1 && -z "$F_DB" ) ]]; then
    NOW="No installer files found for:$([[ $need_g -eq 1 && -z "$F_GRID" ]] && printf ' Grid %s' "$(want_rel grid)")$([[ $need_d -eq 1 && -z "$F_DB" ]] && printf ' database %s' "$(want_rel)")"
    NOW+=$'\n'"Searched in: ${ZIP_DIRS[*]}"
    [[ -n "$MEDIA_REFUSED" ]] && NOW+=$'\n'"Not used, because of their owner or mode:"$'\n'"${MEDIA_REFUSED%$'\n'}"
    KIND_NOW=manual; MANUAL_HOW="the user named on each line"; MANUAL_WHERE="Run on the PRIMARY ($PRIMARY_HOST) and on this server ($(hostname -s))"
    local wg=""; [[ $need_g -eq 1 ]] && wg=" and grid"
    PLAN="-- Copy the files to /stage on this server (owner root, mode 644). Then answer r."
    if [[ $DB_MAJOR -ge 18 ]]; then
      PLAN+=$'\n'"-- Use one of these:"
      PLAN+=$'\n'"-- A) A gold image of the primary home, with the same patches. On the primary:"
      [[ $need_d -eq 1 ]] && PLAN+=$'\n'"     as $ORACLE_USER:  mkdir -p /tmp/gold && $DB_HOME/runInstaller -silent -createGoldImage -destinationLocation /tmp/gold"
      [[ $need_g -eq 1 ]] && PLAN+=$'\n'"     as $GRID_USER:  mkdir -p /tmp/gold && $GRID_HOME/gridSetup.sh -silent -createGoldImage -destinationLocation /tmp/gold"
      PLAN+=$'\n'"   Then on this server, as root:  mkdir -p /stage && scp $PRIMARY_SSH_USER@$PRIMARY_IP:/tmp/gold/*.zip /stage/ && chmod 644 /stage/*.zip"
      PLAN+=$'\n'"-- B) The base installation files of release $DB_MAJOR."
      PLAN+=$'\n'"--    Step 3.11 then asks you to apply the same patches as on the primary."
    else
      PLAN+=$'\n'"-- The base installation files of release $(want_rel)."
      PLAN+=$'\n'"-- Step 3.11 then asks you to apply the same patches as on the primary."
    fi
    [[ $need_d -eq 1 ]] && PLAN+=$'\n'"     database: $(base_media_name db "$(want_rel)")"
    [[ $need_g -eq 1 ]] && PLAN+=$'\n'"     grid:     $(base_media_name grid "$(want_rel grid)")"
    return 1
  fi
  NOW="Installer files found"
  PLAN="Use these installer files:"
  [[ $need_g -eq 1 ]] && PLAN+=$'\n'"  Grid:      $(media_desc "$F_GRID")"
  [[ $need_d -eq 1 ]] && PLAN+=$'\n'"  Database:  $(media_desc "$F_DB")"
  PLAN+=$'\n'"Save them in $SETTINGS_FILE"
  USING="Files of another release than $(want_rel) are ignored."$'\n'"A gold image must come from the primary."
  # base media + a patched primary: say it now, not after two hours of installing
  local pp; pp=$(primary_patches "$DB_HOME" 2>/dev/null | head -n 3 | paste -sd' ' -)
  if [[ -n "$pp" && -z "$RU_DIR" ]] && media_is_gold "${F_DB:-${F_GRID:-}}"; then :   # gold image: same patches
  elif [[ -n "$pp" && -z "$RU_DIR" ]]; then
    USING+=$'\n'"The primary has patches ($pp ...). These base files do not have them."
    USING+=$'\n'"Step 3.11 then asks you to apply them by hand (opatchauto, about an hour)."
    USING+=$'\n'"Faster: unzip the primary's Release Update on this server now and set RU_DIR"
    USING+=$'\n'"and OPATCH_ZIP in the settings. The installer then applies it."
    USING+=$'\n'"To do that: answer q, run $SELF --settings and choose e."
  fi
  [[ -n "$MEDIA_REFUSED" ]] && USING+=$'\n'"Not used, because of owner or mode: ${MEDIA_REFUSED//$'\n'/ }"
  return 1
}
base_media_name() {
  # $1 db|grid, $2 release -> file names of the base installation media
  case "$1:$2" in
    db:12.1)   printf 'linuxamd64_12102_database_1of2.zip + linuxamd64_12102_database_2of2.zip' ;;
    grid:12.1) printf 'linuxamd64_12102_grid_1of2.zip + linuxamd64_12102_grid_2of2.zip' ;;
    db:12.2)   printf 'linuxx64_12201_database.zip' ;;
    grid:12.2) printf 'linuxx64_12201_grid_home.zip' ;;
    db:18|db:19|db:21) printf 'LINUX.X64_%s000_db_home.zip' "$2$([[ $2 == 18 ]] && printf 0 || printf 3)" ;;
    grid:18|grid:19|grid:21) printf 'LINUX.X64_%s000_grid_home.zip' "$2$([[ $2 == 18 ]] && printf 0 || printf 3)" ;;
    *) printf 'the %s %s home zip file from edelivery.oracle.com' "$2" "$1" ;;
  esac
}
d_3_1() { [[ -n "$F_GRID" ]] && GRID_MEDIA=$F_GRID; [[ -n "$F_DB" ]] && DB_MEDIA=$F_DB; save_settings; }

#------------------------------------------------------------------------------
# Response files: copy the template from the media, set only the keys it has
#------------------------------------------------------------------------------
RSP=""; RSP_MISSING=""
secure_rsp() {
  # $1 name. Sets RSP: a file in a new private folder (root-owned while it is written).
  local d
  d=$(mktemp -d /tmp/dg_rsp.XXXXXXXX) || return 1
  RSP="$d/$1"
  CLEANUP_FILES+=("$RSP")
}
finish_rsp() {
  local d; d=$(dirname "$1")
  chown "$2:$INSTALL_GROUP" "$1" && chmod 600 "$1" && chown "$2:$INSTALL_GROUP" "$d" && chmod 700 "$d"
}
remove_rsp() { [[ -n "$1" ]] && rm -f -- "$1" && rmdir -- "$(dirname "$1")" 2>/dev/null; return 0; }
rsp_set() {
  # $1 file, $2 value, $3.. key names (the first one that exists in the template is set).
  # Only a real (uncommented) key line is replaced: the Oracle templates carry commented example lines
  # ("#  oracle.install.asm.diskGroup.disks=/oracle/asm/disk1,...") before the real key, and a Java
  # properties reader takes the LAST line of a key, so a replaced example line would be ignored.
  local f=$1 v=$2 k; shift 2
  for k in "$@"; do
    # the same plain-text test as the replacement (no regular expression: the dots in the keys stay dots)
    if DG_K=$k awk 'BEGIN{k=ENVIRON["DG_K"]} { t=$0; sub(/^[[:space:]]*/, "", t); if (index(t, k "=") == 1) f=1 } END { exit !f }' "$f"; then
      local rc=0
      DG_K=$k DG_V=$v awk 'BEGIN{k=ENVIRON["DG_K"]; v=ENVIRON["DG_V"]}
        { t=$0; sub(/^[[:space:]]*/, "", t)
          if (index(t, k "=") == 1) { print k "=" v; next } print }' "$f" > "$f.new" && cat "$f.new" > "$f" || rc=1
      rm -f -- "$f.new"          # it may hold a password: never left behind
      return $rc
    fi
  done
  return 1
}
rsp_need() { rsp_set "$@" || RSP_MISSING+=" $3"; }       # a key the installation cannot work without
make_rsp() {
  # $1 template, $2 owner. Copies the template into a private file (RSP).
  local tpl=$1 name; name=$(basename "$tpl")
  RSP_TEMPLATE=$tpl
  [[ -f "$tpl" ]] || { bad "The response file template is not in the media: $tpl"; return 1; }
  secure_rsp "$name" || return 1
  ( umask 077; set -C; cat "$tpl" > "$RSP" ) || return 1
  RSP_MISSING=""
}
ver_lt() {
  # 0 when version $1 is lower than $2 (dotted numbers)
  [[ "$1" == "$2" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | head -n 1)" == "$1" ]]
}
RSP_TEMPLATE=""
rsp_review() {
  # after setting the keys: log them (passwords masked) and stop if a needed key is missing
  grep -vE '^[[:space:]]*(#|$)' "$RSP" | log_block "response file $RSP (template from the media)"
  local dup; dup=$(grep -vE '^[[:space:]]*(#|$)' "$RSP" | cut -d= -f1 | tr -d ' ' | sort | uniq -d | paste -sd' ' -)
  [[ -n "$dup" ]] && { bad "The response file has a key twice: $dup
The installer would read only the last one. Fix the template so that each key
is in it once, as an uncommented key= line: $RSP_TEMPLATE"; return 1; }
  if [[ -n "$RSP_MISSING" ]]; then
    bad "The response file template of this media lacks these keys:$RSP_MISSING"
    printf 'This media is newer or older than the script expects. Either install this software\nyourself (h shows the installer choices), or add the missing keys to the template\nas uncommented key= lines and run the step again. The template:\n  %s\n' "$RSP_TEMPLATE" | hint
    return 1
  fi
}

#------------------------------------------------------------------------------
# Installer helpers
#------------------------------------------------------------------------------
ask_asm_password() {
  [[ -n "$ASM_PW" ]] && return 0
  local tries=0 p1
  while [[ $tries -lt 3 ]]; do
    tries=$((tries + 1))
    if [[ -n "$ENV_ASM_PW" ]]; then SECRET=$ENV_ASM_PW; ENV_ASM_PW=""; say "Using the ASM password from DG_ASM_PASSWORD."
    else
      ask_secret "New ASM password for SYS and ASMSNMP (8-30 characters, upper and lower case, a digit)"
      p1=$SECRET
      ask_secret "Type it again"
      [[ "$p1" == "$SECRET" ]] || { SECRET=""; bad "The two passwords are not the same. Type them again."; continue; }
    fi
    p1=$SECRET; SECRET=""
    if [[ ${#p1} -lt 8 || ${#p1} -gt 30 || ! "$p1" =~ [A-Z] || ! "$p1" =~ [a-z] || ! "$p1" =~ [0-9] || "$p1" =~ [[:space:]\"\'@/\\\&\$\`] ]]; then
      bad "The password needs 8-30 characters, upper and lower case letters and a digit.
It must not contain a space, a quote, @ / & \$ \` or a backslash."; continue
    fi
    ASM_PW=$p1
    ok "ASM password set. It is kept only in memory and in a temporary response file."
    mask_pending
    return 0
  done
  return 1
}

INS08101_RETRIED=0
run_installer() {
  # $1 title, $2 runner (as_oracle | as_grid), $3 "ignore prerequisites" flag of this installer, rest = command.
  # Exit codes 0 and 6 are success. Offers one retry that ignores prerequisite failures.
  local title=$1 runner=$2 ign=$3; shift 3
  INS08101_RETRIED=0
  local who=oracle; [[ "$runner" == "as_grid" ]] && who=grid
  local out; out="$LOG_DIR/$(tr -c 'A-Za-z0-9\n' '_' <<< "$title" | tr -s '_' | tr -d '\n')_$RUN_ID.log"
  say "Starting the $title. It runs silently and takes several minutes."
  local rc=0 keep=$JOB_KEEP
  run_long "$title" "$out" "" "$who" "$@" < /dev/null || rc=$?
  if [[ $rc -eq 0 || $rc -eq 6 ]]; then [[ $rc -eq 6 ]] && warn "$title finished with warnings. Output: $out"; installer_done_record "$title"; return 0; fi
  bad "$title failed (exit code $rc)"
  grep -E 'INS-[0-9]+|PRVF-|PRVG-|PRCZ-|\[FATAL\]|\[WARNING\]|SEVERE' <<< "$RUN_OUT" | head -n 15 | hint
  grep -oE '(/[A-Za-z0-9_./-]+/(logs|cfgtoollogs)/[A-Za-z0-9_./-]+\.log)' <<< "$RUN_OUT" | sort -u | head -n 3 | sed 's/^/Installer log: /' | hint
  # the retries below never apply a Release Update a second time (the failed try may have applied it already)
  local -a args=("$@"); local home; home=$([[ "$who" == "grid" ]] && printf '%s' "$GRID_HOME" || printf '%s' "$DB_HOME")
  if ru_applied "$home"; then
    local -a a2=(); local i=0
    while [[ $i -lt ${#args[@]} ]]; do
      if [[ "${args[$i]}" == "-applyRU" || "${args[$i]}" == "-applyPSU" ]]; then i=$((i + 2)); continue; fi
      a2+=("${args[$i]}"); i=$((i + 1))
    done
    args=("${a2[@]}"); say "The Release Update is already in $home. A retry does not apply it again."
  fi
  if grep -q 'INS-08101' <<< "$RUN_OUT"; then
    local did; did=$([[ ${OS_MAJOR:-0} -ge 9 ]] && printf 'OL8' || printf 'OEL7.8')
    if [[ "${INS08101_RETRIED:-0}" -eq 0 ]] && [[ " ${ORA_ENV[*]} ${GRID_ENV[*]} " != *" CV_ASSUME_DISTID=$did "* ]]; then
      INS08101_RETRIED=1
      say "INS-08101: this installer does not know Oracle Linux $OS_MAJOR."
      say "Trying again with CV_ASSUME_DISTID=$did, the usual workaround."
      local -a saved_o=("${ORA_ENV[@]}") saved_g=("${GRID_ENV[@]}")
      ORA_ENV+=("CV_ASSUME_DISTID=$did"); GRID_ENV+=("CV_ASSUME_DISTID=$did")
      rc=0; JOB_KEEP=$keep
      run_long "$title (CV_ASSUME_DISTID=$did)" "${out%.log}_distid.log" "" "$who" "${args[@]}" < /dev/null || rc=$?
      if grep -q 'INS-08101' <<< "$RUN_OUT" || ! { [[ $rc -eq 0 || $rc -eq 6 ]] || grep -qE 'INS-13013|INS-13014|INS-13016|PRVF-|PRVG-' <<< "$RUN_OUT"; }; then
        # kept only when the installer got past the OS check (it finished, or it reached the prerequisite checks)
        ORA_ENV=("${saved_o[@]}"); GRID_ENV=("${saved_g[@]}")
      else
        # the OS check passed with it: kept for the retries below, for 3.4 and for later runs
        install -d -m 700 "$STATE_DIR"; printf '%s\n' "$did" > "$STATE_DIR/distid"; chmod 600 "$STATE_DIR/distid"
        _log INFO "CV_ASSUME_DISTID=$did kept (saved in $STATE_DIR/distid)"
      fi
      if [[ $rc -eq 0 || $rc -eq 6 ]]; then warn "$title finished, with CV_ASSUME_DISTID=$did."; installer_done_record "$title"; return 0; fi
      bad "$title failed again (exit code $rc)"; grep -E 'INS-[0-9]+|\[FATAL\]|SEVERE' <<< "$RUN_OUT" | head -n 10 | hint
    fi
    printf 'INS-08101: this installer does not know this Oracle Linux release.\nUse a newer Release Update: unzip it on this server, then set RU_DIR=<folder>\nand OPATCH_ZIP in the settings:\n  %s --settings   (choose e)\nThen run the script again.\n' "$SELF" | hint
  fi
  if [[ -n "$ign" ]] && grep -qE 'INS-13013|INS-13014|INS-13016|PRVF-|PRVG-' <<< "$RUN_OUT"; then
    printf 'Some prerequisite checks failed (see the lines above). Fix them if you can.\n' | hint
    if confirm_word "Retry and ignore the failed prerequisite checks" "IGNORE"; then
      rc=0
      JOB_KEEP=$keep
      ru_applied "$home" && { local -a a3=(); local j=0; while [[ $j -lt ${#args[@]} ]]; do if [[ "${args[$j]}" == "-applyRU" || "${args[$j]}" == "-applyPSU" ]]; then j=$((j + 2)); continue; fi; a3+=("${args[$j]}"); j=$((j + 1)); done; args=("${a3[@]}"); }
      run_long "$title (ignore prereq)" "${out%.log}_2.log" "" "$who" "${args[@]}" "$ign" < /dev/null || rc=$?
      if [[ $rc -eq 0 || $rc -eq 6 ]]; then warn "$title finished. Failed prerequisite checks were ignored."; installer_done_record "$title"; return 0; fi
      bad "$title failed again (exit code $rc)"
      grep -E 'INS-[0-9]+|\[FATAL\]|SEVERE' <<< "$RUN_OUT" | head -n 10 | hint
    fi
  fi
  return 1
}

ru_applied() {
  # 0 when a patch of RU_DIR (its numbered folders) is already registered in the home $1
  [[ -n "${RU_DIR:-}" && -d "$RU_DIR" && -d "$1/inventory/oneoffs" ]] || return 1
  local d id
  for d in "$RU_DIR" "$RU_DIR"/*/; do
    id=$(basename "$d"); [[ "$id" =~ ^[0-9]{6,}$ ]] || continue
    [[ -d "$1/inventory/oneoffs/$id" ]] && return 0
  done
  return 1
}
installer_done_record() {
  # a success record per installer (the inventory alone does not prove that the installer finished)
  install -d -m 700 "$STATE_DIR"
  case "$1" in
    "Grid installer"*)            : > "$STATE_DIR/grid_install.done"; journal SOFTWARE "$GRID_HOME" "Grid Infrastructure (software only)" ;;
    "Grid configuration tools"*)  : > "$STATE_DIR/grid_config.done";  journal ASMINST "$DATA_DG" "ASM instance, +$DATA_DG and the listener" ;;
    "Database installer"*)        : > "$STATE_DIR/db_install.done";   journal SOFTWARE "$DB_HOME" "Database software (software only)" ;;
  esac
  return 0
}
run_root_script() {
  # root scripts get no input: their questions (local bin folder, TFA) take the default answer
  [[ -x "$1" ]] || { bad "Root script not found: $1"; return 1; }
  local out; out="$LOG_DIR/root_$(basename "$(dirname "$1")")_$(basename "$1" .sh)_$RUN_ID.log"
  if run_long "root script $1" "$out" "" root "$1" < /dev/null; then say "$1 finished without error."; return 0; fi
  bad "$1 failed. The last lines of its output:"; printf '%s\n' "$RUN_OUT" | tail -n 15 | hint
  return 1
}
ru_args() {
  # with RU_DIR the image installer (gridSetup.sh, 18c+ runInstaller) applies that Release Update first
  # ($1 = grid: 12.2 gridSetup.sh calls the option -applyPSU)
  [[ -n "$RU_DIR" && -d "$RU_DIR" ]] || return 0
  # a home that already has the Release Update (an earlier try applied it) does not get it again
  local h; [[ "${1:-}" == "grid" ]] && h=$GRID_HOME || h=$DB_HOME
  if ru_applied "$h"; then say "The Release Update is already in $h. It is not applied again." >&2; return 0; fi
  if [[ "${1:-}" == "grid" && "$(want_rel grid)" == "12.2" ]]; then printf '%s\n' -applyPSU "$RU_DIR"
  else printf '%s\n' -applyRU "$RU_DIR"; fi
}
new_opatch() {
  # $1 home, $2 runner, $3 owner: the Release Update needs a newer OPatch than the base media has
  [[ -n "$RU_DIR" ]] || return 0
  [[ -n "$OPATCH_ZIP" && -f "$OPATCH_ZIP" ]] || { bad "RU_DIR is set, but OPATCH_ZIP is not. It must name the newest OPatch zip (p6880880).
Set it with:  $SELF --settings   (choose e)"; return 1; }
  media_trusted "$OPATCH_ZIP" || { bad "$OPATCH_ZIP is not used: its owner or mode is not safe.
The owner must be root, $ORACLE_USER or $GRID_USER, and only the owner may change it."; return 1; }

  # the old OPatch is kept next to it (no rm -rf of a part of a home)
  # the OPatch of the zip already in place (an earlier try): nothing to do
  local want_v have_v
  want_v=$(unzip -p "$OPATCH_ZIP" OPatch/version.txt 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)
  have_v=$(grep -oE '[0-9]+(\.[0-9]+)+' "$1/OPatch/version.txt" 2>/dev/null | head -n 1)
  if [[ -n "$want_v" && -n "$have_v" ]] && ! ver_lt "$have_v" "$want_v"; then say "$1/OPatch is already version $have_v. The zip has $want_v: nothing to do."; return 0; fi
  say "Replacing $1/OPatch with the one in $OPATCH_ZIP. The Release Update needs it."
  if [[ -e "$1/OPatch" && -e "$1/OPatch.bak_$RUN_ID" ]]; then
    # a retry in this run: the original is kept already; the half copy goes
    run_logged "remove the OPatch of the failed try" "$2" rm -rf -- "$1/OPatch" || { bad "Cannot remove $1/OPatch."; return 1; }
  elif [[ -e "$1/OPatch" ]]; then
    run_logged "keep old OPatch" "$2" mv -T -- "$1/OPatch" "$1/OPatch.bak_$RUN_ID" || { bad "Cannot move $1/OPatch aside."; return 1; }
    journal OPATCH "$1/OPatch" "old=$1/OPatch.bak_$RUN_ID"
  fi
  run_logged "unzip OPatch" "$2" unzip -q -o "$OPATCH_ZIP" -d "$1" || { bad "The unzip of OPatch failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  [[ -x "$1/OPatch/opatch" ]] || { bad "$1/OPatch/opatch is missing after the unzip. Is OPATCH_ZIP the right file?"; return 1; }
}

unzip_marker() { printf '%s/unzip_failed' "$STATE_DIR"; }
unzip_marker_clear() {
  # $1 output file of the unzip that worked: its line goes, and so do older lines of the same zip into the same folder
  [[ -f "$(unzip_marker)" ]] || return 0
  local t="" o="" dest="" ln
  ln=$(grep -F -- "|$1|" "$(unzip_marker)" | head -n 1) || true
  IFS='|' read -r t o dest <<< "$ln"
  if awk -F'|' -v o="$1" -v t="$t" -v d="$dest" '!($2 == o || (t != "" && $1 == t && $3 == d))' "$(unzip_marker)" > "$(unzip_marker).n"; then
    if [[ -s "$(unzip_marker).n" ]]; then cat "$(unzip_marker).n" > "$(unzip_marker)"; else rm -f -- "$(unzip_marker)"; fi
  fi
  rm -f -- "$(unzip_marker).n"
}
unzip_failed_check() {
  # $@ the folders of this software (home and stage folder). An unzip into one of them that did not end with
  # exit code 0 (failed, killed, reboot, closed terminal) leaves a half-filled folder: the installer must not
  # start from it. Lines of an older version have no folder: they count for every folder.
  # Returns 1 with NOW/PLAN set. SW_UNZIP_DIRS / SW_UNZIP_OUTS: what the do function empties and clears
  # (empty when the script must not do it itself: then KIND_NOW=manual).
  SW_UNZIP_DIRS=(); SW_UNZIP_OUTS=()
  [[ -f "$(unzip_marker)" ]] || return 0
  local t o dest list="" f hit rmcmd="" manual=0
  while IFS='|' read -r t o dest; do
    [[ -n "$t" ]] || continue
    hit=0; [[ -z "$dest" ]] && hit=1
    for f in "$@"; do [[ "$dest" == "$f" ]] && hit=1; done
    [[ $hit -eq 1 ]] || continue
    list+="  $t"$'\n'"    into ${dest:-the home or stage folder of that file}"$'\n'
    rmcmd+="grep -vF -- '|${o}|' '$(unzip_marker)' > '$(unzip_marker).n'; mv -f '$(unzip_marker).n' '$(unzip_marker)'"$'\n'
    # the script empties only a folder it knows, that no installed home uses
    if [[ -z "$dest" ]] || in_inventory "$dest" || ! sw_folder_ok "$dest"; then manual=1; fi
    SW_UNZIP_DIRS+=("$dest"); SW_UNZIP_OUTS+=("$o")
  done < "$(unzip_marker)"
  [[ -n "$list" ]] || return 0
  NOW="An earlier unzip did not finish. Its folder is incomplete:"$'\n'"${list%$'\n'}"
  if [[ $manual -eq 0 ]]; then
    PLAN="Empty that folder (nothing is installed there), then unpack the files again"
    return 1
  fi
  SW_UNZIP_DIRS=(); SW_UNZIP_OUTS=()
  KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
  PLAN="-- Empty the folder named above, and nothing else. First check that nothing is
-- installed there: it must not be listed in $INVENTORY_DIR/ContentsXML/inventory.xml.
-- Empty it (hidden files too):  find <folder> -mindepth 1 -delete
-- Then remove its line from the list of failed unzips:
${rmcmd%$'\n'}
-- Then answer r. The files are unpacked again."
  return 1
}
sw_folder_ok() {
  # $1 a software folder the script may empty: the Grid or database home of the settings, or one of their
  # stage folders; a plain path; no program of it runs
  local d=$1 o real fst
  [[ "$d" =~ ^/[A-Za-z0-9_./-]+$ && "$d" != *..* && "$d" != */ && "$d" != *//* ]] || return 1
  [[ "$d" == "$DB_HOME" || ( -n "$GRID_HOME" && "$d" == "$GRID_HOME" ) || "$d" == "$(stage_dir db)" || "$d" == "$(stage_dir grid)" ]] || return 1
  # at least three levels deep (/u01/app/x), not a link, and the same folder when every link is resolved
  [[ $(tr -cd '/' <<< "$d" | wc -c) -ge 3 && ! -L "$d" ]] || return 1
  real=$(readlink -f -- "$d" 2>/dev/null); [[ -z "$real" || "$real" == "$d" ]] || return 1
  # it must not hold (or be) another folder of the setup: base folders, inventory, the other home, database folders
  for o in "$ORACLE_BASE" "${GRID_BASE:-}" "$INVENTORY_DIR" "$DB_HOME" "${GRID_HOME:-}" $(fs_dirs 2>/dev/null); do
    [[ -n "$o" && "$o" != "$d" ]] || continue
    [[ "$o/" == "$d/"* ]] && return 1
  done
  # local storage only, and no other file system mounted inside it (rm -rf would go into it)
  fst=$(findmnt -n -o FSTYPE --target "$(existing_parent "$d")" 2>/dev/null | head -n 1)
  case "$fst" in nfs*|cifs|smb*|acfs|fuse*|glusterfs|ceph*|ocfs2|gfs2|"") return 1 ;; esac
  [[ -d "$d" ]] && findmnt -rn -o TARGET 2>/dev/null | grep -q "^$d/" && return 1
  sw_in_use "$d" && return 1
  return 0
}
sw_in_use() {
  # 0 when a running program comes from folder $1 (the program file of a process is inside it)
  local e r; r=$(readlink -f -- "$1" 2>/dev/null); r=${r:-$1}
  for e in /proc/[0-9]*/exe; do
    e=$(readlink -f -- "$e" 2>/dev/null) || continue
    [[ "$e" == "$1/"* || "$e" == "$r/"* ]] && return 0
  done
  return 1
}
sw_empty_folder() {
  # $1 folder (checked with sw_folder_ok). Everything in it goes, hidden files too; the folder itself and a
  # lost+found of a mount point stay.
  local d=$1
  sw_folder_ok "$d" || { bad "Not emptied: $d is not a software folder of this setup, or a program of it runs."; return 1; }
  [[ -d "$d" ]] || return 0
  find "$d" -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system -- {} + || return 1
  journal DELETED "$d" "cannot be undone: the content of this software folder was deleted (it is installed again)"
  say "Emptied $d"
  _log CHANGE "emptied the software folder $d"
  return 0
}
sw_unzip_fix() {
  # the do part of a failed unzip: empty the folders, then drop their lines from the list of failed unzips
  local i
  for i in "${!SW_UNZIP_DIRS[@]}"; do
    sw_empty_folder "${SW_UNZIP_DIRS[$i]}" || return 1
    grep -vF -- "|${SW_UNZIP_OUTS[$i]}|" "$(unzip_marker)" > "$(unzip_marker).n"
    if [[ -s "$(unzip_marker).n" ]]; then cat "$(unzip_marker).n" > "$(unzip_marker)"; else rm -f -- "$(unzip_marker)"; fi
    rm -f -- "$(unzip_marker).n"
  done
  return 0
}
inventory_mark_removed() {
  # $1 home: the way the Oracle installer detaches a home - its HOME entry gets REMOVED="T" (a backup is kept,
  # --undo puts the file back)
  local inv u tmp; inv="$(inventory_dir)/ContentsXML/inventory.xml"
  [[ -f "$inv" ]] || return 0
  in_inventory "$1" || return 0
  u=$(stat -c '%U' "$inv")
  backup_file "$inv" "$u" || return 1
  tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
  awk -v loc="LOC=\"$1\"" 'index($0, "<HOME ") && index($0, loc) && !index($0, "REMOVED=") { sub(/[[:space:]]*\/?>/, " REMOVED=\"T\"&") } { print }' "$inv" > "$tmp" || return 1
  grep -q "LOC=\"$1\"[^>]*REMOVED=\"T\"" "$tmp" || { bad "The HOME entry of $1 in $inv could not be marked."; return 1; }
  write_as "$u" "$inv" "$(stat -c '%a' "$inv")" < "$tmp" || return 1
  rm -f -- "$tmp"
  say "Marked $1 as removed in $inv"
  return 0
}
sw_half_fix() {
  # $1 home, $2 owner, $3 success record, $4 stage folder. Asks: record it as installed, or clean it.
  # Return: 0 = recorded (nothing more to do), 10 = cleaned (install now), 3 = not done
  local home=$1 owner=$2 rec=$3 stg=$4
  say "Its installer log: the newest file in $INVENTORY_DIR/logs"
  ask_choice "[m] I installed it myself, without error   [c] Clean it and install again   [s] Skip   [q] Quit" "mcsq"
  case "$ANSWER" in
    q) user_stop "Stopped by you" ;;
    s) return 3 ;;
    m) [[ -s "$home/bin/oracle" || -x "$home/bin/crsctl" ]] || { bad "The programs of $home are missing. Choose c to install it again."; return 1; }
       install -d -m 700 "$STATE_DIR"; : > "$rec"; say "Recorded: $home was installed without error."; return 0 ;;
  esac
  sw_folder_ok "$home" || { bad "$home cannot be cleaned by the script: a program of it runs, or it is not the home of the settings."; return 1; }
  if [[ -d "$home/dbs" ]] && ls "$home/dbs" 2>/dev/null | grep -qE '^(spfile|orapw).+'; then
    bad "$home/dbs has an spfile or a password file. A database used this home. It is not cleaned."; return 1
  fi
  # the installer files must be on this server BEFORE the home is emptied (else nothing could install it again)
  local kind=$5 mvar=DB_MEDIA f; [[ "$kind" == grid ]] && mvar=GRID_MEDIA
  if ! media_ok "${!mvar}"; then
    scan_media; f=$(pick_media "$kind")
    if [[ -z "$f" || "$f" == MISSING:* ]]; then
      bad "No installer files for $([[ "$kind" == grid ]] && printf 'Grid %s' "$(want_rel grid)" || printf 'the database %s' "$(want_rel)") were found on this server, so nothing was deleted."
      say "Put them in /stage (owner root, mode 644), then choose c again. Step 3.1 shows where to get them."
      return 1
    fi
    printf -v "$mvar" '%s' "$f"; save_settings; say "Installer files: $f"
  fi
  confirm_word "Everything in $home will be deleted, and it will be installed again." "CLEAN" || return 3
  inventory_mark_removed "$home" || return 1
  sw_empty_folder "$home" || return 1
  [[ -d "$stg" ]] && { sw_empty_folder "$stg" || return 1; }
  rm -f -- "$rec"
  return 10
}
stage_dir() { printf '%s/dg_stage_%s' "$(dirname "$INVENTORY_DIR")" "$1"; }   # for staged (12.x) media
unpack_media() {
  # $1 comma list of zip files, $2 target folder, $3 runner, $4 owner
  local files=$1 dest=$2 runner=$3 owner=$4 f
  [[ -d "$dest" ]] || make_dir "$dest" "$owner" || return 1
  IFS=',' read -ra _uz <<< "$files"
  for f in "${_uz[@]}"; do
    media_trusted "$f" || { bad "$f is not used: its owner or mode has changed."; return 1; }
    runuser -u "$owner" -- test -r "$f" || { bad "$owner cannot read $f. Fix it with:  chmod 644 $f"; return 1; }
    local who=oracle; [[ "$runner" == "as_grid" ]] && who=grid
    local uo="$LOG_DIR/unzip_$(basename "$f" .zip)_$RUN_ID.log"
    # the marker is written first and removed only when the unzip worked: any other end leaves it
    install -d -m 700 "$STATE_DIR"
    printf '%s|%s|%s\n' "unzip $(basename "$f")" "$uo" "$dest" >> "$(unzip_marker)" && chmod 600 "$(unzip_marker)" \
      || { bad "Cannot write $(unzip_marker). Is the disk full? The unzip was not started."; return 1; }
    run_long "unzip $(basename "$f")" "$uo" "" "$who" unzip -q -o "$f" -d "$dest" < /dev/null \
      || { bad "The unzip failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    unzip_marker_clear "$uo"
    journal UNZIP "$dest" "from $(basename "$f")"
  done
}

#------------------------------------------------------------------------------
# Grid
#------------------------------------------------------------------------------
GRID_ROOT_DONE_FILE() { printf '%s/grid_root.done' "$STATE_DIR"; }
grid_state() {
  # DONE | ASM_DOWN | HAS_DOWN | NEED_CONFIGTOOLS | NEED_ROOT | NEED_INSTALL | NEED_UNZIP | UNKNOWN
  GSTATE_OUT=""
  if ! users_ok; then GSTATE=NEED_UNZIP; return; fi
  if [[ -x "$GRID_HOME/bin/crsctl" ]]; then
    local has_on=0
    run_logged "crsctl check has" as_grid timeout 60 "$GRID_HOME/bin/crsctl" check has && grep -q 'CRS-4638' <<< "$RUN_OUT" && has_on=1
    if [[ $has_on -eq 1 ]]; then
      run_logged "crsctl stat res ora.asm" as_grid timeout 60 "$GRID_HOME/bin/crsctl" stat res ora.asm || true
      if grep -q 'CRS-2613' <<< "$RUN_OUT"; then GSTATE=NEED_CONFIGTOOLS
      elif grep -q 'NAME=ora.asm' <<< "$RUN_OUT"; then
        if grep -q 'STATE=ONLINE' <<< "$RUN_OUT"; then GSTATE=DONE; else GSTATE=ASM_DOWN; fi
      else GSTATE=UNKNOWN; GSTATE_OUT=$RUN_OUT; fi
      return
    fi
    # a left-over olr.loc of an earlier install does not make an unpacked home "installed"
    if [[ -f /etc/oracle/olr.loc ]] && in_inventory "$GRID_HOME"; then GSTATE=HAS_DOWN; return; fi
  fi
  if in_inventory "$GRID_HOME"; then
    if [[ -f "$STATE_DIR/grid_install.done" || -f /etc/oracle/olr.loc || -f "$(GRID_ROOT_DONE_FILE)" ]] && [[ -x "$GRID_HOME/bin/crsctl" ]]; then GSTATE=NEED_ROOT
    else GSTATE=HALF_INSTALLED; fi
    return
  fi
  if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then GSTATE=NEED_INSTALL; return; fi
  GSTATE=NEED_UNZIP
}
half_installed_plan() {
  # $1 home, $2 owner, $3 the success record: an installer that registered the home but did not finish
  # (relink error, killed), or a home installed by hand before this script ran
  NOW="$1 is in the Oracle inventory, but the script cannot confirm the installation."$'\n'"There is no record that its installer finished, or its programs are missing."
  KIND_NOW=ask; SW_FIX=half
  PLAN="You choose:
  m  you installed it yourself and the installer finished without error: the script records that
  c  clean it and install again: the home is marked as removed in the inventory (a backup is kept),
     $1 is emptied, and the installer runs again"
}
grid_installer() {
  # prints the installer path for the current media (image: in the home; staged: in the stage folder)
  if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then printf '%s/gridSetup.sh' "$GRID_HOME"
  else printf '%s/grid/runInstaller' "$(stage_dir grid)"; fi
}
grid_template() {
  if [[ -f "$GRID_HOME/install/response/gridsetup.rsp" ]]; then printf '%s/install/response/gridsetup.rsp' "$GRID_HOME"
  else printf '%s/grid/response/grid_install.rsp' "$(stage_dir grid)"; fi
}
write_grid_rsp() {
  # fills RSP (already copied from the template) for Oracle Restart with ASM
  local f=$RSP dl fg
  dl=$(asm_labels "$DATA_DG" | sed "s#^#$(asm_disk_dir)/#" | paste -sd, -)
  fg=$(tr ',' '\n' <<< "$dl" | sed 's/$/,/' | paste -sd, -)     # disk,failgroup,disk,failgroup (empty failgroups)
  rsp_need "$f" HA_CONFIG oracle.install.option installOption
  rsp_need "$f" "$GRID_BASE" ORACLE_BASE oracleBase
  rsp_need "$f" "$INVENTORY_DIR" INVENTORY_LOCATION inventoryLocation
  rsp_set  "$f" "$GRID_HOME" ORACLE_HOME oracleHome || true                 # staged (12.1) installer only
  rsp_set  "$f" "$INSTALL_GROUP" UNIX_GROUP_NAME unixGroupName || true
  rsp_set  "$f" "en" SELECTED_LANGUAGES || true
  rsp_need "$f" "$(grp_or asmdba dba)" oracle.install.asm.OSDBA OSDBA
  rsp_set  "$f" "$(getent group asmoper >/dev/null 2>&1 && printf asmoper)" oracle.install.asm.OSOPER OSOPER || true
  rsp_need "$f" "$(asm_owner_group)" oracle.install.asm.OSASM OSASM
  rsp_need "$f" "$ASM_PW" oracle.install.asm.SYSASMPassword sysasmPassword
  rsp_need "$f" "$ASM_PW" oracle.install.asm.monitorPassword asmsnmpPassword
  rsp_need "$f" "$DATA_DG" oracle.install.asm.diskGroup.name diskGroupName
  rsp_need "$f" EXTERNAL oracle.install.asm.diskGroup.redundancy redundancy
  rsp_set  "$f" 4 oracle.install.asm.diskGroup.AUSize auSize || true
  rsp_need "$f" "$dl" oracle.install.asm.diskGroup.disks diskList
  rsp_set  "$f" "$fg" oracle.install.asm.diskGroup.disksWithFailureGroupNames disksWithFailureGroupNames || true
  rsp_need "$f" "$(asm_disk_dir)/*" oracle.install.asm.diskGroup.diskDiscoveryString diskString
  rsp_set  "$f" false oracle.install.asm.configureAFD configureAFD || true
  rsp_set  "$f" NONE oracle.install.config.managementOption managementOption || true
  rsp_set  "$f" false oracle.install.crs.rootconfig.executeRootScript executeRootScript || true
  rsp_set  "$f" SKIP_UPDATES oracle.installer.autoupdates.option || true
  finish_rsp "$f" "$GRID_USER"
  rsp_review
}

# ---- 3.2 Grid software ----
SW_FIX=""; SW_UNZIP_DIRS=(); SW_UNZIP_OUTS=()
grid_ready() {
  # what the install needs (NOW says what is missing)
  [[ -n "$(asm_labels "$DATA_DG")" ]] || { NOW="No ASM disks for +$DATA_DG yet (step 2.13)"; return 1; }
  if [[ "$GSTATE" == "NEED_UNZIP" ]]; then
    media_ok "$GRID_MEDIA" || { NOW="The Grid installer files are not known yet (step 3.1)"; return 1; }
    if ! media_is_staged "$GRID_MEDIA"; then
      dir_empty "$GRID_HOME" || { NOW="$GRID_HOME is not empty, but it has no gridSetup.sh. Check what is in it."; return 1; }
    fi
  fi
  return 0
}
c_3_2() {
  SW_FIX=""
  use_grid || { NOW="Not needed (the primary does not use ASM)"; return 0; }
  users_ok || { NOW="The Oracle users do not exist yet (step 2.2)"; return 2; }
  grid_state
  case "$GSTATE" in
    DONE|ASM_DOWN|HAS_DOWN|NEED_CONFIGTOOLS|NEED_ROOT) NOW="Grid software is installed in $GRID_HOME"; return 0 ;;
    UNKNOWN) NOW="Cannot read the Grid state: $(head -n 2 <<< "$GSTATE_OUT")"; return 2 ;;
    HALF_INSTALLED) half_installed_plan "$GRID_HOME" "$GRID_USER" "$STATE_DIR/grid_install.done"; return 1 ;;
  esac
  if ! unzip_failed_check "$GRID_HOME" "$(stage_dir grid)"; then SW_FIX=unzip; return 1; fi
  grid_ready || return 2
  NOW="Grid is not installed yet"
  PLAN=""
  if [[ "$GSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$GRID_MEDIA"; then PLAN="Unzip ${GRID_MEDIA//,/ + } into $(stage_dir grid), as $GRID_USER"$'\n'
    else PLAN="Unzip $GRID_MEDIA into $GRID_HOME, as $GRID_USER"$'\n'; fi
  fi
  PLAN+="Install Grid silently as $GRID_USER: Oracle Restart for a single server${RU_DIR:+,}
${RU_DIR:+  with the Release Update in $RU_DIR}
  Disk group +$DATA_DG, external redundancy, disks $(asm_labels "$DATA_DG" | paste -sd' ' -)
  Grid home $GRID_HOME, base $GRID_BASE
  Inventory $INVENTORY_DIR
Ask you for a new ASM password for SYS and ASMSNMP (used only on this server)"
  USING="Same paths and disk group name as the primary."$'\n'"The response file is made from the template in the media."
  return 1
}
d_3_2() {
  local fx=0
  case "$SW_FIX" in
    half)  sw_half_fix "$GRID_HOME" "$GRID_USER" "$STATE_DIR/grid_install.done" "$(stage_dir grid)" grid || fx=$?
           [[ $fx -eq 10 ]] || return $fx ;;
    unzip) sw_unzip_fix || return 1 ;;
  esac
  if [[ -n "$SW_FIX" ]]; then
    SW_FIX=""; grid_state
    grid_ready || { bad "$NOW"; return 1; }
  fi
  if [[ "$GSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$GRID_MEDIA"; then unpack_media "$GRID_MEDIA" "$(stage_dir grid)" as_grid "$GRID_USER" || return 1
    else
      unpack_media "$GRID_MEDIA" "$GRID_HOME" as_grid "$GRID_USER" || return 1
      [[ -x "$GRID_HOME/gridSetup.sh" ]] || { bad "gridSetup.sh is missing after the unzip. Is GRID_MEDIA the right file?"; return 1; }
    fi
  fi
  [[ -x "$GRID_HOME/gridSetup.sh" ]] && { new_opatch "$GRID_HOME" as_grid "$GRID_USER" || return 1; }
  ask_asm_password || return 1
  make_rsp "$(grid_template)" || return 1
  write_grid_rsp || { remove_rsp "$RSP"; return 1; }
  local inst irc=0 rsp=$RSP; inst=$(grid_installer)
  local -a ru=(); mapfile -t ru < <(ru_args grid)
  JOB_KEEP=$rsp
  if [[ "$inst" == */gridSetup.sh ]]; then
    run_installer "Grid installer" as_grid -ignorePrereqFailure "$inst" -silent -waitforcompletion -responseFile "$rsp" "${ru[@]+"${ru[@]}"}" || irc=1
  else
    run_installer "Grid installer (12.1)" as_grid -ignorePrereq "$inst" -silent -waitforcompletion -responseFile "$rsp" || irc=1
  fi
  remove_rsp "$rsp"
  return $irc
}

# ---- 3.3 Grid root scripts ----
c_3_3() {
  use_grid || { NOW="Not needed (no Grid)"; return 0; }
  grid_state
  case "$GSTATE" in
    DONE|ASM_DOWN|NEED_CONFIGTOOLS)
      [[ "$MODE" == "run" ]] && { install -d -m 700 "$STATE_DIR"; : > "$(GRID_ROOT_DONE_FILE)"; }
      NOW="The Grid root scripts have run. Oracle Restart is configured and running."; return 0 ;;
    HAS_DOWN)
      if [[ -f "$(GRID_ROOT_DONE_FILE)" ]]; then NOW="The Grid root scripts have run. High Availability Services is started in step 3.4."; return 0; fi
      NOW="Oracle Restart is configured (olr.loc exists), but High Availability Services is not running."$'\n'"root.sh may have failed."
      KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
      PLAN="$GRID_HOME/bin/crsctl start has
-- If that fails, read $GRID_HOME/cfgtoollogs/crsconfig/roothas_*.log.
-- Then undo the configuration and run root.sh again:
$GRID_HOME/crs/install/roothas.sh -deconfig -force
$GRID_HOME/root.sh"
      return 1 ;;
    NEED_ROOT) ;;
    *) NOW="Grid is not installed yet (step 3.2)"; return 2 ;;
  esac
  # 12.1 Oracle Restart on Oracle Linux 7 (systemd) starts ohasd only with patch 18370031 (also inside a later PSU)
  if [[ "$(want_rel grid)" == "12.1" && "$OS_MAJOR" == "7" && ! -d "$GRID_HOME/inventory/oneoffs/18370031" ]] \
     && ! grep -qs '18370031' "$GRID_HOME"/inventory/oneoffs/*/etc/config/inventory.xml; then
    NOW="12.1 Grid on Oracle Linux 7 needs patch 18370031 before root.sh."$'\n'"Without it, ohasd does not start under systemd."
    KIND_NOW=manual; MANUAL_HOW="$GRID_USER  ->  shell"
    PLAN="-- Download patch 18370031 from My Oracle Support and unzip it. Then:
$GRID_HOME/OPatch/opatch napply -oh $GRID_HOME -local <folder>/18370031
-- Then answer r. root.sh runs after that."
    return 1
  fi
  NOW="Grid is installed. Its root scripts have not run yet."
  local invd; invd=$(inventory_dir)
  PLAN=""
  [[ -x "$invd/orainstRoot.sh" ]] && PLAN="Run $invd/orainstRoot.sh"$'\n'
  PLAN+="Run $GRID_HOME/root.sh. It configures Oracle Restart on this server."$'\n'"Its questions get the default answers."
  return 1
}
d_3_3() {
  local invd; invd=$(inventory_dir)
  if [[ -x "$invd/orainstRoot.sh" ]]; then run_root_script "$invd/orainstRoot.sh" || return 1; fi
  run_root_script "$GRID_HOME/root.sh" || return 1
  install -d -m 700 "$STATE_DIR"; : > "$(GRID_ROOT_DONE_FILE)"
  journal GRIDCONFIG "$GRID_HOME" "root.sh: Oracle Restart configured (ohasd, /etc/oracle, /etc/oraInst.loc)"
}

# ---- 3.4 Grid configuration (ASM, listener) ----
c_3_4() {
  use_grid || { NOW="Not needed (no Grid)"; return 0; }
  grid_state
  case "$GSTATE" in
    DONE) NOW="Oracle Restart is running and ASM is ONLINE"; return 0 ;;
    NEED_CONFIGTOOLS)
      NOW="Oracle Restart is running. ASM is not configured yet."
      if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then PLAN="Run gridSetup.sh -executeConfigTools -silent as $GRID_USER"
      else PLAN="Run $GRID_HOME/cfgtoollogs/configToolAllCommands as $GRID_USER (12.1)"; fi
      PLAN+=$'\n'"It creates ASM, +$DATA_DG and the listener."
      [[ -n "$ASM_PW" ]] || PLAN+=$'\n'"Ask you for the ASM password for SYS and ASMSNMP: the one from step 3.2"$'\n'"(it was not used yet), or a new one" ;;
    HAS_DOWN) NOW="High Availability Services is stopped"; PLAN="Start it as root:  $GRID_HOME/bin/crsctl start has" ;;
    ASM_DOWN) NOW="ASM is not ONLINE"; PLAN="Start it as $GRID_USER:  crsctl start res ora.asm" ;;
    UNKNOWN) NOW="Cannot read the Grid state: $(head -n 2 <<< "$GSTATE_OUT")"; return 2 ;;
    *) NOW="The Grid root scripts have not run yet (step 3.3)"; return 2 ;;
  esac
  return 1
}
d_3_4() {
  case "$GSTATE" in
    NEED_CONFIGTOOLS)
      ask_asm_password || return 1
      local crc=0
      if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then
        make_rsp "$(grid_template)" || return 1
        write_grid_rsp || { remove_rsp "$RSP"; return 1; }
        local rsp=$RSP; JOB_KEEP=$rsp
        run_installer "Grid configuration tools" as_grid -ignorePrereqFailure "$GRID_HOME/gridSetup.sh" -executeConfigTools -responseFile "$rsp" -silent -waitforcompletion || crc=1
        remove_rsp "$rsp"
      else
        secure_rsp cfgrsp.properties || return 1
        ( umask 077; set -C
          printf 'oracle.assistants.asm|S_ASMPASSWORD=%s\noracle.assistants.asm|S_ASMMONITORPASSWORD=%s\n' "$ASM_PW" "$ASM_PW" > "$RSP" ) || return 1
        finish_rsp "$RSP" "$GRID_USER"
        local props=$RSP; JOB_KEEP=$props
        run_installer "Grid configuration tools (12.1)" as_grid "" "$GRID_HOME/cfgtoollogs/configToolAllCommands" "RESPONSE_FILE=$props" || crc=1
        remove_rsp "$props"
      fi
      return $crc ;;
    HAS_DOWN)
      run_logged "crsctl start has" timeout 300 "$GRID_HOME/bin/crsctl" start has || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
      local n=0; say "Waiting for ASM to come online ..."
      until grid_state; [[ "$GSTATE" == "DONE" || $n -ge 12 ]]; do sleep 5; n=$((n + 1)); done ;;
    ASM_DOWN) run_logged "start ora.asm" as_grid timeout 300 "$GRID_HOME/bin/crsctl" start res ora.asm || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; } ;;
  esac
}

# ---- 3.5 disk groups ----
dg_list() { sql_asm "select name||'|'||state||'|'||free_mb||'|'||total_mb from v\$asm_diskgroup;"; }
dg_field() {
  local n s f t
  DG_S=""; DG_F=""; DG_T=""
  while IFS='|' read -r n s f t; do [[ "${n^^}" == "${1^^}" ]] && { DG_S=$s; DG_F=$f; DG_T=$t; }; done <<< "$SQL_OUT"
}
DG_TODO=""
c_3_5() {
  use_grid || { NOW="Not needed (no ASM)"; return 0; }
  grid_sw_ok || { NOW="Grid is not installed yet (step 3.2)"; return 2; }
  dg_list || { NOW="Cannot query ASM: $(ora_errors "$SQL_OUT") (step 3.4)"; return 2; }
  local list=$SQL_OUT ca="" cr=""
  dg_field "$DATA_DG"
  if [[ "$DG_S" == "MOUNTED" || "$DG_S" == "CONNECTED" ]]; then
    sql_asm "select max(decode(a.name,'compatible.asm',a.value))||'|'||max(decode(a.name,'compatible.rdbms',a.value)) from v\$asm_attribute a, v\$asm_diskgroup g where a.group_number=g.group_number and g.name='$DATA_DG';" \
      && IFS='|' read -r ca cr <<< "$(first_line)"
  elif [[ -z "$DG_S" ]]; then
    # the Grid configuration created ASM but not +DATA (it stopped half-way): created here like the others
    warn "+$DATA_DG does not exist, although ASM is running. The Grid configuration did not
finish it. This step creates it, with default attributes."
  fi
  SQL_OUT=$list
  local dg info="" todo="" disks
  DG_TODO=""
  for dg in $(asm_dgs); do
    dg_field "$dg"
    if [[ "$DG_S" == "MOUNTED" || "$DG_S" == "CONNECTED" ]]; then info+="+$dg $DG_S, $(human_mb "$DG_F") free of $(human_mb "$DG_T")"$'\n'; continue; fi
    if [[ -n "$DG_S" ]]; then
      NOW="Disk group +$dg exists here, but it is $DG_S"
      KIND_NOW=manual; MANUAL_HOW="$GRID_USER  ->  export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM ; \$ORACLE_HOME/bin/sqlplus / as sysasm"
      PLAN="-- Mount it only if all its disks belong to this server. NEVER use a disk of the primary.
select path, header_status, name from v\$asm_disk;
alter diskgroup $dg mount;"
      return 1
    fi
    [[ -n "$(asm_labels "$dg")" ]] || { NOW="No ASM disks for +$dg yet (step 2.13)"; return 2; }
    disks=$(asm_labels "$dg" | sed "s#^#'$(asm_disk_dir)/#; s#\$#'#" | paste -sd, -)
    local c="create diskgroup $dg external redundancy disk $disks" attrs=""
    local ca2=$ca cr2=$cr
    if [[ "${PRIMARY_REDO_BS:-${SRL_BLOCKSIZE:-512}}" == "4096" ]]; then
      # a sector size other than the default needs compatible values of 11.2 or newer (12.2 for 512e disks)
      # 12.2 for 512e disks needs a 12.2+ Grid; an older Grid takes 11.2 (enough for sector_size)
      if [[ "$(rel_major "${GRID_REL:-${DB_MAJOR:-19}}")" -ge 18 || "${GRID_REL:-}" == 12.2* ]]; then ver_lt "${ca2:-0}" 12.2 && ca2=12.2.0.1.0
      else ver_lt "${ca2:-0}" 11.2 && ca2=11.2.0.0.0; fi
      ver_lt "${cr2:-0}" 11.2 && cr2=11.2.0.0.0
    fi
    [[ "$ca2" =~ ^[0-9.]+$ && "$cr2" =~ ^[0-9.]+$ ]] && attrs+="'compatible.asm'='$ca2', 'compatible.rdbms'='$cr2'"
    [[ "${PRIMARY_REDO_BS:-${SRL_BLOCKSIZE:-512}}" == "4096" ]] && attrs+="${attrs:+, }'sector_size'='4096'"
    [[ -n "$attrs" ]] && c+=" attribute $attrs"
    DG_TODO+="$c;"$'\n'; todo+=" +$dg"
  done
  DG_TODO=${DG_TODO%$'\n'}
  if [[ -z "$DG_TODO" ]]; then NOW="${info%$'\n'}"; return 0; fi
  NOW="Disk groups to create:$todo"
  PLAN="As $GRID_USER:  export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM ; \$ORACLE_HOME/bin/sqlplus / as sysasm
$DG_TODO"
  USING="Same disk group names as the primary."$'\n'"compatible.asm and compatible.rdbms are the same as in +$DATA_DG."
  return 1
}
d_3_5() {
  local s
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if ! sql_asm "$s"; then
      bad "This failed ($(ora_errors "$SQL_OUT")):"$'\n'"$s"
      if grep -qE 'ORA-15018|ORA-15030|ORA-15033' <<< "$SQL_OUT"; then
        printf 'A disk already has an ASM header, probably from an interrupted earlier try.\nOnly if the disks were made by this script (%s), repeat the statement with FORCE:\n  %s\n' "$(asm_disks_file)" "$(sed -E "s/'((\/|ORCL:)[^']*)'/'\1' force/g" <<< "$s")" | hint
      fi
      return 1
    fi
    [[ "$s" =~ ^create\ diskgroup\ ([A-Za-z0-9_]+) ]] && journal DISKGROUP "${BASH_REMATCH[1]^^}" "external redundancy"
  done <<< "$DG_TODO"
  return 0
}

#------------------------------------------------------------------------------
# Database software
#------------------------------------------------------------------------------
db_state() {
  # DONE | NEED_ROOT | HALF_INSTALLED | NEED_INSTALL | NEED_UNZIP
  if in_inventory "$DB_HOME"; then
    if [[ ! -f "$STATE_DIR/db_install.done" && "$(stat -c '%U' "$DB_HOME/bin/oradism" 2>/dev/null)" != "root" ]] || [[ ! -s "$DB_HOME/bin/oracle" || ! -s "$DB_HOME/bin/sqlplus" ]]; then DSTATE=HALF_INSTALLED; return; fi
    if [[ "$(stat -c '%U' "$DB_HOME/bin/oradism" 2>/dev/null)" == "root" ]]; then DSTATE=DONE; else DSTATE=NEED_ROOT; fi
    return
  fi
  if [[ -x "$DB_HOME/runInstaller" ]]; then DSTATE=NEED_INSTALL; return; fi
  DSTATE=NEED_UNZIP
}
db_template() {
  if [[ -f "$DB_HOME/install/response/db_install.rsp" ]]; then printf '%s/install/response/db_install.rsp' "$DB_HOME"
  else printf '%s/database/response/db_install.rsp' "$(stage_dir db)"; fi
}
db_installer() {
  if [[ -x "$DB_HOME/runInstaller" ]]; then printf '%s/runInstaller' "$DB_HOME"
  else printf '%s/database/runInstaller' "$(stage_dir db)"; fi
}
write_db_rsp() {
  # $1 = image | staged
  local f=$RSP
  rsp_need "$f" INSTALL_DB_SWONLY oracle.install.option installOption
  rsp_need "$f" "$INSTALL_GROUP" UNIX_GROUP_NAME unixGroupName
  rsp_need "$f" "$INVENTORY_DIR" INVENTORY_LOCATION inventoryLocation
  # an image installer installs into the folder it was unpacked in; only staged media needs ORACLE_HOME
  if [[ "$1" == "staged" ]]; then rsp_need "$f" "$DB_HOME" ORACLE_HOME oracleHome; else rsp_set "$f" "$DB_HOME" ORACLE_HOME oracleHome || true; fi
  rsp_need "$f" "$ORACLE_BASE" ORACLE_BASE oracleBase
  rsp_need "$f" "${DB_EDITION:-EE}" oracle.install.db.InstallEdition installEdition
  # group names: 12.2+ (OSDBA_GROUP ...), 12.1 (DBA_GROUP ...), 23ai (OSDBA ...)
  rsp_need "$f" "$(grp_or dba)" oracle.install.db.OSDBA_GROUP oracle.install.db.DBA_GROUP OSDBA
  rsp_set  "$f" "$(grp_or oper dba)" oracle.install.db.OSOPER_GROUP oracle.install.db.OPER_GROUP OSOPER || true
  rsp_set  "$f" "$(grp_or backupdba dba)" oracle.install.db.OSBACKUPDBA_GROUP oracle.install.db.BACKUPDBA_GROUP OSBACKUPDBA || true
  rsp_set  "$f" "$(grp_or dgdba dba)" oracle.install.db.OSDGDBA_GROUP oracle.install.db.DGDBA_GROUP OSDGDBA || true
  rsp_set  "$f" "$(grp_or kmdba dba)" oracle.install.db.OSKMDBA_GROUP oracle.install.db.KMDBA_GROUP OSKMDBA || true
  rsp_set  "$f" "$(grp_or racdba dba)" oracle.install.db.OSRACDBA_GROUP OSRACDBA || true
  rsp_set  "$f" false oracle.install.db.rootconfig.executeRootScript executeRootScript || true
  rsp_set  "$f" true DECLINE_SECURITY_UPDATES || true
  rsp_set  "$f" false SECURITY_UPDATES_VIA_MYORACLESUPPORT || true
  rsp_set  "$f" SKIP_UPDATES oracle.installer.autoupdates.option || true
  rsp_set  "$f" en SELECTED_LANGUAGES || true
  finish_rsp "$f" "$ORACLE_USER"
  rsp_review
}
primary_edition() {
  [[ -n "$DB_EDITION" ]] && return 0
  need_ssh || return 1
  prim_sql "select banner from v\$version where banner like 'Oracle%';" || return 1
  local b; b=$(first_line)
  if [[ "$b" == *"Enterprise Edition"* ]]; then DB_EDITION=EE
  elif [[ "$b" == *"Standard Edition"* ]]; then DB_EDITION=SE2
  else DB_EDITION=EE; warn "Edition not recognised in '$b'. Using Enterprise Edition."; fi
  [[ "$DB_EDITION" == "EE" ]] || fatal "The primary is Standard Edition ($b). Data Guard needs Enterprise Edition. This script cannot build a standby for it."
}

# ---- 3.6 DB software ----
db_ready() {
  if [[ "$DSTATE" == "NEED_UNZIP" ]]; then
    media_ok "$DB_MEDIA" || { NOW="The database installer files are not known yet (step 3.1)"; return 1; }
    if ! media_is_staged "$DB_MEDIA"; then
      dir_empty "$DB_HOME" || { NOW="$DB_HOME is not empty, but it has no runInstaller. Check what is in it."; return 1; }
    fi
  fi
  return 0
}
c_3_6() {
  SW_FIX=""
  users_ok || { NOW="The Oracle users do not exist yet (step 2.2)"; return 2; }
  db_state
  case "$DSTATE" in
    DONE|NEED_ROOT) NOW="Database software is installed in $DB_HOME"; return 0 ;;
    HALF_INSTALLED) half_installed_plan "$DB_HOME" "$ORACLE_USER" "$STATE_DIR/db_install.done"; return 1 ;;
  esac
  primary_edition || { NOW="Cannot read the edition of the primary"; return 2; }
  if ! unzip_failed_check "$DB_HOME" "$(stage_dir db)"; then SW_FIX=unzip; return 1; fi
  db_ready || return 2
  NOW="Database software is not installed yet"
  PLAN=""
  if [[ "$DSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$DB_MEDIA"; then PLAN="Unzip ${DB_MEDIA//,/ + } into $(stage_dir db), as $ORACLE_USER"$'\n'
    else PLAN="Unzip $DB_MEDIA into $DB_HOME, as $ORACLE_USER"$'\n'; fi
  fi
  PLAN+="Install the database software silently as $ORACLE_USER: Software Only, Enterprise Edition${RU_DIR:+,}
${RU_DIR:+  with the Release Update in $RU_DIR}
  Home $DB_HOME, base $ORACLE_BASE, OS groups as on the primary"
  USING="Same home and base as the primary."$'\n'"The response file is made from the template in the media."
  return 1
}
d_3_6() {
  local kind=image fx=0
  case "$SW_FIX" in
    half)  sw_half_fix "$DB_HOME" "$ORACLE_USER" "$STATE_DIR/db_install.done" "$(stage_dir db)" db || fx=$?
           [[ $fx -eq 10 ]] || return $fx ;;
    unzip) sw_unzip_fix || return 1 ;;
  esac
  if [[ -n "$SW_FIX" ]]; then
    SW_FIX=""; db_state
    primary_edition || { bad "Cannot read the edition of the primary"; return 1; }
    db_ready || { bad "$NOW"; return 1; }
  fi
  if [[ "$DSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$DB_MEDIA"; then unpack_media "$DB_MEDIA" "$(stage_dir db)" as_oracle "$ORACLE_USER" || return 1
    else
      unpack_media "$DB_MEDIA" "$DB_HOME" as_oracle "$ORACLE_USER" || return 1
      [[ -x "$DB_HOME/runInstaller" ]] || { bad "runInstaller is missing after the unzip. Is DB_MEDIA the right file?"; return 1; }
    fi
  fi
  local inst irc=0; inst=$(db_installer)
  [[ "$inst" == "$DB_HOME/runInstaller" ]] || kind=staged
  [[ "$kind" == "image" && $DB_MAJOR -ge 18 ]] && { new_opatch "$DB_HOME" as_oracle "$ORACLE_USER" || return 1; }
  make_rsp "$(db_template)" || return 1
  write_db_rsp "$kind" || { remove_rsp "$RSP"; return 1; }
  local rsp=$RSP
  local -a ru=(); [[ $DB_MAJOR -ge 18 ]] && mapfile -t ru < <(ru_args)
  JOB_KEEP=$rsp
  if [[ "$kind" == "image" ]]; then
    run_installer "Database installer" as_oracle -ignorePrereqFailure "$inst" -silent -waitforcompletion -responseFile "$rsp" "${ru[@]+"${ru[@]}"}" || irc=1
  else
    run_installer "Database installer (12.x)" as_oracle -ignorePrereq "$inst" -silent -waitforcompletion -responseFile "$rsp" || irc=1
  fi
  remove_rsp "$rsp"
  return $irc
}

# ---- 3.7 DB root.sh ----
c_3_7() {
  db_state
  case "$DSTATE" in
    DONE) NOW="root.sh of the database home has run"; return 0 ;;
    NEED_ROOT)
      NOW="The database software is installed. Its root.sh has not run yet."
      PLAN=""; [[ -x "$(inventory_dir)/orainstRoot.sh" && ! -f /etc/oraInst.loc ]] && PLAN="Run $(inventory_dir)/orainstRoot.sh"$'\n'
      PLAN+="Run $DB_HOME/root.sh. Its questions get the default answers."; return 1 ;;
    HALF_INSTALLED) NOW="The database installer did not finish (step 3.6)"; return 2 ;;
    *) NOW="Database software is not installed yet (step 3.6)"; return 2 ;;
  esac
}
d_3_7() {
  if [[ ! -f /etc/oraInst.loc && -x "$(inventory_dir)/orainstRoot.sh" ]]; then run_root_script "$(inventory_dir)/orainstRoot.sh" || return 1; fi
  run_root_script "$DB_HOME/root.sh" || return 1
  journal ROOTSH "$DB_HOME" "root.sh of the database home (/usr/local/bin/oraenv, coraenv, dbhome; /etc/oratab)"
  local s; for s in db grid; do [[ -d "$(stage_dir $s)" ]] && say "You can now remove the unpacked installer in $(stage_dir $s) (rm -rf)."; done
  return 0
}

# ---- 3.8 read/write home (18c and newer) ----
OBH=""
c_3_8() {
  db_sw_ok || { NOW="Database software is not installed yet (step 3.6)"; return 2; }
  [[ -x "$DB_HOME/bin/orabasehome" ]] || { NOW="Not needed (read-only homes exist only from 18c)"; return 0; }
  run_logged "orabasehome" as_oracle "$DB_HOME/bin/orabasehome" || { NOW="Cannot run $DB_HOME/bin/orabasehome"; return 2; }
  OBH=$(printf '%s\n' "$RUN_OUT" | grep -E '^/' | head -n 1); OBH=${OBH%/}
  if [[ "$OBH" == "$DB_HOME" ]]; then NOW="The Oracle home is read/write (orabasehome prints the home itself)"; return 0; fi
  NOW="The Oracle home is read-only. orabasehome prints:"$'\n'"  $OBH"
  if [[ -n "$(ls -A "$ORACLE_BASE/dbs" 2>/dev/null)" ]] || pgrep -f "^ora_pmon_" >/dev/null 2>&1; then
    NOW+=$'\n'"A database already uses it: there are files in $ORACLE_BASE/dbs, or an instance runs."$'\n'"The script does not change such a home."
    return 2
  fi
  PLAN="Run roohctl -disable as $ORACLE_USER. The home is new and has no database yet."
  PLAN+=$'\n'"Then the spfile, password file and tnsnames.ora are kept inside $DB_HOME."
  return 1
}
d_3_8() { journal ROOHCTL "$DB_HOME"; run_logged "roohctl -disable" as_oracle "$DB_HOME/bin/roohctl" -disable || { bad "roohctl failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }; }
rw_home_ok() {
  db_sw_ok || return 1
  [[ -x "$DB_HOME/bin/orabasehome" ]] || return 0
  run_logged "orabasehome" as_oracle "$DB_HOME/bin/orabasehome" || return 1
  local o; o=$(printf '%s\n' "$RUN_OUT" | grep -E '^/' | head -n 1)
  [[ "${o%/}" == "$DB_HOME" ]]
}

# ---- 3.9 resources (Grid) ----
RES_TODO=""
c_3_9() {
  use_grid || { NOW="Not needed without Grid. The listener is set up in phase 5."; return 0; }
  grid_sw_ok || { NOW="Grid is not installed yet (step 3.2)"; return 2; }
  local r off=() miss=() on=() dg
  local -a res=(ora.asm "ora.$SB_LSNR.lsnr")
  for dg in $(asm_dgs); do res+=("ora.${dg^^}.dg"); done
  for r in "${res[@]}"; do
    run_logged "crsctl stat res $r" as_grid timeout 60 "$GRID_HOME/bin/crsctl" stat res "$r" || true
    if grep -q 'CRS-2613' <<< "$RUN_OUT" || ! grep -q "NAME=$r" <<< "$RUN_OUT"; then miss+=("$r")
    elif grep -q 'STATE=ONLINE' <<< "$RUN_OUT"; then on+=("$r")
    else off+=("$r"); fi
  done
  if [[ ${#off[@]} -eq 0 && ${#miss[@]} -eq 0 ]]; then NOW="All ONLINE: ${on[*]}"; return 0; fi
  RES_TODO=""
  for r in "${miss[@]+"${miss[@]}"}"; do
    if [[ "$r" == "ora.$SB_LSNR.lsnr" ]]; then
      RES_TODO+="srvctl add listener -listener $SB_LSNR -endpoints TCP:$PORT"$'\n'"srvctl start listener -listener $SB_LSNR"$'\n'
    else
      NOW="Resource $r does not exist (step 3.5)"; return 2
    fi
  done
  for r in "${off[@]+"${off[@]}"}"; do RES_TODO+="crsctl start res $r"$'\n'; done
  RES_TODO=${RES_TODO%$'\n'}
  NOW="Not ONLINE yet: ${off[*]+"${off[*]}"} ${miss[*]+"${miss[*]}"}"
  PLAN="Run as $GRID_USER:
$RES_TODO"
  return 1
}
d_3_9() {
  local c
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    local -a w=(); read -ra w <<< "$c"
    run_logged "$c" as_grid timeout 300 "$GRID_HOME/bin/${w[0]}" "${w[@]:1}" || { bad "$c failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    say "Ran: $c"
    [[ "$c" == "srvctl add listener"* ]] && journal LSNRRES "$SB_LSNR" "srvctl add listener"
  done <<< "$RES_TODO"
}

# ---- 3.10 listener port equal to primary (Grid listener) ----
c_3_10() {
  use_grid || { NOW="Not needed without Grid. Phase 5 creates the listener with port $PORT."; return 0; }
  grid_sw_ok || { NOW="Grid is not installed yet (step 3.2)"; return 2; }
  run_logged "lsnrctl status" as_grid timeout 60 "$GRID_HOME/bin/lsnrctl" status "$SB_LSNR" || { NOW="Listener $SB_LSNR is not running (step 3.9)"; return 2; }
  if grep -q "(PROTOCOL=TCP)(HOST=[^)]*)(PORT=$PORT)" <<< "$(norm "$RUN_OUT")"; then NOW="Listener $SB_LSNR uses port $PORT, the same as the primary"; return 0; fi
  local cur; cur=$(norm "$RUN_OUT" | grep -oE '\(PROTOCOL=TCP\)\(HOST=[^)]*\)\(PORT=[0-9]+\)' | head -n 1 | grep -oE '[0-9]+\)$' | tr -d ')')
  L310_CUR=$cur
  NOW="Listener $SB_LSNR uses port ${cur:-?}. The primary uses $PORT."
  PLAN="Run as $GRID_USER:
srvctl modify listener -listener $SB_LSNR -endpoints TCP:$PORT
srvctl stop listener -listener $SB_LSNR
srvctl start listener -listener $SB_LSNR"
  return 1
}
d_3_10() {
  run_logged "srvctl modify listener" as_grid "$GRID_HOME/bin/srvctl" modify listener -listener "$SB_LSNR" -endpoints "TCP:$PORT" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  journal LSNRPORT "$SB_LSNR" "old=${L310_CUR:-1521} new=$PORT"
  run_logged "srvctl stop listener" as_grid "$GRID_HOME/bin/srvctl" stop listener -listener "$SB_LSNR" || true
  run_logged "srvctl start listener" as_grid "$GRID_HOME/bin/srvctl" start listener -listener "$SB_LSNR" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
}

# ---- 3.11 same software level as primary ----
# The patches of a home are the folder names in <home>/inventory/oneoffs (what opatch lspatches reads).
local_patches() { ls -1 "$1/inventory/oneoffs" 2>/dev/null | grep -E '^[0-9]{6,9}$' | sort -u; }
primary_patches() {
  # $1 home on primary -> patch ids; rc 1 if the inventory of that home cannot be read
  prim_probe owner "$1/inventory" || return 1
  # no oneoffs folder = no patch was ever applied; any other failure (no answer) is not that
  if ! prim_probe owner "$1/inventory/oneoffs"; then
    # the answer of test itself (no error text in any language needed)
    prim_probe exists "$1/inventory/oneoffs" && [[ "$(head -n 1 <<< "$RUN_OUT")" == "NO" ]] && return 0
    return 1
  fi
  prim_probe lsdir "$1/inventory/oneoffs" || return 1           # it exists, so it must be readable
  grep -E '^[0-9]{6,9}$' <<< "$RUN_OUT" | sort -u
  return 0
}
local_release() {
  # base release of the installed database software, from sqlplus -V ("Release 19.0.0.0.0", "Version 19.21.0.0.0")
  run_logged "sqlplus -V" as_oracle "$DB_HOME/bin/sqlplus" -V || return 1
  grep -oE 'Release [0-9]+\.[0-9]+' <<< "$RUN_OUT" | head -n 1 | awk '{print $2}'
}
c_3_11() {
  db_sw_ok || { NOW="Database software is not installed yet (step 3.6)"; return 2; }
  need_ssh || return 2
  primary_edition || { NOW="Cannot read the edition of the primary"; return 2; }
  local rel want h pp lp missing extra report="" bad_rel=""
  rel=$(local_release || true); want=$(want_rel)
  if [[ -n "$rel" ]]; then
    if [[ "$DB_MAJOR" == "12" ]]; then [[ "$rel" == "$want" ]] || bad_rel="release $rel here, release $want on the primary"
    else [[ "${rel%%.*}" == "$DB_MAJOR" ]] || bad_rel="release $rel here, release $DB_MAJOR on the primary"; fi
  fi
  if [[ -n "$bad_rel" ]]; then
    NOW="The database software here is another release: $bad_rel"
    KIND_NOW=manual; MANUAL_HOW="root"
    PLAN="-- Remove this installation and install release $want (steps 3.1 and 3.6).
-- The standby must have the same release as the primary."
    return 1
  fi
  for h in "$DB_HOME" ${GRID_HOME:+"$GRID_HOME"}; do
    use_grid || [[ "$h" != "$GRID_HOME" ]] || continue
    pp=$(primary_patches "$h") || { NOW="Cannot read $h/inventory on the primary. The ssh user must be able to read it."; return 2; }
    lp=$(local_patches "$h")
    missing=$(comm -23 <(printf '%s\n' "$pp" | grep -v '^$') <(printf '%s\n' "$lp" | grep -v '^$') | paste -sd' ' -)
    extra=$(comm -13 <(printf '%s\n' "$pp" | grep -v '^$') <(printf '%s\n' "$lp" | grep -v '^$') | paste -sd' ' -)
    if [[ -n "$missing$extra" ]]; then
      report+="$h:${missing:+ missing here: $missing}${extra:+  only here: $extra}"$'\n'
    fi
  done
  if [[ -z "$report" ]]; then
    local np; np=$(local_patches "$DB_HOME" | wc -l)
    NOW="Same release and patches as the primary: release ${PRIMARY_VERSION:-${rel:-$want}}, Enterprise Edition"$'\n'"$np $([[ $np -eq 1 ]] && printf 'patch' || printf 'patches') in the database home${GRID_HOME:+; the Grid home matches too}"
    return 0
  fi
  NOW="The homes here do not have the same patches as the primary:"$'\n'"${report%$'\n'}"
  KIND_NOW=manual; MANUAL_HOW="root or $ORACLE_USER  ->  each step names the user"
  PLAN="-- Apply the primary's patches to the homes on this server.
-- 1) On the primary, as the owner of each home, list its patches:
<home>/OPatch/opatch lspatches
-- 2) Put the newest OPatch (patch 6880880) into $DB_HOME${GRID_HOME:+ and $GRID_HOME}."
  if use_grid; then
    PLAN+=$'\n'"-- 3) Apply the Release Update, as root:"
    PLAN+=$'\n'"$GRID_HOME/OPatch/opatchauto apply <RU folder> -oh $GRID_HOME ; $DB_HOME/OPatch/opatchauto apply <RU folder> -oh $DB_HOME"
  else
    PLAN+=$'\n'"-- 3) Apply the Release Update, as $ORACLE_USER:"
    PLAN+=$'\n'"cd <RU folder> ; $DB_HOME/OPatch/opatch apply"
  fi
  PLAN+=$'\n'"-- 4) Apply the one-off patches, as $ORACLE_USER:"
  PLAN+=$'\n'"cd <patch folder> ; $DB_HOME/OPatch/opatch apply"
  [[ $DB_MAJOR -ge 18 ]] && PLAN+=$'\n'"-- Easier: install from a gold image of the primary home, as shown in step 3.1."
  if use_grid && ! single_owner; then
    PLAN+=$'\n'"-- After opatch on the database home (role separation), as root:"
    PLAN+=$'\n'"$GRID_HOME/bin/setasmgidwrap o=$DB_HOME/bin/oracle"
  fi
  return 1
}

phase_3() {
  phase_header 3 "Install the Oracle software"
  build_envs_if_possible
  run_step 3.1  auto  "Installer files" c_3_1 d_3_1
  run_step 3.2  auto  "Grid Infrastructure software (Oracle Restart)" c_3_2 d_3_2
  run_step 3.3  auto  "Grid root scripts" c_3_3 d_3_3
  run_step 3.4  auto  "ASM and listener (Grid configuration)" c_3_4 d_3_4
  run_step 3.5  auto  "ASM disk groups (same names as primary)" c_3_5 d_3_5
  run_step 3.6  auto  "Database software (Software Only)" c_3_6 d_3_6
  run_step 3.7  auto  "Database root.sh" c_3_7 d_3_7
  run_step 3.8  auto  "Read/write Oracle home" c_3_8 d_3_8
  run_step 3.9  auto  "Oracle Restart resources ONLINE" c_3_9 d_3_9
  run_step 3.10 auto  "Listener port equal to primary ($PORT)" c_3_10 d_3_10
  run_step 3.11 check "Same release and patches as primary" c_3_11
}

#------------------------------------------------------------------------------
# PHASE 4  Primary readiness
#   Every check here is a SELECT (or lsnrctl status / tnsping) on primary.
#   Nothing is changed on primary: needed commands are printed for you.
#------------------------------------------------------------------------------
P_ORL_COUNT=0; P_ORL_BYTES=0; PVAL=""; SRL_BLOCKSIZE=""

need_ssh() {
  ssh_alive && return 0
  if [[ $SSH_OPEN -eq 1 ]]; then
    # the connection was open before (for example it timed out during a long duplicate)
    warn "The ssh connection to the primary was closed. Reconnecting."
    open_ssh && ssh_alive && return 0
  fi
  NOW="Not connected to the primary (step 1.2)"; return 1
}

p_param() {
  # $1 name -> PVAL (upper case, quotes removed, spaces collapsed). Read-only.
  prim_sql "select nvl(value,'-') from v\$parameter where name='$1';" || return 1
  PVAL=$(first_line | tr '[:lower:]' '[:upper:]' | tr -d "\"'" | tr -s '[:space:]' ' ' | sed -E 's/ *= */=/g; s/\( */(/g; s/ *\)/)/g; s/ *, */,/g')
}
has_token() {
  local t arr=()
  read -ra arr <<< "$(printf '%s' "$1" | tr ',()' '   ')"
  for t in "${arr[@]}"; do [[ "$t" == "$2" ]] && return 0; done
  return 1
}
disp_val() { if [[ -z "$1" || "$1" == "-" ]]; then printf '(not set)'; else printf '%s' "$1"; fi; }   # on screen only: "-" (no value) as "(not set)"
dg_config_has() {
  local inner=${1#*DG_CONFIG=}
  [[ "$inner" != "$1" ]] || return 1
  has_token "$inner" "${2^^}"
}

# ---- 4.1 ----
c_4_1() {
  need_ssh || return 2
  # every change of phase 4 (scope=spfile/both) and the duplicate (spfile clause) needs a primary started from an spfile
  prim_sql "select nvl(value,'-') from v\$parameter where name='spfile';" || { NOW="Query on the primary failed ($(ora_errors "$SQL_OUT"))"; return 2; }
  if [[ "$(first_line)" == "-" ]]; then
    NOW="The primary was started from a text pfile, not from an spfile."$'\n'"The changes of this phase and the RMAN copy need an spfile."
    PLAN="create pfile='?/dbs/init${PRIMARY_SID}_before_dg.ora' from memory;
create spfile from memory;
-- Then restart the primary once (shutdown immediate; startup) at a quiet time.
-- After the restart it uses the spfile. The other changes of this phase need it."
    PLAN_UNDO="delete \$ORACLE_HOME/dbs/spfile${PRIMARY_SID}.ora, then restart with:  startup pfile='\$ORACLE_HOME/dbs/init${PRIMARY_SID}_before_dg.ora'"
    return 1
  fi
  prim_sql "select log_mode||'|'||force_logging from v\$database;" || { NOW="Query on the primary failed ($(ora_errors "$SQL_OUT"))"; return 2; }
  local lm fl; IFS='|' read -r lm fl <<< "$(first_line)"
  if [[ "$lm" == "ARCHIVELOG" && "$fl" == "YES" ]]; then NOW="ARCHIVELOG mode and FORCE LOGGING are on"; return 0; fi
  NOW="log_mode is $lm, force_logging is $fl"
  PLAN=""
  [[ "$fl" != "YES" ]] && PLAN+="alter database force logging;"$'\n'
  [[ "$lm" != "ARCHIVELOG" ]] && PLAN+="-- DOWNTIME: the next 4 lines restart the primary database
shutdown immediate
startup mount
alter database archivelog;
alter database open;"
  PLAN=${PLAN%$'\n'}
  PLAN_UNDO=""; [[ "$fl" != "YES" ]] && PLAN_UNDO="alter database no force logging;"
  [[ "$lm" != "ARCHIVELOG" ]] && PLAN_UNDO+="${PLAN_UNDO:+ }-- keep ARCHIVELOG mode (every backup needs it)"
  return 1
}

# ---- 4.2 ----
SRL_STMTS=""; SRL_INFO=""
srl_statements() {
  # $1 = prim_sql | sql_local. Standby redo logs needed: per thread (online groups + 1), size = largest online log.
  # Sets SRL_STMTS (the ALTER statements, empty when nothing is needed) and SRL_INFO. rc 2 = query failed.
  local run=$1 t c mb maxb have omf maxg dir spec g line
  "$run" "select thread#||'|'||count(*)||'|'||max(bytes) from v\$log group by thread# order by thread#;" || return 2
  local threads=$SQL_OUT
  "$run" "select thread#||'|'||count(*) from v\$standby_log where bytes>=(select max(bytes) from v\$log) group by thread#;" || return 2
  local good=$SQL_OUT
  "$run" "select (select max(blocksize) from v\$log)||'|'||(select count(*) from v\$standby_log where bytes<(select max(bytes) from v\$log)) from dual;" || return 2
  local bsz small; IFS='|' read -r bsz small <<< "$(first_line)"
  local bclause=""; [[ "$bsz" == "4096" ]] && bclause=" blocksize 4096"
  SRL_BLOCKSIZE=$bsz
  [[ -n "$bclause" ]] && SRL_INFO_EXTRA="The online logs use 4096-byte blocks."$'\n'"The standby disks must support 4K sectors, or you get ORA-01378." || SRL_INFO_EXTRA=""
  # standby logs without a thread (thread 0) can serve any thread
  local pool0; pool0=$(awk -F'|' '$1==0 {print $2}' <<< "$good"); num "$pool0" || pool0=0
  "$run" "select (select nvl(max(value),'-') from v\$parameter where name in ('db_create_file_dest','db_create_online_log_dest_1') and value is not null)||'|'||(select max(group#) from (select group# from v\$log union all select group# from v\$standby_log))||'|'||nvl((select min(substr(member,1,instr(member,'/',-1)-1)) keep (dense_rank first order by group#, member) from v\$logfile where type='ONLINE' and upper(member) not like (select upper(nvl(max(value),'#none#'))||'%' from v\$parameter where name='db_recovery_file_dest')),(select max(substr(member,1,instr(member,'/',-1)-1)) from v\$logfile where type='ONLINE')) from dual;" || return 2
  IFS='|' read -r omf maxg dir <<< "$(first_line)"
  num "$maxg" || return 2
  maxb=$(awk -F'|' '{if ($3 > m) m = $3} END {print m+0}' <<< "$threads")
  num "$maxb" && [[ $maxb -gt 0 ]] || return 2
  mb=$(( (maxb + 1048575) / 1048576 )); g=$maxg
  SRL_STMTS=""; SRL_INFO=""
  while IFS='|' read -r t c _; do
    num "$t" && num "$c" || continue
    have=$(awk -F'|' -v t="$t" '$1==t {print $2}' <<< "$good"); num "$have" || have=0
    SRL_INFO+="Thread $t: $c online log groups. Standby logs: $have of $((c + 1)) needed (${mb}M each)"$'\n'
    while [[ $have -lt $((c + 1)) && $pool0 -gt 0 ]]; do have=$((have + 1)); pool0=$((pool0 - 1)); done
    while [[ $have -lt $((c + 1)) ]]; do
      if [[ "$omf" != "-" && -n "$omf" ]]; then spec=""
      elif [[ "$dir" == +* ]]; then spec=" ('${dir%%/*}')"
      else g=$((g + 1)); spec=" group $g ('$dir/srl_t${t}_g${g}.log')"; fi
      SRL_STMTS+="alter database add standby logfile thread $t$spec size ${mb}M$bclause;"$'\n'
      have=$((have + 1))
    done
  done <<< "$threads"
  num "$small" && [[ $small -gt 0 ]] && SRL_INFO+="$small standby log(s) are smaller than the online logs and do not count."$'\n'"Drop them with:  alter database drop standby logfile group <n>;"$'\n'
  [[ -n "$SRL_INFO_EXTRA" ]] && SRL_INFO+="$SRL_INFO_EXTRA"$'\n'
  SRL_INFO=${SRL_INFO%$'\n'}; SRL_STMTS=${SRL_STMTS%$'\n'}
  [[ -z "$SRL_STMTS" ]]
}
c_4_2() {
  need_ssh || return 2
  local rc=0; srl_statements prim_sql || rc=$?
  [[ $rc -eq 2 ]] && { NOW="Query on the primary failed ($(ora_errors "$SQL_OUT"))"; return 2; }
  NOW=$SRL_INFO
  [[ $rc -eq 0 ]] && return 0
  PLAN=$SRL_STMTS
  USING="Per thread: online log groups + 1, each as large as the largest online log"
  local gl; gl=$(grep -oE 'group [0-9]+' <<< "$SRL_STMTS" | awk '{print $2}' | paste -sd',' -)
  if [[ -n "$gl" ]]; then PLAN_UNDO="alter database drop standby logfile group <n>;  for groups $gl, then delete their files"
  else PLAN_UNDO="alter database drop standby logfile group <n>;  for each new group. To list them:  select group#,thread#,bytes from v\$standby_log;"; fi
  return 1
}

# ---- 4.3 ----
c_4_3() {
  need_ssh || return 2
  p_param log_archive_config || { NOW="Query on the primary failed"; return 2; }
  if dg_config_has "$PVAL" "$PRIMARY_UNIQUE" && dg_config_has "$PVAL" "$STANDBY_UNIQUE"; then NOW="log_archive_config = $(disp_val "$PVAL")"; return 0; fi
  NOW="log_archive_config = $(disp_val "$PVAL")"
  dg_config_names_ok "$PVAL" || { NOW+=$'\n'"The names in this list cannot be read safely."$'\n'"Add $STANDBY_UNIQUE to the dg_config list by hand. Keep all other names."; return 2; }
  PLAN="alter system set log_archive_config='$(lac_merged "$PVAL")' scope=both;"
  [[ "$PVAL" == *DG_CONFIG=* ]] && PLAN+=$'\n'"-- This keeps the names already in the list and adds $STANDBY_UNIQUE."
  if [[ "$PVAL" == *DG_CONFIG=* ]]; then PLAN_UNDO="alter system set log_archive_config='$PVAL' scope=both;"
  else PLAN_UNDO="alter system reset log_archive_config scope=both;"; fi
  return 1
}
dg_config_merged() {
  # $1 current value -> comma list: existing members (in their order) + primary + standby, no doubles
  local inner="" t out="" seen=" "
  [[ "$1" == *DG_CONFIG=* ]] && { inner=${1#*DG_CONFIG=}; inner=${inner#(}; inner=${inner%%)*}; }
  for t in $(tr ',' ' ' <<< "$inner") "$PRIMARY_UNIQUE" "$STANDBY_UNIQUE"; do
    [[ -n "$t" ]] || continue
    [[ "$seen" == *" ${t^^} "* ]] && continue
    seen+="${t^^} "; out+="${out:+,}$t"
  done
  printf '%s' "$out"
}
lac_merged() {
  # $1 current log_archive_config (p_param form) -> the full new value: other keywords (SEND, NORECEIVE ...) kept,
  # dg_config = the existing names + primary + standby
  local v=$1 pre post rest m
  m=$(dg_config_merged "$v")
  if [[ "$v" == *DG_CONFIG=* ]]; then
    pre=${v%%DG_CONFIG=*}; rest=${v#*DG_CONFIG=}; post=""
    [[ "$rest" == *")"* ]] && post=${rest#*)}
    printf '%sdg_config=(%s)%s' "$pre" "$m" "$post"
  elif [[ -z "$v" || "$v" == "-" ]]; then printf 'dg_config=(%s)' "$m"
  else
    # NODG_CONFIG would contradict the new list: it goes
    local rest2; rest2=$(tr ',' '\n' <<< "$v" | grep -vx 'NODG_CONFIG' | paste -sd, -)
    if [[ -n "$rest2" ]]; then printf '%s,dg_config=(%s)' "$rest2" "$m"; else printf 'dg_config=(%s)' "$m"; fi
  fi
}
dg_config_names_ok() {
  # 1 when the value has DG_CONFIG but no name can be read from it (then nothing is printed: a wrong list would cut off another standby)
  [[ "$1" == *DG_CONFIG=* ]] || return 0
  local inner=${1#*DG_CONFIG=}; inner=${inner#(}; inner=${inner%%)*}
  [[ "$inner" =~ ^[A-Z0-9_$#]+(,[A-Z0-9_$#]+)*$ ]]
}

# ---- 4.4 ----
DEST_N=""
find_dest() {
  # Which log_archive_dest_N on primary ships (or will ship) to this standby. Read-only.
  # 1) an N that already points to the standby alias, 2) dest_2 if it is free, 3) the first free N.
  prim_sql "select name||'|'||nvl(value,'-') from v\$parameter where name like 'log_archive_dest_%';" || return 1
  local line n v used=" "
  DEST_N=""
  while IFS= read -r line; do
    [[ "$line" =~ ^log_archive_dest_([0-9]+)\|(.*)$ ]] || continue
    n=${BASH_REMATCH[1]}; v=$(tr '[:lower:]' '[:upper:]' <<< "${BASH_REMATCH[2]}" | tr -d "\"'" | sed -E 's/ *= */=/g')
    num "$n" && [[ $n -ge 2 && $n -le 31 ]] || continue
    if has_token "$v" "SERVICE=${STANDBY_TNS^^}"; then DEST_N=$n; return 0; fi
    [[ "$v" == "-" ]] || used+="$n "
  done <<< "$SQL_OUT"
  # a destination without a value (or not listed) is free; prefer 2
  for ((n = 2; n <= 31; n++)); do [[ "$used" == *" $n "* ]] || { DEST_N=$n; return 0; }; done
  return 1
}
c_4_4() {
  need_ssh || return 2
  # log_archive_dest may have been moved on the primary since it was read (answer r): read it again
  if [[ -n "$OLD_ARCH_DEST" ]]; then read_arch_params || { NOW="Cannot read the archive parameters on the primary"; return 2; }; fi
  find_dest || { NOW="No free log_archive_dest_N on the primary"; return 2; }
  p_param "log_archive_dest_$DEST_N" || { NOW="Query on the primary failed"; return 2; }
  if has_token "$PVAL" "SERVICE=${STANDBY_TNS^^}" && has_token "$PVAL" "DB_UNIQUE_NAME=${STANDBY_UNIQUE^^}"; then NOW="log_archive_dest_$DEST_N points to the standby:"$'\n'"  $PVAL"; return 0; fi
  NOW="log_archive_dest_$DEST_N = $(disp_val "$PVAL")"
  [[ "$DEST_N" != "2" ]] && NOW+=$'\n'"log_archive_dest_2 is used for something else, so log_archive_dest_$DEST_N is used"
  PLAN=""
  if [[ -n "$OLD_ARCH_DEST" ]]; then
    NOW+=$'\n'"The primary uses the old parameter log_archive_dest."$'\n'"log_archive_dest_N cannot be used together with it (ORA-16018)."
    # the duplex folder exactly as written (p_param changes the case)
    local dup="-"; prim_sql "select nvl(value,'-') from v\$parameter where name='log_archive_duplex_dest';" && dup=$(first_line)
    PLAN="-- First move log_archive_dest to log_archive_dest_1 (same folder).
-- Run these lines together: between them the archiver writes to \$ORACLE_HOME/dbs.
"
    if [[ -n "$dup" && "$dup" != "-" ]]; then
      local dn=3; [[ "$DEST_N" == "3" ]] && dn=4
      PLAN+="alter system set log_archive_duplex_dest='' scope=both;
alter system set log_archive_dest='' scope=both;
alter system set log_archive_dest_1='location=$OLD_ARCH_DEST' scope=both;
alter system set log_archive_dest_$dn='location=$dup' scope=both;     -- the duplex folder, kept (check that dest_$dn is free)
"
    else
      PLAN+="alter system set log_archive_dest='' scope=both;
alter system set log_archive_dest_1='location=$OLD_ARCH_DEST' scope=both;
"
    fi
  fi
  # the state first: an enabled destination to a standby that does not exist yet fills the alert log with errors
  PLAN+="alter system set log_archive_dest_state_$DEST_N=defer scope=both;
alter system set log_archive_dest_$DEST_N='service=$STANDBY_TNS async valid_for=(online_logfiles,primary_role) db_unique_name=$STANDBY_UNIQUE' scope=both;
-- Step 9.5 enables it, after the standby exists."
  PLAN_UNDO="alter system reset log_archive_dest_$DEST_N scope=both; alter system reset log_archive_dest_state_$DEST_N scope=both;"
  [[ -n "$OLD_ARCH_DEST" ]] && PLAN_UNDO+="   (log_archive_dest_1='location=$OLD_ARCH_DEST' can stay)"
  return 1
}

# ---- 4.5 ----
c_4_5() {
  need_ssh || return 2
  p_param standby_file_management || { NOW="Query on the primary failed"; return 2; }
  [[ "$PVAL" == "AUTO" ]] && { NOW="standby_file_management = AUTO"; return 0; }
  NOW="standby_file_management = $(disp_val "$PVAL")"
  PLAN="alter system set standby_file_management=auto scope=both;"
  local sfm_old=$PVAL; [[ -z "$sfm_old" || "$sfm_old" == "-" ]] && sfm_old=MANUAL    # "-" means not set (MANUAL is the default)
  PLAN_UNDO="alter system set standby_file_management=$sfm_old scope=both;"
  return 1
}

# ---- 4.6 ----
c_4_6() {
  need_ssh || return 2
  # read again from the primary: a change made at this step is seen at once
  local of=$FRA_LOC oa=$ARCH_LOC
  read_arch_params || { NOW="Cannot read the archive parameters on the primary"; return 2; }
  [[ "$of|$oa" != "$FRA_LOC|$ARCH_LOC" && "$MODE" == "run" ]] && { save_settings; warn "The recovery area or archive destination on the primary changed."$'\n'"Recovery area: ${FRA_LOC:-none}   Archive destination: ${ARCH_LOC:-none}"$'\n'"$( { step_in_range 2.12 && [[ -z "${STEP_RESULT[2.12]:-}" ]]; } && printf 'Phase 2 of this run uses the new values.' || printf 'This server needs it too. After this run, run:  %s --from 2.12' "$SELF")"; }
  if [[ "$ARCH_LOC" == "USE_DB_RECOVERY_FILE_DEST" && -n "$FRA_LOC" ]]; then NOW="Archived logs go to the recovery area $FRA_LOC ($(human_mb "$FRA_MB"))"; return 0; fi
  if [[ -n "$ARCH_LOC" && "$ARCH_LOC" != "USE_DB_RECOVERY_FILE_DEST" ]]; then
    NOW="Archived logs go to $ARCH_LOC${FRA_LOC:+ (recovery area $FRA_LOC)}"
    [[ -n "$FRA_LOC" ]] || NOW+=$'\n'"No recovery area. Data Guard works without it."$'\n'"Flashback and automatic deletion of applied logs need one."
    return 0
  fi
  NOW="The primary has no archive destination and no recovery area."$'\n'"Its archived logs go to \$ORACLE_HOME/dbs."
  if [[ -n "$DATA_DG" ]]; then
    PLAN="alter system set db_recovery_file_dest_size=<size, e.g. 200G> scope=both;
alter system set db_recovery_file_dest='+<a disk group for it, e.g. FRA>' scope=both;"
  else
    PLAN="-- Use a folder with enough space, owned by $ORACLE_USER, for example:
host mkdir -p /u01/app/oracle/fast_recovery_area
alter system set db_recovery_file_dest_size=<size, e.g. 200G> scope=both;
alter system set db_recovery_file_dest='/u01/app/oracle/fast_recovery_area' scope=both;"
  fi
  PLAN+=$'\n'"-- The archived logs of the primary then go there. Then answer r here."
  PLAN_UNDO="alter system reset db_recovery_file_dest scope=both; alter system reset db_recovery_file_dest_size scope=both;  only after the archived logs in it are backed up"
  return 1
}

# ---- 4.7 ----
c_4_7() {
  need_ssh || return 2
  p_param remote_login_passwordfile || { NOW="Query on the primary failed"; return 2; }
  local rlp=$PVAL
  prim_sql "select count(*) from v\$pwfile_users where username='SYS' and sysdba='TRUE';" || { NOW="Query on the primary failed"; return 2; }
  local n; n=$(first_line); num "$n" || { NOW="Unexpected answer from the primary: $n"; return 2; }
  if [[ ( "$rlp" == "EXCLUSIVE" || "$rlp" == "SHARED" ) && "$n" -ge 1 ]]; then NOW="remote_login_passwordfile = $rlp, SYS has SYSDBA in the password file"; RLP_PENDING=0; return 0; fi
  NOW="remote_login_passwordfile = $rlp, SYS in the password file: $([[ "$n" -ge 1 ]] && echo yes || echo no)"
  PLAN=""; PLAN_UNDO=""; RLP_PENDING=0
  if [[ "$rlp" != "EXCLUSIVE" && "$rlp" != "SHARED" ]]; then
    # already set in the spfile? then only the restart is missing
    local sp="-"
    prim_sql "select nvl(max(upper(value)),'-') from v\$spparameter where name='remote_login_passwordfile';" && sp=$(first_line | tr -d "\"'")
    if [[ "$sp" == "EXCLUSIVE" || "$sp" == "SHARED" ]]; then
      RLP_PENDING=1
      NOW+=$'\n'"remote_login_passwordfile=$sp is already in the spfile."
      NOW+=$'\n'"It takes effect when the primary restarts."
      NOW+=$'\n'"Answer s for now. The RMAN copy (step 8.1) does not start until the primary has restarted."
      PLAN="-- Restart the primary at a quiet time (as $ORACLE_USER, sqlplus / as sysdba):
shutdown immediate
startup"
    else
      PLAN+="alter system set remote_login_passwordfile=exclusive scope=spfile;
-- Then restart the primary at a quiet time."$'\n'
      PLAN_UNDO="alter system set remote_login_passwordfile=${rlp:-NONE} scope=spfile;  then restart"
    fi
  fi
  if [[ "$n" -lt 1 ]]; then
    # is there a password file at all? ("alter user" cannot create one; with remote_login_passwordfile=NONE the
    # view of its users is empty even when the file exists)
    local pwf="" ans=""
    prim_sql "select nvl(max(file_name),'-') from v\$passwordfile_info;" && pwf=$(first_line)
    if [[ -z "$pwf" || "$pwf" == "-" ]]; then
      prim_probe exists "$DB_HOME/dbs/orapw$PRIMARY_SID"; ans=$(head -n 1 <<< "$RUN_OUT")
      case "$ans" in YES) pwf="$DB_HOME/dbs/orapw$PRIMARY_SID" ;; NO) pwf="-" ;; *) pwf="?" ;; esac
    fi
    if [[ "$pwf" == "-" && -n "$GRID_HOME" ]]; then
      NOW+=$'\n'"The password file may be in ASM. Check on the primary as $ORACLE_USER:"
      NOW+=$'\n'"  $DB_HOME/bin/srvctl config database -db $PRIMARY_UNIQUE | grep -i password"
    fi
    if [[ "$pwf" == "?" ]]; then
      NOW+=$'\n'"No answer from the primary: cannot tell if it has a password file. Check again later."; return 2
    elif [[ "$pwf" == "-" ]]; then
      local fmt=12.2; [[ "$PRIMARY_VERSION" == 12.1* ]] && fmt=12
      if [[ -n "$GRID_HOME" && "$CFD" == +* ]]; then
        PLAN="-- The primary has no password file. Create it in ASM.
-- Run orapwd in a SHELL as $GRID_USER or $ORACLE_USER, not in sqlplus.
-- orapwd asks for the sys password: type the same one the primary uses now.
-- If orapwd answers OPW-00029 (password complexity), use format=12.
orapwd file='$(norm_loc "$CFD")/${PRIMARY_UNIQUE^^}/orapw${PRIMARY_UNIQUE,,}' dbuniquename=$PRIMARY_UNIQUE format=$fmt
-- Only if 'srvctl config database -db $PRIMARY_UNIQUE' works (the database is registered):
srvctl modify database -db $PRIMARY_UNIQUE -pwfile '$(norm_loc "$CFD")/${PRIMARY_UNIQUE^^}/orapw${PRIMARY_UNIQUE,,}'
-- If this step still says SYS is missing afterwards, restart the primary once."$'\n'"$PLAN"
      else
        PLAN="-- The primary has no password file. Create it with orapwd
-- in a SHELL as $ORACLE_USER, not in sqlplus.
-- orapwd asks for the sys password: type the same one the primary uses now.
-- If orapwd answers OPW-00029 (password complexity), use format=12.
orapwd file=\$ORACLE_HOME/dbs/orapw$PRIMARY_SID format=$fmt"$'\n'"$PLAN"
      fi
      PLAN_UNDO+="${PLAN_UNDO:+ ; }delete the new password file"
    elif [[ "$rlp" != "EXCLUSIVE" && "$rlp" != "SHARED" ]]; then
      NOW+=$'\n'"The password file exists: $pwf. SYS is checked again after the restart."
    else
      PLAN+="alter user sys identified by \"<the same sys password as now>\";
-- Keep the same password: every client that logs in as sys uses it.
-- A password change cannot be taken back."
    fi
  fi
  PLAN=${PLAN%$'\n'}
  return 1
}
RLP_PENDING=0

# ---- 4.8 ----
c_4_8() {
  need_ssh || return 2
  p_param fal_server || { NOW="Query on the primary failed"; return 2; }
  if has_token "$PVAL" "${STANDBY_TNS^^}"; then NOW="fal_server = $PVAL"; return 0; fi
  NOW="fal_server = $(disp_val "$PVAL")"
  PLAN="alter system set fal_server='$STANDBY_TNS' scope=both;"
  PLAN_UNDO="alter system reset fal_server scope=both;"
  return 1
}

# ---- 4.9 ----
tns_block() {
  printf '%s =\n  (DESCRIPTION =\n    (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))\n    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = %s)(UR = A))\n  )\n' "$1" "$2" "$PORT" "$3"
}
tns_desc_ok() {
  # $1 tnsping output, $2 host, $3 service -> 0 if the resolved descriptor matches
  local d eh; d=$(norm "$(grep -i 'Attempting to contact' <<< "$1")")
  [[ "$d" =~ \(HOST=([^\)]*)\) ]] || { TNS_WHY="no HOST in the entry"; return 1; }
  eh=${BASH_REMATCH[1]}
  if [[ "$eh" != "${2^^}" ]]; then
    local a1 a2
    if [[ "$eh" =~ ^[0-9.]+$ ]]; then a1=$eh; else a1=$(getent ahostsv4 "${eh,,}" | awk '{print $1; exit}'); fi
    a2=$(getent ahostsv4 "$2" | awk '{print $1; exit}')
    [[ -n "$a1" && "$a1" == "$a2" ]] || { TNS_WHY="HOST is ${eh,,}, expected $2"; return 1; }
  fi
  [[ "$d" == *"(SERVICE_NAME=${3^^})"* ]] || { TNS_WHY="SERVICE_NAME is not $3"; return 1; }
  [[ "$d" == *"(UR=A)"* ]] || { TNS_WHY="(UR = A) is missing"; return 1; }
  [[ "$d" == *"(PORT=$PORT)"* ]] || { TNS_WHY="PORT is not $PORT"; return 1; }
  return 0
}
tnsping_class() {
  # $1 tnsping output -> OK | NOLISTENER (alias resolved, nothing answers there yet) | MISSING | OTHER
  if grep -q '^OK' <<< "$1"; then printf 'OK'
  elif grep -qE 'TNS-12541|TNS-12543|TNS-12535|TNS-12170|TNS-12560|TNS-12547' <<< "$1" && grep -qi 'Attempting to contact' <<< "$1"; then printf 'NOLISTENER'
  elif grep -qE 'TNS-03505|TNS-12154' <<< "$1" || ! grep -qi 'adapter' <<< "$1"; then printf 'MISSING'
  else printf 'OTHER'; fi
}
c_4_9() {
  need_ssh || return 2
  PRIMARY_HOW_STEP="$ORACLE_USER  ->  shell"
  local cls=MISSING
  prim_probe tnsping "$DB_HOME" "$PRIMARY_TNS_ADMIN" "$STANDBY_TNS" || true
  [[ $PROBE_TIMED_OUT -eq 1 ]] && { NOW="tnsping on the primary gave no answer within 120 seconds. Answer r to check again."; return 2; }
  cls=$(tnsping_class "$RUN_OUT")
  PLAN_UNDO="remove the $STANDBY_TNS entry from $PRIMARY_TNS_ADMIN/tnsnames.ora, or put back the backup if you changed an existing entry"
  if [[ "$cls" == "OK" || "$cls" == "NOLISTENER" ]] && grep -qi 'TNSNAMES adapter' <<< "$RUN_OUT"; then
    if tns_desc_ok "$RUN_OUT" "$STANDBY_HOST" "$STANDBY_SERVICE"; then
      NOW="tnsnames.ora on the primary has $STANDBY_TNS = $STANDBY_HOST:$PORT/$STANDBY_SERVICE (UR=A)"
      [[ "$cls" == "NOLISTENER" ]] && NOW+=$'\n'"The alias is right. Nothing answers on this server yet: the listener comes in phase 5."
      return 0
    fi
    NOW="The alias $STANDBY_TNS on the primary is different: $TNS_WHY"
    PLAN="-- Edit $PRIMARY_TNS_ADMIN/tnsnames.ora on the primary.
-- Back it up first (cp -p tnsnames.ora tnsnames.ora.bak_\$(date +%F)). The entry must be:
$(tns_block "$STANDBY_TNS" "$STANDBY_HOST" "$STANDBY_SERVICE")"
    return 1
  fi
  [[ "$cls" == "OTHER" ]] && { NOW="tnsping $STANDBY_TNS on the primary gave an unexpected answer: $(ora_errors "$RUN_OUT")"; return 2; }
  NOW="The alias $STANDBY_TNS is missing from tnsnames.ora on the primary:"$'\n'"  $PRIMARY_TNS_ADMIN/tnsnames.ora"
  PLAN="cp -p $PRIMARY_TNS_ADMIN/tnsnames.ora $PRIMARY_TNS_ADMIN/tnsnames.ora.bak_\$(date +%F)
cat >> $PRIMARY_TNS_ADMIN/tnsnames.ora <<'EOF'

$(tns_block "$STANDBY_TNS" "$STANDBY_HOST" "$STANDBY_SERVICE")
EOF
env ORACLE_HOME=$DB_HOME TNS_ADMIN=$PRIMARY_TNS_ADMIN $DB_HOME/bin/tnsping $STANDBY_TNS
# TNS-12541 (no listener) is normal before phase 5"
  USING="Standby host $STANDBY_HOST, port $PORT, service $STANDBY_SERVICE"
  return 1
}

# ---- 4.10 ----
c_4_10() {
  need_ssh || return 2
  local lown; lown=$([[ "$PRIMARY_LISTENER_HOME" == "$DB_HOME" ]] && printf '%s' "$ORACLE_USER" || printf '%s' "$GRID_USER")
  PRIMARY_HOW_STEP="$lown  ->  shell"
  if [[ -n "${PRIMARY_LISTENER_TNS_ADMIN:-}" ]]; then prim_probe lsnr "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME" "$PRIMARY_LISTENER_TNS_ADMIN" || { NOW="Cannot read the listener status on the primary"; return 2; }
  else prim_probe lsnr "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME" || { NOW="Cannot read the listener status on the primary"; return 2; }; fi
  if grep -qF "Instance \"$PRIMARY_SID\", status UNKNOWN" <<< "$RUN_OUT"; then
    NOW="The primary listener has a static entry for $PRIMARY_SID"; return 0
  fi
  NOW="The primary listener has no static entry for $PRIMARY_SID."
  PLAN="-- Edit this file (or the listener.ora in its TNS_ADMIN, if set):
--   $PRIMARY_LISTENER_HOME/network/admin/listener.ora
-- Add this inside SID_LIST_$LISTENER_NAME, or create the block if it is missing.
-- ORACLE_HOME must be the database home, not the Grid home.
SID_LIST_$LISTENER_NAME =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = $PRIMARY_SERVICE)
      (SID_NAME = $PRIMARY_SID)
      (ORACLE_HOME = $DB_HOME)
    )
  )
-- Then reload the listener:
ORACLE_HOME=$PRIMARY_LISTENER_HOME $PRIMARY_LISTENER_HOME/bin/lsnrctl reload $LISTENER_NAME"
  PLAN_UNDO="remove that SID_DESC block from listener.ora, then run lsnrctl reload $LISTENER_NAME"
  return 1
}

# ---- 4.11 environment of oracle on primary (information) ----
c_4_11() {
  need_ssh || return 2
  if [[ "$PRIMARY_SSH_USER" != "$ORACLE_USER" ]]; then NOW="Not checked: the ssh user $PRIMARY_SSH_USER is not $ORACLE_USER"; return 0; fi
  PRIMARY_HOW_STEP="$ORACLE_USER  ->  Adds 4 lines to ~/.bash_profile"
  prim_probe profile || true
  [[ $PROBE_TIMED_OUT -eq 1 ]] && { NOW="The primary did not answer in time. Answer r to check again."; return 2; }
  local sid home
  sid=$(grep -E 'ORACLE_SID=' <<< "$RUN_OUT" | tail -n 1 | sed -E 's/.*ORACLE_SID=//; s/["'"'"']//g; s/[[:space:]].*//')
  home=$(grep -E 'ORACLE_HOME=' <<< "$RUN_OUT" | tail -n 1 | sed -E 's/.*ORACLE_HOME=//; s/["'"'"']//g; s/[[:space:]].*//')
  home=${home%/}
  if [[ "$sid" == "$PRIMARY_SID" && ( "$home" == "$DB_HOME" || "$home" == *'$'* ) ]]; then NOW="~/.bash_profile of $ORACLE_USER on the primary sets ORACLE_SID=$sid and ORACLE_HOME"; return 0; fi
  NOW="~/.bash_profile of $ORACLE_USER on the primary: ORACLE_SID=${sid:-<not set>} ORACLE_HOME=${home:-<not set>}"
  NOW+=$'\n'"This script does not need it, but sqlplus, rman and dgmgrl by hand do."
  PLAN="cat >> ~/.bash_profile <<'EOF'
export ORACLE_BASE=$ORACLE_BASE
export ORACLE_HOME=$DB_HOME
export ORACLE_SID=$PRIMARY_SID
export PATH=\$ORACLE_HOME/bin:\$PATH
EOF"
  PLAN_UNDO="remove those 4 lines from ~/.bash_profile of $ORACLE_USER"
  return 1
}

phase_4() {
  phase_header 4 "Prepare the primary"
  say "The script only reads the primary. You run the changes it shows."
  STEP_TITLE_HINT=([4.1]="ARCHIVELOG and FORCE LOGGING" [4.2]="Standby redo logs" [4.3]="Data Guard names (log_archive_config)" [4.4]="Redo transport to the standby (log_archive_dest_N)" [4.5]="Automatic standby files (standby_file_management)" [4.6]="Archive destination and recovery area" [4.7]="Password file and SYS" [4.8]="fal_server (optional, for switchover)")
  batch_primary_steps 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8
  run_step 4.1  primary "ARCHIVELOG and FORCE LOGGING" c_4_1
  run_step 4.2  primary "Standby redo logs on the primary" c_4_2
  run_step 4.3  primary "Data Guard names (log_archive_config)" c_4_3
  run_step 4.4  primary "Redo transport to the standby (log_archive_dest_N)" c_4_4
  run_step 4.5  primary "Automatic standby files (standby_file_management)" c_4_5
  run_step 4.6  primary "Archive destination and recovery area" c_4_6
  run_step 4.7  primary "Password file and SYS" c_4_7
  run_step 4.8  primary "fal_server (for switchover)" c_4_8
  run_step 4.9  primary "Standby alias in the primary tnsnames.ora" c_4_9
  run_step 4.10 primary "Static listener entry on the primary" c_4_10
  run_step 4.11 primary "Environment of $ORACLE_USER on the primary" c_4_11
}

#------------------------------------------------------------------------------
# PHASE 5  Network files on this server
#------------------------------------------------------------------------------
lsnr_file() { printf '%s/network/admin/listener.ora' "$(lsnr_home)"; }
tns_file()  { printf '%s/network/admin/tnsnames.ora' "$DB_HOME"; }

static_entry_state() {
  # 0 = correct, 1 = missing, 2 = present with another ORACLE_HOME
  local f; f=$(lsnr_file)
  [[ -f "$f" ]] || return 1
  local flat seg found=1 sidn homen
  flat=$(norm "$(sed 's/#.*//' "$f")")
  sidn="(SID_NAME=${STANDBY_SID^^})"; homen="(ORACLE_HOME=${DB_HOME^^})"
  while IFS= read -r seg || [[ -n "$seg" ]]; do
    if [[ "$seg" == *"$sidn"* ]]; then
      [[ "$seg" == *"$homen"* || "$seg" == *"(ORACLE_HOME=${DB_HOME^^}/)"* ]] && return 0
      found=2
    fi
  done < <(printf '%s' "$flat" | sed 's/(SID_DESC=/\n(SID_DESC=/g')
  return $found
}
lsnr_has_sidlist() { local f; f=$(lsnr_file); [[ -f "$f" ]] && grep -qiE "^[[:space:]]*SID_LIST_${SB_LSNR}[[:space:]]*=" "$f"; }
static_block() {
  printf 'SID_LIST_%s =\n  (SID_LIST =\n    (SID_DESC =\n      (GLOBAL_DBNAME = %s)\n      (SID_NAME = %s)\n      (ORACLE_HOME = %s)\n    )\n  )\n' \
    "$SB_LSNR" "$STANDBY_SERVICE" "$STANDBY_SID" "$DB_HOME"
}

lsnr_desc_block() {
  printf '%s =\n  (DESCRIPTION_LIST =\n    (DESCRIPTION =\n      (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))\n    )\n  )\n' \
    "$SB_LSNR" "$STANDBY_HOST" "$PORT"
}
lsnr_has_desc() { local f; f=$(lsnr_file); [[ -f "$f" ]] && grep -qiE "^[[:space:]]*${SB_LSNR}[[:space:]]*=" "$f"; }

# ---- 5.1 ----
L51_MODE=""
port_owner_pid() {
  # pid of a program that listens on TCP port $1 (empty when nobody does)
  # iproute 3.10 of OL7 < 7.5 prints users:(("tnslsnr",1234,8)); newer ones users:(("tnslsnr",pid=1234,fd=8))
  ss -ltnp "( sport = :$1 )" 2>/dev/null | grep -oE 'users:\(\("[^"]*",(pid=)?[0-9]+' | head -n 1 | grep -oE '[0-9]+$'
}
c_5_1() {
  lsnr_sw_ok || { NOW="The listener software is not installed yet (phase 3)"; return 2; }
  local st=0 f; f=$(lsnr_file)
  # on a server that already runs something else: port $PORT must be free or ours
  local opid oexe; opid=$(port_owner_pid "$PORT")
  if [[ -n "$opid" ]]; then
    oexe=$(readlink "/proc/$opid/exe" 2>/dev/null); oexe=${oexe% (deleted)}
    # both paths resolved (a home under a symbolic link is still our listener)
    if [[ "$(readlink -f -- "$oexe" 2>/dev/null || printf '%s' "$oexe")" != "$(readlink -f -- "$(lsnr_home)/bin/tnslsnr" 2>/dev/null || printf '%s' "$(lsnr_home)/bin/tnslsnr")" ]]; then
      NOW="Port $PORT on this server is used by another program: $oexe (pid $opid)"
      KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
      PLAN="-- The standby listener of $(lsnr_home) must use port $PORT.
-- The primary and the RMAN copy connect to it there.
-- Stop the other program or move it to another port, then answer r. To see what it is:
  ps -fp $opid
  ss -ltnp '( sport = :$PORT )'"
      return 1
    fi
  fi
  static_entry_state || st=$?
  if [[ $st -eq 0 ]] && { use_grid || lsnr_has_desc; }; then NOW="listener.ora has the static entry for $STANDBY_SID with the database home."; return 0; fi
  USING="SID $STANDBY_SID, service $STANDBY_SERVICE
ORACLE_HOME (database home, not Grid):
  $DB_HOME"
  L51_MODE=""
  if ! use_grid && ! lsnr_has_desc; then
    if [[ $st -eq 1 ]] && ! lsnr_has_sidlist; then
      # no Grid: the listener lives in the database home and must be defined completely
      L51_MODE=both
      NOW="No listener is defined in listener.ora. There is no Grid on this server."$'\n'"  $f"
      PLAN="Write this to listener.ora (owner $ORACLE_USER; a backup is kept):
$(lsnr_desc_block)
$(static_block)"
      return 1
    fi
    if [[ $st -eq 0 ]]; then
      L51_MODE=desc
      NOW="listener.ora has the static entry, but no address for the listener $SB_LSNR:"$'\n'"  $f"
      PLAN="Add this to listener.ora (a backup is kept):
$(lsnr_desc_block)"
      return 1
    fi
  fi
  if [[ $st -eq 1 ]] && ! lsnr_has_sidlist; then
    L51_MODE=static
    NOW="listener.ora has no static entry for $STANDBY_SID:"$'\n'"  $f"
    PLAN="Add this to listener.ora (owner $(lsnr_user); a backup is kept):
$(static_block)"
    return 1
  fi
  KIND_NOW=manual; MANUAL_HOW="$(lsnr_user)  ->  shell"
  if [[ $st -eq 2 ]]; then
    NOW="The static entry for $STANDBY_SID has a different ORACLE_HOME."$'\n'"Logins through the listener would fail with ORA-01017."
    NOW+=$'\n'"The script only adds new entries; it does not change an existing one."$'\n'"Please correct this entry by hand."
  else
    NOW="listener.ora has a SID_LIST_$SB_LSNR block without $STANDBY_SID."$'\n'"The script does not edit inside an existing block, so please add the entry by hand."
  fi
  PLAN="-- Edit this file:
--   $f
-- Inside SID_LIST_$SB_LSNR, the (SID_LIST = ...) must contain exactly this SID_DESC:
    (SID_DESC =
      (GLOBAL_DBNAME = $STANDBY_SERVICE)
      (SID_NAME = $STANDBY_SID)
      (ORACLE_HOME = $DB_HOME)
    )"
  ! use_grid && ! lsnr_has_desc && PLAN+=$'\n'"-- and this listener address:"$'\n'"$(lsnr_desc_block)"
  return 1
}
d_5_1() {
  local f u txt; f=$(lsnr_file); u=$(lsnr_user)
  backup_file "$f" "$u" || return 1
  txt="# Added by dg_standby_setup.sh $RUN_ID"$'\n'
  case "$L51_MODE" in
    both)   txt+="$(lsnr_desc_block)"$'\n'"$(static_block)" ;;
    desc)   txt+="$(lsnr_desc_block)" ;;
    *)      txt+="$(static_block)" ;;
  esac
  printf '%s\n' "$txt" | append_as "$u" "$f" || return 1
  printf '%s\n' "$txt" | log_block "added to $f"
}

# ---- 5.2 ----
L52_START=0
c_5_2() {
  lsnr_sw_ok || { NOW="The listener software is not installed yet (phase 3)"; return 2; }
  static_entry_state || { NOW="The static entry is not correct yet (step 5.1)"; return 2; }
  L52_START=0
  if ! run_logged "lsnrctl status" as_lsnr timeout 60 "$(lsnr_home)/bin/lsnrctl" status "$SB_LSNR"; then
    if use_grid; then NOW="Listener $SB_LSNR is not running. It is an Oracle Restart resource, set up in step 3.9."; return 2; fi
    L52_START=1
    NOW="Listener $SB_LSNR is not running"
    PLAN="Start it:  lsnrctl start $SB_LSNR   (as $ORACLE_USER, from $DB_HOME)"
    return 1
  fi
  if ! grep -q "(PROTOCOL=TCP)(HOST=[^)]*)(PORT=$PORT)" <<< "$(norm "$RUN_OUT")"; then
    NOW="Listener $SB_LSNR does not listen on port $PORT, the port the primary uses"
    KIND_NOW=manual; MANUAL_HOW="$(lsnr_user)  ->  shell"
    PLAN="-- Edit this file:
--   $(lsnr_file)
-- Set (PORT = $PORT) in the $SB_LSNR address, then restart the listener:
$(lsnr_home)/bin/lsnrctl stop $SB_LSNR ; $(lsnr_home)/bin/lsnrctl start $SB_LSNR"
    use_grid && { MANUAL_HOW="$GRID_USER  ->  shell"; PLAN="srvctl modify listener -listener $SB_LSNR -endpoints TCP:$PORT
srvctl stop listener -listener $SB_LSNR ; srvctl start listener -listener $SB_LSNR"; }
    return 1
  fi
  if grep -qF "Instance \"$STANDBY_SID\", status UNKNOWN" <<< "$RUN_OUT"; then NOW="The listener shows Instance \"$STANDBY_SID\", status UNKNOWN (port $PORT)"; return 0; fi
  NOW="The listener does not show the static instance $STANDBY_SID yet"
  PLAN="Reload it:  lsnrctl reload $SB_LSNR   (as $(lsnr_user); open connections stay)"
  return 1
}
d_5_2() {
  local a=reload; [[ $L52_START -eq 1 ]] && a=start
  run_logged "lsnrctl $a" as_lsnr timeout 120 "$(lsnr_home)/bin/lsnrctl" "$a" "$SB_LSNR" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  [[ "$a" == "start" ]] && journal LSNRSTART "$SB_LSNR" "started from $(lsnr_home)"
  return 0
}

# ---- 5.3 / 5.4 ----
T_ALIAS=""; T_HOST=""; T_SVC=""
tns_alias_present() { local f; f=$(tns_file); [[ -f "$f" ]] && grep -qiE "^[[:space:]]*$1[[:space:]]*=" "$f"; }
c_tns() {
  db_sw_ok || { NOW="The database software is not installed yet (phase 3)"; return 2; }
  rw_home_ok || { NOW="The Oracle home is read-only (step 3.8)"; return 2; }
  local f; f=$(tns_file)
  USING="Host $T_HOST, port $PORT, service $T_SVC"
  if tns_alias_present "$T_ALIAS" && run_logged "tnsping $T_ALIAS" as_oracle timeout 60 "$DB_HOME/bin/tnsping" "$T_ALIAS" 1 && grep -q '^OK' <<< "$RUN_OUT"; then
    if tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC"; then NOW="tnsping $T_ALIAS works ($T_HOST:$PORT/$T_SVC, UR=A)"; return 0; fi
    NOW="The alias $T_ALIAS exists but is different: $TNS_WHY"
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
    PLAN="-- Edit this file:
--   $f
-- The entry must be:
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
    return 1
  fi
  if tns_alias_present "$T_ALIAS"; then
    case "$(tnsping_class "$RUN_OUT")" in
      NOLISTENER)
        if tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC"; then
          NOW="The alias $T_ALIAS is right, but nothing answers at $T_HOST:$PORT yet: $(grep -oE 'TNS-[0-9]+' <<< "$RUN_OUT" | head -n 1)"
          [[ "$T_HOST" == "$STANDBY_HOST" ]] && { NOW+=$'\n'"The listener on this server is not running (step 5.2)"; return 2; }
          NOW+=$'\n'"The listener on $T_HOST is not running. Check $LISTENER_NAME on the primary (port $PORT)."; return 2
        fi ;;
    esac
    NOW="The alias $T_ALIAS is in tnsnames.ora, but tnsping fails: $(grep -E 'TNS-[0-9]+' <<< "$RUN_OUT" | head -n 1)"
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
    PLAN="-- Edit this file:
--   $f
-- Fix the entry. Check the brackets and the host name:
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
    return 1
  fi
  NOW="The alias $T_ALIAS is missing from tnsnames.ora:"$'\n'"  $f"
  PLAN="Add this to tnsnames.ora (a backup is kept):
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
  return 1
}
d_tns() {
  local f; f=$(tns_file)
  backup_file "$f" "$ORACLE_USER" || return 1
  tns_block "$T_ALIAS" "$T_HOST" "$T_SVC" | append_as "$ORACLE_USER" "$f" || return 1
  tns_block "$T_ALIAS" "$T_HOST" "$T_SVC" | log_block "added to $f"
}
c_5_3() { T_ALIAS=$PRIMARY_TNS; T_HOST=$PRIMARY_HOST; T_SVC=$PRIMARY_SERVICE; c_tns; }
c_5_4() { T_ALIAS=$STANDBY_TNS; T_HOST=$STANDBY_HOST; T_SVC=$STANDBY_SERVICE; c_tns; }

phase_5() {
  phase_header 5 "Listener and tnsnames.ora"
  run_step 5.1 auto "Static listener entry for $STANDBY_SID" c_5_1 d_5_1
  run_step 5.2 auto "Listener shows the static entry" c_5_2 d_5_2
  run_step 5.3 auto "tnsnames.ora entry for the primary ($PRIMARY_TNS)" c_5_3 d_tns
  run_step 5.4 auto "tnsnames.ora entry for the standby ($STANDBY_TNS)" c_5_4 d_tns
}

#------------------------------------------------------------------------------
# PHASE 6  Password file (copy of the primary file), TDE wallet
#------------------------------------------------------------------------------
pw_dest() { printf '%s/dbs/orapw%s' "$DB_HOME" "$STANDBY_SID"; }
pw_tmp_remote() { printf '/tmp/orapw_for_standby_%s' "$STANDBY_SID"; }

pwfile_ok() {
  local d; d=$(pw_dest)
  [[ -f "$d" && ! -L "$d" ]] || return 1
  [[ "$(stat -c '%U' "$d")" == "$ORACLE_USER" ]] || return 1
  [[ "$(stat -c '%a' "$d")" =~ ^6[04]0$ ]] || return 1
  [[ -s "$d" ]] || return 1
  [[ "$PRIMARY_VERSION" == 12.1* ]] && return 0          # 12.1 orapwd has no "describe"
  run_logged "orapwd describe" as_oracle timeout 60 "$DB_HOME/bin/orapwd" describe file="$d" || return 1
  # any format the primary uses (12, 12.2, or LEGACY on an upgraded database): the file is a byte copy
  grep -qE 'format=[A-Za-z0-9.]+' <<< "$RUN_OUT"
}

PW_SRC=""
c_6_1() {
  db_sw_ok || { NOW="The database software is not installed yet (phase 3)"; return 2; }
  rw_home_ok || { NOW="The Oracle home is read-only (step 3.8)"; return 2; }
  local d; d=$(pw_dest)
  if pwfile_ok; then NOW="The password file is in place, owner $ORACLE_USER."$'\n'"  $d"$'\n'"The login test of step 7.4 compares it with the primary."; return 0; fi
  need_ssh || return 2
  # 12.2+: v$passwordfile_info has file_name and format; 12.1: file_name only; else the file in dbs
  local pfile=""
  if prim_sql "select file_name from v\$passwordfile_info;"; then pfile=$(first_line)
  fi
  if [[ -z "$pfile" || "$pfile" == "-" ]]; then
    if prim_probe exists "$DB_HOME/dbs/orapw$PRIMARY_SID" && [[ "$(head -n 1 <<< "$RUN_OUT")" == "YES" ]]; then pfile="$DB_HOME/dbs/orapw$PRIMARY_SID"
    else NOW="The password file of the primary was not found."$'\n'"v\$passwordfile_info is empty and $DB_HOME/dbs/orapw$PRIMARY_SID does not exist."$'\n'"To find it, run on the primary as $ORACLE_USER:"$'\n'"  $DB_HOME/bin/srvctl config database -db $PRIMARY_UNIQUE | grep -i 'password file'"; return 2; fi
  fi
  [[ "$pfile" =~ ^\+[A-Za-z0-9_./+-]+$ || "$pfile" =~ ^/[A-Za-z0-9_./-]+$ ]] || { NOW="The primary password file has an unusual path: '$pfile'"; return 2; }
  if [[ -f "$d" ]]; then NOW="The password file here has the wrong owner, mode or format:"$'\n'"  $d"; else NOW="This server has no password file yet."$'\n'"  $d"; fi
  if [[ "$pfile" == +* ]]; then
    local t towner tg tm tmode ttype tage=""; t=$(pw_tmp_remote)
    if prim_probe statx "$t"; then
      IFS='|' read -r towner tg tmode ttype tm <<< "$(head -n 1 <<< "$RUN_OUT")"
      if [[ "$ttype" != "regular file" || ( "$towner" != "$GRID_USER" && "$towner" != "$ORACLE_USER" ) || ! "$tmode" =~ ^[0-7]+$ || $(( 8#${tmode: -1} & 2 )) -ne 0 ]]; then
        NOW+=$'\n'"$t on the primary is not used (owner $towner, type $ttype, mode $tmode)."
        NOW+=$'\n'"It must be a regular file of $GRID_USER or $ORACLE_USER that others cannot write."
        KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
        PLAN="rm -f $t
asmcmd pwcopy '$pfile' $t
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 reminds you after the copy)"
        return 1
      fi
      # the age is measured with the clock of the primary
      num "$tm" && tage=$(( RUN_START + PRIM_CLOCK_OFFSET - tm ))
    fi
    if [[ -n "$tage" && $tage -gt 86400 ]]; then
      # a copy older than a day (from an earlier attempt) may be from before a sys password change
      NOW+=$'\n'"An old copy $t is on the primary (owner $towner, $((tage / 3600)) hours older than this run)."
      NOW+=$'\n'"It is not used: the sys password may have changed since then."
      KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
      PLAN="rm -f $t
asmcmd pwcopy '$pfile' $t
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 reminds you after the copy)"
      return 1
    fi
    [[ -n "$tage" ]] && NOW="The copy $t is ready on the primary$([[ $tage -ge 60 ]] && printf ' (%s minutes old)' "$((tage / 60))")."$'\n'"$NOW"
    if [[ -n "$tage" ]]; then
      PW_SRC=$t
      PLAN="Copy $t from the primary (scp, checked with md5sum)
Install it here (owner $ORACLE_USER:$INSTALL_GROUP, mode 640):
  $d"
      [[ -f "$d" ]] && PLAN+=$'\n'"Keep the old file as ${d##*/}.bak_$RUN_ID (same folder)"
      USING="Fresh copy of $pfile on the primary (owner $towner)"
      return 1
    fi
    NOW+=$'\n'"The primary password file is in ASM: $pfile"
    KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
    PLAN="asmcmd pwcopy '$pfile' $t
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 reminds you after the copy)"
    USING="After you run the commands below, the script copies the file to this server."$'\n'"Step 6.2 then asks you to delete it on the primary."
    return 1
  fi
  PW_SRC=$pfile
  PLAN="Copy the password file from the primary (scp, checked with md5sum):
  $pfile
Install it here (owner $ORACLE_USER:$INSTALL_GROUP, mode 640):
  $d"
  [[ -f "$d" ]] && PLAN+=$'\n'"Keep the old file as ${d##*/}.bak_$RUN_ID (same folder)"
  return 1
}
fetch_primary_file() {
  # $1 file on primary, $2 private local copy. 0 only when the copy is byte-identical (md5).
  local src=$1 tmp=$2 rmd lmd
  rm -f -- "$tmp"
  prim_scp "$src" "$tmp" || { bad "scp failed: $(tail -n 2 <<< "$RUN_OUT")"; printf 'The ssh user %s must be able to read %s on the primary.\n' "$PRIMARY_SSH_USER" "$src" | hint; return 1; }
  [[ -s "$tmp" && -f "$tmp" && ! -L "$tmp" ]] || { bad "The copy of $src is empty"; return 1; }
  prim_probe md5 "$src" || { bad "Cannot get the md5sum of $src on the primary. The copy is not used."; return 1; }
  rmd=$(awk '{print $1; exit}' <<< "$RUN_OUT"); lmd=$(md5sum "$tmp" | awk '{print $1}')
  [[ "$rmd" =~ ^[0-9a-f]{32}$ && "$rmd" == "$lmd" ]] || { bad "The copy differs from $src on the primary (md5 here $lmd, there $rmd)"; return 1; }
  say "Checksum (md5) is the same as the file on the primary."
}
d_6_1() {
  local d tmp; d=$(pw_dest)
  install -d -m 700 "$STATE_DIR"
  tmp="$STATE_DIR/orapw_incoming.$$"; CLEANUP_FILES+=("$tmp")
  fetch_primary_file "$PW_SRC" "$tmp" || return 1
  local existed=0; [[ -e "$d" ]] && existed=1
  backup_file "$d" "$ORACLE_USER" || return 1
  install -o "$ORACLE_USER" -g "$INSTALL_GROUP" -m 640 "$tmp" "$d" || { bad "Cannot install $d"; return 1; }
  rm -f "$tmp"
  journal_file_written "$d" "$existed"
  DONE_MSG="The primary password file is installed here:"$'\n'"  $d"
}

# ---- 6.2 temporary copy on primary ----
c_6_2() {
  need_ssh || return 2
  local t; t=$(pw_tmp_remote)
  PRIMARY_HOW_STEP="$GRID_USER (or root)  ->  shell"
  if ! prim_probe owner "$t"; then NOW="No temporary password file copy on the primary"; return 0; fi
  pwfile_ok || { NOW="Keep $t for now: the password file is not installed yet (step 6.1)"; return 2; }
  NOW="The temporary copy $t is still on the primary"
  PLAN="rm -f $t"
  return 1
}

# ---- 6.3 TDE wallet ----
TDE_DIRS=(); TDE_TODO=(); TDE_SQLNET=0; TDE_NO_AUTOLOGIN=0
tde_dirs() {
  # file-based wallet folders in use on primary (one per line); TDE_INFO lines: type|location|status
  awk -F'|' 'toupper($1)=="FILE" && $2 != "-" && toupper($3) != "NOT_AVAILABLE" {print $2}' <<< "$TDE_INFO" | sed 's#/*$##' | sort -u
}
sqlnet_file() { printf '%s/network/admin/sqlnet.ora' "$DB_HOME"; }
tde_local_autologin() { awk -F'|' 'toupper($4) ~ /LOCAL/' <<< "$TDE_INFO" | grep -q .; }
orapki_plan() {
  # creates cwallet.sso next to ewallet.p12 on THIS server; orapki asks for the keystore password itself
  printf 'ORACLE_HOME=%s %s/bin/orapki wallet create -wallet %s %s\n' "$DB_HOME" "$DB_HOME" "$1" "$(tde_local_autologin && printf -- '-auto_login_local' || printf -- '-auto_login')"
  printf '# orapki asks for the keystore password and writes %s/cwallet.sso here.\n# The primary is not changed. Then answer r.' "$1"
}
tde_autologin_missing() {
  # 0 when the primary uses a file keystore and this server has no auto-login file for it (ORA-28365 later)
  [[ -n "$TDE_INFO" ]] || return 1
  local d; d=$(tde_dirs | head -n 1)
  [[ -n "$d" && "$d" == /* ]] || return 1
  [[ -f "$d/cwallet.sso" ]] && return 1
  [[ -n "$WALLET_ROOT" && -f "$WALLET_ROOT/tde/cwallet.sso" ]] && return 1
  return 0
}
sqlnet_has_wallet() { local f; f=$(sqlnet_file); [[ -f "$f" ]] && norm "$(sed 's/#.*//' "$f")" | grep -qF "(DIRECTORY=${1^^})"; }
c_6_3() {
  [[ -n "$TDE_INFO" ]] || { NOW="The primary does not use a TDE wallet"; return 0; }
  if awk -F'|' 'toupper($1)!="FILE" && toupper($3)!="NOT_AVAILABLE"' <<< "$TDE_INFO" | grep -q .; then
    NOW="The primary uses a TDE keystore that is not a file (HSM or OKV):"$'\n'"$TDE_INFO"
    PLAN="Set up the same keystore for $STANDBY_UNIQUE on this server, as your HSM or OKV vendor describes."
    return 2
  fi
  local -a dirs=(); local d f; mapfile -t dirs < <(tde_dirs)
  [[ ${#dirs[@]} -gt 0 && -n "${dirs[0]}" ]] || { NOW="The primary does not use a TDE wallet"; return 0; }
  # 18c+: the password for "IDENTIFIED BY EXTERNAL STORE" is in WALLET_ROOT/tde_seps
  [[ -n "$WALLET_ROOT" ]] && need_ssh && prim_probe lsdir "$WALLET_ROOT/tde_seps" && grep -qx 'cwallet.sso' <<< "$RUN_OUT" && dirs+=("$WALLET_ROOT/tde_seps")
  db_sw_ok || { NOW="The database software is not installed yet (phase 3)"; return 2; }
  for d in "${dirs[@]}"; do
    [[ "$d" == /* ]] && v_path "$d" || { NOW="The TDE wallet is at $d, in ASM or at an unusual path"; PLAN="Copy the wallet files by hand to the same location for the standby, for example with asmcmd cp."; return 2; }
  done
  need_ssh || return 2
  TDE_DIRS=("${dirs[@]}"); TDE_TODO=()
  local miss="" diff="" have=""
  for d in "${dirs[@]}"; do
    prim_probe lsdir "$d" || { NOW="Cannot list the wallet folder $d on the primary. The ssh user must be able to read it."; return 2; }
    local found=0
    while IFS= read -r f; do
      [[ "$f" =~ ^(ewallet\.p12|cwallet\.sso)$ ]] || continue
      found=1
      # a LOCAL auto-login wallet of the primary does not open here: it is made again on this server (orapki)
      if [[ "$f" == cwallet.sso ]] && tde_local_autologin; then continue; fi
      if [[ ! -f "$d/$f" ]]; then miss+=" $d/$f"; TDE_TODO+=("$d/$f"); continue; fi
      if prim_probe md5 "$d/$f" && [[ "$(awk '{print $1; exit}' <<< "$RUN_OUT")" == "$(md5sum "$d/$f" | awk '{print $1}')" ]]; then have+=" $d/$f"
      else diff+=" $d/$f"; TDE_TODO+=("$d/$f"); fi
    done <<< "$RUN_OUT"
    [[ $found -eq 1 ]] || { NOW="No ewallet.p12 or cwallet.sso in $d on the primary"; return 2; }
  done
  # without WALLET_ROOT (12c, or 18c-21c set up the old way) the standby finds the wallet only through sqlnet.ora
  TDE_SQLNET=0
  if [[ -z "$WALLET_ROOT" ]]; then
    [[ $DB_MAJOR -ge 23 ]] && { NOW="The primary ($PRIMARY_VERSION) uses TDE without WALLET_ROOT. Set WALLET_ROOT on the primary first."; return 2; }
    if ! sqlnet_has_wallet "${dirs[0]}"; then
      if [[ -f "$(sqlnet_file)" ]] && grep -qiE '^[[:space:]]*ENCRYPTION_WALLET_LOCATION' "$(sqlnet_file)"; then
        NOW="sqlnet.ora has an ENCRYPTION_WALLET_LOCATION that is not ${dirs[0]}:"$'\n'"  $(sqlnet_file)"
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
        PLAN="-- Edit this file:
--   $(sqlnet_file)
-- Change the ENCRYPTION_WALLET_LOCATION line to:
ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))"
        return 1
      fi
      TDE_SQLNET=1
    fi
  fi
  TDE_NO_AUTOLOGIN=0; [[ "$have$miss$diff" == *"cwallet.sso"* ]] || TDE_NO_AUTOLOGIN=1
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 && $TDE_NO_AUTOLOGIN -eq 1 && -f "${dirs[0]}/cwallet.sso" ]]; then TDE_NO_AUTOLOGIN=0; fi
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 && $TDE_NO_AUTOLOGIN -eq 1 ]]; then
    NOW="The TDE wallet is copied, but there is no auto-login keystore (cwallet.sso) here."$'\n'"Without it, the RMAN copy and redo apply stop with ORA-28365."
    tde_local_autologin && NOW+=$'\n'"The primary uses a local auto-login wallet. It opens only on the primary host,"$'\n'"so it is made again here."
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"
    PLAN=$(orapki_plan "${dirs[0]}")
    return 1
  fi
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 ]]; then
    NOW="The TDE wallet is the same as on the primary:$have"
    [[ -n "$WALLET_ROOT" ]] && NOW+=$'\n'"wallet_root=$WALLET_ROOT comes to the standby with the spfile." || NOW+=$'\n'"The wallet location ${dirs[0]} is set in:"$'\n'"  $(sqlnet_file)"
    return 0
  fi
  NOW="The primary uses TDE.${miss:+ Missing here:$miss}${diff:+ Different here:$diff}"
  [[ $TDE_SQLNET -eq 1 ]] && NOW+=$'\n'"sqlnet.ora does not point to the wallet ${dirs[0]}:"$'\n'"  $(sqlnet_file)"
  PLAN=""
  [[ ${#TDE_TODO[@]} -gt 0 ]] && PLAN="Copy these files from the primary to the same path here (scp, checked with md5sum):"$'\n'"$(printf '  %s\n' "${TDE_TODO[@]}")"$'\n'"Owner $ORACLE_USER:$INSTALL_GROUP, mode 600. Old files are kept as .bak_$RUN_ID."$'\n'
  [[ $TDE_SQLNET -eq 1 ]] && PLAN+="Add this to sqlnet.ora (a backup is kept):"$'\n'"ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))"$'\n'
  TDE_NO_AUTOLOGIN=0
  if [[ " ${have} ${TDE_TODO[*]+"${TDE_TODO[*]}"} " != *"cwallet.sso"* ]]; then
    TDE_NO_AUTOLOGIN=1
    if tde_local_autologin; then PLAN+="The primary uses a local auto-login wallet. It opens only on the primary host,"$'\n'"so it is not copied."$'\n'
    else PLAN+="The primary has no auto-login keystore (cwallet.sso)."$'\n'"Without one here, the RMAN copy and redo apply on the standby stop with ORA-28365."$'\n'; fi
    PLAN+="After the copy, this step shows the orapki command that makes cwallet.sso on this server."$'\n'
  fi
  PLAN=${PLAN%$'\n'}
  return 1
}
d_6_3() {
  local f tmp d
  for f in "${TDE_TODO[@]+"${TDE_TODO[@]}"}"; do
    d=$(dirname "$f")
    make_dir "$d" "$ORACLE_USER" || return 1
    runuser -u "$ORACLE_USER" -- chmod 700 "$d" 2>/dev/null || true
    tmp="$STATE_DIR/tde_incoming.$$"; CLEANUP_FILES+=("$tmp")
    fetch_primary_file "$f" "$tmp" || return 1
    local existed=0; [[ -e "$f" ]] && existed=1
    backup_file "$f" "$ORACLE_USER" || return 1
    install -o "$ORACLE_USER" -g "$INSTALL_GROUP" -m 600 "$tmp" "$f" || return 1
    rm -f "$tmp"; say "Installed $f"; journal_file_written "$f" "$existed"
  done
  if [[ $TDE_SQLNET -eq 1 ]]; then
    local s; s=$(sqlnet_file)
    backup_file "$s" "$ORACLE_USER" || return 1
    printf '# Added by dg_standby_setup.sh %s (TDE wallet of the standby)\nENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = %s)))\n' "$RUN_ID" "${TDE_DIRS[0]}" \
      | append_as "$ORACLE_USER" "$s" || return 1
    say "Added ENCRYPTION_WALLET_LOCATION to $s"
  fi
}

phase_6() {
  phase_header 6 "Password file and TDE wallet"
  run_step 6.1 auto    "Password file orapw$STANDBY_SID" c_6_1 d_6_1
  run_step 6.2 primary "Remove the temporary copy on the primary" c_6_2
  run_step 6.3 auto    "TDE wallet (only if the primary uses TDE)" c_6_3 d_6_3
}

#------------------------------------------------------------------------------
# PHASE 7  Start the standby instance (NOMOUNT) and test the logins
#------------------------------------------------------------------------------
STANDBY_BUILT=0
DUP_RAN=0
SC_INFO=""

dup_marker() { printf '%s/dbs/.dg_duplicate_done_%s' "$DB_HOME" "$STANDBY_SID"; }
pfile_path() { printf '%s/dbs/init%s.ora' "$DB_HOME" "$STANDBY_SID"; }
spfile_path() { printf '%s/dbs/spfile%s.ora' "$DB_HOME" "$STANDBY_SID"; }
set_marker() {
  # $1 duplicate = RMAN printed "Finished Duplicate Db"; seen = a mounted standby was compared with the primary
  # (no datafile header error). Both kinds mark a complete standby; later header errors are only reported.
  [[ "$MODE" == "run" ]] || return 0
  [[ "$1" == "seen" && -e "$(dup_marker)" ]] && return 0
  printf '%s\n' "$1" | write_as "$ORACLE_USER" "$(dup_marker)" 640 \
    || warn "Cannot write $(dup_marker)."$'\n'"While the standby is shut down, the script cannot tell that it is complete."
  return 0
}
marker_kind() { [[ -f "$(dup_marker)" ]] || return 0; local k; k=$(head -n 1 -- "$(dup_marker)" 2>/dev/null); printf '%s' "${k:-duplicate}"; }
built_offline() {
  # a standby that is shut down: the duplicate (or a comparison) was recorded and the spfile exists
  [[ -f "$(dup_marker)" && -f "$(spfile_path)" ]] && STANDBY_BUILT=1
  [[ $STANDBY_BUILT -eq 1 ]]
}

standby_complete() {
  # 0 complete, 1 incomplete, 2 cannot tell (SC_INFO says why).
  # The marker file is written when the duplicate finished. Without it, a mounted standby is
  # compared with the primary (datafiles and headers). A standby that is behind the primary
  # (fewer datafiles because apply is stopped) is still a standby: it only needs apply.
  # A marker "seen" (the standby was compared before and was complete) also counts: later header errors
  # (a new datafile on primary, an OFFLINE file) are reported, never treated as a failed copy.
  SC_INFO=""
  local_state
  if [[ "$LSTATE" != "MOUNTED" && "$LSTATE" != "OPEN" ]]; then
    [[ -f "$(dup_marker)" && -f "$(spfile_path)" ]] && return 0
    SC_INFO="the standby is not mounted and no finished copy is recorded"; return 1
  fi
  [[ "$(marker_kind)" == "duplicate" ]] && return 0
  if [[ "$(marker_kind)" == "seen" ]]; then
    if sql_local "select count(*) from v\$datafile_header where error is not null;" && [[ "$(first_line)" != "0" ]]; then
      warn "The standby was complete before, but now $(first_line) datafile header(s) show an error."$'\n'"Usually a datafile was added on the primary, or a file is OFFLINE."
      say "To see them:  select file#, error from v\$datafile_header where error is not null;"
      say "To build the standby again, see the help of step 8.2."
      say "Remove files only if step 2.15 proved that the storage is not shared."
    fi
    return 0
  fi
  sql_local "select (select count(*) from v\$datafile)||'|'||(select count(*) from v\$datafile_header where error is not null) from dual;" || { SC_INFO="cannot read the standby ($(ora_errors "$SQL_OUT"))"; return 2; }
  local sc se pc; IFS='|' read -r sc se <<< "$(first_line)"
  need_ssh || { SC_INFO="no ssh connection to the primary for the comparison"; return 2; }
  prim_sql "select count(*) from v\$datafile;" || { SC_INFO="cannot read the primary ($(ora_errors "$SQL_OUT"))"; return 2; }
  pc=$(first_line)
  num "$sc" && num "$se" && num "$pc" || { SC_INFO="unexpected answers ($sc, $se, $pc)"; return 2; }
  # complete: no datafile header has an error. Fewer datafiles than the primary means apply is behind
  # (new tablespaces on primary), not a failed copy (a failed copy shows the missing files as errors).
  if [[ "$se" == "0" && "$sc" -gt 0 ]]; then set_marker seen; return 0; fi
  SC_INFO="the standby has $sc datafiles ($se with errors), the primary has $pc"
  return 1
}

leftover_files() {
  # files of the standby database on this server (ASM: +DG/<STANDBY_UNIQUE>; folders: the primary's names here)
  local dg out="" f n
  for dg in $(asm_dgs); do
    grid_sw_ok || continue
    if sql_asm "select count(*) from v\$asm_alias a, v\$asm_diskgroup g where a.group_number=g.group_number and g.name=upper('$dg') and upper(a.name)=upper('$STANDBY_UNIQUE');" && [[ "$(first_line)" != "0" ]]; then
      out+="  +$dg/${STANDBY_UNIQUE^^}"$'\n'
    fi
  done
  if [[ -n "$(fs_dirs)" ]] && sql_or_cached_filenames; then
    n=0
    while IFS= read -r f; do [[ -n "$f" && -f "$f" ]] && { n=$((n + 1)); [[ $n -le 5 ]] && out+="  $f"$'\n'; }; done <<< "$FS_FILENAMES"
    [[ $n -gt 5 ]] && out+="  ... and $((n - 5)) more files"$'\n'
    local omfd; omfd=$(omf_dir_here)
    [[ -n "$omfd" && -d "$omfd/${STANDBY_UNIQUE^^}" ]] && out+="  $omfd/${STANDBY_UNIQUE^^}/"$'\n'
  fi
  printf '%s' "${out%$'\n'}"
}
orphan_leftovers() {
  # files of an earlier copy that a new copy would NOT overwrite (ASM folders of the standby, OMF folder)
  leftover_files | grep -E '^ *\+|/$' || true
}
spfile_from_failed_copy() {
  # 0 = the instance runs from the spfile that a duplicate which did not finish left behind
  [[ -f "$(spfile_path)" && "$(marker_kind)" != "duplicate" ]] || return 1
  sql_local "select nvl(value,'-') from v\$parameter where name='spfile';" || return 1
  [[ "$(first_line)" != "-" ]]
}
FS_FILENAMES=""
sql_or_cached_filenames() {
  # the datafile / tempfile / redo / control file names of the primary (read-only), cached in this run
  [[ -n "$FS_FILENAMES" ]] && return 0
  need_ssh || return 1
  prim_sql "select name from v\$datafile union all select name from v\$tempfile union all select member from v\$logfile union all select name from v\$controlfile;" || return 1
  FS_FILENAMES=$(grep '^/' <<< "$SQL_OUT")
  [[ -n "$FS_FILENAMES" ]]
}
omf_dir_here() {
  # the folder where OMF files of the standby are created (db_create_file_dest of primary, or the OMF folder)
  [[ "$CFD" == /* ]] && { printf '%s' "$CFD"; return 0; }
  sql_or_cached_filenames || return 0
  local f; f=$(grep -m1 '/o1_mf_' <<< "$FS_FILENAMES") || return 0
  [[ -n "$f" ]] && dirname "$(dirname "$(dirname "$f")")"
  return 0
}
STORAGE_SRC=""; STORAGE_KEY=""
storage_cache() {
  # runs the storage proof (2.15) in the calling shell, before plans are built inside $( ): its messages and
  # its wait stay on the screen, and a passed or failed proof is not repeated in this run
  # the proof belongs to the mounts it was made on: other storage mounted meanwhile is proven again
  local key="" d; for d in $(fs_dirs); do key+="$(findmnt -n -o SOURCE,UUID --target "$(existing_parent "$d")" 2>/dev/null | head -n 1);"; done
  [[ ( "$STORAGE_SRC" == 0 || "$STORAGE_SRC" == 1 ) && "$key" == "$STORAGE_KEY" ]] && return 0
  STORAGE_SRC=2; STORAGE_KEY=$key
  [[ "$MODE" == "run" && -n "$(fs_dirs)" ]] || return 0
  STORAGE_SRC=0; storage_not_shared || STORAGE_SRC=$?
  return 0
}
leftover_cleanup_plan() {
  # the clean-up commands for the files of a failed copy: host-name guarded, standby names only
  local dg p
  [[ -n "$(asm_dgs)" ]] && printf 'NEVER remove %s. Those are the files of the primary database.\n' "$(asm_dgs | sed "s#^#+#; s#\$#/${PRIMARY_UNIQUE^^}#" | paste -sd' ' -)"
  for dg in $(asm_dgs); do printf 'as %s:  [ "$(hostname -s)" = "%s" ] && ORACLE_HOME=%s ORACLE_SID=+ASM %s/bin/asmcmd rm -rf +%s/%s       (check the name twice)\n' "$GRID_USER" "$(hostname -s)" "$GRID_HOME" "$GRID_HOME" "$dg" "${STANDBY_UNIQUE^^}"; done
  if [[ -n "$(fs_dirs)" ]]; then
    local rmf="" src=${STORAGE_SRC:-2}
    if [[ $src -eq 0 ]]; then rmf=$(fs_cleanup_cmds | sed "s#^#[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] \&\& #" || true); fi
    if [[ -n "$rmf" ]]; then printf 'as %s, on this server only (the files have the same names as on the primary):\n%s\n' "$ORACLE_USER" "$rmf"
      local omfd; omfd=$(omf_dir_here); [[ -n "$omfd" ]] && printf '[ "$(hostname -s)" = "%s" ] && rm -rf %s/%s\n' "$(hostname -s)" "$omfd" "${STANDBY_UNIQUE^^}"
    elif [[ $src -eq 1 ]]; then printf 'Do NOT remove anything in %s. It is the storage of the primary.\n' "$STORAGE_SHARED"
    else printf 'Remove the files the failed copy left in %s (same names as on the primary).\nFirst make sure this is not the storage of the primary (step 2.15).\n' "$(fs_dirs | paste -sd' ' -)"; fi
  fi
  printf 'as %s:  [ "$(hostname -s)" = "%s" ] && rm -f %s %s\n' "$ORACLE_USER" "$(hostname -s)" "$(spfile_path)" "$(dup_marker)"
  return 0
}
DETECT_RC=0
detect_built() {
  # sets STANDBY_BUILT (used by phases 7-10); DETECT_RC 2 = cannot tell (SC_INFO)
  STANDBY_BUILT=0; DETECT_RC=0
  local_state
  if [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]]; then
    sql_local "select database_role from v\$database;" || { DETECT_RC=2; SC_INFO="cannot read the role ($(ora_errors "$SQL_OUT"))"; return 0; }
    [[ "$(first_line)" == "PHYSICAL STANDBY" ]] || return 0
  fi
  local rc=0; standby_complete || rc=$?
  [[ $rc -eq 0 ]] && STANDBY_BUILT=1
  DETECT_RC=$rc
  return 0
}

# ---- 7.1 ----
adump_dir() { printf '%s/admin/%s/adump' "$ORACLE_BASE" "$STANDBY_UNIQUE"; }
inst_dirs() {
  # folders the instance needs at startup (same paths as on primary)
  adump_dir; printf '\n'
  [[ -n "$DIAG_DEST" ]] && printf '%s\n' "$DIAG_DEST"
  return 0
}
I71_TODO=()
c_7_1() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  local d have="" I71=()
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ -d "$d" ]] && runuser -u "$ORACLE_USER" -- test -w "$d"; then have+="  $d"$'\n'; else I71+=("$d"); fi
  done < <(inst_dirs)
  if [[ ${#I71[@]} -eq 0 ]]; then NOW="The folders exist:"$'\n'"${have%$'\n'}"; return 0; fi
  I71_TODO=("${I71[@]}")
  NOW="Missing, or not writable by $ORACLE_USER:"$'\n'"$(printf '  %s\n' "${I71[@]}")"
  PLAN="Create them with owner $ORACLE_USER:$INSTALL_GROUP"$'\n'"The paths are the same as audit_file_dest and diagnostic_dest on the primary"
  return 1
}
d_7_1() { local d; for d in "${I71_TODO[@]}"; do make_dir "$d" "$ORACLE_USER" || return 1; done; }

# ---- 7.7 oratab ----
c_7_7() {
  local cur; cur=$(grep -E "^${STANDBY_SID}:" /etc/oratab 2>/dev/null | head -n 1)
  if [[ "$cur" == "$STANDBY_SID:$DB_HOME:"* ]]; then NOW="/etc/oratab has the line for $STANDBY_SID:"$'\n'"  $cur"; return 0; fi
  if [[ -n "$cur" ]]; then
    local yn; yn=$(cut -d: -f3 <<< "$cur"); [[ "$yn" =~ ^[YNyn]$ ]] || yn=N
    NOW="/etc/oratab has another home for $STANDBY_SID:"$'\n'"  $cur"
    PLAN="Change that line in /etc/oratab to (a backup is kept):"$'\n'"  $STANDBY_SID:$DB_HOME:$yn"
    return 1
  fi
  NOW="/etc/oratab has no line for $STANDBY_SID. oraenv and dbstart need it."
  PLAN="Add this line to /etc/oratab (a backup is kept):"$'\n'"  $STANDBY_SID:$DB_HOME:N"
  return 1
}
d_7_7() {
  local new=0; [[ -f /etc/oratab ]] || new=1
  backup_file /etc/oratab || return 1
  if [[ $new -eq 0 && ! -L /etc/oratab ]] && grep -qE "^${STANDBY_SID}:" /etc/oratab; then
    # only the line of this SID changes (its Y/N stays); written in place, so owner, mode and label stay
    local tmp; tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
    awk -F: -v sid="$STANDBY_SID" -v home="$DB_HOME" 'BEGIN { OFS = ":" } $1 == sid && !done { $2 = home; if ($3 !~ /^[YNyn]$/) $3 = "N"; done = 1 } { print }' /etc/oratab > "$tmp" || return 1
    cat -- "$tmp" > /etc/oratab || { [[ -f "/etc/oratab.bak_$RUN_ID" ]] && cat -- "/etc/oratab.bak_$RUN_ID" > /etc/oratab; bad "/etc/oratab could not be written. The old content was put back."; return 1; }
    rm -f -- "$tmp"
    journal_file_written /etc/oratab 1
    return 0
  fi
  printf '%s:%s:N' "$STANDBY_SID" "$DB_HOME" | append_as root /etc/oratab || return 1
  # a new file gets the usual owner; an existing one (Grid makes it) keeps its owner
  [[ $new -eq 1 ]] && { chown root:"$INSTALL_GROUP" /etc/oratab; chmod 664 /etc/oratab; }
  return 0
}

# ---- 7.2 ----
pfile_text() {
  printf "*.db_name='%s'\n*.db_unique_name='%s'\n" "$DB_NAME" "$STANDBY_UNIQUE"
  [[ "$PRIMARY_CDB" == "YES" ]] && printf '*.enable_pluggable_database=true\n'
  return 0
}
fs_cleanup_cmds() {
  # rm commands for the files a failed copy may have left in the folders (same names as on primary)
  local f
  prim_sql "select name from v\$datafile union all select name from v\$tempfile union all select member from v\$logfile union all select name from v\$controlfile;" || return 1
  while IFS= read -r f; do
    [[ "$f" =~ ^/[A-Za-z0-9_./-]+$ ]] || continue
    printf 'rm -f %s\n' "$f"
  done <<< "$SQL_OUT"
}
c_7_2() {
  L72_CLEAN=""
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  pwfile_ok || { NOW="Password file is not ready (step 6.1)"; return 2; }
  storage_cache
  local_state
  case "$LSTATE" in
    STARTED)
      # NOMOUNT, but from the spfile that a failed duplicate left (RMAN restarts the auxiliary with it):
      # the next duplicate needs an instance started from the text pfile
      if spfile_from_failed_copy; then
        NOW="Instance $STANDBY_SID is in NOMOUNT, but it runs from the spfile of an unfinished copy:"$'\n'"$(spfile_path)"
        cleanup_auto_plan spfile && return 1
        PLAN="# As $ORACLE_USER, on this server only:
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && ORACLE_HOME=$DB_HOME ORACLE_SID=$STANDBY_SID $DB_HOME/bin/sqlplus -S / as sysdba <<< 'shutdown abort'
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && mv $(spfile_path) $(spfile_path).failed_$RUN_ID
$(leftover_cleanup_plan | grep -v "rm -f $(spfile_path) ")
# Then answer r. The script starts the instance again from the pfile."
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"
        return 1
      fi
      # NOMOUNT from the pfile, but a copy that did not finish left files a new copy would not overwrite
      if [[ -f "$STATE_DIR/dup_attempt" && ! -f "$STATE_DIR/existing_files_ok" && "$(marker_kind)" != "duplicate" ]]; then
        local ol; ol=$(orphan_leftovers)
        if [[ -n "$ol" ]]; then
          NOW="Instance $STANDBY_SID is in NOMOUNT, but files of an unfinished copy are still here:"$'\n'"$ol"
          cleanup_auto_plan keep && return 1
          PLAN="# As $ORACLE_USER, on this server only:
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && ORACLE_HOME=$DB_HOME ORACLE_SID=$STANDBY_SID $DB_HOME/bin/sqlplus -S / as sysdba <<< 'shutdown abort'
$(leftover_cleanup_plan)
# Then answer r. The script starts the instance again from the pfile.
# If the files may stay, run this instead and answer r:
touch $STATE_DIR/existing_files_ok"
          KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER${GRID_HOME:+ / $GRID_USER}"
          return 1
        fi
      fi
      NOW="Instance $STANDBY_SID is in NOMOUNT"; return 0 ;;
    MOUNTED|OPEN)
      sql_local "select database_role from v\$database;" || { NOW="Cannot read the database role ($(ora_errors "$SQL_OUT"))"; return 2; }
      local role; role=$(first_line)
      [[ "$role" == "PHYSICAL STANDBY" ]] || fatal "Database $STANDBY_SID on this server is $LSTATE with role '$role'. It is not a standby, so the script stops."
      local sc=0; standby_complete || sc=$?
      if [[ $sc -eq 0 ]]; then STANDBY_BUILT=1; NOW="The standby database already exists ($LSTATE, PHYSICAL STANDBY). No copy is needed."; return 0; fi
      if [[ $sc -eq 2 ]]; then NOW="Cannot compare the standby with the primary: $SC_INFO"; return 2; fi
      NOW="A standby control file exists, but the database is incomplete, probably from a failed copy:"$'\n'"$SC_INFO"
      cleanup_auto_plan mounted && return 1
      KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER${GRID_HOME:+ / $GRID_USER}"
      PLAN="# As $ORACLE_USER, on this server only:"$'\n'"[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && ORACLE_HOME=$DB_HOME ORACLE_SID=$STANDBY_SID $DB_HOME/bin/sqlplus -S / as sysdba <<< 'shutdown abort'"$'\n'"$(leftover_cleanup_plan)"
      PLAN+=$'\n'"# Then answer r. The script starts the instance again from the pfile."
      return 1 ;;
    IDLE)
      if [[ -f "$(dup_marker)" && -f "$(spfile_path)" ]]; then
        STANDBY_BUILT=1
        NOW="The standby database exists (the copy finished). Step 9.2 starts it."
        return 0
      fi
      # files of a copy that was interrupted (reboot, kill): they are named, never removed by the script
      local lo; lo=$(leftover_files)
      if [[ -n "$lo" && ! -f "$STATE_DIR/existing_files_ok" ]]; then
        NOW="Instance $STANDBY_SID is not started, and files already exist where the standby database will be written:"$'\n'"$lo"
        cleanup_auto_plan keep && return 1
        PLAN="$(leftover_cleanup_plan)
# RMAN overwrites files with the same names. Files with OMF names would stay unused and take space.
# Then answer r.
# If you are sure the files may be overwritten or may stay, run this instead and answer r:
touch $STATE_DIR/existing_files_ok"
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER${GRID_HOME:+ / $GRID_USER}"
        return 1
      fi
      NOW="Instance $STANDBY_SID is not started"
      PLAN="Write this pfile:
  $(pfile_path)
with these lines:
$(pfile_text | sed 's/^/  /')
Start the instance as $ORACLE_USER:
  startup nomount pfile='$(pfile_path)'"
      return 1 ;;
    *) NOW="Cannot read the state of the instance on this server ($(ora_errors "$SQL_OUT"))"; return 2 ;;
  esac
}
# The clean-up of a copy that did not finish, done by the script after you typed DELETE.
# Only the standby's own names are removed: +DG/<standby unique name> in ASM, and in the folders the
# primary's file names only when step 2.15 proved that the folders are storage of this server.
L72_CLEAN=""; L72_FS=0
cleanup_auto_plan() {
  # $1 spfile | keep | mounted. Sets the plan for d_7_2 and returns 0, or 1 when the script must not do it
  # itself (folders whose storage is not proven: then the commands are shown, as before)
  local fs=0 dg lines=""
  [[ -n "$STANDBY_UNIQUE" && "${STANDBY_UNIQUE^^}" != "${PRIMARY_UNIQUE^^}" && "${STANDBY_UNIQUE^^}" != "${DB_NAME^^}" ]] || return 1
  # only the leftovers of a copy THIS script started and that did not finish (else the files may be a complete
  # standby, or an older database with the same name: then the commands are shown, nothing is done by the script)
  [[ -f "$STATE_DIR/dup_attempt" && ! -f "$(dup_marker)" ]] || return 1
  # files in folders are never deleted by the script (a shared disk can look local): the commands are shown
  [[ -z "$(fs_dirs)" ]] || return 1
  L72_CLEAN=$1; L72_FS=$fs
  local_state
  [[ "$LSTATE" != "IDLE" ]] && lines+="  stop the instance $STANDBY_SID (shutdown abort)"$'\n'
  [[ -f "$(spfile_path)" ]] && lines+="  rename its spfile to $(basename "$(spfile_path)").failed_$RUN_ID"$'\n'
  for dg in $(asm_dgs); do lines+="  delete +$dg/${STANDBY_UNIQUE^^} in ASM"$'\n'; done
  lines+="  then start the instance again from the pfile"
  PLAN="Clean up this server (after you type DELETE):"$'\n'"$lines"
  [[ -n "$(asm_dgs)" ]] && PLAN+=$'\n'"Never touched: $(asm_dgs | sed "s#^#+#; s#\$#/${PRIMARY_UNIQUE^^}#" | paste -sd' ' -) (the primary's files)"
  KIND_NOW=ask
  return 0
}
leftover_cleanup_do() {
  local dg f n=0
  local_state
  if [[ "$LSTATE" != "IDLE" ]]; then
    sql_local "shutdown abort" || { bad "shutdown abort failed: $(ora_errors "$SQL_OUT")"; return 1; }
    say "Instance $STANDBY_SID stopped."
  fi
  if [[ -f "$(spfile_path)" ]]; then
    runuser -u "$ORACLE_USER" -- mv -f -- "$(spfile_path)" "$(spfile_path).failed_$RUN_ID" || return 1
    journal RENAME "$(spfile_path)" "to=$(spfile_path).failed_$RUN_ID"
    say "Renamed $(spfile_path) to .failed_$RUN_ID"
  fi
  rm -f -- "$(dup_marker)"
  [[ -n "$STANDBY_UNIQUE" ]] || { bad "STANDBY_UNIQUE is empty. Nothing was deleted."; return 1; }
  for dg in $(asm_dgs); do
    grid_sw_ok || { bad "Grid is not installed here. Nothing was deleted in ASM."; return 1; }
    # the folder of the standby at the top of the disk group (parent_index = the disk group's root)
    sql_asm "select count(*) from v\$asm_alias a, v\$asm_diskgroup g where a.group_number=g.group_number and g.name=upper('$dg') and upper(a.name)=upper('$STANDBY_UNIQUE') and a.parent_index=a.group_number*16777216;" \
      || { bad "Cannot read ASM ($(ora_errors "$SQL_OUT")). Nothing was deleted in +$dg."; return 1; }
    [[ "$(first_line)" != "0" ]] || continue
    run_logged "asmcmd rm" as_grid "$GRID_HOME/bin/asmcmd" rm -rf "+$dg/${STANDBY_UNIQUE^^}" || { bad "Could not delete +$dg/${STANDBY_UNIQUE^^}: ${RUN_OUT%%$'\n'*}"; return 1; }
    journal DELETED "+$dg/${STANDBY_UNIQUE^^}" "cannot be undone: files of the unfinished copy, deleted after you typed DELETE"
    say "Deleted +$dg/${STANDBY_UNIQUE^^}"
  done
  _log CHANGE "clean-up of the unfinished copy done on $(hostname -s)"
  return 0
}
d_7_2() {
  if [[ -n "$L72_CLEAN" ]]; then
    local opts="[d] Delete them   [s] Skip   [h] Help   [q] Quit" allowed="dshq"
    [[ "$L72_CLEAN" == keep && -f "$STATE_DIR/dup_attempt" ]] && { opts="[d] Delete them   [k] Keep them (RMAN overwrites files with the same names)   [s] Skip   [h] Help   [q] Quit"; allowed="dkshq"; }
    while true; do
      ask_choice "$opts" "$allowed"
      case "$ANSWER" in
        h) show_help 7.2 || true ;;
        q) user_stop "Stopped by you" ;;
        s) L72_CLEAN=""; return 3 ;;
        k) install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/existing_files_ok"; say "The files stay. RMAN overwrites files with the same names."; break ;;
        d) confirm_word "The files of the unfinished copy on THIS server ($(hostname -s)) will be deleted." "DELETE" || { L72_CLEAN=""; return 3; }
           leftover_cleanup_do || { L72_CLEAN=""; return 1; }
           break ;;
      esac
    done
    L72_CLEAN=""
    local_state
    [[ "$LSTATE" == "IDLE" ]] || return 0          # NOMOUNT from the pfile already: nothing more to start
  fi
  local p; p=$(pfile_path)
  if [[ -f "$p" && "$(cat "$p")" != "$(pfile_text)" ]]; then backup_file "$p" "$ORACLE_USER" || return 1; fi
  [[ -f "$p" && "$(cat "$p")" == "$(pfile_text)" ]] || { pfile_text | write_as "$ORACLE_USER" "$p" 644 || return 1; }
  pfile_text | log_block "pfile $p"
  # journaled first: a run that stops during the startup still lists the instance for --undo
  journal INSTANCE "$STANDBY_SID" "started NOMOUNT with $p"
  sql_local_long "startup nomount pfile='$p'" || { bad "Startup nomount failed ($(ora_errors "$SQL_OUT"))"; printf '%s\n' "$SQL_OUT" | tail -n 5 | hint; return 1; }
}

# ---- 7.3 - 7.6 golden connections ----
golden_text() {
  case "$1" in
    *ORA-01017*)
      if [[ "$2" == "standby-tns" ]]; then
        printf 'Local login works, but login through the listener fails. Check:\n- the static entry: its ORACLE_HOME must be %s (step 5.1)\n- the password file: it must be a copy of the primary file (step 6.1)\n' "$DB_HOME"
      elif [[ "$2" == "local" ]]; then
        printf 'OS login failed: %s must be in the OSDBA group of this home.\nTo check:  id %s ; grep OSDBA %s/rdbms/lib/config.c\n' "$ORACLE_USER" "$ORACLE_USER" "$DB_HOME"
      else
        printf 'Wrong sys password, or the password files differ. To copy the file again:\n1. On the primary, as %s:  rm -f %s\n2. On this server:  mv %s %s.old\n3. Run:  %s --from 6.1\n' "$GRID_USER" "$(pw_tmp_remote)" "$(pw_dest)" "$(pw_dest)" "$SELF"
      fi ;;
    *ORA-12528*) printf 'The listener blocks the connection (phase 5).\n(UR = A) is missing in tnsnames.ora, or there is no static entry.\n' ;;
    *ORA-12514*) printf 'SERVICE_NAME in tnsnames.ora does not match GLOBAL_DBNAME of the static entry (phase 5).\n' ;;
    *ORA-12154*|*TNS-03505*) printf 'The alias is missing in tnsnames.ora (steps 5.3 and 5.4; on the primary, step 4.9).\n' ;;
    *ORA-12541*|*TNS-12541*) printf 'No listener at that host and port (phase 5), or the firewall blocks it (step 2.9).\n' ;;
    *ORA-12170*|*ORA-12535*) printf 'Timeout: a firewall or the network between the servers (steps 2.8 and 2.9).\n' ;;
    *ORA-01031*) printf 'Privilege problem: %s is not in the dba group, or the password file mode is wrong.\n' "$ORACLE_USER" ;;
    *ORA-01034*) printf 'The instance is not started (step 7.2).\n' ;;
    *) printf 'See the log for the full output.\n' ;;
  esac
}
need_sys() { [[ -n "$SYS_PW" ]] && return 0; NOW="The sys password is not known yet (step 1.5)"; NEED_SYS=1; return 1; }
c_7_3() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  if sql_local "select status from v\$instance;"; then NOW="Login works. Instance status: $(first_line)"; return 0; fi
  if grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    built_offline && { NOW="The standby exists but is not started. The logins are tested after step 9.2 starts it."; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  NOW="Local login failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" local); return 1
}
c_7_4() {
  need_sys || return 2
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  local_state
  if [[ "$LSTATE" == "IDLE" ]]; then
    built_offline && { NOW="The standby exists and is not started; tested after step 9.2"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  if sql_standby_tns "select instance_name||' '||status from v\$instance;"; then NOW="Login works: sys@$STANDBY_TNS reaches $(first_line)"; return 0; fi
  if grep -q 'ORA-01034' <<< "$SQL_OUT"; then
    built_offline && { NOW="The standby exists and is not started; tested after step 9.2"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  NOW="Login sys@$STANDBY_TNS failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" standby-tns); return 1
}
c_7_5() {
  need_sys || return 2
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  tns_alias_present "$PRIMARY_TNS" || { NOW="Alias $PRIMARY_TNS is not in tnsnames.ora on this server yet (step 5.3)"; return 2; }
  if sql_primary_tns "select db_unique_name||' '||database_role from v\$database;"; then NOW="Login works: sys@$PRIMARY_TNS reaches $(first_line)"; return 0; fi
  NOW="Login sys@$PRIMARY_TNS failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" primary); return 1
}
c_7_6() {
  need_sys || return 2
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  # the login goes to the standby instance through its listener: before 7.2 there is nothing to reach
  local_state
  if [[ "$LSTATE" == "IDLE" ]]; then
    built_offline && { NOW="The standby exists and is not started; tested after step 9.2"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  need_ssh || return 2
  if prim_sql_as_sys "$STANDBY_TNS" "select instance_name||' '||status from v\$instance;"; then NOW="Login from the primary works: sys@$STANDBY_TNS reaches $(first_line)"; return 0; fi
  if grep -q 'ORA-01034' <<< "$SQL_OUT"; then
    built_offline && { NOW="The standby exists and is not started; tested after step 9.2"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  NOW="Login from the primary to sys@$STANDBY_TNS failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" standby-tns); return 1
}

phase_7() {
  phase_header 7 "Start the empty instance (NOMOUNT)"
  run_step 7.1 auto  "Folders for the instance (audit, diagnostics)" c_7_1 d_7_1
  run_step 7.2 auto  "Instance $STANDBY_SID in NOMOUNT" c_7_2 d_7_2
  run_step 7.3 check "Login 1 of 4: sqlplus / as sysdba on this server" c_7_3
  run_step 7.4 check "Login 2 of 4: sys@$STANDBY_TNS through the listener" c_7_4
  run_step 7.5 check "Login 3 of 4: sys@$PRIMARY_TNS from this server" c_7_5
  run_step 7.6 check "Login 4 of 4: sys@$STANDBY_TNS from the primary" c_7_6
  run_step 7.7 auto  "/etc/oratab entry for $STANDBY_SID" c_7_7 d_7_7
}

#------------------------------------------------------------------------------
# PHASE 8  RMAN active duplicate
#------------------------------------------------------------------------------
DUP_EXTRA=""; PRE_OK=0; PRE_INFO=""; NEWNAMES=""

CF_LIST=""
space_check() {
  # appends to PRE_INFO; sets PRE_FIX and returns 1 if there is not enough space for the database files
  local dg need free l d mnt
  for dg in $(asm_dgs); do
    need=0
    while IFS= read -r l; do
      d=${l%%:*}; d=${d#+}; d=${d%%/*}; [[ "${d^^}" == "$dg" ]] && need=$((need + ${l##*:}))
    done < <(loc_list | grep '^+')
    [[ $need -eq 0 ]] && continue
    need=$(( need * 110 / 100 ))
    free=0; sql_asm "select free_mb from v\$asm_diskgroup where name=upper('$dg');" && free=$(first_line)
    num "$free" || free=0
    # (files of an earlier copy in ASM are NOT counted as free: a new copy creates new OMF files next to them)
    if [[ $free -lt $need ]]; then
      PRE_FIX="+$dg has $(human_mb "$free") free, but needs about $(human_mb "$need") (the database files plus 10%)."
      [[ -n "$(orphan_leftovers | grep -F "+$dg/")" ]] && PRE_FIX+=$'\n'"Files of an earlier copy are in +$dg/${STANDBY_UNIQUE^^}. Removing them frees space (step 7.2 shows how: $SELF --from 7.2)."
      PRE_FIX+=$'\n'"Or add a disk to +$dg: run $SELF --from 2.13, then as $GRID_USER:"$'\n'"  export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM ; \$ORACLE_HOME/bin/sqlplus / as sysasm"$'\n'"  alter diskgroup $dg add disk '$(asm_disk_dir)/<label>';"
      return 1
    fi
    PRE_INFO+="+$dg: $(human_mb "$free") free, about $(human_mb "$need") needed (database files + 10%)"$'\n'
  done
  declare -A need_by_mnt=() free_by_mnt=() there_by_mnt=()
  while IFS= read -r l; do
    d=${l%%:*}
    [[ -d "$d" ]] || { PRE_FIX="The folder $d does not exist (step 2.14)"; return 1; }
    mnt=$(mnt_of "$d"); [[ -n "$mnt" ]] || { PRE_FIX="Cannot read the free space of $d (df)"; return 1; }
    need_by_mnt[$mnt]=$(( ${need_by_mnt[$mnt]:-0} + ${l##*:} ))
    free_by_mnt[$mnt]=$(free_mb_of "$d")
  done < <(loc_list | grep '^/')
  # files at exactly the target paths (an earlier copy) are overwritten by RMAN: their space counts as free (once per file)
  if [[ ${#need_by_mnt[@]} -gt 0 ]] && sql_or_cached_filenames; then
    local f sz
    while IFS= read -r f; do
      [[ -n "$f" && -f "$f" ]] || continue
      mnt=$(mnt_of "$(dirname "$f")"); [[ -n "${need_by_mnt[$mnt]:-}" ]] || continue
      sz=$(stat -c '%s' -- "$f" 2>/dev/null); num "$sz" || continue
      there_by_mnt[$mnt]=$(( ${there_by_mnt[$mnt]:-0} + sz / 1048576 ))
    done <<< "$FS_FILENAMES"
    for mnt in "${!there_by_mnt[@]}"; do free_by_mnt[$mnt]=$(( ${free_by_mnt[$mnt]:-0} + ${there_by_mnt[$mnt]} )); done
  fi
  for mnt in "${!need_by_mnt[@]}"; do
    need=$(( ${need_by_mnt[$mnt]} * 110 / 100 )); free=${free_by_mnt[$mnt]}; num "$free" || free=0
    [[ $free -ge $need ]] || { PRE_FIX="File system $mnt has $(human_mb "$free") free, but needs about $(human_mb "$need") (the database files plus 10%)."; return 1; }
    PRE_INFO+="File system $mnt: $(human_mb "$free") free, about $(human_mb "$need") needed"$'\n'
  done
  return 0
}

dup_prechecks() {
  # read-only. Sets PRE_OK, PRE_INFO (lines), PRE_FIX, DUP_EXTRA, CF_LIST, DEST_N, NEWNAMES.
  PRE_OK=0; PRE_INFO=""; PRE_FIX=""; DUP_EXTRA=""; CF_LIST=""; NEWNAMES=""
  local_state
  [[ "$LSTATE" == "STARTED" ]] || { PRE_FIX="The standby instance must be in NOMOUNT, but it is $LSTATE (step 7.2)"; return 1; }
  if spfile_from_failed_copy; then PRE_FIX="The instance runs from the spfile of an unfinished copy. Clean up first (step 7.2)"; return 1; fi
  # the disk group of the logs must fit the block size of the primary's redo (else ORA-01378 after the copy, at 9.3)
  if use_grid && grid_sw_ok; then
    local ldg="$DATA_DG"; [[ "$CFD" == +* ]] && { ldg=$(norm_loc "$CFD"); ldg=${ldg#+}; }
    if [[ -n "$ldg" ]] && sql_asm "select sector_size from v\$asm_diskgroup where name=upper('$ldg');" && num "$(first_line)"; then
      local ss; ss=$(first_line)
      if [[ "${PRIMARY_REDO_BS:-512}" == "4096" && "$ss" != "4096" ]] || [[ "${PRIMARY_REDO_BS:-512}" == "512" && "$ss" == "4096" ]]; then
        PRE_FIX="+$ldg has a sector size of $ss bytes, but the primary's redo logs use ${PRIMARY_REDO_BS}-byte blocks."$'\n'"After the copy, the standby logs could not be created (ORA-01378)."$'\n'"First create a disk group with sector_size ${PRIMARY_REDO_BS} for the logs. Help: --help-step 3.5"
        return 1
      fi
      PRE_INFO+="+$ldg: sector size $ss bytes fits the redo block size ${PRIMARY_REDO_BS:-512}"$'\n'
    fi
  fi
  # the copy takes the spfile of the primary (duplicate ... spfile): a primary started from a pfile fails there
  prim_sql "select nvl(value,'-') from v\$parameter where name='spfile';" && [[ "$(first_line)" == "-" ]] && { PRE_FIX="The primary runs from a text pfile, but the copy needs its spfile (step 4.1)"; return 1; }
  if [[ -f "$STATE_DIR/dup_attempt" && ! -f "$STATE_DIR/existing_files_ok" && "$(marker_kind)" != "duplicate" && -n "$(orphan_leftovers)" ]]; then
    PRE_FIX="Files of an unfinished copy are still on this server. Clean them up first (step 7.2)"; return 1
  fi
  PRE_INFO+="Standby instance $STANDBY_SID is in NOMOUNT"$'\n'
  if tde_autologin_missing; then PRE_FIX="The TDE keystore of the standby has no auto-login file (cwallet.sso)."$'\n'"The copy and redo apply would stop with ORA-28365 (step 6.3)"; return 1; fi
  # the folders of this server must not be the storage of the primary (NOFILENAMECHECK would overwrite it)
  if [[ -n "$(fs_dirs)" && "$MODE" == "run" ]]; then
    storage_cache; local src=$STORAGE_SRC
    [[ $src -eq 1 ]] && { PRE_FIX="$STORAGE_SHARED is the same storage that the primary uses (step 2.15)."$'\n'"The copy would overwrite the database files of the primary. Do NOT continue."; return 1; }
    [[ $src -eq 2 ]] && { PRE_FIX="$STORAGE_INFO (step 2.15)"; return 1; }
    PRE_INFO+="The database folders are on storage of this server only"$'\n'
  fi
  space_check || return 1
  # primary prerequisites (phase 4) again: a skipped step must not make RMAN fail late
  prim_sql "select log_mode||'|'||force_logging from v\$database;" || { PRE_FIX="Cannot read the log mode of the primary"; return 1; }
  local lm fl; IFS='|' read -r lm fl <<< "$(first_line)"
  [[ "$lm" == "ARCHIVELOG" ]] || { PRE_FIX="The primary is in $lm mode. It must be in ARCHIVELOG mode (step 4.1)"; return 1; }
  [[ "$fl" == "YES" ]] || warn "FORCE LOGGING is off on the primary (step 4.1)."$'\n'"NOLOGGING operations would not reach the standby."
  p_param remote_login_passwordfile || { PRE_FIX="Cannot read remote_login_passwordfile on the primary"; return 1; }
  [[ "$PVAL" == "EXCLUSIVE" || "$PVAL" == "SHARED" ]] || { PRE_FIX="remote_login_passwordfile on the primary is $PVAL. The primary must be restarted after the change (step 4.7)"; return 1; }
  # role separation: the oracle binary must be able to open the ASM disks
  if use_grid && ! single_owner; then
    local og want l1; og=$(stat -c '%G' "$DB_HOME/bin/oracle" 2>/dev/null)
    # the group of a real ASM disk is what counts
    l1=$(asm_labels "$DATA_DG" | head -n 1); want=""
    [[ -n "$l1" ]] && want=$(stat -L -c '%G' "$(asm_disk_dir)/$l1" 2>/dev/null)
    [[ -n "$want" && "$want" != "root" ]] || want=$(asm_owner_group)
    if [[ "$og" != "$want" ]]; then
      PRE_FIX="$DB_HOME/bin/oracle has group $og. It must be $want, the group of the ASM disks, or it cannot open them (ORA-15025)."$'\n'"As root:  $GRID_HOME/bin/setasmgidwrap o=$DB_HOME/bin/oracle"
      # the script can fix this itself (step 8.1 offers it); the old group is kept for the undo
      [[ -x "$GRID_HOME/bin/setasmgidwrap" ]] && { PRE_ASMGID_OLD=$og; PRE_ASMGID_WANT=$want; }
      return 1
    fi
  fi
  # RMAN uses the TNS aliases: prove they reach the right databases
  local pu pr pn ph ti th ts ls; ls=$(hostname -s 2>/dev/null || hostname)
  sql_primary_tns "select d.db_unique_name||'|'||d.database_role||'|'||d.name||'|'||i.host_name from v\$database d, v\$instance i;" || { PRE_FIX="Cannot reach the primary through $PRIMARY_TNS: $(ora_errors "$SQL_OUT") (step 7.5)"; return 1; }
  IFS='|' read -r pu pr pn ph <<< "$(first_line)"
  local phs=${ph%%.*}
  if [[ "${pu^^}" != "${PRIMARY_UNIQUE^^}" || "$pr" != "PRIMARY" || "${pn^^}" != "${DB_NAME^^}" || "${phs,,}" == "${ls,,}" ]]; then
    PRE_FIX="Alias $PRIMARY_TNS does not reach the primary. It reaches: $pu, $pr, $pn, host $ph"; return 1
  fi
  PRE_INFO+="$PRIMARY_TNS reaches $pu (PRIMARY) on $ph"$'\n'
  sql_standby_tns "select instance_name||'|'||host_name||'|'||status from v\$instance;" || { PRE_FIX="Cannot reach the standby through $STANDBY_TNS: $(ora_errors "$SQL_OUT") (step 7.4)"; return 1; }
  IFS='|' read -r ti th ts <<< "$(first_line)"
  local ths=${th%%.*}      # host names compared without the domain and without case
  if [[ "${ti^^}" != "${STANDBY_SID^^}" || "${ths,,}" != "${ls,,}" || "$ts" != "STARTED" ]]; then
    PRE_FIX="Alias $STANDBY_TNS does not reach the NOMOUNT instance on this server. It reaches: $ti, host $th, $ts"; return 1
  fi
  PRE_INFO+="$STANDBY_TNS reaches $ti (NOMOUNT) on this server"$'\n'
  # memory: the spfile of primary is copied; the standby must be able to start with it
  prim_sql "select name||'|'||nvl(value,'0') from v\$parameter where name in ('sga_target','sga_max_size','memory_target','memory_max_target','use_large_pages','db_recovery_file_dest_size');" \
    || { PRE_FIX="Cannot read the memory parameters of the primary"; return 1; }
  local pn pv sga=0 ulp="" rfs=0 memkb hp hpkb mt=0
  while IFS='|' read -r pn pv; do
    case "$pn" in
      sga_target|sga_max_size|memory_target|memory_max_target) num "$pv" && [[ $pv -gt $sga ]] && sga=$pv
                                                             [[ "$pn" == memory_* ]] && num "$pv" && [[ $pv -gt $mt ]] && mt=$pv ;;
      use_large_pages) ulp=${pv^^} ;;
      db_recovery_file_dest_size) num "$pv" && rfs=$pv ;;
    esac
  done <<< "$SQL_OUT"
  memkb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null); num "$memkb" || memkb=0
  hp=$(awk '/^HugePages_Total:/{print $2}' /proc/meminfo 2>/dev/null); num "$hp" || hp=0
  hpkb=$(awk '/^Hugepagesize:/{print $2}' /proc/meminfo 2>/dev/null); num "$hpkb" || hpkb=0
  if [[ $memkb -gt 0 && $(( sga / 1024 )) -gt $(( memkb * 80 / 100 )) ]]; then
    PRE_FIX="The SGA or memory target of the primary is $(human_mb $(( sga / 1048576 ))), but this server has only $(human_mb $(( memkb / 1024 ))) RAM."$'\n'"Add RAM to the standby. It needs as much memory as the primary."
    return 1
  fi
  PRE_INFO+="Memory: the primary needs $(human_mb $(( sga / 1048576 ))), this server has $(human_mb $(( memkb / 1024 )))"$'\n'
  if [[ $mt -gt 0 ]]; then
    # AMM (memory_target) uses /dev/shm; it must be at least as big (ORA-00845)
    local shm; shm=$(df -m --output=avail /dev/shm 2>/dev/null | tail -n 1 | tr -d ' '); num "$shm" || shm=0
    [[ $shm -ge $(( mt / 1048576 )) ]] || { PRE_FIX="memory_target is $(( mt / 1048576 )) MB, but /dev/shm has only $shm MB (ORA-00845)."$'\n'"As root:  mount -o remount,size=$(( mt / 1048576 + 1024 ))m /dev/shm"$'\n'"Set the same size in /etc/fstab too."; return 1; }
  fi
  if [[ "$ulp" == "ONLY" && $(( hp * hpkb )) -lt $(( sga / 1024 )) ]]; then
    DUP_EXTRA+="      set use_large_pages='TRUE'"$'\n'
    PRE_INFO+="The primary has use_large_pages=ONLY, but this server has too few HugePages."$'\n'"The standby gets TRUE. Configure HugePages later."$'\n'
  fi
  # recovery area: never bigger than the space here
  local fra_total=0
  if [[ "$FRA_LOC" == +* ]]; then
    sql_asm "select total_mb from v\$asm_diskgroup where name=upper('${FRA_LOC#+}');" && fra_total=$(first_line)
  elif [[ -n "$FRA_LOC" && -d "$FRA_LOC" ]]; then
    fra_total=$(df -m --output=size -- "$FRA_LOC" 2>/dev/null | tail -n 1 | tr -d ' ')
  fi
  num "$fra_total" || fra_total=0
  if [[ $rfs -gt 0 && $fra_total -gt 0 && $(( rfs / 1048576 )) -gt $(( fra_total * 90 / 100 )) ]]; then
    DUP_EXTRA+="      set db_recovery_file_dest_size='$(( fra_total * 90 / 100 ))M'"$'\n'
    PRE_INFO+="The recovery area size of the primary ($(human_mb $(( rfs / 1048576 )))) is bigger than $FRA_LOC here ($(human_mb "$fra_total"))."$'\n'"The standby gets $(human_mb $(( fra_total * 90 / 100 )))."$'\n'
  fi
  # control files: same disk group (new OMF names) or the same path (an OMF file name becomes controlNN.ctl)
  prim_sql "select name from v\$controlfile;" || { PRE_FIX="Cannot read the control files of the primary"; return 1; }
  local cf n=0
  while IFS= read -r cf; do
    [[ "$cf" =~ ^[+/][A-Za-z0-9_./-]+$ ]] || continue
    n=$((n + 1))
    if [[ "$cf" == +* ]]; then cf=$(norm_loc "$cf")
    elif [[ "$(basename "$cf")" == o1_mf_*.ctl ]]; then cf="$(dirname "$cf")/$(printf 'control%02d.ctl' "$n")"; fi
    CF_LIST+="${CF_LIST:+,}'$cf'"
  done <<< "$SQL_OUT"
  [[ -n "$CF_LIST" ]] || { PRE_FIX="The primary returned no control file names"; return 1; }
  # every datafile and tempfile is created in its own disk group (or with its own name in a folder)
  prim_sql "select 'D|'||file#||'|'||name from v\$datafile union all select 'T|'||file#||'|'||name from v\$tempfile;" || { PRE_FIX="Cannot read the datafile names of the primary"; return 1; }
  local k fno fname
  while IFS='|' read -r k fno fname; do
    num "$fno" && [[ "$fname" =~ ^[+/][A-Za-z0-9_./-]+$ ]] || continue
    local what=datafile; [[ "$k" == "T" ]] && what=tempfile
    if [[ "$fname" == +* ]]; then NEWNAMES+="  set newname for $what $fno to '$(norm_loc "$fname")';"$'\n'
    elif [[ "$(basename "$fname")" != o1_mf_* ]]; then NEWNAMES+="  set newname for $what $fno to '$fname';"$'\n'; fi
  done <<< "$SQL_OUT"
  # files that already exist at the target paths: an earlier copy of this standby, or something else?
  if [[ "$MODE" == "run" && ! -f "$STATE_DIR/existing_files_ok" ]]; then
    local ex="" exn=0 ef
    while IFS='|' read -r k fno fname; do
      [[ "$fname" == /* && -e "$fname" ]] && { exn=$((exn + 1)); [[ $exn -le 5 ]] && ex+="  $fname"$'\n'; }
    done <<< "$SQL_OUT"
    for ef in $(tr ',' '\n' <<< "$CF_LIST" | tr -d "'"); do [[ "$ef" == /* && -e "$ef" ]] && { exn=$((exn + 1)); [[ $exn -le 5 ]] && ex+="  $ef"$'\n'; }; done
    if [[ $exn -gt 0 ]]; then
      if [[ "$(marker_kind)" == "" && ! -f "$STATE_DIR/dup_attempt" ]]; then
        PRE_FIX="$exn file(s) already exist where the copy will write. This script did not make them:"$'\n'"${ex%$'\n'}"
        [[ $exn -gt 5 ]] && PRE_FIX+=$'\n'"  ... and $((exn - 5)) more"
        PRE_FIX+=$'\n'"RMAN would overwrite them (NOFILENAMECHECK)."$'\n'"If they belong to an old database on this server, move or remove them."$'\n'"They are not files of the primary (step 2.15 proved it)."$'\n'"If they may be overwritten, run this and answer r:"$'\n'"  touch $STATE_DIR/existing_files_ok"
        return 1
      fi
      PRE_INFO+="$exn file(s) of the earlier copy will be overwritten"$'\n'
    fi
  fi
  if grep -qE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT"; then
    # file-system OMF files are created again as OMF files in db_create_file_dest
    local omfd="$CFD"
    if [[ "$omfd" != /* ]]; then
      # db_create_file_dest is not a folder on primary: the standby gets the folder of the OMF files (set on the standby only)
      omfd=$(grep -m1 -oE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT" | cut -d'|' -f3); omfd=$(dirname "$(dirname "$(dirname "$omfd")")")
      v_path "$omfd" || { PRE_FIX="Cannot find the folder for the OMF datafiles of the primary"; return 1; }
      DUP_EXTRA+="      set db_create_file_dest='$omfd'"$'\n'
    fi
    runuser -u "$ORACLE_USER" -- test -d "$omfd" -a -w "$omfd" || { PRE_FIX="The OMF folder $omfd does not exist here or is not writable by $ORACLE_USER (step 2.14)"; return 1; }
    PRE_INFO+="OMF datafiles are created in $omfd/${STANDBY_UNIQUE^^}"$'\n'
  fi
  if use_grid && [[ -z "$CFD" || "$CFD" == "-" ]] && ! grep -qE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT"; then
    # datafiles in ASM but no db_create_file_dest: the standby could not create its standby/online logs (ORA-15046).
    # The disk group is the one of the datafiles (never a disk group that only holds the recovery area).
    local ddg; ddg=$(grep -m1 -oE '^D\|[0-9]+\|\+[^/]+' <<< "$SQL_OUT" | cut -d'|' -f3)
    if [[ -n "$ddg" ]]; then
      DUP_EXTRA+="      set db_create_file_dest='$ddg'"$'\n'
      PRE_INFO+="The primary has no db_create_file_dest. The standby gets $ddg, for its redo logs in ASM."$'\n'
    fi
  fi
  # the standby's own audit folder
  DUP_EXTRA+="      set audit_file_dest='$(adump_dir)'"$'\n'
  # redo transport destination used on primary for this standby (the standby gets the same N back to primary)
  find_dest || { PRE_FIX="Cannot read log_archive_dest_N on the primary"; return 1; }
  p_param log_archive_config && P_DG_CONFIG=$PVAL || P_DG_CONFIG=""
  dg_config_names_ok "$P_DG_CONFIG" || { PRE_FIX="log_archive_config of the primary cannot be read safely: $P_DG_CONFIG. Check step 4.3."; return 1; }
  # primary parameters that do not fit the standby
  prim_sql "select name||'|'||value from v\$parameter where value is not null and (name like 'db_create_online_log_dest%' or name like 'log_archive_dest%' or name in ('log_archive_duplex_dest','remote_listener','local_listener','fal_client','db_file_name_convert','log_file_name_convert','dg_broker_start','instance_name','service_names'));" || { PRE_FIX="Cannot read the parameters of the primary"; return 1; }
  local line pname pval known_dgs=" $(asm_dgs | tr '\n' ' ') "
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pname=${line%%|*}; pval=${line#*|}
    if [[ "$pname" =~ ^db_create_online_log_dest_[1-5]$ ]]; then
      local loc; loc=$(norm_loc "$pval")
      if [[ "$loc" == +* && "$known_dgs" != *" ${loc#+} "* ]] || [[ "$loc" == /* && ! -d "$loc" ]]; then
        DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="$pname of the primary ($pval) does not exist here. Cleared on the standby."$'\n'
      fi
    elif [[ "$pname" =~ ^log_archive_dest_([0-9]+)$ ]]; then
      local dn=${BASH_REMATCH[1]}
      if [[ "$dn" != "$DEST_N" && "$dn" != "$ARCH_N" && "$(sed -E "s/ *= */=/g" <<< "${pval^^}")" == *SERVICE=* ]]; then
        # a destination to another standby: kept for a later switchover, but off until then
        DUP_EXTRA+="      set log_archive_dest_state_$dn='defer'"$'\n'; PRE_INFO+="$pname of the primary points to another standby. Kept, but deferred here."$'\n'
      elif [[ "$dn" != "$DEST_N" && "$dn" != "$ARCH_N" ]]; then
        DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="$pname of the primary is cleared on the standby"$'\n'
      fi
    elif [[ "$pname" == "log_archive_dest" || "$pname" == "log_archive_duplex_dest" ]]; then
      # old-style parameters cannot be used together with log_archive_dest_1 (ORA-16019)
      DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="The primary uses the old-style $pname. Cleared on the standby."$'\n'
    elif [[ "$pname" == "remote_listener" || "$pname" == "fal_client" || "$pname" == "db_file_name_convert" ]]; then
      DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="$pname of the primary: cleared on the standby"$'\n'
    elif [[ "$pname" == "log_file_name_convert" ]]; then
      HAS_LFNC=1
    elif [[ "$pname" == "dg_broker_start" && "${pval^^}" == "TRUE" ]]; then
      DUP_EXTRA+="      set dg_broker_start='FALSE'"$'\n'; PRE_INFO+="The primary uses the Data Guard broker. It stays off on the standby until you add it there."$'\n'
    elif [[ "$pname" == "instance_name" && "${pval^^}" != "${STANDBY_SID^^}" ]]; then
      DUP_EXTRA+="      set instance_name='$STANDBY_SID'"$'\n'; PRE_INFO+="instance_name of the primary is $pval. The standby gets $STANDBY_SID."$'\n'
    elif [[ "$pname" == "service_names" ]]; then
      DUP_EXTRA+="      set service_names='$STANDBY_SERVICE'"$'\n'; PRE_INFO+="service_names of the primary is $pval. The standby gets $STANDBY_SERVICE,"$'\n'"so clients of the primary service never reach the standby."$'\n'
    fi
  done <<< "$SQL_OUT"
  # same paths on both servers: MRP tries to clear the online logs and prints ORA-19527/ORA-00312 in the alert
  # log at every start. A convert pair that matches nothing stops that noise (Oracle note 352879.1).
  [[ ${HAS_LFNC:-0} -eq 1 ]] || DUP_EXTRA+="      set log_file_name_convert='/__dg_no_rename__','/__dg_no_rename__'"$'\n'
  # the whole RMAN text is parsed by RMAN itself before anything starts (no connection needed); once per run
  if [[ "$MODE" == "run" && "${RMAN_PREFLIGHT_OK:-}" != "$(rman_script | md5sum | cut -c1-12)" ]]; then
    # the script holds no password (the connect lines are not in it); rman reads it as the database owner
    local chk; chk=$(mktemp /tmp/dg_rman.XXXXXXXX) || { PRE_FIX="Cannot create a temporary file in /tmp"; return 1; }
    CLEANUP_FILES+=("$chk")
    rman_script > "$chk" && chmod 644 "$chk" || { PRE_FIX="Cannot write $chk"; return 1; }
    if ! run_logged "rman checksyntax" as_oracle timeout 120 "$DB_HOME/bin/rman" checksyntax "cmdfile=$chk"; then
      PRE_FIX="RMAN does not accept the generated script: $(grep -E 'RMAN-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ')"$'\n'"The script is saved as $LOG_DIR/duplicate_check_$RUN_ID.rman"
      cp -p -- "$chk" "$LOG_DIR/duplicate_check_$RUN_ID.rman" 2>/dev/null; return 1
    fi
    rm -f -- "$chk"
    # and a real RMAN login to both databases (the connect lines, nothing else)
    local lrc=0 ltmp
    ltmp=$(mktemp /tmp/dg_out.XXXXXXXX) || { PRE_FIX="Cannot create a temporary file"; return 1; }
    CLEANUP_FILES+=("$ltmp")
    # the passwords travel on stdin only (never in a file, never in argv)
    { printf 'connect target sys/"%s"@%s\n' "$SYS_PW" "$PRIMARY_TNS"; printf 'connect auxiliary sys/"%s"@%s\n' "$SYS_PW" "$STANDBY_TNS"; printf 'exit\n'; } \
      | as_oracle timeout 120 "$DB_HOME/bin/rman" > "$ltmp" 2>&1 || lrc=1
    RUN_OUT=$(cat "$ltmp"); rm -f -- "$ltmp"
    printf '%s\n(exit code %s)\n' "$RUN_OUT" "$lrc" | log_block "rman login test"
    # success = both "connected to" lines (RMAN may print harmless warnings next to them)
    if ! grep -q 'connected to target database' <<< "$RUN_OUT" || ! grep -q 'connected to auxiliary database' <<< "$RUN_OUT"; then
      PRE_FIX="RMAN cannot log in to both databases: $(grep -E '(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ')"$'\n'"Check the logins of steps 7.4 and 7.5."; return 1
    fi
    PRE_INFO+="RMAN accepts the script and logs in to both databases"$'\n'
    grep -qE '^(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" && PRE_INFO+="RMAN printed warnings at the login: $(grep -E '^(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ')"$'\n'
    RMAN_PREFLIGHT_OK=$(rman_script | md5sum | cut -c1-12)
  fi
  PRE_INFO=${PRE_INFO%$'\n'}
  PRE_OK=1
}
HAS_LFNC=0; RMAN_PREFLIGHT_OK=""

PRE_ASMGID_OLD=""; PRE_ASMGID_WANT=""
c_8_1() {
  PRE_ASMGID_OLD=""; PRE_ASMGID_WANT=""
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  need_ssh || return 2
  detect_built
  [[ $STANDBY_BUILT -eq 1 ]] || need_sys || return 2
  [[ $STANDBY_BUILT -eq 1 ]] && { NOW="The standby database already exists. No copy is needed."; return 0; }
  if dup_prechecks; then NOW=$PRE_INFO; return 0; fi
  NOW=$PRE_FIX
  [[ "$PRE_FIX" == *"(step "* ]] && return 2          # an earlier step is not done yet
  if [[ -n "$PRE_ASMGID_OLD" ]]; then
    # the one pre-check the script fixes itself: the group of the oracle program
    NOW="$DB_HOME/bin/oracle has group $PRE_ASMGID_OLD. It must be $PRE_ASMGID_WANT, the group of the ASM disks (ORA-15025)."
    PLAN="As root:  $GRID_HOME/bin/setasmgidwrap o=$DB_HOME/bin/oracle"$'\n'"Then all pre-checks run again."
    KIND_NOW=auto; return 1
  fi
  PLAN="$PRE_FIX"; return 1
}
d_8_1() {
  run_logged "setasmgidwrap" "$GRID_HOME/bin/setasmgidwrap" "o=$DB_HOME/bin/oracle" || { bad "setasmgidwrap failed: ${RUN_OUT%%$'\n'*}"; return 1; }
  journal ASMGID "$DB_HOME/bin/oracle" "by hand, only if wanted, as root: chgrp $PRE_ASMGID_OLD $DB_HOME/bin/oracle ; chmod 6751 $DB_HOME/bin/oracle  (the group it had before)"
  say "$DB_HOME/bin/oracle now has group $(stat -c '%G' "$DB_HOME/bin/oracle" 2>/dev/null)."
  return 0
}

rman_script() {
  local i ch="" d1="" ll="''"
  for ((i = 1; i <= AUX_CHANNELS; i++)); do ch+="  allocate auxiliary channel a$i device type disk;"$'\n'; done
  if [[ "$ARCH_LOC" == "USE_DB_RECOVERY_FILE_DEST" ]]; then d1="location=use_db_recovery_file_dest"
  elif [[ -n "$ARCH_LOC" ]]; then d1="location=$ARCH_LOC"; fi
  local dgc; dgc=$(lac_merged "${P_DG_CONFIG:-}")
  # the standby instance registers with its own listener (port of primary)
  [[ "$PORT" != "1521" ]] && ll="'(ADDRESS=(PROTOCOL=TCP)(HOST=$STANDBY_HOST)(PORT=$PORT))'"
  cat <<EOF
run {
${ch}${NEWNAMES}  duplicate target database for standby from active database
    dorecover
    spfile
      set db_unique_name='$STANDBY_UNIQUE'
      set control_files=$CF_LIST
      set fal_server='$PRIMARY_TNS'
      set log_archive_config='$dgc'
EOF
  [[ -n "$d1" ]] && printf "      set log_archive_dest_%s='%s valid_for=(all_logfiles,all_roles) db_unique_name=%s'\n" "${ARCH_N:-1}" "$d1" "$STANDBY_UNIQUE"
  cat <<EOF
      set log_archive_dest_${DEST_N:-2}='service=$PRIMARY_TNS async valid_for=(online_logfiles,primary_role) db_unique_name=$PRIMARY_UNIQUE'
      set log_archive_dest_state_${DEST_N:-2}='enable'
      set standby_file_management='AUTO'
      set local_listener=$ll
${DUP_EXTRA}    nofilenamecheck;
}
EOF
}

c_8_2() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  need_ssh || return 2
  detect_built
  [[ $STANDBY_BUILT -eq 1 ]] || need_sys || return 2
  [[ $STANDBY_BUILT -eq 1 ]] && { NOW="The standby database exists (the copy finished)"; return 0; }
  if [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]]; then
    NOW="A failed or unfinished copy is on this server: $SC_INFO."$'\n'"Clean it up first. Run  $SELF --from 7.2  (step 7.2 shows the commands)."
    return 2
  fi
  dup_prechecks || { NOW="The pre-checks did not pass: $PRE_FIX (step 8.1)"; return 2; }
  NOW="The standby instance is in NOMOUNT and all pre-checks passed"
  local nd nt; nd=$(grep -c 'for datafile' <<< "$NEWNAMES"); nt=$(grep -c 'for tempfile' <<< "$NEWNAMES")
  # the network limits the whole copy: about 100 MB/s on 1 Gbit/s, up to about 1000 MB/s on 10 Gbit/s
  local rate_hi=$(( AUX_CHANNELS * 150 )); [[ $rate_hi -gt 1000 ]] && rate_hi=1000
  local est_lo est_hi; est_lo=$(( PRIMARY_DB_MB / rate_hi / 60 + 1 )); est_hi=$(( PRIMARY_DB_MB / 100 / 60 + 1 ))
  PLAN="Copy the database from the primary with RMAN (active duplicate), as $ORACLE_USER:
  rman target sys@$PRIMARY_TNS auxiliary sys@$STANDBY_TNS
Size to copy: about $(human_mb "$PRIMARY_DB_MB"), with $AUX_CHANNELS channels on this server
Rough time: $(human_min "$est_lo") (fast network and storage) to $(human_min "$est_hi") (1 Gbit/s network)
The primary database is only read: nothing is created, dropped or changed in it.
On the primary during the copy: extra disk and network load, log switches,
a snapshot control file in its \$ORACLE_HOME/dbs, and an audit file for each login.
Run the copy when the load is low, for example at night."
  USING="RMAN command: duplicate target database for standby from active database
  (dorecover, spfile, nofilenamecheck)
$nd $([[ $nd -eq 1 ]] && printf 'datafile' || printf 'datafiles') and $nt $([[ $nt -eq 1 ]] && printf 'tempfile' || printf 'tempfiles') keep their disk group or path.
Settings written to the standby spfile:
$(sed -n 's/^      set /  /p' <<< "$(rman_script)")
The full RMAN script is saved first to $LOG_DIR/duplicate_<date>.rman"
  [[ -z "${TMUX:-}${STY:-}" ]] && USING+=$'\n'"The copy runs in its own session: closing the terminal does not stop it."$'\n'"Run the script again to watch it."
  return 1
}

d_8_2() {
  confirm_word "Start the RMAN copy now." "DUPLICATE" || { say "The copy was not started."; return 3; }
  # the checks again, right before the start (tnsnames.ora or the instance may have changed meanwhile)
  dup_prechecks || { bad "The pre-checks no longer pass: $PRE_FIX"; return 1; }
  local rmanfile="$LOG_DIR/duplicate_$RUN_ID.rman" rlog="$LOG_DIR/duplicate_$RUN_ID.log"
  [[ -e "$(dup_marker)" ]] && rm -f -- "$(dup_marker)"
  rman_script | write_as root "$rmanfile" 640 || return 1
  say "RMAN script:  $rmanfile"
  DUP_RAN=1
  install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/dup_attempt"
  journal DUPLICATE "$STANDBY_UNIQUE" "RMAN duplicate started: files of the standby are created in $(all_locs | cut -d: -f1 | paste -sd' ' -)"
  local rc=0
  run_long "RMAN duplicate" "$rlog" 'Starting|Finished|ORA-|RMAN-|copy complete|output file name|restoring|backup set complete' oracle "$DB_HOME/bin/rman" < <(
    printf 'connect target sys/"%s"@%s\n' "$SYS_PW" "$PRIMARY_TNS"
    printf 'connect auxiliary sys/"%s"@%s\n' "$SYS_PW" "$STANDBY_TNS"
    cat "$rmanfile"
    printf 'exit\n') || rc=$?
  if grep -q 'Finished Duplicate Db' "$rlog" && ! grep -qE '^RMAN-0(3002|3009|3015)' "$rlog"; then
    dup_success_record
    DONE_MSG="The database was copied (RMAN: Finished Duplicate Db)"
    return 0
  fi
  bad "The copy did not finish (exit code $rc; $(ora_errors "$(cat "$rlog")"))"
  install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/dup_attempt"
  RESUME_STEP=7.2; DO_FAIL_STOP_ONLY=1
  {
    grep -m1 -E '^(RMAN|ORA)-[0-9]+' "$rlog" | sed 's/^/First error: /'
    printf 'Full output: %s\n' "$rlog"
    printf 'Common causes:\n'
    printf '  ORA-19504, ORA-17502   a disk group is missing or not mounted\n'
    printf '  ORA-01017              the password files differ (step 6.1)\n'
    printf '  ORA-12528, ORA-12514   listener or tnsnames.ora (phase 5)\n'
    printf '  ORA-15025, ORA-27041   the oracle binary cannot open the ASM disks (setasmgidwrap, step 8.1)\n'
    printf 'Before you try again, clean up this server: answer q, then run  %s --from 7.2\nStep 7.2 shows the clean-up commands.\n' "$SELF"
  } | hint
  return 1
}

dup_success_record() {
  # the duplicate finished: marker, the initial pfile out of the way, journal (also when the run was not watching)
  set_marker duplicate
  rm -f -- "$STATE_DIR/dup_attempt"
  local p; p=$(pfile_path)
  [[ -f "$p" ]] && runuser -u "$ORACLE_USER" -- mv -f -- "$p" "$p.pre_duplicate_$RUN_ID" && { say "The temporary pfile ${p##*/} was renamed. The instance now uses the spfile."; journal RENAME "$p" "to=$p.pre_duplicate_$RUN_ID"; }
  journal DUPLICATE_DONE "$STANDBY_UNIQUE" "Finished Duplicate Db; spfile $(spfile_path)"
  return 0
}

phase_8() {
  phase_header 8 "Copy the database (RMAN)"
  run_step 8.1 check "Pre-checks: space, storage, logins, parameters" c_8_1 d_8_1
  run_step 8.2 auto  "RMAN duplicate for standby" c_8_2 d_8_2
}

#------------------------------------------------------------------------------
# PHASE 9  Oracle Restart registration, standby redo logs, apply, shipping
#------------------------------------------------------------------------------
REG_MODE=""

need_built() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 1; }
  detect_built
  if [[ $STANDBY_BUILT -eq 1 && "$LSTATE" == "IDLE" && "${CUR_STEP%%.*}" == "10" ]]; then
    NOW="The standby instance is not running (step 9.2)."$'\n'"Start it as $ORACLE_USER:  $(use_grid && printf 'srvctl start database -db %s' "$STANDBY_UNIQUE" || printf 'startup mount')"$'\n'"Also check:  systemctl status $(unit_name 2>/dev/null)"
    return 1
  fi
  [[ $STANDBY_BUILT -eq 1 ]] && return 0
  if [[ $DETECT_RC -eq 2 ]]; then NOW="Cannot tell whether the standby is complete: $SC_INFO"; return 1; fi
  NOW="The standby database does not exist yet (phase 8)"; return 1
}
adg_note() {
  # an OPEN standby with apply running is Active Data Guard (a separate license)
  [[ "$1" == OPEN* ]] && warn "The standby is OPEN."$'\n'"An open standby with redo apply needs the Active Data Guard license."$'\n'"This script only mounts it."
  return 0
}

# ---- 9.1 ----
srv_dgs() { asm_dgs | paste -sd, -; }
c_9_1() {
  use_grid || { NOW="Not needed: no Oracle Restart on this server. Step 9.7 sets up the start at boot."; return 0; }
  need_built || return 2
  local srv="$DB_HOME/bin/srvctl" spf; spf=$(spfile_path)
  [[ -f "$spf" ]] || { NOW="The spfile is missing: $spf"; return 2; }
  local add="srvctl add database -db $STANDBY_UNIQUE -oraclehome $DB_HOME -spfile $spf -pwfile $(pw_dest) -role PHYSICAL_STANDBY -startoption MOUNT -dbname $DB_NAME -instance $STANDBY_SID -diskgroup $(srv_dgs)${PRIMARY_DOMAIN:+ -domain $PRIMARY_DOMAIN}"
  if run_logged "srvctl config database" as_oracle "$srv" config database -db "$STANDBY_UNIQUE"; then
    local cfg=$RUN_OUT bad_items=""
    grep -qiE "^spfile:[[:space:]]*${spf}[[:space:]]*\$" <<< "$cfg" || bad_items+=" spfile"
    grep -qiE "^Database role:[[:space:]]*PHYSICAL_STANDBY" <<< "$cfg" || bad_items+=" role"
    grep -qiE "^(Database instance|Instance)( name)?:[[:space:]]*${STANDBY_SID}[[:space:]]*\$" <<< "$cfg" || bad_items+=" instance"
    if [[ -z "$bad_items" ]]; then NOW="Registered in Oracle Restart: role PHYSICAL_STANDBY, instance $STANDBY_SID"$'\n'"spfile: $spf"; return 0; fi
    NOW="Registered, but these values are wrong:$bad_items"$'\n'"$(grep -iE '^(spfile|database role|database instance|instance)' <<< "$cfg")"
    REG_MODE=re
    PLAN="As $ORACLE_USER, on this server only:
srvctl stop database -db $STANDBY_UNIQUE
srvctl remove database -db $STANDBY_UNIQUE -noprompt
$add"
    return 1
  fi
  REG_MODE=add
  NOW="$STANDBY_UNIQUE is not registered in Oracle Restart"
  PLAN="As $ORACLE_USER:
$add"
  USING="-instance must be exactly $STANDBY_SID, or sqlplus shows 'Connected to an idle instance'"
  return 1
}
srv_add() {
  run_logged "srvctl add database" as_oracle "$DB_HOME/bin/srvctl" add database -db "$STANDBY_UNIQUE" \
    -oraclehome "$DB_HOME" -spfile "$(spfile_path)" -pwfile "$(pw_dest)" \
    -role PHYSICAL_STANDBY -startoption MOUNT -dbname "$DB_NAME" -instance "$STANDBY_SID" \
    -diskgroup "$(srv_dgs)" ${PRIMARY_DOMAIN:+-domain "$PRIMARY_DOMAIN"} || { bad "srvctl add failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
}
d_9_1() {
  if [[ "$REG_MODE" == "re" ]]; then
    run_logged "srvctl config (before the new registration)" as_oracle "$DB_HOME/bin/srvctl" config database -db "$STANDBY_UNIQUE" || true
    journal SRVCTL_OLD "$STANDBY_UNIQUE" "the old registration was replaced (its config is in $LOG_FILE)"
    run_logged "srvctl stop" as_oracle "$DB_HOME/bin/srvctl" stop database -db "$STANDBY_UNIQUE" || true
    run_logged "srvctl remove" as_oracle "$DB_HOME/bin/srvctl" remove database -db "$STANDBY_UNIQUE" -noprompt || { bad "srvctl remove failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  fi
  srv_add || return 1
  journal SRVCTL "$STANDBY_UNIQUE" "registered in Oracle Restart (role PHYSICAL_STANDBY, start option MOUNT)"
}

# ---- 9.2 ----
c_9_2() {
  need_built || return 2
  if ! use_grid; then
    # no Oracle Restart: the instance only has to be mounted as a standby
    local_state
    case "$LSTATE" in
      MOUNTED|OPEN) adg_note "$LSTATE"; NOW="Instance $STANDBY_SID is $LSTATE (no Oracle Restart on this server)"; return 0 ;;
      IDLE) NOW="The standby instance is not running"; PLAN="As $ORACLE_USER:  sqlplus / as sysdba  ->  startup mount"; return 1 ;;
      STARTED) NOW="The instance is in NOMOUNT (started with the first pfile)"; PLAN="As $ORACLE_USER, on this server (standby instance $STANDBY_SID only):"$'\n'"  sqlplus / as sysdba  ->  shutdown immediate ; startup mount"$'\n'"The new start uses the spfile"; return 1 ;;
      *) NOW="Instance state: $LSTATE ($(ora_errors "$SQL_OUT"))"; return 2 ;;
    esac
  fi
  run_logged "srvctl status" as_oracle timeout 120 "$DB_HOME/bin/srvctl" status database -db "$STANDBY_UNIQUE" || true
  local srv_on=0
  grep -qi 'is running' <<< "$RUN_OUT" && ! grep -qi 'is not running' <<< "$RUN_OUT" && srv_on=1
  if sql_local "select i.instance_name||'|'||i.status||'|'||d.database_role from v\$instance i, v\$database d;"; then
    local iname ist irole; IFS='|' read -r iname ist irole <<< "$(first_line)"
    if [[ $srv_on -eq 1 && "$iname" == "$STANDBY_SID" && "$irole" == "PHYSICAL STANDBY" && ( "$ist" == "MOUNTED" || "$ist" == "OPEN" ) ]]; then
      adg_note "$ist"; NOW="Running under Oracle Restart: instance $iname, $ist, $irole"; return 0
    fi
    if [[ $srv_on -eq 0 ]]; then
      NOW="Instance $iname is $ist, but it was started by RMAN, not by Oracle Restart"
      PLAN="As $ORACLE_USER, on this server (standby instance $STANDBY_SID only):
sqlplus / as sysdba  ->  shutdown immediate
srvctl start database -db $STANDBY_UNIQUE"
      return 1
    fi
    NOW="Unexpected state: instance $iname, status $ist, role $irole"; return 2
  fi
  if [[ $srv_on -eq 1 ]] && grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    NOW="srvctl says the database is running, but ORACLE_SID=$STANDBY_SID is idle."$'\n'"The registration uses another instance name (step 9.1)"
    return 2
  fi
  NOW="The standby instance is not running"
  PLAN="As $ORACLE_USER:  srvctl start database -db $STANDBY_UNIQUE"
  return 1
}
d_9_2() {
  if ! use_grid; then
    [[ "$LSTATE" == "STARTED" ]] && { sql_local_long "shutdown immediate" || true; }
    sql_local_long "startup mount" || { bad "Startup mount failed ($(ora_errors "$SQL_OUT"))"; return 1; }
    journal INSTANCE "$STANDBY_SID" "startup mount (standby)"; return 0
  fi
  local_state
  if [[ "$LSTATE" != "IDLE" && "$LSTATE" != "NOSW" ]]; then
    say "Stopping the instance that RMAN started on this server"
    sql_local_long "shutdown immediate" || true
  fi
  run_logged "srvctl start" as_oracle timeout 1800 "$DB_HOME/bin/srvctl" start database -db "$STANDBY_UNIQUE" || { bad "srvctl start failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  journal INSTANCE "$STANDBY_SID" "srvctl start database (MOUNT)"
}

# ---- 9.3 ----
SRL_SQL=""
c_9_3() {
  need_built || return 2
  local rc=0; srl_statements sql_local || rc=$?
  [[ $rc -eq 2 ]] && { NOW="Cannot read the redo logs of the standby ($(ora_errors "$SQL_OUT"))"; return 2; }
  NOW=$SRL_INFO
  [[ $rc -eq 0 ]] && return 0
  SRL_SQL="alter system set standby_file_management=manual scope=memory;"$'\n'"$SRL_STMTS"$'\n'"alter system set standby_file_management=auto scope=memory;"
  PLAN="On this server, in sqlplus / as sysdba (apply is stopped first if it runs):
$SRL_SQL"
  USING="Same size as the online logs of the primary"$'\n'"Per thread: one group more than the online groups"
  return 1
}
d_9_3() {
  local before after new
  # without the list of groups before, the new groups could not be told apart (the undo would drop them all)
  sql_local "select group# from v\$standby_log order by group#;" || { bad "Cannot read the standby logs ($(ora_errors "$SQL_OUT"))"; return 1; }
  before=$(tr -d ' ' <<< "$SQL_OUT")
  if mrp_running; then sql_local "alter database recover managed standby database cancel;" || { bad "Cannot stop apply"; return 1; }; fi
  if ! sql_local "$SRL_SQL"; then
    local eo=$SQL_OUT
    sql_local "alter system set standby_file_management=auto scope=memory;" || true
    # groups that were added before the error are recorded too (they are undone with the step)
    sql_local "select group# from v\$standby_log order by group#;" && after=$(tr -d ' ' <<< "$SQL_OUT") || after=""
    new=$(comm -13 <(sort <<< "$before") <(sort <<< "$after") | sort -n | paste -sd' ' -)
    [[ -n "$new" ]] && journal SRL "$STANDBY_SID" "$new"
    SQL_OUT=$eo
    bad "Cannot add the standby redo logs ($(ora_errors "$SQL_OUT"))"
    grep -q 'ORA-01378' <<< "$SQL_OUT" && printf 'ORA-01378: the online logs of the primary use 4K blocks.\nThe disk group or file system here must have a 4K sector size.\n' | hint
    return 1
  fi
  sql_local "select group# from v\$standby_log order by group#;" && after=$(tr -d ' ' <<< "$SQL_OUT") || after=""
  new=$(comm -13 <(sort <<< "$before") <(sort <<< "$after") | sort -n | paste -sd' ' -)
  [[ -n "$new" ]] && journal SRL "$STANDBY_SID" "$new"
  return 0
}

# ---- 9.8 archived logs on the standby ----
arch_in_fra() { [[ "${ARCH_LOC^^}" == "USE_DB_RECOVERY_FILE_DEST" ]]; }
arch_timer() { printf 'dg-arch-cleanup-%s.timer' "${STANDBY_SID,,}"; }
arch_service() { printf 'dg-arch-cleanup-%s.service' "${STANDBY_SID,,}"; }
arch_script() { printf '/usr/local/sbin/dg_arch_cleanup_%s.sh' "${STANDBY_SID,,}"; }
arch_script_text() {
  printf '#!/bin/bash\n# Written by dg_standby_setup.sh: deletes archived logs of the standby that are older than one day.\n'
  printf '# The deletion policy (applied on standby) makes RMAN keep every log that is not applied yet.\n'
  printf 'runuser -u %s -- env -i HOME=/tmp LANG=C ORACLE_HOME=%s ORACLE_SID=%s %s/bin/rman target / <<EOF\n' "$ORACLE_USER" "$DB_HOME" "$STANDBY_SID" "$DB_HOME"
  printf "delete noprompt archivelog all completed before 'sysdate-1';\nexit\nEOF\n"
}
arch_service_text() {
  printf '[Unit]\nDescription=Delete applied archived logs of the standby %s (dg_standby_setup.sh)\n\n' "$STANDBY_UNIQUE"
  printf '[Service]\nType=oneshot\nExecStart=%s\n' "$(arch_script)"
}
arch_timer_text() {
  printf '[Unit]\nDescription=Daily clean-up of applied archived logs of %s\n\n[Timer]\nOnCalendar=*-*-* 04:30:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' "$STANDBY_UNIQUE"
}
arch_timer_ok() {
  local t="/etc/systemd/system/$(arch_timer)" sv="/etc/systemd/system/$(arch_service)"
  [[ -f "$t" && "$(cat "$t")" == "$(arch_timer_text)" && -f "$sv" && "$(cat "$sv")" == "$(arch_service_text)" && -f "$(arch_script)" && "$(cat "$(arch_script)")" == "$(arch_script_text)" ]] \
    && systemctl is-enabled --quiet "$(arch_timer)" 2>/dev/null
}
ARCH_POLICY_OK=0
c_9_8() {
  need_built || return 2
  local_state
  [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { NOW="The standby is not mounted (step 9.2)"; return 2; }
  sql_local "select nvl(max(value),'-') from v\$rman_configuration where name='ARCHIVELOG DELETION POLICY';" || { NOW="Cannot read the RMAN configuration ($(ora_errors "$SQL_OUT"))"; return 2; }
  local v; v=$(first_line)
  # only "applied on (all) standby" deletes on a standby; a policy copied from the primary with "backed up n times"
  # never deletes here (nothing is backed up on the standby)
  ARCH_POLICY_OK=0; [[ "$(tr -s ' ' <<< "${v^^}")" =~ ^TO\ APPLIED\ ON\ (ALL\ )?STANDBY$ ]] && ARCH_POLICY_OK=1
  local tok=1; arch_in_fra || arch_timer_ok || tok=0
  if [[ $ARCH_POLICY_OK -eq 1 && $tok -eq 1 ]]; then
    NOW="RMAN archivelog deletion policy: $v"
    arch_in_fra && NOW+=$'\n'"The recovery area deletes applied logs when it needs space." || NOW+=$'\n'"$(arch_timer) deletes applied logs older than one day in $ARCH_LOC every night"
    return 0
  fi
  NOW=""
  [[ $ARCH_POLICY_OK -eq 1 ]] || NOW="RMAN archivelog deletion policy of the standby: ${v/#-/not set}$([[ "$v" != "-" ]] && printf ', copied from the primary with the control file')."$'\n'"Without the right policy, applied logs are not deleted here."$'\n'"The disk fills up and redo transport stops (ORA-19809, ORA-00257)."
  [[ $tok -eq 1 ]] || NOW+="${NOW:+$'\n'}The archive destination $ARCH_LOC is not the recovery area. Oracle deletes nothing there by itself."
  PLAN=""
  [[ $ARCH_POLICY_OK -eq 1 ]] || PLAN="As $ORACLE_USER on this server:"$'\n'"  rman target /  ->  CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;"
  [[ $tok -eq 1 ]] || PLAN+="${PLAN:+$'\n'}Add a daily systemd timer $(arch_timer) at 04:30."$'\n'"It runs $(arch_script) as $ORACLE_USER:"$'\n'"  rman target /  ->  delete noprompt archivelog all completed before 'sysdate-1';"$'\n'"Logs that are not applied yet are kept."
  USING="Nothing is changed on the primary. Its own policy belongs to its backups.
To see it there:  rman target /  ->  show archivelog deletion policy;
If RMAN backs up the primary, this policy there keeps logs until the standby has them:
  TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DEVICE TYPE <DISK or SBT>
NEVER set it on a primary that RMAN does not back up: its logs would never be deleted."
  return 1
}
d_9_8() {
  if [[ $ARCH_POLICY_OK -eq 0 ]]; then
    local t lrc=0; t=$(mktemp /tmp/dg_rman.XXXXXX) || return 1; CLEANUP_FILES+=("$t"); chmod 644 "$t"
    local old="-"
    sql_local "select nvl(max(value),'-') from v\$rman_configuration where name='ARCHIVELOG DELETION POLICY';" && old=$(first_line)
    printf 'CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;\nexit\n' | as_oracle timeout 300 "$DB_HOME/bin/rman" target / > "$t" 2>&1 || lrc=1
    RUN_OUT=$(cat "$t"); rm -f -- "$t"
    printf '%s\n(exit code %s)\n' "$RUN_OUT" "$lrc" | log_block "rman configure"
    [[ $lrc -eq 0 ]] || { bad "RMAN failed ($(ora_errors "$RUN_OUT"))"; return 1; }
    journal RMANCFG "$STANDBY_SID" "old=${old// /~}"
  fi
  if ! arch_in_fra && ! arch_timer_ok; then
    install -d -m 755 /usr/local/sbin || return 1
    local f
    for f in "$(arch_script)" "/etc/systemd/system/$(arch_service)" "/etc/systemd/system/$(arch_timer)"; do
      [[ -f "$f" ]] && { backup_file "$f" || return 1; }
    done
    arch_script_text | write_as root "$(arch_script)" 755 || return 1
    arch_service_text | write_as root "/etc/systemd/system/$(arch_service)" 644 || return 1
    arch_timer_text | write_as root "/etc/systemd/system/$(arch_timer)" 644 || return 1
    command -v restorecon >/dev/null 2>&1 && restorecon "$(arch_script)" "/etc/systemd/system/$(arch_service)" "/etc/systemd/system/$(arch_timer)" 2>/dev/null
    run_cmds <<< "systemctl daemon-reload
systemctl enable $(arch_timer)
systemctl start $(arch_timer)" || return 1
    journal UNIT "$(arch_timer)" "daily clean-up of applied archived logs"
  fi
  return 0
}

# ---- 9.4 ----
c_9_4() {
  need_built || return 2
  if mrp_running; then
    NOW="Redo apply (MRP) is running"
    # real-time apply needs standby redo logs that the standby can use; without them redo is applied from archived logs only
    if sql_local "select nvl(max(recovery_mode),'-') from v\$archive_dest_status where recovery_mode like 'MANAGED%';" && [[ "$(first_line)" != "-" && "$(first_line)" != *"REAL TIME"* ]]; then
      warn "Redo is applied from archived logs only, not in real time (recovery_mode = $(first_line))."$'\n'"Usually the standby redo logs cannot be used. Check step 9.3, and look in the alert log for:"$'\n'"ORA-19527, ORA-15046, ORA-15173, 'No standby redo logfiles'."
    fi
    return 0
  fi
  NOW="Redo apply (MRP) is not running"
  PLAN="On this server:  alter database recover managed standby database disconnect from session;"
  return 1
}
d_9_4() {
  if ! sql_local "alter database recover managed standby database disconnect from session;"; then
    bad "Cannot start redo apply ($(ora_errors "$SQL_OUT"))"
    grep -q 'ORA-01153' <<< "$SQL_OUT" && printf 'ORA-01153: another recovery session is active (an old MRP or a manual recover). Cancel it first:\n  alter database recover managed standby database cancel;\n' | hint
    grep -q 'ORA-01154' <<< "$SQL_OUT" && printf 'ORA-01154: the database is OPEN or opening. This script only mounts a physical standby.\n' | hint
    return 1
  fi
  journal MRP "$STANDBY_SID" "redo apply started"
  local n=0; until mrp_running || [[ $n -ge 6 ]]; do sleep 5; n=$((n + 1)); done
}

# ---- 9.5 ----
c_9_5() {
  need_built || return 2
  need_ssh || return 2
  find_dest || { NOW="Cannot read the log_archive_dest parameters on the primary"; return 2; }
  local d=$DEST_N
  p_param "log_archive_dest_$d" || { NOW="Query failed"; return 2; }
  if ! has_token "$PVAL" "SERVICE=${STANDBY_TNS^^}"; then
    NOW="log_archive_dest_$d on the primary does not point to this standby: $PVAL"
    PLAN="alter system set log_archive_dest_$d='service=$STANDBY_TNS async valid_for=(online_logfiles,primary_role) db_unique_name=$STANDBY_UNIQUE' scope=both;
alter system set log_archive_dest_state_$d=enable scope=both;
alter system switch logfile;"
    PLAN_UNDO="alter system set log_archive_dest_state_$d=defer scope=both;   (stops redo transport to this standby)"
    return 1
  fi
  prim_sql "select upper(value) from v\$parameter where name='log_archive_dest_state_$d';" || { NOW="Query failed"; return 2; }
  local st; st=$(first_line)
  # ORA- inside the error column would look like a failed query, so it is masked in SQL and restored here
  prim_sql "select status||'|'||nvl(replace(error,'ORA-','ORA_'),'-') from v\$archive_dest where dest_id=$d;" || { NOW="Query failed"; return 2; }
  local s e; IFS='|' read -r s e <<< "$(first_line)"; e=${e//ORA_/ORA-}
  if [[ "$st" == "ENABLE" && "$s" == "VALID" && "$e" == "-" ]]; then NOW="On the primary, dest_$d is ENABLE and VALID, with no error"; return 0; fi
  NOW="On the primary: log_archive_dest_state_$d=$st, dest_$d status $s, $([[ "$e" == "-" ]] && printf 'no error' || printf 'error %s' "$e")"
  PLAN="alter system set log_archive_dest_state_$d=enable scope=both;
alter system switch logfile;"
  PLAN_UNDO="alter system set log_archive_dest_state_$d=defer scope=both;   (stops redo transport to this standby)"
  if [[ "$e" != "-" ]]; then
    case "$e" in
      *16191*|*1017*) PLAN+=$'\n'"-- Cause: the password files differ (step 6.1)" ;;
      *12154*) PLAN+=$'\n'"-- Cause: alias $STANDBY_TNS is missing in tnsnames.ora on the primary (step 4.9)" ;;
      *12514*|*12541*) PLAN+=$'\n'"-- Cause: the listener of the standby (phase 5)" ;;
    esac
  fi
  return 1
}

# ---- 9.6 ----
c_9_6() {
  need_built || return 2
  find_dest >/dev/null 2>&1 || true
  local n=0
  while true; do
    rfs_running && { NOW="RFS is receiving redo from the primary"; return 0; }
    n=$((n + 1)); [[ $n -ge 6 || "$MODE" == "check" ]] && break
    say "Waiting for RFS ($n of 6)"; sleep 10
  done
  NOW="No RFS process on this server yet"
  PLAN="Check step 9.5, then the alert logs:
  standby: ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${STANDBY_UNIQUE,,}/$STANDBY_SID/trace/alert_$STANDBY_SID.log
  primary: ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${PRIMARY_UNIQUE,,}/$PRIMARY_SID/trace/alert_$PRIMARY_SID.log
In the alert log of the primary, look for ORA- errors near LOG_ARCHIVE_DEST_${DEST_N:-2}"
  return 1
}

# ---- 9.7 start at boot ----
#   No Grid: a systemd unit starts the listener, mounts the standby and starts apply (and stops them at shutdown).
#   Grid: Oracle Restart mounts the standby, but nothing starts apply (MRP) again; a unit after
#   oracle-ohasd waits until the standby is mounted and starts it. A standby is never opened.
unit_name() { if use_grid; then printf 'oracle-standby-apply-%s.service' "${STANDBY_SID,,}"; else printf 'oracle-standby-%s.service' "${STANDBY_SID,,}"; fi; }
start_script() { printf '/usr/local/sbin/dg_standby_%s.sh' "${STANDBY_SID,,}"; }
script_text() {
  printf '#!/bin/bash\n'
  printf '# Written by dg_standby_setup.sh: start/stop %s as a MOUNTED physical standby (never opened)\n' "$STANDBY_UNIQUE"
  printf 'export ORACLE_HOME=%s ORACLE_BASE=%s ORACLE_SID=%s\n' "$DB_HOME" "$ORACLE_BASE" "$STANDBY_SID"
  printf 'export PATH=$ORACLE_HOME/bin:/usr/bin:/bin\n'
  printf 'sql() { printf '"'"'set heading off feedback off pagesize 0\\n%%s\\nexit\\n'"'"' "$1" | $ORACLE_HOME/bin/sqlplus -S / as sysdba; }\n'
  printf 'case "${1:-start}" in\n  start)\n'
  if use_grid; then
    printf '    # Oracle Restart mounts the database; wait for it (at most 30 minutes), then start apply\n'
    printf '    for i in $(seq 1 180); do\n'
    printf '      st=$(sql "select status from v\\$instance;" 2>/dev/null | tr -d '"'"'[:space:]'"'"')\n'
    printf '      case "$st" in MOUNTED|OPEN*) break ;; esac\n      sleep 10\n    done\n'
    printf '    case "$st" in MOUNTED|OPEN*) ;; *) echo "standby is not mounted ($st)"; exit 1 ;; esac\n'
  else
    printf '    $ORACLE_HOME/bin/lsnrctl start %s\n' "$SB_LSNR"
    printf '    sql "startup mount"\n'
  fi
  printf '    sql "alter database recover managed standby database disconnect from session;"\n    ;;\n  stop)\n'
  if use_grid; then printf '    sql "alter database recover managed standby database cancel;"\n'
  else printf '    sql "shutdown immediate"\n    $ORACLE_HOME/bin/lsnrctl stop %s\n' "$SB_LSNR"; fi
  printf '    ;;\nesac\nexit 0\n'
}
unit_text() {
  local after="network-online.target remote-fs.target" wants="network-online.target" what
  use_grid && { after+=" oracle-ohasd.service"; wants+=" oracle-ohasd.service"; }
  if use_grid; then what="start apply after Oracle Restart"; else what="listener, mount, apply"; fi
  printf '# Written by dg_standby_setup.sh\n[Unit]\nDescription=Oracle Data Guard standby %s (%s)\nAfter=%s\nWants=%s\n\n' "$STANDBY_UNIQUE" "$what" "$after" "$wants"
  # with Grid the unit only waits for Oracle Restart: Type=simple, so the boot does not wait for it
  printf '[Service]\nType=%s\nRemainAfterExit=yes\nUser=%s\nExecStart=%s start\nExecStop=%s stop\n' "$(use_grid && printf simple || printf oneshot)" "$ORACLE_USER" "$(start_script)" "$(start_script)"
  printf 'TimeoutStartSec=2000\nTimeoutStopSec=900\nLimitNOFILE=65536\nLimitNPROC=16384\nLimitSTACK=33554432\nLimitMEMLOCK=infinity\nLimitCORE=infinity\n\n'
  printf '[Install]\nWantedBy=multi-user.target\n'
}
udev_dropin() { printf '/etc/systemd/system/oracle-ohasd.service.d/10-dg-wait-asm-disks.conf'; }
need_udev_dropin() { use_grid && [[ -f /etc/systemd/system/oracle-ohasd.service || -f /usr/lib/systemd/system/oracle-ohasd.service ]]; }
dropin_text() {
  # Oracle Restart must start after the ASM disks are there (udev rules, or the ASMLib scan)
  if [[ "$(asm_method)" == "asmlib" ]]; then printf '[Unit]\nAfter=oracleasm.service\nWants=oracleasm.service\n'
  else printf '[Unit]\nAfter=systemd-udev-settle.service\nWants=systemd-udev-settle.service\n'; fi
}
c_9_7() {
  command -v systemctl >/dev/null 2>&1 || { NOW="systemd is not found. Start the standby by hand after each reboot."; return 2; }
  need_built || return 2
  local u sc okd=1; u="/etc/systemd/system/$(unit_name)"; sc=$(start_script)
  need_udev_dropin && [[ "$(cat "$(udev_dropin)" 2>/dev/null)" != "$(dropin_text)" ]] && okd=0
  if [[ -f "$u" && "$(cat "$u")" == "$(unit_text)" && -f "$sc" && "$(cat "$sc")" == "$(script_text)" && $okd -eq 1 ]] && systemctl is-enabled --quiet "$(unit_name)" 2>/dev/null && ! systemctl is-failed --quiet "$(unit_name)" 2>/dev/null; then
    if use_grid; then NOW="$(unit_name) is enabled."$'\n'"It starts apply after Oracle Restart mounts the standby."
    else NOW="$(unit_name) is enabled."$'\n'"At boot: listener, startup mount, apply. At shutdown: a clean stop."; fi
    return 0
  fi
  if systemctl is-failed --quiet "$(unit_name)" 2>/dev/null; then
    NOW="$(unit_name) has failed: $(systemctl status "$(unit_name)" --no-pager -l 2>&1 | grep -E 'Active:|ORA-|TNS-|error' | head -n 3 | tr '\n' ' ')"
  elif use_grid; then NOW="After a reboot, Oracle Restart mounts the standby, but nothing starts redo apply (MRP)"
  else NOW="Nothing starts the listener and the standby after a reboot (no Oracle Restart here)"; fi
  if use_grid; then PLAN="Create this script, owned by root. It runs as $ORACLE_USER, waits for MOUNT and starts apply:"$'\n'"  $sc"
  else PLAN="Create this script, owned by root. It runs as $ORACLE_USER:"$'\n'"  $sc"$'\n'"  at boot: lsnrctl start, startup mount, start apply"$'\n'"  at shutdown: shutdown immediate"; fi
  PLAN+=$'\n'"Create and enable this systemd unit:"$'\n'"  $u"$'\n'"It sets the Oracle limits (nofile, nproc, stack, memlock)."
  need_udev_dropin && PLAN+=$'\n'"Create this drop-in, so Oracle Restart starts after the ASM disks are ready:"$'\n'"  $(udev_dropin)"
  PLAN+=$'\n'"Start the unit once now, so the next shutdown stops the standby cleanly."$'\n'"This does not change the running standby."
  USING="The standby is only mounted."$'\n'"Opening it read-only while apply runs needs the Active Data Guard license."
  return 1
}
d_9_7() {
  local sc u; sc=$(start_script); u="/etc/systemd/system/$(unit_name)"
  install -d -m 755 /usr/local/sbin || return 1
  # earlier contents are kept (the undo puts them back)
  [[ -f "$sc" && "$(cat "$sc")" != "$(script_text)" ]] && { backup_file "$sc" || return 1; }
  [[ -f "$u" && "$(cat "$u")" != "$(unit_text)" ]] && { backup_file "$u" || return 1; }
  [[ -f "$sc" && "$(cat "$sc")" == "$(script_text)" ]] || { script_text | write_as root "$sc" 755 || return 1; }
  [[ -f "$u" && "$(cat "$u")" == "$(unit_text)" ]] || { unit_text | write_as root "$u" 644 || return 1; }
  script_text | log_block "written $sc"
  unit_text | log_block "written $u"
  command -v restorecon >/dev/null 2>&1 && restorecon "$sc" "$u" 2>/dev/null
  if need_udev_dropin; then
    install -d -m 755 "$(dirname "$(udev_dropin)")" || return 1
    [[ -f "$(udev_dropin)" && "$(cat "$(udev_dropin)")" != "$(dropin_text)" ]] && { backup_file "$(udev_dropin)" || return 1; }
    [[ -f "$(udev_dropin)" && "$(cat "$(udev_dropin)")" == "$(dropin_text)" ]] || { dropin_text | write_as root "$(udev_dropin)" 644 || return 1; }
  fi
  run_cmds <<< "systemctl daemon-reload
systemctl enable $(unit_name)" || return 1
  journal UNIT "$(unit_name)" "enabled (start at boot)"
  run_cmds <<< "systemctl start $(unit_name)" || { bad "The unit did not start. Check:  systemctl status $(unit_name)"; systemctl status "$(unit_name)" --no-pager -l 2>&1 | tail -n 8 | hint; return 1; }
}

phase_9() {
  phase_header 9 "Start redo apply and transport"
  run_step 9.1 auto    "Registration in Oracle Restart (srvctl)" c_9_1 d_9_1
  run_step 9.2 auto    "Standby instance running (MOUNT)" c_9_2 d_9_2
  run_step 9.3 auto    "Standby redo logs on this server" c_9_3 d_9_3
  run_step 9.4 auto    "Redo apply (MRP)" c_9_4 d_9_4
  run_step 9.5 primary "Redo transport from the primary" c_9_5
  run_step 9.6 check   "Redo arrives on this server (RFS)" c_9_6
  run_step 9.7 auto    "Start at boot (mount and apply)" c_9_7 d_9_7
  run_step 9.8 auto    "Clean-up of archived logs on the standby" c_9_8 d_9_8
}

#------------------------------------------------------------------------------
# PHASE 10  Verify synchronization
#------------------------------------------------------------------------------
lag_seconds() {
  local v=$1
  if [[ "$v" =~ ^\+?([0-9]+)[[:space:]]+([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
    printf '%s' $(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]} ))
  else printf '%s' -1; fi
}
c_10_1() {
  need_built || return 2
  local tries=0 tl al tls als
  while true; do
    sql_local "select nvl(max(decode(name,'transport lag',value)),'-')||'|'||nvl(max(decode(name,'apply lag',value)),'-') from v\$dataguard_stats;" || { NOW="Cannot read v\$dataguard_stats"; return 2; }
    IFS='|' read -r tl al <<< "$(first_line)"
    tls=$(lag_seconds "$tl"); als=$(lag_seconds "$al")
    if [[ $tls -ge 0 && $tls -le 60 && $als -ge 0 && $als -le 60 ]]; then NOW="Transport lag $tl, apply lag $al"; return 0; fi
    tries=$((tries + 1)); [[ $tries -ge 12 || "$MODE" == "check" ]] && break
    say "Transport lag $tl, apply lag $al. Waiting 10 seconds ($tries of 12)"; sleep 10
  done
  NOW="The lag is too high or not known yet: transport '$tl', apply '$al'"
  PLAN="Empty values are normal for a few minutes after the setup.
To force a log switch, on the primary as $ORACLE_USER in sqlplus / as sysdba:
  alter system switch logfile;
Then answer r."
  return 1
}
c_10_2() {
  need_built || return 2
  sql_local "select count(*) from v\$archive_gap;" || { NOW="Cannot read v\$archive_gap"; return 2; }
  num "$(first_line)" || { NOW="Unexpected answer: $(first_line)"; return 2; }
  [[ "$(first_line)" -eq 0 ]] && { NOW="No archive gap"; return 0; }
  sql_local "select thread#||' '||low_sequence#||'-'||high_sequence# from v\$archive_gap;" || true
  NOW="Archive gap: $SQL_OUT"
  PLAN="fal_server usually fetches the missing logs within minutes. If the gap stays, check:
  grep -iE 'FAL|gap|ORA-' ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${STANDBY_UNIQUE,,}/$STANDBY_SID/trace/alert_$STANDBY_SID.log | tail -30"
  return 1
}
c_10_3() {
  need_built || return 2
  need_ssh || return 2
  prim_sql "select nvl(max(sequence#),0) from v\$archived_log where standby_dest='NO' and thread#=1 and resetlogs_change#=(select resetlogs_change# from v\$database);" || { NOW="Cannot read the primary"; return 2; }
  local pmax smax; pmax=$(first_line)
  sql_local "select nvl(max(sequence#),0) from v\$archived_log where applied in ('YES','IN-MEMORY') and thread#=1 and resetlogs_change#=(select resetlogs_change# from v\$database);" || { NOW="Cannot read the standby"; return 2; }
  smax=$(first_line)
  num "$pmax" && num "$smax" || { NOW="Unexpected answer (primary '$pmax', standby '$smax')"; return 2; }
  if [[ "$smax" -ge $((pmax - 1)) ]]; then NOW="Last log archived on the primary: $pmax. Applied on the standby: $smax"; return 0; fi
  NOW="Last log archived on the primary: $pmax. Applied on the standby: only $smax"
  PLAN="Wait a few minutes for apply to catch up, then answer r."
  return 1
}
c_10_4() {
  need_built || return 2
  if mrp_running; then
    NOW="Redo apply (MRP) is running"
    # real-time apply uses a standby log that receives the redo; errors of the last day are shown
    if sql_local "select count(*) from v\$standby_log where status='ACTIVE';" && [[ "$(first_line)" == "0" ]]; then
      warn "No standby redo log is in use (none is ACTIVE)."$'\n'"Redo arrives only as archived logs, so the lag grows by whole log files."$'\n'"Check step 9.3 and the alert log (ORA-19527, ORA-15046)."
    fi
    if sql_local "select count(*) from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > sysdate-1;" && num "$(first_line)" && [[ "$(first_line)" != "0" ]]; then
      warn "$(first_line) Data Guard error message(s) on this standby in the last 24 hours. To see them:"$'\n'"select timestamp, message from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp;"
    fi
    return 0
  fi
  NOW="Redo apply (MRP) is not running"; PLAN="Start it (step 9.4), on this server:"$'\n'"  alter database recover managed standby database disconnect from session;"; return 1
}

phase_10() {
  phase_header 10 "Health check"
  run_step 10.1 check "Transport and apply lag" c_10_1
  run_step 10.2 check "No archive gap" c_10_2
  run_step 10.3 check "Last log: primary and standby" c_10_3
  run_step 10.4 check "Redo apply is running" c_10_4
}

#------------------------------------------------------------------------------
# Help: manual commands for every step  (h at any question, or --help-step X.Y)
# Line format read by show_help: 6-character key (TITLE/WHERE/WHY/RUN/EXPECT/IF), one space,
# text; continuation lines start with 7 spaces.
#------------------------------------------------------------------------------
readonly HELP_IDS=(1.1 1.2 1.3 1.4 1.5 1.6
  2.1 2.2 2.3 2.4 2.5 2.6 2.7 2.8 2.9 2.10 2.11 2.12 2.13 2.14 2.15
  3.1 3.2 3.3 3.4 3.5 3.6 3.7 3.8 3.9 3.10 3.11
  4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9 4.10 4.11
  5.1 5.2 5.3 5.4 6.1 6.2 6.3 7.1 7.2 7.3 7.4 7.5 7.6 7.7 8.1 8.2
  9.1 9.2 9.3 9.4 9.5 9.6 9.7 9.8 10.1 10.2 10.3 10.4)

help_text() {
  local P=${PRIMARY_HOST:-<primary>} S=${STANDBY_HOST:-<standby>} SID=${STANDBY_SID:-<standby SID>}
  local PU=${PRIMARY_UNIQUE:-<primary unique>} SU=${STANDBY_UNIQUE:-<standby unique>}
  local PT=${PRIMARY_TNS:-<primary alias>} ST=${STANDBY_TNS:-<standby alias>}
  local DBH=${DB_HOME:-<db home>} GH=${GRID_HOME:-<grid home>} OU=${ORACLE_USER:-oracle} GU=${GRID_USER:-grid}
  local IG=${INSTALL_GROUP:-oinstall} LN=${LISTENER_NAME:-LISTENER} PO=${PORT:-1521} SL=$SB_LSNR
  local DD=${DATA_DG:-DATA} PS=${PRIMARY_SID:-<primary SID>}
  local PSV=${PRIMARY_SERVICE:-<primary service>} SSV=${STANDBY_SERVICE:-<standby service>}
  local OB=${ORACLE_BASE:-<oracle base>} GB=${GRID_BASE:-<grid base>} INV=${INVENTORY_DIR:-<inventory>}
  local PTA=${PRIMARY_TNS_ADMIN:-\$ORACLE_HOME/network/admin} PLH=${PRIMARY_LISTENER_HOME:-<listener home on primary>}
  local G=0 SO=0; [[ "${USE_GRID:-}" == "yes" ]] && G=1; [[ "$OU" == "$GU" ]] && SO=1
  local LH LU; if [[ $G -eq 1 ]]; then LH=$GH; LU=$GU; else LH=$DBH; LU=$OU; fi
  local AG; AG=$( [[ -n "${GRID_PGROUP:-}" ]] && grp_or asmadmin "$GRID_PGROUP" 2>/dev/null || printf 'asmadmin')
  local DGS; DGS=$( [[ -n "${LOCS:-}" ]] && asm_dgs 2>/dev/null | paste -sd' ' - ); DGS=${DGS:-DATA FRA}
  # SQL on the primary by hand: the exact home and SID, so the environment of the user there does not matter
  local PSQL="as $OU:  export ORACLE_HOME=$DBH ORACLE_SID=$PS ; \$ORACLE_HOME/bin/sqlplus / as sysdba"
  local SSQL="as $OU:  export ORACLE_HOME=$DBH ORACLE_SID=$SID ; \$ORACLE_HOME/bin/sqlplus / as sysdba"
  # 12.1 has no v$dataguard_process: the same information comes from v$managed_standby
  local DGP="v\$dataguard_process" DGN=name DGR=role DGS2=action
  [[ "${PRIMARY_VERSION:-}" == 12.1* ]] && { DGP="v\$managed_standby"; DGN=process; DGR=process; DGS2=status; }
  # TITLE lines match the step titles in run_step (step_title_of() reads them for steps that did not run)
  case "$1" in
  1.1) cat <<EOF
TITLE  Root and tools on this server
WHERE  This server ($S), as root
WHY    The script must run as root on the new standby server, never on the primary.
RUN    whoami
       hostname -s
EXPECT root, and the host name of this server (not the primary)
EOF
  ;;
  1.2) cat <<EOF
TITLE  Connect to the primary over ssh
WHERE  This server ($S), as root
WHY    The script opens one ssh connection and sends only read-only commands over it.
RUN    ssh ${PRIMARY_SSH_USER:-oracle}@${PRIMARY_IP:-<primary IP>} hostname
EXPECT The primary host name, after you type the password
IF     "Permission denied": wrong password, or PasswordAuthentication is "no"
       in /etc/ssh/sshd_config on the primary.
       "Connection refused" or "timed out": check sshd and the firewall (port 22)
       on the primary.
EOF
  ;;
  1.3) cat <<EOF
TITLE  Read the primary configuration (read-only)
WHERE  The primary ($P), as ${PRIMARY_SSH_USER:-oracle}
RUN    ps -eo pid,user,args | grep -E 'ora_pmon|tnslsnr'
       cat /etc/oratab ; cat /etc/oraInst.loc
       id $OU ; id $GU
       $DBH/bin/orabase
       $PSQL
       select name, db_unique_name, database_role, cdb from v\$database;
EXPECT database_role is PRIMARY
IF     The ssh user cannot run "sqlplus / as sysdba": add it to the dba group.
EOF
  ;;
  1.4) cat <<EOF
TITLE  Standby settings
WHERE  This server ($S), file ${SETTINGS_FILE:-/var/lib/dg_standby_setup/settings.conf}
WHY    Paths, users and groups are the same as on the primary.
       They are read from it at every run.
       You can change only the values under "This server (standby)": names, installer
       files, RU_DIR, OPATCH_ZIP, the ASM disk method and the RMAN channels.
RUN    Type a to accept, or e to edit (KEY=VALUE lines, no spaces).
       To change them later, run the script with --settings.
EXPECT STANDBY_UNIQUE differs from $PU.
       STANDBY_SID has at most 12 characters.
EOF
  ;;
  1.5) cat <<EOF
TITLE  sys password
WHERE  Asked on this server ($S); the manual test runs on the primary ($P)
WHY    RMAN and the login tests need it.
       It stays in memory only, never on disk or in the log.
RUN    To test it, on the primary ($P) as $OU:
       $DBH/bin/sqlplus sys@//localhost:$PO/$PSV as sysdba
EXPECT Connected.
IF     ORA-01017: wrong password, or SYS is missing from the password file (step 4.7).
EOF
  ;;
  1.6) cat <<EOF
TITLE  Oracle version supported on this Oracle Linux
WHERE  This server ($S)
WHY    Each Oracle release installs only on certain Oracle Linux versions.
RUN    cat /etc/os-release
       For 19c on OL9:
       1. Unzip the Release Update (with Grid: the GI Release Update) into a folder.
       2. Copy the newest OPatch zip (p6880880) to this server.
       3. In the settings (step 1.4, e), set RU_DIR=<folder> and OPATCH_ZIP=<zip>.
EXPECT A supported pair:
       12.1, 12.2, 18c   Oracle Linux 7 only
       19c               OL7, OL8 (the 19.3 installer gets CV_ASSUME_DISTID=OEL7.8),
                         OL9 only with Release Update 19.19 or later,
                         applied by the installer (-applyRU)
       21c               OL7, OL8, OL9
       23ai              OL8, OL9
EOF
  ;;
  2.1) cat <<EOF
TITLE  Groups (same names and ids as primary)
WHERE  This server ($S), as root
RUN    getent group $(tr ',' ' ' <<< "${GROUP_GIDS:-oinstall:54321}" | sed 's/:[0-9]*//g')
       groupadd -g <gid> <name>      (for each missing group, with the gid of the primary)
EXPECT The same gids as on the primary:  ${GROUP_GIDS:-<name:gid list>}
IF     A group exists with another gid and nothing is installed yet:
       groupmod -g <gid> <name>
EOF
  ;;
  2.2)
    printf 'TITLE  Users (same ids as primary)\nWHERE  This server (%s), as root\n' "$S"
    printf 'RUN    useradd -m -s /bin/bash -u %s -g %s%s %s\n' "${ORACLE_UID:-<uid>}" "$IG" "${ORACLE_GROUPS:+ -G $ORACLE_GROUPS}" "$OU"
    [[ $SO -eq 0 && $G -eq 1 ]] && printf '       useradd -m -s /bin/bash -u %s -g %s%s %s\n' "${GRID_UID:-<uid>}" "${GRID_PGROUP:-oinstall}" "${GRID_GROUPS:+ -G $GRID_GROUPS}" "$GU"
    printf '       passwd <user>      (optional)\nEXPECT "id %s" shows the same uid, gid and groups as on the primary\n' "$OU"
  ;;
  2.3) cat <<EOF
TITLE  Required packages
WHERE  This server ($S), as root
RUN    ${PKG:-dnf} install -y <package>
       Packages, one by one: <preinstall> unzip chrony parted bc
       With ASMLib also: oracleasm-support
       <preinstall> by version:
         12.1  oracle-rdbms-server-12cR1-preinstall
         12.2  oracle-database-server-12cR2-preinstall
         18c   oracle-database-preinstall-18c
         19c   oracle-database-preinstall-19c
         21c   oracle-database-preinstall-21c
         23ai  oracle-database-preinstall-23ai
EXPECT Complete!
IF     "No package available": enable the repository,
       for example ol7_latest or ol8_appstream.
       List the repositories with:  yum repolist  (or dnf repolist)
EOF
  ;;
  2.4) cat <<EOF
TITLE  Limits for the Oracle owners
WHERE  This server ($S), as root, file /etc/security/limits.d/oracle-grid.conf
WHY    The preinstall package sets limits only for the user "oracle".
       Every other owner needs them too.
RUN    Add these lines for each owner:
       <user> soft nofile 1024     <user> hard nofile 65536
       <user> soft nproc 16384     <user> hard nproc 16384
       <user> soft stack 10240     <user> hard stack 32768
       <user> soft memlock unlimited   <user> hard memlock unlimited
EXPECT As <user>, after a new login:  ulimit -Hn  shows 65536
EOF
  ;;
  2.5)
    printf 'TITLE  Software folders (same paths as primary)\nWHERE  This server (%s), as root\n' "$S"
    printf 'WHY    The script never changes the owner of a folder that already contains files.\n'
    if [[ $G -eq 1 ]]; then
      printf 'RUN    mkdir -p %s %s %s %s %s\n' "$GB" "$GH" "$INV" "$OB" "$DBH"
      printf '       chown %s:%s %s %s %s ; chown %s:%s %s %s\n' "$GU" "$IG" "$GB" "$GH" "$INV" "$OU" "$IG" "$OB" "$DBH"
    else
      printf 'RUN    mkdir -p %s %s %s\n' "$INV" "$OB" "$DBH"
      printf '       chown %s:%s %s %s %s\n' "$OU" "$IG" "$INV" "$OB" "$DBH"
    fi
    printf 'EXPECT ls -ld %s  shows owner %s\n' "$DBH" "$OU"
  ;;
  2.6) cat <<EOF
TITLE  Host names on this server
WHERE  This server ($S), as root, file /etc/hosts
RUN    getent ahostsv4 $P ; getent ahostsv4 $S
       If a name is missing, add its line to /etc/hosts:
       ${PRIMARY_IP:-<primary IP>}  $P
       ${STANDBY_IP:-<standby IP>}  $S
EXPECT The right IPv4 address for both names (never 127.x for $S)
EOF
  ;;
  2.7) cat <<EOF
TITLE  Primary resolves the standby host name
WHERE  The primary ($P), as root, file /etc/hosts
RUN    getent hosts $S
       If it is missing:
       echo '${STANDBY_IP:-<standby IP>}    $S' >> /etc/hosts
EXPECT The IP address of this server
EOF
  ;;
  2.8) cat <<EOF
TITLE  Network to the primary listener
WHERE  This server ($S), as root
RUN    timeout 5 bash -c "</dev/tcp/${PRIMARY_IP:-<primary IP>}/$PO" && echo OPEN
EXPECT OPEN
IF     No output: open the port on the primary, as root:
       firewall-cmd --permanent --add-port=$PO/tcp ; firewall-cmd --reload
EOF
  ;;
  2.9) cat <<EOF
TITLE  Firewall on this server
WHERE  This server ($S), as root
RUN    firewall-cmd --get-active-zones
       firewall-cmd --permanent --zone=<zone> --add-port=$PO/tcp
       firewall-cmd --reload
       <zone> is the zone of the network interface, from the first command.
EXPECT firewall-cmd --zone=<zone> --query-port=$PO/tcp  shows yes
       (or firewalld is not running)
EOF
  ;;
  2.10) cat <<EOF
TITLE  Time synchronization
WHERE  Both servers, as root
RUN    systemctl enable --now chronyd
       chronyc tracking
EXPECT Leap status : Normal   (a running ntpd is also fine)
EOF
  ;;
  2.11)
    printf 'TITLE  Environment (.bash_profile) of the Oracle users\nWHERE  This server (%s), ~/.bash_profile of %s%s\n' "$S" "$OU" "$([[ $G -eq 1 && $SO -eq 0 ]] && printf ' and of %s' "$GU"; [[ -z "${USE_GRID:-}" ]] && printf ' (with Grid: also of %s)' "$GU")"
    printf 'WHY    The script does not need it, but sqlplus, rman and srvctl by hand do.\n'
    printf 'RUN    %s:\n         export ORACLE_BASE=%s\n         export ORACLE_HOME=%s\n         export ORACLE_SID=%s\n' "$OU" "$OB" "$DBH" "$SID"
    printf '         export PATH=$ORACLE_HOME/bin:$PATH\n'
    if [[ ( $G -eq 1 && $SO -eq 0 ) || -z "${USE_GRID:-}" ]]; then
      printf '       %s%s:\n         export ORACLE_BASE=%s\n         export ORACLE_HOME=%s\n         export ORACLE_SID=+ASM\n' "$([[ -z "${USE_GRID:-}" ]] && printf 'with Grid, ')" "$GU" "$GB" "$GH"
      printf '         export PATH=$ORACLE_HOME/bin:$PATH\n'
    fi
    printf "EXPECT su - %s -c 'echo \$ORACLE_SID \$ORACLE_HOME'  shows:\n       %s %s\n       (upper/lower case must match)\n" "$OU" "$SID" "$DBH"
    printf 'IF     A wrong value comes from ~/.bashrc or /etc/profile.d: the last export wins.\n       Fix those lines.\n'
  ;;
  2.12) cat <<EOF
TITLE  ASM disk method (ASMLib or udev)
WHERE  This server ($S), as root
WHY    ASMLib needs the UEK kernel (Oracle Linux 7 or 8). Otherwise udev rules are used;
       they work on every kernel.
RUN    ASMLib:
       oracleasm configure -u $GU -g $AG -e -s y ; oracleasm init ; systemctl enable oracleasm ; oracleasm status
       udev: nothing to do here (one rule per disk in step 2.13).
       Set ASM_METHOD=udev in the settings.
EXPECT ASMLib: "Checking if ASM is loaded: yes",
       and  systemctl is-enabled oracleasm  shows enabled
EOF
  ;;
  2.13) cat <<EOF
TITLE  ASM disks
WHERE  This server ($S), as root
WHY    Each disk group of the primary ($DGS) needs one or more disks here.
       Labels: <DG>_1, <DG>_2 ...
       The disks must be empty, including the first MiB. Everything on them is erased.
RUN    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,WWN
       For every disk:
       parted -s <disk> mklabel gpt mkpart primary 1MiB 100% ; partprobe <disk>
       The partition is <disk>1, or <disk>p1 for nvme disks.
       ASMLib:
       oracleasm createdisk ${DD}_1 <partition> ; oracleasm scandisks ; oracleasm listdisks
       udev:
       udevadm info --query=property --name=<partition> | grep ID_PART_ENTRY_UUID
       echo 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_UUID}=="<uuid>", SYMLINK+="oraasm/${DD}_1", OWNER="$GU", GROUP="$AG", MODE="0660"' >> /etc/udev/rules.d/99-oracle-asmdevices.rules
       udevadm control --reload-rules ; udevadm trigger --action=change ; ls -lL /dev/oraasm/
       Then add the label to ${STATE_DIR}/asm_disks as  LABEL|partition
       (or answer y when the script asks to use the disk).
       A disk that is already in a disk group is used only when
       this server's ASM has that group mounted.
EXPECT ${DD}_1 (${DD}_2 ...) for every disk group, big enough (database size + 10%)
IF     The script says a disk has data, and you are sure it is not in use:
       wipefs -a <disk> ; dd if=/dev/zero of=<disk> bs=1M count=10
       Multipath (SAN): match a partition with ENV{DM_UUID}=="part1-mpath-<wwid>"
       (the whole device: "mpath-<wwid>").
       Then add this line to ${STATE_DIR}/asm_disks:
       <LABEL>|/dev/mapper/<name>
EOF
  ;;
  2.14) cat <<EOF
TITLE  Database folders and free space (file system)
WHERE  This server ($S), as root
WHY    The primary keeps its database files in folders, not in ASM.
       This server uses exactly the same paths (no file name conversion).
RUN    df -h <each folder of primary>
       mkdir -p <folder> ; chown $OU:$IG <folder>
       Not enough space: format a new, empty disk, mount it at the same path,
       and add it to /etc/fstab:
       mkfs.xfs /dev/<empty disk>
EXPECT Every folder exists, is owned by $OU, and has the space used on the primary + 10%.
EOF
  ;;
  2.15) cat <<EOF
TITLE  Database folders are not shared with the primary
WHERE  This server ($S) and the primary ($P), as root
WHY    The paths are the same. If a folder is the primary's NFS export or SAN volume,
       the copy would overwrite the primary's files.
RUN    touch <folder>/test_from_standby
       On the primary:
       ls -l <folder>/test_from_standby
       Back on this server:
       rm <folder>/test_from_standby
EXPECT The primary says: No such file or directory
       On a standby that is already built, this was checked before the copy.
IF     The file system UUID is the same on both servers
       (findmnt -o SOURCE,UUID --target <folder>): the disk is a copy of the primary's disk,
       or the same disk mounted twice. Compare the disks on both servers:
       lsblk -s -o NAME,TYPE,WWN,SERIAL,SIZE \$(findmnt -n -o SOURCE --target <folder>)
       Change nothing on such a disk until you know which it is.
EOF
  ;;
  3.1)
    printf 'TITLE  Installer files\nWHERE  The primary (%s) for a gold image, then this server (%s) as root\n' "$P" "$S"
    if [[ ${DB_MAJOR:-19} -ge 18 ]]; then
      printf 'RUN    Best: a gold image of the primary home. It has the same patches.\n'
      printf '       On the primary, as %s:\n       mkdir -p /tmp/gold ; %s/runInstaller -silent -createGoldImage -destinationLocation /tmp/gold\n' "$OU" "$DBH"
      [[ $G -eq 1 ]] && printf '       On the primary, as %s:\n       mkdir -p /tmp/gold ; %s/gridSetup.sh -silent -createGoldImage -destinationLocation /tmp/gold\n' "$GU" "$GH"
      printf '       On this server, as root:\n       mkdir -p /stage ; scp %s@%s:/tmp/gold/*.zip /stage/\n' "${PRIMARY_SSH_USER:-oracle}" "${PRIMARY_IP:-<primary IP>}"
      printf '       Or the base files: LINUX.X64_<180000|193000|213000>_db_home.zip (and _grid_home.zip);\n'
      printf '       23ai from edelivery.\n'
      printf '       For either kind of file:\n'
    else
      printf 'RUN    The base files:\n'
      printf '       12.1  linuxamd64_12102_database_1of2.zip + 2of2  (Grid: linuxamd64_12102_grid_1of2.zip + 2of2)\n'
      printf '       12.2  linuxx64_12201_database.zip  (Grid: linuxx64_12201_grid_home.zip)\n'
    fi
    printf '       chmod 644 /stage/*.zip\n'
    printf '       The owner must be root, %s or %s. Nobody else may be able to change the files.\n' "$OU" "$GU"
    printf 'EXPECT The script finds them. It searches: %s\n' "${ZIP_DIRS[*]}"
  ;;
  3.2) cat <<EOF
TITLE  Grid Infrastructure software (Oracle Restart)
WHERE  This server ($S), as $GU
WHY    Needed only when the primary uses ASM.
RUN    12.2 and newer:
       cd $GH ; unzip -q <grid zip> ; ./gridSetup.sh
       (with a Release Update, add:  -applyRU <folder>)
       12.1:
       unzip both zips into a stage folder ; ./grid/runInstaller
       In the installer choose: Standalone Server (Oracle Restart),
       disk group $DD, External, base $GB,
       discovery path /dev/oracleasm/disks/* (ASMLib) or /dev/oraasm/* (udev).
EXPECT The installer finishes and asks you to run the root scripts (step 3.3).
IF     Logs are in $INV/logs/
       INS-08101 on OL8/9: the OS is newer than the installer.
       Use a Release Update (step 1.6).
EOF
  ;;
  3.3) cat <<EOF
TITLE  Grid root scripts
WHERE  This server ($S), as root
RUN    12.1 on Oracle Linux 7 only, first apply patch 18370031:
       $GH/OPatch/opatch napply -oh $GH -local <patch folder>
       Then:
       $INV/orainstRoot.sh
       $GH/root.sh
EXPECT As $GU:  crsctl check has
       shows CRS-4638 Oracle High Availability Services is online
IF     root.sh failed: undo it, then run it again:
       $GH/crs/install/roothas.sh -deconfig -force
       $GH/root.sh
EOF
  ;;
  3.4) cat <<EOF
TITLE  ASM and listener (Grid configuration)
WHERE  This server ($S), as $GU
RUN    12.2 and newer:
       $GH/gridSetup.sh -executeConfigTools -responseFile <file> -silent
       12.1:
       $GH/cfgtoollogs/configToolAllCommands RESPONSE_FILE=<file with the ASM passwords>
EXPECT crsctl stat res -t  shows ora.asm, ora.$SL.lsnr and ora.${DD^^}.dg ONLINE
IF     HAS is stopped, as root:
       $GH/bin/crsctl start has
       ASM is offline:
       crsctl start res ora.asm
EOF
  ;;
  3.5) cat <<EOF
TITLE  ASM disk groups (same names as primary)
WHERE  This server ($S), as $GU, in  sqlplus / as sysasm
WHY    Each disk group of the primary ($DGS) needs a disk group with the same name here.
RUN    create diskgroup <DG> external redundancy disk '<disk path>' attribute 'compatible.asm'='<as $DD>', 'compatible.rdbms'='<as $DD>';
       asmcmd lsdg
EXPECT Every disk group of the primary is MOUNTED.
IF     A disk group exists but is dismounted:
       alter diskgroup <DG> mount;
EOF
  ;;
  3.6) cat <<EOF
TITLE  Database software (Software Only)
WHERE  This server ($S), as $OU
RUN    18c and newer:
       cd $DBH ; unzip -q <db zip or gold image> ; ./runInstaller
       (with a Release Update, add:  -applyRU <folder>)
       12.x:
       unzip the zip(s) into a stage folder ; ./database/runInstaller
       In the installer choose: Set Up Software Only, Single instance, Enterprise Edition,
       home $DBH, base $OB.
EXPECT The installer finishes. Then step 3.7.
EOF
  ;;
  3.7)
    printf 'TITLE  Database root.sh\nWHERE  This server (%s), as root\n' "$S"
    printf 'RUN    %s/orainstRoot.sh      (only if /etc/oraInst.loc does not exist yet)\n       %s/root.sh\n' "$INV" "$DBH"
    printf 'EXPECT ls -l %s/bin/oradism  shows owner root\n' "$DBH"
  ;;
  3.8) cat <<EOF
TITLE  Read/write Oracle home
WHERE  This server ($S), as $OU
WHY    From 18c a home can be read-only. This setup keeps the spfile, the password file
       and tnsnames.ora in the home, so the home must be read/write.
RUN    $DBH/bin/orabasehome
       $DBH/bin/roohctl -disable      (only on a new home without any database)
EXPECT orabasehome prints $DBH
EOF
  ;;
  3.9) cat <<EOF
TITLE  Oracle Restart resources ONLINE
WHERE  This server ($S), as $GU
RUN    crsctl stat res -t
       crsctl start res <name>      (for each OFFLINE resource)
       If the listener is missing:
       srvctl add listener -listener $SL -endpoints TCP:$PO ; srvctl start listener -listener $SL
EXPECT ONLINE: ora.asm, ora.$SL.lsnr, and ora.<DG>.dg for $DGS
EOF
  ;;
  3.10) cat <<EOF
TITLE  Listener port equal to primary ($PO)
WHERE  This server ($S), as $GU
WHY    The listener here is always $SL (Grid creates it).
       Only its port must match the primary.
RUN    srvctl modify listener -listener $SL -endpoints TCP:$PO
       srvctl stop listener -listener $SL ; srvctl start listener -listener $SL
EXPECT lsnrctl status $SL  shows (PORT=$PO)
EOF
  ;;
  3.11)
    printf 'TITLE  Same release and patches as primary\nWHERE  Both servers, as %s\n' "$OU"
    printf 'RUN    <home>/OPatch/opatch lspatches       (every home, on both servers)\n'
    printf '       %s/bin/sqlplus -V\n' "$DBH"
    printf 'EXPECT The same release and the same patch list on both servers\n'
    printf 'IF     Different: put the newest OPatch (patch 6880880) into the homes, then:\n'
    if [[ $G -eq 1 ]]; then
      printf '       As root:  %s/OPatch/opatchauto apply <RU folder> -oh %s\n' "$GH" "$GH"
      printf '       As root:  %s/OPatch/opatchauto apply <RU folder> -oh %s\n' "$DBH" "$DBH"
    else
      printf '       As %s:  cd <RU folder> ; %s/OPatch/opatch apply\n' "$OU" "$DBH"
    fi
    printf '       One-off patches, as %s:  cd <patch> ; %s/OPatch/opatch apply\n' "$OU" "$DBH"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '       Then, as root:  %s/bin/setasmgidwrap o=%s/bin/oracle\n' "$GH" "$DBH"
    [[ ${DB_MAJOR:-19} -ge 18 ]] && printf '       Easier: install from a gold image of the primary home (step 3.1).\n'
    true
  ;;
  4.1) cat <<EOF
TITLE  ARCHIVELOG and FORCE LOGGING
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       select value from v\$parameter where name='spfile';
       -- empty: the primary runs from a text pfile. Create an spfile first (one restart):
       --   create pfile='/tmp/init<SID>_before_dg.ora' from memory;
       --   create spfile from memory;
       --   then restart
       select log_mode, force_logging from v\$database;
       alter database force logging;
       -- only for NOARCHIVELOG (short downtime):
       --   shutdown immediate / startup mount /
       --   alter database archivelog; / alter database open;
EXPECT log_mode ARCHIVELOG, force_logging YES
EOF
  ;;
  4.2) cat <<EOF
TITLE  Standby redo logs on the primary
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       select thread#, count(*), max(bytes)/1024/1024 mb, max(blocksize) from v\$log group by thread#;
       select thread#, count(*) from v\$standby_log group by thread#;
       -- per thread: online groups + 1; size = the largest online log;
       -- blocksize 4096 if the online logs use it
       -- with OMF or ASM:
       alter database add standby logfile thread 1 size <M>M;
       -- without OMF:
       alter database add standby logfile thread 1 group <n> ('<redo folder>/srl_t1_g<n>.log') size <M>M;
EXPECT For every thread: standby logs = online groups + 1
EOF
  ;;
  4.3) cat <<EOF
TITLE  Data Guard names (log_archive_config)
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       show parameter log_archive_config
       alter system set log_archive_config='dg_config=(<names already in the list>,$PU,$SU)' scope=both;
       -- keep every name that is already in the list,
       -- or another standby stops receiving redo
EXPECT show parameter log_archive_config  shows both names
EOF
  ;;
  4.4) cat <<EOF
TITLE  Redo transport to the standby (log_archive_dest_N)
WHERE  The primary ($P), SQL*Plus as sysdba
WHY    N is usually 2. If log_archive_dest_2 is used for something else,
       the script takes the first free N.
RUN    $PSQL
       alter system set log_archive_dest_state_N=defer scope=both;
       alter system set log_archive_dest_N='service=$ST async valid_for=(online_logfiles,primary_role) db_unique_name=$SU' scope=both;
EXPECT show parameter log_archive_dest_N  shows the service $ST
IF     ORA-16018 (the old parameter log_archive_dest is in use): first run
       alter system set log_archive_dest='' scope=both; alter system set log_archive_dest_1='location=<same folder>' scope=both;
EOF
  ;;
  4.5) cat <<EOF
TITLE  Automatic standby files (standby_file_management)
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       alter system set standby_file_management=auto scope=both;
EXPECT AUTO
EOF
  ;;
  4.6) cat <<EOF
TITLE  Archive destination and recovery area
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       show parameter log_archive_dest_1
       show parameter db_recovery_file_dest
       -- only if neither is set:
       alter system set db_recovery_file_dest_size=200G scope=both;
       alter system set db_recovery_file_dest='<+DG or folder>' scope=both;
EXPECT log_archive_dest_1 has LOCATION=..., or a recovery area is set
EOF
  ;;
  4.7) cat <<EOF
TITLE  Password file and SYS
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       show parameter remote_login_passwordfile
       select username, sysdba from v\$pwfile_users;
       -- SYS is missing, but a password file exists:
       alter user sys identified by "<the same sys password>";
       -- no password file at all: in a shell as $OU (orapwd asks for the password):
       --   file system: orapwd file=\$ORACLE_HOME/dbs/orapw$PS format=12.2     (12.1: format=12)
       --   ASM:         orapwd file='+<DG>/$PU/orapw<db>' dbuniquename=$PU format=12.2
EXPECT EXCLUSIVE (or SHARED), and SYS with sysdba TRUE
EOF
  ;;
  4.8) cat <<EOF
TITLE  fal_server (for switchover)
WHERE  The primary ($P), SQL*Plus as sysdba
WHY    Used only after a switchover. You may skip it.
RUN    $PSQL
       alter system set fal_server='$ST' scope=both;
EXPECT show parameter fal_server  shows $ST
EOF
  ;;
  4.9) cat <<EOF
TITLE  Standby alias in the primary tnsnames.ora
WHERE  The primary ($P), as $OU, file $PTA/tnsnames.ora
RUN    Add this entry:
       $ST =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $S)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $SSV)(UR = A))
         )
       Then test it:
       $DBH/bin/tnsping $ST
EXPECT "Used TNSNAMES adapter" and OK
EOF
  ;;
  4.10) cat <<EOF
TITLE  Static listener entry on the primary
WHERE  The primary ($P), as the owner of the listener home, file:
       $PLH/network/admin/listener.ora
WHY    Needed for switchover and the broker, not to build the standby. You may skip it.
RUN    Add this entry:
       SID_LIST_$LN =
         (SID_LIST =
           (SID_DESC =
             (GLOBAL_DBNAME = $PSV)
             (SID_NAME = $PS)
             (ORACLE_HOME = $DBH)
           )
         )
       Then reload the listener:
       $PLH/bin/lsnrctl reload $LN
EXPECT lsnrctl status $LN  shows Instance "$PS", status UNKNOWN
EOF
  ;;
  4.11) cat <<EOF
TITLE  Environment of $OU on the primary
WHERE  The primary ($P), as $OU, file ~/.bash_profile
WHY    Information only. The script does not use it,
       but sqlplus, rman and dgmgrl by hand need it.
RUN    export ORACLE_BASE=$OB
       export ORACLE_HOME=$DBH
       export ORACLE_SID=$PS
       export PATH=\$ORACLE_HOME/bin:\$PATH
EXPECT After a new login:  echo \$ORACLE_SID  shows $PS
EOF
  ;;
  5.1)
    printf 'TITLE  Static listener entry for %s\n' "$SID"
    if [[ -z "${USE_GRID:-}" ]]; then
      printf 'WHERE  This server (%s), as the listener owner:\n' "$S"
      printf '       with Grid, %s and %s/network/admin/listener.ora;\n' "$GU" "$GH"
      printf '       without Grid, %s and %s/network/admin/listener.ora\n' "$OU" "$DBH"
    else
      printf 'WHERE  This server (%s), as %s, file:\n       %s/network/admin/listener.ora\n' "$S" "$LU" "$LH"
    fi
    printf 'WHY    In NOMOUNT the instance cannot register itself, so the listener needs a static entry.\n'
    printf '       ORACLE_HOME must be the database home.\n'
    printf '       With the Grid home you get ORA-01017 through the listener.\n'
    [[ $G -eq 0 ]] && printf 'RUN    Without Grid, define the listener as well:\n       %s = (DESCRIPTION_LIST = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))))\n       Add this entry:\n' "$SL" "$S" "$PO"
    [[ $G -eq 1 ]] && printf 'RUN    Add this entry:\n'
    printf '       SID_LIST_%s =\n         (SID_LIST =\n           (SID_DESC =\n             (GLOBAL_DBNAME = %s)\n             (SID_NAME = %s)\n             (ORACLE_HOME = %s)\n           )\n         )\n' "$SL" "$SSV" "$SID" "$DBH"
    printf 'EXPECT Step 5.2 checks it.\n'
  ;;
  5.2) cat <<EOF
TITLE  Listener shows the static entry
WHERE  This server ($S), as $LU
RUN    $LH/bin/lsnrctl start $SL      (only without Grid, when it is not running)
       $LH/bin/lsnrctl reload $SL
       $LH/bin/lsnrctl status $SL
EXPECT Instance "$SID", status UNKNOWN, and (PORT=$PO)
EOF
  ;;
  5.3|5.4)
    local TA TH TS
    if [[ "$1" == "5.3" ]]; then TA=$PT; TH=$P; TS=$PSV; printf 'TITLE  tnsnames.ora entry for the primary (%s)\n' "$PT"
    else TA=$ST; TH=$S; TS=$SSV; printf 'TITLE  tnsnames.ora entry for the standby (%s)\n' "$ST"; fi
    cat <<EOF
WHERE  This server ($S), as $OU, file $DBH/network/admin/tnsnames.ora
WHY    This server needs two aliases: the primary (step 5.3) and itself (step 5.4).
RUN    Add this entry:
       $TA =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $TH)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $TS)(UR = A))
         )
       Then test it:
       tnsping $TA
EXPECT OK, with HOST = $TH
EOF
  ;;
  6.1) cat <<EOF
TITLE  Password file orapw$SID
WHERE  The primary ($P), then this server ($S)
WHY    This server needs an exact copy of the primary's password file.
RUN    On the primary, find the file:
       $PSQL
       select file_name from v\$passwordfile_info;
       -- 12.2 and newer; on 12.1 the file is usually \$ORACLE_HOME/dbs/orapw<SID>
       If the name starts with +, on the primary as $GU
       (export ORACLE_HOME=$GH ORACLE_SID=+ASM):
         rm -f /tmp/orapw_for_standby_$SID
         \$ORACLE_HOME/bin/asmcmd pwcopy '<file_name>' /tmp/orapw_for_standby_$SID
         chgrp $IG /tmp/orapw_for_standby_$SID ; chmod 640 /tmp/orapw_for_standby_$SID
       On this server, as root:
         scp ${PRIMARY_SSH_USER:-oracle}@$P:<file or /tmp copy> $DBH/dbs/orapw$SID
         chown $OU:$IG $DBH/dbs/orapw$SID ; chmod 640 $DBH/dbs/orapw$SID
EXPECT md5sum is the same on both servers.
       12.2 and newer: this shows a format:
       orapwd describe file=$DBH/dbs/orapw$SID
EOF
  ;;
  6.2) cat <<EOF
TITLE  Remove the temporary copy on the primary
WHERE  The primary ($P)
WHY    The copy of the password file must not stay in /tmp.
RUN    rm -f /tmp/orapw_for_standby_$SID
EXPECT ls /tmp/orapw_for_standby_$SID  shows No such file
EOF
  ;;
  6.3) cat <<EOF
TITLE  TDE wallet (only if the primary uses TDE)
WHERE  The primary ($P), then this server ($S)
RUN    On the primary:
       $PSQL
       select wrl_type, wrl_parameter, status, wallet_type from v\$encryption_wallet;
       Copy ewallet.p12 to the same folder here.
       Copy cwallet.sso too, unless wallet_type is LOCAL_AUTOLOGIN:
       scp ${PRIMARY_SSH_USER:-oracle}@$P:<folder>/ewallet.p12 <folder>/
       scp ${PRIMARY_SSH_USER:-oracle}@$P:<folder>/cwallet.sso <folder>/
       chown $OU:$IG <folder>/* ; chmod 600 <folder>/*
       No cwallet.sso, or a LOCAL one on the primary: create it here as $OU
       (orapki asks for the keystore password; LOCAL on the primary: use -auto_login_local):
       $DBH/bin/orapki wallet create -wallet <folder> -auto_login
       No WALLET_ROOT on the primary (12c, or the old setup):
       add this line to $DBH/network/admin/sqlnet.ora:
       ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = <folder>)))
EXPECT md5sum of the wallet files is the same on both servers.
EOF
  ;;
  7.1) cat <<EOF
TITLE  Folders for the instance (audit, diagnostics)
WHERE  This server ($S), as root
RUN    mkdir -p ${ORACLE_BASE:-<oracle base>}/admin/$SU/adump ${DIAG_DEST:-<diagnostic_dest of primary>}
       chown $OU:$IG <each new folder>
EXPECT The audit folder of the standby and the diagnostic_dest of the primary exist
       and are writable by $OU.
EOF
  ;;
  7.2) cat <<EOF
TITLE  Instance $SID in NOMOUNT
WHERE  This server ($S), as $OU
RUN    Create $DBH/dbs/init$SID.ora with:
         *.db_name='${DB_NAME:-<db_name>}'
         *.db_unique_name='$SU'
         *.enable_pluggable_database=true        (only if the primary is a CDB)
       Then:
       $SSQL
       startup nomount pfile='$DBH/dbs/init$SID.ora'
EXPECT ORACLE instance started.
EOF
  ;;
  7.3|7.4|7.5|7.6)
    case "$1" in
      7.3) printf 'TITLE  Login 1 of 4: sqlplus / as sysdba on this server\n' ;;
      7.4) printf 'TITLE  Login 2 of 4: sys@%s through the listener\n' "$ST" ;;
      7.5) printf 'TITLE  Login 3 of 4: sys@%s from this server\n' "$PT" ;;
      *)   printf 'TITLE  Login 4 of 4: sys@%s from the primary\n' "$ST" ;;
    esac
    if [[ "$1" == "7.6" ]]; then printf 'WHERE  The primary (%s), as %s\n' "$P" "$OU"; else printf 'WHERE  This server (%s), as %s\n' "$S" "$OU"; fi
    printf 'WHY    All four logins (steps 7.3 to 7.6) must work before the RMAN copy.\n'
    case "$1" in
      7.3) printf 'RUN    sqlplus / as sysdba\n' ;;
      7.5) printf 'RUN    sqlplus sys@%s as sysdba\n' "$PT" ;;
      *)   printf 'RUN    sqlplus sys@%s as sysdba\n' "$ST" ;;
    esac
    printf 'EXPECT Connected.\n'
    case "$1" in
      7.3) printf 'IF     ORA-01017: %s is not in the OSDBA group of the home\n' "$OU" ;;
      7.5) printf 'IF     ORA-01017: wrong sys password, or the password files differ (step 6.1)\n'
           printf '       ORA-12154: the alias is missing (step 5.3)\n'
           printf '       ORA-12514 or ORA-12541: the listener on the primary\n' ;;
      *)   printf 'IF     ORA-01017: static entry ORACLE_HOME (step 5.1) or password file (step 6.1)\n'
           printf '       ORA-12528: (UR = A) or the static entry is missing\n'
           printf '       ORA-12514: SERVICE_NAME differs from GLOBAL_DBNAME\n'
           if [[ "$1" == "7.6" ]]; then printf '       ORA-12154: the alias is missing on the primary (step 4.9)\n'
           else printf '       ORA-12154: the alias is missing (step 5.4)\n'; fi ;;
    esac
  ;;
  7.7) cat <<EOF
TITLE  /etc/oratab entry for $SID
WHERE  This server ($S), as root
RUN    echo '$SID:$DBH:N' >> /etc/oratab
EXPECT As $OU, . oraenv (answer $SID) sets ORACLE_HOME=$DBH
EOF
  ;;
  8.1)
    printf 'TITLE  Pre-checks: space, storage, logins, parameters\nWHERE  This server (%s)\n' "$S"
    printf 'RUN    %s\n       select status from v$instance;      (STARTED)\n' "$SSQL"
    [[ $G -eq 1 ]] && printf '       As %s:  asmcmd lsdg      (Free_MB of %s)\n' "$GU" "$DGS"
    [[ -n "${LOCS:-}" ]] && fs_dirs >/dev/null 2>&1 && [[ -n "$(fs_dirs)" ]] && printf '       df -m %s\n' "$(fs_dirs | paste -sd' ' -)"
    printf '       Size of the primary in MB:\n       sqlplus sys@%s as sysdba\n       select round(sum(bytes)/1024/1024) from v$datafile;\n' "$PT"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '       ls -l %s/bin/oracle      (group %s; if not, as root: %s/bin/setasmgidwrap o=%s/bin/oracle)\n' "$DBH" "$AG" "$GH" "$DBH"
    printf 'EXPECT Free space is larger than the primary size + 10%%.\n'
    printf '       The folders are not the primary storage (step 2.15).\n'
  ;;
  8.2)
    local SUU=$SU PUU=$PU
    [[ -n "${STANDBY_UNIQUE:-}" ]] && SUU=${SU^^}; [[ -n "${PRIMARY_UNIQUE:-}" ]] && PUU=${PU^^}
    cat <<EOF
TITLE  RMAN duplicate for standby
WHERE  This server ($S), as $OU
WHY    The primary only reads its datafiles and sends them.
       Nothing on the primary is changed.
RUN    rman target sys@$PT auxiliary sys@$ST
       Then the run { ... } block from ${LOG_DIR:-/var/log/dg_standby_setup}/duplicate_<date>.rman
EXPECT Finished Duplicate Db.
       RMAN-05535, or ORA-19527 / ORA-00312 about redo log files,
       are normal during the copy.
IF     The copy failed: clean this server before you try again, and check every name twice.
       The script shows the exact commands when you run it with --from 7.2.
       On this server only ($S):
         $SSQL
         shutdown abort
       ASM, as $GU:
         [ "\$(hostname -s)" = "$(hostname -s)" ] && ORACLE_HOME=$GH ORACLE_SID=+ASM $GH/bin/asmcmd rm -rf +<DG>/$SUU
         NEVER +<DG>/$PUU: those are the primary's files.
       Folders: delete the files the copy left (step 7.2 lists them).
       As $OU:
         [ "\$(hostname -s)" = "$(hostname -s)" ] && rm -f $DBH/dbs/spfile$SID.ora $DBH/dbs/.dg_duplicate_done_$SID
       Then run the script with:  --from 7.2
EOF
  ;;
  9.1) cat <<EOF
TITLE  Registration in Oracle Restart (srvctl)
WHERE  This server ($S), as $OU
WHY    Only with Grid. Oracle Restart then mounts the standby after a reboot.
RUN    srvctl config database -db $SU
       srvctl add database -db $SU -oraclehome $DBH -spfile $DBH/dbs/spfile$SID.ora \\
         -pwfile $DBH/dbs/orapw$SID -role PHYSICAL_STANDBY -startoption MOUNT \\
         -dbname ${DB_NAME:-<db_name>} -instance $SID -diskgroup $(tr ' ' ',' <<< "$DGS")${PRIMARY_DOMAIN:+ -domain $PRIMARY_DOMAIN}
EXPECT srvctl config database -db $SU
       shows the instance name exactly $SID
IF     "Connected to an idle instance": the -instance value is wrong.
EOF
  ;;
  9.2) cat <<EOF
TITLE  Standby instance running (MOUNT)
WHERE  This server ($S), as $OU
RUN    With Grid:
       sqlplus / as sysdba  ->  shutdown immediate
       srvctl start database -db $SU
       Without Grid:
       sqlplus / as sysdba  ->  startup mount
       Check:
       sqlplus / as sysdba  ->  select instance_name, status from v\$instance;
EXPECT $SID  MOUNTED
       Never OPEN read only without an Active Data Guard license.
EOF
  ;;
  9.3) cat <<EOF
TITLE  Standby redo logs on this server
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       alter database recover managed standby database cancel;
       alter system set standby_file_management=manual scope=memory;
       alter database add standby logfile thread 1 size <same as primary>M;
       (this form is for OMF or ASM; otherwise add a file name)
       alter system set standby_file_management=auto scope=memory;
EXPECT Per thread: online groups + 1
EOF
  ;;
  9.4) cat <<EOF
TITLE  Redo apply (MRP)
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       alter database recover managed standby database disconnect from session;
       select $DGN, $DGR, $DGS2 from $DGP where $DGN like 'MRP%';
EXPECT MRP0 with APPLYING_LOG or WAIT_FOR_LOG
EOF
  ;;
  9.5) cat <<EOF
TITLE  Redo transport from the primary
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       alter system set log_archive_dest_state_N=enable scope=both;
       (N from step 4.4, usually 2)
       alter system switch logfile;
       select status, error from v\$archive_dest where dest_id=N;
EXPECT VALID, and error is empty
IF     ORA-16191 or ORA-01017: password file (step 6.1)
       ORA-12154: the standby alias on the primary (step 4.9)
       ORA-12514 or ORA-12541: listener and tnsnames.ora here (phase 5)
EOF
  ;;
  9.6) cat <<EOF
TITLE  Redo arrives on this server (RFS)
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       select $DGN, $DGR, $DGS2 from $DGP where $DGR like 'RFS%';
EXPECT At least one RFS row
EOF
  ;;
  9.7)
    printf 'TITLE  Start at boot (mount and apply)\nWHERE  This server (%s), as root\n' "$S"
    if [[ -z "${USE_GRID:-}" ]]; then
      printf 'WHY    With Grid, Oracle Restart mounts the standby but nothing starts redo apply.\n'
      printf '       Without Grid, nothing starts the listener or the standby after a reboot.\n'
      printf 'RUN    With Grid:\n'
    elif [[ $G -eq 1 ]]; then
      printf 'WHY    Oracle Restart mounts the standby after a reboot, but it does not start apply (MRP).\n'
    else
      printf 'WHY    Without Grid, nothing starts the listener or the standby after a reboot.\n'
    fi
    if [[ $G -eq 1 || -z "${USE_GRID:-}" ]]; then
      printf '%s A script (owned by root, run as %s) that waits until v$instance shows MOUNTED,\n' "$([[ $G -eq 1 ]] && printf 'RUN   ' || printf '      ')" "$OU"
      printf '       then runs:\n'
      printf '         alter database recover managed standby database disconnect from session;\n'
      printf '       A systemd unit that runs it (User=%s, Type=simple, After=oracle-ohasd.service).\n' "$OU"
      printf '       Then:\n'
      printf '       systemctl enable <unit>\n'
    fi
    if [[ $G -eq 0 ]]; then
      [[ -z "${USE_GRID:-}" ]] && printf '       Without Grid:\n'
      printf '%s A script (owned by root, run as %s). At start:\n' "$([[ -z "${USE_GRID:-}" ]] && printf '      ' || printf 'RUN   ')" "$OU"
      printf '         lsnrctl start %s ; startup mount ;\n' "$SL"
      printf '         alter database recover managed standby database disconnect from session;\n'
      printf '       At shutdown:\n'
      printf '         shutdown immediate ; lsnrctl stop %s\n' "$SL"
      printf '       A systemd unit (User=%s, Type=oneshot + RemainAfterExit,\n' "$OU"
      printf '       LimitNOFILE/NPROC/STACK/MEMLOCK as for %s). Then:\n' "$OU"
      printf '       systemctl enable <unit>\n'
    fi
    printf 'EXPECT After a reboot the standby is MOUNTED and MRP runs.\n'
  ;;
  9.8) cat <<EOF
TITLE  Clean-up of archived logs on the standby
WHERE  This server ($S), as $OU (the timer as root)
WHY    Without a deletion policy the archived logs fill the recovery area or the archive
       destination, and redo transport stops (ORA-19809 / ORA-00257).
       A policy copied from the primary with "BACKED UP n TIMES"
       never deletes anything here.
RUN    rman target /
       CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;
       With a recovery area, Oracle then deletes applied logs by itself when it needs space.
       With another archive destination (a folder or a disk group),
       add a daily job as $OU,
       for example a systemd timer that runs:
       rman target /  ->  delete noprompt archivelog all completed before 'sysdate-1';
       The primary is not changed here. Its own policy belongs to its backups.
       To check it there:
       show archivelog deletion policy;
       Never set "BACKED UP n TIMES" on a primary that RMAN does not back up.
EXPECT select value from v\$rman_configuration where name='ARCHIVELOG DELETION POLICY';
       shows TO APPLIED ON STANDBY
EOF
  ;;
  10.1) cat <<EOF
TITLE  Transport and apply lag
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       select name, value from v\$dataguard_stats where name in ('transport lag','apply lag');
EXPECT +00 00:00:00 or a few seconds.
       Right after setup the values can be empty for some minutes.
EOF
  ;;
  10.2) cat <<EOF
TITLE  No archive gap
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       select * from v\$archive_gap;
EXPECT no rows selected
EOF
  ;;
  10.3) cat <<EOF
TITLE  Last log: primary and standby
WHERE  Both servers, as $OU, sqlplus / as sysdba
RUN    On the primary:
       select max(sequence#) from v\$archived_log where standby_dest='NO' and thread#=1
         and resetlogs_change#=(select resetlogs_change# from v\$database);
       On this server:
       select max(sequence#) from v\$archived_log where applied in ('YES','IN-MEMORY') and thread#=1
         and resetlogs_change#=(select resetlogs_change# from v\$database);
EXPECT Equal, or the standby is 1 lower
EOF
  ;;
  10.4) cat <<EOF
TITLE  Redo apply is running
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       select $DGN, $DGR, $DGS2 from $DGP where $DGN like 'MRP%';
       select count(*) from v\$standby_log where status='ACTIVE';
       (1 or more: real-time apply gets redo)
       select timestamp, message from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp;
EXPECT MRP0 runs, at least one standby log is ACTIVE, and there are no new errors
EOF
  ;;
  *) return 1 ;;
  esac
}

show_help() {
  local id=${1:-} txt line key rest title
  if ! txt=$(help_text "$id"); then
    printf '    No help for step "%s". All steps:  %s --help-step all\n' "$id" "$SELF"; return 1
  fi
  title=$(grep -m1 '^TITLE ' <<< "$txt"); title=${title:7}
  local t="Help $S_DOT Step $id  $title" lbl
  if [[ ${#t} -le 62 ]]; then printf '\n    %s%s %s %s%s\n' "$C_C" "$(rule 2)" "$t" "$(rule $((64 - ${#t})))" "$C_N"
  else printf '\n    %s%s %s%s\n    %s%s%s\n' "$C_C" "$(rule 2)" "$t" "$C_N" "$C_C" "$(rule 70)" "$C_N"; fi   # a long title: the rule goes under it
  while IFS= read -r line || [[ -n "$line" ]]; do
    key=${line:0:6}; rest=${line:7}
    case "$key" in
      "TITLE ") ;;
      "WHERE "|"WHY   "|"RUN   "|"EXPECT"|"IF    ")
        case "$key" in "WHERE ") lbl="Where" ;; "WHY   ") lbl="Why" ;; "RUN   ") lbl="How" ;; "EXPECT") lbl="Expect" ;; *) lbl="Problems" ;; esac
        printf '\n      %s%-8s%s %s\n' "$C_Y" "$lbl" "$C_N" "$rest" ;;
      *) printf '               %s\n' "${line:7}" ;;
    esac
  done <<< "$txt"
  printf '    %s%s%s\n\n' "$C_C" "$(rule 70)" "$C_N"
  _log HELP "Help shown for step $id"
}

help_cli() {
  # --help-step X.Y | all : uses saved settings when they are safe to read (parsed, never executed)
  local id=$1 i
  init_settings
  SETTINGS_FILE="$STATE_DIR/settings.conf"
  if [[ -r "$SETTINGS_FILE" ]]; then
    load_settings soft >/dev/null 2>&1 || { init_settings; printf '(saved settings not usable; showing placeholders)\n'; }
  elif [[ -e "$SETTINGS_FILE" ]]; then
    printf '(the settings file is not readable for this user; run as root to see your values)\n'
  else
    printf '(no saved settings yet; showing placeholders)\n'
  fi
  if [[ "$id" == "all" ]]; then for i in "${HELP_IDS[@]}"; do show_help "$i"; done
  else show_help "$id" || exit 2; fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
CLI_IP=""; CLI_USER=""

usage() {
  cat <<EOF
dg_standby_setup.sh, version $SCRIPT_VERSION: builds an Oracle Data Guard physical standby (12.1 to 23ai)

Run it as root on the new standby server (Oracle Linux 7, 8 or 9).
It never changes the primary. What the primary needs is shown for you to run.
Storage in ASM or in folders, Grid with its own user or not: all are supported.

Usage
  dg_standby_setup.sh                      Start or continue the setup
  dg_standby_setup.sh --primary 10.0.0.5   IP address or host name of the primary
  dg_standby_setup.sh --user oracle        OS user for ssh on the primary (default oracle)
  dg_standby_setup.sh --check              Check and report only; changes nothing
                                           (still asks for the ssh and sys passwords)
  dg_standby_setup.sh --from 6.1           Continue from a step (phase 1 always runs)
  dg_standby_setup.sh --only 10            Run one phase only (10 = daily health check)
  dg_standby_setup.sh --settings           Review or edit the settings, then stop
  dg_standby_setup.sh --status             Show the result of every phase and step
                                           (connects to nothing)
  dg_standby_setup.sh --show-changes       Changes made by the setup, and how to undo them
  dg_standby_setup.sh --show-changes 6.1   The same, for one step
  dg_standby_setup.sh --undo 6.1           Undo the changes of one step (asks before each one)
  dg_standby_setup.sh --help-step 6.1      How to do a step by hand ("all" for every step)

How it works
  Each step shows what it found and what it will do, then asks:
    [y] Yes, do it   [s] Skip   [h] Help   [q] Quit
  Commands for the primary are only shown. You run them there, answer r,
  and the script checks the result.
  Installers, root scripts and the RMAN copy run in their own session. A closed terminal
  does not stop them. Run the script again and it waits for them.

Phases
   1 Connect to the primary          6 Password file and TDE wallet
   2 Prepare this server             7 Start the empty instance (NOMOUNT)
   3 Install the Oracle software     8 Copy the database (RMAN)
   4 Prepare the primary             9 Start redo apply and transport
   5 Listener and tnsnames.ora      10 Health check
  Phases 4, 6 and 9 need commands on the primary. Phase 4 can be done first
  (the first run offers it) or at any time:  dg_standby_setup.sh --only 4

Files
  Settings   $STATE_DIR/settings.conf (last accepted copy: settings.accepted)
  Progress   $STATE_DIR/progress, and changes.log for --undo
  Logs       $LOG_DIR/run_<date>.log
             actions_<date>.txt: the commands shown for you
             duplicate_<date>.rman and .log, installer and root script output
  Editor     The settings open in \$EDITOR (default vi).

Exit codes
  0  Every step is OK
  1  Stopped, or some steps are not OK or skipped (normal for --check on a new server)
  2  Wrong option or unknown step
EOF
}

valid_step() { local i; for i in "${HELP_IDS[@]}"; do [[ "$i" == "$1" ]] && return 0; done; return 1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --primary) [[ $# -ge 2 ]] && valid_value ip "$2" || { printf 'Missing or invalid value for --primary\n'; exit 2; }; CLI_IP=$2; shift ;;
      --user) [[ $# -ge 2 ]] && valid_value name "$2" && [[ "$2" != "root" ]] || { printf 'Missing or invalid value for --user. Give the Oracle software owner, not root.\n'; exit 2; }; CLI_USER=$2; shift ;;
      --check) MODE="check" ;;
      --settings) REVIEW_SETTINGS=1 ;;
      --status) STATUS_ONLY=1 ;;
      --show-changes) SHOW_CHANGES=all; [[ $# -ge 2 && "$2" =~ ^[0-9]+\.[0-9]+$ ]] && { SHOW_CHANGES=$2; shift; } ;;
      --undo) [[ $# -ge 2 ]] && valid_step "$2" || { printf 'Use --undo N.M with a step number. To list the steps:  --help-step all\n'; exit 2; }; UNDO_STEP=$2; shift ;;
      --from)
        [[ $# -ge 2 && "$2" =~ ^([1-9]|10)(\.[0-9]{1,2})?$ ]] || { printf 'Use --from N or --from N.M, for example --from 6.1\n'; exit 2; }
        FROM_STEP=$2
        if [[ "$FROM_STEP" == *.* ]]; then valid_step "$FROM_STEP" || { printf 'There is no step %s. To list the steps:  --help-step all\n' "$FROM_STEP"; exit 2; }
        else FROM_STEP="$FROM_STEP.0"; fi
        shift ;;
      --only) [[ $# -ge 2 && "$2" =~ ^([1-9]|10)$ ]] || { printf 'Use --only N, with N from 1 to 10\n'; exit 2; }; ONLY_PHASE=$2; shift ;;
      --help-step) [[ $# -ge 2 ]] || { usage; exit 2; }; HELP_STEP=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'Unknown option: %s\n\n' "$1"; usage; exit 2 ;;
    esac
    shift
  done
  [[ -n "$FROM_STEP" && -n "$ONLY_PHASE" ]] && { printf 'Use either --from or --only, not both.\n'; exit 2; }
  if [[ -n "$UNDO_STEP" && ( "$MODE" == "check" || $STATUS_ONLY -eq 1 || -n "$SHOW_CHANGES" || -n "$FROM_STEP" || -n "$ONLY_PHASE" || $REVIEW_SETTINGS -eq 1 ) ]]; then
    printf '%s\n' '--undo cannot be combined with other options. To see first what it would do:  --show-changes STEP'; exit 2
  fi
  # --settings alone: review the settings and stop (phase 1 only)
  [[ $REVIEW_SETTINGS -eq 1 && -z "$FROM_STEP" && -z "$ONLY_PHASE" ]] && ONLY_PHASE=1
  return 0
}
STATUS_ONLY=0; SHOW_CHANGES=""; UNDO_STEP=""

dir_safe() {
  # $1 directory: owned by root, not writable by others (it holds the lock, the settings, the password file copy)
  local o m; o=$(stat -c '%U' -- "$1" 2>/dev/null); m=$(stat -c '%a' -- "$1" 2>/dev/null)
  [[ "$o" == "root" && ! -L "$1" && "${m: -1}" =~ ^[0145]$ && "${m: -2:1}" =~ ^[0145]$ ]]
}

same_primary() {
  # $1 IP or host name: the same server as the saved primary (also when one is a name and the other the address)
  local n=${1,,} a b
  [[ "$n" == "${PRIMARY_IP,,}" || ( -n "$PRIMARY_HOST" && "$n" == "${PRIMARY_HOST,,}" ) ]] && return 0
  a=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'); b=$(getent ahostsv4 "$PRIMARY_IP" 2>/dev/null | awk '{print $1; exit}')
  [[ -n "$a" && "$a" == "$b" ]]
}
set_aside_state() {
  # the confirmations and records of a standby of another primary are kept aside, not used
  local tag=$1 sf
  [[ "$MODE" == "run" ]] || return 0
  for sf in existing_files_ok dup_attempt storage_clone_ok primary_pending; do
    [[ -e "$STATE_DIR/$sf" ]] && mv -f -- "$STATE_DIR/$sf" "$STATE_DIR/$sf.$tag"
  done
  [[ -s "$PROGRESS_FILE" ]] && mv -f -- "$PROGRESS_FILE" "$PROGRESS_FILE.$tag"
  declare -F load_progress >/dev/null && load_progress
  return 0
}
OLD_PRIMARY_UNIQUE=""
set_aside_old_primary() {
  # another primary: the settings, confirmations and records of the old one are kept aside, not used
  local tag=${PRIMARY_IP:-old}_$RUN_ID
  [[ "$MODE" == "run" && -f "$SETTINGS_FILE" ]] && cp -p "$SETTINGS_FILE" "$SETTINGS_FILE.$tag"
  set_aside_state "$tag"
  init_settings
  printf '  The saved settings are for another primary, so they are not used.%s\n' "$([[ "$MODE" == "run" ]] && printf ' A copy ends in .%s' "$tag")"
  _log WARN "saved settings for another primary set aside ($tag)"
}
reenter_primary() {
  # the IP or the ssh user was wrong: ask again (the saved settings of another primary are not used)
  local ip u
  while true; do
    ask "IP address or host name of the primary [$PRIMARY_IP]"
    ip=${ANSWER:-$PRIMARY_IP}
    valid_value ip "$ip" && [[ "$ip" != "h" ]] && break
    say "This is not a valid IP address or host name."
  done
  while true; do
    ask "OS user for ssh on the primary, the owner of the database [$PRIMARY_SSH_USER]"
    u=${ANSWER:-$PRIMARY_SSH_USER}
    valid_value name "$u" && [[ "$u" != "root" ]] && break
    say "This is not a valid user name. root is not allowed."
  done
  if [[ -n "$PRIMARY_HOST" ]] && ! same_primary "$ip"; then
    # maybe only another address of the same server: the records are set aside after step 1.3 only when the
    # database found there is another one
    OLD_PRIMARY_UNIQUE=$PRIMARY_UNIQUE
    [[ "$MODE" == "run" && -f "$SETTINGS_FILE" ]] && cp -p "$SETTINGS_FILE" "$SETTINGS_FILE.${PRIMARY_IP:-old}_$RUN_ID"
    init_settings; rm -f -- "$ACCEPTED_FILE" 2>/dev/null
    say "The saved settings are for another primary address. They are read again from the new one."
  fi
  PRIMARY_IP=$ip; PRIMARY_SSH_USER=$u
  _log INFO "primary=$PRIMARY_IP ssh_user=$PRIMARY_SSH_USER (entered again)"
  return 0
}

main() {
  parse_args "$@"
  if [[ -n "$HELP_STEP" ]]; then help_cli "$HELP_STEP"; exit 0; fi
  [[ $EUID -eq 0 ]] || { printf 'Run this script as root, on the standby server.\n'; exit 1; }
  cd / || exit 1
  os_info
  LOG_DIR=$(readlink -m -- "$LOG_DIR"); STATE_DIR=$(readlink -m -- "$STATE_DIR")
  { [[ -d "$LOG_DIR" ]] || install -d -m 750 "$LOG_DIR"; } && { [[ -d "$STATE_DIR" ]] || install -d -m 700 "$STATE_DIR"; } || { printf 'Cannot create %s or %s. Is the file system read-only or full?\n' "$LOG_DIR" "$STATE_DIR"; exit 1; }
  dir_safe "$STATE_DIR" || { printf '%s must belong to root, and others must not be able to write to it.\nIt holds the settings and copies of the password file.\n' "$STATE_DIR"; exit 1; }
  dir_safe "$LOG_DIR" || { printf '%s must belong to root, and others must not be able to write to it.\nroot writes the logs there.\n' "$LOG_DIR"; exit 1; }
  SETTINGS_FILE="$STATE_DIR/settings.conf"; ACCEPTED_FILE="$STATE_DIR/settings.accepted"; JOB_FILE="$STATE_DIR/job"
  PROGRESS_FILE="$STATE_DIR/progress"; LASTRUN_FILE="$STATE_DIR/last_run"; JOURNAL_FILE="$STATE_DIR/changes.log"
  if [[ $STATUS_ONLY -eq 1 || -n "$SHOW_CHANGES" ]]; then
    # read-only views: no lock, no log, no connection
    init_settings; [[ -f "$SETTINGS_FILE" ]] && load_settings soft >/dev/null 2>&1
    printf '\n  %sOracle Data Guard Standby Setup%s   %sversion %s%s\n' "$C_B" "$C_N" "$C_D" "$SCRIPT_VERSION" "$C_N"
    printf '  %s\n' "$(rule 70)"
    printf '  This server   %s\n' "$(hostname -s 2>/dev/null)"
    [[ -n "$PRIMARY_UNIQUE" ]] && printf '  Primary       %s on %s\n  Standby       %s\n' "$PRIMARY_UNIQUE" "${PRIMARY_HOST:-$PRIMARY_IP}" "${STANDBY_UNIQUE:-?}"
    if [[ $STATUS_ONLY -eq 1 ]]; then print_progress_board; [[ -s "$JOURNAL_FILE" ]] && printf '  Changes made on this server: %s --show-changes\n' "$SELF"; fi
    [[ -n "$SHOW_CHANGES" ]] && show_changes_cli "$([[ "$SHOW_CHANGES" == all ]] || printf '%s' "$SHOW_CHANGES")"
    exit 0
  fi
  # every run asks questions: without a terminal (nohup, cron, ssh without -t) it would fail later at a confusing point
  if ! { : < /dev/tty; } 2>/dev/null; then
    printf 'This script asks questions. Run it in an interactive terminal, for example:  ssh -t root@%s\n' "$(hostname -s 2>/dev/null)"
    exit 1
  fi
  # one run at a time (a second run would take over the ssh connection and the settings)
  exec 9> "$STATE_DIR/lock" || { printf 'Cannot open %s/lock\n' "$STATE_DIR"; exit 1; }
  if ! flock -n 9; then printf 'Another run of this script is active on this server. Wait for it to end, then try again.\n'; exit 1; fi
  LOG_FILE="$LOG_DIR/run_$RUN_ID.log"; : > "$LOG_FILE" && chmod 640 "$LOG_FILE" || { LOG_FILE=""; printf 'Cannot write the log in %s. Is the file system read-only or full?\n' "$LOG_DIR"; exit 1; }
  ACTIONS_FILE="$LOG_DIR/actions_$RUN_ID.txt"; : > "$ACTIONS_FILE" && chmod 640 "$ACTIONS_FILE" || { printf 'Cannot write in %s\n' "$LOG_DIR"; exit 1; }
  if [[ -n "$UNDO_STEP" ]]; then
    init_settings
    [[ -f "$SETTINGS_FILE" ]] || { printf 'There is no settings file (%s). This script has set up nothing here.\n' "$SETTINGS_FILE"; exit 1; }
    local lerr=""; load_settings soft >/dev/null 2>&1 || lerr=${LOAD_ERR:-cannot be read}
    if [[ -n "$lerr" || -z "$ORACLE_USER" || -z "$DB_HOME" || -z "$STANDBY_SID" ]]; then
      printf 'The settings in %s cannot be used: %s.\nThe undo needs them to find the standby. Fix them first:  %s --settings\n' "$SETTINGS_FILE" "${lerr:-a value is missing or invalid}" "$SELF"
      exit 1
    fi
    MODE=run; build_envs_if_possible
    _log START "dg_standby_setup.sh $SCRIPT_VERSION --undo $UNDO_STEP pid=$$"
    if undo_cli "$UNDO_STEP"; then exit 0; else exit 1; fi
  fi

  init_settings
  if [[ -f "$SETTINGS_FILE" ]]; then
    load_settings
    if [[ $SETTINGS_UPGRADED -eq 1 && "$MODE" == "run" ]]; then
      cp -p "$SETTINGS_FILE" "$SETTINGS_FILE.v3_$RUN_ID"
      _log INFO "old settings file kept as $SETTINGS_FILE.v3_$RUN_ID"
      # disks made by version 3 used ASMLib
      [[ -z "$ASM_METHOD" ]] && command -v oracleasm >/dev/null 2>&1 && [[ -n "$(oracleasm listdisks 2>/dev/null)" ]] && ASM_METHOD=asmlib
    fi
    if [[ -n "$CLI_IP" ]] && ! same_primary "$CLI_IP"; then
      set_aside_old_primary
      _log WARN "saved settings for another primary not used"
      [[ "$MODE" == "run" ]] && rm -f -- "$ACCEPTED_FILE"
    fi
  fi
  [[ -n "$CLI_IP" ]] && PRIMARY_IP=$CLI_IP
  [[ -n "$CLI_USER" ]] && PRIMARY_SSH_USER=$CLI_USER
  local first_run=0; [[ -n "$PRIMARY_SSH_USER" ]] || first_run=1
  [[ -n "$PRIMARY_SSH_USER" ]] || PRIMARY_SSH_USER=oracle
  _log START "dg_standby_setup.sh $SCRIPT_VERSION mode=$MODE from=${FROM_STEP:--} only=${ONLY_PHASE:--} pid=$$"

  printf '\n  %sOracle Data Guard Standby Setup%s   %sversion %s%s\n' "$C_B" "$C_N" "$C_D" "$SCRIPT_VERSION" "$C_N"
  printf '  %s\n' "$(rule 70)"
  printf '  This server   %s (the new standby)\n' "$(hostname -s 2>/dev/null)"
  printf '  Mode          %s\n' "$([[ "$MODE" == check ]] && printf 'check only (nothing is changed)' || printf 'setup')"
  printf '  Log           %s\n' "$LOG_FILE"
  printf '\n  The script never changes the primary itself. When the primary needs a change,\n'
  printf '  the commands are shown for you to run, and the script then checks the result.\n'
  printf '  %sAt each question: h shows help, q quits.%s\n' "$C_D" "$C_N"
  print_progress_board
  # a long job of an earlier run (installer, root script, RMAN) is waited for before anything else;
  # phase 4 alone works only with the primary and does not need to wait
  if [[ "$ONLY_PHASE" == "4" ]] && job_alive; then
    say "A long job is running: $JOB_TITLE (session $JOB_PID)."
    say "Phase 4 works only with the primary, so it does not wait for the job."
  else
    job_wait_step
  fi

  while [[ -z "$PRIMARY_IP" ]]; do
    ask "IP address or host name of the primary"
    valid_value ip "$ANSWER" && [[ "${ANSWER,,}" != "h" ]] && PRIMARY_IP=$ANSWER || say "This is not a valid IP address or host name."
  done
  if [[ $first_run -eq 1 && -z "$CLI_USER" ]]; then
    say "The ssh user must own the database on the primary and be able to run  sqlplus / as sysdba."
    while true; do
      ask "OS user for ssh on the primary [oracle]"
      ANSWER=${ANSWER:-oracle}
      valid_value name "$ANSWER" && [[ "$ANSWER" != "root" ]] && { PRIMARY_SSH_USER=$ANSWER; break; }
      say "This is not a valid user name. root is not allowed."
    done
  else
    say "ssh user on the primary: $PRIMARY_SSH_USER (another user: --user NAME)"
  fi
  _log INFO "primary=$PRIMARY_IP ssh_user=$PRIMARY_SSH_USER"

  local p
  for p in 1 2 3 4 5 6 7 8 9 10; do
    if [[ $p -gt 1 && -n "$ONLY_PHASE" && "$ONLY_PHASE" != "$p" ]]; then continue; fi
    if [[ $p -gt 1 && -n "$FROM_STEP" && $p -lt ${FROM_STEP%%.*} ]]; then continue; fi
    [[ $p -eq 4 && $PHASE4_FIRST -eq 1 ]] && continue      # done right after phase 1
    "phase_$p"
    [[ $p -eq 1 && $PHASE4_FIRST -eq 1 ]] && phase_4
  done
  CUR_STEP=""
  summary
  local id bad_n=0
  for id in "${STEP_ORDER[@]}"; do case "${STEP_RESULT[$id]}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL) ;; *) bad_n=$((bad_n + 1)) ;; esac; done
  write_last_run "$([[ $bad_n -eq 0 ]] && printf 'ended, every step OK' || printf 'ended, %s step(s) not OK' "$bad_n")"
  if [[ "$MODE" == "run" && $bad_n -eq 0 ]]; then
    if [[ -z "$ONLY_PHASE" ]] && [[ -z "$FROM_STEP" || "${FROM_STEP%%.*}" -le 9 ]] && [[ -n "${STEP_RESULT[10.1]:-}" ]]; then
      printf '\n  %sStandby setup is complete.%s  Daily check:  %s --only 10\n' "$C_G" "$C_N" "$SELF"
      printf '  Keep in mind:\n'
      printf '    - After a sys password change on the primary, copy the password file again:\n        %s --from 6.1\n' "$SELF"
      [[ -n "$TDE_INFO" ]] && printf '    - After a new TDE master key on the primary, copy the wallet again:\n        %s --from 6.3\n' "$SELF"
      if [[ -s "$JOURNAL_FILE" ]] && journal_entries "" "" | awk -F'|' '$5 == "PKG" && $6 ~ /preinstall/' | grep -q .; then
        printf '    - The preinstall package changed kernel settings (transparent huge pages).\n      Plan one reboot of this server.\n'
      fi
    elif [[ "$ONLY_PHASE" == "1" && $REVIEW_SETTINGS -eq 1 ]]; then
      printf '\n  %sSettings reviewed.%s  To continue the setup:  %s\n' "$C_G" "$C_N" "$SELF"
    elif [[ -n "$FROM_STEP" ]]; then
      printf '\n  %sAll steps from %s are OK.%s  To check every step once more:  %s --check\n' "$C_G" "${FROM_STEP%.0}" "$C_N" "$SELF"

    else
      printf '\n  %sPhase %s is OK.%s\n' "$C_G" "$ONLY_PHASE" "$C_N"
    fi
  fi
  [[ $bad_n -eq 0 ]]
}

main "$@"
