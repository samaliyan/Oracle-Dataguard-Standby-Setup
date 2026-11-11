#------------------------------------------------------------------------------
# Local SQL (standby) and TNS checks
#------------------------------------------------------------------------------
_sql_exec() {
  # $1 connect line, $2 sql text, $3 log title, $4 runner (as_oracle|as_grid), $5 home, $6 timeout (s)
  local connect=$1 sql=$2 title=$3 runner=$4 home=$5 tmo=${6:-$SQL_TIMEOUT} out rc=0 tmp
  # during an action, a statement that changes something is shown before it runs (selects are only logged)
  if [[ ${IN_DO:-0} -eq 1 && ! "${sql,,}" =~ ^[[:space:]]*select[[:space:]] ]]; then
    local who=$ORACLE_USER; [[ "$runner" == as_grid ]] && who=$GRID_USER
    local first; first=$(head -n 1 <<< "$sql"); local nl; nl=$(grep -c '' <<< "$sql")
    say "${C_D}Running as $who:${C_N} $(printf '%s\n' "sqlplus ${connect#connect }  ->  $first" | mask_pw)$([[ $nl -gt 1 ]] && printf '  (and %s more lines)' $((nl - 1)))"
  fi
  # output through a file: background processes of a started instance must not keep a pipe open
  tmp=$(mktemp /tmp/dg_sql.XXXXXXXX) || { SQL_OUT="SP2-0000: cannot create a temporary file"; return 1; }
  CLEANUP_FILES+=("$tmp")
  printf 'set define off echo off\n%s\n%s\nprompt %s\n%s\nexit\n' "$connect" "$SQL_HEADER" "$SQL_MARK" "$sql" \
    | "$runner" timeout -k 30 "$tmo" "$home/bin/sqlplus" -S /nolog > "$tmp" 2>&1 || rc=$?
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

pmon_running() { pgrep -u "$ORACLE_USER" -f "^(ora|db)_pmon_${STANDBY_SID}( |\$)" >/dev/null 2>&1; }   # the processes of the standby instance run
STATE_TMO=$((FAST_WAITS == 1 ? 5 : 120))     # a login that hangs longer than this is a hung instance, not a slow one
local_state() {
  # LSTATE = IDLE | STARTED | MOUNTED | OPEN | HUNG | ERROR | NOSW
  # HUNG: the instance's processes run (ora_pmon_<SID>), but a login fails with ORA-01012 (not logged on) or does
  # not answer. Seen after a duplicate, when "shutdown immediate" of the instance RMAN started did not finish.
  if ! db_sw_ok; then LSTATE=NOSW; return; fi
  if sql_local "select status from v\$instance;" "$STATE_TMO"; then
    LSTATE=$(first_line)
  elif grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    LSTATE="IDLE"
  elif grep -qE 'ORA-01012|did not answer within' <<< "$SQL_OUT" && pmon_running; then
    LSTATE="HUNG"
  else
    LSTATE="ERROR"
  fi
}
hung_text() { printf 'Instance %s hangs: its processes run (ora_pmon_%s), but a login gives %s.' "$STANDBY_SID" "$STANDBY_SID" "$(grep -q 'did not answer' <<< "$SQL_OUT" && printf 'no answer' || printf 'ORA-01012 (not logged on)')"; }
SHUT_TMO=$((FAST_WAITS == 1 ? 5 : 300))      # shutdown immediate longer than this: it hangs (then shutdown abort is offered)
inst_abort() {
  # shutdown abort of the standby instance $STANDBY_SID (never another SID: ORACLE_SID is set by as_oracle).
  # A normal login first; when that gives ORA-01012 or does not answer, "sqlplus -prelim" (it attaches without a
  # session). Then the processes must be gone (ora_pmon_<SID>) within a minute.
  local t0
  say "${C_D}Running as $ORACLE_USER: sqlplus / as sysdba  ->  shutdown abort${C_N}"
  if ! sql_local "shutdown abort" 120 && ! grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    say "${C_D}Running as $ORACLE_USER: sqlplus -prelim / as sysdba  ->  shutdown abort  (a normal login does not work)${C_N}"
    local tmp; tmp=$(mktemp /tmp/dg_sql.XXXXXXXX) && CLEANUP_FILES+=("$tmp")
    printf 'shutdown abort\nexit\n' | as_oracle timeout 120 "$DB_HOME/bin/sqlplus" -S -prelim / as sysdba > "${tmp:-/dev/null}" 2>&1 || true
    { printf 'sqlplus -S -prelim / as sysdba <<< shutdown abort\n'; cat -- "$tmp" 2>/dev/null; } | log_block "STANDBY sqlplus -prelim: shutdown abort"
    rm -f -- "$tmp"
  fi
  t0=$SECONDS
  while pmon_running && (( SECONDS - t0 < (FAST_WAITS == 1 ? 3 : 60) )); do nap 2; done
  if pmon_running; then bad "Instance $STANDBY_SID still runs after shutdown abort (ora_pmon_$STANDBY_SID). Check:  ps -ef | grep ora_pmon_$STANDBY_SID"; return 1; fi
  journal INSTANCE "$STANDBY_SID" "shutdown abort (the instance hung or did not stop)"
  say "Instance $STANDBY_SID is stopped (shutdown abort)."
  return 0
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
