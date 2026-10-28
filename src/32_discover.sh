#------------------------------------------------------------------------------
# Discovery of the primary (read-only). Nothing here depends on the environment
# (.bash_profile) of the user on primary: the database is found by its running
# processes, its home by /etc/oratab or by the program the process runs.
# A program found this way is used only when it belongs to the user that runs
# the process and nobody else can change it.
#------------------------------------------------------------------------------
PS_OUT=""; DB_PMON_PID=""; ASM_PMON_PID=""; AUDIT_DEST=""; DIAG_DEST=""; TDE_INFO=""; WALLET_ROOT=""; TDE_CONFIG=""
PRIM_CLOCK_OFFSET=0    # primary clock minus this server's clock (seconds)
DISC_NOTES=()          # things worth telling the user (oratab differs, env missing, ...)

parse_id_line() {
  # "uid=54321(oracle) gid=54321(oinstall) groups=54321(oinstall),54322(dba)"
  # -> sets PID_UID PID_PGROUP PID_GROUPS(name:gid,...)
  local line=$1
  PID_UID=$(sed -n 's/^uid=\([0-9]*\).*/\1/p' <<< "$line")
  PID_PGROUP=$(sed -n 's/.* gid=[0-9]*(\([^)]*\)).*/\1/p' <<< "$line")
  PID_GROUPS=$(sed -n 's/.*groups=//p' <<< "$line" | tr ',' '\n' | sed -n 's/^\([0-9]*\)(\([^)]*\))$/\2:\1/p' | paste -sd, -)
}

home_of_pid() {
  # $1 pid -> ORACLE_HOME of the program it runs (empty if it cannot be read)
  prim_probe exe "$1" || return 1
  local exe; exe=$(head -n 1 <<< "$RUN_OUT")
  [[ "$exe" == */bin/oracle ]] || return 1
  printf '%s' "${exe%/bin/oracle}"
}

