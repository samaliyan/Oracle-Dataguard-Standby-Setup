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
srv_words() {
  # the words $@ as one shell command line (for the "Will run" list: what is shown is what bash runs). A word
  # with characters other than these is put in single quotes, so a value with a space stays one value
  local a out="" q="'"
  for a in "$@"; do
    if [[ "$a" =~ ^[A-Za-z0-9_./,:+=@-]+$ ]]; then out+="$a "; else out+="$q${a//$q/$q\\$q$q}$q "; fi
  done
  printf '%s' "${out% }"
}
c_9_1() {
  use_grid || { NOW="Not needed: no Oracle Restart on this server. Step 9.7 sets up the start at boot."; return 0; }
  need_built || return 2
  local srv="$DB_HOME/bin/srvctl" spf; spf=$(spfile_path)
  [[ -f "$spf" ]] || { NOW="The spfile is missing: $spf"; return 2; }
  local add; srv_new_args; add=$(srv_words srvctl add database "${SRV_NEW[@]}")
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
      # (Oracle Restart cannot start the database while a disk group it depends on is missing: attention)
      [[ -n "$dead" ]] && { NOW+="; it still names disk group(s) ASM here does not see:$dead"; CHECK_WAITS=1; }
      NOW+=$'\n'"spfile: $spf"
      [[ -n "$DG_DEAD_NOTE" ]] && { NOW+=$'\n'"$DG_DEAD_NOTE"; CHECK_WAITS=1; }
      return 0
    fi
    NOW="Registered, but these values are wrong:$bad_items"$'\n'"$(grep -iE '^(spfile|database role|database instance|instance|start options|oracle home|password file|disk groups|domain)' <<< "$cfg")"
    [[ -n "$DG_DEAD_NOTE" ]] && NOW+=$'\n'"$DG_DEAD_NOTE"
    # a new registration or a disk-group change while the disk groups cannot be read: not now (the old disk
    # groups could not be kept, and the standby would be stopped for nothing). A standby in folders whose
    # registration names no disk group has nothing to keep: ASM does not matter then
    if [[ $dg_unread -eq 1 && ( -n "$cdg" || -n "$(srv_dgs)" ) && "$bad_items" =~ (spfile|role|instance|diskgroup) ]]; then
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
    # (named here too, not only in the warning: the run summary keeps NOW)
    [[ -n "$dead" ]] && NOW+=$'\n'"It also names disk group(s) that ASM here does not see:$dead (kept, see the warning)."
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
      # changed in place: the running standby is not stopped
      PLAN="Change the wrong values of the registration in place, on this server only (the standby keeps running)."
      cp_add oracle "$(srv_words srvctl modify database -db "$STANDBY_UNIQUE" "${REG_MOD_ARGS[@]}")"
      return 1
    fi
    REG_MODE=re
    # the command shown is made from the same values as the action (policy, stop option, disk groups, domain)
    local cf radd; cf=$(mktemp) || return 2; CLEANUP_FILES+=("$cf"); printf '%s\n' "$cfg" > "$cf"
    srv_new_args "$cf"; radd=$(srv_add_cmd_from "$cf"); rm -f -- "$cf"
    add=$(srv_words srvctl add database "${SRV_NEW[@]}")
    # (a stop that fails does not end the step: remove then says whether the registration can go)
    cp_add oracle "srvctl stop database -db $STANDBY_UNIQUE"
    cp_add oracle "srvctl remove database -db $STANDBY_UNIQUE -noprompt"
    cp_add oracle "$add"
    PLAN="Register $STANDBY_UNIQUE in Oracle Restart again, on this server only (the standby is stopped for it)."
    [[ -n "$SRV_DG_LOST" ]] && PLAN+=$'\n'"The disk groups of the old registration cannot be read ($SRV_DG_LOST): only the needed ones are set."
    PLAN+=$'\n'"The management policy, stop option, disk groups and domain of the old registration are kept."$'\n'"The old registration is saved first. If the new one cannot be added, the old one is added again;"$'\n'"settings it had beyond these (for example services) are then listed, to set again by hand."
    [[ -n "$radd" ]] && PLAN+=$'\n'"Only if the new registration fails, this puts the old one back (as $ORACLE_USER):"$'\n'"  $radd"
    return 1
  fi
  # only "the resource could not be found" means not registered; another failure (CRS down, a timeout) is unknown
  if ! srv_notfound "$STANDBY_UNIQUE"; then
    NOW="srvctl config database -db $STANDBY_UNIQUE failed: $(tail -n 2 <<< "$RUN_OUT" | tr '\n' ' ')"; return 2
  fi
  REG_MODE=add
  NOW="$STANDBY_UNIQUE is not registered in Oracle Restart"
  PLAN="Register $STANDBY_UNIQUE in Oracle Restart (role PHYSICAL_STANDBY, start option MOUNT)."
  cp_add oracle "$add"
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
SRV_ADD_IDX=""
srv_shown_add() {
  # SRV_ADD_IDX: the index of the "srvctl add database" entry of the shown list when it is exactly the command
  # that the values now give (SRV_NEW); 1 (and said) when it is not: a registration that changed since the check
  # is not touched (answer r: it is checked and shown again)
  local i want; want=$(srv_words srvctl add database "${SRV_NEW[@]}"); SRV_ADD_IDX=""
  if i=$(cp_find oracle "srvctl add database ") && [[ "${CP_CMD[$i]}" == "$want" ]]; then SRV_ADD_IDX=$i; return 0; fi
  bad "The srvctl add command is not the one shown before (the registration or the settings changed since the check)."$'\n'"Answer r: it is checked and shown again."
  return 1
}
srv_add() {
  # $1 (optional) saved "srvctl config database" of an earlier registration: see srv_new_args. Runs the shown
  # "srvctl add database" entry, after checking that it is still the right command
  srv_new_args "${1:-}"
  # ASM stopped answering after the check (during stop/remove): no new registration with an unchecked list. The
  # caller puts the old registration back
  if [[ -n "$SRV_DG_UNREAD" && -n "${1:-}" ]]; then bad "The disk groups of this server cannot be read now (old ones: $SRV_DG_UNREAD). The new registration is not added."; return 1; fi
  [[ -n "$SRV_DG_LOST" ]] && warn "The disk groups of the old registration cannot be read ($SRV_DG_LOST). Only the ones the standby needs are set:"$'\n'"$(srv_dgs). Add others again with:  srvctl modify database -db $STANDBY_UNIQUE -diskgroup <list>"
  srv_shown_add || return 1
  cp_exec "$SRV_ADD_IDX" || { bad "srvctl add failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  [[ ${#SRV_KEPT[@]} -gt 0 ]] && say "Kept from the old registration: ${SRV_KEPT[*]}"
  return 0
}
d_9_1() {
  if [[ "$REG_MODE" == "modify" ]]; then
    cp_run || return 1
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
    # that would lose the old disk groups (none in the old registration and none needed: nothing to lose)
    local odg; odg=$(_cfgv "$old" 'Disk Groups' | tr -d ' \t\r')
    if [[ -n "$odg" || -n "$(srv_dgs)" ]] && ! asm_dg_names; then bad "The disk groups of this server cannot be read now${ASM_MISSING:+ (missing:$ASM_MISSING)}. Nothing is changed."; return 1; fi
    # the new registration made from the registration as it is now must be the one shown: else nothing is stopped
    srv_new_args "$old"
    [[ -z "$SRV_DG_UNREAD" ]] || { bad "The disk groups of this server cannot be read now (old ones: $SRV_DG_UNREAD). Nothing is changed."; return 1; }
    srv_shown_add || { say "Nothing is changed."; return 1; }
    cp_run_one oracle "srvctl stop database -db $STANDBY_UNIQUE" || true
    cp_run_one oracle "srvctl remove database -db $STANDBY_UNIQUE -noprompt" || { bad "srvctl remove failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    if ! srv_add "$old"; then
      # (put back after a failure: the command is shown when it runs, and logged)
      say "The new registration failed. Adding the old registration again."
      local radd back=0 diffl=""; radd=$(srv_add_cmd_from "$old")
      if srv_old_args "$old" && run_logged "srvctl add (the old registration)" as_oracle timeout 600 "${SRV_OLD_ARGS[@]}"; then
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
    # values of the old registration the new one does not carry (services, server pools, OS groups ...): read
    # again and named. The values this step sets itself are left out of the comparison
    if run_logged "srvctl config (after the new registration)" as_oracle timeout 600 "$DB_HOME/bin/srvctl" config database -db "$STANDBY_UNIQUE"; then
      local lost; lost=$(comm -23 <(srv_cfg_norm < "$old" | sort -u) <(printf '%s\n' "$RUN_OUT" | srv_cfg_norm | sort -u) \
        | grep -viE '^(Database unique name|Database name|Oracle home|Oracle user|Spfile|Password file|Domain|Start options|Stop options|Database role|Management policy|Disk Groups|Database instance|Instance|Instance name):' \
        | grep -E '^[^:]+:[[:space:]]*[^[:space:]]' | head -n 8)
      [[ -n "$lost" ]] && warn "The new registration does not have these values of the old one:"$'\n'"$(sed 's/^/  /' <<< "$lost")"$'\n'"The old registration is saved in:  $old"$'\n'"Set them again by hand, as $ORACLE_USER (srvctl modify database, srvctl add service)."
    else
      warn "The new registration could not be read to compare it with the old one (saved in $old)."
    fi
    return 0
  fi
  srv_add || return 1
  journal SRVCTL "$STANDBY_UNIQUE" "registered in Oracle Restart (role PHYSICAL_STANDBY, start option MOUNT)"
}

# ---- 9.2 ----
# A standby instance that RMAN started is stopped (shutdown immediate, at most SHUT_TMO seconds) and started again
# under Oracle Restart. When it does not stop, or it hangs (its processes run but a login gives ORA-01012), the step
# offers shutdown abort: safe for a standby that is only mounted (nothing is lost, redo apply recovers it). Asked
# every time, also with yes to all.
L92_MODE=""
c_9_2() {
  L92_MODE=""
  # a hung instance first: everything else (the comparison with the primary too) needs a login it refuses
  if db_sw_ok; then
    local_state
    if [[ "$LSTATE" == HUNG && ! -f "$(spfile_path)" && ! -f "$(pfile_path)" ]]; then
      NOW="$(hung_text)"$'\n'"Neither $(spfile_path) nor $(pfile_path) is here: it is not the standby instance this script set up. Not touched."
      return 2
    fi
    if [[ "$LSTATE" == HUNG ]]; then
      NOW=$(hung_text)
      PLAN="Stop it with shutdown abort. That is safe for a standby that is only mounted: nothing is lost,"$'\n'"redo apply recovers it. Then start it again$(use_grid && printf ' under Oracle Restart' || printf ' in MOUNT'), and check that it is MOUNTED."
      cp_add oracle "sqlplus -S -prelim / as sysdba" "shutdown abort" 120
      if use_grid; then cp_add oracle "srvctl start database -db $STANDBY_UNIQUE" "" 1800
      else cp_add oracle "sqlplus -S / as sysdba" "startup mount" 1800; fi
      L92_MODE=abort; KIND_NOW=ask; return 1
    fi
  fi
  need_built || return 2
  if ! use_grid; then
    # no Oracle Restart: the instance only has to be mounted as a standby
    local_state
    case "$LSTATE" in
      MOUNTED|OPEN) adg_note "$LSTATE"; NOW="Instance $STANDBY_SID is $LSTATE (no Oracle Restart on this server)"
                    logins_after_start || { KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="To check on this server ($(hostname -s))"; return 1; }; return 0 ;;
      IDLE) NOW="The standby instance is not running"; PLAN="Start it in MOUNT."
            cp_add oracle "sqlplus -S / as sysdba" "startup mount" 1800; L92_MODE=start; return 1 ;;
      STARTED) NOW="The instance is in NOMOUNT (started with the first pfile)"; PLAN="Stop it and start it in MOUNT. The new start uses the spfile."
               cp_add oracle "sqlplus -S / as sysdba" "shutdown immediate" "$SHUT_TMO"
               cp_add oracle "sqlplus -S / as sysdba" "startup mount" 1800; L92_MODE=restart; return 1 ;;
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
      PLAN="Stop it (at most $(human_min $(( (SHUT_TMO + 59) / 60 )))) and start it under Oracle Restart."$'\n'"If it does not stop, shutdown abort is offered (safe for a mounted standby)."
      cp_add oracle "sqlplus -S / as sysdba" "shutdown immediate" "$SHUT_TMO"
      cp_add oracle "srvctl start database -db $STANDBY_UNIQUE" "" 1800
      L92_MODE=restart; return 1
    fi
    NOW="Unexpected state: instance $iname, status $ist, role $irole"; return 2
  fi
  if [[ $srv_on -eq 1 ]] && grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    NOW="srvctl says the database is running, but ORACLE_SID=$STANDBY_SID is idle."$'\n'"The registration uses another instance name (step 9.1)"
    return 2
  fi
  NOW="The standby instance is not running"
  PLAN="Start it under Oracle Restart."
  cp_add oracle "srvctl start database -db $STANDBY_UNIQUE" "" 1800
  L92_MODE=start
  return 1
}
abort_offer() {
  # the instance did not stop (or hangs): shutdown abort, after you agree (never answered by yes to all)
  local why=$1
  warn "$why"
  say "shutdown abort is safe for a standby that is only mounted: nothing is lost, redo apply recovers it."
  ask_choice "[y] Stop it with shutdown abort   [s] Skip   [q] Quit" "ysq"
  case "$ANSWER" in s) return 3 ;; q) user_stop "Stopped by you" ;; esac
  inst_abort
}
d_9_2() {
  local i rc=0 last=$(( ${#CP_CMD[@]} - 1 ))
  case "$L92_MODE" in
    abort)
      ask_choice "[y] Stop it with shutdown abort and start it again   [s] Skip   [q] Quit" "ysq"
      case "$ANSWER" in s) return 3 ;; q) user_stop "Stopped by you" ;; esac
      cp_exec 0 || true
      local t0=$SECONDS; while pmon_running && (( SECONDS - t0 < (FAST_WAITS == 1 ? 3 : 60) )); do nap 2; done
      pmon_running && { bad "Instance $STANDBY_SID still runs after shutdown abort (ora_pmon_$STANDBY_SID). Check:  ps -ef | grep ora_pmon_$STANDBY_SID"; return 1; }
      journal INSTANCE "$STANDBY_SID" "shutdown abort (the instance hung)"
      say "Instance $STANDBY_SID is stopped."
      cp_exec 1 || { bad "The start failed: $(tail -n 3 <<< "$RUN_OUT" | mask_pw)"; return 1; }
      journal INSTANCE "$STANDBY_SID" "$(head -n 1 <<< "${CP_CMD[1]}${CP_IN[1]:+  ->  ${CP_IN[1]}}")"
      return 0 ;;
    restart)
      # entry 0: shutdown immediate with a time limit; it must really be down before the start
      cp_exec 0 || rc=$?
      local_state
      if [[ "$LSTATE" != IDLE && "$LSTATE" != NOSW ]]; then
        local why="The instance did not stop with shutdown immediate"
        [[ $rc -eq 124 ]] && why+=" within $(human_min $(( (SHUT_TMO + 59) / 60 )))"
        [[ "$LSTATE" == HUNG ]] && why+=". $(hung_text)" || why+=" (state $LSTATE)"
        local arc=0; abort_offer "$why" || arc=$?
        [[ $arc -eq 0 ]] || return $arc
      fi
      cp_exec "$last" || { bad "The start failed: $(tail -n 3 <<< "$RUN_OUT" | mask_pw)"; return 1; }
      journal INSTANCE "$STANDBY_SID" "$(use_grid && printf 'srvctl start database (MOUNT)' || printf 'startup mount (standby)')"
      return 0 ;;
    *)
      cp_run || return 1
      journal INSTANCE "$STANDBY_SID" "$(use_grid && printf 'srvctl start database (MOUNT)' || printf 'startup mount (standby)')"
      return 0 ;;
  esac
}

