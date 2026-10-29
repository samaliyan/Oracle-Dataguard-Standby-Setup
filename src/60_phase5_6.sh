#------------------------------------------------------------------------------
# PHASE 5  Network files on this server
#------------------------------------------------------------------------------
lsnr_file() { printf '%s/network/admin/listener.ora' "$(lsnr_home)"; }
tns_file()  { printf '%s/network/admin/tnsnames.ora' "$DB_HOME"; }

static_entry_state() {
  # 0 = correct, 1 = missing, 2 = present with another ORACLE_HOME
  local f; f=$(lsnr_file)
  [[ -f "$f" ]] || return 1
  local flat seg found=1 sidn homen
  flat=$(norm "$(sed 's/#.*//' "$f")")
  sidn="(SID_NAME=${STANDBY_SID^^})"; homen="(ORACLE_HOME=${DB_HOME^^})"
  while IFS= read -r seg || [[ -n "$seg" ]]; do
    if [[ "$seg" == *"$sidn"* ]]; then
      [[ "$seg" == *"$homen"* || "$seg" == *"(ORACLE_HOME=${DB_HOME^^}/)"* ]] && return 0
      found=2
    fi
  done < <(printf '%s' "$flat" | sed 's/(SID_DESC=/\n(SID_DESC=/g')
  return $found
}
lsnr_has_sidlist() { local f; f=$(lsnr_file); [[ -f "$f" ]] && grep -qiE "^[[:space:]]*SID_LIST_${SB_LSNR}[[:space:]]*=" "$f"; }
static_block() {
  printf 'SID_LIST_%s =\n  (SID_LIST =\n    (SID_DESC =\n      (GLOBAL_DBNAME = %s)\n      (SID_NAME = %s)\n      (ORACLE_HOME = %s)\n    )\n  )\n' \
    "$SB_LSNR" "$STANDBY_SERVICE" "$STANDBY_SID" "$DB_HOME"
}

lsnr_desc_block() {
  printf '%s =\n  (DESCRIPTION_LIST =\n    (DESCRIPTION =\n      (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))\n    )\n  )\n' \
    "$SB_LSNR" "$STANDBY_HOST" "$PORT"
}
lsnr_has_desc() { local f; f=$(lsnr_file); [[ -f "$f" ]] && grep -qiE "^[[:space:]]*${SB_LSNR}[[:space:]]*=" "$f"; }

