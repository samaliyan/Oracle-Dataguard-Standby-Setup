#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
CLI_IP=""; CLI_USER=""

usage() {
  cat <<EOF
dg_standby_setup.sh, version $SCRIPT_VERSION: builds an Oracle Data Guard physical standby (12.1 to 23ai)

Run it as root on the new standby server (Oracle Linux 7, 8 or 9).
It never changes the primary on its own. What the primary needs is shown for you to run
(with PRIMARY_RUN=yes in the settings, it may run listed Data Guard statements there, step by step,
after you answer y: never a restart, a stop or a deletion).
Storage in ASM or in folders, Grid with its own user or not: all are supported.

Run with no option to see all of this as a menu (the same items, the same code).

Setup
  (no option)          Full setup, or continue where the last run stopped
                         dg_standby_setup.sh
  --check              Check and report only; changes nothing (also prints the summary screen)
                         dg_standby_setup.sh --check
  --only <part>        A part only: os, grid, db, primary, a phase, or steps; it stops after them
                         dg_standby_setup.sh --only 2.1-2.4
  --from <step>        Continue from a step (phase 1 always runs first)
                         dg_standby_setup.sh --from 7.2
  --yes                Answer y for the actions on this server (risky ones are still asked;
                       a at any step question does the same from there)
                         dg_standby_setup.sh --yes
  --primary <ip>       The primary (IP address or host name)
                         dg_standby_setup.sh --primary 10.0.0.5
  --user <name>        OS user for ssh on the primary (default oracle)
                         dg_standby_setup.sh --user oracle
  --plain              Plain scrolling output instead of the screen layout
                         dg_standby_setup.sh --plain
  --verbose            Every step in full, with each read-only query or command it runs and its
                       answer ("· query  ->  answer"); the end summary lists every step.
                       With --health: the queries of each check under its line.
                         dg_standby_setup.sh --verbose      dg_standby_setup.sh --health --verbose
After setup
  --only 10            Health check, with the screen and questions
                         dg_standby_setup.sh --only 10
  --health             Health check for cron or monitoring: no questions, no changes; exit 0 OK,
                       1 WARNING, 2 CRITICAL, 3 UNKNOWN (needs an ssh key: --help-step health)
                         dg_standby_setup.sh --health
  --roll-forward       Bring a standby that cannot catch up up to date from the primary (18c+)
                         dg_standby_setup.sh --roll-forward
Information
  --status             The result of every phase and step (no connection to the primary)
                         dg_standby_setup.sh --status
  --show-changes [N.M] Changes made by the setup, and how to undo them
                         dg_standby_setup.sh --show-changes 6.1
  --undo N.M           Undo the changes of one step (asks before each one)
                         dg_standby_setup.sh --undo 6.1
  --help-step N.M      How to do a step by hand ("all" for every step)
                         dg_standby_setup.sh --help-step 9.2
  --settings           The summary screen and the values of the setup, then stop
                         dg_standby_setup.sh --settings

How it works
  After phase 1 a summary screen shows what was found, where the standby goes, the plan, the
  problems found now and the values of this run (a number changes one; Enter starts).
  Each step shows what it found and the exact commands it will run ("Will run"), then asks:
    [y] Yes, do it   [a] Yes to all   [s] Skip   [h] Help   [q] Quit
  Commands for the primary are only shown. You run them there, answer r,
  and the script checks the result.
  The screen: the top shows every phase with its steps done, the rest shows the current step.
  At any question, l lists every step (a step number shows its details), d shows the details
  of the current step and h its help. In a terminal smaller than 80 x 24 the output scrolls.
  Installers, root scripts and the RMAN copy run in their own session. A closed terminal
  does not stop them. Run the script again and it waits for them.

Few questions, not unattended
  Run --check first, put the installer zips in place (step 3.1 shows where), then run with --yes.
  The steps on this server then run without the [y] question. Still needed from a person:
    - the commands on the primary (shown; with PRIMARY_RUN=yes the listed ones may be run over ssh
      when you answer y), and r when they are done
    - the ssh and sys passwords (typed, never saved), and the host key of the primary
    - erasing disks, moving leftovers aside, the RMAN copy (the word DUPLICATE) and the restart steps
  The setup is not meant to run without a person. Only --health is (for example from cron).

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
  Logs       $LOG_DIR/run_<date>.log  (--health: health_<date>.log, kept 14 days)
             actions_<date>.txt: the commands shown for you
             commands_<step>_<date>.txt: a long "Will run" list, as a script you can run
             duplicate_<date>.rman and .log, installer and root script output
  Editor     The settings open in \$EDITOR (default vi).

Exit codes
  0  Every step is OK
  1  Stopped by you, or some steps are not OK or skipped (normal for --check on a new server)
  2  Wrong option or unknown step
  4  A step failed and the run cannot go on (the last lines name the step, its error and what to do)
  With --health:  0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (could not check, or a wrong option)

Run with no option to see all of this as a menu.
EOF
}

