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
  # $1 duplicate = RMAN printed "Finished Duplicate Db" and the new standby was checked; copied = RMAN finished,
  # not checked yet; seen = a mounted standby was compared with the primary (no datafile header error).
  # All mark a finished copy; "copied" is compared again when the standby is mounted (then "seen").
  [[ "$MODE" == "run" ]] || return 0
  [[ "$1" == "seen" && -e "$(dup_marker)" && "$(marker_kind)" != copied ]] && return 0
  printf '%s\n' "$1" | write_as "$ORACLE_USER" "$(dup_marker)" 640 \
    || warn "Cannot write $(dup_marker)."$'\n'"While the standby is shut down, the script cannot tell that it is complete."
  return 0
}
marker_kind() { [[ -f "$(dup_marker)" ]] || return 0; local k; k=$(head -n 1 -- "$(dup_marker)" 2>/dev/null); printf '%s' "${k:-duplicate}"; }
# the RMAN copy finished: "duplicate" (and the new standby was checked) or "copied" (RMAN finished, the standby
# could not be checked yet: the next look at a mounted standby compares it with the primary, then "seen")
copy_finished() { local k; k=$(marker_kind); [[ "$k" == duplicate || "$k" == copied ]]; }
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
  [[ "$LSTATE" == "ERROR" ]] && { SC_INFO="the state of the standby instance cannot be read ($(ora_errors "$SQL_OUT"))"; return 2; }
  [[ "$LSTATE" == "HUNG" ]] && { SC_INFO="$(hung_text) Step 9.2 offers to stop it (shutdown abort) and start it again."; return 2; }
  if [[ "$LSTATE" != "MOUNTED" && "$LSTATE" != "OPEN" ]]; then
    if [[ -f "$(dup_marker)" && -f "$(spfile_path)" ]]; then
      # only the record: the files are checked when the standby is mounted (step 9.2 mounts it)
      SC_INFO="Recorded as built, not checked now: the standby is not mounted. Its files are checked when it is mounted."
      return 0
    fi
    SC_INFO="the standby is not mounted and no finished copy is recorded"; return 1
  fi
  if [[ "$(marker_kind)" == "duplicate" || "$(marker_kind)" == "seen" ]]; then
    # verified before: header errors now are reported, never treated as a failed copy
    if ! sql_local "select count(*) from v\$datafile_header where error is not null;" || ! num "$(first_line)"; then
      SC_INFO="the datafile headers of the standby cannot be read now ($(ora_errors "$SQL_OUT"))"; return 2
    elif [[ "$(first_line)" != "0" ]]; then
      warn "The standby was complete before, but now $(first_line) datafile header(s) show an error."$'\n'"Usually a datafile was added on the primary, a file is OFFLINE, or a file was removed."
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
  if [[ "$se" == "0" && "$sc" -gt 0 ]]; then
    # a complete physical standby that this script did not copy (made by hand, or by another tool) is accepted
    [[ -z "$(marker_kind)" && ! -f "$STATE_DIR/dup_attempt" ]] && SC_INFO="Accepted: a complete physical standby ($sc datafiles, no header errors) that this script did not copy."
    set_marker seen; return 0
  fi
  SC_INFO="the standby has $sc datafiles ($se with errors), the primary has $pc"
  return 1
}

leftover_files() {
  # files of the standby database on this server (ASM: +DG/<STANDBY_UNIQUE>; folders: the primary's names here)
  local dg out="" f n
  for dg in $(asm_dgs); do
    grid_sw_ok || continue
    # the folder at the top of the disk group only (parent_index = its root), the same test as clean_collect
    if sql_asm "select count(*) from v\$asm_alias a, v\$asm_diskgroup g where a.group_number=g.group_number and g.name=upper('$dg') and upper(a.name)=upper('$STANDBY_UNIQUE') and a.parent_index=a.group_number*16777216;" && [[ "$(first_line)" != "0" ]]; then
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
  [[ -f "$(spfile_path)" ]] && ! copy_finished || return 1
  sql_local "select nvl(value,'-') from v\$parameter where name='spfile';" || return 1
  [[ "$(first_line)" != "-" ]]
}
FS_FILENAMES=""; FS_READ_FAIL=0
sql_or_cached_filenames() {
  # the datafile / tempfile / redo / control file names of the primary (read-only), cached in this run
  # FS_READ_FAIL=1: the names could not be read (not the same as "the primary has no file in a folder")
  FS_READ_FAIL=0
  [[ -n "$FS_FILENAMES" ]] && return 0
  need_ssh || { FS_READ_FAIL=1; return 1; }
  prim_sql "select name from v\$datafile union all select name from v\$tempfile union all select member from v\$logfile union all select name from v\$controlfile;" || { FS_READ_FAIL=1; return 1; }
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
DETECT_RC=0
detect_built() {
  # sets STANDBY_BUILT (used by phases 7-10); DETECT_RC 2 = cannot tell (SC_INFO)
  STANDBY_BUILT=0; DETECT_RC=0; SC_INFO=""
  local_state
  if [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]]; then
    sql_local "select database_role from v\$database;" || { DETECT_RC=2; SC_INFO="cannot read the role ($(ora_errors "$SQL_OUT"))"; return 0; }
    [[ "$(first_line)" == "PHYSICAL STANDBY" ]] || { SC_INFO="the database here is $LSTATE with role $(first_line), not a physical standby"; return 0; }
  fi
  local rc=0; standby_complete || rc=$?
  [[ $rc -eq 0 ]] && STANDBY_BUILT=1
  DETECT_RC=$rc
  return 0
}