# ---- 5.1 ----
L51_MODE=""
port_owner_pid() {
  # pid of a program that listens on TCP port $1 (empty when nobody does)
  # iproute 3.10 of OL7 < 7.5 prints users:(("tnslsnr",1234,8)); newer ones users:(("tnslsnr",pid=1234,fd=8))
  ss -ltnp "( sport = :$1 )" 2>/dev/null | grep -oE 'users:\(\("[^"]*",(pid=)?[0-9]+' | head -n 1 | grep -oE '[0-9]+$'
}
c_5_1() {
  lsnr_sw_ok || { NOW="The listener software is not installed yet (phase 3)"; return 2; }
  local st=0 f; f=$(lsnr_file)
  # on a server that already runs something else: port $PORT must be free or ours
  local opid oexe; opid=$(port_owner_pid "$PORT")
  if [[ -n "$opid" ]]; then
    oexe=$(readlink "/proc/$opid/exe" 2>/dev/null); oexe=${oexe% (deleted)}
    # both paths resolved (a home under a symbolic link is still our listener)
    if [[ "$(readlink -f -- "$oexe" 2>/dev/null || printf '%s' "$oexe")" != "$(readlink -f -- "$(lsnr_home)/bin/tnslsnr" 2>/dev/null || printf '%s' "$(lsnr_home)/bin/tnslsnr")" ]]; then
      NOW="Port $PORT on this server is used by another program: $oexe (pid $opid)"
      KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
      PLAN="-- The standby listener of $(lsnr_home) must use port $PORT.
-- The primary and the RMAN copy connect to it there.
-- Stop the other program or move it to another port, then answer r. To see what it is:
  ps -fp $opid
  ss -ltnp '( sport = :$PORT )'"
      return 1
    fi
  fi
  static_entry_state || st=$?
  if [[ $st -eq 0 ]] && { use_grid || lsnr_has_desc; }; then NOW="listener.ora has the static entry for $STANDBY_SID with the database home."; return 0; fi
  USING="SID $STANDBY_SID, service $STANDBY_SERVICE
ORACLE_HOME (database home, not Grid):
  $DB_HOME"
  L51_MODE=""
  if ! use_grid && ! lsnr_has_desc; then
    if [[ $st -eq 1 ]] && ! lsnr_has_sidlist; then
      # no Grid: the listener lives in the database home and must be defined completely
      L51_MODE=both
      NOW="No listener is defined in listener.ora. There is no Grid on this server."$'\n'"  $f"
      PLAN="Write this to listener.ora (owner $ORACLE_USER; a backup is kept):
$(lsnr_desc_block)
$(static_block)"
      return 1
    fi
    if [[ $st -eq 0 ]]; then
      L51_MODE=desc
      NOW="listener.ora has the static entry, but no address for the listener $SB_LSNR:"$'\n'"  $f"
      PLAN="Add this to listener.ora (a backup is kept):
$(lsnr_desc_block)"
      return 1
    fi
  fi
  if [[ $st -eq 1 ]] && ! lsnr_has_sidlist; then
    L51_MODE=static
    NOW="listener.ora has no static entry for $STANDBY_SID:"$'\n'"  $f"
    PLAN="Add this to listener.ora (owner $(lsnr_user); a backup is kept):
$(static_block)"
    return 1
  fi
  KIND_NOW=manual; MANUAL_HOW="$(lsnr_user)  ->  shell"
  if [[ $st -eq 2 ]]; then
    NOW="The static entry for $STANDBY_SID has a different ORACLE_HOME."$'\n'"Logins through the listener would fail with ORA-01017."
    NOW+=$'\n'"The script only adds new entries; it does not change an existing one."$'\n'"Please correct this entry by hand."
  else
    NOW="listener.ora has a SID_LIST_$SB_LSNR block without $STANDBY_SID."$'\n'"The script does not edit inside an existing block, so please add the entry by hand."
  fi
  PLAN="-- Edit this file:
--   $f
-- Inside SID_LIST_$SB_LSNR, the (SID_LIST = ...) must contain exactly this SID_DESC:
    (SID_DESC =
      (GLOBAL_DBNAME = $STANDBY_SERVICE)
      (SID_NAME = $STANDBY_SID)
      (ORACLE_HOME = $DB_HOME)
    )"
  ! use_grid && ! lsnr_has_desc && PLAN+=$'\n'"-- and this listener address:"$'\n'"$(lsnr_desc_block)"
  return 1
}
d_5_1() {
  local f u txt; f=$(lsnr_file); u=$(lsnr_user)
  backup_file "$f" "$u" || return 1
  txt="# Added by dg_standby_setup.sh $RUN_ID"$'\n'
  case "$L51_MODE" in
    both)   txt+="$(lsnr_desc_block)"$'\n'"$(static_block)" ;;
    desc)   txt+="$(lsnr_desc_block)" ;;
    *)      txt+="$(static_block)" ;;
  esac
  printf '%s\n' "$txt" | append_as "$u" "$f" || return 1
  printf '%s\n' "$txt" | log_block "added to $f"
}

