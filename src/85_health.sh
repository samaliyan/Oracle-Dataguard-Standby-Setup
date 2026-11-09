#------------------------------------------------------------------------------
# --health: the checks of phase 10, unattended (cron, a monitoring agent).
# Never asks, never changes anything, needs no terminal. One line per check on stdout, the details in
# $LOG_DIR/health_<time>.log. Exit code (the convention of Nagios-style monitoring):
#   0 OK   1 WARNING (attention, nothing broken yet)   2 CRITICAL (a problem)   3 UNKNOWN (could not check)
# Worst first: CRITICAL, then UNKNOWN, then WARNING.
#------------------------------------------------------------------------------
HEALTH=0; HEALTH_SSH_OPEN=0; HEALTH_SSH_ERR=""; HEALTH_LOG=""; HEALTH_REPORTED=0
declare -A HEALTH_STATE=(); declare -A HEALTH_TEXT=(); HEALTH_ORDER=()

# fd 7: the real stdout of the run (a check runs with its own output sent to the log; what it must say reaches
# cron through fd 7 even then)
health_out() { printf '%s\n' "$*" >&7; [[ -n "$HEALTH_LOG" ]] && printf '%s\n' "$*" >> "$HEALTH_LOG"; return 0; }

health_exit() {
  # $1 overall state when the run cannot go on (UNKNOWN), $2 the reason; or no arguments: the end of the run
  local worst=OK id st code
  # inside a command substitution (a fatal() deep in a check): only the log; the run itself reports
  if [[ "${BASHPID:-$$}" != "$$" ]]; then [[ -n "${2:-}" && -n "$HEALTH_LOG" ]] && printf 'UNKNOWN: %s\n' "$2" >> "$HEALTH_LOG"; exit 3; fi
  if [[ -n "${1:-}" ]]; then
    [[ $HEALTH_REPORTED -eq 0 && ${#HEALTH_ORDER[@]} -gt 0 ]] && health_report
    # the reason the run stopped: no state label of its own (the Result line below gives the overall state,
    # which a CRITICAL check found before may make worse than UNKNOWN)
    health_out "  Stopped:  $2"
    worst=UNKNOWN
  fi
  for id in "${HEALTH_ORDER[@]+"${HEALTH_ORDER[@]}"}"; do
    st=${HEALTH_STATE[$id]}
    case "$st" in
      CRITICAL) worst=CRITICAL ;;
      UNKNOWN)  [[ "$worst" != CRITICAL ]] && worst=UNKNOWN ;;
      WARNING)  [[ "$worst" == OK ]] && worst=WARNING ;;
    esac      # SKIPPED (a check that does not exist for this release) counts as nothing
  done
  case "$worst" in OK) code=0 ;; WARNING) code=1 ;; CRITICAL) code=2 ;; *) code=3 ;; esac
  health_out "Result: $worst (exit $code)${HEALTH_LOG:+. Details: $HEALTH_LOG}"
  _log STOP "health result $worst"
  exit "$code"
}

health_no_question() {
  # every prompt ends here in --health: nothing in an unattended run may wait for an answer
  health_exit UNKNOWN "A question would be needed (\"$1\"). Run the script in a terminal:  $SELF --only 10"
}

health_ssh() {
  # a connection of its own (never the one of an interactive run), opened only with a key: BatchMode=yes
  # never asks for a password. The same host-key rules as every other connection of the script
  SSH_CTL="$STATE_DIR/ssh_ctl_health"
  [[ -e "$SSH_CTL" ]] && timeout 10 ssh -o ControlPath="$SSH_CTL" -O exit "$PRIMARY_SSH_USER@$PRIMARY_IP" >/dev/null 2>&1
  rm -f -- "$SSH_CTL"
  local elog="$STATE_DIR/ssh_error_health.log"
  : > "$elog"; chmod 600 "$elog"
  if timeout 30 ssh -E "$elog" -o BatchMode=yes -o ControlMaster=yes -o ControlPath="$SSH_CTL" -o ControlPersist=300 \
       -o StrictHostKeyChecking=yes -o CheckHostIP=no -o UserKnownHostsFile="$ROOT_KH $KH_FILE" \
       -o ConnectTimeout=15 -o ServerAliveInterval=30 -fN "$PRIMARY_SSH_USER@$PRIMARY_IP" < /dev/null 9>&- \
     && ssh_alive; then
    HEALTH_SSH_OPEN=1; return 0
  fi
  local el; el=$(tail -n 1 "$elog" 2>/dev/null | tr -cd '[:print:]')
  if [[ "$el" == *"Permission denied"* ]]; then HEALTH_SSH_ERR="ssh to $PRIMARY_SSH_USER@$PRIMARY_IP needs a key for root (no password can be typed here)"
  else HEALTH_SSH_ERR="ssh to $PRIMARY_SSH_USER@$PRIMARY_IP failed${el:+: $el}"; fi
  log_block "ssh error output (health)" < "$elog"
  return 1
}

