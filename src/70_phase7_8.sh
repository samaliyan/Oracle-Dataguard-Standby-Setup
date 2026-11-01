#------------------------------------------------------------------------------
# PHASE 7  Start the standby instance (NOMOUNT) and test the logins
#------------------------------------------------------------------------------
STANDBY_BUILT=0
DUP_RAN=0
SC_INFO=""

dup_marker() { printf '%s/dbs/.dg_duplicate_done_%s' "$DB_HOME" "$STANDBY_SID"; }
pfile_path() { printf '%s/dbs/init%s.ora' "$DB_HOME" "$STANDBY_SID"; }
spfile_path() { printf '%s/dbs/spfile%s.ora' "$DB_HOME" "$STANDBY_SID"; }
set_marker() {
  # $1 duplicate = RMAN printed "Finished Duplicate Db"; seen = a mounted standby was compared with the primary
  # (no datafile header error). Both kinds mark a complete standby; later header errors are only reported.
  [[ "$MODE" == "run" ]] || return 0
  [[ "$1" == "seen" && -e "$(dup_marker)" ]] && return 0
  printf '%s\n' "$1" | write_as "$ORACLE_USER" "$(dup_marker)" 640 \
    || warn "Cannot write $(dup_marker)."$'\n'"While the standby is shut down, the script cannot tell that it is complete."
  return 0
}
marker_kind() { [[ -f "$(dup_marker)" ]] || return 0; local k; k=$(head -n 1 -- "$(dup_marker)" 2>/dev/null); printf '%s' "${k:-duplicate}"; }
built_offline() {
  # a standby that is shut down: the duplicate (or a comparison) was recorded and the spfile exists
  [[ -f "$(dup_marker)" && -f "$(spfile_path)" ]] && STANDBY_BUILT=1
  [[ $STANDBY_BUILT -eq 1 ]]
}

standby_complete() {
  # 0 complete, 1 incomplete, 2 cannot tell (SC_INFO says why).
  # The marker file is written when the duplicate finished. Without it, a mounted standby is
  # compared with the primary (datafiles and headers). A standby that is behind the primary
  # (fewer datafiles because apply is stopped) is still a standby: it only needs apply.
  # A marker "seen" (the standby was compared before and was complete) also counts: later header errors
  # (a new datafile on primary, an OFFLINE file) are reported, never treated as a failed copy.
  SC_INFO=""
  local_state
  if [[ "$LSTATE" != "MOUNTED" && "$LSTATE" != "OPEN" ]]; then
    [[ -f "$(dup_marker)" && -f "$(spfile_path)" ]] && return 0
    SC_INFO="the standby is not mounted and no finished copy is recorded"; return 1
  fi
  [[ "$(marker_kind)" == "duplicate" ]] && return 0
  if [[ "$(marker_kind)" == "seen" ]]; then
    if sql_local "select count(*) from v\$datafile_header where error is not null;" && [[ "$(first_line)" != "0" ]]; then
      warn "The standby was complete before, but now $(first_line) datafile header(s) show an error."$'\n'"Usually a datafile was added on the primary, or a file is OFFLINE."
      say "To see them:  select file#, error from v\$datafile_header where error is not null;"
      say "To build the standby again, see the help of step 8.2."
      say "Remove files only if step 2.15 proved that the storage is not shared."
    fi
    return 0
  fi
  sql_local "select (select count(*) from v\$datafile)||'|'||(select count(*) from v\$datafile_header where error is not null) from dual;" || { SC_INFO="cannot read the standby ($(ora_errors "$SQL_OUT"))"; return 2; }
  local sc se pc; IFS='|' read -r sc se <<< "$(first_line)"
  need_ssh || { SC_INFO="no ssh connection to the primary for the comparison"; return 2; }
  prim_sql "select count(*) from v\$datafile;" || { SC_INFO="cannot read the primary ($(ora_errors "$SQL_OUT"))"; return 2; }
  pc=$(first_line)
  num "$sc" && num "$se" && num "$pc" || { SC_INFO="unexpected answers ($sc, $se, $pc)"; return 2; }
  # complete: no datafile header has an error. Fewer datafiles than the primary means apply is behind
  # (new tablespaces on primary), not a failed copy (a failed copy shows the missing files as errors).
  if [[ "$se" == "0" && "$sc" -gt 0 ]]; then set_marker seen; return 0; fi
  SC_INFO="the standby has $sc datafiles ($se with errors), the primary has $pc"
  return 1
}