# ---- 5.2 ----
L52_START=0
c_5_2() {
  lsnr_sw_ok || { NOW="The listener software is not installed yet (phase 3)"; return 2; }
  static_entry_state || { NOW="The static entry is not correct yet (step 5.1)"; return 2; }
  L52_START=0
  if ! run_logged "lsnrctl status" as_lsnr timeout 60 "$(lsnr_home)/bin/lsnrctl" status "$SB_LSNR"; then
    if use_grid; then NOW="Listener $SB_LSNR is not running. It is an Oracle Restart resource, set up in step 3.9."; return 2; fi
    L52_START=1
    NOW="Listener $SB_LSNR is not running"
    PLAN="Start it:  lsnrctl start $SB_LSNR   (as $ORACLE_USER, from $DB_HOME)"
    return 1
  fi
  if ! grep -q "(PROTOCOL=TCP)(HOST=[^)]*)(PORT=$PORT)" <<< "$(norm "$RUN_OUT")"; then
    NOW="Listener $SB_LSNR does not listen on port $PORT, the port the primary uses"
    KIND_NOW=manual; MANUAL_HOW="$(lsnr_user)  ->  shell"
    PLAN="-- Edit this file:
--   $(lsnr_file)
-- Set (PORT = $PORT) in the $SB_LSNR address, then restart the listener:
$(lsnr_home)/bin/lsnrctl stop $SB_LSNR ; $(lsnr_home)/bin/lsnrctl start $SB_LSNR"
    use_grid && { MANUAL_HOW="$GRID_USER  ->  shell"; PLAN="srvctl modify listener -listener $SB_LSNR -endpoints TCP:$PORT
srvctl stop listener -listener $SB_LSNR ; srvctl start listener -listener $SB_LSNR"; }
    return 1
  fi
  if grep -qF "Instance \"$STANDBY_SID\", status UNKNOWN" <<< "$RUN_OUT"; then NOW="The listener shows Instance \"$STANDBY_SID\", status UNKNOWN (port $PORT)"; return 0; fi
  NOW="The listener does not show the static instance $STANDBY_SID yet"
  PLAN="Reload it:  lsnrctl reload $SB_LSNR   (as $(lsnr_user); open connections stay)"
  return 1
}
d_5_2() {
  local a=reload; [[ $L52_START -eq 1 ]] && a=start
  run_logged "lsnrctl $a" as_lsnr timeout 120 "$(lsnr_home)/bin/lsnrctl" "$a" "$SB_LSNR" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  [[ "$a" == "start" ]] && journal LSNRSTART "$SB_LSNR" "started from $(lsnr_home)"
  return 0
}

# ---- 5.3 / 5.4 ----
T_ALIAS=""; T_HOST=""; T_SVC=""
tns_alias_present() { local f; f=$(tns_file); [[ -f "$f" ]] && grep -qiE "^[[:space:]]*$1[[:space:]]*=" "$f"; }
c_tns() {
  db_sw_ok || { NOW="The database software is not installed yet (phase 3)"; return 2; }
  rw_home_ok || { NOW="The Oracle home is read-only (step 3.8)"; return 2; }
  local f; f=$(tns_file)
  USING="Host $T_HOST, port $PORT, service $T_SVC"
  if tns_alias_present "$T_ALIAS" && run_logged "tnsping $T_ALIAS" as_oracle timeout 60 "$DB_HOME/bin/tnsping" "$T_ALIAS" 1 && grep -q '^OK' <<< "$RUN_OUT"; then
    if tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC"; then NOW="tnsping $T_ALIAS works ($T_HOST:$PORT/$T_SVC, UR=A)"; return 0; fi
    NOW="The alias $T_ALIAS exists but is different: $TNS_WHY"
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
    PLAN="-- Edit this file:
--   $f
-- The entry must be:
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
    return 1
  fi
  if tns_alias_present "$T_ALIAS"; then
    case "$(tnsping_class "$RUN_OUT")" in
      NOLISTENER)
        if tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC"; then
          NOW="The alias $T_ALIAS is right, but nothing answers at $T_HOST:$PORT yet: $(grep -oE 'TNS-[0-9]+' <<< "$RUN_OUT" | head -n 1)"
          [[ "$T_HOST" == "$STANDBY_HOST" ]] && { NOW+=$'\n'"The listener on this server is not running (step 5.2)"; return 2; }
          NOW+=$'\n'"The listener on $T_HOST is not running. Check $LISTENER_NAME on the primary (port $PORT)."; return 2
        fi ;;
    esac
    NOW="The alias $T_ALIAS is in tnsnames.ora, but tnsping fails: $(grep -E 'TNS-[0-9]+' <<< "$RUN_OUT" | head -n 1)"
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
    PLAN="-- Edit this file:
--   $f
-- Fix the entry. Check the brackets and the host name:
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
    return 1
  fi
  NOW="The alias $T_ALIAS is missing from tnsnames.ora:"$'\n'"  $f"
  PLAN="Add this to tnsnames.ora (a backup is kept):
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
  return 1
}
d_tns() {
  local f; f=$(tns_file)
  backup_file "$f" "$ORACLE_USER" || return 1
  tns_block "$T_ALIAS" "$T_HOST" "$T_SVC" | append_as "$ORACLE_USER" "$f" || return 1
  tns_block "$T_ALIAS" "$T_HOST" "$T_SVC" | log_block "added to $f"
}
c_5_3() { T_ALIAS=$PRIMARY_TNS; T_HOST=$PRIMARY_HOST; T_SVC=$PRIMARY_SERVICE; c_tns; }
c_5_4() { T_ALIAS=$STANDBY_TNS; T_HOST=$STANDBY_HOST; T_SVC=$STANDBY_SERVICE; c_tns; }

