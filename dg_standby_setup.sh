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

readonly SCRIPT_VERSION="5.0"
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
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1;34m'; C_C=$'\e[36m'; C_M=$'\e[1;35m'; C_D=$'\e[2m'; C_W=$'\e[1m'; C_N=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_M=""; C_D=""; C_W=""; C_N=""
fi

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
  printf '%s | %-6s | %s\n' "$(ts)" "$1" "$2" | mask_pw >> "$LOG_FILE"
}

log_block() {
  [[ -n "$LOG_FILE" ]] || { cat > /dev/null; return 0; }
  {
    printf '%s | OUT    | --- %s ---\n' "$(ts)" "$1"
    sed 's/^/          /'
    printf '%s | OUT    | --- end ---\n' "$(ts)"
  } | mask_pw >> "$LOG_FILE"
}

say()  { printf '      %s\n' "$*"; _log INFO "$*"; }
ok()   { printf '      %s[ OK ]%s %s\n' "$C_G" "$C_N" "$*"; _log OK "$*"; }
WARN_LIST=()
warn() {
  _log WARN "$*"
  local w="[${CUR_STEP:-start}] $*" x
  for x in "${WARN_LIST[@]+"${WARN_LIST[@]}"}"; do [[ "$x" == "$w" ]] && return 0; done   # same warning again (a re-check): shown and listed once
  printf '      %s[WARN]%s %s\n' "$C_Y" "$C_N" "$*"
  WARN_COUNT=$((WARN_COUNT + 1)); WARN_LIST+=("$w")
}
bad()  { printf '      %s[FAIL]%s %s\n' "$C_R" "$C_N" "$*"; _log FAIL "$*"; }
todo() { printf '      %s[TODO]%s %s\n' "$C_M" "$C_N" "$*"; _log TODO "$*"; }
wait_msg() { printf '      %s[WAIT]%s %s\n' "$C_D" "$C_N" "$*"; _log WAIT "$*"; }

hint() {
  # explanations and advice: plain text, indented (questions are cyan, commands are in boxes)
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '             %s\n' "$line"
    _log HINT "$line"
  done
}

block() {
  # $1 = label (Plan/Using/Now), stdin = lines
  local label=$1 line first=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ $first -eq 1 ]]; then
      printf '      %s%-7s%s %s\n' "$C_W" "$label" "$C_N" "$line"; first=0
    else
      printf '              %s\n' "$line"
    fi
    _log "${label^^}" "$line"
  done
}

primary_note() {
  # what was done on the primary by this run (the duplicate is the only thing that works against it)
  if [[ ${DUP_RAN:-0} -eq 1 ]]; then printf 'On the primary this script ran only read-only commands and the RMAN duplicate you confirmed.'
  else printf 'This script changed nothing on the primary server.'; fi
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
  if [[ $STOPPED_BY_USER -eq 1 ]]; then printf '\n  %sStopped by you.%s %s\n' "$C_Y" "$C_N" "$(primary_note)"
  else printf '\n  %sStopped.%s %s\n' "$C_R" "$C_N" "$(primary_note)"; fi
  local rs=${RESUME_STEP:-$CUR_STEP}
  [[ "$rs" == *.x ]] && rs="${rs%.x}"
  if [[ -n "${UNDO_STEP:-}" ]]; then
    # an undo that stops half-way: what it did is in the journal; the step counts as not done when anything was undone
    if [[ ${UNDO_N_DONE:-0} -gt 0 ]] && declare -F record >/dev/null; then
      NOW="partly undone with --undo"; STEP_TITLE[$UNDO_STEP]=${STEP_TITLE[$UNDO_STEP]:-step}; record "$UNDO_STEP" UNDONE
    fi
    printf '  Undo stopped. What is left:  %s --show-changes %s\n' "$SELF" "$UNDO_STEP"
  elif [[ -n "$DETACHED_JOB" ]]; then
    printf '  %s. Do NOT start it again by hand.\n' "$DETACHED_JOB"
    printf '  See it:  %s --status     When it has ended, run  %s  (it records the result and goes on).\n' "$SELF" "$SELF"
  elif [[ ${NEXT_PRINTED:-0} -eq 1 ]]; then :
  elif [[ -n "$rs" && "$rs" != 1.* && "$rs" != *.* ]]; then
    printf '  Continue later:  %s --from %s\n' "$SELF" "$rs"
  elif [[ -n "$rs" && "$rs" != 1.* ]]; then
    printf '  Continue later from this step:  %s --from %s\n  Manual commands:  %s --help-step %s\n' "$SELF" "$rs" "$SELF" "$rs"
  elif [[ -n "$rs" ]]; then
    printf '  Manual commands:  %s --help-step %s\n' "$SELF" "$rs"
  fi
  [[ -n "$LOG_FILE" ]] && printf '  Log: %s\n' "$LOG_FILE"
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
  fatal "Stopped by signal $1 (terminal closed or kill). A long job (installer, root script, RMAN) keeps running by itself; run the script again later."
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
  # $1 = question. Result in ANSWER.
  while true; do
    if [[ "$1" == *"[h] help"* || -z "$CUR_STEP" ]]; then
      printf '      %s> %s%s ' "$C_C" "$1" "$C_N"
    else
      printf '      %s> %s%s %s(h = help)%s ' "$C_C" "$1" "$C_N" "$C_D" "$C_N"
    fi
    if ! IFS= read -r ANSWER < "$PROMPT_IN"; then
      printf '\n'; fatal "No input available for the question: $1
             Run the script in an interactive terminal (for example: ssh -t root@$(hostname -s 2>/dev/null))."
    fi
    _log ASK "$1  -> $ANSWER"
    case "${ANSWER,,}" in
      h|"?"|help) if [[ -n "$CUR_STEP" ]]; then show_help "$CUR_STEP" || true
                  else say "There is no help for this question. The options of the script: $SELF --help"; fi ;;
      *) return 0 ;;
    esac
  done
}

ask_default() {
  # $1 question, $2 default. Result in ANSWER (default when Enter).
  ask "$1 [$2]:"
  [[ -n "$ANSWER" ]] || ANSWER=$2
}

confirm() {
  ask "$1 [y/N]"
  [[ "${ANSWER,,}" == "y" || "${ANSWER,,}" == "yes" ]]
}

confirm_word() {
  # $1 question, $2 the word to type. Spaces around the answer are ignored; a word in capital letters
  # (DUPLICATE, IGNORE) is accepted in any case; a device name must be typed exactly. Three tries.
  local n a
  for n in 1 2 3; do
    ask "$1  Type $2 to continue (n = no):"
    a=${ANSWER//[[:space:]]/}
    [[ "$a" == "$2" ]] && return 0
    [[ "$2" =~ ^[A-Z]+$ && "${a^^}" == "$2" ]] && return 0
    [[ "${a,,}" == "n" || "${a,,}" == "no" ]] && return 1
    # an Enter by mistake does not stop an important step: it asks again
    if [[ -z "$a" ]]; then [[ $n -lt 3 ]] && say "Nothing typed. Type $2, or n to stop."; continue; fi
    if [[ $n -lt 3 ]]; then
      if [[ "$2" =~ ^[A-Z]+$ ]]; then say "You typed \"$a\". Type $2 (capital or small letters), or n to stop."
      else say "You typed \"$a\". Type exactly $2, or n to stop."; fi
    fi
  done
  return 1
}

ask_secret() {
  # $1 prompt. Result in SECRET.
  printf '      %s> %s%s ' "$C_C" "$1" "$C_N"
  IFS= read -rs SECRET < "$PROMPT_IN" || fatal "No input for: $1 (run the script in an interactive terminal, for example ssh -t)"
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
      _log JOB "the job '$JOB_TITLE' was stopped by a reboot"; say "The job '$JOB_TITLE' of an earlier run was stopped by a reboot (output: $JOB_OUT)."
      job_remove_keep
    fi
    rm -f -- "$JOB_FILE"; JOB_PID=""; JOB_KEEP=""; return 1
  fi
  if job_running "$JOB_PID"; then
    # the command itself has ended (its exit code is written); only programs it left behind still run
    [[ -n "$JOB_OUT" && -f "$JOB_OUT.rc" ]] || return 0
    if [[ "$JOB_LEFT_WARNED" != "$JOB_PID" ]]; then
      JOB_LEFT_WARNED=$JOB_PID
      warn "The job '$JOB_TITLE' has ended; programs it started are still running: $(pgrep -s "$JOB_PID" -l 2>/dev/null | head -n 5 | tr '\n' ' ')"
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
  say "The job '$JOB_TITLE' has ended (exit code ${rc:-unknown}). Its output: $JOB_OUT"
  # the passwords may not be known yet (the job is finished before step 1.5): mask again later
  [[ -z "$SYS_PW$ASM_PW" ]] && { install -d -m 700 "$STATE_DIR"; printf '%s\n' "$JOB_OUT" >> "$STATE_DIR/unmasked"; chmod 600 "$STATE_DIR/unmasked"; chmod 600 "$JOB_OUT" 2>/dev/null; }
  # the step that started the job records what the job did (journal lines carry that step)
  local cs=${CUR_STEP:-}; CUR_STEP=${JOB_STEP:-$cs}
  local jok=0; [[ "$rc" == "0" || ( "$rc" == "6" && ( "$JOB_TITLE" == *installer* || "$JOB_TITLE" == "Grid configuration tools"* ) ) ]] && jok=1
  case "$JOB_TITLE" in
    "RMAN duplicate")
      if grep -q 'Finished Duplicate Db' "$JOB_OUT" && ! grep -qE '^RMAN-0(3002|3009|3015)' "$JOB_OUT" && declare -F dup_success_record >/dev/null; then
        dup_success_record; say "The RMAN duplicate had finished: recorded."; jok=1
      else
        jok=0; install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/dup_attempt"
        say "The RMAN duplicate did NOT finish ($(grep -m1 -E '^(RMAN|ORA)-[0-9]+' "$JOB_OUT" 2>/dev/null || printf 'see its output')). Step 7.2 of a normal run shows the clean-up of THIS server."
      fi ;;
    "Grid installer"*|"Grid configuration tools"*|"Database installer"*)
      if [[ "$rc" == "0" || "$rc" == "6" ]] && declare -F installer_done_record >/dev/null; then
        installer_done_record "$JOB_TITLE"; say "'$JOB_TITLE' had finished without error: recorded."
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
  ask_choice "[w] keep watching   [d] leave it running and stop the script (run it again later: it waits for the job)" "wd"
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
  ( umask 077; : > "$out" ) || { bad "Cannot write $out"; return 1; }
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
    || warn "Cannot write $JOB_FILE: if this run stops, the next run will not know that $title is still running"
  JOB_PID=$jpid; JOB_TITLE=$title; JOB_OUT=$out; JOB_STEP=${CUR_STEP:-}
  _log JOB "start pid=$jpid $title -> $out"
  say "$title is running (process $jpid). Output: $out"
  if [[ $LONG_ADVICE_SHOWN -eq 0 ]]; then
    LONG_ADVICE_SHOWN=1
    say "It runs in its own session $jpid: a closed terminal does not stop it; the next run of the script waits for it."
    say "Ctrl+C asks whether to keep watching or to leave it running (the job itself goes on)."
    say "To stop the job itself: pkill -s $jpid   (a stopped installer or root script leaves a half-configured home)"
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
        say "... $title still running after $(( (SECONDS - t0) / 60 )) minutes: $(grep -cE 'restoring datafile|datafile copy complete|copying datafile' "$out" 2>/dev/null) datafile line(s) done so far (output: $out)"
      else
        say "... $title still running after $(( (SECONDS - t0) / 60 )) minutes (output: $(du -h -- "$out" 2>/dev/null | cut -f1) in $out)"
      fi
    fi
  done
  TAIL_PID=""
  wait "$bg" 2>/dev/null
  # the wrapper may have been killed while its command goes on: wait for the whole job
  n=0
  while job_running "$jpid"; do
    [[ $n -eq 0 ]] && say "Waiting for the rest of the job (session $jpid) to end ..."
    n=$((n + 1)); sleep 2
    if [[ $RL_INT -eq 1 ]]; then RL_INT=0; printf '\n'; job_detach_question "$title" "$jpid" "$out"; fi
    # the command has ended and only programs it started still run: do not wait for them
    if [[ -f "$out.rc" && $n -ge 30 ]]; then
      warn "$title has ended; programs it started keep running: $(pgrep -s "$jpid" -l 2>/dev/null | head -n 5 | tr '\n' ' ')"
      break
    fi
    if (( n % 300 == 0 )); then
      say "Programs of the job are still running after $((n * 2 / 60)) minutes: $(pgrep -s "$jpid" -l 2>/dev/null | head -n 5 | tr '\n' ' ')"
      ask_choice "[k] keep waiting   [c] continue without them (they keep running)" "kc"
      [[ "$ANSWER" == "c" ]] && break
    fi
  done
  n=0; while [[ ! -f "$out.rc" && $n -lt 50 ]]; do sleep 0.1; n=$((n + 1)); done
  local rc; rc=$(cat "$out.rc" 2>/dev/null); rm -f -- "$out.rc" "$JOB_FILE"; JOB_PID=""
  num "$rc" || { rc=1; bad "$title was stopped before it finished"; }
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
  say "backup: $b"
}
append_as() {
  # $1 user (empty or root = root), $2 file; stdin = text to add at the end (a missing final newline is added first)
  local u=${1:-root} f=$2 txt before=0 after=0 lead=0
  txt=$(cat)
  [[ -L "$f" ]] && { bad "$f is a symbolic link; not changed"; return 1; }
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
  [[ -L "$f" ]] && { bad "$f is a symbolic link; not changed"; return 1; }
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
  if [[ $m -lt 120 ]]; then printf '%s minutes' "$m"
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
  printf '\n%s==============================================================================%s\n' "$C_B" "$C_N"
  printf '%s PHASE %s  |  %s%s\n' "$C_B" "$1" "$2" "$C_N"
  printf '%s==============================================================================%s\n' "$C_B" "$C_N"
  _log PHASE "$1  $2"
}

ok_lines() {
  # ok for the first line, the other lines indented under it
  local l first=${1%%$'\n'*} rest=""
  [[ "$1" == *$'\n'* ]] && rest=${1#*$'\n'}
  ok "$first"
  [[ -n "$rest" ]] && while IFS= read -r l; do [[ -n "$l" ]] && say "       $l"; done <<< "$rest"
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
PHASE_TITLES=("" "Connect and read the primary" "This server (OS, users, disks, folders)" "Oracle software on this server" "Primary readiness (commands for the primary)" "Listener and tnsnames" "Password file and TDE wallet" "Standby instance (NOMOUNT) and login tests" "RMAN duplicate (the copy)" "Register, apply, shipping, start at boot" "Daily check (lag, gap, apply)")
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
  local p r col i open="" first=""
  printf '\n  %sWhere you are%s (results of earlier runs on this server)\n' "$C_W" "$C_N"
  for p in 1 2 3 4 5 6 7 8 9 10; do
    r=$(phase_done_result "$p")
    case "$r" in DONE) col=$C_G ;; OPEN) col=$C_Y ;; PARTLY) col=$C_C ;; *) col=$C_D ;; esac
    printf '  %sphase %2s  %-7s%s %s\n' "$col" "$p" "$r" "$C_N" "${PHASE_TITLES[$p]}"
  done
  local nopen=0
  for i in "${HELP_IDS[@]}"; do
    case "${LAST_RESULT[$i]:-}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|"") ;;
      *) nopen=$((nopen + 1))
         if [[ $nopen -le 8 ]]; then
           open+="$(printf '    %-5s %-15s %s  (%s)' "$i" "${LAST_RESULT[$i]}" "$(step_title_of "$i" 2>/dev/null | cut -c1-40)" "${LAST_WHEN[$i]:0:16}")"$'\n'
           [[ -n "${LAST_REASON[$i]:-}" ]] && open+="          ${LAST_REASON[$i]:0:100}"$'\n'
         fi
         [[ -n "$first" || "$i" == 1.* ]] || first=$i ;;
    esac
  done
  [[ $nopen -gt 8 ]] && open+="    ... and $((nopen - 8)) more"$'\n'
  if [[ -s "$LASTRUN_FILE" ]]; then
    local lr; lr=$(cat "$LASTRUN_FILE" 2>/dev/null)
    printf '  Last run: %s\n' "$lr"
  fi
  # a long job that still runs by itself (read-only look: pid and boot of the job file)
  if [[ -n "$JOB_FILE" && -s "$JOB_FILE" ]]; then
    local jp jt jo jk jb js
    IFS='|' read -r jp jt jo jk jb js < "$JOB_FILE" || true
    if [[ "$jb" == "$(boot_id)" ]] && job_running "$jp"; then
      printf '  %sRunning now: %s (session %s, started in step %s; output %s, %s)%s\n' "$C_C" "$jt" "$jp" "${js:-?}" "$jo" "$(du -h -- "$jo" 2>/dev/null | cut -f1)" "$C_N"
      printf '  Do not start it again by hand. When it has ended, run the script: it records the result.\n'
    else
      printf '  %sThe long job %s (step %s) has ended%s. Run the script to record its result.%s\n' "$C_Y" "$jt" "${js:-?}" "$( [[ -f "$jo.rc" ]] && printf ' (exit code %s)' "$(cat "$jo.rc" 2>/dev/null)")" "$C_N"
    fi
  fi
  if [[ -n "$open" ]]; then
    printf '  Steps of earlier runs that are not done:\n%s' "$open"
    [[ -n "$first" ]] && printf '  (a normal run checks every step again; to start at the first one:  %s --from %s)\n' "$SELF" "$first"
  elif [[ ! -s "$PROGRESS_FILE" ]]; then
    printf '  First run on this server. You will be asked: the primary IP and its Oracle OS user, the ssh password,\n'
    printf '  the sys password (step 1.5); with ASM also the disks (2.13) and a new ASM password (3.2); DUPLICATE (8.2).\n'
  fi
  printf '  Legend: DONE = every step OK   OPEN = a step is not done   PARTLY = some steps done   - = never ran\n'
  [[ -n "$open" ]] && printf '  Step results: UNDONE = taken back with --undo   RUNNING = its long job ran by itself   WAITS = an earlier step was not done\n                TODO / PROBLEM = from a --check run   SKIPPED / FAILED_SKIPPED = you went on without it\n'
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
  if is_optional "$1"; then say "Skipped (optional step; the standby works without it)."; record "$1" SKIPPED_OPTIONAL
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
  if no_skip "$1"; then say "How to do this step by hand (then answer r to check again):"
  else say "How to do this step by hand (then answer r to check again, or s to go on):"; fi
  show_help "$1" || true
}

print_commands() {
  # $1 where, $2 run as, stdin = commands
  local where=$1 how=$2 line cmds
  cmds=$(cat)
  printf '      %s+-- %s%s\n' "$C_M" "$where" "$C_N"
  printf '      %s|   run as: %s%s\n' "$C_M" "$how" "$C_N"
  printf '      %s|%s\n' "$C_M" "$C_N"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '      %s|%s   %s\n' "$C_M" "$C_N" "$line"
  done <<< "$cmds"
  printf '      %s+--------------------------------------------------------------%s\n' "$C_M" "$C_N"
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
    say "Please answer one of: $(sed 's/./& /g' <<< "$2")"
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
    wait_msg "A long job is still running: $JOB_TITLE (session $JOB_PID)."
    say "Its output: $JOB_OUT"
    say "Its programs: $(pgrep -s "$JOB_PID" -l 2>/dev/null | head -n 5 | tr '\n' ' ')"
    say "(To stop it: pkill -s $JOB_PID  - an installer or root script stopped half-way leaves a half-configured home.)"
    if [[ "$MODE" == "check" ]]; then
      # the steps the job works on (and all after them) cannot be judged while it runs: their clean-up plans would hit the job
      case "$JOB_TITLE" in "RMAN duplicate"*) JOB_BUSY_PHASE=7 ;; *) JOB_BUSY_PHASE=3 ;; esac
      JOB_BUSY_TEXT="'$JOB_TITLE' is still running (session $JOB_PID): checked after it has ended"
      say "Check mode: phase $JOB_BUSY_PHASE and later are not judged until the job has ended (they show WAITS)."
      return 0
    fi
    local main_prog
    main_prog=$(pgrep -s "$JOB_PID" -l 2>/dev/null | awk '{print $2}' | grep -E '^(rman|java|perl|unzip|runInstaller|gridSetup|root\.sh|sqlplus|opatch|opatchauto|oracle|setup)' | sort -u | paste -sd' ' -)
    if kill -0 "$JOB_PID" 2>/dev/null || [[ -n "$main_prog" ]]; then
      [[ -n "$main_prog" ]] && say "The job itself is still working ($main_prog)."
      ask_choice "[w] watch it until it ends (Ctrl+C stops watching)   [r] check again   [q] quit (it keeps running)" "wrq"
    else
      # the leader of the job is gone, other programs of its session remain
      ask_choice "[w] watch it until it ends (Ctrl+C stops watching)   [r] check again   [c] continue without it   [q] quit (it keeps running)" "wrcq"
    fi
    case "$ANSWER" in
      w) WATCH_STOP=0; trap 'WATCH_STOP=1' INT
         { tail -n 20 -f --pid=$$ -- "$JOB_OUT" 2>/dev/null | sed -u 's/^/        /'; } 9>&- &
         tp=$!; TAIL_PID=$tp
         while [[ $WATCH_STOP -eq 0 ]] && job_running "$JOB_PID" && [[ ! -f "$JOB_OUT.rc" ]]; do sleep 2; done
         sleep 1; pkill -P "$tp" 2>/dev/null; kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null; TAIL_PID=""
         trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT ;;
      c) if confirm_word "Continue without the job '$JOB_TITLE'?" "CONTINUE"; then
           _log JOB "user continues without the job $JOB_TITLE (session $JOB_PID)"
           job_finish_late; rm -f -- "$JOB_FILE"; JOB_PID=""; JOB_KEEP=""; return 0
         fi ;;
      q) DETACHED_JOB="'$JOB_TITLE' keeps running (session $JOB_PID, output $JOB_OUT)"; CUR_STEP=${JOB_STEP:-$CUR_STEP}
         user_stop "Stopped by you (the job keeps running; run the script again when it has finished)" ;;
    esac
  done
}

run_step() {
  local id=$1 kind0=$2 kind=$2 title=$3 checkfn=$4 dofn=${5:-}
  step_in_range "$id" || return 0
  STEP_ORDER+=("$id"); STEP_TITLE[$id]=$title; CUR_STEP=$id
  printf '\n  %s[%s]%s %s%s%s\n' "$C_B" "$id" "$C_N" "$C_W" "$title" "$C_N"
  _log STEP "[$id] $title"
  local rc drc acted=0 helped=0 opts w
  is_optional "$id" && say "(optional step: needed for switchover, not for the standby itself)"
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
        ok_lines "Done (by you). ${NOW}"; record "$id" DONE_BY_YOU
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
        elif [[ -n "$w" ]]; then wait_msg "Can be checked only after $w: $NOW"; record "$id" WAITS
        else bad "Problem: ${NOW:-unknown}"; [[ -n "$PLAN" ]] && printf '%s\n' "$PLAN" | block "Fix:"; record "$id" PROBLEM; fi
        return 0
      fi
      # the earlier step (or phase) was not done in this run and you went on: the waiters do not ask again
      if [[ -n "$w" && -n "${AUTO_WAIT[$w]:-}" ]]; then
        wait_msg "Waits for $w (not done in this run): $NOW"; record "$id" WAITS; AUTO_WAIT["step $id"]=1; return 0
      fi
      if [[ -n "$w" ]]; then
        bad "Cannot continue yet: $NOW"
        if [[ $NEED_SYS -eq 1 ]]; then say "The sys password is needed here: answer p to type it now."
        elif [[ "$w" == step* && "$wid" == 1.* ]]; then say "Step $wid can only be done by the script: answer q and run the script again."
        elif [[ "$w" == step* && -n "${STEP_RESULT[$wid]:-}" ]]; then say "Step $wid ended as ${STEP_RESULT[$wid]} in this run. Do it first (--help-step $wid shows how), then answer r; or s to go on without it."
        elif [[ "$w" == step* ]] && ! step_in_range "$wid"; then say "Step $wid is not done yet and is not part of this run: answer q, then run  $SELF --from $wid   (or without --from)"
        elif [[ "$w" == step* ]]; then say "Step $wid has to be done first (--help-step $wid shows how). Then answer r; or s to go on without it."
        else say "Phase $wid is not done: answer s to go on (the other steps that need it then wait without asking), or q and run  $SELF --from $wid"; fi
      else
        bad "Cannot continue automatically: ${NOW:-unknown}"
        if [[ -n "$PLAN" ]]; then printf '%s\n' "$PLAN" | print_commands "${MANUAL_WHERE:-ON THIS SERVER ($(hostname -s)) - you do it}" "${MANUAL_HOW:-root}"
        elif [[ $helped -eq 0 ]]; then how_by_hand "$id"; helped=1; fi
      fi
      opts="[r] check again   [s] skip (I do it myself)   [h] help   [q] quit"; local allowed="rshq"
      no_skip "$id" && { opts="[r] check again   [h] help   [q] quit"; allowed="rhq"; }
      if [[ $NEED_SYS -eq 1 ]]; then opts="[p] type the sys password now   $opts"; allowed+="p"; fi
      ask_choice "$opts" "$allowed"
      case "$ANSWER" in
        p) if d_1_5; then record 1.5 DONE; fi; continue ;;
        s) [[ -n "$w" ]] && AUTO_WAIT[$w]=1
           skip_record "$id" "Skipped by you. Make sure it is done before the steps that need it."; return 0 ;;
        q) [[ -n "$w" && -z "$RESUME_STEP" ]] && RESUME_STEP=$wid
           user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
        *) continue ;;
      esac
    fi
    # rc 1: something must be done
    [[ -n "$NOW" ]] && printf '%s\n' "$NOW" | block "Now:"
    if [[ "$kind" == "primary" || "$kind" == "manual" ]]; then
      local where how
      if [[ "$kind" == "primary" ]]; then where="ON PRIMARY ($PRIMARY_HOST) - you run it"; how=${PRIMARY_HOW_STEP:-$PRIMARY_HOW}
      else where=${MANUAL_WHERE:-"ON THIS SERVER ($(hostname -s)) - you do it"}; how=${MANUAL_HOW:-root}; fi
      [[ -n "$USING" ]] && printf '%s\n' "$USING" | block "Using:"
      [[ "$kind" == "primary" ]] && primary_pending_add "$id" "$PLAN_UNDO"
      { printf '%s\n' "$PLAN"; [[ -n "$PLAN_UNDO" ]] && printf -- '-- undo (if ever needed): %s\n' "$PLAN_UNDO"; } | print_commands "$where" "$how"
      if [[ "$MODE" == "check" ]]; then todo "Needed (check mode)"; record "$id" TODO; return 0; fi
      [[ $PRIMARY_BOX_NOTE -eq 0 ]] && { PRIMARY_BOX_NOTE=1; say "(Every command shown for the primary is also collected in $ACTIONS_FILE)"; }
      ask_choice "[r] I did it, check again   [s] skip (I do it later)   [h] help   [q] quit" "rshq"
      case "$ANSWER" in
        s) skip_record "$id" "Skipped by you."; return 0 ;;
        q) user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
        r) acted=1; say "Checking again ..."; continue ;;
      esac
    fi
    if [[ "$kind" == "check" ]]; then
      [[ -n "$PLAN" ]] && printf '%s\n' "$PLAN" | block "Fix:"
      if [[ "$MODE" == "check" ]]; then bad "Problem found (see Fix above)"; record "$id" PROBLEM; return 0; fi
      [[ $helped -eq 0 && -z "$PLAN" ]] && { how_by_hand "$id"; helped=1; }
      ask_choice "[r] check again   [s] skip (I do it myself)   [h] help   [q] quit" "rshq"
      case "$ANSWER" in
        s) skip_record "$id" "Skipped by you."; return 0 ;;
        q) user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
        *) continue ;;
      esac
    fi
    # kind auto (or ask: the do function asks its own question)
    printf '%s\n' "$PLAN" | block "Plan:"
    [[ -n "$USING" ]] && printf '%s\n' "$USING" | block "Using:"
    if [[ "$MODE" == "check" ]]; then todo "Would do the plan above (check mode)"; record "$id" TODO; return 0; fi
    if [[ "$kind" != "ask" ]]; then
      ask_choice "[y] do it   [s] skip (I do it myself)   [h] help   [q] quit" "yshq"
      case "$ANSWER" in
        y) ;;
        s) skip_record "$id" "Skipped by you. Type h at any question (or --help-step $id) to see the commands."; return 0 ;;
        q) user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
      esac
    fi
    _log DO "[$id] start"
    JOURNAL_STEP_ENTRIES=0
    drc=0; "$dofn" || drc=$?
    if [[ $drc -eq 3 ]]; then skip_record "$id" "Not started (your answer). Run the step again later: $SELF --from $id"; return 0; fi
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
        say "Done so far. One more thing has to be done by hand:"; acted=1; continue
      fi
      bad "The action ran, but the check still fails: ${NOW:-unknown}"
    else
      bad "The action did not complete."
    fi
    if [[ $DO_FAIL_STOP_ONLY -eq 1 ]]; then
      # a retry here would build on what the failed action left: the clean-up is in an earlier step
      DO_FAIL_STOP_ONLY=0
      record "$id" FAILED
      say "It cannot go on from here: the next run shows the clean-up of THIS server first (step 7.2)."
      while true; do ask_choice "[h] help   [q] quit" "hq"; [[ "$ANSWER" == "q" ]] && break; show_help "$id" || true; done
      user_stop "Stopped after the failed step $id"
    fi
    [[ $helped -eq 0 ]] && { how_by_hand "$id"; helped=1; }
    opts="[r] try again   [s] skip (I fix it myself)   [h] help   [q] quit"; local allowed2="rshq"
    no_skip "$id" && { opts="[r] try again   [h] help   [q] quit"; allowed2="rhq"; }
    [[ "$id" == "1.2" ]] && { opts="[r] try again   [i] another IP address or user   [h] help   [q] quit"; allowed2="rihq"; }
    ask_choice "$opts" "$allowed2"
    case "$ANSWER" in
      s) warn "Skipped by you after an error."; record "$id" FAILED_SKIPPED; [[ "$id" == 1.* ]] || AUTO_WAIT["step $id"]=1; return 0 ;;
      q) user_stop "Stopped by you" ;;
      h) show_help "$id" || true; continue ;;
      i) reenter_primary; continue ;;
      *) continue ;;
    esac
  done
}

summary() {
  local id r col n_ok=0 n_opt=0 n_done=0 n_skip=0 n_bad=0 n_todo=0 n_wait=0 n_prob=0 first_bad=""
  printf '\n%s================================ SUMMARY ================================%s\n' "$C_B" "$C_N"
  for id in "${STEP_ORDER[@]}"; do
    r=${STEP_RESULT[$id]:-"NOT_FINISHED"}
    case "$r" in
      OK) col=$C_G; n_ok=$((n_ok + 1)) ;;
      SKIPPED_OPTIONAL) col=$C_D; n_opt=$((n_opt + 1)) ;;
      DONE|DONE_BY_YOU) col=$C_G; n_done=$((n_done + 1)) ;;
      SKIPPED) col=$C_Y; n_skip=$((n_skip + 1)) ;;
      TODO) col=$C_M; n_todo=$((n_todo + 1)) ;;
      WAITS) col=$C_D; n_wait=$((n_wait + 1)) ;;
      RUNNING) col=$C_C; n_wait=$((n_wait + 1)) ;;
      PROBLEM) col=$C_R; n_prob=$((n_prob + 1)) ;;
      *) col=$C_R; n_bad=$((n_bad + 1)) ;;
    esac
    printf '  %-6s %s%-15s%s %s\n' "$id" "$col" "$r" "$C_N" "${STEP_TITLE[$id]}"
    case "$r" in
      OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|TODO) ;;
      *) [[ -n "${STEP_NOW[$id]:-}" ]] && printf '         %s%s%s\n' "$C_D" "${STEP_NOW[$id]:0:110}" "$C_N"
         [[ -n "$first_bad" ]] || first_bad=$id ;;
    esac
    _log SUM "$id $r ${STEP_TITLE[$id]}"
  done
  local el=$(( $(date +%s) - RUN_START ))
  if [[ "$MODE" == "check" ]]; then
    printf '\n  already correct: %s   to do: %s   waits for earlier steps: %s   problems: %s   warnings: %s   (%d min)\n' "$n_ok" "$n_todo" "$n_wait" "$((n_prob + n_bad))" "$WARN_COUNT" "$((el / 60))"
    printf '  Check mode changed nothing, so on a new server most steps are TODO or WAITS. That is normal.\n'
    printf '  TODO     = a normal run does it (or shows you the commands for the primary)\n'
    printf '  WAITS    = can be checked only after an earlier step is done (for example no users yet)\n'
    printf '  PROBLEM  = must be fixed: see the Fix / Problem lines of that step above\n'
  else
    printf '\n  already correct: %s   done now: %s   skipped: %s   optional skipped: %s   not OK: %s   warnings: %s   (%d min)\n' \
      "$n_ok" "$n_done" "$n_skip" "$n_opt" "$((n_bad + n_todo + n_wait + n_prob))" "$WARN_COUNT" "$((el / 60))"
    printf '  OK = was already correct   DONE = done now   DONE_BY_YOU = you did it, checked   SKIPPED = you skipped it\n'
    printf '  FAILED_SKIPPED = the action failed and you skipped it   NOT_FINISHED = the run stopped in this step\n'
    [[ $n_opt -gt 0 ]] && printf '  SKIPPED_OPTIONAL = an optional step you skipped (the standby works without it)\n'
    [[ " ${STEP_RESULT[*]+${STEP_RESULT[*]}} " == *" FAILED "* ]] && printf '  FAILED = the action failed; what to do next is in the Next line\n'
    [[ $n_wait -gt 0 ]] && printf '  WAITS = needs a step that was not done in this run; checked again in the next run   RUNNING = its long job goes on by itself\n'
  fi
  if [[ ${#WARN_LIST[@]} -gt 0 ]]; then
    printf '  Warnings:\n'; local x; for x in "${WARN_LIST[@]}"; do printf '    - %s\n' "$x"; done
  fi
  declare -F journal_run_summary >/dev/null && journal_run_summary
  printf '  Log: %s\n' "$LOG_FILE"
  [[ -s "$ACTIONS_FILE" ]] && printf '  Commands shown for primary/manual work: %s\n' "$ACTIONS_FILE"
  printf '  %s\n' "$(primary_note)"
  if [[ "$MODE" == "check" ]]; then
    [[ $((n_todo + n_prob + n_bad)) -gt 0 ]] && printf '  Next: fix the PROBLEM steps (if any), then run the script without --check:  %s\n' "$SELF"
  else
    local nc; nc=$(next_cmd)
    if [[ -n "$nc" ]]; then
      NEXT_PRINTED=1
      if [[ "$nc" == *" --from "*.* ]]; then printf '  Next: continue with  %s   (--help-step %s shows the manual commands)\n' "$nc" "${nc##* }"
      elif [[ "$nc" == "$SELF" ]]; then printf '  Next: run  %s   (it checks every step; the steps already done pass quickly)\n' "$nc"
      else printf '  Next: continue with  %s\n' "$nc"; fi
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
    NOW=""; PLAN=""; PLAN_UNDO=""; USING=""; KIND_NOW=""; PRIMARY_HOW_STEP=""; NEED_SYS=0; CUR_STEP=$id
    "$cf" >/dev/null 2>"$BATCH_ERR"; rc=$?
    [[ -s "$BATCH_ERR" && "$BATCH_ERR" != /dev/null ]] && log_block "quiet check $id (stderr)" < "$BATCH_ERR"
    [[ $rc -eq 1 && -n "$PLAN" && "${KIND_NOW:-primary}" == "primary" ]] || continue
    primary_pending_add "$id" "$PLAN_UNDO"
    [[ "$id" == "4.1" ]] && in41=1; [[ "$id" == "4.7" ]] && in47=1
    n=$((n + 1))
    [[ -n "$how" ]] || how=${PRIMARY_HOW_STEP:-$PRIMARY_HOW}
    all+="-- [$id] ${STEP_TITLE_HINT[$id]:-}"$'\n'"$PLAN"$'\n'"${PLAN_UNDO:+-- undo (if ever needed): $PLAN_UNDO}"$'\n\n'
  done
  CUR_STEP=""
  exec {BATCH_TTY}>&-; BATCH_TTY=""
  # warnings of the quiet checks are shown here (the steps do not repeat them)
  local wi; for ((wi = wbefore; wi < ${#WARN_LIST[@]}; wi++)); do printf '      %s[WARN]%s %s\n' "$C_Y" "$C_N" "${WARN_LIST[$wi]#\[*\] }"; done
  [[ $n -ge 2 ]] || return 0
  printf '\n  %s%s steps of this phase need commands on the primary (SQL, unless a line says SHELL). All of them together:%s\n' "$C_W" "$n" "$C_N"
  say "(Run them in this order. Each step is checked again afterwards; a step that is not done asks again by itself."
  say " The file changes on the primary (steps 4.9 to 4.11, if needed) come after this box, one by one.)"
  CUR_STEP="${1%%.*}.x"
  printf '%s' "${all%$'\n\n'}" | print_commands "ON PRIMARY ($PRIMARY_HOST) - you run it" "$how"
  CUR_STEP=""
  PRIMARY_BOX_NOTE=1; say "(The same commands are in $ACTIONS_FILE)"
  if [[ $in41 -eq 1 && $in47 -eq 1 ]]; then
    if grep -q 'create spfile from memory' <<< "$all"; then say "(4.1 first, with its restart: the scope=spfile lines of the other steps work only when the primary runs from the spfile.)"
    else say "(4.1 and 4.7 both need a restart of the primary: run the 4.7 line before the shutdown of 4.1, then one restart covers both.)"; fi
  fi
  ask_choice "[r] I did them, check every step   [o] one step at a time instead   [q] quit" "roq"
  case "$ANSWER" in
    q) [[ $PHASE4_FIRST -eq 0 && -z "$ONLY_PHASE" ]] && RESUME_STEP=$1; user_stop "Stopped by you" ;;
    r) say "Checking the steps one by one ..." ;;
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
    [[ $JOURNAL_WARNED -eq 1 ]] || { JOURNAL_WARNED=1; warn "Cannot write the change journal $JOURNAL_FILE (disk full?): changes of this run may be missing in --show-changes / --undo"; }
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
    APPEND)     printf 'auto: cut the added %s bytes off the end of %s again' "$(detail_field "$det" len)" "$obj" ;;
    EDIT)       b=$(detail_field "$det" bak)
                if [[ -n "$b" && "$b" != "-" ]]; then printf 'auto: put back the copy %s' "$b"; else printf 'rewritten without an exact backup copy of the state before: compare %s with its .bak_ copies (if any) and fix it by hand' "$obj"; fi ;;
    RENAME)     printf 'auto: rename %s back to %s' "$(detail_field "$det" to)" "$obj" ;;
    DIR)        printf 'auto: remove the folder %s (only when it is empty)' "$obj" ;;
    GROUP)      printf 'by hand: groupdel %s   (only when no file and no user uses it)' "$obj" ;;
    USER)       printf 'by hand: userdel -r %s   (removes the home folder of the user too)' "$obj" ;;
    USERMOD)    printf 'by hand: the groups of %s were changed (%s); set them back with usermod if needed' "$obj" "$det" ;;
    PKG)        printf 'by hand (usually not wanted): %s remove %s' "$PKG" "$obj" ;;
    FWPORT)     printf 'auto: firewall-cmd --permanent --zone=%s --remove-port=%s ; firewall-cmd --reload' "${obj%%:*}" "${obj#*:}" ;;
    SERVICE)    printf 'left as it is: %s was enabled and started (a time service is wanted on every server)' "$obj" ;;
    ASMCFG)     printf 'by hand: oracleasm configure -d ; systemctl disable oracleasm   (only when no ASM disk uses ASMLib)' ;;
    SETTING)    printf 'in the settings file: %s' "$det" ;;
    PART)       printf 'by hand, ONLY if the disk is in no ASM disk group: wipefs -a %s ; wipefs -a %s   (%s)' "$(part_name "$obj")" "$obj" "$det" ;;
    ASMLABEL)   if [[ "$(asm_method 2>/dev/null)" == "asmlib" ]]; then printf 'by hand, ONLY if +%s is dropped: oracleasm deletedisk %s' "${obj%_*}" "$obj"
                else printf 'by hand, ONLY if +%s is dropped: remove the line with SYMLINK+="oraasm/%s" from %s ; udevadm control --reload-rules ; udevadm trigger' "${obj%_*}" "$obj" "$UDEV_RULES"; fi
                printf '   and remove the line %s| from %s' "$obj" "$(asm_disks_file 2>/dev/null)" ;;
    UNZIP)      printf 'by hand, ONLY after the SOFTWARE undo of this home (or when it was never installed): rm -rf %s' "$obj" ;;
    SOFTWARE)   if [[ "$obj" == "${GRID_HOME:-/nonexistent}" ]]; then printf 'by hand, after the GRIDCONFIG undo (step 3.3): as %s  %s/deinstall/deinstall' "$GRID_USER" "$obj"
                else printf 'by hand: as the owner  %s/deinstall/deinstall   (removes the Oracle home %s from the inventory and the disk)' "$obj" "$obj"; fi ;;
    ROOTSH)     printf 'nothing separate: it belongs to the home %s and goes with its SOFTWARE undo (deinstall)' "$obj" ;;
    GRIDCONFIG) printf 'by hand: as root  %s/crs/install/roothas.sh -deconfig -force   then the SOFTWARE undo of the Grid home' "$obj" ;;
    ASMINST)    printf 'by hand: the ASM instance and +%s were created by the Grid configuration; roothas.sh -deconfig -force (GRIDCONFIG undo) removes them; the disks keep their ASM headers' "$obj" ;;
    DISKGROUP)  printf 'by hand, destroys everything in it: as %s  export ORACLE_HOME=%s ORACLE_SID=+ASM ; $ORACLE_HOME/bin/sqlplus / as sysasm  ->  drop diskgroup %s including contents;' "$GRID_USER" "$GRID_HOME" "$obj" ;;
    ROOHCTL)    printf 'left as it is: the home %s was made read/write (roohctl -disable); roohctl -enable would make it read-only again' "$obj" ;;
    LSNRRES)    printf 'auto: srvctl stop listener -listener %s ; srvctl remove listener -listener %s   (as %s)' "$obj" "$obj" "$GRID_USER" ;;
    LSNRPORT)   printf 'auto: srvctl modify listener -listener %s -endpoints TCP:%s ; stop and start it   (the port before the change)' "$obj" "$(detail_field "$det" old)" ;;
    LSNRSTART)  printf 'auto: lsnrctl stop %s   (as %s)' "$obj" "$(lsnr_user 2>/dev/null || printf '%s' "$ORACLE_USER")" ;;
    INSTANCE)   printf 'auto: shut the instance %s down (srvctl stop database when it is registered, else shutdown immediate)' "$obj" ;;
    DUPLICATE)  printf 'by hand: see  %s --help-step 8.2  (shutdown abort, then remove the files of %s on THIS server only - never the files of the primary)' "$SELF" "$obj" ;;
    DUPLICATE_DONE) printf 'the copied standby database %s: see the DUPLICATE line above' "$obj" ;;
    SRVCTL)     printf 'auto: srvctl stop database -db %s ; srvctl remove database -db %s -noprompt   (the database files stay)' "$obj" "$obj" ;;
    SRL)        printf 'auto: drop standby logfile group(s) %s on THIS server (apply stopped first, standby_file_management MANUAL for the drop)' "$det" ;;
    MRP)        printf 'auto: alter database recover managed standby database cancel' ;;
    UNIT)       if [[ "$obj" == *.timer ]]; then printf 'auto: systemctl disable --now %s  (the nightly clean-up stops; its files are removed by their own lines)' "$obj"
                else printf 'auto: systemctl disable %s  (the running standby is left running; its files are removed by their own lines)' "$obj"; fi ;;
    OPATCH)     printf 'by hand (only if wanted): rm -rf %s ; mv %s %s   (the OPatch of the media back)' "$obj" "$(detail_field "$det" old)" "$obj" ;;
    SRVCTL_OLD) printf 'by hand: the earlier registration of %s (srvctl config in the log of that run) can be added again with srvctl add database' "$obj" ;;
    RMANCFG)    local ov; ov=$(detail_field "$det" old); ov=${ov//\~/ }
                if [[ -z "$ov" || "$ov" == "-" ]]; then printf 'by hand (usually not wanted): as %s  rman target /  ->  CONFIGURE ARCHIVELOG DELETION POLICY CLEAR;' "$ORACLE_USER"
                else printf 'by hand (usually not wanted): as %s  rman target /  ->  CONFIGURE ARCHIVELOG DELETION POLICY %s;' "$ORACLE_USER" "$ov"; fi ;;
    PRIMARY)    printf 'on the PRIMARY, by hand, only after this standby no longer receives redo: %s' "$det" ;;
    *)          printf '%s' "$det" ;;
  esac
}

show_changes_cli() {
  # $1 step or empty
  local l seq t run step kind obj det n=0 last_step=""
  [[ -s "$JOURNAL_FILE" ]] || { printf 'No change is recorded yet (%s).\n' "$JOURNAL_FILE"; return 0; }
  journal_load_undone
  printf 'Changes made by %s (%s)\n' "$(basename "$SELF")" "$JOURNAL_FILE"
  printf 'auto = "%s --undo STEP" can undo it;  by hand = commands for you;  PRIMARY = you ran it on the primary\n' "$(basename "$SELF")"
  while IFS= read -r l; do
    IFS='|' read -r seq t run step kind obj det <<< "$l"
    [[ "$step" != "$last_step" ]] && { printf '\n[%s] %s\n' "$step" "$(step_title_of "$step")"; last_step=$step; }
    printf '  %4s  %s  %-10s %s\n' "$seq" "${t:0:16}" "$kind" "$obj"
    printf '        undo: %s\n' "$(undo_text "$kind" "$obj" "$det")"
    n=$((n + 1))
  done < <(journal_entries "${1:-}")
  if [[ $n -eq 0 ]]; then [[ -n "${1:-}" ]] && printf 'No change is recorded for step %s.\n' "$1" || printf 'No change is recorded (or every change was taken back).\n'; fi
  return 0
}
journal_run_summary() {
  # the changes of THIS run, under the summary
  [[ "$MODE" == "run" && -s "$JOURNAL_FILE" ]] || return 0
  journal_load_undone
  local l seq t run step kind obj det n=0 lines=""
  while IFS= read -r l; do
    IFS='|' read -r seq t run step kind obj det <<< "$l"
    n=$((n + 1))
    [[ $n -le 12 ]] && lines+="    $step  $kind  $obj"$'\n'
  done < <(journal_entries "" "$RUN_ID")
  [[ $n -gt 0 ]] || return 0
  printf '  Changes made by this run (%s):\n%s' "$n" "$lines"
  [[ $n -gt 12 ]] && printf '    ... and %s more\n' "$((n - 12))"
  printf '  Every change with its undo:  %s --show-changes      undo one step:  %s --undo STEP\n' "$SELF" "$SELF"
  return 0
}

#---- undo ------------------------------------------------------------------
_undo_file_ok() {
  # $1 file, $2 recorded md5 of the whole file: 0 when the file is unchanged since the script wrote it (or the user accepts)
  local cur; cur=$(file_md5 "$1")
  [[ -n "$2" && "$cur" == "$2" ]] && return 0
  warn "$1 was changed after this script wrote it."
  confirm "Undo anyway (the later change is lost)?"
}
_hint_after_restore() {
  case "$1" in
    */network/admin/listener.ora) say "Then reload the listener:  lsnrctl reload   (as $(lsnr_user 2>/dev/null || printf '%s' "$ORACLE_USER"))" ;;
    /etc/security/limits.d/*)     say "Limits apply at the next login of the users." ;;
    /etc/udev/rules.d/*)          say "Then:  udevadm control --reload-rules ; udevadm trigger" ;;
    /etc/systemd/system/*)        systemctl daemon-reload 2>/dev/null || true ;;
    */.bash_profile)              say "Applies at the next login of that user." ;;
  esac
  return 0
}
_db_registered() { use_grid && [[ -x "$DB_HOME/bin/srvctl" ]] && run_logged "srvctl config" as_oracle "$DB_HOME/bin/srvctl" config database -db "$STANDBY_UNIQUE" >/dev/null 2>&1; }
_undo_obj_ok() {
  # the journal is root-only, but its fields are checked again before anything is run with them
  local kind=$1 obj=$2 det=$3 x
  case "$kind" in
    NEW|APPEND|EDIT|RENAME|DIR)
      [[ "$obj" == /* ]] && v_path "$obj" || { bad "The journal line names an unusual path ($obj): not undone"; return 1; }
      [[ "$obj" == *"/../"* || "$obj" == *"/./"* || "$obj" == *"//"* || "$obj" == */.. || "$obj" == */. || "$obj" == */ ]] && { bad "The journal line names an unusual path ($obj): not undone"; return 1; }
      [[ "$kind" != DIR && -L "$obj" ]] && { bad "$obj is a symbolic link now: not undone"; return 1; }
      case "$obj" in /|/etc|/usr|/usr/*bin|/bin|/sbin|/lib*|/var|/opt|/home|/root|/boot|/dev|/proc|/sys|/tmp|/u0[0-9]) bad "$obj is a system folder: not undone"; return 1 ;; esac
      [[ "$kind" != DIR && -d "$obj" && ! -L "$obj" ]] && { bad "$obj is a folder; the journal line is for a file: not undone"; return 1; }
      if [[ "$kind" == EDIT ]]; then x=$(detail_field "$det" bak); [[ "$x" == "-" || ( "$x" == "$obj".bak_* && "${x#"$obj".bak_}" =~ ^[0-9]{8}_?[0-9]{6}$ ) ]] || { bad "The backup name $x does not belong to $obj: not undone"; return 1; }; fi
      if [[ "$kind" == RENAME ]]; then x=$(detail_field "$det" to); [[ ( "$x" == "$obj".pre_duplicate_* && "${x#"$obj".pre_duplicate_}" =~ ^[0-9_]+$ ) || ( "$x" == "$obj".failed_* && "${x#"$obj".failed_}" =~ ^[0-9_]+$ ) ]] || { bad "The renamed name $x does not belong to $obj: not undone"; return 1; }; fi ;;
    FWPORT) [[ "$obj" =~ ^[A-Za-z0-9_-]+:[0-9]+/tcp$ ]] || { bad "Bad firewall entry ($obj): not undone"; return 1; } ;;
    UNIT)   [[ "$obj" =~ ^[A-Za-z0-9_.@-]+\.(service|timer)$ ]] || { bad "Bad unit name ($obj): not undone"; return 1; } ;;
    LSNRRES|LSNRPORT|LSNRSTART) v_name "$obj" || { bad "Bad listener name ($obj): not undone"; return 1; } ;;
    SRVCTL) v_name "$obj" || { bad "Bad database name ($obj): not undone"; return 1; } ;;
    INSTANCE|MRP|SRL)
      # the line is for the standby of the current settings only (after a rename or a rebuild it is another database)
      [[ "$obj" == "$STANDBY_SID" ]] \
        || { bad "This line is for the instance $obj; the settings now are for $STANDBY_SID: not undone (do it by hand if still wanted)"; return 1; } ;;
  esac
  return 0
}
_srl_drop() {
  # $1 groups. standby_file_management=AUTO refuses the drop (ORA-01275): MANUAL for the drop, AUTO again in any case
  local g rc=0 have
  sql_local "select group#||'|'||status from v\$standby_log;" || { bad "Cannot read the standby logs ($(ora_errors "$SQL_OUT"))"; return 1; }
  have=$SQL_OUT
  local sfm="AUTO"; sql_local "select upper(value) from v\$parameter where name='standby_file_management';" && [[ "$(first_line)" == "MANUAL" ]] && sfm=MANUAL
  sql_local "alter system set standby_file_management=manual scope=memory;" || { bad "Cannot set standby_file_management=manual ($(ora_errors "$SQL_OUT"))"; return 1; }
  for g in $1; do
    num "$g" || continue
    grep -q "^$g|" <<< "$have" || { say "group $g is already gone"; continue; }
    if grep -q "^$g|ACTIVE" <<< "$have"; then
      bad "group $g is in use (ACTIVE: redo of the primary is written into it). Stop the shipping first (on the primary: alter system set log_archive_dest_state_<N of step 4.4>=defer scope=both; - the undo of step 9.5), then run this undo again."
      rc=1; continue
    fi
    local mem=""; sql_local "select member from v\$logfile where group#=$g and member like '/%' and rownum=1;" && mem=$(first_line)
    if sql_local "alter database drop standby logfile group $g;"; then
      say "standby logfile group $g dropped"
      [[ "$mem" == /* && "$mem" != */o1_mf_* && -e "$mem" ]] && say "Its file stays in the folder; remove it (as $ORACLE_USER):  [ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && rm -f $mem"
    else bad "drop of group $g failed ($(ora_errors "$SQL_OUT"))"; rc=1; fi
  done
  if [[ "$sfm" == AUTO ]]; then
    sql_local "alter system set standby_file_management=auto scope=memory;" || warn "standby_file_management is still MANUAL in memory: alter system set standby_file_management=auto scope=memory;"
  fi
  return $rc
}
_state_or_2() {
  # local_state that is not readable means "cannot check": never treated as done
  local_state
  case "$LSTATE" in NOSW|ERROR|"") bad "Cannot check the instance (settings or software not found: $LSTATE)"; return 2 ;; esac
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
      say "removed $obj"; _hint_after_restore "$obj"; return 0 ;;
    APPEND)
      [[ -f "$obj" ]] || { say "$obj is gone."; return 0; }
      local off len md5 cur_len tail_md5 u tmp
      off=$(detail_field "$det" off); len=$(detail_field "$det" len); md5=$(detail_field "$det" md5)
      num "$off" && num "$len" || return 1
      cur_len=$(stat -c '%s' -- "$obj")
      if [[ $cur_len -lt $((off + len)) ]]; then say "$obj is shorter than when the block was added; fix it by hand."; return 2; fi
      tail_md5=$(tail -c +$((off + 1)) -- "$obj" | head -c "$len" | md5sum | cut -d' ' -f1)
      if [[ "$tail_md5" != "$md5" ]]; then say "The block added to $obj is not there any more (the file was edited); fix it by hand."; return 2; fi
      # the udev rule of a disk that a disk group still uses must stay (the disk group would not mount any more)
      if [[ "$obj" == "${UDEV_RULES:-/nonexistent}" ]]; then
        local lab used_by=""
        for lab in $(tail -c +$((off + 1)) -- "$obj" | head -c "$len" | grep -oE 'SYMLINK\+="oraasm/[A-Za-z0-9_]+"' | sed 's#.*/##; s#"##'); do
          # removed only when proven unused: ASM must answer 0 (no answer = kept)
          if grid_sw_ok 2>/dev/null && sql_asm "select count(*) from v\$asm_disk where path like '%/$lab' and group_number > 0;" && [[ "$(first_line)" == "0" ]]; then :
          elif ! grid_sw_ok 2>/dev/null && [[ ! -e "$(asm_disk_dir 2>/dev/null)/$lab" ]]; then :
          else used_by+=" $lab"; fi
        done
        [[ -z "$used_by" ]] || { bad "ASM disk(s)$used_by may be in a disk group (or ASM cannot tell now): their udev rule stays. Drop the disk group first (see the ASMLABEL lines), with ASM running."; return 2; }
      fi
      u=$(stat -c '%U' -- "$obj")
      backup_file "$obj" "$u" || return 1
      # exactly the added bytes go; text before and after them stays (the newline added in front of the block stays
      # when more text follows it, so two lines are not glued together). The file is rewritten as its owner.
      [[ -L "$obj" ]] && { bad "$obj is a symbolic link now; not changed"; return 2; }
      local lead keep_nl=0; lead=$(detail_field "$det" lead)
      [[ "$lead" == "1" && $cur_len -gt $((off + len)) ]] && keep_nl=1
      tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
      { head -c "$off" -- "$obj"; [[ $keep_nl -eq 1 ]] && printf '\n'; tail -c +$((off + len + 1)) -- "$obj"; } > "$tmp" || { rm -f -- "$tmp"; return 1; }
      if [[ "$u" == "root" ]]; then cat "$tmp" > "$obj" || { rm -f -- "$tmp"; return 1; }
      else chmod 644 "$tmp"; runuser -u "$u" -- cp -- "$tmp" "$obj" || { rm -f -- "$tmp"; return 1; }; fi
      rm -f -- "$tmp"
      if [[ $off -eq 0 && ! -s "$obj" ]]; then rm -f -- "$obj"; say "$obj only held the added block: removed"
      else say "the block added to $obj was removed again"; fi
      _hint_after_restore "$obj"; return 0 ;;
    EDIT)
      b=$(detail_field "$det" bak); m=$(detail_field "$det" md5)
      [[ -n "$b" && "$b" != "-" ]] || { say "No exact backup copy for this change: compare $obj with its .bak_ copies and fix it by hand."; return 2; }
      [[ -f "$b" ]] || { bad "The backup copy $b is gone; fix $obj by hand."; return 2; }
      _undo_file_ok "$obj" "$m" || return 2
      cp -p --remove-destination -- "$b" "$obj" || return 1
      say "$obj put back from $b"; _hint_after_restore "$obj"; return 0 ;;
    RENAME)
      local to; to=$(detail_field "$det" to)
      [[ -f "$to" ]] || { say "$to is gone; nothing to rename back."; return 0; }
      [[ -e "$obj" ]] && { say "$obj exists again; the renamed copy $to is left as it is."; return 2; }
      mv -f -- "$to" "$obj" || return 1
      say "$to renamed back to $obj"; return 0 ;;
    DIR)
      [[ -d "$obj" ]] || { say "$obj is already gone."; return 0; }
      if rmdir -- "$obj" 2>/dev/null; then say "removed the empty folder $obj"; return 0; fi
      say "$obj is not empty; left as it is."; return 2 ;;
    FWPORT)
      run_cmds <<< "firewall-cmd --permanent --zone=${obj%%:*} --remove-port=${obj#*:}
firewall-cmd --reload" ;;
    UNIT)
      if [[ ! -f "/etc/systemd/system/$obj" ]] && ! systemctl cat "$obj" >/dev/null 2>&1; then say "$obj is already gone."; return 0; fi
      if [[ "$obj" == *.timer ]]; then
        # a timer is stopped too (it would fire every night); its files are removed by their own lines
        run_cmds <<< "systemctl disable --now $obj" || return 1
        systemctl daemon-reload 2>/dev/null || true
        say "$obj is stopped and disabled"; return 0
      fi
      run_cmds <<< "systemctl disable $obj" || return 1
      systemctl reset-failed "$obj" 2>/dev/null || true
      say "$obj is disabled (it will not start at boot; the standby itself was not stopped)"; return 0 ;;
    LSNRRES)
      run_logged "srvctl config listener" as_grid "$GRID_HOME/bin/srvctl" config listener -listener "$obj" >/dev/null 2>&1 || { say "listener $obj is not registered (already gone)"; return 0; }
      run_logged "srvctl stop listener" as_grid "$GRID_HOME/bin/srvctl" stop listener -listener "$obj" || true
      run_logged "srvctl remove listener" as_grid "$GRID_HOME/bin/srvctl" remove listener -listener "$obj" || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      say "listener $obj removed from Oracle Restart"; return 0 ;;
    LSNRPORT)
      local old; old=$(detail_field "$det" old); num "$old" || return 2
      run_logged "srvctl modify listener" as_grid "$GRID_HOME/bin/srvctl" modify listener -listener "$obj" -endpoints "TCP:$old" || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      run_logged "srvctl stop listener" as_grid "$GRID_HOME/bin/srvctl" stop listener -listener "$obj" || true
      run_logged "srvctl start listener" as_grid "$GRID_HOME/bin/srvctl" start listener -listener "$obj" || true
      say "listener $obj back on port $old"; return 0 ;;
    LSNRSTART)
      if run_logged "lsnrctl stop" as_lsnr timeout 120 "$(lsnr_home)/bin/lsnrctl" stop "$obj"; then say "listener $obj stopped"; return 0; fi
      grep -qE 'TNS-12541|TNS-12560|TNS-00511|No listener' <<< "$RUN_OUT" && { say "listener $obj was not running"; return 0; }
      bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1 ;;
    INSTANCE)
      _state_or_2 || return 2
      [[ "$LSTATE" == "IDLE" ]] && { say "Instance $obj is not running."; return 0; }
      if [[ "$LSTATE" == "MOUNTED" ]] && mrp_running; then
        warn "The standby is mounted and APPLYING redo. Shutting it down stops the apply (it continues when it is started again)."
        confirm "Shut it down anyway?" || return 2
      fi
      if _db_registered; then
        run_logged "srvctl stop database" as_oracle timeout 1800 "$DB_HOME/bin/srvctl" stop database -db "$STANDBY_UNIQUE" -stopoption immediate || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      else
        sql_local_long "shutdown immediate" || { bad "shutdown immediate failed ($(ora_errors "$SQL_OUT")); trying shutdown abort"; sql_local "shutdown abort" || return 1; }
      fi
      say "instance $obj is down"; return 0 ;;
    SRVCTL)
      run_logged "srvctl config" as_oracle "$DB_HOME/bin/srvctl" config database -db "$obj" >/dev/null 2>&1 || { say "$obj is not registered (already gone)"; return 0; }
      run_logged "srvctl status" as_oracle "$DB_HOME/bin/srvctl" status database -db "$obj" || true
      grep -q 'is running' <<< "$RUN_OUT" && { run_logged "srvctl stop" as_oracle timeout 1800 "$DB_HOME/bin/srvctl" stop database -db "$obj" -stopoption immediate || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }; }
      run_logged "srvctl remove" as_oracle "$DB_HOME/bin/srvctl" remove database -db "$obj" -noprompt || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      say "$obj removed from Oracle Restart (the database files are untouched)"; return 0 ;;
    SRL)
      _state_or_2 || return 2
      [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { bad "The standby must be mounted to drop standby logs (step 9.2)."; return 2; }
      local was_mrp=0
      if mrp_running; then was_mrp=1; sql_local "alter database recover managed standby database cancel;" || { bad "Cannot stop apply first"; return 1; }; fi
      local src=0; _srl_drop "$det" || src=1
      if [[ $was_mrp -eq 1 ]]; then
        warn "Redo apply was stopped for the drop and is NOT running now. Start it again:  $SELF --from 9.4   (or: alter database recover managed standby database disconnect;)"
      fi
      return $src ;;
    MRP)
      _state_or_2 || return 2
      [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { say "The standby is not mounted; apply is not running."; return 0; }
      sql_local "alter database recover managed standby database cancel;" || { grep -q 'ORA-16136' <<< "$SQL_OUT" && { say "apply was not running"; return 0; }; bad "cancel failed ($(ora_errors "$SQL_OUT"))"; return 1; }
      say "apply (MRP) stopped"; return 0 ;;
    *)  return 2 ;;
  esac
}

UNDO_QUIT=0; UNDO_N_DONE=0
undo_cli() {
  # $1 step id. Walks the journal of that step backwards. Needs the settings (no primary connection).
  # Returns 0 when every line was handled, 1 when a line failed or was left.
  local step=$1 l seq t run step2 kind obj det n=0 rc n_done=0 n_left=0
  [[ -s "$JOURNAL_FILE" ]] || { printf 'No change is recorded yet (%s).\n' "$JOURNAL_FILE"; return 0; }
  job_alive && { bad "A long job of an earlier run is still running ($JOB_TITLE). Wait for it, then try again."; return 1; }
  journal_load_undone
  local -a lines=(); mapfile -t lines < <(journal_entries "$step" | tac)
  [[ ${#lines[@]} -gt 0 ]] || { printf 'No change is recorded for step %s (see --show-changes).\n' "$step"; return 0; }
  printf '%sUndo of step %s%s  %s\n' "$C_B" "$step" "$C_N" "$(step_title_of "$step")"
  printf 'The changes are undone in the reverse order, one by one. Nothing on the primary is touched.\n'
  if later_steps_active "$step"; then
    local later; later=$(journal_entries | awk -F'|' -v s="$step" '$4 ~ /^[0-9]+\.[0-9]+$/ && $5 !~ /^(SERVICE|ROOHCTL|SETTING|DUPLICATE_DONE)$/ {split($4,a,"."); split(s,b,"."); if (a[1]*100+a[2] > b[1]*100+b[2]) print $4}' | sort -t. -k1,1n -k2,2n -u | paste -sd' ' -)
    warn "Later steps have changes that build on this one: $later. Undo them first (the last one first: --undo ${later##* }), or type UNDO to continue anyway."
    confirm_word "Undo step $step although later steps depend on it?" "UNDO" || { printf 'Undo not started.\n'; return 1; }
  fi
  CUR_STEP=$step
  for l in "${lines[@]}"; do
    IFS='|' read -r seq t run step2 kind obj det <<< "$l"
    n=$((n + 1))
    printf '\n  %s%s) %s %s%s   (run %s)\n' "$C_W" "$n" "$kind" "$obj" "$C_N" "$run"
    printf '     undo: %s\n' "$(undo_text "$kind" "$obj" "$det")"
    case "$kind" in
      NEW|APPEND|EDIT|RENAME|DIR|FWPORT|UNIT|LSNRRES|LSNRPORT|LSNRSTART|INSTANCE|SRVCTL|SRL|MRP)
        ask_choice "[y] undo it   [s] skip   [q] quit" "ysq"
        case "$ANSWER" in
          s) n_left=$((n_left + 1)); continue ;;
          q) UNDO_QUIT=1; n_left=$((n_left + 1)); break ;;
        esac
        rc=0; undo_one "$kind" "$obj" "$det" || rc=$?
        if [[ $rc -eq 0 ]]; then journal UNDONE "$seq" "$kind $obj"; ok "undone"; n_done=$((n_done + 1)); UNDO_N_DONE=$n_done
        else
          [[ $rc -eq 1 ]] && bad "could not undo this change (see the log)"
          if confirm "Mark this line as done by you (it is then no longer listed)?"; then journal UNDONE "$seq" "$kind $obj (by you)"; n_done=$((n_done + 1)); UNDO_N_DONE=$n_done
          else n_left=$((n_left + 1)); fi
        fi ;;
      SERVICE|ROOHCTL|SETTING|DUPLICATE_DONE)
        say "Nothing to do for this line." ;;
      *)
        say "This change is undone by hand (command above)."
        if confirm "Mark it as done by you?"; then journal UNDONE "$seq" "$kind $obj"; n_done=$((n_done + 1)); else n_left=$((n_left + 1)); fi ;;
    esac
  done
  # the progress board shows the step as not done any more
  if [[ $n_done -gt 0 ]] && declare -F record >/dev/null; then
    NOW="undone with --undo ($n_done change(s)$([[ $n_left -gt 0 ]] && printf '; %s left' "$n_left"))"; STEP_TITLE[$step]=$(step_title_of "$step"); record "$step" UNDONE
  fi
  if [[ $UNDO_QUIT -eq 1 ]]; then printf '\nUndo of step %s stopped by you. What is left:  %s --show-changes %s\n' "$step" "$SELF" "$step"
  elif [[ $n_left -gt 0 ]]; then printf '\nUndo of step %s finished (%s undone, %s left). %s --show-changes %s shows what is left.\n' "$step" "$n_done" "$n_left" "$SELF" "$step"
  else printf '\nUndo of step %s finished: every change of the step is taken back.\n' "$step"; fi
  [[ $n_done -gt 0 ]] && printf 'The step counts as not done now: a normal run (or  %s --from %s) does it again.\n' "$SELF" "$step"
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
    ip)        [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$v" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ;;
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
    LOAD_ERR="$SETTINGS_FILE must be a file owned by root and not writable by others"
    [[ "$soft" == "soft" ]] && return 1; fatal "$LOAD_ERR"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$line" != *=* ]]; then LOAD_ERR="Bad line (no KEY=VALUE): $line"; break; fi
    key=${line%%=*}; val=${line#*=}
    case "$key" in
      GRID_ZIP) key=GRID_MEDIA; SETTINGS_UPGRADED=1 ;;
      DB_ZIP)   key=DB_MEDIA;   SETTINGS_UPGRADED=1 ;;
    esac
    if [[ "$OLD_KEYS" == *" $key "* ]]; then DROPPED_KEYS+=" $key"; SETTINGS_UPGRADED=1; continue; fi
    spec=""
    for t in $SETTING_SPECS; do [[ "${t%%:*}" == "$key" ]] && spec=${t#*:}; done
    if [[ -z "$spec" ]]; then DROPPED_KEYS+=" $key"; continue; fi
    if ! valid_value "$spec" "$val"; then
      if is_standby_key "$key"; then LOAD_ERR="Invalid value: $key=$val"; break; fi
      continue        # a primary value is read again from the primary anyway
    fi
    printf -v "$key" '%s' "$val"
  done < "$SETTINGS_FILE"
  if [[ -n "$LOAD_ERR" ]]; then
    [[ "$soft" == "soft" ]] && return 1
    fatal "$SETTINGS_FILE: $LOAD_ERR   (fix or delete the file, then run again)"
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
  } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SETTINGS_FILE" || { rm -f -- "$tmp"; bad "Cannot write $SETTINGS_FILE (disk full?)"; return 1; }
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
      [[ -n "${!v}" ]] || { bad "Setting $v is empty"; bad_n=1; continue; }
    fi
    valid_value "$t" "${!v}" || { bad "Setting $v has an invalid value: ${!v}"; bad_n=1; }
  done
  for v in DB_HOME ORACLE_BASE GRID_HOME GRID_BASE INVENTORY_DIR; do
    case "${!v}" in /|/usr|/usr/*|/etc|/etc/*|/var|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/root|/home|/proc|/sys|/dev|/dev/*|/tmp)
      bad "$v points to a system folder: ${!v}"; bad_n=1 ;; esac
  done
  if [[ "$USE_GRID" == "yes" ]]; then
    [[ -n "$GRID_HOME" && -n "$GRID_BASE" ]] || { bad "GRID_HOME and GRID_BASE are needed (the primary uses ASM)"; bad_n=1; }
    # the standby uses the same paths as the primary: a layout that works on the primary is kept (only noted)
    [[ "$GRID_HOME/" != "$GRID_BASE/"* ]] || warn "GRID_HOME $GRID_HOME is inside GRID_BASE $GRID_BASE (as on primary; kept)"
    [[ "$GRID_HOME/" != "$ORACLE_BASE/"* ]] || warn "GRID_HOME $GRID_HOME is inside ORACLE_BASE $ORACLE_BASE (as on primary; kept)"
    [[ -n "$DATA_DG" ]] || { bad "DATA_DG (the first ASM disk group) is empty"; bad_n=1; }
  elif all_locs | grep -q '^+'; then
    bad "USE_GRID must be yes: the primary keeps files in ASM"; bad_n=1
  fi
  [[ "$DB_NAME" =~ [\$#] || "$PRIMARY_UNIQUE" =~ [\$#] ]] && { bad "Database names with \$ or # ($DB_NAME / $PRIMARY_UNIQUE) are not supported by this script"; bad_n=1; }
  [[ -n "$STANDBY_IP" && "$STANDBY_IP" != 127.* ]] || { bad "STANDBY_IP must be the network address of this server (not empty, not 127.x)"; bad_n=1; }
  [[ "$STANDBY_IP" != "$PRIMARY_IP" ]] || { bad "STANDBY_IP is the primary IP"; bad_n=1; }
  [[ "${STANDBY_HOST,,}" != "${PRIMARY_HOST,,}" ]] || { bad "STANDBY_HOST must differ from the primary host name"; bad_n=1; }
  if [[ "$STANDBY_IP" =~ ^[0-9.]+$ ]] && command -v ip >/dev/null 2>&1 && ! grep -qw -- "$STANDBY_IP" <<< "$(ip -o addr show 2>/dev/null)"; then
    bad "STANDBY_IP $STANDBY_IP is not an address of this server"; bad_n=1
  fi
  [[ "${PRIMARY_UNIQUE^^}" != "${STANDBY_UNIQUE^^}" ]] || { bad "Standby db_unique_name must differ from primary"; bad_n=1; }
  [[ "${PRIMARY_TNS,,}" != "${STANDBY_TNS,,}" ]] || { bad "The two TNS aliases must differ"; bad_n=1; }
  [[ ${#STANDBY_SID} -le 12 ]] || { bad "STANDBY_SID '$STANDBY_SID' is longer than 12 characters"; bad_n=1; }
  [[ "$STANDBY_SID" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || { bad "STANDBY_SID must start with a letter and use only letters, digits and _"; bad_n=1; }
  [[ ${#STANDBY_UNIQUE} -le 30 ]] || { bad "STANDBY_UNIQUE is longer than 30 characters"; bad_n=1; }
  [[ "$AUX_CHANNELS" =~ ^[0-9]+$ && "$AUX_CHANNELS" -ge 1 && "$AUX_CHANNELS" -le 16 ]] || { bad "AUX_CHANNELS must be 1-16"; bad_n=1; }
  [[ -z "$RU_DIR" || -d "$RU_DIR" ]] || { bad "RU_DIR $RU_DIR is not a folder"; bad_n=1; }
  if [[ -n "$RU_DIR" ]]; then
    [[ -n "$OPATCH_ZIP" && -f "$OPATCH_ZIP" ]] || { bad "RU_DIR needs OPATCH_ZIP: the newest OPatch zip (p6880880), the one in the base media is too old"; bad_n=1; }
  fi
  [[ -z "$OPATCH_ZIP" || -f "$OPATCH_ZIP" ]] || { bad "OPATCH_ZIP $OPATCH_ZIP is not a file"; bad_n=1; }
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
  local fmt='      %-22s %s\n' l
  printf '\n      %sPRIMARY (read from %s at every run)%s\n' "$C_W" "$PRIMARY_IP" "$C_N"
  printf "$fmt" "host" "$PRIMARY_HOST"
  printf "$fmt" "ORACLE_SID" "$PRIMARY_SID"
  printf "$fmt" "db_name / unique" "$DB_NAME / $PRIMARY_UNIQUE"
  printf "$fmt" "version / CDB" "$PRIMARY_VERSION / $PRIMARY_CDB"
  if [[ ${LSNR_ASSUMED:-0} -eq 1 ]]; then printf "$fmt" "service / port" "$PRIMARY_SERVICE / $PORT  (listener $LISTENER_NAME)  ASSUMED"; printf "$fmt" "" "(no running listener on primary offered the service: check them; correct them with e)"
  else printf "$fmt" "service / port" "$PRIMARY_SERVICE / $PORT  (listener $LISTENER_NAME)"; fi
  [[ -n "${DB_EDITION:-}" ]] && printf "$fmt" "edition" "$DB_EDITION"
  printf "$fmt" "database size" "$(human_mb "$PRIMARY_DB_MB")"
  printf "$fmt" "storage" "$(use_grid && printf 'ASM (Oracle Restart will be installed here)' || printf 'file system (no Grid needed here)')"
  while IFS= read -r l; do printf "$fmt" "" "${l%%:*}  ($(human_mb "${l##*:}"))"; done < <(loc_list)
  printf "$fmt" "recovery area" "${FRA_LOC:-not set}${FRA_LOC:+  ($FRA_MB MB on primary)}"
  printf "$fmt" "archive destination" "${ARCH_LOC:-not set}"
  printf "$fmt" "DB home" "$DB_HOME"
  use_grid && printf "$fmt" "Grid home" "$GRID_HOME"
  printf "$fmt" "Oracle base" "$ORACLE_BASE"
  use_grid && printf "$fmt" "Grid base" "$GRID_BASE"
  printf "$fmt" "inventory" "$INVENTORY_DIR"
  if single_owner; then printf "$fmt" "owner" "$ORACLE_USER ($ORACLE_UID) owns everything"
  else printf "$fmt" "users" "$ORACLE_USER ($ORACLE_UID)  $GRID_USER ($GRID_UID)"; fi
  printf "$fmt" "groups" "$GROUP_GIDS"
  printf "$fmt" "homes, users, paths" "the same here (fixed: RMAN copies the files without renaming)"
  printf '\n      %sSTANDBY (this server; you may change these: e)%s   (key in the settings file)\n' "$C_W" "$C_N"
  printf "$fmt" "host / IP" "$STANDBY_HOST / $STANDBY_IP   (STANDBY_HOST, STANDBY_IP)"
  printf "$fmt" "db_unique_name" "$STANDBY_UNIQUE   (STANDBY_UNIQUE)"
  [[ "$STANDBY_UNIQUE" == *_SB ]] && printf "$fmt" "" "(_SB, not _STBY: ORACLE_SID can have at most 12 characters)"
  printf "$fmt" "ORACLE_SID" "$STANDBY_SID   (STANDBY_SID)"
  printf "$fmt" "service" "$STANDBY_SERVICE   (STANDBY_SERVICE)"
  printf "$fmt" "TNS aliases" "$PRIMARY_TNS (primary)   $STANDBY_TNS (standby)   (PRIMARY_TNS, STANDBY_TNS)"
  printf "$fmt" "listener" "$SB_LSNR, port $PORT   (always LISTENER here; with Grid it is created by Grid)"
  printf "$fmt" "installer files" "${GRID_MEDIA:-}${GRID_MEDIA:+  }${DB_MEDIA:-found later (step 3.1)}   (GRID_MEDIA, DB_MEDIA)"
  [[ -n "$RU_DIR" ]] && printf "$fmt" "release update" "$RU_DIR (applied by the installer)   (RU_DIR, OPATCH_ZIP)"
  use_grid && printf "$fmt" "ASM disk method" "${ASM_METHOD:-decided in step 2.12}   (ASM_METHOD)"
  printf "$fmt" "RMAN channels" "$AUX_CHANNELS   (AUX_CHANNELS)"
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

v_name() { [[ "$1" =~ ^[A-Za-z0-9_.+-]+$ ]]; }
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
    [[ "$a" != -* ]] && { v_name "$a" || v_path "$a"; } || fatal "SAFETY STOP: invalid value for primary probe $p: $a"
  done
  case "$p" in
    host)        cmd='hostname -s; hostname -f' ;;
    oratab)      cmd='cat /etc/oratab' ;;
    orainst)     cmd='cat /etc/oraInst.loc' ;;
    olr)         cmd='cat /etc/oracle/olr.loc' ;;
    ps)          cmd='ps -eo pid,user:32,args' ;;
    exe)         num "$1" || fatal "SAFETY STOP: bad pid $1"; cmd="readlink /proc/$1/exe" ;;
    environ)     num "$1" || fatal "SAFETY STOP: bad pid $1"
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
    *) fatal "SAFETY STOP: unknown primary probe $p" ;;
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
  [[ $rc -eq 124 ]] && { printf 'no answer from the primary within %s s (%s)\n' "$PROBE_TIMEOUT" "$p" >> "$err"; PROBE_TIMED_OUT=1; warn "The primary did not answer in time ($p; limit 120 s on the primary, $PROBE_TIMEOUT s here); the result of this check is unknown."; }
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
  v_path "$src" || fatal "SAFETY STOP: invalid remote path $src"
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
    || fatal "SAFETY STOP: invalid primary SID/home/TNS_ADMIN"
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
  readonly_guard "$q" || { _log SAFETY "Blocked: $q"; fatal "SAFETY STOP: refused to send a non read-only statement to primary: $q"; }
  _prim_sqlplus "connect / as sysdba" "$q" "PRIMARY (read-only): ${q:0:150}"
}

prim_sql_as_sys() {
  # READ-ONLY query on primary, logging in as sys through the network ($1 = target).
  local target=$1 q=$2
  readonly_guard "$q" || fatal "SAFETY STOP: refused statement: $q"
  [[ "$target" =~ ^(//[A-Za-z0-9_.-]+:[0-9]+/[A-Za-z0-9_.-]+|[A-Za-z0-9_.-]+)$ ]] || fatal "SAFETY STOP: invalid target $target"
  _prim_sqlplus "connect sys/\"$SYS_PW\"@$target as sysdba" "$q" "PRIMARY sqlplus as sys@$target (read-only): ${q:0:120}"
}

ssh_diagnose() {
  # $1 = ssh error file. Says what is wrong and prints the commands that fix it.
  local e; e=$(cat "$1" 2>/dev/null)
  local u=$PRIMARY_SSH_USER ip=$PRIMARY_IP
  case "$e" in
    *"Permission denied"*)
      print_commands "ON PRIMARY ($ip) - check" "root  ->  shell" <<EOF
# The password of $u was refused (wrong password), or password login is off.
grep -iE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|AllowUsers|DenyUsers)' /etc/ssh/sshd_config
# PasswordAuthentication must be yes; if you change it:
systemctl restart sshd
# unlock / set the password if needed:
passwd $u
EOF
      ;;
    *"Connection refused"*)
      print_commands "ON PRIMARY ($ip) - check" "root  ->  shell" <<EOF
# Nothing listens on port 22: sshd is stopped
systemctl enable --now sshd
systemctl status sshd
EOF
      ;;
    *"timed out"*|*"No route to host"*|*"Network is unreachable"*)
      print_commands "ON PRIMARY ($ip) - check" "root  ->  shell" <<EOF
# The network or a firewall blocks port 22 between the servers
firewall-cmd --list-services
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload
EOF
      ;;
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
      print_commands "ON THIS SERVER ($(hostname -s)) - you do it" "root  ->  shell" <<EOF
# The saved host key of $ip is old (the primary was reinstalled?). Remove it, then try again:
ssh-keygen -R $ip
ssh $u@$ip hostname
EOF
      ;;
    *"Could not resolve hostname"*)
      say "The name $ip cannot be resolved here; start the script with the IP address:  $SELF --primary <IP>" ;;
    *)
      print_commands "ON THIS SERVER ($(hostname -s)) - test" "root  ->  shell" <<EOF
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
  say "ssh will ask the password of user $PRIMARY_SSH_USER on $PRIMARY_IP (it goes to ssh only)."
  say "If ssh asks to accept the host key of the primary, answer yes."
  # Only options that every OpenSSH since 6.7 knows (Oracle Linux 7 has 7.4, OL8 has 8.0).
  # -E: ssh writes its own error messages to a file, so they can be shown and logged.
  if ssh -E "$elog" -o ControlMaster=yes -o ControlPath="$SSH_CTL" -o ControlPersist=12h \
         -o ServerAliveInterval=60 -o ConnectTimeout=15 -o NumberOfPasswordPrompts=3 \
         -fN "$PRIMARY_SSH_USER@$PRIMARY_IP" < "$PROMPT_IN" 9>&-; then
    SSH_OPEN=1
  else
    bad "ssh connection to $PRIMARY_SSH_USER@$PRIMARY_IP failed"
    if [[ -s "$elog" ]]; then printf 'ssh said:\n'; sed 's/^/  /' "$elog"; fi | hint
    ssh_diagnose "$elog"
    log_block "ssh error output" < "$elog"
    return 1
  fi
  ssh_alive || { bad "ssh connection is not usable"; sed 's/^/  /' "$elog" | hint; return 1; }
  DONE_MSG="Connected to $PRIMARY_SSH_USER@$PRIMARY_IP (one connection, reused by all read-only checks)"
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
    ask "$1 (q = stop):"
    [[ "${ANSWER,,}" == "q" ]] && user_stop "Stopped by you"
    [[ "$ANSWER" =~ ^[0-9]{1,3}$ ]] && (( 10#$ANSWER >= 1 && 10#$ANSWER <= $2 )) && { ANSWER=$((10#$ANSWER)); return 0; }
    say "Please type a number from 1 to $2, or q."
  done
}

discover_primary() {
  local l
  DISC_NOTES=()
  [[ "$PRIMARY_SSH_USER" != "root" ]] || fatal "Use the Oracle software owner (for example oracle) for ssh, not root: --user oracle"
  # ---- host
  prim_probe host || { bad "Cannot run commands on primary"; return 1; }
  PRIMARY_HOST=$(sed -n '1p' <<< "$RUN_OUT" | tr -d '[:space:]')
  v_name "$PRIMARY_HOST" || { bad "Unexpected host name from primary: $PRIMARY_HOST"; return 1; }
  local ls; ls=$(hostname -s 2>/dev/null || hostname)
  if [[ "${PRIMARY_HOST,,}" == "${ls,,}" ]]; then
    fatal "The primary has the same host name ($PRIMARY_HOST) as this server. Data Guard needs two different host names.
             If this IS the primary: run the script on the standby server.
             If this server is a copy (clone) of the primary: give it its own name first, for example
               hostnamectl set-hostname <new name>      and fix /etc/hosts, then run the script again."
  fi
  ok "Primary host: $PRIMARY_HOST"
  if prim_probe now && num "$(head -n 1 <<< "$RUN_OUT")"; then
    PRIM_CLOCK_OFFSET=$(( $(head -n 1 <<< "$RUN_OUT") - $(date +%s) ))
    [[ ${PRIM_CLOCK_OFFSET#-} -gt 300 ]] && DISC_NOTES+=("The clocks differ by $PRIM_CLOCK_OFFSET seconds (primary minus this server). Fix time synchronization (step 2.10 here, chronyd on primary).")
  fi

  # ---- running instances and listeners
  prim_probe ps || { bad "Cannot list processes on primary"; return 1; }
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
    bad "No running database instance (ora_pmon_<SID>) on primary."
    printf 'The primary database must be running (OPEN) for this script.\nStart it on primary as oracle:  sqlplus / as sysdba   ->  startup\n' | hint
    return 1
  fi
  local pick=1 i saved_sid=$PRIMARY_SID
  if [[ ${#pm[@]} -gt 1 ]]; then
    pick=""
    # the database chosen in an earlier run is used again (--settings or a new primary IP start over)
    if [[ -n "$saved_sid" && $REVIEW_SETTINGS -eq 0 ]]; then
      for i in "${!pm[@]}"; do [[ "${pm[$i]%%:*}" == "$saved_sid" ]] && pick=$((i + 1)); done
      [[ -n "$pick" ]] && ok "Database $saved_sid (chosen in an earlier run; to choose another one: $SELF --settings)"
    fi
    if [[ -z "$pick" ]]; then
      say "Running databases on primary (SID, OS user):"
      for i in "${!pm[@]}"; do say "  $((i + 1))) ${pm[$i]%%:*}   (user ${pm[$i]##*:})"; done
      pick_from_list "Number of the database that gets the standby (1-${#pm[@]})" "${#pm[@]}"
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
    if [[ -z "$tab_home" ]]; then DISC_NOTES+=("/etc/oratab on primary has no line for $PRIMARY_SID (add: $PRIMARY_SID:$DB_HOME:N)")
    elif [[ "$tab_home" != "$run_home" ]]; then DISC_NOTES+=("/etc/oratab on primary says $tab_home for $PRIMARY_SID, but the database runs from $run_home"); fi
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
    [[ -n "$DB_HOME" ]] && DISC_NOTES+=("/etc/oratab on primary has no usable line for $PRIMARY_SID; its home $DB_HOME was found in the process environment / inventory (add to oratab: $PRIMARY_SID:$DB_HOME:N)")
  fi
  if [[ -z "$DB_HOME" ]]; then
    warn "The Oracle home of $PRIMARY_SID could not be found (no usable /etc/oratab line, process not readable, not in the inventory)."
    while true; do
      ask "Full path of the database ORACLE_HOME on primary (for example /u01/app/oracle/product/19.0.0/dbhome_1), or q to stop:"
      [[ "${ANSWER,,}" == "q" ]] && user_stop "Stopped by you"
      ANSWER=${ANSWER%/}
      if home_ok "$ANSWER" "$pmon_user"; then DB_HOME=$ANSWER; break; fi
      say "$ANSWER/bin/oracle does not exist on primary, or does not belong to $pmon_user (the user of the running instance)."
    done
  fi
  ok "Database: ORACLE_SID=$PRIMARY_SID  home=$DB_HOME"

  # ---- environment of the running database (true TNS_ADMIN); readable only as the DB owner
  PRIMARY_TNS_ADMIN=""
  if prim_probe environ "$DB_PMON_PID"; then
    PRIMARY_TNS_ADMIN=$(sed -n 's/^TNS_ADMIN=//p' <<< "$RUN_OUT" | head -n 1); PRIMARY_TNS_ADMIN=${PRIMARY_TNS_ADMIN%/}
    v_path "$PRIMARY_TNS_ADMIN" || PRIMARY_TNS_ADMIN=""
  fi

  # ---- edition: Data Guard needs Enterprise Edition (checked here, before anything is installed)
  prim_sql "select banner from v\$version where banner like 'Oracle%';" \
    || { bad "Cannot query the database on primary ($(ora_errors "$SQL_OUT"))"; printf 'The ssh user %s must be able to run:  sqlplus / as sysdba   (member of the dba group).\n' "$PRIMARY_SSH_USER" | hint; return 1; }
  local ban; ban=$(first_line)
  if [[ "$ban" == *"Enterprise Edition"* ]]; then DB_EDITION=EE
  elif [[ "$ban" == *"Standard Edition"* ]]; then DB_EDITION=SE2
  else DB_EDITION=EE; DISC_NOTES+=("Edition not recognised in '$ban'; assuming Enterprise Edition"); fi
  [[ "$DB_EDITION" == "EE" ]] || fatal "The primary is Standard Edition ($ban). Data Guard needs Enterprise Edition. This script cannot build a standby for it."

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
  prim_probe ids "$ORACLE_USER" "$GRID_USER" || { bad "Cannot read user ids on primary"; return 1; }
  parse_id_line "$(grep -m1 "^uid=[0-9]*($ORACLE_USER)" <<< "$RUN_OUT")"
  ORACLE_UID=$PID_UID; INSTALL_GROUP=$PID_PGROUP; local og=$PID_GROUPS
  parse_id_line "$(grep -m1 "^uid=[0-9]*($GRID_USER)" <<< "$RUN_OUT")"
  GRID_UID=$PID_UID; GRID_PGROUP=$PID_PGROUP; local gg=$PID_GROUPS
  num "$ORACLE_UID" && num "$GRID_UID" && [[ -n "$INSTALL_GROUP" ]] || { bad "Cannot parse 'id' output from primary"; return 1; }
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
  v_path "$ORACLE_BASE" || { bad "Cannot read ORACLE_BASE of $DB_HOME (orabase)"; return 1; }
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
    || { bad "Cannot query the database on primary ($(ora_errors "$SQL_OUT"))"; printf 'The ssh user %s must be able to run:  sqlplus / as sysdba   (member of the dba group).\n' "$PRIMARY_SSH_USER" | hint; return 1; }
  local role ver dom rac omode
  IFS='|' read -r DB_NAME PRIMARY_UNIQUE role PRIMARY_CDB ver dom rac omode <<< "$(first_line)"
  [[ "$role" == "PRIMARY" ]] || fatal "Database $PRIMARY_SID on $PRIMARY_HOST has role '$role', not PRIMARY. Stopping."
  [[ "$rac" != "TRUE" ]] || fatal "The primary is a RAC database (cluster_database=TRUE). This script builds a single-instance standby of a single-instance primary only."
  v_name "$DB_NAME" && v_name "$PRIMARY_UNIQUE" || { bad "Unexpected database name from primary: $DB_NAME / $PRIMARY_UNIQUE"; return 1; }
  [[ "$dom" == "-" ]] && dom=""; [[ -z "$dom" ]] || v_name "$dom" || dom=""; PRIMARY_DOMAIN=$dom
  DB_MAJOR=${ver%%.*}; num "$DB_MAJOR" || { bad "Unexpected version: $ver"; return 1; }
  [[ $DB_MAJOR -ge 12 ]] || fatal "Primary version is $ver. This script supports 12.1 and newer."
  PRIMARY_VERSION=$ver
  if [[ $DB_MAJOR -ge 18 ]] && prim_sql "select version_full from v\$instance;"; then PRIMARY_VERSION=$(first_line); fi
  v_name "$PRIMARY_VERSION" || PRIMARY_VERSION=$ver
  [[ "$omode" == READ\ WRITE* ]] || warn "Primary open mode is '$omode' (expected READ WRITE)."

  # ---- storage: every place with database files (also the standby redo logs) and how much is there
  local c="case when name like '+%' then upper(regexp_substr(name,'^[+][^/]+')) else substr(name,1,instr(name,'/',-1)-1) end"
  local cm="case when f.member like '+%' then upper(regexp_substr(f.member,'^[+][^/]+')) else substr(f.member,1,instr(f.member,'/',-1)-1) end"
  prim_sql "select loc||':'||round(sum(b)/1048576) from (select $c loc, bytes b from v\$datafile union all select $c, bytes from v\$tempfile union all select $cm, l.bytes from v\$logfile f, v\$log l where f.group#=l.group# union all select $cm, s.bytes from v\$logfile f, v\$standby_log s where f.group#=s.group# union all select $c, block_size*file_size_blks from v\$controlfile) group by loc;" \
    || { bad "Cannot read the database file locations ($(ora_errors "$SQL_OUT"))"; return 1; }
  LOCS=$(grep -E '^[+/][A-Za-z0-9_./-]*:[0-9]+$' <<< "$SQL_OUT" | paste -sd, -)
  [[ -n "$LOCS" ]] || { bad "Unexpected answer for the file locations: $(head -n 3 <<< "$SQL_OUT")"; return 1; }
  PRIMARY_DB_MB=$(loc_list | awk -F: '{s+=$2} END {print s+0}')
  # block size of the online logs (512 or 4096): the standby logs and their disks must support it
  PRIMARY_REDO_BS=512
  prim_sql "select max(blocksize) from v\$log;" && PRIMARY_REDO_BS=$(first_line | cut -d'|' -f1)
  num "$PRIMARY_REDO_BS" || PRIMARY_REDO_BS=512

  # ---- recovery area, archive destination, folders used by the instance
  read_arch_params || { bad "Cannot read parameters on primary"; return 1; }

  # ---- ASM or file system
  DATA_DG=""
  if [[ -n "$(asm_dgs)" ]]; then
    USE_GRID=yes
    [[ -n "$GRID_HOME" ]] || { bad "The primary uses ASM ($(asm_dgs | paste -sd' ' -)) but its Grid home was not found."; return 1; }
    [[ -n "$GRID_BASE" ]] || { bad "Cannot read ORACLE_BASE of $GRID_HOME (orabase)"; return 1; }
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
      DISC_NOTES+=("The Grid release could not be read on primary ($GRID_HOME/inventory/ContentsXML/comps.xml); assuming $GRID_REL like the database")
    fi
  else
    USE_GRID=no; GRID_REL=""
    # no ASM on the standby: no Grid; the listener runs from the database home
    GRID_HOME=""; GRID_BASE=""; GRID_USER=$ORACLE_USER; GRID_UID=$ORACLE_UID; GRID_PGROUP=$INSTALL_GROUP; GRID_GROUPS=""
  fi
  ok "Database: $DB_NAME / $PRIMARY_UNIQUE, PRIMARY, CDB=$PRIMARY_CDB, $PRIMARY_VERSION, $(human_mb "$PRIMARY_DB_MB")"
  ok "Storage: $(tr ',' ' ' <<< "$LOCS")${FRA_LOC:+, recovery area $FRA_LOC}"

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
  if [[ $found -eq 1 ]]; then ok "Listener $LISTENER_NAME ($PRIMARY_LISTENER_HOME) on port $PORT, service $PRIMARY_SERVICE"
  else
    LSNR_ASSUMED=1
    # values the admin corrected in the settings of an earlier run are kept
    if [[ -n "$sv_port" && -n "$sv_ln" && -n "$sv_svc" && ( "$sv_port" != "1521" || "$sv_ln" != "LISTENER" || "$sv_svc" != "$want" ) ]]; then
      PORT=$sv_port; LISTENER_NAME=$sv_ln; PRIMARY_SERVICE=$sv_svc; [[ -n "$sv_lh" ]] && PRIMARY_LISTENER_HOME=$sv_lh
      warn "No running listener on primary offers the service $want. Using your settings: $LISTENER_NAME, port $PORT, service $PRIMARY_SERVICE."
    else
      warn "No running listener on primary offers the service $want. Assuming LISTENER, port $PORT, service $want."
      say "If that is wrong, correct PORT / LISTENER_NAME / PRIMARY_SERVICE in the settings (step 1.4 shows them: choose e; later:  $SELF --settings)."
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
      case "$wn" in wallet_root) [[ "$wv" != "-" ]] && WALLET_ROOT=${wv%/}; [[ -z "$WALLET_ROOT" ]] || v_path "$WALLET_ROOT" || { DISC_NOTES+=("wallet_root on primary is '$WALLET_ROOT' (not a folder; the TDE wallet is copied by hand, step 6.3)"); WALLET_ROOT=""; } ;; tde_configuration) [[ "$wv" != "-" ]] && TDE_CONFIG=$wv ;; esac
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
  readonly_guard "$1" || fatal "SAFETY STOP: refused statement for primary: $1"
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
  [[ $EUID -eq 0 ]] || { NOW="Not running as root"; PLAN="Run the script as root"; return 1; }
  local t missing=()
  for t in runuser getent awk sed grep stat timeout install useradd groupadd usermod lsblk blkid cmp ssh scp paste md5sum df du comm mktemp setsid tail ip flock pgrep pkill unzip; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    NOW="Missing tools: ${missing[*]}"
    PLAN="${PKG:-yum} install -y util-linux coreutils shadow-utils openssh-clients gawk sed grep iproute diffutils procps-ng unzip"
    return 1
  fi
  local os="unknown"; os=$(. "$OS_RELEASE_FILE" 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")
  NOW="root on $(hostname -s), $os (package tool: $PKG), bash ${BASH_VERSION%%(*}, all tools present"
  if ! [[ "$OS_MAJOR" =~ ^[0-9]+$ && $OS_MAJOR -ge 7 ]]; then
    NOW+=$'\n'"This is not Oracle Linux / RHEL 7 or newer; packages and kernel settings may need work by hand"
    warn "Operating system $os is not Oracle Linux 7, 8 or 9 (continuing)"
  fi
  return 0
}

c_1_6() {
  # Oracle version and Oracle Linux version must be a supported pair (checked when the version is known)
  [[ $DISCOVERED -eq 1 ]] || { NOW="Primary configuration not read (step 1.3)"; return 2; }
  [[ "$OS_MAJOR" =~ ^[0-9]+$ ]] || { NOW="Operating system version unknown; not checked"; return 0; }
  local v=$PRIMARY_VERSION why="" r w
  # the database release, and the Grid release when there is Grid (Grid may be newer)
  for r in "$(want_rel)" ${GRID_REL:+"$GRID_REL"}; do
    w=""
    case "$r" in
      12.1) [[ $OS_MAJOR -ge 8 ]] && w="12.1 is certified on Oracle Linux 7 only."
            [[ "$v" == 12.1.0.1* && $OS_MAJOR -eq 7 ]] && w="12.1.0.1 is not certified on Oracle Linux 7 (only 12.1.0.2)." ;;
      12.2|18) [[ $OS_MAJOR -ge 8 ]] && w="$r is not certified on Oracle Linux $OS_MAJOR (there is no preinstall package and the installer stops). Use Oracle Linux 7 for this standby." ;;
      19)   [[ $OS_MAJOR -ge 9 && -z "$RU_DIR" ]] && w="19c on Oracle Linux 9 must be installed together with Release Update 19.19 or newer. Unzip that RU on this server (and the newest OPatch zip p6880880), then set RU_DIR and OPATCH_ZIP in the settings (answer s here; step 1.4 then shows the settings: choose e)." ;;
      21)   ;;
      *)    [[ $OS_MAJOR -le 7 ]] && w="$r needs Oracle Linux 8 or newer." ;;
    esac
    [[ -n "$w" ]] && why+="$w "
  done
  if use_grid && [[ -n "$GRID_REL" ]]; then
    local gm dm; gm=$(rel_major "$GRID_REL"); dm=$DB_MAJOR
    if [[ $gm -lt $dm || ( $gm -eq 12 && $dm -eq 12 && "${GRID_REL#12.}" < "${PRIMARY_VERSION:3:1}" ) ]]; then why+="Grid $GRID_REL is older than the database $v (the primary would not work like this either). "; fi
  fi
  why=${why% }
  if [[ -n "$why" ]]; then NOW="Oracle $v${GRID_REL:+ (Grid $GRID_REL)} on Oracle Linux $OS_MAJOR: $why"; PLAN="$why"; return 1; fi
  NOW="Oracle $v${GRID_REL:+ (Grid $GRID_REL)} on Oracle Linux $OS_MAJOR: supported"
  [[ "$DB_MAJOR" == "19" && $OS_MAJOR -ge 8 && -z "$RU_DIR" ]] && NOW+=$'\n'"19c base media is installed with CV_ASSUME_DISTID=OEL7.8 (needed for 19.3 on Oracle Linux 8+)"
  return 0
}

c_1_2() {
  if [[ -n "$PRIMARY_IP" ]] && command -v ip >/dev/null 2>&1 && grep -qw -- "$PRIMARY_IP" <<< "$(ip -o addr show 2>/dev/null)"; then
    fatal "This server owns $PRIMARY_IP, the primary IP you gave. Run the script on the standby server."
  fi
  if ssh_alive; then NOW="Connected to $PRIMARY_SSH_USER@$PRIMARY_IP"; return 0; fi
  if [[ "$MODE" == "check" ]]; then open_ssh && { NOW="Connected to $PRIMARY_SSH_USER@$PRIMARY_IP"; return 0; }; NOW="ssh failed (see above)"; return 2; fi
  NOW="Not connected to primary"
  PLAN="Open one ssh connection to $PRIMARY_SSH_USER@$PRIMARY_IP
ssh asks the password of $PRIMARY_SSH_USER (the script never sees it)
Only read-only commands are sent over this connection"
  USING="primary IP $PRIMARY_IP, user $PRIMARY_SSH_USER (another user: --user <name>)"
  return 1
}
d_1_2() { open_ssh; }

c_1_3() {
  if [[ $DISCOVERED -eq 1 ]]; then NOW="Primary configuration read ($PRIMARY_UNIQUE on $PRIMARY_HOST)"; return 0; fi
  need_ssh || { NOW="No ssh connection to primary (step 1.2)"; return 2; }
  if [[ "$MODE" == "check" ]]; then discover_primary && { NOW="Primary configuration read"; return 0; }; NOW="Reading the primary failed (see above)"; return 2; fi
  NOW="Primary configuration not read yet"
  PLAN="Read on primary (read-only, without its .bash_profile):
running instances and listeners (ps), the home of the running database,
/etc/oratab, /etc/oraInst.loc, owners and ids of the Oracle users, Oracle bases,
database name/role/version/storage/size (sqlplus / as sysdba, SELECT only),
listener port and service (lsnrctl status)"
  return 1
}
d_1_3() { discover_primary; }

SETTINGS_DIFF=""
c_1_4() {
  [[ $DISCOVERED -eq 1 ]] || { NOW="Primary configuration not read (step 1.3)"; return 2; }
  derive_standby_settings
  if [[ $SETTINGS_ACCEPTED -eq 1 ]]; then NOW="Settings accepted ($SETTINGS_FILE)"; return 0; fi
  local d rc=0
  d=$(accepted_diff) || rc=1
  # 1.6 found a value that must be set in the settings (for example RU_DIR): show them, do not accept silently
  if [[ $rc -eq 0 && -z "$d" && $REVIEW_SETTINGS -eq 0 && $SETTINGS_UPGRADED -eq 0 && "${STEP_RESULT[1.6]:-OK}" == OK ]] && validate_settings >/dev/null 2>&1; then
    SETTINGS_ACCEPTED=1
    NOW="Same settings as you accepted before ($SETTINGS_FILE)"$'\n'"To see or change them: $SELF --settings"
    return 0
  fi
  SETTINGS_DIFF=$d
  show_settings
  [[ $rc -eq 0 && -n "$d" ]] && { printf 'Changed since you accepted the settings last time:\n%s\n' "$d" | hint; _log INFO "settings changed: $(tr '\n' ';' <<< "$d")"; }
  if [[ $SETTINGS_UPGRADED -eq 1 ]]; then
    warn "The settings file was written by an older version of the script. It was converted; please check the values above.${DROPPED_KEYS:+ No longer used:$DROPPED_KEYS (disks are chosen in step 2.13).}"
  elif [[ -n "$DROPPED_KEYS" ]]; then
    warn "Unknown keys in $SETTINGS_FILE were ignored:$DROPPED_KEYS"
  fi
  if [[ "$MODE" == "check" ]]; then validate_settings && { NOW="Settings derived (not saved in check mode)"; return 0; }; NOW="Settings have problems (lines above)"; return 2; fi
  NOW="Settings shown above are not confirmed yet"
  PLAN="Use the values above for all next steps and save them to $SETTINGS_FILE
(a = accept, e = edit the standby values first)"
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
    ask_choice "[a] accept these settings   [e] edit them in an editor   [q] quit" "aeq"
    case "$ANSWER" in
      a)
        validate_settings || { bad "Fix the settings first (choose e)"; continue; }
        [[ ${ED_KEEP_FILE:-0} -eq 1 ]] && warn "Your last edit was not valid and is not used; the values shown before the edit are saved."
        save_settings; save_accepted; SETTINGS_ACCEPTED=1; SETTINGS_UPGRADED=0
        _log INFO "settings accepted"
        DONE_MSG="Settings saved to $SETTINGS_FILE"; return 0 ;;
      e)
        ed=$(pick_editor) || { bad "No editor found (vi, nano). Edit $SETTINGS_FILE by hand and run the script again."; continue; }
        [[ ${ED_KEEP_FILE:-0} -eq 1 ]] || save_settings
        ED_KEEP_FILE=0
        say "The file opens in $ed. Only the values under 'Standby values' can be changed (the standby uses the"
        say "same paths, users, groups and names as the primary: RMAN copies the files without renaming them)."
        [[ $LSNR_ASSUMED -eq 1 ]] && say "PORT, LISTENER_NAME and PRIMARY_SERVICE were assumed (no running listener offered the service): you may correct them."
        [[ "$ed" == vi* ]] && say "vi: press i to change text, Esc then :wq to save and close, Esc then :q! to close without saving."
        # what the primary told us: an edit of these values is not accepted
        local k snap="" old_unique=$STANDBY_UNIQUE old_sid=$STANDBY_SID old_svc=$STANDBY_SERVICE old_tns=$STANDBY_TNS
        for k in $(all_setting_keys); do is_standby_key "$k" || assumed_key "$k" || snap+="$k=${!k}"$'\n'; done
        $ed "$SETTINGS_FILE" < "$PROMPT_IN" || true
        # check the edited file first (a typo must not stop the script)
        local -A keep=(); local line
        while IFS= read -r line; do [[ -n "$line" ]] && keep[${line%%=*}]=${line#*=}; done <<< "$snap"
        local save_vals=""; for k in $STANDBY_KEYS; do save_vals+="$k=${!k}"$'\n'; done
        if ! load_settings soft; then
          bad "The edited file has an error: $LOAD_ERR"; say "Choose e to fix it."
          while IFS= read -r line; do [[ -n "$line" ]] && printf -v "${line%%=*}" '%s' "${line#*=}"; done <<< "$save_vals"
          for k in "${!keep[@]}"; do printf -v "$k" '%s' "${keep[$k]}"; done
          say "Your edits are still in $SETTINGS_FILE; e opens it again."
          ED_KEEP_FILE=1
          continue
        fi
        local changed="" refused=""
        for k in "${!keep[@]}"; do
          if [[ "${!k}" != "${keep[$k]}" ]]; then refused+=" $k"; printf -v "$k" '%s' "${keep[$k]}"; fi
        done
        [[ -n "$refused" ]] && warn "These values are read from the primary and cannot be changed here (kept):$refused"
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
  if [[ $SYS_VERIFIED -eq 1 ]]; then NOW="sys password works on primary"; return 0; fi
  [[ $DISCOVERED -eq 1 ]] || { NOW="Primary configuration not read (step 1.3)"; return 2; }
  sys_needed || { NOW="Not needed for the steps of this run (only the login tests 7.4-7.6 and the duplicate use it)"; return 0; }
  if [[ "$MODE" == "check" ]]; then d_1_5 && { NOW="sys password works on primary"; return 0; }; NOW="sys password not verified (see above)"; return 2; fi
  NOW="sys password not given yet"
  PLAN="Ask the sys password (not shown while typing), keep it only in memory
Test it on primary through its listener: sqlplus sys@//$PRIMARY_HOST:$PORT/$PRIMARY_SERVICE (SELECT 1 FROM DUAL)"
  return 1
}
d_1_5() {
  if [[ -n "$ENV_SYS_PW" ]]; then SECRET=$ENV_SYS_PW; ENV_SYS_PW=""; say "Using DG_SYS_PASSWORD from environment"
  else ask_secret "sys password of the primary database (not shown while typing):"; fi
  if [[ -z "$SECRET" ]] || ! sys_pw_ok "$SECRET"; then
    SECRET=""
    bad "Empty password, or it contains a space, a quote, or one of @ / & ; # \\ \$ \` or a non-ASCII character."
    printf 'This script cannot pass such a password to sqlplus and RMAN. Change it on the primary first\n(as %s, sqlplus / as sysdba):  alter user sys identified by "<new password>";\n(12.2 and newer update the password file by themselves), then answer r.\n' "$ORACLE_USER" | hint
    return 1
  fi
  SYS_PW=$SECRET; SECRET=""
  local tgt
  for tgt in "//localhost:$PORT/$PRIMARY_SERVICE" "//$PRIMARY_HOST:$PORT/$PRIMARY_SERVICE" "//$PRIMARY_IP:$PORT/$PRIMARY_SERVICE"; do
    if prim_sql_as_sys "$tgt" "select 1 from dual;"; then
      SYS_VERIFIED=1; DONE_MSG="sys password works on primary"
      mask_pending
      if [[ ${#SYS_PW} -lt 8 ]] || grep -qiF -- "$SYS_PW" <<< "$ORACLE_USER $GRID_USER $DB_HOME $ORACLE_BASE $PRIMARY_SID $STANDBY_SID"; then
        warn "The sys password is short or is part of a name or path. The log hides it with ***** everywhere it appears, also inside names."
      fi
      return 0
    fi
    # only a network problem is a reason to try the next address
    grep -qE 'ORA-12541|TNS-12541|ORA-12514|ORA-12170|ORA-12545' <<< "$SQL_OUT" || break
  done
  local errs; errs=$(ora_errors "$SQL_OUT")
  bad "Login as sys on primary failed (${errs:-no error text}). The test ran ON THE PRIMARY (over ssh) through its listener."
  {
    [[ "$errs" == *ORA-01017* ]] && printf 'ORA-01017: wrong sys password, or SYS is not in the primary password file.\n           To set it on primary (sqlplus / as sysdba):  alter user sys identified by "<password>";\n'
    [[ "$errs" == *ORA-12514* ]] && printf 'ORA-12514: the listener on primary does not know the service %s.\n           On primary as the listener owner:  ORACLE_HOME=%s %s/bin/lsnrctl status %s   (the service must be listed; else check the service_names of the database)\n' "$PRIMARY_SERVICE" "$PRIMARY_LISTENER_HOME" "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME"
    [[ "$errs" == *12541* ]] && printf 'ORA-12541: no listener on port %s on primary. On primary as the listener owner:  ORACLE_HOME=%s %s/bin/lsnrctl start %s\n' "$PORT" "$PRIMARY_LISTENER_HOME" "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME"
    [[ "$errs" == *ORA-12170* || "$errs" == *ORA-12545* ]] && printf 'ORA-12170/12545: the host name or port cannot be reached on primary.\n'
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
  phase_header 1 "Connect to primary and read its configuration"
  run_step 1.1 check "Local safety checks (root, tools)" c_1_1
  # 1.2, 1.3 and 1.5 only read (or ask a password): no [y] question for them
  run_step 1.2 ask   "Connect to primary over ssh" c_1_2 d_1_2
  run_step 1.3 ask   "Read primary configuration (read-only)" c_1_3 d_1_3
  # without the primary configuration no other step can do anything
  [[ $DISCOVERED -eq 1 ]] || fatal "Steps 1.2 and 1.3 (connection to the primary, its configuration) must be done before anything else. Fix the problem shown above and run the script again."
  # [i] at 1.2 gave another address: another database there means another standby (its records are set aside)
  if [[ -n "$OLD_PRIMARY_UNIQUE" && -n "$PRIMARY_UNIQUE" && "${OLD_PRIMARY_UNIQUE^^}" != "${PRIMARY_UNIQUE^^}" ]]; then
    set_aside_state "${OLD_PRIMARY_UNIQUE}_$RUN_ID"; say "Another primary database ($PRIMARY_UNIQUE, before: $OLD_PRIMARY_UNIQUE): the records of the old setup are kept aside."
  fi
  OLD_PRIMARY_UNIQUE=""
  run_step 1.6 check "Oracle version supported on this Oracle Linux" c_1_6
  run_step 1.4 ask   "Standby settings" c_1_4 d_1_4
  # a 1.6 problem that the new settings solved (RU_DIR set in 1.4): checked again, quietly
  if [[ -n "${STEP_RESULT[1.6]:-}" && "${STEP_RESULT[1.6]}" != OK && "$MODE" == "run" ]] && c_1_6 >/dev/null 2>&1; then
    ok_lines "1.6 is fine now with the new settings"; record 1.6 OK
  fi
  run_step 1.5 ask   "sys password" c_1_5 d_1_5
  # nothing below works without these
  if [[ $DISCOVERED -ne 1 || $SETTINGS_ACCEPTED -ne 1 ]]; then
    [[ "$MODE" == "check" && $DISCOVERED -eq 1 ]] || fatal "Steps 1.2, 1.3 and 1.4 (connection, primary configuration, settings) must be done before anything else. Run the script again."
  fi
  build_envs_if_possible
  # (only useful while the long installs of phase 3 are still ahead)
  if [[ "$MODE" == "run" && -z "$ONLY_PHASE" && -z "$FROM_STEP" ]] && ! phase4_all_done && [[ "$(phase_done_result 3)" != "DONE" ]]; then
    say "Phases 4, 6 and 9 need commands on the PRIMARY (the script prints them, you run them, the script checks)."
    say "Phase 4 needs nothing of this server: you can do it now, before the long software installs."
    CUR_STEP=""
    ask_choice "[4] do phase 4 (primary) first   [c] continue in order   [q] quit" "4cq"
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
    say "ran: $c"
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
        diff+="gid $gid (needed for $name) is already used here by group $other"$'\n'
        fix+="groupmod -g <a free gid> $other"$'\n'"groupadd -g $gid $name"$'\n'
      else miss+="groupadd -g $gid $name"$'\n'; fi
    elif [[ "$cur" != "$gid" ]]; then
      diff+="group $name has gid $cur here, $gid on primary"$'\n'
      fix+="groupmod -g $gid $name"$'\n'
    fi
  done
  if [[ -n "$diff" ]]; then
    NOW="${diff%$'\n'}"
    MANUAL_HOW="root  ->  shell (only while no Oracle software is installed here)"
    PLAN="${fix%$'\n'}
(the gids must be the same on both servers for ASM and the password file to work;
 files that belong to the old gid keep it: find / -xdev -gid <old gid> lists them)"
    return 2
  fi
  if [[ -z "$miss" ]]; then NOW="All ${#_ge[@]} groups exist with the same ids as primary"; return 0; fi
  G_TODO=${miss%$'\n'}
  NOW="Missing groups: $(grep -oE '[^ ]+$' <<< "$G_TODO" | paste -sd' ' -)"
  PLAN="$G_TODO"
  USING="group names and ids read from primary"
  return 1
}
d_2_1() {
  # each command is journaled as soon as it worked (a later failure does not hide an earlier change)
  local c; while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    run_cmds <<< "$c" || return 1
    [[ "$c" =~ ^groupadd\ .*\ ([A-Za-z0-9_.-]+)$ ]] && journal GROUP "${BASH_REMATCH[1]}" "gid ${c#groupadd -g }"
  done <<< "$G_TODO"
  return 0
}

# ---- 2.2 users ----
U_TODO=""
c_2_2() {
  local spec name uid pg supp g miss_g todo="" err="" fix=""
  local -a specs=("$ORACLE_USER|$ORACLE_UID|$INSTALL_GROUP|$ORACLE_GROUPS")
  single_owner || specs+=("$GRID_USER|$GRID_UID|$GRID_PGROUP|$GRID_GROUPS")
  for spec in "${specs[@]}"; do
    IFS='|' read -r name uid pg supp <<< "$spec"
    if ! id "$name" >/dev/null 2>&1; then
      local other; other=$(getent passwd "$uid" | cut -d: -f1)
      if [[ -n "$other" ]]; then
        err+="uid $uid (needed for $name) is already used here by user $other"$'\n'
        fix+="usermod -u <a free uid> $other"$'\n'; continue
      fi
      todo+="useradd -m -s /bin/bash -u $uid -g $pg${supp:+ -G $supp} $name"$'\n'; continue
    fi
    [[ "$(id -u "$name")" == "$uid" ]] || { err+="user $name has uid $(id -u "$name") here, $uid on primary"$'\n'; fix+="usermod -u $uid $name"$'\n'; continue; }
    [[ "$(id -gn "$name")" == "$pg" ]] || todo+="usermod -g $pg $name"$'\n'
    miss_g=""
    IFS=',' read -ra _gl <<< "$supp"
    for g in "${_gl[@]}"; do [[ -n "$g" ]] && ! in_group "$name" "$g" && miss_g+="$g,"; done
    [[ -n "$miss_g" ]] && todo+="usermod -a -G ${miss_g%,} $name"$'\n'
  done
  if [[ -n "$err" ]]; then
    NOW="${err%$'\n'}"
    MANUAL_HOW="root  ->  shell (only while no Oracle software is installed here)"
    PLAN="${fix%$'\n'}
(files of the old uid keep it: find / -xdev -uid <old uid> lists them)"
    return 2
  fi
  if [[ -z "$todo" ]]; then
    if single_owner; then NOW="$ORACLE_USER ($ORACLE_UID) exists with the same groups as primary"
    else NOW="$ORACLE_USER ($ORACLE_UID) and $GRID_USER ($GRID_UID) exist with the same groups as primary"; fi
    return 0
  fi
  U_TODO=${todo%$'\n'}
  NOW="Users are missing or miss some groups"
  PLAN="$U_TODO"
  USING="uid, primary group and groups of each user on primary"
  return 1
}
d_2_2() {
  local c; while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    run_cmds <<< "$c" || return 1
    [[ "$c" =~ ^useradd\ .*\ ([A-Za-z0-9_.-]+)$ ]] && journal USER "${BASH_REMATCH[1]}" "$c"
    [[ "$c" =~ ^usermod\ .*\ ([A-Za-z0-9_.-]+)$ ]] && journal USERMOD "${BASH_REMATCH[1]}" "$c"
  done <<< "$U_TODO"
  say "Passwords are not needed by this script (set them with passwd if you want to log in as these users)."
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
  command -v rpm >/dev/null 2>&1 || { NOW="rpm not found: this server is not Oracle Linux / RHEL"; return 2; }
  local p; P_MISS=()
  while IFS= read -r p; do rpm -q "$p" >/dev/null 2>&1 || P_MISS+=("$p"); done < <(need_pkgs)
  if [[ ${#P_MISS[@]} -eq 0 ]]; then NOW="Required packages are installed"; return 0; fi
  NOW="Missing packages: ${P_MISS[*]}"
  PLAN="$PKG install -y <package>   (one package at a time, so one that is not found does not stop the others):
  ${P_MISS[*]}
($(preinstall_pkg) sets kernel parameters and limits for the user oracle; it does not change existing users)"
  USING="Oracle Linux $OS_MAJOR, database $DB_MAJOR"
  return 1
}
d_2_3() {
  local p failed=()
  for p in "${P_MISS[@]}"; do
    if run_logged "$PKG install -y $p" "$PKG" install -y "$p" && rpm -q "$p" >/dev/null 2>&1; then say "installed: $p"; journal PKG "$p"
    else failed+=("$p"); bad "Not installed: $p ($(grep -iE 'no package|unable to find|error' <<< "$RUN_OUT" | head -n 1))"; fi
  done
  [[ ${#failed[@]} -eq 0 ]] && return 0
  local repo
  case "$OS_MAJOR" in 7) repo="ol7_latest ol7_addons" ;; 8) repo="ol8_baseos_latest ol8_appstream ol8_addons" ;; *) repo="ol${OS_MAJOR}_baseos_latest ol${OS_MAJOR}_appstream ol${OS_MAJOR}_addons" ;; esac
  {
    printf 'Usually a repository is not enabled, or there is no internet / local repository.\n'
    printf 'Check:   %s repolist      (needed: %s)\n' "$PKG" "$repo"
    if [[ "$PKG" == "yum" ]]; then printf 'Enable:  yum-config-manager --enable <repo>\n'; else printf 'Enable:  dnf config-manager --set-enabled <repo>\n'; fi
    printf 'Not every preinstall package exists for every Oracle Linux release (for example 12c on OL8 or OL9).\n'
    [[ " ${failed[*]} " == *" oracleasm-support "* ]] && printf 'Without oracleasm-support the ASM disks can use udev rules instead: skip this step, then step 2.12 offers udev.\n'
    printf 'Then install them yourself and answer r:  %s install -y %s\n' "$PKG" "${failed[*]}"
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
  if [[ -z "$(limit_users)" ]]; then NOW="Not needed (the only Oracle owner is oracle; $(preinstall_pkg) sets its limits)"; return 0; fi
  if [[ ${#miss[@]} -eq 0 ]]; then NOW="Limits exist for: $(limit_users | paste -sd' ' -)"; return 0; fi
  LIM_TODO=("${miss[@]}")
  NOW="No limits for: ${miss[*]} (the preinstall package sets them only for the user named oracle)"
  PLAN="Write $LIMITS_FILE: nofile 1024/65536, nproc 16384, stack 10240/32768, memlock unlimited for ${miss[*]}"
  [[ "$ORACLE_USER" != "oracle" ]] && ! id oracle >/dev/null 2>&1 && \
    PLAN+=$'\n'"Note: the preinstall package may create a user named oracle (uid 54321); it is not used by this standby."
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
    bad "Refused to create or change the system folder $path"; return 1 ;; esac
  IFS='/' read -ra parts <<< "${path#/}"
  for comp in "${parts[@]}"; do
    [[ -n "$comp" ]] || continue
    p+="/$comp"
    if [[ -L "$p" ]]; then
      local lo; lo=$(stat -c '%U' "$p")
      [[ "$lo" == "root" ]] || { bad "$p is a symbolic link owned by $lo; not used"; return 1; }
    fi
    if [[ ! -e "$p" ]]; then install -d -o "$owner" -g "$INSTALL_GROUP" -m 775 "$p" || return 1; say "created $p"; journal DIR "$p" "owner $owner"; fi
  done
  [[ -L "$path" ]] && { bad "$path is a symbolic link; its owner is not changed"; return 0; }
  if [[ -z "$(ls -A "$path" 2>/dev/null)" ]]; then chown -h "$owner:$INSTALL_GROUP" "$path" && chmod 775 "$path"; fi
}
dir_specs() {
  if use_grid; then printf '%s\n' "$GRID_BASE:$GRID_USER" "$GRID_HOME:$GRID_USER"; fi
  printf '%s\n' "$INVENTORY_DIR:$GRID_USER" "$ORACLE_BASE:$ORACLE_USER" "$DB_HOME:$ORACLE_USER"
}
existing_parent() { local p=$1; while [[ ! -e "$p" && "$p" != "/" ]]; do p=$(dirname "$p"); done; printf '%s' "$p"; }
mnt_of() { df --output=target -- "$(existing_parent "$1")" 2>/dev/null | tail -n 1; }
free_mb_of() { local f; f=$(df -m --output=avail -- "$(existing_parent "$1")" 2>/dev/null | tail -n 1 | tr -d ' '); num "$f" && printf '%s' "$f" || printf '0'; }
c_2_5() {
  users_ok || { NOW="Users do not exist yet (step 2.2)"; return 2; }
  local d own miss="" wrong="" fixw=""
  while IFS=: read -r d own; do
    if [[ ! -d "$d" ]]; then miss+="$d ($own)"$'\n'; continue; fi
    local cur; cur=$(stat -c '%U' "$d")
    if [[ "$cur" != "$own" && ! ( "$cur" == "root" && "$d" == "$GRID_HOME" ) ]]; then
      if [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then miss+="$d (owner $cur -> $own)"$'\n'
      else wrong+="$d is owned by $cur (expected $own) and is not empty"$'\n'; fixw+="chown $own:$INSTALL_GROUP $d"$'\n'; fi
    fi
  done < <(dir_specs)
  if [[ -n "$wrong" ]]; then
    NOW="${wrong%$'\n'}"
    MANUAL_HOW="root  ->  shell (only if these files belong to this standby setup)"
    PLAN="Check what is in the folder first (ls -la). If it is right to change the owner:
${fixw%$'\n'}"
    return 2
  fi
  # an empty home needs room for the software (about 15 GB each)
  local short="" h
  for h in "$DB_HOME" ${GRID_HOME:+"$GRID_HOME"}; do
    [[ -n "$(ls -A "$h" 2>/dev/null)" ]] && continue
    use_grid || [[ "$h" != "$GRID_HOME" ]] || continue
    [[ $(free_mb_of "$h") -ge 15360 ]] || short+="$(mnt_of "$h") has $(human_mb "$(free_mb_of "$h")") free for $h (needs about 15 GB); "
  done
  [[ -n "$short" ]] && warn "Little space for the software: $short"
  if [[ -z "$miss" ]]; then NOW="Folders exist with correct owners"; return 0; fi
  NOW="Missing folders or wrong owner on empty folders"
  PLAN="Create (owner, group $INSTALL_GROUP, mode 775):
${miss%$'\n'}
Owners of existing non-empty folders are never changed"
  USING="same paths as on primary"
  return 1
}
d_2_5() { local d own; while IFS=: read -r d own; do make_dir "$d" "$own" || return 1; done < <(dir_specs); }

# ---- 2.6 /etc/hosts on standby ----
H_TODO=""
v4_of() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }
c_2_6() {
  local todo="" h ip want wrong=""
  for h in "$PRIMARY_HOST|$PRIMARY_IP" "$STANDBY_HOST|$STANDBY_IP"; do
    IFS='|' read -r h want <<< "$h"
    ip=$(v4_of "$h")
    if [[ -z "$ip" ]]; then
      if [[ "$want" =~ ^[0-9.]+$ ]]; then
        local fq=""; [[ "$h" == "$STANDBY_HOST" ]] && fq=$(hostname 2>/dev/null) && [[ "$fq" == *.* && "${fq%%.*}" == "$h" ]] || fq=""
        todo+="$want    ${fq:+$fq }$h"$'\n'
      else NOW="$h does not resolve and no IP is known"; return 2; fi
    elif [[ "$want" =~ ^[0-9.]+$ && "$ip" != "$want" && "$ip" != 127.* ]]; then
      wrong+="$h resolves to $ip here, expected $want"$'\n'
    fi
  done
  local sip; sip=$(v4_of "$STANDBY_HOST")
  if [[ "$sip" == 127.* ]]; then
    # the Grid listener would listen only on loopback; primary could not reach it
    NOW="$STANDBY_HOST resolves to $sip (loopback) on this server"
    KIND_NOW=manual; MANUAL_HOW="root  ->  edit /etc/hosts"
    PLAN="In /etc/hosts remove $STANDBY_HOST from the 127.x line and add:
$STANDBY_IP    $STANDBY_HOST"
    return 1
  fi
  if [[ -n "$wrong" ]]; then
    NOW="${wrong%$'\n'}"
    KIND_NOW=manual; MANUAL_HOW="root  ->  edit /etc/hosts (or the DNS entry)"
    PLAN="Make the names resolve to the right addresses, for example in /etc/hosts:
$PRIMARY_IP    $PRIMARY_HOST
$STANDBY_IP    $STANDBY_HOST"
    return 1
  fi
  if [[ -z "$todo" ]]; then NOW="$PRIMARY_HOST -> $(v4_of "$PRIMARY_HOST"), $STANDBY_HOST -> $sip"; return 0; fi
  H_TODO=${todo%$'\n'}
  NOW="Host names do not resolve on this server"
  PLAN="Add to /etc/hosts (a backup copy is kept):
$H_TODO"
  return 1
}
d_2_6() {
  backup_file /etc/hosts || return 1
  local l add=""
  while IFS= read -r l; do grep -qxF -- "$l" /etc/hosts || add+="$l"$'\n'; done <<< "$H_TODO"
  [[ -n "$add" ]] && printf '%s' "${add%$'\n'}" | append_as root /etc/hosts
  return 0
}

# ---- 2.7 primary resolves standby ----
c_2_7() {
  need_ssh || return 2
  if prim_probe hosts "$STANDBY_HOST" && [[ -n "$(awk '{print $1; exit}' <<< "$RUN_OUT")" ]]; then
    local pip; pip=$(awk '{print $1; exit}' <<< "$RUN_OUT")
    if [[ "$pip" == "$STANDBY_IP" ]]; then NOW="Primary resolves $STANDBY_HOST -> $pip"; return 0; fi
    NOW="Primary resolves $STANDBY_HOST -> $pip, but this server is $STANDBY_IP"
    PRIMARY_HOW_STEP="root  ->  edit /etc/hosts (or DNS)"
    PLAN="Change the line for $STANDBY_HOST in /etc/hosts on primary to:
$STANDBY_IP    $STANDBY_HOST"
    PLAN_UNDO="put back the line '$pip    $STANDBY_HOST' in /etc/hosts on the primary"
    return 1
  fi
  NOW="Primary does not resolve $STANDBY_HOST"
  PRIMARY_HOW_STEP="root  ->  shell"
  PLAN="echo '$STANDBY_IP    $STANDBY_HOST' >> /etc/hosts"
  PLAN_UNDO="remove the line '$STANDBY_IP    $STANDBY_HOST' from /etc/hosts on the primary"
  return 1
}

# ---- 2.8 network to primary listener ----
c_2_8() {
  if timeout 5 bash -c "exec 3<>/dev/tcp/$PRIMARY_IP/$PORT" 2>/dev/null; then NOW="$PRIMARY_IP:$PORT is reachable"; return 0; fi
  NOW="Cannot open TCP $PRIMARY_IP:$PORT (a firewall on the primary or in the network between the servers)"
  KIND_NOW=primary; PRIMARY_HOW_STEP="root  ->  shell (only if the primary runs firewalld; else ask the network team)"
  # added only when it is not open yet, and without a reload (a reload would drop rules the primary admin added at runtime)
  PLAN="firewall-cmd --query-port=$PORT/tcp || { firewall-cmd --add-port=$PORT/tcp ; firewall-cmd --permanent --add-port=$PORT/tcp ; }
# if the port was open already, the block is in the network between the servers: ask the network team"
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
    if grep -q 'Leap status.*Normal' <<< "$(chronyc tracking 2>/dev/null)"; then NOW="chronyd is running, clock in sync"; else NOW="chronyd is running (sync not confirmed yet)"; fi
    return 0
  fi
  if systemctl is-active --quiet ntpd 2>/dev/null; then NOW="ntpd is running (time synchronization)"; return 0; fi
  NOW="No time synchronization is running (chronyd or ntpd)"
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
  users_ok || { NOW="Users do not exist yet (step 2.2)"; return 2; }
  local entry usr base home sid cur csid chome cbase todo=() report="" okl="" over=""
  while IFS= read -r entry; do
    IFS='|' read -r usr base home sid <<< "$entry"
    cur=$(login_env "$usr"); IFS='|' read -r csid chome cbase <<< "$cur"
    if [[ "$csid" == "$sid" && "${chome%/}" == "$home" && "${cbase%/}" == "$base" ]]; then okl+="$usr -> $sid  "; continue; fi
    local prof; prof="$(home_of "$usr")/.bash_profile"
    if [[ -f "$prof" ]] && grep -qxF "export ORACLE_SID=$sid" "$prof" && grep -qxF "export ORACLE_HOME=$home" "$prof" && grep -qF "dg_standby_setup.sh" "$prof"; then
      over+="$usr: the lines are in $prof, but after login the values are ORACLE_SID=${csid:-<not set>} ORACLE_HOME=${chome:-<not set>}"$'\n'
      continue
    fi
    todo+=("$entry")
    report+="$usr now has: ORACLE_SID=${csid:-<not set>} ORACLE_HOME=${chome:-<not set>} ORACLE_BASE=${cbase:-<not set>}"$'\n'
  done < <(profile_specs)
  if [[ -n "$over" ]]; then
    NOW="${over%$'\n'}"
    KIND_NOW=manual; MANUAL_HOW="the user  ->  edit the login files"
    PLAN="Something that runs after ~/.bash_profile sets other values (often ~/.bashrc or /etc/profile.d/*.sh):
grep -n 'ORACLE_' ~/.bashrc /etc/profile.d/*.sh
Remove or correct those lines, then answer r."
    return 1
  fi
  if [[ ${#todo[@]} -eq 0 ]]; then NOW="Profiles correct: $okl"; return 0; fi
  PROF_TODO=("${todo[@]}")
  NOW="${report%$'\n'}"
  PLAN="Append to ~/.bash_profile of each user (backup kept; old lines stay, the new lines win):"
  local others; others=$(grep -vE '^\s*(#|$|\+ASM)' /etc/oratab 2>/dev/null | cut -d: -f1 | grep -vx -- "$STANDBY_SID" | paste -sd' ' -)
  [[ -n "$others" ]] && USING="NOTE: /etc/oratab lists other databases on this server ($others): the default ORACLE_SID of $ORACLE_USER becomes $STANDBY_SID"
  for entry in "${todo[@]}"; do
    IFS='|' read -r usr base home sid <<< "$entry"
    PLAN+=$'\n'"  $usr:  ORACLE_BASE=$base  ORACLE_HOME=$home  ORACLE_SID=$sid  PATH=\$ORACLE_HOME/bin:\$PATH"
  done
  return 1
}
d_2_11() {
  local entry usr base home sid prof
  for entry in "${PROF_TODO[@]}"; do
    IFS='|' read -r usr base home sid <<< "$entry"
    prof="$(home_of "$usr")/.bash_profile"
    [[ -L "$prof" ]] && { bad "$prof is a symbolic link; not changed"; return 1; }
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
    NOW="ASM disks use udev rules ($UDEV_RULES, devices in /dev/oraasm; no ASMLib on this kernel)"
    if [[ "$ASM_METHOD" != "udev" && "$MODE" == "run" ]]; then ASM_METHOD=udev; save_settings; journal SETTING ASM_METHOD "ASM_METHOD=udev"; NOW+=" - saved"; fi
    return 0
  fi
  if ! command -v oracleasm >/dev/null 2>&1; then
    if [[ -n "$(asm_labels_all)" ]]; then NOW="oracleasm is not installed, but ASM disks were made with it before (step 2.3)"; return 2; fi
    NOW="ASMLib (oracleasm-support) is not installed"
    PLAN="Use udev rules for the ASM disks instead of ASMLib (works on every kernel)
(or install oracleasm-support in step 2.3 and answer s here, then run the script again)"
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
  if [[ -z "$need" && "$ASM_METHOD" == "asmlib" ]]; then NOW="ASMLib configured for $GRID_USER:$ag, loaded, and started at boot"; return 0; fi
  NOW="ASMLib (oracleasm) is not configured, not loaded or not started at boot"
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
  [[ "$(asm_method)" == "udev" ]] || command -v oracleasm >/dev/null 2>&1 || { NOW="oracleasm not installed (step 2.12)"; return 2; }
  local dg have="" miss="" short="" l foreign="" min hv
  for dg in $(asm_dgs); do
    l=$(asm_foreign "$dg"); [[ -n "$l" ]] && foreign+="+$dg: $(paste -sd' ' - <<< "$l")"$'\n'
    min=$(dg_min_mb "$dg"); hv=$(dg_have_mb "$dg")
    if [[ -z "$(asm_labels "$dg")" ]]; then miss+=" +$dg"
    elif [[ $hv -lt $min ]]; then short+=" +$dg"; have+="+$dg: $(asm_labels "$dg" | paste -sd' ' -) ($(human_mb "$hv"), needs $(human_mb "$min"))   "
    else have+="+$dg: $(asm_labels "$dg" | paste -sd' ' -) ($(human_mb "$hv"))   "; fi
  done
  A213_FOREIGN=${foreign%$'\n'}
  if [[ -z "$miss$short$foreign" ]]; then NOW="ASM disks: $have"; return 0; fi
  NOW=""
  [[ -n "$have" ]] && NOW+="ASM disks: $have"$'\n'
  [[ -n "$miss" ]] && NOW+="No ASM disks yet for:$miss"$'\n'
  [[ -n "$short" ]] && NOW+="Too small:$short (more disks are added)"$'\n'
  [[ -n "$foreign" ]] && NOW+="ASM disks that this script did not make (you are asked whether to use them):"$'\n'"$A213_FOREIGN"$'\n'
  NOW=${NOW%$'\n'}
  local fd; fd=$(free_disks)
  PLAN="You choose EMPTY disks (one or more) for each disk group; the list is below
Each chosen disk: parted mklabel gpt + one partition, then"
  if [[ "$(asm_method)" == "asmlib" ]]; then PLAN+=" oracleasm createdisk <DG>_1, <DG>_2 ..."
  else PLAN+=" a udev rule (partition UUID) -> /dev/oraasm/<DG>_1, owner $GRID_USER:$(asm_owner_group), mode 0660"; fi
  PLAN+=$'\n'"All chosen disks are checked first; you type each disk name to confirm; disks with any data are refused"
  USING="Size needed (database files of primary + 10%; recovery area: what a standby needs, see step 8.1):"
  for dg in $(asm_dgs); do USING+=$'\n'"  +$dg  at least $(human_mb "$(dg_min_mb "$dg")")"; done
  if [[ -n "$fd" ]]; then
    USING+=$'\n'"Empty disks found:"
    while read -r l; do USING+=$'\n'"  ${l%% *}  $(human_mb "${l##* }")"; done <<< "$fd"
  else
    USING+=$'\n'"No empty disk found on this server (multipath devices are not offered: see --help-step 2.13)"
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
  disk_is_free "$disk" || { bad "$disk cannot be used any more: $DISK_WHY. Nothing was erased."; return 1; }
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
      printf 'The disk now has an empty GPT partition (no data on it). To try again later, clear it first:\n  wipefs -a %s ; wipefs -a %s\n' "$part" "$disk" | hint
      return 1
    fi
  else
    local uuid; uuid=$(udev_uuid "$part")
    if ! [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      bad "Cannot read the partition UUID of $part"
      printf 'The disk now has an empty GPT partition (no data on it). To try again later, clear it first:\n  wipefs -a %s ; wipefs -a %s\n' "$part" "$disk" | hint
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
    [[ "$perm" == "$GRID_USER:$(asm_owner_group):660" ]] || { bad "/dev/oraasm/$label has owner/mode '$perm', expected $GRID_USER:$(asm_owner_group):660"; return 1; }
  fi
  asm_label_exists "$label" || { bad "ASM disk $label is not visible after it was created"; return 1; }
  record_label "$label" "$part"
  journal ASMLABEL "$label" "on $part"
  say "ASM disk $label created on $part"
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
      if [[ "$g" == "?" ]]; then refused+=" $i(device not found)"
      elif [[ -n "$g" ]] && ! asm_group_mounted_here "$g"; then refused+=" $i(member of disk group $g, not mounted here)"; reflab+=" $i"
      else ok_l+=" $i"; fi
    done <<< "$l"
    if [[ -n "$refused" ]]; then
      warn "Not used:$refused. Such disks may belong to another server (for example the primary)."
      install -d -m 700 "$STATE_DIR"; for i in $reflab; do printf '%s|-\n' "$i" >> "$(asm_disks_file)"; done; chmod 600 "$(asm_disks_file)"
    fi
    [[ -n "$ok_l" ]] || continue
    if confirm "Use the existing ASM disk(s)$ok_l for +$dg on this standby? (only if nothing else uses them)"; then
      for i in $ok_l; do record_label "$i" "$(label_device "$i")"; done
    else
      for i in $ok_l; do install -d -m 700 "$STATE_DIR"; printf '%s|-\n' "$i" >> "$(asm_disks_file)"; done; chmod 600 "$(asm_disks_file)"
      say "Not used:$ok_l (remembered). New disks are chosen for +$dg instead."
    fi
  done
  # 2) new disks for every disk group that has none or too little space
  fd=$(free_disks)
  local -a disks=(); [[ -n "$fd" ]] && mapfile -t disks <<< "$fd"
  for dg in $(asm_dgs); do
    min=$(dg_min_mb "$dg"); have=$(dg_have_mb "$dg")
    [[ -n "$(asm_labels "$dg")" && $have -ge $min ]] && continue
    local need_more=$(( min - have ))
    [[ ${#disks[@]} -gt 0 ]] || { bad "No empty disk on this server for +$dg. Add disks (h shows the manual way). Nothing was erased."; return 1; }
    if [[ $have -gt 0 ]]; then say "Disk group +$dg needs at least $min MB; its disks have $have MB. Empty disks:"
    else say "Disk group +$dg needs at least $min MB. Empty disks:"; fi
    def=""
    for i in "${!disks[@]}"; do
      if [[ "$used" == *" ${disks[$i]%% *} "* ]]; then say "  $((i + 1))) ${disks[$i]%% *}  $(human_mb "${disks[$i]##* }")   (chosen)"
      else say "  $((i + 1))) ${disks[$i]%% *}  $(human_mb "${disks[$i]##* }")"; [[ -z "$def" ]] && def=$((i + 1)); fi
    done
    [[ -n "$def" ]] || { bad "Not enough empty disks for +$dg. Nothing was erased."; return 1; }
    local left=0
    for i in "${!disks[@]}"; do [[ "$used" == *" ${disks[$i]%% *} "* ]] || left=$((left + ${disks[$i]##* })); done
    if [[ $left -lt $need_more ]]; then
      bad "The empty disks left have $left MB together; +$dg needs $need_more MB more. Add disks to this server. Nothing was erased."
      return 1
    fi
    while true; do
      ask_default "Disk numbers for +$dg (one or more, separated by spaces; q = stop, nothing is erased)" "$def"
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
      if [[ $total -lt $need_more ]]; then bad "These disks have $total MB; +$dg needs $need_more MB more. Choose more or bigger disks."; continue; fi
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
      [[ -n "$pbs" && "$pbs" -lt 4096 ]] && { bad "The redo logs of the primary use 4096-byte blocks, but $d has $pbs-byte sectors: the standby logs could not be created (ORA-01378). Use disks with 4K sectors. Nothing was erased."; return 1; }
    else
      [[ -n "$lbs" && "$lbs" -ge 4096 ]] && { bad "$d is a 4K-native disk (4096-byte logical sectors), but the redo logs of the primary use 512-byte blocks: the standby and online logs could not be created (ORA-01378). Use disks with 512-byte (or 512e) sectors. Nothing was erased."; return 1; }
    fi
  done
  for p in "${sel[@]}"; do
    d=${p#*|}
    confirm_word "ALL DATA on $d ($(lsblk -dn -o SIZE "$d" | tr -d ' ')) will be erased for ASM disk ${p%%|*}." "$d" \
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
  users_ok || { NOW="Users do not exist yet (step 2.2)"; return 2; }
  local d mb mnt free used missing=() short="" report="" notmine=""
  declare -A need_by_mnt=() free_by_mnt=()
  while IFS='|' read -r d mb; do
    mnt=$(mnt_of "$d"); [[ -n "$mnt" ]] || { NOW="Cannot read the free space for $d (df)"; return 2; }
    free=$(free_mb_of "$d")
    # files that are already there (an earlier duplicate) already use their space
    used=0; [[ -d "$d" ]] && used=$(du -smx -- "$d" 2>/dev/null | awk '{print $1+0}'); num "$used" || used=0
    mb=$(( mb > used ? mb - used : 0 ))
    need_by_mnt[$mnt]=$(( ${need_by_mnt[$mnt]:-0} + mb ))
    free_by_mnt[$mnt]=$free
    if [[ -d "$d" && "$(stat -c %U "$d")" == "$ORACLE_USER" ]]; then report+="$d exists ($mnt)"$'\n'
    elif [[ -d "$d" && -n "$(ls -A "$d" 2>/dev/null)" ]]; then notmine+="$d is owned by $(stat -c %U "$d") and is not empty"$'\n'
    else missing+=("$d"); report+="$d missing ($mnt)"$'\n'; fi
  done < <(fs_need_lines)
  if [[ -n "$notmine" ]]; then
    NOW="${notmine%$'\n'}"; MANUAL_HOW="root  ->  shell (check the files first: ls -la)"
    PLAN="$(while IFS= read -r d; do [[ -n "$d" ]] && printf 'chown %s:%s %s\n' "$ORACLE_USER" "$INSTALL_GROUP" "${d%% is owned*}"; done <<< "$notmine")"
    return 2
  fi
  for mnt in "${!need_by_mnt[@]}"; do
    local want=$(( ${need_by_mnt[$mnt]} * 11 / 10 ))
    [[ ${free_by_mnt[$mnt]} -ge $want ]] || short+="file system $mnt has $(human_mb "${free_by_mnt[$mnt]}") free, needs about $(human_mb "$want")"$'\n'
  done
  if [[ -n "$short" ]]; then
    NOW="${report}${short%$'\n'}"
    MANUAL_HOW="root  ->  shell"
    PLAN="Give the database folders enough space, for example a new disk as a new file system:
lsblk                                   (find an EMPTY disk; below it is called /dev/<empty disk>)
mkfs.xfs /dev/<empty disk>
mkdir -p <mount point, for example $(fs_dirs | head -n 1 | cut -d/ -f1-2)>
echo \"UUID=\$(blkid -s UUID -o value /dev/<empty disk>)  <mount point>  xfs  defaults  0 0\" >> /etc/fstab
mount <mount point>
Then answer r (paths must stay the same as on primary)."
    return 2
  fi
  if [[ ${#missing[@]} -eq 0 ]]; then NOW="${report%$'\n'}"; return 0; fi
  FS_TODO=("${missing[@]}")
  NOW="${report%$'\n'}"
  PLAN="Create (owner $ORACLE_USER:$INSTALL_GROUP, mode 775, same paths as primary):"
  for d in "${missing[@]}"; do PLAN+=$'\n'"  $d"; done
  return 1
}
d_2_14() { local d; for d in "${FS_TODO[@]}"; do make_dir "$d" "$ORACLE_USER" || return 1; done; }

# ---- 2.15 storage is not shared with the primary ----
STORAGE_SHARED=""
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
  STORAGE_SHARED=""; STORAGE_INFO=""; STORAGE_PLAN=""
  read_primary_mounts || { STORAGE_INFO="Cannot read the file systems mounted on primary (findmnt/lsblk over ssh)"; return 2; }
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
    [[ "$ans" == "YES" || "$ans" == "NO" ]] || { [[ -z "$info2" ]] && info2="Cannot test $d on primary (no answer over ssh)"; np=1; continue; }
    pid=""; prim_probe fsid "$d" && pid=$(head -n 1 <<< "$RUN_OUT"); psrc=${pid%% *}; psrc=${psrc%%\[*}
    # 1) a network file system mounted from the same source on both servers
    if [[ $net -eq 1 && -n "$lsrc" && "$lsrc" != /dev/* && "$lsrc" == "$psrc" ]]; then STORAGE_SHARED+="$d ($fst, the same source $lsrc on both servers) "; continue; fi
    # 2) a test file written here (as the database owner) must not be visible on the primary
    if [[ "$ans" == "YES" ]]; then
      m="$d/.dg_standby_test_$(hostname -s)_${RUN_ID}_$$"
      CLEANUP_FILES+=("$m")
      runuser -u "$ORACLE_USER" -- sh -c 'umask 077; : > "$1"' sh "$m" 2>/dev/null || ( umask 077; : > "$m" ) 2>/dev/null \
        || { [[ -z "$info2" ]] && info2="Cannot write a test file in $d"; np=1; continue; }
      ans=""; prim_probe exists "$m" && ans=$(head -n 1 <<< "$RUN_OUT")
      if [[ "$ans" == "NO" && $net -eq 1 && "$STORAGE_NET_DONE" != *" $d|$lsrc "* ]]; then
        # a network file system client may cache folder contents for up to a minute: ask again after that (once per run)
        say "  $d is $fst: testing again in 65 seconds (the primary may cache the folder contents) ..."
        sleep 65
        ans=""; prim_probe exists "$m" && ans=$(head -n 1 <<< "$RUN_OUT")
        [[ "$ans" == "NO" ]] && STORAGE_NET_DONE+="$d|$lsrc "
      fi
      rm -f -- "$m"
      case "$ans" in
        YES) STORAGE_SHARED+="$d ($fst, the test file is seen on primary) "; continue ;;
        NO)  ans=SEEN_NO ;;
        *)   [[ -z "$info2" ]] && info2="Cannot test $d on primary (no answer over ssh)"; np=1; continue ;;
      esac
    fi
    # 3) the same file system UUID as a file system of the primary (at any path)
    if [[ -n "$luuid" ]] && grep -qxF -- "${luuid^^}" <<< "$P_MNT_UUIDS"; then
      wcom=$(comm -12 <(grep '^W:' <<< "$lids") <(primary_ids_of_uuid "$luuid" | grep '^W:') | sed 's/^W://' | paste -sd' ' -)
      if [[ -n "$wcom" ]]; then STORAGE_SHARED+="$d (file system $luuid on the same disk $wcom as on primary) "; continue; fi
      key=$luuid
      why="$d has the same file system UUID ($luuid) as a file system of the primary. This is a copy of the primary's disk, or the SAME disk mounted on both servers (the disk ids do not prove which)."
    elif [[ -n "$lids" ]] && wcom=$(comm -12 <(grep '^W:' <<< "$lids") <(primary_ids_all | grep '^W:') | sed 's/^W://' | paste -sd' ' -) && [[ -n "$wcom" ]]; then
      # 4) a disk of this folder is a disk under a file system of the primary (another partition, or a copied disk id)
      key="disks:$(paste -sd, - <<< "$lids")"
      why="A disk of $d (WWN $wcom) is also a disk under a file system of the primary: another partition of the same disk, or a virtual disk copied with its id."
    elif [[ $net -eq 1 ]]; then
      # 5) network file system: only the test file can prove it
      if [[ "$ans" == "SEEN_NO" ]]; then ok=1; STORAGE_INFO+="$d: $fst, test file not visible on primary after 65 seconds ($lsrc here, ${psrc:-?} there)"$'\n'
      else
        why="$d ($fst): the primary user $PRIMARY_SSH_USER cannot look into this folder there, so the test file cannot be used. It cannot be proven that this is not the storage of the primary."
        plan="For $d: run the script again with the owner of the database files on primary:
$SELF --user $ORACLE_USER"
      fi
    elif [[ -n "$luuid" && $P_MNT_COMPLETE -eq 1 ]]; then
      # 6) the primary shows every file system it mounts, and this one is not among them
      ok=1; STORAGE_INFO+="$d: ${fst:-?}, file system $luuid is not mounted on primary$([[ "$ans" == "SEEN_NO" ]] && printf '; test file not visible there')"$'\n'
    else
      if [[ -n "$luuid" ]]; then key=$luuid; elif [[ -n "$lids" ]]; then key="disks:$(paste -sd, - <<< "$lids")"; else key="device:$lsrc"; fi
      if [[ -z "$luuid" ]]; then why="$d: the file system UUID of THIS server could not be read."
      else why="$d: the primary does not show the UUID of every file system it mounts (user $PRIMARY_SSH_USER may not read them)."; fi
      why+=" It cannot be proven that this is not the storage of the primary."
    fi
    [[ $ok -eq 1 ]] && continue
    # not proven: a confirmation for exactly this disk counts
    if [[ -n "$key" && -f "$(storage_clone_file)" ]] && grep -qxF -- "$key" "$(storage_clone_file)"; then
      STORAGE_INFO+="$d: ${fst:-?}, you confirmed it is a separate disk of this server ($key)"$'\n'; continue
    fi
    if [[ -n "$key" ]]; then
      plan="For $d: do NOT change or format anything until you know which disk it is. Compare the disks on both servers:
here:            lsblk -s -o NAME,TYPE,WWN,SERIAL,SIZE \$(findmnt -n -o SOURCE --target $d)
on the primary:  lsblk -o NAME,TYPE,WWN,SERIAL,SIZE,MOUNTPOINT
(look in the storage or virtualization console whether it is the same volume)${plan:+
$plan}
Only if it is a separate disk of this server:
echo '$key' >> $(storage_clone_file)
then answer r."
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
  [[ -n "$(fs_dirs)" ]] || { NOW="Not needed (no database folders; new ASM disks must be empty, existing ones are checked in step 2.13)"; return 0; }
  [[ "$(marker_kind 2>/dev/null)" == "duplicate" ]] && { NOW="The copy already ran; the storage was proven before it started"; return 0; }
  if [[ "$MODE" == "check" ]]; then NOW="Tested only in a normal run (it writes a small test file)"; return 2; fi
  need_ssh || return 2
  local rc=0; storage_not_shared || rc=$?
  if [[ $rc -eq 2 ]]; then NOW=$STORAGE_INFO; [[ -n "$STORAGE_PLAN" ]] && PLAN=$STORAGE_PLAN; return 2; fi
  if [[ $rc -eq 0 ]]; then NOW="Each database folder is storage of this server only:"$'\n'"$STORAGE_INFO"; return 0; fi
  NOW="DANGER: these folders are the SAME storage as on the primary: $STORAGE_SHARED"$'\n'"The duplicate would overwrite the files of the primary database."
  KIND_NOW=manual; MANUAL_HOW="root  ->  storage"
  PLAN="Give this server its own storage for these paths (not the NFS export or SAN volume of the primary),
mount it at the same path, then answer r. The duplicate (step 8.2) is refused until this is fixed."
  :
  return 1
}

phase_2() {
  phase_header 2 "This server: groups, users, packages, folders, network, storage"
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
  run_step 2.15 check   "Database folders are not shared with the primary" c_2_15
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
  users_ok || { NOW="Users do not exist yet (step 2.2)"; return 2; }
  local need_g=0 need_d=0
  if use_grid; then grid_state; [[ "$GSTATE" == "NEED_UNZIP" ]] && need_g=1; fi
  db_state; [[ "$DSTATE" == "NEED_UNZIP" ]] && need_d=1
  if [[ $need_g -eq 0 && $need_d -eq 0 ]]; then NOW="Software is already unpacked/installed; installer files not needed"; return 0; fi
  if { [[ $need_g -eq 0 ]] || media_ok "$GRID_MEDIA"; } && { [[ $need_d -eq 0 ]] || media_ok "$DB_MEDIA"; }; then
    NOW="Installer files:${GRID_MEDIA:+ Grid=$GRID_MEDIA}${DB_MEDIA:+ DB=$DB_MEDIA}"; return 0
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
    NOW="The second file of the installer is missing:$miss2 (it must be in the same folder as the first one)"
    KIND_NOW=manual; MANUAL_HOW="root"; PLAN="Copy$miss2 next to the first file (owner root, chmod 644), then answer r."
    return 1
  fi
  if [[ ( $need_g -eq 1 && -z "$F_GRID" ) || ( $need_d -eq 1 && -z "$F_DB" ) ]]; then
    NOW="No installer files found in ${ZIP_DIRS[*]} for:$([[ $need_g -eq 1 && -z "$F_GRID" ]] && printf ' Grid %s' "$(want_rel grid)")$([[ $need_d -eq 1 && -z "$F_DB" ]] && printf ' database %s' "$(want_rel)")"
    [[ -n "$MEDIA_REFUSED" ]] && NOW+=$'\n'"Not used (owner is not root/$ORACLE_USER/$GRID_USER, or others can change the file):"$'\n'"${MEDIA_REFUSED%$'\n'}"
    KIND_NOW=manual; MANUAL_HOW="see each line"; MANUAL_WHERE="PRIMARY ($PRIMARY_HOST) and THIS SERVER ($(hostname -s)) - you do it"
    local wg=""; [[ $need_g -eq 1 ]] && wg=" and grid"
    PLAN="Copy the files to /stage on this server (owner root, chmod 644), then answer r. Either:"
    if [[ $DB_MAJOR -ge 18 ]]; then
      PLAN+=$'\n'"A) a GOLD IMAGE of the primary home (same patches). ON PRIMARY:"
      [[ $need_d -eq 1 ]] && PLAN+=$'\n'"     as $ORACLE_USER:  mkdir -p /tmp/gold && $DB_HOME/runInstaller -silent -createGoldImage -destinationLocation /tmp/gold"
      [[ $need_g -eq 1 ]] && PLAN+=$'\n'"     as $GRID_USER:  mkdir -p /tmp/gold && $GRID_HOME/gridSetup.sh -silent -createGoldImage -destinationLocation /tmp/gold"
      PLAN+=$'\n'"   then ON THIS SERVER as root:  mkdir -p /stage && scp $PRIMARY_SSH_USER@$PRIMARY_IP:/tmp/gold/*.zip /stage/ && chmod 644 /stage/*.zip"
      PLAN+=$'\n'"B) the base installation files of version $DB_MAJOR (then step 3.11 asks for the same patches as primary):"
    else
      PLAN+=$'\n'"the base installation files of version $(want_rel) (then step 3.11 asks for the same patches as primary):"
    fi
    [[ $need_d -eq 1 ]] && PLAN+=$'\n'"     database: $(base_media_name db "$(want_rel)")"
    [[ $need_g -eq 1 ]] && PLAN+=$'\n'"     grid:     $(base_media_name grid "$(want_rel grid)")"
    return 1
  fi
  NOW="Found installer files"
  PLAN="Use these files:"
  [[ $need_g -eq 1 ]] && PLAN+=$'\n'"  Grid: $(media_desc "$F_GRID")"
  [[ $need_d -eq 1 ]] && PLAN+=$'\n'"  DB:   $(media_desc "$F_DB")"
  PLAN+=$'\n'"and save them in $SETTINGS_FILE"
  USING="files with another version than $(want_rel) in their name are ignored; a gold image must come from the primary"
  # base media + a patched primary: say it now, not after two hours of installing
  local pp; pp=$(primary_patches "$DB_HOME" 2>/dev/null | head -n 3 | paste -sd' ' -)
  if [[ -n "$pp" && -z "$RU_DIR" ]] && media_is_gold "${F_DB:-${F_GRID:-}}"; then :   # gold image: same patches
  elif [[ -n "$pp" && -z "$RU_DIR" ]]; then
    USING+=$'\n'"NOTE: the primary has patches ($pp ...). These are base files: after the installation step 3.11 asks you to apply"
    USING+=$'\n'"the same patches by hand (opatchauto, about an hour). Faster: unzip the Release Update of the primary here now,"
    USING+=$'\n'"set RU_DIR and OPATCH_ZIP in the settings (q, then $SELF --settings, e) and the installer applies it."
  fi
  [[ -n "$MEDIA_REFUSED" ]] && USING+=$'\n'"not used (owner or mode): ${MEDIA_REFUSED//$'\n'/ }"
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
  [[ -f "$tpl" ]] || { bad "Response file template not found in the media: $tpl"; return 1; }
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
  [[ -n "$dup" ]] && { bad "The response file has a key twice ($dup): the installer would read the last one. Check the template $RSP_TEMPLATE (each key once, as an uncommented key= line)."; return 1; }
  if [[ -n "$RSP_MISSING" ]]; then
    bad "The response file template of this media does not have these settings:$RSP_MISSING"
    printf 'This media is newer or older than the script expects. Install this software yourself\n(h shows the installer choices), or add the missing keys as uncommented key= lines to the template\n%s and run the step again.\n' "$RSP_TEMPLATE" | hint
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
    if [[ -n "$ENV_ASM_PW" ]]; then SECRET=$ENV_ASM_PW; ENV_ASM_PW=""; say "Using DG_ASM_PASSWORD from environment"
    else
      ask_secret "New password for ASM SYS/ASMSNMP on this server (8-30 chars, upper, lower, digit; not shown while typing):"
      p1=$SECRET
      ask_secret "Repeat:"
      [[ "$p1" == "$SECRET" ]] || { SECRET=""; bad "Passwords do not match. Please type them again."; continue; }
    fi
    p1=$SECRET; SECRET=""
    if [[ ${#p1} -lt 8 || ${#p1} -gt 30 || ! "$p1" =~ [A-Z] || ! "$p1" =~ [a-z] || ! "$p1" =~ [0-9] || "$p1" =~ [[:space:]\"\'@/\\\&\$\`] ]]; then
      bad "Password must be 8-30 chars with upper, lower and a digit, without space, quote, @ / & \$ \` or backslash"; continue
    fi
    ASM_PW=$p1
    ok "ASM password received (kept only in memory and in a temporary response file)"
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
  say "$title (silent). This takes several minutes."
  local rc=0 keep=$JOB_KEEP
  run_long "$title" "$out" "" "$who" "$@" < /dev/null || rc=$?
  if [[ $rc -eq 0 || $rc -eq 6 ]]; then [[ $rc -eq 6 ]] && warn "$title finished with warnings (see $out)"; installer_done_record "$title"; return 0; fi
  bad "$title failed (exit code $rc)"
  grep -E 'INS-[0-9]+|PRVF-|PRVG-|PRCZ-|\[FATAL\]|\[WARNING\]|SEVERE' <<< "$RUN_OUT" | head -n 15 | hint
  grep -oE '(/[A-Za-z0-9_./-]+/(logs|cfgtoollogs)/[A-Za-z0-9_./-]+\.log)' <<< "$RUN_OUT" | sort -u | head -n 3 | sed 's/^/installer log: /' | hint
  # the retries below never apply a Release Update a second time (the failed try may have applied it already)
  local -a args=("$@"); local home; home=$([[ "$who" == "grid" ]] && printf '%s' "$GRID_HOME" || printf '%s' "$DB_HOME")
  if ru_applied "$home"; then
    local -a a2=(); local i=0
    while [[ $i -lt ${#args[@]} ]]; do
      if [[ "${args[$i]}" == "-applyRU" || "${args[$i]}" == "-applyPSU" ]]; then i=$((i + 2)); continue; fi
      a2+=("${args[$i]}"); i=$((i + 1))
    done
    args=("${a2[@]}"); say "The Release Update is already in $home: a retry does not apply it again."
  fi
  if grep -q 'INS-08101' <<< "$RUN_OUT"; then
    local did; did=$([[ ${OS_MAJOR:-0} -ge 9 ]] && printf 'OL8' || printf 'OEL7.8')
    if [[ "${INS08101_RETRIED:-0}" -eq 0 ]] && [[ " ${ORA_ENV[*]} ${GRID_ENV[*]} " != *" CV_ASSUME_DISTID=$did "* ]]; then
      INS08101_RETRIED=1
      say "INS-08101: this installer does not know Oracle Linux $OS_MAJOR. Trying again with CV_ASSUME_DISTID=$did (the usual workaround)."
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
      if [[ $rc -eq 0 || $rc -eq 6 ]]; then warn "$title finished with CV_ASSUME_DISTID=$did"; installer_done_record "$title"; return 0; fi
      bad "$title failed again (exit code $rc)"; grep -E 'INS-[0-9]+|\[FATAL\]|SEVERE' <<< "$RUN_OUT" | head -n 10 | hint
    fi
    printf 'INS-08101: this installer does not know this Oracle Linux release. Use a newer Release Update:\nunzip it on this server, set RU_DIR=<folder> and OPATCH_ZIP in the settings (%s --settings, choose e),\nthen run the script again.\n' "$SELF" | hint
  fi
  if [[ -n "$ign" ]] && grep -qE 'INS-13013|INS-13014|INS-13016|PRVF-|PRVG-' <<< "$RUN_OUT"; then
    printf 'Some prerequisite checks failed (lines above). Fix them if you can.\n' | hint
    if confirm_word "Retry and IGNORE the prerequisite failures?" "IGNORE"; then
      rc=0
      JOB_KEEP=$keep
      ru_applied "$home" && { local -a a3=(); local j=0; while [[ $j -lt ${#args[@]} ]]; do if [[ "${args[$j]}" == "-applyRU" || "${args[$j]}" == "-applyPSU" ]]; then j=$((j + 2)); continue; fi; a3+=("${args[$j]}"); j=$((j + 1)); done; args=("${a3[@]}"); }
      run_long "$title (ignore prereq)" "${out%.log}_2.log" "" "$who" "${args[@]}" "$ign" < /dev/null || rc=$?
      if [[ $rc -eq 0 || $rc -eq 6 ]]; then warn "$title finished with ignored prerequisites"; installer_done_record "$title"; return 0; fi
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
  [[ -x "$1" ]] || { bad "Not found: $1"; return 1; }
  local out; out="$LOG_DIR/root_$(basename "$(dirname "$1")")_$(basename "$1" .sh)_$RUN_ID.log"
  if run_long "root script $1" "$out" "" root "$1" < /dev/null; then say "$1 completed"; return 0; fi
  bad "$1 failed"; printf '%s\n' "$RUN_OUT" | tail -n 15 | hint
  return 1
}
ru_args() {
  # with RU_DIR the image installer (gridSetup.sh, 18c+ runInstaller) applies that Release Update first
  # ($1 = grid: 12.2 gridSetup.sh calls the option -applyPSU)
  [[ -n "$RU_DIR" && -d "$RU_DIR" ]] || return 0
  # a home that already has the Release Update (an earlier try applied it) does not get it again
  local h; [[ "${1:-}" == "grid" ]] && h=$GRID_HOME || h=$DB_HOME
  if ru_applied "$h"; then say "The Release Update is already in $h: it is not applied again." >&2; return 0; fi
  if [[ "${1:-}" == "grid" && "$(want_rel grid)" == "12.2" ]]; then printf '%s\n' -applyPSU "$RU_DIR"
  else printf '%s\n' -applyRU "$RU_DIR"; fi
}
new_opatch() {
  # $1 home, $2 runner, $3 owner: the Release Update needs a newer OPatch than the base media has
  [[ -n "$RU_DIR" ]] || return 0
  [[ -n "$OPATCH_ZIP" && -f "$OPATCH_ZIP" ]] || { bad "RU_DIR is set but OPATCH_ZIP (the newest OPatch, p6880880) is not: set it with  $SELF --settings  (choose e)"; return 1; }
  media_trusted "$OPATCH_ZIP" || { bad "$OPATCH_ZIP may not be used (owner or mode)"; return 1; }

  # the old OPatch is kept next to it (no rm -rf of a part of a home)
  # the OPatch of the zip already in place (an earlier try): nothing to do
  local want_v have_v
  want_v=$(unzip -p "$OPATCH_ZIP" OPatch/version.txt 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)
  have_v=$(grep -oE '[0-9]+(\.[0-9]+)+' "$1/OPatch/version.txt" 2>/dev/null | head -n 1)
  if [[ -n "$want_v" && -n "$have_v" ]] && ! ver_lt "$have_v" "$want_v"; then say "$1/OPatch is already version $have_v (the zip has $want_v)"; return 0; fi
  say "Replacing $1/OPatch with $OPATCH_ZIP (needed by the Release Update)"
  if [[ -e "$1/OPatch" && -e "$1/OPatch.bak_$RUN_ID" ]]; then
    # a retry in this run: the original is kept already; the half copy goes
    run_logged "remove the OPatch of the failed try" "$2" rm -rf -- "$1/OPatch" || { bad "Cannot remove $1/OPatch"; return 1; }
  elif [[ -e "$1/OPatch" ]]; then
    run_logged "keep old OPatch" "$2" mv -T -- "$1/OPatch" "$1/OPatch.bak_$RUN_ID" || { bad "Cannot move $1/OPatch aside"; return 1; }
    journal OPATCH "$1/OPatch" "old=$1/OPatch.bak_$RUN_ID"
  fi
  run_logged "unzip OPatch" "$2" unzip -q -o "$OPATCH_ZIP" -d "$1" || { bad "unzip of OPatch failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  [[ -x "$1/OPatch/opatch" ]] || { bad "$1/OPatch/opatch missing after unzip (wrong file?)"; return 1; }
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
  [[ -f "$(unzip_marker)" ]] || return 0
  local t o dest list="" f hit rmcmd=""
  while IFS='|' read -r t o dest; do
    [[ -n "$t" ]] || continue
    hit=0; [[ -z "$dest" ]] && hit=1
    for f in "$@"; do [[ "$dest" == "$f" ]] && hit=1; done
    [[ $hit -eq 1 ]] || continue
    list+="  '$t' into ${dest:-(folder not recorded: the home or stage folder of that file)} (output $o)"$'\n'
    rmcmd+="grep -vF -- '|${o}|' '$(unzip_marker)' > '$(unzip_marker).n'; mv -f '$(unzip_marker).n' '$(unzip_marker)'"$'\n'
  done < "$(unzip_marker)"
  [[ -n "$list" ]] || return 0
  NOW="An earlier unzip did not finish; this folder is incomplete:"$'\n'"${list%$'\n'}"
  MANUAL_HOW="root  ->  shell"
  PLAN="Empty ONLY the folder named above (check that nothing is installed there: it must not be in $INVENTORY_DIR/ContentsXML/inventory.xml), then remove its line(s):
${rmcmd%$'\n'}
and answer r (the files are unpacked again)"
  return 1
}
stage_dir() { printf '%s/dg_stage_%s' "$(dirname "$INVENTORY_DIR")" "$1"; }   # for staged (12.x) media
unpack_media() {
  # $1 comma list of zip files, $2 target folder, $3 runner, $4 owner
  local files=$1 dest=$2 runner=$3 owner=$4 f
  [[ -d "$dest" ]] || make_dir "$dest" "$owner" || return 1
  IFS=',' read -ra _uz <<< "$files"
  for f in "${_uz[@]}"; do
    media_trusted "$f" || { bad "$f may not be used (owner or mode changed)"; return 1; }
    runuser -u "$owner" -- test -r "$f" || { bad "$owner cannot read $f (chmod 644 it)"; return 1; }
    local who=oracle; [[ "$runner" == "as_grid" ]] && who=grid
    local uo="$LOG_DIR/unzip_$(basename "$f" .zip)_$RUN_ID.log"
    # the marker is written first and removed only when the unzip worked: any other end leaves it
    install -d -m 700 "$STATE_DIR"
    printf '%s|%s|%s\n' "unzip $(basename "$f")" "$uo" "$dest" >> "$(unzip_marker)" && chmod 600 "$(unzip_marker)" \
      || { bad "Cannot write $(unzip_marker) (disk full?); the unzip is not started"; return 1; }
    run_long "unzip $(basename "$f")" "$uo" "" "$who" unzip -q -o "$f" -d "$dest" < /dev/null \
      || { bad "unzip failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
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
    if [[ -f /etc/oracle/olr.loc ]]; then GSTATE=HAS_DOWN; return; fi
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
  NOW="$1 is in the inventory, but this script has no record that its installer finished (or its programs are missing)"
  KIND_NOW=manual; MANUAL_HOW="$2  ->  shell"
  PLAN="If YOU installed this home and the installer finished without error (check the newest log under $INVENTORY_DIR/logs):
  as root:  touch $3      then answer r
If the installer failed or was stopped: fix the cause, remove the half home and answer r (it is installed again):
  $1/deinstall/deinstall     (if that fails: as root  rm -rf $1/*  and remove the HOME line of $1 from $INVENTORY_DIR/ContentsXML/inventory.xml)"
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
c_3_2() {
  use_grid || { NOW="Not needed (the primary does not use ASM)"; return 0; }
  users_ok || { NOW="Users do not exist yet (step 2.2)"; return 2; }
  grid_state
  case "$GSTATE" in
    DONE|ASM_DOWN|HAS_DOWN|NEED_CONFIGTOOLS|NEED_ROOT) NOW="Grid software is installed in $GRID_HOME"; return 0 ;;
    UNKNOWN) NOW="Cannot read the Grid state: $(head -n 2 <<< "$GSTATE_OUT")"; return 2 ;;
    HALF_INSTALLED) half_installed_plan "$GRID_HOME" "$GRID_USER" "$STATE_DIR/grid_install.done"; return 1 ;;
  esac
  [[ -n "$(asm_labels "$DATA_DG")" ]] || { NOW="No ASM disk for +$DATA_DG yet (step 2.13)"; return 2; }
  unzip_failed_check "$GRID_HOME" "$(stage_dir grid)" || return 2
  if [[ "$GSTATE" == "NEED_UNZIP" ]]; then
    media_ok "$GRID_MEDIA" || { NOW="Grid installer files are not known (step 3.1)"; return 2; }
    if ! media_is_staged "$GRID_MEDIA"; then
      [[ -z "$(ls -A "$GRID_HOME" 2>/dev/null)" ]] || { NOW="$GRID_HOME is not empty but has no gridSetup.sh"; return 2; }
    fi
  fi
  NOW="Grid Infrastructure is not installed"
  PLAN=""
  if [[ "$GSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$GRID_MEDIA"; then PLAN="unzip ${GRID_MEDIA//,/ + } into $(stage_dir grid) (as $GRID_USER)"$'\n'
    else PLAN="unzip $GRID_MEDIA into $GRID_HOME (as $GRID_USER)"$'\n'; fi
  fi
  PLAN+="Grid installer, silent, Oracle Restart (single server), as $GRID_USER${RU_DIR:+, applying the Release Update in $RU_DIR}
  disk group +$DATA_DG, EXTERNAL redundancy, disks $(asm_labels "$DATA_DG" | paste -sd' ' -)
  Grid home $GRID_HOME, base $GRID_BASE, inventory $INVENTORY_DIR
You will be asked a NEW password for ASM SYS/ASMSNMP (local to this server)"
  USING="same paths and disk group name as primary; response file from the template in the media"
  return 1
}
d_3_2() {
  if [[ "$GSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$GRID_MEDIA"; then unpack_media "$GRID_MEDIA" "$(stage_dir grid)" as_grid "$GRID_USER" || return 1
    else
      unpack_media "$GRID_MEDIA" "$GRID_HOME" as_grid "$GRID_USER" || return 1
      [[ -x "$GRID_HOME/gridSetup.sh" ]] || { bad "gridSetup.sh not found after unzip (wrong file?)"; return 1; }
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
      NOW="Grid root scripts have run (Oracle Restart is configured and running)"; return 0 ;;
    HAS_DOWN)
      if [[ -f "$(GRID_ROOT_DONE_FILE)" ]]; then NOW="Grid root scripts have run (Oracle High Availability Services is started in step 3.4)"; return 0; fi
      NOW="Oracle Restart is configured (olr.loc exists) but Oracle High Availability Services does not run: root.sh may have failed"
      KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
      PLAN="$GRID_HOME/bin/crsctl start has
If that fails, look at $GRID_HOME/cfgtoollogs/crsconfig/roothas_*.log, then undo and run root.sh again:
$GRID_HOME/crs/install/roothas.sh -deconfig -force
$GRID_HOME/root.sh"
      return 1 ;;
    NEED_ROOT) ;;
    *) NOW="Grid software is not installed (step 3.2)"; return 2 ;;
  esac
  # 12.1 Oracle Restart on Oracle Linux 7 (systemd) starts ohasd only with patch 18370031 (also inside a later PSU)
  if [[ "$(want_rel grid)" == "12.1" && "$OS_MAJOR" == "7" && ! -d "$GRID_HOME/inventory/oneoffs/18370031" ]] \
     && ! grep -qs '18370031' "$GRID_HOME"/inventory/oneoffs/*/etc/config/inventory.xml; then
    NOW="12.1 Grid on Oracle Linux 7: patch 18370031 must be applied BEFORE root.sh (otherwise ohasd does not start under systemd)"
    KIND_NOW=manual; MANUAL_HOW="$GRID_USER  ->  shell"
    PLAN="download patch 18370031 (My Oracle Support), unzip it, then:
$GRID_HOME/OPatch/opatch napply -oh $GRID_HOME -local <folder>/18370031
Then answer r (root.sh runs after it)."
    return 1
  fi
  NOW="Grid is installed, root scripts not run yet"
  local invd; invd=$(inventory_dir)
  PLAN=""
  [[ -x "$invd/orainstRoot.sh" ]] && PLAN="$invd/orainstRoot.sh"$'\n'
  PLAN+="$GRID_HOME/root.sh   (configures Oracle Restart on this server; its questions take the default answer)"
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
      NOW="Oracle Restart is running, ASM is not configured yet"
      if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then PLAN="gridSetup.sh -executeConfigTools -silent (as $GRID_USER): creates ASM, +$DATA_DG and the listener"
      else PLAN="$GRID_HOME/cfgtoollogs/configToolAllCommands (12.1, as $GRID_USER): creates ASM, +$DATA_DG and the listener"; fi
      [[ -n "$ASM_PW" ]] || PLAN+=$'\n'"You will be asked the password for ASM (SYS/ASMSNMP): the one typed in step 3.2 (it was not used yet), or a new one" ;;
    HAS_DOWN) NOW="Oracle High Availability Services is stopped"; PLAN="$GRID_HOME/bin/crsctl start has   (as root)" ;;
    ASM_DOWN) NOW="ASM is not ONLINE"; PLAN="crsctl start res ora.asm   (as $GRID_USER)" ;;
    UNKNOWN) NOW="Cannot read the Grid state: $(head -n 2 <<< "$GSTATE_OUT")"; return 2 ;;
    *) NOW="Grid root scripts did not run yet (step 3.3)"; return 2 ;;
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
      local n=0; say "waiting for ASM to come ONLINE ..."
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
  grid_sw_ok || { NOW="Grid is not installed (step 3.2)"; return 2; }
  dg_list || { NOW="Cannot query ASM ($(ora_errors "$SQL_OUT")) (step 3.4)"; return 2; }
  local list=$SQL_OUT ca="" cr=""
  dg_field "$DATA_DG"
  if [[ "$DG_S" == "MOUNTED" || "$DG_S" == "CONNECTED" ]]; then
    sql_asm "select max(decode(a.name,'compatible.asm',a.value))||'|'||max(decode(a.name,'compatible.rdbms',a.value)) from v\$asm_attribute a, v\$asm_diskgroup g where a.group_number=g.group_number and g.name='$DATA_DG';" \
      && IFS='|' read -r ca cr <<< "$(first_line)"
  elif [[ -z "$DG_S" ]]; then
    # the Grid configuration created ASM but not +DATA (it stopped half-way): created here like the others
    warn "+$DATA_DG does not exist although ASM runs (the Grid configuration did not finish it); it is created now with the default attributes"
  fi
  SQL_OUT=$list
  local dg info="" todo="" disks
  DG_TODO=""
  for dg in $(asm_dgs); do
    dg_field "$dg"
    if [[ "$DG_S" == "MOUNTED" || "$DG_S" == "CONNECTED" ]]; then info+="+$dg $DG_S, free $DG_F MB of $DG_T MB"$'\n'; continue; fi
    if [[ -n "$DG_S" ]]; then
      NOW="Disk group +$dg exists here but is $DG_S"
      KIND_NOW=manual; MANUAL_HOW="$GRID_USER  ->  export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM ; \$ORACLE_HOME/bin/sqlplus / as sysasm"
      PLAN="Mount it only if all its disks belong to THIS standby (never a disk of the primary):
select path, header_status, name from v\$asm_disk;
alter diskgroup $dg mount;"
      return 1
    fi
    [[ -n "$(asm_labels "$dg")" ]] || { NOW="No ASM disk for +$dg yet (step 2.13)"; return 2; }
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
  NOW="Disk groups to create or mount:$todo"
  PLAN="As $GRID_USER:  export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM ; \$ORACLE_HOME/bin/sqlplus / as sysasm
$DG_TODO"
  USING="same disk group names as primary; attributes compatible.asm/rdbms as +$DATA_DG"
  return 1
}
d_3_5() {
  local s
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if ! sql_asm "$s"; then
      bad "Failed ($(ora_errors "$SQL_OUT")): $s"
      if grep -qE 'ORA-15018|ORA-15030|ORA-15033' <<< "$SQL_OUT"; then
        printf 'A disk already has an ASM header (an earlier try that was interrupted). Only for disks made by this\nscript (%s) the statement may be repeated with FORCE:\n  %s\n' "$(asm_disks_file)" "$(sed -E "s/'((\/|ORCL:)[^']*)'/'\1' force/g" <<< "$s")" | hint
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
  else DB_EDITION=EE; warn "Edition not recognised in '$b'; using Enterprise Edition"; fi
  [[ "$DB_EDITION" == "EE" ]] || fatal "The primary is Standard Edition ($b). Data Guard needs Enterprise Edition. This script cannot build a standby for it."
}

# ---- 3.6 DB software ----
c_3_6() {
  users_ok || { NOW="Users do not exist yet (step 2.2)"; return 2; }
  db_state
  case "$DSTATE" in
    DONE|NEED_ROOT) NOW="Database software is installed in $DB_HOME"; return 0 ;;
    HALF_INSTALLED) half_installed_plan "$DB_HOME" "$ORACLE_USER" "$STATE_DIR/db_install.done"; return 1 ;;
  esac
  primary_edition || { NOW="Cannot read the primary edition"; return 2; }
  unzip_failed_check "$DB_HOME" "$(stage_dir db)" || return 2
  if [[ "$DSTATE" == "NEED_UNZIP" ]]; then
    media_ok "$DB_MEDIA" || { NOW="Database installer files are not known (step 3.1)"; return 2; }
    if ! media_is_staged "$DB_MEDIA"; then
      [[ -z "$(ls -A "$DB_HOME" 2>/dev/null)" ]] || { NOW="$DB_HOME is not empty but has no runInstaller"; return 2; }
    fi
  fi
  NOW="Database software is not installed"
  PLAN=""
  if [[ "$DSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$DB_MEDIA"; then PLAN="unzip ${DB_MEDIA//,/ + } into $(stage_dir db) (as $ORACLE_USER)"$'\n'
    else PLAN="unzip $DB_MEDIA into $DB_HOME (as $ORACLE_USER)"$'\n'; fi
  fi
  PLAN+="runInstaller, silent, Software Only, Enterprise Edition (as $ORACLE_USER)${RU_DIR:+, applying the Release Update in $RU_DIR}
  home $DB_HOME, base $ORACLE_BASE, OS groups as on primary"
  USING="same home and base as primary; response file from the template in the media"
  return 1
}
d_3_6() {
  local kind=image
  if [[ "$DSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$DB_MEDIA"; then unpack_media "$DB_MEDIA" "$(stage_dir db)" as_oracle "$ORACLE_USER" || return 1
    else
      unpack_media "$DB_MEDIA" "$DB_HOME" as_oracle "$ORACLE_USER" || return 1
      [[ -x "$DB_HOME/runInstaller" ]] || { bad "runInstaller not found after unzip (wrong file?)"; return 1; }
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
      NOW="Database software installed, root.sh not run yet"
      PLAN=""; [[ -x "$(inventory_dir)/orainstRoot.sh" && ! -f /etc/oraInst.loc ]] && PLAN="$(inventory_dir)/orainstRoot.sh"$'\n'
      PLAN+="$DB_HOME/root.sh   (its questions take the default answer)"; return 1 ;;
    HALF_INSTALLED) NOW="The database installer did not finish (step 3.6)"; return 2 ;;
    *) NOW="Database software is not installed (step 3.6)"; return 2 ;;
  esac
}
d_3_7() {
  if [[ ! -f /etc/oraInst.loc && -x "$(inventory_dir)/orainstRoot.sh" ]]; then run_root_script "$(inventory_dir)/orainstRoot.sh" || return 1; fi
  run_root_script "$DB_HOME/root.sh" || return 1
  journal ROOTSH "$DB_HOME" "root.sh of the database home (/usr/local/bin/oraenv, coraenv, dbhome; /etc/oratab)"
  local s; for s in db grid; do [[ -d "$(stage_dir $s)" ]] && say "The unpacked installer in $(stage_dir $s) can be removed now (rm -rf)."; done
  return 0
}

# ---- 3.8 read/write home (18c and newer) ----
OBH=""
c_3_8() {
  db_sw_ok || { NOW="Database software is not installed (step 3.6)"; return 2; }
  [[ -x "$DB_HOME/bin/orabasehome" ]] || { NOW="Not needed (read-only homes exist only from 18c)"; return 0; }
  run_logged "orabasehome" as_oracle "$DB_HOME/bin/orabasehome" || { NOW="Cannot run $DB_HOME/bin/orabasehome"; return 2; }
  OBH=$(printf '%s\n' "$RUN_OUT" | grep -E '^/' | head -n 1); OBH=${OBH%/}
  if [[ "$OBH" == "$DB_HOME" ]]; then NOW="Read/write Oracle home (orabasehome = $DB_HOME)"; return 0; fi
  NOW="Oracle home is READ-ONLY (orabasehome = $OBH)"
  if [[ -n "$(ls -A "$ORACLE_BASE/dbs" 2>/dev/null)" ]] || pgrep -f "^ora_pmon_" >/dev/null 2>&1; then
    NOW+=$'\n'"A database already uses this home (files in $ORACLE_BASE/dbs or a running instance); the script will not convert it"
    return 2
  fi
  PLAN="roohctl -disable   (as $ORACLE_USER; new home without any database)
so spfile, password file and tnsnames.ora are inside $DB_HOME"
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
  use_grid || { NOW="Not needed (no Grid; the listener is set up in phase 5)"; return 0; }
  grid_sw_ok || { NOW="Grid is not installed (step 3.2)"; return 2; }
  local r off=() miss=() on=() dg
  local -a res=(ora.asm "ora.$SB_LSNR.lsnr")
  for dg in $(asm_dgs); do res+=("ora.${dg^^}.dg"); done
  for r in "${res[@]}"; do
    run_logged "crsctl stat res $r" as_grid timeout 60 "$GRID_HOME/bin/crsctl" stat res "$r" || true
    if grep -q 'CRS-2613' <<< "$RUN_OUT" || ! grep -q "NAME=$r" <<< "$RUN_OUT"; then miss+=("$r")
    elif grep -q 'STATE=ONLINE' <<< "$RUN_OUT"; then on+=("$r")
    else off+=("$r"); fi
  done
  if [[ ${#off[@]} -eq 0 && ${#miss[@]} -eq 0 ]]; then NOW="ONLINE: ${on[*]}"; return 0; fi
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
  NOW="Not ONLINE: ${off[*]+"${off[*]}"} ${miss[*]+"${miss[*]}"}"
  PLAN="As $GRID_USER:
$RES_TODO"
  return 1
}
d_3_9() {
  local c
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    local -a w=(); read -ra w <<< "$c"
    run_logged "$c" as_grid timeout 300 "$GRID_HOME/bin/${w[0]}" "${w[@]:1}" || { bad "$c failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    say "ran: $c"
    [[ "$c" == "srvctl add listener"* ]] && journal LSNRRES "$SB_LSNR" "srvctl add listener"
  done <<< "$RES_TODO"
}

# ---- 3.10 listener port equal to primary (Grid listener) ----
c_3_10() {
  use_grid || { NOW="Not needed here (the database-home listener is created with port $PORT in phase 5)"; return 0; }
  grid_sw_ok || { NOW="Grid is not installed (step 3.2)"; return 2; }
  run_logged "lsnrctl status" as_grid timeout 60 "$GRID_HOME/bin/lsnrctl" status "$SB_LSNR" || { NOW="Listener $SB_LSNR is not running (step 3.9)"; return 2; }
  if grep -q "(PROTOCOL=TCP)(HOST=[^)]*)(PORT=$PORT)" <<< "$(norm "$RUN_OUT")"; then NOW="Listener $SB_LSNR listens on port $PORT (same as primary)"; return 0; fi
  local cur; cur=$(norm "$RUN_OUT" | grep -oE '\(PROTOCOL=TCP\)\(HOST=[^)]*\)\(PORT=[0-9]+\)' | head -n 1 | grep -oE '[0-9]+\)$' | tr -d ')')
  L310_CUR=$cur
  NOW="Listener listens on port ${cur:-?}, primary uses $PORT"
  PLAN="As $GRID_USER:
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
  db_sw_ok || { NOW="Database software is not installed (step 3.6)"; return 2; }
  need_ssh || return 2
  primary_edition || { NOW="Cannot read the primary edition"; return 2; }
  local rel want h pp lp missing extra report="" bad_rel=""
  rel=$(local_release || true); want=$(want_rel)
  if [[ -n "$rel" ]]; then
    if [[ "$DB_MAJOR" == "12" ]]; then [[ "$rel" == "$want" ]] || bad_rel="installed release $rel, primary is $want"
    else [[ "${rel%%.*}" == "$DB_MAJOR" ]] || bad_rel="installed release $rel, primary is $DB_MAJOR"; fi
  fi
  if [[ -n "$bad_rel" ]]; then
    NOW="The database software here is another release: $bad_rel"
    KIND_NOW=manual; MANUAL_HOW="root"
    PLAN="Remove this installation and install release $want (steps 3.1, 3.6): the standby must have the same release as the primary."
    return 1
  fi
  for h in "$DB_HOME" ${GRID_HOME:+"$GRID_HOME"}; do
    use_grid || [[ "$h" != "$GRID_HOME" ]] || continue
    pp=$(primary_patches "$h") || { NOW="Cannot read $h/inventory on primary (the ssh user must be able to read it)"; return 2; }
    lp=$(local_patches "$h")
    missing=$(comm -23 <(printf '%s\n' "$pp" | grep -v '^$') <(printf '%s\n' "$lp" | grep -v '^$') | paste -sd' ' -)
    extra=$(comm -13 <(printf '%s\n' "$pp" | grep -v '^$') <(printf '%s\n' "$lp" | grep -v '^$') | paste -sd' ' -)
    if [[ -n "$missing$extra" ]]; then
      report+="$h:${missing:+ missing here: $missing}${extra:+  only here: $extra}"$'\n'
    fi
  done
  if [[ -z "$report" ]]; then NOW="Same patches as primary ($(local_patches "$DB_HOME" | wc -l) in $DB_HOME${GRID_HOME:+ and the Grid home}), release ${rel:-$want}, Enterprise Edition"; return 0; fi
  NOW="The homes here do not have the same patches as primary:"$'\n'"${report%$'\n'}"
  KIND_NOW=manual; MANUAL_HOW="root / $ORACLE_USER  ->  OPatch"
  PLAN="Apply the same patches as primary to the homes on this server:
  1) on primary, as the owner of the home, see the list:   <home>/OPatch/opatch lspatches
  2) put the newest OPatch (patch 6880880) into $DB_HOME${GRID_HOME:+ and $GRID_HOME}"
  if use_grid; then
    PLAN+=$'\n'"  3) Release Update, as root:   $GRID_HOME/OPatch/opatchauto apply <RU folder> -oh $GRID_HOME ; $DB_HOME/OPatch/opatchauto apply <RU folder> -oh $DB_HOME"
  else
    PLAN+=$'\n'"  3) Release Update, as $ORACLE_USER:   cd <RU folder> ; $DB_HOME/OPatch/opatch apply"
  fi
  PLAN+=$'\n'"  4) one-off patches, as $ORACLE_USER:   cd <patch folder> ; $DB_HOME/OPatch/opatch apply"
  [[ $DB_MAJOR -ge 18 ]] && PLAN+=$'\n'"Easier: install from a gold image of the primary home (see step 3.1)."
  if use_grid && ! single_owner; then
    PLAN+=$'\n'"After opatch on the database home (role separation), as root:  $GRID_HOME/bin/setasmgidwrap o=$DB_HOME/bin/oracle"
  fi
  return 1
}

phase_3() {
  phase_header 3 "Oracle software on this server"
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
    warn "The ssh connection to primary was closed. Opening it again."
    open_ssh && ssh_alive && return 0
  fi
  NOW="No ssh connection to primary (step 1.2)"; return 1
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
dg_config_has() {
  local inner=${1#*DG_CONFIG=}
  [[ "$inner" != "$1" ]] || return 1
  has_token "$inner" "${2^^}"
}

# ---- 4.1 ----
c_4_1() {
  need_ssh || return 2
  # every change of phase 4 (scope=spfile/both) and the duplicate (spfile clause) needs a primary started from an spfile
  prim_sql "select nvl(value,'-') from v\$parameter where name='spfile';" || { NOW="Query failed ($(ora_errors "$SQL_OUT"))"; return 2; }
  if [[ "$(first_line)" == "-" ]]; then
    NOW="The primary was started from a text pfile (no spfile): the changes below (scope=spfile/both) and the copy need an spfile"
    PLAN="create pfile='?/dbs/init${PRIMARY_SID}_before_dg.ora' from memory;
create spfile from memory;
-- then restart the primary once (shutdown immediate; startup), at a time with little load, for example at night:
-- it then uses the spfile. The other changes of this phase work only after that restart (scope=spfile/both)."
    PLAN_UNDO="remove \$ORACLE_HOME/dbs/spfile${PRIMARY_SID}.ora and restart with:  startup pfile='\$ORACLE_HOME/dbs/init${PRIMARY_SID}_before_dg.ora'"
    return 1
  fi
  prim_sql "select log_mode||'|'||force_logging from v\$database;" || { NOW="Query failed ($(ora_errors "$SQL_OUT"))"; return 2; }
  local lm fl; IFS='|' read -r lm fl <<< "$(first_line)"
  if [[ "$lm" == "ARCHIVELOG" && "$fl" == "YES" ]]; then NOW="ARCHIVELOG, FORCE LOGGING = YES"; return 0; fi
  NOW="log_mode=$lm  force_logging=$fl"
  PLAN=""
  [[ "$fl" != "YES" ]] && PLAN+="alter database force logging;"$'\n'
  [[ "$lm" != "ARCHIVELOG" ]] && PLAN+="-- needs a short downtime:
shutdown immediate
startup mount
alter database archivelog;
alter database open;"
  PLAN=${PLAN%$'\n'}
  PLAN_UNDO=""; [[ "$fl" != "YES" ]] && PLAN_UNDO="alter database no force logging;"
  [[ "$lm" != "ARCHIVELOG" ]] && PLAN_UNDO+="${PLAN_UNDO:+ }-- ARCHIVELOG is kept (needed for every backup; not taken back)"
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
  [[ -n "$bclause" ]] && SRL_INFO_EXTRA="the online logs use 4096-byte blocks: the standby disks must support 4K sectors (else ORA-01378)" || SRL_INFO_EXTRA=""
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
    SRL_INFO+="thread $t: $c online groups, $have standby logs of ${mb}M, need $((c + 1))"$'\n'
    while [[ $have -lt $((c + 1)) && $pool0 -gt 0 ]]; do have=$((have + 1)); pool0=$((pool0 - 1)); done
    while [[ $have -lt $((c + 1)) ]]; do
      if [[ "$omf" != "-" && -n "$omf" ]]; then spec=""
      elif [[ "$dir" == +* ]]; then spec=" ('${dir%%/*}')"
      else g=$((g + 1)); spec=" group $g ('$dir/srl_t${t}_g${g}.log')"; fi
      SRL_STMTS+="alter database add standby logfile thread $t$spec size ${mb}M$bclause;"$'\n'
      have=$((have + 1))
    done
  done <<< "$threads"
  num "$small" && [[ $small -gt 0 ]] && SRL_INFO+="$small standby log(s) are smaller than the online logs and are not counted (drop them: alter database drop standby logfile group <n>;)"$'\n'
  [[ -n "$SRL_INFO_EXTRA" ]] && SRL_INFO+="$SRL_INFO_EXTRA"$'\n'
  SRL_INFO=${SRL_INFO%$'\n'}; SRL_STMTS=${SRL_STMTS%$'\n'}
  [[ -z "$SRL_STMTS" ]]
}
c_4_2() {
  need_ssh || return 2
  local rc=0; srl_statements prim_sql || rc=$?
  [[ $rc -eq 2 ]] && { NOW="Query failed ($(ora_errors "$SQL_OUT"))"; return 2; }
  NOW=$SRL_INFO
  [[ $rc -eq 0 ]] && return 0
  PLAN=$SRL_STMTS
  USING="rule: standby redo logs = online groups + 1 per thread, same size as the largest online log"
  local gl; gl=$(grep -oE 'group [0-9]+' <<< "$SRL_STMTS" | awk '{print $2}' | paste -sd',' -)
  if [[ -n "$gl" ]]; then PLAN_UNDO="alter database drop standby logfile group <n>;  for each of the groups $gl  (then remove their files)"
  else PLAN_UNDO="alter database drop standby logfile group <n>;  for each NEW group (select group#,thread#,bytes from v\$standby_log; - the groups that were not there before)"; fi
  return 1
}

# ---- 4.3 ----
c_4_3() {
  need_ssh || return 2
  p_param log_archive_config || { NOW="Query failed"; return 2; }
  if dg_config_has "$PVAL" "$PRIMARY_UNIQUE" && dg_config_has "$PVAL" "$STANDBY_UNIQUE"; then NOW="log_archive_config = $PVAL"; return 0; fi
  NOW="log_archive_config = $PVAL"
  dg_config_names_ok "$PVAL" || { NOW+=" (the names in it cannot be read safely; add $STANDBY_UNIQUE to the dg_config list by hand, keep every other name)"; return 2; }
  PLAN="alter system set log_archive_config='$(lac_merged "$PVAL")' scope=both;"
  [[ "$PVAL" == *DG_CONFIG=* ]] && PLAN+=$'\n'"-- the names that were already in the list are kept; $STANDBY_UNIQUE is added"
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
  find_dest || { NOW="Cannot find a free log_archive_dest_N on primary"; return 2; }
  p_param "log_archive_dest_$DEST_N" || { NOW="Query failed"; return 2; }
  if has_token "$PVAL" "SERVICE=${STANDBY_TNS^^}" && has_token "$PVAL" "DB_UNIQUE_NAME=${STANDBY_UNIQUE^^}"; then NOW="log_archive_dest_$DEST_N = $PVAL"; return 0; fi
  NOW="log_archive_dest_$DEST_N = $PVAL"
  [[ "$DEST_N" != "2" ]] && NOW+=$'\n'"log_archive_dest_2 is already used for something else, so dest $DEST_N is used"
  PLAN=""
  if [[ -n "$OLD_ARCH_DEST" ]]; then
    NOW+=$'\n'"The primary uses the old parameter log_archive_dest; log_archive_dest_N cannot be used with it (ORA-16018)"
    # the duplex folder exactly as written (p_param changes the case)
    local dup="-"; prim_sql "select nvl(value,'-') from v\$parameter where name='log_archive_duplex_dest';" && dup=$(first_line)
    PLAN="-- first change log_archive_dest to log_archive_dest_1 (same folder; between the statements the
-- archiver writes to \$ORACLE_HOME/dbs for a moment, so run them together):
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
-- (it is enabled at step 9.5, after the standby exists)"
  PLAN_UNDO="alter system reset log_archive_dest_$DEST_N scope=both; alter system reset log_archive_dest_state_$DEST_N scope=both;"
  [[ -n "$OLD_ARCH_DEST" ]] && PLAN_UNDO+="  (log_archive_dest_1='location=$OLD_ARCH_DEST' can stay)"
  return 1
}

# ---- 4.5 ----
c_4_5() {
  need_ssh || return 2
  p_param standby_file_management || { NOW="Query failed"; return 2; }
  [[ "$PVAL" == "AUTO" ]] && { NOW="standby_file_management = AUTO"; return 0; }
  NOW="standby_file_management = $PVAL"
  PLAN="alter system set standby_file_management=auto scope=both;"
  PLAN_UNDO="alter system set standby_file_management=${PVAL:-MANUAL} scope=both;"
  return 1
}

# ---- 4.6 ----
c_4_6() {
  need_ssh || return 2
  # read again from the primary: a change made at this step is seen at once
  local of=$FRA_LOC oa=$ARCH_LOC
  read_arch_params || { NOW="Cannot read parameters on primary"; return 2; }
  [[ "$of|$oa" != "$FRA_LOC|$ARCH_LOC" && "$MODE" == "run" ]] && { save_settings; warn "Recovery area / archive destination changed on primary: now ${FRA_LOC:-none} / ${ARCH_LOC:-none}. $( { step_in_range 2.12 && [[ -z "${STEP_RESULT[2.12]:-}" ]]; } && printf 'Phase 2 of this run uses the new value.' || printf 'This server must have it too: after this run, run  %s --from 2.12' "$SELF")"; }
  if [[ "$ARCH_LOC" == "USE_DB_RECOVERY_FILE_DEST" && -n "$FRA_LOC" ]]; then NOW="Archived logs go to the recovery area $FRA_LOC ($FRA_MB MB)"; return 0; fi
  if [[ -n "$ARCH_LOC" && "$ARCH_LOC" != "USE_DB_RECOVERY_FILE_DEST" ]]; then
    NOW="Archived logs go to $ARCH_LOC${FRA_LOC:+ (recovery area $FRA_LOC)}"
    [[ -n "$FRA_LOC" ]] || NOW+=$'\n'"No recovery area: fine for Data Guard, but flashback and automatic deletion of applied logs need one"
    return 0
  fi
  NOW="The primary has no archive destination and no recovery area (archived logs go to \$ORACLE_HOME/dbs)"
  if [[ -n "$DATA_DG" ]]; then
    PLAN="alter system set db_recovery_file_dest_size=<size, e.g. 200G> scope=both;
alter system set db_recovery_file_dest='+<a disk group for it, e.g. FRA>' scope=both;"
  else
    PLAN="-- a folder with enough space, owned by $ORACLE_USER, for example:
host mkdir -p /u01/app/oracle/fast_recovery_area
alter system set db_recovery_file_dest_size=<size, e.g. 200G> scope=both;
alter system set db_recovery_file_dest='/u01/app/oracle/fast_recovery_area' scope=both;"
  fi
  PLAN+=$'\n'"-- archived logs of the primary start going there; then answer r here"
  PLAN_UNDO="alter system reset db_recovery_file_dest scope=both; alter system reset db_recovery_file_dest_size scope=both;  (after the archived logs in it were backed up)"
  return 1
}

# ---- 4.7 ----
c_4_7() {
  need_ssh || return 2
  p_param remote_login_passwordfile || { NOW="Query failed"; return 2; }
  local rlp=$PVAL
  prim_sql "select count(*) from v\$pwfile_users where username='SYS' and sysdba='TRUE';" || { NOW="Query failed"; return 2; }
  local n; n=$(first_line); num "$n" || { NOW="Unexpected answer: $n"; return 2; }
  if [[ ( "$rlp" == "EXCLUSIVE" || "$rlp" == "SHARED" ) && "$n" -ge 1 ]]; then NOW="remote_login_passwordfile = $rlp, SYS has SYSDBA in the password file"; RLP_PENDING=0; return 0; fi
  NOW="remote_login_passwordfile = $rlp, SYS in password file: $([[ "$n" -ge 1 ]] && echo yes || echo no)"
  PLAN=""; PLAN_UNDO=""; RLP_PENDING=0
  if [[ "$rlp" != "EXCLUSIVE" && "$rlp" != "SHARED" ]]; then
    # already set in the spfile? then only the restart is missing
    local sp="-"
    prim_sql "select nvl(max(upper(value)),'-') from v\$spparameter where name='remote_login_passwordfile';" && sp=$(first_line | tr -d "\"'")
    if [[ "$sp" == "EXCLUSIVE" || "$sp" == "SHARED" ]]; then
      RLP_PENDING=1
      NOW+=$'\n'"remote_login_passwordfile=$sp is already in the spfile: it takes effect at the next restart of the primary."
      NOW+=$'\n'"Answer s now; the duplicate (step 8.1) refuses to run until the primary was restarted."
      PLAN="-- restart the primary database at a time with little load (for example at night) (as $ORACLE_USER, sqlplus / as sysdba):
shutdown immediate
startup"
    else
      PLAN+="alter system set remote_login_passwordfile=exclusive scope=spfile;
-- then restart the primary database at a time with little load (for example at night)"$'\n'
      PLAN_UNDO="alter system set remote_login_passwordfile=${rlp:-NONE} scope=spfile;  (restart)"
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
      NOW+=$'\n'"(a password file in ASM that only Oracle Restart knows: check first on the primary as $ORACLE_USER:  $DB_HOME/bin/srvctl config database -db $PRIMARY_UNIQUE | grep -i password)"
    fi
    if [[ "$pwf" == "?" ]]; then
      NOW+=$'\n'"Cannot tell whether the primary has a password file (no answer from the primary): check again later"; return 2
    elif [[ "$pwf" == "-" ]]; then
      local fmt=12.2; [[ "$PRIMARY_VERSION" == 12.1* ]] && fmt=12
      if [[ -n "$GRID_HOME" && "$CFD" == +* ]]; then
        PLAN="-- the primary has NO password file. In a SHELL as $GRID_USER/$ORACLE_USER (not in sqlplus), create it in ASM
-- (orapwd asks for the sys password; use the SAME one as now;
-- if orapwd answers OPW-00029 (password complexity), use format=12):
orapwd file='$(norm_loc "$CFD")/${PRIMARY_UNIQUE^^}/orapw${PRIMARY_UNIQUE,,}' dbuniquename=$PRIMARY_UNIQUE format=$fmt
-- only if 'srvctl config database -db $PRIMARY_UNIQUE' works (the database is registered):
srvctl modify database -db $PRIMARY_UNIQUE -pwfile '$(norm_loc "$CFD")/${PRIMARY_UNIQUE^^}/orapw${PRIMARY_UNIQUE,,}'
-- if this step still says SYS is missing afterwards, restart the primary once"$'\n'"$PLAN"
      else
        PLAN="-- the primary has NO password file. In a SHELL as $ORACLE_USER (not in sqlplus), create it
-- (orapwd asks for the sys password; use the SAME one as now;
-- if orapwd answers OPW-00029 (password complexity), use format=12):
orapwd file=\$ORACLE_HOME/dbs/orapw$PRIMARY_SID format=$fmt"$'\n'"$PLAN"
      fi
      PLAN_UNDO+="${PLAN_UNDO:+ ; }remove the new password file"
    elif [[ "$rlp" != "EXCLUSIVE" && "$rlp" != "SHARED" ]]; then
      NOW+=$'\n'"The password file exists ($pwf); SYS is checked again after the restart"
    else
      PLAN+="alter user sys identified by \"<the same sys password as now>\";
-- (use the SAME password: every client that logs in as sys uses it; a password change is not taken back)"
    fi
  fi
  PLAN=${PLAN%$'\n'}
  return 1
}
RLP_PENDING=0

# ---- 4.8 ----
c_4_8() {
  need_ssh || return 2
  p_param fal_server || { NOW="Query failed"; return 2; }
  if has_token "$PVAL" "${STANDBY_TNS^^}"; then NOW="fal_server = $PVAL"; return 0; fi
  NOW="fal_server = $PVAL (used only after a switchover)"
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
  [[ $PROBE_TIMED_OUT -eq 1 ]] && { NOW="No answer from the primary for tnsping within 120 s; checked again with r"; return 2; }
  cls=$(tnsping_class "$RUN_OUT")
  PLAN_UNDO="remove the $STANDBY_TNS entry from $PRIMARY_TNS_ADMIN/tnsnames.ora (if you changed an entry that was there before: put back the copy of the file made before the edit)"
  if [[ "$cls" == "OK" || "$cls" == "NOLISTENER" ]] && grep -qi 'TNSNAMES adapter' <<< "$RUN_OUT"; then
    if tns_desc_ok "$RUN_OUT" "$STANDBY_HOST" "$STANDBY_SERVICE"; then
      NOW="Primary tnsnames.ora has $STANDBY_TNS -> $STANDBY_HOST:$PORT/$STANDBY_SERVICE (UR=A)"
      [[ "$cls" == "NOLISTENER" ]] && NOW+=$'\n'"(nothing answers on this server yet: the listener comes in phase 5; the alias itself is right)"
      return 0
    fi
    NOW="Primary alias $STANDBY_TNS exists but is different: $TNS_WHY"
    PLAN="Edit $PRIMARY_TNS_ADMIN/tnsnames.ora on primary (first: cp -p tnsnames.ora tnsnames.ora.bak_\$(date +%F)); the entry must be:
$(tns_block "$STANDBY_TNS" "$STANDBY_HOST" "$STANDBY_SERVICE")"
    return 1
  fi
  [[ "$cls" == "OTHER" ]] && { NOW="tnsping $STANDBY_TNS on primary gave an unexpected answer: $(ora_errors "$RUN_OUT")"; return 2; }
  NOW="The alias $STANDBY_TNS is not in $PRIMARY_TNS_ADMIN/tnsnames.ora on primary (tnsping)"
  PLAN="cp -p $PRIMARY_TNS_ADMIN/tnsnames.ora $PRIMARY_TNS_ADMIN/tnsnames.ora.bak_\$(date +%F)
cat >> $PRIMARY_TNS_ADMIN/tnsnames.ora <<'EOF'

$(tns_block "$STANDBY_TNS" "$STANDBY_HOST" "$STANDBY_SERVICE")
EOF
env ORACLE_HOME=$DB_HOME TNS_ADMIN=$PRIMARY_TNS_ADMIN $DB_HOME/bin/tnsping $STANDBY_TNS
# (TNS-12541 'no listener' is fine before phase 5)"
  USING="standby host $STANDBY_HOST, port $PORT, service $STANDBY_SERVICE"
  return 1
}

# ---- 4.10 ----
c_4_10() {
  need_ssh || return 2
  local lown; lown=$([[ "$PRIMARY_LISTENER_HOME" == "$DB_HOME" ]] && printf '%s' "$ORACLE_USER" || printf '%s' "$GRID_USER")
  PRIMARY_HOW_STEP="$lown  ->  edit $PRIMARY_LISTENER_HOME/network/admin/listener.ora (or the listener.ora of its TNS_ADMIN)"
  if [[ -n "${PRIMARY_LISTENER_TNS_ADMIN:-}" ]]; then prim_probe lsnr "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME" "$PRIMARY_LISTENER_TNS_ADMIN" || { NOW="Cannot read the primary listener status"; return 2; }
  else prim_probe lsnr "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME" || { NOW="Cannot read the primary listener status"; return 2; }; fi
  if grep -qF "Instance \"$PRIMARY_SID\", status UNKNOWN" <<< "$RUN_OUT"; then
    NOW="Primary listener has a static entry for $PRIMARY_SID"; return 0
  fi
  NOW="Primary listener has no static entry for $PRIMARY_SID (needed for switchover and broker, not for this setup)"
  PLAN="Add inside SID_LIST_$LISTENER_NAME (create the block if it does not exist).
ORACLE_HOME must be the DATABASE home:
SID_LIST_$LISTENER_NAME =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = $PRIMARY_SERVICE)
      (SID_NAME = $PRIMARY_SID)
      (ORACLE_HOME = $DB_HOME)
    )
  )
then:  ORACLE_HOME=$PRIMARY_LISTENER_HOME $PRIMARY_LISTENER_HOME/bin/lsnrctl reload $LISTENER_NAME"
  PLAN_UNDO="remove that SID_DESC block from listener.ora, then lsnrctl reload $LISTENER_NAME"
  return 1
}

# ---- 4.11 environment of oracle on primary (information) ----
c_4_11() {
  need_ssh || return 2
  if [[ "$PRIMARY_SSH_USER" != "$ORACLE_USER" ]]; then NOW="Not checked (ssh user $PRIMARY_SSH_USER is not $ORACLE_USER)"; return 0; fi
  PRIMARY_HOW_STEP="$ORACLE_USER  ->  edit ~/.bash_profile"
  prim_probe profile || true
  [[ $PROBE_TIMED_OUT -eq 1 ]] && { NOW="No answer from the primary within the time limit; checked again with r"; return 2; }
  local sid home
  sid=$(grep -E 'ORACLE_SID=' <<< "$RUN_OUT" | tail -n 1 | sed -E 's/.*ORACLE_SID=//; s/["'"'"']//g; s/[[:space:]].*//')
  home=$(grep -E 'ORACLE_HOME=' <<< "$RUN_OUT" | tail -n 1 | sed -E 's/.*ORACLE_HOME=//; s/["'"'"']//g; s/[[:space:]].*//')
  home=${home%/}
  if [[ "$sid" == "$PRIMARY_SID" && ( "$home" == "$DB_HOME" || "$home" == *'$'* ) ]]; then NOW="~/.bash_profile of $ORACLE_USER on primary sets ORACLE_SID=$sid and ORACLE_HOME"; return 0; fi
  NOW="~/.bash_profile of $ORACLE_USER on primary: ORACLE_SID=${sid:-<not set>} ORACLE_HOME=${home:-<not set>}"
  NOW+=$'\n'"(this script does not need it, but sqlplus/rman/dgmgrl by hand do)"
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
  phase_header 4 "Primary readiness (checked read-only; you make the changes)"
  STEP_TITLE_HINT=([4.1]="ARCHIVELOG and FORCE LOGGING" [4.2]="Standby redo logs" [4.3]="log_archive_config" [4.4]="log_archive_dest_N (redo to standby)" [4.5]="standby_file_management" [4.6]="Archive destination / recovery area" [4.7]="Password file and SYS" [4.8]="fal_server (for switchover, optional)")
  batch_primary_steps 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8
  run_step 4.1  primary "ARCHIVELOG and FORCE LOGGING" c_4_1
  run_step 4.2  primary "Standby redo logs on primary" c_4_2
  run_step 4.3  primary "log_archive_config" c_4_3
  run_step 4.4  primary "log_archive_dest_N (redo to standby)" c_4_4
  run_step 4.5  primary "standby_file_management" c_4_5
  run_step 4.6  primary "Archive destination / recovery area" c_4_6
  run_step 4.7  primary "Password file and SYS" c_4_7
  run_step 4.8  primary "fal_server (for switchover)" c_4_8
  run_step 4.9  primary "Primary tnsnames.ora has the standby alias" c_4_9
  run_step 4.10 primary "Primary static listener entry (for switchover)" c_4_10
  run_step 4.11 primary "Environment of $ORACLE_USER on primary (.bash_profile)" c_4_11
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
  lsnr_sw_ok || { NOW="The software for the listener is not installed (phase 3)"; return 2; }
  local st=0 f; f=$(lsnr_file)
  # on a server that already runs something else: port $PORT must be free or ours
  local opid oexe; opid=$(port_owner_pid "$PORT")
  if [[ -n "$opid" ]]; then
    oexe=$(readlink "/proc/$opid/exe" 2>/dev/null); oexe=${oexe% (deleted)}
    # both paths resolved (a home under a symbolic link is still our listener)
    if [[ "$(readlink -f -- "$oexe" 2>/dev/null || printf '%s' "$oexe")" != "$(readlink -f -- "$(lsnr_home)/bin/tnslsnr" 2>/dev/null || printf '%s' "$(lsnr_home)/bin/tnslsnr")" ]]; then
      NOW="Port $PORT on this server is already used by $oexe (pid $opid), not by the listener of $(lsnr_home)"
      KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
      PLAN="Another listener (or program) owns port $PORT. The standby listener must be the one in $(lsnr_home) on this port
(the primary and the copy use port $PORT). Stop the other one, or move it to another port, then answer r:
  ps -fp $opid
  ss -ltnp '( sport = :$PORT )'"
      return 1
    fi
  fi
  static_entry_state || st=$?
  if [[ $st -eq 0 ]] && { use_grid || lsnr_has_desc; }; then NOW="Static entry for $STANDBY_SID with ORACLE_HOME=$DB_HOME in $f"; return 0; fi
  USING="SID $STANDBY_SID, service $STANDBY_SERVICE, DATABASE home $DB_HOME (never the Grid home)"
  L51_MODE=""
  if ! use_grid && ! lsnr_has_desc; then
    if [[ $st -eq 1 ]] && ! lsnr_has_sidlist; then
      # no Grid: the listener lives in the database home and must be defined completely
      L51_MODE=both
      NOW="No listener defined in $f (there is no Grid on this server)"
      PLAN="Write to $f (backup kept, owner $ORACLE_USER):
$(lsnr_desc_block)
$(static_block)"
      return 1
    fi
    if [[ $st -eq 0 ]]; then
      L51_MODE=desc
      NOW="$f has the static entry, but no address for the listener $SB_LSNR"
      PLAN="Add to $f (backup kept):
$(lsnr_desc_block)"
      return 1
    fi
  fi
  if [[ $st -eq 1 ]] && ! lsnr_has_sidlist; then
    L51_MODE=static
    NOW="No static entry in $f"
    PLAN="Append to $f (backup kept, owner $(lsnr_user)):
$(static_block)"
    return 1
  fi
  KIND_NOW=manual; MANUAL_HOW="$(lsnr_user)  ->  edit $f"
  if [[ $st -eq 2 ]]; then
    NOW="The static entry for $STANDBY_SID has ANOTHER ORACLE_HOME (this gives ORA-01017 through the listener)"
  else
    NOW="$f already has a SID_LIST_$SB_LSNR block without $STANDBY_SID; the script does not edit inside it"
  fi
  PLAN="Inside SID_LIST_$SB_LSNR / (SID_LIST = ... ) there must be exactly this SID_DESC:
    (SID_DESC =
      (GLOBAL_DBNAME = $STANDBY_SERVICE)
      (SID_NAME = $STANDBY_SID)
      (ORACLE_HOME = $DB_HOME)
    )"
  ! use_grid && ! lsnr_has_desc && PLAN+=$'\n'"and the listener address:"$'\n'"$(lsnr_desc_block)"
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
  lsnr_sw_ok || { NOW="The software for the listener is not installed (phase 3)"; return 2; }
  static_entry_state || { NOW="Static entry is not correct (step 5.1)"; return 2; }
  L52_START=0
  if ! run_logged "lsnrctl status" as_lsnr timeout 60 "$(lsnr_home)/bin/lsnrctl" status "$SB_LSNR"; then
    if use_grid; then NOW="Listener $SB_LSNR is not running (Oracle Restart resource, step 3.9)"; return 2; fi
    L52_START=1
    NOW="Listener $SB_LSNR is not running"
    PLAN="lsnrctl start $SB_LSNR   (as $ORACLE_USER, from $DB_HOME)"
    return 1
  fi
  if ! grep -q "(PROTOCOL=TCP)(HOST=[^)]*)(PORT=$PORT)" <<< "$(norm "$RUN_OUT")"; then
    NOW="Listener $SB_LSNR does not listen on port $PORT (the primary uses $PORT)"
    KIND_NOW=manual; MANUAL_HOW="$(lsnr_user)  ->  edit $(lsnr_file)"
    PLAN="Set (PORT = $PORT) in the $SB_LSNR address of $(lsnr_file), then:
$(lsnr_home)/bin/lsnrctl stop $SB_LSNR ; $(lsnr_home)/bin/lsnrctl start $SB_LSNR"
    use_grid && { MANUAL_HOW="$GRID_USER  ->  shell"; PLAN="srvctl modify listener -listener $SB_LSNR -endpoints TCP:$PORT
srvctl stop listener -listener $SB_LSNR ; srvctl start listener -listener $SB_LSNR"; }
    return 1
  fi
  if grep -qF "Instance \"$STANDBY_SID\", status UNKNOWN" <<< "$RUN_OUT"; then NOW="Listener shows: Instance \"$STANDBY_SID\", status UNKNOWN (port $PORT)"; return 0; fi
  NOW="Listener does not show the static instance $STANDBY_SID yet"
  PLAN="lsnrctl reload $SB_LSNR   (as $(lsnr_user); running connections are not affected)"
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
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  rw_home_ok || { NOW="Oracle home is read-only (step 3.8)"; return 2; }
  local f; f=$(tns_file)
  USING="host $T_HOST, port $PORT, service $T_SVC"
  if tns_alias_present "$T_ALIAS" && run_logged "tnsping $T_ALIAS" as_oracle timeout 60 "$DB_HOME/bin/tnsping" "$T_ALIAS" 1 && grep -q '^OK' <<< "$RUN_OUT"; then
    if tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC"; then NOW="tnsping $T_ALIAS OK ($T_HOST:$PORT/$T_SVC, UR=A)"; return 0; fi
    NOW="Alias $T_ALIAS exists but is different: $TNS_WHY"
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  edit $f"
    PLAN="The entry must be:
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
    return 1
  fi
  if tns_alias_present "$T_ALIAS"; then
    case "$(tnsping_class "$RUN_OUT")" in
      NOLISTENER)
        if tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC"; then
          NOW="Alias $T_ALIAS is right ($T_HOST:$PORT/$T_SVC), but nothing answers there yet: $(grep -oE 'TNS-[0-9]+' <<< "$RUN_OUT" | head -n 1) (the listener on $T_HOST is not running)"
          [[ "$T_HOST" == "$STANDBY_HOST" ]] && { NOW+=" (step 5.2)"; return 2; }
          NOW+=" - check the listener on the primary ($LISTENER_NAME, port $PORT)"; return 2
        fi ;;
    esac
    NOW="Alias $T_ALIAS is in $f but tnsping fails: $(grep -E 'TNS-[0-9]+' <<< "$RUN_OUT" | head -n 1)"
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  edit $f"
    PLAN="Fix the entry (check brackets and the host name):
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
    return 1
  fi
  NOW="Alias $T_ALIAS is not in $f"
  PLAN="Append to $f (backup kept):
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
  phase_header 5 "Network files on this server (listener.ora, tnsnames.ora)"
  run_step 5.1 auto "Static listener entry for $STANDBY_SID" c_5_1 d_5_1
  run_step 5.2 auto "Listener shows the static entry" c_5_2 d_5_2
  run_step 5.3 auto "tnsnames.ora: $PRIMARY_TNS (primary)" c_5_3 d_tns
  run_step 5.4 auto "tnsnames.ora: $STANDBY_TNS (standby)" c_5_4 d_tns
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
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  rw_home_ok || { NOW="Oracle home is read-only (step 3.8)"; return 2; }
  local d; d=$(pw_dest)
  if pwfile_ok; then NOW="$d exists, owner $ORACLE_USER (compared with primary by the login test 7.4)"; return 0; fi
  need_ssh || return 2
  # 12.2+: v$passwordfile_info has file_name and format; 12.1: file_name only; else the file in dbs
  local pfile=""
  if [[ "$PRIMARY_VERSION" != 12.1* ]] && prim_sql "select file_name from v\$passwordfile_info;"; then pfile=$(first_line)
  elif prim_sql "select file_name from v\$passwordfile_info;"; then pfile=$(first_line)
  fi
  if [[ -z "$pfile" || "$pfile" == "-" ]]; then
    if prim_probe exists "$DB_HOME/dbs/orapw$PRIMARY_SID" && [[ "$(head -n 1 <<< "$RUN_OUT")" == "YES" ]]; then pfile="$DB_HOME/dbs/orapw$PRIMARY_SID"
    else NOW="The primary password file could not be found (v\$passwordfile_info is empty and $DB_HOME/dbs/orapw$PRIMARY_SID does not exist). On primary as $ORACLE_USER:  $DB_HOME/bin/srvctl config database -db $PRIMARY_UNIQUE | grep -i 'password file'"; return 2; fi
  fi
  [[ "$pfile" =~ ^[+/][A-Za-z0-9_./+-]+$ ]] || { NOW="Primary password file path is unusual: '$pfile'"; return 2; }
  if [[ -f "$d" ]]; then NOW="$d exists but owner, mode or format is wrong"; else NOW="$d does not exist"; fi
  if [[ "$pfile" == +* ]]; then
    local t towner tg tm tmode ttype tage=""; t=$(pw_tmp_remote)
    if prim_probe statx "$t"; then
      IFS='|' read -r towner tg tmode ttype tm <<< "$(head -n 1 <<< "$RUN_OUT")"
      if [[ "$ttype" != "regular file" || ( "$towner" != "$GRID_USER" && "$towner" != "$ORACLE_USER" ) || ! "$tmode" =~ ^[0-7]+$ || $(( 8#${tmode: -1} & 2 )) -ne 0 ]]; then
        NOW+=$'\n'"$t on primary is not a file of $GRID_USER/$ORACLE_USER (owner $towner, type $ttype, mode $tmode); it is not used"
        KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
        PLAN="rm -f $t
asmcmd pwcopy '$pfile' $t
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 asks for it after the copy)"
        return 1
      fi
      # the age is measured with the clock of the primary
      num "$tm" && tage=$(( RUN_START + PRIM_CLOCK_OFFSET - tm ))
    fi
    if [[ -n "$tage" && $tage -gt 86400 ]]; then
      # a copy older than a day (from an earlier attempt) may be from before a sys password change
      NOW+=$'\n'"An OLD copy $t (owner $towner, $((tage / 3600)) hours older than this run) is on primary; it is not used"
      KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
      PLAN="rm -f $t
asmcmd pwcopy '$pfile' $t
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 asks for it after the copy)"
      return 1
    fi
    [[ -n "$tage" && $tage -gt 0 ]] && NOW+=$'\n'"(the copy $t on primary is $((tage / 60)) minutes old: made for this setup, it is used)"
    if [[ -n "$tage" ]]; then
      PW_SRC=$t
      PLAN="Copy $t from primary (scp over the open connection, checked with md5sum)
install it as $d  (owner $ORACLE_USER:$INSTALL_GROUP, mode 640)"
      [[ -f "$d" ]] && PLAN+=$'\n'"the old file is kept as $d.bak_$RUN_ID"
      USING="copy made on primary during this run (owner $towner) from $pfile"
      return 1
    fi
    NOW+=$'\n'"The primary password file is inside ASM: $pfile"
    KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
    PLAN="asmcmd pwcopy '$pfile' $t
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 asks for it after the copy)"
    USING="the script then copies $t (step 6.2 reminds you to delete it)"
    return 1
  fi
  PW_SRC=$pfile
  PLAN="Copy $pfile from primary (scp over the open connection, checked with md5sum)
install it as $d  (owner $ORACLE_USER:$INSTALL_GROUP, mode 640)"
  [[ -f "$d" ]] && PLAN+=$'\n'"the old file is kept as $d.bak_$RUN_ID"
  return 1
}
fetch_primary_file() {
  # $1 file on primary, $2 private local copy. 0 only when the copy is byte-identical (md5).
  local src=$1 tmp=$2 rmd lmd
  rm -f -- "$tmp"
  prim_scp "$src" "$tmp" || { bad "scp failed: $(tail -n 2 <<< "$RUN_OUT")"; printf 'The ssh user %s must be able to read %s on primary.\n' "$PRIMARY_SSH_USER" "$src" | hint; return 1; }
  [[ -s "$tmp" && -f "$tmp" && ! -L "$tmp" ]] || { bad "The copied file $src is empty"; return 1; }
  prim_probe md5 "$src" || { bad "Cannot compute md5sum of $src on primary; the copy is not used"; return 1; }
  rmd=$(awk '{print $1; exit}' <<< "$RUN_OUT"); lmd=$(md5sum "$tmp" | awk '{print $1}')
  [[ "$rmd" =~ ^[0-9a-f]{32}$ && "$rmd" == "$lmd" ]] || { bad "The copied file differs from $src on primary (md5 $lmd vs $rmd)"; return 1; }
  say "md5 checked: same as $src on primary"
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
  DONE_MSG="Installed $d (copy of the primary password file)"
}

# ---- 6.2 temporary copy on primary ----
c_6_2() {
  need_ssh || return 2
  local t; t=$(pw_tmp_remote)
  PRIMARY_HOW_STEP="$GRID_USER (or root)  ->  shell"
  if ! prim_probe owner "$t"; then NOW="No temporary password file copy on primary"; return 0; fi
  pwfile_ok || { NOW="Password file not installed yet (step 6.1); keep $t for now"; return 2; }
  NOW="Temporary copy $t is still on primary"
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
  printf '# orapki asks for the keystore password; it writes %s/cwallet.sso here; the primary is not changed. Then answer r.' "$1"
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
  [[ -n "$TDE_INFO" ]] || { NOW="No TDE wallet in use on primary"; return 0; }
  if awk -F'|' 'toupper($1)!="FILE" && toupper($3)!="NOT_AVAILABLE"' <<< "$TDE_INFO" | grep -q .; then
    NOW="Primary uses a TDE keystore that is not a file (HSM / OKV):"$'\n'"$TDE_INFO"
    PLAN="Configure the same keystore for $STANDBY_UNIQUE on this server as described by your HSM/OKV vendor."
    return 2
  fi
  local -a dirs=(); local d f; mapfile -t dirs < <(tde_dirs)
  [[ ${#dirs[@]} -gt 0 && -n "${dirs[0]}" ]] || { NOW="No TDE wallet in use on primary"; return 0; }
  # 18c+: the password for "IDENTIFIED BY EXTERNAL STORE" is in WALLET_ROOT/tde_seps
  [[ -n "$WALLET_ROOT" ]] && need_ssh && prim_probe lsdir "$WALLET_ROOT/tde_seps" && grep -qx 'cwallet.sso' <<< "$RUN_OUT" && dirs+=("$WALLET_ROOT/tde_seps")
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  for d in "${dirs[@]}"; do
    [[ "$d" == /* ]] && v_path "$d" || { NOW="The TDE wallet is at $d (inside ASM or unusual path)"; PLAN="Copy the wallet files by hand to the same location for the standby (asmcmd cp ...)."; return 2; }
  done
  need_ssh || return 2
  TDE_DIRS=("${dirs[@]}"); TDE_TODO=()
  local miss="" diff="" have=""
  for d in "${dirs[@]}"; do
    prim_probe lsdir "$d" || { NOW="Cannot list the wallet folder $d on primary (the ssh user must be able to read it)"; return 2; }
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
    [[ $found -eq 1 ]] || { NOW="No ewallet.p12 / cwallet.sso in $d on primary"; return 2; }
  done
  # without WALLET_ROOT (12c, or 18c-21c set up the old way) the standby finds the wallet only through sqlnet.ora
  TDE_SQLNET=0
  if [[ -z "$WALLET_ROOT" ]]; then
    [[ $DB_MAJOR -ge 23 ]] && { NOW="The primary ($PRIMARY_VERSION) uses TDE without WALLET_ROOT; set WALLET_ROOT on the primary first"; return 2; }
    if ! sqlnet_has_wallet "${dirs[0]}"; then
      if [[ -f "$(sqlnet_file)" ]] && grep -qiE '^[[:space:]]*ENCRYPTION_WALLET_LOCATION' "$(sqlnet_file)"; then
        NOW="$(sqlnet_file) already has an ENCRYPTION_WALLET_LOCATION that is not ${dirs[0]}"
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  edit $(sqlnet_file)"
        PLAN="Change it to:
ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))"
        return 1
      fi
      TDE_SQLNET=1
    fi
  fi
  TDE_NO_AUTOLOGIN=0; [[ "$have$miss$diff" == *"cwallet.sso"* ]] || TDE_NO_AUTOLOGIN=1
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 && $TDE_NO_AUTOLOGIN -eq 1 && -f "${dirs[0]}/cwallet.sso" ]]; then TDE_NO_AUTOLOGIN=0; fi
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 && $TDE_NO_AUTOLOGIN -eq 1 ]]; then
    NOW="TDE wallet copied, but there is no auto-login keystore (cwallet.sso) here: the copy and the apply would stop (ORA-28365)"
    tde_local_autologin && NOW+=$'\n'"(the primary uses a LOCAL auto-login wallet, which opens only on the primary host: it is made again here)"
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER (THIS server)"
    PLAN=$(orapki_plan "${dirs[0]}")
    return 1
  fi
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 ]]; then
    NOW="TDE wallet is the same as on primary:$have"
    [[ -n "$WALLET_ROOT" ]] && NOW+=$'\n'"(wallet_root=$WALLET_ROOT comes to the standby with the spfile)" || NOW+=$'\n'"($(sqlnet_file) points to ${dirs[0]})"
    return 0
  fi
  NOW="The primary uses TDE.${miss:+ Missing here:$miss}${diff:+ Different here:$diff}"
  [[ $TDE_SQLNET -eq 1 ]] && NOW+=$'\n'"$(sqlnet_file) does not point to the wallet ${dirs[0]}"
  PLAN=""
  [[ ${#TDE_TODO[@]} -gt 0 ]] && PLAN="Copy from primary (scp, checked with md5sum) to the same path here, owner $ORACLE_USER:$INSTALL_GROUP, mode 600 (old files kept as .bak_$RUN_ID):"$'\n'"$(printf '  %s\n' "${TDE_TODO[@]}")"$'\n'
  [[ $TDE_SQLNET -eq 1 ]] && PLAN+="Add to $(sqlnet_file) (backup kept):"$'\n'"ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))"$'\n'
  TDE_NO_AUTOLOGIN=0
  if [[ " ${have} ${TDE_TODO[*]+"${TDE_TODO[*]}"} " != *"cwallet.sso"* ]]; then
    TDE_NO_AUTOLOGIN=1
    if tde_local_autologin; then PLAN+="The primary uses a LOCAL auto-login wallet (it opens only on the primary host): it is not copied."$'\n'
    else PLAN+="NO AUTO-LOGIN KEYSTORE (cwallet.sso) on the primary: the copy and the redo apply on the standby would stop with ORA-28365."$'\n'; fi
    PLAN+="After the copy this step shows the orapki command that makes cwallet.sso on THIS server (no instance needed)."$'\n'
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
    rm -f "$tmp"; say "installed $f"; journal_file_written "$f" "$existed"
  done
  if [[ $TDE_SQLNET -eq 1 ]]; then
    local s; s=$(sqlnet_file)
    backup_file "$s" "$ORACLE_USER" || return 1
    printf '# Added by dg_standby_setup.sh %s (TDE wallet of the standby)\nENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = %s)))\n' "$RUN_ID" "${TDE_DIRS[0]}" \
      | append_as "$ORACLE_USER" "$s" || return 1
    say "added ENCRYPTION_WALLET_LOCATION to $s"
  fi
}

phase_6() {
  phase_header 6 "Password file and TDE wallet (same as primary)"
  run_step 6.1 auto    "Password file orapw$STANDBY_SID" c_6_1 d_6_1
  run_step 6.2 primary "Remove the temporary copy on primary" c_6_2
  run_step 6.3 auto    "TDE wallet (only if the primary uses encryption)" c_6_3 d_6_3
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
    || warn "Cannot write $(dup_marker): when the standby is shut down, the script cannot tell that it is complete"
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
    SC_INFO="the standby instance is not mounted and no finished duplicate is recorded"; return 1
  fi
  [[ "$(marker_kind)" == "duplicate" ]] && return 0
  if [[ "$(marker_kind)" == "seen" ]]; then
    if sql_local "select count(*) from v\$datafile_header where error is not null;" && [[ "$(first_line)" != "0" ]]; then
      warn "The standby was complete before; now $(first_line) datafile header(s) show an error (for example a datafile added on primary, or an OFFLINE file)."
      say "Check:  select file#, error from v\$datafile_header where error is not null;"
      say "To build the standby again if you want: see the help of step 8.2 (remove files only after step 2.15 proved the storage is not shared)."
    fi
    return 0
  fi
  sql_local "select (select count(*) from v\$datafile)||'|'||(select count(*) from v\$datafile_header where error is not null) from dual;" || { SC_INFO="cannot read the standby ($(ora_errors "$SQL_OUT"))"; return 2; }
  local sc se pc; IFS='|' read -r sc se <<< "$(first_line)"
  need_ssh || { SC_INFO="no ssh connection to compare with primary"; return 2; }
  prim_sql "select count(*) from v\$datafile;" || { SC_INFO="cannot read the primary ($(ora_errors "$SQL_OUT"))"; return 2; }
  pc=$(first_line)
  num "$sc" && num "$se" && num "$pc" || { SC_INFO="unexpected answers ($sc, $se, $pc)"; return 2; }
  # complete: no datafile header has an error. Fewer datafiles than the primary means apply is behind
  # (new tablespaces on primary), not a failed copy (a failed copy shows the missing files as errors).
  if [[ "$se" == "0" && "$sc" -gt 0 ]]; then set_marker seen; return 0; fi
  SC_INFO="standby has $sc datafiles ($se with errors), primary has $pc"
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
  [[ -n "$(asm_dgs)" ]] && printf 'NEVER remove %s (those names are the primary database)\n' "$(asm_dgs | sed "s#^#+#; s#\$#/${PRIMARY_UNIQUE^^}#" | paste -sd' ' -)"
  for dg in $(asm_dgs); do printf 'as %s:  [ "$(hostname -s)" = "%s" ] && ORACLE_HOME=%s ORACLE_SID=+ASM %s/bin/asmcmd rm -rf +%s/%s       (check the name twice)\n' "$GRID_USER" "$(hostname -s)" "$GRID_HOME" "$GRID_HOME" "$dg" "${STANDBY_UNIQUE^^}"; done
  if [[ -n "$(fs_dirs)" ]]; then
    local rmf="" src=${STORAGE_SRC:-2}
    if [[ $src -eq 0 ]]; then rmf=$(fs_cleanup_cmds | sed "s#^#[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] \&\& #" || true); fi
    if [[ -n "$rmf" ]]; then printf 'as %s (THIS server only; the same names as on primary):\n%s\n' "$ORACLE_USER" "$rmf"
      local omfd; omfd=$(omf_dir_here); [[ -n "$omfd" ]] && printf '[ "$(hostname -s)" = "%s" ] && rm -rf %s/%s\n' "$(hostname -s)" "$omfd" "${STANDBY_UNIQUE^^}"
    elif [[ $src -eq 1 ]]; then printf 'DANGER: %s is the storage of the PRIMARY. Do not remove anything there.\n' "$STORAGE_SHARED"
    else printf 'remove the files the failed copy left in: %s (the same names as on primary; first make sure this is not the storage of the primary, step 2.15)\n' "$(fs_dirs | paste -sd' ' -)"; fi
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
    if [[ -d "$d" ]] && runuser -u "$ORACLE_USER" -- test -w "$d"; then have+="$d "; else I71+=("$d"); fi
  done < <(inst_dirs)
  if [[ ${#I71[@]} -eq 0 ]]; then NOW="Folders exist: $have"; return 0; fi
  I71_TODO=("${I71[@]}")
  NOW="Missing (or not writable by $ORACLE_USER): ${I71[*]}"
  PLAN="Create them, owner $ORACLE_USER:$INSTALL_GROUP (same paths as audit_file_dest / diagnostic_dest on primary)"
  return 1
}
d_7_1() { local d; for d in "${I71_TODO[@]}"; do make_dir "$d" "$ORACLE_USER" || return 1; done; }

# ---- 7.7 oratab ----
c_7_7() {
  local cur; cur=$(grep -E "^${STANDBY_SID}:" /etc/oratab 2>/dev/null | head -n 1)
  if [[ "$cur" == "$STANDBY_SID:$DB_HOME:"* ]]; then NOW="/etc/oratab: $cur"; return 0; fi
  if [[ -n "$cur" ]]; then
    NOW="/etc/oratab has another home for $STANDBY_SID: $cur"
    KIND_NOW=manual; MANUAL_HOW="root  ->  edit /etc/oratab"
    PLAN="Change that line to:  $STANDBY_SID:$DB_HOME:N"; return 1
  fi
  NOW="/etc/oratab has no line for $STANDBY_SID (oraenv and dbstart need it)"
  PLAN="Append to /etc/oratab:  $STANDBY_SID:$DB_HOME:N   (backup kept)"
  return 1
}
d_7_7() {
  local new=0; [[ -f /etc/oratab ]] || new=1
  backup_file /etc/oratab || return 1
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
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  pwfile_ok || { NOW="Password file is not ready (step 6.1)"; return 2; }
  storage_cache
  local_state
  case "$LSTATE" in
    STARTED)
      # NOMOUNT, but from the spfile that a failed duplicate left (RMAN restarts the auxiliary with it):
      # the next duplicate needs an instance started from the text pfile
      if spfile_from_failed_copy; then
        NOW="Instance $STANDBY_SID is NOMOUNT, started from the spfile of a copy that did not finish ($(spfile_path))"
        PLAN="# as $ORACLE_USER, on THIS server only:
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && ORACLE_HOME=$DB_HOME ORACLE_SID=$STANDBY_SID $DB_HOME/bin/sqlplus -S / as sysdba <<< 'shutdown abort'
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && mv $(spfile_path) $(spfile_path).failed_$RUN_ID
$(leftover_cleanup_plan | grep -v "rm -f $(spfile_path) ")
Then answer r: the instance is started again from the pfile."
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER (THIS server only)"
        return 1
      fi
      # NOMOUNT from the pfile, but a copy that did not finish left files a new copy would not overwrite
      if [[ -f "$STATE_DIR/dup_attempt" && ! -f "$STATE_DIR/existing_files_ok" && "$(marker_kind)" != "duplicate" ]]; then
        local ol; ol=$(orphan_leftovers)
        if [[ -n "$ol" ]]; then
          NOW="Instance $STANDBY_SID is NOMOUNT, but files of the copy that did not finish are still here:"$'\n'"$ol"
          PLAN="# as $ORACLE_USER, on THIS server only:
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && ORACLE_HOME=$DB_HOME ORACLE_SID=$STANDBY_SID $DB_HOME/bin/sqlplus -S / as sysdba <<< 'shutdown abort'
$(leftover_cleanup_plan)
Then answer r: the instance is started again from the pfile. If the files may stay:  touch $STATE_DIR/existing_files_ok   and answer r."
          KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER${GRID_HOME:+ / $GRID_USER} (THIS server only)"
          return 1
        fi
      fi
      NOW="Instance $STANDBY_SID is in NOMOUNT"; return 0 ;;
    MOUNTED|OPEN)
      sql_local "select database_role from v\$database;" || { NOW="Cannot read the role ($(ora_errors "$SQL_OUT"))"; return 2; }
      local role; role=$(first_line)
      [[ "$role" == "PHYSICAL STANDBY" ]] || fatal "The local database $STANDBY_SID is $LSTATE with role '$role'. This is not a standby. Stopping."
      local sc=0; standby_complete || sc=$?
      if [[ $sc -eq 0 ]]; then STANDBY_BUILT=1; NOW="Standby database already exists ($LSTATE, PHYSICAL STANDBY); duplicate is not needed"; return 0; fi
      if [[ $sc -eq 2 ]]; then NOW="Cannot compare the standby with primary: $SC_INFO"; return 2; fi
      NOW="A standby control file exists but the database is INCOMPLETE ($SC_INFO) - probably a failed duplicate"
      KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER${GRID_HOME:+ / $GRID_USER} on THIS server only"
      PLAN="# as $ORACLE_USER, on THIS server only:"$'\n'"[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && ORACLE_HOME=$DB_HOME ORACLE_SID=$STANDBY_SID $DB_HOME/bin/sqlplus -S / as sysdba <<< 'shutdown abort'"$'\n'"$(leftover_cleanup_plan)"
      PLAN+=$'\n'"Then answer r: the instance is started again from the pfile."
      return 1 ;;
    IDLE)
      if [[ -f "$(dup_marker)" && -f "$(spfile_path)" ]]; then
        STANDBY_BUILT=1
        NOW="The standby database exists (finished duplicate); it is started in step 9.2, not in NOMOUNT"
        return 0
      fi
      # files of a copy that was interrupted (reboot, kill): they are named, never removed by the script
      local lo; lo=$(leftover_files)
      if [[ -n "$lo" && ! -f "$STATE_DIR/existing_files_ok" ]]; then
        NOW="Instance $STANDBY_SID is not started, and files already exist where the standby database will be written (an earlier copy, or something else):"$'\n'"$lo"
        PLAN="$(leftover_cleanup_plan)
(RMAN overwrites files with the same names; files with OMF names would stay unused and take space)
Then answer r. If you are sure they may be overwritten or may stay:  touch $STATE_DIR/existing_files_ok   and answer r."
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER${GRID_HOME:+ / $GRID_USER} (THIS server only)"
        return 1
      fi
      NOW="Instance $STANDBY_SID is not started"
      PLAN="Write $(pfile_path):
$(pfile_text | sed 's/^/  /')
startup nomount pfile='$(pfile_path)'   (as $ORACLE_USER)"
      return 1 ;;
    *) NOW="Cannot read the local instance state ($(ora_errors "$SQL_OUT"))"; return 2 ;;
  esac
}
d_7_2() {
  local p; p=$(pfile_path)
  if [[ -f "$p" && "$(cat "$p")" != "$(pfile_text)" ]]; then backup_file "$p" "$ORACLE_USER" || return 1; fi
  [[ -f "$p" && "$(cat "$p")" == "$(pfile_text)" ]] || { pfile_text | write_as "$ORACLE_USER" "$p" 644 || return 1; }
  pfile_text | log_block "pfile $p"
  # journaled first: a run that stops during the startup still lists the instance for --undo
  journal INSTANCE "$STANDBY_SID" "started NOMOUNT with $p"
  sql_local_long "startup nomount pfile='$p'" || { bad "startup nomount failed ($(ora_errors "$SQL_OUT"))"; printf '%s\n' "$SQL_OUT" | tail -n 5 | hint; return 1; }
}

# ---- 7.3 - 7.6 golden connections ----
golden_text() {
  case "$1" in
    *ORA-01017*)
      if [[ "$2" == "standby-tns" ]]; then
        printf 'Local login works but login through the listener fails:\n- static entry ORACLE_HOME is not %s (step 5.1), or\n- the password file is not a copy of the primary file (step 6.1).\n' "$DB_HOME"
      elif [[ "$2" == "local" ]]; then
        printf 'OS authentication failed: %s must be in the OSDBA group of this home (id %s ; grep OSDBA %s/rdbms/lib/config.c).\n' "$ORACLE_USER" "$ORACLE_USER" "$DB_HOME"
      else
        printf 'Wrong sys password, or the password files differ.\nTo copy again: on primary as %s  rm -f %s ; here  mv %s %s.old ; then run  %s --from 6.1\n' "$GRID_USER" "$(pw_tmp_remote)" "$(pw_dest)" "$(pw_dest)" "$SELF"
      fi ;;
    *ORA-12528*) printf 'The listener blocks the connection: (UR = A) missing in tnsnames, or no static entry (phase 5).\n' ;;
    *ORA-12514*) printf 'SERVICE_NAME in tnsnames does not match GLOBAL_DBNAME of the static entry (phase 5).\n' ;;
    *ORA-12154*|*TNS-03505*) printf 'The alias is missing in tnsnames.ora (step 5.3/5.4, or 4.9 for the primary side).\n' ;;
    *ORA-12541*|*TNS-12541*) printf 'No listener at that host/port (phase 5, firewall step 2.9).\n' ;;
    *ORA-12170*|*ORA-12535*) printf 'Timeout: firewall or network between the servers (steps 2.8, 2.9).\n' ;;
    *ORA-01031*) printf 'Privilege problem: user %s not in the dba group, or password file mode.\n' "$ORACLE_USER" ;;
    *ORA-01034*) printf 'The instance is not started (step 7.2).\n' ;;
    *) printf 'See the log for the full output.\n' ;;
  esac
}
need_sys() { [[ -n "$SYS_PW" ]] && return 0; NOW="The sys password is not known yet (step 1.5)"; NEED_SYS=1; return 1; }
c_7_3() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  if sql_local "select status from v\$instance;"; then NOW="sqlplus / as sysdba  ->  $(first_line)"; return 0; fi
  if grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    built_offline && { NOW="The standby exists and is not started; the logins are tested after step 9.2 starts it"; return 0; }
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
  if sql_standby_tns "select instance_name||' '||status from v\$instance;"; then NOW="sys@$STANDBY_TNS (through the listener)  ->  $(first_line)"; return 0; fi
  if grep -q 'ORA-01034' <<< "$SQL_OUT"; then
    built_offline && { NOW="The standby exists and is not started; tested after step 9.2"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  NOW="sys@$STANDBY_TNS failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" standby-tns); return 1
}
c_7_5() {
  need_sys || return 2
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  tns_alias_present "$PRIMARY_TNS" || { NOW="The alias $PRIMARY_TNS is not in tnsnames.ora of this server yet (step 5.3)"; return 2; }
  if sql_primary_tns "select db_unique_name||' '||database_role from v\$database;"; then NOW="sys@$PRIMARY_TNS from this server  ->  $(first_line)"; return 0; fi
  NOW="sys@$PRIMARY_TNS failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" primary); return 1
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
  # the test needs the standby side: software, listener (phase 5) and the instance (step 7.2)
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  local_state
  if [[ "$LSTATE" == "IDLE" ]]; then
    built_offline && { NOW="The standby exists and is not started; tested after step 9.2"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  if prim_sql_as_sys "$STANDBY_TNS" "select instance_name||' '||status from v\$instance;"; then NOW="On primary: sys@$STANDBY_TNS  ->  $(first_line)"; return 0; fi
  if grep -q 'ORA-01034' <<< "$SQL_OUT"; then
    built_offline && { NOW="The standby exists and is not started; tested after step 9.2"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  NOW="On primary: sys@$STANDBY_TNS failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" standby-tns); return 1
}

phase_7() {
  phase_header 7 "Start the standby instance and test the logins"
  run_step 7.1 auto  "Folders for the instance (audit, diagnostics)" c_7_1 d_7_1
  run_step 7.2 auto  "Instance $STANDBY_SID in NOMOUNT" c_7_2 d_7_2
  run_step 7.3 check "Login 1/4: sqlplus / as sysdba (standby)" c_7_3
  run_step 7.4 check "Login 2/4: sys@$STANDBY_TNS through the listener" c_7_4
  run_step 7.5 check "Login 3/4: sys@$PRIMARY_TNS from this server" c_7_5
  run_step 7.6 check "Login 4/4: sys@$STANDBY_TNS from primary" c_7_6
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
      PRE_FIX="+$dg has $(human_mb "$free") free, needs about $(human_mb "$need") (database files + 10%)."
      [[ -n "$(orphan_leftovers | grep -F "+$dg/")" ]] && PRE_FIX+=" Files of an earlier copy are in +$dg/${STANDBY_UNIQUE^^}: removing them gives space back (step 7.2 shows how: $SELF --from 7.2)."
      PRE_FIX+=" Or add a disk to +$dg: run step 2.13 again ($SELF --from 2.13), then as $GRID_USER (export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM ; \$ORACLE_HOME/bin/sqlplus / as sysasm): alter diskgroup $dg add disk '$(asm_disk_dir)/<label>';"
      return 1
    fi
    PRE_INFO+="+$dg free $(human_mb "$free"), needed about $(human_mb "$need")"$'\n'
  done
  declare -A need_by_mnt=() free_by_mnt=() there_by_mnt=()
  while IFS= read -r l; do
    d=${l%%:*}
    [[ -d "$d" ]] || { PRE_FIX="Folder $d does not exist (step 2.14)"; return 1; }
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
    [[ $free -ge $need ]] || { PRE_FIX="File system $mnt has $(human_mb "$free") free, needs about $(human_mb "$need") (database files + 10%)."; return 1; }
    PRE_INFO+="file system $mnt free $(human_mb "$free"), needed about $(human_mb "$need")"$'\n'
  done
  return 0
}

dup_prechecks() {
  # read-only. Sets PRE_OK, PRE_INFO (lines), PRE_FIX, DUP_EXTRA, CF_LIST, DEST_N, NEWNAMES.
  PRE_OK=0; PRE_INFO=""; PRE_FIX=""; DUP_EXTRA=""; CF_LIST=""; NEWNAMES=""
  local_state
  [[ "$LSTATE" == "STARTED" ]] || { PRE_FIX="Standby instance must be in NOMOUNT (state $LSTATE) (step 7.2)"; return 1; }
  if spfile_from_failed_copy; then PRE_FIX="The instance runs from the spfile of a copy that did not finish: clean it first (step 7.2)"; return 1; fi
  # the disk group of the logs must fit the block size of the primary's redo (else ORA-01378 after the copy, at 9.3)
  if use_grid && grid_sw_ok; then
    local ldg="$DATA_DG"; [[ "$CFD" == +* ]] && { ldg=$(norm_loc "$CFD"); ldg=${ldg#+}; }
    if [[ -n "$ldg" ]] && sql_asm "select sector_size from v\$asm_diskgroup where name=upper('$ldg');" && num "$(first_line)"; then
      local ss; ss=$(first_line)
      if [[ "${PRIMARY_REDO_BS:-512}" == "4096" && "$ss" != "4096" ]] || [[ "${PRIMARY_REDO_BS:-512}" == "512" && "$ss" == "4096" ]]; then
        PRE_FIX="+$ldg has a sector size of $ss bytes, but the redo logs of the primary use ${PRIMARY_REDO_BS}-byte blocks: the standby logs could not be created after the copy (ORA-01378). Create a disk group with sector_size ${PRIMARY_REDO_BS} for the logs first (see --help-step 3.5)."
        return 1
      fi
      PRE_INFO+="+$ldg sector size $ss bytes fits the redo block size ${PRIMARY_REDO_BS:-512}"$'\n'
    fi
  fi
  # the copy takes the spfile of the primary (duplicate ... spfile): a primary started from a pfile fails there
  prim_sql "select nvl(value,'-') from v\$parameter where name='spfile';" && [[ "$(first_line)" == "-" ]] && { PRE_FIX="The primary runs from a text pfile; the copy needs its spfile (step 4.1)"; return 1; }
  if [[ -f "$STATE_DIR/dup_attempt" && ! -f "$STATE_DIR/existing_files_ok" && "$(marker_kind)" != "duplicate" && -n "$(orphan_leftovers)" ]]; then
    PRE_FIX="Files of the copy that did not finish are still on this server: clean them first (step 7.2)"; return 1
  fi
  PRE_INFO+="standby instance $STANDBY_SID is NOMOUNT"$'\n'
  if tde_autologin_missing; then PRE_FIX="The TDE keystore of the standby has no auto-login file (cwallet.sso): the copy and the redo apply would stop with ORA-28365 (step 6.3)"; return 1; fi
  # the folders of this server must not be the storage of the primary (NOFILENAMECHECK would overwrite it)
  if [[ -n "$(fs_dirs)" && "$MODE" == "run" ]]; then
    storage_cache; local src=$STORAGE_SRC
    [[ $src -eq 1 ]] && { PRE_FIX="DANGER: $STORAGE_SHARED is the SAME storage as on the primary (step 2.15). The duplicate would overwrite the primary files."; return 1; }
    [[ $src -eq 2 ]] && { PRE_FIX="$STORAGE_INFO (step 2.15)"; return 1; }
    PRE_INFO+="database folders are storage of this server only"$'\n'
  fi
  space_check || return 1
  # primary prerequisites (phase 4) again: a skipped step must not make RMAN fail late
  prim_sql "select log_mode||'|'||force_logging from v\$database;" || { PRE_FIX="Cannot read the primary log mode"; return 1; }
  local lm fl; IFS='|' read -r lm fl <<< "$(first_line)"
  [[ "$lm" == "ARCHIVELOG" ]] || { PRE_FIX="The primary is in $lm mode; it must be ARCHIVELOG (step 4.1)"; return 1; }
  [[ "$fl" == "YES" ]] || warn "FORCE LOGGING is off on primary (step 4.1): NOLOGGING operations would not reach the standby"
  p_param remote_login_passwordfile || { PRE_FIX="Cannot read remote_login_passwordfile on primary"; return 1; }
  [[ "$PVAL" == "EXCLUSIVE" || "$PVAL" == "SHARED" ]] || { PRE_FIX="remote_login_passwordfile on primary is $PVAL: the primary must be restarted after the change (step 4.7)"; return 1; }
  # role separation: the oracle binary must be able to open the ASM disks
  if use_grid && ! single_owner; then
    local og want l1; og=$(stat -c '%G' "$DB_HOME/bin/oracle" 2>/dev/null)
    # the group of a real ASM disk is what counts
    l1=$(asm_labels "$DATA_DG" | head -n 1); want=""
    [[ -n "$l1" ]] && want=$(stat -L -c '%G' "$(asm_disk_dir)/$l1" 2>/dev/null)
    [[ -n "$want" && "$want" != "root" ]] || want=$(asm_owner_group)
    [[ "$og" == "$want" ]] || { PRE_FIX="$DB_HOME/bin/oracle has group $og, it must be $want (the group of the ASM disks) to open them (ORA-15025). As root: $GRID_HOME/bin/setasmgidwrap o=$DB_HOME/bin/oracle"; return 1; }
  fi
  # RMAN uses the TNS aliases: prove they reach the right databases
  local pu pr pn ph ti th ts ls; ls=$(hostname -s 2>/dev/null || hostname)
  sql_primary_tns "select d.db_unique_name||'|'||d.database_role||'|'||d.name||'|'||i.host_name from v\$database d, v\$instance i;" || { PRE_FIX="Cannot query primary through $PRIMARY_TNS ($(ora_errors "$SQL_OUT")) (step 7.5)"; return 1; }
  IFS='|' read -r pu pr pn ph <<< "$(first_line)"
  if [[ "${pu^^}" != "${PRIMARY_UNIQUE^^}" || "$pr" != "PRIMARY" || "${pn^^}" != "${DB_NAME^^}" || "${ph%%.*}" == "${ls,,}" || "${ph%%.*}" == "${ls}" ]]; then
    PRE_FIX="Alias $PRIMARY_TNS does not reach the primary ($pu, $pr, $pn, host $ph)"; return 1
  fi
  PRE_INFO+="$PRIMARY_TNS reaches $pu (PRIMARY) on $ph"$'\n'
  sql_standby_tns "select instance_name||'|'||host_name||'|'||status from v\$instance;" || { PRE_FIX="Cannot reach the standby through $STANDBY_TNS ($(ora_errors "$SQL_OUT")) (step 7.4)"; return 1; }
  IFS='|' read -r ti th ts <<< "$(first_line)"
  if [[ "$ti" != "$STANDBY_SID" || "${th%%.*}" != "$ls" || "$ts" != "STARTED" ]]; then
    PRE_FIX="Alias $STANDBY_TNS does not reach THIS NOMOUNT instance ($ti, host $th, $ts)"; return 1
  fi
  PRE_INFO+="$STANDBY_TNS reaches $ti (NOMOUNT) on this server"$'\n'
  # memory: the spfile of primary is copied; the standby must be able to start with it
  prim_sql "select name||'|'||nvl(value,'0') from v\$parameter where name in ('sga_target','sga_max_size','memory_target','memory_max_target','use_large_pages','db_recovery_file_dest_size');" \
    || { PRE_FIX="Cannot read primary memory parameters"; return 1; }
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
    PRE_FIX="Primary SGA/memory target is $(( sga / 1048576 )) MB but this server has only $(( memkb / 1024 )) MB RAM. Add RAM to the standby (it needs the same memory as primary)."
    return 1
  fi
  PRE_INFO+="memory: primary needs $(( sga / 1048576 )) MB, this server has $(( memkb / 1024 )) MB"$'\n'
  if [[ $mt -gt 0 ]]; then
    # AMM (memory_target) uses /dev/shm; it must be at least as big (ORA-00845)
    local shm; shm=$(df -m --output=avail /dev/shm 2>/dev/null | tail -n 1 | tr -d ' '); num "$shm" || shm=0
    [[ $shm -ge $(( mt / 1048576 )) ]] || { PRE_FIX="memory_target is $(( mt / 1048576 )) MB but /dev/shm has $shm MB (ORA-00845). As root: mount -o remount,size=$(( mt / 1048576 + 1024 ))m /dev/shm  (and the same size in /etc/fstab)"; return 1; }
  fi
  if [[ "$ulp" == "ONLY" && $(( hp * hpkb )) -lt $(( sga / 1024 )) ]]; then
    DUP_EXTRA+="      set use_large_pages='TRUE'"$'\n'
    PRE_INFO+="primary use_large_pages=ONLY, but this server has not enough HugePages -> TRUE on standby (configure HugePages later)"$'\n'
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
    PRE_INFO+="primary recovery area size $(( rfs / 1048576 )) MB is bigger than $FRA_LOC here ($fra_total MB) -> $(( fra_total * 90 / 100 )) MB on standby"$'\n'
  fi
  # control files: same disk group (new OMF names) or the same path (an OMF file name becomes controlNN.ctl)
  prim_sql "select name from v\$controlfile;" || { PRE_FIX="Cannot read the control files of primary"; return 1; }
  local cf n=0
  while IFS= read -r cf; do
    [[ "$cf" =~ ^[+/][A-Za-z0-9_./-]+$ ]] || continue
    n=$((n + 1))
    if [[ "$cf" == +* ]]; then cf=$(norm_loc "$cf")
    elif [[ "$(basename "$cf")" == o1_mf_*.ctl ]]; then cf="$(dirname "$cf")/$(printf 'control%02d.ctl' "$n")"; fi
    CF_LIST+="${CF_LIST:+,}'$cf'"
  done <<< "$SQL_OUT"
  [[ -n "$CF_LIST" ]] || { PRE_FIX="No control file names from primary"; return 1; }
  # every datafile and tempfile is created in its own disk group (or with its own name in a folder)
  prim_sql "select 'D|'||file#||'|'||name from v\$datafile union all select 'T|'||file#||'|'||name from v\$tempfile;" || { PRE_FIX="Cannot read the datafile names of primary"; return 1; }
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
        PRE_FIX="$exn file(s) already exist at the paths the copy will write to (not from a copy made by this script):"$'\n'"${ex%$'\n'}"
        [[ $exn -gt 5 ]] && PRE_FIX+=$'\n'"  ... and $((exn - 5)) more"
        PRE_FIX+=$'\n'"RMAN would overwrite them (NOFILENAMECHECK). If they belong to an old database of this server, move or remove them (step 2.15 proved they are not the primary's). If they may be overwritten:  touch $STATE_DIR/existing_files_ok   and answer r."
        return 1
      fi
      PRE_INFO+="$exn file(s) of the earlier copy at the target paths are overwritten"$'\n'
    fi
  fi
  if grep -qE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT"; then
    # file-system OMF files are created again as OMF files in db_create_file_dest
    local omfd="$CFD"
    if [[ "$omfd" != /* ]]; then
      # db_create_file_dest is not a folder on primary: the standby gets the folder of the OMF files (set on the standby only)
      omfd=$(grep -m1 -oE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT" | cut -d'|' -f3); omfd=$(dirname "$(dirname "$(dirname "$omfd")")")
      v_path "$omfd" || { PRE_FIX="Cannot find the folder for the OMF datafiles of primary"; return 1; }
      DUP_EXTRA+="      set db_create_file_dest='$omfd'"$'\n'
    fi
    runuser -u "$ORACLE_USER" -- test -d "$omfd" -a -w "$omfd" || { PRE_FIX="The OMF folder $omfd does not exist here or is not writable by $ORACLE_USER (step 2.14)"; return 1; }
    PRE_INFO+="OMF datafiles in folders are created in $omfd/${STANDBY_UNIQUE^^}"$'\n'
  fi
  if use_grid && [[ -z "$CFD" || "$CFD" == "-" ]] && ! grep -qE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT"; then
    # datafiles in ASM but no db_create_file_dest: the standby could not create its standby/online logs (ORA-15046).
    # The disk group is the one of the datafiles (never a disk group that only holds the recovery area).
    local ddg; ddg=$(grep -m1 -oE '^D\|[0-9]+\|\+[^/]+' <<< "$SQL_OUT" | cut -d'|' -f3)
    if [[ -n "$ddg" ]]; then
      DUP_EXTRA+="      set db_create_file_dest='$ddg'"$'\n'
      PRE_INFO+="primary has no db_create_file_dest -> $ddg on standby (needed to create standby redo logs in ASM)"$'\n'
    fi
  fi
  # the standby's own audit folder
  DUP_EXTRA+="      set audit_file_dest='$(adump_dir)'"$'\n'
  # redo transport destination used on primary for this standby (the standby gets the same N back to primary)
  find_dest || { PRE_FIX="Cannot read log_archive_dest_N on primary"; return 1; }
  p_param log_archive_config && P_DG_CONFIG=$PVAL || P_DG_CONFIG=""
  dg_config_names_ok "$P_DG_CONFIG" || { PRE_FIX="log_archive_config of primary ($P_DG_CONFIG) cannot be read safely; check step 4.3"; return 1; }
  # primary parameters that do not fit the standby
  prim_sql "select name||'|'||value from v\$parameter where value is not null and (name like 'db_create_online_log_dest%' or name like 'log_archive_dest%' or name in ('log_archive_duplex_dest','remote_listener','local_listener','fal_client','db_file_name_convert','log_file_name_convert','dg_broker_start','instance_name','service_names'));" || { PRE_FIX="Cannot read primary parameters"; return 1; }
  local line pname pval known_dgs=" $(asm_dgs | tr '\n' ' ') "
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pname=${line%%|*}; pval=${line#*|}
    if [[ "$pname" =~ ^db_create_online_log_dest_[1-5]$ ]]; then
      local loc; loc=$(norm_loc "$pval")
      if [[ "$loc" == +* && "$known_dgs" != *" ${loc#+} "* ]] || [[ "$loc" == /* && ! -d "$loc" ]]; then
        DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="primary $pname=$pval does not exist here -> cleared on standby"$'\n'
      fi
    elif [[ "$pname" =~ ^log_archive_dest_([0-9]+)$ ]]; then
      local dn=${BASH_REMATCH[1]}
      if [[ "$dn" != "$DEST_N" && "$dn" != "$ARCH_N" && "$(sed -E "s/ *= */=/g" <<< "${pval^^}")" == *SERVICE=* ]]; then
        # a destination to another standby: kept for a later switchover, but off until then
        DUP_EXTRA+="      set log_archive_dest_state_$dn='defer'"$'\n'; PRE_INFO+="primary $pname (another standby) -> kept, deferred on this standby"$'\n'
      elif [[ "$dn" != "$DEST_N" && "$dn" != "$ARCH_N" ]]; then
        DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="primary $pname is set -> cleared on standby"$'\n'
      fi
    elif [[ "$pname" == "log_archive_dest" || "$pname" == "log_archive_duplex_dest" ]]; then
      # old-style parameters cannot be used together with log_archive_dest_1 (ORA-16019)
      DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="primary uses old-style $pname -> cleared on standby"$'\n'
    elif [[ "$pname" == "remote_listener" || "$pname" == "fal_client" || "$pname" == "db_file_name_convert" ]]; then
      DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="primary $pname -> cleared on standby"$'\n'
    elif [[ "$pname" == "log_file_name_convert" ]]; then
      HAS_LFNC=1
    elif [[ "$pname" == "dg_broker_start" && "${pval^^}" == "TRUE" ]]; then
      DUP_EXTRA+="      set dg_broker_start='FALSE'"$'\n'; PRE_INFO+="primary uses the Data Guard broker -> off on the standby until you add it to the broker configuration"$'\n'
    elif [[ "$pname" == "instance_name" && "${pval^^}" != "${STANDBY_SID^^}" ]]; then
      DUP_EXTRA+="      set instance_name='$STANDBY_SID'"$'\n'; PRE_INFO+="primary instance_name=$pval -> $STANDBY_SID on standby"$'\n'
    elif [[ "$pname" == "service_names" ]]; then
      DUP_EXTRA+="      set service_names='$STANDBY_SERVICE'"$'\n'; PRE_INFO+="primary service_names=$pval -> $STANDBY_SERVICE on standby (clients must not reach the standby with the primary service)"$'\n'
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
      PRE_FIX="RMAN does not accept the generated script: $(grep -E 'RMAN-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ') (the script: $LOG_DIR/duplicate_check_$RUN_ID.rman)"
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
      PRE_FIX="RMAN cannot log in to both databases: $(grep -E '(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ')- check the logins of steps 7.4 and 7.5"; return 1
    fi
    PRE_INFO+="RMAN accepts the script and logs in to both databases"$'\n'
    grep -qE '^(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" && PRE_INFO+="(RMAN printed warnings at the login: $(grep -E '^(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' '))"$'\n'
    RMAN_PREFLIGHT_OK=$(rman_script | md5sum | cut -c1-12)
  fi
  PRE_INFO=${PRE_INFO%$'\n'}
  PRE_OK=1
}
HAS_LFNC=0; RMAN_PREFLIGHT_OK=""

c_8_1() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  need_ssh || return 2
  detect_built
  [[ $STANDBY_BUILT -eq 1 ]] || need_sys || return 2
  [[ $STANDBY_BUILT -eq 1 ]] && { NOW="Standby database already exists; duplicate is not needed"; return 0; }
  if dup_prechecks; then NOW=$PRE_INFO; return 0; fi
  NOW=$PRE_FIX
  [[ "$PRE_FIX" == *"(step "* ]] && return 2          # an earlier step is not done yet
  PLAN="$PRE_FIX"; return 1
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
  [[ $STANDBY_BUILT -eq 1 ]] && { NOW="Standby database exists (duplicate finished)"; return 0; }
  if [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]]; then
    NOW="A failed or unfinished copy is on this server ($SC_INFO). Clean it first: run  $SELF --from 7.2  (step 7.2 shows the commands)"
    return 2
  fi
  dup_prechecks || { NOW="Pre-checks not passed: $PRE_FIX (step 8.1)"; return 2; }
  NOW="Standby instance is NOMOUNT, all pre-checks passed"
  local nd nt; nd=$(grep -c 'for datafile' <<< "$NEWNAMES"); nt=$(grep -c 'for tempfile' <<< "$NEWNAMES")
  PLAN="As $ORACLE_USER:  rman target sys@$PRIMARY_TNS auxiliary sys@$STANDBY_TNS
duplicate target database for standby from active database dorecover spfile ... nofilenamecheck
  set newname for $nd datafiles and $nt tempfiles (each stays in its own disk group / keeps its path)
  spfile changes:
$(sed -n 's/^      set /    /p' <<< "$(rman_script)")
The full script is written to $LOG_DIR/duplicate_<date>.rman before it starts."
  # the network limits the whole copy: about 100 MB/s on 1 Gbit/s, up to about 1000 MB/s on 10 Gbit/s
  local rate_hi=$(( AUX_CHANNELS * 150 )); [[ $rate_hi -gt 1000 ]] && rate_hi=1000
  local est_lo est_hi; est_lo=$(( PRIMARY_DB_MB / rate_hi / 60 + 1 )); est_hi=$(( PRIMARY_DB_MB / 100 / 60 + 1 ))
  USING="size to copy: about $(human_mb "$PRIMARY_DB_MB"); $AUX_CHANNELS channels on THIS server
rough time: $(human_min "$est_lo") (fast network and storage, $AUX_CHANNELS channels) to $(human_min "$est_hi") (1 Gbit/s network). The screen shows the progress.
On PRIMARY during the copy: RMAN READS the datafiles (extra I/O and network), log switches happen,
a snapshot control file is written in its \$ORACLE_HOME/dbs, and every login writes an audit file in
its audit_file_dest. Nothing is created, dropped or changed in the primary database.
Run it at a time with little load (for example at night). You will be asked to type DUPLICATE."
  [[ -z "${TMUX:-}${STY:-}" ]] && USING+=$'\n'"The copy runs by itself in its own session: a closed terminal does not stop it (run the script again to see it)."
  return 1
}

d_8_2() {
  confirm_word "Start the RMAN duplicate now?" "DUPLICATE" || { say "Duplicate not started."; return 3; }
  # the checks again, right before the start (tnsnames.ora or the instance may have changed meanwhile)
  dup_prechecks || { bad "Pre-checks not passed any more: $PRE_FIX"; return 1; }
  local rmanfile="$LOG_DIR/duplicate_$RUN_ID.rman" rlog="$LOG_DIR/duplicate_$RUN_ID.log"
  [[ -e "$(dup_marker)" ]] && rm -f -- "$(dup_marker)"
  rman_script | write_as root "$rmanfile" 640 || return 1
  say "RMAN script: $rmanfile"
  say "Full RMAN output: $rlog  (progress lines below)"
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
    DONE_MSG="Finished Duplicate Db"
    return 0
  fi
  bad "Duplicate did not finish (exit code $rc; $(ora_errors "$(cat "$rlog")"))"
  install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/dup_attempt"
  RESUME_STEP=7.2; DO_FAIL_STOP_ONLY=1
  {
    grep -m1 -E '^(RMAN|ORA)-[0-9]+' "$rlog" | sed 's/^/first error: /'
    printf 'Full output: %s\n' "$rlog"
    printf ' ORA-19504/ORA-17502  disk group missing or not mounted\n'
    printf ' ORA-01017            password files differ (step 6.1)\n'
    printf ' ORA-12528/ORA-12514  listener/tnsnames (phase 5)\n'
    printf ' ORA-15025/ORA-27041  the oracle binary cannot open the ASM disks (setasmgidwrap, step 8.1)\n'
    printf 'Before trying again, clean THIS server: answer q, then run  %s --from 7.2  (it shows the clean-up commands)\n' "$SELF"
  } | hint
  return 1
}

dup_success_record() {
  # the duplicate finished: marker, the initial pfile out of the way, journal (also when the run was not watching)
  set_marker duplicate
  rm -f -- "$STATE_DIR/dup_attempt"
  local p; p=$(pfile_path)
  [[ -f "$p" ]] && runuser -u "$ORACLE_USER" -- mv -f -- "$p" "$p.pre_duplicate_$RUN_ID" && { say "initial pfile renamed (the spfile is used from now on)"; journal RENAME "$p" "to=$p.pre_duplicate_$RUN_ID"; }
  journal DUPLICATE_DONE "$STANDBY_UNIQUE" "Finished Duplicate Db; spfile $(spfile_path)"
  return 0
}

phase_8() {
  phase_header 8 "Copy the database (RMAN active duplicate)"
  run_step 8.1 check "Pre-checks (space, storage, TNS targets, parameters)" c_8_1
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
    NOW="The standby instance is not running (step 9.2): $(use_grid && printf 'srvctl start database -db %s' "$STANDBY_UNIQUE" || printf 'startup mount')  as $ORACLE_USER; also check:  systemctl status $(unit_name 2>/dev/null)"
    return 1
  fi
  [[ $STANDBY_BUILT -eq 1 ]] && return 0
  if [[ $DETECT_RC -eq 2 ]]; then NOW="Cannot tell whether the standby is complete: $SC_INFO"; return 1; fi
  NOW="The standby database does not exist yet (phase 8)"; return 1
}
adg_note() {
  # an OPEN standby with apply running is Active Data Guard (a separate license)
  [[ "$1" == OPEN* ]] && warn "The standby is OPEN. Opening a physical standby while redo is applied needs the Active Data Guard license; this script only mounts it."
  return 0
}

# ---- 9.1 ----
srv_dgs() { asm_dgs | paste -sd, -; }
c_9_1() {
  use_grid || { NOW="Not needed (no Oracle Restart on this server; see step 9.7 for start at boot)"; return 0; }
  need_built || return 2
  local srv="$DB_HOME/bin/srvctl" spf; spf=$(spfile_path)
  [[ -f "$spf" ]] || { NOW="spfile not found: $spf"; return 2; }
  local add="srvctl add database -db $STANDBY_UNIQUE -oraclehome $DB_HOME -spfile $spf -pwfile $(pw_dest) -role PHYSICAL_STANDBY -startoption MOUNT -dbname $DB_NAME -instance $STANDBY_SID -diskgroup $(srv_dgs)${PRIMARY_DOMAIN:+ -domain $PRIMARY_DOMAIN}"
  if run_logged "srvctl config database" as_oracle "$srv" config database -db "$STANDBY_UNIQUE"; then
    local cfg=$RUN_OUT bad_items=""
    grep -qiE "^spfile:[[:space:]]*${spf}[[:space:]]*\$" <<< "$cfg" || bad_items+=" spfile"
    grep -qiE "^Database role:[[:space:]]*PHYSICAL_STANDBY" <<< "$cfg" || bad_items+=" role"
    grep -qiE "^(Database instance|Instance)( name)?:[[:space:]]*${STANDBY_SID}[[:space:]]*\$" <<< "$cfg" || bad_items+=" instance"
    if [[ -z "$bad_items" ]]; then NOW="Registered: spfile $spf, role PHYSICAL_STANDBY, instance $STANDBY_SID"; return 0; fi
    NOW="Registered, but wrong:$bad_items"$'\n'"$(grep -iE '^(spfile|database role|database instance|instance)' <<< "$cfg")"
    REG_MODE=re
    PLAN="On THIS server only, as $ORACLE_USER:
srvctl stop database -db $STANDBY_UNIQUE
srvctl remove database -db $STANDBY_UNIQUE -noprompt
$add"
    return 1
  fi
  REG_MODE=add
  NOW="$STANDBY_UNIQUE is not registered in Oracle Restart"
  PLAN="As $ORACLE_USER:
$add"
  USING="-instance must be exactly $STANDBY_SID (otherwise: 'Connected to an idle instance')"
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
      IDLE) NOW="The standby instance is not running"; PLAN="sqlplus / as sysdba  ->  startup mount   (as $ORACLE_USER)"; return 1 ;;
      STARTED) NOW="The instance is in NOMOUNT (started with the first pfile)"; PLAN="sqlplus / as sysdba  ->  shutdown immediate ; startup mount   (as $ORACLE_USER, with the spfile)"; return 1 ;;
      *) NOW="Instance state: $LSTATE ($(ora_errors "$SQL_OUT"))"; return 2 ;;
    esac
  fi
  run_logged "srvctl status" as_oracle timeout 120 "$DB_HOME/bin/srvctl" status database -db "$STANDBY_UNIQUE" || true
  local srv_on=0
  grep -qi 'is running' <<< "$RUN_OUT" && ! grep -qi 'is not running' <<< "$RUN_OUT" && srv_on=1
  if sql_local "select i.instance_name||'|'||i.status||'|'||d.database_role from v\$instance i, v\$database d;"; then
    local iname ist irole; IFS='|' read -r iname ist irole <<< "$(first_line)"
    if [[ $srv_on -eq 1 && "$iname" == "$STANDBY_SID" && "$irole" == "PHYSICAL STANDBY" && ( "$ist" == "MOUNTED" || "$ist" == "OPEN" ) ]]; then
      adg_note "$ist"; NOW="srvctl: running; instance $iname $ist $irole"; return 0
    fi
    if [[ $srv_on -eq 0 ]]; then
      NOW="Instance $iname is $ist, but it was started by RMAN, not by Oracle Restart"
      PLAN="As $ORACLE_USER (THIS server):
sqlplus / as sysdba  ->  shutdown immediate
srvctl start database -db $STANDBY_UNIQUE"
      return 1
    fi
    NOW="Unexpected: instance=$iname status=$ist role=$irole"; return 2
  fi
  if [[ $srv_on -eq 1 ]] && grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    NOW="srvctl says running, but ORACLE_SID=$STANDBY_SID is idle: the registration uses another instance name (step 9.1)"
    return 2
  fi
  NOW="The standby instance is not running"
  PLAN="srvctl start database -db $STANDBY_UNIQUE   (as $ORACLE_USER)"
  return 1
}
d_9_2() {
  if ! use_grid; then
    [[ "$LSTATE" == "STARTED" ]] && { sql_local_long "shutdown immediate" || true; }
    sql_local_long "startup mount" || { bad "startup mount failed ($(ora_errors "$SQL_OUT"))"; return 1; }
    journal INSTANCE "$STANDBY_SID" "startup mount (standby)"; return 0
  fi
  local_state
  if [[ "$LSTATE" != "IDLE" && "$LSTATE" != "NOSW" ]]; then
    say "Stopping the instance started by RMAN (this server only)"
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
  PLAN="On THIS server, sqlplus / as sysdba (apply is stopped first if running):
$SRL_SQL"
  USING="same size as the online logs of primary; one more than the online groups, per thread"
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
    bad "Adding standby redo logs failed ($(ora_errors "$SQL_OUT"))"
    grep -q 'ORA-01378' <<< "$SQL_OUT" && printf 'ORA-01378: the online logs of the primary use 4K blocks; the disk group / file system here must have a 4K sector size.\n' | hint
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
    arch_in_fra && NOW+=" (the recovery area deletes applied logs when it needs space)" || NOW+=$'\n'"$(arch_timer) deletes applied logs older than one day in $ARCH_LOC every night"
    return 0
  fi
  NOW=""
  [[ $ARCH_POLICY_OK -eq 1 ]] || NOW="RMAN archivelog deletion policy of the standby: ${v/#-/not set}$([[ "$v" != "-" ]] && printf ' (copied from the primary with its control file)'). It does not delete applied logs here: the archived logs fill the disk and redo transport stops (ORA-19809 / ORA-00257)."
  [[ $tok -eq 1 ]] || NOW+="${NOW:+$'\n'}The archive destination is not the recovery area ($ARCH_LOC): Oracle deletes nothing there by itself."
  PLAN=""
  [[ $ARCH_POLICY_OK -eq 1 ]] || PLAN="As $ORACLE_USER on THIS server:  rman target /  ->  CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;"
  [[ $tok -eq 1 ]] || PLAN+="${PLAN:+$'\n'}A daily systemd timer $(arch_timer) (04:30) runs $(arch_script) as $ORACLE_USER:"$'\n'"  rman target /  ->  delete noprompt archivelog all completed before 'sysdate-1';   (logs not applied yet are kept)"
  USING="For the PRIMARY nothing is changed. Its own policy belongs to its backups: check it there with  rman target /  ->  show archivelog deletion policy;
Only if the primary is backed up by RMAN, a policy such as TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DEVICE TYPE <the device of its backups: DISK or SBT>
keeps logs until this standby has them. Never set it on a primary that RMAN does not back up (its logs would never be deleted)."
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
    [[ $lrc -eq 0 ]] || { bad "rman failed ($(ora_errors "$RUN_OUT"))"; return 1; }
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
    NOW="MRP (apply) is running"
    # real-time apply needs standby redo logs that the standby can use; without them redo is applied from archived logs only
    if sql_local "select nvl(max(recovery_mode),'-') from v\$archive_dest_status where recovery_mode like 'MANAGED%';" && [[ "$(first_line)" != "-" && "$(first_line)" != *"REAL TIME"* ]]; then
      warn "Redo is applied from archived logs only (recovery_mode = $(first_line)), not in real time. Usually the standby redo logs cannot be used: step 9.3, and in the alert log: ORA-19527, ORA-15046, ORA-15173, 'No standby redo logfiles'."
    fi
    return 0
  fi
  NOW="MRP (apply) is not running"
  PLAN="alter database recover managed standby database disconnect from session;   (THIS server)"
  return 1
}
d_9_4() {
  if ! sql_local "alter database recover managed standby database disconnect from session;"; then
    bad "Cannot start apply ($(ora_errors "$SQL_OUT"))"
    grep -q 'ORA-01153' <<< "$SQL_OUT" && printf 'ORA-01153: another recovery session is active (an old MRP or a manual recover). Cancel it first:\n  alter database recover managed standby database cancel;\n' | hint
    grep -q 'ORA-01154' <<< "$SQL_OUT" && printf 'ORA-01154: the database is OPEN or being opened; a physical standby is mounted, not opened, by this script.\n' | hint
    return 1
  fi
  journal MRP "$STANDBY_SID" "redo apply started"
  local n=0; until mrp_running || [[ $n -ge 6 ]]; do sleep 5; n=$((n + 1)); done
}

# ---- 9.5 ----
c_9_5() {
  need_built || return 2
  need_ssh || return 2
  find_dest || { NOW="Cannot read the log_archive_dest parameters on primary"; return 2; }
  local d=$DEST_N
  p_param "log_archive_dest_$d" || { NOW="Query failed"; return 2; }
  if ! has_token "$PVAL" "SERVICE=${STANDBY_TNS^^}"; then
    NOW="log_archive_dest_$d on primary does not point to the standby ($PVAL)"
    PLAN="alter system set log_archive_dest_$d='service=$STANDBY_TNS async valid_for=(online_logfiles,primary_role) db_unique_name=$STANDBY_UNIQUE' scope=both;
alter system set log_archive_dest_state_$d=enable scope=both;
alter system switch logfile;"
    PLAN_UNDO="alter system set log_archive_dest_state_$d=defer scope=both;   (stops shipping to this standby)"
    return 1
  fi
  prim_sql "select upper(value) from v\$parameter where name='log_archive_dest_state_$d';" || { NOW="Query failed"; return 2; }
  local st; st=$(first_line)
  # ORA- inside the error column would look like a failed query, so it is masked in SQL and restored here
  prim_sql "select status||'|'||nvl(replace(error,'ORA-','ORA_'),'-') from v\$archive_dest where dest_id=$d;" || { NOW="Query failed"; return 2; }
  local s e; IFS='|' read -r s e <<< "$(first_line)"; e=${e//ORA_/ORA-}
  if [[ "$st" == "ENABLE" && "$s" == "VALID" && "$e" == "-" ]]; then NOW="Primary dest_$d is ENABLE and VALID, no error"; return 0; fi
  NOW="Primary log_archive_dest_state_$d=$st, dest_$d status=$s error=$e"
  PLAN="alter system set log_archive_dest_state_$d=enable scope=both;
alter system switch logfile;"
  PLAN_UNDO="alter system set log_archive_dest_state_$d=defer scope=both;   (stops shipping to this standby)"
  if [[ "$e" != "-" ]]; then
    case "$e" in
      *16191*|*1017*) PLAN+=$'\n'"-- error: password files differ (step 6.1)" ;;
      *12154*) PLAN+=$'\n'"-- error: alias $STANDBY_TNS missing in primary tnsnames.ora (step 4.9)" ;;
      *12514*|*12541*) PLAN+=$'\n'"-- error: standby listener (phase 5)" ;;
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
    rfs_running && { NOW="RFS is receiving redo from primary"; return 0; }
    n=$((n + 1)); [[ $n -ge 6 || "$MODE" == "check" ]] && break
    say "waiting for RFS ... ($n/6)"; sleep 10
  done
  NOW="No RFS process on standby yet"
  PLAN="Check step 9.5, then the alert logs:
  standby: ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${STANDBY_UNIQUE,,}/$STANDBY_SID/trace/alert_$STANDBY_SID.log
  primary: ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${PRIMARY_UNIQUE,,}/$PRIMARY_SID/trace/alert_$PRIMARY_SID.log
  primary: alert log of $PRIMARY_SID (look for ORA- near LOG_ARCHIVE_DEST_${DEST_N:-2})"
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
  command -v systemctl >/dev/null 2>&1 || { NOW="systemd not found; start the standby by hand after a reboot"; return 2; }
  need_built || return 2
  local u sc okd=1; u="/etc/systemd/system/$(unit_name)"; sc=$(start_script)
  need_udev_dropin && [[ "$(cat "$(udev_dropin)" 2>/dev/null)" != "$(dropin_text)" ]] && okd=0
  if [[ -f "$u" && "$(cat "$u")" == "$(unit_text)" && -f "$sc" && "$(cat "$sc")" == "$(script_text)" && $okd -eq 1 ]] && systemctl is-enabled --quiet "$(unit_name)" 2>/dev/null && ! systemctl is-failed --quiet "$(unit_name)" 2>/dev/null; then
    if use_grid; then NOW="$(unit_name) is enabled (starts apply after Oracle Restart has mounted the standby)"
    else NOW="$(unit_name) is enabled (listener + startup mount + apply at boot, clean stop at shutdown)"; fi
    return 0
  fi
  if systemctl is-failed --quiet "$(unit_name)" 2>/dev/null; then
    NOW="$(unit_name) is in the failed state: $(systemctl status "$(unit_name)" --no-pager -l 2>&1 | grep -E 'Active:|ORA-|TNS-|error' | head -n 3 | tr '\n' ' ')"
  elif use_grid; then NOW="After a reboot Oracle Restart mounts the standby, but nothing starts apply (MRP)"
  else NOW="Nothing starts the listener and the standby after a reboot (no Oracle Restart here)"; fi
  if use_grid; then PLAN="Create $sc (root-owned; runs as $ORACLE_USER: waits for MOUNT, starts apply)"
  else PLAN="Create $sc (root-owned; runs as $ORACLE_USER: lsnrctl start, startup mount, start apply; at shutdown: shutdown immediate)"; fi
  PLAN+=$'\n'"Create $u (with the Oracle limits: nofile, nproc, stack, memlock) and enable it"
  need_udev_dropin && PLAN+=$'\n'"Create $(udev_dropin): Oracle Restart starts after the ASM disks are there"
  PLAN+=$'\n'"Start the unit once now (it does not change a running standby), so it is stopped cleanly at the next shutdown"
  USING="MOUNT only: opening a standby read-only while apply runs needs the Active Data Guard license"
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
  run_cmds <<< "systemctl start $(unit_name)" || { bad "The unit did not start: systemctl status $(unit_name)"; systemctl status "$(unit_name)" --no-pager -l 2>&1 | tail -n 8 | hint; return 1; }
}

phase_9() {
  phase_header 9 "Register, start apply, start shipping"
  run_step 9.1 auto    "Registration in Oracle Restart (srvctl)" c_9_1 d_9_1
  run_step 9.2 auto    "Standby instance running (MOUNT)" c_9_2 d_9_2
  run_step 9.3 auto    "Standby redo logs on this server" c_9_3 d_9_3
  run_step 9.4 auto    "Apply (MRP)" c_9_4 d_9_4
  run_step 9.5 primary "Redo shipping from primary" c_9_5
  run_step 9.6 check   "Redo arrives on this server (RFS)" c_9_6
  run_step 9.7 auto    "Start at boot (mount and apply)" c_9_7 d_9_7
  run_step 9.8 auto    "Archived logs on the standby (deletion)" c_9_8 d_9_8
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
    if [[ $tls -ge 0 && $tls -le 60 && $als -ge 0 && $als -le 60 ]]; then NOW="transport lag $tl, apply lag $al"; return 0; fi
    tries=$((tries + 1)); [[ $tries -ge 12 || "$MODE" == "check" ]] && break
    say "transport lag=$tl apply lag=$al ... waiting 10s ($tries/12)"; sleep 10
  done
  NOW="transport lag '$tl', apply lag '$al'"
  PLAN="Empty values right after setup are normal for a few minutes.
On primary (as $ORACLE_USER, sqlplus / as sysdba) you can force a log:  alter system switch logfile;
then answer r"
  return 1
}
c_10_2() {
  need_built || return 2
  sql_local "select count(*) from v\$archive_gap;" || { NOW="Cannot read v\$archive_gap"; return 2; }
  num "$(first_line)" || { NOW="Unexpected answer: $(first_line)"; return 2; }
  [[ "$(first_line)" -eq 0 ]] && { NOW="No archive gap"; return 0; }
  sql_local "select thread#||' '||low_sequence#||'-'||high_sequence# from v\$archive_gap;" || true
  NOW="Archive gap: $SQL_OUT"
  PLAN="fal_server normally fetches missing logs within minutes. If it stays:
  grep -iE 'FAL|gap|ORA-' ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${STANDBY_UNIQUE,,}/$STANDBY_SID/trace/alert_$STANDBY_SID.log | tail -30"
  return 1
}
c_10_3() {
  need_built || return 2
  need_ssh || return 2
  prim_sql "select nvl(max(sequence#),0) from v\$archived_log where standby_dest='NO' and thread#=1 and resetlogs_change#=(select resetlogs_change# from v\$database);" || { NOW="Cannot read primary"; return 2; }
  local pmax smax; pmax=$(first_line)
  sql_local "select nvl(max(sequence#),0) from v\$archived_log where applied in ('YES','IN-MEMORY') and thread#=1 and resetlogs_change#=(select resetlogs_change# from v\$database);" || { NOW="Cannot read standby"; return 2; }
  smax=$(first_line)
  num "$pmax" && num "$smax" || { NOW="Unexpected answer (primary '$pmax', standby '$smax')"; return 2; }
  if [[ "$smax" -ge $((pmax - 1)) ]]; then NOW="Primary last archived $pmax, standby applied $smax"; return 0; fi
  NOW="Primary last archived $pmax, standby applied only $smax"
  PLAN="Wait a few minutes (apply catches up), then answer r"
  return 1
}
c_10_4() {
  need_built || return 2
  if mrp_running; then
    NOW="MRP is running"
    # real-time apply uses a standby log that receives the redo; errors of the last day are shown
    if sql_local "select count(*) from v\$standby_log where status='ACTIVE';" && [[ "$(first_line)" == "0" ]]; then
      warn "No standby redo log is in use (none ACTIVE): redo arrives only as archived logs, the lag grows by whole log files. Check step 9.3 and the alert log (ORA-19527, ORA-15046)."
    fi
    if sql_local "select count(*) from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > sysdate-1;" && num "$(first_line)" && [[ "$(first_line)" != "0" ]]; then
      warn "$(first_line) Data Guard error message(s) in the last 24 hours on this standby:  select timestamp, message from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp;"
    fi
    return 0
  fi
  NOW="MRP is not running"; PLAN="Step 9.4:  alter database recover managed standby database disconnect from session;"; return 1
}

phase_10() {
  phase_header 10 "Verify synchronization"
  run_step 10.1 check "Transport and apply lag" c_10_1
  run_step 10.2 check "No archive gap" c_10_2
  run_step 10.3 check "Last sequence: primary vs standby" c_10_3
  run_step 10.4 check "Apply process running" c_10_4
}

#------------------------------------------------------------------------------
# Help: manual commands for every step  (h at any question, or --help-step X.Y)
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
  case "$1" in
  1.1) cat <<EOF
TITLE  Run as root on the standby server
WHERE  STANDBY ($S), user root
RUN    whoami
       hostname -s
EXPECT root, and the standby host name (never the primary)
EOF
  ;;
  1.2) cat <<EOF
TITLE  ssh connection to primary
WHERE  STANDBY ($S), user root
WHY    The script opens ONE ssh connection and sends only read-only commands over it.
RUN    ssh ${PRIMARY_SSH_USER:-oracle}@${PRIMARY_IP:-<primary IP>} hostname
EXPECT the primary host name, after you typed the password
IF     "Permission denied": wrong password, or PasswordAuthentication no in /etc/ssh/sshd_config on primary
       "Connection refused/timed out": sshd or firewall on primary (port 22)
EOF
  ;;
  1.3) cat <<EOF
TITLE  Read the primary configuration (read-only)
WHERE  PRIMARY ($P), user ${PRIMARY_SSH_USER:-oracle}
RUN    ps -eo pid,user,args | grep -E 'ora_pmon|tnslsnr'
       cat /etc/oratab ; cat /etc/oraInst.loc
       id $OU ; id $GU
       $DBH/bin/orabase
       $PSQL
       select name, db_unique_name, database_role, cdb from v\$database;
EXPECT role PRIMARY. The ssh user must be able to run "sqlplus / as sysdba" (dba group).
EOF
  ;;
  1.4) cat <<EOF
TITLE  Standby settings
WHERE  STANDBY ($S), file ${SETTINGS_FILE:-/var/lib/dg_standby_setup/settings.conf}
WHY    Paths, users and groups are the same as primary and are read from it at every run.
       Only the values under "Standby values" can be changed (names, installer files, RU_DIR, OPATCH_ZIP).
RUN    choose a to accept, or e to edit (KEY=VALUE lines, no spaces). Later: --settings
EXPECT STANDBY_UNIQUE differs from $PU, STANDBY_SID at most 12 characters
EOF
  ;;
  1.5) cat <<EOF
TITLE  sys password
WHERE  STANDBY ($S)
WHY    Needed for RMAN and the login tests. Kept in memory only, never written to disk or log.
RUN    on primary:  $OU ->  $DBH/bin/sqlplus sys@//localhost:$PO/$PSV as sysdba
EXPECT Connected
IF     ORA-01017: wrong password, or SYS not in the password file (step 4.7)
EOF
  ;;
  1.6) cat <<EOF
TITLE  Oracle version supported on this Oracle Linux
WHERE  STANDBY ($S)
WHY    12.1, 12.2 and 18c: Oracle Linux 7 only.  19c: OL7, OL8 (the 19.3 installer gets CV_ASSUME_DISTID=OEL7.8),
       OL9 only with Release Update 19.19+ applied by the installer (-applyRU).  21c: OL7/8/9.  23ai: OL8/9.
RUN    cat /etc/os-release
       for 19c on OL9: unzip the RU (with Grid: the GI Release Update) to a folder, put the newest OPatch zip
       (p6880880) on this server, and set RU_DIR=<folder> and OPATCH_ZIP=<zip> in the settings (step 1.4, e)
EXPECT a supported pair
EOF
  ;;
  2.1) cat <<EOF
TITLE  Groups (same names and ids as primary)
WHERE  STANDBY ($S), user root
RUN    getent group $(tr ',' ' ' <<< "${GROUP_GIDS:-oinstall:54321}" | sed 's/:[0-9]*//g')
       groupadd -g <gid> <name>      for each missing group (gid as on primary)
EXPECT the same gid as on primary:  ${GROUP_GIDS:-<name:gid list>}
IF     a group exists with another gid and nothing is installed yet:  groupmod -g <gid> <name>
EOF
  ;;
  2.2)
    printf 'TITLE  Users (same ids as primary)\nWHERE  STANDBY (%s), user root\n' "$S"
    printf 'RUN    useradd -m -s /bin/bash -u %s -g %s%s %s\n' "${ORACLE_UID:-<uid>}" "$IG" "${ORACLE_GROUPS:+ -G $ORACLE_GROUPS}" "$OU"
    [[ $SO -eq 0 && $G -eq 1 ]] && printf '       useradd -m -s /bin/bash -u %s -g %s%s %s\n' "${GRID_UID:-<uid>}" "${GRID_PGROUP:-oinstall}" "${GRID_GROUPS:+ -G $GRID_GROUPS}" "$GU"
    printf '       passwd <user>      (optional)\nEXPECT id %s   -> same numbers and groups as on primary\n' "$OU"
  ;;
  2.3) cat <<EOF
TITLE  Required packages
WHERE  STANDBY ($S), user root
RUN    ${PKG:-dnf} install -y <package>        one by one: <preinstall> unzip chrony parted bc
       <preinstall> by version:  12.1 oracle-rdbms-server-12cR1-preinstall   12.2 oracle-database-server-12cR2-preinstall
                                 18c oracle-database-preinstall-18c   19c ...-19c   21c ...-21c   23ai ...-23ai
       with ASMLib also:  oracleasm-support
EXPECT Complete!
IF     "No package available": enable the repository (yum repolist / dnf repolist), for example ol7_latest, ol8_appstream
EOF
  ;;
  2.4) cat <<EOF
TITLE  Limits for the Oracle owners
WHERE  STANDBY ($S), user root, file /etc/security/limits.d/oracle-grid.conf
WHY    The preinstall package sets limits only for the user named "oracle". Every other owner needs them.
RUN    <user> soft nofile 1024     <user> hard nofile 65536
       <user> soft nproc 16384     <user> hard nproc 16384
       <user> soft stack 10240     <user> hard stack 32768
       <user> soft memlock unlimited   <user> hard memlock unlimited
EXPECT as <user> after a new login:  ulimit -Hn  -> 65536
EOF
  ;;
  2.5)
    printf 'TITLE  Software folders\nWHERE  STANDBY (%s), user root\n' "$S"
    if [[ $G -eq 1 ]]; then
      printf 'RUN    mkdir -p %s %s %s %s %s\n' "$GB" "$GH" "$INV" "$OB" "$DBH"
      printf '       chown %s:%s %s %s %s ; chown %s:%s %s %s\n' "$GU" "$IG" "$GB" "$GH" "$INV" "$OU" "$IG" "$OB" "$DBH"
    else
      printf 'RUN    mkdir -p %s %s %s\n' "$INV" "$OB" "$DBH"
      printf '       chown %s:%s %s %s %s\n' "$OU" "$IG" "$INV" "$OB" "$DBH"
    fi
    printf 'EXPECT ls -ld %s  -> owner %s\nWHY    The script never changes the owner of a folder that already has files.\n' "$DBH" "$OU"
  ;;
  2.6) cat <<EOF
TITLE  Host names on this server
WHERE  STANDBY ($S), user root, file /etc/hosts
RUN    getent ahostsv4 $P ; getent ahostsv4 $S
       if missing, add:  ${PRIMARY_IP:-<primary IP>}  $P      and   ${STANDBY_IP:-<standby IP>}  $S
EXPECT the right IPv4 address for both names (never 127.x for $S)
EOF
  ;;
  2.7) cat <<EOF
TITLE  Primary resolves the standby host name
WHERE  PRIMARY ($P), user root, file /etc/hosts
RUN    getent hosts $S
       if missing:  echo '${STANDBY_IP:-<standby IP>}    $S' >> /etc/hosts
EXPECT the standby IP
EOF
  ;;
  2.8) cat <<EOF
TITLE  Network to the primary listener
WHERE  STANDBY ($S), user root
RUN    timeout 5 bash -c "</dev/tcp/${PRIMARY_IP:-<primary IP>}/$PO" && echo OPEN
EXPECT OPEN
IF     no output: on PRIMARY as root  firewall-cmd --permanent --add-port=$PO/tcp ; firewall-cmd --reload
EOF
  ;;
  2.9) cat <<EOF
TITLE  Firewall on this server
WHERE  STANDBY ($S), user root
RUN    firewall-cmd --get-active-zones            (the zone of the network interface)
       firewall-cmd --permanent --zone=<zone> --add-port=$PO/tcp
       firewall-cmd --reload
EXPECT firewall-cmd --zone=<zone> --query-port=$PO/tcp  -> yes   (or firewalld not running)
EOF
  ;;
  2.10) cat <<EOF
TITLE  Time synchronization
WHERE  BOTH servers, user root
RUN    systemctl enable --now chronyd        (a running ntpd is also fine)
       chronyc tracking
EXPECT Leap status : Normal
EOF
  ;;
  2.11)
    printf 'TITLE  Environment (.bash_profile) of the Oracle users\nWHERE  STANDBY (%s), ~/.bash_profile of %s%s\n' "$S" "$OU" "$([[ $G -eq 1 && $SO -eq 0 ]] && printf ' and of %s' "$GU")"
    printf 'WHY    The script itself does not need it, but sqlplus/rman/srvctl by hand do.\n'
    printf 'RUN    %s:  export ORACLE_BASE=%s ; export ORACLE_HOME=%s ; export ORACLE_SID=%s\n' "$OU" "$OB" "$DBH" "$SID"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '       %s:  export ORACLE_BASE=%s ; export ORACLE_HOME=%s ; export ORACLE_SID=+ASM\n' "$GU" "$GB" "$GH"
    printf '       export PATH=$ORACLE_HOME/bin:$PATH\n'
    printf "EXPECT su - %s -c 'echo \$ORACLE_SID \$ORACLE_HOME'   ->  %s %s   (exact case)\n" "$OU" "$SID" "$DBH"
    printf 'IF     a wrong value comes from ~/.bashrc or /etc/profile.d: the last export wins; fix those lines\n'
  ;;
  2.12) cat <<EOF
TITLE  ASM disk method
WHERE  STANDBY ($S), user root
WHY    ASMLib needs the UEK kernel (Oracle Linux 7/8). Otherwise udev rules are used: they work on every kernel.
RUN    ASMLib:  oracleasm configure -u $GU -g $AG -e -s y ; oracleasm init ; systemctl enable oracleasm ; oracleasm status
       udev:    nothing to configure here (one rule per disk in step 2.13); set ASM_METHOD=udev in the settings
EXPECT ASMLib: "Checking if ASM is loaded: yes", and systemctl is-enabled oracleasm -> enabled
EOF
  ;;
  2.13) cat <<EOF
TITLE  ASM disks (one or more per disk group, same disk group names as primary: $DGS)
WHERE  STANDBY ($S), user root
WHY    The disks must be EMPTY (also the first MiB). Everything on them is erased. Labels: <DG>_1, <DG>_2 ...
RUN    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,WWN
       for every disk:  parted -s <disk> mklabel gpt mkpart primary 1MiB 100% ; partprobe <disk>
       (the partition is <disk>1, or <disk>p1 for nvme disks)
       ASMLib:  oracleasm createdisk ${DD}_1 <partition> ; oracleasm scandisks ; oracleasm listdisks
       udev:    udevadm info --query=property --name=<partition> | grep ID_PART_ENTRY_UUID
                echo 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_UUID}=="<uuid>", SYMLINK+="oraasm/${DD}_1", OWNER="$GU", GROUP="$AG", MODE="0660"' >> /etc/udev/rules.d/99-oracle-asmdevices.rules
                udevadm control --reload-rules ; udevadm trigger --action=change ; ls -lL /dev/oraasm/
       then add the label to ${STATE_DIR}/asm_disks as  LABEL|partition  (or answer y when the script asks to use it;
       a disk that already belongs to a disk group is used only when THIS server's ASM has that group mounted)
EXPECT ${DD}_1 (${DD}_2 ...) for every disk group, big enough (database size + 10%)
IF     the script says the disk has data and you are SURE it is free:  wipefs -a <disk> ; dd if=/dev/zero of=<disk> bs=1M count=10
       multipath (SAN): a partition on a multipath device is matched with ENV{DM_UUID}=="part1-mpath-<wwid>"
                (the whole device: "mpath-<wwid>"); then add the line  <LABEL>|/dev/mapper/<name>  to STATE_DIR/asm_disks
EOF
  ;;
  2.14) cat <<EOF
TITLE  Database folders and free space (primary stores files in folders, not in ASM)
WHERE  STANDBY ($S), user root
WHY    The standby uses exactly the same paths as primary (no file name conversion).
RUN    df -h <each folder of primary>
       mkdir -p <folder> ; chown $OU:$IG <folder>
       not enough space: new disk -> mkfs.xfs /dev/<empty disk> ; mount it at the same path ; add it to /etc/fstab
EXPECT every folder exists, owner $OU, and its file system has the space of primary + 10%
EOF
  ;;
  2.15) cat <<EOF
TITLE  Database folders are not shared with the primary
WHERE  STANDBY ($S), user root
WHY    With the same paths, a folder that is the primary's NFS export or SAN volume would be overwritten by the copy.
RUN    touch <folder>/test_from_standby
       on primary:  ls -l <folder>/test_from_standby       -> must say: No such file or directory
       rm <folder>/test_from_standby
EXPECT the primary does not see the file
       (a built standby: the proof was given before the copy; the step says so)
       The same file system UUID on both servers (findmnt -o SOURCE,UUID --target <folder>) means a copy of
       the primary's disk or the SAME disk mounted twice: compare the disks on both servers:
         lsblk -s -o NAME,TYPE,WWN,SERIAL,SIZE \$(findmnt -n -o SOURCE --target <folder>)
       Change nothing on such a disk before you know which it is.
EOF
  ;;
  3.1)
    printf 'TITLE  Installer files\nWHERE  PRIMARY (%s) for a gold image, then STANDBY (%s) as root\n' "$P" "$S"
    if [[ ${DB_MAJOR:-19} -ge 18 ]]; then
      printf 'RUN    best: a gold image of the primary home, it has the same patches:\n'
      printf '         on primary as %s:  mkdir -p /tmp/gold ; %s/runInstaller -silent -createGoldImage -destinationLocation /tmp/gold\n' "$OU" "$DBH"
      [[ $G -eq 1 ]] && printf '         on primary as %s:  mkdir -p /tmp/gold ; %s/gridSetup.sh -silent -createGoldImage -destinationLocation /tmp/gold\n' "$GU" "$GH"
      printf '         here as root:  mkdir -p /stage ; scp %s@%s:/tmp/gold/*.zip /stage/\n' "${PRIMARY_SSH_USER:-oracle}" "${PRIMARY_IP:-<primary IP>}"
      printf '       or the base files: LINUX.X64_<180000|193000|213000>_db_home.zip (and _grid_home.zip), 23ai from edelivery\n'
    else
      printf 'RUN    the base files: 12.1 linuxamd64_12102_database_1of2.zip + 2of2 (grid: linuxamd64_12102_grid_1of2.zip + 2of2)\n'
      printf '                       12.2 linuxx64_12201_database.zip (grid: linuxx64_12201_grid_home.zip)\n'
    fi
    printf '       chmod 644 /stage/*.zip   (owner root, %s or %s; nobody else may be able to change them)\n' "$OU" "$GU"
    printf 'EXPECT the script finds them (it searches %s)\n' "${ZIP_DIRS[*]}"
  ;;
  3.2) cat <<EOF
TITLE  Grid Infrastructure software (Oracle Restart) - only when the primary uses ASM
WHERE  STANDBY ($S), user $GU
RUN    12.2 and newer: cd $GH ; unzip -q <grid zip> ; ./gridSetup.sh   (with an RU: -applyRU <folder>)
       12.1:           unzip both zips into a stage folder ; ./grid/runInstaller
       choices: Standalone Server (Oracle Restart), disk group $DD, External, discovery path
       /dev/oracleasm/disks/* (ASMLib) or /dev/oraasm/* (udev), base $GB
EXPECT installer finishes; it asks to run the root scripts (step 3.3)
IF     logs:  $INV/logs/   INS-08101 on OL8/9: the OS is newer than the installer (use an RU, step 1.6)
EOF
  ;;
  3.3) cat <<EOF
TITLE  Grid root scripts
WHERE  STANDBY ($S), user root
RUN    $INV/orainstRoot.sh
       $GH/root.sh
       12.1 on Oracle Linux 7: patch 18370031 first:  $GH/OPatch/opatch napply -oh $GH -local <patch folder>
EXPECT as $GU:  crsctl check has  -> CRS-4638 Oracle High Availability Services is online
IF     root.sh failed:  $GH/crs/install/roothas.sh -deconfig -force ; then $GH/root.sh again
EOF
  ;;
  3.4) cat <<EOF
TITLE  ASM and listener (Grid configuration)
WHERE  STANDBY ($S), user $GU
RUN    12.2+:  $GH/gridSetup.sh -executeConfigTools -responseFile <file> -silent
       12.1:   $GH/cfgtoollogs/configToolAllCommands RESPONSE_FILE=<file with the ASM passwords>
       if HAS is stopped (root):  $GH/bin/crsctl start has
       if ASM is offline:         crsctl start res ora.asm
EXPECT crsctl stat res -t  ->  ora.asm ONLINE, ora.$SL.lsnr ONLINE, ora.${DD^^}.dg ONLINE
EOF
  ;;
  3.5) cat <<EOF
TITLE  ASM disk groups (same names as primary: $DGS)
WHERE  STANDBY ($S), user $GU, sqlplus / as sysasm
RUN    create diskgroup <DG> external redundancy disk '<disk path>' attribute 'compatible.asm'='<as $DD>', 'compatible.rdbms'='<as $DD>';
       asmcmd lsdg
EXPECT every disk group of primary is MOUNTED
IF     exists but dismounted:  alter diskgroup <DG> mount;
EOF
  ;;
  3.6) cat <<EOF
TITLE  Database software (Software Only)
WHERE  STANDBY ($S), user $OU
RUN    18c and newer: cd $DBH ; unzip -q <db zip or gold image> ; ./runInstaller   (with an RU: -applyRU <folder>)
       12.x:          unzip the zip(s) into a stage folder ; ./database/runInstaller
       choices: Set Up Software Only, Single instance, Enterprise Edition, home $DBH, base $OB
EXPECT installer finishes; then step 3.7
EOF
  ;;
  3.7)
    printf 'TITLE  Database root.sh\nWHERE  STANDBY (%s), user root\n' "$S"
    printf 'RUN    %s/orainstRoot.sh      (only if /etc/oraInst.loc does not exist yet)\n       %s/root.sh\n' "$INV" "$DBH"
    printf 'EXPECT ls -l %s/bin/oradism  -> owner root\n' "$DBH"
  ;;
  3.8) cat <<EOF
TITLE  Read/write Oracle home (18c and newer)
WHERE  STANDBY ($S), user $OU
WHY    18c+ can install a read-only home; this setup keeps spfile, password file and tnsnames.ora in the home.
RUN    $DBH/bin/orabasehome
       $DBH/bin/roohctl -disable      (only on a NEW home without any database)
EXPECT orabasehome prints $DBH
EOF
  ;;
  3.9) cat <<EOF
TITLE  Oracle Restart resources ONLINE
WHERE  STANDBY ($S), user $GU
RUN    crsctl stat res -t
       crsctl start res <name>                   (for each OFFLINE one)
       srvctl add listener -listener $SL -endpoints TCP:$PO ; srvctl start listener -listener $SL   (if missing)
EXPECT ora.asm, ora.$SL.lsnr and ora.<DG>.dg ONLINE for: $DGS
EOF
  ;;
  3.10) cat <<EOF
TITLE  Listener port equal to primary
WHERE  STANDBY ($S), user $GU
WHY    The standby listener is always called $SL (Grid creates it); only the port must be the same as on primary.
RUN    srvctl modify listener -listener $SL -endpoints TCP:$PO
       srvctl stop listener -listener $SL ; srvctl start listener -listener $SL
EXPECT lsnrctl status $SL  ->  (PORT=$PO)
EOF
  ;;
  3.11)
    printf 'TITLE  Same release and patches as primary\nWHERE  BOTH servers, user %s\n' "$OU"
    printf 'RUN    <home>/OPatch/opatch lspatches       (on both servers and for every home: the lists must be equal)\n'
    printf '       %s/bin/sqlplus -V                   (the same release)\n' "$DBH"
    printf 'IF     different:  newest OPatch (patch 6880880) into the homes, then\n'
    if [[ $G -eq 1 ]]; then
      printf '                   as root:  %s/OPatch/opatchauto apply <RU folder> -oh %s\n' "$GH" "$GH"
      printf '                   as root:  %s/OPatch/opatchauto apply <RU folder> -oh %s\n' "$DBH" "$DBH"
    else
      printf '                   as %s:  cd <RU folder> ; %s/OPatch/opatch apply\n' "$OU" "$DBH"
    fi
    printf '                   one-off patches as %s:  cd <patch> ; %s/OPatch/opatch apply\n' "$OU" "$DBH"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '                   then as root:  %s/bin/setasmgidwrap o=%s/bin/oracle\n' "$GH" "$DBH"
    [[ ${DB_MAJOR:-19} -ge 18 ]] && printf '       easier: install from a gold image of the primary home (step 3.1)\n'
    true
  ;;
  4.1) cat <<EOF
TITLE  ARCHIVELOG and FORCE LOGGING
WHERE  PRIMARY ($P), $PSQL
RUN    select value from v\$parameter where name='spfile';
       -- empty: the primary runs from a text pfile; first (one restart):
       --   create pfile='/tmp/init<SID>_before_dg.ora' from memory;  create spfile from memory;  then restart
       select log_mode, force_logging from v\$database;
       alter database force logging;
       -- NOARCHIVELOG only (short downtime): shutdown immediate / startup mount /
       -- alter database archivelog; / alter database open;
EXPECT ARCHIVELOG  YES
EOF
  ;;
  4.2) cat <<EOF
TITLE  Standby redo logs on primary
WHERE  PRIMARY ($P), $PSQL
RUN    select thread#, count(*), max(bytes)/1024/1024 mb, max(blocksize) from v\$log group by thread#;
       select thread#, count(*) from v\$standby_log group by thread#;
       -- per thread: (online groups + 1), size = largest online log (blocksize 4096 if the online logs have it)
       with OMF/ASM:  alter database add standby logfile thread 1 size <M>M;
       without OMF:   alter database add standby logfile thread 1 group <n> ('<redo folder>/srl_t1_g<n>.log') size <M>M;
EXPECT standby logs = online groups + 1 for every thread
EOF
  ;;
  4.3) cat <<EOF
TITLE  log_archive_config
WHERE  PRIMARY ($P), $PSQL
RUN    show parameter log_archive_config
       alter system set log_archive_config='dg_config=(<names already in the list>,$PU,$SU)' scope=both;
       -- keep every name that is already in the list (another standby would stop receiving redo)
EXPECT show parameter log_archive_config  -> both names
EOF
  ;;
  4.4) cat <<EOF
TITLE  log_archive_dest_N for the standby
WHERE  PRIMARY ($P), $PSQL
WHY    Usually N = 2. If dest_2 is already used for something else, the script uses the first free N.
RUN    alter system set log_archive_dest_state_N=defer scope=both;
       alter system set log_archive_dest_N='service=$ST async valid_for=(online_logfiles,primary_role) db_unique_name=$SU' scope=both;
IF     ORA-16018 (the old parameter log_archive_dest is used): first
       alter system set log_archive_dest='' scope=both; alter system set log_archive_dest_1='location=<same folder>' scope=both;
EXPECT show parameter log_archive_dest_N
EOF
  ;;
  4.5) cat <<EOF
TITLE  standby_file_management
WHERE  PRIMARY ($P), $PSQL
RUN    alter system set standby_file_management=auto scope=both;
EXPECT AUTO
EOF
  ;;
  4.6) cat <<EOF
TITLE  Archive destination / recovery area
WHERE  PRIMARY ($P), $PSQL
RUN    show parameter log_archive_dest_1
       show parameter db_recovery_file_dest
       -- if neither is set:
       alter system set db_recovery_file_dest_size=200G scope=both;
       alter system set db_recovery_file_dest='<+DG or folder>' scope=both;
EXPECT log_archive_dest_1 LOCATION=... or a recovery area
EOF
  ;;
  4.7) cat <<EOF
TITLE  Password file and SYS
WHERE  PRIMARY ($P), $PSQL
RUN    show parameter remote_login_passwordfile
       select username, sysdba from v\$pwfile_users;
       alter user sys identified by "<the same sys password>";     -- if SYS is missing and a password file exists
       -- no password file at all (in a SHELL as $OU; orapwd asks for the password):
       --   file system: orapwd file=\$ORACLE_HOME/dbs/orapw$PS format=12.2     (12.1: format=12)
       --   ASM:         orapwd file='+<DG>/$PU/orapw<db>' dbuniquename=$PU format=12.2
EXPECT EXCLUSIVE (or SHARED), and SYS TRUE
EOF
  ;;
  4.8) cat <<EOF
TITLE  fal_server on primary (optional)
WHERE  PRIMARY ($P), $PSQL
WHY    Used only after a switchover. Skip it if you want.
RUN    alter system set fal_server='$ST' scope=both;
EXPECT $ST
EOF
  ;;
  4.9) cat <<EOF
TITLE  Primary tnsnames.ora has the standby alias
WHERE  PRIMARY ($P), user $OU, file $PTA/tnsnames.ora
RUN    $ST =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $S)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $SSV)(UR = A))
         )
       $DBH/bin/tnsping $ST
EXPECT "Used TNSNAMES adapter" and OK
EOF
  ;;
  4.10) cat <<EOF
TITLE  Primary static listener entry (optional, for switchover)
WHERE  PRIMARY ($P), owner of $PLH, file $PLH/network/admin/listener.ora
WHY    Needed for switchover and the broker, not for building the standby. You may skip it.
RUN    SID_LIST_$LN =
         (SID_LIST =
           (SID_DESC =
             (GLOBAL_DBNAME = $PSV)
             (SID_NAME = $PS)
             (ORACLE_HOME = $DBH)
           )
         )
       $PLH/bin/lsnrctl reload $LN
EXPECT lsnrctl status $LN  -> Instance "$PS", status UNKNOWN
EOF
  ;;
  4.11) cat <<EOF
TITLE  Environment of $OU on primary (optional, information only)
WHERE  PRIMARY ($P), user $OU, file ~/.bash_profile
WHY    The script does not use it, but sqlplus / rman / dgmgrl by hand need the right values.
RUN    export ORACLE_BASE=$OB
       export ORACLE_HOME=$DBH
       export ORACLE_SID=$PS
       export PATH=\$ORACLE_HOME/bin:\$PATH
EXPECT after a new login:  echo \$ORACLE_SID  ->  $PS
EOF
  ;;
  5.1)
    printf 'TITLE  Static listener entry on standby\nWHERE  STANDBY (%s), user %s, file %s/network/admin/listener.ora\n' "$S" "$LU" "$LH"
    printf 'WHY    In NOMOUNT the instance cannot register itself. ORACLE_HOME must be the DATABASE home;\n       with the Grid home you get ORA-01017 through the listener.\n'
    [[ $G -eq 0 ]] && printf 'RUN    without Grid, define the listener too:\n       %s = (DESCRIPTION_LIST = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))))\n' "$SL" "$S" "$PO"
    [[ $G -eq 1 ]] && printf 'RUN    add:\n'
    printf '       SID_LIST_%s =\n         (SID_LIST =\n           (SID_DESC =\n             (GLOBAL_DBNAME = %s)\n             (SID_NAME = %s)\n             (ORACLE_HOME = %s)\n           )\n         )\n' "$SL" "$SSV" "$SID" "$DBH"
    printf 'EXPECT see step 5.2\n'
  ;;
  5.2) cat <<EOF
TITLE  Listener shows the static entry
WHERE  STANDBY ($S), user $LU
RUN    $LH/bin/lsnrctl start $SL      (only when it is not running and there is no Grid)
       $LH/bin/lsnrctl reload $SL
       $LH/bin/lsnrctl status $SL
EXPECT Instance "$SID", status UNKNOWN   and   (PORT=$PO)
EOF
  ;;
  5.3|5.4) cat <<EOF
TITLE  tnsnames.ora on standby
WHERE  STANDBY ($S), user $OU, file $DBH/network/admin/tnsnames.ora
RUN    $PT =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $P)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $PSV)(UR = A))
         )
       $ST =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $S)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $SSV)(UR = A))
         )
       tnsping $PT ; tnsping $ST
EXPECT OK for both, with the right HOST
EOF
  ;;
  6.1) cat <<EOF
TITLE  Password file = copy of the primary file
WHERE  PRIMARY then STANDBY
RUN    on primary:  $PSQL  ->  select file_name from v\$passwordfile_info (12.2+; 12.1: file_name only, or \$ORACLE_HOME/dbs/orapw<SID>);
       if it starts with +, on primary as $GU (export ORACLE_HOME=$GH ORACLE_SID=+ASM):
         rm -f /tmp/orapw_for_standby_$SID
         \$ORACLE_HOME/bin/asmcmd pwcopy '<file_name>' /tmp/orapw_for_standby_$SID
         chgrp $IG /tmp/orapw_for_standby_$SID ; chmod 640 /tmp/orapw_for_standby_$SID
       on standby as root:
         scp ${PRIMARY_SSH_USER:-oracle}@$P:<file or /tmp copy> $DBH/dbs/orapw$SID
         chown $OU:$IG $DBH/dbs/orapw$SID ; chmod 640 $DBH/dbs/orapw$SID
EXPECT md5sum equal on both servers; orapwd describe file=$DBH/dbs/orapw$SID shows a format (12.2+)
EOF
  ;;
  6.2) cat <<EOF
TITLE  Remove the temporary copy on primary
WHERE  PRIMARY ($P)
RUN    rm -f /tmp/orapw_for_standby_$SID
EXPECT ls /tmp/orapw_for_standby_$SID  -> No such file
EOF
  ;;
  6.3) cat <<EOF
TITLE  TDE wallet (only if the primary uses encryption)
WHERE  PRIMARY then STANDBY
RUN    on primary:  $PSQL  ->  select wrl_type, wrl_parameter, status, wallet_type from v\$encryption_wallet;
       copy ewallet.p12 (and cwallet.sso, unless wallet_type is LOCAL_AUTOLOGIN) to the SAME folder here:
       scp ${PRIMARY_SSH_USER:-oracle}@$P:<folder>/ewallet.p12 <folder>/
       scp ${PRIMARY_SSH_USER:-oracle}@$P:<folder>/cwallet.sso <folder>/
       chown $OU:$IG <folder>/* ; chmod 600 <folder>/*
       no cwallet.sso (or a LOCAL one on primary): make it here, as $OU (orapki asks the keystore password):
         $DBH/bin/orapki wallet create -wallet <folder> -auto_login      (LOCAL on primary: -auto_login_local)
       without WALLET_ROOT on primary (12c, or set up the old way): in $DBH/network/admin/sqlnet.ora
       ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = <folder>)))
EXPECT md5sum of the files equal on both servers
EOF
  ;;
  7.1) cat <<EOF
TITLE  Folders for the instance
WHERE  STANDBY ($S), user root
RUN    mkdir -p ${ORACLE_BASE:-<oracle base>}/admin/$SU/adump ${DIAG_DEST:-<diagnostic_dest of primary>}
       chown $OU:$IG <each new folder>
EXPECT the audit folder of the standby and the diagnostic_dest of primary exist, writable by $OU
EOF
  ;;
  7.2) cat <<EOF
TITLE  Instance in NOMOUNT
WHERE  STANDBY ($S), user $OU
RUN    file $DBH/dbs/init$SID.ora:
         *.db_name='${DB_NAME:-<db_name>}'
         *.db_unique_name='$SU'
         *.enable_pluggable_database=true        (only if primary is a CDB)
       $SSQL
       startup nomount pfile='$DBH/dbs/init$SID.ora'
EXPECT ORACLE instance started.
EOF
  ;;
  7.3|7.4|7.5|7.6) cat <<EOF
TITLE  Login tests (all four must work before the duplicate)
WHERE  STANDBY ($S) as $OU, and PRIMARY ($P) as $OU for the last one
RUN    sqlplus / as sysdba
       sqlplus sys@$ST as sysdba
       sqlplus sys@$PT as sysdba
       on primary:  sqlplus sys@$ST as sysdba
EXPECT Connected, four times
IF     ORA-01017 only through @  -> static entry ORACLE_HOME (5.1) or password file (6.1)
       ORA-01017 with / as sysdba -> $OU is not in the OSDBA group of the home
       ORA-12528                 -> (UR = A) or static entry missing
       ORA-12514                 -> SERVICE_NAME differs from GLOBAL_DBNAME
       ORA-12154                 -> alias missing (5.3, 5.4 or 4.9 on primary)
EOF
  ;;
  7.7) cat <<EOF
TITLE  /etc/oratab entry
WHERE  STANDBY ($S), user root
RUN    echo '$SID:$DBH:N' >> /etc/oratab
EXPECT . oraenv  (as $OU, answer $SID) sets ORACLE_HOME=$DBH
EOF
  ;;
  8.1)
    printf 'TITLE  Pre-checks for the duplicate\nWHERE  STANDBY (%s)\n' "$S"
    printf 'RUN    %s  ->  select status from v$instance;     (STARTED)\n' "$SSQL"
    [[ $G -eq 1 ]] && printf '       as %s:  asmcmd lsdg                                       (Free_MB of %s)\n' "$GU" "$DGS"
    [[ -n "${LOCS:-}" ]] && fs_dirs >/dev/null 2>&1 && [[ -n "$(fs_dirs)" ]] && printf '       df -m %s\n' "$(fs_dirs | paste -sd' ' -)"
    printf '       sqlplus sys@%s as sysdba  ->  select round(sum(bytes)/1024/1024) from v$datafile;\n' "$PT"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '       ls -l %s/bin/oracle   -> group %s (else as root: %s/bin/setasmgidwrap o=%s/bin/oracle)\n' "$DBH" "$AG" "$GH" "$DBH"
    printf 'EXPECT free space bigger than the primary size + 10%%, the folders are not the primary storage (2.15)\n'
  ;;
  8.2) cat <<EOF
TITLE  RMAN active duplicate
WHERE  STANDBY ($S), user $OU
WHY    Primary only READS its datafiles and sends them. It is not changed.
RUN    rman target sys@$PT auxiliary sys@$ST
       then the run { ... } block from ${LOG_DIR:-/var/log/dg_standby_setup}/duplicate_<date>.rman
EXPECT Finished Duplicate Db. Lines such as RMAN-05535 or ORA-19527 / ORA-00312 about redo
       log files during the copy are expected and harmless.
IF     it failed, clean THIS server before trying again (check names twice; the script
       prints the exact commands: run it with --from 7.2):
         on THIS server only ($S), $SSQL  ->  shutdown abort
         ASM:     as $GU:  [ "\$(hostname -s)" = "$(hostname -s)" ] && ORACLE_HOME=$GH ORACLE_SID=+ASM $GH/bin/asmcmd rm -rf +<DG>/${SU^^}
                  (never +<DG>/${PU^^}: those are the primary's files)
         folders: rm -f the files the copy left (step 7.2 lists them: run the script with --from 7.2)
         as $OU:  [ "\$(hostname -s)" = "$(hostname -s)" ] && rm -f $DBH/dbs/spfile$SID.ora $DBH/dbs/.dg_duplicate_done_$SID
       then run the script with:  --from 7.2
EOF
  ;;
  9.1) cat <<EOF
TITLE  Registration in Oracle Restart (only with Grid)
WHERE  STANDBY ($S), user $OU
RUN    srvctl config database -db $SU
       srvctl add database -db $SU -oraclehome $DBH -spfile $DBH/dbs/spfile$SID.ora \\
         -pwfile $DBH/dbs/orapw$SID -role PHYSICAL_STANDBY -startoption MOUNT \\
         -dbname ${DB_NAME:-<db_name>} -instance $SID -diskgroup $(tr ' ' ',' <<< "$DGS")${PRIMARY_DOMAIN:+ -domain $PRIMARY_DOMAIN}
EXPECT -instance exactly $SID (otherwise "Connected to an idle instance")
EOF
  ;;
  9.2) cat <<EOF
TITLE  Standby instance running (MOUNT)
WHERE  STANDBY ($S), user $OU
RUN    with Grid:    sqlplus / as sysdba -> shutdown immediate ; srvctl start database -db $SU
       without Grid: sqlplus / as sysdba -> startup mount
       sqlplus / as sysdba  ->  select instance_name, status from v\$instance;
EXPECT $SID  MOUNTED   (never OPEN read only without an Active Data Guard license)
EOF
  ;;
  9.3) cat <<EOF
TITLE  Standby redo logs on standby
WHERE  STANDBY ($S), $SSQL
RUN    alter database recover managed standby database cancel;
       alter system set standby_file_management=manual scope=memory;
       alter database add standby logfile thread 1 size <same as primary>M;    (with OMF/ASM; else give a file name)
       alter system set standby_file_management=auto scope=memory;
EXPECT per thread: online groups + 1
EOF
  ;;
  9.4) cat <<EOF
TITLE  Apply (MRP)
WHERE  STANDBY ($S), $SSQL
RUN    alter database recover managed standby database disconnect from session;
       select $DGN, $DGR, $DGS2 from $DGP where $DGN like 'MRP%';
EXPECT MRP0  APPLYING_LOG or WAIT_FOR_LOG
EOF
  ;;
  9.5) cat <<EOF
TITLE  Redo shipping from primary
WHERE  PRIMARY ($P), $PSQL
RUN    alter system set log_archive_dest_state_N=enable scope=both;      (N from step 4.4, usually 2)
       alter system switch logfile;
       select status, error from v\$archive_dest where dest_id=N;
EXPECT VALID, error empty
IF     ORA-16191 / ORA-01017 -> password file (6.1);  ORA-12154 -> 4.9;  ORA-12514/12541 -> phase 5
EOF
  ;;
  9.6) cat <<EOF
TITLE  Redo arrives (RFS)
WHERE  STANDBY ($S), $SSQL
RUN    select $DGN, $DGR, $DGS2 from $DGP where $DGR like 'RFS%';
EXPECT at least one RFS row
EOF
  ;;
  9.7)
    printf 'TITLE  Start at boot (mount and apply)\nWHERE  STANDBY (%s), user root\n' "$S"
    if [[ $G -eq 1 ]]; then
      printf 'WHY    Oracle Restart mounts the standby after a reboot, but does not start apply (MRP).\n'
      printf 'RUN    a script (root-owned, run as %s): wait until v$instance says MOUNTED, then\n' "$OU"
      printf '         alter database recover managed standby database disconnect from session;\n'
      printf '       a systemd unit (User=%s, Type=simple, After=oracle-ohasd.service) that runs it ; systemctl enable <unit>\n' "$OU"
    else
      printf 'RUN    a script (root-owned, run as %s):  lsnrctl start %s ; startup mount ;\n' "$OU" "$SL"
      printf '                         alter database recover managed standby database disconnect from session;\n'
      printf '       and at shutdown: shutdown immediate ; lsnrctl stop %s\n' "$SL"
      printf '       a systemd unit (User=%s, Type=oneshot + RemainAfterExit, LimitNOFILE/NPROC/STACK/MEMLOCK as for %s) ; systemctl enable <unit>\n' "$OU" "$OU"
    fi
    printf 'EXPECT after a reboot: the standby is MOUNTED and MRP runs\n'
  ;;
  9.8) cat <<EOF
TITLE  Archived logs on the standby (deletion)
WHERE  STANDBY ($S), user $OU (the timer: root)
WHY    Without a deletion policy the archived logs fill the recovery area (or the archive
       destination) and redo transport stops (ORA-19809 / ORA-00257). A policy copied from the
       primary with "BACKED UP n TIMES" never deletes anything here.
RUN    rman target /
       CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;
       With a recovery area Oracle then deletes applied logs by itself when space is needed.
       Another archive destination (a folder or a disk group): a daily job as $OU, for example a
       systemd timer that runs:  rman target /  ->  delete noprompt archivelog all completed before 'sysdate-1';
       On the PRIMARY nothing is changed here. Its own policy belongs to its backups (check it there:
       show archivelog deletion policy;). Never set "BACKED UP n TIMES" on a primary that RMAN does not back up.
EXPECT select value from v\$rman_configuration where name='ARCHIVELOG DELETION POLICY';  ->  TO APPLIED ON STANDBY
EOF
  ;;
  10.1) cat <<EOF
TITLE  Transport and apply lag
WHERE  STANDBY ($S), $SSQL
RUN    select name, value from v\$dataguard_stats where name in ('transport lag','apply lag');
EXPECT +00 00:00:00 or a few seconds (empty for some minutes right after setup)
EOF
  ;;
  10.2) cat <<EOF
TITLE  Archive gap
WHERE  STANDBY ($S), $SSQL
RUN    select * from v\$archive_gap;
EXPECT no rows selected
EOF
  ;;
  10.3) cat <<EOF
TITLE  Last sequence on both sides
WHERE  BOTH, user $OU, sqlplus / as sysdba
RUN    primary:  select max(sequence#) from v\$archived_log where standby_dest='NO' and thread#=1
                   and resetlogs_change#=(select resetlogs_change# from v\$database);
       standby:  select max(sequence#) from v\$archived_log where applied in ('YES','IN-MEMORY') and thread#=1
                   and resetlogs_change#=(select resetlogs_change# from v\$database);
EXPECT equal, or standby 1 lower
EOF
  ;;
  10.4) cat <<EOF
TITLE  Apply process
WHERE  STANDBY ($S), $SSQL
RUN    select $DGN, $DGR, $DGS2 from $DGP where $DGN like 'MRP%';
       select count(*) from v\$standby_log where status='ACTIVE';      -- 1 or more: real-time apply gets redo
       select timestamp, message from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp;
EXPECT MRP0; at least one ACTIVE standby log; no new errors
EOF
  ;;
  *) return 1 ;;
  esac
}

show_help() {
  local id=${1:-} txt line key rest title
  if ! txt=$(help_text "$id"); then
    printf '      No help for step "%s". Use: %s --help-step all\n' "$id" "$SELF"; return 1
  fi
  title=$(grep -m1 '^TITLE ' <<< "$txt"); title=${title:7}
  printf '\n      %s+-- HELP  [%s]  %s%s%s\n' "$C_C" "$id" "$C_B" "$title" "$C_N"
  while IFS= read -r line || [[ -n "$line" ]]; do
    key=${line:0:6}; rest=${line:7}
    case "$key" in
      "TITLE ") ;;
      "WHERE "|"WHY   "|"RUN   "|"EXPECT"|"IF    ")
        printf '      %s|%s\n      %s|%s   %s%-7s%s %s\n' "$C_C" "$C_N" "$C_C" "$C_N" "$C_Y" "${key%% *}" "$C_N" "$rest" ;;
      *) printf '      %s|%s           %s\n' "$C_C" "$C_N" "${line:7}" ;;
    esac
  done <<< "$txt"
  printf '      %s+--------------------------------------------------------------%s\n\n' "$C_C" "$C_N"
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
dg_standby_setup.sh $SCRIPT_VERSION - build an Oracle Data Guard physical standby (12.1 to 23ai)
Run it ON THE STANDBY SERVER (Oracle Linux 7, 8 or 9) as root.
The primary server is never changed by this script.
Primary storage in ASM or in folders, Grid with its own user or owned by oracle: all supported.

  dg_standby_setup.sh                      start (asks the primary IP if it is not saved yet)
  dg_standby_setup.sh --primary 10.0.0.5   primary IP (or host name)
  dg_standby_setup.sh --user oracle        OS user for ssh on primary (default: oracle; never root)
  dg_standby_setup.sh --check              only check and report; changes nothing. It still connects to
                                           the primary: it asks the primary IP (if not saved), the ssh
                                           password and the sys password
  dg_standby_setup.sh --from 5.1           continue from a step (phase 1 always runs)
  dg_standby_setup.sh --only 10            run only one phase (10 = daily sync check)
  dg_standby_setup.sh --settings           review or edit the settings (standby values), then stop
  dg_standby_setup.sh --status             where you are: the result of every phase and step so far,
                                           without connecting to anything
  dg_standby_setup.sh --show-changes       every change this script made on THIS server, with its undo
  dg_standby_setup.sh --show-changes 5.1   ... of one step
  dg_standby_setup.sh --undo 5.1           undo the changes of one step (asks before each change)
  dg_standby_setup.sh --help-step 5.1      manual commands of a step ("all" for every step)

Before every step the script shows what it found, what it will do and with which values,
and asks:  [y] do it   [s] skip (I do it myself)   [h] help   [q] quit
Work on the PRIMARY is only printed; after you run it, answer r and the script checks it.
Long jobs (installers, root scripts, the RMAN copy) run in their own session: a closed terminal
does not stop them; run the script again and it waits for them.

Phases:  1 connect + read primary   2 OS   3 Oracle software   4 primary readiness
         5 network files   6 password file   7 NOMOUNT + login tests   8 duplicate
         9 register, apply, shipping, start at boot   10 verify
         Every run starts with "Where you are": the result of every phase so far.
         Phases 4, 6 and 9 need commands on the primary (printed, then checked). Phase 4 can be
         done first (the first run offers it) or any time:  dg_standby_setup.sh --only 4
Files:   settings  $STATE_DIR/settings.conf  (accepted values: settings.accepted)
         progress  $STATE_DIR/progress (per step), changes.log (every change made here, for --undo)
         logs      $LOG_DIR/run_<date>.log, actions_<date>.txt (commands shown for you),
                   duplicate_<date>.rman/.log, installer and root script outputs
Editor:  the settings open in \$EDITOR (default vi)
Exit code: 0 = every step is OK
           1 = stopped, or some steps are not OK or skipped (normal in --check on a new server)
           2 = wrong option or unknown step
EOF
}

valid_step() { local i; for i in "${HELP_IDS[@]}"; do [[ "$i" == "$1" ]] && return 0; done; return 1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --primary) [[ $# -ge 2 ]] && valid_value ip "$2" || { printf 'Bad or missing value for --primary\n'; exit 2; }; CLI_IP=$2; shift ;;
      --user) [[ $# -ge 2 ]] && valid_value name "$2" && [[ "$2" != "root" ]] || { printf 'Bad or missing value for --user (the Oracle software owner, not root)\n'; exit 2; }; CLI_USER=$2; shift ;;
      --check) MODE="check" ;;
      --settings) REVIEW_SETTINGS=1 ;;
      --status) STATUS_ONLY=1 ;;
      --show-changes) SHOW_CHANGES=all; [[ $# -ge 2 && "$2" =~ ^[0-9]+\.[0-9]+$ ]] && { SHOW_CHANGES=$2; shift; } ;;
      --undo) [[ $# -ge 2 ]] && valid_step "$2" || { printf 'Use --undo N.M (a step id, see --help-step all)\n'; exit 2; }; UNDO_STEP=$2; shift ;;
      --from)
        [[ $# -ge 2 && "$2" =~ ^([1-9]|10)(\.[0-9]{1,2})?$ ]] || { printf 'Use --from N or --from N.M (for example 5.1)\n'; exit 2; }
        FROM_STEP=$2
        if [[ "$FROM_STEP" == *.* ]]; then valid_step "$FROM_STEP" || { printf 'There is no step %s (see --help-step all)\n' "$FROM_STEP"; exit 2; }
        else FROM_STEP="$FROM_STEP.0"; fi
        shift ;;
      --only) [[ $# -ge 2 && "$2" =~ ^([1-9]|10)$ ]] || { printf 'Use --only N (1-10)\n'; exit 2; }; ONLY_PHASE=$2; shift ;;
      --help-step) [[ $# -ge 2 ]] || { usage; exit 2; }; HELP_STEP=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'Unknown option: %s\n\n' "$1"; usage; exit 2 ;;
    esac
    shift
  done
  [[ -n "$FROM_STEP" && -n "$ONLY_PHASE" ]] && { printf 'Use either --from or --only, not both.\n'; exit 2; }
  if [[ -n "$UNDO_STEP" && ( "$MODE" == "check" || $STATUS_ONLY -eq 1 || -n "$SHOW_CHANGES" || -n "$FROM_STEP" || -n "$ONLY_PHASE" || $REVIEW_SETTINGS -eq 1 ) ]]; then
    printf '%s\n' '--undo goes alone (to see first what it would do:  --show-changes STEP).'; exit 2
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
  printf 'The saved settings were for another primary; they are not used%s.\n' "$([[ "$MODE" == "run" ]] && printf ' (kept with the ending .%s)' "$tag")"
  _log WARN "saved settings for another primary set aside ($tag)"
}
reenter_primary() {
  # the IP or the ssh user was wrong: ask again (the saved settings of another primary are not used)
  local ip u
  while true; do
    ask "IP address (or host name) of the PRIMARY server [$PRIMARY_IP]:"
    ip=${ANSWER:-$PRIMARY_IP}
    valid_value ip "$ip" && [[ "$ip" != "h" ]] && break
    say "Not a valid IP or host name."
  done
  while true; do
    ask "OS user on primary that owns the database (for ssh) [$PRIMARY_SSH_USER]:"
    u=${ANSWER:-$PRIMARY_SSH_USER}
    valid_value name "$u" && [[ "$u" != "root" ]] && break
    say "Not a valid user name (and never root)."
  done
  if [[ -n "$PRIMARY_HOST" ]] && ! same_primary "$ip"; then
    # maybe only another address of the same server: the records are set aside after step 1.3 only when the
    # database found there is another one
    OLD_PRIMARY_UNIQUE=$PRIMARY_UNIQUE
    [[ "$MODE" == "run" && -f "$SETTINGS_FILE" ]] && cp -p "$SETTINGS_FILE" "$SETTINGS_FILE.${PRIMARY_IP:-old}_$RUN_ID"
    init_settings; rm -f -- "$ACCEPTED_FILE" 2>/dev/null
    say "The saved settings were for another primary address; they are read again from the new one."
  fi
  PRIMARY_IP=$ip; PRIMARY_SSH_USER=$u
  _log INFO "primary=$PRIMARY_IP ssh_user=$PRIMARY_SSH_USER (entered again)"
  return 0
}

main() {
  parse_args "$@"
  if [[ -n "$HELP_STEP" ]]; then help_cli "$HELP_STEP"; exit 0; fi
  [[ $EUID -eq 0 ]] || { printf 'Run as root (on the STANDBY server).\n'; exit 1; }
  cd / || exit 1
  os_info
  LOG_DIR=$(readlink -m -- "$LOG_DIR"); STATE_DIR=$(readlink -m -- "$STATE_DIR")
  { [[ -d "$LOG_DIR" ]] || install -d -m 750 "$LOG_DIR"; } && { [[ -d "$STATE_DIR" ]] || install -d -m 700 "$STATE_DIR"; } || { printf 'Cannot create %s or %s (read-only or full file system?)\n' "$LOG_DIR" "$STATE_DIR"; exit 1; }
  dir_safe "$STATE_DIR" || { printf '%s must belong to root and must not be writable by others (it holds the settings and copies of the password file).\n' "$STATE_DIR"; exit 1; }
  dir_safe "$LOG_DIR" || { printf '%s must belong to root and must not be writable by others (root writes the logs there).\n' "$LOG_DIR"; exit 1; }
  SETTINGS_FILE="$STATE_DIR/settings.conf"; ACCEPTED_FILE="$STATE_DIR/settings.accepted"; JOB_FILE="$STATE_DIR/job"
  PROGRESS_FILE="$STATE_DIR/progress"; LASTRUN_FILE="$STATE_DIR/last_run"; JOURNAL_FILE="$STATE_DIR/changes.log"
  if [[ $STATUS_ONLY -eq 1 || -n "$SHOW_CHANGES" ]]; then
    # read-only views: no lock, no log, no connection
    init_settings; [[ -f "$SETTINGS_FILE" ]] && load_settings soft >/dev/null 2>&1
    printf '%sOracle Data Guard standby setup %s%s   this server: %s\n' "$C_B" "$SCRIPT_VERSION" "$C_N" "$(hostname -s 2>/dev/null)"
    [[ -n "$PRIMARY_UNIQUE" ]] && printf 'Primary: %s on %s   standby: %s\n' "$PRIMARY_UNIQUE" "${PRIMARY_HOST:-$PRIMARY_IP}" "${STANDBY_UNIQUE:-?}"
    if [[ $STATUS_ONLY -eq 1 ]]; then print_progress_board; [[ -s "$JOURNAL_FILE" ]] && printf '  Changes made on this server: %s --show-changes\n' "$SELF"; fi
    [[ -n "$SHOW_CHANGES" ]] && show_changes_cli "$([[ "$SHOW_CHANGES" == all ]] || printf '%s' "$SHOW_CHANGES")"
    exit 0
  fi
  # every run asks questions: without a terminal (nohup, cron, ssh without -t) it would fail later at a confusing point
  if ! { : < /dev/tty; } 2>/dev/null; then
    printf 'This script asks questions: run it in an interactive terminal (for example:  ssh -t root@%s).\n' "$(hostname -s 2>/dev/null)"
    exit 1
  fi
  # one run at a time (a second run would take over the ssh connection and the settings)
  exec 9> "$STATE_DIR/lock" || { printf 'Cannot open %s/lock\n' "$STATE_DIR"; exit 1; }
  if ! flock -n 9; then printf 'Another run of this script is active on this server. Wait for it to end (or stop it), then try again.\n'; exit 1; fi
  LOG_FILE="$LOG_DIR/run_$RUN_ID.log"; : > "$LOG_FILE" && chmod 640 "$LOG_FILE" || { LOG_FILE=""; printf 'Cannot write the log in %s (read-only or full?)\n' "$LOG_DIR"; exit 1; }
  ACTIONS_FILE="$LOG_DIR/actions_$RUN_ID.txt"; : > "$ACTIONS_FILE" && chmod 640 "$ACTIONS_FILE" || { printf 'Cannot write in %s\n' "$LOG_DIR"; exit 1; }
  if [[ -n "$UNDO_STEP" ]]; then
    init_settings
    [[ -f "$SETTINGS_FILE" ]] || { printf 'No settings file (%s): nothing was set up by this script here.\n' "$SETTINGS_FILE"; exit 1; }
    local lerr=""; load_settings soft >/dev/null 2>&1 || lerr=${LOAD_ERR:-cannot be read}
    if [[ -n "$lerr" || -z "$ORACLE_USER" || -z "$DB_HOME" || -z "$STANDBY_SID" ]]; then
      printf 'The settings in %s cannot be used (%s).\nFix them first (%s --settings); the undo needs them to find the standby.\n' "$SETTINGS_FILE" "${lerr:-a value is missing or invalid}" "$SELF"
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

  printf '%sOracle Data Guard standby setup %s%s   mode: %s   this server: %s\n' "$C_B" "$SCRIPT_VERSION" "$C_N" "$MODE" "$(hostname -s 2>/dev/null)"
  printf 'Log: %s\n' "$LOG_FILE"
  printf 'This script changes only THIS server. For the primary it prints the commands and checks them.\n'
  print_progress_board
  # a long job of an earlier run (installer, root script, RMAN) is waited for before anything else;
  # phase 4 alone works only with the primary and does not need to wait
  if [[ "$ONLY_PHASE" == "4" ]] && job_alive; then
    say "A long job is running ($JOB_TITLE, session $JOB_PID). Phase 4 works only with the primary: it does not wait for it."
  else
    job_wait_step
  fi

  while [[ -z "$PRIMARY_IP" ]]; do
    ask "IP address (or host name) of the PRIMARY server:"
    valid_value ip "$ANSWER" && [[ "${ANSWER,,}" != "h" ]] && PRIMARY_IP=$ANSWER || say "Not a valid IP or host name."
  done
  if [[ $first_run -eq 1 && -z "$CLI_USER" ]]; then
    while true; do
      ask "OS user on primary that owns the database (for ssh; it must be able to run sqlplus / as sysdba) [oracle]:"
      ANSWER=${ANSWER:-oracle}
      valid_value name "$ANSWER" && [[ "$ANSWER" != "root" ]] && { PRIMARY_SSH_USER=$ANSWER; break; }
      say "Not a valid user name (and never root)."
    done
  else
    say "ssh user on primary: $PRIMARY_SSH_USER (another one: --user <name>)"
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
      printf '\n  %sStandby setup is complete.%s Daily check:  %s --only 10\n' "$C_G" "$C_N" "$SELF"
      printf '  Keep in mind:\n'
      printf '   - when the sys password changes on the primary: copy the password file again (%s --from 6.1)\n' "$SELF"
      [[ -n "$TDE_INFO" ]] && printf '   - after a new TDE master key on the primary (administer key management set key): copy the wallet again (%s --from 6.3)\n' "$SELF"
      if [[ -s "$JOURNAL_FILE" ]] && journal_entries "" "" | awk -F'|' '$5 == "PKG" && $6 ~ /preinstall/' | grep -q .; then
        printf '   - the preinstall package changed kernel settings (transparent huge pages): plan one reboot of this server\n'
      fi
    elif [[ "$ONLY_PHASE" == "1" && $REVIEW_SETTINGS -eq 1 ]]; then
      printf '\n  %sSettings reviewed.%s To continue the setup:  %s\n' "$C_G" "$C_N" "$SELF"
    elif [[ -n "$FROM_STEP" ]]; then
      printf '\n  %sAll steps from %s are OK.%s To check every step once more:  %s --check\n' "$C_G" "${FROM_STEP%.0}" "$C_N" "$SELF"
    else
      printf '\n  %sPhase %s is OK.%s\n' "$C_G" "$ONLY_PHASE" "$C_N"
    fi
  fi
  [[ $bad_n -eq 0 ]]
}

main "$@"