valid_step() { local i; for i in "${HELP_IDS[@]}"; do [[ "$i" == "$1" ]] && return 0; done; return 1; }

parse_only() {
  # $1: a phase (1-10), a named part (os grid db primary), or steps "A-B" / "A" (A, B: N or N.M).
  # Sets ONLY_PHASE, or FROM_STEP and TO_STEP (a range). 1 = not valid (nothing is changed then).
  local v=${1,,} a b
  case "$v" in
    os) v=2 ;; primary) v=4 ;; grid) v=3.1-3.5 ;; db) v=3.6-3.11 ;;
  esac
  if [[ "$v" =~ ^([1-9]|10)$ ]]; then ONLY_PHASE=$v; FROM_STEP=""; TO_STEP=""; TO_TEXT=""; ONLY_TEXT=${1,,}; return 0; fi
  local re='^(([1-9]|10)(\.[0-9]{1,2})?)(-(([1-9]|10)(\.[0-9]{1,2})?))?$'
  [[ "$v" =~ $re ]] || return 1
  a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[5]:-${BASH_REMATCH[1]}}
  if [[ "$a" == *.* ]]; then valid_step "$a" || return 1; else a="$a.0"; fi
  local bt=$b
  if [[ "$b" == *.* ]]; then valid_step "$b" || return 1; else b="$b.99"; fi
  [[ $(step_num "$a") -le $(step_num "$b") ]] || return 1
  ONLY_PHASE=""; FROM_STEP=$a; TO_STEP=$b; TO_TEXT=$bt; ONLY_TEXT=${1,,}
  return 0
}
names_on_demand() { on_demand "${1%%-*}" || on_demand "${1#*-}"; }     # "10.7" or a range that starts or ends there
on_demand_inside() {
  # the steps that run only on demand (10.7) inside the range parse_only set (FROM_STEP-TO_STEP): they are left out
  local s; [[ -n "$TO_STEP" && -n "$FROM_STEP" ]] || return 1
  for s in $ON_DEMAND_STEPS; do
    (( $(step_num "$s") >= $(step_num "$FROM_STEP") && $(step_num "$s") <= $(step_num "$TO_STEP") )) && printf '%s ' "$s"
  done
  return 0
}
range_text() {
  # the range of this run in words, for example "steps 2.1 to 2.4", "phase 3", "step 3.6"
  local a=${FROM_STEP%.0} b=$TO_TEXT
  if [[ "$a" == "$b" ]]; then range_word "$a"
  elif [[ "$a" == *.* && "$b" == *.* ]]; then printf 'steps %s to %s' "$a" "$b"
  else printf '%s to %s' "$(range_word "$a")" "$(range_word "$b")"; fi
}
range_word() { [[ "$1" == *.* ]] && printf 'step %s' "$1" || printf 'phase %s' "$1"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --primary) [[ $# -ge 2 ]] && valid_value ip "$2" || { printf 'Missing or invalid value for --primary\n'; exit $PX; }; CLI_IP=$2; shift ;;
      --user) [[ $# -ge 2 ]] && valid_value name "$2" && [[ "$2" != "root" ]] || { printf 'Missing or invalid value for --user. Give the Oracle software owner, not root.\n'; exit $PX; }; CLI_USER=$2; shift ;;
      --check) MODE="check" ;;
      --health) HEALTH=1 ;;
      --roll-forward) ROLL_FORWARD=1 ;;
      --settings) REVIEW_SETTINGS=1 ;;
      --status) STATUS_ONLY=1 ;;
      --yes) YES_MODE=1 ;;
      --plain) PLAIN_OPT=1 ;;
      --verbose) VERBOSE=1 ;;
      --show-changes) SHOW_CHANGES=all
        if [[ $# -ge 2 && "$2" != -* ]]; then
          valid_step "$2" || { printf 'There is no step %s. Use --show-changes, or --show-changes N.M (to list the steps:  --help-step all)\n' "$2"; exit $PX; }
          SHOW_CHANGES=$2; shift
        fi ;;
      --undo) [[ $# -ge 2 ]] && valid_step "$2" || { printf 'Use --undo N.M with a step number. To list the steps:  --help-step all\n'; exit $PX; }; UNDO_STEP=$2; shift ;;
      --from)
        [[ $# -ge 2 && "$2" =~ ^([1-9]|10)(\.[0-9]{1,2})?$ ]] || { printf 'Use --from N or --from N.M, for example --from 6.1\n'; exit $PX; }
        FROM_STEP=$2; FROM_SEEN=1
        [[ "$FROM_STEP" == *.0 ]] && FROM_STEP=${FROM_STEP%.0}     # N.0 is the same as N (the start of phase N)
        if [[ "$FROM_STEP" == *.* ]]; then valid_step "$FROM_STEP" || { printf 'There is no step %s. To list the steps:  --help-step all\n' "$FROM_STEP"; exit $PX; }
          on_demand "$FROM_STEP" && { printf 'Step %s runs only with --roll-forward (without --from or --only).\n' "$FROM_STEP"; exit $PX; }
        else FROM_STEP="$FROM_STEP.0"; fi
        shift ;;
      --only) [[ $# -ge 2 ]] && parse_only "$2" || { printf 'Use --only with a phase (1 to 10), os, grid, db, primary, or steps such as 2.1-2.4\n'; exit $PX; }
              names_on_demand "$2" && { printf 'Step 10.7 runs only with --roll-forward (without --from or --only).\n'; exit $PX; }
              [[ -n "$(on_demand_inside)" ]] && printf 'Note: step 10.7 is left out of this range. It runs only with --roll-forward.\n'
              shift ;;
      --help-step) [[ $# -ge 2 ]] || { printf 'Use --help-step N.M, or --help-step all\n'; exit $PX; }; HELP_STEP=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'Unknown option: %s\n\n' "$1"; usage; exit $PX ;;
    esac
    shift
  done
  [[ -n "$ONLY_TEXT" && -n "$FROM_SEEN" ]] && { printf 'Use either --from or --only, not both.\n'; exit $PX; }
  # --roll-forward: phase 1 (connection, settings, sys password), then step 10.7 and the checks of phase 10
  if [[ $ROLL_FORWARD -eq 1 ]]; then
    if [[ "$MODE" == "check" || $STATUS_ONLY -eq 1 || -n "$SHOW_CHANGES" || -n "$FROM_STEP" || -n "$ONLY_TEXT" || -n "$UNDO_STEP" || $REVIEW_SETTINGS -eq 1 || $YES_MODE -eq 1 || $HEALTH -eq 1 ]]; then
      printf '%s\n' '--roll-forward cannot be combined with --check, --yes, --only, --from, --undo, --settings, --status, --show-changes or --health.'; exit $PX
    fi
    parse_only 10 || exit $PX
  fi
  # --health is a whole mode of its own (exit 3 = "unknown" for a monitoring system, never 2 = "critical")
  if [[ $HEALTH -eq 1 && ( "$MODE" == "check" || $STATUS_ONLY -eq 1 || -n "$SHOW_CHANGES" || -n "$FROM_STEP" || -n "$ONLY_TEXT" || -n "$UNDO_STEP" || $REVIEW_SETTINGS -eq 1 || $YES_MODE -eq 1 || -n "$CLI_IP" || -n "$CLI_USER" || -n "$HELP_STEP" || ${ROLL_FORWARD:-0} -eq 1 ) ]]; then
    printf '%s\n' '--health cannot be combined with other options.'; exit 3
  fi
  if [[ -n "$UNDO_STEP" && ( "$MODE" == "check" || $STATUS_ONLY -eq 1 || -n "$SHOW_CHANGES" || -n "$FROM_STEP" || -n "$ONLY_PHASE" || $REVIEW_SETTINGS -eq 1 ) ]]; then
    printf '%s\n' '--undo cannot be combined with other options. To see first what it would do:  --show-changes STEP'; exit $PX
  fi
  # --settings alone: review the settings and stop (phase 1 only)
  [[ $REVIEW_SETTINGS -eq 1 && -z "$FROM_STEP" && -z "$ONLY_PHASE" ]] && ONLY_PHASE=1
  return 0
}
STATUS_ONLY=0; SHOW_CHANGES=""; UNDO_STEP=""; FROM_SEEN=""; ROLL_FORWARD=0; PX=2

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
    ask_value "IP address or host name of the primary [$PRIMARY_IP]"
    ip=${ANSWER:-$PRIMARY_IP}
    valid_value ip "$ip" && [[ "$ip" != "h" ]] && break
    say "This is not a valid IP address or host name."
  done
  while true; do
    ask_value "OS user for ssh on the primary, the owner of the database [$PRIMARY_SSH_USER]"
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

run_undo() {
  # --undo STEP (or the menu): undo the changes of one step, then stop
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
}

menu_next() {
  # for the menu: where a full run goes on (the first step after phase 1 that is not done)
  local i
  [[ -s "$PROGRESS_FILE" ]] || { printf 'start'; return 0; }
  for i in "${HELP_IDS[@]}"; do
    [[ "$i" == 1.* ]] && continue
    is_optional "$i" && continue
    on_demand "$i" && continue
    case "${LAST_RESULT[$i]:-}" in OK|DONE|DONE_BY_YOU|NOT_ON_RELEASE) ;; *) printf 'next: %s' "$i"; return 0 ;; esac
  done
  printf 'all done'
}
menu_line() { printf '  %3s) %-44s %s%s%s\n' "$1" "$2" "$C_D" "$3" "$C_N"; }
menu_records() {
  # menu item 12: the changes made, undo (and the status, as before)
  local st
  ask_choice "[c] Changes made, with undo commands   [u] Undo a step   [s] Status of every step   [b] Back   [q] Quit" "scubq"
  case "$ANSWER" in
    q) menu_quit ;;
    s) print_progress_board ;;
    c) if [[ -s "$JOURNAL_FILE" ]]; then show_changes_cli ""; else say "No changes are recorded on this server."; fi ;;
    u) while true; do
         ask "Step to undo, for example 2.9 (Enter = back)"
         st=${ANSWER//[[:space:]]/}
         [[ -z "$st" || "${st,,}" == b ]] && return 0
         [[ "${st,,}" == q ]] && menu_quit
         valid_step "$st" && break
         say "There is no step $st. To list the steps:  $SELF --help-step all"
       done
       if [[ -z "$(journal_entries "$st")" ]]; then say "No change of step $st is recorded, so there is nothing to undo."; return 0; fi
       say "First, what it would undo:"
       show_changes_cli "$st"
       confirm "Undo the changes of step $st now? Each change is asked again before it is undone." || return 0
       # from here changes are made: Ctrl+C is a stop in the middle (fatal), not a quit at the menu
       trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT
       UNDO_STEP=$st; run_undo ;;
  esac
  return 0
}
menu_quit() { _log STOP "quit at the start menu"; printf '\n'; exit 0; }
start_menu() {
  # shown when the script is run without options: one grouped menu. Next to each item, in grey, the switch that does
  # the same from the command line (for scripts and cron). Every item reaches the same code as its switch.
  local c st mn def=1
  # Ctrl+C here only leaves the menu: nothing has started, the record of the last run stays as it is
  trap 'printf "\n"; menu_quit' INT
  while true; do
    load_progress
    # a finished standby: the daily check is the usual choice (Enter), a full setup is a check of every step again
    mn=$(menu_next); def=1; [[ "$mn" == "all done" ]] && def=9
    printf '\n  %sWhat do you want to do?%s\n' "$C_W" "$C_N"
    printf '\n  %sSetup%s\n' "$C_B" "$C_N"
    if [[ $def -eq 9 ]]; then menu_line 1 "Full setup again (all done; checks every step)" "(no option)"
    else menu_line 1 "Full setup ($mn)" "(no option)"; fi
    menu_line 2 "Check only, change nothing" "--check"
    menu_line 3 "OS preparation only (phase 2)" "--only os"
    menu_line 4 "Grid Infrastructure and ASM only" "--only grid"
    menu_line 5 "Database software only" "--only db"
    menu_line 6 "Primary changes for the DBA (phase 4)" "--only primary"
    menu_line 7 "Choose steps" "--only 2.1-2.4"
    menu_line 8 "Start from a step" "--from 7.2"
    printf '\n  %sAfter setup%s\n' "$C_B" "$C_N"
    menu_line 9 "Health check" "--only 10   (cron: --health)"
    menu_line 10 "Roll forward the standby from the primary" "--roll-forward"
    printf '\n  %sInformation%s\n' "$C_B" "$C_N"
    menu_line 11 "Status of every step" "--status"
    menu_line 12 "Changes made, and undo" "--show-changes, --undo N.M"
    menu_line 13 "The manual way of a step" "--help-step N.M"
    menu_line 14 "Settings" "--settings"
    printf '\n   q) Quit\n\n'
    CUR_STEP=""
    ask "Choice [$def]"
    c=${ANSWER//[[:space:]]/}; c=${c,,}; [[ -z "$c" ]] && c=$def
    case "$c" in
      1) break ;;
      2) MODE=check; break ;;
      3) parse_only os; break ;;
      4) parse_only grid; break ;;
      5) parse_only db; break ;;
      6) parse_only primary; break ;;
      7) while true; do
           ask "Steps to run, for example 2.1-2.4, 3.6 or 2-3 (Enter = back)"
           ANSWER=${ANSWER//[[:space:]]/}
           [[ -z "$ANSWER" || "${ANSWER,,}" == b ]] && continue 2
           [[ "${ANSWER,,}" == q ]] && menu_quit
           if parse_only "$ANSWER"; then
             # 10.7 runs only on demand (as --only): named, it would run nothing and report OK
             if names_on_demand "$ANSWER"; then FROM_STEP=""; TO_STEP=""; TO_TEXT=""; ONLY_PHASE=""; ONLY_TEXT=""; say "Step 10.7 runs only with --roll-forward (menu item 10)."; continue; fi
             [[ -n "$(on_demand_inside)" ]] && say "Step 10.7 is left out of this range. It runs only with --roll-forward (menu item 10)."
             break
           fi
           say "This is not a step or a range of steps. Examples:  2.1-2.4   3.6-3.11   5"
         done
         break ;;
      8) while true; do
           ask "Start from which step, for example 7.2 or 9 (Enter = back)"
           st=${ANSWER//[[:space:]]/}
           [[ -z "$st" || "${st,,}" == b ]] && continue 2
           [[ "${st,,}" == q ]] && menu_quit
           if [[ "$st" =~ ^([1-9]|10)$ ]]; then FROM_STEP="$st.0"; FROM_SEEN=1; break; fi
           if valid_step "$st" && ! on_demand "$st"; then FROM_STEP=$st; FROM_SEEN=1; break; fi
           if valid_step "$st"; then say "Step $st runs only with --roll-forward (menu item 10)."; continue; fi
           say "There is no step $st. To list the steps:  $SELF --help-step all"
         done
         break ;;
      9) parse_only 10; break ;;
      10) ROLL_FORWARD=1; parse_only 10; break ;;
      11) print_progress_board; printf '\n  %sEvery step%s\n' "$C_B" "$C_N"; ui_list_text 100 ;;
      12) menu_records ;;
      13) while true; do
            ask "Which step, for example 9.2 (Enter = back)"
            st=${ANSWER//[[:space:]]/}
            [[ -z "$st" || "${st,,}" == b ]] && continue 2
            [[ "${st,,}" == q ]] && menu_quit
            { valid_step "$st" || [[ "$st" == all || "$st" == health ]]; } && { help_cli "$st" || true; break; }
            say "There is no step $st. To list the steps:  $SELF --help-step all"
          done ;;
      14) REVIEW_SETTINGS=1; ONLY_PHASE=1; break ;;
      q) menu_quit ;;
      *) say "Please type a number from 1 to 14, or q." ;;
    esac
  done
  _log INFO "menu choice $c${ONLY_TEXT:+ ($ONLY_TEXT)}${FROM_STEP:+ (from $FROM_STEP)}"
  if [[ -n "$TO_STEP" ]]; then say "This run: $(range_text). It stops after it. Phase 1 (the primary) runs first."
  elif [[ -n "$ONLY_PHASE" && $REVIEW_SETTINGS -eq 0 ]]; then say "This run: phase $ONLY_PHASE only. Phase 1 (the primary) runs first."
  elif [[ -n "$FROM_STEP" ]]; then say "This run: from $(range_word "${FROM_STEP%.0}"). Phase 1 (the primary) runs first."; fi
  # (no --yes question here: value 2 "Yes to all" of the summary screen (step 1.4) sets it for this run, and a at
  # any step question does the same from there)
  trap 'printf "\n"; fatal "Interrupted by user (Ctrl+C)"' INT
  return 0
}