phase_5() {
  phase_header 5 "Listener and tnsnames.ora"
  run_step 5.1 auto "Static listener entry for $STANDBY_SID" c_5_1 d_5_1
  run_step 5.2 auto "Listener shows the static entry" c_5_2 d_5_2
  run_step 5.3 auto "tnsnames.ora entry for the primary ($PRIMARY_TNS)" c_5_3 d_tns
  run_step 5.4 auto "tnsnames.ora entry for the standby ($STANDBY_TNS)" c_5_4 d_tns
}

#------------------------------------------------------------------------------
# PHASE 6  Password file (copy of the primary file), TDE wallet
#------------------------------------------------------------------------------
pw_dest() { printf '%s/dbs/orapw%s' "$DB_HOME" "$STANDBY_SID"; }
pw_tmp_remote() { printf '/tmp/orapw_for_standby_%s' "$STANDBY_SID"; }

pwfile_ok() {
  local d; d=$(pw_dest)
  [[ -f "$d" && ! -L "$d" ]] || return 1
  [[ "$(stat -c '%U' "$d")" == "$ORACLE_USER" ]] || return 1
  [[ "$(stat -c '%a' "$d")" =~ ^6[04]0$ ]] || return 1
  [[ -s "$d" ]] || return 1
  [[ "$PRIMARY_VERSION" == 12.1* ]] && return 0          # 12.1 orapwd has no "describe"
  run_logged "orapwd describe" as_oracle timeout 60 "$DB_HOME/bin/orapwd" describe file="$d" || return 1
  # any format the primary uses (12, 12.2, or LEGACY on an upgraded database): the file is a byte copy
  grep -qE 'format=[A-Za-z0-9.]+' <<< "$RUN_OUT"
}

