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
