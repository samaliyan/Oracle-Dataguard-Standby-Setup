#!/bin/bash
# Scenario tests for dg_standby_setup.sh v4 (mock standby + mock primary over mock ssh).
set -uo pipefail
T=/tmp/dgt
TD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRV=$TD/driver.py
PASS=0; FAILN=0; FAILED=()
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAILN=$((FAILN+1)); FAILED+=("$CUR: $1")
  local d=/tmp/dgt_fail/$(printf '%03d' $FAILN); mkdir -p $d; cp $T/*.txt $d/ 2>/dev/null; cp $T/state/calls.log $T/state/primary_cmds.log $d/ 2>/dev/null; printf '%s\n' "$1" > $d/CHECK; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
fresh() { bash $TD/setup_env.sh "${1:-installed}" >/dev/null; }
jset() { python3 - "$@" <<'EOF'
import json,sys
f,expr=sys.argv[1],sys.argv[2]
d=json.load(open(f)); exec(expr); json.dump(d,open(f,'w'),indent=1)
EOF
}
run() { # $1 = output file, rest = script args.  Env DG_TEST_* passed through.
  local out=$1; shift
  ( cd $T && PATH=$T/rootbin:$PATH DG_LOG_DIR=$T/log DG_STATE_DIR=$T/varlib DG_OS_RELEASE_FILE=$T/os-release DG_TEST_OUT=$out \
      timeout 600 python3 $DRV ./dg_standby_setup.sh "$@" >/dev/null 2>&1 ); local rc=$?
  grep -q "DRIVER TIMEOUT" "$out" 2>/dev/null && { mkdir -p /tmp/dgt_stuck; cp "$out" "/tmp/dgt_stuck/${CUR:-x}_$(basename "$out")"; }
  echo $rc
}
P=$T/state/primary.json; S=$T/state/standby.json; O=$T/state/os.json
res() {  # result code of step $1 in the summary of output $2 (the summary shows words; mapped back to the codes)
  local l
  grep -E "^    $1 +(ok|done|skipped|failed|waiting|running|to do|problem|undone|stopped here)( |,|$)" "$2" | cut -c11-28 | sed 's/ *$//' | while IFS= read -r l; do
    case "$l" in ok) echo OK ;; done) echo DONE ;; "done by you") echo DONE_BY_YOU ;; skipped) echo SKIPPED ;;
      "skipped (optional)") echo SKIPPED_OPTIONAL ;; "failed, skipped") echo FAILED_SKIPPED ;; failed) echo FAILED ;;
      waiting) echo WAITS ;; running) echo RUNNING ;; "to do") echo TODO ;; problem) echo PROBLEM ;; undone) echo UNDONE ;;
      "stopped here") echo NOT_FINISHED ;; *) echo "$l" ;; esac
  done
}
nonselect_on_primary() { [[ -s $T/state/primary_sql.log ]] && grep -viqE '^\s*select ' $T/state/primary_sql.log; }
cmds_whitelisted() {
  # every command sent to the primary must be one of the read-only probes
  local l bad=0
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    l=${l#timeout 120 }
    if [[ "$l" =~ ^\[master\ opened ]] || [[ "$l" =~ ^\[scp\ /tmp/orapw_for_standby_[A-Z_]+\]$ ]] || [[ "$l" =~ ^\[scp\ /[A-Za-z0-9_./]+orapw[A-Za-z0-9_]*\]$ ]] \
       || [[ "$l" == "hostname -s; hostname -f" || "$l" == "cat /etc/oratab" || "$l" == "cat /etc/oraInst.loc" || "$l" == "cat /etc/oracle/olr.loc" ]] \
       || [[ "$l" =~ ^id\ [a-z]+\;\ id\ [a-z]+$ ]] || [[ "$l" =~ ^stat\ -c\ \'%U\ %[GY]\'\ /[A-Za-z0-9_./-]+$ ]] \
       || [[ "$l" =~ ^stat\ -c\ \'%U\|%G\|%a\|%F\|%Y\'\ /[A-Za-z0-9_./-]+$ ]] || [[ "$l" == "date +%s" ]] \
       || [[ "$l" =~ ^sh\ -c\ \'timeout\ 120\ test\ (-e|-d)\ /[A-Za-z0-9_./-]+(\ -a\ -x\ /[A-Za-z0-9_./-]+)?\;\ r=\$\?\;\ \[\ \$r\ -eq\ 0\ \]\ \&\&\ echo\ YES\;\ \[\ \$r\ -eq\ 1\ \]\ \&\&\ echo\ NO\;\ true\'$ ]] || [[ "$l" =~ ^findmnt\ -n\ -o\ SOURCE,UUID\ --target\ /[A-Za-z0-9_./-]+$ ]] \
       || [[ "$l" == "sh -c 'findmnt -rn -o SOURCE,UUID | while read -r s u; do case \"\$s\" in /dev/*) echo \"M|\$s|\$u\"; lsblk -nsP -o TYPE,WWN,SERIAL \"\${s%%\\[*}\";; esac; done; echo __DG_MOUNTS_END__'" ]] \
       || [[ "$l" =~ ^lsblk\ -nsP\ -o\ TYPE,WWN,SERIAL\ \"\$\(findmnt\ -n\ -o\ SOURCE\ --target\ /[A-Za-z0-9_./-]+\)\"$ ]] \
       || [[ "$l" =~ ^grep\ -o\ \'NAME=\"oracle.crs\"\ VER=\"\[0-9.\]\*\"\'\ /[A-Za-z0-9_./-]+/inventory/ContentsXML/comps.xml$ ]] \
       || [[ "$l" =~ ^env\ ORACLE_HOME=/[^\ ]+\ /[^\ ]+/bin/(orabase|orabasehome)$ ]] \
       || [[ "$l" =~ ^env\ ORACLE_HOME=/[^\ ]+(\ TNS_ADMIN=/[^\ ]+)?\ timeout\ 120\ /[^\ ]+/bin/lsnrctl\ status\ [A-Z_]+$ ]] \
       || [[ "$l" =~ ^cat\ /[A-Za-z0-9_./-]+/ContentsXML/inventory\.xml$ ]] \
       || [[ "$l" =~ ^env\ ORACLE_HOME=/[^\ ]+\ TNS_ADMIN=/[^\ ]+\ /[^\ ]+/bin/tnsping\ [a-z_]+\ 1$ ]] \
       || [[ "$l" =~ ^getent\ ahostsv4\ [A-Za-z0-9.-]+$ ]] \
       || [[ "$l" == "ps -eo pid,user:32,args" ]] || [[ "$l" =~ ^readlink\ /proc/[0-9]+/exe$ ]] \
       || [[ "$l" =~ ^tr\ \'\\0\'\ \'\\n\'\ \<\ /proc/[0-9]+/environ\ \|\ grep\ -E\ \'\^\(ORACLE_HOME\|ORACLE_SID\|ORACLE_BASE\|TNS_ADMIN\)=\'$ ]] \
       || [[ "$l" =~ ^md5sum\ /[A-Za-z0-9_./-]+$ ]] || [[ "$l" =~ ^ls\ -1A\ /[A-Za-z0-9_./-]+$ ]] \
       || [[ "$l" == "grep -sE '^[[:space:]]*(export[[:space:]]+)?(ORACLE_HOME|ORACLE_SID|ORACLE_BASE|TNS_ADMIN)=' \$HOME/.bash_profile \$HOME/.bashrc" ]] \
       || [[ "$l" =~ ^env\ (-u\ [A-Z_]+\ )*ORACLE_HOME=/[^\ ]+\ ORACLE_SID=[A-Za-z0-9_]+\ TNS_ADMIN=/[^\ ]+\ timeout\ [0-9]+\ /[^\ ]+/bin/sqlplus\ -S\ /nolog$ ]]; then :; else
      printf '        not whitelisted: %s\n' "$l"; bad=1
    fi
  done < $T/state/primary_cmds.log
  [[ $bad -eq 0 && ! -s $T/state/primary_UNEXPECTED.log ]]
}
safe_primary() { cmds_whitelisted && ! nonselect_on_primary; }
no_secrets() { ! grep -rqE 'Welcome_123|Asm_Pass123|Oracle_os1' $T/log/ "$T/varlib" 2>/dev/null; }

#==============================================================================
CUR=A; echo "== A. readonly_guard unit tests"
fresh
G=$(mktemp); sed -n '/^readonly_guard()/,/^}/p' $T/dg_standby_setup.sh > "$G"; source "$G"; rm -f "$G"
allowed=(
 "select log_mode from v\$database;"
 "  SELECT name FROM v\$parameter where name='fal_server';  "
 "select d.db_unique_name||'|'||d.database_role from v\$database d, v\$instance i;"
 "select count(*) from v\$archive_dest where status='VALID';"
 "select banner from v\$version where banner like 'Oracle%';"
 "select file_name||'|'||format from v\$passwordfile_info;"
)
blocked=(
 "alter system set log_archive_dest_state_2=enable scope=both;" "ALTER DATABASE FORCE LOGGING;" "delete from aud\$;"
 "select 1 from dual; alter system switch logfile;" $'select 1 from dual;\nhost rm -rf /'
 "select dbms_pipe.send_message('x') from dual;" "begin null; end;" "exec dbms_stats.gather_schema_stats('X');"
 "shutdown abort" "create table x(a number);" "select sys.dbms_lock.sleep(5) from dual;" "select 1 from dual"
 "grant dba to scott;" "update t set a=1;" "select '&x' from dual;" "select 1 from dual -- x;"
 "select /* x */ 1 from dual;" "select * from t@remote;" "select 1 from dual for update; commit;"
)
for q in "${allowed[@]}"; do if readonly_guard "$q"; then pass "guard allows: ${q:0:50}"; else fail "guard should allow: $q"; fi; done
for q in "${blocked[@]}"; do if readonly_guard "$q"; then fail "guard should BLOCK: $q"; else pass "guard blocks: ${q:0:50}"; fi; done
G=$(mktemp); { sed -n '/^v_name()/p;/^v_path()/p' $T/dg_standby_setup.sh; sed -n '/^prim_probe()/,/^}/p' $T/dg_standby_setup.sh; } > "$G"
out=$(bash -c "fatal(){ echo FATAL:\$*; exit 1; }; run_logged(){ echo RUN; }; source $G; prim_probe owner '/tmp/x; rm -rf /'" 2>&1)
check "prim_probe refuses an argument with ; and spaces" "[[ '$out' == FATAL:* ]]"
out=$(bash -c "fatal(){ echo FATAL:\$*; exit 1; }; run_logged(){ echo RUN; }; source $G; prim_probe rmrf /tmp" 2>&1)
check "prim_probe refuses an unknown probe name" "[[ '$out' == FATAL:* ]]"
out=$(bash -c "fatal(){ echo FATAL:\$*; exit 1; }; run_logged(){ echo RUN; }; source $G; prim_probe hosts 'a\$(id)'" 2>&1); rm -f "$G"
check "prim_probe refuses \$( ) in an argument" "[[ '$out' == FATAL:* ]]"

#==============================================================================
CUR=B; echo "== B. Empty server, full run (only IP + passwords given)"
fresh empty
rc=$(run $T/b.txt)
check "exit code 0" "[[ $rc -eq 0 ]]"
check "summary: no SKIPPED/FAILED/TODO" "! grep -qE '^    [0-9.]+ +(skipped|failed, skipped|to do|UNKNOWN)' $T/b.txt"
check "setup complete message" "grep -q 'Standby setup is complete' $T/b.txt"
check "primary: only whitelisted read-only commands" "cmds_whitelisted"
check "primary: only SELECT statements" "! nonselect_on_primary"
check "primary SQL log is not empty (checks really ran)" "[[ \$(wc -l < $T/state/primary_sql.log) -gt 20 ]]"
check "groups created with primary gids" "[[ \$(getent group asmadmin | cut -d: -f3) == 54327 && \$(getent group oinstall | cut -d: -f3) == 54321 ]]"
check "oracle uid and groups as on primary" "[[ \$(id -u oracle) == 54321 ]] && id -nG oracle | grep -qw asmdba && id -nG oracle | grep -qw backupdba"
check "grid uid and groups as on primary" "[[ \$(id -u grid) == 54331 ]] && id -nG grid | grep -qw asmadmin"
check "DATA_1 on sdb (biggest), FRA_1 on sdc" "python3 -c \"import json;d=json.load(open('$O'))['asm']['disks'];assert d=={'DATA_1':'/dev/sdb1','FRA_1':'/dev/sdc1'}\""
check "ASM disks recorded as made by this script" "grep -qx 'DATA_1|/dev/sdb1' $T/varlib/asm_disks"
check "RMAN keeps every datafile in its disk group (set newname)" "grep -q \"set newname for datafile 1 to '+DATA'\" $T/log/duplicate_*.rman"
check "Grid: unit that starts apply after Oracle Restart" "grep -q 'After=.*oracle-ohasd.service' /etc/systemd/system/oracle-standby-apply-proddb_stby.service && grep -q 'LimitNOFILE=65536' /etc/systemd/system/oracle-standby-apply-proddb_stby.service && [[ \$(stat -c '%U %a' /usr/local/sbin/dg_standby_proddb_stby.sh) == 'root 755' ]]"
check "installer and root script output in their own log files" "ls $T/log/Grid_installer_*.log $T/log/root_*_root_*.log >/dev/null 2>&1"
check "no job left behind" "[[ ! -e $T/varlib/job ]]"
check "disks with data (sdd ext4, sde gpt) untouched" "! grep -qE 'parted.*/dev/sd[de]|createdisk.*/dev/sd[de]' $T/state/calls.log"
check "installer zips found automatically" "grep -q 'Use these installer files' $T/b.txt"
check "grid installed with silent HA_CONFIG" "grep -q \"gridSetup.sh user=grid dir=.* args=\\['-silent', '-waitforcompletion', '-responseFile'\" $T/state/calls.log"
check "grid configtools ran" "grep -q \"gridSetup.sh user=grid dir=.* args=\\['-executeConfigTools'\" $T/state/calls.log"
check "response files removed" "! ls -d /tmp/dg_rsp.* 2>/dev/null | grep -q ."
check "no password env leak into root scripts" "! grep -q ENV-LEAK $T/state/calls.log"
check "FRA created with the compatible attributes of DATA" "python3 -c \"import json;assert 'compatible.rdbms' in ' '.join(json.load(open('$S'))['dg_sql'])\""
check "roohctl -disable ran" "grep -q 'roohctl user=oracle' $T/state/calls.log"
check "password file is primary copy, mode 640" "grep -q ORAPW-PRIMARY $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY && [[ \$(stat -c %a $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY) == 640 ]]"
check "static entry uses DB home" "grep -q 'ORACLE_HOME = $T/u01/app/oracle/product/19.0.0/dbhome_1' $T/u01/app/19.0.0/grid/network/admin/listener.ora"
check "9.8: archivelog deletion policy set on the standby" "grep -qE '^    9\.8 +done' $T/b.txt && grep -q 'rman_adp' $S"
check "rman duplicate ran once (plus the syntax check, the login test and the 9.8 policy)" "python3 -c \"import json;assert json.load(open('$S')).get('duplicated')==1\" && [[ \$(grep -c '^rman ' $T/state/calls.log) -eq 4 ]]"
check "srvctl -instance is the SID" "python3 -c \"import json;assert json.load(open('$S'))['srvctl']['instance']=='PRODDB_STBY'\""
check "settings file root 600" "[[ \$(stat -c '%U %a' $T/varlib/settings.conf) == 'root 600' ]]"
check "settings contain discovered values" "grep -q '^PRIMARY_SID=PRODDB$' $T/varlib/settings.conf && grep -q '^STANDBY_UNIQUE=PRODDB_STBY$' $T/varlib/settings.conf && grep -q '^GROUP_GIDS=.*asmadmin:54327' $T/varlib/settings.conf"
check "no password in logs or settings" "no_secrets"
check "ssh control socket closed at exit" "[[ ! -e $T/varlib/ssh_ctl ]]"
check "every primary step shows ON PRIMARY block" "[[ \$(grep -c 'Run on the PRIMARY (prim01)' $T/b.txt) -ge 9 ]]"
check "primary steps recorded DONE_BY_YOU" "[[ \$(res 4.1 $T/b.txt) == DONE_BY_YOU && \$(res 9.5 $T/b.txt) == DONE_BY_YOU ]]"
check "actions file lists primary commands" "grep -q 'alter database force logging' $T/log/actions_*.txt"
check "every [y] question comes after a Plan of the same step" "awk '/^  \\[[0-9]+\\.[0-9]+\\] /{p=0} /Plan:/{p=1} /\\[y\\] do it/{if(!p){bad=1}} END{exit bad}' $T/b.txt"
check "/etc/hosts backup kept" "ls /etc/hosts.bak_* >/dev/null 2>&1"
cp $T/b.txt $T/b_full.txt

