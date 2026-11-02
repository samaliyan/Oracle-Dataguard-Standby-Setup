#------------------------------------------------------------------------------
# PHASE 9  Oracle Restart registration, standby redo logs, apply, shipping
#------------------------------------------------------------------------------
REG_MODE=""; REG_OLD_OPT=""; REG_OLD_HOME=""; REG_OLD_PW=""; REG_MOD_ARGS=()

need_built() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 1; }
  detect_built
  if [[ $STANDBY_BUILT -eq 1 && "$LSTATE" == "IDLE" && "${CUR_STEP%%.*}" == "10" ]]; then
    NOW="The standby instance is not running (step 9.2)."$'\n'"Start it as $ORACLE_USER:  $(use_grid && printf 'srvctl start database -db %s' "$STANDBY_UNIQUE" || printf 'startup mount')"$'\n'"Also check:  systemctl status $(unit_name 2>/dev/null)"
    return 1
  fi
  [[ $STANDBY_BUILT -eq 1 ]] && return 0
  if [[ $DETECT_RC -eq 2 ]]; then NOW="Cannot tell whether the standby is complete: $SC_INFO"; return 1; fi
  NOW="The standby database does not exist yet (phase 8)"; return 1
}
adg_note() {
  # an OPEN standby with apply running is Active Data Guard (a separate license)
  [[ "$1" == OPEN* ]] && warn "The standby is OPEN."$'\n'"An open standby with redo apply needs the Active Data Guard license."$'\n'"This script only mounts it."
  return 0
}

