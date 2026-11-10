#------------------------------------------------------------------------------
# --health: the checks of phase 10, unattended (cron, a monitoring agent).
# Never asks, never changes anything, needs no terminal. Output on stdout (the form monitoring agents read):
#   line 1   STATE - short summary | perfdata         (Nagios form: the agent shows the first line)
#   then     the title, one line per check, notes, and "Result: STATE (exit N). Details: <log>"
# The details are in $LOG_DIR/health_<time>.log. Exit code (the convention of Nagios-style monitoring):
#   0 OK   1 WARNING (attention, nothing broken yet)   2 CRITICAL (a problem)   3 UNKNOWN (could not check)
# Worst first: CRITICAL, then UNKNOWN, then WARNING. SKIPPED counts as nothing: the checks of the primary are
# SKIPPED when root has no ssh key for it (10.3 and 10.5 are then done on the standby side only).
#------------------------------------------------------------------------------
HEALTH=0; HEALTH_SSH_OPEN=0; HEALTH_SSH_ERR=""; HEALTH_SSH_NOKEY=0; HEALTH_LOG=""; HEALTH_REPORTED=0
declare -A HEALTH_STATE=(); declare -A HEALTH_TEXT=(); HEALTH_ORDER=(); HEALTH_BUF=()

# fd 7: the real stdout of the run (a check runs with its own output sent to the log; what it must say reaches
# cron through fd 7 even then). The lines are kept until the end, so the status line can come first.
health_out() { HEALTH_BUF+=("$*"); [[ -n "$HEALTH_LOG" ]] && printf '%s\n' "$*" >> "$HEALTH_LOG"; return 0; }