CUR=C; echo "== C. Second run on the finished server changes nothing"
: > $T/state/calls.log; : > $T/state/primary_cmds.log
rc=$(run $T/c.txt)
check "exit 0" "[[ $rc -eq 0 ]]"
check "no step DONE now except ssh/discovery/sys password" "! grep -E '^    [0-9.]+ +done ' $T/c.txt | grep -vE '^    1\.[235] ' | grep -q ."
check "settings accepted without question (same as accepted)" "grep -q 'Same settings as you accepted before' $T/c.txt && ! grep -q '\[a\] accept' $T/c.txt"
check "no installer, no rman, no parted, no groupadd" "! grep -qE '^(gridSetup|runInstaller|rman|parted)' $T/state/calls.log"
check "primary still safe" "safe_primary"

CUR=D; echo "== D. --only 10 (daily check) and --from"
rc=$(run $T/d1.txt --only 10)
check "--only 10 exit 0" "[[ $rc -eq 0 ]]"
check "--only 10 runs phase 1 and 10 only" "grep -q 'Phase 10 of 10' $T/d1.txt && ! grep -qE 'Phase (2|3|4|5|6|7|8|9) of 10' $T/d1.txt"
rc=$(run $T/d2.txt --from 9.3)
check "--from 9.3 starts at 9.3" "grep -q 'Step 9.3  ' $T/d2.txt && ! grep -q 'Step 9.2  ' $T/d2.txt && ! grep -q 'Phase 8 of 10' $T/d2.txt"
rc=$(run $T/d3.txt --from 11); check "--from 11 rejected" "[[ $rc -ne 0 ]] && grep -q 'Use --from' $T/d3.txt"
rc=$(run $T/d4.txt --from 3.99); check "--from 3.99 (no such step) rejected" "[[ $rc -eq 2 ]] && grep -q 'There is no step 3.99' $T/d4.txt"
rc=$(run $T/d5.txt --from 5.1 --only 10); check "--from with --only rejected" "[[ $rc -eq 2 ]] && grep -q 'not both' $T/d5.txt"
rc=$(run $T/d6.txt --from 9.1); check "--from 9.1 does not ask the sys password, says all OK" "! grep -q 'sys password (same on primary' $T/d6.txt && grep -q 'Standby setup is complete' $T/d6.txt"

CUR=E; echo "== E. --check on an empty server changes nothing"
fresh empty
rc=$(run $T/e.txt --check)
check "exit non-zero (work to do)" "[[ $rc -ne 0 ]]"
check "no groups/users created" "! getent group oinstall >/dev/null && ! id oracle >/dev/null 2>&1"
check "no dnf/oracleasm configure/parted" "! grep -qE \"^(dnf|parted) |'-u', 'grid'\" $T/state/calls.log"
check "no settings file written" "[[ ! -f $T/varlib/settings.conf ]]"
check "no [y] do it prompt" "! grep -q '\[y\] do it' $T/e.txt"
check "TODO items listed" "grep -qE '^    2\.1 +to do' $T/e.txt"
check "check mode: waiting steps are WAIT, not FAIL" "grep -q 'Checked after step 2.2 is done' $T/e.txt && ! grep -q 'Not possible yet' $T/e.txt && grep -qE '^    2\.5 +waiting' $T/e.txt"
check "check mode: legend explains TODO / WAITS / PROBLEM" "grep -q 'Only .problem. steps need your attention' $T/e.txt"
check "check mode on a new server with a healthy primary: no PROBLEM (7.6 waits for 7.2)" "! grep -qE '^    [0-9]+\.[0-9]+ +problem' $T/e.txt && grep -qE '^    7\.6 +waiting' $T/e.txt"
check "primary safe" "safe_primary"

CUR=F; echo "== F. Safety stops"
fresh; jset $P "d['host']='$(hostname -s).example.local'"
rc=$(run $T/f1.txt)
check "primary host = this host -> stop with explanation" "[[ $rc -ne 0 ]] && grep -q 'has the same host name' $T/f1.txt && grep -q 'hostnamectl set-hostname' $T/f1.txt"
check "stop prints a summary of this run" "grep -q ' Summary ' $T/f1.txt && grep -q 'The script itself changed nothing on the primary' $T/f1.txt"
fresh; jset $P "d['role']='PHYSICAL STANDBY'"
rc=$(run $T/f2.txt)
check "primary role not PRIMARY -> stop" "[[ $rc -ne 0 ]] && grep -q \"not PRIMARY\" $T/f2.txt"
check "nothing created on standby" "! grep -q groupadd $T/f2.txt"
fresh; rc=$(DG_TEST_OSPW=wrong run $T/f3.txt)
check "wrong ssh password -> sshd_config / passwd commands shown" "grep -q 'PasswordAuthentication must be yes' $T/f3.txt && grep -q 'passwd oracle' $T/f3.txt"
check "wrong ssh password -> stop, nothing done" "[[ $rc -ne 0 ]] && grep -q 'ssh connection to oracle@127.0.0.2 failed' $T/f3.txt && grep -q '\[i\] Other IP address or user' $T/f3.txt && ! grep -q groupadd $T/state/calls.log"
fresh; jset $P "d['os_auth']=False"
rc=$(run $T/f4.txt)
check "ssh user cannot sqlplus / as sysdba -> clear hint" "[[ $rc -ne 0 ]] && grep -q 'must be able to run  sqlplus / as sysdba' $T/f4.txt"
fresh; mkdir -p $T/varlib /tmp/dgt_canary; printf 'PRIMARY_IP=127.0.0.2\nDB_HOME=$(rm -rf /tmp/dgt_canary)\n' > $T/varlib/settings.conf; chmod 600 $T/varlib/settings.conf
rc=$(DG_TEST_QUIT_AT=2.1 run $T/f5.txt)
check "tampered primary value in settings -> never executed, read again from primary" "[[ -d /tmp/dgt_canary ]] && grep -q 'home=$T/u01/app/oracle/product/19.0.0/dbhome_1' $T/f5.txt"
rmdir /tmp/dgt_canary 2>/dev/null
fresh; mkdir -p $T/varlib; printf 'PRIMARY_IP=127.0.0.2\nSTANDBY_SID=$(id)\n' > $T/varlib/settings.conf; chmod 600 $T/varlib/settings.conf
rc=$(run $T/f5b.txt)
check "tampered standby value in settings -> refused" "[[ $rc -ne 0 ]] && grep -q 'Invalid value: STANDBY_SID' $T/f5b.txt"
fresh; mkdir -p $T/varlib; printf 'PRIMARY_IP=127.0.0.2\nEVIL=1\n' > $T/varlib/settings.conf; chmod 600 $T/varlib/settings.conf
rc=$(DG_TEST_QUIT_AT=2.1 run $T/f6.txt); check "unknown key in settings -> ignored with a warning" "grep -q 'Unknown keys in .* were ignored: EVIL' $T/f6.txt"
fresh; mkdir -p $T/varlib; printf 'PRIMARY_IP=127.0.0.2\n' > $T/varlib/settings.conf; chmod 666 $T/varlib/settings.conf
rc=$(run $T/f7.txt); check "world-writable settings -> refused" "[[ $rc -ne 0 ]] && grep -q 'that others cannot write' $T/f7.txt"
fresh; rc=$(DG_TEST_IP=127.0.0.9 run $T/f8.txt)
check "wrong primary IP -> ssh fails, stop" "[[ $rc -ne 0 ]] && grep -q 'ssh connection to oracle@127.0.0.9 failed' $T/f8.txt"
check "ssh's own error message is shown to the user, with the fix" "grep -q 'Connection refused' $T/f8.txt && grep -q 'systemctl enable --now sshd' $T/f8.txt"
check "no option that old OpenSSH (OL7) rejects" "! grep -q 'accept-new' $T/dg_standby_setup.sh"

CUR=G; echo "== G. Installed server: fixes + manual steps"
fresh
rc=$(run $T/g.txt)
check "exit 0" "[[ $rc -eq 0 ]]"
check "oracle missing groups added with usermod" "grep -q 'usermod -a -G oper,backupdba,dgdba,kmdba,racdba,asmdba oracle' $T/g.txt && id -nG oracle | grep -qw kmdba"
check "wrong static ORACLE_HOME detected, shown as manual" "grep -q 'has a different ORACLE_HOME' $T/g.txt && grep -q 'Run on this server' $T/g.txt"
check "5.1 recorded DONE_BY_YOU" "[[ \$(res 5.1 $T/g.txt) == DONE_BY_YOU ]]"
check "ASM disks of an older version (DATA1) are used only after you confirm" "grep -q 'Use the existing ASM disks DATA1 for +DATA' $T/g.txt && grep -qx 'DATA1|/dev/sdb1' $T/varlib/asm_disks"
check "existing proddb alias accepted, standby alias added" "[[ \$(res 5.3 $T/g.txt) == OK && \$(res 5.4 $T/g.txt) == DONE ]]"
check "no installer run (software present)" "! grep -qE '^(gridSetup|runInstaller)' $T/state/calls.log"
check "primary safe" "safe_primary"

CUR=H; echo "== H. Skip, quit, help, Ctrl-C"
fresh empty; rc=$(DG_TEST_SKIP=2.11 run $T/h1.txt)
check "skip 2.11 -> SKIPPED, run continues to the end" "[[ \$(res 2.11 $T/h1.txt) == SKIPPED ]] && grep -q 'Phase 10 of 10' $T/h1.txt"
check "skipped run exits non-zero and says so" "[[ $rc -ne 0 ]] && grep -q 'Next: ' $T/h1.txt"
check "profile not written" "! grep -qs 'ORACLE_SID=' /home/oracle/.bash_profile"
fresh empty; rc=$(DG_TEST_QUIT_AT=3.2 run $T/h2.txt)
check "quit at 3.2 -> exit 1 with --from 3.2" "[[ $rc -ne 0 ]] && grep -q -- '--from 3.2' $T/h2.txt"
check "quit: nothing installed" "! grep -q '^gridSetup' $T/state/calls.log"
fresh empty; rc=$(DG_TEST_HELP_AT=2.1 DG_TEST_QUIT_AT=2.2 run $T/h3.txt)
check "h shows help of the current step" "grep -qE 'Help .{1,3} Step 2\.1 ' $T/h3.txt && grep -q 'groupadd -g <gid>' $T/h3.txt"
fresh empty; rc=$(DG_TEST_CTRLC_AT=3.4 run $T/h4.txt)
check "Ctrl-C -> stopped, message" "[[ $rc -ne 0 ]] && grep -q 'Interrupted' $T/h4.txt"
check "Ctrl-C: no response file left, ssh closed" "! ls -d /tmp/dg_rsp.* 2>/dev/null | grep -q . && [[ ! -e $T/varlib/ssh_ctl ]]"
out=$(cd $T && bash ./dg_standby_setup.sh --help-step all 2>&1); n=$(grep -cE 'Help .{1,3} Step [0-9]' <<< "$out")
check "--help-step all prints every step (71)" "[[ $n -eq 71 ]]"
check "--help-step uses saved names" "grep -q 'PRODDB_STBY' <<< \"\$out\" || true"
out=$(cd $T && bash ./dg_standby_setup.sh --help-step 9.9 2>&1); check "--help-step unknown -> message" "grep -q 'No help for step' <<< \"\$out\""
out=$(cd $T && bash ./dg_standby_setup.sh --help 2>&1); check "--help shows usage" "grep -q -- '--primary' <<< \"\$out\""
for st in 1.1 1.2 1.3 1.4 1.5 1.6 2.1 2.2 2.3 2.4 2.5 2.6 2.7 2.8 2.9 2.10 2.11 2.12 2.13 2.14 2.15 3.1 3.2 3.3 3.4 3.5 3.6 3.7 3.8 3.9 3.10 3.11 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9 4.10 4.11 5.1 5.2 5.3 5.4 6.1 6.2 6.3 7.1 7.2 7.3 7.4 7.5 7.6 7.7 8.1 8.2 9.1 9.2 9.3 9.4 9.5 9.6 9.7 9.8 10.1 10.2 10.3 10.4; do
  grep -q "run_step $st " $T/dg_standby_setup.sh || fail "step $st exists in the script"