trusted_prog() {
  # $1 program path on primary, $2 expected owner (empty = any Oracle owner seen so far).
  # 0 when it is a regular file, owned by that user, not writable by group or others.
  v_path "$1" || return 1
  prim_probe statx "$1" || return 1
  local u g m t
  IFS='|' read -r u g m t _ <<< "$(head -n 1 <<< "$RUN_OUT")"
  [[ "$t" == "regular file" ]] || return 1
  [[ -z "$2" || "$u" == "$2" ]] || return 1
  [[ "$m" =~ ^[0-7]+$ ]] || return 1
  local gd=${m: -2:1} od=${m: -1}
  (( (8#$gd & 2) == 0 && (8#$od & 2) == 0 ))
}
home_ok() { v_path "$1" && trusted_prog "$1/bin/oracle" "${2:-}"; }    # it is an Oracle home on primary

ARCH_N=""; P_DG_CONFIG=""
norm_loc() {
  # "+data/X/..." -> "+DATA" ; "/u02/oradata/X/" -> "/u02/oradata/X"
  local v=$1
  if [[ "$v" == +* ]]; then v=${v%%/*}; printf '%s' "${v^^}"; else printf '%s' "${v%/}"; fi
}

read_arch_params() {
  # recovery area, archive destination, folders of the instance (read-only).
  # Sets FRA_LOC FRA_MB ARCH_LOC ARCH_N AUDIT_DEST DIAG_DEST CFD. The local archive destination is the lowest
  # log_archive_dest_N with a LOCATION (not always 1).
  prim_sql "select name||'|'||nvl(value,'-') from v\$parameter where name in ('db_create_file_dest','db_recovery_file_dest','db_recovery_file_dest_size','log_archive_dest','audit_file_dest','diagnostic_dest') or (name like 'log_archive_dest__' or name like 'log_archive_dest___') and upper(value) like '%LOCATION%';" \
    || return 1
  local pn pv d1="-" lad="-" dn
  CFD="-"; FRA_LOC=""; FRA_MB=0; ARCH_LOC=""; ARCH_N=""; AUDIT_DEST=""; DIAG_DEST=""
  while IFS='|' read -r pn pv; do
    case "$pn" in
      db_create_file_dest) CFD=$pv ;;
      db_recovery_file_dest) [[ "$pv" != "-" ]] && FRA_LOC=$(norm_loc "$pv") ;;
      db_recovery_file_dest_size) num "$pv" && FRA_MB=$(( pv / 1048576 )) ;;
      log_archive_dest_[0-9]*) dn=${pn#log_archive_dest_}
        # a destination that works only in the standby role (left from an earlier role change) is not the local one
        if num "$dn" && [[ -z "$ARCH_N" || $dn -lt $ARCH_N ]] && [[ "${pv^^}" == *LOCATION* && "$(tr -d ' ' <<< "${pv^^}")" != *",STANDBY_ROLE)"* ]]; then ARCH_N=$dn; d1=$pv; fi ;;
      log_archive_dest) lad=$pv ;;
      audit_file_dest) [[ "$pv" =~ ^/[A-Za-z0-9_./-]+$ ]] && AUDIT_DEST=${pv%/} ;;
      diagnostic_dest) [[ "$pv" =~ ^/[A-Za-z0-9_./-]+$ ]] && DIAG_DEST=${pv%/} ;;
    esac
  done <<< "$SQL_OUT"
  [[ "$FRA_LOC" =~ ^[+/][A-Za-z0-9_./-]+$ ]] || FRA_LOC=""
  [[ -n "$FRA_LOC" ]] || FRA_MB=0
  OLD_ARCH_DEST=""
  local d1u=${d1^^}
  if [[ "$d1u" =~ LOCATION[[:space:]]*=[[:space:]]*[\"\']?USE_DB_RECOVERY_FILE_DEST ]]; then ARCH_LOC=USE_DB_RECOVERY_FILE_DEST
  elif [[ "$d1" =~ [Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn][[:space:]]*=[[:space:]]*[\"\']?([+/][A-Za-z0-9_./-]+) ]]; then ARCH_LOC=$(norm_loc "${BASH_REMATCH[1]}")
  elif [[ "$lad" =~ ^[+/][A-Za-z0-9_./-]+$ ]]; then ARCH_LOC=$(norm_loc "$lad"); OLD_ARCH_DEST=$ARCH_LOC
  elif [[ -n "$FRA_LOC" ]]; then ARCH_LOC=USE_DB_RECOVERY_FILE_DEST
  else ARCH_LOC=""; fi
  [[ -n "$ARCH_N" ]] || ARCH_N=1
  return 0
}

pick_from_list() {
  # $1 prompt, $2 count -> ANSWER = 1..count; q stops the script. No default: the order of ps means nothing.
  while true; do
    ask "$1  (q to stop)"
    [[ "${ANSWER,,}" == "q" ]] && user_stop "Stopped by you"
    [[ "$ANSWER" =~ ^[0-9]{1,3}$ ]] && (( 10#$ANSWER >= 1 && 10#$ANSWER <= $2 )) && { ANSWER=$((10#$ANSWER)); return 0; }
    say "Please type a number from 1 to $2, or q."
  done
}

discover_primary() {
  local l
  DISC_NOTES=()
  [[ "$PRIMARY_SSH_USER" != "root" ]] || fatal "Do not use root for ssh. Use the Oracle software owner, for example:  --user oracle"
  # ---- host
  prim_probe host || { bad "Cannot run commands on the primary."; return 1; }
  PRIMARY_HOST=$(sed -n '1p' <<< "$RUN_OUT" | tr -d '[:space:]')
  v_name "$PRIMARY_HOST" || { bad "The primary returned an unexpected host name: $PRIMARY_HOST"; return 1; }
  local ls; ls=$(hostname -s 2>/dev/null || hostname)
  if [[ "${PRIMARY_HOST,,}" == "${ls,,}" ]]; then
    fatal "The primary has the same host name as this server: $PRIMARY_HOST. Data Guard needs two names.
If this server is the primary, run the script on the standby server instead.
If this server is a clone of the primary, give it its own name first:
  hostnamectl set-hostname <new name>
Then fix /etc/hosts and run the script again."
  fi
  ok "Primary host: $PRIMARY_HOST"
  if prim_probe now && num "$(head -n 1 <<< "$RUN_OUT")"; then
    PRIM_CLOCK_OFFSET=$(( $(head -n 1 <<< "$RUN_OUT") - $(date +%s) ))
    [[ ${PRIM_CLOCK_OFFSET#-} -gt 300 ]] && DISC_NOTES+=("The clock of the primary is $PRIM_CLOCK_OFFSET seconds off from this server.
Fix the time synchronization: step 2.10 here, chronyd on the primary.")
  fi

  # ---- running instances and listeners
  prim_probe ps || { bad "Cannot list the processes on the primary."; return 1; }
  PS_OUT=$RUN_OUT
  local -a pm=()
  ASM_PMON_PID=""
  local pid user args
  while read -r pid user args; do
    if [[ "$args" =~ ^ora_pmon_([A-Za-z][A-Za-z0-9_]*)$ ]]; then
      local psid=${BASH_REMATCH[1]}
      num "$pid" && v_name "$user" && pm+=("$psid:$pid:$user")
    fi
    [[ "$args" =~ ^asm_pmon_\+ASM[0-9]*$ ]] && num "$pid" && ASM_PMON_PID=$pid
  done <<< "$PS_OUT"
  local oratab=""
  prim_probe oratab && oratab=$RUN_OUT

  if [[ ${#pm[@]} -eq 0 ]]; then
    bad "No database instance is running on the primary (no ora_pmon_<SID> process)."
    printf 'The primary database must be open for this script.\nStart it on the primary as oracle:\n  sqlplus / as sysdba\n  startup\n' | hint
    return 1
  fi
  local pick=1 i saved_sid=$PRIMARY_SID
  if [[ ${#pm[@]} -gt 1 ]]; then
    pick=""
    # the database chosen in an earlier run is used again (--settings or a new primary IP start over)
    if [[ -n "$saved_sid" && $REVIEW_SETTINGS -eq 0 ]]; then
      for i in "${!pm[@]}"; do [[ "${pm[$i]%%:*}" == "$saved_sid" ]] && pick=$((i + 1)); done
      [[ -n "$pick" ]] && ok "Database $saved_sid, chosen in an earlier run
To choose another one:  $SELF --settings"
    fi
    if [[ -z "$pick" ]]; then
      say "Running databases on the primary:"
      for i in "${!pm[@]}"; do say "  $((i + 1))) ${pm[$i]%%:*}   user ${pm[$i]##*:}"; done
      pick_from_list "Number of the database for the standby, 1 to ${#pm[@]}" "${#pm[@]}"
      pick=$ANSWER
    fi
  fi
  local e=${pm[$((pick - 1))]} pmon_user
  PRIMARY_SID=${e%%:*}; e=${e#*:}; DB_PMON_PID=${e%%:*}; pmon_user=${e#*:}
  v_name "$PRIMARY_SID" || { bad "Unexpected SID: $PRIMARY_SID"; return 1; }

  # ---- database home: the program of the running process, else oratab, else ask.
  #      The home is accepted only when its bin/oracle belongs to the user that runs the instance.
  local tab_home="" run_home=""
  tab_home=$(awk -F: -v s="$PRIMARY_SID" '$1==s {print $2; exit}' <<< "$(sed 's/#.*//' <<< "$oratab")")
  tab_home=${tab_home%/}
  run_home=$(home_of_pid "$DB_PMON_PID" || true)
  if [[ -n "$run_home" ]] && home_ok "$run_home" "$pmon_user"; then
    DB_HOME=$run_home
    if [[ -z "$tab_home" ]]; then DISC_NOTES+=("/etc/oratab on the primary has no line for $PRIMARY_SID. Suggested line:  $PRIMARY_SID:$DB_HOME:N")
    elif [[ "$tab_home" != "$run_home" ]]; then DISC_NOTES+=("/etc/oratab on the primary says $tab_home for $PRIMARY_SID,
but the database runs from $run_home."); fi
  elif [[ -n "$tab_home" ]] && home_ok "$tab_home" "$pmon_user"; then
    DB_HOME=$tab_home
  else
    # the environment of the running process (readable as its owner), then the inventory, then ask
    local eh="" ih
    if prim_probe environ "$DB_PMON_PID"; then eh=$(sed -n 's/^ORACLE_HOME=//p' <<< "$RUN_OUT" | head -n 1); eh=${eh%/}; fi
    if [[ -n "$eh" ]] && home_ok "$eh" "$pmon_user"; then DB_HOME=$eh
    else
      for ih in $(inventory_homes); do home_ok "$ih" "$pmon_user" && { DB_HOME=$ih; break; }; done
    fi
    [[ -n "$DB_HOME" ]] && DISC_NOTES+=("/etc/oratab on the primary has no usable line for $PRIMARY_SID. Its home was found another way.
Suggested oratab line:  $PRIMARY_SID:$DB_HOME:N")
  fi
  if [[ -z "$DB_HOME" ]]; then
    warn "The Oracle home of $PRIMARY_SID was not found.
It is not in /etc/oratab or the inventory, and the process cannot be read."
    say "Example of a home:  /u01/app/oracle/product/19.0.0/dbhome_1"
    while true; do
      ask "Full path of the database ORACLE_HOME on the primary (q to stop)"
      [[ "${ANSWER,,}" == "q" ]] && user_stop "Stopped by you"
      ANSWER=${ANSWER%/}
      if home_ok "$ANSWER" "$pmon_user"; then DB_HOME=$ANSWER; break; fi
      say "$ANSWER/bin/oracle is not on the primary, or it does not belong to $pmon_user (the owner of the instance)."
    done
  fi
  ok "Instance: ORACLE_SID=$PRIMARY_SID  home=$DB_HOME"

  # ---- environment of the running database (true TNS_ADMIN); readable only as the DB owner
  PRIMARY_TNS_ADMIN=""
  if prim_probe environ "$DB_PMON_PID"; then
    PRIMARY_TNS_ADMIN=$(sed -n 's/^TNS_ADMIN=//p' <<< "$RUN_OUT" | head -n 1); PRIMARY_TNS_ADMIN=${PRIMARY_TNS_ADMIN%/}
    v_path "$PRIMARY_TNS_ADMIN" || PRIMARY_TNS_ADMIN=""
  fi

  # ---- edition: Data Guard needs Enterprise Edition (checked here, before anything is installed)
  prim_sql "select banner from v\$version where banner like 'Oracle%';" \
    || { bad "Cannot query the database on the primary: $(ora_errors "$SQL_OUT")"; printf 'The ssh user %s must be able to run  sqlplus / as sysdba  (it must be in the dba group).\n' "$PRIMARY_SSH_USER" | hint; return 1; }
  local ban; ban=$(first_line)
  if [[ "$ban" == *"Enterprise Edition"* ]]; then DB_EDITION=EE
  elif [[ "$ban" == *"Standard Edition"* ]]; then DB_EDITION=SE2
  else DB_EDITION=EE; DISC_NOTES+=("The edition in '$ban' is not known. Enterprise Edition is assumed."); fi
  [[ "$DB_EDITION" == "EE" ]] || fatal "The primary is Standard Edition: $ban
Data Guard needs Enterprise Edition, so this script cannot build a standby for it."

  # ---- Grid home (only if there is Grid/ASM)
  GRID_HOME=$(awk -F: '$1 ~ /^\+ASM[0-9]*$/ {print $2; exit}' <<< "$(sed 's/#.*//' <<< "$oratab")")
  if [[ -z "$GRID_HOME" ]] && prim_probe olr; then GRID_HOME=$(sed -n 's/^crs_home=//p' <<< "$RUN_OUT" | head -n 1); fi
  if [[ -z "$GRID_HOME" && -n "$ASM_PMON_PID" ]]; then GRID_HOME=$(home_of_pid "$ASM_PMON_PID" || true); fi
  GRID_HOME=${GRID_HOME%/}
  [[ -z "$GRID_HOME" ]] || home_ok "$GRID_HOME" || GRID_HOME=""

  # ---- inventory
  INVENTORY_DIR=""
  prim_probe orainst && INVENTORY_DIR=$(sed -n 's/^inventory_loc=//p' <<< "$RUN_OUT" | head -n 1)
  INVENTORY_DIR=${INVENTORY_DIR%/}
  v_path "$INVENTORY_DIR" || INVENTORY_DIR="$(dirname "$(dirname "$DB_HOME")")/oraInventory"

  # ---- owners, ids, groups
  ORACLE_USER=""; GRID_USER=""
  prim_probe owner "$DB_HOME/bin/oracle" && ORACLE_USER=$(awk '{print $1; exit}' <<< "$RUN_OUT")
  if [[ -n "$GRID_HOME" ]] && prim_probe owner "$GRID_HOME/bin/oracle"; then GRID_USER=$(awk '{print $1; exit}' <<< "$RUN_OUT"); fi
  v_name "$ORACLE_USER" || ORACLE_USER=oracle
  v_name "$GRID_USER" || GRID_USER=$ORACLE_USER
  prim_probe ids "$ORACLE_USER" "$GRID_USER" || { bad "Cannot read the user ids on the primary."; return 1; }
  parse_id_line "$(grep -m1 "^uid=[0-9]*($ORACLE_USER)" <<< "$RUN_OUT")"
  ORACLE_UID=$PID_UID; INSTALL_GROUP=$PID_PGROUP; local og=$PID_GROUPS
  parse_id_line "$(grep -m1 "^uid=[0-9]*($GRID_USER)" <<< "$RUN_OUT")"
  GRID_UID=$PID_UID; GRID_PGROUP=$PID_PGROUP; local gg=$PID_GROUPS
  num "$ORACLE_UID" && num "$GRID_UID" && [[ -n "$INSTALL_GROUP" ]] || { bad "Cannot understand the output of 'id' on the primary."; return 1; }
  # Only Oracle OS groups are copied (not wheel, docker, LDAP groups and so on)
  local ora_re="^(${INSTALL_GROUP}|${GRID_PGROUP}|oinstall|dba|oper|backupdba|dgdba|kmdba|racdba|asmadmin|asmdba|asmoper):"
  og=$(tr ',' '\n' <<< "$og" | grep -E "$ora_re" | paste -sd, -)
  gg=$(tr ',' '\n' <<< "$gg" | grep -E "$ora_re" | paste -sd, -)
  GROUP_GIDS=$(printf '%s\n%s\n' "$og" "$gg" | tr ',' '\n' | grep -v '^$' | sort -u -t: -k1,1 | paste -sd, -)
  ORACLE_GROUPS=$(tr ',' '\n' <<< "$og" | cut -d: -f1 | grep -vx "$INSTALL_GROUP" | paste -sd, -)
  GRID_GROUPS=$(tr ',' '\n' <<< "$gg" | cut -d: -f1 | grep -vx "$GRID_PGROUP" | paste -sd, -)
  if [[ "$ORACLE_USER" == "$GRID_USER" ]]; then ok "Owner: $ORACLE_USER ($ORACLE_UID) owns the database${GRID_HOME:+ and the Grid} software"
  else ok "Users: $ORACLE_USER ($ORACLE_UID), $GRID_USER ($GRID_UID)"; fi

  # ---- Oracle bases, network admin folder
  ORACLE_BASE=""; GRID_BASE=""
  prim_probe orabase "$DB_HOME" && ORACLE_BASE=$(grep -m1 -E '^/' <<< "$RUN_OUT")
  ORACLE_BASE=${ORACLE_BASE%/}
  v_path "$ORACLE_BASE" || { bad "Cannot read the ORACLE_BASE of $DB_HOME (orabase failed)."; return 1; }
  if [[ -n "$GRID_HOME" ]]; then
    prim_probe orabase "$GRID_HOME" && GRID_BASE=$(grep -m1 -E '^/' <<< "$RUN_OUT")
    GRID_BASE=${GRID_BASE%/}
    v_path "$GRID_BASE" || GRID_BASE=""
  fi
  if [[ -z "$PRIMARY_TNS_ADMIN" ]]; then
    local obh=""
    prim_probe orabasehome "$DB_HOME" && obh=$(grep -m1 -E '^/' <<< "$RUN_OUT")   # 18c and newer only
    obh=${obh%/}
    if v_path "$obh"; then PRIMARY_TNS_ADMIN="$obh/network/admin"; else PRIMARY_TNS_ADMIN="$DB_HOME/network/admin"; fi
  fi

  # ---- database facts (version-neutral SQL, works on 12.1 and newer)
  prim_sql "select d.name||'|'||d.db_unique_name||'|'||d.database_role||'|'||d.cdb||'|'||i.version||'|'||nvl((select value from v\$parameter where name='db_domain'),'-')||'|'||nvl((select upper(value) from v\$parameter where name='cluster_database'),'FALSE')||'|'||d.open_mode from v\$database d, v\$instance i;" \
    || { bad "Cannot query the database on the primary: $(ora_errors "$SQL_OUT")"; printf 'The ssh user %s must be able to run  sqlplus / as sysdba  (it must be in the dba group).\n' "$PRIMARY_SSH_USER" | hint; return 1; }
  local role ver dom rac omode
  IFS='|' read -r DB_NAME PRIMARY_UNIQUE role PRIMARY_CDB ver dom rac omode <<< "$(first_line)"
  [[ "$role" == "PRIMARY" ]] || fatal "Database $PRIMARY_SID on $PRIMARY_HOST has the role $role, not PRIMARY.
Run the script against the primary database."
  [[ "$rac" != "TRUE" ]] || fatal "The primary is a RAC database (cluster_database=TRUE).
This script supports only a single-instance primary."
  v_name "$DB_NAME" && v_name "$PRIMARY_UNIQUE" || { bad "The primary returned an unexpected database name: $DB_NAME, $PRIMARY_UNIQUE"; return 1; }
  [[ "$dom" == "-" ]] && dom=""; [[ -z "$dom" ]] || v_name "$dom" || dom=""; PRIMARY_DOMAIN=$dom
  DB_MAJOR=${ver%%.*}; num "$DB_MAJOR" || { bad "The primary returned an unexpected version: $ver"; return 1; }
  [[ $DB_MAJOR -ge 12 ]] || fatal "The primary runs Oracle $ver. This script supports 12.1 and newer."
  PRIMARY_VERSION=$ver
  if [[ $DB_MAJOR -ge 18 ]] && prim_sql "select version_full from v\$instance;"; then PRIMARY_VERSION=$(first_line); fi
  v_name "$PRIMARY_VERSION" || PRIMARY_VERSION=$ver
  [[ "$omode" == READ\ WRITE* ]] || warn "The primary is open as $omode, not READ WRITE."

  # ---- storage: every place with database files (also the standby redo logs) and how much is there
  local c="case when name like '+%' then upper(regexp_substr(name,'^[+][^/]+')) else substr(name,1,instr(name,'/',-1)-1) end"
  local cm="case when f.member like '+%' then upper(regexp_substr(f.member,'^[+][^/]+')) else substr(f.member,1,instr(f.member,'/',-1)-1) end"
  prim_sql "select loc||':'||round(sum(b)/1048576) from (select $c loc, bytes b from v\$datafile union all select $c, bytes from v\$tempfile union all select $cm, l.bytes from v\$logfile f, v\$log l where f.group#=l.group# union all select $cm, s.bytes from v\$logfile f, v\$standby_log s where f.group#=s.group# union all select $c, block_size*file_size_blks from v\$controlfile) group by loc;" \
    || { bad "Cannot read the locations of the database files: $(ora_errors "$SQL_OUT")"; return 1; }
  LOCS=$(grep -E '^[+/][A-Za-z0-9_./-]*:[0-9]+$' <<< "$SQL_OUT" | paste -sd, -)
  [[ -n "$LOCS" ]] || { bad "Unexpected answer for the file locations: $(head -n 3 <<< "$SQL_OUT")"; return 1; }
  PRIMARY_DB_MB=$(loc_list | awk -F: '{s+=$2} END {print s+0}')
  # block size of the online logs (512 or 4096): the standby logs and their disks must support it
  PRIMARY_REDO_BS=512
  prim_sql "select max(blocksize) from v\$log;" && PRIMARY_REDO_BS=$(first_line | cut -d'|' -f1)
  num "$PRIMARY_REDO_BS" || PRIMARY_REDO_BS=512

  # ---- recovery area, archive destination, folders used by the instance
  read_arch_params || { bad "Cannot read the parameters of the primary database."; return 1; }

  # ---- ASM or file system
  DATA_DG=""
  if [[ -n "$(asm_dgs)" ]]; then
    USE_GRID=yes
    [[ -n "$GRID_HOME" ]] || { bad "The primary uses ASM ($(asm_dgs | paste -sd' ' -)), but its Grid home was not found."; return 1; }
    [[ -n "$GRID_BASE" ]] || { bad "Cannot read the ORACLE_BASE of $GRID_HOME (orabase failed)."; return 1; }
    if [[ "$CFD" == +* ]]; then DATA_DG=$(norm_loc "$CFD"); DATA_DG=${DATA_DG#+}
    else DATA_DG=$(loc_list | grep '^+' | sort -t: -k2,2nr | head -n 1 | cut -d: -f1); DATA_DG=${DATA_DG#+}; fi
    # only the recovery area / archive destination in ASM: Grid is installed with that disk group
    [[ -n "$DATA_DG" ]] || DATA_DG=$(asm_dgs | head -n 1)
    # the Grid release may be newer than the database release (for example Grid 19c with a 12.2 database)
    GRID_REL=""
    if prim_probe gridver "$GRID_HOME"; then
      local gv; gv=$(grep -oE 'VER="[0-9.]+"' <<< "$RUN_OUT" | head -n 1 | grep -oE '[0-9.]+')
      if [[ "$gv" =~ ^([0-9]+)\.([0-9]+) ]]; then
        if [[ ${BASH_REMATCH[1]} == 12 ]]; then GRID_REL="12.${BASH_REMATCH[2]}"; else GRID_REL=${BASH_REMATCH[1]}; fi
      fi
    fi
    if [[ -z "$GRID_REL" ]]; then
      GRID_REL=$(want_rel db)
      DISC_NOTES+=("The Grid release of the primary could not be read from $GRID_HOME/inventory/ContentsXML/comps.xml.
Grid $GRID_REL is assumed, the same as the database.")
    fi
  else
    USE_GRID=no; GRID_REL=""
    # no ASM on the standby: no Grid; the listener runs from the database home
    GRID_HOME=""; GRID_BASE=""; GRID_USER=$ORACLE_USER; GRID_UID=$ORACLE_UID; GRID_PGROUP=$INSTALL_GROUP; GRID_GROUPS=""
  fi
  ok "Database: $DB_NAME, unique name $PRIMARY_UNIQUE, $PRIMARY_VERSION, CDB $PRIMARY_CDB, $(human_mb "$PRIMARY_DB_MB")"
  local sl="" l; for l in $(tr ',' ' ' <<< "$LOCS"); do sl+="${sl:+, }${l%:*} ($(human_mb "${l##*:}"))"; done
  ok "Storage: database files in $sl${FRA_LOC:+
Recovery area: $FRA_LOC}"

  # ---- listener: the running tnslsnr that offers this database's service.
  #      Only a tnslsnr that runs as an Oracle owner from a program of that owner is asked.
  local want="${PRIMARY_UNIQUE}${PRIMARY_DOMAIN:+.$PRIMARY_DOMAIN}" lu lh ln lp found=0 p svc lta
  local sv_port=$PORT sv_ln=$LISTENER_NAME sv_svc=$PRIMARY_SERVICE sv_lh=$PRIMARY_LISTENER_HOME
  LISTENER_NAME=LISTENER; PORT=1521; PRIMARY_LISTENER_HOME=${GRID_HOME:-$DB_HOME}; PRIMARY_SERVICE=$want; LSNR_ASSUMED=0
  while read -r lp lu lh ln; do
    v_path "$lh" && v_name "$ln" && v_name "$lu" && num "$lp" || continue
    [[ "$lu" == "$ORACLE_USER" || "$lu" == "$GRID_USER" ]] || continue
    trusted_prog "$lh/bin/lsnrctl" "$lu" || continue
    # the listener may read its listener.ora from a TNS_ADMIN of its own (readable only as its owner)
    lta=""; if prim_probe environ "$lp"; then lta=$(sed -n 's/^TNS_ADMIN=//p' <<< "$RUN_OUT" | head -n 1); lta=${lta%/}; v_path "$lta" || lta=""; fi
    # its own TNS_ADMIN; else its home's network/admin (no TNS_ADMIN); a listener of the database home may
    # also use the TNS_ADMIN of the database
    local tries=() t; [[ -n "$lta" ]] && tries=("$lta") || tries=("-")
    [[ -z "$lta" && "$lh" == "$DB_HOME" && -n "${PRIMARY_TNS_ADMIN:-}" ]] && tries+=("$PRIMARY_TNS_ADMIN")
    svc=""
    for t in "${tries[@]}"; do
      if [[ "$t" == "-" ]]; then prim_probe lsnr "$lh" "$ln" || continue; else prim_probe lsnr "$lh" "$ln" "$t" || continue; fi
      svc=$(grep -oE 'Service "[^"]+"' <<< "$RUN_OUT" | cut -d'"' -f2 | grep -ix -- "$want" | head -n 1)
      [[ -n "$svc" ]] && { PRIMARY_LISTENER_TNS_ADMIN=${t#-}; break; }
    done
    [[ -n "$svc" ]] || continue
    p=$(norm "$RUN_OUT" | grep -oE '\(PROTOCOL=TCP\)\(HOST=[^)]*\)\(PORT=[0-9]+\)' | head -n 1 | grep -oE '[0-9]+\)$' | tr -d ')')
    LISTENER_NAME=$ln; PRIMARY_LISTENER_HOME=$lh; PRIMARY_SERVICE=$svc; num "$p" && PORT=$p; found=1; break
  done < <(awk '{ for (i = 3; i <= NF; i++) if ($i ~ /\/bin\/tnslsnr$/) { h=$i; sub(/\/bin\/tnslsnr$/, "", h); print $1, $2, h, $(i+1); break } }' <<< "$PS_OUT")
  if [[ $found -eq 1 ]]; then ok "Listener $LISTENER_NAME on port $PORT, service $PRIMARY_SERVICE
Listener home: $PRIMARY_LISTENER_HOME"
  else
    LSNR_ASSUMED=1
    # values the admin corrected in the settings of an earlier run are kept
    if [[ -n "$sv_port" && -n "$sv_ln" && -n "$sv_svc" && ( "$sv_port" != "1521" || "$sv_ln" != "LISTENER" || "$sv_svc" != "$want" ) ]]; then
      PORT=$sv_port; LISTENER_NAME=$sv_ln; PRIMARY_SERVICE=$sv_svc; [[ -n "$sv_lh" ]] && PRIMARY_LISTENER_HOME=$sv_lh
      warn "No running listener on the primary offers the service $want.
Using your settings: $LISTENER_NAME, port $PORT, service $PRIMARY_SERVICE."
    else
      warn "No running listener on the primary offers the service $want.
Assuming LISTENER, port $PORT, service $want."
      say "If that is wrong, correct it in step 1.4 (choose e), or later with  $SELF --settings"
    fi
  fi

  # ---- TDE (12.1+ view; an empty answer means no wallet). 18c+: wallet_root / tde_configuration
  TDE_INFO=""; WALLET_ROOT=""; TDE_CONFIG=""
  # wallet_type (12.1.0.2+): LOCAL_AUTOLOGIN wallets open only on the host that made them
  if prim_sql "select wrl_type||'|'||nvl(wrl_parameter,'-')||'|'||status||'|'||nvl(wallet_type,'-') from v\$encryption_wallet;"; then TDE_INFO=$SQL_OUT
  else prim_sql "select wrl_type||'|'||nvl(wrl_parameter,'-')||'|'||status from v\$encryption_wallet;" && TDE_INFO=$SQL_OUT; fi
  if [[ $DB_MAJOR -ge 18 ]] && prim_sql "select name||'|'||nvl(value,'-') from v\$parameter where name in ('wallet_root','tde_configuration');"; then
    local wn wv
    while IFS='|' read -r wn wv; do
      case "$wn" in wallet_root) [[ "$wv" != "-" ]] && WALLET_ROOT=${wv%/}; [[ -z "$WALLET_ROOT" ]] || v_path "$WALLET_ROOT" || { DISC_NOTES+=("wallet_root on the primary is '$WALLET_ROOT', which is not a folder.
Copy the TDE wallet by hand in step 6.3.");WALLET_ROOT=""; } ;; tde_configuration) [[ "$wv" != "-" ]] && TDE_CONFIG=$wv ;; esac

    done <<< "$SQL_OUT"
  fi

  local n; for n in "${DISC_NOTES[@]+"${DISC_NOTES[@]}"}"; do warn "$n"; done
  set_primary_how
  DISCOVERED=1
  DONE_MSG="Primary configuration read"
}

inventory_homes() {
  # the Oracle homes registered on the primary (read-only: cat of inventory.xml), newest first
  local inv=${INVENTORY_DIR:-}
  [[ -n "$inv" ]] || { prim_probe orainst && inv=$(sed -n 's/^inventory_loc=//p' <<< "$RUN_OUT" | head -n 1); }
  v_path "$inv" || return 0
  prim_probe invxml "$inv" || return 0
  grep -oE 'LOC="[^"]+"' <<< "$RUN_OUT" | cut -d'"' -f2 | tac
  return 0
}
LSNR_ASSUMED=0; PRIMARY_LISTENER_TNS_ADMIN=""
assumed_key() { [[ $LSNR_ASSUMED -eq 1 && ( "$1" == PORT || "$1" == LISTENER_NAME || "$1" == PRIMARY_SERVICE ) ]]; }