leftover_files() {
  # files of the standby database on this server (ASM: +DG/<STANDBY_UNIQUE>; folders: the primary's names here)
  local dg out="" f n
  for dg in $(asm_dgs); do
    grid_sw_ok || continue
    if sql_asm "select count(*) from v\$asm_alias a, v\$asm_diskgroup g where a.group_number=g.group_number and g.name=upper('$dg') and upper(a.name)=upper('$STANDBY_UNIQUE');" && [[ "$(first_line)" != "0" ]]; then
      out+="  +$dg/${STANDBY_UNIQUE^^}"$'\n'
    fi
  done
  if [[ -n "$(fs_dirs)" ]] && sql_or_cached_filenames; then
    n=0
    while IFS= read -r f; do [[ -n "$f" && -f "$f" ]] && { n=$((n + 1)); [[ $n -le 5 ]] && out+="  $f"$'\n'; }; done <<< "$FS_FILENAMES"
    [[ $n -gt 5 ]] && out+="  ... and $((n - 5)) more files"$'\n'
    local omfd; omfd=$(omf_dir_here)
    [[ -n "$omfd" && -d "$omfd/${STANDBY_UNIQUE^^}" ]] && out+="  $omfd/${STANDBY_UNIQUE^^}/"$'\n'
  fi
  printf '%s' "${out%$'\n'}"
}
orphan_leftovers() {
  # files of an earlier copy that a new copy would NOT overwrite (ASM folders of the standby, OMF folder)
  leftover_files | grep -E '^ *\+|/$' || true
}
spfile_from_failed_copy() {
  # 0 = the instance runs from the spfile that a duplicate which did not finish left behind
  [[ -f "$(spfile_path)" && "$(marker_kind)" != "duplicate" ]] || return 1
  sql_local "select nvl(value,'-') from v\$parameter where name='spfile';" || return 1
  [[ "$(first_line)" != "-" ]]
}
FS_FILENAMES=""
sql_or_cached_filenames() {
  # the datafile / tempfile / redo / control file names of the primary (read-only), cached in this run
  [[ -n "$FS_FILENAMES" ]] && return 0
  need_ssh || return 1
  prim_sql "select name from v\$datafile union all select name from v\$tempfile union all select member from v\$logfile union all select name from v\$controlfile;" || return 1
  FS_FILENAMES=$(grep '^/' <<< "$SQL_OUT")
  [[ -n "$FS_FILENAMES" ]]
}
omf_dir_here() {
  # the folder where OMF files of the standby are created (db_create_file_dest of primary, or the OMF folder)
  [[ "$CFD" == /* ]] && { printf '%s' "$CFD"; return 0; }
  sql_or_cached_filenames || return 0
  local f; f=$(grep -m1 '/o1_mf_' <<< "$FS_FILENAMES") || return 0
  [[ -n "$f" ]] && dirname "$(dirname "$(dirname "$f")")"
  return 0
}
STORAGE_SRC=""; STORAGE_KEY=""
storage_cache() {
  # runs the storage proof (2.15) in the calling shell, before plans are built inside $( ): its messages and
  # its wait stay on the screen, and a passed or failed proof is not repeated in this run
  # the proof belongs to the mounts it was made on: other storage mounted meanwhile is proven again
  local key="" d; for d in $(fs_dirs); do key+="$(findmnt -n -o SOURCE,UUID --target "$(existing_parent "$d")" 2>/dev/null | head -n 1);"; done
  [[ ( "$STORAGE_SRC" == 0 || "$STORAGE_SRC" == 1 ) && "$key" == "$STORAGE_KEY" ]] && return 0
  STORAGE_SRC=2; STORAGE_KEY=$key
  [[ "$MODE" == "run" && -n "$(fs_dirs)" ]] || return 0
  STORAGE_SRC=0; storage_not_shared || STORAGE_SRC=$?
  return 0
}
leftover_cleanup_plan() {
  # the clean-up commands for the files of a failed copy: host-name guarded, standby names only
  local dg p
  [[ -n "$(asm_dgs)" ]] && printf 'NEVER remove %s. Those are the files of the primary database.\n' "$(asm_dgs | sed "s#^#+#; s#\$#/${PRIMARY_UNIQUE^^}#" | paste -sd' ' -)"
  for dg in $(asm_dgs); do printf 'as %s:  [ "$(hostname -s)" = "%s" ] && ORACLE_HOME=%s ORACLE_SID=+ASM %s/bin/asmcmd rm -rf +%s/%s       (check the name twice)\n' "$GRID_USER" "$(hostname -s)" "$GRID_HOME" "$GRID_HOME" "$dg" "${STANDBY_UNIQUE^^}"; done
  if [[ -n "$(fs_dirs)" ]]; then
    local rmf="" src=${STORAGE_SRC:-2}
    if [[ $src -eq 0 ]]; then rmf=$(fs_cleanup_cmds | sed "s#^#[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] \&\& #" || true); fi
    if [[ -n "$rmf" ]]; then printf 'as %s, on this server only (the files have the same names as on the primary):\n%s\n' "$ORACLE_USER" "$rmf"
      local omfd; omfd=$(omf_dir_here); [[ -n "$omfd" ]] && printf '[ "$(hostname -s)" = "%s" ] && rm -rf %s/%s\n' "$(hostname -s)" "$omfd" "${STANDBY_UNIQUE^^}"
    elif [[ $src -eq 1 ]]; then printf 'Do NOT remove anything in %s. It is the storage of the primary.\n' "$STORAGE_SHARED"
    else printf 'Remove the files the failed copy left in %s (same names as on the primary).\nFirst make sure this is not the storage of the primary (step 2.15).\n' "$(fs_dirs | paste -sd' ' -)"; fi
  fi
  printf 'as %s:  [ "$(hostname -s)" = "%s" ] && rm -f %s %s\n' "$ORACLE_USER" "$(hostname -s)" "$(spfile_path)" "$(dup_marker)"
  return 0
}
DETECT_RC=0
detect_built() {
  # sets STANDBY_BUILT (used by phases 7-10); DETECT_RC 2 = cannot tell (SC_INFO)
  STANDBY_BUILT=0; DETECT_RC=0
  local_state
  if [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]]; then
    sql_local "select database_role from v\$database;" || { DETECT_RC=2; SC_INFO="cannot read the role ($(ora_errors "$SQL_OUT"))"; return 0; }
    [[ "$(first_line)" == "PHYSICAL STANDBY" ]] || return 0
  fi
  local rc=0; standby_complete || rc=$?
  [[ $rc -eq 0 ]] && STANDBY_BUILT=1
  DETECT_RC=$rc
  return 0
}

# ---- 7.1 ----
adump_dir() { printf '%s/admin/%s/adump' "$ORACLE_BASE" "$STANDBY_UNIQUE"; }
inst_dirs() {
  # folders the instance needs at startup (same paths as on primary)
  adump_dir; printf '\n'
  [[ -n "$DIAG_DEST" ]] && printf '%s\n' "$DIAG_DEST"
  return 0
}
I71_TODO=()
c_7_1() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  local d have="" I71=()
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ -d "$d" ]] && runuser -u "$ORACLE_USER" -- test -w "$d"; then have+="  $d"$'\n'; else I71+=("$d"); fi
  done < <(inst_dirs)
  if [[ ${#I71[@]} -eq 0 ]]; then NOW="The folders exist:"$'\n'"${have%$'\n'}"; return 0; fi
  I71_TODO=("${I71[@]}")
  NOW="Missing, or not writable by $ORACLE_USER:"$'\n'"$(printf '  %s\n' "${I71[@]}")"
  PLAN="Create them with owner $ORACLE_USER:$INSTALL_GROUP"$'\n'"The paths are the same as audit_file_dest and diagnostic_dest on the primary"
  return 1
}
d_7_1() { local d; for d in "${I71_TODO[@]}"; do make_dir "$d" "$ORACLE_USER" || return 1; done; }

# ---- 7.7 oratab ----
c_7_7() {
  local cur; cur=$(grep -E "^${STANDBY_SID}:" /etc/oratab 2>/dev/null | head -n 1)
  if [[ "$cur" == "$STANDBY_SID:$DB_HOME:"* ]]; then NOW="/etc/oratab has the line for $STANDBY_SID:"$'\n'"  $cur"; return 0; fi
  if [[ -n "$cur" ]]; then
    local yn; yn=$(cut -d: -f3 <<< "$cur"); [[ "$yn" =~ ^[YNyn]$ ]] || yn=N
    NOW="/etc/oratab has another home for $STANDBY_SID:"$'\n'"  $cur"
    PLAN="Change that line in /etc/oratab to (a backup is kept):"$'\n'"  $STANDBY_SID:$DB_HOME:$yn"
    return 1
  fi
  NOW="/etc/oratab has no line for $STANDBY_SID. oraenv and dbstart need it."
  PLAN="Add this line to /etc/oratab (a backup is kept):"$'\n'"  $STANDBY_SID:$DB_HOME:N"
  return 1
}
d_7_7() {
  local new=0; [[ -f /etc/oratab ]] || new=1
  backup_file /etc/oratab || return 1
  if [[ $new -eq 0 && ! -L /etc/oratab ]] && grep -qE "^${STANDBY_SID}:" /etc/oratab; then
    # only the line of this SID changes (its Y/N stays); written in place, so owner, mode and label stay
    local tmp; tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
    awk -F: -v sid="$STANDBY_SID" -v home="$DB_HOME" 'BEGIN { OFS = ":" } $1 == sid && !done { $2 = home; if ($3 !~ /^[YNyn]$/) $3 = "N"; done = 1 } { print }' /etc/oratab > "$tmp" || return 1
    cat -- "$tmp" > /etc/oratab || { [[ -f "/etc/oratab.bak_$RUN_ID" ]] && cat -- "/etc/oratab.bak_$RUN_ID" > /etc/oratab; bad "/etc/oratab could not be written. The old content was put back."; return 1; }
    rm -f -- "$tmp"
    journal_file_written /etc/oratab 1
    return 0
  fi
  printf '%s:%s:N' "$STANDBY_SID" "$DB_HOME" | append_as root /etc/oratab || return 1
  # a new file gets the usual owner; an existing one (Grid makes it) keeps its owner
  [[ $new -eq 1 ]] && { chown root:"$INSTALL_GROUP" /etc/oratab; chmod 664 /etc/oratab; }
  return 0
}

# ---- 7.2 ----
pfile_text() {
  printf "*.db_name='%s'\n*.db_unique_name='%s'\n" "$DB_NAME" "$STANDBY_UNIQUE"
  [[ "$PRIMARY_CDB" == "YES" ]] && printf '*.enable_pluggable_database=true\n'
  return 0
}
fs_cleanup_cmds() {
  # rm commands for the files a failed copy may have left in the folders (same names as on primary)
  local f
  prim_sql "select name from v\$datafile union all select name from v\$tempfile union all select member from v\$logfile union all select name from v\$controlfile;" || return 1
  while IFS= read -r f; do
    [[ "$f" =~ ^/[A-Za-z0-9_./-]+$ ]] || continue
    printf 'rm -f %s\n' "$f"
  done <<< "$SQL_OUT"
}
c_7_2() {
  L72_CLEAN=""
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  pwfile_ok || { NOW="Password file is not ready (step 6.1)"; return 2; }
  storage_cache
  local_state
  case "$LSTATE" in
    STARTED)
      # NOMOUNT, but from the spfile that a failed duplicate left (RMAN restarts the auxiliary with it):
      # the next duplicate needs an instance started from the text pfile
      if spfile_from_failed_copy; then
        NOW="Instance $STANDBY_SID is in NOMOUNT, but it runs from the spfile of an unfinished copy:"$'\n'"$(spfile_path)"
        cleanup_auto_plan spfile && return 1
        PLAN="# As $ORACLE_USER, on this server only:
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && ORACLE_HOME=$DB_HOME ORACLE_SID=$STANDBY_SID $DB_HOME/bin/sqlplus -S / as sysdba <<< 'shutdown abort'
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && mv $(spfile_path) $(spfile_path).failed_$RUN_ID
$(leftover_cleanup_plan | grep -v "rm -f $(spfile_path) ")
# Then answer r. The script starts the instance again from the pfile."
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"
        return 1
      fi
      # NOMOUNT from the pfile, but a copy that did not finish left files a new copy would not overwrite
      if [[ -f "$STATE_DIR/dup_attempt" && ! -f "$STATE_DIR/existing_files_ok" && "$(marker_kind)" != "duplicate" ]]; then
        local ol; ol=$(orphan_leftovers)
        if [[ -n "$ol" ]]; then
          NOW="Instance $STANDBY_SID is in NOMOUNT, but files of an unfinished copy are still here:"$'\n'"$ol"
          cleanup_auto_plan keep && return 1
          PLAN="# As $ORACLE_USER, on this server only:
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && ORACLE_HOME=$DB_HOME ORACLE_SID=$STANDBY_SID $DB_HOME/bin/sqlplus -S / as sysdba <<< 'shutdown abort'
$(leftover_cleanup_plan)
# Then answer r. The script starts the instance again from the pfile.
# If the files may stay, run this instead and answer r:
touch $STATE_DIR/existing_files_ok"
          KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER${GRID_HOME:+ / $GRID_USER}"
          return 1
        fi
      fi
      NOW="Instance $STANDBY_SID is in NOMOUNT"; return 0 ;;
    MOUNTED|OPEN)
      sql_local "select database_role from v\$database;" || { NOW="Cannot read the database role ($(ora_errors "$SQL_OUT"))"; return 2; }
      local role; role=$(first_line)
      if [[ "$role" != "PHYSICAL STANDBY" ]]; then
        # check mode only reports (the other phases are still shown); a real run stops here
        [[ "$MODE" == "check" ]] && { NOW="Database $STANDBY_SID on this server is $LSTATE with role '$role'. It is not a standby: nothing here may touch it."; return 2; }
        fatal "Database $STANDBY_SID on this server is $LSTATE with role '$role'. It is not a standby, so the script stops."
      fi
      local sc=0; standby_complete || sc=$?
      if [[ $sc -eq 0 ]]; then STANDBY_BUILT=1; NOW="The standby database already exists ($LSTATE, PHYSICAL STANDBY). No copy is needed."; return 0; fi
      if [[ $sc -eq 2 ]]; then NOW="Cannot compare the standby with the primary: $SC_INFO"; return 2; fi
      NOW="A standby control file exists, but the database is incomplete, probably from a failed copy:"$'\n'"$SC_INFO"
      cleanup_auto_plan mounted && return 1
      KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER${GRID_HOME:+ / $GRID_USER}"
      PLAN="# As $ORACLE_USER, on this server only:"$'\n'"[ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && ORACLE_HOME=$DB_HOME ORACLE_SID=$STANDBY_SID $DB_HOME/bin/sqlplus -S / as sysdba <<< 'shutdown abort'"$'\n'"$(leftover_cleanup_plan)"
      PLAN+=$'\n'"# Then answer r. The script starts the instance again from the pfile."
      return 1 ;;
    IDLE)
      if [[ -f "$(dup_marker)" && -f "$(spfile_path)" ]]; then
        STANDBY_BUILT=1
        NOW="The standby database exists (the copy finished). Step 9.2 starts it."
        return 0
      fi
      # files of a copy that was interrupted (reboot, kill): they are named, never removed by the script
      local lo; lo=$(leftover_files)
      if [[ -n "$lo" && ! -f "$STATE_DIR/existing_files_ok" ]]; then
        NOW="Instance $STANDBY_SID is not started, and files already exist where the standby database will be written:"$'\n'"$lo"
        cleanup_auto_plan keep && return 1
        PLAN="$(leftover_cleanup_plan)
# RMAN overwrites files with the same names. Files with OMF names would stay unused and take space.
# Then answer r.
# If you are sure the files may be overwritten or may stay, run this instead and answer r:
touch $STATE_DIR/existing_files_ok"
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER${GRID_HOME:+ / $GRID_USER}"
        return 1
      fi
      NOW="Instance $STANDBY_SID is not started"
      PLAN="Write this pfile:
  $(pfile_path)
with these lines:
$(pfile_text | sed 's/^/  /')
Start the instance as $ORACLE_USER:
  startup nomount pfile='$(pfile_path)'"
      return 1 ;;
    *) NOW="Cannot read the state of the instance on this server ($(ora_errors "$SQL_OUT"))"; return 2 ;;
  esac
}
# The clean-up of a copy that did not finish, done by the script after you typed DELETE.
# Only the standby's own names are removed: +DG/<standby unique name> in ASM, and in the folders the
# primary's file names only when step 2.15 proved that the folders are storage of this server.
L72_CLEAN=""; L72_FS=0
cleanup_auto_plan() {
  # $1 spfile | keep | mounted. Sets the plan for d_7_2 and returns 0, or 1 when the script must not do it
  # itself (folders whose storage is not proven: then the commands are shown, as before)
  local fs=0 dg lines=""
  [[ -n "$STANDBY_UNIQUE" && "${STANDBY_UNIQUE^^}" != "${PRIMARY_UNIQUE^^}" && "${STANDBY_UNIQUE^^}" != "${DB_NAME^^}" ]] || return 1
  # only the leftovers of a copy THIS script started and that did not finish (else the files may be a complete
  # standby, or an older database with the same name: then the commands are shown, nothing is done by the script)
  [[ -f "$STATE_DIR/dup_attempt" && ! -f "$(dup_marker)" ]] || return 1
  # files in folders are never deleted by the script (a shared disk can look local): the commands are shown
  [[ -z "$(fs_dirs)" ]] || return 1
  L72_CLEAN=$1; L72_FS=$fs
  local_state
  [[ "$LSTATE" != "IDLE" ]] && lines+="  stop the instance $STANDBY_SID (shutdown abort)"$'\n'
  [[ -f "$(spfile_path)" ]] && lines+="  rename its spfile to $(basename "$(spfile_path)").failed_$RUN_ID"$'\n'
  for dg in $(asm_dgs); do lines+="  delete +$dg/${STANDBY_UNIQUE^^} in ASM"$'\n'; done
  lines+="  then start the instance again from the pfile"
  PLAN="Clean up this server (after you type DELETE):"$'\n'"$lines"
  [[ -n "$(asm_dgs)" ]] && PLAN+=$'\n'"Never touched: $(asm_dgs | sed "s#^#+#; s#\$#/${PRIMARY_UNIQUE^^}#" | paste -sd' ' -) (the primary's files)"
  KIND_NOW=ask
  return 0
}
leftover_cleanup_do() {
  local dg f n=0
  # never on the primary's own name, whatever the caller checked (this deletes files and stops the instance)
  [[ -n "$STANDBY_UNIQUE" && "${STANDBY_UNIQUE^^}" != "${PRIMARY_UNIQUE^^}" ]] || { bad "Safety stop: STANDBY_UNIQUE equals the primary's unique name. Nothing is deleted."; return 1; }
  local_state
  if [[ "$LSTATE" != "IDLE" ]]; then
    sql_local "shutdown abort" || { bad "shutdown abort failed: $(ora_errors "$SQL_OUT")"; return 1; }
    say "Instance $STANDBY_SID stopped."
  fi
  if [[ -f "$(spfile_path)" ]]; then
    runuser -u "$ORACLE_USER" -- mv -f -- "$(spfile_path)" "$(spfile_path).failed_$RUN_ID" || return 1
    journal RENAME "$(spfile_path)" "to=$(spfile_path).failed_$RUN_ID"
    say "Renamed $(spfile_path) to .failed_$RUN_ID"
  fi
  rm -f -- "$(dup_marker)"
  [[ -n "$STANDBY_UNIQUE" ]] || { bad "STANDBY_UNIQUE is empty. Nothing was deleted."; return 1; }
  for dg in $(asm_dgs); do
    grid_sw_ok || { bad "Grid is not installed here. Nothing was deleted in ASM."; return 1; }
    # the folder of the standby at the top of the disk group (parent_index = the disk group's root)
    sql_asm "select count(*) from v\$asm_alias a, v\$asm_diskgroup g where a.group_number=g.group_number and g.name=upper('$dg') and upper(a.name)=upper('$STANDBY_UNIQUE') and a.parent_index=a.group_number*16777216;" \
      || { bad "Cannot read ASM ($(ora_errors "$SQL_OUT")). Nothing was deleted in +$dg."; return 1; }
    [[ "$(first_line)" != "0" ]] || continue
    run_logged "asmcmd rm" as_grid "$GRID_HOME/bin/asmcmd" rm -rf "+$dg/${STANDBY_UNIQUE^^}" || { bad "Could not delete +$dg/${STANDBY_UNIQUE^^}: ${RUN_OUT%%$'\n'*}"; return 1; }
    journal DELETED "+$dg/${STANDBY_UNIQUE^^}" "cannot be undone: files of the unfinished copy, deleted after you typed DELETE"
    say "Deleted +$dg/${STANDBY_UNIQUE^^}"
  done
  _log CHANGE "clean-up of the unfinished copy done on $(hostname -s)"
  return 0
}
d_7_2() {
  if [[ -n "$L72_CLEAN" ]]; then
    local opts="[d] Delete them   [s] Skip   [h] Help   [q] Quit" allowed="dshq"
    [[ "$L72_CLEAN" == keep && -f "$STATE_DIR/dup_attempt" ]] && { opts="[d] Delete them   [k] Keep them (RMAN overwrites files with the same names)   [s] Skip   [h] Help   [q] Quit"; allowed="dkshq"; }
    while true; do
      ask_choice "$opts" "$allowed"
      case "$ANSWER" in
        h) show_help 7.2 || true ;;
        q) user_stop "Stopped by you" ;;
        s) L72_CLEAN=""; return 3 ;;
        k) install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/existing_files_ok"; say "The files stay. RMAN overwrites files with the same names."; break ;;
        d) confirm_word "The files of the unfinished copy on THIS server ($(hostname -s)) will be deleted." "DELETE" || { L72_CLEAN=""; return 3; }
           leftover_cleanup_do || { L72_CLEAN=""; return 1; }
           break ;;
      esac
    done
    L72_CLEAN=""
    local_state
    [[ "$LSTATE" == "IDLE" ]] || return 0          # NOMOUNT from the pfile already: nothing more to start
  fi
  local p; p=$(pfile_path)
  if [[ -f "$p" && "$(cat "$p")" != "$(pfile_text)" ]]; then backup_file "$p" "$ORACLE_USER" || return 1; fi
  [[ -f "$p" && "$(cat "$p")" == "$(pfile_text)" ]] || { pfile_text | write_as "$ORACLE_USER" "$p" 644 || return 1; }
  pfile_text | log_block "pfile $p"
  # journaled first: a run that stops during the startup still lists the instance for --undo
  journal INSTANCE "$STANDBY_SID" "started NOMOUNT with $p"
  sql_local_long "startup nomount pfile='$p'" || { bad "Startup nomount failed ($(ora_errors "$SQL_OUT"))"; printf '%s\n' "$SQL_OUT" | tail -n 5 | hint; return 1; }
}

# ---- 7.3 - 7.6 golden connections ----
golden_text() {
  case "$1" in
    *ORA-01017*)
      if [[ "$2" == "standby-tns" ]]; then
        printf 'Local login works, but login through the listener fails. Check:\n- the static entry: its ORACLE_HOME must be %s (step 5.1)\n- the password file: it must be a copy of the primary file (step 6.1)\n' "$DB_HOME"
      elif [[ "$2" == "local" ]]; then
        printf 'OS login failed: %s must be in the OSDBA group of this home.\nTo check:  id %s ; grep OSDBA %s/rdbms/lib/config.c\n' "$ORACLE_USER" "$ORACLE_USER" "$DB_HOME"
      else
        printf 'Wrong sys password, or the password files differ. To copy the file again:\n1. On the primary, as %s:  rm -f %s\n2. On this server:  mv %s %s.old\n3. Run:  %s --from 6.1\n' "$GRID_USER" "$(pw_tmp_remote)" "$(pw_dest)" "$(pw_dest)" "$SELF"
      fi ;;
    *ORA-12528*) printf 'The listener blocks the connection (phase 5).\n(UR = A) is missing in tnsnames.ora, or there is no static entry.\n' ;;
    *ORA-12514*) printf 'SERVICE_NAME in tnsnames.ora does not match GLOBAL_DBNAME of the static entry (phase 5).\n' ;;
    *ORA-12154*|*TNS-03505*) printf 'The alias is missing in tnsnames.ora (steps 5.3 and 5.4; on the primary, step 4.9).\n' ;;
    *ORA-12541*|*TNS-12541*) printf 'No listener at that host and port (phase 5), or the firewall blocks it (step 2.9).\n' ;;
    *ORA-12170*|*ORA-12535*) printf 'Timeout: a firewall or the network between the servers (steps 2.8 and 2.9).\n' ;;
    *ORA-01031*) printf 'Privilege problem: %s is not in the dba group, or the password file mode is wrong.\n' "$ORACLE_USER" ;;
    *ORA-01034*) printf 'The instance is not started (step 7.2).\n' ;;
    *) printf 'See the log for the full output.\n' ;;
  esac
}
need_sys() { [[ -n "$SYS_PW" ]] && return 0; NOW="The sys password is not known yet (step 1.5)"; NEED_SYS=1; return 1; }
c_7_3() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  if sql_local "select status from v\$instance;"; then NOW="Login works. Instance status: $(first_line)"; return 0; fi
  if grep -qE 'ORA-01034|idle instance' <<< "$SQL_OUT"; then
    built_offline && { logins_defer; NOW="Not tested now: the standby exists but is not started. The logins are tested after step 9.2 starts it."; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  NOW="Local login failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" local); return 1
}
c_7_4() {
  need_sys || return 2
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  local_state
  if [[ "$LSTATE" == "IDLE" ]]; then
    built_offline && { logins_defer; NOW="Not tested now: the standby exists and is not started (tested after step 9.2)"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  if sql_standby_tns "select instance_name||' '||status from v\$instance;"; then NOW="Login works: sys@$STANDBY_TNS reaches $(first_line)"; return 0; fi
  if grep -q 'ORA-01034' <<< "$SQL_OUT"; then
    built_offline && { logins_defer; NOW="Not tested now: the standby exists and is not started (tested after step 9.2)"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  NOW="Login sys@$STANDBY_TNS failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" standby-tns); return 1
}
c_7_5() {
  need_sys || return 2
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  tns_alias_present "$PRIMARY_TNS" || { NOW="Alias $PRIMARY_TNS is not in tnsnames.ora on this server yet (step 5.3)"; return 2; }
  if sql_primary_tns "select db_unique_name||' '||database_role from v\$database;"; then NOW="Login works: sys@$PRIMARY_TNS reaches $(first_line)"; return 0; fi
  NOW="Login sys@$PRIMARY_TNS failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" primary); return 1
}
c_7_6() {
  need_sys || return 2
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  # the login goes to the standby instance through its listener: before 7.2 there is nothing to reach
  local_state
  if [[ "$LSTATE" == "IDLE" ]]; then
    built_offline && { logins_defer; NOW="Not tested now: the standby exists and is not started (tested after step 9.2)"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  need_ssh || return 2
  if prim_sql_as_sys "$STANDBY_TNS" "select instance_name||' '||status from v\$instance;"; then NOW="Login from the primary works: sys@$STANDBY_TNS reaches $(first_line)"; return 0; fi
  if grep -q 'ORA-01034' <<< "$SQL_OUT"; then
    built_offline && { logins_defer; NOW="Not tested now: the standby exists and is not started (tested after step 9.2)"; return 0; }
    NOW="The instance is not started (step 7.2)"; return 2
  fi
  NOW="Login from the primary to sys@$STANDBY_TNS failed ($(ora_errors "$SQL_OUT"))"; PLAN=$(golden_text "$SQL_OUT" standby-tns); return 1
}

LOGINS_DEFERRED=0
logins_flag() { printf '%s/logins_deferred' "$STATE_DIR"; }
logins_defer() {
  # phase 7 could not test the logins (the built standby was down): remembered, also for a later run
  LOGINS_DEFERRED=1
  [[ "$MODE" == "run" && -n "$STATE_DIR" ]] && { install -d -m 700 "$STATE_DIR"; : > "$(logins_flag)"; }
  return 0
}
logins_after_start() {
  # the logins of 7.3, 7.4 and 7.6 that could not be tested in phase 7 (the standby was down) are tested now.
  # 0 = all work, or nothing was deferred, or a test cannot run now (a warning); 1 = one fails (NOW and PLAN say why)
  [[ $LOGINS_DEFERRED -eq 1 || -f "$(logins_flag)" ]] || return 0
  need_ssh || { warn "The logins of steps 7.3, 7.4 and 7.6 are tested in a later run (no connection to the primary now)."; return 0; }
  local f rc keep_now=$NOW sid
  for f in c_7_3 c_7_4 c_7_6; do
    NOW=""; PLAN=""; rc=0; "$f" >/dev/null || rc=$?
    sid=${f#c_}; sid=${sid/_/.}
    if [[ $rc -eq 2 ]]; then warn "Step $sid cannot be tested now (${NOW%%$'\n'*}). It is tested in a later run."; NOW=$keep_now; return 0; fi
    if [[ $rc -ne 0 ]]; then
      local why=$PLAN
      NOW="The standby is running, but the login of step $sid fails: $NOW"
      # the explanation is text, not commands: shown as comments
      PLAN=$(printf '%s\n' "${why:-See:  $SELF --help-step $sid}" | sed 's/^/-- /')$'\n'"-- Then answer r."
      return 1
    fi
  done
  LOGINS_DEFERRED=0; rm -f -- "$(logins_flag)"
  NOW="$keep_now"$'\n'"The logins of steps 7.3, 7.4 and 7.6 work now."
  return 0
}
phase_7() {
  phase_header 7 "Start the empty instance (NOMOUNT)"
  run_step 7.1 auto  "Folders for the instance (audit, diagnostics)" c_7_1 d_7_1
  run_step 7.2 auto  "Instance $STANDBY_SID in NOMOUNT" c_7_2 d_7_2
  run_step 7.3 check "Login 1 of 4: sqlplus / as sysdba on this server" c_7_3
  run_step 7.4 check "Login 2 of 4: sys@$STANDBY_TNS through the listener" c_7_4
  run_step 7.5 check "Login 3 of 4: sys@$PRIMARY_TNS from this server" c_7_5
  run_step 7.6 check "Login 4 of 4: sys@$STANDBY_TNS from the primary" c_7_6
  run_step 7.7 auto  "/etc/oratab entry for $STANDBY_SID" c_7_7 d_7_7
}

#------------------------------------------------------------------------------
# PHASE 8  RMAN active duplicate
#------------------------------------------------------------------------------
DUP_EXTRA=""; PRE_OK=0; PRE_INFO=""; NEWNAMES=""

CF_LIST=""
srl_plan_space() {
  # Standby logs that step 9.3 still has to create (missing or smaller than the online logs), which are not in the
  # sizes read from the primary: SRL_MB, and SRL_LOC = where 9.3 puts them (the same rule as srl_statements:
  # the OMF destination, else the first online-log folder outside the recovery area). Multiplexed OMF logs count twice.
  SRL_MB=0; SRL_LOC=""
  prim_sql "select (select count(*)+count(distinct thread#) from v\$log)||'|'||(select count(*) from v\$standby_log where bytes>=(select max(bytes) from v\$log))||'|'||(select max(bytes) from v\$log)||'|'||(select count(*) from v\$parameter where name like 'db_create_online_log_dest_%' and value is not null)||'|'||(select nvl(max(value),'-') from v\$parameter where name in ('db_create_file_dest','db_create_online_log_dest_1') and value is not null)||'|'||nvl((select min(substr(member,1,instr(member,'/',-1)-1)) keep (dense_rank first order by group#, member) from v\$logfile where type='ONLINE' and upper(member) not like (select upper(nvl(max(value),'#none#'))||'%' from v\$parameter where name='db_recovery_file_dest')),(select max(substr(member,1,instr(member,'/',-1)-1)) from v\$logfile where type='ONLINE')) from dual;" || return 0
  local need have b copies omf dir; IFS='|' read -r need have b copies omf dir <<< "$(first_line)"
  num "$need" && num "$have" && num "$b" || return 0
  num "$copies" && [[ $copies -ge 1 ]] || copies=1
  [[ $need -gt $have ]] || return 0
  SRL_MB=$(( (need - have) * ((b + 1048575) / 1048576) ))
  if [[ -n "$omf" && "$omf" != "-" ]]; then SRL_LOC=$omf; SRL_MB=$((SRL_MB * copies)); else SRL_LOC=$dir; fi
}
space_check() {
  # appends to PRE_INFO; sets PRE_FIX and returns 1 if there is not enough space for the database files
  local dg need free l d mnt
  srl_plan_space
  local srl_dg=""; [[ "$SRL_LOC" == +* ]] && { srl_dg=${SRL_LOC#+}; srl_dg=${srl_dg%%/*}; srl_dg=${srl_dg^^}; }
  for dg in $(asm_dgs); do
    need=0
    while IFS= read -r l; do
      d=${l%%:*}; d=${d#+}; d=${d%%/*}; [[ "${d^^}" == "$dg" ]] && need=$((need + ${l##*:}))
    done < <(loc_list | grep '^+')
    [[ "$dg" == "$srl_dg" && $SRL_MB -gt 0 ]] && { need=$((need + SRL_MB)); PRE_INFO+="+$dg also gets the standby logs of step 9.3: $(human_mb "$SRL_MB")"$'\n'; }
    [[ $need -eq 0 ]] && continue
    need=$(( need * 110 / 100 ))
    free=0; sql_asm "select free_mb from v\$asm_diskgroup where name=upper('$dg');" && free=$(first_line)
    num "$free" || free=0
    # (files of an earlier copy in ASM are NOT counted as free: a new copy creates new OMF files next to them)
    if [[ $free -lt $need ]]; then
      PRE_FIX="+$dg has $(human_mb "$free") free, but needs about $(human_mb "$need") (the database files plus 10%)."
      [[ -n "$(orphan_leftovers | grep -F "+$dg/")" ]] && PRE_FIX+=$'\n'"Files of an earlier copy are in +$dg/${STANDBY_UNIQUE^^}. Removing them frees space (step 7.2 shows how: $SELF --from 7.2)."
      PRE_FIX+=$'\n'"Or add a disk to +$dg: run $SELF --from 2.13, then as $GRID_USER:"$'\n'"  export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM ; \$ORACLE_HOME/bin/sqlplus / as sysasm"$'\n'"  alter diskgroup $dg add disk '$(asm_disk_dir)/<label>';"
      return 1
    fi
    PRE_INFO+="+$dg: $(human_mb "$free") free, about $(human_mb "$need") needed (database files + 10%)"$'\n'
  done
  declare -A need_by_mnt=() free_by_mnt=() there_by_mnt=()
  while IFS= read -r l; do
    d=${l%%:*}
    [[ -d "$d" ]] || { PRE_FIX="The folder $d does not exist (step 2.14)"; return 1; }
    mnt=$(mnt_of "$d"); [[ -n "$mnt" ]] || { PRE_FIX="Cannot read the free space of $d (df)"; return 1; }
    need_by_mnt[$mnt]=$(( ${need_by_mnt[$mnt]:-0} + ${l##*:} ))
    free_by_mnt[$mnt]=$(free_mb_of "$d")
  done < <(loc_list | grep '^/')
  if [[ "$SRL_LOC" == /* && $SRL_MB -gt 0 ]]; then
    mnt=$(mnt_of "$SRL_LOC")
    if [[ -n "$mnt" ]]; then
      need_by_mnt[$mnt]=$(( ${need_by_mnt[$mnt]:-0} + SRL_MB )); [[ -n "${free_by_mnt[$mnt]:-}" ]] || free_by_mnt[$mnt]=$(free_mb_of "$SRL_LOC")
      PRE_INFO+="$mnt also gets the standby logs of step 9.3: $(human_mb "$SRL_MB")"$'\n'
    fi
  fi
  # files at exactly the target paths (an earlier copy) are overwritten by RMAN: their space counts as free (once per file)
  if [[ ${#need_by_mnt[@]} -gt 0 ]] && sql_or_cached_filenames; then
    local f sz
    while IFS= read -r f; do
      [[ -n "$f" && -f "$f" ]] || continue
      mnt=$(mnt_of "$(dirname "$f")"); [[ -n "${need_by_mnt[$mnt]:-}" ]] || continue
      sz=$(stat -c '%s' -- "$f" 2>/dev/null); num "$sz" || continue
      there_by_mnt[$mnt]=$(( ${there_by_mnt[$mnt]:-0} + sz / 1048576 ))
    done <<< "$FS_FILENAMES"
    for mnt in "${!there_by_mnt[@]}"; do free_by_mnt[$mnt]=$(( ${free_by_mnt[$mnt]:-0} + ${there_by_mnt[$mnt]} )); done
  fi
  for mnt in "${!need_by_mnt[@]}"; do
    need=$(( ${need_by_mnt[$mnt]} * 110 / 100 )); free=${free_by_mnt[$mnt]}; num "$free" || free=0
    [[ $free -ge $need ]] || { PRE_FIX="File system $mnt has $(human_mb "$free") free, but needs about $(human_mb "$need") (the database files plus 10%)."; return 1; }
    PRE_INFO+="File system $mnt: $(human_mb "$free") free, about $(human_mb "$need") needed"$'\n'
  done
  return 0
}

dup_prechecks() {
  # read-only. Sets PRE_OK, PRE_INFO (lines), PRE_FIX, DUP_EXTRA, CF_LIST, DEST_N, NEWNAMES.
  PRE_OK=0; PRE_INFO=""; PRE_FIX=""; DUP_EXTRA=""; CF_LIST=""; NEWNAMES=""
  local_state
  [[ "$LSTATE" == "STARTED" ]] || { PRE_FIX="The standby instance must be in NOMOUNT, but it is $LSTATE (step 7.2)"; return 1; }
  if spfile_from_failed_copy; then PRE_FIX="The instance runs from the spfile of an unfinished copy. Clean up first (step 7.2)"; return 1; fi
  # the disk group of the logs must fit the block size of the primary's redo (else ORA-01378 after the copy, at 9.3)
  if use_grid && grid_sw_ok; then
    # every disk group that gets log files: the data disk group (or db_create_file_dest), the disk groups of
    # the primary's online log members, and db_create_online_log_dest_1..5 (the standby uses the same names)
    # not proven = not passed: an unread block size, an unread list of disk groups, an unread sector size
    [[ ${PRIMARY_REDO_BS_KNOWN:-0} -eq 1 ]] || { PRE_FIX="The redo block size of the primary could not be read, so the disk groups for the logs cannot be checked"; return 1; }
    local ldg ldgs="$DATA_DG"; [[ "$CFD" == +* ]] && { ldg=$(norm_loc "$CFD"); ldgs=${ldg#+}; }
    if ! prim_sql "select distinct upper(substr(v, 2, decode(instr(v, '/'), 0, length(v), instr(v, '/') - 2))) from (select member v from v\$logfile where member like '+%' union all select value from v\$parameter where name like 'db_create_online_log_dest_%' and value like '+%');"; then
      PRE_FIX="Cannot read on the primary which disk groups hold its logs"; return 1
    fi
    ldgs+=" $(grep -E '^[A-Z0-9_$#]+$' <<< "$SQL_OUT" | tr '\n' ' ')"
    local ss seen=" "
    for ldg in $ldgs; do
      ldg=${ldg^^}; [[ "$seen" == *" $ldg "* ]] && continue; seen+="$ldg "
      if ! sql_asm "select sector_size from v\$asm_diskgroup where name=upper('$ldg');" || ! num "$(first_line)"; then
        PRE_FIX="Cannot read the sector size of +$ldg here (log files go there). Is the disk group mounted (step 3.5)?"; return 1
      fi
      ss=$(first_line)
      [[ $ss -gt 0 ]] || { PRE_FIX="+$ldg reports a sector size of 0 (not mounted?). Log files go there. Mount it first (step 3.5)."; return 1; }
      # 12.2+: a 512e disk group (sector_size 4096, logical_sector_size 512) takes 512-byte redo
      local lss="$ss" lnote=""
      if sql_asm "select logical_sector_size from v\$asm_diskgroup where name=upper('$ldg');" && num "$(first_line)" && [[ "$(first_line)" -gt 0 ]]; then lss=$(first_line)
      else lnote=" (its logical sector size cannot be read in this ASM version, so the physical one is used)"; fi
      # redo blocks must not be smaller than the (logical) sector, and 4K redo needs a 4K disk group
      if [[ $PRIMARY_REDO_BS -lt $lss ]] || [[ $PRIMARY_REDO_BS -eq 4096 && $ss -ne 4096 ]]; then
        PRE_FIX="+$ldg has a sector size of $ss bytes$lnote, but the primary's redo logs use ${PRIMARY_REDO_BS}-byte blocks."$'\n'"Log files go there, so after the copy they could not be created (ORA-01378)."$'\n'"First create a disk group with sector_size ${PRIMARY_REDO_BS} for the logs. Help: --help-step 3.5"
        return 1
      fi
      PRE_INFO+="+$ldg: sector size $ss bytes fits the redo block size ${PRIMARY_REDO_BS:-512}"$'\n'
    done
  fi
  # the copy takes the spfile of the primary (duplicate ... spfile): a primary started from a pfile fails there
  prim_sql "select nvl(value,'-') from v\$parameter where name='spfile';" && [[ "$(first_line)" == "-" ]] && { PRE_FIX="The primary runs from a text pfile, but the copy needs its spfile (step 4.1)"; return 1; }
  if [[ -f "$STATE_DIR/dup_attempt" && ! -f "$STATE_DIR/existing_files_ok" && "$(marker_kind)" != "duplicate" && -n "$(orphan_leftovers)" ]]; then
    PRE_FIX="Files of an unfinished copy are still on this server. Clean them up first (step 7.2)"; return 1
  fi
  PRE_INFO+="Standby instance $STANDBY_SID is in NOMOUNT"$'\n'
  if tde_autologin_missing; then PRE_FIX="The TDE keystore of the standby has no auto-login file (cwallet.sso)."$'\n'"The copy and redo apply would stop with ORA-28365 (step 6.3)"; return 1; fi
  # the folders of this server must not be the storage of the primary (NOFILENAMECHECK would overwrite it)
  if [[ -n "$(fs_dirs)" && "$MODE" == "run" ]]; then
    storage_cache; local src=$STORAGE_SRC
    [[ $src -eq 1 ]] && { PRE_FIX="$STORAGE_SHARED is the same storage that the primary uses (step 2.15)."$'\n'"The copy would overwrite the database files of the primary. Do NOT continue."; return 1; }
    [[ $src -eq 2 ]] && { PRE_FIX="$STORAGE_INFO (step 2.15)"; return 1; }
    PRE_INFO+="The database folders are on storage of this server only"$'\n'
  fi
  space_check || return 1
  # primary prerequisites (phase 4) again: a skipped step must not make RMAN fail late
  prim_sql "select log_mode||'|'||force_logging from v\$database;" || { PRE_FIX="Cannot read the log mode of the primary"; return 1; }
  local lm fl; IFS='|' read -r lm fl <<< "$(first_line)"
  [[ "$lm" == "ARCHIVELOG" ]] || { PRE_FIX="The primary is in $lm mode. It must be in ARCHIVELOG mode (step 4.1)"; return 1; }
  [[ "$fl" == "YES" ]] || warn "FORCE LOGGING is off on the primary (step 4.1)."$'\n'"NOLOGGING operations would not reach the standby."
  p_param remote_login_passwordfile || { PRE_FIX="Cannot read remote_login_passwordfile on the primary"; return 1; }
  [[ "$PVAL" == "EXCLUSIVE" || "$PVAL" == "SHARED" ]] || { PRE_FIX="remote_login_passwordfile on the primary is $PVAL. The primary must be restarted after the change (step 4.7)"; return 1; }
  # role separation: the oracle binary must be able to open the ASM disks
  if use_grid && ! single_owner; then
    local og want l1; og=$(stat -c '%G' "$DB_HOME/bin/oracle" 2>/dev/null)
    # the group of a real ASM disk is what counts
    l1=$(asm_labels "$DATA_DG" | head -n 1); want=""
    [[ -n "$l1" ]] && want=$(stat -L -c '%G' "$(asm_disk_dir)/$l1" 2>/dev/null)
    [[ -n "$want" && "$want" != "root" ]] || want=$(asm_owner_group)
    if [[ "$og" != "$want" ]]; then
      PRE_FIX="$DB_HOME/bin/oracle has group $og. It must be $want, the group of the ASM disks, or it cannot open them (ORA-15025)."$'\n'"As root:  $GRID_HOME/bin/setasmgidwrap o=$DB_HOME/bin/oracle"
      # the script can fix this itself (step 8.1 offers it); the old group is kept for the undo
      [[ -x "$GRID_HOME/bin/setasmgidwrap" ]] && { PRE_ASMGID_OLD=$og; PRE_ASMGID_WANT=$want; }
      return 1
    fi
  fi
  # RMAN uses the TNS aliases: prove they reach the right databases
  local pu pr pn ph ti th ts ls; ls=$(hostname -s 2>/dev/null || hostname)
  sql_primary_tns "select d.db_unique_name||'|'||d.database_role||'|'||d.name||'|'||i.host_name from v\$database d, v\$instance i;" || { PRE_FIX="Cannot reach the primary through $PRIMARY_TNS: $(ora_errors "$SQL_OUT") (step 7.5)"; return 1; }
  IFS='|' read -r pu pr pn ph <<< "$(first_line)"
  local phs=${ph%%.*}
  if [[ "${pu^^}" != "${PRIMARY_UNIQUE^^}" || "$pr" != "PRIMARY" || "${pn^^}" != "${DB_NAME^^}" || "${phs,,}" == "${ls,,}" ]]; then
    PRE_FIX="Alias $PRIMARY_TNS does not reach the primary. It reaches: $pu, $pr, $pn, host $ph"; return 1
  fi
  PRE_INFO+="$PRIMARY_TNS reaches $pu (PRIMARY) on $ph"$'\n'
  sql_standby_tns "select instance_name||'|'||host_name||'|'||status from v\$instance;" || { PRE_FIX="Cannot reach the standby through $STANDBY_TNS: $(ora_errors "$SQL_OUT") (step 7.4)"; return 1; }
  IFS='|' read -r ti th ts <<< "$(first_line)"
  local ths=${th%%.*}      # host names compared without the domain and without case
  if [[ "${ti^^}" != "${STANDBY_SID^^}" || "${ths,,}" != "${ls,,}" || "$ts" != "STARTED" ]]; then
    PRE_FIX="Alias $STANDBY_TNS does not reach the NOMOUNT instance on this server. It reaches: $ti, host $th, $ts"; return 1
  fi
  PRE_INFO+="$STANDBY_TNS reaches $ti (NOMOUNT) on this server"$'\n'
  # and the other way: redo goes from the primary to this listener after the copy (a firewall shows only here)
  prim_sql_as_sys "$STANDBY_TNS" "select instance_name||' '||status from v\$instance;" \
    || { PRE_FIX="The primary cannot reach the standby through $STANDBY_TNS: $(ora_errors "$SQL_OUT") (step 7.6)"$'\n'"$(golden_text "$SQL_OUT" standby-tns)"; return 1; }
  PRE_INFO+="The primary reaches $STANDBY_TNS too"$'\n'
  # memory: the spfile of primary is copied; the standby must be able to start with it (same rules as step 2.16)
  local mrc=0 rfs; mem_probe || mrc=$?
  [[ $mrc -eq 2 ]] && { PRE_FIX="Cannot read the memory parameters of the primary"; return 1; }
  if [[ $mrc -eq 1 ]]; then
    PRE_FIX="$MEM_FAIL"$'\n'"$MEM_INFO"$'\n'"Step 2.16 shows what to do."
    return 1
  fi
  PRE_INFO+="Memory: ${MEM_INFO%%$'\n'*}; this server has $(human_mb "$MEM_RAM_MB")"$'\n'
  [[ -n "$MEM_WARN" ]] && PRE_INFO+="Warning: $MEM_WARN"$'\n'
  rfs=$MEM_RFS
  if [[ $MEM_HP_LOW -eq 1 ]]; then
    DUP_EXTRA+="      set use_large_pages='TRUE'"$'\n'
    PRE_INFO+="The primary has use_large_pages=ONLY, but this server has too few HugePages."$'\n'"The standby gets TRUE. Configure HugePages later."$'\n'
  fi
  # recovery area: never bigger than the FREE space here, less what the copy itself puts there
  # (a full disk group or file system must not get a quota that it cannot hold)
  # (ASM: usable_file_mb, the space after mirroring; the files counted are the ones of this copy, and the standby
  # logs of step 9.3 when they go there. A re-run after a part copy counts its files twice: on the safe side.)
  local fra_free=0 fra_files=0 l dgn d fmnt=""
  if [[ "$FRA_LOC" == +* ]]; then
    dgn=${FRA_LOC#+}; dgn=${dgn%%/*}
    sql_asm "select usable_file_mb from v\$asm_diskgroup where name=upper('$dgn');" && fra_free=$(first_line)
    while IFS= read -r l; do d=${l%%:*}; d=${d#+}; d=${d%%/*}; [[ "${d^^}" == "${dgn^^}" ]] && fra_files=$((fra_files + ${l##*:})); done < <(loc_list | grep '^+')
    local sd=${SRL_LOC#+}; sd=${sd%%/*}; [[ "$SRL_LOC" == +* && "${sd^^}" == "${dgn^^}" ]] && fra_files=$((fra_files + SRL_MB))
  elif [[ -n "$FRA_LOC" && -d "$FRA_LOC" ]]; then
    fra_free=$(free_mb_of "$FRA_LOC")
    fmnt=$(mnt_of "$FRA_LOC")
    while IFS= read -r l; do [[ "$(mnt_of "${l%%:*}")" == "$fmnt" ]] && fra_files=$((fra_files + ${l##*:})); done < <(loc_list | grep '^/')
    [[ "$SRL_LOC" == /* && "$(mnt_of "$SRL_LOC")" == "$fmnt" ]] && fra_files=$((fra_files + SRL_MB))
  fi
  num "$fra_free" || fra_free=0
  local fra_cap=$(( (fra_free - fra_files) * 90 / 100 ))
  if [[ $rfs -gt 0 && $fra_free -gt 0 && $fra_cap -lt 2048 ]]; then
    PRE_FIX="The recovery area $FRA_LOC has too little free space: $(human_mb "$fra_free") free, and the copy itself puts $(human_mb "$fra_files") there."$'\n'"The standby needs room there for archived logs. Add space to $FRA_LOC first."
    return 1
  fi
  if [[ $rfs -gt 0 && $fra_free -gt 0 && $(( rfs / 1048576 )) -gt $fra_cap ]]; then
    DUP_EXTRA+="      set db_recovery_file_dest_size='${fra_cap}M'"$'\n'
    PRE_INFO+="The recovery area size of the primary ($(human_mb $(( rfs / 1048576 )))) is more than the free space for it in $FRA_LOC here."$'\n'"The standby gets $(human_mb "$fra_cap") (90% of what stays free after the copy)."$'\n'
  fi
  # control files: same disk group (new OMF names) or the same path (an OMF file name becomes controlNN.ctl)
  prim_sql "select name from v\$controlfile;" || { PRE_FIX="Cannot read the control files of the primary"; return 1; }
  local cf n=0
  while IFS= read -r cf; do
    [[ "$cf" =~ ^[+/][A-Za-z0-9_./-]+$ ]] || continue
    n=$((n + 1))
    if [[ "$cf" == +* ]]; then cf=$(norm_loc "$cf")
    elif [[ "$(basename "$cf")" == o1_mf_*.ctl ]]; then cf="$(dirname "$cf")/$(printf 'control%02d.ctl' "$n")"; fi
    CF_LIST+="${CF_LIST:+,}'$cf'"
  done <<< "$SQL_OUT"
  [[ -n "$CF_LIST" ]] || { PRE_FIX="The primary returned no control file names"; return 1; }
  # every datafile and tempfile is created in its own disk group (or with its own name in a folder)
  prim_sql "select 'D|'||file#||'|'||name from v\$datafile union all select 'T|'||file#||'|'||name from v\$tempfile;" || { PRE_FIX="Cannot read the datafile names of the primary"; return 1; }
  local k fno fname
  while IFS='|' read -r k fno fname; do
    num "$fno" && [[ "$fname" =~ ^[+/][A-Za-z0-9_./-]+$ ]] || continue
    local what=datafile; [[ "$k" == "T" ]] && what=tempfile
    if [[ "$fname" == +* ]]; then NEWNAMES+="  set newname for $what $fno to '$(norm_loc "$fname")';"$'\n'
    elif [[ "$(basename "$fname")" != o1_mf_* ]]; then NEWNAMES+="  set newname for $what $fno to '$fname';"$'\n'; fi
  done <<< "$SQL_OUT"
  # files that already exist at the target paths: an earlier copy of this standby, or something else?
  if [[ "$MODE" == "run" && ! -f "$STATE_DIR/existing_files_ok" ]]; then
    local ex="" exn=0 ef
    while IFS='|' read -r k fno fname; do
      [[ "$fname" == /* && -e "$fname" ]] && { exn=$((exn + 1)); [[ $exn -le 5 ]] && ex+="  $fname"$'\n'; }
    done <<< "$SQL_OUT"
    for ef in $(tr ',' '\n' <<< "$CF_LIST" | tr -d "'"); do [[ "$ef" == /* && -e "$ef" ]] && { exn=$((exn + 1)); [[ $exn -le 5 ]] && ex+="  $ef"$'\n'; }; done
    if [[ $exn -gt 0 ]]; then
      if [[ "$(marker_kind)" == "" && ! -f "$STATE_DIR/dup_attempt" ]]; then
        PRE_FIX="$exn file(s) already exist where the copy will write. This script did not make them:"$'\n'"${ex%$'\n'}"
        [[ $exn -gt 5 ]] && PRE_FIX+=$'\n'"  ... and $((exn - 5)) more"
        PRE_FIX+=$'\n'"RMAN would overwrite them (NOFILENAMECHECK)."$'\n'"If they belong to an old database on this server, move or remove them."$'\n'"They are not files of the primary (step 2.15 proved it)."$'\n'"If they may be overwritten, run this and answer r:"$'\n'"  touch $STATE_DIR/existing_files_ok"
        return 1
      fi
      PRE_INFO+="$exn file(s) of the earlier copy will be overwritten"$'\n'
    fi
  fi
  if grep -qE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT"; then
    # file-system OMF files are created again as OMF files in db_create_file_dest
    local omfd="$CFD"
    if [[ "$omfd" != /* ]]; then
      # db_create_file_dest is not a folder on primary: the standby gets the folder of the OMF files (set on the standby only)
      omfd=$(grep -m1 -oE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT" | cut -d'|' -f3); omfd=$(dirname "$(dirname "$(dirname "$omfd")")")
      v_path "$omfd" || { PRE_FIX="Cannot find the folder for the OMF datafiles of the primary"; return 1; }
      DUP_EXTRA+="      set db_create_file_dest='$omfd'"$'\n'
    fi
    runuser -u "$ORACLE_USER" -- test -d "$omfd" -a -w "$omfd" || { PRE_FIX="The OMF folder $omfd does not exist here or is not writable by $ORACLE_USER (step 2.14)"; return 1; }
    PRE_INFO+="OMF datafiles are created in $omfd/${STANDBY_UNIQUE^^}"$'\n'
  fi
  if use_grid && [[ -z "$CFD" || "$CFD" == "-" ]] && ! grep -qE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT"; then
    # datafiles in ASM but no db_create_file_dest: the standby could not create its standby/online logs (ORA-15046).
    # The disk group is the one of the datafiles (never a disk group that only holds the recovery area).
    local ddg; ddg=$(grep -m1 -oE '^D\|[0-9]+\|\+[^/]+' <<< "$SQL_OUT" | cut -d'|' -f3)
    if [[ -n "$ddg" ]]; then
      DUP_EXTRA+="      set db_create_file_dest='$ddg'"$'\n'
      PRE_INFO+="The primary has no db_create_file_dest. The standby gets $ddg, for its redo logs in ASM."$'\n'
    fi
  fi
  # the standby's own audit folder
  DUP_EXTRA+="      set audit_file_dest='$(adump_dir)'"$'\n'
  # redo transport destination used on primary for this standby (the standby gets the same N back to primary)
  find_dest || { PRE_FIX="Cannot read log_archive_dest_N on the primary"; return 1; }
  p_param log_archive_config && P_DG_CONFIG=$PVAL || P_DG_CONFIG=""
  dg_config_names_ok "$P_DG_CONFIG" || { PRE_FIX="log_archive_config of the primary cannot be read safely: $P_DG_CONFIG. Check step 4.3."; return 1; }
  # primary parameters that do not fit the standby
  prim_sql "select name||'|'||value from v\$parameter where value is not null and (name like 'db_create_online_log_dest%' or name like 'log_archive_dest%' or name in ('log_archive_duplex_dest','remote_listener','local_listener','fal_client','db_file_name_convert','log_file_name_convert','dg_broker_start','instance_name','service_names'));" || { PRE_FIX="Cannot read the parameters of the primary"; return 1; }
  local line pname pval known_dgs=" $(asm_dgs | tr '\n' ' ') "
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pname=${line%%|*}; pval=${line#*|}
    if [[ "$pname" =~ ^db_create_online_log_dest_[1-5]$ ]]; then
      local loc; loc=$(norm_loc "$pval")
      if [[ "$loc" == +* && "$known_dgs" != *" ${loc#+} "* ]] || [[ "$loc" == /* && ! -d "$loc" ]]; then
        DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="$pname of the primary ($pval) does not exist here. Cleared on the standby."$'\n'
      fi
    elif [[ "$pname" =~ ^log_archive_dest_([0-9]+)$ ]]; then
      local dn=${BASH_REMATCH[1]}
      if [[ "$dn" != "$DEST_N" && "$dn" != "$ARCH_N" && "$(sed -E "s/ *= */=/g" <<< "${pval^^}")" == *SERVICE=* ]]; then
        # a destination to another standby: kept for a later switchover, but off until then
        DUP_EXTRA+="      set log_archive_dest_state_$dn='defer'"$'\n'; PRE_INFO+="$pname of the primary points to another standby. Kept, but deferred here."$'\n'
      elif [[ "$dn" != "$DEST_N" && "$dn" != "$ARCH_N" ]]; then
        DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="$pname of the primary is cleared on the standby"$'\n'
      fi
    elif [[ "$pname" == "log_archive_dest" || "$pname" == "log_archive_duplex_dest" ]]; then
      # old-style parameters cannot be used together with log_archive_dest_1 (ORA-16019)
      DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="The primary uses the old-style $pname. Cleared on the standby."$'\n'
    elif [[ "$pname" == "remote_listener" || "$pname" == "fal_client" || "$pname" == "db_file_name_convert" ]]; then
      DUP_EXTRA+="      set $pname=''"$'\n'; PRE_INFO+="$pname of the primary: cleared on the standby"$'\n'
    elif [[ "$pname" == "log_file_name_convert" ]]; then
      HAS_LFNC=1
    elif [[ "$pname" == "dg_broker_start" && "${pval^^}" == "TRUE" ]]; then
      DUP_EXTRA+="      set dg_broker_start='FALSE'"$'\n'; PRE_INFO+="The primary uses the Data Guard broker. It stays off on the standby until you add it there."$'\n'
    elif [[ "$pname" == "instance_name" && "${pval^^}" != "${STANDBY_SID^^}" ]]; then
      DUP_EXTRA+="      set instance_name='$STANDBY_SID'"$'\n'; PRE_INFO+="instance_name of the primary is $pval. The standby gets $STANDBY_SID."$'\n'
    elif [[ "$pname" == "service_names" ]]; then
      DUP_EXTRA+="      set service_names='$STANDBY_SERVICE'"$'\n'; PRE_INFO+="service_names of the primary is $pval. The standby gets $STANDBY_SERVICE,"$'\n'"so clients of the primary service never reach the standby."$'\n'
    fi
  done <<< "$SQL_OUT"
  # same paths on both servers: MRP tries to clear the online logs and prints ORA-19527/ORA-00312 in the alert
  # log at every start. A convert pair that matches nothing stops that noise (Oracle note 352879.1).
  [[ ${HAS_LFNC:-0} -eq 1 ]] || DUP_EXTRA+="      set log_file_name_convert='/__dg_no_rename__','/__dg_no_rename__'"$'\n'
  # the whole RMAN text is parsed by RMAN itself before anything starts (no connection needed); once per run
  if [[ "$MODE" == "run" && "${RMAN_PREFLIGHT_OK:-}" != "$(rman_script | md5sum | cut -c1-12)" ]]; then
    # the script holds no password (the connect lines are not in it); rman reads it as the database owner
    local chk; chk=$(mktemp /tmp/dg_rman.XXXXXXXX) || { PRE_FIX="Cannot create a temporary file in /tmp"; return 1; }
    CLEANUP_FILES+=("$chk")
    rman_script > "$chk" && chmod 644 "$chk" || { PRE_FIX="Cannot write $chk"; return 1; }
    if ! run_logged "rman checksyntax" as_oracle timeout 120 "$DB_HOME/bin/rman" checksyntax "cmdfile=$chk"; then
      PRE_FIX="RMAN does not accept the generated script: $(grep -E 'RMAN-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ')"$'\n'"The script is saved as $LOG_DIR/duplicate_check_$RUN_ID.rman"
      cp -p -- "$chk" "$LOG_DIR/duplicate_check_$RUN_ID.rman" 2>/dev/null; return 1
    fi
    rm -f -- "$chk"
    # and a real RMAN login to both databases (the connect lines, nothing else)
    local lrc=0 ltmp
    ltmp=$(mktemp /tmp/dg_out.XXXXXXXX) || { PRE_FIX="Cannot create a temporary file"; return 1; }
    CLEANUP_FILES+=("$ltmp")
    # the passwords travel on stdin only (never in a file, never in argv)
    { printf 'connect target sys/"%s"@%s\n' "$SYS_PW" "$PRIMARY_TNS"; printf 'connect auxiliary sys/"%s"@%s\n' "$SYS_PW" "$STANDBY_TNS"; printf 'exit\n'; } \
      | as_oracle timeout 120 "$DB_HOME/bin/rman" > "$ltmp" 2>&1 || lrc=1
    RUN_OUT=$(cat "$ltmp"); rm -f -- "$ltmp"
    printf '%s\n(exit code %s)\n' "$RUN_OUT" "$lrc" | log_block "rman login test"
    # success = both "connected to" lines (RMAN may print harmless warnings next to them)
    if ! grep -q 'connected to target database' <<< "$RUN_OUT" || ! grep -q 'connected to auxiliary database' <<< "$RUN_OUT"; then
      PRE_FIX="RMAN cannot log in to both databases: $(grep -E '(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ')"$'\n'"Check the logins of steps 7.4 and 7.5."; return 1
    fi
    PRE_INFO+="RMAN accepts the script and logs in to both databases"$'\n'
    grep -qE '^(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" && PRE_INFO+="RMAN printed warnings at the login: $(grep -E '^(RMAN|ORA)-[0-9]+' <<< "$RUN_OUT" | head -n 2 | tr '\n' ' ')"$'\n'
    RMAN_PREFLIGHT_OK=$(rman_script | md5sum | cut -c1-12)
  fi
  PRE_INFO=${PRE_INFO%$'\n'}
  PRE_OK=1
}
HAS_LFNC=0; RMAN_PREFLIGHT_OK=""