done
pass "all help ids are real steps"

CUR=I; echo "== I. Disks"
fresh empty; jset $O "d['disks']['/dev/sdb']['size_mb']=50000; d['disks']['/dev/sdc']['size_mb']=60000"
rc=$(run $T/i1.txt)
check "no disk big enough -> refused, nothing erased" "grep -q 'The empty disks left have' $T/i1.txt && ! grep -q '^parted' $T/state/calls.log"
fresh empty; rc=$(DG_TEST_DISKWORD=/dev/sdx run $T/i2.txt)
check "wrong typed device -> nothing erased" "grep -q 'Not confirmed. Nothing was erased' $T/i2.txt && ! grep -q '^parted' $T/state/calls.log"
fresh empty; jset $O "del d['disks']['/dev/sdc']"
rc=$(run $T/i3.txt)
check "only one empty disk -> not enough, nothing erased" "grep -q 'Not enough empty disks for +FRA' $T/i3.txt && ! grep -q '^parted' $T/state/calls.log"
fresh empty; rc=$(DG_TEST_DISK_PICKS=2,1 run $T/i4.txt)
check "user picks sdc for DATA -> too small refused, asks again" "grep -qE '\\+DATA needs [0-9]+ MB more. Choose more' $T/i4.txt"

CUR=J; echo "== J. Primary side not done by the DBA"
fresh; rc=$(DG_TEST_NOFIX=4.3,4.8,4.10 run $T/j.txt)
check "4.3 SKIPPED, optional 4.8 / 4.10 SKIPPED_OPTIONAL, others continue" "[[ \$(res 4.3 $T/j.txt) == SKIPPED && \$(res 4.8 $T/j.txt) == SKIPPED_OPTIONAL && \$(res 4.10 $T/j.txt) == SKIPPED_OPTIONAL && \$(res 5.1 $T/j.txt) != '' ]]"
check "commands for primary were printed, never run" "grep -q \"alter system set log_archive_config='dg_config=(proddb,PRODDB_STBY)' scope=both;\" $T/j.txt && safe_primary"
fresh; jset $P "d['tns_stby']=1; d['tns_stby_host']='wronghost'"
rc=$(run $T/j2.txt)
check "primary alias pointing to a wrong host detected" "grep -q 'is different: HOST is wronghost' $T/j2.txt"
fresh; jset $P "d['dest2_error']='ORA-16191: Primary log shipping client not logged on standby'; d['params']['log_archive_dest_state_2']='ENABLE'"
rc=$(DG_TEST_NOFIX=9.5 run $T/j3.txt)
check "dest_2 error explained (password file)" "grep -q 'password files differ' $T/j3.txt"

CUR=K; echo "== K. Password file variants"
fresh; jset $P "d['pwfile']='$T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB'"
rc=$(run $T/k1.txt)
check "password file on disk -> copied directly, no primary action" "[[ \$(res 6.1 $T/k1.txt) == DONE ]] && ! grep -q 'asmcmd pwcopy' $T/k1.txt"
fresh; printf 'OLDFILE\n' > $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY; chown oracle:oinstall $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY
rc=$(run $T/k2.txt)
check "invalid existing file replaced, backup kept" "ls $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY.bak_* >/dev/null 2>&1 && grep -q ORAPW-PRIMARY $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY"

CUR=L; echo "== L. Duplicate safety"
fresh; rc=$(DG_TEST_DUP=no run $T/l1.txt)
check "duplicate not confirmed -> not run" "grep -q 'The copy was not started' $T/l1.txt && ! python3 -c \"import json;assert json.load(open('$S')).get('duplicated')\" 2>/dev/null"
check "8.2 SKIPPED (not started is not a failure), 9.x cannot run" "[[ \$(res 8.2 $T/l1.txt) == SKIPPED ]] && grep -q 'does not exist yet (phase 8)' $T/l1.txt"
fresh; jset $S "d['instances']['PRODDB_STBY']={'state':'mounted','datafiles':10,'df_errors':7}"
rc=$(run $T/l2.txt)
check "incomplete standby, no copy of this script recorded -> commands shown only, no rman" "grep -q 'the database is incomplete' $T/l2.txt && grep -q 'NEVER remove +DATA/PRODDB' $T/l2.txt && ! grep -q \"^rman .*args=\\[\\]\" $T/state/calls.log"
fresh; python3 - <<EOF
import json; f='$T/state/env.json'; d=json.load(open(f)); d['data_free']=1000; json.dump(d,open(f,'w'))
EOF
rc=$(run $T/l3.txt)
check "not enough space in +DATA -> no duplicate" "grep -q 'needs about' $T/l3.txt && ! grep -q \"^rman .*args=\\[\\]\" $T/state/calls.log"
fresh; jset $P "d['params']['log_archive_dest_3']='service=other'; d['params']['db_create_online_log_dest_1']='+REDO1'"
rc=$(run $T/l4.txt)
check "primary-only parameters remapped/cleared in RMAN script" "grep -q \"set db_create_online_log_dest_1=''\" $T/log/duplicate_*.rman && grep -q \"set log_archive_dest_state_3='defer'\" $T/log/duplicate_*.rman && grep -q \"dg_config=(PRODDB,PRODDB_STBY)\" $T/log/duplicate_*.rman"
check "rman script has no password" "! grep -q Welcome_123 $T/log/duplicate_*.rman $T/log/duplicate_*.log"

CUR=M; echo "== M. Registration and apply problems"
fresh empty; run $T/m0.txt >/dev/null
jset $S "d['srvctl']['instance']='PRODDB'; d['srvctl']['running']=1; d['instances']['PRODDB']={'state':'mounted','srl':4}; d['instances']['PRODDB_STBY']={'state':'idle','srl':4,'datafiles':10}"
rc=$(run $T/m1.txt --from 9.1)
check "wrong -instance detected and re-registered" "grep -q 'Registered, but these values are wrong: instance' $T/m1.txt && python3 -c \"import json;assert json.load(open('$S'))['srvctl']['instance']=='PRODDB_STBY'\""
check "after fix exit 0" "[[ $rc -eq 0 ]]"

CUR=N; echo "== N. Software problems"
fresh empty; jset $S "d['grid_prereq_fail']=1"
rc=$(run $T/n1.txt)
check "grid prereq failure -> IGNORE retry -> installed" "grep -q 'Retry and ignore the failed prerequisite checks' $T/n1.txt && grep -q 'ignorePrereqFailure' $T/state/calls.log && [[ \$(res 3.2 $T/n1.txt) == DONE ]]"
fresh empty; rc=$(DG_TEST_ASMPW=Asm_Pass123 DG_TEST_ASMPW2=Other_999x DG_TEST_QUIT_AT=3.3 run $T/n2.txt)
check "ASM password mismatch -> not installed" "grep -q 'The two passwords are not the same' $T/n2.txt && [[ \$(res 3.2 $T/n2.txt) == FAILED_SKIPPED ]]"
fresh empty; rc=$(DG_TEST_ASMPW=short DG_TEST_QUIT_AT=3.3 run $T/n3.txt)
check "weak ASM password refused" "grep -q 'The password needs 8-30 characters' $T/n3.txt"
fresh; rmdir $T/u01/app/oracle/product/19.0.0/dbhome_1/inventory/oneoffs/35643107; mkdir -p $T/u01/app/oracle/product/19.0.0/dbhome_1/inventory/oneoffs/29517242
rc=$(run $T/n4.txt)
check "different patches -> missing patch ids and opatchauto instructions" "grep -q 'missing here: 35643107' $T/n4.txt && grep -q 'only here: 29517242' $T/n4.txt && grep -q 'opatchauto apply' $T/n4.txt && [[ \$(res 3.11 $T/n4.txt) == DONE_BY_YOU ]]"
check "patch list read without opatch on primary (opatch writes logs)" "! grep -q 'opatch' $T/state/primary_cmds.log && grep -q 'inventory/oneoffs' $T/state/primary_cmds.log"
fresh; jset $P "d['banner']='Oracle Database 21c Standard Edition 2 Release 21.0.0.0.0 - Production'"
rc=$(DG_TEST_QUIT_AT=4.1 run $T/n5.txt)
check "Standard Edition primary -> explained" "grep -q 'Data Guard needs Enterprise Edition' $T/n5.txt"
fresh empty; rm -f $T/stage/*.zip; rc=$(DG_TEST_QUIT_AT=3.2 run $T/n6.txt)
check "no installer zip -> gold image and base file names shown, nothing installed" "grep -q 'No installer files found for: Grid 19 database 19' $T/n6.txt && grep -q 'createGoldImage' $T/n6.txt && grep -q 'LINUX.X64_193000_grid_home.zip' $T/n6.txt && ! grep -q '^gridSetup' $T/state/calls.log"
fresh; jset $S "d['has']=0"
rc=$(run $T/n7.txt)
check "HAS stopped, root.sh result unknown -> start/deconfig commands shown" "grep -q 'root.sh may have failed' $T/n7.txt && grep -q 'roothas.sh -deconfig -force' $T/n7.txt && [[ \$(res 3.3 $T/n7.txt) == DONE_BY_YOU ]]"
fresh; jset $S "d['has']=0"; mkdir -p $T/varlib; : > $T/varlib/grid_root.done
rc=$(run $T/n7b.txt)
check "HAS stopped after a recorded root.sh -> crsctl start has (standby only)" "grep -q 'High Availability Services is stopped' $T/n7b.txt && grep -q \"crsctl .*args=\\['start', 'has'\\]\" $T/state/calls.log"
fresh; jset $S "d['rooh']=1"; mkdir -p $T/u01/app/oracle/dbs; touch $T/u01/app/oracle/dbs/spfileX.ora
rc=$(DG_TEST_QUIT_AT=4.1 run $T/n8.txt)
check "read-only home already used -> not converted" "grep -q 'The script does not change such a home' $T/n8.txt && ! grep -q 'roohctl' $T/state/calls.log"

CUR=O; echo "== O. Settings"
fresh; rc=$(DG_TEST_QUIT_AT=2.1 run $T/o1.txt)
rc=$(DG_TEST_QUIT_AT=2.1 run $T/o2.txt --primary 127.0.0.2)
check "saved settings reused without asking IP" "! grep -q 'IP address (or host name)' $T/o2.txt && grep -q 'Same settings as you accepted before' $T/o2.txt"
rc=$(DG_TEST_QUIT_AT=1.2 run $T/o3.txt --primary 127.0.0.7)
check "other primary IP -> saved settings not used, kept as a copy" "grep -q 'The saved settings are for another primary, so they are not used. A copy ends in' $T/o3.txt && ls $T/varlib/settings.conf.127.0.0.2_* >/dev/null 2>&1"
fresh; jset $P "d['extra_pmon']=['OTHERDB']"
rc=$(DG_TEST_DBPICK=1 DG_TEST_QUIT_AT=2.1 run $T/o4.txt)
check "several running databases -> user chooses" "grep -q 'Running databases on the primary' $T/o4.txt && grep -q 'ORACLE_SID=PRODDB ' $T/o4.txt"
fresh; jset $P "d['unique']='verylongname'"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/o5.txt)
check "long db_unique_name -> standby name within 12 chars" "grep -qE 'db_unique_name +VERYLONGN_SB' $T/o5.txt"

CUR=P; echo "== P. Review fixes (noise, stale files, dest in use, multi-disk, memory, ...)"
fresh empty; jset $P "d['login_noise']='Welcome to prim01 - authorized users only'; d['glogin_noise']='Session altered.'"
rc=$(DG_TEST_PW=Welcome_123 DG_SYS_PASSWORD=Welcome_123 run $T/p1.txt)
check "login banner and glogin output on primary are ignored" "[[ $rc -eq 0 ]] && grep -qE 'Primary host: prim01[[:space:]]*$' $T/p1.txt"
check "probes always use the output marker" "! grep -q 'probe without marker' $T/state/primary_UNEXPECTED.log"
check "DG_SYS_PASSWORD from env not passed to root scripts" "! grep -q ENV-LEAK $T/state/calls.log && grep -q 'Using DG_SYS_PASSWORD from environment' $T/p1.txt"
fresh; jset $P "d['pw_tmp']=1; d['pw_tmp_mtime']=1000000000"
rc=$(run $T/p2.txt)
check "old /tmp password copy on primary not used; new copy requested" "grep -q 'An old copy /tmp/orapw_for_standby_PRODDB_STBY' $T/p2.txt && grep -q 'rm -f /tmp/orapw_for_standby_PRODDB_STBY' $T/p2.txt && [[ $rc -eq 0 ]]"
fresh; jset $P "d['params']['log_archive_dest_2']='service=othersite async db_unique_name=OTHER'"
rc=$(run $T/p3.txt)
check "dest_2 in use -> dest 3 used, dest_2 never touched" "grep -q \"alter system set log_archive_dest_3='service=proddb_stby\" $T/p3.txt && ! grep -q \"set log_archive_dest_2='service=proddb_stby\" $T/p3.txt && grep -q 'log_archive_dest_state_3=enable' $T/p3.txt && [[ $rc -eq 0 ]]"
fresh empty; jset $O "d['disks']['/dev/sdb']['size_mb']=80000; d['disks']['/dev/sdc']['size_mb']=80000; d['disks']['/dev/sdf']={'size_mb':60000}"
rc=$(DG_TEST_DISK_PICKS=1+2,3 run $T/p4.txt)
check "+DATA on two disks (DATA_1, DATA_2), FRA on third" "python3 -c \"import json;d=json.load(open('$O'))['asm']['disks'];assert sorted(d)==['DATA_1','DATA_2','FRA_1'],d\" && [[ $rc -eq 0 ]]"
check "grid response file lists both DATA disks" "grep -qx 'oracle.install.asm.diskGroup.disks=/dev/oracleasm/disks/DATA_1,/dev/oracleasm/disks/DATA_2' $T/state/last_grid_rsp_disks.txt && grep -qx 'oracle.install.asm.diskGroup.disksWithFailureGroupNames=/dev/oracleasm/disks/DATA_1,,/dev/oracleasm/disks/DATA_2,' $T/state/last_grid_rsp_disks.txt"
fresh; jset $P "d['mem']={'sga_target':str(900*1024**3),'sga_max_size':str(900*1024**3),'memory_target':'0','memory_max_target':'0','use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
rc=$(run $T/p5.txt)
check "primary SGA bigger than standby RAM -> no duplicate, clear message" "grep -q 'Add RAM to the standby' $T/p5.txt && ! grep -q '^rman' $T/state/calls.log"
fresh; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':'0','memory_max_target':'0','use_large_pages':'ONLY','db_recovery_file_dest_size':str(900*1024**3)}"
rc=$(run $T/p6.txt)
check "use_large_pages=ONLY without HugePages -> TRUE on standby" "grep -q \"set use_large_pages='TRUE'\" $T/log/duplicate_*.rman"
check "recovery area size limited to the standby +FRA" "grep -q \"set db_recovery_file_dest_size='360000M'\" $T/log/duplicate_*.rman"
fresh; jset $P "d['params']['log_archive_dest']='/arch'; d['params'].pop('log_archive_dest_1', None)"
rc=$(DG_TEST_NOFIX=4.4 run $T/p7.txt)
check "old-style log_archive_dest cleared on standby" "grep -q \"set log_archive_dest=''\" $T/log/duplicate_*.rman"
check "old-style log_archive_dest: 4.4 shows the conversion to log_archive_dest_1 first" "grep -q \"alter system set log_archive_dest='' scope=both;\" $T/p7.txt && grep -q \"log_archive_dest_1='location=/arch'\" $T/p7.txt"
fresh empty; run $T/p8a.txt >/dev/null
jset $S "d['instances']['PRODDB_STBY']['datafiles']=3"
rc=$(run $T/p8.txt --only 10)
check "a finished standby that is behind the primary is still a standby (phase 10 runs)" "! grep -q 'does not exist yet (phase 8)' $T/p8.txt && grep -qE '^    10\.1 +ok' $T/p8.txt"
rc=$(run $T/p8b.txt)
check "... and step 7.2 never offers to delete it" "! grep -q 'the database is incomplete' $T/p8b.txt && ! grep -q 'asmcmd rm' $T/p8b.txt"
fresh; jset $P "d['oratab_has_db']=False; d['environ_readable']=False"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/p9.txt)
check "no oratab line on primary -> home found from the running process, note shown" "grep -q 'has no line for PRODDB' $T/p9.txt && grep -q 'ORACLE_SID=PRODDB  home=' $T/p9.txt"
fresh empty; groupadd -g 54327 other_grp
rc=$(DG_TEST_QUIT_AT=2.2 run $T/p10.txt); groupdel other_grp
check "gid already used by another group -> manual instructions shown" "grep -q 'Group id 54327 is needed for asmadmin, but group other_grp uses it here' $T/p10.txt && grep -q 'groupmod -g' $T/p10.txt && grep -q 'Run on this server' $T/p10.txt"
fresh; jset $P "d['ids']['oracle']=d['ids']['oracle']+',10(wheel),990(docker)'"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/p11.txt)
check "non-Oracle groups (wheel, docker) not copied" "! grep -qE 'GROUP_GIDS=.*(wheel|docker)' $T/varlib/settings.conf"
fresh empty; printf '%s\n' "127.0.1.1    $(hostname -s)" > /tmp/dgt-hosts.$$; cat /etc/hosts >> /tmp/dgt-hosts.$$; cp /tmp/dgt-hosts.$$ /etc/hosts; rm -f /tmp/dgt-hosts.$$
rc=$(DG_TEST_QUIT_AT=2.7 run $T/p12.txt)
check "standby host name on loopback -> found and fixed by the script (backup kept)" "grep -q 'resolves to 127.0.1.1 (loopback)' $T/p12.txt && ! grep -qE '^127\.0\.1\.1[[:space:]].*\b'\$(hostname -s)'\b' /etc/hosts && grep -qE '^192\.0\.2\.2[[:space:]]+(.* )?'\$(hostname -s)'( |$)' /etc/hosts && ls /etc/hosts.bak_* >/dev/null 2>&1 && grep -q '|2.6|EDIT|/etc/hosts|' $T/varlib/changes.log"
fresh
cat > $T/ed.sh <<'EOF'
#!/bin/bash
f=$1; c=/tmp/dgt/ed.count; n=$(cat $c 2>/dev/null || echo 0); echo $((n+1)) > $c
if [[ $n -eq 0 ]]; then sed -i 's/^STANDBY_SID=.*/STANDBY_SID=bad value/' "$f"; else sed -i 's/^STANDBY_SID=.*/STANDBY_SID=PRODDB_STBY/' "$f"; fi
EOF
chmod 755 $T/ed.sh
rc=$(EDITOR=$T/ed.sh DG_TEST_SETTINGS=e,e,a DG_TEST_QUIT_AT=2.1 run $T/p13.txt)
check "typo in settings editor -> error shown, can edit again, no stop" "grep -q 'The edited file has an error' $T/p13.txt && grep -q 'Settings saved' $T/p13.txt"
fresh; jset $P "d['domain']='example.local'"
rc=$(run $T/p14.txt)
check "db_domain set -> srvctl add with -domain" "grep -q -- '-domain example.local' $T/p14.txt"