run_end() {
  # the EXIT trap: the last line of the run log says how the run ended and how long it took (a log without it was
  # cut off: the server stopped, or the script was killed), then the clean-up as always
  local rc=$1 last="" r
  if [[ -n "$LOG_FILE" && ${RUN_END_LOGGED:-0} -eq 0 ]]; then
    RUN_END_LOGGED=1
    [[ ${#STEP_ORDER[@]} -gt 0 ]] && last=${STEP_ORDER[${#STEP_ORDER[@]}-1]}
    [[ "${CUR_STEP:-}" =~ ^[0-9]+\.[0-9]+$ ]] && last=$CUR_STEP
    if [[ -n "$last" ]]; then r=${STEP_RESULT[$last]:-not finished}; last=", last step $last $r"; fi
    _log END "exit code $rc, run time $(ui_dur $(( $(date +%s) - RUN_START )))$last"
  fi
  cleanup
}
main() {
  # (replaces the plain clean-up trap of the core: the same clean-up, after the END line of the log)
  trap 'run_end $?' EXIT
  [[ $# -eq 0 ]] && MENU_OK=1
  # a wrong command line is exit 2, but 3 (unknown) with --health: 2 means "critical" to a monitoring system
  local a; PX=2; for a in "$@"; do [[ "$a" == "--health" ]] && PX=3; done
  parse_args "$@"
  vq_init
  if [[ -n "$HELP_STEP" ]]; then help_cli "$HELP_STEP"; exit 0; fi
  # a failure to start is "unknown" (3) for --health, as for a monitoring system (fd 7: its output, see health_out)
  local ef=1; [[ $HEALTH -eq 1 ]] && { ef=3; exec 7>&1; }
  [[ $EUID -eq 0 ]] || { printf 'Run this script as root, on the standby server.\n'; exit $ef; }
  cd / || exit $ef
  os_info
  LOG_DIR=$(readlink -m -- "$LOG_DIR"); STATE_DIR=$(readlink -m -- "$STATE_DIR")
  # the folders and files root writes or reads (DG_* in the environment can move them): plain absolute paths only,
  # as they also go into commands and the crontab line
  local pv
  for pv in "$LOG_DIR" "$STATE_DIR" "$SHORT_DIR" "$FSTAB_FILE" "$SHM_UNIT_FILE" "$OS_RELEASE_FILE" "$MEMINFO_FILE" "$SYSTEMD_RUN_DIR"; do
    v_path "$pv" || { printf 'Not a plain absolute path (only letters, digits and _ . / -): %s
Check DG_LOG_DIR, DG_STATE_DIR and the other DG_* paths in the environment.
' "$pv"; exit $ef; }
  done
  { [[ -d "$LOG_DIR" ]] || install -d -m 750 "$LOG_DIR"; } && { [[ -d "$STATE_DIR" ]] || install -d -m 700 "$STATE_DIR"; } || { printf 'Cannot create %s or %s. Is the file system read-only or full?\n' "$LOG_DIR" "$STATE_DIR"; exit $ef; }
  dir_safe "$STATE_DIR" || { printf '%s must belong to root, and others must not be able to write to it.\nIt holds the settings and copies of the password file.\n' "$STATE_DIR"; exit $ef; }
  # it holds settings and password-file copies: only root reads it (only the script's own folder is changed)
  [[ "$(basename "$STATE_DIR")" == dg_standby_setup ]] && chmod 700 "$STATE_DIR" 2>/dev/null
  dir_safe "$LOG_DIR" || { printf '%s must belong to root, and others must not be able to write to it.\nroot writes the logs there.\n' "$LOG_DIR"; exit $ef; }
  SETTINGS_FILE="$STATE_DIR/settings.conf"; ACCEPTED_FILE="$STATE_DIR/settings.accepted"; JOB_FILE="$STATE_DIR/job"
  PROGRESS_FILE="$STATE_DIR/progress"; LASTRUN_FILE="$STATE_DIR/last_run"; JOURNAL_FILE="$STATE_DIR/changes.log"
  [[ $HEALTH -eq 1 ]] && { health_main; exit 3; }
  if [[ $STATUS_ONLY -eq 1 || -n "$SHOW_CHANGES" ]]; then
    # read-only views: no lock, no log, no connection
    init_settings; [[ -f "$SETTINGS_FILE" ]] && load_settings soft >/dev/null 2>&1
    printf '\n  %sOracle Data Guard Standby Setup%s   %sversion %s%s\n' "$C_B" "$C_N" "$C_D" "$SCRIPT_VERSION" "$C_N"
    printf '  %s\n' "$(rule 70)"
    printf '  This server   %s\n' "$(hostname -s 2>/dev/null)"
    [[ -n "$PRIMARY_UNIQUE" ]] && printf '  Primary       %s on %s\n  Standby       %s\n' "$PRIMARY_UNIQUE" "${PRIMARY_HOST:-$PRIMARY_IP}" "${STANDBY_UNIQUE:-?}"
    if [[ $STATUS_ONLY -eq 1 ]]; then
      dg_status_block
      print_progress_board
      printf '\n  %sEvery step%s\n' "$C_W" "$C_N"; ui_list_text 100
      status_runs_block
      [[ -s "$JOURNAL_FILE" ]] && printf '\n  Changes made on this server: %s --show-changes\n' "$SELF"
    fi
    [[ -n "$SHOW_CHANGES" ]] && show_changes_cli "$([[ "$SHOW_CHANGES" == all ]] || printf '%s' "$SHOW_CHANGES")"
    exit 0
  fi
  # every run asks questions: without a terminal (nohup, cron, ssh without -t) it would fail later at a confusing point
  if ! { : < /dev/tty; } 2>/dev/null; then
    printf 'This script asks questions. Run it in an interactive terminal, for example:  ssh -t root@%s\n' "$(hostname -s 2>/dev/null)"
    exit 1
  fi
  # the questions are written to the standard output: sent to a file, they would not be seen and the run would
  # seem to hang (a pipe such as "| tee file" is fine)
  if [[ -f /dev/stdout ]]; then
    printf 'This script asks questions on the screen, so its output cannot go to a file. To keep a copy:  %s ... | tee file\n(The run log in %s holds everything in any case.)\n' "$SELF" "$LOG_DIR" >&2
    exit 1
  fi
  # one run at a time (a second run would take over the ssh connection and the settings)
  exec 9> "$STATE_DIR/lock" || { printf 'Cannot open %s/lock\n' "$STATE_DIR"; exit 1; }
  if ! flock -n 9; then printf 'Another run of this script is active on this server. Wait for it to end, then try again.\n'; exit 1; fi
  LOG_FILE="$LOG_DIR/run_$RUN_ID.log"; : > "$LOG_FILE" && chmod 640 "$LOG_FILE" || { LOG_FILE=""; printf 'Cannot write the log in %s. Is the file system read-only or full?\n' "$LOG_DIR"; exit 1; }
  ACTIONS_FILE="$LOG_DIR/actions_$RUN_ID.txt"; : > "$ACTIONS_FILE" && chmod 640 "$ACTIONS_FILE" || { printf 'Cannot write in %s\n' "$LOG_DIR"; exit 1; }
  [[ -n "$UNDO_STEP" ]] && run_undo

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
  _log START "dg_standby_setup.sh $SCRIPT_VERSION mode=$MODE from=${FROM_STEP:--} only=${ONLY_PHASE:--} to=${TO_STEP:--} pid=$$"
  [[ $FAST_WAITS -eq 1 ]] && _log WARN "DG_TEST_FAST_WAITS=1 is set: every wait is 0.2 seconds (a setting for the test suite)"

  printf '\n  %sOracle Data Guard Standby Setup%s   %sversion %s%s\n' "$C_B" "$C_N" "$C_D" "$SCRIPT_VERSION" "$C_N"
  printf '  %s\n' "$(rule 70)"
  printf '  This server   %s (the new standby)\n' "$(hostname -s 2>/dev/null)"
  printf '  Mode          %s\n' "$([[ "$MODE" == check ]] && printf 'check only (nothing is changed)' || printf 'setup%s' "$([[ $YES_MODE -eq 1 ]] && printf ', --yes: actions on this server without asking')")"
  printf '  Log           %s\n' "$LOG_FILE"
  if [[ "${PRIMARY_RUN:-no}" == yes && "$MODE" == run ]]; then
    # PRIMARY_RUN=yes: say so, the default text below would not be true
    printf '\n  PRIMARY_RUN=yes: on the primary the script may run only listed Data Guard statements\n'
    printf '  (parameters, force logging, standby logs), only after you answer y at that step.\n'
    printf '  Everything else for the primary is shown for you to run; the script then checks it.\n'
  else
    printf '\n  The script never changes the primary itself. When the primary needs a change,\n'
    printf '  the commands are shown for you to run, and the script then checks the result.\n'
  fi
  printf '  %sAt each question: h shows help, q quits.%s\n' "$C_D" "$C_N"
  print_progress_board
  [[ $MENU_OK -eq 1 && "$MODE" == "run" ]] && start_menu
  # the screen layout (a map of the phases on top, the current step below) from here on
  ui_start
  # a long job of an earlier run (installer, root script, RMAN) is waited for before anything else;
  # phase 4 alone works only with the primary and does not need to wait
  if [[ "$ONLY_PHASE" == "4" ]] && job_alive; then
    say "A long job is running: $JOB_TITLE (session $JOB_PID)."
    say "Phase 4 works only with the primary, so it does not wait for the job."
  else
    job_wait_step
  fi

  while [[ -z "$PRIMARY_IP" ]]; do
    ask_value "IP address or host name of the primary"
    [[ "${ANSWER,,}" == "q" ]] && user_stop "Stopped by you"
    valid_value ip "$ANSWER" && [[ "${ANSWER,,}" != "h" ]] && PRIMARY_IP=$ANSWER || say "This is not a valid IP address or host name."
  done
  if [[ $first_run -eq 1 && -z "$CLI_USER" ]]; then
    say "The ssh user must own the database on the primary and be able to run  sqlplus / as sysdba."
    while true; do
      ask_value "OS user for ssh on the primary [oracle]"
      [[ "${ANSWER,,}" == "q" ]] && user_stop "Stopped by you"
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
    if [[ $p -gt 1 && -n "$TO_STEP" && $p -gt ${TO_STEP%%.*} ]]; then continue; fi
    [[ $p -eq 4 && $PHASE4_FIRST -eq 1 ]] && continue      # done right after phase 1
    "phase_$p"
    [[ $p -eq 1 && $PHASE4_FIRST -eq 1 ]] && phase_4
  done
  CUR_STEP=""
  ui_end
  summary
  local id bad_n=0
  for id in "${STEP_ORDER[@]}"; do case "${STEP_RESULT[$id]}" in OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|NOT_ON_RELEASE) ;; *) bad_n=$((bad_n + 1)) ;; esac; done
  write_last_run "$([[ $bad_n -eq 0 ]] && printf 'ended, every step OK' || printf 'ended, %s step(s) not OK' "$bad_n")"
  if [[ "$MODE" == "run" && $bad_n -eq 0 ]]; then
    if [[ -z "$ONLY_PHASE" ]] && [[ -z "$FROM_STEP" || "${FROM_STEP%%.*}" -le 9 ]] && [[ -n "${STEP_RESULT[10.1]:-}" ]]; then
      printf '\n  %sStandby setup is complete.%s\n' "$C_G" "$C_N"
      printf '  Daily check:  %s --health    (from cron; it checks the primary with the key of step 9.9)\n' "$SELF"
      printf '                %s --only 10   (by hand, the same checks with the screen)\n' "$SELF"
      [[ "${STEP_RESULT[9.9]:-}" == OK || "${STEP_RESULT[9.9]:-}" == DONE ]] || \
        printf '  %s--health will not check the primary (no ssh key for it):  %s --only 9.9%s\n' "$C_Y" "$SELF" "$C_N"
      printf '  Keep in mind:\n'
      printf '    - After a sys password change on the primary, copy the password file again:\n        %s --from 6.1\n' "$SELF"
      [[ -n "$TDE_INFO" ]] && printf '    - After a new TDE master key on the primary, copy the wallet again:\n        %s --from 6.3\n' "$SELF"
      if [[ -s "$JOURNAL_FILE" ]] && journal_entries "" "" | awk -F'|' '$5 == "PKG" && $6 ~ /preinstall/' | grep -q .; then
        printf '    - The preinstall package changed kernel settings (transparent huge pages).\n      Plan one reboot of this server.\n'
      fi
    elif [[ "$ONLY_PHASE" == "1" && $REVIEW_SETTINGS -eq 1 ]]; then
      printf '\n  %sSettings reviewed.%s  To continue the setup:  %s\n' "$C_G" "$C_N" "$SELF"
    elif [[ -n "$TO_STEP" ]]; then
      printf '\n  %sDone: %s, every step OK.%s  To run more:  %s\n' "$C_G" "$(range_text)" "$C_N" "$SELF"
    elif [[ -n "$FROM_STEP" ]]; then
      printf '\n  %sAll steps from %s are OK.%s  To check every step once more:  %s --check\n' "$C_G" "${FROM_STEP%.0}" "$C_N" "$SELF"

    else
      printf '\n  %sPhase %s is OK.%s\n' "$C_G" "$ONLY_PHASE" "$C_N"
    fi
  fi
  [[ $bad_n -eq 0 ]]
}

main "$@"