# ---- 9.3 ----
SRL_SQL=""
# redo apply: one statement each way (9.3, 9.4, 9.7 and 10.7 show and run exactly these)
APPLY_START_SQL="alter database recover managed standby database disconnect from session;"
APPLY_STOP_SQL="alter database recover managed standby database cancel;"
sb_cp_idx() {
  # the index of the shown entry with role $1, command $2 and input $3 (all exactly); 1 when there is none
  local i
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    [[ "${CP_ROLE[$i]}" == "$1" && "${CP_CMD[$i]}" == "$2" && "${CP_IN[$i]}" == "${3:-}" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}
srl_add_input() { printf 'whenever sqlerror exit failure\n%s' "$SRL_SQL"; }   # the first error stops the rest
c_9_3() {
  need_built || return 2
  local rc=0; srl_statements sql_local || rc=$?
  [[ $rc -eq 2 ]] && { NOW="Cannot read the redo logs of the standby ($(ora_errors "$SQL_OUT"))"; return 2; }
  NOW=$SRL_INFO
  [[ $rc -eq 0 ]] && return 0
  SRL_SQL="alter system set standby_file_management=manual scope=memory;"$'\n'"$SRL_STMTS"$'\n'"alter system set standby_file_management=auto scope=memory;"
  # apply is stopped while the logs are added, and started again afterwards (also after an error)
  local mrp=0; mrp_running && mrp=1
  PLAN="Add the standby redo logs on this server$([[ $mrp -eq 1 ]] && printf ' (redo apply is stopped for it, and started again afterwards, also after an error)')."
  PLAN+=$'\n'"If adding fails, standby_file_management is set back to AUTO."
  [[ $mrp -eq 1 ]] && cp_add oracle "sqlplus -S / as sysdba" "$APPLY_STOP_SQL"
  cp_add oracle "sqlplus -S / as sysdba" "$(srl_add_input)"
  [[ $mrp -eq 1 ]] && cp_add oracle "sqlplus -S / as sysdba" "$APPLY_START_SQL"
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
  # the statements needed now must be the ones shown (else nothing is changed: checked and shown again)
  local iadd istop istart
  iadd=$(sb_cp_idx oracle "sqlplus -S / as sysdba" "$(srl_add_input)") \
    || { bad "The standby redo logs needed now are not the ones shown before (they changed since the check). Nothing is changed."$'\n'"Answer r: they are checked and shown again."; return 1; }
  istop=$(sb_cp_idx oracle "sqlplus -S / as sysdba" "$APPLY_STOP_SQL") || istop=""
  istart=$(sb_cp_idx oracle "sqlplus -S / as sysdba" "$APPLY_START_SQL") || istart=""
  # without the list of groups before, the new groups could not be told apart (the undo would drop them all)
  sql_local "select group# from v\$standby_log order by group#;" || { bad "Cannot read the standby logs ($(ora_errors "$SQL_OUT"))"; return 1; }
  before=$(tr -d ' ' <<< "$SQL_OUT")
  local was_mrp=0
  if mrp_running; then
    [[ -n "$istop" && -n "$istart" ]] || { bad "Redo apply was started since the check: stopping it was not shown. Nothing is changed."$'\n'"Answer r: it is checked and shown again."; return 1; }
    cp_exec "$istop" || { bad "Cannot stop apply ($(ora_errors "$RUN_OUT"))"; return 1; }
    was_mrp=1
  elif [[ -n "$istop" ]]; then
    say "Redo apply is not running now: it is not stopped, and not started afterwards."
  fi
  if ! cp_exec "$iadd"; then
    local eo=$RUN_OUT
    # (after an error: shown when it runs)
    sql_local "alter system set standby_file_management=auto scope=memory;" \
      || warn "standby_file_management could not be set back to AUTO. Set it by hand:  alter system set standby_file_management=auto scope=memory;"
    # groups that were added before the error are recorded too (they are undone with the step)
    sql_local "select group# from v\$standby_log order by group#;" && after=$(tr -d ' ' <<< "$SQL_OUT") || after=""
    new=$(comm -13 <(sort <<< "$before") <(sort <<< "$after") | sort -n | paste -sd' ' -)
    [[ -n "$new" ]] && journal SRL "$STANDBY_SID" "$new"
    bad "Cannot add the standby redo logs ($(ora_errors "$eo"))"
    grep -q 'ORA-01378' <<< "$eo" && printf 'ORA-01378: the online logs of the primary use 4K blocks.\nThe disk group or file system here must have a 4K sector size.\n' | hint
    srl_apply_back $was_mrp "$istart"
    return 1
  fi
  sql_local "select group# from v\$standby_log order by group#;" && after=$(tr -d ' ' <<< "$SQL_OUT") || after=""
  new=$(comm -13 <(sort <<< "$before") <(sort <<< "$after") | sort -n | paste -sd' ' -)
  [[ -n "$new" ]] && journal SRL "$STANDBY_SID" "$new"
  srl_apply_back $was_mrp "$istart" || return 1
  return 0
}
srl_apply_back() {
  # $1 = 1: apply ran before step 9.3 stopped it; it is started again with the shown entry $2 (1 when that fails)
  [[ "$1" == 1 ]] || return 0
  if cp_exec "$2"; then say "Redo apply is running again."; return 0; fi
  bad "Redo apply was stopped to add the standby logs and could not be started again ($(ora_errors "$RUN_OUT")). Step 9.4 starts it."
  return 1
}

# ---- 9.8 archived logs on the standby ----
# What deletes applied archived logs here is a setting, ARCH_CLEANUP (see 20_settings.sh):
#   timer    a systemd timer every night (the default; it also runs after a missed time)
#   crontab  a line in the crontab of the oracle user, marked "# dg_standby_setup <sid>"
#   oracle   only the recovery area itself (it deletes applied logs when it needs space); logs in the recovery area only
#   none     nothing
# Step 9.8 sets the RMAN deletion policy TO APPLIED ON STANDBY first (it keeps every log that is not applied yet),
# then puts in place exactly what is set; a schedule of the other kind is taken out. Never "delete ... force".
# Not chosen yet: 9.8 asks once and saves the answer as the setting.
arch_in_fra() { [[ "$(arch_dest_sb)" == USE_DB_RECOVERY_FILE_DEST ]]; }
arch_where() { if arch_in_fra; then printf 'the recovery area (%s)' "$(fra_dest)"; else printf '%s' "$(arch_dest_sb)"; fi; }
arch_time() { printf '%s' "${ARCH_CLEANUP_TIME:-04:30}"; }
arch_days() { local d=${ARCH_CLEANUP_DAYS:-1}; printf '%d' "$((10#$d))"; }
arch_timer() { printf 'dg-arch-cleanup-%s.timer' "${STANDBY_SID,,}"; }
arch_service() { printf 'dg-arch-cleanup-%s.service' "${STANDBY_SID,,}"; }
arch_script() { printf '/usr/local/sbin/dg_arch_cleanup_%s.sh' "${STANDBY_SID,,}"; }
arch_cron_tag() { printf '# dg_standby_setup %s' "${STANDBY_SID,,}"; }
arch_cron_log() { printf '%s/arch_cleanup_%s.log' "$LOG_DIR" "${STANDBY_SID,,}"; }
arch_cron_line() { local t; t=$(arch_time); printf '%d %d * * * %s >> %s 2>&1 %s' "$((10#${t#*:}))" "$((10#${t%%:*}))" "$(arch_script)" "$(arch_cron_log)" "$(arch_cron_tag)"; }
arch_mode_text() {
  # one line: what the choice $1 means
  local d; d=$(arch_days)
  case "$1" in
    timer)   printf 'a systemd timer deletes applied logs older than %s day(s) every night at %s' "$d" "$(arch_time)" ;;
    crontab) printf 'a line in the crontab of %s deletes applied logs older than %s day(s) every night at %s' "$ORACLE_USER" "$d" "$(arch_time)" ;;
    oracle)  printf 'the recovery area deletes applied logs by itself when it needs space' ;;
    none)    printf 'nothing deletes them: the disk fills up unless you delete them yourself' ;;
  esac
}
arch_script_text() {
  printf '#!/bin/bash\n# Written by dg_standby_setup.sh: deletes the archived logs of the standby %s that are applied and older\n' "$STANDBY_UNIQUE"
  printf '# than %s day(s). The RMAN deletion policy (applied on standby) keeps every log that is not applied yet.\n' "$(arch_days)"
  printf '[ "$(id -un)" = root ] && exec runuser -u %s -- "$0" "$@"\n' "$ORACLE_USER"
  printf 'echo "=== dg_arch_cleanup $(date '"'"'+%%Y-%%m-%%d %%H:%%M:%%S'"'"') ==="\n'
  printf 'export ORACLE_HOME=%s ORACLE_SID=%s LANG=C\n' "$DB_HOME" "$STANDBY_SID"
  printf '# the deletion policy first: without TO APPLIED ON STANDBY a log that is not applied could be deleted\n'
  printf '# (the same rule as step 9.8: "... BACKED UP n TIMES ..." is not enough on a standby)\n'
  printf 'pol=$(printf "show archivelog deletion policy;\\nexit\\n" | "$ORACLE_HOME/bin/rman" target / 2>&1)\n'
  printf 'if ! printf "%%s\\n" "$pol" | grep -qiE "POLICY TO APPLIED ON +(ALL +)?STANDBY *;"; then echo "RMAN-00000: the deletion policy is not TO APPLIED ON STANDBY: nothing deleted (step 9.8 sets it)"; printf "%%s\\n" "$pol" | grep -iE "DELETION POLICY|RMAN-[0-9]|ORA-[0-9]" | head -n 5; exit 1; fi\n'
  printf '"$ORACLE_HOME/bin/rman" target / <<EOF\n'
  printf "delete noprompt archivelog all completed before 'sysdate-%s';\nexit\nEOF\n" "$(arch_days)"
  printf 'rc=$?\necho "=== end (exit code $rc) ==="\nexit $rc\n'
}
arch_service_text() {
  printf '[Unit]\nDescription=Delete applied archived logs of the standby %s (dg_standby_setup.sh)\n\n' "$STANDBY_UNIQUE"
  printf '[Service]\nType=oneshot\nExecStart=%s\n' "$(arch_script)"
}
arch_timer_text() {
  printf '[Unit]\nDescription=Daily clean-up of applied archived logs of %s\n\n[Timer]\nOnCalendar=*-*-* %s:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' "$STANDBY_UNIQUE" "$(arch_time)"
}
arch_timer_present() { [[ -f "/etc/systemd/system/$(arch_timer)" ]] || systemctl is-enabled --quiet "$(arch_timer)" 2>/dev/null; }
arch_cron_ours() {
  # the lines of the oracle crontab that this script added for this standby (they end with the tag)
  local l t; t=$(arch_cron_tag)
  while IFS= read -r l; do [[ "$l" == *" $t" ]] && printf '%s\n' "$l"; done < <(crontab -u "$ORACLE_USER" -l 2>/dev/null)
  return 0
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
arch_log_traversable() {
  # the oracle user can reach the log folder (cron writes its log file there as that user)
  runuser -u "$ORACLE_USER" -- test -x "$LOG_DIR" 2>/dev/null
}
arch_cron_last_errors() {
  # RMAN-/ORA- lines of the last run in the cron log (since its last "=== dg_arch_cleanup" line)
  local f; f=$(arch_cron_log); [[ -r "$f" ]] || return 0
  awk '/^=== dg_arch_cleanup /{buf=""; next} /^(RMAN|ORA)-[0-9]+/{buf=buf $0 "\n"} END{printf "%s", buf}' "$f" | head -n 3
}
arch_cron_state() {
  # ok | line (missing, twice or different) | script (missing or different) | log (the log cannot be written by oracle)
  # | failed (the last run printed RMAN-/ORA- errors)
  local ours; ours=$(arch_cron_ours)
  [[ "$ours" == "$(arch_cron_line)" ]] || { printf line; return; }
  [[ -f "$(arch_script)" && "$(cat "$(arch_script)")" == "$(arch_script_text)" ]] || { printf script; return; }
  { [[ -f "$(arch_cron_log)" && "$(stat -c '%U' "$(arch_cron_log)" 2>/dev/null)" == "$ORACLE_USER" ]] && arch_log_traversable; } || { printf log; return; }
  [[ -n "$(arch_cron_last_errors)" ]] && { printf failed; return; }
  printf ok
}
# $1 the value of 'ARCHIVELOG DELETION POLICY' in v$rman_configuration: the one rule of 9.8, 10.8 and the nightly script
arch_policy_is_ok() { [[ "$(tr -s ' ' <<< "${1^^}")" =~ ^TO\ APPLIED\ ON\ (ALL\ )?STANDBY$ ]]; }
ARCH_POLICY_OK=0; L98_ASK=0; L98_OLDPOL="-"; L98_TIMER_OFF=0; L98_CRON_OFF=""; L98_CRON_ON=0; L98_TIMER_ON=0
c_9_8() {
  L98_ASK=0; L98_TIMER_OFF=0; L98_CRON_OFF=""; L98_CRON_ON=0; L98_TIMER_ON=0
  need_built || return 2
  local_state
  [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { NOW="The standby is not mounted (step 9.2)"; return 2; }
  sql_local "select nvl(max(value),'-') from v\$rman_configuration where name='ARCHIVELOG DELETION POLICY';" || { NOW="Cannot read the RMAN configuration ($(ora_errors "$SQL_OUT"))"; return 2; }
  local v; v=$(first_line); L98_OLDPOL=$v
  # only "applied on (all) standby" deletes on a standby; a policy copied from the primary with "backed up n times"
  # never deletes here (nothing is backed up on the standby)
  ARCH_POLICY_OK=0; arch_policy_is_ok "$v" && ARCH_POLICY_OK=1
  local mode=${ARCH_CLEANUP:-}
  if [[ "$mode" == oracle ]] && ! arch_in_fra; then
    NOW="ARCH_CLEANUP=oracle, but the archived logs go to $(arch_where), not to the recovery area. Oracle deletes nothing there."
    KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
    PLAN="-- Choose timer or crontab (then run step 9.8 again):"$'\n'"$SELF --settings"
    return 1
  fi
  local tp=0 cron_now; arch_timer_present && tp=1; cron_now=$(arch_cron_ours)
  local tst="" cst=""
  [[ "$mode" == timer ]] && tst=$(arch_timer_state)
  [[ "$mode" == crontab ]] && cst=$(arch_cron_state)
  local sched_ok=0
  case "$mode" in
    timer)       [[ "$tst" == ok && -z "$cron_now" ]] && sched_ok=1 ;;
    crontab)     [[ "$cst" == ok && $tp -eq 0 ]] && sched_ok=1 ;;
    oracle|none) [[ $tp -eq 0 && -z "$cron_now" ]] && sched_ok=1 ;;
  esac
  if [[ $ARCH_POLICY_OK -eq 1 && $sched_ok -eq 1 ]]; then
    NOW="RMAN archivelog deletion policy: $v"$'\n'"Archived logs in $(arch_where): $(arch_mode_text "$mode") (ARCH_CLEANUP=$mode)"
    [[ "$mode" == none ]] && NOW+=$'\n'"Nothing deletes them here. Watch the space, or choose timer or crontab:  $SELF --settings"
    return 0
  fi
  NOW=""
  [[ $ARCH_POLICY_OK -eq 1 ]] || NOW="RMAN archivelog deletion policy of the standby: ${v/#-/not set}$([[ "$v" != "-" ]] && printf ', copied from the primary with the control file')."$'\n'"Without the right policy, applied logs are not deleted here."$'\n'"The disk fills up and redo transport stops (ORA-19809, ORA-00257)."
  cp_reset
  [[ $ARCH_POLICY_OK -eq 1 ]] || cp_add oracle "rman target /" "CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;" 300
  if [[ -z "$mode" ]]; then
    # not chosen yet: one question in the action (each choice with its meaning), saved as ARCH_CLEANUP
    NOW+="${NOW:+$'\n'}How applied archived logs are deleted here is not chosen yet (ARCH_CLEANUP). They go to $(arch_where)."
    PLAN="Ask you how (systemd timer, crontab of $ORACLE_USER$(arch_in_fra && printf ', or leave it to the recovery area')), save it, then set it up."
    L98_ASK=1; KIND_NOW=ask
    return 1
  fi
  # the schedule of the other kind goes (only what this script made: its timer, its tagged crontab line)
  if [[ "$mode" != timer && $tp -eq 1 ]]; then
    NOW+="${NOW:+$'\n'}$(arch_timer) is set up, but ARCH_CLEANUP=$mode: the timer is taken out."
    cp_add root "systemctl disable --now $(arch_timer)"
    cp_add root "rm -f /etc/systemd/system/$(arch_timer) /etc/systemd/system/$(arch_service)"
    cp_add root "systemctl daemon-reload"
    L98_TIMER_OFF=1
  fi
  if [[ -n "$cron_now" && ( "$mode" != crontab || "$cst" == line ) ]]; then
    [[ "$mode" != crontab ]] && NOW+="${NOW:+$'\n'}The crontab of $ORACLE_USER has the clean-up line, but ARCH_CLEANUP=$mode: the line is taken out."
    cp_add root "c=\$(crontab -u $ORACLE_USER -l 2>/dev/null) || { e=\$(crontab -u $ORACLE_USER -l 2>&1 >/dev/null); case \"\$e\" in 'no crontab for'*) c= ;; *) echo \"\$e\"; exit 1 ;; esac; }; { [ -z \"\$c\" ] || printf '%s\\n' \"\$c\" | grep -v -- ' $(arch_cron_tag)\$'; } | crontab -u $ORACLE_USER -"
    L98_CRON_OFF=$cron_now
  fi
  case "$mode" in
    timer)
      case "$tst" in
        off)    NOW+="${NOW:+$'\n'}$(arch_timer) is not running (stopped or not enabled). Applied logs are not deleted."
                cp_add root "systemctl enable $(arch_timer)"; cp_add root "systemctl start $(arch_timer)"; L98_TIMER_ON=1 ;;
        failed) NOW+="${NOW:+$'\n'}The last run of $(arch_service) failed: $(journalctl -u "$(arch_service)" -n 20 --no-pager -o cat 2>/dev/null | grep -E 'RMAN-|ORA-' | tail -n 2 | tr '\n' ' ')"
                NOW+=$'\n'"To see why:  journalctl -u $(arch_service)"
                cp_add root "systemctl reset-failed $(arch_service)"; cp_add root "systemctl start $(arch_service)" "" 3600
                systemctl is-enabled --quiet "$(arch_timer)" 2>/dev/null && systemctl is-active --quiet "$(arch_timer)" 2>/dev/null || { cp_add root "systemctl enable $(arch_timer)"; cp_add root "systemctl start $(arch_timer)"; L98_TIMER_ON=1; } ;;
        files)  NOW+="${NOW:+$'\n'}The nightly clean-up timer is not set up as wanted ($(arch_mode_text timer))."
                cp_add_file "$(arch_script)" 755 "$(arch_script_text)"
                cp_add_file "/etc/systemd/system/$(arch_service)" 644 "$(arch_service_text)"
                cp_add_file "/etc/systemd/system/$(arch_timer)" 644 "$(arch_timer_text)"
                cp_add root "systemctl daemon-reload"; cp_add root "systemctl enable $(arch_timer)"; cp_add root "systemctl start $(arch_timer)"; L98_TIMER_ON=1 ;;
      esac ;;
    crontab)
      case "$cst" in
        failed) NOW+="${NOW:+$'\n'}The last clean-up run from the crontab printed errors: $(arch_cron_last_errors | tr '\n' ' ')"$'\n'"Log: $(arch_cron_log)"
                cp_add root "$(arch_script) >> $(arch_cron_log) 2>&1" "" 3600 ;;
        *)      [[ "$cst" == line ]] && NOW+="${NOW:+$'\n'}The clean-up line in the crontab of $ORACLE_USER is missing or not as wanted ($(arch_mode_text crontab))."
                [[ "$cst" == script ]] && NOW+="${NOW:+$'\n'}$(arch_script) is missing or not as wanted."
                [[ "$cst" == log ]] && NOW+="${NOW:+$'\n'}$ORACLE_USER cannot write the log $(arch_cron_log)."
                [[ -f "$(arch_script)" && "$(cat "$(arch_script)")" == "$(arch_script_text)" ]] || cp_add_file "$(arch_script)" 755 "$(arch_script_text)"
                # the log: a file of oracle in the log folder; the folder gets the install group so oracle can reach it
                arch_log_traversable || { cp_add root "chgrp $INSTALL_GROUP $LOG_DIR"; cp_add root "chmod 750 $LOG_DIR"; }
                # (a log that is there with another owner is given to oracle, not emptied: its error lines are kept)
                if ! [[ -f "$(arch_cron_log)" && "$(stat -c '%U' "$(arch_cron_log)" 2>/dev/null)" == "$ORACLE_USER" ]]; then
                  if [[ -f "$(arch_cron_log)" && ! -L "$(arch_cron_log)" ]]; then cp_add root "chown $ORACLE_USER:$INSTALL_GROUP $(arch_cron_log)"; cp_add root "chmod 640 $(arch_cron_log)"
                  else cp_add root "install -o $ORACLE_USER -g $INSTALL_GROUP -m 640 /dev/null $(arch_cron_log)"; fi
                fi
                if [[ "$(arch_cron_ours)" != "$(arch_cron_line)" ]]; then
                  cp_add root "c=\$(crontab -u $ORACLE_USER -l 2>/dev/null) || { e=\$(crontab -u $ORACLE_USER -l 2>&1 >/dev/null); case \"\$e\" in 'no crontab for'*) c= ;; *) echo \"\$e\"; exit 1 ;; esac; }; { [ -z \"\$c\" ] || printf '%s\\n' \"\$c\" | grep -v -- ' $(arch_cron_tag)\$'; echo '$(arch_cron_line)'; } | crontab -u $ORACLE_USER -"
                  L98_CRON_ON=1
                fi ;;
      esac ;;
  esac
  local what; what=$(arch_mode_text "$mode")
  PLAN="${PLAN:+$PLAN$'\n'}Archived logs in $(arch_where): ${what} (ARCH_CLEANUP=$mode)."
  [[ $ARCH_POLICY_OK -eq 1 ]] || PLAN+=$'\n'"First the RMAN deletion policy: logs that are not applied yet are never deleted."
  USING="Nothing is changed on the primary. Its own policy belongs to its backups.
