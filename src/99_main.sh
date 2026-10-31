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
  dg_standby_setup.sh --check              Check and report only; changes nothing in Oracle,
                                           the OS or the primary, and keeps the saved progress
                                           (still asks for the ssh and sys passwords)
  dg_standby_setup.sh --from 6.1           Continue from a step (phase 1 always runs)
  dg_standby_setup.sh --only 10            Run one phase only (10 = daily health check;
                                           phase 1 runs first, so the primary must be reachable)
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