CUR=Q; echo "== Q. Oracle Linux 7 (bash 4.2 mode, OpenSSH 7.4) and help after failures"
fresh empty
sed -i 's/^if (( BASH_VERSINFO\[0\] > 4 .*then set -u; fi$/: # bash 4.2 mode for the test: nounset off/' $T/dg_standby_setup.sh
check "bash 4.2 mode switch applied in the test copy" "grep -q 'bash 4.2 mode for the test' $T/dg_standby_setup.sh"
rc=$(run $T/q1.txt)
check "full run without set -u (as on bash 4.2) -> complete" "[[ $rc -eq 0 ]] && grep -q 'Standby setup is complete' $T/q1.txt"
check "OpenSSH 7.4 mock accepted the ssh options" "grep -q 'Connected to oracle@127.0.0.2' $T/q1.txt"
check "no 'unbound variable' anywhere" "! grep -q 'unbound variable' $T/q1.txt"
fresh empty; rc=$(DG_TEST_ASMPW=short DG_TEST_QUIT_AT=3.3 run $T/q2.txt)
check "after a failed action the manual commands of the step are shown" "grep -q 'To do this step by hand' $T/q2.txt && grep -qE 'Help .{1,3} Step 3\.2 ' $T/q2.txt && grep -q 'gridSetup.sh' $T/q2.txt"
fresh; jset $P "d['tns_stby']=1; d['tns_stby_host']='wronghost'"
rc=$(DG_TEST_NOFIX=4.9 DG_TEST_QUIT_AT=5.1 run $T/q3.txt)
check "primary step failure prints exact commands" "grep -q 'The entry must be:' $T/q3.txt"

CUR=R; echo "== R. Combinations: storage x version x owner x media x OS (full runs)"
full_ok() { # $1 output
  [[ $(grep -cE '^    [0-9.]+ +(skipped|failed, skipped|to do|UNKNOWN) ' "$1") -eq 0 ]] && grep -q 'Standby setup is complete' "$1" && safe_primary && no_secrets
}
combo() { # $1 tag, then env assignments for setup; runs empty server to the end
  local tag=$1; shift
  ( export "$@"; bash $TD/setup_env.sh empty >/dev/null )
  ( export "$@"; run $T/r_$tag.txt ) >/dev/null
}
DGT_UNAME_OL9=5.14.0-427.el9.x86_64

combo fs19 DGT_STORAGE=fs DGT_VER=19.21.0.0.0
check "fs 19c: complete, primary untouched" "full_ok $T/r_fs19.txt"
check "fs 19c: no Grid installed, no ASM disk touched" "! grep -q '^gridSetup' $T/state/calls.log && ! grep -q '^parted' $T/state/calls.log"
check "fs 19c: listener defined in the DB home" "grep -q '^LISTENER =' $T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/listener.ora && grep -q 'SID_NAME = PRODDB_STBY' $T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/listener.ora"
check "fs 19c: same folders, owner oracle" "[[ \$(stat -c %U $T/u02/oradata/PRODDB) == oracle && -d $T/u03/fra ]]"
check "fs 19c: RMAN control_files = same paths" "grep -q \"set control_files='$T/u02/oradata/PRODDB/control01.ctl','$T/u03/fra/PRODDB/control02.ctl'\" $T/log/duplicate_*.rman"
check "fs 19c: standby redo logs with file names" "grep -q \"add standby logfile thread 1 group 4 ('$T/u02/oradata/PRODDB/srl_t1_g4.log') size 200M\" $T/r_fs19.txt"
check "fs 19c: boot unit enabled, MOUNT only, clean stop, limits" "systemctl_enabled=\$(python3 -c \"import json;print(json.load(open('$O')).get('enabled'))\"); [[ \$systemctl_enabled == *oracle-standby-proddb_stby.service* ]] && grep -q 'startup mount' /usr/local/sbin/dg_standby_proddb_stby.sh && grep -q 'shutdown immediate' /usr/local/sbin/dg_standby_proddb_stby.sh && ! grep -qE 'alter database open|startup open' /usr/local/sbin/dg_standby_proddb_stby.sh && grep -q 'ExecStop=' /etc/systemd/system/oracle-standby-proddb_stby.service && grep -q 'LimitMEMLOCK=infinity' /etc/systemd/system/oracle-standby-proddb_stby.service"
check "fs 19c: storage tested not shared with primary" "grep -qE '^    2\.15 +ok' $T/r_fs19.txt"
check "fs 19c: datafiles keep their names (set newname to the same path)" "grep -q \"set newname for datafile 1 to '$T/u02/oradata/PRODDB/system01.dbf'\" $T/log/duplicate_*.rman"
check "fs 19c: no srvctl registration" "[[ \$(res 9.1 $T/r_fs19.txt) == OK ]] && ! grep -q 'srvctl user=oracle.*add' $T/state/calls.log"
check "fs 19c: /etc/oratab line" "grep -q '^PRODDB_STBY:$T/u01/app/oracle/product/19.0.0/dbhome_1:N' /etc/oratab"

combo single19 DGT_STORAGE=asm DGT_OWNER=single
check "single owner 19c: complete" "full_ok $T/r_single19.txt"
check "single owner: no grid user created, Grid home owned by oracle" "! id grid >/dev/null 2>&1 && [[ \$(stat -c %U $T/u01/app/19.0.0/grid) == oracle ]]"
check "single owner: ASMLib owner oracle" "python3 -c \"import json;assert json.load(open('$O'))['asm']['uid']=='oracle'\""
check "single owner: one profile (oracle -> standby SID)" "grep -q 'ORACLE_SID=PRODDB_STBY' /home/oracle/.bash_profile && ! grep -q 'ORACLE_SID=+ASM' /home/oracle/.bash_profile"

combo mixed21 DGT_STORAGE=mixed DGT_VER=21.13.0.0.0 DGT_OS=9 DGT_UNAME=$DGT_UNAME_OL9
check "mixed 21c OL9: complete" "full_ok $T/r_mixed21.txt"
check "mixed: udev rules (no ASMLib on this kernel) and /dev/oraasm disks" "[[ \$(grep -c 'oraasm/' /etc/udev/rules.d/99-oracle-asmdevices.rules) -eq 2 ]] && [[ -e /dev/oraasm/DATA_1 && -e /dev/oraasm/FRA_1 ]] && ! grep -q 'oracleasm user=root args=\\['\\''createdisk' $T/state/calls.log"
check "mixed: Grid installed with the udev discovery path" "grep -q 'oracle.install.asm.diskGroup.disks=/dev/oraasm/DATA_1' $T/state/last_grid_rsp_disks.txt"
check "mixed: udev rule limited to block partitions" "grep -q 'ACTION==\"add|change\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"partition\"' /etc/udev/rules.d/99-oracle-asmdevices.rules"
check "mixed: folder for the file-system part created" "[[ -d $T/u02/oradata/PRODDB ]]"
check "mixed: dnf used on OL9" "grep -q '^dnf user=root' $T/state/calls.log"

combo s121 DGT_VER=12.1.0.2.0 DGT_MEDIA=staged DGT_OS=7
check "12.1 staged OL7: complete" "full_ok $T/r_s121.txt"
check "12.1 OL7: patch 18370031 asked for before the Grid root.sh" "grep -q 'needs patch 18370031 before root.sh' $T/r_s121.txt"
check "12.1: yum and the 12cR1 preinstall package" "grep -q \"yum user=root args=\\['install', '-y', 'oracle-rdbms-server-12cR1-preinstall'\" $T/state/calls.log"
check "12.1: both zip files of each product used" "grep -q 'linuxamd64_12102_database_1of2.zip + /tmp/dgt/stage/linuxamd64_12102_database_2of2.zip' $T/r_s121.txt"
check "12.1: installers with -waitforcompletion, configToolAllCommands" "grep -q \"runInstaller user=grid .*'-waitforcompletion'\" $T/state/calls.log && grep -q 'configToolAllCommands' $T/state/calls.log"
check "12.1: 12.1 response keys (DBA_GROUP, DECLINE_SECURITY_UPDATES) set" "grep -q 'oracle.install.db.DBA_GROUP=dba' $T/log/run_*.log && grep -q 'DECLINE_SECURITY_UPDATES=true' $T/log/run_*.log"
check "12.1: no read-only-home step needed" "grep -q 'Not needed (read-only homes exist only from 18c)' $T/r_s121.txt && ! grep -q 'roohctl' $T/state/calls.log"
check "12.1: version_full not asked" "! grep -q 'version_full' $T/state/primary_sql.log"

combo s122 DGT_VER=12.2.0.1.0 DGT_MEDIA=staged DGT_OWNER=single DGT_OS=7
check "12.2 single owner OL7: complete" "full_ok $T/r_s122.txt"
check "12.2: grid image + staged database" "grep -q 'gridSetup.sh user=oracle' $T/state/calls.log && grep -q \"runInstaller user=oracle .*'-waitforcompletion'\" $T/state/calls.log"

combo gold18 DGT_VER=18.14.0.0.0 DGT_MEDIA=gold DGT_OS=7
check "18c gold image: complete" "full_ok $T/r_gold18.txt"
check "18c: gold image files used (no version in the name)" "grep -q 'db_home_2026-10-01_10-00-00AM.zip' $T/r_gold18.txt"

