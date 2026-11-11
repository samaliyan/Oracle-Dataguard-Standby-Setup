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
declare -A STEP_RESULT=() STEP_TITLE=() STEP_NOW=() LAST_RESULT=() LAST_WHEN=() LAST_REASON=() LAST_RUNID=()
PHASE4_FIRST=0           # the admin chose to do phase 4 (primary) right after phase 1
NEXT_PRINTED=0           # the summary printed the "Next:" line (fatal does not print a second one)
DO_FAIL_STOP_ONLY=0      # set by a do function: after its failure only [q] is offered (RESUME_STEP says where to go on)
JOB_BUSY_TEXT=""
JOB_BUSY_PHASE=""        # check mode with a long job running: steps of this phase and later are not judged
declare -A AUTO_WAIT=()   # "step X" / "phase N" -> 1: not done in this run and you went on (its waiters are not asked again)
# steps that only the script can do: there is no [s] skip for them
readonly NO_SKIP_STEPS=" 1.2 1.3 1.4 "
# --yes answers "y" for the actions on this server. Never for: steps that stop or restart a running standby
# (9.1 9.2 9.3 9.7), questions inside an action (disk erasure, CLEAN, DELETE, DUPLICATE, the host key, passwords),
# and anything on the primary (printed only, as always).
YES_MODE=0
readonly YES_ASK_STEPS=" 3.10 9.1 9.2 9.3 9.7 9.8 "     # 3.10 restarts the listener, 9.8 sets deletion of archived logs
YES_HOLD=0          # a check sets it when its action would erase something (a half-unpacked software folder)
PRIM_RAN=0          # the primary commands of this step were run by the script (PRIMARY_RUN=yes)
DONE_AS_OK=0        # a do function sets it when it changed nothing (recorded OK, not DONE)
CHECK_WAITS=0       # a check sets it when nothing is wrong but it could not really check: 1 = waiting (checked again
                    # later), 2 = it cannot be checked at all (skipped (optional) for an optional step, else waiting). Never OK.
yes_to_all_on() {
  # [a] at a step question: from here to the end of this run, the actions on this server are answered y
  # (the steps and questions listed above are still asked)
  YES_MODE=1
  _log ASK "[${CUR_STEP:-}] a: yes to all from here (this server; risky actions are still asked)"
  say "${C_D}Yes to all from here, for this server. Risky actions (restarts, deletions, the primary) are still asked.${C_N}"
  ui_header 2>/dev/null || true
}
yes_auto() { [[ $YES_MODE -eq 1 && $YES_HOLD -eq 0 && "$YES_ASK_STEPS" != *" $1 "* ]]; }
no_skip() { [[ "$NO_SKIP_STEPS" == *" $1 "* ]]; }
NOW=""; PLAN=""; USING=""; DONE_MSG=""; QUIET_PLAN=0; KIND_NOW=""; NEED_SYS=0; MANUAL_WHERE=""

step_num() { local a=${1%%.*} b=${1#*.}; printf '%d' $(( 10#$a * 1000 + 10#$b )); }

step_in_range() {
  local id=$1
  [[ "${id%%.*}" == "1" ]] && return 0          # phase 1 (connect/settings) always runs
  [[ -n "$TO_STEP" && $(step_num "$id") -gt $(step_num "$TO_STEP") ]] && return 1
  if [[ -n "$ONLY_PHASE" ]]; then [[ "${id%%.*}" == "$ONLY_PHASE" ]]; return; fi
  [[ -z "$FROM_STEP" ]] && return 0
  [[ $(step_num "$id") -ge $(step_num "$FROM_STEP") ]]
}

phase_header() {
  local t="Phase $1 of 10 $S_DOT ${PHASE_TITLES[$1]:-$2}" w   # one name per phase, the same everywhere
  w=$((66 - ${#t})); [[ $w -lt 2 ]] && w=2
  if [[ $UI -eq 1 ]]; then
    # the map shows the phase; what is printed before its first step goes on a clean area
    [[ -n "$UI_PHASE" && "$UI_PHASE" != "$1" ]] && UI_PREV_PHASE=$UI_PHASE
    UI_PHASE=$1; ui_live_clear; ui_header
    ui_flush
    if [[ $UI_KEEP_ONCE -eq 1 ]]; then ui_buf_start 0; else ui_buf_start 1; fi
    ui_emit ""
    ui_emit "$(printf '  %sPhase %s %s %s%s' "$C_B" "$1" "$S_DOT" "${PHASE_TITLES[$1]:-$2}" "$C_N")"
    # what is printed before the first step of the phase (its intro, warnings of quiet checks, a password
    # that did not work) stays in view at that step
    UI_KEEP_ONCE=1
  else
    printf '\n\n  %s%s %s %s%s\n' "$C_B" "$(rule 2 "$S_HR2")" "$t" "$(rule $w "$S_HR2")" "$C_N"
  fi
  _log PHASE "$1  $2"
}
# words shown for the result codes kept in the progress file
result_label() {
  case "$1" in
    OK) printf 'ok' ;; DONE) printf 'done' ;; DONE_BY_YOU) printf 'done by you' ;; SKIPPED) printf 'skipped' ;;
    SKIPPED_OPTIONAL) printf 'skipped (optional)' ;; NOT_ON_RELEASE) printf 'n/a (release)' ;; FAILED_SKIPPED) printf 'failed, skipped' ;; FAILED) printf 'failed' ;;
    WAITS) printf 'waiting' ;; RUNNING) printf 'running' ;; TODO) printf 'to do' ;; PROBLEM) printf 'problem' ;;
    UNDONE) printf 'undone' ;; NOT_FINISHED) printf 'stopped here' ;; *) printf '%s' "$1" ;;
  esac
}
result_color() {
  case "$1" in OK|DONE|DONE_BY_YOU) printf '%s' "$C_G" ;; SKIPPED_OPTIONAL|NOT_ON_RELEASE|WAITS) printf '%s' "$C_D" ;; RUNNING) printf '%s' "$C_C" ;;
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

