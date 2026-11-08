#------------------------------------------------------------------------------
# PHASE 9  Oracle Restart registration, standby redo logs, apply, shipping
#------------------------------------------------------------------------------
DG_DEAD_NOTE=""; REG_MODE=""; REG_OLD_OPT=""; REG_OLD_HOME=""; REG_OLD_PW=""; REG_MOD_ARGS=(); REG_OLD_DG=""; REG_NEW_DG=""; REG_OLD_DOM=""

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
ASM_DGS=""; ASM_MISSING=""
asm_dg_names() {
  # the disk groups of this server -> ASM_DGS (upper case, one per line; may be empty). 1 = they cannot be read
  # (a failed query is never taken as "none")
  ASM_DGS=""; ASM_MISSING=""
  sql_asm "select name from v\$asm_diskgroup;" || return 1
  ASM_DGS=$(tr -d ' \t\r' <<< "$SQL_OUT" | tr '[:lower:]' '[:upper:]' | grep -v '^$')
  # v$asm_diskgroup lists every disk group whose disks ASM sees, mounted or not. One the standby needs that is
  # not there (ASM started before its disks, for example): the list is taken as not complete ("cannot be read"),
  # never as "the others are gone"
  local g
  for g in $(srv_dgs | tr ',' ' '); do
    grep -Fqx -- "$g" <<< "$ASM_DGS" || ASM_MISSING+=" $g"
  done
  [[ -z "$ASM_MISSING" ]] || { ASM_DGS=""; return 1; }
  return 0
}
dg_union() {
  # $1 $2 comma lists of disk groups -> one list, upper case, each once, in the order first seen
  printf '%s,%s' "$1" "$2" | tr ',' '\n' | tr -d ' \t\r' | tr '[:lower:]' '[:upper:]' | grep -v '^$' | awk '!s[$0]++' | paste -sd, -
}
c_9_1() {
  use_grid || { NOW="Not needed: no Oracle Restart on this server. Step 9.7 sets up the start at boot."; return 0; }
  need_built || return 2
  local srv="$DB_HOME/bin/srvctl" spf; spf=$(spfile_path)
  [[ -f "$spf" ]] || { NOW="The spfile is missing: $spf"; return 2; }
  local add="srvctl add database -db $STANDBY_UNIQUE -oraclehome $DB_HOME -spfile $spf -pwfile $(pw_dest) -role PHYSICAL_STANDBY -startoption MOUNT -dbname $DB_NAME -instance $STANDBY_SID -diskgroup $(srv_dgs)${PRIMARY_DOMAIN:+ -domain $PRIMARY_DOMAIN}"
  DG_DEAD_NOTE=""
  if run_logged "srvctl config database" as_oracle timeout 600 "$srv" config database -db "$STANDBY_UNIQUE"; then
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
    # the disk groups the standby needs (missing ones: Oracle Restart may start it before they are mounted);
    # disk groups the registration has besides them are kept
    local cdg want_dg; cdg=$(sed -n 's/^Disk Groups:[[:space:]]*//Ip' <<< "$cfg" | head -n 1 | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'); REG_OLD_DG=$cdg
    want_dg=$(dg_union "$cdg" "$(srv_dgs)")
    [[ "$want_dg" == "$(dg_union "$cdg" "")" ]] || { bad_items+=" diskgroup"; REG_NEW_DG=$want_dg; }
    # the domain of the primary's db_domain (an empty one in the registration is a missing one)
    local cdom; cdom=$(sed -n 's/^Domain:[[:space:]]*//Ip' <<< "$cfg" | head -n 1 | sed 's/[[:space:]]*$//'); REG_OLD_DOM=$cdom
    [[ -z "$PRIMARY_DOMAIN" || "${cdom,,}" == "${PRIMARY_DOMAIN,,}" ]] || bad_items+=" domain"
    # the other way round: registered disk groups ASM here does not see, a domain the primary does not set.
    # A list that cannot be read: waiting
    local x have_dg="" dg_unread=0
    if asm_dg_names; then have_dg=$ASM_DGS; else dg_unread=1; fi
    if [[ $dg_unread -eq 1 && -n "$cdg" ]]; then
      if [[ -n "$ASM_MISSING" ]]; then DG_DEAD_NOTE="ASM here does not show the disk group(s)${ASM_MISSING} the standby needs (are their disks there?): whether all registered ones ($cdg) exist is not checked."
      else DG_DEAD_NOTE="The disk groups of this server could not be read: whether all registered ones ($cdg) exist is not checked."; fi
    fi
    # registered disk groups (besides the needed ones) that ASM here does not see: named. They are not taken out
    # by the script: one whose disks come later would be lost from the registration
    local dead="" live=""
    if [[ $dg_unread -eq 0 ]]; then
      for x in ${cdg//,/ }; do if grep -Fqx -- "$x" <<< "$have_dg"; then live+="${live:+,}$x"; else dead+=" $x"; fi; done
      [[ -n "$dead" ]] && warn "The registration names disk group(s) that ASM here does not see:$dead"$'\n'"If they are gone for good, set the list by hand (as $ORACLE_USER):  srvctl modify database -db $STANDBY_UNIQUE -diskgroup $(dg_union "$live" "$(srv_dgs)")"
    fi
    [[ -z "$PRIMARY_DOMAIN" && -n "$cdom" ]] && warn "The registration has the domain $cdom, but the primary sets no db_domain."$'\n'"It is kept: the domain only forms the service names, and changing it may cut clients that use them."$'\n'"If it is not wanted, change it by hand:  srvctl modify database -db $STANDBY_UNIQUE -domain <new>"
    if [[ -z "$bad_items" ]]; then
      NOW="Registered in Oracle Restart: role PHYSICAL_STANDBY, instance $STANDBY_SID"
      # (on the first line: the run summary and the progress file keep it)
      [[ -n "$dead" ]] && NOW+="; it still names disk group(s) ASM here does not see:$dead"
      NOW+=$'\n'"spfile: $spf"
      [[ -n "$DG_DEAD_NOTE" ]] && { NOW+=$'\n'"$DG_DEAD_NOTE"; CHECK_WAITS=1; }
      return 0
    fi
    NOW="Registered, but these values are wrong:$bad_items"$'\n'"$(grep -iE '^(spfile|database role|database instance|instance|start options|oracle home|password file|disk groups|domain)' <<< "$cfg")"
    [[ -n "$DG_DEAD_NOTE" ]] && NOW+=$'\n'"$DG_DEAD_NOTE"
    # a new registration or a disk-group change while the disk groups cannot be read: not now (the old disk
    # groups could not be kept, and the standby would be stopped for nothing)
    if [[ $dg_unread -eq 1 && "$bad_items" =~ (spfile|role|instance|diskgroup) ]]; then
      NOW+=$'\n'"The registration is changed when the disk groups of this server can be read again (ASM running)."
      return 2
    fi
    # a new registration with a disk group ASM does not see could fail (its resource may be gone), and then the
    # old one could not be put back either: the list is set by hand first
    if [[ -n "$dead" && "$bad_items" =~ (spfile|role|instance) ]]; then
      NOW+=$'\n'"A new registration is needed, but it names disk group(s) that ASM here does not see:$dead"
      KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="To do on this server ($(hostname -s))"
      PLAN="-- If those disk groups are gone for good, take them out of the registration first:"$'\n'"srvctl modify database -db $STANDBY_UNIQUE -diskgroup $(dg_union "$live" "$(srv_dgs)")"$'\n'"-- If their disks only come later, wait until ASM sees them. Then answer r."
      return 1
    fi
    REG_OLD_OPT=$(sed -n 's/^Start options:[[:space:]]*//Ip' <<< "$cfg" | head -n 1 | tr -cd 'A-Za-z ' | tr ' ' '_')
    # start option, home and password file are changed in place (the running standby is not stopped);
    # a wrong spfile, role or instance needs a new registration
    # (srvctl modify cannot empty the disk-group list: when none would be left, the standby is registered anew)
    if [[ "$bad_items" != *spfile* && "$bad_items" != *role* && "$bad_items" != *instance* ]] && ! [[ "$bad_items" == *diskgroup* && -z "$REG_NEW_DG" ]]; then
      REG_MODE=modify; REG_MOD_ARGS=()
      [[ "$bad_items" == *start-option* ]] && REG_MOD_ARGS+=(-startoption MOUNT)
      [[ "$bad_items" == *oracle-home* ]] && REG_MOD_ARGS+=(-oraclehome "$DB_HOME")
      [[ "$bad_items" == *password-file* ]] && REG_MOD_ARGS+=(-pwfile "$(pw_dest)")
      [[ "$bad_items" == *diskgroup* ]] && REG_MOD_ARGS+=(-diskgroup "$REG_NEW_DG")
      [[ "$bad_items" == *domain* ]] && REG_MOD_ARGS+=(-domain "$PRIMARY_DOMAIN")
      PLAN="As $ORACLE_USER, on this server only:
srvctl modify database -db $STANDBY_UNIQUE ${REG_MOD_ARGS[*]}"
      return 1
    fi
    REG_MODE=re
    # the command shown is made from the same values as the action (policy, stop option, disk groups, domain)
    local cf; cf=$(mktemp) || return 2; CLEANUP_FILES+=("$cf"); printf '%s\n' "$cfg" > "$cf"
    srv_new_args "$cf"; rm -f -- "$cf"
    add="srvctl add database ${SRV_NEW[*]}"
    PLAN="As $ORACLE_USER, on this server only:
srvctl stop database -db $STANDBY_UNIQUE
srvctl remove database -db $STANDBY_UNIQUE -noprompt
$add"
    [[ -n "$SRV_DG_LOST" ]] && PLAN+=$'\n'"The disk groups of the old registration cannot be read ($SRV_DG_LOST): only the needed ones are set."
    PLAN+=$'\n'"The management policy, stop option, disk groups and domain of the old registration are kept."$'\n'"The old registration is saved first. If the new one cannot be added, the old one is added again;"$'\n'"settings it had beyond these (for example services) are then listed, to set again by hand."
    return 1
  fi
  # only "the resource could not be found" means not registered; another failure (CRS down, a timeout) is unknown
  if ! grep -qE 'PRCD-1120|PRCR-1001|could not be found|does not exist' <<< "$RUN_OUT"; then
    NOW="srvctl config database -db $STANDBY_UNIQUE failed: $(tail -n 2 <<< "$RUN_OUT" | tr '\n' ' ')"; return 2
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
srv_new_args() {
  # $1 (optional) saved "srvctl config database" of an earlier registration -> SRV_NEW: the arguments of the
  # new "srvctl add database"; SRV_KEPT: what is kept from the old one (management policy, stop option, its
  # disk groups besides the needed ones, its domain when the primary has none set). SRV_DG_LOST: an old disk
  # group list that cannot be read (named, never dropped in silence). One function for the plan and the action.
  local pol="" sto="" odg="" odom="" dgs dom=$PRIMARY_DOMAIN keep=()
  SRV_KEPT=(); SRV_DG_LOST=""; SRV_DG_UNREAD=""; dgs=$(srv_dgs)
  if [[ -n "${1:-}" && -s "$1" ]]; then
    pol=$(_cfgv "$1" 'Management policy'); sto=$(_cfgv "$1" 'Stop options')
    [[ "$pol" =~ ^[A-Za-z]+$ ]] && { keep+=(-policy "$pol"); SRV_KEPT+=(-policy "$pol"); }
    [[ "$sto" =~ ^[A-Za-z]+$ ]] && { keep+=(-stopoption "$sto"); SRV_KEPT+=(-stopoption "$sto"); }
    odg=$(_cfgv "$1" 'Disk Groups' | tr -d ' \t\r')
    if [[ "$odg" =~ ^[A-Za-z0-9_\$#,]+$ ]]; then
      # kept as they are (9.1 stops before a new registration that names a disk group ASM does not see; the list
      # cannot be checked when ASM cannot be read: then named, and the action stops before in that case)
      asm_dg_names || SRV_DG_UNREAD=$odg
      dgs=$(dg_union "$dgs" "$odg"); [[ "$dgs" != "$(dg_union "$(srv_dgs)" "")" ]] && SRV_KEPT+=(-diskgroup "$dgs")
    elif [[ -n "$odg" ]]; then SRV_DG_LOST=$odg; fi
    odom=$(_cfgv "$1" 'Domain')
    [[ -z "$dom" && "$odom" =~ ^[A-Za-z0-9_.-]+$ ]] && { dom=$odom; SRV_KEPT+=(-domain "$dom"); }
  fi
  SRV_NEW=( -db "$STANDBY_UNIQUE" -oraclehome "$DB_HOME" -spfile "$(spfile_path)" -pwfile "$(pw_dest)"
    -role PHYSICAL_STANDBY -startoption MOUNT -dbname "$DB_NAME" -instance "$STANDBY_SID" )
  [[ -n "$dgs" ]] && SRV_NEW+=(-diskgroup "$dgs")
  [[ -n "$dom" ]] && SRV_NEW+=(-domain "$dom")
  SRV_NEW+=("${keep[@]}")
  return 0
}
srv_add() {
  # $1 (optional) saved "srvctl config database" of an earlier registration: see srv_new_args
  srv_new_args "${1:-}"
  # ASM stopped answering after the check (during stop/remove): no new registration with an unchecked list. The
  # caller puts the old registration back
  if [[ -n "$SRV_DG_UNREAD" && -n "${1:-}" ]]; then bad "The disk groups of this server cannot be read now (old ones: $SRV_DG_UNREAD). The new registration is not added."; return 1; fi
  [[ -n "$SRV_DG_LOST" ]] && warn "The disk groups of the old registration cannot be read ($SRV_DG_LOST). Only the ones the standby needs are set:"$'\n'"$(srv_dgs). Add others again with:  srvctl modify database -db $STANDBY_UNIQUE -diskgroup <list>"
  run_logged "srvctl add database" as_oracle timeout 600 "$DB_HOME/bin/srvctl" add database "${SRV_NEW[@]}" || { bad "srvctl add failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  [[ ${#SRV_KEPT[@]} -gt 0 ]] && say "Kept from the old registration: ${SRV_KEPT[*]}"
  return 0
}
d_9_1() {
  if [[ "$REG_MODE" == "modify" ]]; then
    run_logged "srvctl modify database" as_oracle timeout 600 "$DB_HOME/bin/srvctl" modify database -db "$STANDBY_UNIQUE" "${REG_MOD_ARGS[@]}" \
      || { bad "srvctl modify failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    # the old values, so --undo can say exactly how to put them back
    local od=""
    [[ " ${REG_MOD_ARGS[*]} " == *" -startoption "* ]] && od+="old=${REG_OLD_OPT:-unknown} "
    [[ " ${REG_MOD_ARGS[*]} " == *" -oraclehome "* ]] && od+="oldhome=${REG_OLD_HOME:--} "
    [[ " ${REG_MOD_ARGS[*]} " == *" -pwfile "* ]] && od+="oldpw=${REG_OLD_PW:--} "
    [[ " ${REG_MOD_ARGS[*]} " == *" -diskgroup "* ]] && od+="olddg=${REG_OLD_DG:--} "
    [[ " ${REG_MOD_ARGS[*]} " == *" -domain "* ]] && od+="olddom=${REG_OLD_DOM:--} "
    journal SRVOPT "$STANDBY_UNIQUE" "${od% }"
    return 0
  fi
  if [[ "$REG_MODE" == "re" ]]; then
    # the old registration is kept in a file first: if the new one cannot be added, it is there to put back
    local old="$STATE_DIR/srvctl_old_${STANDBY_UNIQUE}_$RUN_ID.txt"
    run_logged "srvctl config (before the new registration)" as_oracle timeout 600 "$DB_HOME/bin/srvctl" config database -db "$STANDBY_UNIQUE" || { bad "Cannot read the old registration. Nothing is changed."; return 1; }
    ( umask 077; printf '%s\n' "$RUN_OUT" > "$old" ) || { bad "Cannot save the old registration to $old. Nothing is changed."; return 1; }
    # the disk groups are read again right before (ASM may have stopped since the check): no new registration
    # that would lose the old disk groups
    if ! asm_dg_names; then bad "The disk groups of this server cannot be read now${ASM_MISSING:+ (missing:$ASM_MISSING)}. Nothing is changed."; return 1; fi
    run_logged "srvctl stop" as_oracle timeout 600 "$DB_HOME/bin/srvctl" stop database -db "$STANDBY_UNIQUE" || true
    run_logged "srvctl remove" as_oracle timeout 600 "$DB_HOME/bin/srvctl" remove database -db "$STANDBY_UNIQUE" -noprompt || { bad "srvctl remove failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    if ! srv_add "$old"; then
      say "The new registration failed. Adding the old registration again."
      local radd back=0 diffl=""; radd=$(srv_add_cmd_from "$old")
      if srv_old_args "$old" && run_logged "srvctl add (the old registration)" as_oracle "${SRV_OLD_ARGS[@]}"; then
        back=1
        # the same as before? srvctl config is read again and compared, line by line, with the saved one
        if run_logged "srvctl config (after putting the old registration back)" as_oracle timeout 600 "$DB_HOME/bin/srvctl" config database -db "$STANDBY_UNIQUE"; then
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
  # neither "is running" nor "is not running" (a CRS error, a timeout): it is not known who started the instance,
  # and a running standby is never stopped on a guess
  if ! grep -qiE 'is (not )?running' <<< "$RUN_OUT"; then
    NOW="srvctl status database -db $STANDBY_UNIQUE gave no answer: $(tail -n 2 <<< "$RUN_OUT" | tr '\n' ' ')"; return 2
  fi
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
  # a failed run first: its fix (step 9.8) also turns the timer on again, so both are done in one run
  systemctl is-failed --quiet "$(arch_service)" 2>/dev/null && { printf failed; return; }
  systemctl is-enabled --quiet "$(arch_timer)" 2>/dev/null && systemctl is-active --quiet "$(arch_timer)" 2>/dev/null || { printf off; return; }
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
  if [[ "$tst" == files ]]; then
    # files that are there but different (a schedule set by hand, for example) are named: they are replaced
    local af differ=""
    for af in "/etc/systemd/system/$(arch_timer)|$(arch_timer_text)" "/etc/systemd/system/$(arch_service)|$(arch_service_text)" "$(arch_script)|$(arch_script_text)"; do
      [[ -f "${af%%|*}" && "$(cat "${af%%|*}")" != "${af#*|}" ]] && differ+="  ${af%%|*}"$'\n'
    done
    [[ -n "$differ" ]] && PLAN+="${PLAN:+$'\n'}These files are there but different (for example a time set by hand). They are replaced; a backup is kept:"$'\n'"${differ%$'\n'}"
  fi
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
    if ! { systemctl is-enabled --quiet "$(arch_timer)" 2>/dev/null && systemctl is-active --quiet "$(arch_timer)" 2>/dev/null; }; then
      run_cmds <<< "systemctl enable $(arch_timer)
systemctl start $(arch_timer)" || return 1
      journal UNIT "$(arch_timer)" "enabled and started again (it was off)"
    fi
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
  # the command ran, so its undo (cancel) is recorded either way; the journal says what was seen
  local n=0; until mrp_running || [[ $n -ge 12 ]]; do nap 5; n=$((n + 1)); done
  if mrp_running; then journal MRP "$STANDBY_SID" "redo apply started"; return 0; fi
  journal MRP "$STANDBY_SID" "redo apply start command accepted, no MRP process seen"
  bad "The start command was accepted, but no MRP process appeared within 60 seconds. See the alert log of $STANDBY_SID."; return 1
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
    PLAN_UNDO="(stops redo transport to this standby)  alter system set log_archive_dest_state_$d=defer scope=both;"
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
  PLAN_UNDO="(stops redo transport to this standby)  alter system set log_archive_dest_state_$d=defer scope=both;"
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
    n=$((n + 1)); [[ $n -gt 6 || "$MODE" == "check" ]] && break
    say "Waiting for RFS ($n of 6)"; nap 10
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
    printf '    case "$st" in MOUNTED|OPEN*) ;; *) echo "<3>DG-BOOT-ERROR: standby is not mounted ($st)"; exit 1 ;; esac\n'
  else
    printf '    # a listener that already runs is fine (lsnrctl start then fails, status works)\n'
    printf '    $ORACLE_HOME/bin/lsnrctl start %s >/dev/null 2>&1 || $ORACLE_HOME/bin/lsnrctl status %s >/dev/null 2>&1 || echo "<3>DG-BOOT-ERROR: listener %s did not start"\n' "$SB_LSNR" "$SB_LSNR" "$SB_LSNR"
    printf '    sql "startup mount"\n'
    printf '    st=$(sql "select status from v\\$instance;" 2>/dev/null | tr -d '"'"'[:space:]'"'"')\n'
    printf '    # not mounted (or open read only with Active Data Guard): the unit fails, nothing to stop cleanly\n'
    printf '    case "$st" in MOUNTED|OPEN*) ;; *) echo "<3>DG-BOOT-ERROR: standby is not mounted ($st)"; exit 1 ;; esac\n'
  fi
  printf '    # mounted from here on: the unit stays active even when something below fails, because only an active\n'
  printf '    # unit runs its stop at shutdown (a clean stop of the standby). Errors go to the journal with priority\n'
  printf '    # "err" (the <3> prefix), so a journal alert sees them; step 9.7 shows them and starts what is missing.\n'
  printf '    role=$(sql "select database_role from v\\$database;" 2>/dev/null | tr -s '"'"'[:space:]'"'"' '"'"' '"'"' | sed '"'"'s/^ //; s/ $//'"'"')\n'
  printf '    if [ "$role" != "PHYSICAL STANDBY" ]; then echo "<3>DG-BOOT-ERROR: the database role is ${role:-unknown}, not PHYSICAL STANDBY: redo apply is not started"; exit 0; fi\n'
  printf '    # an open standby: apply there is Active Data Guard (a separate license), never started from here\n'
  printf '    case "$st" in OPEN*) echo "<3>DG-BOOT-ERROR: the standby is open ($st), not mounted: redo apply is not started (Active Data Guard needs its own license)"; exit 0 ;; esac\n'
  printf '    # ORA-01153 = apply already runs\n'
  printf '    out=$(sql "alter database recover managed standby database disconnect from session;" 2>&1)\n'
  printf '    case "$out" in *ORA-01153*) ;; *ORA-*|*SP2-*) echo "<3>DG-BOOT-ERROR: redo apply did not start: $(printf "%%s" "$out" | tr "\\n" " ")" ;; esac\n'
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
DGERR_PREV=""
BOOT_ERR_SHOWN=0
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
    local berr; berr=$(boot_errors_now)
    [[ -n "$berr" ]] && { warn "At its last start, $(unit_name) reported:"$'\n'"$berr"; BOOT_ERR_SHOWN=1; }
    # the unit stays active on purpose (so the shutdown still stops the standby): what it started is checked here.
    # A stopped listener or apply is started by the action of this step (asked first); a wrong role is not touched.
    local_state
    if [[ "$LSTATE" == IDLE || "$LSTATE" == STARTED ]] && use_grid; then
      # the standby was mounted by step 9.2 in this run and is down now: it stopped, waiting does not help
      if [[ "$LSTATE" == IDLE ]] && [[ "${STEP_RESULT[9.2]:-}" == OK || "${STEP_RESULT[9.2]:-}" == DONE ]]; then
        NOW="$(unit_name) is enabled, but the standby stopped after step 9.2 mounted it in this run ($LSTATE)."
        PLAN="-- Find out why: the alert log of $STANDBY_SID, and as $ORACLE_USER:"$'\n'"srvctl status database -db $STANDBY_UNIQUE -verbose"$'\n'"-- Start it with:  srvctl start database -db $STANDBY_UNIQUE   Then answer r."
        MANUAL_WHERE="To check on this server ($(hostname -s))"; MANUAL_HOW="$ORACLE_USER"
        return 2
      fi
      # Oracle Restart often mounts it within minutes (after a reboot): looked at again a few times, at most
      # 5 minutes in all whatever POLL_WAIT is
      local n=0 pw=$POLL_WAIT; [[ $pw -gt 50 ]] && pw=50
      # (STARTED on the way: Oracle Restart is mounting it, so it is looked at again too)
      while [[ "$MODE" != check && ( "$LSTATE" == IDLE || "$LSTATE" == STARTED ) && $n -lt 6 ]]; do
        n=$((n + 1)); say "The standby is not mounted yet. Oracle Restart starts it. Checked again in $pw seconds ($n of 6)"
        nap "$pw"; local_state
      done
      # still in NOMOUNT after step 9.2 mounted it in this run: not a matter of waiting
      if [[ "$LSTATE" == STARTED && $n -gt 0 ]] && [[ "${STEP_RESULT[9.2]:-}" == OK || "${STEP_RESULT[9.2]:-}" == DONE ]]; then
        NOW="$(unit_name) is enabled, but the standby stays in NOMOUNT after step 9.2 mounted it in this run."
        PLAN="-- Find out why: the alert log of $STANDBY_SID, and as $ORACLE_USER:"$'\n'"srvctl status database -db $STANDBY_UNIQUE -verbose"$'\n'"-- Then answer r."
        MANUAL_WHERE="To check on this server ($(hostname -s))"; MANUAL_HOW="$ORACLE_USER"
        return 2
      fi
      if [[ "$LSTATE" == IDLE || ( "$LSTATE" == STARTED && $n -gt 0 ) ]]; then
        [[ "$LSTATE" == STARTED ]] && NOW+=$'\n'"It is started (NOMOUNT) but not mounted yet."
        # the unit waits for Oracle Restart to mount the standby, then starts apply: nothing to do here yet
        NOW+=$'\n'"The standby is not mounted now ($LSTATE). Oracle Restart mounts it (step 9.2); the unit then starts redo apply."
        NOW+=$'\n'"If it stays so, as $ORACLE_USER:  srvctl status database -db $STANDBY_UNIQUE -verbose  (and the alert log)"
        CHECK_WAITS=1; return 0
      fi
    fi
    case "$LSTATE" in
      MOUNTED|OPEN) ;;
      IDLE)
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
boot_errors_now() {
  # what the boot unit reported at the start of this boot (empty when nothing, no unit or no journal)
  command -v journalctl >/dev/null 2>&1 && declare -F unit_name >/dev/null || return 0
  [[ -n "${STANDBY_SID:-}" ]] || return 0
  systemctl is-enabled --quiet "$(unit_name)" 2>/dev/null || return 0
  journalctl -u "$(unit_name)" -b --no-pager -o cat 2>/dev/null | awk '/^Start(ing|ed) / {n = 0; next} /DG-BOOT-ERROR/ {e[++n] = $0} END {for (i = 1; i <= n && i <= 3; i++) print e[i]}' | sed 's/^<[0-7]>//; s/DG-BOOT-ERROR: //'
}
boot_err_hint() {
  # the unit stays active after an error at boot (so the shutdown stays clean): its errors are in the journal
  printf 'What went wrong at a boot is logged with priority "err". To see it (or to alert on it):\n  journalctl -p err -u %s\n' "$(unit_name)" | hint
}
d_9_7() {
  local sc u; sc=$(start_script); u="/etc/systemd/system/$(unit_name)"
  # the unit is right, but what it starts is not running: only that is started (on this server)
  case "$C97_FIX" in
    start) run_cmds <<< "systemctl restart $(unit_name)" || { bad "The unit did not start. Check:  systemctl status $(unit_name)"; return 1; }; boot_err_hint; return 0 ;;
    lsnr)
      if use_grid; then run_logged "srvctl start listener" as_grid timeout 600 "$GRID_HOME/bin/srvctl" start listener -listener "$SB_LSNR" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
      else run_logged "lsnrctl start" as_oracle timeout 120 "$DB_HOME/bin/lsnrctl" start "$SB_LSNR" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }; fi
      journal LSNRSTART "$SB_LSNR" "started from $(lsnr_home)$(use_grid && printf ' via=srvctl')"
      boot_err_hint; return 0 ;;
    mrp) d_9_4 || return 1; boot_err_hint; return 0 ;;
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
  boot_err_hint
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
dg_error_hint() {
  # $1 text with Oracle error codes (messages of v$dataguard_status, the error of a redo destination).
  # Prints one line per known code: the usual cause and what to do. Codes it does not know give nothing.
  local t=$1 seen="" c h
  for c in $(grep -oE 'ORA-[0-9]{5}' <<< "$t" | sort -u); do
    case "$c" in
      ORA-16191|ORA-01017|ORA-01031)
        h="password file differs between primary and standby (often after a sys password change on the primary): copy it again:  $SELF --only 6.1" ;;
      ORA-28374)
        h="TDE wallet here is missing a master key of the primary (often after a key change there): copy it again:  $SELF --only 6.3" ;;
      ORA-28365|ORA-28417|ORA-28353)
        h="TDE wallet here is not open (no auto-login wallet, or it cannot be read): see step 6.3" ;;
      ORA-12541|ORA-12514|ORA-12528|ORA-12505)
        h="the listener or the service of the standby is not reachable: check the listener here (steps 5.1 to 5.3)" ;;
      ORA-12170|ORA-12535|ORA-12543|ORA-12547|ORA-03113|ORA-03135|ORA-16198)
        h="network between the servers (firewall, routing, dropped connections): check port $PORT/tcp both ways (step 2.9)" ;;
      ORA-00257|ORA-19809|ORA-19815|ORA-19804|ORA-16038)
        h="archive destination or recovery area is full: free space, or check the clean-up of archived logs (step 9.8)" ;;
      ORA-01274|ORA-01111)
        h="a datafile added on the primary could not be created here (standby_file_management, space or path): see the alert log of the standby" ;;
      ORA-16086)
        h="the standby has no usable standby redo logs for the redo it receives: see step 9.3" ;;
      ORA-16058)
        h="the standby instance is not mounted: see step 9.2" ;;
      ORA-16055|ORA-16401)
        h="fetching a missing log (FAL) failed or a log was received twice: usually gone within minutes" ;;
      ORA-16057|ORA-16047)
        h="log_archive_config of the primary and of the standby do not name each other: see step 4.3" ;;
      *) continue ;;
    esac
    # one line per cause (two codes of the same cause are named once)
    grep -qxF -- "$h" <<< "$seen" && continue
    seen+="$h"$'\n'
    printf '  %s: %s\n' "$c" "$h"
  done
  return 0
}
lag_seconds() {
  local v=$1
  if [[ "$v" =~ ^\+?([0-9]+)[[:space:]]+([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
    printf '%s' $(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]} ))
  else printf '%s' -1; fi
}
c_10_1() {
  need_built || return 2
  # the limit: 60 seconds in a run in the terminal (it waits up to 2 minutes for a peak to pass); --health uses
  # HEALTH_LAG_MAX of the settings (default 300 seconds), as a daily run must not raise an alarm for a peak
  local lim=60; [[ ${HEALTH:-0} -eq 1 ]] && lim=$((10#${HEALTH_LAG_MAX:-300})); [[ $lim -lt 30 ]] && lim=30
  local tries=0 tl al tls als age
  while true; do
    NOW=""
    # datum_time: when the standby last received data from the primary. v$dataguard_stats keeps its last
    # values when nothing arrives any more, so a lag of 0 on a broken link would look healthy without it
    sql_local "select nvl(max(decode(name,'transport lag',value)),'-')||'|'||nvl(max(decode(name,'apply lag',value)),'-')||'|'||nvl(to_char(max(case when name='transport lag' and datum_time is not null then round((sysdate-to_date(datum_time,'MM/DD/YYYY HH24:MI:SS'))*86400) end)),'-') from v\$dataguard_stats;" || { NOW="Cannot read v\$dataguard_stats"; return 2; }
    IFS='|' read -r tl al age <<< "$(first_line)"
    tls=$(lag_seconds "$tl"); als=$(lag_seconds "$al")
    if [[ $tls -ge 0 && $tls -le $lim && $als -ge 0 && $als -le $lim ]]; then
      if [[ "$age" =~ ^[0-9]+$ && $age -gt $lim ]]; then
        NOW="No data from the primary for $age seconds (the last lag values, transport $tl and apply $al, are old)"
      else
        NOW="Transport lag $tl, apply lag $al"; return 0
      fi
    fi
    tries=$((tries + 1)); [[ $tries -ge 12 || "$MODE" == "check" ]] && break
    say "Transport lag $tl, apply lag $al. Waiting 10 seconds ($tries of 12)"; nap 10
  done
  if [[ "$NOW" != "No data from the primary"* ]]; then NOW="The lag is too high or not known yet: transport '$tl', apply '$al' (limit $lim seconds)"; fi
  # what the primary says about its redo destination for this standby (read-only): the most direct reason
  # (the error column holds ORA- text, so the query "fails" by the usual rule: only its marked lines are used,
  # and "no destination" is said only when the query itself worked)
  if ssh_alive; then
    local prc=0 dl did dst der
    prim_sql "select distinct 'DEST:'||dest_id||'|'||status||'|'||nvl(error,'-') from gv\$archive_dest where upper(db_unique_name)=upper('$STANDBY_UNIQUE') and target='STANDBY';" || prc=1
    # a RAC primary gives one line per instance: a line with an error first
    dl=$(sed -n 's/^[[:space:]]*DEST://p' <<< "$SQL_OUT" | awk -F'|' '{print ($3 == "-" ? 1 : 0) "\t" $0}' | sort -k1,1n | cut -f2- | head -n 1)
    if [[ "$dl" =~ ^[0-9]+\|[A-Z_\ ]+\| ]]; then
      IFS='|' read -r did dst der <<< "$(tr -cd '[:print:]' <<< "$dl")"
      NOW+=$'\n'"On the primary, log_archive_dest_$did for this standby: $dst$([[ "$der" != "-" ]] && printf ', error: %s' "$der")"
      local hx; hx=$(dg_error_hint "$der"); [[ -n "$hx" ]] && NOW+=$'\n'"Usual cause:"$'\n'"$hx"
    elif [[ $prc -eq 0 ]]; then
      NOW+=$'\n'"No redo destination of the primary names db_unique_name=$STANDBY_UNIQUE (step 9.5 sets it)."
    fi
  fi
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
  local gaps; gaps=$(grep -E '^[[:space:]]*[0-9]+ [0-9]+-[0-9]+[[:space:]]*$' <<< "$SQL_OUT" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  NOW="Archive gap: ${gaps:-$SQL_OUT}"
  PLAN="fal_server usually fetches the missing logs within minutes. If the gap stays, check:
  grep -iE 'FAL|gap|ORA-' ${DIAG_DEST:-$ORACLE_BASE}/diag/rdbms/${STANDBY_UNIQUE,,}/$STANDBY_SID/trace/alert_$STANDBY_SID.log | tail -30"
  # are the missing logs still on the disk of the primary? (fal_server can send only those; read-only)
  local t r lo hi have gone=""
  if [[ -n "$gaps" ]] && ssh_alive; then
    while read -r t r; do
      lo=${r%-*}; hi=${r#*-}
      num "$t" && num "$lo" && num "$hi" || continue
      prim_sql "select count(distinct sequence#) from v\$archived_log where thread#=$t and sequence# between $lo and $hi and deleted='NO' and status='A' and name is not null and standby_dest='NO' and resetlogs_change#=(select resetlogs_change# from v\$database);" || { gone=""; break; }
      have=$(first_line); num "$have" || { gone=""; break; }
      [[ $have -lt $((hi - lo + 1)) ]] && gone+="  thread $t, sequence $lo to $hi"$'\n'
    done <<< "$gaps"
  fi
  if [[ -n "$gone" ]]; then
    NOW+=$'\n'"Some of these logs are no longer on the disk of the primary, so fal_server cannot send them:"$'\n'"${gone%$'\n'}"
    PLAN="-- 1) Restore them on the primary from its backup (RMAN there, as $ORACLE_USER), for each line above:"
    while read -r t r; do PLAN+=$'\n'"restore archivelog from sequence ${r%-*} until sequence ${r#*-} thread $t;"; done <<< "$gaps"
    PLAN+=$'\n'"--    fal_server then sends them within minutes."
    if [[ ${DB_MAJOR:-0} -ge 18 ]]; then PLAN+=$'\n'"-- 2) Or, without the logs, roll the standby forward from the primary:  $SELF --roll-forward"
    else PLAN+=$'\n'"-- 2) Or make a new copy of the standby (phase 8)."; fi
  fi
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
    say "${NOW%%$'\n'*}. $2 Checked again in $POLL_WAIT seconds ($tries of 6)"; nap "$POLL_WAIT"
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
    local w="" n
    # a view that cannot be read is no proof of health: rc 2, the same rule as 10.3
    sql_local "select group# from v\$standby_log order by group#;" || { NOW+=$'\n'"Cannot read v\$standby_log: $(ora_errors "$SQL_OUT")"; return 2; }
    # no standby log at all is not a matter of waiting: step 9.3 adds them
    if [[ -z "$(grep -E '^[[:space:]]*[0-9]+' <<< "$SQL_OUT")" ]]; then
      NOW="Redo apply (MRP) is running, but this standby has no standby redo logs. Redo is applied only from archived logs."
      PLAN="Add them with step 9.3:  $SELF --only 9.3"; KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="Run on this server ($(hostname -s))"
      [[ -z "$RESUME_STEP" ]] && RESUME_STEP=9.3
      return 1
    fi
    sql_local "select count(*) from v\$standby_log where status='ACTIVE';" && n=$(first_line) && num "$n" || { NOW+=$'\n'"Cannot read the state of the standby redo logs: $(ora_errors "$SQL_OUT")"; return 2; }
    if [[ "$n" == "0" ]]; then
      w+=$'\n'"No standby redo log is in use (none is ACTIVE). Redo arrives only as archived logs,"$'\n'"so the lag grows by whole log files. Check step 9.3 and the alert log (ORA-19527, ORA-15046)."
    fi
    sql_local "select count(*) from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > sysdate-1/96;" && n=$(first_line) && num "$n" || { NOW+=$'\n'"Cannot read v\$dataguard_status: $(ora_errors "$SQL_OUT")"; return 2; }
    if [[ "$n" != "0" ]]; then
      local msgs=""
      # the messages hold ORA- codes themselves, so the query "fails" by the usual rule: its lines are shown anyway
      sql_local "select message from (select message from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > sysdate-1/96 order by timestamp desc) where rownum <= 3;" || true
      msgs=$(sed 's/^[[:space:]]*//; s/[^[:print:]]//g' <<< "$SQL_OUT" | grep -v '^$' | head -n 3 | sed 's/^/  /')
      w+=$'\n'"$n Data Guard error message(s) in the last 15 minutes${msgs:+:}"${msgs:+$'\n'"$msgs"}
      local hint_txt; hint_txt=$(dg_error_hint "$msgs"); [[ -n "$hint_txt" ]] && w+=$'\n'"Usual cause:"$'\n'"$hint_txt"
    else
      sql_local "select count(*) from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > sysdate-1;" && n=$(first_line) && num "$n" || { NOW+=$'\n'"Cannot read v\$dataguard_status: $(ora_errors "$SQL_OUT")"; return 2; }
      if [[ "$n" != "0" ]]; then
        # errors that keep coming between runs (newer than the ones the last run saw, but not in the last 15
        # minutes) are a condition, not a start-up message: waiting. The same old ones again: only shown
        # --health keeps its own memory: a daily run and an interactive one must not move each other's baseline
        local last="" prev="" lf; lf="$STATE_DIR/dg_errors_seen_$([[ ${HEALTH:-0} -eq 1 ]] && printf 'health_')$STANDBY_SID"
        sql_local "select nvl(to_char(max(timestamp),'YYYYMMDDHH24MISS'),'-') from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > sysdate-1;" && last=$(first_line)
        [[ "$last" =~ ^[0-9]{14}$ || "$last" == "-" ]] || { NOW+=$'\n'"Cannot read the time of the newest Data Guard error: $(ora_errors "$SQL_OUT")"; return 2; }
        # the value of the previous run, read once per run (a second look in this run compares with it too)
        [[ -n "$DGERR_PREV" ]] || DGERR_PREV="x$(cat "$lf" 2>/dev/null)"
        prev=${DGERR_PREV#x}
        if [[ "$last" =~ ^[0-9]{14}$ && "$prev" =~ ^[0-9]{14}$ && "$last" > "$prev" ]]; then
          # the messages newer than the last run (they hold ORA- codes, so the query "fails" by the usual rule:
          # its lines are used only when the session itself worked)
          local nm="" mq="select 'DGMSG:'||message from (select message from v\$dataguard_status where severity in ('Error','Fatal') and timestamp > to_date('$prev','YYYYMMDDHH24MISS') order by timestamp desc) where rownum <= 3;"
          sql_local "$mq" || true
          # only lines of the view (marked DGMSG:), never sqlplus' own error text
          nm=$(sed -n 's/^[[:space:]]*DGMSG://p' <<< "$SQL_OUT" | sed 's/[^[:print:]]//g' | head -n 3 | sed 's/^/  /')
          w+=$'\n'"New Data Guard error messages came since the last run (the newest at ${last:0:4}-${last:4:2}-${last:6:2} ${last:8:2}:${last:10:2}),"$'\n'"though none in the last 15 minutes${nm:+:}"${nm:+$'\n'"$nm"}
          [[ -n "$nm" ]] || w+=$'\n'"To see them:  select timestamp, message from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp;"
          local hint2; hint2=$(dg_error_hint "$nm"); [[ -n "$hint2" ]] && w+=$'\n'"Usual cause:"$'\n'"$hint2"
        else
          warn "$n Data Guard error message(s) on this standby in the last 24 hours (none in the last 15 minutes). To see them:"$'\n'"select timestamp, message from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp;"
        fi
        [[ ( "$MODE" != check || ${HEALTH:-0} -eq 1 ) && "$last" =~ ^[0-9]{14}$ ]] && { install -d -m 700 "$STATE_DIR" 2>/dev/null; printf '%s\n' "$last" > "$lf"; }
      fi
    fi
    if [[ -n "$w" ]]; then
      NOW+="$w"$'\n'"Run the script again in a few minutes. If this stays, see:  $SELF --help-step 10.4"
      CHECK_WAITS=1
    fi
    return 0
  fi
  NOW="Redo apply (MRP) is not running"; PLAN="Start it (step 9.4), on this server:"$'\n'"  alter database recover managed standby database disconnect from session;"; return 1
}

# ---- 10.5 ----
c_10_5() {
  # NOLOGGING work on the primary writes no redo for the data: the standby gets only a note that those blocks
  # are invalid, and the error shows only when the data is read (ORA-01578 / ORA-26040), often after a failover.
  # The proof is the standby's list of such blocks (12.2 and later); force logging on the primary is advice.
  # Read-only on both sides
  need_built || return 2
  need_ssh || return 2
  prim_sql "select force_logging from v\$database;" || { NOW="Cannot read force_logging of the primary: $(ora_errors "$SQL_OUT")"; return 2; }
  local fl n b fnote=""
  fl=$(first_line | sed 's/[[:space:]]*$//')
  [[ -n "$fl" ]] || { NOW="Cannot read force_logging of the primary (no answer)"; return 2; }
  if [[ "${PRIMARY_VERSION:-0}" =~ ^12\.1 ]]; then
    # 12.1 keeps no list of nonlogged blocks on a standby: only force logging can be looked at
    fnote="12.1 keeps no list of nonlogged blocks: only force logging is checked."
  else
    sql_local "select count(*)||' '||nvl(sum(blocks),0) from v\$nonlogged_block;" || { NOW="Cannot read v\$nonlogged_block on the standby: $(ora_errors "$SQL_OUT")"; return 2; }
    read -r n b <<< "$(first_line)"
    num "$n" && num "$b" || { NOW="Unexpected answer from the standby: $(first_line)"; return 2; }
    if [[ $n -gt 0 ]]; then
      NOW="$b block(s) in $n range(s) were changed on the primary without redo (NOLOGGING). They are not usable here."
      KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="On this server ($(hostname -s))"
      PLAN="-- Fetch these blocks from the primary:
-- 1) sqlplus / as sysdba:  alter database recover managed standby database cancel;
-- 2) rman target /:        recover database nonlogged block;
-- 3) sqlplus / as sysdba:  alter database recover managed standby database disconnect from session;
-- So it does not happen again, on the primary:  alter database force logging;"
      return 1
    fi
  fi
  case "${fl^^}" in
    YES) if [[ -n "$fnote" ]]; then NOW="Force logging is on at the primary. $fnote"; CHECK_WAITS=3; else NOW="No unrecoverable changes; force logging is on at the primary"; fi; return 0 ;;
    "STANDBY NOLOGGING"*)
      # 18c and later, set on purpose: the list of nonlogged blocks above is the proof for this standby
      if [[ -n "$fnote" ]]; then NOW="The primary uses $fl (set on purpose). $fnote"; CHECK_WAITS=3; else NOW="No unrecoverable changes. The primary uses $fl (set on purpose)."; fi; return 0 ;;
  esac
  NOW="$([[ -n "$fnote" ]] && printf 'Force logging is off at the primary' || printf 'No unrecoverable changes so far, but force logging is off at the primary') (force_logging = $fl)."$'\n'"A NOLOGGING load there would leave unusable blocks on the standby. On the primary:  alter database force logging;"$'\n'"(Force logging set per PDB or per tablespace is not looked at here.)${fnote:+$'\n'$fnote}"
  CHECK_WAITS=1
  return 0
}
# ---- 10.6 ----
c_10_6() {
  # the patches of the database home here and on the primary (folder names in inventory/oneoffs, read-only on
  # the primary). A difference is normal for a short time (standby-first patching), so it is "attention", not a
  # failure; a home that cannot be read is "cannot check"
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  need_ssh || return 2
  local pp lp onlyp onlyh
  pp=$(primary_patches "$DB_HOME") || { NOW="Cannot read $DB_HOME/inventory on the primary (the ssh user must be able to read it)"; return 2; }
  [[ -d "$DB_HOME/inventory" ]] || { NOW="Cannot read $DB_HOME/inventory on this server"; return 2; }
  lp=$(local_patches "$DB_HOME")
  onlyp=$(comm -23 <(grep -v '^$' <<< "$pp") <(grep -v '^$' <<< "$lp") | paste -sd' ' -)
  onlyh=$(comm -13 <(grep -v '^$' <<< "$pp") <(grep -v '^$' <<< "$lp") | paste -sd' ' -)
  if [[ -z "$onlyp$onlyh" ]]; then
    local np; np=$(grep -c . <<< "$lp")
    NOW="The database homes have the same patches ($np $([[ $np -eq 1 ]] && printf 'patch' || printf 'patches'))"; return 0
  fi
  NOW="The database homes do not have the same patches:"
  [[ -n "$onlyp" ]] && NOW+=$'\n'"  only on the primary: $onlyp"
  [[ -n "$onlyh" ]] && NOW+=$'\n'"  only here: $onlyh"
  NOW+=$'\n'"This is normal for a short time while a Release Update is applied standby first."$'\n'"Finish it on both servers; datapatch runs only on the primary. See:  $SELF --help-step 10.6"
  CHECK_WAITS=1
  return 0
}
# ---- 10.7 (only with --roll-forward) ----
RF_DONE=0; RF_FINISH=0
rf_pending_file() { printf '%s/rollforward_pending' "$STATE_DIR"; }
rf_login_test() {
  # RMAN logs in to the standby (as target, the way the roll forward does) and to the primary alias (the
  # same credentials are used for FROM SERVICE). The password travels on stdin only
  local ltmp lrc=0
  ltmp=$(mktemp /tmp/dg_out.XXXXXXXX) || { NOW="Cannot create a temporary file"; return 2; }
  CLEANUP_FILES+=("$ltmp")
  { printf 'connect target sys/"%s"@%s\n' "$SYS_PW" "$PRIMARY_TNS"; printf 'connect auxiliary sys/"%s"@%s\n' "$SYS_PW" "$STANDBY_TNS"; printf 'exit\n'; } \
    | as_oracle timeout 120 "$DB_HOME/bin/rman" > "$ltmp" 2>&1 || lrc=1
  RUN_OUT=$(mask_pw < "$ltmp"); rm -f -- "$ltmp"
  printf '%s\n(exit code %s)\n' "$RUN_OUT" "$lrc" | log_block "rman login test (roll forward)"
  grep -q 'connected to target database' <<< "$RUN_OUT" && grep -q 'connected to auxiliary database' <<< "$RUN_OUT" && return 0
  NOW="RMAN cannot log in to both databases with the sys password: $(grep -E '(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ')"
  local hx; hx=$(dg_error_hint "$RUN_OUT"); [[ -n "$hx" ]] && NOW+=$'\n'"Usual cause:"$'\n'"$hx"
  return 1
}
c_10_7() {
  # RECOVER STANDBY DATABASE FROM SERVICE (18c and later): the standby fetches the changes it misses from the
  # primary as incremental backups, instead of a whole new copy. Only when asked for (--roll-forward). Every
  # condition is read first; any doubt stops before a change
  [[ $RF_DONE -eq 1 ]] && { NOW="The standby was rolled forward in this run"; return 0; }
  RF_FINISH=0
  if job_alive; then NOW="A long job runs: $JOB_TITLE (session $JOB_PID). Wait for it to end."; return 2; fi
  # a roll forward of an earlier run that ended while no run was watching (terminal closed): its result is
  # checked and its clean-up done now; RMAN is not started again for it
  local pf; pf=$(rf_pending_file)
  if [[ -f "$pf" ]]; then
    local plog prc
    IFS='|' read -r plog prc < "$pf"
    if [[ "$prc" == "0" && -f "$plog" ]] && ! grep -qE '^RMAN-0(3002|3009)|ERROR MESSAGE STACK' "$plog"; then
      local_state
      [[ "$LSTATE" == MOUNTED ]] || { NOW="The roll forward of an earlier run has ended, but the standby is not mounted ($LSTATE). Start it (step 9.2), then run again."; return 2; }
      RF_FINISH=1
      NOW="The roll forward of an earlier run has ended without error (output: $plog)."$'\n'"It was not checked yet, and redo apply is stopped."
      PLAN="-- Check the standby, set its standby redo logs and RMAN settings again (9.3, 9.8) and start redo apply.
-- RMAN is not run again."
      return 1
    fi
    # it did not finish: said, and the roll forward may be started again (every check below runs first)
    warn "The roll forward of an earlier run did not finish (exit code ${prc:-unknown}; output: ${plog:-unknown}). Redo apply is stopped."
    rm -f -- "$pf"
  fi
  need_built || return 2
  need_ssh || return 2
  if [[ ${DB_MAJOR:-0} -lt 18 ]]; then
    # not something to answer r to: the script cannot do it on this release (shown, recorded as waiting)
    NOW="Release $DB_MAJOR has no single roll-forward command (it came with 18c). The script does not do it here."$'\n'"By hand: Oracle note 1987763.1 (stop redo apply; in RMAN  recover database from service $PRIMARY_TNS noredo;"$'\n'"restore the standby control file from service $PRIMARY_TNS; catalog and switch the datafiles; restore the"$'\n'"datafiles added since; start redo apply). Or make a new copy (phase 8)."
    CHECK_WAITS=1; return 0
  fi
  local_state
  case "$LSTATE" in
    MOUNTED) ;;
    OPEN) NOW="The standby is OPEN. The roll forward needs it mounted."; KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="On this server, sqlplus / as sysdba"
          PLAN="shutdown immediate"$'\n'"startup mount"; return 1 ;;
    IDLE|STARTED) NOW="The standby instance is not mounted ($LSTATE). Start it first (step 9.2)."; return 2 ;;
    *) NOW="The state of the standby instance cannot be read: $(ora_errors "$SQL_OUT")"; return 2 ;;
  esac
  # RMAN restarts the instance itself: it must find the server parameter file in the usual place
  [[ -f "$DB_HOME/dbs/spfile$STANDBY_SID.ora" || -f "$DB_HOME/dbs/init$STANDBY_SID.ora" ]] \
    || { NOW="Neither $DB_HOME/dbs/spfile$STANDBY_SID.ora nor init$STANDBY_SID.ora exists: RMAN could not restart the instance."; return 2; }
  local v
  sql_local "select upper(value) from v\$parameter where name='dg_broker_start';" || { NOW="Cannot read the standby: $(ora_errors "$SQL_OUT")"; return 2; }
  v=$(first_line)
  if [[ "$v" == "TRUE" ]]; then
    NOW="The Data Guard broker runs on the standby. It would start redo apply again during the roll forward, so the"$'\n'"script does not do it. By hand:  dgmgrl: edit database '$STANDBY_UNIQUE' set state='APPLY-OFF';"$'\n'"then  rman target sys@$STANDBY_TNS: recover standby database from service $PRIMARY_TNS;"$'\n'"then  dgmgrl: edit database '$STANDBY_UNIQUE' set state='APPLY-ON';"
    CHECK_WAITS=1; return 0
  fi
  sql_local "select count(*) from v\$session where upper(program) like 'RMAN%';" && v=$(first_line) && num "$v" || { NOW="Cannot read the sessions of the standby: $(ora_errors "$SQL_OUT")"; return 2; }
  [[ $v -eq 0 ]] || { NOW="An RMAN session is connected to the standby ($v). Wait until it ends."; return 2; }
  # the control file of the primary names the primary's files. RMAN finds the standby's own files again only
  # when the names are the same, or a convert parameter or OMF (db_create_file_dest) tells where they are
  local sfiles pfiles cfd="-" dfc="-" n vv how=""
  sql_local "select name||'|'||nvl(value,'-') from v\$parameter where name in ('db_create_file_dest','db_file_name_convert');" || { NOW="Cannot read the standby: $(ora_errors "$SQL_OUT")"; return 2; }
  while IFS='|' read -r n vv; do n=${n//[[:space:]]/}; case "$n" in db_create_file_dest) cfd=$vv ;; db_file_name_convert) dfc=$vv ;; esac; done <<< "$SQL_OUT"
  sql_local "select 'F:'||file#||'|'||name from v\$datafile order by file#;" || { NOW="Cannot read the datafiles of the standby: $(ora_errors "$SQL_OUT")"; return 2; }
  sfiles=$(sed -n 's/^[[:space:]]*F://p' <<< "$SQL_OUT")
  prim_sql "select 'F:'||file#||'|'||name from v\$datafile order by file#;" || { NOW="Cannot read the datafiles of the primary: $(ora_errors "$SQL_OUT")"; return 2; }
  pfiles=$(sed -n 's/^[[:space:]]*F://p' <<< "$SQL_OUT")
  [[ -n "$sfiles" && -n "$pfiles" ]] || { NOW="No datafiles could be read on the standby or the primary"; return 2; }
  # the files both have (a file added on the primary since, or an UNNAMED placeholder here, is restored anyway)
  local same=1 fno fn pn
  while IFS='|' read -r fno fn; do
    [[ -n "$fno" ]] || continue
    [[ "$fn" == *UNNAMED* ]] && continue
    pn=$(grep -m1 "^$fno|" <<< "$pfiles" | cut -d'|' -f2-)
    [[ -z "$pn" || "$pn" == "$fn" ]] || { same=0; break; }
  done <<< "$sfiles"
  if [[ $same -eq 1 ]]; then how="the datafiles have the same names on both servers"
  elif [[ "$dfc" != "-" ]]; then how="db_file_name_convert of the standby maps the names"
  elif [[ "$cfd" != "-" ]] && ! cut -d'|' -f2- <<< "$sfiles" | grep -v UNNAMED | grep -qviF -- "$cfd/" \
       && ! cut -d'|' -f2- <<< "$sfiles" | grep -v UNNAMED | grep -qvE '^\+[^/]+/.+\.[0-9]+\.[0-9]+$|/o1_mf_[^/]+$'; then how="the standby's datafiles are Oracle-managed files in $cfd"
  else
    NOW="The standby's datafiles have other names than the primary's, and neither db_file_name_convert nor"$'\n'"Oracle-managed files (db_create_file_dest) would let RMAN find them again after the roll forward."$'\n'"The script does not roll this standby forward. Make a new copy (phase 8), or set db_file_name_convert on"$'\n'"the standby (scope=spfile, then restart) to map the primary's folders to the standby's, and run again."
    CHECK_WAITS=1; return 0
  fi
  # TDE: RMAN restarts the instance; an encrypted standby needs a wallet that opens by itself
  [[ ${TDE_UNREAD:-0} -eq 1 ]] && { NOW="Whether the primary uses TDE cannot be read (step 1.3), so the wallet of the standby cannot be judged."; return 2; }
  if awk -F'|' '$3 == "OPEN" {f=1} END {exit !f}' <<< "$TDE_INFO"; then
    sql_local "select wallet_type||'|'||status from v\$encryption_wallet;" || { NOW="Cannot read the wallet of the standby: $(ora_errors "$SQL_OUT")"; return 2; }
    grep -qE '^[[:space:]]*(LOCAL_)?AUTOLOGIN\|OPEN[[:space:]]*$' <<< "$SQL_OUT" || { NOW="The primary uses TDE, but the wallet of the standby does not open by itself (no open AUTOLOGIN wallet). Step 6.3."; return 2; }
  fi
  # the alias of the standby must reach the instance while it is restarted: a static entry in the listener
  run_logged "lsnrctl status" as_lsnr "$(lsnr_home)/bin/lsnrctl" status "$SB_LSNR" || true
  grep -qE 'TNS-1254[0-9]|TNS-12541' <<< "$RUN_OUT" && { NOW="The listener here does not answer (step 5.3)."; return 2; }
  grep -qiE "Instance \"$STANDBY_SID\", status UNKNOWN" <<< "$RUN_OUT" || { NOW="The listener here has no static entry for $STANDBY_SID (needed while RMAN restarts the instance). Step 5.2."; return 2; }
  need_sys || return 2
  rf_login_test || return 2
  local fb; sql_local "select flashback_on from v\$database;" && fb=$(first_line) || fb="?"
  NOW="The standby can be rolled forward from the primary ($how)."
  [[ "$fb" == "YES" ]] && NOW+=$'\n'"Flashback database is on here. Its logs are no longer usable after the roll forward: turn it off and on again afterwards."
  RF_FB=$fb
  PLAN="-- 1) Redo apply is stopped, then RMAN, as $ORACLE_USER on this server:
recover standby database from service $PRIMARY_TNS;
-- RMAN restarts the standby instance, takes the control file of the primary, copies the datafiles added since,
-- and fetches the changes as incremental backups. The primary is only read (it makes the backups RMAN fetches).
-- 2) The control file then lists the primary's standby redo logs and RMAN settings: those log groups are dropped,
--    or cleared when their files are on this server (standby_file_management is MANUAL for that moment), and the
--    standby's own are added again (step 9.3);
--    RMAN catalogs the recovery area and cross-checks the archived logs; the deletion policy is set again (9.8).
-- 3) Redo apply is started again."
  return 1
}
rf_after() {
  # after RECOVER STANDBY DATABASE FROM SERVICE the control file is the primary's: it lists the primary's standby
  # redo logs (with the primary's names), the primary's RMAN settings, and none of the archived logs here.
  # 1) standby redo logs: the listed groups are dropped (only their entries: no file of this standby is named
  #    there) and the standby's own are added again (step 9.3)
  local rc=0 g groups mem m allhere
  # redo apply must not run meanwhile (the boot script or a hand start may have started it since)
  dg_proc_count MRP || { bad "Cannot tell whether redo apply runs: $(ora_errors "$SQL_OUT")"; return 1; }
  if [[ $DGP_COUNT -ge 1 ]]; then
    sql_local "alter database recover managed standby database cancel;" || { bad "Cannot stop redo apply: $(ora_errors "$SQL_OUT")"; return 1; }
  fi
  sql_local "select group# from v\$standby_log order by group#;" || { bad "Cannot read the standby redo logs: $(ora_errors "$SQL_OUT")"; return 1; }
  groups=$(grep -oE '^[[:space:]]*[0-9]+' <<< "$SQL_OUT" | tr -d ' ')
  if [[ -n "$groups" ]]; then
    sql_local "alter system set standby_file_management=manual scope=memory;" || { bad "Cannot set standby_file_management: $(ora_errors "$SQL_OUT")"; return 1; }
    for g in $groups; do
      # a group whose files are on this server (the same paths on both servers) is cleared, so the files are used
      # again; a group that names files of the primary only is dropped (its entry; no file here is named)
      sql_local "select 'M:'||member from v\$logfile where group#=$g and type='STANDBY';" || { warn "Cannot read the members of group $g: $(ora_errors "$SQL_OUT")"; rc=1; continue; }
      mem=$(sed -n 's/^[[:space:]]*M://p' <<< "$SQL_OUT"); allhere=1
      [[ -n "$mem" ]] || allhere=0
      while IFS= read -r m; do [[ -n "$m" && "$m" == /* && -f "$m" ]] || allhere=0; done <<< "$mem"
      if [[ $allhere -eq 1 ]]; then
        sql_local "alter database clear logfile group $g;" || { warn "Group $g could not be cleared: $(ora_errors "$SQL_OUT")"; rc=1; }
      else
        sql_local "alter database drop standby logfile group $g;" || { warn "Group $g could not be dropped: $(ora_errors "$SQL_OUT")"; rc=1; }
      fi
    done
    sql_local "alter system set standby_file_management=auto scope=memory;" \
      || { warn "Set it back by hand:  alter system set standby_file_management=auto scope=memory;"; rc=1; }
  fi
  if [[ $rc -eq 0 ]]; then d_9_3_wrap || rc=1; fi
  # 2) the archived logs and backups here, as RMAN knows them: the recovery area is catalogued again and every
  #    archived log is cross-checked (else the recovery area could not reclaim the old logs and fills up)
  local fra t lrc=0
  sql_local "select nvl(value,'-') from v\$parameter where name='db_recovery_file_dest';" && fra=$(first_line) || fra="-"
  t=$(mktemp /tmp/dg_rman.XXXXXX) || { bad "Cannot create a temporary file in /tmp"; return 1; }; CLEANUP_FILES+=("$t")
  { [[ "$fra" != "-" ]] && printf 'catalog recovery area noprompt;\n'; printf 'crosscheck archivelog all;\nexit\n'; } \
    | as_oracle timeout 1800 "$DB_HOME/bin/rman" target / > "$t" 2>&1 || lrc=1
  RUN_OUT=$(cat "$t"); rm -f -- "$t"
  printf '%s\n(exit code %s)\n' "$RUN_OUT" "$lrc" | log_block "rman catalog and crosscheck after the roll forward"
  [[ $lrc -eq 0 ]] || { warn "RMAN could not catalog or cross-check the archived logs: $(ora_errors "$RUN_OUT")"; rc=1; }
  # 3) the deletion policy of the standby (step 9.8): the primary's came with its control file
  local r8=0; c_9_8 >/dev/null 2>&1 || r8=$?
  if [[ $r8 -eq 1 ]]; then d_9_8_wrap || rc=1
  elif [[ $r8 -eq 2 ]]; then warn "The deletion policy of archived logs could not be checked (step 9.8)."; rc=1; fi
  # 4) Oracle Restart: RMAN started the instance itself, outside Oracle Restart
  if use_grid; then
    run_logged "srvctl status" as_oracle timeout 600 "$DB_HOME/bin/srvctl" status database -db "$STANDBY_UNIQUE" || true
    grep -qi 'is not running' <<< "$RUN_OUT" && warn "Oracle Restart shows $STANDBY_UNIQUE as not running (RMAN started it outside Oracle Restart)."$'\n'"At a quiet time, as $ORACLE_USER:  srvctl stop database -db $STANDBY_UNIQUE ; srvctl start database -db $STANDBY_UNIQUE -startoption mount"$'\n'"Then start redo apply again (step 9.4)."
  fi
  return $rc
}
# the steps' own functions, with their journal entries under their own step numbers
d_9_3_wrap() { local CUR_STEP=9.3; d_9_3; }
d_9_8_wrap() { local CUR_STEP=9.8; d_9_8; }
d_10_7() {
  local pf rlog rc=0; pf=$(rf_pending_file)
  if [[ $RF_FINISH -eq 1 ]]; then
    IFS='|' read -r rlog _ < "$pf"
  else
    confirm_word "Roll the standby forward from the primary now." "ROLLFORWARD" || { say "The roll forward was not started."; return 3; }
    # apply must be stopped: a process list that cannot be read is no "not running"
    dg_proc_count MRP || { bad "Cannot tell whether redo apply runs: $(ora_errors "$SQL_OUT")"; return 1; }
    if [[ $DGP_COUNT -ge 1 ]]; then
      sql_local "alter database recover managed standby database cancel;" || { bad "Cannot stop redo apply: $(ora_errors "$SQL_OUT")"; return 1; }
      say "Redo apply stopped."
    fi
    rlog="$LOG_DIR/rollforward_$RUN_ID.log"
    journal ROLLFWD "$STANDBY_UNIQUE" "RMAN roll forward from $PRIMARY_TNS (control file and datafiles of the standby refreshed)"
    # a mark for a roll forward that ends while no run watches (its result is then checked by the next one)
    install -d -m 700 "$STATE_DIR"; printf '%s|\n' "$rlog" > "$pf"
    run_long "RMAN roll forward" "$rlog" 'Starting|Finished|ORA-|RMAN-|restor|recover|media recovery' oracle "$DB_HOME/bin/rman" < <(
      printf 'connect target sys/"%s"@%s\n' "$SYS_PW" "$STANDBY_TNS"
      printf 'recover standby database from service %s;\n' "$PRIMARY_TNS"
      printf 'exit\n') || rc=$?
  fi
  if [[ $rc -ne 0 ]] || grep -qE '^RMAN-0(3002|3009)|ERROR MESSAGE STACK' "$rlog"; then
    rm -f -- "$pf"
    bad "The roll forward did not finish (exit code $rc; $(ora_errors "$(cat "$rlog")"))"
    printf 'Full output: %s
Redo apply was not started again. Look at the output, then run  %s --roll-forward  again,
or start redo apply by hand (step 9.4).
' "$rlog" "$SELF" | hint
    return 1
  fi
  local_state
  sql_local "select database_role||'|'||controlfile_type from v\$database;" || { bad "The standby cannot be read after the roll forward: $(ora_errors "$SQL_OUT")"; return 1; }
  [[ "$(first_line)" == "PHYSICAL STANDBY|STANDBY" ]] || { bad "After the roll forward the database is not a mounted physical standby: $(first_line)"; return 1; }
  # the changes of the steps that run now belong to those steps (an undo of 10.7 must not stop redo apply)
  local cs=$CUR_STEP arc=0
  rf_after || arc=1
  rm -f -- "$pf"
  # redo apply runs again in any case: a standby without its own standby redo logs still applies archived logs
  CUR_STEP=9.4; d_9_4 || { CUR_STEP=$cs; bad "The roll forward worked, but redo apply did not start. Start it:  $SELF --only 9.4"; return 1; }
  CUR_STEP=$cs
  if [[ $arc -eq 1 ]]; then
    bad "The standby was rolled forward and redo apply runs, but the clean-up after it did not finish (see above)."
    printf 'Run the steps again to finish it:  %s --only 9.3-9.8
' "$SELF" | hint
    return 1
  fi
  RF_DONE=1
  DONE_MSG="The standby was rolled forward from the primary: its standby redo logs and RMAN settings are set again, and redo apply runs. Output: $rlog"$'\n'"The temp files now have the primary's names. Check them before you open this standby or switch over to it."
  [[ "${RF_FB:-}" == YES ]] && DONE_MSG+=$'\n'"Flashback database: turn it off and on again (its logs are not usable after the roll forward)."
  return 0
}
switchover_verify_cmd() { printf 'alter database switchover to %s verify;' "$STANDBY_UNIQUE"; }
phase10_footer() {
  # every check of phase 10 OK: the standby is ready as far as this script can tell. The readiness check of
  # Oracle itself runs on the primary and changes nothing there (12.1 and later): shown, never run
  local id
  for id in 10.1 10.2 10.3 10.4 10.5 10.6; do [[ "${STEP_RESULT[$id]:-}" == OK || ( "$id" == 10.5 && "${STEP_RESULT[$id]:-}" == NOT_ON_RELEASE ) ]] || return 0; done
  printf '\n'
  say "Before a planned switchover, Oracle can check the readiness. On the primary, in sqlplus / as sysdba:"
  printf '  %s\n' "$(switchover_verify_cmd)"
  say "It changes nothing. Problems are shown as errors there; the details are in the alert log of the primary."
}
phase_10() {
  phase_header 10 "Health check"
  if [[ ${ROLL_FORWARD:-0} -eq 1 ]]; then
    # the roll forward needs the sys password (RMAN logs in with it): asked first, as step 1.5 does
    if [[ -z "$SYS_PW" ]]; then d_1_5 && record 1.5 DONE; fi
    run_step 10.7 ask "Roll forward the standby from the primary" c_10_7 d_10_7
  fi
  run_step 10.1 check "Transport and apply lag" c_10_1
  run_step 10.2 check "No archive gap" c_10_2
  run_step 10.3 check "Last log: primary and standby" c_10_3
  run_step 10.4 check "Redo apply is running" c_10_4
  run_step 10.5 check "No unrecoverable (NOLOGGING) changes" c_10_5
  run_step 10.6 check "Patch level: primary and standby" c_10_6
  phase10_footer
}