# ---- 7.1 ----
adump_dir() { printf '%s/admin/%s/adump' "$ORACLE_BASE" "$STANDBY_UNIQUE"; }
spfile_audit_raw() {
  # audit_file_dest as written in the spfile of a standby that exists already (empty: no spfile, no such line)
  local f v; f=$(spfile_path); [[ -f "$f" ]] || return 0
  # a line for this instance (SID.) wins over one for all (*.), as in the database; lines of other SIDs are not used
  local all; all=$(grep -a -o -iE "^[*A-Za-z0-9_]*\.audit_file_dest='[^']+'" "$f" 2>/dev/null)
  v=$(grep -i -- "^${STANDBY_SID}\." <<< "$all" | tail -n 1)
  [[ -n "$v" ]] || v=$(grep -- '^\*\.' <<< "$all" | tail -n 1)
  v=$(sed "s/^[^']*'//; s/'\$//" <<< "$v")
  printf '%s' "${v%/}"
}
spfile_audit_dest() {
  # the same, only when it is a plain absolute path (a copy made before, not by step 8.2 of this script, may
  # keep the primary's own folder); an unusual one is handled by the check of 7.1 (a step by hand)
  local v; v=$(spfile_audit_raw)
  [[ "$v" == /* ]] && v_path "$v" && printf '%s' "$v"
  return 0
}
inst_dirs() {
  # folders the instance needs at startup (same paths as on primary)
  adump_dir; printf '\n'
  # (only under ORACLE_BASE: a folder elsewhere, read from a file the oracle user owns, is not made by root)
  local a obr; a=$(spfile_audit_dest); obr=$(readlink -m -- "$ORACLE_BASE" 2>/dev/null || printf '%s' "$ORACLE_BASE")
  # a link that points nowhere is left to the check (it says so); it is never a folder to make
  [[ -n "$a" && -L "$a" && ! -e "$a" ]] && a=""
  [[ -n "$a" ]] && a=$(readlink -m -- "$a" 2>/dev/null || printf '%s' "$a")
  [[ -n "$a" && "$a" != "$(readlink -m -- "$(adump_dir)" 2>/dev/null)" && "$a" == "$obr"/* ]] && printf '%s\n' "$a"
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
  # an audit folder outside ORACLE_BASE (read from the spfile, a file the oracle user owns) is not created by
  # root: it is a step to do by hand, never passed with a warning (the instance does not start without it)
  # an audit_file_dest in the spfile that is not a plain absolute path (".." parts, odd characters): by hand
  local raw; raw=$(spfile_audit_raw)
  if [[ -n "$raw" ]] && ! { [[ "$raw" == /* ]] && v_path "$raw"; }; then
    NOW="The spfile of the standby sets audit_file_dest to an unusual path:  $(tr -cd '[:print:]' <<< "$raw")"$'\n'"The script does not use it. The instance needs a plain folder there to start."
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="To do on this server ($(hostname -s))"
    PLAN="-- Set audit_file_dest in the spfile of $STANDBY_SID to a plain folder under $ORACLE_BASE, for example:"$'\n'"--   $(adump_dir)"$'\n'"-- Then answer r."
    return 1
  fi
  local sa out="" obr broken=""; sa=$(spfile_audit_dest); obr=$(readlink -m -- "$ORACLE_BASE" 2>/dev/null || printf '%s' "$ORACLE_BASE")
  # a link that points nowhere: said as such (resolved, it would look like a folder to make)
  [[ -n "$sa" && -L "$sa" && ! -e "$sa" ]] && broken=$sa
  # the real place (a folder above may be a link, also one the oracle user made): judged and shown resolved,
  # against the resolved ORACLE_BASE; under it, it is in the list above (inst_dirs) and made there
  [[ -n "$sa" ]] && sa=$(readlink -m -- "$sa" 2>/dev/null || printf '%s' "$sa")
  # resolved through links the oracle user may have made: checked again (a space, ';' or a newline from a link
  # target must never reach a command shown for root)
  if [[ -n "$sa" ]] && ! { [[ "$sa" == /* ]] && v_path "$sa"; }; then
    NOW="audit_file_dest in the spfile of the standby leads, through links, to an unusual path:  $(tr -cd '[:print:]' <<< "$sa")"$'\n'"The script does not use it. The instance needs a plain folder there to start."
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"; MANUAL_WHERE="To do on this server ($(hostname -s))"
    PLAN="-- Set audit_file_dest in the spfile of $STANDBY_SID to a plain folder under $ORACLE_BASE, for example:"$'\n'"--   $(adump_dir)"$'\n'"-- Then answer r."
    return 1
  fi
  if [[ -n "$broken" ]]; then out=$broken
  elif [[ -n "$sa" && "$sa" != "$obr"/* ]] && ! { [[ -d "$sa" ]] && runuser -u "$ORACLE_USER" -- test -w "$sa"; }; then out=$sa; fi
  if [[ ${#I71[@]} -eq 0 && -n "$out" ]]; then
    NOW="The spfile of the standby sets audit_file_dest to $out ($([[ -n "$broken" ]] && printf 'a link that points nowhere' || printf 'outside %s' "$ORACLE_BASE"))."$'\n'"It is missing or not writable by $ORACLE_USER. The instance does not start without it."
    KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
    # the path comes from a file the oracle user can change: no chown is suggested for a folder that exists, and a
    # system folder is never offered to that user
    # (also the home folder of any other account: a folder there made for $ORACLE_USER could hold programs that
    # account runs, for example ~/bin)
    # why a folder is refused (the plan names it): a system folder, another account's home, a folder above an
    # Oracle home or base (write access there would let the oracle user swap them), or a nearest existing folder
    # that belongs to someone other than root or the oracle user
    local oh_o hh why_no="" anc ao hx; oh_o=$(home_of "$ORACLE_USER"); [[ -n "$oh_o" ]] && oh_o=$(readlink -m -- "$oh_o" 2>/dev/null)
    case "$out" in /|/usr|/usr/*|/etc|/etc/*|/var|/var/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/root|/root/*|/tmp|/tmp/*|/home|/srv|/opt|/run|/run/*) why_no="a system folder" ;;
      # under /home only the oracle user's own home: accounts from LDAP or sssd may be missing from getent
      /home/*) [[ -n "$oh_o" && ( "$out" == "$oh_o" || "$out" == "$oh_o"/* ) ]] || why_no="under /home, outside the home folder of $ORACLE_USER" ;; esac
    # another account's home (getent; without the oracle user's own home known, this test is left out: the owner
    # test below still covers it)
    if [[ -z "$why_no" && -n "$oh_o" ]]; then
      while IFS=: read -r _ _ _ _ _ hh _; do
        hh=$(readlink -m -- "$hh" 2>/dev/null); [[ -n "$hh" && "$hh" != / && "$hh" != "$oh_o" ]] || continue
        [[ "$out" == "$hh" || "$out" == "$hh"/* ]] && { why_no="in the home folder of another account ($hh)"; break; }
      done < <(getent passwd)
    fi
    if [[ -z "$why_no" ]]; then
      for hx in "$ORACLE_BASE" "$DB_HOME" ${GRID_HOME:+"$GRID_HOME"} ${GRID_BASE:+"$GRID_BASE"}; do
        hx=$(readlink -m -- "$hx" 2>/dev/null); [[ -n "$hx" && ( "$hx" == "$out" || "$hx" == "$out"/* ) ]] && { why_no="$( [[ "$hx" == "$out" ]] && printf "an Oracle home or base itself" || printf "a folder above %s" "$hx")"; break; }
      done
    fi
    if [[ -z "$why_no" ]]; then
      anc=$out; while [[ ! -e "$anc" && "$anc" != / ]]; do anc=$(dirname "$anc"); done
      ao=$(stat -c '%U' -- "$anc" 2>/dev/null)
      if [[ "$anc" != "$out" && -e "$anc" && ! -d "$anc" ]]; then why_no="under $anc, which is not a folder"
      elif [[ -z "$ao" ]]; then why_no="under $anc, whose owner cannot be read"
      elif [[ "$ao" != root && "$ao" != "$ORACLE_USER" ]]; then
        if [[ "$anc" == "$out" ]]; then why_no="a folder that belongs to ${ao:-an unknown owner}"; else why_no="under $anc, which belongs to ${ao:-an unknown owner}"; fi
      fi
    fi
    # a root mkdir and chown only when no one but root can change any folder on the way (else the oracle user
    # could put a link in place before root runs them: chown would follow it). Otherwise the oracle user makes
    # the folder itself when it can, and the path is refused when it cannot
    local root_ok=0 mk_ora=0 cd cm co
    if [[ -z "$why_no" && ! -e "$out" && ! -L "$out" ]]; then
      root_ok=1; cd=$anc
      while :; do
        IFS=' ' read -r co cm <<< "$(stat -c '%U %a' -- "$cd" 2>/dev/null)"
        [[ -n "$co" ]] || { root_ok=0; why_no="under $cd, whose owner and mode cannot be read"; break; }
        [[ "$co" == root && "$cm" =~ ^[0-7]+$ ]] && (( (8#$cm & 8#022) == 0 )) || { root_ok=0; break; }
        [[ "$cd" == / ]] && break
        cd=$(dirname "$cd")
      done
      if [[ $root_ok -eq 0 && -z "$why_no" ]]; then
        if runuser -u "$ORACLE_USER" -- test -w "$anc" 2>/dev/null; then mk_ora=1
        else why_no="under $cd, which users other than root can change"; fi
      fi
    fi
    local out_sys=0; [[ -n "$why_no" ]] && out_sys=1
    case "$out_sys" in 1)
        PLAN="-- $out is $why_no: it must not be the audit folder."$'\n'"-- Change audit_file_dest in the spfile of $STANDBY_SID to a folder under $ORACLE_BASE (for example"$'\n'"-- $(adump_dir)), then answer r." ;;
      *) if [[ -n "$broken" || -e "$out" || -L "$out" ]] && [[ ! -d "$out" ]]; then
           PLAN="-- $out is there, but it is not a folder (a file or a broken link). Check what it is:  ls -l $out"$'\n'"-- Change audit_file_dest in the spfile to a folder under $ORACLE_BASE. Then answer r."
         elif [[ -e "$out" ]]; then
           PLAN="-- $out exists, but $ORACLE_USER cannot write to it. Check who owns it and why:  ls -ld $out"$'\n'"-- Give $ORACLE_USER write access only if the folder is meant for this database,"$'\n'"-- or change audit_file_dest in the spfile. Then answer r."
         elif [[ $mk_ora -eq 1 ]]; then
           MANUAL_HOW="$ORACLE_USER"
           PLAN="-- The script does not create a folder outside $ORACLE_BASE that comes from the spfile."$'\n'"-- As $ORACLE_USER (not as root: users other than root can change $cd):"$'\n'"mkdir -p $out"$'\n'"-- (or change audit_file_dest in the spfile). Then answer r."
         else
           PLAN="-- The script does not create a folder outside $ORACLE_BASE that comes from the spfile."$'\n'"mkdir -p $out"$'\n'"chown $ORACLE_USER:$INSTALL_GROUP $out"$'\n'"-- (or change audit_file_dest in the spfile). Then answer r."
         fi ;;
    esac
    return 1
  fi
  if [[ ${#I71[@]} -eq 0 ]]; then NOW="The folders exist:"$'\n'"${have%$'\n'}"; return 0; fi
  I71_TODO=("${I71[@]}")
  NOW="Missing, or not writable by $ORACLE_USER:"$'\n'"$(printf '  %s\n' "${I71[@]}")"
  [[ -n "$out" ]] && NOW+=$'\n'"Also $out (audit_file_dest of the spfile, outside $ORACLE_BASE): the check after this action shows how to make it."
  PLAN="Create them with owner $ORACLE_USER:$INSTALL_GROUP"$'\n'"The audit folder is the one the standby uses (the copy in step 8.2 sets audit_file_dest to it;"$'\n'"a standby that exists already uses the audit_file_dest of its spfile, also checked);"$'\n'"the diagnostic folder is diagnostic_dest of the primary."
  return 1
}
d_7_1() {
  local d o
  for d in "${I71_TODO[@]}"; do
    make_dir "$d" "$ORACLE_USER" || return 1
    # an existing folder that is not empty keeps its owner (nothing in it is changed): said here, by name
    if ! runuser -u "$ORACLE_USER" -- test -w "$d"; then
      o=$(stat -c '%U:%G %a' -- "$d" 2>/dev/null)
      bad "$d is not writable by $ORACLE_USER (owner and mode: ${o:-unknown}). It is not empty, so the script does not change it."
      printf 'Give it to %s, for example (as root):
  chown %s:%s %s
' "$ORACLE_USER" "$ORACLE_USER" "$INSTALL_GROUP" "$d" | hint
      return 1
    fi
  done
}

# ---- 7.7 oratab ----
c_7_7() {
  local cur; cur=$(grep -E "^${STANDBY_SID}:" /etc/oratab 2>/dev/null | head -n 1)
  if [[ "$cur" == "$STANDBY_SID:$DB_HOME:"* ]]; then NOW="/etc/oratab has the line for $STANDBY_SID:"$'\n'"  $cur"; return 0; fi
  if [[ -n "$cur" ]]; then
    local yn; yn=$(cut -d: -f3 <<< "$cur"); [[ "$yn" =~ ^[YNyn]$ ]] || yn=N
    NOW="/etc/oratab has another home for $STANDBY_SID:"$'\n'"  $cur"
    PLAN="Change that line in /etc/oratab to (a backup is kept):"$'\n'"  $STANDBY_SID:$DB_HOME:$yn"
    oratab_link_plan
    return 1
  fi
  NOW="/etc/oratab has no line for $STANDBY_SID. oraenv and dbstart need it."
  PLAN="Add this line to /etc/oratab (a backup is kept):"$'\n'"  $STANDBY_SID:$DB_HOME:N"
  oratab_link_plan
  return 1
}
oratab_file() {
  # the file to write: /etc/oratab, or the file a safe link points to (empty: a link that is not safe)
  if [[ -L /etc/oratab ]]; then safe_link_target /etc/oratab || true; else printf '/etc/oratab'; fi
}
oratab_link_plan() {
  # a link is written through only when it is safe (safe_link_target); else the line is set by hand
  [[ -L /etc/oratab ]] || return 0
  local t; t=$(readlink -f /etc/oratab 2>/dev/null)
  if [[ -n "$(oratab_file)" ]]; then NOW+=$'\n'"/etc/oratab is a link to $t (owned by root, in folders only root can change): that file is changed."; return 0; fi
  NOW+=$'\n'"/etc/oratab is a link to ${t:-a missing file}. The script does not write through it:"$'\n'"the link or a folder above the file can be changed by a user other than root, or the file is missing."
  PLAN="-- Edit the file the link points to:  ${t:-/etc/oratab}"$'\n'"-- The line for $STANDBY_SID must be:"$'\n'"$STANDBY_SID:$DB_HOME:${yn:-N}"$'\n'"-- Then answer r."
  KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
}
d_7_7() {
  local f; f=$(oratab_file); [[ -n "$f" ]] || { bad "/etc/oratab is a link that is not safe to write through."; return 1; }
  local new=0; [[ -f "$f" ]] || new=1
  backup_file "$f" || return 1
  if [[ $new -eq 0 ]] && grep -qE "^${STANDBY_SID}:" "$f"; then
    # only the line of this SID changes (its Y/N stays); written in place, so owner, mode and label stay
    local tmp; tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
    awk -F: -v sid="$STANDBY_SID" -v home="$DB_HOME" 'BEGIN { OFS = ":" } $1 == sid && !done { $2 = home; if ($3 !~ /^[YNyn]$/) $3 = "N"; done = 1 } { print }' "$f" > "$tmp" || return 1
    cat -- "$tmp" > "$f" || { [[ -f "$f.bak_$RUN_ID" ]] && cat -- "$f.bak_$RUN_ID" > "$f"; bad "$f could not be written. The old content was put back."; return 1; }
    rm -f -- "$tmp"
    journal_file_written "$f" 1
    return 0
  fi
  printf '%s:%s:N' "$STANDBY_SID" "$DB_HOME" | append_as root "$f" || return 1
  # a new file gets the usual owner; an existing one (Grid makes it) keeps its owner
  [[ $new -eq 1 ]] && { chown root:"$INSTALL_GROUP" "$f"; chmod 664 "$f"; }
  return 0
}

# ---- 7.2 ----
pfile_text() {
  printf "*.db_name='%s'\n*.db_unique_name='%s'\n" "$DB_NAME" "$STANDBY_UNIQUE"
  [[ "$PRIMARY_CDB" == "YES" ]] && printf '*.enable_pluggable_database=true\n'
  return 0
}
c_7_2() {
  L72_CLEAN=""; L72_MOUNTCHECK=0
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
        cleanup_offer spfile && return 1
        NOW+=$'\n'"The script cannot clean this up ($CL_WHY)."; return 2
      fi
      # NOMOUNT from the pfile, but a copy that did not finish left files a new copy would not overwrite
      if [[ -f "$STATE_DIR/dup_attempt" && ! -f "$STATE_DIR/existing_files_ok" ]] && ! copy_finished; then
        local ol; ol=$(orphan_leftovers)
        if [[ -n "$ol" ]]; then
          NOW="Instance $STANDBY_SID is in NOMOUNT, but files of an unfinished copy are still here:"$'\n'"$ol"
          cleanup_offer keep && return 1
          # known leftovers are never passed over in silence: the way by hand, as in the other branches
          cleanup_cannot; return 2
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
      if [[ $sc -eq 0 ]]; then STANDBY_BUILT=1; NOW="The standby database already exists ($LSTATE, PHYSICAL STANDBY). No copy is needed."; [[ "$SC_INFO" == Accepted:* ]] && NOW+=$'\n'"$SC_INFO"; return 0; fi
      if [[ $sc -eq 2 ]]; then NOW="Cannot compare the standby with the primary: $SC_INFO"; return 2; fi
      NOW="A standby control file exists, but the database is incomplete, probably from a failed copy:"$'\n'"$SC_INFO"
      cleanup_offer mounted && return 1
      NOW+=$'\n'"The script cannot clean this up ($CL_WHY)."; return 2 ;;
    IDLE)
      if [[ -f "$(dup_marker)" && -f "$(spfile_path)" ]]; then
        STANDBY_BUILT=1
        NOW="The standby database exists (the copy finished). Step 9.2 starts it."$'\n'"Recorded as built, not checked now: its files are checked when it is mounted."
        return 0
      fi
      # a standby spfile without the record of a finished copy: maybe a standby made by hand (or by another tool).
      # It is mounted once to be compared with the primary (a complete one is accepted, an incomplete one is a
      # failed copy and is offered for the clean-up)
      if [[ -f "$(spfile_path)" && ! -f "$STATE_DIR/dup_attempt" && "${L72_MOUNTED_ONCE:-0}" -eq 0 ]]; then
        NOW="Instance $STANDBY_SID is not started, and a standby spfile exists that this script did not make:"$'\n'"$(spfile_path)"
        PLAN="Start the instance in MOUNT with that spfile, to see whether it is a complete standby."$'\n'"A complete one is used as it is (no copy); an incomplete one is offered for the clean-up."
        cp_add oracle "sqlplus -S / as sysdba" "startup mount"
        L72_MOUNTCHECK=1
        return 1
      fi
      # files of a copy that was interrupted (reboot, kill): they are named, never removed by the script
      local lo; lo=$(leftover_files)
      if [[ -n "$lo" && ! -f "$STATE_DIR/existing_files_ok" ]]; then
        NOW="Instance $STANDBY_SID is not started, and files already exist where the standby database will be written:"$'\n'"$lo"
        cleanup_offer keep && return 1
        cleanup_cannot; return 2
      fi
      NOW="Instance $STANDBY_SID is not started"
      PLAN="Write this pfile:
  $(pfile_path)
with these lines:
$(pfile_text | sed 's/^/  /')
Start the instance as $ORACLE_USER:
  startup nomount pfile='$(pfile_path)'"
      return 1 ;;
    HUNG) NOW="$(hung_text)"$'\n'"Run step 9.2 to stop it (shutdown abort):  $SELF --from 9.2"; return 2 ;;
    *) NOW="Cannot read the state of the instance on this server ($(ora_errors "$SQL_OUT"))"; return 2 ;;
  esac
}
# ---- the clean-up of a copy that did not finish ----
# Offered as:  [y] Clean up for me   [m] Show the commands   [s] Skip   [q] Quit
#   y  the script checks once that this is the standby (host name, address, the instance's db_unique_name), lists
#      what goes (with sizes), asks for the word CLEAN, then runs the shown commands
#   m  the same commands in a short script file (one host check at its top); you type one short line to run it
# Removed: the standby's own folders in ASM (+DG/<standby unique name>), the OMF folder of the standby, and with the
# primary's paths ("same") the files of the copy at those paths, only when step 2.15 proved that the folders are
# storage of this server. Renamed: the spfile of the failed copy. Never touched: init<SID>.ora, orapw<SID>, and
# anything of the primary's own name.
L72_CLEAN=""; L72_AUTO=0; CL_TEXT=""; CL_UNREAD=""; CL_WHY=""
clean_collect() {
  # fills the command list (cp_add) and CL_TEXT (what goes, with sizes); 1 = nothing to clean
  # CL_UNREAD: places that could not be read (never taken as "nothing there"; no clean-up for me then)
  local dg f n=0 sz total=0 d seen=" "
  CL_TEXT=""; CL_UNREAD=""
  local_state
  if [[ "$LSTATE" != "IDLE" && "$LSTATE" != "NOSW" ]]; then
    cp_add oracle "sqlplus -S / as sysdba" "shutdown abort"
    CL_TEXT+="  stop the instance $STANDBY_SID (shutdown abort)"$'\n'
  fi
  if [[ -f "$(spfile_path)" ]]; then
    cp_add oracle "mv -f $(spfile_path) $(spfile_path).failed_$RUN_ID"
    CL_TEXT+="  rename $(spfile_path) to $(basename "$(spfile_path)").failed_$RUN_ID"$'\n'
  fi
  for dg in $(asm_dgs); do
    grid_sw_ok || { CL_UNREAD+="  +$dg/${STANDBY_UNIQUE^^}  (Grid is not installed here, ASM cannot be read)"$'\n'; continue; }
    if ! sql_asm "select count(*) from v\$asm_alias a, v\$asm_diskgroup g where a.group_number=g.group_number and g.name=upper('$dg') and upper(a.name)=upper('$STANDBY_UNIQUE') and a.parent_index=a.group_number*16777216;" || ! num "$(first_line)"; then
      CL_UNREAD+="  +$dg/${STANDBY_UNIQUE^^}  (cannot read ASM: $(ora_errors "$SQL_OUT"))"$'\n'; continue
    fi
    [[ "$(first_line)" != "0" ]] || continue
    # the size of the files under the standby's folder only (the folder tree, each file once)
    sz=""; sql_asm "select round(nvl(sum(f.bytes),0)/1048576) from v\$asm_file f, (select distinct group_number, file_number from v\$asm_alias where alias_directory='N' start with upper(name)=upper('$STANDBY_UNIQUE') and parent_index=group_number*16777216 and group_number in (select group_number from v\$asm_diskgroup where name=upper('$dg')) connect by prior reference_index=parent_index and prior group_number=group_number) a where f.group_number=a.group_number and f.file_number=a.file_number;" && sz=$(first_line)
    cp_add grid "asmcmd rm -rf +$dg/${STANDBY_UNIQUE^^}"
    CL_TEXT+="  +$dg/${STANDBY_UNIQUE^^}  (ASM folder of the standby$(num "$sz" && printf ', about %s' "$(human_mb "$sz")"))"$'\n'
  done
  # OMF folders of the standby in folders here (named after the standby: never the primary's)
  for d in $( [[ "$(place_mode)" == dir ]] && data_dest; f=$(fra_dest); [[ "$f" == /* ]] && printf '%s\n' "$f"; [[ "$(place_mode)" == same ]] && omf_dir_here ); do
    # each folder once (the recovery area may be the data folder)
    d=${d%/}; [[ -n "$d" && "$seen" != *" $d "* ]] || continue; seen+="$d "
    [[ -d "$d/${STANDBY_UNIQUE^^}" ]] || continue
    sz=$(du -sm -- "$d/${STANDBY_UNIQUE^^}" 2>/dev/null | cut -f1)
    # never into another file system mounted below it
    cp_add oracle "rm -rf --one-file-system $d/${STANDBY_UNIQUE^^}"
    CL_TEXT+="  $d/${STANDBY_UNIQUE^^}/  (OMF folder of the standby, $(human_mb "${sz:-0}"))"$'\n'
  done
  # the primary's paths: the files of the copy have the same names as the primary's own files; only on storage
  # that step 2.15 proved to be this server's
  if [[ "$(place_mode)" == same && -n "$(fs_dirs)" ]] && ! sql_or_cached_filenames; then
    # names not read: the files (and an OMF folder) at the primary's paths are not known, never "none"
    [[ $FS_READ_FAIL -eq 1 ]] && CL_UNREAD+="  files of the copy at the primary's paths in $(fs_dirs | paste -sd' ' -)  (the primary's file names cannot be read)"$'\n'
  elif [[ "$(place_mode)" == same && -n "$(fs_dirs)" ]]; then
    if [[ "${STORAGE_SRC:-2}" -eq 0 ]]; then
      while IFS= read -r f; do
        [[ "$f" =~ ^/[A-Za-z0-9_./-]+$ && -f "$f" ]] || continue
        sz=$(stat -c '%s' -- "$f" 2>/dev/null); num "$sz" || sz=0
        cp_add oracle "rm -f $f"; n=$((n + 1)); total=$((total + sz / 1048576))
        [[ $n -le 8 ]] && CL_TEXT+="  $f  ($(human_mb $((sz / 1048576))))"$'\n'
      done <<< "$FS_FILENAMES"
      [[ $n -gt 8 ]] && CL_TEXT+="  ... and $((n - 8)) more files (all $n: $(human_mb "$total"))"$'\n'
    else
      CL_FS_UNPROVEN=1
    fi
  fi
  [[ -f "$(dup_marker)" ]] && cp_add oracle "rm -f $(dup_marker)"
  [[ -n "$CL_TEXT" ]]
}
cleanup_offer() {
  # $1 spfile | keep | mounted: sets the plan for d_7_2 (KIND_NOW=ask). 1 = nothing the script may offer (CL_WHY)
  CL_FS_UNPROVEN=0; CL_UNREAD=""
  CL_WHY="STANDBY_UNIQUE must differ from the primary's names"
  [[ -n "$STANDBY_UNIQUE" && "${STANDBY_UNIQUE^^}" != "${PRIMARY_UNIQUE^^}" && "${STANDBY_UNIQUE^^}" != "${DB_NAME^^}" ]] || return 1
  cp_reset
  if ! clean_collect; then
    cp_reset
    CL_WHY="it found nothing here that it may remove"
    [[ $CL_FS_UNPROVEN -eq 1 ]] && CL_WHY="step 2.15 has not proven that $(fs_dirs | paste -sd' ' -) is storage of this server only"
    if [[ -n "$CL_UNREAD" ]]; then
      if [[ $CL_FS_UNPROVEN -eq 1 ]]; then CL_WHY+="; not checked:"; else CL_WHY="these could not be read:"; fi
      CL_WHY+=$'\n'"${CL_UNREAD%$'\n'}"
    fi
    return 1
  fi
  L72_CLEAN=$1
  # [y] only for the leftovers of a copy THIS script started and that did not finish (else the files may be a
  # complete standby, or an older database with the same name: then [m] writes the commands, you decide)
  L72_AUTO=0
  [[ -f "$STATE_DIR/dup_attempt" && ! -f "$(dup_marker)" ]] && L72_AUTO=1
  # files at the primary's paths that you once allowed to stay (existing_files_ok) may be of another database:
  # then the script does not remove them itself
  [[ "$(place_mode)" == same && -n "$(fs_dirs)" && -f "$STATE_DIR/existing_files_ok" ]] && L72_AUTO=0
  # a place that could not be read may hold more of the copy: only the commands to read and run yourself
  [[ -n "$CL_UNREAD" ]] && L72_AUTO=0
  PLAN="Clean up what the unfinished copy left on this server:"$'\n'"${CL_TEXT%$'\n'}"
  PLAN+=$'\n'"Kept: $(basename "$(pfile_path)"), orapw$STANDBY_SID. Then the instance starts again from the pfile (NOMOUNT)."
  [[ -n "$(asm_dgs)" ]] && PLAN+=$'\n'"Never touched: $(asm_dgs | sed "s#^#+#; s#\$#/${PRIMARY_UNIQUE^^}#" | paste -sd' ' -) (the primary's names)"
  [[ $CL_FS_UNPROVEN -eq 1 ]] && PLAN+=$'\n'"Not removed: files at the primary's paths in $(fs_dirs | paste -sd' ' -). Step 2.15 has not proven that this is storage of this server only."
  [[ -n "$CL_UNREAD" ]] && PLAN+=$'\n'"Not checked (could not be read; check them by hand, they are not in the commands):"$'\n'"${CL_UNREAD%$'\n'}"
  if [[ "$(dup_cause)" == FRA_FULL ]]; then
    PLAN+=$'\n'"The copy failed because the recovery area was full ($(human_mb "$(fra_full_mb)"))."
    PLAN+=$'\n'"The next copy gets $(human_mb "$(fra_size_mb)") in $(fra_dest) (step 8.1 checks the space first), and step 8.2 copies again."
  fi
  KIND_NOW=ask
  return 0
}
cleanup_cannot() {
  # leftovers are known, but cleanup_offer has nothing to offer (CL_WHY): said, with the way by hand
  NOW+=$'\n'"The script cannot clean this up: $CL_WHY."
  NOW+=$'\n'"By hand, after checking that they belong to the unfinished copy:"
  [[ -n "$(asm_dgs)" ]] && NOW+=$'\n'"  an ASM folder, as $GRID_USER:  asmcmd rm -rf <folder>"
  NOW+=$'\n'"  a folder, as $ORACLE_USER:  rm -rf --one-file-system <folder>      a file:  rm -f <file>"
  NOW+=$'\n'"Or keep them (RMAN overwrites files with the same names):  touch $STATE_DIR/existing_files_ok"
  NOW+=$'\n'"Then run step 7.2 again:  $SELF --from 7.2"
}
cleanup_proof() {
  # once, right before anything is removed: this is the standby server and its instance
  # host names compared without the domain and without case (STANDBY_HOST may be the full name); an empty one fails
  local ls lsh sh; ls=$(hostname -s 2>/dev/null); lsh=${ls%%.*}; sh=${STANDBY_HOST%%.*}
  [[ -n "$lsh" && "${lsh,,}" == "${sh,,}" ]] || { bad "This server is $ls, not $STANDBY_HOST. Nothing was removed."; return 1; }
  is_local_ip "$STANDBY_IP" || ! command -v ip >/dev/null 2>&1 || { bad "$STANDBY_IP is not an address of this server. Nothing was removed."; return 1; }
  [[ "${STANDBY_UNIQUE^^}" != "${PRIMARY_UNIQUE^^}" ]] || { bad "Safety stop: STANDBY_UNIQUE equals the primary's unique name. Nothing was removed."; return 1; }
  local_state
  if [[ "$LSTATE" != "IDLE" && "$LSTATE" != "NOSW" ]]; then
    sql_local "select upper(value) from v\$parameter where name='db_unique_name';" || { bad "Cannot read the running instance ($(ora_errors "$SQL_OUT")). Nothing was removed."; return 1; }
    [[ "$(first_line)" == "${STANDBY_UNIQUE^^}" ]] || { bad "The running instance $STANDBY_SID has db_unique_name $(first_line), not ${STANDBY_UNIQUE^^}. Nothing was removed."; return 1; }
    if [[ "$LSTATE" == MOUNTED || "$LSTATE" == OPEN ]]; then
      sql_local "select database_role from v\$database;" && [[ "$(first_line)" == "PHYSICAL STANDBY" ]] || { bad "The mounted database here is not a physical standby. Nothing was removed."; return 1; }
    fi
  fi
  say "Checked: this is $ls ($STANDBY_IP), the standby ${STANDBY_UNIQUE^^}."
  return 0
}
cleanup_id_text() {
  # the [m] file's own check of the instance it stops (as cleanup_proof does for [y]): a running instance must have
  # db_unique_name STANDBY_UNIQUE, and a mounted or open one the role PHYSICAL STANDBY (never a primary). No
  # instance running (ORA-01034) passes; any other answer refuses.
  local t=""
  IFS= read -r -d '' t <<'EOF' || true
dgid=$(runuser -u @OU@ -- env -i HOME=/ LANG=C ORACLE_HOME=@OH@ ORACLE_SID=@SID@ PATH=@OH@/bin:/usr/bin:/bin timeout 120 sqlplus -S -L / as sysdba 2>&1 <<'SQLEOF'
set heading off feedback off pagesize 0 linesize 300 trimout on
select 'DGID|'||i.status||'|'||upper(p.value) from v$instance i, v$parameter p where p.name='db_unique_name';
select 'DGROLE|'||database_role from v$database;
exit
SQLEOF
)
case "$dgid" in
  *"DGID|"*)
    dgs=$(sed -n 's/^DGID|\([^|]*\)|.*/\1/p' <<< "$dgid" | head -n 1); dgu=$(sed -n 's/^DGID|[^|]*|//p' <<< "$dgid" | head -n 1)
    [ "$dgu" = "@SU@" ] || { echo "The running instance @SID@ has db_unique_name $dgu, not @SU@. Nothing was done."; exit 1; }
    [ "$dgs" = STARTED ] || grep -qx 'DGROLE|PHYSICAL STANDBY' <<< "$dgid" || { echo "The database mounted here is not a physical standby. Nothing was done."; exit 1; } ;;
  *ORA-01034*|*ORA-27101*) ;;
  *) echo "Cannot read the instance @SID@. Nothing was done."; exit 1 ;;
esac
EOF
  t=${t%$'\n'}; t=${t//@OU@/$ORACLE_USER}; t=${t//@OH@/$DB_HOME}; t=${t//@SID@/$STANDBY_SID}; t=${t//@SU@/${STANDBY_UNIQUE^^}}
  printf '%s\n' "$t"
}
cleanup_script() {
  # [m]: the commands as a short script file; prints its path. Besides the host check it refuses to run if a copy
  # finishes after this file was written (no record then: once any record appears; a record already there: once it
  # is newer than the file). When a finished copy was already recorded, running it is the DBA's decision ([m] only).
  # It also checks the running instance it stops (cleanup_id_text).
  local guard
  if [[ -e "$(dup_marker)" ]]; then guard="[ %s -nt \"\$0\" ]"; else guard="[ -e %s ]"; fi
  { printf "$guard"' && { echo "A copy has finished since this file was written: these are the files of the standby now. Nothing was done."; exit 1; }\n' "$(dup_marker)"
    cleanup_id_text
    cp_script_text; } | short_script "c72"
}
d_7_2_cleanup() {
  # 0 = cleaned (or kept), 3 = not now
  local opts="[y] Clean up for me   [m] Show the commands   [s] Skip   [q] Quit" allowed="ymsq" f
  if [[ $L72_AUTO -ne 1 ]]; then
    opts="[m] Show the commands   [s] Skip   [q] Quit"; allowed="msq"
    if [[ -n "$CL_UNREAD" ]]; then say "${C_D}Some places could not be read (see the list), so the script does not remove these files itself.${C_N}"
    else say "${C_D}The script did not start this copy (or it finished), so it does not remove these files itself.${C_N}"; fi
  fi
  [[ "$L72_CLEAN" == keep && -f "$STATE_DIR/dup_attempt" ]] && { opts+="   [k] Keep them"; allowed+="k"; }
  while true; do
    ask_choice "$opts" "$allowed"
    case "$ANSWER" in
      q) user_stop "Stopped by you" ;;
      s) L72_CLEAN=""; return 3 ;;
      k) install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/existing_files_ok"; say "The files stay. RMAN overwrites files with the same names."; return 0 ;;
      m) if f=$(cleanup_script); then
           printf '%s\n' "${CL_TEXT%$'\n'}" | block "It removes:"
           { printf '# as root, on this server (%s):\n' "$(hostname -s)"; printf '%s\n' "$f"; } | print_commands "Run on this server ($(hostname -s))" "root"
           say "The file checks the host name first. To read it:  less $f"
           say "Then answer r here."
         else bad "The script file could not be written in $SHORT_DIR."; fi
         ask_choice "[r] Check again   [s] Skip   [q] Quit" "rsq"
         case "$ANSWER" in r) L72_CLEAN=""; return 4 ;; s) L72_CLEAN=""; return 3 ;; q) user_stop "Stopped by you" ;; esac ;;
      y) cleanup_proof || return 1
         printf '%s\n' "${CL_TEXT%$'\n'}" | block "Removed now:"
         confirm_word "Remove these files of the unfinished copy on THIS server ($(hostname -s))." "CLEAN" || { L72_CLEAN=""; return 3; }
         # each change is journaled after it was done (a command that failed, and those after it, leave no entry)
         local i nf=0
         for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
           if ! cp_exec "$i"; then
             bad "This command failed:  $(head -n 1 <<< "${CP_CMD[$i]}" | mask_pw)"$'\n'"$(tail -n 4 <<< "$RUN_OUT" | mask_pw)"
             [[ $((i + 1)) -lt ${#CP_CMD[@]} ]] && say "The commands after it were not run."
             [[ $nf -gt 0 ]] && journal DELETED "$STANDBY_UNIQUE" "cannot be undone: $nf file(s) of the unfinished copy at the primary's paths, after you typed CLEAN"
             return 1
           fi
           case "${CP_CMD[$i]}" in
             "mv -f $(spfile_path) "*) journal RENAME "$(spfile_path)" "to=$(spfile_path).failed_$RUN_ID" ;;
             "asmcmd rm -rf "*|"rm -rf "*) journal DELETED "${CP_CMD[$i]##* }" "cannot be undone: files of the unfinished copy, after you typed CLEAN" ;;
             "rm -f $(dup_marker)") ;;
             "rm -f "*) nf=$((nf + 1)) ;;
           esac
         done
         [[ $nf -gt 0 ]] && journal DELETED "$STANDBY_UNIQUE" "cannot be undone: $nf file(s) of the unfinished copy at the primary's paths, after you typed CLEAN"
         _log CHANGE "clean-up of the unfinished copy done on $(hostname -s)"
         rm -f -- "$STATE_DIR/existing_files_ok"
         return 0 ;;
    esac
  done
}