# ---- 9.1 ----
srv_dgs() { asm_dgs | paste -sd, -; }
c_9_1() {
  use_grid || { NOW="Not needed: no Oracle Restart on this server. Step 9.7 sets up the start at boot."; return 0; }
  need_built || return 2
  local srv="$DB_HOME/bin/srvctl" spf; spf=$(spfile_path)
  [[ -f "$spf" ]] || { NOW="The spfile is missing: $spf"; return 2; }
  local add="srvctl add database -db $STANDBY_UNIQUE -oraclehome $DB_HOME -spfile $spf -pwfile $(pw_dest) -role PHYSICAL_STANDBY -startoption MOUNT -dbname $DB_NAME -instance $STANDBY_SID -diskgroup $(srv_dgs)${PRIMARY_DOMAIN:+ -domain $PRIMARY_DOMAIN}"
  if run_logged "srvctl config database" as_oracle "$srv" config database -db "$STANDBY_UNIQUE"; then
    local cfg=$RUN_OUT bad_items=""
    # compared as text (a path is not a pattern: a dot in it must not match any character)
    local cspf; cspf=$(sed -n 's/^spfile:[[:space:]]*//Ip' <<< "$cfg" | head -n 1 | sed 's/[[:space:]]*$//')
    [[ "$cspf" == "$spf" ]] || bad_items+=" spfile"
    grep -qiE "^Database role:[[:space:]]*PHYSICAL_STANDBY" <<< "$cfg" || bad_items+=" role"
    grep -qiE "^(Database instance|Instance)( name)?:[[:space:]]*${STANDBY_SID}[[:space:]]*\$" <<< "$cfg" || bad_items+=" instance"
    # a standby must only be mounted at boot (open would need Active Data Guard, and apply starts on a mounted one)
    grep -qiE "^Start options:[[:space:]]*mount[[:space:]]*\$" <<< "$cfg" || bad_items+=" start-option"
    # the home and the password file it starts with (a stale one fails only at the next start)
    local oh pw; oh=$(sed -n 's/^Oracle home:[[:space:]]*//Ip' <<< "$cfg" | head -n 1 | tr -s '/'); oh=${oh%/}; REG_OLD_HOME=$oh
    [[ "$oh" == "$(tr -s '/' <<< "${DB_HOME%/}")" ]] || bad_items+=" oracle-home"
    # an empty password file is right too: the instance then uses dbs/orapw<SID> of its home
    pw=$(sed -n 's/^Password file:[[:space:]]*//Ip' <<< "$cfg" | head -n 1 | tr -s '/'); pw=${pw%"${pw##*[![:space:]]}"}; REG_OLD_PW=$pw
    [[ -z "$pw" || "$pw" == "$(pw_dest | tr -s '/')" ]] || bad_items+=" password-file"
    if [[ -z "$bad_items" ]]; then NOW="Registered in Oracle Restart: role PHYSICAL_STANDBY, instance $STANDBY_SID"$'\n'"spfile: $spf"; return 0; fi
    NOW="Registered, but these values are wrong:$bad_items"$'\n'"$(grep -iE '^(spfile|database role|database instance|instance|start options|oracle home|password file)' <<< "$cfg")"
    REG_OLD_OPT=$(sed -n 's/^Start options:[[:space:]]*//Ip' <<< "$cfg" | head -n 1 | tr -cd 'A-Za-z ' | tr ' ' '_')
    # start option, home and password file are changed in place (the running standby is not stopped);
    # a wrong spfile, role or instance needs a new registration
    if [[ "$bad_items" != *spfile* && "$bad_items" != *role* && "$bad_items" != *instance* ]]; then
      REG_MODE=modify; REG_MOD_ARGS=()
      [[ "$bad_items" == *start-option* ]] && REG_MOD_ARGS+=(-startoption MOUNT)
      [[ "$bad_items" == *oracle-home* ]] && REG_MOD_ARGS+=(-oraclehome "$DB_HOME")
      [[ "$bad_items" == *password-file* ]] && REG_MOD_ARGS+=(-pwfile "$(pw_dest)")
      PLAN="As $ORACLE_USER, on this server only:
srvctl modify database -db $STANDBY_UNIQUE ${REG_MOD_ARGS[*]}"
      return 1
    fi
    REG_MODE=re
    PLAN="As $ORACLE_USER, on this server only:
srvctl stop database -db $STANDBY_UNIQUE
srvctl remove database -db $STANDBY_UNIQUE -noprompt
$add"
    PLAN+=$'\n'"The management policy and the stop option of the old registration are kept. The old registration is saved first."
    return 1
  fi
  REG_MODE=add
  NOW="$STANDBY_UNIQUE is not registered in Oracle Restart"
  PLAN="As $ORACLE_USER:
$add"
  USING="-instance must be exactly $STANDBY_SID, or sqlplus shows 'Connected to an idle instance'"
  return 1
}
_cfgv() { sed -n "s/^$2:[[:space:]]*//Ip" "$1" | head -n 1 | sed 's/[[:space:]]*$//'; }   # $1 file, $2 label
SRV_OLD_ARGS=()
_srv_opt() {
  # $1 option, $2 value: added to SRV_OLD_ARGS when set. A value that starts with "-" (read as an option)
  # or holds a line break is not used: then the whole command is not made (SRV_BAD)
  [[ -n "$2" ]] || return 0
  [[ "$2" == -* || "$2" == *$'\n'* ]] && SRV_BAD=1
  SRV_OLD_ARGS+=( "$1" "$2" )
}
srv_old_args() {
  # $1 saved "srvctl config database" output -> SRV_OLD_ARGS: the srvctl add command (an array, so a value
  # with a space stays one value) that makes the same registration. 1 when it cannot be made.
  local f=$1
  SRV_OLD_ARGS=(); SRV_BAD=0
  [[ -s "$f" ]] || return 1
  local oh inst dg
  oh=$(_cfgv "$f" 'Oracle home'); [[ -n "$oh" ]] || return 1
  inst=$(_cfgv "$f" 'Database instance'); [[ -n "$inst" ]] || inst=$(_cfgv "$f" 'Instance name'); [[ -n "$inst" ]] || inst=$(_cfgv "$f" 'Instance')
  dg=$(_cfgv "$f" 'Disk Groups'); dg=${dg//[[:space:]]/}      # "DATA, FRA" is the list DATA,FRA
  SRV_OLD_ARGS=( "$DB_HOME/bin/srvctl" add database -db "$STANDBY_UNIQUE" )
  _srv_opt -oraclehome "$oh"
  _srv_opt -spfile "$(_cfgv "$f" 'Spfile')"; _srv_opt -pwfile "$(_cfgv "$f" 'Password file')"
  _srv_opt -role "$(_cfgv "$f" 'Database role')"; _srv_opt -startoption "$(_cfgv "$f" 'Start options')"
  _srv_opt -dbname "$(_cfgv "$f" 'Database name')"; _srv_opt -instance "$inst"; _srv_opt -diskgroup "$dg"
  _srv_opt -domain "$(_cfgv "$f" 'Domain')"; _srv_opt -policy "$(_cfgv "$f" 'Management policy')"
  _srv_opt -stopoption "$(_cfgv "$f" 'Stop options')"
  [[ $SRV_BAD -eq 0 ]] || { SRV_OLD_ARGS=(); return 1; }
  return 0
}
srv_add_cmd_from() {
  # $1 saved "srvctl config database" output -> the same srvctl add command as text (for the screen)
  srv_old_args "$1" || return 0
  local a out="" q="'"
  for a in "${SRV_OLD_ARGS[@]}"; do
    if [[ "$a" =~ ^[A-Za-z0-9_./,:+=@-]+$ ]]; then out+="$a "; else out+="$q${a//$q/$q\\$q$q}$q "; fi
  done
  printf '%s' "${out% }"
}
srv_cfg_norm() { sed 's/[[:space:]]*$//; s/^[[:space:]]*//' | grep -v '^$'; }
srv_add() {
  # $1 (optional) saved "srvctl config database" of an earlier registration: its management policy and stop
  # option are kept (a new registration would otherwise reset them to the defaults without a word)
  local keep=() pol="" sto=""
  if [[ -n "${1:-}" && -s "$1" ]]; then
    pol=$(_cfgv "$1" 'Management policy'); sto=$(_cfgv "$1" 'Stop options')
    [[ "$pol" =~ ^[A-Za-z]+$ ]] && keep+=(-policy "$pol")
    [[ "$sto" =~ ^[A-Za-z]+$ ]] && keep+=(-stopoption "$sto")
  fi
  run_logged "srvctl add database" as_oracle "$DB_HOME/bin/srvctl" add database -db "$STANDBY_UNIQUE" \
    -oraclehome "$DB_HOME" -spfile "$(spfile_path)" -pwfile "$(pw_dest)" \
    -role PHYSICAL_STANDBY -startoption MOUNT -dbname "$DB_NAME" -instance "$STANDBY_SID" \
    -diskgroup "$(srv_dgs)" ${PRIMARY_DOMAIN:+-domain "$PRIMARY_DOMAIN"} "${keep[@]}" || { bad "srvctl add failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  [[ ${#keep[@]} -gt 0 ]] && say "Kept from the old registration: ${keep[*]}"
  return 0
}
d_9_1() {
  if [[ "$REG_MODE" == "modify" ]]; then
    run_logged "srvctl modify database" as_oracle "$DB_HOME/bin/srvctl" modify database -db "$STANDBY_UNIQUE" "${REG_MOD_ARGS[@]}" \
      || { bad "srvctl modify failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    # the old values, so --undo can say exactly how to put them back
    local od=""
    [[ " ${REG_MOD_ARGS[*]} " == *" -startoption "* ]] && od+="old=${REG_OLD_OPT:-unknown} "
    [[ " ${REG_MOD_ARGS[*]} " == *" -oraclehome "* ]] && od+="oldhome=${REG_OLD_HOME:--} "
    [[ " ${REG_MOD_ARGS[*]} " == *" -pwfile "* ]] && od+="oldpw=${REG_OLD_PW:--} "
    journal SRVOPT "$STANDBY_UNIQUE" "${od% }"
    return 0
  fi
  if [[ "$REG_MODE" == "re" ]]; then
    # the old registration is kept in a file first: if the new one cannot be added, it is there to put back
    local old="$STATE_DIR/srvctl_old_${STANDBY_UNIQUE}_$RUN_ID.txt"
    run_logged "srvctl config (before the new registration)" as_oracle "$DB_HOME/bin/srvctl" config database -db "$STANDBY_UNIQUE" || { bad "Cannot read the old registration. Nothing is changed."; return 1; }
    ( umask 077; printf '%s\n' "$RUN_OUT" > "$old" ) || { bad "Cannot save the old registration to $old. Nothing is changed."; return 1; }
    run_logged "srvctl stop" as_oracle "$DB_HOME/bin/srvctl" stop database -db "$STANDBY_UNIQUE" || true
    run_logged "srvctl remove" as_oracle "$DB_HOME/bin/srvctl" remove database -db "$STANDBY_UNIQUE" -noprompt || { bad "srvctl remove failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    if ! srv_add "$old"; then
      say "The new registration failed. The old registration is now added again."
      local radd back=0 diffl=""; radd=$(srv_add_cmd_from "$old")
      if srv_old_args "$old" && run_logged "srvctl add (the old registration)" as_oracle "${SRV_OLD_ARGS[@]}"; then
        back=1
        # the same as before? srvctl config is read again and compared, line by line, with the saved one
        if run_logged "srvctl config (after putting the old registration back)" as_oracle "$DB_HOME/bin/srvctl" config database -db "$STANDBY_UNIQUE"; then
          # diff: 0 = the same, 1 = different, anything else = it could not compare (never taken as the same)
          local dout drc=0; dout=$(diff <(srv_cfg_norm < "$old") <(printf '%s\n' "$RUN_OUT" | srv_cfg_norm) 2>&1) || drc=$?
          if [[ $drc -eq 0 ]]; then back=2
          elif [[ $drc -eq 1 ]]; then
            # only lines the old one did not have (no old value missing) count as the same registration
            diffl=$(sed -n 's/^< //p' <<< "$dout" | head -n 8); [[ -z "$diffl" ]] && back=2
          fi
        fi
      fi
      if [[ $back -eq 2 ]]; then
        say "The old registration is back: srvctl config shows the same values as before. The standby is not started: step 9.2 starts it."
      elif [[ $back -eq 1 ]]; then
        journal SRVCTL_OLD "$STANDBY_UNIQUE" "file=$old"
        { printf 'The old registration is added again, but not every value is the same as before.\n'
          if [[ -n "$diffl" ]]; then printf 'These values of the old registration are missing now:\n%s\n' "$(sed 's/^/  /' <<< "$diffl")"
          else printf 'The new srvctl config could not be compared with the old one.\n'; fi
          printf 'The old registration is saved in:  %s\n' "$old"
          printf 'Set the missing values with srvctl modify database (as %s).\n' "$ORACLE_USER"; } | hint
      else
        journal SRVCTL_OLD "$STANDBY_UNIQUE" "file=$old"
        { printf 'The old registration could not be put back. It is saved in:  %s\n' "$old"
          if [[ -n "$radd" ]]; then printf 'As %s:  %s\n' "$ORACLE_USER" "$radd"
          else printf 'Its values (add them with srvctl add database, as %s):\n%s\n' "$ORACLE_USER" "$(grep -iE '^(Database name|Oracle home|Spfile|Password file|Domain|Start options|Stop options|Database role|Management policy|Disk Groups|Database instance|Instance)' "$old" | sed 's/^/  /')"; fi
          printf 'Or start the standby by hand (as %s):  sqlplus / as sysdba  ->  startup mount\n' "$ORACLE_USER"; } | hint
      fi
      return 1
    fi
    journal SRVCTL_OLD "$STANDBY_UNIQUE" "file=$old"
    journal SRVCTL "$STANDBY_UNIQUE" "registered in Oracle Restart (role PHYSICAL_STANDBY, start option MOUNT)"
    return 0
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
      MOUNTED|OPEN) adg_note "$LSTATE"; NOW="Instance $STANDBY_SID is $LSTATE (no Oracle Restart on this server)"
                    logins_after_start || { KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="To check on this server ($(hostname -s))"; return 1; }; return 0 ;;
      IDLE) NOW="The standby instance is not running"; PLAN="As $ORACLE_USER:  sqlplus / as sysdba  ->  startup mount"; return 1 ;;
      STARTED) NOW="The instance is in NOMOUNT (started with the first pfile)"; PLAN="As $ORACLE_USER, on this server (standby instance $STANDBY_SID only):"$'\n'"  sqlplus / as sysdba  ->  shutdown immediate ; startup mount"$'\n'"The new start uses the spfile"; return 1 ;;
      *) NOW="Instance state: $LSTATE ($(ora_errors "$SQL_OUT"))"; return 2 ;;
    esac
  fi
  run_logged "srvctl status" as_oracle timeout 120 "$DB_HOME/bin/srvctl" status database -db "$STANDBY_UNIQUE" || true
  local srv_on=0
  # single instance: "Database is running."; otherwise the line of this instance counts (not any other line)
  grep -qiE "^[[:space:]]*(Database is running|Instance $STANDBY_SID is running)" <<< "$RUN_OUT" && srv_on=1
  if sql_local "select i.instance_name||'|'||i.status||'|'||d.database_role from v\$instance i, v\$database d;"; then
    local iname ist irole; IFS='|' read -r iname ist irole <<< "$(first_line)"
    if [[ $srv_on -eq 1 && "$iname" == "$STANDBY_SID" && "$irole" == "PHYSICAL STANDBY" && ( "$ist" == "MOUNTED" || "$ist" == "OPEN" ) ]]; then
      adg_note "$ist"; NOW="Running under Oracle Restart: instance $iname, $ist, $irole"
      logins_after_start || { KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="To check on this server ($(hostname -s))"; return 1; }
      return 0
    fi
    if [[ $srv_on -eq 0 ]]; then
      NOW="Instance $iname is $ist, but it was started by RMAN, not by Oracle Restart"
      PLAN="As $ORACLE_USER, on this server (standby instance $STANDBY_SID only):
sqlplus / as sysdba  ->  shutdown immediate
srvctl start database -db $STANDBY_UNIQUE"
      return 1
    fi
    NOW="Unexpected state: instance $iname, status $ist, role $irole"; return 2
  fi
  if [[ $srv_on -eq 1 ]] && grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    NOW="srvctl says the database is running, but ORACLE_SID=$STANDBY_SID is idle."$'\n'"The registration uses another instance name (step 9.1)"
    return 2
  fi
  NOW="The standby instance is not running"
  PLAN="As $ORACLE_USER:  srvctl start database -db $STANDBY_UNIQUE"
  return 1
}
d_9_2() {
  if ! use_grid; then
    [[ "$LSTATE" == "STARTED" ]] && { sql_local_long "shutdown immediate" || true; }
    sql_local_long "startup mount" || { bad "Startup mount failed ($(ora_errors "$SQL_OUT"))"; return 1; }
    journal INSTANCE "$STANDBY_SID" "startup mount (standby)"; return 0
  fi
  local_state
  if [[ "$LSTATE" != "IDLE" && "$LSTATE" != "NOSW" ]]; then
    say "Stopping the instance that RMAN started on this server"
    # it must really be down: srvctl start on an instance that still runs would not put it under Oracle Restart
    sql_local_long "shutdown immediate" || true
    local_state
    [[ "$LSTATE" == "IDLE" ]] || { bad "The instance did not stop (state $LSTATE; $(ora_errors "$SQL_OUT")). Oracle Restart cannot take it over."; return 1; }
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
  PLAN="On this server, in sqlplus / as sysdba (apply is stopped first if it runs):
$SRL_SQL"
  USING="Same size as the online logs of the primary"$'\n'"Per thread: one group more than the online groups"
  return 1
}
d_9_3() {
  local before after new
  # what is needed is worked out again now: logs added by hand since the check are not added a second time
  local rc=0; srl_statements sql_local || rc=$?
  [[ $rc -eq 2 ]] && { bad "Cannot read the redo logs of the standby ($(ora_errors "$SQL_OUT"))"; return 1; }
  [[ $rc -eq 0 ]] && { say "The standby logs are already there."; return 0; }
  SRL_SQL="alter system set standby_file_management=manual scope=memory;"$'\n'"$SRL_STMTS"$'\n'"alter system set standby_file_management=auto scope=memory;"
  # without the list of groups before, the new groups could not be told apart (the undo would drop them all)
  sql_local "select group# from v\$standby_log order by group#;" || { bad "Cannot read the standby logs ($(ora_errors "$SQL_OUT"))"; return 1; }
  before=$(tr -d ' ' <<< "$SQL_OUT")
  # apply is stopped while the logs are added, and started again afterwards (also after an error)
  local was_mrp=0
  if mrp_running; then sql_local "alter database recover managed standby database cancel;" || { bad "Cannot stop apply"; return 1; }; was_mrp=1; fi
  if ! sql_local "$SRL_SQL"; then
    local eo=$SQL_OUT
    sql_local "alter system set standby_file_management=auto scope=memory;" \
      || warn "standby_file_management could not be set back to AUTO. Set it by hand:  alter system set standby_file_management=auto scope=memory;"
    # groups that were added before the error are recorded too (they are undone with the step)
    sql_local "select group# from v\$standby_log order by group#;" && after=$(tr -d ' ' <<< "$SQL_OUT") || after=""
    new=$(comm -13 <(sort <<< "$before") <(sort <<< "$after") | sort -n | paste -sd' ' -)
    [[ -n "$new" ]] && journal SRL "$STANDBY_SID" "$new"
    SQL_OUT=$eo
    bad "Cannot add the standby redo logs ($(ora_errors "$SQL_OUT"))"
    grep -q 'ORA-01378' <<< "$SQL_OUT" && printf 'ORA-01378: the online logs of the primary use 4K blocks.\nThe disk group or file system here must have a 4K sector size.\n' | hint
    srl_apply_back $was_mrp
    return 1
  fi
  sql_local "select group# from v\$standby_log order by group#;" && after=$(tr -d ' ' <<< "$SQL_OUT") || after=""
  new=$(comm -13 <(sort <<< "$before") <(sort <<< "$after") | sort -n | paste -sd' ' -)
  [[ -n "$new" ]] && journal SRL "$STANDBY_SID" "$new"
  srl_apply_back $was_mrp || return 1
  return 0
}
srl_apply_back() {
  # $1 = 1: apply ran before step 9.3 stopped it; it is started again (1 when that fails)
  [[ "$1" == 1 ]] || return 0
  if sql_local "alter database recover managed standby database disconnect from session;"; then say "Redo apply is running again."; return 0; fi
  bad "Redo apply was stopped to add the standby logs and could not be started again ($(ora_errors "$SQL_OUT")). Step 9.4 starts it."
  return 1
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
arch_timer_state() {
  # ok | files (missing or different) | off (not enabled or not running) | failed (the last clean-up run failed)
  local t="/etc/systemd/system/$(arch_timer)" sv="/etc/systemd/system/$(arch_service)"
  [[ -f "$t" && "$(cat "$t")" == "$(arch_timer_text)" && -f "$sv" && "$(cat "$sv")" == "$(arch_service_text)" && -f "$(arch_script)" && "$(cat "$(arch_script)")" == "$(arch_script_text)" ]] || { printf files; return; }
  systemctl is-enabled --quiet "$(arch_timer)" 2>/dev/null && systemctl is-active --quiet "$(arch_timer)" 2>/dev/null || { printf off; return; }
  systemctl is-failed --quiet "$(arch_service)" 2>/dev/null && { printf failed; return; }
  printf ok
}
arch_timer_ok() { [[ "$(arch_timer_state)" == "ok" ]]; }
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
    arch_in_fra && NOW+=$'\n'"The recovery area deletes applied logs when it needs space." || NOW+=$'\n'"$(arch_timer) deletes applied logs older than one day in $ARCH_LOC every night"
    return 0
  fi
  NOW=""
  [[ $ARCH_POLICY_OK -eq 1 ]] || NOW="RMAN archivelog deletion policy of the standby: ${v/#-/not set}$([[ "$v" != "-" ]] && printf ', copied from the primary with the control file')."$'\n'"Without the right policy, applied logs are not deleted here."$'\n'"The disk fills up and redo transport stops (ORA-19809, ORA-00257)."
  local tst=""; [[ $tok -eq 1 ]] || tst=$(arch_timer_state)
  case "$tst" in
    "") ;;
    off)    NOW+="${NOW:+$'\n'}$(arch_timer) is not running (stopped or not enabled). Applied logs in $ARCH_LOC are not deleted." ;;
    failed) NOW+="${NOW:+$'\n'}The last run of $(arch_service) failed: $(journalctl -u "$(arch_service)" -n 20 --no-pager -o cat 2>/dev/null | grep -E 'RMAN-|ORA-' | tail -n 2 | tr '\n' ' ')"
            NOW+=$'\n'"Applied logs in $ARCH_LOC are not deleted. To see why:  journalctl -u $(arch_service)" ;;
    *)      NOW+="${NOW:+$'\n'}The archive destination $ARCH_LOC is not the recovery area. Oracle deletes nothing there by itself." ;;
  esac
  PLAN=""
  [[ $ARCH_POLICY_OK -eq 1 ]] || PLAN="As $ORACLE_USER on this server:"$'\n'"  rman target /  ->  CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;"
  [[ "$tst" == off ]] && PLAN+="${PLAN:+$'\n'}systemctl enable $(arch_timer)"$'\n'"systemctl start $(arch_timer)"
  [[ "$tst" == failed ]] && PLAN+="${PLAN:+$'\n'}Run the clean-up once now, to see that it works again:"$'\n'"systemctl reset-failed $(arch_service)"$'\n'"systemctl start $(arch_service)"
  [[ "$tst" == files ]] && PLAN+="${PLAN:+$'\n'}Add a daily systemd timer $(arch_timer) at 04:30."$'\n'"It runs $(arch_script) as $ORACLE_USER:"$'\n'"  rman target /  ->  delete noprompt archivelog all completed before 'sysdate-1';"$'\n'"Logs that are not applied yet are kept."
  USING="Nothing is changed on the primary. Its own policy belongs to its backups.