declare -A STEP_T0=() DO_T0=()
record() {
  # the result of a step: in memory, in the log, and in the progress file (so the next run can show
  # how far the last run got, and which steps are done)
  [[ $UI -eq 1 ]] || pt_flush      # (a step that ends without a word still shows its title)
  STEP_RESULT[$1]=$2; STEP_NOW[$1]=${NOW%%$'\n'*}; STEP_WHEN[$1]=$(date +%H:%M)
  ui_flush
  ui_header
  # the step a "Next" line pointed to is done now: the pointer would only mislead later
  [[ "$RESUME_STEP" == "$1" && ( "$2" == OK || "$2" == DONE || "$2" == DONE_BY_YOU ) ]] && RESUME_STEP=""
  # how long it took: from its action when it had one (the question before it is not counted), else from its start
  local dt="" t0=${DO_T0[$1]:-${STEP_T0[$1]:-}}
  if [[ "$1" == "${CUR_STEP:-}" && -n "$t0" ]]; then
    dt=$((SECONDS - t0))
    # plain output: the time of a step that took a while, under its result
    [[ $UI -eq 0 && $dt -ge 5 ]] && printf '      %s(%s)%s\n' "$C_D" "$(ui_dur "$dt")" "$C_N"
    dt=" ($(ui_dur "$dt")$([[ -n "${DO_T0[$1]:-}" ]] && printf ' action'))"
  fi
  _log RESULT "[$1] $2$dt  ${STEP_TITLE[$1]:-}${STEP_NOW[$1]:+  -- ${STEP_NOW[$1]}}"
  # the values of this run (the summary screen of step 1.4, as accepted): once in the log, so the log is complete
  if [[ "$1" == 1.4 && ( "$2" == OK || "$2" == DONE ) && ${VALUES_LOGGED:-0} -eq 0 && -s "$LOG_DIR/summary_$RUN_ID.txt" ]]; then
    VALUES_LOGGED=1; log_block "values of this run (step 1.4, as accepted; also in $LOG_DIR/summary_$RUN_ID.txt)" < "$LOG_DIR/summary_$RUN_ID.txt"
  fi
  [[ -n "$PROGRESS_FILE" ]] || return 0
  # check mode writes nothing but its log: the progress file keeps the results of the real runs
  [[ "$MODE" == "check" ]] && return 0
  install -d -m 700 "$STATE_DIR" 2>/dev/null
  local gr=0
  if ! { { grep -v "^$1|" "$PROGRESS_FILE" 2>/dev/null || gr=$?; printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$(ts)" "$RUN_ID" "${STEP_NOW[$1]//|/ }" && [[ $gr -le 1 || ! -e "$PROGRESS_FILE" ]]; } > "$PROGRESS_FILE.n" 2>/dev/null \
    && mv -f -- "$PROGRESS_FILE.n" "$PROGRESS_FILE"; }; then
    # the next run would show an old result for this step: said once
    [[ ${PROGRESS_WARNED:-0} -eq 1 ]] || { PROGRESS_WARNED=1; warn "The progress file $PROGRESS_FILE cannot be written. The next run may show old results."; }
  fi
  chmod 600 "$PROGRESS_FILE" 2>/dev/null
  return 0
}
load_progress() {
  # results of earlier runs (LAST_RESULT / LAST_WHEN per step)
  LAST_RESULT=(); LAST_WHEN=(); LAST_REASON=(); LAST_RUNID=()
  [[ -n "$PROGRESS_FILE" && -s "$PROGRESS_FILE" ]] || return 0
  local id r t run why
  while IFS='|' read -r id r t run why; do [[ "$id" =~ ^[0-9]+\.[0-9]+$ ]] && { LAST_RESULT[$id]=$r; LAST_WHEN[$id]=$t; LAST_REASON[$id]=$why; [[ "$run" =~ ^[0-9_]+$ ]] && LAST_RUNID[$id]=$run; }; done < "$PROGRESS_FILE"
  return 0
}
PHASE_TITLES=("" "Connect to the primary" "Prepare this server" "Install the Oracle software" "Prepare the primary" "Listener and tnsnames.ora" "Password file and TDE wallet" "Start the empty instance (NOMOUNT)" "Copy the database (RMAN)" "Start redo apply and transport" "Health check")
phase_done_result() {
  # overall result of a phase from the progress file: DONE | PARTLY | OPEN | - (never ran)
  local p=$1 i n=0 ok=0 bad=0
  for i in "${HELP_IDS[@]}"; do
    [[ "${i%%.*}" == "$p" ]] || continue
    on_demand "$i" && continue
    n=$((n + 1))
    case "${LAST_RESULT[$i]:-}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|NOT_ON_RELEASE) ok=$((ok + 1)) ;; "") ;; *) bad=$((bad + 1)) ;; esac
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
    case "${LAST_RESULT[$i]:-}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|NOT_ON_RELEASE|"") ;;
      *) nopen=$((nopen + 1))
         if [[ $nopen -le 8 ]]; then
           open+="$(printf '      %-5s %s%-16s%s %s' "$i" "$(result_color "${LAST_RESULT[$i]}")" "$(result_label "${LAST_RESULT[$i]}")" "$C_N" "$(step_title_of "$i" 2>/dev/null | cut -c1-44)")"$'\n'
           [[ -n "${LAST_REASON[$i]:-}" ]] && open+="            ${C_D}${LAST_REASON[$i]:0:100}${C_N}"$'\n'
         fi
         [[ -n "$first" || "$i" == 1.* ]] || on_demand "$i" || first=$i ;;
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
    printf '    - commands on the primary, in one visit (phase 4): as oracle (SQL), as grid (listener, password file)\n'
    printf '      and as root (one /etc/hosts line, if needed); a short downtime only if the primary is in NOARCHIVELOG\n'
  fi
  return 0
}
step_ok_anywhere() {
  # 0 when step $1 is done: in this run, or (when it did not run now) in an earlier run
  case "${STEP_RESULT[$1]:-}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|NOT_ON_RELEASE) return 0 ;; "") ;; *) return 1 ;; esac
  # started in this run but not finished (the run stopped inside it): not done
  [[ " ${STEP_ORDER[*]+${STEP_ORDER[*]}} " == *" $1 "* ]] && return 1
  case "${LAST_RESULT[$1]:-}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|NOT_ON_RELEASE) return 0 ;; esac
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
    # (2.7 waiting for the visit to the primary in phase 4 is no place to go on from: phase 4 shows its command)
    [[ "$id" == 2.7 && ${P27_DEFERRED:-0} -eq 1 ]] && continue
    n=$(step_num "$id"); [[ $n -lt $best ]] && { best=$n; nx=$id; }
  done
  # (record() clears it when that step is done later in the run; one set after the step was done, such as 7.2 after
  # a failed copy, is a deliberate "go back there")
  [[ -n "$RESUME_STEP" && "$RESUME_STEP" != 1.* ]] && nx=$RESUME_STEP
  [[ -n "$nx" ]] || return 0
  # the step on demand (10.7) goes on only with its own option
  on_demand "$nx" && { printf '%s --roll-forward' "$SELF"; return 0; }
  [[ ${ROLL_FORWARD:-0} -eq 1 && "$nx" == 10.* ]] && { printf '%s --roll-forward' "$SELF"; return 0; }
  if [[ -n "$ONLY_PHASE" && "$ONLY_PHASE" != "1" ]]; then printf '%s --only %s' "$SELF" "${ONLY_TEXT:-$ONLY_PHASE}"; return 0; fi
  # a range (--only 2.1-2.4, grid, db): the same range again, from the step that is not done
  if [[ -n "$TO_STEP" && "$nx" == *.* ]] && [[ $(step_num "$nx") -ge $(step_num "$FROM_STEP") && $(step_num "$nx") -le $(step_num "$TO_STEP") ]]; then
    if [[ "$nx" == "${FROM_STEP%.0}" || "$nx" == "$FROM_STEP" ]]; then printf '%s --only %s' "$SELF" "$ONLY_TEXT"
    else printf '%s --only %s-%s' "$SELF" "$nx" "$TO_TEXT"; fi
    return 0
  fi
  local lim; lim=$(step_num "$([[ "$nx" == *.* ]] && printf '%s' "$nx" || printf '%s.0' "$nx")")
  for id in "${HELP_IDS[@]}"; do
    [[ "$id" == 1.* ]] && continue
    [[ $(step_num "$id") -lt $lim ]] || break
    is_optional "$id" && continue
    [[ "$id" == 2.7 && ${P27_DEFERRED:-0} -eq 1 ]] && continue
    step_ok_anywhere "$id" || { printf '%s' "$SELF"; return 0; }
  done
  printf '%s --from %s' "$SELF" "$nx"
}
write_last_run() {
  # $1 how the run ended
  [[ -n "$LASTRUN_FILE" ]] || return 0
  [[ -n "${UNDO_STEP:-}" ]] && return 0     # an undo is not a run of the steps (the journal holds what it did)
  [[ "$MODE" == "check" ]] && return 0       # check mode writes nothing but its log
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
readonly OPTIONAL_STEPS=" 4.8 4.10 4.11 9.9 "
is_optional() { [[ "$OPTIONAL_STEPS" == *" $1 "* ]]; }
# steps that run only when asked for (10.7: --roll-forward): never "next", never needed for a phase to be done
readonly ON_DEMAND_STEPS=" 10.7 "
on_demand() { [[ "$ON_DEMAND_STEPS" == *" $1 "* ]]; }
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
  # (the screen layout: one line; h opens them on the separate screen)
  if [[ $UI -eq 1 ]]; then
    if no_skip "$1"; then say "${C_D}To do it by hand: h shows the commands of this step. Then answer r to check again.${C_N}"
    else say "${C_D}To do it by hand: h shows the commands of this step. Then answer r to check again, or s to go on.${C_N}"; fi
    return 0
  fi
  if no_skip "$1"; then say "To do this step by hand (then answer r to check again):"
  else say "To do this step by hand (then answer r to check again, or s to go on):"; fi
  show_help "$1" || true
}

paste_safe() {
  # stdin = shell lines to type (or paste) in an interactive shell; stdout = the same lines, safe to paste:
  # a line that can end with "exit" (a guard such as  ... || { rm -f "$t"; exit 1; }) runs in a subshell ( ... ),
  # so a failure ends that line only, never the shell of the user. A line that starts a here-document gets its ")"
  # after the end word of the here-document. Lines inside a here-document are data: never changed.
  local line hd="" close=0 re='<<-?[[:space:]]*['"'"'"]?([A-Za-z_][A-Za-z0-9_]*)'
  local rx='(^|[;&|{([:space:]])exit([[:space:]]+[0-9]+)?[[:space:]]*($|[;}&|)])'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$hd" ]]; then
      printf '%s\n' "$line"
      if [[ "$line" == "$hd" ]]; then hd=""; [[ $close -eq 1 ]] && printf ')\n'; close=0; fi
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*# || ! "$line" =~ $rx ]]; then
      printf '%s\n' "$line"
      [[ "$line" =~ ^[[:space:]]*# ]] || { [[ "$line" =~ $re ]] && hd=${BASH_REMATCH[1]}; }
      continue
    fi
    if [[ "$line" =~ $re ]]; then hd=${BASH_REMATCH[1]}; close=1; printf '( %s\n' "$line"
    else printf '( %s )\n' "$line"; fi
  done
}
box_width() {
  # the width of the rules around commands: 70, less on a narrow screen (the top and bottom rules are the same)
  local w=70
  [[ ${UI_COLS:-0} -gt 0 && $((UI_COLS - 6)) -lt $w ]] && w=$((UI_COLS - 6))
  [[ $w -lt 30 ]] && w=30
  printf '%d' "$w"
}
print_commands() {
  # $1 where, $2 run as ("user  ->  env ; program" or a user name), stdin = commands.
  # The commands are printed at column 0 between the two rules: copied from the screen, they are exactly what must be
  # typed (the end word of a here-document, an entry of tnsnames.ora or listener.ora that must start in column 1).
  # The same text goes to the screen, the log and the actions file.
  local where=$1 how=$2 line cmds who prep="" note="" t body=""
  [[ $UI -eq 1 ]] || pt_flush
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
  # remarks in a shell box are shell comments (# ...), in an SQL or RMAN box they stay "-- ..."
  local shellbox=1; [[ "$how" == *sqlplus* || "$how" == *rman* || "$how" == *asmcmd* ]] && shellbox=0
  # the text to type, built once
  [[ -n "$note" ]] && body+="# $note"$'\n'
  if [[ -n "$prep" ]]; then
    while IFS= read -r line; do line=${line# }; [[ -n "$line" ]] && body+="$line"$'\n'; done <<< "${prep// ; /$'\n'}"
    body+=$'\n'
  fi
  local sh=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ $shellbox -eq 1 && "$line" == "-- "* ]] && line="# ${line#-- }"
    [[ $shellbox -eq 1 && "$line" == "--" ]] && line="#"
    sh+="$line"$'\n'
  done <<< "$cmds"
  # in a shell box, a guard that ends with "exit" runs in a subshell (it must not close the shell of the user)
  if [[ $shellbox -eq 1 ]]; then body+=$(printf '%s' "$sh" | paste_safe); else body+=${sh%$'\n'}; fi
  ui_live_clear
  # (on the screen layout every line goes to the step area, so the box is laid out with the step text)
  _pc() { if [[ $UI -eq 1 ]]; then ui_emit "$1"; else printf '%s\n' "$1"; fi; }
  local bw w; bw=$(box_width); w=$((bw - 4 - ${#t})); [[ $w -lt 2 ]] && w=2
  _pc ""; _pc "$(printf '    %s%s %s %s%s' "$C_M" "$(rule 2)" "$t" "$(rule $w)" "$C_N")"
  local inhd="" hre='<<-?[[:space:]]*['"'"'"]?([A-Za-z_][A-Za-z0-9_]*)'
  while IFS= read -r line || [[ -n "$line" ]]; do
    # comments dim (never inside a here-document: that is the text of a file)
    if [[ -z "$inhd" && ( "$line" == "#"* || "$line" == "-- "* || "$line" == "( #"* ) ]]; then _pc "$C_D$line$C_N"
    else _pc "$line"; fi
    if [[ -n "$inhd" ]]; then [[ "$line" == "$inhd" ]] && inhd=""
    elif [[ "$line" =~ $hre && "$line" != "#"* ]]; then inhd=${BASH_REMATCH[1]}; fi
  done <<< "$body"
  _pc "$(printf '    %s%s%s' "$C_M" "$(rule "$bw")" "$C_N")"; _pc ""
  printf '%s\n' "$body" | log_block "commands for: $where (as $who)"
  if [[ -n "$ACTIONS_FILE" ]]; then
    { printf '\n# ===== %s | step %s | %s, as %s\n' "$(ts)" "$CUR_STEP" "$where" "$who"; printf '%s\n' "$body"; } | mask_pw >> "$ACTIONS_FILE"
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
    # the screen layout: l (every step) and d (details of this step) at any question that has no such answer
    if [[ $UI -eq 1 && "$ANSWER" == l ]]; then ui_list; continue; fi
    if [[ $UI -eq 1 && "$ANSWER" == d ]]; then ui_details "${CUR_STEP:-}"; continue; fi
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
         if [[ $UI -eq 1 ]]; then
           local wt0=$SECONDS
           while [[ $UI -eq 1 && $WATCH_STOP -eq 0 ]] && job_running "$JOB_PID" && [[ ! -f "$JOB_OUT.rc" ]]; do ui_job_tick "$JOB_TITLE" "$JOB_OUT" "$wt0"; done
           ui_live_clear; ui_drain
         else
         { tail -n 20 -f --pid=$$ -- "$JOB_OUT" 2>/dev/null | mask_pw | sed -u 's/^/        /'; } 9>&- &
         tp=$!; TAIL_PID=$tp
         while [[ $WATCH_STOP -eq 0 ]] && job_running "$JOB_PID" && [[ ! -f "$JOB_OUT.rc" ]]; do nap 2; done
         sleep 1; pkill -P "$tp" 2>/dev/null; kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null; TAIL_PID=""
         fi
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

step_error() {
  # $1 = a byte position in the run log. The first real error the action logged after it: the first line of its ✘
  # messages with an error code (ORA-, RMAN-, INS-, PRVF-, TNS-, SP2-, CRS- ..., [FATAL]), else the first such message.
  # One line, as it is in the log (masked).
  [[ -n "$LOG_FILE" && -r "$LOG_FILE" ]] || return 0
  tail -c +$(( ${1:-0} + 1 )) -- "$LOG_FILE" 2>/dev/null | awk '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:]+ \| / {
      infail = index($0, "| FAIL   | ") > 0
      if (!infail) next
      t = $0; sub(/^[^|]*\| FAIL   \| /, "", t)
    }
    !/^[0-9][0-9][0-9][0-9]-/ { if (!infail) next; t = $0 }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "") next
      if (first == "" && t !~ /:$/) first = t
      if (code == "" && t ~ /((ORA|RMAN|INS|PRV[FGE]|TNS|SP2|CRS|PRC[A-Z]|CLSRSC|ASMCMD|DBT|LRM|OPATCH|UDE|DGM)-[0-9]+)|\[FATAL\]/) code = t
    }
    END { r = (code != "" ? code : first); if (length(r) > 150) r = substr(r, 1, 147) "..."; printf "%s", r }'
}
EXIT_STEP_FAILED=4
step_failed_stop() {
  # $1 step, $2 its error. A failed step after which nothing can be chosen (no retry, no skip): the run ends here,
  # without a question. The last lines say so, with the error and what to do next. Exit code 4 (a quit is 1).
  local id=$1 err=$2
  say "${C_D}How to do this step by hand:  $SELF --help-step $id${C_N}"
  _log STOP "step $id failed: $err"
  tty_restore; ui_end
  CUR_STEP=$id
  summary "Stopped: step $id failed${err:+ ($err)}"
  FATAL_SEEN=1            # (a stop from here on prints no second summary)
  write_last_run "stopped, the step failed"
  exit "$EXIT_STEP_FAILED"
}

run_step() {
  local id=$1 kind0=$2 kind=$2 title=$3 checkfn=$4 dofn=${5:-}
  step_in_range "$id" || return 0
  # (a step checked twice in a run, like 2.7 waiting in phase 2 and checked again after the phase-4 visit, is listed once)
  [[ " ${STEP_ORDER[*]-} " == *" $id "* ]] || STEP_ORDER+=("$id"); STEP_TITLE[$id]=$title; CUR_STEP=$id
  STEP_T0[$id]=$SECONDS; unset "DO_T0[$id]"
  if [[ $UI -eq 1 ]]; then ui_step_begin "$id" "$title"
  elif [[ $VERBOSE -eq 0 ]]; then pt_flush; PT_PENDING="$id"$'\t'"$title"     # printed with the first output of the step
  else printf '\n  %sStep %s%s  %s%s%s\n' "$C_B" "$id" "$C_N" "$C_W" "$title" "$C_N"; fi
  _log STEP "[$id] $title"
  local rc drc acted=0 helped=0 opts w ferr=""
  PRIM_RAN=0
  # (phase 4 needs nothing of this server: it is judged also while a job runs)
  if [[ -n "$JOB_BUSY_PHASE" && "${id%%.*}" -ge "$JOB_BUSY_PHASE" && "${id%%.*}" != 4 ]]; then
    NOW=$JOB_BUSY_TEXT
    wait_msg "$NOW"; STEP_NOW[$id]=$NOW; record "$id" WAITS; return 0
  fi
  while true; do
    # a new attempt (you answered r): the step starts again on a clean area
    if [[ $UI -eq 1 && $UI_RETRY -eq 1 ]]; then UI_RETRY=0; UI_ATTEMPT=$((UI_ATTEMPT + 1)); helped=0; ui_body_reset "$id" "$title"; fi
    UI_RETRY=0
    YES_HOLD=0
    NOW=""; PLAN=""; USING=""; DONE_MSG=""; QUIET_PLAN=0; PRIMARY_HOW_STEP=""; MANUAL_HOW=""; MANUAL_WHERE=""; KIND_NOW=""; NEED_SYS=0; PLAN_UNDO=""; CHECK_WAITS=0
    cp_reset; job_show_reset; DONE_AS_OK=0   # (the job list of phase 3 is cleared like the command list)
    ui_live "$S_WAIT checking ..."
    "$checkfn"; rc=$?
    ui_live_clear
    vq_dump
    # (plain output: the title waits only for a step that is already correct; block and hint often run in a pipe,
    # where clearing PT_PENDING would not reach this shell)
    if [[ -n "$PT_PENDING" ]] && ! [[ $rc -eq 0 && $CHECK_WAITS -eq 0 && $PRIM_RAN -eq 0 && $acted -eq 0 && -z "$(primary_pending_get "$id")" ]]; then pt_flush; fi
    kind=${KIND_NOW:-$kind0}
    # nothing is wrong, but the check itself could not be done now (NOW says when it is): waiting, never OK.
    # 2: an optional step that cannot be checked at all: skipped (optional), never OK
    if [[ $rc -eq 0 && $CHECK_WAITS -eq 1 ]]; then
      wait_msg "$NOW"; record "$id" WAITS; return 0
    fi
    # 3: the check does not exist for this release (10.5 on 12.1): nothing to wait for and nothing wrong
    if [[ $rc -eq 0 && $CHECK_WAITS -eq 3 ]]; then
      _mark "$C_D" "$S_DOT" INFO "$NOW"; record "$id" NOT_ON_RELEASE; return 0
    fi
    if [[ $rc -eq 0 && $CHECK_WAITS -eq 2 ]]; then
      # only an optional step can be left out; any other step that cannot be checked waits
      wait_msg "$NOW"; if is_optional "$id"; then record "$id" SKIPPED_OPTIONAL; else record "$id" WAITS; fi; return 0
    fi
    if [[ $rc -eq 0 ]]; then
      local pend; pend=$(primary_pending_get "$id")
      if [[ $PRIM_RAN -eq 1 ]]; then
        # run on the primary by the script (PRIMARY_RUN=yes, you answered y): journaled with its undo
        PRIM_RAN=0; ok_lines "Done on the primary (over ssh). ${NOW}"; record "$id" DONE
        [[ "$pend" == "-" || -z "$pend" ]] && pend="(nothing to take back; see --help-step $id)"
        journal PRIMARY "$id" "[run by the script over ssh as $PRIMARY_SSH_USER] $pend"; primary_pending_del "$id"
      elif [[ $acted -eq 1 || -n "$pend" ]]; then
        ok_lines "Done by you. ${NOW}"; record "$id" DONE_BY_YOU
        # the commands printed for the primary (in this run or an earlier one) are done now: journal them with their undo
        if [[ -n "$pend" ]]; then
          [[ "$pend" == "-" ]] && pend="(nothing to take back; see --help-step $id)"
          local phow; phow=$(primary_pending_how "$id")
          journal PRIMARY "$id" "${P4_CHANGE[$id]:+changed: ${P4_CHANGE[$id]}; }${phow:+[as $phow] }$pend"; primary_pending_del "$id"
        fi
      elif [[ -n "$PT_PENDING" ]]; then
        # already correct and nothing printed yet: one line (the title and the first line of the result; the rest is in the log)
        PT_PENDING=""
        local t1=$title r1; [[ ${#t1} -gt 42 ]] && t1="${t1:0:41}…"
        # the first line of the result (a line ending in ":" with the line after it)
        r1=$(awk 'NR == 1 {l = $0; if (l !~ /:$/) {print l; exit}} NR == 2 {sub(/^ +/, ""); print l " " $0; exit} END {if (NR == 1 && l ~ /:$/) print l}' <<< "${NOW:-Already correct}")
        [[ ${#r1} -gt 100 ]] && r1="${r1:0:99}…"
        printf '  %s%s%s %-5s %-42s  %s%s%s\n' "$C_G" "$S_OK" "$C_N" "$id" "$t1" "$C_D" "$r1" "$C_N"
        _log OK "${NOW:-Already correct}"; record "$id" OK
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
        elif [[ "$w" == step* ]] && ! step_in_range "$wid"; then say "Step $wid is not done and is not part of this run. Answer q, then run:  $(go_on_cmd "$wid")"
        elif [[ "$w" == step* ]]; then say "Step $wid must be done first. Then answer r. Or answer s to go on without it."
        else say "Phase $wid is not done. Answer s to go on (steps that need it will wait), or q and run:  $(go_on_cmd "$wid")"; fi
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
        p) if d_1_5; then record 1.5 DONE; UI_RETRY=1; fi; continue ;;
        s) [[ -n "$w" ]] && AUTO_WAIT[$w]=1
           skip_record "$id" "Skipped. Do it before the steps that need it."; return 0 ;;
        q) [[ -n "$w" && -z "$RESUME_STEP" ]] && RESUME_STEP=$wid
           user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
        *) UI_RETRY=1; continue ;;
      esac
    fi
    # rc 1: something must be done
    if [[ "$id" == 9.9 ]]; then say "${C_D}Optional: needed only for --health to check the primary, not to build the standby.${C_N}"
    else is_optional "$id" && say "${C_D}Optional: needed only for switchover and the broker, not to build the standby.${C_N}"; fi
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
      local prun=0
      [[ "$kind" == "primary" ]] && prim_run_allowed "$PLAN" "$how" && prun=1
      if [[ $prun -eq 1 ]]; then ask_choice "[y] Run it on the primary for me (as $PRIMARY_SSH_USER)   [r] I ran it myself   [s] Skip   [h] Help   [q] Quit" "yrshq"
      elif is_optional "$id"; then ask_choice "[r] Done, check it   [s] Skip (optional)   [h] Help   [q] Quit" "rshq"
      else ask_choice "[r] Done, check it   [s] Skip for now   [h] Help   [q] Quit" "rshq"; fi
      case "$ANSWER" in
        y) if prim_run_plan "$PLAN"; then PRIM_RAN=1; acted=1; UI_RETRY=1; continue; fi
           say "Nothing more was run on the primary. Run the rest yourself, then answer r."; continue ;;
        s) skip_record "$id" "Skipped."; return 0 ;;
        q) user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
        r) acted=1; UI_RETRY=1; PRIM_RAN=0; continue ;;
      esac
    fi
    if [[ "$kind" == "check" ]]; then
      # the fix once: not again when the status above already says it word for word
      [[ -n "$PLAN" && "$PLAN" != "$NOW" ]] && printf '%s\n' "$PLAN" | block "Fix:"
      if [[ "$MODE" == "check" ]]; then bad "Problem found.$([[ -n "$PLAN" && "$PLAN" != "$NOW" ]] && printf ' See Fix above.')"; record "$id" PROBLEM; return 0; fi
      [[ $helped -eq 0 && -z "$PLAN" ]] && { how_by_hand "$id"; helped=1; }
      ask_choice "[r] Check again   [s] Skip   [h] Help   [q] Quit" "rshq"
      case "$ANSWER" in
        s) skip_record "$id" "Skipped."; return 0 ;;
        q) user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
        *) UI_RETRY=1; continue ;;
      esac
    fi
    # kind auto (or ask: the do function asks its own question)
    printf '%s\n' "$PLAN" | block "Plan:"
    [[ -n "$USING" ]] && printf '%s\n' "$USING" | block "Using:"
    cp_show
    if [[ "$MODE" == "check" ]]; then todo "To do in a normal run"; record "$id" TODO; return 0; fi
    if [[ "$kind" != "ask" ]] && yes_auto "$id"; then
      ui_flush; printf '    %s%s Yes (yes to all)%s\n' "$C_D" "$S_ASK" "$C_N"; _log ASK "[$id] y (yes to all)"; ANSWER=y
    elif [[ "$kind" != "ask" ]]; then
      if [[ $YES_MODE -eq 0 ]]; then ask_choice "[y] Yes, do it   [a] Yes to all   [s] Skip   [h] Help   [q] Quit" "yashq"
      else ask_choice "[y] Yes, do it   [s] Skip   [h] Help   [q] Quit" "yshq"; fi
      case "$ANSWER" in
        a) yes_to_all_on ;;
        y) ;;
        s) skip_record "$id" "Skipped. To do it by hand:  $SELF --help-step $id"; return 0 ;;
        q) user_stop "Stopped by you" ;;
        h) show_help "$id" || true; continue ;;
      esac
    fi
    _log DO "[$id] start"
    JOURNAL_STEP_ENTRIES=0
    # where the log is now: the first error the action logs is found after this point (step_error)
    local logpos=0; [[ -n "$LOG_FILE" ]] && logpos=$(stat -c %s -- "$LOG_FILE" 2>/dev/null || printf 0)
    DO_T0[$id]=$SECONDS
    ui_flush; drc=0; IN_DO=1; "$dofn" || drc=$?; IN_DO=0; vq_dump
    _log DO "[$id] end, exit code $drc, after $(ui_dur $((SECONDS - DO_T0[$id])))"
    if [[ $drc -eq 3 ]]; then skip_record "$id" "Not started. To run it later:  $(on_demand "$id" && printf '%s --roll-forward' "$SELF" || printf '%s --from %s' "$SELF" "$id")"; return 0; fi
    if [[ $drc -eq 0 ]]; then
      NOW=""; CHECK_WAITS=0; "$checkfn"; rc=$?
      # done, but the result cannot really be checked yet: waiting (checked again in a later run)
      if [[ $rc -eq 0 && $CHECK_WAITS -eq 2 ]] && is_optional "$id"; then wait_msg "Done, not checked yet. $NOW"; record "$id" SKIPPED_OPTIONAL; return 0; fi
      if [[ $rc -eq 0 && $CHECK_WAITS -ne 0 ]]; then wait_msg "Done, not checked yet. $NOW"; record "$id" WAITS; return 0; fi
      # an action that changed nothing (the summary of 1.4 started without a change): OK, not DONE
      if [[ $rc -eq 0 && $DONE_AS_OK -eq 1 ]]; then DONE_AS_OK=0; ok_lines "${DONE_MSG:-$NOW}"; record "$id" OK; return 0; fi
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
      if [[ $rc -eq 1 && "$KIND_NOW" == "primary" ]]; then
        # the action did its part here (9.9: the key); the rest is on the primary (shown next, then checked).
        # acted stays 0: nothing was done on the primary yet, so no "Not done yet" line before the box
        ok_lines "Done on this server. Now on the primary:"; continue
      fi
      # the error is what the check says now
      ferr=${NOW%%$'\n'*}
      bad "The action ran, but the check still fails. ${NOW:-}"
    else
      # the error is the first one the action reported (an ORA-, RMAN-, INS- ... line, else its first ✘ message)
      ferr=$(step_error "$logpos")
      bad "The action did not finish."
    fi
    [[ -n "$ferr" ]] || ferr="the action did not finish"
    if [[ $DO_FAIL_STOP_ONLY -eq 1 ]]; then
      # a retry here would build on what the failed action left: the clean-up is in an earlier step.
      # Nothing can be chosen here, so nothing is asked: the run ends with the error (exit code 4)
      DO_FAIL_STOP_ONLY=0
      NOW=$ferr; record "$id" FAILED
      say "The script cannot go on from here. The next run first shows how to clean up this server (step 7.2)."
      step_failed_stop "$id" "$ferr"
    fi
    [[ $helped -eq 0 ]] && { how_by_hand "$id"; helped=1; }
    opts="[r] Try again   [s] Skip   [h] Help   [q] Quit"; local allowed2="rshq"
    no_skip "$id" && { opts="[r] Try again   [h] Help   [q] Quit"; allowed2="rhq"; }
    [[ "$id" == "1.2" ]] && { opts="[r] Try again   [i] Other IP address or user   [h] Help   [q] Quit"; allowed2="rihq"; }
    ask_choice "$opts" "$allowed2"
    case "$ANSWER" in
      s) NOW=$ferr; warn "Skipped after an error."; record "$id" FAILED_SKIPPED; [[ "$id" == 1.* ]] || AUTO_WAIT["step $id"]=1; return 0 ;;
      # (the step failed, then you quit: it is recorded as failed, with its error, not as "stopped here")
      q) NOW=$ferr; record "$id" FAILED; user_stop "Stopped by you" ;;
      h) show_help "$id" || true; continue ;;
      i) reenter_primary; UI_RETRY=1; continue ;;
      *) UI_RETRY=1; continue ;;
    esac
  done
}