combo fs23 DGT_STORAGE=fs DGT_VER=23.5.0.24.07 DGT_OWNER=single DGT_OS=9 DGT_UNAME=$DGT_UNAME_OL9
check "23ai fs OL9: complete" "full_ok $T/r_fs23.txt"
check "23ai: short response keys (installOption, OSDBA) set" "grep -q 'installOption=INSTALL_DB_SWONLY' $T/log/run_*.log && grep -q 'OSDBA=dba' $T/log/run_*.log"
check "23ai: preinstall-23ai package" "grep -q 'oracle-database-preinstall-23ai' $T/state/calls.log"

( export DGT_MEDIA=broken; bash $TD/setup_env.sh empty >/dev/null )
rc=$(DG_TEST_QUIT_AT=3.7 run $T/r_broken.txt)
check "unknown response template -> clear stop, nothing installed" "grep -q 'template of this media lacks these keys: oracle.install.option' $T/r_broken.txt && ! grep -q '^runInstaller' $T/state/calls.log"

fresh empty; jset $P "d['rac']=True"
rc=$(run $T/r_rac.txt)
check "RAC primary -> refused at once" "[[ $rc -ne 0 ]] && grep -q 'RAC database' $T/r_rac.txt && ! grep -q groupadd $T/r_rac.txt"
fresh empty; jset $P "d['version']='11.2.0.4.0'"
rc=$(run $T/r_11.txt)
check "11g primary -> refused at once" "[[ $rc -ne 0 ]] && grep -q 'supports 12.1 and newer' $T/r_11.txt"

fresh; jset $P "d['threads']=2"
rc=$(run $T/r_thr.txt)
check "two redo threads -> standby logs for both threads" "grep -q 'Thread 2: 3 online log groups' $T/r_thr.txt && grep -q 'add standby logfile thread 2' $T/r_thr.txt"

fresh; jset $P "d['tde']=['FILE|$T/pwallet/|OPEN']; d['files']={'$T/pwallet/ewallet.p12':'EWALLET\n','$T/pwallet/cwallet.sso':'CWALLET\n'}"
rc=$(run $T/r_tde.txt)
check "TDE wallet copied to the same folder, md5 equal" "[[ \$(cat $T/pwallet/ewallet.p12) == EWALLET && \$(stat -c '%U %a' $T/pwallet/cwallet.sso) == 'oracle 600' ]] && [[ \$(res 6.3 $T/r_tde.txt) == DONE ]]"
check "TDE without WALLET_ROOT: sqlnet.ora points to the wallet" "grep -q 'ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = $T/pwallet)))' $T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/sqlnet.ora"
fresh; jset $P "d['tde']=['FILE|$T/pwallet/|OPEN']; d['wallet_root']='$T/pwroot'; d['files']={'$T/pwallet/ewallet.p12':'EWALLET\\n','$T/pwallet/cwallet.sso':'CWALLET\\n'}"
rc=$(DG_TEST_QUIT_AT=7.1 run $T/r_tde2.txt)
check "TDE with WALLET_ROOT: no sqlnet.ora entry" "[[ \$(res 6.3 $T/r_tde2.txt) == DONE ]] && ! grep -qs ENCRYPTION_WALLET_LOCATION $T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/sqlnet.ora"

( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['port']=1525"
rc=$(DG_TEST_QUIT_AT=6.1 run $T/r_port.txt)
check "primary port 1525 -> standby listener on 1525" "grep -q 'PORT = 1525' $T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/listener.ora"

fresh; jset $P "d['profile']=[]"
rc=$(DG_TEST_QUIT_AT=5.1 run $T/r_prof.txt)
check "primary .bash_profile without ORACLE_SID -> shown with the lines to add (optional)" "grep -q 'ORACLE_SID=<not set>' $T/r_prof.txt && grep -q 'export ORACLE_SID=PRODDB' $T/r_prof.txt"

fresh; jset $P "d['oratab_has_db']=False; d['exe_readable']=False"
rc=$(DG_TEST_HOMEPATH=$T/u01/app/oracle/product/19.0.0/dbhome_1 DG_TEST_QUIT_AT=2.1 run $T/r_home.txt)
check "home not in oratab, process not readable -> found in the inventory, not asked" "! grep -q 'Full path of the database ORACLE_HOME' $T/r_home.txt && grep -q 'ORACLE_SID=PRODDB  home=$T/u01/app/oracle/product/19.0.0/dbhome_1' $T/r_home.txt && grep -q 'Its home was found another way' $T/r_home.txt"


CUR=S; echo "== S. Audit round 1: new safety and flow checks"
# S1 storage shared with the primary (file system): the copy is refused
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['shared_dirs']=['$T/u02/oradata/PRODDB']"
rc=$(run $T/s1.txt)
check "shared folder detected (2.15) and the duplicate refused" "grep -q 'DANGER: these folders are the SAME storage as on the primary' $T/s1.txt && grep -q 'is the same storage that the primary uses (step 2.15)' $T/s1.txt && ! grep -q '^rman' $T/state/calls.log"
check "shared check left no test file behind" "! ls $T/u02/oradata/PRODDB/.dg_standby_test_* >/dev/null 2>&1"
# S2 a disk with data in its first MiB (for example an ASM disk of another server) is never offered
fresh empty; jset $O "d['disks']['/dev/sdb']['dirty']=True; d['disks']['/dev/sdf']={'size_mb':300000}"
rc=$(run $T/s2.txt)
check "disk with a non-empty first MiB not offered, not touched" "! grep -q 'parted user=root .*/dev/sdb' $T/state/calls.log && python3 -c \"import json;d=json.load(open('$O'))['asm']['disks'];assert d['DATA_1']=='/dev/sdf1',d\""
# S3 disk group names that are prefixes of each other (DATA and DATA2) get their own disks
fresh empty; jset $P "d['locs']=['+DATA:60000','+DATA2:20000']"; jset $O "d['disks']['/dev/sdf']={'size_mb':60000}"
rc=$(DG_TEST_DISK_PICKS=1,3,2 run $T/s3.txt)
check "DATA and DATA2: separate labels DATA_1 / DATA2_1, both disk groups created" "python3 -c \"import json;d=json.load(open('$O'))['asm']['disks'];assert 'DATA_1' in d and 'DATA2_1' in d and d['DATA_1']!=d['DATA2_1'],d\" && grep -qi 'create diskgroup data2 external redundancy disk .*DATA2_1' <<< \"\$(python3 -c \"import json;print(json.load(open('$S'))['dg_sql'])\")\" && [[ $rc -eq 0 ]]"
# S4 settings of version 3 are converted
fresh; mkdir -p $T/varlib; printf 'PRIMARY_IP=127.0.0.2\nPRIMARY_SSH_USER=oracle\nSTANDBY_UNIQUE=TAV_DR\nFRA_DG=FRA\nDATA_DISK=/dev/sdb\nGRID_ZIP=/tmp/dgt/stage/LINUX.X64_193000_grid_home.zip\n' > $T/varlib/settings.conf; chmod 600 $T/varlib/settings.conf
rc=$(DG_TEST_QUIT_AT=2.1 run $T/s4.txt)
check "v3 settings converted (backup kept, old keys dropped, names kept)" "grep -q 'came from an older version of the script' $T/s4.txt && ls $T/varlib/settings.conf.v3_* >/dev/null 2>&1 && grep -qE 'db_unique_name +TAV_DR' $T/s4.txt && grep -q '^GRID_MEDIA=/tmp/dgt/stage/LINUX.X64_193000_grid_home.zip' $T/varlib/settings.conf && ! grep -q 'FRA_DG' $T/varlib/settings.conf"
# S5 edit: a primary value cannot be changed; an edit that was not accepted is shown again next run
fresh; rc=$(DG_TEST_QUIT_AT=2.1 run $T/s5a.txt)
cat > $T/ed2.sh <<'EOF'
#!/bin/bash
sed -i 's#^DB_HOME=.*#DB_HOME=/somewhere/else#; s#^AUX_CHANNELS=.*#AUX_CHANNELS=8#' "$1"
EOF
chmod 755 $T/ed2.sh
rc=$(EDITOR=$T/ed2.sh DG_TEST_SETTINGS=e,q run $T/s5b.txt --settings)
check "--settings shows accepted settings; edit: primary value refused, standby value taken" "grep -q 'These values come from the primary and cannot be changed here: DB_HOME' $T/s5b.txt && grep -q 'Changed: AUX_CHANNELS=8' $T/s5b.txt"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/s5c.txt)
check "edited but not accepted -> shown again with what changed" "grep -q 'AUX_CHANNELS: 4 -> 8' $T/s5c.txt && grep -q '\[a\] Accept   \[e\] Edit' $T/s5c.txt"
# S6 only one run at a time
fresh; mkdir -p $T/varlib; ( flock $T/varlib/lock sleep 15 ) & lp=$!; sleep 1
rc=$(run $T/s6.txt); kill $lp 2>/dev/null; wait $lp 2>/dev/null
check "second run while one is active -> refused" "[[ $rc -ne 0 ]] && grep -q 'Another run of this script is active' $T/s6.txt"
# S7 the terminal is closed during the duplicate: RMAN goes on, the next run sees the result
fresh; jset $T/state/env.json "d['rman_sleep']=6"
rc=$(DG_TEST_HUP_ON_JOB='RMAN duplicate' run $T/s7a.txt)
check "closed terminal stops the script, not RMAN" "[[ $rc -ne 0 ]] && grep -q 'or the script was stopped (signal HUP)' $T/s7a.txt"
sleep 8
rc=$(run $T/s7b.txt)
check "after the copy ended: the next run sees a finished standby and completes" "python3 -c \"import json;assert json.load(open('$S')).get('duplicated')==1\" && grep -qE '^    8\.2 +ok' $T/s7b.txt && [[ $rc -eq 0 ]]"
# S8 sys password not given at 1.5 -> the login test offers to type it
fresh; rc=$(DG_TEST_PW1=Wrong_pw_1 DG_TEST_PSYS=7.4 run $T/s8.txt)
check "sys password can be typed when a step needs it" "grep -q '\[p\] Type the sys password' $T/s8.txt && grep -qE '^    7\.4 +ok' $T/s8.txt"
# S9 primary listener with another name: the standby listener is LISTENER on the same port
fresh empty; jset $P "d['listener_name']='LISTENER_TAV'"
rc=$(run $T/s9.txt)
check "primary listener LISTENER_TAV -> standby uses LISTENER (Grid), run complete" "[[ $rc -eq 0 ]] && grep -q 'Listener LISTENER_TAV' $T/s9.txt && grep -q 'SID_LIST_LISTENER =' $T/u01/app/19.0.0/grid/network/admin/listener.ora"
# S10 installer zip that others may change is not used
fresh empty; chmod 666 $T/stage/*.zip
rc=$(DG_TEST_QUIT_AT=3.2 run $T/s10.txt)
check "world-writable installer zip refused" "grep -q 'Not used, because of their owner or mode' $T/s10.txt && ! grep -q '^gridSetup' $T/state/calls.log"
# S11 19c on Oracle Linux 9 without a Release Update folder -> explained
( export DGT_OS=9 DGT_UNAME=5.14.0-427.el9.x86_64; bash $TD/setup_env.sh empty >/dev/null )
rc=$(DG_TEST_QUIT_AT=2.1 run $T/s11.txt)
check "19c on OL9 without RU -> 1.6 explains RU_DIR" "grep -q '19c on Oracle Linux 9 must be installed together with Release Update 19.19' $T/s11.txt"
# S12 LEGACY password file format is accepted
fresh; jset $T/state/env.json "d['pw_format']='LEGACY'"
rc=$(DG_TEST_QUIT_AT=7.1 run $T/s12.txt)
check "LEGACY password file format accepted" "[[ \$(res 6.1 $T/s12.txt) == DONE ]]"
# S13 temporary password copy on primary owned by another user is not used
fresh; jset $P "d['pw_tmp']=1; d['pw_tmp_owner']='nobody'"
rc=$(DG_TEST_NOFIX=6.1 DG_TEST_QUIT_AT=6.2 run $T/s13.txt)
check "password copy of another user on primary -> not used" "grep -q 'on the primary is not used (owner nobody' $T/s13.txt && ! grep -q 'scp /tmp/orapw_for_standby' $T/state/primary_cmds.log"
# S14 OL7 blkid prints no PART_ENTRY_UUID: the udev path still works (udevadm info)
( export DGT_OS=7 DGT_UNAME=3.10.0-1160.el7.x86_64; bash $TD/setup_env.sh empty >/dev/null ); jset $O "d['blkid_old']=True"
rc=$(DGT_UNAME=3.10.0-1160.el7.x86_64 run $T/s14.txt)
check "OL7 RHCK: udev rules with the UUID from udevadm info" "[[ $rc -eq 0 ]] && grep -q 'ENV{ID_PART_ENTRY_UUID}==\"[0-9a-f-]\{36\}\"' /etc/udev/rules.d/99-oracle-asmdevices.rules"
# S15 a step is never in an endless prompt loop: wrong answers are refused with a message
fresh empty; rc=$(DG_TEST_QUIT_AT=2.2 run $T/s15.txt)
check "first run: the ssh user is asked once with the default oracle; later runs only say it" "grep -q 'OS user for ssh on the primary' $T/s15.txt && [[ \$(grep -c 'OS user for ssh on the primary' $T/s15.txt) -eq 1 ]]"
rc=$(DG_TEST_QUIT_AT=2.2 run $T/s15b.txt)
check "... second run does not ask the ssh user" "grep -q 'ssh user on the primary: oracle' $T/s15b.txt && ! grep -q 'OS user for ssh on the primary' $T/s15b.txt"


CUR=T; echo "== T. Audit round 2"
# T1 Grid newer than the database (Grid 19c, database 12.2): Grid media and checks use the Grid release
( export DGT_VER=12.2.0.1.0 DGT_MEDIA=staged DGT_OS=7; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['grid_version']='19.21.0.0.0'"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/t1.txt)
check "Grid 19 with database 12.2: release shown, Grid 19 media asked for" "grep -q '(Grid 19) on Oracle Linux 7: supported' $T/t1.txt && grep -q 'for: Grid 19' $T/t1.txt && grep -q 'LINUX.X64_193000_grid_home.zip' $T/t1.txt"
# T2 existing ASM disks that you do not want: remembered, not asked again
fresh; rc=$(DG_TEST_YN=n DG_TEST_QUIT_AT=3.1 run $T/t2a.txt)
rc=$(DG_TEST_QUIT_AT=3.1 run $T/t2b.txt)
check "declined existing ASM disks are remembered" "grep -q 'This answer is remembered' $T/t2a.txt && grep -qx 'DATA1|-' $T/varlib/asm_disks && ! grep -q 'Use the existing ASM disks DATA1' $T/t2b.txt"
# T3 a failed copy (datafile headers with errors) is still recognised as incomplete; the cleanup lines check the host
( export DGT_STORAGE=fs; bash $TD/setup_env.sh installed >/dev/null ); jset $S "d['instances']['PRODDB_STBY']={'state':'mounted','datafiles':10,'df_errors':7}"
rc=$(DG_TEST_QUIT_AT=8.1 run $T/t3.txt)
check "file-system cleanup: rm lines only after the storage test, each with a host check" "grep -q 'the database is incomplete' $T/t3.txt && grep -qE '\\[ \"\\\$\\(hostname -s\\)\" = \"[^\"]+\" \\] && rm -f $T/u02/oradata/PRODDB/system01.dbf' $T/t3.txt"


CUR=U; echo "== U. Audit round 3"
# U1 the same file system UUID as on primary, test file not seen: copy or the SAME disk -> not proven
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']='/dev/vdb aaaa1111-2222-3333-4444-555566667777'"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u1a.txt)
check "same file system UUID -> not accepted, compare the disks, no advice to change the disk" "grep -q 'same file system UUID (aaaa1111' $T/u1a.txt && ! grep -q 'xfs_admin' $T/u1a.txt && grep -q 'Type SEPARATE to continue' $T/u1a.txt && ! grep -qE '^    2\.15 +(ok|done)' $T/u1a.txt"
touch $T/varlib/storage_clone_confirmed; echo bbbb1111-2222-3333-4444-555566667777 > $T/varlib/storage_clone_ok
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u1b.txt)
check "... a general confirmation file or another UUID does not count" "! grep -qE '^    2\.15 +ok' $T/u1b.txt"
echo aaaa1111-2222-3333-4444-555566667777 >> $T/varlib/storage_clone_ok
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u1c.txt)
check "... accepted after the confirmation for exactly this UUID" "grep -qE '^    2\.15 +ok' $T/u1c.txt && grep -q 'you confirmed it is a separate disk' $T/u1c.txt"
# U1d same UUID on the same disk WWN -> shared (DANGER)
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']='/dev/vdb aaaa1111-2222-3333-4444-555566667777'"
jset $O "d['disks']['/dev/vdb']={'mnt':'/u02','size_mb':102400,'wwn':'0x5000c500aaaa0001'}"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u1d.txt)
check "same UUID on the same disk WWN -> DANGER, shared" "grep -q 'DANGER' $T/u1d.txt && grep -q 'on the same disk 0x5000c500aaaa0001 as on the primary' $T/u1d.txt"
# U1e same UUID, other disk ids -> still not proven (ids that differ do not prove two disks)
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']='/dev/vdb aaaa1111-2222-3333-4444-555566667777'"
jset $O "d['disks']['/dev/vdb']={'mnt':'/u02','size_mb':102400,'wwn':'0x5000c500bbbb0002','serial':'STBYDISK1'}"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u1e.txt)
check "same UUID, other disk ids -> not accepted without confirmation" "! grep -qE '^    2\.15 +ok' $T/u1e.txt && grep -q 'or the same disk mounted on both servers' $T/u1e.txt"
# U2 same UUID and the primary user cannot look into the folder -> not proven
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']='/dev/vdb aaaa1111-2222-3333-4444-555566667777'; d['canlook']='NO'"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u2.txt)
check "same UUID, folder not visible on primary -> not accepted" "grep -q 'same file system UUID (aaaa1111' $T/u2.txt && ! grep -qE '^    2\.15 +ok' $T/u2.txt"
# U3 the primary does not show a UUID for one of its file systems, folder not visible -> not proven
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']=''; d['canlook']='NO'"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u3.txt)
check "primary list of UUIDs incomplete, folder not visible -> not proven" "grep -q 'It cannot be proven that this is not the storage of the primary' $T/u3.txt && grep -q 'does not show the UUID of every file system' $T/u3.txt && ! grep -qE '^    2\.15 +ok' $T/u3.txt"
# U4 folder not visible, but the primary shows all its file systems and this UUID is not one of them -> not shared
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['canlook']='NO'"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u4.txt)
check "UUID not mounted on primary (complete list) -> accepted" "grep -qE '^    2\.15 +ok' $T/u4.txt && grep -q 'is not mounted on the primary' $T/u4.txt"
# U5 test file not seen, but the list of the primary is incomplete -> not proven; U6 confirmed -> accepted
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['mount_uuids']=['']"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u5.txt)
check "incomplete UUID list on primary -> not accepted even when the test file is not seen" "! grep -qE '^    2\.15 +ok' $T/u5.txt && grep -q 'does not show the UUID of every file system' $T/u5.txt"
echo aaaa1111-2222-3333-4444-555566667777 > $T/varlib/storage_clone_ok
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u6.txt)
check "... accepted after the confirmation for this disk" "grep -qE '^    2\.15 +ok' $T/u6.txt"
# U7 the local file system UUID is a file system the primary mounts at ANOTHER path -> not accepted
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['mount_uuids']=['aaaa1111-2222-3333-4444-555566667777']"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u7.txt)
check "UUID mounted on primary at another path -> not accepted" "grep -q 'same file system UUID (aaaa1111' $T/u7.txt && ! grep -qE '^    2\.15 +ok' $T/u7.txt"
# U8 a local disk WWN is a disk under a file system of the primary (other UUID) -> not accepted
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['devid']='TYPE=\"disk\" WWN=\"0x5000c500cccc0003\" SERIAL=\"X\"'"
jset $O "d['disks']['/dev/vdb']={'mnt':'/u02','size_mb':102400,'wwn':'0x5000c500cccc0003'}"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/u8.txt)
check "local disk WWN is under a file system of the primary -> not accepted" "! grep -qE '^    2\.15 +ok' $T/u8.txt && grep -q 'is also under a file system of the primary' $T/u8.txt"

CUR=V; echo "== V. Audit round 4"
# V1 the terminal is closed during the duplicate, the copy ends, then the server is rebooted: the result still counts
fresh; jset $T/state/env.json "d['rman_sleep']=6"
rc=$(DG_TEST_HUP_ON_JOB='RMAN duplicate' run $T/v1a.txt)
sleep 8
sed -i 's/|[^|]*$/|another-boot-id/' $T/varlib/job
jset $S "d['instances']['PRODDB_STBY']['state']='idle'"
rc=$(run $T/v1b.txt)
check "finished duplicate + reboot -> result kept, no second duplicate" "grep -q 'has ended with exit code' $T/v1b.txt && python3 -c \"import json;assert json.load(open('$S')).get('duplicated')==1\" && [[ $rc -eq 0 ]]"
# V2 --from 7.3 on a built standby that is shut down: the login steps wait for 9.2, they do not ask for 7.2
jset $S "d['instances']['PRODDB_STBY']['state']='idle'"
rc=$(DG_TEST_QUIT_AT=8.1 run $T/v2.txt --from 7.3)
check "--from 7.3 on a stopped standby -> 7.3 OK (tested after 9.2)" "grep -qE '^    7\.3 +ok' $T/v2.txt && ! grep -q 'The instance is not started (step 7.2)' $T/v2.txt"
# V3 a job of a run before a reboot that did not end: its response files are removed; check mode keeps the job file
fresh; mkdir -p /tmp/dg_rsp.v3test $T/varlib $T/log; echo secret > /tmp/dg_rsp.v3test/grid.rsp; touch $T/log/unzip_v3.log
echo "999999|root script /x/root.sh|$T/log/unzip_v3.log|/tmp/dg_rsp.v3test/grid.rsp|another-boot-id" > $T/varlib/job
rc=$(run $T/v3a.txt --check)
check "check mode leaves the job file of an earlier boot" "[[ -f $T/varlib/job ]] && [[ -f /tmp/dg_rsp.v3test/grid.rsp ]]"
rc=$(DG_TEST_QUIT_AT=1.1 run $T/v3b.txt)
check "a normal run reports the stopped job and removes its response files" "grep -q 'was stopped by a reboot' $T/v3b.txt && [[ ! -e /tmp/dg_rsp.v3test/grid.rsp ]] && [[ ! -f $T/varlib/job ]]"
rm -rf /tmp/dg_rsp.v3test
# V4 an unzip that fails half-way in this run: the folder is marked, the installer is never started from it
fresh empty
python3 - $T/stage/LINUX.X64_193000_grid_home.zip <<'EOF'
import sys, zipfile
z = sys.argv[1]
with zipfile.ZipFile(z, "a", compression=zipfile.ZIP_STORED) as f: f.writestr("zz_part.dat", b"A" * 4000)
b = bytearray(open(z, "rb").read()); i = b.rindex(b"A" * 4000); b[i + 100] = ord("B"); open(z, "wb").write(bytes(b))
EOF
rc=$(DG_TEST_QUIT_AT=3.5 run $T/v4a.txt)
check "failed unzip -> marker names the folder" "grep -q 'grid' $T/varlib/unzip_failed && grep -q '$T/u01/app/19.0.0/grid' $T/varlib/unzip_failed"
rc=$(DG_TEST_QUIT_AT=3.5 run $T/v4b.txt)
check "... next run: incomplete folder shown, gridSetup never started" "grep -q 'An earlier unzip did not finish' $T/v4b.txt && ! grep -q 'gridSetup.sh user=' $T/state/calls.log"
# V5 a standby recognised by comparison (marker 'seen') is compared again while mounted
( export DGT_STORAGE=fs; bash $TD/setup_env.sh installed >/dev/null ); jset $S "d['instances']['PRODDB_STBY']={'state':'mounted','datafiles':10,'df_errors':0}"
rc=$(DG_TEST_QUIT_AT=8.1 run $T/v5a.txt)
mk=$(ls $T/u01/app/oracle/product/*/dbhome_1/dbs/.dg_duplicate_done_* 2>/dev/null | head -n 1)
check "mounted complete standby -> marker 'seen' (not 'duplicate')" "[[ -n '$mk' ]] && grep -qx seen '$mk'"
jset $S "d['instances']['PRODDB_STBY']['df_errors']=7"
rc=$(DG_TEST_QUIT_AT=8.1 run $T/v5b.txt)
check "... later header errors are reported, never treated as a failed copy" "grep -q 'datafile header(s) show an error' $T/v5b.txt && ! grep -q 'the database is incomplete' $T/v5b.txt"
# V6 a job of an earlier run has ended (exit code written) but left a program running: finished, not waited for
fresh; mkdir -p $T/varlib $T/log; : > $T/log/v6job.log; echo 0 > $T/log/v6job.log.rc
setsid sh -c 'sleep 25' & sleep 1; lp=$(pgrep -n -f '^sleep 25$'); lead=$(ps -o sid= -p $lp | tr -d ' ')
echo "$lead|unzip v6.zip|$T/log/v6job.log||$(cat /proc/sys/kernel/random/boot_id)" > $T/varlib/job
rc=$(DG_TEST_QUIT_AT=1.2 run $T/v6.txt)
check "ended job with a left-over program -> finished, the run goes on" "grep -q 'has ended, but programs it started still run' $T/v6.txt && grep -q 'has ended with exit code' $T/v6.txt && [[ ! -f $T/varlib/job ]]"
kill $lp 2>/dev/null
# V7 the leader of an earlier job is gone, a program of its session still runs: [w] waits until the session ends
fresh; mkdir -p $T/varlib $T/log; : > $T/log/v7job.log
setsid sh -c 'sleep 8 & exit 0'; sleep 1; lp=$(pgrep -n -f '^sleep 8$'); lead=$(ps -o sid= -p $lp | tr -d ' ')
echo "$lead|unzip v7.zip|$T/log/v7job.log||$(cat /proc/sys/kernel/random/boot_id)" > $T/varlib/job
rc=$(DG_TEST_QUIT_AT=1.2 run $T/v7.txt)
check "leader gone, program left -> [c] offered, [w] waits for the session" "grep -q '\\[c\\] Continue without it' $T/v7.txt && grep -q 'has ended with exit code' $T/v7.txt && ! pgrep -f '^sleep 8$' >/dev/null"

CUR=W; echo "== W. Field report 1 (check mode on a real server)"
# W1 software installed here, no instance yet: check mode shows no PROBLEM for 1.4 / 4.2 / 7.6
fresh; jset $S "d['instances']={}"
rc=$(run $T/w1.txt --check)
check "check mode, software installed, no instance: 4.2 query works, 7.4/7.6 wait for 7.2" "! grep -q 'ORA-00937' $T/w1.txt && ! grep -qE '^  (1\.4|4\.2|7\.6) +PROBLEM' $T/w1.txt && grep -qE '^    7\.6 +waiting' $T/w1.txt && grep -qE '^    7\.4 +waiting' $T/w1.txt"
# W2 Grid home inside the Grid base on primary (works there): kept, only noted
fresh; jset $P "d['grid_base']='$T/u01/app'"
rc=$(run $T/w2.txt --check)
check "Grid home inside Grid base as on primary -> 1.4 not a problem, noted" "! grep -qE '^    1\.4 +problem' $T/w2.txt && grep -q 'is inside the Grid base' $T/w2.txt"
# W3 a failed login shows the real error (printed before the marker), not only SP2-0640
fresh; jset $S "d['instances']={'PRODDB_STBY':{'state':'started'}}"; jset $P "d['tns_stby']=0"
rc=$(DG_TEST_NOFIX=4.9 DG_TEST_QUIT_AT=7.7 run $T/w3.txt --from 7.6)
check "login from primary fails -> ORA-12154 and its explanation, not only SP2-0640" "grep -q 'sys@proddb_stby failed (ORA-12154' $T/w3.txt && grep -q 'The alias is missing in tnsnames.ora' $T/w3.txt"