PRE_ASMGID_OLD=""; PRE_ASMGID_WANT=""
c_8_1() {
  PRE_ASMGID_OLD=""; PRE_ASMGID_WANT=""
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  need_ssh || return 2
  detect_built
  [[ $STANDBY_BUILT -eq 1 ]] || need_sys || return 2
  [[ $STANDBY_BUILT -eq 1 ]] && { NOW="The standby database already exists. No copy is needed."; return 0; }
  if dup_prechecks; then NOW=$PRE_INFO; return 0; fi
  NOW=$PRE_FIX
  [[ "$PRE_FIX" == *"(step "* ]] && return 2          # an earlier step is not done yet
  if [[ -n "$PRE_ASMGID_OLD" ]]; then
    # the one pre-check the script fixes itself: the group of the oracle program
    NOW="$DB_HOME/bin/oracle has group $PRE_ASMGID_OLD. It must be $PRE_ASMGID_WANT, the group of the ASM disks (ORA-15025)."
    PLAN="As root:  $GRID_HOME/bin/setasmgidwrap o=$DB_HOME/bin/oracle"$'\n'"Then all pre-checks run again."
    KIND_NOW=auto; return 1
  fi
  PLAN="$PRE_FIX"; return 1
}
d_8_1() {
  run_logged "setasmgidwrap" "$GRID_HOME/bin/setasmgidwrap" "o=$DB_HOME/bin/oracle" || { bad "setasmgidwrap failed: ${RUN_OUT%%$'\n'*}"; return 1; }
  journal ASMGID "$DB_HOME/bin/oracle" "by hand, only if wanted, as root: chgrp $PRE_ASMGID_OLD $DB_HOME/bin/oracle ; chmod 6751 $DB_HOME/bin/oracle  (the group it had before)"
  say "$DB_HOME/bin/oracle now has group $(stat -c '%G' "$DB_HOME/bin/oracle" 2>/dev/null)."
  return 0
}