health_status_line() {
  # $1 overall state, $2 the reason the run stopped (empty: the run ended normally). One line:
  # "STATE - summary | perfdata"
  local worst=$1 why=${2:-} id st txt="" first="" n=0 perf="" lim=${HC_LIM:-}
  if [[ -n "$why" ]]; then txt=$why
  else
    # the checks that are not OK, the worst first: the first one with its text, the others counted
    for st in CRITICAL UNKNOWN WARNING; do
      for id in "${HEALTH_ORDER[@]+"${HEALTH_ORDER[@]}"}"; do
        [[ "${HEALTH_STATE[$id]}" == "$st" ]] || continue
        n=$((n + 1))
        [[ -z "$first" ]] && first="$([[ "$id" != 0.0 ]] && printf '%s ' "$id")${HEALTH_TEXT[$id]}"
      done
    done
    [[ ${#first} -gt 110 ]] && first="${first:0:107}..."
    if [[ $n -gt 0 ]]; then txt="$first$([[ $n -gt 1 ]] && printf ' (+%s more not OK)' $((n - 1)))"
    else txt="standby ${STANDBY_UNIQUE:-?}$([[ "${HEALTH_STATE[10.4]:-}" == OK ]] && printf ', redo apply running')"; fi
  fi
  [[ "${HC_ALS:--1}" -ge 0 || "${HC_TLS:--1}" -ge 0 ]] && txt+="; lag: transport ${HC_TLS/#-1/?} s, apply ${HC_ALS/#-1/?} s${lim:+ (limit $lim s)}"
  [[ -n "${DGS_PROT:-}" ]] && txt+="; protection $DGS_PROT"
  [[ $HEALTH_SSH_NOKEY -eq 1 ]] && txt+="; primary not checked (no ssh key)"
  [[ "${HC_TLS:--1}" -ge 0 ]] && perf+="transport_lag=${HC_TLS}s;;${lim};0 "
  [[ "${HC_ALS:--1}" -ge 0 ]] && perf+="apply_lag=${HC_ALS}s;;${lim};0 "
  perf=${perf% }
  printf '%s - %s%s' "$worst" "$(tr -d '|' <<< "$txt")" "${perf:+ | $perf}"
}

health_exit() {
  # $1 overall state when the run cannot go on (UNKNOWN), $2 the reason; or no arguments: the end of the run
  local worst=OK id st code l
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
    esac      # SKIPPED (not on this release, or the primary without a key) counts as nothing
  done
  case "$worst" in OK) code=0 ;; WARNING) code=1 ;; CRITICAL) code=2 ;; *) code=3 ;; esac
  # a CRITICAL check found before the stop is the summary; otherwise the reason of the stop
  l=$(health_status_line "$worst" "$([[ -n "${1:-}" && "$worst" == UNKNOWN ]] && printf '%s' "${2:-}")")
  printf '%s\n' "$l" >&7
  [[ -n "$HEALTH_LOG" ]] && printf '\n%s\n' "$l" >> "$HEALTH_LOG"
  for l in "${HEALTH_BUF[@]+"${HEALTH_BUF[@]}"}"; do printf '%s\n' "$l" >&7; done
  HEALTH_BUF=()
  health_out "Result: $worst (exit $code)${HEALTH_LOG:+. Details: $HEALTH_LOG}"
  printf '%s\n' "${HEALTH_BUF[0]}" >&7; HEALTH_BUF=()
  dg_state_save health "$worst" "$HEALTH_LOG"
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
  # the key of step 9.9 when it exists (only that one is offered then); else root's usual keys
  local -a idf=(); local kf; kf=$(health_key_file); [[ -f "$kf" ]] && idf=(-o IdentityFile="$kf")
  if timeout 30 ssh -E "$elog" "${idf[@]+"${idf[@]}"}" -o BatchMode=yes -o ControlMaster=yes -o ControlPath="$SSH_CTL" -o ControlPersist=300 \
       -o StrictHostKeyChecking=yes -o CheckHostIP=no -o UserKnownHostsFile="$ROOT_KH $KH_FILE" \
       -o ConnectTimeout=15 -o ServerAliveInterval=30 -fN "$PRIMARY_SSH_USER@$PRIMARY_IP" < /dev/null 9>&- \
     && ssh_alive; then
    HEALTH_SSH_OPEN=1; return 0
  fi
  local el; el=$(tail -n 1 "$elog" 2>/dev/null | tr -cd '[:print:]')
  # no key that the primary accepts: the checks of the primary are SKIPPED (not UNKNOWN), as nothing is wrong with
  # the standby; any other failure (no answer, a changed host key) stays UNKNOWN for them
  if [[ "$el" == *"Permission denied"* ]]; then HEALTH_SSH_NOKEY=1; HEALTH_SSH_ERR="primary not checked: no ssh key for root to $PRIMARY_SSH_USER@$PRIMARY_IP"
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
  vq_take > /dev/null      # (--verbose: the list of this check starts empty)
  rc=0; "$fn" >> "$HEALTH_LOG" 2>&1 || rc=$?
  [[ -n "$VQ_FILE" ]] && HEALTH_VQ[$id]=$(vq_take)
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
  # one statement may take at most 60 seconds here (not the 600 of a setup run), so a run with a hung sqlplus
  # still ends well within the 300 seconds a monitoring agent allows; DG_SQL_TIMEOUT, when set, is kept
  [[ -n "${DG_SQL_TIMEOUT:-}" ]] || SQL_TIMEOUT=60
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
  # the checks below do not read the instance state, the role and the datafile headers again (need_built)
  HEALTH_BUILT_OK=1

  health_ssh || _log WARN "health: $HEALTH_SSH_ERR"
  [[ -n "$VQ_FILE" ]] && HEALTH_VQ[0.0]=$(vq_take)
  local -a checks=("10.1|Transport and apply lag|c_10_1" "10.2|No archive gap|c_10_2_once" "10.3|Last log: primary and standby|c_10_3_once"
                   "10.4|Redo apply is running|c_10_4" "10.5|No unrecoverable (NOLOGGING) changes|c_10_5" "10.6|Patch level: primary and standby|c_10_6"
                   "10.8|Archived logs: space and nightly clean-up|c_10_8")
  local c id title fn
  local -a again=()
  for c in "${checks[@]}"; do IFS='|' read -r id title fn <<< "$c"; health_run_check "$id" "$title" "$fn"; done
  # a short gap, a log or two behind, a lag peak: often gone within a minute. Those checks are done once more
  # after 60 seconds before anything is reported (the patch check and NOLOGGING do not change in a minute).
  # Also once more: 10.8 when it failed, and any check that could not read (a dropped connection, a busy view);
  # but not 10.6 when there is no ssh connection to the primary at all (that stays so; 10.3 and 10.5 then read
  # the standby only, and a failed read there is worth a second look)
  for c in "${checks[@]}"; do
    IFS='|' read -r id title fn <<< "$c"
    case "$id:${HEALTH_STATE[$id]}" in
      10.[1-4]:CRITICAL|10.[1-4]:WARNING|10.8:CRITICAL) again+=("$c") ;;
      *:UNKNOWN) [[ $HEALTH_SSH_OPEN -eq 1 || "$id" != 10.6 ]] && again+=("$c") ;;
    esac
  done
  if [[ ${#again[@]} -gt 0 ]]; then
    printf '\n(checked once more in 60 seconds:%s)\n' "$(for c in "${again[@]}"; do printf ' %s' "${c%%|*}"; done)" >> "$HEALTH_LOG"
    nap 60
    # the connection may have dropped meanwhile: opened again (still only with a key)
    [[ $HEALTH_SSH_OPEN -eq 1 ]] && ! ssh_alive && { health_ssh || _log WARN "health: $HEALTH_SSH_ERR"; }
    for c in "${again[@]}"; do IFS='|' read -r id title fn <<< "$c"; health_run_check "$id" "$title" "$fn"; done
  fi
  # the state of Data Guard on this standby (role, protection mode, last applied log): a line of its own, and
  # kept for --status
  dg_state_read >> "$HEALTH_LOG" 2>&1
  [[ -n "$VQ_FILE" ]] && HEALTH_VQ[dg]=$(vq_take)
  health_report
  health_exit
}

declare -A HEALTH_VQ=()
health_vq() {
  # --verbose: the queries of check $1, under its line
  local l; [[ -n "${HEALTH_VQ[$1]:-}" ]] || return 0
  while IFS= read -r l; do [[ -n "$l" ]] && health_out "                  · $l"; done <<< "${HEALTH_VQ[$1]}"
  return 0
}
health_report() {
  local id
  HEALTH_REPORTED=1
  [[ -n "$HEALTH_LOG" ]] && printf '\n==== Summary ====\n' >> "$HEALTH_LOG"
  for id in "${HEALTH_ORDER[@]}"; do
    health_out "$(printf '  %-9s %-5s %s' "${HEALTH_STATE[$id]}" "$([[ "$id" == 0.0 ]] || printf '%s' "$id")" "${HEALTH_TEXT[$id]}")"
    health_vq "$id"
  done
  [[ -n "${DGS_ROLE:-}" ]] && { health_out "  Data Guard: $(dg_state_oneline)"; health_vq dg; }
  if [[ $HEALTH_SSH_NOKEY -eq 1 ]]; then
    health_out "  Note: $HEALTH_SSH_ERR (set it up with step 9.9:  $SELF --only 9.9; see --help-step 9.9 / README). 10.3 and 10.5: standby side only; 10.6 skipped."
  elif [[ -n "$HEALTH_SSH_ERR" ]]; then
    health_out "  Note: $HEALTH_SSH_ERR. The checks that need the primary were not done. See:  $SELF --help-step health"
  fi
  # what the boot unit (step 9.7) reported at its start in this boot: a note, not a state (it stays in the journal
  # until the next start of the unit, also after the problem was fixed; 0.0 and 10.4 show the effect itself)
  local berr; berr=$(boot_errors_now 2>/dev/null)
  [[ -n "$berr" ]] && health_out "  Note: at its start in this boot, $(unit_name) reported: $(head -n 1 <<< "$berr")$([[ $(grep -c . <<< "$berr") -gt 1 ]] && printf ' (and more)'). See:  journalctl -p err -u $(unit_name) -b"
  return 0
}

#------------------------------------------------------------------------------
# The state of Data Guard on this standby, in a few values: shown at the end of phase 10, by --health (and kept
# for --status in $STATE_DIR/dg_state_health or dg_state_run). Read-only, on the standby only. The protection
# mode is the one of the configuration (v$database of a standby shows the mode the primary sends with).
#------------------------------------------------------------------------------
DGS_ROLE=""; DGS_OPEN=""; DGS_PROT=""; DGS_PLEVEL=""; DGS_MRP=""; DGS_TL=""; DGS_AL=""; DGS_APPLIED=""; DGS_WHEN=""
HC_TLS=-1; HC_ALS=-1; HC_LIM=""     # lag in seconds and its limit, as check 10.1 measured them (-1: not known)
dg_state_read() {
  # sets the DGS_ values (empty: could not be read); it uses SQL_OUT
  DGS_ROLE=""; DGS_OPEN=""; DGS_PROT=""; DGS_PLEVEL=""; DGS_MRP=""; DGS_TL=""; DGS_AL=""; DGS_APPLIED=""; DGS_WHEN=$(ts)
  local l t q
  if sql_local "select 'DB:'||database_role||'|'||open_mode||'|'||protection_mode||'|'||protection_level from v\$database;"; then
    l=$(sed -n 's/^[[:space:]]*DB://p' <<< "$SQL_OUT" | head -n 1 | tr -cd '[:print:]')
    IFS='|' read -r DGS_ROLE DGS_OPEN DGS_PROT DGS_PLEVEL <<< "$l"
  fi
  if dg_proc_count MRP; then if [[ $DGP_COUNT -ge 1 ]]; then DGS_MRP="running"; else DGS_MRP="not running"; fi; fi
  if sql_local "select nvl(max(decode(name,'transport lag',value)),'-')||'|'||nvl(max(decode(name,'apply lag',value)),'-') from v\$dataguard_stats;"; then
    IFS='|' read -r DGS_TL DGS_AL <<< "$(first_line | tr -cd '[:print:]')"
  fi
  if sql_local "select thread#||' '||max(sequence#) from v\$archived_log where applied in ('YES','IN-MEMORY') and resetlogs_change#=(select resetlogs_change# from v\$database) group by thread# order by thread#;"; then
    while read -r t q; do
      [[ "$t" =~ ^[0-9]+$ && "$q" =~ ^[0-9]+$ ]] && DGS_APPLIED+="${DGS_APPLIED:+, }thread $t sequence $q"
    done <<< "$SQL_OUT"
  fi
  return 0
}
dg_state_oneline() {
  # the values in one line (for --health)
  local o=""
  [[ -n "$DGS_ROLE" ]] && o+="$DGS_ROLE${DGS_OPEN:+, $DGS_OPEN}"
  [[ -n "$DGS_PROT" ]] && o+="; protection mode $DGS_PROT$([[ -n "$DGS_PLEVEL" && "$DGS_PLEVEL" != "$DGS_PROT" ]] && printf ' (level now %s)' "$DGS_PLEVEL")"
  [[ -n "$DGS_MRP" ]] && o+="; redo apply $DGS_MRP"
  [[ -n "$DGS_APPLIED" ]] && o+="; last applied: $DGS_APPLIED"
  printf '%s' "${o#; }"
}
dg_state_lines() {
  # the values, one per line, $1 = indent
  local i=${1:-    } plev=""
  [[ -n "$DGS_PLEVEL" && "$DGS_PLEVEL" != "$DGS_PROT" ]] && plev=" (level now $DGS_PLEVEL)"
  printf '%sRole          %s\n' "$i" "${DGS_ROLE:-not read}${DGS_OPEN:+, $DGS_OPEN}"
  printf '%sProtection    %s\n' "$i" "${DGS_PROT:-not read}$plev"
  printf '%sRedo apply    %s\n' "$i" "${DGS_MRP:+MRP }${DGS_MRP:-not read}"
  printf '%sLag           %s\n' "$i" "$([[ -n "$DGS_TL$DGS_AL" ]] && printf 'transport %s, apply %s' "${DGS_TL:--}" "${DGS_AL:--}" || printf 'not read')"
  printf '%sLast applied  %s\n' "$i" "${DGS_APPLIED:-not read}"
}
dg_state_save() {
  # $1 health | run (which file), $2 the result, $3 its log. Plain key=value lines; read back only by
  # dg_state_load (never sourced)
  [[ -n "${STATE_DIR:-}" && -d "$STATE_DIR" ]] || return 0
  local f="$STATE_DIR/dg_state_$1"
  { printf 'when=%s\nresult=%s\nrun=%s\nlog=%s\n' "$(ts)" "$2" "${RUN_ID:-}" "$3"
    printf 'role=%s\nopen_mode=%s\nprotection=%s\nprotection_level=%s\nmrp=%s\ntransport_lag=%s\napply_lag=%s\nlast_applied=%s\nread=%s\n' \
      "$DGS_ROLE" "$DGS_OPEN" "$DGS_PROT" "$DGS_PLEVEL" "$DGS_MRP" "$DGS_TL" "$DGS_AL" "$DGS_APPLIED" "$DGS_WHEN"
  } 2>/dev/null | tr -cd '[:print:]\n' > "$f.n" 2>/dev/null && mv -f -- "$f.n" "$f" 2>/dev/null && chmod 600 "$f" 2>/dev/null
  return 0
}
DGL_WHEN=""; DGL_RESULT=""; DGL_RUN=""; DGL_LOG=""
dg_state_load() {
  # $1 health | run: the values saved by dg_state_save into DGS_ and DGL_ (false when there is no such file)
  local f="$STATE_DIR/dg_state_$1" k v
  DGL_WHEN=""; DGL_RESULT=""; DGL_RUN=""; DGL_LOG=""
  [[ -r "$f" ]] || return 1
  DGS_ROLE=""; DGS_OPEN=""; DGS_PROT=""; DGS_PLEVEL=""; DGS_MRP=""; DGS_TL=""; DGS_AL=""; DGS_APPLIED=""; DGS_WHEN=""
  while IFS='=' read -r k v; do
    case "$k" in
      when) DGL_WHEN=$v ;; result) DGL_RESULT=$v ;; run) DGL_RUN=$v ;; log) DGL_LOG=$v ;;
      role) DGS_ROLE=$v ;; open_mode) DGS_OPEN=$v ;; protection) DGS_PROT=$v ;; protection_level) DGS_PLEVEL=$v ;;
      mrp) DGS_MRP=$v ;; transport_lag) DGS_TL=$v ;; apply_lag) DGS_AL=$v ;; last_applied) DGS_APPLIED=$v ;; read) DGS_WHEN=$v ;;
    esac
  done < "$f"
  return 0
}

