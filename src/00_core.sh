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
#      checks them again with SELECT. Only with PRIMARY_RUN=yes in the settings
#      may a primary step run its statements over ssh, from a fixed list
#      (Data Guard parameters, force logging, standby logs), after you answer y.
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

readonly SCRIPT_VERSION="5.29"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
MODE="run"                     # run | check
FROM_STEP=""
ONLY_PHASE=""
TO_STEP=""                     # last step of a range (--only 2.1-2.4, grid, db, or the menu)
TO_TEXT=""                     # the same as typed: 3 for the end of phase 3
ONLY_TEXT=""                   # the --only value as given (for the "Next" line)
MENU_OK=0                      # no options given: the start menu is shown
REVIEW_SETTINGS=0
PROMPT_IN="${DG_PROMPT_IN:-/dev/tty}"
LOG_DIR="${DG_LOG_DIR:-/var/log/dg_standby_setup}"
STATE_DIR="${DG_STATE_DIR:-/var/lib/dg_standby_setup}"
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"      # the pid too: two runs in the same second never share files
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
# process (runuser, root.sh, installers, ssh) can see them. The environment the script
# was started with still holds them (readable by root in /proc/<pid>/environ): for tests only.
ENV_SYS_PW=${DG_SYS_PASSWORD:-}; ENV_ASM_PW=${DG_ASM_PASSWORD:-}
unset DG_SYS_PASSWORD DG_ASM_PASSWORD
# seconds; a hung sqlplus never blocks the script forever (also sent to the primary, so it must be a number)
SQL_TIMEOUT=${DG_SQL_TIMEOUT:-600}
num "$SQL_TIMEOUT" && (( 10#$SQL_TIMEOUT >= 10 && 10#$SQL_TIMEOUT <= 86400 )) || SQL_TIMEOUT=600
SQL_TIMEOUT=$((10#$SQL_TIMEOUT))
# seconds between the re-checks of steps 10.2 and 10.3 (6 checks)
POLL_WAIT=${DG_POLL_WAIT:-20}
num "$POLL_WAIT" && (( 10#$POLL_WAIT >= 1 && 10#$POLL_WAIT <= 300 )) || POLL_WAIT=20
POLL_WAIT=$((10#$POLL_WAIT))
OS_RELEASE_FILE=${DG_OS_RELEASE_FILE:-/etc/os-release}
FSTAB_FILE=${DG_FSTAB_FILE:-/etc/fstab}
MEMINFO_FILE=${DG_MEMINFO_FILE:-/proc/meminfo}
# waits between looks at something that is still starting (apply, a job, RFS): nap N sleeps N seconds. The test
# harness sets DG_TEST_FAST_WAITS=1 (mocks answer at once): then every such wait is 0.2 seconds. Nothing else changes.
FAST_WAITS=0; [[ "${DG_TEST_FAST_WAITS:-}" == 1 ]] && FAST_WAITS=1
# (said on screen when it is on: in a real run every wait for something that starts would be too short)
[[ $FAST_WAITS -eq 1 ]] && printf 'Note: DG_TEST_FAST_WAITS=1 is set (a setting for the test suite): waits are shortened to 0.2 seconds.\n' >&2
nap() { if [[ $FAST_WAITS -eq 1 ]]; then sleep 0.2; else sleep "$1"; fi; }
SYSTEMD_RUN_DIR=${DG_SYSTEMD_RUN_DIR:-/run/systemd/system}   # exists when systemd is running
SHM_UNIT_FILE=${DG_SHM_UNIT_FILE:-/etc/systemd/system/dev-shm.mount}   # when it exists, it sets /dev/shm at boot (not fstab)
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
    # the passwords reach awk through a pipe (printf is a builtin): never in its arguments or environment
    awk '
      function mask(s, p,   out, i) {
        if (p == "") return s
        out = ""
        while ((i = index(s, p)) > 0) { out = out substr(s, 1, i - 1) "*****"; s = substr(s, i + length(p)) }
        return out s
      }
      BEGIN { if ((getline p1 < "/dev/fd/3") <= 0) p1 = ""; if ((getline p2 < "/dev/fd/3") <= 0) p2 = "" }
      { print mask(mask($0, p1), p2); fflush() }' 3< <(printf '%s\n%s\n' "$SYS_PW" "$ASM_PW")
  else
    cat
  fi
}

_log() {
  # every line of a message gets the time and the tag (grep and less show each line with its context)
  [[ -n "$LOG_FILE" ]] || return 0
  local p; p=$(printf '%s | %-6s | ' "$(ts)" "$1"); p=${p//\\/\\\\}; p=${p//\//\\/}; p=${p//&/\\&}
  printf '%s\n' "$2" | sed -e 's/\x1b\[[0-9;]*m//g' -e "s/^/$p/" | mask_pw >> "$LOG_FILE"
}

log_block() {
  # $1 title, stdin = the output (its last line is often "(exit code N)"). An output with ORA- / SP2- error lines
  # and exit code 0 (sqlplus without WHENEVER SQLERROR) is marked: "(exit code 0, ORA- in output)"
  [[ -n "$LOG_FILE" ]] || { cat > /dev/null; return 0; }
  local body t=$1 e=""
  body=$(cat)
  if grep -qx '(exit code 0)' <<< "$body"; then
    grep -vE '^SQL> ' <<< "$body" | grep -qE '(^|[[:space:]])ORA-[0-9]{4,5}' && e="ORA-"
    grep -vE '^SQL> ' <<< "$body" | grep -qE '(^|[[:space:]])SP2-[0-9]{4}' && e+="${e:+/}SP2-"
    if [[ -n "$e" ]]; then body=$(sed "s#^(exit code 0)\$#(exit code 0, $e in output)#" <<< "$body"); t+=" (exit code 0, $e in output)"; fi
  fi
  # SQL: the query is in the title once (not again as "SQL> ..."), the output marker of the probes is left out
  local nq; nq=$(grep -c '^SQL> ' <<< "$body")
  # (a statement of several lines keeps its block: its other lines follow "SQL> " indented)
  [[ $nq -eq 1 ]] && awk 'p ~ /^SQL> / && /^     / {f = 1} {p = $0} END {exit !f}' <<< "$body" && nq=2
  if [[ $nq -eq 1 && "$t" == *": "* ]]; then
    local q; q=$(sed -n 's/^SQL> //p' <<< "$body")
    [[ "${t#*: }" == "${q:0:20}"* ]] && { t="${t%%: *}: $q${e:+ (exit code 0, $e in output)}"; body=$(grep -v '^SQL> ' <<< "$body"); }
  fi
  body=$(grep -vx '__DG_SQL_OUTPUT__' <<< "$body")
  # --verbose: a read-only query or command also goes to the list shown under the step
  if [[ -n "$VQ_FILE" ]]; then
    local vrc vres; vrc=$(sed -n 's/^(exit code \([0-9]*\).*/\1/p' <<< "$body" | tail -n 1); vres=$(grep -vE '^\(exit code [0-9]+' <<< "$body")
    if [[ "$t" =~ ^(STANDBY|ASM|PRIMARY)[^:]*:\ +[Ss][Ee][Ll][Ee][Cc][Tt]\  ]]; then vq_line "$t" "$vres" "${vrc:-0}" "$e"
    elif [[ "$body" == "command (as "* ]]; then
      local c1; c1=$(head -n 1 <<< "$body"); c1=${c1#*: }
      cmd_reads_only "$c1" && vq_line "${c1}" "$(sed 1d <<< "$vres")" "${vrc:-0}" ""
    fi
  fi
  # a short answer without an error: one line, "title  ->  answer"
  if [[ -z "$e" && $nq -le 1 ]] && grep -qx '(exit code 0)' <<< "$body"; then
    local res; res=$(grep -vx '(exit code 0)' <<< "$body" | sed '/^[[:space:]]*$/d')
    if [[ $(grep -c '' <<< "$res") -le 1 && ${#res} -le 200 ]]; then
      printf '%s | OUT    | %s  ->  %s\n' "$(ts)" "$t" "${res:-(no rows)}" | mask_pw >> "$LOG_FILE"
      return 0
    fi
  fi
  {
    printf '%s | OUT    | --- %s ---\n' "$(ts)" "$t"
    [[ -n "$body" ]] && printf '%s\n' "$body" | sed 's/^/          /'
    printf '%s | OUT    | --- end ---\n' "$(ts)"
  } | mask_pw >> "$LOG_FILE"
}

# Screen layout of a step:   "  Step 1.5  Title"  then 4 spaces + symbol + text; more lines of a message at 6 spaces
# Plain output, not --verbose: the title of a step waits (PT_PENDING) until the step prints something. A step that
# is already correct prints one line instead (run_step: pt_ok_line); anything else prints the title first (pt_flush).
PT_PENDING=""
# --verbose: every read-only query and command (SQL select, a probe on the primary, a local read like crsctl stat) is
# also shown, one line each ("query  ->  answer"), under the step that ran it (in --health: under its check). They
# are collected in VQ_FILE (a file: many of them run in a subshell) and shown by vq_dump / health_report.
VQ_FILE=""
# (DG_TEST_NO_QUERIES=1: the test suite, which runs with DG_VERBOSE=1, keeps its outputs without these lines)
vq_init() { [[ ${VERBOSE:-0} -eq 1 && -z "$VQ_FILE" && "${DG_TEST_NO_QUERIES:-0}" != 1 ]] || return 0; VQ_FILE=$(mktemp /tmp/dg_vq.XXXXXXXX 2>/dev/null) || VQ_FILE=""; [[ -z "$VQ_FILE" ]] || CLEANUP_FILES+=("$VQ_FILE"); }
vq_add() { [[ -n "$VQ_FILE" ]] || return 0; printf '%s\n' "$1" | sed -e 's/\x1b\[[0-9;]*m//g' | mask_pw >> "$VQ_FILE"; }
vq_take() { [[ -n "$VQ_FILE" && -s "$VQ_FILE" ]] || return 0; cat -- "$VQ_FILE"; : > "$VQ_FILE"; }
vq_dump() {
  # the queries collected so far, on the screen under the current step (dimmed, "· query  ->  answer")
  [[ -n "$VQ_FILE" && -s "$VQ_FILE" && ${HEALTH:-0} -ne 1 ]] || return 0
  local l
  while IFS= read -r l; do
    if [[ $UI -eq 1 ]]; then ui_out 8 "      ${C_D}· $l${C_N}"; else pt_flush; printf '      %s· %s%s\n' "$C_D" "$l" "$C_N"; fi
  done < <(vq_take)
}
vq_line() {
  # $1 title ("STANDBY sqlplus: select ..."), $2 answer lines, $3 rc, $4 error flag -> one line for VQ_FILE
  local a n; n=$(grep -c . <<< "$2")
  if [[ -n "$4" || "$3" != 0 ]]; then a=$(grep -m1 -oE '(ORA|SP2|TNS|RMAN|PRCD|PRCR|CRS)-[0-9]+[^|]{0,80}' <<< "$2"); a="error: ${a:-exit code $3}"
  elif [[ $n -eq 0 ]]; then a="(no rows)"
  elif [[ $n -eq 1 ]]; then a=$(grep . <<< "$2"); [[ ${#a} -gt 100 ]] && a="${a:0:99}…"
  else a="$(grep -m1 . <<< "$2" | cut -c1-60)  (and $((n - 1)) more lines)"; fi
  local t=$1; [[ ${#t} -gt 120 ]] && t="${t:0:119}…"
  vq_add "$t  ->  $a"
}
pt_flush() { [[ -n "$PT_PENDING" ]] || return 0; printf '\n  %sStep %s%s  %s%s%s\n' "$C_B" "${PT_PENDING%%$'\t'*}" "$C_N" "$C_W" "${PT_PENDING#*$'\t'}" "$C_N"; PT_PENDING=""; }
say()  { if [[ $UI -eq 1 ]]; then ui_out 6 "      $*"; else pt_flush; printf '      %s\n' "$*"; fi; _log INFO "$*"; }
_mark() { # $1 color $2 symbol $3 log tag, rest = text (first line after the symbol, other lines under it)
  local col=$1 sym=$2 tag=$3 l first=1 o=""; shift 3
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ $first -eq 1 ]]; then o+=$(printf '    %s%s%s %s' "$col" "$sym" "$C_N" "$l")$'\n'; first=0
    else [[ -n "$l" ]] && o+="      $l"$'\n'; fi
  done <<< "$*"
  if [[ $UI -eq 1 ]]; then ui_out 6 "${o%$'\n'}"; else pt_flush; printf '%s' "$o"; fi
  _log "$tag" "$*"
}
ok()   { _mark "$C_G" "$S_OK" OK "$*"; }
WARN_LIST=()
warn() {
  _log WARN "$*"
  local w="[${CUR_STEP:-start}] $*" x
  [[ "${WARN_DEDUP:-1}" == 0 ]] || for x in "${WARN_LIST[@]+"${WARN_LIST[@]}"}"; do [[ "$x" == "$w" ]] && return 0; done   # same warning again (a re-check): shown and listed once
  local l first=1 o=""
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ $first -eq 1 ]]; then o+=$(printf '    %s%s %s%s' "$C_Y" "$S_WARN" "$l" "$C_N")$'\n'; first=0
    else [[ -n "$l" ]] && o+=$(printf '      %s%s%s' "$C_Y" "$l" "$C_N")$'\n'; fi
  done <<< "$*"
  if [[ $UI -eq 1 ]]; then ui_out 6 "${o%$'\n'}"; else pt_flush; printf '%s' "$o"; fi
  WARN_COUNT=$((WARN_COUNT + 1)); WARN_LIST+=("$w")
}
warn_drop() {
  # $1 step, $2 pattern (glob) of the warning text, $3 why: warnings a later check has made void leave the list
  # (and the end summary); the log keeps them, with the reason
  local -a keep=(); local x n=0
  for x in "${WARN_LIST[@]+"${WARN_LIST[@]}"}"; do
    # shellcheck disable=SC2053
    if [[ "$x" == "[$1] "$2 ]]; then n=$((n + 1)); else keep+=("$x"); fi
  done
  [[ $n -gt 0 ]] || return 0
  WARN_LIST=("${keep[@]+"${keep[@]}"}"); WARN_COUNT=$((WARN_COUNT - n)); [[ $WARN_COUNT -ge 0 ]] || WARN_COUNT=0
  _log INFO "$n warning(s) of step $1 no longer apply: $3"
}
bad()  { _mark "$C_R" "$S_BAD" FAIL "$*"; }
todo() { _mark "$C_M" "$S_TODO" TODO "$*"; }
wait_msg() { _mark "$C_D" "$S_WAIT" WAIT "$*"; }

hint() {
  # explanations and advice: plain text under the message they belong to (often tool output: masked on screen too)
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $UI -eq 1 ]]; then ui_out 6 "      $line"; else pt_flush; printf '      %s\n' "$line"; fi
    _log HINT "$line"
  done < <(mask_pw)
}

block() {
  # $1 = label (Status / Plan / Details / Fix; old names Now: Plan: Using: are mapped), stdin = lines
  local label=$1 line first=1
  [[ $UI -eq 1 ]] || pt_flush
  case "$label" in "Now:") label="Status" ;; "Plan:") label="Plan" ;; "Using:") label="Details" ;; "Fix:") label="Fix" ;; esac
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ $first -eq 1 ]]; then
      if [[ $UI -eq 1 ]]; then ui_out 13 "$(printf '    %s%-8s%s %s' "$C_D" "$label" "$C_N" "$line")"; else printf '    %s%-8s%s %s\n' "$C_D" "$label" "$C_N" "$line"; fi
      first=0
    elif [[ $UI -eq 1 ]]; then ui_out 13 "             $line"
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

go_on_cmd() {
  # the command that goes on at step (or phase) $1 and stays inside the part of this run (--only, a range, the menu)
  local s=$1 lo
  [[ "$s" == 10.7 ]] && { printf '%s --roll-forward' "$SELF"; return 0; }
  if [[ -n "$TO_STEP" ]]; then
    # a bare phase N starts at N.0. Inside the range, or before it: from there up to the end of the range (the
    # same range when it starts there), so the waited-for step and the rest of the range run in one go (on
    # purpose: the steps between them are checked, which is quick when they are done). After the range: --from
    if [[ "$s" == *.* ]]; then lo=$(step_num "$s"); else lo=$(step_num "$s.0"); fi
    if [[ $lo -le $(step_num "$TO_STEP") ]]; then
      if [[ $lo -eq $(step_num "$FROM_STEP") ]]; then printf '%s --only %s' "$SELF" "$ONLY_TEXT"
      else printf '%s --only %s-%s' "$SELF" "$s" "$TO_TEXT"; fi
      return 0
    fi
  fi
  if [[ -n "$ONLY_PHASE" && "$ONLY_PHASE" != 1 && "${s%%.*}" == "$ONLY_PHASE" ]]; then printf '%s --only %s' "$SELF" "${ONLY_TEXT:-$ONLY_PHASE}"; return 0; fi
  printf '%s --from %s' "$SELF" "$s"
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
  # --health: no summary, no "to continue" hints, and the exit code of "unknown" for the monitoring system
  if [[ ${HEALTH:-0} -eq 1 ]] && declare -F health_exit >/dev/null; then _log FATAL "$*"; health_exit UNKNOWN "$*"; fi
  tty_restore
  [[ -n "${BATCH_TTY:-}" ]] && { exec 1>&"$BATCH_TTY" 2>&1; BATCH_TTY=""; }
  ui_end
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
    printf '  To continue later:   %s\n' "$(go_on_cmd "$rs")"
  elif [[ -n "$rs" && "$rs" != 1.* ]]; then
    printf '  To continue later:   %s\n  To do it by hand:    %s --help-step %s\n' "$(go_on_cmd "$rs")" "$SELF" "$rs"
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
  trap '' HUP TERM INT QUIT PIPE
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

TTY_RESTORE=""     # the terminal settings before a hidden question (put back on any exit: Ctrl+C, signal, error)
tty_restore() { [[ -n "$TTY_RESTORE" ]] && { stty "$TTY_RESTORE" < "${PROMPT_IN:-/dev/tty}" 2>/dev/null; TTY_RESTORE=""; }; return 0; }
cleanup() {
  tty_restore
  # the screen layout leaves the terminal as it was (whole screen scrolls, cursor shown)
  [[ $UI -eq 1 || $UI_ALT -eq 1 ]] && { [[ $UI_ALT -eq 1 ]] && printf '\e[?1049l'; printf '\e[r\e[?25h\e[%d;1H\n' "${UI_ROWS:-24}"; UI=0; UI_ALT=0; }
  local f
  for f in "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}"; do
    [[ -n "$f" ]] || continue
    # a response file of a job that still runs is removed by the job itself when it ends
    # (once the job's command has ended, its .rc file exists: the response file is no longer needed and goes now)
    [[ -n "$JOB_KEEP" && ",$JOB_KEEP," == *",$f,"* ]] && job_running "$JOB_PID" && [[ ! -f "${JOB_OUT:-/nonexistent}.rc" ]] && continue
    rm -f -- "$f"
    [[ "$(dirname "$f")" == /tmp/dg_rsp.* ]] && rmdir -- "$(dirname "$f")" 2>/dev/null
  done
  if [[ ( $SSH_OPEN -eq 1 || ${HEALTH_SSH_OPEN:-0} -eq 1 ) && -n "$SSH_CTL" ]]; then
    ssh -o ControlPath="$SSH_CTL" -O exit "${PRIMARY_SSH_USER:-x}@${PRIMARY_IP:-x}" >/dev/null 2>&1 || true
    rm -f -- "$SSH_CTL"
  fi
}
trap cleanup EXIT
trap 'on_signal HUP' HUP
trap 'on_signal TERM' TERM
trap 'on_signal QUIT' QUIT
# a closed pipe (script | tee, and the ssh session drops) must not kill the script before its clean-up: handled
# like a dropped terminal (a handler, not "ignore": programs started later keep the normal SIGPIPE)
trap 'on_signal PIPE' PIPE
trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT

#------------------------------------------------------------------------------
# Prompts  (typing h at any question shows the manual commands of the step)
#------------------------------------------------------------------------------
ask() {
  # $1 = question. Result in ANSWER.  Typing h shows the help of the current step.
  [[ ${HEALTH:-0} -eq 1 ]] && health_no_question "$1"
  while true; do
    vq_dump
    if [[ $UI -eq 1 ]]; then ui_live_clear; ui_flush; ui_header; printf '\n'; else pt_flush; fi
    printf '    %s%s %s%s %s ' "$C_C" "$S_ASK" "$1" "$C_N" "$S_END"
    if ! IFS= read -r ANSWER < "$PROMPT_IN"; then
      printf '\n'
      # Ctrl+D in a terminal is a stop; no terminal at all is a wrong way to run it
      # (the answers come from PROMPT_IN: that is the input to judge, not stdin)
      if [[ "$PROMPT_IN" == /dev/tty ]]; then { : < /dev/tty; } 2>/dev/null && fatal "Stopped: no answer (Ctrl+D) for: $1"
      elif [[ -t 0 && ( "$PROMPT_IN" == /dev/stdin || "$PROMPT_IN" == /dev/fd/0 ) ]]; then fatal "Stopped: no answer (Ctrl+D) for: $1"; fi
      fatal "No answer could be read for: $1
This script asks questions. Run it in an interactive terminal, for example:  ssh -t root@$(hostname -s 2>/dev/null)"
    fi
    _log ASK "$1  -> $ANSWER"
    case "${ANSWER,,}" in
      h|"?"|help) if [[ -n "$CUR_STEP" && $UI -eq 1 ]]; then ui_show "Help  $S_DOT  step $CUR_STEP" show_help "$CUR_STEP"
                  elif [[ -n "$CUR_STEP" ]]; then show_help "$CUR_STEP" || true
                  else say "No help for this question. All options:  $SELF --help"; fi ;;
      # the step text was cut to fit the screen ("N more lines: d shows all"): d shows it here too
      # (not cut: d is the details of the step from the log, as the caller handles it)
      d) if [[ $UI -eq 1 && -n "$CUR_STEP" && ${UI_CUT:-0} -eq 1 && -s "$UI_BUF_FILE.cut" ]]; then
           # the whole text of the step, uncut; command lines (15 columns or more) are not split
           ui_page "$UI_BUF_FILE.cut" "Step $CUR_STEP  (the whole text)" "" 0 15
         else return 0; fi ;;
      *) return 0 ;;
    esac
  done
}

ask_value() {
  # $1 question: a free-text value (a host or a user name). A lone l or d is a screen key at every question,
  # never the value: on the screen layout it opens the list or the details, else it asks again with a hint
  while true; do
    ask "$1"
    case "${ANSWER,,}" in
      l) if [[ $UI -eq 1 ]]; then ui_list; else say "l and d are screen keys, not values. Type the whole name."; fi ;;
      d) if [[ $UI -eq 1 ]]; then ui_details "${CUR_STEP:-}"; else say "l and d are screen keys, not values. Type the whole name."; fi ;;
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
  [[ ${HEALTH:-0} -eq 1 ]] && health_no_question "$1"
  # echo is off BEFORE the question is shown: a password typed (or pasted) at once is never shown on the screen
  TTY_RESTORE=$(stty -g < "$PROMPT_IN" 2>/dev/null) && stty -echo < "$PROMPT_IN" 2>/dev/null
  [[ $UI -eq 1 ]] && { ui_live_clear; ui_flush; printf '\n'; }
  printf '    %s%s %s%s %s ' "$C_C" "$S_ASK" "$1" "$C_N" "$S_END"
  local rc=0; IFS= read -rs SECRET < "$PROMPT_IN" || rc=$?
  tty_restore
  [[ $rc -eq 0 ]] || fatal "No answer could be read for: $1  (run the script in an interactive terminal, for example ssh -t)"
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
ORATMP_WARNED=""      # the causes already said (nodir, bad): each one once, a second cause is still said
oracle_tmp() {
  # The Oracle installers run programs from their temporary folder. When /tmp is mounted noexec (hardened
  # servers) they fail, so a folder next to the inventory is used instead (root-owned, sticky, like /tmp).
  [[ "$MODE" == "run" ]] || return 0
  findmnt -n -o OPTIONS --target /tmp 2>/dev/null | tr ',' '\n' | grep -qx noexec || return 0
  local t; t="$(dirname "${INVENTORY_DIR:-/u01/app/oraInventory}")/dg_tmp"
  [[ "$t" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 0
  # plain mkdir (never through a link someone else put there), then mode and owner checked before use
  # made with its final mode in one call: root never runs chmod on a path others could swap
  if [[ ! -e "$t" && ! -L "$t" ]]; then ( umask 0; mkdir -m 1777 -- "$t" ) 2>/dev/null || return 0; fi
  [[ ! -L "$t" && -d "$t" && "$(stat -c '%U %a' -- "$t" 2>/dev/null)" == "root 1777" ]] || return 0
  printf '%s' "$t"
}
build_envs() {
  local oh gh dx=() gx=() v t
  t=$(oracle_tmp); [[ -n "$t" ]] && { dx+=("TMP=$t" "TMPDIR=$t"); gx+=("TMP=$t" "TMPDIR=$t"); }
  # /tmp is noexec and no folder for the installers could be used (its parent is made by step 2.5): said once per cause
  local tp tcause=bad; tp="$(dirname "${INVENTORY_DIR:-/u01/app/oraInventory}")"; [[ -d "$tp" ]] || tcause=nodir
  if [[ -z "$t" && "$MODE" == "run" && " $ORATMP_WARNED " != *" $tcause "* && ${HEALTH:-0} -eq 0 ]] \
     && findmnt -n -o OPTIONS --target /tmp 2>/dev/null | tr ',' '\n' | grep -qx noexec; then
    ORATMP_WARNED+=" $tcause"
    if [[ $tcause == nodir ]]; then
      warn "/tmp does not allow programs to run (noexec), and $tp does not exist yet (step 2.5 makes it)."$'\n'"Until then the Oracle installers would fail. Run phase 2 first."
    else
      warn "/tmp does not allow programs to run (noexec), and no folder for the installers could be made or used in $tp"$'\n'"($tp/dg_tmp must be a folder of root, mode 1777; the inventory path must be a plain path). The Oracle installers"$'\n'"may fail. Check:  ls -ld $tp $tp/dg_tmp"
    fi
  fi
  oh=$(home_of "$ORACLE_USER"); gh=$(home_of "$GRID_USER")
  v=$(distid_for "${DB_MAJOR:-0}"); [[ -n "$v" ]] && dx+=("$v")
  v=$(distid_for "$(rel_major "${GRID_REL:-${DB_MAJOR:-0}}")"); [[ -n "$v" ]] && gx+=("$v")
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

ipv4_of() {
  # $1 host name or IPv4 address -> IPv4 address (empty when the name does not resolve)
  if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf '%s' "$1"; return 0; fi
  [[ -n "$1" ]] || return 0
  getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 {print $1}'
}
is_local_ip() {
  # 0 = $1 (IPv4) is an address of this server
  [[ -n "$1" ]] && command -v ip >/dev/null 2>&1 \
    && ip -o addr show 2>/dev/null | awk -v a="$1" '{split($4, x, "/"); if (x[1] == a) f = 1} END {exit !f}'
}
os_field() {
  # $1 key -> its value in the os-release file. The file is read, never run (sourced) as root.
  local v; v=$(sed -n "s/^$1=//p" -- "$OS_RELEASE_FILE" 2>/dev/null | head -n 1)
  v=${v#[\"\']}; v=${v%[\"\']}
  printf '%s' "${v//[^A-Za-z0-9 ._()\/-]/}"
}
os_info() {
  # OS_ID (ol, rhel, ...), OS_MAJOR (7, 8, 9), PKG (yum or dnf)
  OS_ID=$(os_field ID); OS_ID=${OS_ID:-unknown}
  OS_MAJOR=$(os_field VERSION_ID); OS_MAJOR=${OS_MAJOR%%.*}; num "$OS_MAJOR" || OS_MAJOR=0
  if command -v dnf >/dev/null 2>&1 && [[ "$OS_MAJOR" != "7" ]]; then PKG=dnf; else PKG=yum; fi
}

dup_log_ok() {
  # $1 RMAN output, $2 its exit code. The copy counts only with exit code 0, "Finished Duplicate Db", and no error
  # stack (RMAN prints "ERROR MESSAGE STACK FOLLOWS" / RMAN-00569 before any error that stops a command)
  [[ "${2:-}" == "0" ]] && grep -q 'Finished Duplicate Db' "$1" \
    && ! grep -qE '^RMAN-0(0569|3002|3009|3015)|ERROR MESSAGE STACK FOLLOWS' "$1"
}
IN_DO=0          # 1 while a step's action runs: every command that changes something is shown before it runs
cmd_display() {
  # the user and the command line of a run_logged call, as a person would type it: "grid|srvctl start asm"
  local u=root w out="" q="'"
  local -a a=("$@")
  case "${a[0]:-}" in
    as_oracle) u=$ORACLE_USER; a=("${a[@]:1}") ;;
    as_grid)   u=$GRID_USER; a=("${a[@]:1}") ;;
    runuser)   [[ "${a[1]:-}" == -u ]] && { u=${a[2]}; a=("${a[@]:3}"); [[ "${a[0]:-}" == -- ]] && a=("${a[@]:1}"); } ;;
  esac
  [[ "${a[0]:-}" == timeout && "${a[1]:-}" =~ ^[0-9]+$ ]] && a=("${a[@]:2}")
  [[ "${a[0]:-}" == bash && "${a[1]:-}" == -c ]] && a=("${a[2]}")
  for w in "${a[@]}"; do
    if [[ ${#a[@]} -eq 1 || "$w" =~ ^[A-Za-z0-9_./,:+=@%-]+$ ]]; then out+="$w "; else out+="$q${w//$q/$q\\$q$q}$q "; fi
  done
  printf '%s|%s' "$u" "${out% }"
}
cmd_reads_only() {
  # commands that only read (not worth a line on the screen while an action runs; they are in the log)
  [[ "$1" =~ (^|/)(srvctl[[:space:]]+(status|config)|crsctl[[:space:]]+(stat|check|query)|lsnrctl[[:space:]]+(status|services)|asmcmd[[:space:]]+(ls|lsdg|find|lsdsk)|systemctl[[:space:]]+(is-[a-z]+|status|cat|show)|rpm[[:space:]]+-q|getent|id|stat|df|cat|ls|test|grep|findmnt|blkid|lsblk)([[:space:]]|$) ]]
}
run_logged() {
  # $1 = title; rest = command. Output -> RUN_OUT and log. Returns command rc. stdin is not passed on.
  # The output goes through a file: a daemon the command starts (lsnrctl start -> tnslsnr) may keep
  # its stdout open, and reading a pipe would then wait for ever.
  # The exact command line goes to the log; during an action it is also shown ("Running as grid: ...").
  local title=$1; shift
  local rc=0 tmp disp du dc
  disp=$(cmd_display "$@"); du=${disp%%|*}; dc=${disp#*|}
  [[ $IN_DO -eq 1 ]] && ! cmd_reads_only "$dc" && say "${C_D}Running as $du:${C_N} $(mask_pw <<< "$dc")"
  tmp=$(mktemp /tmp/dg_out.XXXXXXXX) || { RUN_OUT="cannot create a temporary file"; return 1; }
  CLEANUP_FILES+=("$tmp")
  "$@" > "$tmp" 2>&1 < /dev/null 9>&- || rc=$?
  RUN_OUT=$(cat "$tmp"); rm -f -- "$tmp"
  { printf 'command (as %s): %s\n' "$du" "$dc"; printf '%s\n(exit code %s)\n' "$RUN_OUT" "$rc"; } | mask_pw | log_block "$title"
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
      if dup_log_ok "$JOB_OUT" "$rc" && declare -F dup_success_record >/dev/null; then
        # nobody watched the end of the copy: recorded as finished but not checked ("copied"); the next look at
        # the mounted standby compares it with the primary
        dup_success_record copied; say "The RMAN copy had finished. Its result is recorded; the standby is compared with the primary next."; jok=1
      else
        jok=0; install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/dup_attempt"
        # the same reading as a watched copy: the first real error, and a cause step 7.2 can fix (ORA-19809)
        local fe=""; declare -F rman_first_error >/dev/null && fe=$(rman_first_error "$JOB_OUT")
        declare -F dup_cause_record >/dev/null && dup_cause_record "$JOB_OUT"
        say "The RMAN copy did NOT finish: ${fe:-see its output $JOB_OUT}"
        [[ "$(dup_cause 2>/dev/null)" == FRA_FULL ]] && say "The recovery area on this server was full. Step 7.2 offers to clean up and copy again with a bigger one."
        say "Step 7.2 of a normal run offers to clean up this server."
      fi ;;
    "RMAN roll forward")
      # not judged here: the next run with --roll-forward checks the standby, finishes the clean-up and starts
      # redo apply (stopped for the roll forward). Its exit code is kept for that run
      jok=0
      [[ -f "$STATE_DIR/rollforward_pending" ]] && printf '%s|%s\n' "$JOB_OUT" "${rc:-}" > "$STATE_DIR/rollforward_pending"
      say "Redo apply is stopped since the roll forward. To check the result and start redo apply again:  $SELF --roll-forward" ;;
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
    if [[ "$JOB_TITLE" == "RMAN roll forward" ]]; then NOW="$JOB_TITLE ended (exit code ${rc:-unknown}); not checked yet: run with --roll-forward"; record "$JOB_STEP" WAITS
    elif [[ $jok -eq 1 ]]; then NOW="$JOB_TITLE ended without error (recorded later)"; record "$JOB_STEP" DONE
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
  if [[ $UI -eq 1 ]]; then
    say "To stop the job itself:  pkill -s $2"
    [[ "$1" == RMAN* ]] || say "A stopped installer or root script leaves a half-configured home."
  fi
  if [[ $UI -eq 1 ]]; then
    # (d is "details" at every other question of the screen layout)
    ask_choice "[w] Keep watching   [x] Leave it running and stop the script" "wx"; [[ "$ANSWER" == "x" ]] && ANSWER=d
  else ask_choice "[w] Keep watching   [d] Leave it running and stop the script" "wd"; fi
  [[ "$ANSWER" == "d" ]] || return 0
  [[ -n "$TAIL_PID" ]] && { pkill -P "$TAIL_PID" 2>/dev/null; kill "$TAIL_PID" 2>/dev/null; wait "$TAIL_PID" 2>/dev/null; TAIL_PID=""; }
  trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT
  # JOB_KEEP stays: the response files are removed by the job itself when it ends (cleanup keeps them while it runs)
  DETACHED_JOB="'$1' keeps running (session $2, output $3)"
  [[ -n "$CUR_STEP" ]] && declare -F record >/dev/null && { NOW="$1 still running (session $2)"; record "$CUR_STEP" RUNNING; }
  RESUME_STEP=""
  user_stop "Left running: $1"
}

dur_text() {
  # $1 seconds -> "45 s", "6 min 12 s", "2 h 05 min"
  local s=${1:-0}
  if [[ $s -lt 60 ]]; then printf '%d s' "$s"
  elif [[ $s -lt 3600 ]]; then printf '%d min %d s' $((s / 60)) $((s % 60))
  else printf '%d h %02d min' $((s / 3600)) $((s % 3600 / 60)); fi
}
JOB_PROGRESS_FN=""   # set by the caller of run_long: a function "$fn OUTPUT_FILE START_SECONDS" that prints one short
                     # progress text of the job ("" = nothing known yet); run_long clears it when the job has ended
JOB_PROGRESS=""      # its last text (the screen layout shows it on the live line)
RUN_LONG_OUT=""      # the output file run_long really used (a retry in the same run gets <name>_2.log, _3.log ...)
JOB_TAIL_LOG=30      # lines of a job's output copied into the run log (all of it stays in its own file)
job_progress_poll() {
  # $1 output file, $2 start (SECONDS): JOB_PROGRESS from the caller's function (read-only, never fatal)
  [[ -n "$JOB_PROGRESS_FN" ]] && declare -F "$JOB_PROGRESS_FN" >/dev/null || return 0
  JOB_PROGRESS=$("$JOB_PROGRESS_FN" "$1" "$2" 2>/dev/null | head -n 1) || JOB_PROGRESS=""
  return 0
}
job_live_title() {
  # $1 title: the title and the progress for the one live line of the screen layout, cut to the terminal width
  # (the live line itself adds about 56 columns: the time and the keys l and d)
  local t=$1 room=$(( ${UI_COLS:-80} - 58 ))
  [[ -n "$JOB_PROGRESS" ]] || { printf '%s' "$t"; return 0; }
  t="$1  $JOB_PROGRESS"
  [[ ${#t} -le $room ]] || t="${1%% *}  $JOB_PROGRESS"
  if [[ ${#t} -gt $room && $room -gt 10 ]]; then t=${t:0:$room}; t="${t% *}"; fi
  [[ ${#t} -le $room ]] || t=$1
  printf '%s' "$t"
}
job_log_tail() {
  # the end of a job's output for the run log: the last JOB_TAIL_LOG lines, error lines from before them, the file
  # $1 output file, $2 exit code (the header and footer lines "#| " of the file are left out)
  local f=$1 n k=$JOB_TAIL_LOG
  n=$(grep -vc '^#| ' "$f" 2>/dev/null); num "$n" || n=0
  if [[ $n -gt $k ]]; then
    printf '(%s lines of output; the last %s are below. All of them: %s)\n' "$n" "$k" "$f"
    local el
    el=$(grep -v '^#| ' "$f" 2>/dev/null | head -n $((n - k)) | grep -nE '^(ORA|RMAN|INS|PRV[FG]|CLSRSC|PRCZ)-[0-9]+|\[FATAL\]|SEVERE|ERROR' | head -n 20)
    [[ -n "$el" ]] && printf 'Error lines before them (line: text):\n%s\n--- the last %s lines ---\n' "$el" "$k"
  fi
  grep -v '^#| ' "$f" 2>/dev/null | tail -n "$k"
  printf '(exit code %s)\n' "$2"
}
run_long() {
  # $1 title, $2 output file, $3 filter regex for the screen ("" = every line),
  # $4 who (root | oracle | grid), rest = command. The command reads the stdin of run_long.
  # JOB_KEEP (comma list): files the job needs (response files); the job removes them when it ends.
  # JOB_PROGRESS_FN (optional): see above; the progress is shown every minute (plain) or on the live line.
  # Returns the exit code of the command. The full output is in $2 (RUN_LONG_OUT: the file really used), with a
  # header (command, user, start) and a footer (end, exit code, duration); the run log gets its last lines.
  local title=$1 out=$2 filt=$3 who=$4; shift 4
  local -a pre=()
  ui_flush
  # a retry in the same run keeps the output of the earlier try: the new one is <name>_2.log (_3, ...)
  if [[ -e "$out" ]]; then
    local ob=$out ox="" k=2; [[ "$out" == *.log ]] && { ob=${out%.log}; ox=.log; }
    while [[ -e "${ob}_$k$ox" ]]; do k=$((k + 1)); done
    _log JOB "$out exists (an earlier try): this one writes to ${ob}_$k$ox"
    out="${ob}_$k$ox"
  fi
  RUN_LONG_OUT=$out; JOB_PROGRESS=""
  case "$who" in
    oracle) pre=(runuser -u "$ORACLE_USER" -- env -i "${ORA_ENV[@]}") ;;
    grid)   pre=(runuser -u "$GRID_USER" -- env -i "${GRID_ENV[@]}") ;;
    *)      pre=(env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME=/root LANG=C LC_ALL=C) ;;
  esac
  rm -f -- "$out.rc" "$out.pid" "$out.rc.t" "$out.pid.t"
  # the header of the output file: what runs, as whom, since when (no error codes in it: the file is searched for them)
  local hcmd; hcmd=$(cmd_display "$@"); hcmd=${hcmd#*|}
  { ( umask 077; { printf '#| %s %s, run %s, step %s: %s\n' "${SELF##*/}" "$SCRIPT_VERSION" "$RUN_ID" "${CUR_STEP:--}" "$title"
                   printf '#| as %s, started %s: %s\n' "$(cp_user "$who" 2>/dev/null || printf '%s' "$who")" "$(ts)" "$hcmd"
                   printf '#| ---- output ----\n'; } | mask_pw > "$out" ); } 2>/dev/null || { bad "Cannot write $out."; JOB_PROGRESS_FN=""; return 1; }
  # fd 9 (the lock of this script) is closed for the job: a job that outlives the script must not block the next run
  # the job removes its JOB_KEEP files only when the script is gone (else the script still needs them, e.g. for a retry)
  # .pid and .rc are written to a temp name and moved: a reader never sees a half-written file
  setsid bash -c 'cd / || exit 1; echo $$ > "$1.pid.t" && mv -f -- "$1.pid.t" "$1.pid"; f=$1; k=$2; sp=$3; shift 3
    "$@" >> "$f" 2>&1; r=$?; d=$SECONDS
    printf "#| ---- end %s, exit code %s, after %s min %s s ----\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$r" $((d / 60)) $((d % 60)) >> "$f"
    echo $r > "$f.rc.t" && mv -f -- "$f.rc.t" "$f.rc"
    kill -0 "$sp" 2>/dev/null || { IFS=,; for x in $k; do [ -n "$x" ] && { rm -f -- "$x"; rmdir -- "${x%/*}" 2>/dev/null; }; done; }' dg_long_job "$out" "$JOB_KEEP" "$$" "${pre[@]}" "$@" <&0 9>&- &
  local bg=$! n=0 jpid=""
  while [[ ! -s "$out.pid" && $n -lt 300 ]]; do sleep 0.1; n=$((n + 1)); done
  jpid=$(cat "$out.pid" 2>/dev/null); rm -f -- "$out.pid"
  # Fallback only: a background job of a script is not a process group leader, so setsid does not fork
  # and $! is already the session id that pgrep -s watches.
  num "$jpid" || { jpid=$bg; _log JOB "no pid file after 30 s, using $bg"; }
  { printf '%s|%s|%s|%s|%s|%s\n' "$jpid" "$title" "$out" "$JOB_KEEP" "$(boot_id)" "${CUR_STEP:-}" > "$JOB_FILE.n" \
      && mv -f -- "$JOB_FILE.n" "$JOB_FILE"; } 2>/dev/null \
    || warn "Cannot write $JOB_FILE.
If this run stops, the next run will not know that $title is still running."
  JOB_PID=$jpid; JOB_TITLE=$title; JOB_OUT=$out; JOB_STEP=${CUR_STEP:-}
  _log JOB "start pid=$jpid $title -> $out"
  say "$title is running (process $jpid). Output: $out"
  if [[ $LONG_ADVICE_SHOWN -eq 0 && $UI -eq 1 ]]; then
    # the screen layout: one line (how to stop the job itself is shown after Ctrl+C)
    LONG_ADVICE_SHOWN=1
    say "${C_D}It runs in its own session: closing the terminal does not stop it. Ctrl+C shows the options.${C_N}"
  elif [[ $LONG_ADVICE_SHOWN -eq 0 ]]; then
    LONG_ADVICE_SHOWN=1
    say "It runs in its own session. A closed terminal does not stop it, and the next run waits for it."
    say "Ctrl+C asks if you want to keep watching. The job itself goes on in any case."
    say "To stop the job itself:  pkill -s $jpid"
    [[ "${title:-}" == RMAN* ]] || say "A stopped installer or root script leaves a half-configured home."
  fi
  RL_INT=0; trap 'RL_INT=1' INT
  local t0=$SECONDS hb=0 ui_on=$UI pg_t=$SECONDS pg_said="" pg_said_t=$SECONDS
  # how often the progress is read: every 15 s for the live line, every 60 s in plain mode (shown when it changed,
  # at least every 5 minutes); with the test timing every 2 s
  local pg_live=15 pg_plain=60; [[ $FAST_WAITS -eq 1 ]] && { pg_live=2; pg_plain=2; }
  TAIL_PID=""
  if [[ $ui_on -eq 1 ]]; then
    # the screen layout: one live line (time, progress, keys l and d) instead of the output; the output stays in its file
    while [[ $UI -eq 1 ]] && kill -0 "$jpid" 2>/dev/null; do
      if (( SECONDS - pg_t >= pg_live )) || [[ $pg_t -eq $t0 ]]; then
        pg_t=$SECONDS; job_progress_poll "$out" "$t0"
        [[ -n "$JOB_PROGRESS" && "$JOB_PROGRESS" != "$pg_said" && $(( SECONDS - pg_said_t )) -ge 300 ]] && { pg_said=$JOB_PROGRESS; pg_said_t=$SECONDS; _log JOB "$title: $JOB_PROGRESS"; }
      fi
      ui_job_tick "$(job_live_title "$title")" "$out" "$t0"
      if [[ $RL_INT -eq 1 ]]; then
        RL_INT=0; ui_live_clear
        job_detach_question "$title" "$jpid" "$out"
      fi
      (( SECONDS - t0 >= 600 * (hb + 1) )) && { hb=$((hb + 1)); _log JOB "$title still running after $(( (SECONDS - t0) / 60 )) minutes"; }
    done
    ui_live_clear
    # the terminal became too small: the plain output takes over for the rest of the job
    [[ $UI -eq 1 ]] || ui_on=0
  fi
  # the output is shown by a background pipeline; waiting for it can be interrupted by HUP/TERM at once
  if [[ $ui_on -eq 1 ]]; then :
  elif [[ -n "$filt" ]]; then
    { tail -n +1 -f --pid="$jpid" -- "$out" 2>/dev/null | grep --line-buffered -E -- "$filt" | grep --line-buffered -v '^#| ' | mask_pw | sed -u 's/^/        /'; } 9>&- &
  else
    { tail -n +1 -f --pid="$jpid" -- "$out" 2>/dev/null | grep --line-buffered -v '^#| ' | mask_pw | sed -u 's/^/        /'; } 9>&- &
  fi
  [[ $ui_on -eq 1 ]] || TAIL_PID=$!
  while [[ -n "$TAIL_PID" ]] && kill -0 "$TAIL_PID" 2>/dev/null; do
    nap 5
    if [[ $RL_INT -eq 1 ]]; then
      RL_INT=0; printf '\n'
      job_detach_question "$title" "$jpid" "$out"
    fi
    if [[ -n "$JOB_PROGRESS_FN" ]] && (( SECONDS - pg_t >= pg_plain )); then
      # the progress the caller can read (an RMAN copy: datafiles and GB done, time left): when it changed, and
      # at least every 5 minutes
      pg_t=$SECONDS; job_progress_poll "$out" "$t0"
      if [[ -n "$JOB_PROGRESS" ]] && [[ "$JOB_PROGRESS" != "$pg_said" || $(( SECONDS - pg_said_t )) -ge 300 ]]; then
        pg_said=$JOB_PROGRESS; pg_said_t=$SECONDS; hb=$(( (SECONDS - t0) / 600 ))
        say "${C_D}$title, $(dur_text $((SECONDS - t0))):${C_N} $JOB_PROGRESS"
      fi
    fi
    if (( SECONDS - t0 >= 600 * (hb + 1) )); then
      hb=$((hb + 1))
      say "$title still running after $(( (SECONDS - t0) / 60 )) minutes. Output so far: $(du -h -- "$out" 2>/dev/null | cut -f1)"
    fi
  done
  TAIL_PID=""
  wait "$bg" 2>/dev/null
  # the wrapper may have been killed while its command goes on: wait for the whole job
  n=0
  while job_running "$jpid"; do
    [[ $n -eq 0 ]] && say "Waiting for the rest of the job (session $jpid) to end."
    n=$((n + 1)); nap 2
    if [[ $RL_INT -eq 1 ]]; then RL_INT=0; printf '\n'; job_detach_question "$title" "$jpid" "$out"; fi
    # the command has ended and only programs it started still run: do not wait for them
    if [[ -f "$out.rc" && $n -ge 30 ]]; then
      warn "$title has ended, but programs it started still run: $(pgrep -s "$jpid" -l 2>/dev/null | head -n 5 | tr '\n' ' ')"
      break
    fi
    if (( n % 300 == 0 )); then
      say "Programs of the job still run after $((n * 2 / 60)) minutes: $(pgrep -s "$jpid" -l 2>/dev/null | head -n 5 | tr '\n' ' ')"
      # the command itself has not ended (no exit code yet; once it is there the loop ends above): going on would
      # let a later step take the files of a running copy for leftovers, so there is no "continue" here
      say "The command itself has not ended. Ctrl+C offers to leave it running and stop this script."
    fi
  done
  n=0; while [[ ! -f "$out.rc" && $n -lt 50 ]]; do sleep 0.1; n=$((n + 1)); done
  local rc; rc=$(cat "$out.rc" 2>/dev/null); rm -f -- "$out.rc"; job_running "$jpid" || rm -f -- "$JOB_FILE"; JOB_PID=""
  num "$rc" || { rc=1; bad "$title was stopped before it finished."; }
  trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT
  JOB_KEEP=""
  # the output file may contain the passwords only if a tool printed them; mask it to be sure
  if [[ -n "$SYS_PW$ASM_PW" ]]; then ( umask 077; mask_pw < "$out" > "$out.m" ) && mv -f -- "$out.m" "$out"; rm -f -- "$out.m"; fi
  chmod 640 "$out" 2>/dev/null
  # RUN_OUT: the output of the command only (without the header and footer lines of the file)
  RUN_OUT=$(grep -v '^#| ' "$out")
  job_log_tail "$out" "$rc" | log_block "$title (output: $out)"
  local jd; jd=$(dur_text $((SECONDS - t0)))
  # the last progress (an RMAN copy: datafiles done of all), then the time the job took
  if [[ -n "$JOB_PROGRESS_FN" ]]; then job_progress_poll "$out" "$t0"; [[ -n "$JOB_PROGRESS" ]] && _log JOB "$title at its end: $JOB_PROGRESS"; fi
  _log JOB "end pid=$jpid rc=$rc $title, after $jd"
  local jok=0; [[ "$rc" == 0 || ( "$rc" == 6 && ( "$title" == *installer* || "$title" == *"configuration tools"* ) ) ]] && jok=1
  # plain: always the time it took; the screen layout says it for a job that worked (ui_job_done), here for one that did not
  if [[ $UI -ne 1 ]]; then say "$title ended after $jd (exit code $rc)."
  elif [[ $jok -eq 0 ]]; then ui_live_clear; say "$title ended after $jd (exit code $rc)."; fi
  ui_job_done "$title" "$rc" "$t0" "$out"
  JOB_PROGRESS_FN=""; JOB_PROGRESS=""
  ui_drain
  return "$rc"
}

#------------------------------------------------------------------------------
# Files: backups and writes that never follow a symbolic link, done as the owner
#------------------------------------------------------------------------------
declare -A BACKUPS_MADE=()
backup_file() {
  # $1 file, $2 user (empty = root). Keeps <file>.bak_<run id> once per run.
  local f=$1 u=${2:-} b="$1.bak_$RUN_ID"
  [[ -f "$f" && ! -L "$f" ]] || return 0
  # made once per run. In a folder of another user, a name that exists but was not made by this run is not
  # taken as the backup (that user could have put it there before)
  if [[ -e "$b" || -L "$b" ]]; then
    [[ -n "${BACKUPS_MADE[$b]:-}" || -z "$u" || "$u" == root ]] && return 0
    bad "$b exists already, but this run did not make it. Nothing is changed in $f."; return 1
  fi
  if [[ -n "$u" && "$u" != "root" ]]; then
    # made and protected by the user itself: root never runs chmod on a path in that user's folder
    # (a backup is never readable by everyone, even when the old file was: a password file or wallet with a bad mode)
    runuser -u "$u" -- sh -c 'cp -p -- "$1" "$2" && chmod o-rwx -- "$2"' sh "$f" "$b" || return 1
  else cp -p --remove-destination -- "$f" "$b" && chmod o-rwx -- "$b" || return 1; fi
  BACKUPS_MADE[$b]=1
  say "Backup: $b"
}
dir_root_only() {
  # 0 = only root can add, remove or rename entries in the folder of $1. Root writes a file only there:
  # in a folder another user can write to, the file could be swapped for a link between check and write.
  local d o m; d=$(dirname -- "$1")
  read -r o m < <(stat -c '%u %a' -- "$d" 2>/dev/null) || return 1
  [[ "$o" == "0" ]] && (( (8#$m & 8#022) == 0 ))
}
append_as() {
  # $1 user (empty or root = root), $2 file; stdin = text to add at the end (a missing final newline is added first)
  local u=${1:-root} f=$2 txt before=0 after=0 lead=0
  txt=$(cat)
  [[ -L "$f" ]] && { bad "Not changed: $f is a symbolic link."; return 1; }
  if [[ -s "$f" && -n "$(tail -c 1 -- "$f")" ]]; then txt=$'\n'"$txt"; lead=1; fi
  [[ -f "$f" ]] && before=$(stat -c '%s' -- "$f")
  if [[ "$u" != "root" ]]; then printf '%s\n' "$txt" | runuser -u "$u" -- tee -a -- "$f" > /dev/null || return 1
  else
    dir_root_only "$f" || { bad "Not changed: $(dirname -- "$f") must be a folder that only root can write to."; return 1; }
    printf '%s\n' "$txt" >> "$f" || return 1
  fi
  after=$(stat -c '%s' -- "$f" 2>/dev/null)
  declare -F journal_file_appended >/dev/null && journal_file_appended "$f" "$before" "$txt"$'\n' "$((after - before))" "$lead"
  return 0
}
write_as() {
  # $1 user, $2 file, $3 mode; stdin = the whole new content (written as that user)
  local u=$1 f=$2 m=$3 existed=0
  [[ -L "$f" ]] && { bad "Not changed: $f is a symbolic link."; return 1; }
  [[ -d "$f" ]] && { bad "Not changed: $f is a folder, not a file."; return 1; }
  [[ -e "$f" ]] && existed=1

  if [[ "$u" == "root" ]]; then
    local t; t=$(mktemp "$(dirname "$f")/.dgtmp.XXXXXX") || return 1
    cat > "$t" && chmod "$m" "$t" && mv -fT -- "$t" "$f" || { rm -f -- "$t"; return 1; }
  else
    # as the owner, also through a temp file in the same folder and a rename: a crash never leaves half a file
    # (the group of the old file is kept)
    runuser -u "$u" -- sh -c 't=$(mktemp "$(dirname "$1")/.dgtmp.XXXXXX") || exit 1
      if cat > "$t" && chmod "$2" "$t" && { [ ! -e "$1" ] || chgrp --reference="$1" "$t" 2>/dev/null || true; } && mv -fT -- "$t" "$1"; then exit 0; fi
      rm -f -- "$t"; exit 1' sh "$f" "$m" || return 1
  fi
  declare -F journal_file_written >/dev/null && journal_file_written "$f" "$existed"
  return 0
}

install_as() {
  # $1 user, $2 group, $3 mode, $4 private source file of root, $5 target in a folder of $1. Like install -o -g -m,
  # but written by $1 itself (temp file and rename in the target folder): root never chmods or chowns a path
  # there, so a link swapped in meanwhile cannot lead root to another file
  [[ -L "$5" ]] && { bad "Not changed: $5 is a symbolic link."; return 1; }
  [[ -d "$5" ]] && { bad "Not changed: $5 is a folder, not a file."; return 1; }
  runuser -u "$1" -- sh -c 'umask 077; t=$(mktemp "$(dirname "$1")/.dgtmp.XXXXXX") || exit 1
    if cat > "$t" && chgrp "$2" "$t" && chmod "$3" "$t" && mv -fT -- "$t" "$1"; then exit 0; fi
    rm -f -- "$t"; exit 1' sh "$5" "$2" "$3" < "$4"
}
safe_link_target() {
  # $1 a symbolic link -> prints the file it points to, when writing through it is safe: the link is owned by
  # root, the target is a regular file of root, $ORACLE_USER or $GRID_USER, and every folder above the target is
  # owned by root and writable only by root (nobody else could swap the file). 1 otherwise.
  [[ -L "$1" && "$(stat -c '%U' -- "$1" 2>/dev/null)" == root ]] || return 1
  local t d o m; t=$(readlink -e -- "$1" 2>/dev/null) || return 1
  [[ -f "$t" && ! -L "$t" ]] || return 1
  o=$(stat -c '%U' -- "$t" 2>/dev/null)
  [[ "$o" == root || "$o" == "$ORACLE_USER" || ( -n "${GRID_USER:-}" && "$o" == "$GRID_USER" ) ]] || return 1
  d=$(dirname "$t")
  while :; do
    IFS=' ' read -r o m <<< "$(stat -c '%U %a' -- "$d" 2>/dev/null)"
    [[ "$o" == root && "$m" =~ ^[0-7]+$ ]] && (( (8#$m & 8#022) == 0 )) || return 1
    [[ "$d" == / ]] && break
    d=$(dirname "$d")
  done
  printf '%s' "$t"
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
srv_notfound() {
  # $1 the name asked for, $2 an extra code that means "not found" (optional). True only when the srvctl output
  # in RUN_OUT says that this resource is not registered: its own codes, or "could not be found" / "does not
  # exist" on a line that names it (any other failure, such as CRS down or a missing file, is no such answer)
  # (the pattern in a variable: written in [[ ]], bash would expand its $# and drop the characters)
  local n=${1,,} re='^[a-z0-9_.$#+-]+$'
  [[ "$n" =~ $re ]] || return 1
  # the regex characters a name can hold (. $ +) as literals, escaped with sed (the same on bash 4.2 and 5)
  n=$(printf '%s' "$n" | sed 's#[.$+]#\\&#g')
  [[ -n "${2:-}" ]] && grep -qE "$2" <<< "$RUN_OUT" && return 0
  # the name as the resource it is (database x, listener x, ora.x.db), never a path that only contains it, on the
  # line of the code or the message (a PRCR-1001 about another resource is no answer about this one)
  grep -iE 'PRCD-1120|PRCR-1001|could not be found|does not exist' <<< "$RUN_OUT" | tr '[:upper:]' '[:lower:]' \
    | grep -qE "(database|listener|resource) $n( |\.|$)|ora\.$n\.(db|lsnr)( |$)"
}
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