To see it there:  rman target /  ->  show archivelog deletion policy;
If RMAN backs up the primary, this policy there keeps logs until the standby has them:
  TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DEVICE TYPE <DISK or SBT>
NEVER set it on a primary that RMAN does not back up: its logs would never be deleted."
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
    [[ $lrc -eq 0 ]] || { bad "RMAN failed ($(ora_errors "$RUN_OUT"))"; return 1; }
    journal RMANCFG "$STANDBY_SID" "old=${old// /~}"
  fi
  local tst=ok; arch_in_fra || tst=$(arch_timer_state)
  if [[ "$tst" == off ]]; then
    run_cmds <<< "systemctl enable $(arch_timer)
systemctl start $(arch_timer)" || return 1
    journal UNIT "$(arch_timer)" "enabled and started again (it was off)"
  elif [[ "$tst" == failed ]]; then
    # the clean-up itself: deletes only logs that are applied and older than one day (as the timer does every night)
    run_cmds <<< "systemctl reset-failed $(arch_service)
systemctl start $(arch_service)" || { bad "The clean-up failed again. To see why:  journalctl -u $(arch_service)"; return 1; }
  elif [[ "$tst" == files ]]; then
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
    NOW="Redo apply (MRP) is running"
    # real-time apply needs standby redo logs that the standby can use; without them redo is applied from archived logs only
    if sql_local "select nvl(max(recovery_mode),'-') from v\$archive_dest_status where recovery_mode like 'MANAGED%';" && [[ "$(first_line)" != "-" && "$(first_line)" != *"REAL TIME"* ]]; then
      warn "Redo is applied from archived logs only, not in real time (recovery_mode = $(first_line))."$'\n'"Usually the standby redo logs cannot be used. Check step 9.3, and look in the alert log for:"$'\n'"ORA-19527, ORA-15046, ORA-15173, 'No standby redo logfiles'."
    fi
    # logins that phase 7 could not test (a run that starts after 9.2): the standby runs, so they are tested here
    logins_after_start || { KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="To check on this server ($(hostname -s))"; return 1; }
    return 0
  fi
  NOW="Redo apply (MRP) is not running"
  PLAN="On this server:  alter database recover managed standby database disconnect from session;"
  return 1
}
d_9_4() {
  if ! sql_local "alter database recover managed standby database disconnect from session;"; then
    bad "Cannot start redo apply ($(ora_errors "$SQL_OUT"))"
    grep -q 'ORA-01153' <<< "$SQL_OUT" && printf 'ORA-01153: another recovery session is active (an old MRP or a manual recover). Cancel it first:\n  alter database recover managed standby database cancel;\n' | hint
    grep -q 'ORA-01154' <<< "$SQL_OUT" && printf 'ORA-01154: the database is OPEN or opening. This script only mounts a physical standby.\n' | hint
    return 1
  fi
  # the command ran, so its undo (cancel) is recorded now; success needs an MRP process
  journal MRP "$STANDBY_SID" "redo apply started"
  local n=0; until mrp_running || [[ $n -ge 12 ]]; do sleep 5; n=$((n + 1)); done
  mrp_running || { bad "The start command was accepted, but no MRP process appeared within 60 seconds. See the alert log of $STANDBY_SID."; return 1; }
}