dg_status_block() {
  # for --status (the caller prints the header): the state of Data Guard, read now when the standby instance
  # runs here (read-only, on this server only, at most a few seconds), else the last recorded one; then when
  # --health and phase 10 last ran, with their logs
  local live=0 hw="" rw=""
  printf '\n  %sData Guard%s\n' "$C_W" "$C_N"
  if [[ -n "${STANDBY_SID:-}" && -n "${ORACLE_USER:-}" ]] && db_sw_ok 2>/dev/null && pmon_running; then
    derive_standby_settings >/dev/null 2>&1; build_envs >/dev/null 2>&1
    local SQL_TIMEOUT=15
    dg_state_read >/dev/null 2>&1
    [[ -n "$DGS_ROLE" ]] && live=1
  fi
  if [[ $live -eq 1 ]]; then
    dg_state_lines "    "
    printf '    %s\n' "(read now from the standby instance, read-only)"
  elif { dg_state_load health && [[ -n "$DGS_ROLE" ]]; } || { dg_state_load run && [[ -n "$DGS_ROLE" ]]; }; then
    dg_state_lines "    "
    printf '    %s\n' "(not read now: the standby instance does not run here, or did not answer. Recorded at ${DGS_WHEN:-$DGL_WHEN})"
  else
    printf '    %s\n' "Not known: the standby instance does not run here, and no health check has run yet."
  fi
  if dg_state_load health; then hw="$DGL_RESULT at $DGL_WHEN"; printf '  Last --health   %s%s\n' "$hw" "${DGL_LOG:+   $DGL_LOG}"
  else printf '  Last --health   never (cron: %s --health)\n' "$SELF"; fi
  if dg_state_load run; then rw="$DGL_RESULT at $DGL_WHEN"; printf '  Last phase 10   %s%s\n' "$rw" "${DGL_RUN:+   run $DGL_RUN}"; fi
  return 0
}