VERBOSE=${DG_VERBOSE:-0}       # 1 (--verbose): the end summary lists every step (else a fully OK phase is one line)
step_good() { case "$1" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|NOT_ON_RELEASE) return 0 ;; esac; return 1; }
summary_step_line() {
  # one step of the summary: number, result, title, and under a step that is not ok its reason or error
  local id=$1 r=$2
  printf '    %-5s %s%-18s%s %s\n' "$id" "$(result_color "$r")" "$(result_label "$r")" "$C_N" "${STEP_TITLE[$id]}"
  case "$r" in
    OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|NOT_ON_RELEASE|TODO) ;;
    *) [[ -n "${STEP_NOW[$id]:-}" ]] && printf '          %s%s%s\n' "$C_D" "${STEP_NOW[$id]:0:110}" "$C_N" ;;
  esac
}
summary_dg_now() {
  # the state of Data Guard at the end of a run that reached phase 10: only what the steps of this run found
  # (no new query), one line each
  [[ -n "${STEP_RESULT[10.1]:-}${STEP_RESULT[10.4]:-}" ]] || return 0
  local -a ids=(9.2 10.4 9.5 10.1 10.2 10.3 10.8) labels=("Standby" "Redo apply" "Transport" "Lag" "Gap" "Last log" "Archived logs")
  local i id r txt out=""
  for ((i = 0; i < ${#ids[@]}; i++)); do
    id=${ids[$i]}; r=${STEP_RESULT[$id]:-}
    [[ -n "$r" && -n "${STEP_NOW[$id]:-}" ]] || continue
    txt=${STEP_NOW[$id]}; txt=${txt#Done by you. }; txt=${txt#Done. }
    step_good "$r" || txt="$(result_label "$r"): $txt"
    out+="$(printf '    %-14s %s%s%s' "${labels[$i]}" "$(step_good "$r" || printf '%s' "$C_Y")" "${txt:0:100}" "$C_N")"$'\n'
  done
  [[ -n "$out" ]] || return 0
  printf '\n  %sData Guard now%s  %s%s (%s) -> %s (%s), from the checks of this run%s\n%s' "$C_W" "$C_N" "$C_D" \
    "${PRIMARY_UNIQUE:-primary}" "${PRIMARY_HOST:-$PRIMARY_IP}" "${STANDBY_UNIQUE:-standby}" "$(hostname -s 2>/dev/null)" "$C_N" "$out"
}
summary() {
  # $1 (optional): the verdict line of a run that stops here (a failed step); it is printed last, before "Next"
  local verdict=${1:-}
  local id r n_ok=0 n_opt=0 n_done=0 n_skip=0 n_bad=0 n_todo=0 n_wait=0 n_prob=0 n_stop=0
  local t="Summary"
  printf '\n\n  %s%s %s %s%s\n' "$C_B" "$(rule 2 "$S_HR2")" "$t" "$(rule $((66 - ${#t})) "$S_HR2")" "$C_N"
  printf '  %sok = was already correct   done = done by the script   done by you = you did it, the script checked it%s\n\n' "$C_D" "$C_N"
  for id in "${STEP_ORDER[@]}"; do
    r=${STEP_RESULT[$id]:-"NOT_FINISHED"}
    case "$r" in
      OK|NOT_ON_RELEASE) n_ok=$((n_ok + 1)) ;;
      SKIPPED_OPTIONAL) n_opt=$((n_opt + 1)) ;;
      DONE|DONE_BY_YOU) n_done=$((n_done + 1)) ;;
      SKIPPED) n_skip=$((n_skip + 1)) ;;
      TODO) n_todo=$((n_todo + 1)) ;;
      WAITS|RUNNING) n_wait=$((n_wait + 1)) ;;
      PROBLEM) n_prob=$((n_prob + 1)) ;;
      NOT_FINISHED) n_stop=$((n_stop + 1)) ;;
      *) n_bad=$((n_bad + 1)) ;;
    esac
    _log SUM "$id $r ${STEP_TITLE[$id]}"
  done
  if [[ $VERBOSE -eq 1 ]]; then
    # every step (--verbose)
    for id in "${STEP_ORDER[@]}"; do summary_step_line "$id" "${STEP_RESULT[$id]:-NOT_FINISHED}"; done
  else
    # one line per phase; under it only the steps that need a look. A phase where every step is fine is one line.
    local p seen=" " g n nd ws wl
    for id in "${STEP_ORDER[@]}"; do
      p=${id%%.*}; [[ "$seen" == *" $p "* ]] && continue; seen+="$p "
      g=0; n=0; nd=0; ws=0; wl=""
      local sid
      for sid in "${STEP_ORDER[@]}"; do
        [[ "${sid%%.*}" == "$p" ]] || continue
        r=${STEP_RESULT[$sid]:-NOT_FINISHED}; n=$((n + 1))
        step_good "$r" && g=$((g + 1))
        [[ "$r" == DONE || "$r" == DONE_BY_YOU ]] && nd=$((nd + 1))
      done
      if [[ $g -eq $n ]]; then
        printf '    Phase %-3s %-38s %s%s/%s ok%s%s\n' "$p" "${PHASE_TITLES[$p]:-}" "$C_G" "$g" "$n" "$C_N" "$([[ $nd -gt 0 ]] && printf '  (%s done in this run)' "$nd")"
        continue
      fi
      printf '    Phase %-3s %-38s %s/%s ok\n' "$p" "${PHASE_TITLES[$p]:-}" "$g" "$n"
      for sid in "${STEP_ORDER[@]}"; do
        [[ "${sid%%.*}" == "$p" ]] || continue
        r=${STEP_RESULT[$sid]:-NOT_FINISHED}
        step_good "$r" && continue
        # check mode: the steps that wait were each shown above; here they are only named
        if [[ "$MODE" == "check" && "$r" == WAITS ]]; then ws=$((ws + 1)); wl+=" $sid"; continue; fi
        summary_step_line "$sid" "$r"
      done
      [[ $ws -gt 0 ]] && printf '          %s%s waiting (shown above):%s%s\n' "$C_D" "$ws" "$wl" "$C_N"
    done
  fi
  local el=$(( $(date +%s) - RUN_START ))
  printf '\n'
  if [[ "$MODE" == "check" ]]; then
    printf '  %s ok, %s to do, %s waiting, %s problems, %s warnings\n' "$n_ok" "$n_todo" "$n_wait" "$((n_prob + n_bad))" "$WARN_COUNT"
    printf '  %sCheck mode changes nothing in Oracle, the OS or the primary, so on a new server most steps are "to do" or "waiting". That is normal.\n' "$C_D"
    printf '  Only "problem" steps need your attention: see the Fix lines above.%s\n' "$C_N"
  else
    printf '  %s already ok, %s done in this run, %s skipped, %s not ok%s, %s warnings%s\n' \
      "$n_ok" "$n_done" "$((n_skip + n_opt))" "$((n_bad + n_todo + n_wait + n_prob))" "$([[ $n_stop -gt 0 ]] && printf ', %s stopped here' "$n_stop")" "$WARN_COUNT" \
      "$( [[ $el -ge 60 ]] && printf '   (run time %s)' "$(ui_dur "$el")")"
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
  # what the start-at-boot unit reported at this boot: shown in every summary (also when 9.7 did not run now)
  # (not again when step 9.7 ran in this run: it showed them)
  local be=""; [[ ${BOOT_ERR_SHOWN:-0} -eq 1 ]] || be=$(boot_errors_now 2>/dev/null)
  [[ -n "$be" ]] && printf '\n  %sAt this boot, the start-at-boot unit reported:%s\n%s\n  To see it all:  journalctl -p err -u %s\n' "$C_Y" "$C_N" "$(sed 's/^/    /' <<< "$be")" "$(unit_name)"
  summary_dg_now
  # the footer, once: at a stop the stop itself (fatal) prints the log and what the script did on the primary
  printf '\n'
  [[ ${FATAL_SEEN:-0} -eq 1 ]] || printf '  Log:               %s\n' "$LOG_FILE"
  [[ -s "$ACTIONS_FILE" ]] && printf '  Commands for you:  %s\n' "$ACTIONS_FILE"
  [[ ${FATAL_SEEN:-0} -eq 1 ]] || printf '  %s\n' "$(primary_note)"
  [[ -n "$verdict" ]] && printf '\n  %s%s %s%s\n' "$C_R" "$S_BAD" "$verdict" "$C_N"
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
  # (grep: 0 or 1 = written, with or without lines; 2 = it could not read or write: the old file stays)
  local gr=0
  { grep -v "^$1|" "$f" 2>/dev/null || gr=$?; printf '%s|%s|%s\n' "$1" "${u:--}" "$how" && [[ $gr -le 1 || ! -e "$f" ]]; } > "$f.n" 2>/dev/null && mv -f -- "$f.n" "$f"; chmod 600 "$f" 2>/dev/null
  return 0
}
primary_pending_get() { [[ -n "$STATE_DIR" ]] || return 0; grep -m1 "^$1|" "$(primary_pending_file)" 2>/dev/null | cut -d'|' -f2; return 0; }
primary_pending_how() { [[ -n "$STATE_DIR" ]] || return 0; grep -m1 "^$1|" "$(primary_pending_file)" 2>/dev/null | cut -d'|' -f3; return 0; }
primary_pending_del() {
  [[ "$MODE" == "run" ]] || return 0
  local f; f=$(primary_pending_file); [[ -f "$f" ]] || return 0
  local gr=0; grep -v "^$1|" "$f" > "$f.n" 2>/dev/null || gr=$?
  if [[ $gr -le 1 ]]; then mv -f -- "$f.n" "$f"; else rm -f -- "$f.n"; fi
  return 0
}
batch_primary_steps() {
  # $@ step ids of kind primary that follow each other. Their checks are run first (read-only) and every
  # plan is printed in ONE box, so the admin goes to the primary once. Then the steps run as usual: the
  # ones that were done pass at once, the others ask again one by one.
  [[ "$MODE" == "run" ]] || return 0
  # the script may run them itself (PRIMARY_RUN=yes): one step at a time, each with its own [y] question
  if [[ "${PRIMARY_RUN:-no}" == yes ]]; then say "${C_D}PRIMARY_RUN=yes: each primary step offers to run its commands over ssh (only the allowed statements).${C_N}"; return 0; fi
  local id cf rc all="" restart="" n=0 how="" BATCH_ERR
  # file changes (tnsnames.ora, listener.ora, .bash_profile) are shell commands: a second box per user
  local -a fhow=() fplan=() fstep=()
  # the connection is opened visibly first: the checks below run quietly
  need_ssh || return 0
  BATCH_ERR=$(mktemp /tmp/dg_batch.XXXXXX) && CLEANUP_FILES+=("$BATCH_ERR") || BATCH_ERR=/dev/null
  exec {BATCH_TTY}>&1      # a stop inside a quiet check (Ctrl+C, safety stop) still reaches the screen (fatal)
  local in41=0 in47=0 inedit=0 wbefore=${#WARN_LIST[@]}
  for id in "$@"; do
    step_in_range "$id" || continue
    cf="c_${id//./_}"; declare -F "$cf" >/dev/null || continue
    # a lost connection is opened again here, on the screen (the checks below run quietly)
    need_ssh || break
    NOW=""; PLAN=""; PLAN_UNDO=""; USING=""; KIND_NOW=""; PRIMARY_HOW_STEP=""; NEED_SYS=0; CHECK_WAITS=0; CUR_STEP=$id
    "$cf" >/dev/null 2>"$BATCH_ERR"; rc=$?
    [[ -s "$BATCH_ERR" && "$BATCH_ERR" != /dev/null ]] && log_block "quiet check $id (stderr)" < "$BATCH_ERR"
    [[ $rc -eq 1 && -n "$PLAN" && "${KIND_NOW:-primary}" == "primary" ]] || continue
    # (only a plan that is really for the primary and not shown here may be a hand edit that follows on its own)
    [[ "$id" == "4.9" || "$id" == "4.10" ]] && inedit=1
    primary_pending_add "$id" "$PLAN_UNDO"
    # file changes in a shell, not SQL, grouped by the user; only plans that are commands (an entry to edit by
    # hand follows on its own)
    if [[ " 4.9 4.11 " == *" $id "* ]]; then
      [[ "$PLAN" == *"cat >>"* ]] || { primary_pending_del "$id"; continue; }
      n=$((n + 1)); fhow+=("${PRIMARY_HOW_STEP%%  ->  *}  ->  shell"); fstep+=("$id")
      # comment lines of a plan are shell comments in this box
      fplan+=("# Step $id: ${STEP_TITLE_HINT[$id]:-}"$'\n'"$(sed 's/^-- /# /' <<< "$PLAN")"$'\n'"${PLAN_UNDO:+# Undo, if ever needed: $PLAN_UNDO}")
      continue
    fi
    [[ "$id" == "4.1" ]] && in41=1; [[ "$id" == "4.7" ]] && in47=1
    n=$((n + 1))
    [[ -n "$how" ]] || how=${PRIMARY_HOW_STEP:-$PRIMARY_HOW}
    # a restart of the primary (the "-- DOWNTIME" part of a plan) goes into its own box, after the online changes
    local on=$PLAN down=""
    if grep -q '^-- DOWNTIME' <<< "$PLAN"; then
      on=$(sed '/^-- DOWNTIME/,$d' <<< "$PLAN"); down=$(sed -n '/^-- DOWNTIME/,$p' <<< "$PLAN")
      restart+="-- Step $id: ${STEP_TITLE_HINT[$id]:-}"$'\n'"$down"$'\n\n'
    fi
    grep -q '[^[:space:]]' <<< "$(grep -v '^--' <<< "$on")" \
      && all+="-- Step $id: ${STEP_TITLE_HINT[$id]:-}"$'\n'"$on"$'\n'"${PLAN_UNDO:+-- Undo, if ever needed: $PLAN_UNDO}"$'\n\n'
  done
  CUR_STEP=""
  exec {BATCH_TTY}>&-; BATCH_TTY=""
  # shell commands for the primary of steps outside this batch (PRIMARY_BATCH_EXTRA): in the same visit
  local ex xs xu xc
  for ex in ${PRIMARY_BATCH_EXTRA[@]+"${PRIMARY_BATCH_EXTRA[@]}"}; do
    xs=${ex%%|*}; ex=${ex#*|}; xu=${ex%%|*}; xc=${ex#*|}
    [[ "$xs" =~ ^[0-9]+\.[0-9]+$ && -n "$xu" && -n "$xc" ]] || continue
    n=$((n + 1)); fhow+=("$xu  ->  shell"); fstep+=("$xs")
    fplan+=("# Step $xs: ${STEP_TITLE_HINT[$xs]:-$(step_title_of "$xs" 2>/dev/null)}"$'\n'"$(sed 's/^-- /# /' <<< "$xc")")
  done
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
  if [[ -n "$restart" ]] || grep -q '^shutdown immediate' <<< "$all"; then
    printf '\n    %s%s Step 4.1 restarts the primary database: its own box (DOWNTIME), after the online changes.%s\n' "$C_Y" "$S_WARN" "$C_N"
    printf '      %sRun it in your change window, or choose [o] and run the steps one at a time.%s\n\n' "$C_Y" "$C_N"
  fi
  CUR_STEP="${1%%.*}.x"
  if [[ -n "$all" ]]; then
    say "The first two lines start SQL*Plus; the rest runs inside SQL*Plus (a line marked SHELL runs in a shell)."
    printf '%s' "${all%$'\n\n'}" | print_commands "Run on the PRIMARY ($PRIMARY_HOST)" "$how"
  fi
  # the shell commands (file changes, and the extra entries), one box per user on the primary: root first, then
  # the others in the order they first appear; inside a box the steps in step order
  local fi2 fj u done_u=" " ord="" k
  for ((fi2 = 0; fi2 < ${#fhow[@]}; fi2++)); do ord+="$(step_num "${fstep[$fi2]}") $fi2"$'\n'; done
  local -a fidx=(); [[ -n "$ord" ]] && mapfile -t fidx < <(sort -n -k1,1 -s <<< "${ord%$'\n'}" | cut -d' ' -f2)
  local -a users=()
  for k in ${fidx[@]+"${fidx[@]}"}; do [[ "${fhow[$k]}" == "root  ->  shell" ]] && { users=("root  ->  shell"); break; }; done
  [[ ${#users[@]} -gt 0 ]] && done_u="|${users[0]}|"
  for k in ${fidx[@]+"${fidx[@]}"}; do u=${fhow[$k]}; [[ "$done_u" == *"|$u|"* ]] || { users+=("$u"); done_u+="|$u|"; }; done
  for u in ${users[@]+"${users[@]}"}; do
    local fb=""
    for fj in ${fidx[@]+"${fidx[@]}"}; do [[ "${fhow[$fj]}" == "$u" ]] && fb+="${fplan[$fj]}"$'\n\n'; done
    printf '%s' "${fb%$'\n\n'}" | print_commands "$([[ -n "$all" ]] && printf 'Then, in')$([[ -z "$all" ]] && printf 'In') a shell on the PRIMARY ($PRIMARY_HOST)" "$u"
  done
  # the restart of the primary last, in its own box: a change window can be planned for it alone
  [[ -n "$restart" ]] && printf '%s' "${restart%$'\n\n'}" | print_commands "DOWNTIME: restart of the PRIMARY ($PRIMARY_HOST), in your change window" "${how:-$PRIMARY_HOW}"
  [[ $inedit -eq 1 ]] && say "Edits of a file by hand (the static listener entry of 4.10, a changed alias in 4.9), if needed, follow on their own."
  CUR_STEP=""
  say "Afterwards the script checks every step again."
  PRIMARY_BOX_NOTE=1; say "${C_D}The same commands are saved in $ACTIONS_FILE${C_N}"
  if [[ $in41 -eq 1 && $in47 -eq 1 ]]; then
    if grep -q 'create spfile from memory' <<< "$all"; then say "Run step 4.1 first, with its restart. The scope=spfile lines of the other steps need the spfile."
    else say "Steps 4.1 and 4.7 both need a restart of the primary. Run the 4.7 line before the shutdown of 4.1: then one restart covers both."; fi
  fi
  ask_choice "[r] Done, check all steps   [o] Show the steps one at a time   [q] Quit" "roq"
  case "$ANSWER" in
    q) [[ $PHASE4_FIRST -eq 0 && -z "$ONLY_PHASE" && -z "$TO_STEP" ]] && RESUME_STEP=$1; user_stop "Stopped by you" ;;
  esac
  return 0
}
declare -A STEP_TITLE_HINT=()
# Hook: shell commands for the primary from a step outside phase 4, shown in the combined phase-4 block, so the DBA
# goes to the primary once. One entry per step and user:  PRIMARY_BATCH_EXTRA+=("2.7|root|<commands>")
# (commands: shell lines, "-- " or "# " comments; they are printed at column 0 in the box of that user). The entry
# only prints the commands: the step that added it checks the result at its own time (and journals it as usual).
declare -a PRIMARY_BATCH_EXTRA=()
LAST_PLAN_UNDO=""