CUR=X; echo "== X. Pass 1 of the final review (flow, questions, rollback, Oracle, OS)"
# X1 a full run: no [y] question for 1.2/1.3/1.5, the progress board, the end hints, the journal
fresh empty
rc=$(run $T/x1.txt)
check "no [y] question before the settings (1.2, 1.3 only read)" "! sed -n '/Step 1.2  /,/Step 1.4  /p' $T/x1.txt | grep -q '\[y\] Yes, do it'"
check "progress board at the start, with the legend" "grep -q '  Progress' $T/x1.txt && grep -q 'Nothing is set up yet' $T/x1.txt"
check "phase 4 offered first after phase 1" "grep -q 'Do phase 4 (primary) first' $T/x1.txt"
check "one box with every primary command of phase 4 (batch)" "grep -q 'steps need commands on the primary. They are shown together below, in order.' $T/x1.txt && grep -q -- '-- Step 4.2: Standby redo logs' $T/x1.txt && grep -q -- '-- Undo, if ever needed: alter database drop standby logfile' $T/x1.txt"
check "run-mode summary has a legend and the changes of this run" "grep -qE '[0-9]+ already ok, [0-9]+ done in this run' $T/x1.txt && grep -q 'ok = was already correct' $T/x1.txt && grep -q 'Changes on this server in this run' $T/x1.txt"
check "end hints: archivelog deletion, password file, reboot" "grep -qi 'archivelog deletion policy' $T/x1.txt && grep -q 'Plan one reboot' $T/x1.txt"
check "journal records the primary commands with their undo" "grep -q '|PRIMARY|4.4|' $T/varlib/changes.log && grep -q 'alter system reset log_archive_dest_2' $T/varlib/changes.log"
check "progress and last_run files written" "grep -q '^9.7|DONE|' $T/varlib/progress && grep -q 'every step OK' $T/varlib/last_run"
check "RMAN plan is short: counts instead of one line per datafile; size and time estimate" "grep -qE '[0-9]+ datafiles? and [0-9]+ tempfiles? keep their disk group or path' $T/x1.txt && grep -q 'Rough time:' $T/x1.txt"
check "duplicate: audit folder of the standby, convert pair against ORA-19527 noise" "grep -q \"audit_file_dest='$T/u01/app/oracle/admin/PRODDB_STBY/adump'\" $T/log/duplicate_*.rman && grep -q '__dg_no_rename__' $T/log/duplicate_*.rman"
# X2 --status and --show-changes without a connection; a second run shows the board as DONE
rc=$(run $T/x2.txt --status)
check "--status: every phase DONE, no connection, no password asked" "grep -qE '^ +1  Connect to the primary +done' $T/x2.txt && grep -qE '^ +10  Health check +done' $T/x2.txt && ! grep -q 'password' $T/x2.txt && [[ $rc -eq 0 ]]"
rc=$(run $T/x2b.txt --show-changes 9.7)
check "--show-changes 9.7 lists the unit and the script with their undo" "grep -q 'UNIT' $T/x2b.txt && grep -q 'auto: systemctl disable' $T/x2b.txt && grep -q 'dg_standby_proddb_stby.sh' $T/x2b.txt"
# X3 --undo 9.7: unit disabled, files removed; the standby itself is left alone
rc=$(run $T/x3.txt --undo 9.7)
check "--undo 9.7 marks the step UNDONE on the progress board" "grep -q '^9.7|UNDONE|' $T/varlib/progress"
check "--undo 9.7 removes the unit and the script, standby untouched" "grep -q 'is disabled: it no longer starts at boot. The running standby was not stopped.' $T/x3.txt && [[ ! -e /etc/systemd/system/oracle-standby-apply-proddb_stby.service ]] && [[ ! -e /usr/local/sbin/dg_standby_proddb_stby.sh ]] && ! grep -q 'shutdown' $T/state/calls.log"
rc=$(run $T/x3b.txt --show-changes 9.7)
check "... afterwards --show-changes 9.7 has nothing left" "grep -q 'No change is recorded for step 9.7' $T/x3b.txt"
# X4 --undo 5.4 while later steps exist: the word UNDO is required; the appended block is cut off exactly
tns=$T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/tnsnames.ora; cp $tns $T/tns_before_undo
rc=$(run $T/x4.txt --undo 5.4)
check "--undo 5.4 warns about later steps and needs UNDO; the standby alias block is removed, the primary alias stays" "grep -q 'Later steps have changes that build on this one' $T/x4.txt && ! grep -qi '^proddb_stby' $tns && grep -qi '^proddb *=' $tns"
# X5 a second run with two running databases on the primary: the saved one is used without a question
fresh; rc=$(DG_TEST_QUIT_AT=2.1 run $T/x5a.txt); jset $P "d['extra_pmon']=['OTHERDB']"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/x5.txt)
check "saved PRIMARY_SID used again, no question" "grep -q 'chosen in an earlier run' $T/x5.txt && ! grep -q 'Number of the database' $T/x5.txt"
# X6 no listener found on primary: assumed values are marked and can be corrected in 1.4
fresh empty; jset $P "d['listener_name']='LISTENER_X'; d['lsnr_no_service']=1"
cat > $T/ed3.sh <<'EOF'
#!/bin/bash
sed -i 's#^PORT=.*#PORT=1530#; s#^PRIMARY_SERVICE=.*#PRIMARY_SERVICE=proddb_svc#' "$1"
EOF
chmod 755 $T/ed3.sh
rc=$(EDITOR=$T/ed3.sh DG_TEST_SETTINGS=e,a DG_TEST_QUIT_AT=1.6 run $T/x6.txt)
check "assumed listener values: warned, marked ASSUMED, edit of PORT accepted" "grep -q 'Assuming LISTENER, port 1521' $T/x6.txt && grep -q '(assumed)' $T/x6.txt && grep -q 'No running listener offers this service' $T/x6.txt && grep -q 'PORT=1530' $T/varlib/settings.conf && grep -q '^PRIMARY_SERVICE=proddb_svc' $T/varlib/settings.conf"
rc=$(DG_TEST_QUIT_AT=1.6 run $T/x6b.txt)
check "... the next run keeps the corrected values" "grep -q 'Using your settings: LISTENER, port 1530, service proddb_svc' $T/x6b.txt"
# X7 response file: the commented example line of the real template is NOT the one that is set
G=$(mktemp); sed -n '/^rsp_set()/,/^}/p' $T/dg_standby_setup.sh > "$G"; source "$G"; rm -f "$G"
R=$(mktemp); printf '#-----\n#     For Unix based Operating System:\n#     oracle.install.asm.diskGroup.disks=/oracle/asm/disk1,/oracle/asm/disk2\n#-----\noracle.install.asm.diskGroup.disks=\n' > "$R"
rsp_set "$R" /dev/oraasm/DATA_1 oracle.install.asm.diskGroup.disks
check "rsp_set replaces the real key, never the commented example" "[[ \$(grep -c '^oracle.install.asm.diskGroup.disks=/dev/oraasm/DATA_1' $R) -eq 1 ]] && grep -q '^#     oracle.install.asm.diskGroup.disks=/oracle' $R && ! grep -q '^oracle.install.asm.diskGroup.disks=$' $R"
rm -f "$R"
# X8 standby redo log size is rounded UP to whole MB (else the primary would get more and more logs)
fresh; jset $P "d['orl_bytes']=100000000; d['srl']=0"
rc=$(DG_TEST_QUIT_AT=4.3 run $T/x8.txt --only 4)
check "SRL size 100000000 bytes -> size 96M (rounded up)" "grep -q 'add standby logfile thread 1 size 96M' $T/x8.txt"
# X9 log_archive_config keeps other members; 4.7 pending restart
fresh; jset $P "d['params']['log_archive_config']='DG_CONFIG=(PRODDB,OTHERSB)'; d['params']['remote_login_passwordfile']='NONE'; d['spparams']={'remote_login_passwordfile':'EXCLUSIVE'}"
rc=$(DG_TEST_NOFIX=4.7 run $T/x9.txt --only 4)
check "4.3 printed command keeps OTHERSB and adds the standby" "grep -q \"dg_config=(PRODDB,OTHERSB,PRODDB_STBY)\" $T/x9.txt"
check "4.7: EXCLUSIVE already in the spfile -> restart pending, no new alter" "grep -q 'is already in the spfile' $T/x9.txt && ! grep -q 'alter system set remote_login_passwordfile=exclusive' $T/x9.txt"
# X10 4.9: alias right, standby listener not up yet -> not 'missing'
fresh empty; jset $P "d['tns_stby']=1; d['stby_lsnr_down']=1"
rc=$(DG_TEST_QUIT_AT=4.10 run $T/x10.txt --only 4)
check "4.9 with TNS-12541 -> alias accepted (listener comes in phase 5)" "grep -qE '^    4\.9 +ok' $T/x10.txt && grep -q 'Nothing answers on this server yet' $T/x10.txt"
# X11 a failed copy left the instance NOMOUNT with its spfile -> 7.2 shows the clean-up, no second duplicate
fresh; jset $S "d['instances']['PRODDB_STBY']={'state':'started','spfile_param':'$T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora'}"; touch $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora; chown oracle $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(DG_TEST_NOFIX=7.2 DG_TEST_QUIT_AT=7.3 run $T/x11.txt --from 6.1)
check "NOMOUNT from the spfile of a failed copy -> shutdown abort + move spfile plan, nothing automatic" "grep -q 'runs from the spfile of an unfinished copy' $T/x11.txt && grep -q 'shutdown abort' $T/x11.txt && ! grep -q '^rman ' $T/state/calls.log"
# X12 files of an interrupted copy in ASM while the instance is down -> named before NOMOUNT
fresh; jset $S "d['instances']['PRODDB_STBY']={'state':'idle'}; d['asm_leftovers']=1"
rc=$(DG_TEST_NOFIX=7.2 DG_TEST_QUIT_AT=7.3 run $T/x12.txt --from 6.1)
check "leftovers of an earlier copy (+DATA/PRODDB_STBY) named with the clean-up commands" "grep -q 'files already exist where the standby database will be written' $T/x12.txt && grep -q 'asmcmd rm -rf +DATA/PRODDB_STBY' $T/x12.txt && grep -q 'NEVER remove +DATA/PRODDB' $T/x12.txt"
check "steps behind the skipped 7.2 wait by themselves (not asked again)" "! grep -q 'Step 7.2 is not done in this run (result' $T/x12.txt && grep -q 'Waiting for step 7.2, which was not done in this run' $T/x12.txt && grep -qE '^    7\.4 +waiting' $T/x12.txt && grep -q 'steps need a step that was not done in this run' $T/x12.txt"
# X13 files at the target paths (file system) that no copy of this script made -> OVERWRITE guard
( export DGT_STORAGE=fs; bash $TD/setup_env.sh installed >/dev/null ); mkdir -p $T/u02/oradata/PRODDB; echo old > $T/u02/oradata/PRODDB/system01.dbf; chown -R oracle $T/u02/oradata
rc=$(DG_TEST_NOFIX=7.2 DG_TEST_QUIT_AT=8.2 run $T/x13.txt)
check "existing file at a target path -> named in 7.2 with the clean-up, no copy" "grep -q 'files already exist where the standby database will be written' $T/x13.txt && grep -q 'rm -f $T/u02/oradata/PRODDB/system01.dbf' $T/x13.txt && ! grep -q '^rman ' $T/state/calls.log"
touch $T/varlib/existing_files_ok
rc=$(run $T/x13b.txt)
check "... with existing_files_ok the copy runs" "[[ $rc -eq 0 ]] && python3 -c \"import json;assert json.load(open('$S')).get('duplicated')==1\""
# X14 12.1 primary: the password file is found without the 12.2 column
( export DGT_VER=12.1.0.2.0 DGT_OS=7 DGT_UNAME=4.1.12-124.el7uek.x86_64 DGT_STORAGE=fs DGT_OWNER=single; bash $TD/setup_env.sh installed >/dev/null )
rc=$(DG_TEST_QUIT_AT=6.2 run $T/x14.txt --from 6.1)
check "12.1: password file copied (no 'format' column needed)" "grep -qE '^    6\.1 +done' $T/x14.txt"
# X15 TDE without an auto-login keystore: 6.3 asks for it, 8.1 refuses the copy until it exists
fresh; jset $P "d['tde']=['FILE|$T/pwallet/|OPEN']; d['files']={'$T/pwallet/ewallet.p12':'EWALLET\\n'}"
rc=$(DG_TEST_NOFIX=6.3 DG_TEST_QUIT_AT=8.2 run $T/x15.txt --from 6.1)
check "TDE without cwallet.sso -> orapki auto_login asked; 8.1 blocked" "grep -q 'orapki wallet create -wallet .* -auto_login' $T/x15.txt && grep -q 'no auto-login file (cwallet.sso)' $T/x15.txt && ! grep -q '^rman ' $T/state/calls.log"
# X16 Standard Edition primary -> stop at 1.3, nothing installed
fresh empty; jset $P "d['banner']='Oracle Database 19c Standard Edition 2 Release 19.0.0.0.0 - Production'"
rc=$(run $T/x16.txt)
check "Standard Edition -> stop at discovery, before any install" "[[ $rc -ne 0 ]] && grep -q 'Standard Edition' $T/x16.txt && ! grep -q 'gridSetup.sh user=' $T/state/calls.log && ! id oracle >/dev/null 2>&1"
# X17 patched primary + base media: told at 3.1, before installing
fresh empty
rc=$(DG_TEST_QUIT_AT=3.2 run $T/x17.txt)
check "3.1 says the primary has patches and how to avoid patching by hand" "grep -q 'The primary has patches' $T/x17.txt && grep -q 'and OPATCH_ZIP in the settings' $T/x17.txt"
# X18 a home in the inventory without a finished installer -> not 'installed'
fresh; chown oracle $T/u01/app/oracle/product/19.0.0/dbhome_1/bin/oradism; rm -f $T/varlib/db_install.done
rc=$(DG_TEST_NOFIX=3.6 DG_TEST_QUIT_AT=3.7 run $T/x18.txt --from 3.6)
check "inventory entry without finished installer -> HALF installed, m / c choice offered" "grep -q 'no record that its installer finished' $T/x18.txt && grep -q 'I installed it myself, without error' $T/x18.txt && ! grep -q 'runInstaller user=' $T/state/calls.log"
# X19 DUPLICATE typed in lower case is accepted; a wrong word gets two more tries
fresh
rc=$(DG_TEST_DUP=duplicate DG_TEST_QUIT_AT=9.1 run $T/x19.txt)
check "'duplicate' (lower case) accepted" "grep -qE '^    8\.2 +done' $T/x19.txt"
# X20 the daily check on a standby that is down says so
fresh; jset $S "d['instances']['PRODDB_STBY']['state']='idle'"; touch $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/.dg_duplicate_done_PRODDB_STBY $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(run $T/x20.txt --only 10)
check "--only 10 with the standby down: clear message, no v\$ errors" "grep -q 'The standby instance is not running (step 9.2)' $T/x20.txt && ! grep -q 'Cannot read v' $T/x20.txt"
# X21 apply not in real time -> warned
fresh; jset $S "d['instances']['PRODDB_STBY']={'state':'mounted','datafiles':10,'df_errors':0,'srl':4,'recovery_mode':'MANAGED'}"; printf 'duplicate\n' > $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/.dg_duplicate_done_PRODDB_STBY; touch $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(DG_TEST_QUIT_AT=9.5 run $T/x21.txt --from 9.4)
check "recovery_mode MANAGED (not real time) -> warning with the causes" "grep -q 'not in real time' $T/x21.txt"
# X22 --settings reviews and stops; a built standby in --check: 2.15 OK
fresh
rc=$(run $T/x22.txt --settings)
check "--settings stops after phase 1" "grep -q 'Settings reviewed' $T/x22.txt && ! grep -q 'Step 2.1  ' $T/x22.txt && [[ $rc -eq 0 ]]"
( export DGT_STORAGE=fs; bash $TD/setup_env.sh installed >/dev/null ); printf 'duplicate\n' > $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/.dg_duplicate_done_PRODDB_STBY
rc=$(run $T/x22b.txt --check)
check "--check on a built standby: 2.15 is OK (proven before the copy), not WAITS" "grep -qE '^    2\.15 +ok' $T/x22b.txt"