health_run_check() {
  # $1 step id, $2 title, $3 check function. Called directly (not through run_step: no progress record,
  # no prompt); the same per-check variables as run_step
  local id=$1 title=$2 fn=$3 rc st first
  NOW=""; PLAN=""; USING=""; DONE_MSG=""; QUIET_PLAN=0; PRIMARY_HOW_STEP=""; MANUAL_HOW=""; MANUAL_WHERE=""; KIND_NOW=""; NEED_SYS=0; PLAN_UNDO=""; CHECK_WAITS=0
  CUR_STEP=$id
  { printf '\n==== %s  %s ====\n' "$id" "$title"; } >> "$HEALTH_LOG"
  rc=0; "$fn" >> "$HEALTH_LOG" 2>&1 || rc=$?
  if [[ $rc -eq 0 && $CHECK_WAITS -eq 0 ]]; then st=OK
  elif [[ $rc -eq 0 && $CHECK_WAITS -ge 2 ]]; then st=SKIPPED
  elif [[ $rc -eq 0 ]]; then st=WARNING
  elif [[ $rc -eq 1 ]]; then st=CRITICAL
  else st=UNKNOWN; fi
  { printf 'Result: %s\n%s\n' "$st" "$NOW"; [[ -n "$PLAN" && "$PLAN" != "$NOW" ]] && printf 'What to do:\n%s\n' "$PLAN"; } >> "$HEALTH_LOG"
  first=${NOW%%$'\n'*}
  # a first line that only announces a list ("...:") takes the first item with it
  if [[ "$first" == *: && "$NOW" == *$'\n'* ]]; then local rest=${NOW#*$'\n'}; rest=${rest%%$'\n'*}; first="$first ${rest#"${rest%%[![:space:]]*}"}"; fi
  [[ -n "$first" ]] || first="(no details)"
  [[ -n "${HEALTH_STATE[$id]:-}" ]] || HEALTH_ORDER+=("$id")
  HEALTH_STATE[$id]=$st
  # not OK, and the first line only says what runs: the reason is on the next line
  if [[ "$st" != OK && "$first" != *: && "$NOW" == *$'\n'* ]]; then local r2=${NOW#*$'\n'}; r2=${r2%%$'\n'*}; first="$first; ${r2#"${r2%%[![:space:]]*}"}"; fi
  if [[ "$first" == "$title" ]]; then HEALTH_TEXT[$id]=$title; else HEALTH_TEXT[$id]="$title: $first"; fi
}

health_main() {
  # a fixed environment: cron starts with almost none (runuser is in /sbin on Oracle Linux 7)
  export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" LANG=C LC_ALL=C
  umask 077
  exec 7>&1
  MODE=check; PROBE_TIMEOUT=120
  # the logs of --health: 14 days, and never more than the newest 500 (a run every few minutes)
  find "$LOG_DIR" -maxdepth 1 -type f -name 'health_*.log' -mtime +14 -delete 2>/dev/null
  find "$LOG_DIR" -maxdepth 1 -type f -name 'health_*.log' -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +501 | cut -d' ' -f2- | xargs -r -d '\n' rm -f --
  HEALTH_LOG="$LOG_DIR/health_$RUN_ID.log"
  ( umask 027; : > "$HEALTH_LOG" ) 2>/dev/null || { HEALTH_LOG=""; health_exit UNKNOWN "Cannot write the log in $LOG_DIR. Is the file system full or read-only?"; }
  LOG_FILE=$HEALTH_LOG
  exec 7>&1
  health_out "Data Guard health check of the standby on $(hostname -s 2>/dev/null), $(date '+%Y-%m-%d %H:%M:%S')  (dg_standby_setup.sh $SCRIPT_VERSION)"
  # one run at a time: an interactive run may be changing things right now
  exec 9> "$STATE_DIR/lock" || health_exit UNKNOWN "Cannot open $STATE_DIR/lock"
  flock -n 9 || health_exit UNKNOWN "Another run of this script (a setup run or --health) is active on this server. The check was not done."
  _log START "dg_standby_setup.sh $SCRIPT_VERSION mode=health pid=$$"
  init_settings
  [[ -f "$SETTINGS_FILE" ]] || health_exit UNKNOWN "No settings yet: the standby was not set up with this script on this server."
  load_settings soft || health_exit UNKNOWN "The settings cannot be used: $LOAD_ERR"
  derive_standby_settings
  [[ -n "$PRIMARY_IP" && -n "$STANDBY_UNIQUE" && -n "$DB_HOME" ]] || health_exit UNKNOWN "The settings are not complete. Run the setup in a terminal first."
  users_ok || health_exit UNKNOWN "The Oracle users of the settings do not exist on this server."
  build_envs
  db_sw_ok || health_exit UNKNOWN "The database software is not installed here (phase 3)."
  # a long job (the copy, a roll forward, an installer) is maintenance: the standby is not expected to be in sync
  if job_alive >> "$HEALTH_LOG" 2>&1; then health_exit UNKNOWN "Maintenance is running: $JOB_TITLE (session $JOB_PID). The check was not done."; fi
  # a roll forward that ended while no run watched: redo apply stays stopped until it is finished
  if [[ -f "$(rf_pending_file)" ]]; then
    HEALTH_STATE[10.7]=CRITICAL; HEALTH_TEXT[10.7]="A roll forward has ended but is not finished (redo apply is stopped). Run in a terminal:  $SELF --roll-forward"
    HEALTH_ORDER+=(10.7)
  fi
  health_out "Standby $STANDBY_UNIQUE, primary $PRIMARY_UNIQUE on ${PRIMARY_HOST:-$PRIMARY_IP}"

  # the instance first: when it is down, every other check would only say "cannot check"
  local_state >> "$HEALTH_LOG" 2>&1
  case "$LSTATE" in
    MOUNTED|OPEN) HEALTH_STATE[0.0]=OK; HEALTH_TEXT[0.0]="Standby instance: $LSTATE" ;;
    HUNG) HEALTH_STATE[0.0]=CRITICAL; HEALTH_TEXT[0.0]="Standby instance: $(hung_text)" ;;
    ERROR) HEALTH_STATE[0.0]=UNKNOWN; HEALTH_TEXT[0.0]="Standby instance: its state cannot be read ($(ora_errors "$SQL_OUT"))" ;;
    *) HEALTH_STATE[0.0]=CRITICAL; HEALTH_TEXT[0.0]="Standby instance: $([[ "$LSTATE" == IDLE ]] && printf 'not running' || printf 'state %s, not mounted' "$LSTATE")" ;;
  esac
  HEALTH_ORDER+=(0.0)
  if [[ "${HEALTH_STATE[0.0]}" != OK ]]; then health_report; health_exit; fi
  # after a switchover or failover this server is the primary: --health checks a standby
  if sql_local "select database_role from v\$database;" >> "$HEALTH_LOG" 2>&1 && [[ "$(first_line)" == PRIMARY ]]; then
    health_exit UNKNOWN "This server runs the PRIMARY now (after a switchover or failover). --health checks a standby."
  fi
  detect_built >> "$HEALTH_LOG" 2>&1
  [[ $STANDBY_BUILT -eq 1 ]] || health_exit UNKNOWN "The standby database is not recorded as built here (phase 8). $SC_INFO"

  health_ssh || _log WARN "health: $HEALTH_SSH_ERR"
  local -a checks=("10.1|Transport and apply lag|c_10_1" "10.2|No archive gap|c_10_2_once" "10.3|Last log: primary and standby|c_10_3_once"
                   "10.4|Redo apply is running|c_10_4" "10.5|No unrecoverable (NOLOGGING) changes|c_10_5" "10.6|Patch level: primary and standby|c_10_6"
                   "10.8|Archived logs: space and nightly clean-up|c_10_8")
  local c id title fn
  local -a again=()
  for c in "${checks[@]}"; do IFS='|' read -r id title fn <<< "$c"; health_run_check "$id" "$title" "$fn"; done
  # a short gap, a log or two behind, a lag peak: often gone within a minute. Those checks are done once more
  # after 60 seconds before anything is reported (the patch check and NOLOGGING do not change in a minute)
  for c in "${checks[@]:0:4}"; do
    IFS='|' read -r id title fn <<< "$c"
    [[ "${HEALTH_STATE[$id]}" == CRITICAL || "${HEALTH_STATE[$id]}" == WARNING ]] && again+=("$c")
  done
  if [[ ${#again[@]} -gt 0 ]]; then
    printf '\n(checked once more in 60 seconds:%s)\n' "$(for c in "${again[@]}"; do printf ' %s' "${c%%|*}"; done)" >> "$HEALTH_LOG"
    nap 60
    # the connection may have dropped meanwhile: opened again (still only with a key)
    [[ $HEALTH_SSH_OPEN -eq 1 ]] && ! ssh_alive && { health_ssh || _log WARN "health: $HEALTH_SSH_ERR"; }
    for c in "${again[@]}"; do IFS='|' read -r id title fn <<< "$c"; health_run_check "$id" "$title" "$fn"; done
  fi
  health_report
  health_exit
}

health_report() {
  local id
  HEALTH_REPORTED=1
  [[ -n "$HEALTH_LOG" ]] && printf '\n==== Summary ====\n' >> "$HEALTH_LOG"
  for id in "${HEALTH_ORDER[@]}"; do
    health_out "$(printf '  %-9s %-5s %s' "${HEALTH_STATE[$id]}" "$([[ "$id" == 0.0 ]] || printf '%s' "$id")" "${HEALTH_TEXT[$id]}")"
  done
  [[ -n "$HEALTH_SSH_ERR" ]] && health_out "  Note: $HEALTH_SSH_ERR. The checks that need the primary were not done. See:  $SELF --help-step health"
  return 0
}