status_runs_block() {
  # for --status: the runs whose results the step list shows (from the progress file), newest first, each with
  # its log (the step list gives the result per step; this says which run recorded it, and where its log is)
  [[ -n "${PROGRESS_FILE:-}" && -s "$PROGRESS_FILE" ]] || return 0
  local id r t run why l
  printf '\n  %sRuns behind these results%s   (newest first; the log of each run: what was done and its output)\n' "$C_W" "$C_N"
  while IFS='|' read -r id r t run why; do
    [[ "$id" =~ ^[0-9]+\.[0-9]+$ && "$run" =~ ^[0-9_]+$ ]] && printf '%s|%s|%s\n' "$run" "$t" "${id%%.*}"
  done < "$PROGRESS_FILE" | sort -t'|' -k1,1 -k2,2 \
    | awk -F'|' '{n[$1]++; last[$1]=$2; if (!(($1, $3) in seen)) {seen[$1,$3]=1; p[$1]=p[$1] (p[$1] == "" ? "" : ",") $3}} END {for (k in n) print k "|" n[k] "|" last[k] "|" p[k]}' \
    | sort -r | while IFS='|' read -r run r t id; do
      l="$LOG_DIR/run_$run.log"; [[ -f "$l" ]] || l="$l (no longer there)"
      printf '    run %s   %s step(s) (phases %s), the last at %s\n      log: %s\n' "$run" "$r" "$id" "${t:0:16}" "$l"
    done
  return 0
}