# ---- 9.5 ----
c_9_5() {
  need_built || return 2
  need_ssh || return 2
  find_dest || { NOW="Cannot read the log_archive_dest parameters on the primary"; return 2; }
  local d=$DEST_N
  p_param "log_archive_dest_$d" || { NOW="Query failed"; return 2; }
  if ! has_token "$PVAL" "SERVICE=${STANDBY_TNS^^}"; then
    NOW="log_archive_dest_$d on the primary does not point to this standby: $PVAL"
    PLAN="alter system set log_archive_dest_$d='service=$STANDBY_TNS async valid_for=(online_logfiles,primary_role) db_unique_name=$STANDBY_UNIQUE' scope=both;
alter system set log_archive_dest_state_$d=enable scope=both;
alter system switch logfile;"
    PLAN_UNDO="alter system set log_archive_dest_state_$d=defer scope=both;   (stops redo transport to this standby)"
    return 1
  fi
  prim_sql "select upper(value) from v\$parameter where name='log_archive_dest_state_$d';" || { NOW="Query failed"; return 2; }
  local st; st=$(first_line)
  # ORA- inside the error column would look like a failed query, so it is masked in SQL and restored here
  prim_sql "select status||'|'||nvl(replace(error,'ORA-','ORA_'),'-') from v\$archive_dest where dest_id=$d;" || { NOW="Query failed"; return 2; }
  local s e; IFS='|' read -r s e <<< "$(first_line)"; e=${e//ORA_/ORA-}
  if [[ "$st" == "ENABLE" && "$s" == "VALID" && "$e" == "-" ]]; then NOW="On the primary, dest_$d is ENABLE and VALID, with no error"; return 0; fi
  NOW="On the primary: log_archive_dest_state_$d=$st, dest_$d status $s, $([[ "$e" == "-" ]] && printf 'no error' || printf 'error %s' "$e")"
  PLAN="alter system set log_archive_dest_state_$d=enable scope=both;
alter system switch logfile;"
  PLAN_UNDO="alter system set log_archive_dest_state_$d=defer scope=both;   (stops redo transport to this standby)"
  if [[ "$e" != "-" ]]; then
    case "$e" in
      *16191*|*1017*) PLAN+=$'\n'"-- Cause: the password files differ (step 6.1)" ;;
      *12154*) PLAN+=$'\n'"-- Cause: alias $STANDBY_TNS is missing in tnsnames.ora on the primary (step 4.9)" ;;
      *12514*|*12541*) PLAN+=$'\n'"-- Cause: the listener of the standby (phase 5)" ;;
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
    rfs_running && { NOW="RFS is receiving redo from the primary"; return 0; }
    n=$((n + 1)); [[ $n -ge 6 || "$MODE" == "check" ]] && break
    say "Waiting for RFS ($n of 6)"; sleep 10
  done
  NOW="No RFS process on this server yet"
  PLAN="A quiet primary may send nothing for a while. To make it send redo now, on the PRIMARY (sqlplus / as sysdba):
  alter system switch logfile;