rman_script() {
  local i ch="" d1="" ll="''"
  for ((i = 1; i <= AUX_CHANNELS; i++)); do ch+="  allocate auxiliary channel a$i device type disk;"$'\n'; done
  if [[ "$ARCH_LOC" == "USE_DB_RECOVERY_FILE_DEST" ]]; then d1="location=use_db_recovery_file_dest"
  elif [[ -n "$ARCH_LOC" ]]; then d1="location=$ARCH_LOC"; fi
  local dgc; dgc=$(lac_merged "${P_DG_CONFIG:-}")
  # the standby instance registers with its own listener (port of primary)
  [[ "$PORT" != "1521" ]] && ll="'(ADDRESS=(PROTOCOL=TCP)(HOST=$STANDBY_HOST)(PORT=$PORT))'"
  cat <<EOF
run {
${ch}${NEWNAMES}  duplicate target database for standby from active database
    dorecover
    spfile
      set db_unique_name='$STANDBY_UNIQUE'
      set control_files=$CF_LIST
      set fal_server='$PRIMARY_TNS'
      set log_archive_config='$dgc'
EOF
  [[ -n "$d1" ]] && printf "      set log_archive_dest_%s='%s valid_for=(all_logfiles,all_roles) db_unique_name=%s'\n" "${ARCH_N:-1}" "$d1" "$STANDBY_UNIQUE"
  cat <<EOF
      set log_archive_dest_${DEST_N:-2}='service=$PRIMARY_TNS async valid_for=(online_logfiles,primary_role) db_unique_name=$PRIMARY_UNIQUE'
      set log_archive_dest_state_${DEST_N:-2}='enable'
      set standby_file_management='AUTO'
      set local_listener=$ll
${DUP_EXTRA}    nofilenamecheck;
}
EOF
}