PW_SRC=""
c_6_1() {
  db_sw_ok || { NOW="The database software is not installed yet (phase 3)"; return 2; }
  rw_home_ok || { NOW="The Oracle home is read-only (step 3.8)"; return 2; }
  local d; d=$(pw_dest)
  if pwfile_ok; then NOW="The password file is in place, owner $ORACLE_USER."$'\n'"  $d"$'\n'"The login test of step 7.4 compares it with the primary."; return 0; fi
  need_ssh || return 2
  # 12.2+: v$passwordfile_info has file_name and format; 12.1: file_name only; else the file in dbs
  local pfile=""
  if prim_sql "select file_name from v\$passwordfile_info;"; then pfile=$(first_line)
  fi
  if [[ -z "$pfile" || "$pfile" == "-" ]]; then
    if prim_probe exists "$DB_HOME/dbs/orapw$PRIMARY_SID" && [[ "$(head -n 1 <<< "$RUN_OUT")" == "YES" ]]; then pfile="$DB_HOME/dbs/orapw$PRIMARY_SID"
    else NOW="The password file of the primary was not found."$'\n'"v\$passwordfile_info is empty and $DB_HOME/dbs/orapw$PRIMARY_SID does not exist."$'\n'"To find it, run on the primary as $ORACLE_USER:"$'\n'"  $DB_HOME/bin/srvctl config database -db $PRIMARY_UNIQUE | grep -i 'password file'"; return 2; fi
  fi
  [[ "$pfile" =~ ^\+[A-Za-z0-9_./+-]+$ || "$pfile" =~ ^/[A-Za-z0-9_./-]+$ ]] || { NOW="The primary password file has an unusual path: '$pfile'"; return 2; }
  if [[ -f "$d" ]]; then NOW="The password file here has the wrong owner, mode or format:"$'\n'"  $d"; else NOW="This server has no password file yet."$'\n'"  $d"; fi
  if [[ "$pfile" == +* ]]; then
    local t towner tg tm tmode ttype tage=""; t=$(pw_tmp_remote)
    if prim_probe statx "$t"; then
      IFS='|' read -r towner tg tmode ttype tm <<< "$(head -n 1 <<< "$RUN_OUT")"
      if [[ "$ttype" != "regular file" || ( "$towner" != "$GRID_USER" && "$towner" != "$ORACLE_USER" ) || ! "$tmode" =~ ^[0-7]+$ || $(( 8#${tmode: -1} & 2 )) -ne 0 ]]; then
        NOW+=$'\n'"$t on the primary is not used (owner $towner, type $ttype, mode $tmode)."
        NOW+=$'\n'"It must be a regular file of $GRID_USER or $ORACLE_USER that others cannot write."
        KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
        PLAN="rm -f $t
asmcmd pwcopy '$pfile' $t
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 reminds you after the copy)"
        return 1
      fi
      # the age is measured with the clock of the primary
      num "$tm" && tage=$(( RUN_START + PRIM_CLOCK_OFFSET - tm ))
    fi
    if [[ -n "$tage" && $tage -gt 86400 ]]; then
      # a copy older than a day (from an earlier attempt) may be from before a sys password change
      NOW+=$'\n'"An old copy $t is on the primary (owner $towner, $((tage / 3600)) hours older than this run)."
      NOW+=$'\n'"It is not used: the sys password may have changed since then."
      KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
      PLAN="rm -f $t
asmcmd pwcopy '$pfile' $t
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 reminds you after the copy)"
      return 1
    fi
    [[ -n "$tage" ]] && NOW="The copy $t is ready on the primary$([[ $tage -ge 60 ]] && printf ' (%s minutes old)' "$((tage / 60))")."$'\n'"$NOW"
    if [[ -n "$tage" ]]; then
      PW_SRC=$t
      PLAN="Copy $t from the primary (scp, checked with md5sum)
Install it here (owner $ORACLE_USER:$INSTALL_GROUP, mode 640):
  $d"
      [[ -f "$d" ]] && PLAN+=$'\n'"Keep the old file as ${d##*/}.bak_$RUN_ID (same folder)"
      USING="Fresh copy of $pfile on the primary (owner $towner)"
      return 1
    fi
    NOW+=$'\n'"The primary password file is in ASM: $pfile"
    KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
    PLAN="asmcmd pwcopy '$pfile' $t
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 reminds you after the copy)"
    USING="After you run the commands below, the script copies the file to this server."$'\n'"Step 6.2 then asks you to delete it on the primary."
    return 1
  fi
  PW_SRC=$pfile
  PLAN="Copy the password file from the primary (scp, checked with md5sum):
  $pfile
Install it here (owner $ORACLE_USER:$INSTALL_GROUP, mode 640):
  $d"
  [[ -f "$d" ]] && PLAN+=$'\n'"Keep the old file as ${d##*/}.bak_$RUN_ID (same folder)"
  return 1
}
fetch_primary_file() {
  # $1 file on primary, $2 private local copy. 0 only when the copy is byte-identical (md5).
  local src=$1 tmp=$2 rmd lmd
  rm -f -- "$tmp"
  prim_scp "$src" "$tmp" || { bad "scp failed: $(tail -n 2 <<< "$RUN_OUT")"; printf 'The ssh user %s must be able to read %s on the primary.\n' "$PRIMARY_SSH_USER" "$src" | hint; return 1; }
  [[ -s "$tmp" && -f "$tmp" && ! -L "$tmp" ]] || { bad "The copy of $src is empty"; return 1; }
  prim_probe md5 "$src" || { bad "Cannot get the md5sum of $src on the primary. The copy is not used."; return 1; }
  rmd=$(awk '{print $1; exit}' <<< "$RUN_OUT"); lmd=$(md5sum "$tmp" | awk '{print $1}')
  [[ "$rmd" =~ ^[0-9a-f]{32}$ && "$rmd" == "$lmd" ]] || { bad "The copy differs from $src on the primary (md5 here $lmd, there $rmd)"; return 1; }
  say "Checksum (md5) is the same as the file on the primary."
}
d_6_1() {
  local d tmp; d=$(pw_dest)
  install -d -m 700 "$STATE_DIR"
  tmp="$STATE_DIR/orapw_incoming.$$"; CLEANUP_FILES+=("$tmp")
  fetch_primary_file "$PW_SRC" "$tmp" || return 1
  local existed=0; [[ -e "$d" ]] && existed=1
  backup_file "$d" "$ORACLE_USER" || return 1
  install -o "$ORACLE_USER" -g "$INSTALL_GROUP" -m 640 "$tmp" "$d" || { bad "Cannot install $d"; return 1; }
  rm -f "$tmp"
  journal_file_written "$d" "$existed"
  DONE_MSG="The primary password file is installed here:"$'\n'"  $d"
}

# ---- 6.2 temporary copy on primary ----
c_6_2() {
  need_ssh || return 2
  local t; t=$(pw_tmp_remote)
  PRIMARY_HOW_STEP="$GRID_USER (or root)  ->  shell"
  if ! prim_probe owner "$t"; then NOW="No temporary password file copy on the primary"; return 0; fi
  pwfile_ok || { NOW="Keep $t for now: the password file is not installed yet (step 6.1)"; return 2; }
  NOW="The temporary copy $t is still on the primary"
  PLAN="rm -f $t"
  return 1
}

# ---- 6.3 TDE wallet ----
TDE_DIRS=(); TDE_TODO=(); TDE_SQLNET=0; TDE_NO_AUTOLOGIN=0
tde_dirs() {
  # file-based wallet folders in use on primary (one per line); TDE_INFO lines: type|location|status
  awk -F'|' 'toupper($1)=="FILE" && $2 != "-" && toupper($3) != "NOT_AVAILABLE" {print $2}' <<< "$TDE_INFO" | sed 's#/*$##' | sort -u
}
sqlnet_file() { printf '%s/network/admin/sqlnet.ora' "$DB_HOME"; }
tde_local_autologin() { awk -F'|' 'toupper($4) ~ /LOCAL/' <<< "$TDE_INFO" | grep -q .; }
orapki_plan() {
  # creates cwallet.sso next to ewallet.p12 on THIS server; orapki asks for the keystore password itself
  printf 'ORACLE_HOME=%s %s/bin/orapki wallet create -wallet %s %s\n' "$DB_HOME" "$DB_HOME" "$1" "$(tde_local_autologin && printf -- '-auto_login_local' || printf -- '-auto_login')"
  printf '# orapki asks for the keystore password and writes %s/cwallet.sso here.\n# The primary is not changed. Then answer r.' "$1"
}
tde_autologin_missing() {
  # 0 when the primary uses a file keystore and this server has no auto-login file for it (ORA-28365 later)
  [[ -n "$TDE_INFO" ]] || return 1
  local d; d=$(tde_dirs | head -n 1)
  [[ -n "$d" && "$d" == /* ]] || return 1
  [[ -f "$d/cwallet.sso" ]] && return 1
  [[ -n "$WALLET_ROOT" && -f "$WALLET_ROOT/tde/cwallet.sso" ]] && return 1
  return 0
}
sqlnet_has_wallet() { local f; f=$(sqlnet_file); [[ -f "$f" ]] && norm "$(sed 's/#.*//' "$f")" | grep -qF "(DIRECTORY=${1^^})"; }
c_6_3() {
  [[ -n "$TDE_INFO" ]] || { NOW="The primary does not use a TDE wallet"; return 0; }
  if awk -F'|' 'toupper($1)!="FILE" && toupper($3)!="NOT_AVAILABLE"' <<< "$TDE_INFO" | grep -q .; then
    NOW="The primary uses a TDE keystore that is not a file (HSM or OKV):"$'\n'"$TDE_INFO"
    PLAN="Set up the same keystore for $STANDBY_UNIQUE on this server, as your HSM or OKV vendor describes."
    return 2
  fi
  local -a dirs=(); local d f; mapfile -t dirs < <(tde_dirs)
  [[ ${#dirs[@]} -gt 0 && -n "${dirs[0]}" ]] || { NOW="The primary does not use a TDE wallet"; return 0; }
  # 18c+: the password for "IDENTIFIED BY EXTERNAL STORE" is in WALLET_ROOT/tde_seps
  [[ -n "$WALLET_ROOT" ]] && need_ssh && prim_probe lsdir "$WALLET_ROOT/tde_seps" && grep -qx 'cwallet.sso' <<< "$RUN_OUT" && dirs+=("$WALLET_ROOT/tde_seps")
  db_sw_ok || { NOW="The database software is not installed yet (phase 3)"; return 2; }
  for d in "${dirs[@]}"; do
    [[ "$d" == /* ]] && v_path "$d" || { NOW="The TDE wallet is at $d, in ASM or at an unusual path"; PLAN="Copy the wallet files by hand to the same location for the standby, for example with asmcmd cp."; return 2; }
  done
  need_ssh || return 2
  TDE_DIRS=("${dirs[@]}"); TDE_TODO=()
  local miss="" diff="" have=""
  for d in "${dirs[@]}"; do
    prim_probe lsdir "$d" || { NOW="Cannot list the wallet folder $d on the primary. The ssh user must be able to read it."; return 2; }
    local found=0
    while IFS= read -r f; do
      [[ "$f" =~ ^(ewallet\.p12|cwallet\.sso)$ ]] || continue
      found=1
      # a LOCAL auto-login wallet of the primary does not open here: it is made again on this server (orapki)
      if [[ "$f" == cwallet.sso ]] && tde_local_autologin; then continue; fi
      if [[ ! -f "$d/$f" ]]; then miss+=" $d/$f"; TDE_TODO+=("$d/$f"); continue; fi
      if prim_probe md5 "$d/$f" && [[ "$(awk '{print $1; exit}' <<< "$RUN_OUT")" == "$(md5sum "$d/$f" | awk '{print $1}')" ]]; then have+=" $d/$f"
      else diff+=" $d/$f"; TDE_TODO+=("$d/$f"); fi
    done <<< "$RUN_OUT"
    [[ $found -eq 1 ]] || { NOW="No ewallet.p12 or cwallet.sso in $d on the primary"; return 2; }
  done
  # without WALLET_ROOT (12c, or 18c-21c set up the old way) the standby finds the wallet only through sqlnet.ora
  TDE_SQLNET=0
  if [[ -z "$WALLET_ROOT" ]]; then
    [[ $DB_MAJOR -ge 23 ]] && { NOW="The primary ($PRIMARY_VERSION) uses TDE without WALLET_ROOT. Set WALLET_ROOT on the primary first."; return 2; }
    if ! sqlnet_has_wallet "${dirs[0]}"; then
      if [[ -f "$(sqlnet_file)" ]] && grep -qiE '^[[:space:]]*ENCRYPTION_WALLET_LOCATION' "$(sqlnet_file)"; then
        NOW="sqlnet.ora has an ENCRYPTION_WALLET_LOCATION that is not ${dirs[0]}:"$'\n'"  $(sqlnet_file)"
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
        PLAN="-- Edit this file:
--   $(sqlnet_file)
-- Change the ENCRYPTION_WALLET_LOCATION line to:
ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))"
        return 1
      fi
      TDE_SQLNET=1
    fi
  fi
  TDE_NO_AUTOLOGIN=0; [[ "$have$miss$diff" == *"cwallet.sso"* ]] || TDE_NO_AUTOLOGIN=1
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 && $TDE_NO_AUTOLOGIN -eq 1 && -f "${dirs[0]}/cwallet.sso" ]]; then TDE_NO_AUTOLOGIN=0; fi
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 && $TDE_NO_AUTOLOGIN -eq 1 ]]; then
    NOW="The TDE wallet is copied, but there is no auto-login keystore (cwallet.sso) here."$'\n'"Without it, the RMAN copy and redo apply stop with ORA-28365."
    tde_local_autologin && NOW+=$'\n'"The primary uses a local auto-login wallet. It opens only on the primary host,"$'\n'"so it is made again here."
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER"
    PLAN=$(orapki_plan "${dirs[0]}")
    return 1
  fi
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 ]]; then
    NOW="The TDE wallet is the same as on the primary:$have"
    [[ -n "$WALLET_ROOT" ]] && NOW+=$'\n'"wallet_root=$WALLET_ROOT comes to the standby with the spfile." || NOW+=$'\n'"The wallet location ${dirs[0]} is set in:"$'\n'"  $(sqlnet_file)"
    return 0
  fi
  NOW="The primary uses TDE.${miss:+ Missing here:$miss}${diff:+ Different here:$diff}"
  [[ $TDE_SQLNET -eq 1 ]] && NOW+=$'\n'"sqlnet.ora does not point to the wallet ${dirs[0]}:"$'\n'"  $(sqlnet_file)"
  PLAN=""
  [[ ${#TDE_TODO[@]} -gt 0 ]] && PLAN="Copy these files from the primary to the same path here (scp, checked with md5sum):"$'\n'"$(printf '  %s\n' "${TDE_TODO[@]}")"$'\n'"Owner $ORACLE_USER:$INSTALL_GROUP, mode 600. Old files are kept as .bak_$RUN_ID."$'\n'
  [[ $TDE_SQLNET -eq 1 ]] && PLAN+="Add this to sqlnet.ora (a backup is kept):"$'\n'"ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))"$'\n'
  TDE_NO_AUTOLOGIN=0
  if [[ " ${have} ${TDE_TODO[*]+"${TDE_TODO[*]}"} " != *"cwallet.sso"* ]]; then
    TDE_NO_AUTOLOGIN=1
    if tde_local_autologin; then PLAN+="The primary uses a local auto-login wallet. It opens only on the primary host,"$'\n'"so it is not copied."$'\n'
    else PLAN+="The primary has no auto-login keystore (cwallet.sso)."$'\n'"Without one here, the RMAN copy and redo apply on the standby stop with ORA-28365."$'\n'; fi
    PLAN+="After the copy, this step shows the orapki command that makes cwallet.sso on this server."$'\n'
  fi
  PLAN=${PLAN%$'\n'}
  return 1
}
d_6_3() {
  local f tmp d
  for f in "${TDE_TODO[@]+"${TDE_TODO[@]}"}"; do
    d=$(dirname "$f")
    make_dir "$d" "$ORACLE_USER" || return 1
    runuser -u "$ORACLE_USER" -- chmod 700 "$d" 2>/dev/null || true
    tmp="$STATE_DIR/tde_incoming.$$"; CLEANUP_FILES+=("$tmp")
    fetch_primary_file "$f" "$tmp" || return 1
    local existed=0; [[ -e "$f" ]] && existed=1
    backup_file "$f" "$ORACLE_USER" || return 1
    install -o "$ORACLE_USER" -g "$INSTALL_GROUP" -m 600 "$tmp" "$f" || return 1
    rm -f "$tmp"; say "Installed $f"; journal_file_written "$f" "$existed"
  done
  if [[ $TDE_SQLNET -eq 1 ]]; then
    local s; s=$(sqlnet_file)
    backup_file "$s" "$ORACLE_USER" || return 1
    printf '# Added by dg_standby_setup.sh %s (TDE wallet of the standby)\nENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = %s)))\n' "$RUN_ID" "${TDE_DIRS[0]}" \
      | append_as "$ORACLE_USER" "$s" || return 1
    say "Added ENCRYPTION_WALLET_LOCATION to $s"
  fi
}

phase_6() {
  phase_header 6 "Password file and TDE wallet"
  run_step 6.1 auto    "Password file orapw$STANDBY_SID" c_6_1 d_6_1
  run_step 6.2 primary "Remove the temporary copy on the primary" c_6_2
  run_step 6.3 auto    "TDE wallet (only if the primary uses TDE)" c_6_3 d_6_3
}