Then answer r. If RFS still does not start, check step 9.5 and the alert logs:
  standby: ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${STANDBY_UNIQUE,,}/$STANDBY_SID/trace/alert_$STANDBY_SID.log
  primary: ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${PRIMARY_UNIQUE,,}/$PRIMARY_SID/trace/alert_$PRIMARY_SID.log
In the alert log of the primary, look for ORA- errors near LOG_ARCHIVE_DEST_${DEST_N:-2}"
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
    printf '    case "$st" in MOUNTED|OPEN*) ;; *) echo "DG-BOOT-ERROR: standby is not mounted ($st)"; exit 1 ;; esac\n'
  else
    printf '    # a listener that already runs is fine (lsnrctl start then fails, status works)\n'
    printf '    $ORACLE_HOME/bin/lsnrctl start %s >/dev/null 2>&1 || $ORACLE_HOME/bin/lsnrctl status %s >/dev/null 2>&1 || echo "DG-BOOT-ERROR: listener %s did not start"\n' "$SB_LSNR" "$SB_LSNR" "$SB_LSNR"
    printf '    sql "startup mount"\n'
    printf '    st=$(sql "select status from v\\$instance;" 2>/dev/null | tr -d '"'"'[:space:]'"'"')\n'
    printf '    # not mounted (or open read only with Active Data Guard): the unit fails, nothing to stop cleanly\n'
    printf '    case "$st" in MOUNTED|OPEN*) ;; *) echo "DG-BOOT-ERROR: standby is not mounted ($st)"; exit 1 ;; esac\n'
  fi
  printf '    # mounted from here on: the unit stays active even when something below fails, because only an active\n'
  printf '    # unit runs its stop at shutdown (a clean stop of the standby). Errors go to the journal; step 9.7\n'
  printf '    # shows them and reports a missing listener or apply as a problem.\n'
  printf '    role=$(sql "select database_role from v\\$database;" 2>/dev/null | tr -s '"'"'[:space:]'"'"' '"'"' '"'"' | sed '"'"'s/^ //; s/ $//'"'"')\n'
  printf '    if [ "$role" != "PHYSICAL STANDBY" ]; then echo "DG-BOOT-ERROR: the database role is ${role:-unknown}, not PHYSICAL STANDBY: redo apply is not started"; exit 0; fi\n'
  printf '    # ORA-01153 = apply already runs\n'
  printf '    out=$(sql "alter database recover managed standby database disconnect from session;" 2>&1)\n'
  printf '    case "$out" in *ORA-01153*) ;; *ORA-*|*SP2-*) echo "DG-BOOT-ERROR: redo apply did not start: $(echo $out)" ;; esac\n'
  printf '    ;;\n  stop)\n'
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
C97_FIX=""
c_9_7() {
  C97_FIX=""
  command -v systemctl >/dev/null 2>&1 || { NOW="systemd is not found. Start the standby by hand after each reboot."; return 2; }
  need_built || return 2
  local u sc okd=1; u="/etc/systemd/system/$(unit_name)"; sc=$(start_script)
  need_udev_dropin && [[ "$(cat "$(udev_dropin)" 2>/dev/null)" != "$(dropin_text)" ]] && okd=0
  if [[ -f "$u" && "$(cat "$u")" == "$(unit_text)" && -f "$sc" && "$(cat "$sc")" == "$(script_text)" && $okd -eq 1 ]] && systemctl is-enabled --quiet "$(unit_name)" 2>/dev/null && ! systemctl is-failed --quiet "$(unit_name)" 2>/dev/null; then
    if use_grid; then NOW="$(unit_name) is enabled."$'\n'"It starts apply after Oracle Restart mounts the standby."
    else NOW="$(unit_name) is enabled."$'\n'"At boot: listener, startup mount, apply. At shutdown: a clean stop."; fi
    # what went wrong at the last start (since this boot): shown, the apply itself is checked in 9.4 and 10.x
    local berr; berr=$(journalctl -u "$(unit_name)" -b --no-pager -o cat 2>/dev/null | awk '/^Start(ing|ed) / {n = 0; next} /DG-BOOT-ERROR/ {e[++n] = $0} END {for (i = 1; i <= n && i <= 3; i++) print e[i]}')
    [[ -n "$berr" ]] && warn "At its last start, $(unit_name) reported:"$'\n'"${berr//DG-BOOT-ERROR: /}"
    # the unit stays active on purpose (so the shutdown still stops the standby): what it started is checked here.
    # A stopped listener or apply is started by the action of this step (asked first); a wrong role is not touched.
    local_state
    case "$LSTATE" in
      MOUNTED|OPEN) ;;
      IDLE)
        if use_grid; then
          # the unit waits for Oracle Restart to mount the standby, then starts apply: nothing to do here yet
          NOW+=$'\n'"The standby is not mounted now ($LSTATE). Oracle Restart mounts it (step 9.2); the unit then starts redo apply."
          CHECK_WAITS=1; return 0
        fi
        NOW="$(unit_name) is enabled, but the standby is not running now ($LSTATE)."
        C97_FIX=start; PLAN="systemctl restart $(unit_name)"$'\n'"-- It starts the listener, mounts the standby and starts redo apply."
        return 1 ;;
      *)
        # NOMOUNT (someone works on it by hand) or a state that cannot be read: never restarted by the script
        local oe=""; [[ "$LSTATE" == ERROR ]] && oe=$(ora_errors "$SQL_OUT")
        NOW="$(unit_name) is enabled, but the standby is $LSTATE${oe:+ ($oe)}, not mounted."
        PLAN="-- Find out why (alert log of $STANDBY_SID). When it is mounted again, answer r."
        MANUAL_WHERE="To check on this server ($(hostname -s))"; MANUAL_HOW="$ORACLE_USER  ->  sqlplus / as sysdba"
        return 2 ;;
    esac
    local role=""; sql_local "select database_role from v\$database;" && role=$(first_line)
    if [[ "$role" != "PHYSICAL STANDBY" ]]; then
      NOW="$(unit_name) is enabled, but the database role is ${role:-unknown}, not PHYSICAL STANDBY."
      PLAN="-- The unit starts redo apply only on a physical standby. Check what changed the role (a failover?)."$'\n'"-- Then answer r."
      MANUAL_WHERE="To check on this server ($(hostname -s))"; MANUAL_HOW="$ORACLE_USER"
      return 2
    fi
    if ! run_logged "lsnrctl status" as_lsnr timeout 60 "$(lsnr_home)/bin/lsnrctl" status "$SB_LSNR"; then
      NOW="$(unit_name) is enabled, but the listener $SB_LSNR is not running. The primary cannot send redo."
      C97_FIX=lsnr
      if use_grid; then PLAN="As $GRID_USER:  srvctl start listener -listener $SB_LSNR"
      else PLAN="As $ORACLE_USER:  lsnrctl start $SB_LSNR"; fi
      return 1
    fi
    if ! mrp_running; then
      NOW="$(unit_name) is enabled, but redo apply (MRP) is not running."
      if [[ "$LSTATE" == OPEN* ]]; then
        # apply on an open standby is Active Data Guard (a separate license): never started by the script
        NOW+=$'\n'"The standby is OPEN. Redo apply on an open standby needs the Active Data Guard license."
        PLAN="-- Either start apply (only with the Active Data Guard license), in sqlplus / as sysdba:"$'\n'"alter database recover managed standby database disconnect from session;"$'\n'"-- or restart the standby mounted (as $ORACLE_USER):  shutdown immediate ; startup mount"$'\n'"-- Then answer r."
        MANUAL_WHERE="Run on this server ($(hostname -s))"; MANUAL_HOW="$ORACLE_USER  ->  sqlplus / as sysdba"
        return 2
      fi
      C97_FIX=mrp; PLAN="On this server, in sqlplus / as sysdba:"$'\n'"alter database recover managed standby database disconnect from session;"
      return 1
    fi
    adg_note "$LSTATE"
    return 0
  fi
  if systemctl is-failed --quiet "$(unit_name)" 2>/dev/null; then
    NOW="$(unit_name) has failed: $(systemctl status "$(unit_name)" --no-pager -l 2>&1 | grep -iE 'Active:|ORA-|TNS-|error' | head -n 3 | tr '\n' ' ')"
  elif use_grid; then NOW="After a reboot, Oracle Restart mounts the standby, but nothing starts redo apply (MRP)"
  else NOW="Nothing starts the listener and the standby after a reboot (no Oracle Restart here)"; fi
  if use_grid; then PLAN="Create this script, owned by root. It runs as $ORACLE_USER, waits for MOUNT and starts apply:"$'\n'"  $sc"
  else PLAN="Create this script, owned by root. It runs as $ORACLE_USER:"$'\n'"  $sc"$'\n'"  at boot: lsnrctl start, startup mount, start apply"$'\n'"  at shutdown: shutdown immediate"; fi
  PLAN+=$'\n'"Create and enable this systemd unit:"$'\n'"  $u"$'\n'"It sets the Oracle limits (nofile, nproc, stack, memlock)."
  need_udev_dropin && PLAN+=$'\n'"Create this drop-in, so Oracle Restart starts after the ASM disks are ready:"$'\n'"  $(udev_dropin)"
  PLAN+=$'\n'"Start the unit once now, so the next shutdown stops the standby cleanly."
  if use_grid; then PLAN+=$'\n'"It waits until Oracle Restart has mounted the standby, then starts redo apply if it is not running."
  else PLAN+=$'\n'"A running standby stays as it is (redo apply is started if it is not running);"$'\n'"a standby that is down is started: listener, startup mount, redo apply."; fi
  USING="The standby is only mounted."$'\n'"Opening it read-only while apply runs needs the Active Data Guard license."
  return 1
}
d_9_7() {
  local sc u; sc=$(start_script); u="/etc/systemd/system/$(unit_name)"
  # the unit is right, but what it starts is not running: only that is started (on this server)
  case "$C97_FIX" in
    start) run_cmds <<< "systemctl restart $(unit_name)" || { bad "The unit did not start. Check:  systemctl status $(unit_name)"; return 1; }; return 0 ;;
    lsnr)
      if use_grid; then run_logged "srvctl start listener" as_grid "$GRID_HOME/bin/srvctl" start listener -listener "$SB_LSNR" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
      else run_logged "lsnrctl start" as_oracle timeout 120 "$DB_HOME/bin/lsnrctl" start "$SB_LSNR" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
           journal LSNRSTART "$SB_LSNR" "started from $DB_HOME"; fi
      return 0 ;;
    mrp) d_9_4; return ;;
  esac
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
  run_cmds <<< "systemctl start $(unit_name)" || { bad "The unit did not start. Check:  systemctl status $(unit_name)"; systemctl status "$(unit_name)" --no-pager -l 2>&1 | tail -n 8 | hint; return 1; }
}