c_8_2() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  need_ssh || return 2
  detect_built
  [[ $STANDBY_BUILT -eq 1 ]] || need_sys || return 2
  [[ $STANDBY_BUILT -eq 1 ]] && { NOW="The standby database exists (the copy finished)"; return 0; }
  if [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]]; then
    NOW="A failed or unfinished copy is on this server: $SC_INFO."$'\n'"Clean it up first. Run  $SELF --from 7.2  (step 7.2 shows the commands)."
    return 2
  fi
  dup_prechecks || { NOW="The pre-checks did not pass: $PRE_FIX (step 8.1)"; return 2; }
  NOW="The standby instance is in NOMOUNT and all pre-checks passed"
  local nd nt; nd=$(grep -c 'for datafile' <<< "$NEWNAMES"); nt=$(grep -c 'for tempfile' <<< "$NEWNAMES")
  # the network limits the whole copy: about 100 MB/s on 1 Gbit/s, up to about 1000 MB/s on 10 Gbit/s
  local rate_hi=$(( AUX_CHANNELS * 150 )); [[ $rate_hi -gt 1000 ]] && rate_hi=1000
  local est_lo est_hi; est_lo=$(( PRIMARY_DB_MB / rate_hi / 60 + 1 )); est_hi=$(( PRIMARY_DB_MB / 100 / 60 + 1 ))
  PLAN="Copy the database from the primary with RMAN (active duplicate), as $ORACLE_USER:
  rman target sys@$PRIMARY_TNS auxiliary sys@$STANDBY_TNS