To see it there:  rman target /  ->  show archivelog deletion policy;
NEVER set TO APPLIED ON STANDBY on a primary that RMAN does not back up: its logs would never be deleted.
Change the way or the time later with  $SELF --settings  (ARCH_CLEANUP, ARCH_CLEANUP_TIME, ARCH_CLEANUP_DAYS)."
  return 1
}
arch_choose() {
  # 9.8: ARCH_CLEANUP not set yet: asked once, saved
  local opts="[t] systemd timer   [c] crontab of $ORACLE_USER" allowed="tc"
  printf '%s\n' "t  $(arch_mode_text timer) (it also runs after a missed time)" "c  $(arch_mode_text crontab)" \
    "$(arch_in_fra && printf 'o  %s' "$(arch_mode_text oracle)")" "n  $(arch_mode_text none)" | grep -v "^$" | block "Choices:"
  arch_in_fra && { opts+="   [o] Leave it to the recovery area"; allowed+="o"; }
  opts+="   [n] Nothing"; allowed+="n"
  ask_choice "$opts" "$allowed"
  case "$ANSWER" in t) ARCH_CLEANUP=timer ;; c) ARCH_CLEANUP=crontab ;; o) ARCH_CLEANUP=oracle ;; n) ARCH_CLEANUP=none ;; esac
  save_settings
  _log SETTINGS "ARCH_CLEANUP=$ARCH_CLEANUP (chosen in step 9.8)"
  journal SETTING ARCH_CLEANUP "chosen in step 9.8: $ARCH_CLEANUP"
  say "Saved: ARCH_CLEANUP=$ARCH_CLEANUP. To change it later:  $SELF --settings"
}
d_9_8() {
  if [[ $L98_ASK -eq 1 ]]; then
    arch_choose
    # the list for the choice just made: shown, then asked
    NOW=""; PLAN=""; local r2=0; c_9_8 || r2=$?
    [[ $r2 -eq 0 ]] && return 0
    [[ $r2 -eq 2 ]] && { bad "$NOW"; return 1; }
    cp_show
    ask_choice "[y] Yes, do it   [s] Skip   [q] Quit" "ysq"
    case "$ANSWER" in s) return 3 ;; q) user_stop "Stopped by you" ;; esac
  fi
  # the shown list, in order; each change is journaled right after it is done (a command that failed, and those
  # after it, leave no entry)
  local i c coff=$L98_CRON_OFF
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    if ! cp_exec "$i"; then
      bad "This command failed:  $(head -n 1 <<< "${CP_CMD[$i]}" | mask_pw)"$'\n'"$(tail -n 4 <<< "$RUN_OUT" | mask_pw)"
      [[ $((i + 1)) -lt ${#CP_CMD[@]} ]] && say "The commands after it were not run."
      return 1
    fi
    c=${CP_CMD[$i]}
    case "$c" in
      "rman target /") journal RMANCFG "$STANDBY_SID" "old=${L98_OLDPOL// /~}" ;;
      "systemctl disable --now $(arch_timer)") journal UNITOFF "$(arch_timer)" "taken out (ARCH_CLEANUP=${ARCH_CLEANUP})" ;;
      "systemctl enable $(arch_timer)") journal UNIT "$(arch_timer)" "daily clean-up of applied archived logs at $(arch_time)" ;;
      "c=\$(crontab -u "*)
        # the line put in (it ends with "echo '<line>'") or the line taken out
        if [[ "$c" == *"echo '"* ]]; then journal CRONLINE "$ORACLE_USER" "tag=$(arch_cron_tag | tr ' ' '~')"
        elif [[ -n "$coff" ]]; then journal CRONOFF "$ORACLE_USER" "tag=$(arch_cron_tag | tr ' ' '~')"; fi ;;
    esac
  done
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
  PLAN="Start redo apply (MRP) on this server."
  cp_add oracle "sqlplus -S / as sysdba" "$APPLY_START_SQL"
  return 1
}
d_9_4() {
  local i; i=$(sb_cp_idx oracle "sqlplus -S / as sysdba" "$APPLY_START_SQL") || { bad "Internal error: the start of redo apply was not shown before, so it is not run."; return 1; }
  apply_start_run "$i"
}
apply_start_run() {
  # $1 the index of the shown entry that starts redo apply (steps 9.4, 9.7 and 10.7)
  if ! cp_exec "$1"; then
    bad "Cannot start redo apply ($(ora_errors "$RUN_OUT"))"
    grep -q 'ORA-01153' <<< "$RUN_OUT" && printf 'ORA-01153: another recovery session is active (an old MRP or a manual recover). Cancel it first:\n  alter database recover managed standby database cancel;\n' | hint
    grep -q 'ORA-01154' <<< "$RUN_OUT" && printf 'ORA-01154: the database is OPEN or opening. This script only mounts a physical standby.\n' | hint
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
srv_status_text() {
  # read-only: "srvctl status database -verbose" of the standby, a few lines indented (empty when it gives nothing)
  run_logged "srvctl status database" as_oracle timeout 60 "$DB_HOME/bin/srvctl" status database -db "$STANDBY_UNIQUE" -verbose || true
  local o; o=$(grep -v '^[[:space:]]*$' <<< "$RUN_OUT" | head -n 4 | sed 's/^/  /')
  [[ -n "$o" ]] && printf 'srvctl status database -db %s -verbose:\n%s' "$STANDBY_UNIQUE" "$o"
  return 0
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
      local n=0 pw=$POLL_WAIT sub; [[ $pw -gt 50 ]] && pw=50
      # a unit that has already ended (SubState exited, with RemainAfterExit) waits for nothing any more: no poll
      sub=$(systemctl show -p SubState "$(unit_name)" 2>/dev/null | sed -n 's/^SubState=//p')
      # (STARTED on the way: Oracle Restart is mounting it, so it is looked at again too)
      while [[ "$MODE" != check && "$sub" != exited && ( "$LSTATE" == IDLE || "$LSTATE" == STARTED ) && $n -lt 6 ]]; do
        n=$((n + 1)); say "The standby is not mounted yet. Oracle Restart starts it. Checked again in $pw seconds ($n of 6)"
        nap "$pw"; local_state
      done
      # still in NOMOUNT after step 9.2 mounted it in this run: not a matter of waiting
      if [[ "$LSTATE" == STARTED && $n -gt 0 ]] && [[ "${STEP_RESULT[9.2]:-}" == OK || "${STEP_RESULT[9.2]:-}" == DONE ]]; then
        NOW="$(unit_name) is enabled, but the standby stays in NOMOUNT after step 9.2 mounted it in this run."
        local sst; sst=$(srv_status_text); [[ -n "$sst" ]] && NOW+=$'\n'"$sst"
        PLAN="-- Find out why: the alert log of $STANDBY_SID, and as $ORACLE_USER:"$'\n'"srvctl status database -db $STANDBY_UNIQUE -verbose"$'\n'"-- Then answer r."
        MANUAL_WHERE="To check on this server ($(hostname -s))"; MANUAL_HOW="$ORACLE_USER"
        return 2
      fi
      if [[ "$LSTATE" == IDLE || ( "$LSTATE" == STARTED && $n -gt 0 ) ]]; then
        [[ "$LSTATE" == STARTED ]] && NOW+=$'\n'"It is started (NOMOUNT) but not mounted yet."
        if [[ "$sub" == exited ]]; then
          # the unit has ended: it does not start apply when the standby is mounted later
          NOW+=$'\n'"The standby is not mounted now ($LSTATE), and $(unit_name) has already ended: it does not start redo apply"$'\n'"when Oracle Restart mounts the standby later. After the mount, start apply with step 9.4 (or:  systemctl restart $(unit_name))."
        else
          # the unit waits for Oracle Restart to mount the standby, then starts apply: nothing to do here yet
          NOW+=$'\n'"The standby is not mounted now ($LSTATE). Oracle Restart mounts it (step 9.2); the unit then starts redo apply."
        fi
        local sst; sst=$(srv_status_text)
        if [[ -n "$sst" ]]; then NOW+=$'\n'"$sst"$'\n'"If it stays so, see the alert log of $STANDBY_SID."
        else NOW+=$'\n'"If it stays so, as $ORACLE_USER:  srvctl status database -db $STANDBY_UNIQUE -verbose  (and the alert log)"; fi
        CHECK_WAITS=1; return 0
      fi
    fi
    case "$LSTATE" in
      MOUNTED|OPEN) ;;
      IDLE)
        NOW="$(unit_name) is enabled, but the standby is not running now ($LSTATE)."
        C97_FIX=start; PLAN="Restart the unit: it starts the listener, mounts the standby and starts redo apply."
        cp_add root "systemctl restart $(unit_name)" "" 2100
        return 1 ;;
      *)
        # NOMOUNT (someone works on it by hand) or a state that cannot be read: never restarted by the script
        local oe=""; [[ "$LSTATE" == ERROR ]] && oe=$(ora_errors "$SQL_OUT"); [[ "$LSTATE" == HUNG ]] && oe="hangs: a login gives ORA-01012; step 9.2 stops it"
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
      C97_FIX=lsnr; PLAN="Start the listener $SB_LSNR$(use_grid && printf ' through Oracle Restart')."
      if use_grid; then cp_add grid "srvctl start listener -listener $SB_LSNR"
      else cp_add oracle "lsnrctl start $SB_LSNR" "" 120; fi
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
      C97_FIX=mrp; PLAN="Start redo apply (MRP) on this server."
      cp_add oracle "sqlplus -S / as sysdba" "$APPLY_START_SQL"
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
  # the files that are missing or not as wanted (a backup of an earlier one is kept; --undo puts it back), then
  # the unit is enabled and started
  [[ -f "$sc" && "$(cat "$sc")" == "$(script_text)" ]] || cp_add_file "$sc" 755 "$(script_text)"
  [[ -f "$u" && "$(cat "$u")" == "$(unit_text)" ]] || cp_add_file "$u" 644 "$(unit_text)"
  if need_udev_dropin; then [[ -f "$(udev_dropin)" && "$(cat "$(udev_dropin)")" == "$(dropin_text)" ]] || cp_add_file "$(udev_dropin)" 644 "$(dropin_text)"; fi
  cp_add root "systemctl daemon-reload"
  cp_add root "systemctl enable $(unit_name)"
  cp_add root "systemctl start $(unit_name)" "" 2100
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
  # the unit is right, but what it starts is not running: only that is started (on this server)
  case "$C97_FIX" in
    start) cp_run || { bad "The unit did not start. Check:  systemctl status $(unit_name)"; return 1; }; boot_err_hint; return 0 ;;
    lsnr)
      cp_run || return 1
      journal LSNRSTART "$SB_LSNR" "started from $(lsnr_home)$(use_grid && printf ' via=srvctl')"
      boot_err_hint; return 0 ;;
    mrp) d_9_4 || return 1; boot_err_hint; return 0 ;;
  esac
  # the shown list: the files, daemon-reload, enable, start (each change journaled after it is done; a written
  # file is journaled by the write itself)
  local i
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    if ! cp_exec "$i"; then
      if [[ "${CP_CMD[$i]}" == "systemctl start $(unit_name)" ]]; then
        bad "The unit did not start. Check:  systemctl status $(unit_name)"; systemctl status "$(unit_name)" --no-pager -l 2>&1 | tail -n 8 | hint
      else
        bad "This command failed:  $(head -n 1 <<< "${CP_CMD[$i]}")"$'\n'"$(tail -n 4 <<< "$RUN_OUT")"
        [[ $((i + 1)) -lt ${#CP_CMD[@]} ]] && say "The commands after it were not run."
      fi
      return 1
    fi
    [[ "${CP_CMD[$i]}" == "systemctl enable $(unit_name)" ]] && journal UNIT "$(unit_name)" "enabled (start at boot)"
  done
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
# the release of the standby's own instance ("12.1", "19"): decisions about what the standby can do are taken
# from it, never from the primary's version (which --health does not read). Read once per run; empty when
# it cannot be read
SB_VER=""
sb_version() {
  # sets SB_VER (call it directly, not in $(...), so the value is kept for the run); it uses SQL_OUT
  [[ -n "$SB_VER" ]] && return 0
  local v=""
  sql_local "select version from v\$instance;" && v=$(first_line | tr -d '[:space:]')
  [[ "$v" =~ ^[0-9]+\.[0-9]+ ]] && SB_VER=$v
  return 0
}
# the major release of the standby (0 when it cannot be read); sb_version must have run
# (the primary's release when it was read in this run: both are the same release, step 3.11)
sb_major() { local v=${SB_VER%%.*}; [[ -n "$v" ]] || v=${DB_MAJOR:-0}; [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '0'; }
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
    # old values are no measurement, whatever they say: that diagnosis comes first
    if [[ "$age" =~ ^[0-9]+$ && $age -gt $lim ]]; then
      NOW="No data from the primary for $age seconds (the last lag values, transport $tl and apply $al, are old)"
    elif [[ $tls -ge 0 && $tls -le $lim && $als -ge 0 && $als -le $lim ]]; then
      NOW="Transport lag $tl, apply lag $al"; return 0
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
  local t r lo hi have gone="" gonel="" unread=0
  if [[ -n "$gaps" ]] && ssh_alive; then
    while read -r t r; do
      lo=${r%-*}; hi=${r#*-}
      num "$t" && num "$lo" && num "$hi" || continue
      # a failed read stops the search; what was found so far is still reported (and the rest is said to be unknown)
      prim_sql "select count(distinct sequence#) from v\$archived_log where thread#=$t and sequence# between $lo and $hi and deleted='NO' and status='A' and name is not null and standby_dest='NO' and resetlogs_change#=(select resetlogs_change# from v\$database);" || { unread=1; break; }
      have=$(first_line); num "$have" || { unread=1; break; }
      [[ $have -lt $((hi - lo + 1)) ]] && { gone+="  thread $t, sequence $lo to $hi"$'\n'; gonel+="$t $lo-$hi"$'\n'; }
    done <<< "$gaps"
  elif [[ -n "$gaps" ]]; then
    # not looked at: said, so nobody waits for fal_server to send logs the primary may no longer have
    NOW+=$'\n'"Whether the missing logs are still on the primary was not checked (no ssh connection to the primary)."
  fi
  [[ $unread -eq 1 ]] && NOW+=$'\n'"Whether the missing logs are still on the primary could not be read$([[ -n "$gone" ]] && printf ' for the other gaps')."
  if [[ -n "$gone" ]]; then
    NOW+=$'\n'"Some of these logs are no longer on the disk of the primary, so fal_server cannot send them:"$'\n'"${gone%$'\n'}"
    PLAN="-- 1) Restore them on the primary from its backup (RMAN there, as $ORACLE_USER), for each line above:"
    while read -r t r; do [[ -n "$t" ]] && PLAN+=$'\n'"restore archivelog from sequence ${r%-*} until sequence ${r#*-} thread $t;"; done <<< "$gonel"
    PLAN+=$'\n'"--    fal_server then sends them within minutes."
    sb_version
    if [[ $(sb_major) -ge 18 ]]; then PLAN+=$'\n'"-- 2) Or, without the logs, roll the standby forward from the primary:  $SELF --roll-forward"
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
  # the standby's own release decides (12.1 has no v$nonlogged_block); not known: the view itself tells
  sb_version
  local r121=0 nrc=0
  if [[ "$SB_VER" =~ ^12\.1\. ]]; then r121=1
  elif [[ -z "$SB_VER" && "${PRIMARY_VERSION:-}" =~ ^12\.1\. ]]; then r121=1; fi
  if [[ $r121 -eq 0 ]]; then
    sql_local "select count(*)||' '||nvl(sum(blocks),0) from v\$nonlogged_block;" || { nrc=1; [[ -z "$SB_VER" ]] && grep -q 'ORA-00942' <<< "$SQL_OUT" && r121=1; }
  fi
  if [[ $r121 -eq 1 ]]; then
    # 12.1 keeps no list of nonlogged blocks on a standby: only force logging can be looked at
    fnote="12.1 keeps no list of nonlogged blocks: only force logging is checked."
  else
    [[ $nrc -eq 0 ]] || { NOW="Cannot read v\$nonlogged_block on the standby: $(ora_errors "$SQL_OUT")"; return 2; }
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
    YES) if [[ -n "$fnote" ]]; then NOW="Force logging is on at the primary. $fnote"; else NOW="No unrecoverable changes; force logging is on at the primary"; fi; return 0 ;;
    "STANDBY NOLOGGING"*)
      # 18c and later, set on purpose: the list of nonlogged blocks above is the proof for this standby
      if [[ -n "$fnote" ]]; then NOW="The primary uses $fl (set on purpose). $fnote"; else NOW="No unrecoverable changes. The primary uses $fl (set on purpose)."; fi; return 0 ;;
  esac
  NOW="$([[ -n "$fnote" ]] && printf 'Force logging is off at the primary' || printf 'No unrecoverable changes so far, but force logging is off at the primary') (force_logging = $fl)."$'\n'"A NOLOGGING load there would leave unusable blocks on the standby. On the primary:  alter database force logging;"$'\n'"(Force logging set per PDB or per tablespace is not looked at here.)${fnote:+$'\n'$fnote}"
  CHECK_WAITS=1
  return 0
}
# ---- 10.8 archived logs: space and the nightly clean-up ----
# A recovery area that is "full" but whose logs are all reclaimable is fine (Oracle deletes applied logs when it
# needs space); one that fills with logs that are NOT reclaimable stops redo transport (ORA-19809).
c_10_8() {
  need_built || return 2
  local_state
  [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { NOW="The standby is not mounted (step 9.2)"; return 2; }
  local used recl real=0 msg="" bad=0 warnl=0 waits=0 lrc d
  # where the standby really archives (read from it, not from the settings: a standby made by hand may differ)
  local rfra dests v
  sql_local "select nvl(max(value),'-') from v\$parameter where name='db_recovery_file_dest';" || { NOW="Cannot read the standby ($(ora_errors "$SQL_OUT"))"; return 2; }
  rfra=$(first_line); [[ "$rfra" == "-" ]] && rfra=""
  sql_local "select value from v\$parameter where name like 'log_archive_dest_%' and upper(value) like '%LOCATION=%' order by to_number(regexp_substr(name, '[0-9]+\$'));" || { NOW="Cannot read the archive destinations of the standby ($(ora_errors "$SQL_OUT"))"; return 2; }
  # every local destination, each once (a second one can fill up as well)
  dests=$(grep -oiE 'location=[^ ]+' <<< "$SQL_OUT" | sed 's/^[^=]*=//' | awk 'toupper($0) == "USE_DB_RECOVERY_FILE_DEST" {$0 = "USE_DB_RECOVERY_FILE_DEST"} !s[$0]++')
  [[ -z "$dests" && -n "$rfra" ]] && dests=USE_DB_RECOVERY_FILE_DEST
  [[ -n "$dests" ]] || { NOW="The standby has no local archive destination (log_archive_dest_n with LOCATION) and no recovery area."; return 1; }
  # a disk group: its own free space counts too (a recovery area quota inside a full disk group still fails)
  _dg_low() {
    local g=${1#+}; g=${g%%/*}; local f t
    sql_asm "select free_mb||'|'||total_mb from v\$asm_diskgroup where name=upper('$g');" || return 2
    IFS='|' read -r f t <<< "$(first_line)"; num "$f" && num "$t" && [[ $t -gt 0 ]] || return 2
    DG_FREE_PCT=$(( f * 100 / t )); [[ $DG_FREE_PCT -lt 10 ]]
  }
  # a folder: how full its file system is (DF_USED, percent); 1 when df cannot tell
  _df_used() { DF_USED=$(df -P -- "$1" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}'); num "$DF_USED"; }
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    msg+="${msg:+$'\n'}"
    if [[ "$d" == USE_DB_RECOVERY_FILE_DEST ]]; then
      sql_local "select nvl(round(sum(percent_space_used)),0)||'|'||nvl(round(sum(percent_space_reclaimable)),0) from v\$recovery_area_usage;" \
        || { NOW="Cannot read v\$recovery_area_usage ($(ora_errors "$SQL_OUT"))"; return 2; }
      IFS='|' read -r used recl <<< "$(first_line)"
      num "$used" && num "$recl" || { NOW="Unexpected answer from v\$recovery_area_usage: $(first_line)"; return 2; }
      real=$(( used - recl )); [[ $real -lt 0 ]] && real=0
      msg+="Recovery area $rfra: ${used}% used, ${recl}% of it reclaimable (applied logs), ${real}% not reclaimable"
      [[ $real -ge 90 ]] && bad=1; [[ $real -ge 80 && $real -lt 90 ]] && warnl=1
      if [[ "$rfra" == +* ]]; then
        # a disk group that cannot be read: cannot check, never OK (the same rule as an archive disk group)
        lrc=0; _dg_low "$rfra" || lrc=$?
        [[ $lrc -eq 2 ]] && { NOW="Cannot read the free space of disk group $(dg_of "$rfra") (recovery area $rfra)"; return 2; }
        if [[ $lrc -eq 0 ]]; then msg+=$'\n'"Disk group $(dg_of "$rfra") has only ${DG_FREE_PCT}% free: the recovery area cannot grow to its size"; bad=1
        elif [[ $DG_FREE_PCT -lt 20 ]]; then msg+=$'\n'"Disk group $(dg_of "$rfra") has only ${DG_FREE_PCT}% free"; warnl=1; fi
      elif [[ "$rfra" == /* ]]; then
        # its size (db_recovery_file_dest_size) may be more than its file system really has free
        _df_used "$rfra" || { NOW="Cannot read the free space of $rfra (df)"; return 2; }
        msg+=$'\n'"Its file system: ${DF_USED}% used"
        [[ $DF_USED -ge 90 ]] && bad=1; [[ $DF_USED -ge 80 && $DF_USED -lt 90 ]] && warnl=1
      fi
    elif [[ "$d" == +* ]]; then
      lrc=0; _dg_low "$d" || lrc=$?
      [[ $lrc -eq 2 ]] && { NOW="Cannot read the free space of disk group $(dg_of "$d")"; return 2; }
      msg+="Archive destination $d: ${DG_FREE_PCT}% of the disk group free"
      # the same bands as a folder: less than 10% free is a problem, less than 20% needs attention
      [[ $lrc -eq 0 ]] && bad=1; [[ $lrc -eq 1 && $DG_FREE_PCT -lt 20 ]] && warnl=1
    else
      _df_used "$d" || { NOW="Cannot read the free space of $d (df)"; return 2; }
      msg+="Archive folder $d: ${DF_USED}% of its file system used"
      [[ $DF_USED -ge 90 ]] && bad=1; [[ $DF_USED -ge 80 && $DF_USED -lt 90 ]] && warnl=1
    fi
  done <<< "$dests"
  # the clean-up that ARCH_CLEANUP chose: did its last run work?
  local mode=${ARCH_CLEANUP:-} cmsg=""
  case "$mode" in
    timer)   case "$(arch_timer_state)" in
               ok)     cmsg="Nightly clean-up: $(arch_timer) runs (at $(arch_time))" ;;
               failed) cmsg="The last run of $(arch_service) failed (journalctl -u $(arch_service)). Step 9.8 runs it again."; bad=1 ;;
               off)    cmsg="$(arch_timer) is not running. Step 9.8 starts it."; bad=1 ;;
               *)      cmsg="$(arch_timer) is not set up as wanted. Step 9.8 sets it up."; bad=1 ;;
             esac ;;
    crontab) case "$(arch_cron_state)" in
               ok)     cmsg="Nightly clean-up: the crontab of $ORACLE_USER (at $(arch_time)), last run without errors" ;;
               failed) cmsg="The last clean-up run from the crontab printed: $(arch_cron_last_errors | head -n 1). Log: $(arch_cron_log)"; bad=1 ;;
               *)      cmsg="The clean-up line in the crontab of $ORACLE_USER is missing or not as wanted. Step 9.8 sets it."; bad=1 ;;
             esac
             # a cron line that has not run for two days (cron stopped, a wrong time)
             local lf; lf=$(arch_cron_log)
             if [[ $bad -eq 0 && -f "$lf" && -n "$(find "$lf" -mmin +$((49 * 60)) 2>/dev/null)" ]]; then cmsg+="; but its log has not changed for more than two days (is crond running?)"; warnl=1; fi ;;
    oracle)  # (the same rule as 9.8: Oracle deletes only in the recovery area)
             local outside; outside=$(grep -vx USE_DB_RECOVERY_FILE_DEST <<< "$dests" | paste -sd' ' -)
             if [[ -n "$outside" ]]; then
               cmsg="ARCH_CLEANUP=oracle, but archived logs also go to $outside, not to the recovery area. Oracle deletes nothing there."$'\n'"Choose timer or crontab ($SELF --settings), then run step 9.8."; bad=1
             else cmsg="Clean-up: left to the recovery area (ARCH_CLEANUP=oracle)"; fi ;;
    none)    cmsg="Clean-up: none (ARCH_CLEANUP=none): watch the space" ;;
    *)       cmsg="Clean-up: not chosen yet (ARCH_CLEANUP is empty): nothing deletes applied logs here. Step 9.8 asks."; waits=1 ;;
  esac
  # the RMAN deletion policy that step 9.8 set (changed later, or the primary's back after a roll forward):
  # attention, not a failure (read-only; the space above shows its effect)
  if [[ "$mode" == timer || "$mode" == crontab || "$mode" == oracle ]]; then
    if sql_local "select nvl(max(value),'-') from v\$rman_configuration where name='ARCHIVELOG DELETION POLICY';"; then
      v=$(first_line)
      arch_policy_is_ok "$v" || { cmsg+=$'\n'"RMAN archivelog deletion policy: ${v/#-/not set}, not TO APPLIED ON STANDBY. Applied logs may not be deleted here (step 9.8 sets it)."; waits=1; }
    else
      cmsg+=$'\n'"Cannot read the RMAN archivelog deletion policy ($(ora_errors "$SQL_OUT"))"; waits=1
    fi
  fi
  # attention that comes from the clean-up part: its lines first (the --health summary shows the first two lines)
  if [[ $waits -eq 1 && $bad -eq 0 ]]; then NOW="$cmsg"$'\n'"$msg"; else NOW="$msg"$'\n'"$cmsg"; fi
  if [[ $bad -eq 1 ]]; then
    [[ "$msg" == *"not reclaimable"* && $real -ge 90 ]] && NOW+=$'\n'"Logs that are not applied (or not reclaimable) fill the recovery area. Check redo apply (10.4) and the deletion policy (9.8)."
    return 1
  fi
  # not chosen, or a policy that does not fit: waiting (WARNING in --health), never OK
  [[ $waits -eq 1 ]] && { CHECK_WAITS=1; return 0; }
  if [[ $warnl -eq 1 ]]; then
    if [[ ${HEALTH:-0} -eq 1 ]]; then CHECK_WAITS=1; else warn "${NOW%%$'\n'*}"; fi
  fi
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
  lp=$(local_patches "$DB_HOME") || { NOW="Cannot list $DB_HOME/inventory/oneoffs on this server"; return 2; }
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
RF_DONE=0; RF_FINISH=0; RF_FAILED=""; RF_FRA="-"
rf_pending_file() { printf '%s/rollforward_pending' "$STATE_DIR"; }
rf_log() { printf '%s/rollforward_%s.log' "$LOG_DIR" "$RUN_ID"; }
rf_rman_input() {
  # the input of the RMAN job; $1 the password (the real one for the job, ***** for the screen): one text for both
  printf 'connect target sys/"%s"@%s\n' "$1" "$STANDBY_TNS"
  printf 'recover standby database from service %s;\n' "$PRIMARY_TNS"
  printf 'exit\n'
}
rf_job_text() {
  # what the job runs, as shown before ROLLFORWARD (run_long starts exactly this, in its own session)
  printf '%s/bin/rman <<'"'"'EOF'"'"'\n' "$DB_HOME"
  rf_rman_input '*****' | sed 's/^/  /'
  printf 'EOF\n(output: %s)\n' "$(rf_log)"
}
rf_login_test() {
  # RMAN logs in to the standby as target (the way the roll forward does) and to the primary alias (as auxiliary
  # here: FROM SERVICE uses the same credentials to reach it). The password travels on stdin only
  local ltmp lrc=0
  ltmp=$(mktemp /tmp/dg_out.XXXXXXXX) || { NOW="Cannot create a temporary file"; return 2; }
  CLEANUP_FILES+=("$ltmp")
  { printf 'connect target sys/"%s"@%s\n' "$SYS_PW" "$STANDBY_TNS"; printf 'connect auxiliary sys/"%s"@%s\n' "$SYS_PW" "$PRIMARY_TNS"; printf 'exit\n'; } \
    | as_oracle timeout 120 "$DB_HOME/bin/rman" > "$ltmp" 2>&1 || lrc=1
  RUN_OUT=$(mask_pw < "$ltmp"); rm -f -- "$ltmp"
  printf '%s\n(exit code %s)\n' "$RUN_OUT" "$lrc" | log_block "rman login test (roll forward)"
  grep -q 'connected to target database' <<< "$RUN_OUT" && grep -q 'connected to auxiliary database' <<< "$RUN_OUT" && return 0
  NOW="RMAN cannot log in to both databases with the sys password: $(grep -E '(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ')"
  local hx; hx=$(dg_error_hint "$RUN_OUT"); [[ -n "$hx" ]] && NOW+=$'\n'"Usual cause:"$'\n'"$hx"
  # a wrong password: it can be typed again in this run (answer p)
  if grep -qE 'ORA-0?1017' <<< "$RUN_OUT"; then
    NEED_SYS=1
    if grep -q 'connected to target database' <<< "$RUN_OUT"; then
      NOW+=$'\n'"The primary refused the password. Answer p to type it again."
    else
      NOW+=$'\n'"The standby refused the password. If it is wrong, answer p to type it again. If it is right (the primary"$'\n'"accepted it in step 1.5), the password file of the standby is older than the primary's: copy it again with"$'\n'"step 6.1  ($SELF --only 6.1)."
    fi
  fi
  return 1
}
rf_wallet_bad() {
  # stdin: "con_id|wallet_type|status|keystore_mode" rows of v$encryption_wallet. Prints (up to 3) wallets that
  # would not open by themselves after a restart; nothing when all would. The root (con_id 0 in a non-CDB, 1 in
  # a CDB) must have an open auto-login wallet; a PDB in united mode goes with it, any other must have its own
  # Lines: "B|text" = would not open (a password wallet), "U|text" = cannot be judged here. In MOUNT an open
  # keystore shows OPEN_UNKNOWN_MASTER_KEY_STATUS (the key cannot be verified before open): that is open. A
  # container may have several rows (HSM and a file wallet, wallet_order): one good row is enough
  awk -F'|' '
    function good(t, s) { return t ~ /^(LOCAL_)?AUTOLOGIN$/ && (s == "OPEN" || s == "OPEN_UNKNOWN_MASTER_KEY_STATUS") }
    { c = $1; if (!(c in seen)) { seen[c] = 1; order[++n] = c }
      if (good($2, $3)) ok[c] = 1
      if ($2 == "PASSWORD") pw[c] = 1
      if ($3 == "NOT_AVAILABLE") na[c] = 1
      if ($4 == "UNITED") un[c] = 1
      if ($4 == "ISOLATED") iso[c] = 1
      txt[c] = txt[c] (txt[c] == "" ? "" : "; ") $2 ", " $3 }
    END {
      root = ("1" in seen) ? "1" : (("0" in seen) ? "0" : "")
      if (root == "") { print "U|no row for the root container: its wallet cannot be judged"; exit }
      if (!(root in ok)) print ((root in pw || root in na) ? "B" : "U") "|root container: " txt[root] ((root in na) ? " (no wallet found here)" : "")
      for (i = 1; i <= n; i++) { c = order[i]; if (c == root || c in ok || c == 0 && root == 1) continue
        if (c in un && !(c in iso)) continue
        print ((c in pw) ? "B" : "U") "|container " c ": " txt[c] ((c in iso) ? " (isolated wallet)" : "") }
    }' | sort -s -t'|' -k1,1 | head -n 3
}
rf_convert_ok() {
  # $1 db_file_name_convert of the standby, $2 the standby's datafiles, $3 the primary's ("file#|name" lines).
  # Each file both have, named differently, must become exactly the standby's name by the convert pairs, the way
  # Oracle applies them (the first pair whose string is in the name; that part is replaced). RF_CONV_BAD: the
  # first file that does not
  local -a pr=(); local x i fno fn pn conv hit
  RF_CONV_BAD=""
  IFS=',' read -r -a pr <<< "$1"
  for i in "${!pr[@]}"; do x=${pr[$i]}; x=${x#"${x%%[![:space:]]*}"}; x=${x%"${x##*[![:space:]]}"}; x=${x#\'}; x=${x%\'}; pr[$i]=$x; done
  [[ ${#pr[@]} -ge 2 && $(( ${#pr[@]} % 2 )) -eq 0 ]] || { RF_CONV_BAD="db_file_name_convert ($1) is not a list of pairs"; return 1; }
  while IFS='|' read -r fno fn; do
    [[ -n "$fno" && "$fn" != *UNNAMED* ]] || continue
    pn=$(grep -m1 "^$fno|" <<< "$3" | cut -d'|' -f2-)
    [[ -z "$pn" || "$pn" == "$fn" ]] && continue
    conv=""; hit=0
    for ((i = 0; i < ${#pr[@]}; i += 2)); do
      [[ -n "${pr[$i]}" && "$pn" == *"${pr[$i]}"* ]] || continue
      conv=${pn/"${pr[$i]}"/"${pr[$((i + 1))]}"}; hit=1; break
    done
    if [[ $hit -eq 0 ]]; then RF_CONV_BAD="file $fno: $pn (no pair of db_file_name_convert matches it)"; return 1; fi
    [[ "$conv" == "$fn" ]] || { RF_CONV_BAD="file $fno: $pn becomes $conv, but the standby's file is $fn"; return 1; }
  done <<< "$2"
  return 0
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
      # an OPEN standby runs already: it must be mounted again, not started (the same as a new roll forward)
      if [[ "$LSTATE" == OPEN ]]; then
        NOW="The roll forward of an earlier run has ended, but the standby is OPEN. Its clean-up needs it mounted."
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="On this server, sqlplus / as sysdba"
        PLAN="shutdown immediate"$'\n'"startup mount"; return 1
      fi
      [[ "$LSTATE" == MOUNTED ]] || { NOW="The roll forward of an earlier run has ended, but the standby is not mounted ($LSTATE). Start it (step 9.2), then run again."; return 2; }
      RF_FINISH=1
      local fb0; sql_local "select flashback_on from v\$database;" && fb0=$(first_line) || fb0="?"; RF_FB=$fb0
      NOW="The roll forward of an earlier run has ended without error (output: $plog)."$'\n'"It was not checked yet, and redo apply is stopped."
      [[ "$fb0" == "YES" ]] && NOW+=$'\n'"Flashback database is on here. Its logs are no longer usable after the roll forward: turn it off and on again afterwards."
      [[ "$fb0" == "?" ]] && NOW+=$'\n'"Whether flashback database is on here could not be read ($(ora_errors "$SQL_OUT")). If it is on, turn it off and on again after the roll forward."
      PLAN="-- Check the standby, set its standby redo logs and RMAN settings again (9.3, 9.8) and start redo apply.
-- RMAN is not run again. The commands of each part are worked out from the standby as it is then, and
-- shown before that part runs."
      return 1
    fi
    # it did not finish: said, and the roll forward may be started again (every check below runs first)
    warn "The roll forward of an earlier run did not finish (exit code ${prc:-unknown}; output: ${plog:-unknown}). Redo apply is stopped."
    rm -f -- "$pf"
  fi
  need_built || return 2
  need_ssh || return 2
  # the standby's own release decides (RMAN of this home runs the command)
  sb_version
  local rel; rel=$(sb_major)
  [[ $rel -gt 0 ]] || { NOW="The release of the standby instance cannot be read: $(ora_errors "$SQL_OUT")"; return 2; }
  if [[ $rel -lt 18 ]]; then
    # not something to answer r to: the script cannot do it on this release (shown, recorded as waiting)
    NOW="Release $rel has no single roll-forward command (it came with 18c). The script does not do it here."$'\n'"By hand: Oracle note 1987763.1 (stop redo apply; in RMAN  recover database from service $PRIMARY_TNS noredo;"$'\n'"restore the standby control file from service $PRIMARY_TNS; catalog and switch the datafiles; restore the"$'\n'"datafiles added since; start redo apply). Or make a new copy (phase 8)."
    CHECK_WAITS=1; return 0
  fi
  local_state
  case "$LSTATE" in
    MOUNTED) ;;
    OPEN) NOW="The standby is OPEN. The roll forward needs it mounted."; KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="On this server, sqlplus / as sysdba"
          PLAN="shutdown immediate"$'\n'"startup mount"; return 1 ;;
    IDLE|STARTED|HUNG) NOW="The standby instance is not mounted ($LSTATE). Start it first (step 9.2)."; return 2 ;;
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
  # a convert parameter counts only when it really gives every standby name (else the OMF rule may still fit)
  local convnote=""
  if [[ $same -eq 0 && "$dfc" != "-" ]] && ! rf_convert_ok "$dfc" "$sfiles" "$pfiles"; then convnote=$RF_CONV_BAD; dfc="-"; fi
  if [[ $same -eq 1 ]]; then how="the datafiles have the same names on both servers"
  elif [[ "$dfc" != "-" ]]; then how="db_file_name_convert of the standby gives the standby's name of every datafile"
  elif [[ "$cfd" != "-" ]] && ! cut -d'|' -f2- <<< "$sfiles" | grep -v UNNAMED | grep -qviF -- "$cfd/" \
       && ! cut -d'|' -f2- <<< "$sfiles" | grep -v UNNAMED | grep -qvE '^\+[^/]+/.+\.[0-9]+\.[0-9]+$|/o1_mf_[^/]+$'; then how="the standby's datafiles are Oracle-managed files in $cfd"
  else
    NOW="The standby's datafiles have other names than the primary's, and neither db_file_name_convert nor"$'\n'"Oracle-managed files (db_create_file_dest) would let RMAN find them again after the roll forward."${convnote:+$'\n'"db_file_name_convert does not fit: $convnote"}$'\n'"The script does not roll this standby forward. Make a new copy (phase 8), or set db_file_name_convert on"$'\n'"the standby (scope=spfile, then restart) to map the primary's folders to the standby's, and run again."
    CHECK_WAITS=1; return 0
  fi
  # TDE: RMAN restarts the instance; an encrypted standby needs a wallet that opens by itself
  [[ ${TDE_UNREAD:-0} -eq 1 ]] && { NOW="Whether the primary uses TDE cannot be read (step 1.3), so the wallet of the standby cannot be judged."; return 2; }
  if awk -F'|' '$3 == "OPEN" {f=1} END {exit !f}' <<< "$TDE_INFO"; then
    # one row per container in a CDB: every one must open by itself after the restart. A PDB in united mode uses
    # the wallet of the root (so the root's row decides for it); an isolated PDB has its own wallet
    sql_local "select 'W:'||con_id||'|'||wallet_type||'|'||status||'|'||nvl(keystore_mode,'NONE') from v\$encryption_wallet;" || { NOW="Cannot read the wallet of the standby: $(ora_errors "$SQL_OUT")"; return 2; }
    local wrows wbad
    wrows=$(sed -n 's/^[[:space:]]*W://p' <<< "$SQL_OUT" | sed 's/[[:space:]]*$//')
    [[ -n "$wrows" ]] || { NOW="The wallet of the standby cannot be read (v\$encryption_wallet gave no row)."; return 2; }
    wbad=$(rf_wallet_bad <<< "$wrows")
    if grep -q '^B|' <<< "$wbad"; then
      NOW="The primary uses TDE, but a wallet of the standby would not open by itself when RMAN restarts the instance:"$'\n'"$(sed 's/^[BU]|/  /' <<< "$wbad")"$'\n'"Every wallet must be an auto-login wallet (AUTOLOGIN or LOCAL_AUTOLOGIN). Step 6.3."; return 2
    elif [[ -n "$wbad" ]]; then
      NOW="The primary uses TDE, and whether these wallets of the standby open by themselves after a restart cannot be told"$'\n'"while it is mounted:"$'\n'"$(sed 's/^[BU]|/  /' <<< "$wbad")"$'\n'"The script does not roll it forward. Check the wallets (v\$encryption_wallet after open, step 6.3), or do it by hand"$'\n'"(see:  $SELF --help-step 10.7)."; return 2
    fi
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
  [[ "$fb" == "?" ]] && NOW+=$'\n'"Whether flashback database is on here could not be read ($(ora_errors "$SQL_OUT")). If it is on, turn it off and on again after the roll forward."
  RF_FB=$fb
  # redo apply is stopped first (shown under "Will run"); RMAN runs as a job (shown in the plan)
  mrp_running && cp_add oracle "sqlplus -S / as sysdba" "$APPLY_STOP_SQL"
  PLAN="-- 1) $(cp_any && printf 'Redo apply is stopped (see Will run). ')RMAN runs as a job, as $ORACLE_USER on this server:
$(rf_job_text)
-- RMAN restarts the standby instance, takes the control file of the primary, copies the datafiles added since,
-- and fetches the changes as incremental backups. The primary builds and sends those backups over the network:
-- it reads its data and works for a while, but nothing on the primary is changed.
-- 2) The control file then lists the primary's standby redo logs and RMAN settings: those log groups are dropped,
--    or cleared when their files are on this server (standby_file_management is MANUAL for that moment), and the
--    standby's own are added again (step 9.3);
--    RMAN catalogs the recovery area and cross-checks the archived logs; the deletion policy is set again (9.8).
-- 3) Redo apply is started again (9.4).
-- The commands of 2) and 3) depend on the control file RMAN brings: they are shown before each part runs."
  return 1
}
rf_after() {
  # after RECOVER STANDBY DATABASE FROM SERVICE the control file is the primary's: it lists the primary's standby
  # redo logs (with the primary's names), the primary's RMAN settings, and none of the archived logs here.
  # Each part is worked out from the standby as it is now, its commands are shown, then run (ROLLFORWARD covers them).
  # 1) standby redo logs: the listed groups are dropped (only their entries: no file of this standby is named
  #    there) and the standby's own are added again (step 9.3)
  local rc=0 g groups mem m allhere i
  # redo apply must not run meanwhile (the boot script or a hand start may have started it since)
  dg_proc_count MRP || { bad "Cannot tell whether redo apply runs: $(ora_errors "$SQL_OUT")"; RF_FAILED=" srl catalog policy"; RF_FRA="?"; return 1; }
  sql_local "select group# from v\$standby_log order by group#;" || { bad "Cannot read the standby redo logs: $(ora_errors "$SQL_OUT")"; RF_FAILED=" srl catalog policy"; RF_FRA="?"; return 1; }
  groups=$(grep -oE '^[[:space:]]*[0-9]+' <<< "$SQL_OUT" | tr -d ' ')
  cp_reset
  [[ $DGP_COUNT -ge 1 ]] && cp_add oracle "sqlplus -S / as sysdba" "$APPLY_STOP_SQL"
  if [[ -n "$groups" ]]; then
    cp_add oracle "sqlplus -S / as sysdba" "alter system set standby_file_management=manual scope=memory;"
    for g in $groups; do
      # a group whose files are on this server (the same paths on both servers) is cleared, so the files are used
      # again; a group that names files of the primary only is dropped (its entry; no file here is named)
      sql_local "select 'M:'||member from v\$logfile where group#=$g and type='STANDBY';" || { warn "Cannot read the members of group $g: $(ora_errors "$SQL_OUT")"; rc=1; continue; }
      mem=$(sed -n 's/^[[:space:]]*M://p' <<< "$SQL_OUT"); allhere=1
      [[ -n "$mem" ]] || allhere=0
      while IFS= read -r m; do [[ -n "$m" && "$m" == /* && -f "$m" ]] || allhere=0; done <<< "$mem"
      if [[ $allhere -eq 1 ]]; then cp_add oracle "sqlplus -S / as sysdba" "alter database clear logfile group $g;"
      else cp_add oracle "sqlplus -S / as sysdba" "alter database drop standby logfile group $g;"; fi
    done
    cp_add oracle "sqlplus -S / as sysdba" "alter system set standby_file_management=auto scope=memory;"
  fi
  if cp_any; then
    say "After the roll forward: redo apply stays stopped, the standby redo log entries of the primary go:"; cp_show
    for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
      cp_exec "$i" && continue
      case "${CP_IN[$i]}" in
        "$APPLY_STOP_SQL") bad "Cannot stop redo apply: $(ora_errors "$RUN_OUT")"; RF_FAILED=" srl catalog policy"; RF_FRA="?"; return 1 ;;
        *"=manual "*) bad "Cannot set standby_file_management: $(ora_errors "$RUN_OUT")"; RF_FAILED=" srl catalog policy"; RF_FRA="?"; return 1 ;;
        *"=auto "*) warn "Set it back by hand:  alter system set standby_file_management=auto scope=memory;"; rc=1 ;;
        *) g=$(grep -oE '[0-9]+;$' <<< "${CP_IN[$i]}"); warn "Group ${g%;} could not be $([[ "${CP_IN[$i]}" == *clear* ]] && printf cleared || printf dropped): $(ora_errors "$RUN_OUT")"; rc=1 ;;
      esac
    done
  fi
  if [[ $rc -eq 0 ]]; then d_9_3_wrap || rc=1; fi
  [[ $rc -eq 0 ]] || RF_FAILED+=" srl"
  # 2) the archived logs and backups here, as RMAN knows them: the recovery area is catalogued again and every
  #    archived log is cross-checked (else the recovery area could not reclaim the old logs and fills up)
  local fra
  # a recovery area that cannot be read is not taken as "none": the cross-check still runs, the catalog is
  # reported as not done ("?": rf_redo_hint names it)
  sql_local "select nvl(max(value),'-') from v\$parameter where name='db_recovery_file_dest';" && fra=$(first_line) || fra="?"
  [[ -n "$fra" ]] || fra="?"
  [[ "$fra" == "?" ]] && { warn "Cannot read db_recovery_file_dest ($(ora_errors "$SQL_OUT")): the recovery area is not catalogued."; rc=1; RF_FAILED+=" catalog"; RF_FRA="?"; }
  local rin="crosscheck archivelog all;"$'\n'"exit"
  [[ "$fra" != "-" && "$fra" != "?" ]] && rin="catalog recovery area noprompt;"$'\n'"$rin"
  cp_reset; cp_add oracle "rman target /" "$rin" 1800
  say "After the roll forward: the archived logs here, as RMAN knows them:"; cp_show
  cp_exec 0 || { warn "RMAN could not catalog or cross-check the archived logs: $(ora_errors "$RUN_OUT")"; rc=1; [[ "$RF_FAILED" == *catalog* ]] || RF_FAILED+=" catalog"; RF_FRA=$fra; }
  # 3) the deletion policy of the standby (step 9.8): the primary's came with its control file
  #    (only the policy: the nightly schedule is not touched by the roll forward)
  local r8=0; c_9_8 >/dev/null 2>&1 || r8=$?
  if [[ $r8 -eq 2 ]]; then warn "The deletion policy of archived logs could not be checked (step 9.8)."; rc=1; RF_FAILED+=" policy"
  elif [[ $ARCH_POLICY_OK -eq 0 ]]; then arch_policy_wrap || { rc=1; RF_FAILED+=" policy"; }; fi
  # 4) Oracle Restart: RMAN started the instance itself, outside Oracle Restart
  if use_grid; then
    run_logged "srvctl status" as_oracle timeout 600 "$DB_HOME/bin/srvctl" status database -db "$STANDBY_UNIQUE" || true
    grep -qi 'is not running' <<< "$RUN_OUT" && warn "Oracle Restart shows $STANDBY_UNIQUE as not running (RMAN started it outside Oracle Restart)."$'\n'"At a quiet time, as $ORACLE_USER:  srvctl stop database -db $STANDBY_UNIQUE ; srvctl start database -db $STANDBY_UNIQUE -startoption mount"$'\n'"Then start redo apply again (step 9.4)."
  fi
  return $rc
}
rf_redo_hint() {
  # what is left after a clean-up that did not finish, by its parts (RF_FAILED)
  {
    [[ "$RF_FAILED" == *srl* ]] && printf 'Standby redo logs:  %s --only 9.3\n' "$SELF"
    if [[ "$RF_FAILED" == *catalog* ]]; then
      printf 'Archived logs, as %s on this server:  rman target /\n' "$ORACLE_USER"
      case "${RF_FRA:--}" in -) ;; "?") printf '  catalog recovery area noprompt;      (only when db_recovery_file_dest is set)\n' ;; *) printf '  catalog recovery area noprompt;\n' ;; esac
      printf '  crosscheck archivelog all;\n'
    fi
    [[ "$RF_FAILED" == *policy* ]] && printf 'Deletion policy of archived logs:  %s --only 9.8\n' "$SELF"
    [[ -n "$RF_FAILED" ]] || printf 'Run the steps again to finish it:  %s --only 9.3-9.8\n' "$SELF"
  } | hint
}
# the steps' own functions, with their journal entries under their own step numbers
# (after the roll forward, which you confirmed with ROLLFORWARD: each list is shown, then run)
d_9_3_wrap() {
  local CUR_STEP=9.3 NOW="" PLAN="" USING="" r=0
  cp_reset; c_9_3 || r=$?
  [[ $r -eq 0 ]] && { say "The standby redo logs are there (step 9.3)."; return 0; }
  [[ $r -eq 2 ]] && { bad "${NOW:-Step 9.3 cannot be checked}"; return 1; }
  say "Step 9.3, the standby redo logs of the standby:"; cp_show
  d_9_3
}
d_9_4_wrap() {
  local CUR_STEP=9.4
  cp_reset; cp_add oracle "sqlplus -S / as sysdba" "$APPLY_START_SQL"
  say "Step 9.4, redo apply:"; cp_show
  d_9_4
}
arch_policy_wrap() {
  # the RMAN deletion policy of step 9.8 alone (journaled under 9.8)
  local CUR_STEP=9.8
  cp_reset; cp_add oracle "rman target /" "CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;" 300
  say "Step 9.8, the RMAN deletion policy of archived logs:"; cp_show
  cp_run || return 1
  journal RMANCFG "$STANDBY_SID" "old=${L98_OLDPOL// /~}"
}
d_10_7() {
  local pf rlog rc=0; pf=$(rf_pending_file)
  if [[ $RF_FINISH -eq 1 ]]; then
    IFS='|' read -r rlog _ < "$pf"
    # the clean-up drops or clears standby redo logs and resets RMAN settings: asked like a fresh roll forward
    confirm_word "Finish the roll forward of the earlier run now (standby redo logs, RMAN settings, redo apply)." "ROLLFORWARD" || { say "Nothing was changed."; return 3; }
  else
    confirm_word "Roll the standby forward from the primary now." "ROLLFORWARD" || { say "The roll forward was not started."; return 3; }
    # apply must be stopped: a process list that cannot be read is no "not running"
    dg_proc_count MRP || { bad "Cannot tell whether redo apply runs: $(ora_errors "$SQL_OUT")"; return 1; }
    if [[ $DGP_COUNT -ge 1 ]]; then
      local istop; istop=$(sb_cp_idx oracle "sqlplus -S / as sysdba" "$APPLY_STOP_SQL") \
        || { bad "Redo apply was started since the check: stopping it was not shown. Nothing was changed."$'\n'"Answer r: it is checked and shown again."; return 1; }
      cp_exec "$istop" || { bad "Cannot stop redo apply: $(ora_errors "$RUN_OUT")"; return 1; }
      say "Redo apply stopped."
    fi
    rlog=$(rf_log)
    journal ROLLFWD "$STANDBY_UNIQUE" "RMAN roll forward from $PRIMARY_TNS (control file and datafiles of the standby refreshed)"
    # a mark for a roll forward that ends while no run watches (its result is then checked by the next one)
    install -d -m 700 "$STATE_DIR"; printf '%s|\n' "$rlog" > "$pf"
    say "${C_D}Running as $ORACLE_USER (a job):${C_N} $DB_HOME/bin/rman  ->  $(rf_rman_input '*****' | head -n 2 | tail -n 1)"
    run_long "RMAN roll forward" "$rlog" 'Starting|Finished|ORA-|RMAN-|restor|recover|media recovery' oracle "$DB_HOME/bin/rman" < <(rf_rman_input "$SYS_PW") || rc=$?
  fi
  if [[ $rc -ne 0 || ! -f "$rlog" ]] || grep -qE '^RMAN-0(3002|3009)|ERROR MESSAGE STACK' "$rlog"; then
    rm -f -- "$pf"
    bad "The roll forward did not finish (exit code $rc$([[ -f "$rlog" ]] && printf '; %s' "$(ora_errors "$(cat -- "$rlog")")"))"
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
  local cs=$CUR_STEP arc=0 mrc=0
  RF_FAILED=""
  rf_after || arc=1
  rm -f -- "$pf"
  # redo apply runs again in any case: a standby without its own standby redo logs still applies archived logs
  d_9_4_wrap || mrc=1
  CUR_STEP=$cs
  if [[ $arc -eq 1 ]]; then
    bad "The standby was rolled forward$([[ $mrc -eq 0 ]] && printf ' and redo apply runs'), but the clean-up after it did not finish (see above)."
    rf_redo_hint
  fi
  if [[ $mrc -eq 1 ]]; then bad "The roll forward worked, but redo apply did not start. Start it:  $SELF --only 9.4"; return 1; fi
  [[ $arc -eq 0 ]] || return 1
  RF_DONE=1
  DONE_MSG="The standby was rolled forward from the primary: its standby redo logs and RMAN settings are set again, and redo apply runs. Output: $rlog"$'\n'"The temp files now have the primary's names. Check them before you open this standby or switch over to it."
  [[ "${RF_FB:-}" == YES ]] && DONE_MSG+=$'\n'"Flashback database: turn it off and on again (its logs are not usable after the roll forward)."
  [[ "${RF_FB:-}" == "?" ]] && DONE_MSG+=$'\n'"Flashback database: its state could not be read. If it is on, turn it off and on again (its logs are not usable after the roll forward)."
  return 0
}
switchover_verify_cmd() { printf 'alter database switchover to %s verify;' "$STANDBY_UNIQUE"; }
phase10_footer() {
  # every check of phase 10 OK: the standby is ready as far as this script can tell. The readiness check of
  # Oracle itself runs on the primary and changes nothing there (12.1 and later): shown, never run
  local id
  for id in 10.1 10.2 10.3 10.4 10.5 10.6 10.8; do [[ "${STEP_RESULT[$id]:-}" == OK || ( "$id" == 10.5 && "${STEP_RESULT[$id]:-}" == NOT_ON_RELEASE ) ]] || return 0; done
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
  run_step 10.8 check "Archived logs: space and nightly clean-up" c_10_8
  phase10_footer
}