phase_9() {
  phase_header 9 "Start redo apply and transport"
  run_step 9.1 auto    "Registration in Oracle Restart (srvctl)" c_9_1 d_9_1
  run_step 9.2 auto    "Standby instance running (MOUNT)" c_9_2 d_9_2
  run_step 9.3 auto    "Standby redo logs on this server" c_9_3 d_9_3
  run_step 9.4 auto    "Redo apply (MRP)" c_9_4 d_9_4
  run_step 9.5 primary "Redo transport from the primary" c_9_5
  run_step 9.6 check   "Redo arrives on this server (RFS)" c_9_6
  run_step 9.7 auto    "Start at boot (mount and apply)" c_9_7 d_9_7
  run_step 9.8 auto    "Clean-up of archived logs on the standby" c_9_8 d_9_8
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
    if [[ $tls -ge 0 && $tls -le 60 && $als -ge 0 && $als -le 60 ]]; then NOW="Transport lag $tl, apply lag $al"; return 0; fi
    tries=$((tries + 1)); [[ $tries -ge 12 || "$MODE" == "check" ]] && break
    say "Transport lag $tl, apply lag $al. Waiting 10 seconds ($tries of 12)"; sleep 10
  done
  NOW="The lag is too high or not known yet: transport '$tl', apply '$al'"
  PLAN="Empty values are normal for a few minutes after the setup.
To force a log switch, on the primary as $ORACLE_USER in sqlplus / as sysdba:
  alter system switch logfile;
Then answer r."
  return 1
}
c_10_2_once() {
  need_built || return 2
  sql_local "select count(*) from v\$archive_gap;" || { NOW="Cannot read v\$archive_gap"; return 2; }
  num "$(first_line)" || { NOW="Unexpected answer: $(first_line)"; return 2; }
  [[ "$(first_line)" -eq 0 ]] && { NOW="No archive gap"; return 0; }
  sql_local "select thread#||' '||low_sequence#||'-'||high_sequence# from v\$archive_gap;" || true
  NOW="Archive gap: $SQL_OUT"
  PLAN="fal_server usually fetches the missing logs within minutes. If the gap stays, check:
  grep -iE 'FAL|gap|ORA-' ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${STANDBY_UNIQUE,,}/$STANDBY_SID/trace/alert_$STANDBY_SID.log | tail -30"
  return 1
}
c_10_3_once() {
  # every enabled redo thread of the primary (a RAC primary has more than thread 1; a disabled thread of an
  # old RAC sends no redo any more and is left out)
  need_built || return 2
  need_ssh || return 2
  prim_sql "select thread#||' '||max(sequence#) from v\$archived_log where standby_dest='NO' and resetlogs_change#=(select resetlogs_change# from v\$database) and thread# in (select thread# from v\$thread where enabled<>'DISABLED') group by thread# order by thread#;" || { NOW="Cannot read the primary"; return 2; }
  local pout sout t p a line behind="" info=""
  pout=$(grep -E '^[[:space:]]*[0-9]+ [0-9]+[[:space:]]*$' <<< "$SQL_OUT")
  sql_local "select thread#||' '||max(sequence#) from v\$archived_log where applied in ('YES','IN-MEMORY') and resetlogs_change#=(select resetlogs_change# from v\$database) group by thread# order by thread#;" || { NOW="Cannot read the standby"; return 2; }
  sout=$(grep -E '^[[:space:]]*[0-9]+ [0-9]+[[:space:]]*$' <<< "$SQL_OUT")
  [[ -n "$pout" ]] || { NOW="The primary has no archived log yet in this incarnation"; return 2; }
  local -A applied=()
  while read -r t a; do [[ -n "$t" ]] && applied[$t]=$a; done <<< "$sout"
  while read -r t p; do
    [[ -n "$t" ]] || continue
    a=${applied[$t]:-0}
    line="Thread $t: last log archived on the primary $p, applied on the standby $a"
    info+="${info:+$'\n'}$line"
    [[ $a -ge $((p - 1)) ]] || behind+="${behind:+$'\n'}$line"
  done <<< "$pout"
  if [[ -z "$behind" ]]; then NOW=$info; return 0; fi
  NOW="Apply is behind:"$'\n'"$behind"
  PLAN="Wait a few minutes for apply to catch up, then answer r."
  return 1
}
# a gap or a standby that is a few logs behind is often gone within a minute or two (fal_server, apply catching
# up): checked again 6 times (every POLL_WAIT seconds, 2 minutes by default) before it is reported (not in check mode)
poll_check() {
  # $1 the check, $2 what is waited for (shown)
  local rc tries=0
  while true; do
    rc=0; "$1" || rc=$?
    [[ $rc -eq 1 ]] || return $rc
    tries=$((tries + 1)); [[ $tries -ge 6 || "$MODE" == "check" ]] && return 1
    say "${NOW%%$'\n'*}. $2 Checked again in $POLL_WAIT seconds ($tries of 6)"; sleep "$POLL_WAIT"
  done
}
c_10_2() { poll_check c_10_2_once "fal_server fetches missing logs."; }
c_10_3() { poll_check c_10_3_once "Apply catches up."; }
c_10_4() {
  need_built || return 2
  if mrp_running; then
    NOW="Redo apply (MRP) is running"
    # real-time apply uses a standby log that receives the redo. None in use, or Data Guard errors of the last
    # 15 minutes: the step waits (checked again in the next run), it is not OK. Older errors are shown.
    local w=""
    # no standby log at all is not a matter of waiting: step 9.3 adds them
    if sql_local "select group# from v\$standby_log order by group#;" && [[ -z "$(grep -E '^[[:space:]]*[0-9]+' <<< "$SQL_OUT")" ]]; then
      NOW="Redo apply (MRP) is running, but this standby has no standby redo logs. Redo is applied only from archived logs."
      PLAN="Add them with step 9.3:  $SELF --only 9.3"; KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="Run on this server ($(hostname -s))"
      return 1
    fi
    if sql_local "select count(*) from v\$standby_log where status='ACTIVE';" && [[ "$(first_line)" == "0" ]]; then
      w+=$'\n'"No standby redo log is in use (none is ACTIVE). Redo arrives only as archived logs,"$'\n'"so the lag grows by whole log files. Check step 9.3 and the alert log (ORA-19527, ORA-15046)."
    fi
    if sql_local "select count(*) from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > sysdate-1/96;" && num "$(first_line)" && [[ "$(first_line)" != "0" ]]; then
      local n=$(first_line) msgs=""
      # the messages hold ORA- codes themselves, so the query "fails" by the usual rule: its lines are shown anyway
      sql_local "select message from (select message from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > sysdate-1/96 order by timestamp desc) where rownum <= 3;" || true
      msgs=$(sed 's/^[[:space:]]*//' <<< "$SQL_OUT" | grep -v '^$' | head -n 3 | sed 's/^/  /')
      w+=$'\n'"$n Data Guard error message(s) in the last 15 minutes${msgs:+:}"${msgs:+$'\n'"$msgs"}
    elif sql_local "select count(*) from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > sysdate-1;" && num "$(first_line)" && [[ "$(first_line)" != "0" ]]; then
      warn "$(first_line) Data Guard error message(s) on this standby in the last 24 hours (none in the last 15 minutes). To see them:"$'\n'"select timestamp, message from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp;"
    fi
    if [[ -n "$w" ]]; then
      NOW+="$w"$'\n'"Run the script again in a few minutes. If this stays, see:  $SELF --help-step 10.4"
      CHECK_WAITS=1
    fi
    return 0
  fi
  NOW="Redo apply (MRP) is not running"; PLAN="Start it (step 9.4), on this server:"$'\n'"  alter database recover managed standby database disconnect from session;"; return 1
}

phase_10() {
  phase_header 10 "Health check"
  run_step 10.1 check "Transport and apply lag" c_10_1
  run_step 10.2 check "No archive gap" c_10_2
  run_step 10.3 check "Last log: primary and standby" c_10_3
  run_step 10.4 check "Redo apply is running" c_10_4
}