d_7_2() {
  if [[ ${L72_MOUNTCHECK:-0} -eq 1 ]]; then
    L72_MOUNTCHECK=0
    journal INSTANCE "$STANDBY_SID" "startup mount (to compare the standby with the primary)"
    # mounted once per run (a standby that is down again later is not mounted again and again); a mount that
    # failed and left nothing running does not use up that one try
    if ! cp_run; then local_state; [[ "$LSTATE" == IDLE ]] || L72_MOUNTED_ONCE=1; return 1; fi
    L72_MOUNTED_ONCE=1
    return 0
  fi
  if [[ -n "$L72_CLEAN" ]]; then
    local crc=0; d_7_2_cleanup || crc=$?
    L72_CLEAN=""
    if [[ $crc -eq 4 ]]; then
      # you ran the script file: what it should have removed must be gone now
      cp_reset; local_state
      if [[ "$LSTATE" != IDLE ]] || clean_collect; then cp_reset; bad "The files of the unfinished copy are still here (or the instance still runs). Run the file, then answer r."; return 1; fi
      # a place that cannot be read is not proof that it is clean
      [[ -z "$CL_UNREAD" ]] || { cp_reset; bad "Cannot check that the files are gone:"$'\n'"${CL_UNREAD%$'\n'}"$'\n'"Answer r when it can be read."; return 1; }
      cp_reset; crc=0
      # done: the file is removed (run again later, it would remove a working standby)
      rm -f -- "$SHORT_DIR/c72"
    fi
    [[ $crc -eq 0 ]] || return $crc
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
  LOGINS_DEFERRED=1; CHECK_WAITS=1      # the step is waiting (not OK) until the logins are really tested
  [[ "$MODE" == "run" && -n "$STATE_DIR" ]] && { install -d -m 700 "$STATE_DIR"; : > "$(logins_flag)"; }
  return 0
}
logins_after_start() {
  # the logins of 7.3, 7.4 and 7.6 that could not be tested in phase 7 (the standby was down) are tested now.
  # 0 = all work, or nothing was deferred; 0 with CHECK_WAITS=1 = a test cannot run now (the calling step waits);
  # 1 = one fails (NOW and PLAN say why)
  [[ $LOGINS_DEFERRED -eq 1 || -f "$(logins_flag)" ]] || return 0
  # a test that cannot run now: this step waits (not OK), so the logins are not forgotten (the flag file stays)
  local keep0=$NOW
  need_ssh || { NOW=$keep0$'\n'"The logins of steps 7.3, 7.4 and 7.6 are not tested yet (no connection to the primary now)."; CHECK_WAITS=1; return 0; }
  local f rc keep_now=$NOW sid keep_cw=$CHECK_WAITS
  # 7.4 and 7.6 need the sys password; a run that started after phase 7 has not asked for it yet
  if [[ -z "$SYS_PW" && "$MODE" == "run" ]]; then
    say "The logins of steps 7.3, 7.4 and 7.6 are tested now. Steps 7.4 and 7.6 need the sys password."
    d_1_5 && record 1.5 DONE
  fi
  local -A lnow=()
  for f in c_7_3 c_7_4 c_7_6; do
    NOW=""; PLAN=""; rc=0; CHECK_WAITS=0; "$f" >/dev/null || rc=$?
    sid=${f#c_}; sid=${sid/_/.}
    # not tested after all (the standby is down again): the steps stay waiting
    if [[ $rc -eq 0 && $CHECK_WAITS -ne 0 ]]; then rc=2; fi
    CHECK_WAITS=$keep_cw
    if [[ $rc -eq 2 ]]; then local why1=${NOW%%$'\n'*}; NOW=$keep_now$'\n'"The logins of steps 7.3, 7.4 and 7.6 are not tested yet. Step $sid cannot be tested now: $why1"; CHECK_WAITS=1; return 0; fi
    lnow[$sid]=$NOW
    if [[ $rc -ne 0 ]]; then
      local why=$PLAN
      NOW="The standby is running, but the login of step $sid fails: $NOW"
      # the explanation is text, not commands: shown as comments
      PLAN=$(printf '%s\n' "${why:-See:  $SELF --help-step $sid}" | sed 's/^/-- /')$'\n'"-- Then answer r."
      return 1
    fi
  done
  LOGINS_DEFERRED=0; rm -f -- "$(logins_flag)"
  # the three steps were recorded as waiting: they are OK now (in this run and in the progress file)
  for sid in 7.3 7.4 7.6; do NOW=${lnow[$sid]}; record "$sid" OK; done
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
DUP_EXTRA=""; PRE_OK=0; PRE_INFO=""; NEWNAMES=""; DUP_SECTION=""

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
  # appends to PRE_INFO; sets PRE_FIX and returns 1 when a place here lacks space. Each place (a disk group, or the
  # file system of a folder) must hold what goes there TOGETHER: the database files (+10 %), the standby logs of
  # step 9.3 and the recovery area (its full size, set as db_recovery_file_dest_size).
  local l d mb key mnt f ff free need short="" sz
  declare -A NEED_DB=() NEED_SRL=() NEED_FRA=() FREE=() THERE=() LABEL=()
  srl_plan_space
  [[ "$(place_mode)" != same && $SRL_MB -gt 0 ]] && SRL_LOC=$(data_dest)
  _sk() {
    # the place of $1: "+DG", or the mount point of an existing folder (KEY); 1 = the folder is missing or unreadable
    if [[ "$1" == +* ]]; then KEY=$(dg_of "$1"); return 0; fi
    [[ -d "$1" ]] || { PRE_FIX="The folder $1 does not exist (step 2.14)"; return 1; }
    KEY=$(mnt_of "$1"); [[ -n "$KEY" ]] || { PRE_FIX="Cannot read the free space of $1 (df)"; return 1; }
    [[ -n "${FREE[$KEY]:-}" ]] || FREE[$KEY]=$(free_mb_of "$1")
    LABEL[$KEY]="File system $KEY"
  }
  local KEY
  while IFS= read -r l; do
    d=${l%%:*}; mb=${l##*:}
    _sk "$d" || return 1
    NEED_DB[$KEY]=$(( ${NEED_DB[$KEY]:-0} + mb ))
  done < <(sb_loc_list)
  if [[ -n "$SRL_LOC" && $SRL_MB -gt 0 ]]; then _sk "$SRL_LOC" || return 1; NEED_SRL[$KEY]=$(( ${NEED_SRL[$KEY]:-0} + SRL_MB )); fi
  f=$(fra_dest)
  if [[ -n "$f" ]]; then _sk "$f" || return 1; NEED_FRA[$KEY]=$(fra_size_mb); fi
  # ASM: usable_file_mb, the space after mirroring. Files of an earlier copy in ASM are NOT counted as free (a new copy
  # creates new OMF files next to them).
  for key in "${!NEED_DB[@]}" "${!NEED_SRL[@]}" "${!NEED_FRA[@]}"; do
    [[ "$key" == +* && -z "${FREE[$key]:-}" ]] || continue
    free=0; sql_asm "select usable_file_mb from v\$asm_diskgroup where name=upper('${key#+}');" && free=$(first_line)
    num "$free" || free=0
    FREE[$key]=$free; LABEL[$key]=$key
  done
  # same paths in folders: files at exactly the target paths (an earlier copy) are overwritten by RMAN, their space
  # counts as free (once per file)
  if [[ "$(place_mode)" == same && -n "$(fs_dirs)" ]] && sql_or_cached_filenames; then
    # (its own variable: f still holds the recovery area for the advice below)
    while IFS= read -r ff; do
      [[ -n "$ff" && -f "$ff" ]] || continue
      mnt=$(mnt_of "$(dirname "$ff")"); [[ -n "${NEED_DB[$mnt]:-}" ]] || continue
      sz=$(stat -c '%s' -- "$ff" 2>/dev/null); num "$sz" || continue
      THERE[$mnt]=$(( ${THERE[$mnt]:-0} + sz / 1048576 ))
    done <<< "$FS_FILENAMES"
  fi
  local seen=" "
  for key in "${!NEED_DB[@]}" "${!NEED_SRL[@]}" "${!NEED_FRA[@]}"; do
    [[ "$seen" == *" $key "* ]] && continue; seen+="$key "
    local ndb=${NEED_DB[$key]:-0} nsrl=${NEED_SRL[$key]:-0} nfra=${NEED_FRA[$key]:-0} parts=""
    need=$(( (ndb + nsrl) * 110 / 100 + nfra ))
    free=$(( ${FREE[$key]:-0} + ${THERE[$key]:-0} ))
    [[ $ndb -gt 0 ]] && parts+="database files $(human_mb "$ndb"), "
    [[ $nsrl -gt 0 ]] && parts+="standby logs $(human_mb "$nsrl"), "
    [[ $nfra -gt 0 ]] && parts+="recovery area $(human_mb "$nfra"), "
    parts=${parts%, }
    if [[ $free -lt $need ]]; then
      short+="${LABEL[$key]}: needs $(human_mb "$need") ($parts, +10 % on the files), has $(human_mb "$free") free. Missing: $(human_mb $((need - free)))."$'\n'
    else
      PRE_INFO+="${LABEL[$key]}: $(human_mb "$free") free, $(human_mb "$need") needed ($parts)"$'\n'
    fi
  done
  [[ -z "$short" ]] && return 0
  PRE_FIX="Not enough space here for the copy:"$'\n'"${short%$'\n'}"
  [[ -n "$f" && -z "${FRA_SIZE:-}" ]] && PRE_FIX+=$'\n'"The recovery area size ($(human_mb "$(fra_size_mb)")) is an estimate: $(fra_size_why)."
  [[ -n "$f" ]] && PRE_FIX+=$'\n'"To use another size or place: $SELF --settings  (FRA_SIZE, FRA_DEST, DATA_DEST)"
  local dg
  for dg in $(asm_dgs); do
    [[ -n "$(orphan_leftovers | grep -F "+$dg/")" ]] && PRE_FIX+=$'\n'"Files of an earlier copy are in +$dg/${STANDBY_UNIQUE^^}. Removing them frees space (step 7.2: $SELF --from 7.2)."
  done
  [[ "$short" == +* || "$short" == *$'\n'+* ]] && PRE_FIX+=$'\n'"To add a disk to a disk group: $SELF --from 2.13 shows the ASM disks; then step 3.5."
  return 1
}

dup_prechecks() {
  # read-only. Sets PRE_OK, PRE_INFO (lines), PRE_FIX, DUP_EXTRA, CF_LIST, DEST_N, NEWNAMES.
  PRE_OK=0; PRE_INFO=""; PRE_FIX=""; DUP_EXTRA=""; CF_LIST=""; NEWNAMES=""
  local_state
  [[ "$LSTATE" == "STARTED" ]] || { PRE_FIX="The standby instance must be in NOMOUNT, but it is $LSTATE (step 7.2)"; return 1; }
  if spfile_from_failed_copy; then PRE_FIX="The instance runs from the spfile of an unfinished copy. Clean up first (step 7.2)"; return 1; fi
  # the software here must be the primary's release, the same test as step 3.11 (--from 8.1 does not need 3.11 to
  # have passed). A patch difference is only reported: patching the standby first (standby-first) is supported.
  local rel wr bad_rel=""; rel=$(local_release || true); wr=$(want_rel)
  [[ -n "$rel" && -n "$wr" ]] || { PRE_FIX="The release of the database software here (sqlplus -V) or of the primary could not be read (step 3.11)"; return 1; }
  if [[ "$DB_MAJOR" == "12" ]]; then [[ "$rel" == "$wr" ]] || bad_rel="release $rel here, release $wr on the primary"
  else [[ "${rel%%.*}" == "$DB_MAJOR" ]] || bad_rel="release $rel here, release $DB_MAJOR on the primary"; fi
  [[ -z "$bad_rel" ]] || { PRE_FIX="The database software here is another release: $bad_rel."$'\n'"The standby must have the same release as the primary (step 3.11)."; return 1; }
  # (the Release Update is one of these patch ids too)
  local pp lp pdiff
  if pp=$(primary_patches "$DB_HOME") && lp=$(local_patches "$DB_HOME"); then
    pdiff=$(comm -3 <(printf '%s\n' "$pp" | grep -v '^$') <(printf '%s\n' "$lp" | grep -v '^$') | tr -d '\t' | paste -sd' ' -)
    if [[ -n "$pdiff" ]]; then PRE_INFO+="Warning: the patches of $DB_HOME differ from the primary ($pdiff; step 10.6 shows them). Allowed: a standby may be patched first."$'\n'
    else PRE_INFO+="Release $rel; the patches of $DB_HOME match the primary"$'\n'; fi
  else
    PRE_INFO+="Release $rel; the patches of $DB_HOME were not compared with the primary (an inventory cannot be read)"$'\n'
  fi
  # the disk group of the logs must fit the block size of the primary's redo (else ORA-01378 after the copy, at 9.3)
  if use_grid && grid_sw_ok; then
    # every disk group that gets log files: the data disk group (or db_create_file_dest), the disk groups of
    # the primary's online log members, and db_create_online_log_dest_1..5 (the standby uses the same names)
    # not proven = not passed: an unread block size, an unread list of disk groups, an unread sector size
    [[ ${PRIMARY_REDO_BS_KNOWN:-0} -eq 1 ]] || { PRE_FIX="The redo block size of the primary could not be read, so the disk groups for the logs cannot be checked"; return 1; }
    local ldg ldgs="" pm; pm=$(place_mode)
    if [[ "$pm" == asm ]]; then ldgs=$(data_dest); ldgs=${ldgs#+}       # every log of the standby goes to its data disk group
    elif [[ "$pm" == same ]]; then
      ldgs="$DATA_DG"; [[ "$CFD" == +* ]] && { ldg=$(norm_loc "$CFD"); ldgs=${ldg#+}; }
      if ! prim_sql "select distinct upper(substr(v, 2, decode(instr(v, '/'), 0, length(v), instr(v, '/') - 2))) from (select member v from v\$logfile where member like '+%' union all select value from v\$parameter where name like 'db_create_online_log_dest_%' and value like '+%');"; then
        PRE_FIX="Cannot read on the primary which disk groups hold its logs"; return 1
      fi
      ldgs+=" $(grep -E '^[A-Z0-9_$#]+$' <<< "$SQL_OUT" | tr '\n' ' ')"
    fi
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
  # (a failed query or an answer that is not a value is "could not be read", never "has an spfile")
  prim_sql "select nvl(value,'-') from v\$parameter where name='spfile';" || { PRE_FIX="The spfile setting of the primary could not be read ($(ora_errors "$SQL_OUT"))"; return 1; }
  local spv; spv=$(first_line)
  [[ -n "$spv" && ! "$spv" =~ ^(ORA|SP2)-[0-9] ]] || { PRE_FIX="The spfile setting of the primary could not be read (unexpected answer: $(tr -cd '[:print:]' <<< "${spv:-nothing}"))"; return 1; }
  [[ "$spv" == "-" ]] && { PRE_FIX="The primary runs from a text pfile, but the copy needs its spfile (step 4.1)"; return 1; }
  if [[ -f "$STATE_DIR/dup_attempt" && ! -f "$STATE_DIR/existing_files_ok" ]] && ! copy_finished && [[ -n "$(orphan_leftovers)" ]]; then
    PRE_FIX="Files of an unfinished copy are still on this server. Clean them up first (step 7.2)"; return 1
  fi
  PRE_INFO+="Standby instance $STANDBY_SID is in NOMOUNT"$'\n'
  # TDE settings that could not be read: not known whether the copy needs a wallet (never taken as "no TDE")
  if [[ ${TDE_UNREAD:-0} -eq 1 ]]; then need_ssh && tde_read
    [[ $TDE_UNREAD -eq 0 ]] || { PRE_FIX="The TDE settings of the primary cannot be read${TDE_ERR:+ ($TDE_ERR)} (step 6.3)"; return 1; }
  fi
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
  # force logging (step 4.1); the STANDBY NOLOGGING modes (18c+, set on purpose) are accepted, as in step 10.5
  case "${fl^^}" in
    YES|"STANDBY NOLOGGING"*) ;;
    *) PRE_FIX="FORCE LOGGING is off on the primary (force_logging = ${fl:-unknown}, step 4.1)."$'\n'"NOLOGGING operations would not reach the standby. On the primary:  alter database force logging;"; return 1 ;;
  esac
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
  local mrc=0; mem_probe || mrc=$?
  if [[ $mrc -eq 2 ]]; then
    if [[ "$SQL_OUT" == "MemTotal could not be read"* ]]; then PRE_FIX="The RAM of this server cannot be read ($SQL_OUT)"
    else PRE_FIX="Cannot read the memory parameters of the primary"; fi
    return 1
  fi
  if [[ $mrc -eq 1 ]]; then
    PRE_FIX="$MEM_FAIL"$'\n'"$MEM_INFO"$'\n'"Step 2.16 shows what to do."
    return 1
  fi
  PRE_INFO+="Memory: ${MEM_INFO%%$'\n'*}; this server has $(human_mb "$MEM_RAM_MB")"$'\n'
  [[ -n "$MEM_WARN" ]] && PRE_INFO+="Warning: $MEM_WARN"$'\n'
  if [[ $MEM_HP_LOW -eq 1 ]]; then
    DUP_EXTRA+="      set use_large_pages='TRUE'"$'\n'
    PRE_INFO+="The primary has use_large_pages=ONLY, but this server has too few HugePages."$'\n'"The standby gets TRUE. Configure HugePages later."$'\n'
  fi
  # where the files go (data_dest): one disk group or folder with Oracle-managed names, or the primary's own
  # paths file by file ("same", the only case that needs the names of the primary)
  if [[ "$(place_mode)" != same ]]; then
    local pd; pd=$(data_dest)
    if [[ "$pd" == /* ]]; then
      runuser -u "$ORACLE_USER" -- test -d "$pd" -a -w "$pd" || { PRE_FIX="The folder $pd does not exist here or is not writable by $ORACLE_USER (step 2.14)"; return 1; }
    fi
    PRE_INFO+="Database files go to $(place_text "$pd") with Oracle-managed names: datafiles, tempfiles, control files and logs"$'\n'
    primary_mixed && PRE_INFO+="The primary keeps files in $(primary_where); here all of them go to $pd"$'\n'
    PRE_INFO+="Datafiles added later on the primary are created in $pd too (db_create_file_dest)"$'\n'
  else
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
    local k fno fname odd=""
    while IFS='|' read -r k fno fname; do
      [[ -n "$k$fno$fname" ]] || continue
      # a row without a name is no file (an empty line of the output): not a name to report
      [[ -n "${fname//[[:space:]]/}" ]] || continue
      # a name with other characters cannot be put into the RMAN script safely: said here, before the copy starts
      # (skipped, RMAN would try the primary's own name on this server and fail late in the copy)
      num "$fno" && [[ "$fname" =~ ^[+/][A-Za-z0-9_./-]+$ ]] || { odd+="  $(tr -cd '[:print:]' <<< "$fname")"$'\n'; continue; }
      local what=datafile; [[ "$k" == "T" ]] && what=tempfile
      if [[ "$fname" == +* ]]; then NEWNAMES+="  set newname for $what $fno to '$(norm_loc "$fname")';"$'\n'
      elif [[ "$(basename "$fname")" != o1_mf_* ]]; then NEWNAMES+="  set newname for $what $fno to '$fname';"$'\n'; fi
    done <<< "$SQL_OUT"
    [[ -z "$odd" ]] || { PRE_FIX="File names on the primary with characters the script does not use (only letters, digits and _ . / - are used;"$'\n'"a space, a quote or another sign in a path is refused, as it would break the paths here):"$'\n'"${odd%$'\n'}"$'\n'"Give those files a plain name on the primary, as a planned change: a datafile with"$'\n'"  alter database move datafile '<old name>' to '<new name>';   (online in Enterprise Edition 12c and later;"$'\n'"  for a file of a PDB, first:  alter session set container=<pdb>;)"$'\n'"a tempfile by adding a new one and dropping the old one. Or copy the database by hand with your own RMAN script."; return 1; }
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
    grep -qE '^D\|[0-9]+\|/' <<< "$SQL_OUT" && PRE_INFO+="Datafiles keep the primary's folders. A datafile added later on the primary in a folder needs that folder here too, or apply stops"$'\n'
    if use_grid && [[ -z "$CFD" || "$CFD" == "-" ]] && ! grep -qE '^[DT]\|[0-9]+\|/.*/o1_mf_' <<< "$SQL_OUT"; then
      # datafiles in ASM but no db_create_file_dest: the standby could not create its standby/online logs (ORA-15046).
      # The disk group is the one of the datafiles (never a disk group that only holds the recovery area).
      local ddg; ddg=$(grep -m1 -oE '^D\|[0-9]+\|\+[^/]+' <<< "$SQL_OUT" | cut -d'|' -f3)
      if [[ -n "$ddg" ]]; then
        DUP_EXTRA+="      set db_create_file_dest='$ddg'"$'\n'
        PRE_INFO+="The primary has no db_create_file_dest. The standby gets $ddg, for its redo logs in ASM."$'\n'
      fi
    fi
  fi
  # the standby's own audit folder
  DUP_EXTRA+="      set audit_file_dest='$(adump_dir)'"$'\n'
  # redo transport destination used on primary for this standby (the standby gets the same N back to primary)
  find_dest || { PRE_FIX="Cannot read log_archive_dest_N on the primary"; return 1; }
  p_param log_archive_config || { PRE_FIX="Cannot read log_archive_config of the primary"; return 1; }
  P_DG_CONFIG=$PVAL
  dg_config_names_ok "$P_DG_CONFIG" || { PRE_FIX="log_archive_config of the primary cannot be read safely: $P_DG_CONFIG. Check step 4.3."; return 1; }
  # primary parameters that do not fit the standby
  prim_sql "select name||'|'||value from v\$parameter where value is not null and (name like 'db_create_online_log_dest%' or name like 'log_archive_dest%' or name in ('log_archive_duplex_dest','remote_listener','local_listener','fal_client','db_file_name_convert','log_file_name_convert','dg_broker_start','instance_name','service_names'));" || { PRE_FIX="Cannot read the parameters of the primary"; return 1; }
  local line pname pval known_dgs=" $(asm_dgs | tr '\n' ' ') "
  PRIMARY_OLD_DESTS=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pname=${line%%|*}; pval=${line#*|}
    if [[ "$pname" =~ ^db_create_online_log_dest_([1-5])$ && "$(place_mode)" != same ]]; then
      # the standby's logs go to its own destination (place_spfile_sets sets _1 and clears the others the primary has)
      PRIMARY_OLD_DESTS+=" ${BASH_REMATCH[1]}"
    elif [[ "$pname" =~ ^db_create_online_log_dest_[1-5]$ ]]; then
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
      DUP_EXTRA+="      set dg_broker_start='FALSE'"$'\n'; PRE_INFO+="The primary uses the Data Guard broker. It stays off on the standby until you add it there."$'\n'"Under the broker, set log_archive_dest_N on neither database by hand: clear what steps 4.4 and 9.5"$'\n'"set before ADD DATABASE (else ORA-16698), and let the broker manage transport."$'\n'
    elif [[ "$pname" == "instance_name" && "${pval^^}" != "${STANDBY_SID^^}" ]]; then
      DUP_EXTRA+="      set instance_name='$STANDBY_SID'"$'\n'; PRE_INFO+="instance_name of the primary is $pval. The standby gets $STANDBY_SID."$'\n'
    elif [[ "$pname" == "service_names" ]]; then
      DUP_EXTRA+="      set service_names='$STANDBY_SERVICE'"$'\n'; PRE_INFO+="service_names of the primary is $pval. The standby gets $STANDBY_SERVICE,"$'\n'"so clients of the primary service never reach the standby."$'\n'
    fi
  done <<< "$SQL_OUT"
  # same paths on both servers: MRP tries to clear the online logs and prints ORA-19527/ORA-00312 in the alert
  # log at every start. A convert pair that matches nothing stops that noise (Oracle note 352879.1).
  [[ ${HAS_LFNC:-0} -eq 1 ]] || DUP_EXTRA+="      set log_file_name_convert='/__dg_no_rename__','/__dg_no_rename__'"$'\n'
  # section size: one big datafile (a bigfile tablespace) is otherwise copied by one channel only, however many
  # there are. DUP_SECTION_SIZE: empty = automatic (32G when a datafile is 64 GB or more and there is more than
  # one channel), 0 = never, or a size such as 16G
  DUP_SECTION=""
  if [[ "${DUP_SECTION_SIZE:-}" == "0" ]]; then :
  elif [[ -n "${DUP_SECTION_SIZE:-}" ]]; then DUP_SECTION=$DUP_SECTION_SIZE
  elif [[ $(chan_n "${AUX_CHANNELS:-}" 1) -gt 1 ]]; then
    prim_sql "select round(max(bytes)/1048576) from v\$datafile;" || { PRE_FIX="Cannot read the size of the datafiles of the primary"; return 1; }
    local maxdf; maxdf=$(first_line)
    num "$maxdf" || { PRE_FIX="Unexpected answer for the largest datafile of the primary: $maxdf"; return 1; }
    [[ $maxdf -ge 65536 ]] && DUP_SECTION=32G
  fi
  # sections need backup sets, and those need COMPATIBLE 12.0 or higher (a primary upgraded from 11.2 may keep 11.2)
  if [[ -n "$DUP_SECTION" ]]; then
    p_param compatible || { PRE_FIX="Cannot read compatible of the primary"; return 1; }
    if ! [[ "$PVAL" =~ ^([0-9]+)\. ]] || [[ ${BASH_REMATCH[1]} -lt 12 ]]; then
      if [[ -n "${DUP_SECTION_SIZE:-}" ]]; then PRE_FIX="DUP_SECTION_SIZE is set, but compatible of the primary is $PVAL (sections need 12.0 or higher). Set DUP_SECTION_SIZE=0"; return 1; fi
      PRE_INFO+="compatible of the primary is $PVAL: the copy runs without sections (they need 12.0 or higher)"$'\n'; DUP_SECTION=""
    fi
  fi
  [[ -n "$DUP_SECTION" ]] && PRE_INFO+="Large datafiles are copied in sections of $DUP_SECTION by the $AUX_CHANNELS channel(s) of the copy (DUP_SECTION_SIZE in the settings)"$'\n'
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
  [[ $STANDBY_BUILT -eq 1 ]] && { NOW="The standby database already exists. No copy is needed."; [[ "$SC_INFO" == Accepted:* ]] && NOW+=$'\n'"$SC_INFO"; return 0; }
  [[ $DETECT_RC -eq 2 ]] && { NOW="Cannot tell whether the standby here is complete: $SC_INFO"; return 2; }
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
  root_prog_ok "$GRID_HOME/bin/setasmgidwrap" || return 1
  run_logged "setasmgidwrap" "$GRID_HOME/bin/setasmgidwrap" "o=$DB_HOME/bin/oracle" || { bad "setasmgidwrap failed: ${RUN_OUT%%$'\n'*}"; return 1; }
  journal ASMGID "$DB_HOME/bin/oracle" "by hand, only if wanted, as root: chgrp $PRE_ASMGID_OLD $DB_HOME/bin/oracle ; chmod 6751 $DB_HOME/bin/oracle  (the group it had before)"
  say "$DB_HOME/bin/oracle now has group $(stat -c '%G' "$DB_HOME/bin/oracle" 2>/dev/null)."
  return 0
}

rman_script() {
  # the RMAN text of the copy (no password in it). The channels and the placement of the files come from
  # 22_storage.sh, the parameters from dup_prechecks.
  local d1="" ll="''" ad; ad=$(arch_dest_sb)
  if [[ "$ad" == "USE_DB_RECOVERY_FILE_DEST" ]]; then d1="location=use_db_recovery_file_dest"
  elif [[ -n "$ad" ]]; then d1="location=$ad"; fi
  local dgc; dgc=$(lac_merged "${P_DG_CONFIG:-}")
  # the standby instance registers with its own listener (port of primary)
  [[ "$PORT" != "1521" ]] && ll="'(ADDRESS=(PROTOCOL=TCP)(HOST=$STANDBY_HOST)(PORT=$PORT))'"
  # (each part ends without its last newline after $( ): the lines are put one below the other here)
  local nn; nn=$(place_newname_lines)
  printf 'run {\n%s\n%s  duplicate target database for standby from active database\n' "$(rman_channel_lines)" "${nn:+$nn$'\n'}"
  [[ -n "${DUP_SECTION:-}" ]] && printf '    section size %s\n' "$DUP_SECTION"
  printf '    dorecover\n    spfile\n'
  printf "      set db_unique_name='%s'\n" "$STANDBY_UNIQUE"
  place_spfile_sets
  printf "      set fal_server='%s'\n      set log_archive_config='%s'\n" "$PRIMARY_TNS" "$dgc"
  [[ -n "$d1" ]] && printf "      set log_archive_dest_%s='%s valid_for=(all_logfiles,all_roles) db_unique_name=%s'\n" "${ARCH_N:-1}" "$d1" "$STANDBY_UNIQUE"
  printf "      set log_archive_dest_%s='service=%s async valid_for=(online_logfiles,primary_role) db_unique_name=%s'\n" "${DEST_N:-2}" "$PRIMARY_TNS" "$PRIMARY_UNIQUE"
  printf "      set log_archive_dest_state_%s='enable'\n      set standby_file_management='AUTO'\n      set local_listener=%s\n" "${DEST_N:-2}" "$ll"
  printf '%s    nofilenamecheck;\n}\n' "$DUP_EXTRA"
}

c_8_2() {
  db_sw_ok || { NOW="Database software is not installed (phase 3)"; return 2; }
  need_ssh || return 2
  detect_built
  [[ $STANDBY_BUILT -eq 1 ]] || need_sys || return 2
  [[ $STANDBY_BUILT -eq 1 ]] && { NOW="The standby database exists$(copy_finished && printf ' (the copy finished)')"; [[ -n "$SC_INFO" ]] && NOW+=$'\n'"$SC_INFO"; return 0; }
  # it cannot be told (headers unreadable), or it is no standby at all: never called a failed copy
  [[ $DETECT_RC -eq 2 ]] && { NOW="Cannot tell whether the standby here is complete: $SC_INFO"; return 2; }
  if [[ "$SC_INFO" == *"not a physical standby"* ]]; then NOW="Not copied: $SC_INFO. Nothing here is changed."; return 2; fi
  if [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]]; then
    NOW="A failed or unfinished copy is on this server: $SC_INFO."$'\n'"Clean it up first. Run  $SELF --from 7.2  (step 7.2 offers the clean-up)."
    return 2
  fi
  dup_prechecks || { NOW="The pre-checks did not pass: $PRE_FIX (step 8.1)"; return 2; }
  NOW="The standby instance is in NOMOUNT and all pre-checks passed"
  # the network limits the whole copy: about 100 MB/s on 1 Gbit/s, up to about 1000 MB/s on 10 Gbit/s
  net_speed_read || true
  local est_lo est_hi; est_lo=$(copy_minutes lo); est_hi=$(copy_minutes hi)
  PLAN="Copy the database from the primary with RMAN (active duplicate), as $ORACLE_USER:
  rman target sys@$PRIMARY_TNS auxiliary sys@$STANDBY_TNS
Size to copy: about $(human_mb "$PRIMARY_DB_MB"), with $(prim_channels) channels on the primary and $AUX_CHANNELS on this server
Rough time: $(human_min "$est_lo") to $(human_min "$est_hi") ($(copy_speed_text))
The primary database is only read: nothing is created, dropped or changed in it.
On the primary during the copy: extra disk and network load, log switches,
a snapshot control file in its \$ORACLE_HOME/dbs, and an audit file for each login.
Run the copy when the load is low, for example at night."
  local fd; fd=$(fra_dest)
  USING="RMAN command: duplicate target database for standby from active database
  (dorecover, spfile, nofilenamecheck)
Database files go to: $(place_text "$(data_dest)")
Recovery area: $(place_text "$fd")${fd:+, $(human_mb "$(fra_size_mb)")}
Settings written to the standby spfile:
$(sed -n 's/^      set /  /p' <<< "$(rman_script)")
The full RMAN script is saved first to $LOG_DIR/duplicate_<date>.rman"
  [[ -z "${TMUX:-}${STY:-}" ]] && USING+=$'\n'"The copy runs in its own session: closing the terminal does not stop it."$'\n'"Run the script again to watch it."
  # Grid is here, but files would go to a file system: said before the copy (the confirmation asks)
  if use_grid && grid_sw_ok && [[ -n "$(fs_dirs)" ]]; then
    warn "This server has ASM, but files of the standby go to the file system: $(fs_dirs | paste -sd' ' -)"$'\n'"To put everything into ASM: answer s, then $SELF --settings (DATA_DEST, FRA_DEST)."
  fi
  return 1
}

d_8_2() {
  local pc0 ac0; pc0=$(prim_channels); ac0=$AUX_CHANNELS
  ask_channels || return 3
  # changed now: said again right before the start (the RMAN script is written from the values below)
  [[ "$(prim_channels)/$AUX_CHANNELS" != "$pc0/$ac0" ]] && say "The copy uses $(prim_channels) channels on the primary and $AUX_CHANNELS here (rough time now $(human_min "$(copy_minutes lo)") to $(human_min "$(copy_minutes hi)"))."
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
    # "Finished" in the RMAN output is not the whole proof: the standby itself is looked at first. Only a
    # verified copy gets the "duplicate" marker (otherwise later steps would take the standby as built)
    local vr=0; dup_verify "$rlog" || vr=$?
    # RMAN finished, but the copy is not right: no marker (nothing takes it as built), and no "unfinished copy"
    # record either, so its files are never offered for deletion by the script (the DBA decides; step 7.2 shows
    # the commands)
    if [[ $vr -eq 1 ]]; then rm -f -- "$STATE_DIR/dup_attempt"; return 1; fi
    if [[ $vr -eq 2 ]]; then
      # recorded as a finished copy that is not checked yet: the next look at the mounted standby compares it
      dup_success_record copied
      DONE_MSG="The database was copied (RMAN: Finished Duplicate Db). The new standby could not be checked now; it is compared with the primary at the next check."
      return 0
    fi
    dup_success_record
    DONE_MSG="The database was copied (RMAN: Finished Duplicate Db). $DUP_VERIFIED"
    return 0
  fi
  install -d -m 700 "$STATE_DIR"; : > "$STATE_DIR/dup_attempt"
  RESUME_STEP=7.2; DO_FAIL_STOP_ONLY=1
  local fe; fe=$(rman_first_error "$rlog")
  dup_cause_record "$rlog"
  if [[ "$(dup_cause)" == FRA_FULL ]]; then
    bad "The copy did not finish: the recovery area on this server is full ($(fra_dest), $(human_mb "$(fra_full_mb)"))."
  else
    bad "The copy did not finish (exit code $rc)."
  fi
  {
    [[ -n "$fe" ]] && printf 'First error:\n%s\n' "$(sed 's/^/  /' <<< "$fe")"
    printf 'Full output: %s\n' "$rlog"
    printf 'Common causes:\n'
    printf '  ORA-19809, ORA-19804   the recovery area here is full (db_recovery_file_dest_size)\n'
    printf '  ORA-19504, ORA-17502   a disk group is missing or not mounted\n'
    printf '  ORA-01017              the password files differ (step 6.1)\n'
    printf '  ORA-12528, ORA-12514   listener or tnsnames.ora (phase 5)\n'
    printf '  ORA-15025, ORA-27041   the oracle binary cannot open the ASM disks (setasmgidwrap, step 8.1)\n'
    printf 'Next: run the script again. Step 7.2 offers to clean up this server%s.\n' "$([[ "$(dup_cause)" == FRA_FULL ]] && printf ', with a bigger recovery area (%s), and the copy runs again' "$(human_mb "$(fra_size_mb)")")"
  } | hint
  return 1
}

# ---- the first real error of a failed RMAN run, and its cause ----
rman_first_error() {
  # the frame of the error stack (RMAN-00571, RMAN-00569, "=====") and the general wrappers (RMAN-03002 failure of
  # ... command, RMAN-05501 aborting duplication, RMAN-03009/03015 failure on a channel or a stored script) are
  # skipped, and so are errors that only follow from another one (ORA-19849, ORA-19660/19661/19662 after a failed
  # restore). The first real error is shown with the real errors right after it (ORA-19809 + ORA-19804).
  # Nothing left: the first error that is not part of the frame.
  local out
  out=$(awk '
    /^(RMAN|ORA)-[0-9]+/ {
      code = $0; sub(/:.*/, "", code)
      if (code ~ /^RMAN-0(0571|0569|3002|5501|3009|3015)$/ || code ~ /^ORA-(19849|19660|19661|19662)$/) { if (n) stop = 1; next }
      if (stop) exit
      if (n < 3) { print; n++ }
      next
    }
    n { stop = 1 }' "$1" 2>/dev/null)
  [[ -n "$out" ]] || out=$(grep -E '^(RMAN|ORA)-[0-9]+' "$1" 2>/dev/null | grep -vE '^RMAN-0(0571|0569)' | head -n 1)
  printf '%s' "$out"
}
dup_cause_file() { printf '%s/dup_cause' "$STATE_DIR"; }
dup_cause() { [[ -f "$(dup_cause_file)" ]] && head -n 1 -- "$(dup_cause_file)"; return 0; }
dup_cause_record() {
  # a cause the script can fix itself is recorded for step 7.2 (clean up, fix, copy again)
  rm -f -- "$(dup_cause_file)"
  if grep -qE '^ORA-(19809|19804)' "$1" 2>/dev/null; then
    printf 'FRA_FULL\n' > "$(dup_cause_file)"
    # the size that was full (the next estimate is at least twice that): the limit ORA-19804 names, else the size
    # in the RMAN script of that copy; the estimate of this run only when it is known (a copy that ended unwatched is
    # recorded before the primary is read)
    local b mb="" sz
    b=$(grep -m1 -oE 'from [0-9]+ bytes limit' "$1" 2>/dev/null | grep -oE '[0-9]+')
    num "$b" && mb=$(( b / 1048576 ))
    if [[ -z "$mb" ]]; then
      sz=$(grep -hoE "db_recovery_file_dest_size='[0-9]+[GM]'" "$1" "$(ls -t "$LOG_DIR"/duplicate_*.rman 2>/dev/null | head -n 1)" 2>/dev/null | tail -n 1 | grep -oE '[0-9]+[GM]')
      case "$sz" in *G) mb=$(( ${sz%G} * 1024 )) ;; *M) mb=${sz%M} ;; esac
    fi
    [[ -z "$mb" && -n "${PRIMARY_DB_MB:-}" ]] && mb=$(fra_size_mb)
    num "$mb" && printf '%s\n' "$mb" > "$(fra_full_file)"
  fi
  return 0
}

DUP_VERIFIED=""
dup_verify() {
  # right after the duplicate: mounted, a physical standby, no datafile header error, the datafiles of the primary.
  # 0 = checked; 1 = something is wrong (said why; nothing is removed); 2 = it could not be checked now
  # $1 the RMAN log of the copy (named in the hints)
  local rl=${1:-the RMAN log}
  DUP_VERIFIED=""
  local_state
  # a failed query says nothing about the copy: not checked now (it is compared at the next check)
  [[ "$LSTATE" == "ERROR" ]] && { warn "The new standby could not be read after the copy."; return 2; }
  [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { bad "RMAN reported success, but the standby is not mounted ($LSTATE)."; printf 'See the alert log of %s and:  %s\n' "$STANDBY_SID" "$rl" | hint; return 1; }
  adg_note "$LSTATE"
  sql_local "select database_role from v\$database;" || { warn "The new standby could not be read after the copy ($(ora_errors "$SQL_OUT"))."; return 2; }
  [[ "$(first_line)" == "PHYSICAL STANDBY" ]] || { bad "RMAN reported success, but the database role is $(first_line), not PHYSICAL STANDBY."; return 1; }
  local sc se pc
  sql_local "select (select count(*) from v\$datafile)||'|'||(select count(*) from v\$datafile_header where error is not null) from dual;" || { warn "The datafiles of the new standby could not be read ($(ora_errors "$SQL_OUT"))."; return 2; }
  IFS='|' read -r sc se <<< "$(first_line)"
  num "$sc" && num "$se" || { warn "Unexpected answer when the datafiles were counted ($sc, $se)."; return 2; }
  # header errors are a failed copy whatever the primary says (checked before the primary is read)
  if [[ "$se" != "0" || "$sc" -eq 0 ]]; then
    bad "RMAN reported success, but the standby has $sc datafiles, $se of them with header errors."
    printf 'To see them:  select file#, error from v$datafile_header where error is not null;\nNothing was removed. See the help of step 8.2 before you copy again.\n' | hint
    return 1
  fi
  # the ssh connection may have closed during a long copy: opened again before the primary is read
  need_ssh || { warn "No connection to the primary to compare the datafiles."; return 2; }
  prim_sql "select count(*) from v\$datafile;" || { warn "The datafiles of the primary could not be counted."; return 2; }
  pc=$(first_line); num "$pc" || { warn "Unexpected answer from the primary ($pc)."; return 2; }
  # a different number without header errors = a datafile added or dropped on the primary during the copy;
  # apply follows it (the same rule as for an existing standby)
  [[ "$sc" -ne "$pc" ]] && warn "The standby has $sc datafiles, the primary $pc. A datafile was added or dropped on the primary during the copy; redo apply follows it."
  DUP_VERIFIED="Checked: mounted, physical standby, $sc datafiles (primary $pc), no header errors."
  return 0
}
dup_success_record() {
  # the duplicate finished: marker, the initial pfile out of the way, journal (also when the run was not watching)
  set_marker "${1:-duplicate}"
  rm -f -- "$STATE_DIR/dup_attempt" "$(dup_cause_file)" "$(fra_full_file)"
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
