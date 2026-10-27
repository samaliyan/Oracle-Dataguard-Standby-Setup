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