Size to copy: about $(human_mb "$PRIMARY_DB_MB"), with $AUX_CHANNELS channels on this server
Rough time: $(human_min "$est_lo") (fast network and storage) to $(human_min "$est_hi") (1 Gbit/s network)
The primary database is only read: nothing is created, dropped or changed in it.
On the primary during the copy: extra disk and network load, log switches,
a snapshot control file in its \$ORACLE_HOME/dbs, and an audit file for each login.
Run the copy when the load is low, for example at night."
  USING="RMAN command: duplicate target database for standby from active database
  (dorecover, spfile, nofilenamecheck)
$nd $([[ $nd -eq 1 ]] && printf 'datafile' || printf 'datafiles') and $nt $([[ $nt -eq 1 ]] && printf 'tempfile' || printf 'tempfiles') keep their disk group or path.
Settings written to the standby spfile:
$(sed -n 's/^      set /  /p' <<< "$(rman_script)")
The full RMAN script is saved first to $LOG_DIR/duplicate_<date>.rman"
  [[ -z "${TMUX:-}${STY:-}" ]] && USING+=$'\n'"The copy runs in its own session: closing the terminal does not stop it."$'\n'"Run the script again to watch it."
  return 1
}

d_8_2() {
  confirm_word "Start the RMAN copy now." "DUPLICATE" || { say "The copy was not started."; return 3; }
  # the checks again, right before the start (tnsnames.ora or the instance may have changed meanwhile)
  dup_prechecks || { bad "The pre-checks no longer pass: $PRE_FIX"; return 1; }
  local rmanfile="$LOG_DIR/duplicate_$RUN_ID.rman" rlog="$LOG_DIR/duplicate_$RUN_ID.log"
  [[ -e "$(dup_marker)" ]] && rm -f -- "$(dup_marker)"
  rman_script | write_as root "$rmanfile" 640 || return 1
  say "RMAN script:  $rmanfile"
  DUP_RAN=1
  install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/dup_attempt"
  journal DUPLICATE "$STANDBY_UNIQUE" "RMAN duplicate started: files of the standby are created in $(all_locs | cut -d: -f1 | paste -sd' ' -)"
  local rc=0
  run_long "RMAN duplicate" "$rlog" 'Starting|Finished|ORA-|RMAN-|copy complete|output file name|restoring|backup set complete' oracle "$DB_HOME/bin/rman" < <(
    printf 'connect target sys/"%s"@%s\n' "$SYS_PW" "$PRIMARY_TNS"
    printf 'connect auxiliary sys/"%s"@%s\n' "$SYS_PW" "$STANDBY_TNS"
    cat "$rmanfile"
    printf 'exit\n') || rc=$?
  if dup_log_ok "$rlog" "$rc"; then
    dup_success_record
    DONE_MSG="The database was copied (RMAN: Finished Duplicate Db)"
    return 0
  fi
  bad "The copy did not finish (exit code $rc; $(ora_errors "$(cat "$rlog")"))"
  install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/dup_attempt"
  RESUME_STEP=7.2; DO_FAIL_STOP_ONLY=1
  {
    grep -m1 -E '^(RMAN|ORA)-[0-9]+' "$rlog" | sed 's/^/First error: /'
    printf 'Full output: %s\n' "$rlog"
    printf 'Common causes:\n'
    printf '  ORA-19504, ORA-17502   a disk group is missing or not mounted\n'
    printf '  ORA-01017              the password files differ (step 6.1)\n'
    printf '  ORA-12528, ORA-12514   listener or tnsnames.ora (phase 5)\n'
    printf '  ORA-15025, ORA-27041   the oracle binary cannot open the ASM disks (setasmgidwrap, step 8.1)\n'
    printf 'Before you try again, clean up this server: answer q, then run  %s --from 7.2\nStep 7.2 shows the clean-up commands.\n' "$SELF"
  } | hint
  return 1
}

dup_success_record() {
  # the duplicate finished: marker, the initial pfile out of the way, journal (also when the run was not watching)
  set_marker duplicate
  rm -f -- "$STATE_DIR/dup_attempt"
  local p; p=$(pfile_path)
  [[ -f "$p" ]] && runuser -u "$ORACLE_USER" -- mv -f -- "$p" "$p.pre_duplicate_$RUN_ID" && { say "The temporary pfile ${p##*/} was renamed. The instance now uses the spfile."; journal RENAME "$p" "to=$p.pre_duplicate_$RUN_ID"; }
  journal DUPLICATE_DONE "$STANDBY_UNIQUE" "Finished Duplicate Db; spfile $(spfile_path)"
  return 0
}

phase_8() {
  phase_header 8 "Copy the database (RMAN)"
  run_step 8.1 check "Pre-checks: space, storage, logins, parameters" c_8_1 d_8_1
  run_step 8.2 auto  "RMAN duplicate for standby" c_8_2 d_8_2
}
