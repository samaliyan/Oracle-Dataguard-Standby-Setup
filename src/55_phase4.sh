#------------------------------------------------------------------------------
# PHASE 4  Primary readiness
#   Every check here is a SELECT (or lsnrctl status / tnsping) on primary.
#   Nothing is changed on primary: needed commands are printed for you.
#------------------------------------------------------------------------------
P_ORL_COUNT=0; P_ORL_BYTES=0; PVAL=""; SRL_BLOCKSIZE=""

need_ssh() {
  ssh_alive && return 0
  if [[ $SSH_OPEN -eq 1 ]]; then
    # the connection was open before (for example it timed out during a long duplicate)
    warn "The ssh connection to the primary was closed. Reconnecting."
    open_ssh && ssh_alive && return 0
  fi
  NOW="Not connected to the primary (step 1.2)"; return 1
}

p_param() {
  # $1 name -> PVAL (upper case, quotes removed, spaces collapsed). Read-only.
  [[ "$1" =~ ^[a-z0-9_]+$ ]] || fatal "Safety stop: invalid parameter name: $1"
  prim_sql "select nvl(value,'-') from v\$parameter where name='$1';" || return 1
  PVAL=$(first_line | tr '[:lower:]' '[:upper:]' | tr -d "\"'" | tr -s '[:space:]' ' ' | sed -E 's/ *= */=/g; s/\( */(/g; s/ *\)/)/g; s/ *, */,/g')
}
has_token() {
  local t arr=()
  read -ra arr <<< "$(printf '%s' "$1" | tr ',()' '   ')"
  for t in "${arr[@]}"; do [[ "$t" == "$2" ]] && return 0; done
  return 1
}
disp_val() { if [[ -z "$1" || "$1" == "-" ]]; then printf '(not set)'; else printf '%s' "$1"; fi; }   # on screen only: "-" (no value) as "(not set)"
dg_config_has() {
  local inner=${1#*DG_CONFIG=}
  [[ "$inner" != "$1" ]] || return 1
  has_token "$inner" "${2^^}"
}

# ---- 4.1 ----
c_4_1() {
  need_ssh || return 2
  # every change of phase 4 (scope=spfile/both) and the duplicate (spfile clause) needs a primary started from an spfile
  prim_sql "select nvl(value,'-') from v\$parameter where name='spfile';" || { NOW="Query on the primary failed ($(ora_errors "$SQL_OUT"))"; return 2; }
  if [[ "$(first_line)" == "-" ]]; then
    NOW="The primary was started from a text pfile, not from an spfile."$'\n'"The changes of this phase and the RMAN copy need an spfile."
    PLAN="create pfile='?/dbs/init${PRIMARY_SID}_before_dg.ora' from memory;
create spfile from memory;
-- Then restart the primary once (shutdown immediate; startup) at a quiet time.
-- After the restart it uses the spfile. The other changes of this phase need it."
    PLAN_UNDO="delete \$ORACLE_HOME/dbs/spfile${PRIMARY_SID}.ora, then restart with:  startup pfile='\$ORACLE_HOME/dbs/init${PRIMARY_SID}_before_dg.ora'"
    return 1
  fi
  prim_sql "select log_mode||'|'||force_logging from v\$database;" || { NOW="Query on the primary failed ($(ora_errors "$SQL_OUT"))"; return 2; }
  local lm fl; IFS='|' read -r lm fl <<< "$(first_line)"
  if [[ "$lm" == "ARCHIVELOG" && "$fl" == "YES" ]]; then NOW="ARCHIVELOG mode and FORCE LOGGING are on"; return 0; fi
  NOW="log_mode is $lm, force_logging is $fl"
  PLAN=""
  [[ "$fl" != "YES" ]] && PLAN+="alter database force logging;"$'\n'
  [[ "$lm" != "ARCHIVELOG" ]] && PLAN+="-- DOWNTIME: the next 4 lines restart the primary database
shutdown immediate
startup mount
alter database archivelog;
alter database open;"
  PLAN=${PLAN%$'\n'}
  PLAN_UNDO=""; [[ "$fl" != "YES" ]] && PLAN_UNDO="alter database no force logging;"
  [[ "$lm" != "ARCHIVELOG" ]] && PLAN_UNDO+="${PLAN_UNDO:+ }-- keep ARCHIVELOG mode (every backup needs it)"
  return 1
}

# ---- 4.2 ----
SRL_STMTS=""; SRL_INFO=""
srl_statements() {
  # $1 = prim_sql | sql_local. Standby redo logs needed: per thread (online groups + 1), size = largest online log.
  # Sets SRL_STMTS (the ALTER statements, empty when nothing is needed) and SRL_INFO. rc 2 = query failed.
  local run=$1 t c mb maxb have omf maxg dir spec g line
  "$run" "select thread#||'|'||count(*)||'|'||max(bytes) from v\$log group by thread# order by thread#;" || return 2
  local threads=$SQL_OUT
  "$run" "select thread#||'|'||count(*) from v\$standby_log where bytes>=(select max(bytes) from v\$log) group by thread#;" || return 2
  local good=$SQL_OUT
  "$run" "select (select max(blocksize) from v\$log)||'|'||(select count(*) from v\$standby_log where bytes<(select max(bytes) from v\$log)) from dual;" || return 2
  local bsz small; IFS='|' read -r bsz small <<< "$(first_line)"
  local bclause=""; [[ "$bsz" == "4096" ]] && bclause=" blocksize 4096"
  SRL_BLOCKSIZE=$bsz
  [[ -n "$bclause" ]] && SRL_INFO_EXTRA="The online logs use 4096-byte blocks."$'\n'"The standby disks must support 4K sectors, or you get ORA-01378." || SRL_INFO_EXTRA=""
  # standby logs without a thread (thread 0) can serve any thread
  local pool0; pool0=$(awk -F'|' '$1==0 {print $2}' <<< "$good"); num "$pool0" || pool0=0
  "$run" "select (select nvl(max(value),'-') from v\$parameter where name in ('db_create_file_dest','db_create_online_log_dest_1') and value is not null)||'|'||(select max(group#) from (select group# from v\$log union all select group# from v\$standby_log))||'|'||nvl((select min(substr(member,1,instr(member,'/',-1)-1)) keep (dense_rank first order by group#, member) from v\$logfile where type='ONLINE' and upper(member) not like (select upper(nvl(max(value),'#none#'))||'%' from v\$parameter where name='db_recovery_file_dest')),(select max(substr(member,1,instr(member,'/',-1)-1)) from v\$logfile where type='ONLINE')) from dual;" || return 2
  IFS='|' read -r omf maxg dir <<< "$(first_line)"
  num "$maxg" || return 2
  maxb=$(awk -F'|' '{if ($3 > m) m = $3} END {print m+0}' <<< "$threads")
  num "$maxb" && [[ $maxb -gt 0 ]] || return 2
  mb=$(( (maxb + 1048575) / 1048576 )); g=$maxg
  SRL_STMTS=""; SRL_INFO=""
  while IFS='|' read -r t c _; do
    num "$t" && num "$c" || continue
    have=$(awk -F'|' -v t="$t" '$1==t {print $2}' <<< "$good"); num "$have" || have=0
    SRL_INFO+="Thread $t: $c online log groups. Standby logs: $have of $((c + 1)) needed (${mb}M each)"$'\n'
    while [[ $have -lt $((c + 1)) && $pool0 -gt 0 ]]; do have=$((have + 1)); pool0=$((pool0 - 1)); done
    while [[ $have -lt $((c + 1)) ]]; do
      if [[ "$omf" != "-" && -n "$omf" ]]; then spec=""
      elif [[ "$dir" == +* ]]; then spec=" ('${dir%%/*}')"
      else g=$((g + 1)); spec=" group $g ('$dir/srl_t${t}_g${g}.log')"; fi
      SRL_STMTS+="alter database add standby logfile thread $t$spec size ${mb}M$bclause;"$'\n'
      have=$((have + 1))
    done
  done <<< "$threads"
  num "$small" && [[ $small -gt 0 ]] && SRL_INFO+="$small standby log(s) are smaller than the online logs and do not count."$'\n'"Drop them with:  alter database drop standby logfile group <n>;"$'\n'
  [[ -n "$SRL_INFO_EXTRA" ]] && SRL_INFO+="$SRL_INFO_EXTRA"$'\n'
  SRL_INFO=${SRL_INFO%$'\n'}; SRL_STMTS=${SRL_STMTS%$'\n'}
  [[ -z "$SRL_STMTS" ]]
}
c_4_2() {
  need_ssh || return 2
  local rc=0; srl_statements prim_sql || rc=$?
  [[ $rc -eq 2 ]] && { NOW="Query on the primary failed ($(ora_errors "$SQL_OUT"))"; return 2; }
  NOW=$SRL_INFO
  [[ $rc -eq 0 ]] && return 0
  PLAN=$SRL_STMTS
  USING="Per thread: online log groups + 1, each as large as the largest online log"
  local gl; gl=$(grep -oE 'group [0-9]+' <<< "$SRL_STMTS" | awk '{print $2}' | paste -sd',' -)
  if [[ -n "$gl" ]]; then PLAN_UNDO="alter database drop standby logfile group <n>;  for groups $gl, then delete their files"
  else PLAN_UNDO="alter database drop standby logfile group <n>;  for each new group. To list them:  select group#,thread#,bytes from v\$standby_log;"; fi
  return 1
}

# ---- 4.3 ----
c_4_3() {
  need_ssh || return 2
  p_param log_archive_config || { NOW="Query on the primary failed"; return 2; }
  if dg_config_has "$PVAL" "$PRIMARY_UNIQUE" && dg_config_has "$PVAL" "$STANDBY_UNIQUE"; then NOW="log_archive_config = $(disp_val "$PVAL")"; return 0; fi
  NOW="log_archive_config = $(disp_val "$PVAL")"
  dg_config_names_ok "$PVAL" || { NOW+=$'\n'"The names in this list cannot be read safely."$'\n'"Add $STANDBY_UNIQUE to the dg_config list by hand. Keep all other names."; return 2; }
  PLAN="alter system set log_archive_config='$(lac_merged "$PVAL")' scope=both;"
  [[ "$PVAL" == *DG_CONFIG=* ]] && PLAN+=$'\n'"-- This keeps the names already in the list and adds $STANDBY_UNIQUE."
  if [[ "$PVAL" == *DG_CONFIG=* ]]; then PLAN_UNDO="alter system set log_archive_config='$PVAL' scope=both;"
  else PLAN_UNDO="alter system reset log_archive_config scope=both;"; fi
  return 1
}
dg_config_merged() {
  # $1 current value -> comma list: existing members (in their order) + primary + standby, no doubles
  local inner="" t out="" seen=" "
  [[ "$1" == *DG_CONFIG=* ]] && { inner=${1#*DG_CONFIG=}; inner=${inner#(}; inner=${inner%%)*}; }
  for t in $(tr ',' ' ' <<< "$inner") "$PRIMARY_UNIQUE" "$STANDBY_UNIQUE"; do
    [[ -n "$t" ]] || continue
    [[ "$seen" == *" ${t^^} "* ]] && continue
    seen+="${t^^} "; out+="${out:+,}$t"
  done
  printf '%s' "$out"
}
lac_merged() {
  # $1 current log_archive_config (p_param form) -> the full new value: other keywords (SEND, NORECEIVE ...) kept,
  # dg_config = the existing names + primary + standby
  local v=$1 pre post rest m
  m=$(dg_config_merged "$v")
  if [[ "$v" == *DG_CONFIG=* ]]; then
    pre=${v%%DG_CONFIG=*}; rest=${v#*DG_CONFIG=}; post=""
    [[ "$rest" == *")"* ]] && post=${rest#*)}
    printf '%sdg_config=(%s)%s' "$pre" "$m" "$post"
  elif [[ -z "$v" || "$v" == "-" ]]; then printf 'dg_config=(%s)' "$m"
  else
    # NODG_CONFIG would contradict the new list: it goes
    local rest2; rest2=$(tr ',' '\n' <<< "$v" | grep -vx 'NODG_CONFIG' | paste -sd, -)
    if [[ -n "$rest2" ]]; then printf '%s,dg_config=(%s)' "$rest2" "$m"; else printf 'dg_config=(%s)' "$m"; fi
  fi
}
dg_config_names_ok() {
  # 1 when the value has DG_CONFIG but no name can be read from it (then nothing is printed: a wrong list would cut off another standby)
  [[ "$1" == *DG_CONFIG=* ]] || return 0
  local inner=${1#*DG_CONFIG=}; inner=${inner#(}; inner=${inner%%)*}
  [[ "$inner" =~ ^[A-Z0-9_$#]+(,[A-Z0-9_$#]+)*$ ]]
}

# ---- 4.4 ----
DEST_N=""
find_dest() {
  # Which log_archive_dest_N on primary ships (or will ship) to this standby. Read-only.
  # 1) an N that already points to the standby alias, 2) dest_2 if it is free, 3) the first free N.
  prim_sql "select name||'|'||nvl(value,'-') from v\$parameter where name like 'log_archive_dest_%';" || return 1
  local line n v used=" "
  DEST_N=""
  while IFS= read -r line; do
    [[ "$line" =~ ^log_archive_dest_([0-9]+)\|(.*)$ ]] || continue
    n=${BASH_REMATCH[1]}; v=$(tr '[:lower:]' '[:upper:]' <<< "${BASH_REMATCH[2]}" | tr -d "\"'" | sed -E 's/ *= */=/g')
    num "$n" && [[ $n -ge 2 && $n -le 31 ]] || continue
    if has_token "$v" "SERVICE=${STANDBY_TNS^^}"; then DEST_N=$n; return 0; fi
    [[ "$v" == "-" ]] || used+="$n "
  done <<< "$SQL_OUT"
  # a destination without a value (or not listed) is free; prefer 2
  for ((n = 2; n <= 31; n++)); do [[ "$used" == *" $n "* ]] || { DEST_N=$n; return 0; }; done
  return 1
}
c_4_4() {
  need_ssh || return 2
  # log_archive_dest may have been moved on the primary since it was read (answer r): read it again
  if [[ -n "$OLD_ARCH_DEST" ]]; then read_arch_params || { NOW="Cannot read the archive parameters on the primary"; return 2; }; fi
  find_dest || { NOW="No free log_archive_dest_N on the primary"; return 2; }
  p_param "log_archive_dest_$DEST_N" || { NOW="Query on the primary failed"; return 2; }
  if has_token "$PVAL" "SERVICE=${STANDBY_TNS^^}" && has_token "$PVAL" "DB_UNIQUE_NAME=${STANDBY_UNIQUE^^}"; then NOW="log_archive_dest_$DEST_N points to the standby:"$'\n'"  $PVAL"; return 0; fi
  NOW="log_archive_dest_$DEST_N = $(disp_val "$PVAL")"
  [[ "$DEST_N" != "2" ]] && NOW+=$'\n'"log_archive_dest_2 is used for something else, so log_archive_dest_$DEST_N is used"
  PLAN=""
  if [[ -n "$OLD_ARCH_DEST" ]]; then
    NOW+=$'\n'"The primary uses the old parameter log_archive_dest."$'\n'"log_archive_dest_N cannot be used together with it (ORA-16018)."
    # the duplex folder exactly as written (p_param changes the case)
    local dup="-"; prim_sql "select nvl(value,'-') from v\$parameter where name='log_archive_duplex_dest';" && dup=$(first_line)
    PLAN="-- First move log_archive_dest to log_archive_dest_1 (same folder).
-- Run these lines together: between them the archiver writes to \$ORACLE_HOME/dbs.
"
    if [[ -n "$dup" && "$dup" != "-" ]]; then
      local dn=3; [[ "$DEST_N" == "3" ]] && dn=4
      PLAN+="alter system set log_archive_duplex_dest='' scope=both;
alter system set log_archive_dest='' scope=both;
alter system set log_archive_dest_1='location=$OLD_ARCH_DEST' scope=both;
alter system set log_archive_dest_$dn='location=$dup' scope=both;     -- the duplex folder, kept (check that dest_$dn is free)
"
    else
      PLAN+="alter system set log_archive_dest='' scope=both;
alter system set log_archive_dest_1='location=$OLD_ARCH_DEST' scope=both;
"
    fi
  fi
  # the state first: an enabled destination to a standby that does not exist yet fills the alert log with errors
  PLAN+="alter system set log_archive_dest_state_$DEST_N=defer scope=both;
alter system set log_archive_dest_$DEST_N='service=$STANDBY_TNS async valid_for=(online_logfiles,primary_role) db_unique_name=$STANDBY_UNIQUE' scope=both;
-- Step 9.5 enables it, after the standby exists."
  PLAN_UNDO="alter system reset log_archive_dest_$DEST_N scope=both; alter system reset log_archive_dest_state_$DEST_N scope=both;"
  [[ -n "$OLD_ARCH_DEST" ]] && PLAN_UNDO+="   (log_archive_dest_1='location=$OLD_ARCH_DEST' can stay)"
  return 1
}

# ---- 4.5 ----
c_4_5() {
  need_ssh || return 2
  p_param standby_file_management || { NOW="Query on the primary failed"; return 2; }
  [[ "$PVAL" == "AUTO" ]] && { NOW="standby_file_management = AUTO"; return 0; }
  NOW="standby_file_management = $(disp_val "$PVAL")"
  PLAN="alter system set standby_file_management=auto scope=both;"
  local sfm_old=$PVAL; [[ -z "$sfm_old" || "$sfm_old" == "-" ]] && sfm_old=MANUAL    # "-" means not set (MANUAL is the default)
  PLAN_UNDO="alter system set standby_file_management=$sfm_old scope=both;"
  return 1
}

# ---- 4.6 ----
c_4_6() {
  need_ssh || return 2
  # read again from the primary: a change made at this step is seen at once
  local of=$FRA_LOC oa=$ARCH_LOC
  read_arch_params || { NOW="Cannot read the archive parameters on the primary"; return 2; }
  [[ "$of|$oa" != "$FRA_LOC|$ARCH_LOC" && "$MODE" == "run" ]] && { save_settings; warn "The recovery area or archive destination on the primary changed."$'\n'"Recovery area: ${FRA_LOC:-none}   Archive destination: ${ARCH_LOC:-none}"$'\n'"$( { step_in_range 2.12 && [[ -z "${STEP_RESULT[2.12]:-}" ]]; } && printf 'Phase 2 of this run uses the new values.' || printf 'This server needs it too. After this run, run:  %s --from 2.12' "$SELF")"; }
  if [[ "$ARCH_LOC" == "USE_DB_RECOVERY_FILE_DEST" && -n "$FRA_LOC" ]]; then NOW="Archived logs go to the recovery area $FRA_LOC ($(human_mb "$FRA_MB"))"; return 0; fi
  if [[ -n "$ARCH_LOC" && "$ARCH_LOC" != "USE_DB_RECOVERY_FILE_DEST" ]]; then
    NOW="Archived logs go to $ARCH_LOC${FRA_LOC:+ (recovery area $FRA_LOC)}"
    [[ -n "$FRA_LOC" ]] || NOW+=$'\n'"No recovery area. Data Guard works without it."$'\n'"Flashback and automatic deletion of applied logs need one."
    return 0
  fi
  NOW="The primary has no archive destination and no recovery area."$'\n'"Its archived logs go to \$ORACLE_HOME/dbs."
  if [[ -n "$DATA_DG" ]]; then
    PLAN="alter system set db_recovery_file_dest_size=<size, e.g. 200G> scope=both;
alter system set db_recovery_file_dest='+<a disk group for it, e.g. FRA>' scope=both;"
  else
    PLAN="-- Use a folder with enough space, owned by $ORACLE_USER, for example:
host mkdir -p /u01/app/oracle/fast_recovery_area
alter system set db_recovery_file_dest_size=<size, e.g. 200G> scope=both;
alter system set db_recovery_file_dest='/u01/app/oracle/fast_recovery_area' scope=both;"
  fi
  PLAN+=$'\n'"-- The archived logs of the primary then go there. Then answer r here."
  PLAN_UNDO="alter system reset db_recovery_file_dest scope=both; alter system reset db_recovery_file_dest_size scope=both;  only after the archived logs in it are backed up"
  return 1
}

# ---- 4.7 ----
c_4_7() {
  need_ssh || return 2
  p_param remote_login_passwordfile || { NOW="Query on the primary failed"; return 2; }
  local rlp=$PVAL
  prim_sql "select count(*) from v\$pwfile_users where username='SYS' and sysdba='TRUE';" || { NOW="Query on the primary failed"; return 2; }
  local n; n=$(first_line); num "$n" || { NOW="Unexpected answer from the primary: $n"; return 2; }
  if [[ ( "$rlp" == "EXCLUSIVE" || "$rlp" == "SHARED" ) && "$n" -ge 1 ]]; then NOW="remote_login_passwordfile = $rlp, SYS has SYSDBA in the password file"; RLP_PENDING=0; return 0; fi
  NOW="remote_login_passwordfile = $rlp, SYS in the password file: $([[ "$n" -ge 1 ]] && echo yes || echo no)"
  PLAN=""; PLAN_UNDO=""; RLP_PENDING=0
  if [[ "$rlp" != "EXCLUSIVE" && "$rlp" != "SHARED" ]]; then
    # already set in the spfile? then only the restart is missing
    local sp="-"
    prim_sql "select nvl(max(upper(value)),'-') from v\$spparameter where name='remote_login_passwordfile';" && sp=$(first_line | tr -d "\"'")
    if [[ "$sp" == "EXCLUSIVE" || "$sp" == "SHARED" ]]; then
      RLP_PENDING=1
      NOW+=$'\n'"remote_login_passwordfile=$sp is already in the spfile."
      NOW+=$'\n'"It takes effect when the primary restarts."
      NOW+=$'\n'"Answer s for now. The RMAN copy (step 8.1) does not start until the primary has restarted."
      PLAN="-- Restart the primary at a quiet time (as $ORACLE_USER, sqlplus / as sysdba):
shutdown immediate
startup"
    else
      PLAN+="alter system set remote_login_passwordfile=exclusive scope=spfile;
-- Then restart the primary at a quiet time."$'\n'
      PLAN_UNDO="alter system set remote_login_passwordfile=${rlp:-NONE} scope=spfile;  then restart"
    fi
  fi
  if [[ "$n" -lt 1 ]]; then
    # is there a password file at all? ("alter user" cannot create one; with remote_login_passwordfile=NONE the
    # view of its users is empty even when the file exists)
    local pwf="" ans=""
    prim_sql "select nvl(max(file_name),'-') from v\$passwordfile_info;" && pwf=$(first_line)
    if [[ -z "$pwf" || "$pwf" == "-" ]]; then
      prim_probe exists "$DB_HOME/dbs/orapw$PRIMARY_SID"; ans=$(head -n 1 <<< "$RUN_OUT")
      case "$ans" in YES) pwf="$DB_HOME/dbs/orapw$PRIMARY_SID" ;; NO) pwf="-" ;; *) pwf="?" ;; esac
    fi
    if [[ "$pwf" == "-" && -n "$GRID_HOME" ]]; then
      NOW+=$'\n'"The password file may be in ASM. Check on the primary as $ORACLE_USER:"
      NOW+=$'\n'"  $DB_HOME/bin/srvctl config database -db $PRIMARY_UNIQUE | grep -i password"
    fi
    if [[ "$pwf" == "?" ]]; then
      NOW+=$'\n'"No answer from the primary: cannot tell if it has a password file. Check again later."; return 2
    elif [[ "$pwf" == "-" ]]; then
      local fmt=12.2; [[ "$PRIMARY_VERSION" == 12.1* ]] && fmt=12
      if [[ -n "$GRID_HOME" && "$CFD" == +* ]]; then
        PLAN="-- The primary has no password file. Create it in ASM.
-- Run orapwd in a SHELL as $GRID_USER or $ORACLE_USER, not in sqlplus.
-- orapwd asks for the sys password: type the same one the primary uses now.
-- If orapwd answers OPW-00029 (password complexity), use format=12.
orapwd file='$(norm_loc "$CFD")/${PRIMARY_UNIQUE^^}/orapw${PRIMARY_UNIQUE,,}' dbuniquename=$PRIMARY_UNIQUE format=$fmt
-- Only if 'srvctl config database -db $PRIMARY_UNIQUE' works (the database is registered):
srvctl modify database -db $PRIMARY_UNIQUE -pwfile '$(norm_loc "$CFD")/${PRIMARY_UNIQUE^^}/orapw${PRIMARY_UNIQUE,,}'
-- If this step still says SYS is missing afterwards, restart the primary once."$'\n'"$PLAN"
      else
        PLAN="-- The primary has no password file. Create it with orapwd
-- in a SHELL as $ORACLE_USER, not in sqlplus.
-- orapwd asks for the sys password: type the same one the primary uses now.
-- If orapwd answers OPW-00029 (password complexity), use format=12.
orapwd file=\$ORACLE_HOME/dbs/orapw$PRIMARY_SID format=$fmt"$'\n'"$PLAN"
      fi
      PLAN_UNDO+="${PLAN_UNDO:+ ; }delete the new password file"
    elif [[ "$rlp" != "EXCLUSIVE" && "$rlp" != "SHARED" ]]; then
      NOW+=$'\n'"The password file exists: $pwf. SYS is checked again after the restart."
    else
      PLAN+="alter user sys identified by \"<the same sys password as now>\";
-- Keep the same password: every client that logs in as sys uses it.
-- A password change cannot be taken back."
    fi
  fi
  PLAN=${PLAN%$'\n'}
  return 1
}
RLP_PENDING=0

# ---- 4.8 ----
c_4_8() {
  need_ssh || return 2
  p_param fal_server || { NOW="Query on the primary failed"; return 2; }
  if has_token "$PVAL" "${STANDBY_TNS^^}"; then NOW="fal_server = $PVAL"; return 0; fi
  NOW="fal_server = $(disp_val "$PVAL")"
  PLAN="alter system set fal_server='$STANDBY_TNS' scope=both;"
  PLAN_UNDO="alter system reset fal_server scope=both;"
  return 1
}

# ---- 4.9 ----
tns_block() {
  printf '%s =\n  (DESCRIPTION =\n    (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))\n    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = %s)(UR = A))\n  )\n' "$1" "$2" "$PORT" "$3"
}
tns_desc_ok() {
  # $1 tnsping output, $2 host, $3 service -> 0 if the resolved descriptor matches
  local d eh; d=$(norm "$(grep -i 'Attempting to contact' <<< "$1")")
  [[ "$d" =~ \(HOST=([^\)]*)\) ]] || { TNS_WHY="no HOST in the entry"; return 1; }
  eh=${BASH_REMATCH[1]}
  if [[ "$eh" != "${2^^}" ]]; then
    local a1 a2
    if [[ "$eh" =~ ^[0-9.]+$ ]]; then a1=$eh; else a1=$(getent ahostsv4 "${eh,,}" | awk '{print $1; exit}'); fi
    a2=$(getent ahostsv4 "$2" | awk '{print $1; exit}')
    [[ -n "$a1" && "$a1" == "$a2" ]] || { TNS_WHY="HOST is ${eh,,}, expected $2"; return 1; }
  fi
  [[ "$d" == *"(SERVICE_NAME=${3^^})"* ]] || { TNS_WHY="SERVICE_NAME is not $3"; return 1; }
  [[ "$d" == *"(UR=A)"* ]] || { TNS_WHY="(UR = A) is missing"; return 1; }
  [[ "$d" == *"(PORT=$PORT)"* ]] || { TNS_WHY="PORT is not $PORT"; return 1; }
  return 0
}
tnsping_class() {
  # $1 tnsping output -> OK | NOLISTENER (alias resolved, nothing answers there yet) | MISSING | OTHER
  if grep -q '^OK' <<< "$1"; then printf 'OK'
  elif grep -qE 'TNS-12541|TNS-12543|TNS-12535|TNS-12170|TNS-12560|TNS-12547' <<< "$1" && grep -qi 'Attempting to contact' <<< "$1"; then printf 'NOLISTENER'
  elif grep -qE 'TNS-03505|TNS-12154' <<< "$1" || ! grep -qi 'adapter' <<< "$1"; then printf 'MISSING'
  else printf 'OTHER'; fi
}
c_4_9() {
  need_ssh || return 2
  PRIMARY_HOW_STEP="$ORACLE_USER  ->  shell"
  local cls=MISSING
  prim_probe tnsping "$DB_HOME" "$PRIMARY_TNS_ADMIN" "$STANDBY_TNS" || true
  [[ $PROBE_TIMED_OUT -eq 1 ]] && { NOW="tnsping on the primary gave no answer within 120 seconds. Answer r to check again."; return 2; }
  cls=$(tnsping_class "$RUN_OUT")
  PLAN_UNDO="remove the $STANDBY_TNS entry from $PRIMARY_TNS_ADMIN/tnsnames.ora, or put back the backup if you changed an existing entry"
  if [[ "$cls" == "OK" || "$cls" == "NOLISTENER" ]] && grep -qi 'TNSNAMES adapter' <<< "$RUN_OUT"; then
    if tns_desc_ok "$RUN_OUT" "$STANDBY_HOST" "$STANDBY_SERVICE"; then
      NOW="tnsnames.ora on the primary has $STANDBY_TNS = $STANDBY_HOST:$PORT/$STANDBY_SERVICE (UR=A)"
      [[ "$cls" == "NOLISTENER" ]] && NOW+=$'\n'"The alias is right. Nothing answers on this server yet: the listener comes in phase 5."
      return 0
    fi
    NOW="The alias $STANDBY_TNS on the primary is different: $TNS_WHY"
    PLAN="-- Edit $PRIMARY_TNS_ADMIN/tnsnames.ora on the primary.
-- Back it up first (cp -p tnsnames.ora tnsnames.ora.bak_\$(date +%F)). The entry must be:
$(tns_block "$STANDBY_TNS" "$STANDBY_HOST" "$STANDBY_SERVICE")"
    return 1
  fi
  [[ "$cls" == "OTHER" ]] && { NOW="tnsping $STANDBY_TNS on the primary gave an unexpected answer: $(ora_errors "$RUN_OUT")"; return 2; }
  NOW="The alias $STANDBY_TNS is missing from tnsnames.ora on the primary:"$'\n'"  $PRIMARY_TNS_ADMIN/tnsnames.ora"
  PLAN="cp -p $PRIMARY_TNS_ADMIN/tnsnames.ora $PRIMARY_TNS_ADMIN/tnsnames.ora.bak_\$(date +%F)
cat >> $PRIMARY_TNS_ADMIN/tnsnames.ora <<'EOF'

$(tns_block "$STANDBY_TNS" "$STANDBY_HOST" "$STANDBY_SERVICE")
EOF
env ORACLE_HOME=$DB_HOME TNS_ADMIN=$PRIMARY_TNS_ADMIN $DB_HOME/bin/tnsping $STANDBY_TNS
# TNS-12541 (no listener) is normal before phase 5"
  USING="Standby host $STANDBY_HOST, port $PORT, service $STANDBY_SERVICE"
  return 1
}

# ---- 4.10 ----
c_4_10() {
  need_ssh || return 2
  local lown; lown=$([[ "$PRIMARY_LISTENER_HOME" == "$DB_HOME" ]] && printf '%s' "$ORACLE_USER" || printf '%s' "$GRID_USER")
  PRIMARY_HOW_STEP="$lown  ->  shell"
  if [[ -n "${PRIMARY_LISTENER_TNS_ADMIN:-}" ]]; then prim_probe lsnr "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME" "$PRIMARY_LISTENER_TNS_ADMIN" || { NOW="Cannot read the listener status on the primary"; return 2; }
  else prim_probe lsnr "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME" || { NOW="Cannot read the listener status on the primary"; return 2; }; fi
  if grep -qF "Instance \"$PRIMARY_SID\", status UNKNOWN" <<< "$RUN_OUT"; then
    NOW="The primary listener has a static entry for $PRIMARY_SID"; return 0
  fi
  NOW="The primary listener has no static entry for $PRIMARY_SID."
  PLAN="-- Edit this file (or the listener.ora in its TNS_ADMIN, if set):
--   $PRIMARY_LISTENER_HOME/network/admin/listener.ora
-- Add this inside SID_LIST_$LISTENER_NAME, or create the block if it is missing.
-- ORACLE_HOME must be the database home, not the Grid home.
SID_LIST_$LISTENER_NAME =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = $PRIMARY_SERVICE)
      (SID_NAME = $PRIMARY_SID)
      (ORACLE_HOME = $DB_HOME)
    )
  )
-- Then reload the listener:
ORACLE_HOME=$PRIMARY_LISTENER_HOME $PRIMARY_LISTENER_HOME/bin/lsnrctl reload $LISTENER_NAME"
  PLAN_UNDO="remove that SID_DESC block from listener.ora, then run lsnrctl reload $LISTENER_NAME"
  return 1
}

# ---- 4.11 environment of oracle on primary (information) ----
c_4_11() {
  need_ssh || return 2
  if [[ "$PRIMARY_SSH_USER" != "$ORACLE_USER" ]]; then NOW="Not checked: the ssh user $PRIMARY_SSH_USER is not $ORACLE_USER"; return 0; fi
  PRIMARY_HOW_STEP="$ORACLE_USER  ->  Adds 4 lines to ~/.bash_profile"
  prim_probe profile || true
  [[ $PROBE_TIMED_OUT -eq 1 ]] && { NOW="The primary did not answer in time. Answer r to check again."; return 2; }
  local sid home
  sid=$(grep -E 'ORACLE_SID=' <<< "$RUN_OUT" | tail -n 1 | sed -E 's/.*ORACLE_SID=//; s/["'"'"']//g; s/[[:space:]].*//')
  home=$(grep -E 'ORACLE_HOME=' <<< "$RUN_OUT" | tail -n 1 | sed -E 's/.*ORACLE_HOME=//; s/["'"'"']//g; s/[[:space:]].*//')
  home=${home%/}
  if [[ "$sid" == "$PRIMARY_SID" && ( "$home" == "$DB_HOME" || "$home" == *'$'* ) ]]; then NOW="~/.bash_profile of $ORACLE_USER on the primary sets ORACLE_SID=$sid and ORACLE_HOME"; return 0; fi
  NOW="~/.bash_profile of $ORACLE_USER on the primary: ORACLE_SID=${sid:-<not set>} ORACLE_HOME=${home:-<not set>}"
  NOW+=$'\n'"This script does not need it, but sqlplus, rman and dgmgrl by hand do."
  PLAN="cat >> ~/.bash_profile <<'EOF'
export ORACLE_BASE=$ORACLE_BASE
export ORACLE_HOME=$DB_HOME
export ORACLE_SID=$PRIMARY_SID
export PATH=\$ORACLE_HOME/bin:\$PATH
EOF"
  PLAN_UNDO="remove those 4 lines from ~/.bash_profile of $ORACLE_USER"
  return 1
}

phase_4() {
  phase_header 4 "Prepare the primary"
  say "The script only reads the primary. You run the changes it shows."
  STEP_TITLE_HINT=([4.1]="ARCHIVELOG and FORCE LOGGING" [4.2]="Standby redo logs" [4.3]="Data Guard names (log_archive_config)" [4.4]="Redo transport to the standby (log_archive_dest_N)" [4.5]="Automatic standby files (standby_file_management)" [4.6]="Archive destination and recovery area" [4.7]="Password file and SYS" [4.8]="fal_server (optional, for switchover)")
  batch_primary_steps 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8
  run_step 4.1  primary "ARCHIVELOG and FORCE LOGGING" c_4_1
  run_step 4.2  primary "Standby redo logs on the primary" c_4_2
  run_step 4.3  primary "Data Guard names (log_archive_config)" c_4_3
  run_step 4.4  primary "Redo transport to the standby (log_archive_dest_N)" c_4_4
  run_step 4.5  primary "Automatic standby files (standby_file_management)" c_4_5
  run_step 4.6  primary "Archive destination and recovery area" c_4_6
  run_step 4.7  primary "Password file and SYS" c_4_7
  run_step 4.8  primary "fal_server (for switchover)" c_4_8
  run_step 4.9  primary "Standby alias in the primary tnsnames.ora" c_4_9
  run_step 4.10 primary "Static listener entry on the primary" c_4_10
  run_step 4.11 primary "Environment of $ORACLE_USER on the primary" c_4_11
}