health_key_test() {
  # true when root can open an ssh connection to the primary with a key alone, as --health does. A connection
  # of its own (never the one of this run), closed again at once; it never asks for a password
  [[ -n "${PRIMARY_IP:-}" && -n "${PRIMARY_SSH_USER:-}" ]] || return 1
  local ctl="$STATE_DIR/ssh_ctl_keytest" rc=1
  local -a idf=(); local kf; kf=$(health_key_file); [[ -f "$kf" ]] && idf=(-o IdentityFile="$kf")
  rm -f -- "$ctl"
  if timeout 30 ssh "${idf[@]+"${idf[@]}"}" -o BatchMode=yes -o ControlMaster=yes -o ControlPath="$ctl" -o ControlPersist=10 \
       -o StrictHostKeyChecking=yes -o CheckHostIP=no -o UserKnownHostsFile="$ROOT_KH $KH_FILE" \
       -o ConnectTimeout=15 -fN "$PRIMARY_SSH_USER@$PRIMARY_IP" < /dev/null > /dev/null 2>&1 9>&-; then rc=0; fi
  [[ -e "$ctl" ]] && timeout 10 ssh -o ControlPath="$ctl" -O exit "$PRIMARY_SSH_USER@$PRIMARY_IP" >/dev/null 2>&1
  rm -f -- "$ctl"
  return $rc
}
# the key of step 9.9 for --health: root's own, used only by this script (DG_SSH_DIR moves the folder, for tests)
health_key_file() { printf '%s/dg_health_%s' "${DG_SSH_DIR:-$(dirname "$ROOT_KH")}" "${STANDBY_UNIQUE,,}"; }
health_key_line() {
  # the line for ~/.ssh/authorized_keys on the primary: the key, usable only from this server, without a
  # terminal or forwarding (--health runs its read-only commands over it)
  local pub; pub=$(head -n 1 "$(health_key_file).pub" 2>/dev/null | tr -cd '[:print:]')
  printf 'from="%s",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty %s' "${STANDBY_IP:-<address of this server>}" "${pub:-<the line of $(health_key_file).pub>}"
}
health_key_hint() {
  # what to do when --health cannot log in to the primary with a key; $1 = indent
  local i=${1:-  }
  printf '%s%s --only 9.9
' "$i" "$SELF"
  printf '%s# (makes the key %s and shows the line for ~%s/.ssh/authorized_keys on the primary)
' "$i" "$(health_key_file)" "$PRIMARY_SSH_USER"
}