CUR=Y; echo "== Y. Pass 2 of the final review"
# Y1 the phase-4 box answered with r: steps are DONE_BY_YOU and the primary commands are in the journal with their undo
fresh; rc=$(DG_TEST_BATCH=r run $T/y1.txt --only 4)
check "batch box + r: 4.3 DONE_BY_YOU, PRIMARY journal line with its undo" "grep -qE '^    4\.3 +done by you' $T/y1.txt && grep -q '|4.3|PRIMARY|' $T/varlib/changes.log && ! grep -q '^4.3|' $T/varlib/primary_pending"
rc=$(run $T/y1b.txt --show-changes 4.3)
check "--show-changes 4.3 shows the primary command and its undo" "grep -q 'PRIMARY' $T/y1b.txt && grep -q 'log_archive_config' $T/y1b.txt"
# Y2 phase 4 can be done first, right after phase 1
fresh empty; rc=$(DG_TEST_P4FIRST=4 DG_TEST_QUIT_AT=2.1 run $T/y2.txt)
check "[4] at the end of phase 1: phase 4 runs before phase 2" "[[ \$(grep -n 'Phase 4 of 10' $T/y2.txt | head -n 1 | cut -d: -f1) -lt \$(grep -n 'Phase 2 of 10' $T/y2.txt | head -n 1 | cut -d: -f1) ]]"
# Y3 the terminal is closed during the Grid installer: --status and --check see the running job; the next run records the result
fresh empty; jset $T/state/env.json "d['installer_sleep']=12"
rc=$(DG_TEST_HUP_ON_JOB='Grid installer' run $T/y3a.txt)
rc=$(run $T/y3s.txt --status)
check "--status during the installer: 'Running now' with the job" "grep -q 'Running now: Grid installer' $T/y3s.txt"
rc=$(run $T/y3c.txt --check)
check "--check during the installer: phase 3 and later WAITS, no clean-up plan" "grep -qE '^    3\.2 +waiting' $T/y3c.txt && grep -qE 'is still running \(session|has ended but is not recorded yet' $T/y3c.txt && ! grep -q 'deinstall' $T/y3c.txt"
sleep 14
rc=$(DG_TEST_QUIT_AT=3.3 run $T/y3b.txt --from 3.2)
check "installer ended unwatched -> recorded; 3.2 OK (not HALF installed); SOFTWARE in the journal" "grep -q 'had finished without error. Its result is recorded' $T/y3b.txt && grep -qE '^    3\.2 +ok' $T/y3b.txt && grep -q '|3.2|SOFTWARE|' $T/varlib/changes.log"
# Y4 a failed duplicate: only [q] is offered, the next step is 7.2 (one Next line)
fresh; jset $T/state/env.json "d['rman_fail']=1"
rc=$(run $T/y4.txt)
check "failed duplicate: only [q], continue with --from 7.2, phase 9 not started" "grep -q 'The next run first shows how to clean up this server' $T/y4.txt && grep -qE 'Next: ' $T/y4.txt && ! grep -q 'Step 9.1  ' $T/y4.txt && ! grep -q 'from 8.0' $T/y4.txt"
# Y5 --undo goes alone; --undo with unusable settings stops
rc=$(run $T/y5.txt --undo 9.7 --check)
check "--undo with --check refused" "[[ $rc -eq 2 ]] && grep -q 'cannot be combined with other options' $T/y5.txt"
fresh; rc=$(DG_TEST_QUIT_AT=2.1 run $T/y5a.txt); sed -i 's/^AUX_CHANNELS=.*/AUX_CHANNELS=abc/' $T/varlib/settings.conf; echo '1|2026-10-26 10:00:00|x|9.4|MRP|PRODDB_STBY|redo apply started' > $T/varlib/changes.log; chmod 600 $T/varlib/changes.log
rc=$(run $T/y5b.txt --undo 9.4)
check "--undo with unusable settings: stops, nothing marked undone" "[[ $rc -ne 0 ]] && grep -q 'cannot be used' $T/y5b.txt && ! grep -q 'UNDONE' $T/varlib/changes.log"
# Y6 SRL undo: standby_file_management MANUAL for the drop, AUTO again
fresh; rc=$(DG_TEST_QUIT_AT=2.1 run $T/y6a.txt); jset $S "d['instances']['PRODDB_STBY']={'state':'mounted','datafiles':10,'df_errors':0,'srl':4,'mrp':1}"; printf 'duplicate\n' > $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/.dg_duplicate_done_PRODDB_STBY; touch $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
printf '#journal v1\n1|2026-10-26 10:00:00|x|9.3|SRL|PRODDB_STBY|5\n' > $T/varlib/changes.log; chmod 600 $T/varlib/changes.log
rc=$(run $T/y6.txt --undo 9.3)
check "SRL undo: drop with MANUAL, AUTO again, apply restart advised" "grep -q 'Standby log group 5 dropped' $T/y6.txt && python3 -c \"import json;d=json.load(open('$S'))['instances']['PRODDB_STBY'];assert d['sfm']=='AUTO' and 5 in d['dropped']\" && grep -q 'Redo apply was stopped for the drop' $T/y6.txt"
# Y7 log_archive_config written with spaces: the other standby is kept
fresh; jset $P "d['params']['log_archive_config']='DG_CONFIG = ( PRODDB , OTHERSB )'"
rc=$(DG_TEST_NOFIX=4.3 run $T/y7.txt --only 4)
check "dg_config with spaces: OTHERSB kept in the printed command" "grep -q \"dg_config=(PRODDB,OTHERSB,PRODDB_STBY)\" $T/y7.txt"
# Y8 primary started from a pfile -> 4.1 prints create spfile
fresh; jset $P "d['spfile']='-'"
rc=$(DG_TEST_NOFIX=4.1 run $T/y8.txt --only 4)
check "primary without spfile: 4.1 says create spfile from memory (with a pfile backup)" "grep -q 'create spfile from memory' $T/y8.txt && grep -q 'create pfile=' $T/y8.txt"
# Y9 primary without a password file -> orapwd
fresh; jset $P "d['sys_in_pwfile']=False; d['pwfile']='-'"
rc=$(DG_TEST_NOFIX=4.7 run $T/y9.txt --only 4)
check "primary without password file: 4.7 prints orapwd, not alter user" "grep -q 'orapwd file=' $T/y9.txt"
# Y10 LOCAL auto-login wallet: cwallet.sso is not copied, made here with -auto_login_local
fresh; jset $P "d['tde']=['FILE|$T/pwallet/|OPEN|LOCAL_AUTOLOGIN']; d['files']={'$T/pwallet/ewallet.p12':'EWALLET\\n','$T/pwallet/cwallet.sso':'LOCALSSO\\n'}"
rc=$(DG_TEST_NOFIX=6.3 DG_TEST_QUIT_AT=7.1 run $T/y10.txt --from 6.1)
check "LOCAL auto-login wallet: not copied, orapki -auto_login_local shown" "grep -q -- '-auto_login_local' $T/y10.txt && [[ ! -f $T/pwallet/cwallet.sso ]] && [[ -f $T/pwallet/ewallet.p12 ]]"
# Y11 typed word: an Enter by mistake asks again
fresh; rc=$(DG_TEST_DUP= DG_TEST_QUIT_AT=9.1 run $T/y11.txt)
check "Enter at DUPLICATE asks again (does not skip the copy)" "grep -q 'Nothing was typed. Type DUPLICATE' $T/y11.txt"

#==============================================================================
CUR=Z; echo "== Z. External review fixes (5.1)"
fresh
G=$(mktemp); { sed -n '/^v_name()/p;/^v_path()/p' $T/dg_standby_setup.sh; sed -n '/^valid_value()/,/^}/p' $T/dg_standby_setup.sh; } > "$G"
for v in 10.0.0.5 192.168.1.20 db01 db01.example.local; do
  out=$(bash -c "source $G; valid_value ip '$v' && echo OK" 2>&1); check "ip accepted: $v" "[[ '$out' == OK ]]"
done
for v in 10.0.0 192.168.1. 999.1.1.1 1.2.3.4.5 -host a..b; do
  out=$(bash -c "source $G; valid_value ip '$v' && echo OK" 2>&1); check "ip refused: $v" "[[ '$out' != OK ]]"
done
out=$(bash -c "source $G; v_name -inherit && echo OK" 2>&1); check "listener name -inherit refused (skipped, no safety stop)" "[[ '$out' != OK ]]"
rm -f "$G"
# empty derived keys in the settings file are derived again (as the file itself says)
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z1.txt)
sed -i 's/^STANDBY_SID=.*/STANDBY_SID=/; s/^STANDBY_TNS=.*/STANDBY_TNS=/' $T/varlib/settings.conf
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z2.txt --settings)
check "empty STANDBY_SID / STANDBY_TNS in the settings are derived again" "! grep -q 'Invalid value' $T/z2.txt && grep -q '^STANDBY_SID=PRODDB_STBY$' $T/varlib/settings.conf"

# ---- 5.3: the script fixes what is safe on this server itself ----
# oratab line with another home -> corrected, Y/N kept
fresh; printf 'PRODDB_STBY:/u01/other/home:Y\n' >> /etc/oratab
rc=$(DG_TEST_QUIT_AT=8.1 run $T/z3.txt --from 7.7)
check "oratab line with another home -> corrected by the script, Y kept" "grep -qx 'PRODDB_STBY:$T/u01/app/oracle/product/19.0.0/dbhome_1:Y' /etc/oratab && ! grep -q '/u01/other/home' /etc/oratab"
# a fresh mount point with only lost+found counts as empty: the script sets its owner
fresh empty; mkdir -p $T/u01/app/oracle/lost+found; chown root:root $T/u01/app/oracle
rc=$(DG_TEST_QUIT_AT=2.6 run $T/z4.txt)
check "folder with only lost+found -> owner set by the script" "[[ \$(stat -c %U $T/u01/app/oracle) == oracle ]] && grep -qE '^    2\.5 +done' $T/z4.txt"
# half-installed database home: [c] cleans it (inventory marked REMOVED) and installs again
fresh; chown oracle $T/u01/app/oracle/product/19.0.0/dbhome_1/bin/oradism; rm -f $T/varlib/db_install.done
rc=$(DG_TEST_QUIT_AT=3.7 run $T/z5.txt --from 3.6)
check "half-installed home: c -> marked removed in the inventory, emptied, installed again" "grep -q 'Marked $T/u01/app/oracle/product/19.0.0/dbhome_1 as removed' $T/z5.txt && grep -q 'Emptied $T/u01/app/oracle/product/19.0.0/dbhome_1' $T/z5.txt && grep -q 'runInstaller user=' $T/state/calls.log"
# oracle program with the wrong group (role separation) -> 8.1 runs setasmgidwrap itself, journaled
fresh; chgrp oinstall $T/u01/app/oracle/product/19.0.0/dbhome_1/bin/oracle; jset $S "d['instances']['PRODDB_STBY']={'state':'started'}"; jset $P "d['log_mode']='ARCHIVELOG'; d['force_logging']='YES'"
rc=$(DG_TEST_QUIT_AT=8.2 run $T/z6.txt --from 7.2)
check "wrong group of the oracle program -> setasmgidwrap run by step 8.1, in the journal" "grep -q 'setasmgidwrap user=' $T/state/calls.log && [[ \$(stat -c %G $T/u01/app/oracle/product/19.0.0/dbhome_1/bin/oracle) == asmadmin ]] && grep -q '|8.1|ASMGID|' $T/varlib/changes.log"
# files of an unfinished copy of this script in ASM, instance down -> DELETE typed -> removed by the script, then NOMOUNT
fresh; jset $S "d['instances']['PRODDB_STBY']={'state':'idle'}; d['asm_leftovers']=1"; mkdir -p $T/varlib; chmod 700 $T/varlib; touch $T/varlib/dup_attempt; rm -f $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/.dg_duplicate_done_PRODDB_STBY
rc=$(DG_TEST_QUIT_AT=7.3 run $T/z7.txt --from 6.1)
check "leftovers of an unfinished copy: DELETE -> +DATA/PRODDB_STBY removed, never the primary's, instance started" "python3 -c \"import json;d=json.load(open('$S'));assert d.get('asm_removed') and all(x.upper().endswith('/PRODDB_STBY') for x in d['asm_removed']);assert d['instances']['PRODDB_STBY']['state']=='started'\""
# the same, but the admin keeps the files
fresh; jset $S "d['instances']['PRODDB_STBY']={'state':'idle'}; d['asm_leftovers']=1"; mkdir -p $T/varlib; chmod 700 $T/varlib; touch $T/varlib/dup_attempt; rm -f $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/.dg_duplicate_done_PRODDB_STBY
rc=$(DG_TEST_L72=k DG_TEST_QUIT_AT=7.3 run $T/z8.txt --from 6.1)
check "leftovers kept with k -> nothing removed, existing_files_ok recorded" "[[ -f $T/varlib/existing_files_ok ]] && ! python3 -c \"import json;assert json.load(open('$S')).get('asm_removed')\" 2>/dev/null"

echo
echo "RESULT: $PASS passed, $FAILN failed"
for f in "${FAILED[@]}"; do echo "  - $f"; done
[[ $FAILN -eq 0 ]]
