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
# (pipefail off while a condition runs: in "sed ... | grep -q x", grep ends at the first match and sed may then
# get SIGPIPE; the result is the one of grep, as in a plain shell)
check() { local ok=0; set +o pipefail; eval "$2" && ok=1; set -o pipefail; if [[ $ok -eq 1 ]]; then pass "$1"; else fail "$1"; fi; }
fresh() { bash $TD/setup_env.sh "${1:-installed}" >/dev/null; }
jset() { python3 - "$@" <<'EOF'
import json,sys
f,expr=sys.argv[1],sys.argv[2]
d=json.load(open(f)); exec(expr); json.dump(d,open(f,'w'),indent=1)
EOF
}
run() { # $1 = output file, rest = script args.  Env DG_TEST_* passed through.
  local out=$1; shift
  ( cd $T && PATH=$T/rootbin:$PATH DG_PLAIN=${DG_PLAIN:-1} DG_VERBOSE=${DG_VERBOSE:-1} DG_SSH_DIR=$T/ssh DG_LOG_DIR=$T/log DG_STATE_DIR=$T/varlib DG_OS_RELEASE_FILE=$T/os-release DG_FSTAB_FILE=$T/fstab DG_SHM_UNIT_FILE=$T/dev-shm.mount DG_MEMINFO_FILE=${DG_MEMINFO_FILE:-$T/meminfo} DG_POLL_WAIT=1 DG_TEST_FAST_WAITS=${DG_TEST_FAST_WAITS:-1} DG_TEST_OUT=$out \
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
hostres_ok() {
  # the read-only probe "hostres <name>": how a host name resolves on the primary
  local n; n=$(sed -n "s/^sh -c 'echo F \$(getent -s files ahostsv4 \([A-Za-z0-9.-]*\) 2>.*/\1/p" <<< "$1")
  [[ -n "$n" && "$1" == "sh -c 'echo F \$(getent -s files ahostsv4 $n 2>/dev/null | head -n 1); echo D \$(timeout 10 getent -s dns ahostsv4 $n 2>/dev/null | head -n 1); echo A \$(getent ahosts $n 2>/dev/null | head -n 1)'" ]]
}
cmds_whitelisted() {
  # every command sent to the primary must be one of the read-only probes
  local l bad=0
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    l=${l#timeout 120 }
    if [[ "$l" =~ ^\[master\ opened ]] || [[ "$l" =~ ^\[ssh-keyscan\ [0-9.]+\]$ ]] || [[ "$l" =~ ^\[scp\ /tmp/orapw_for_standby_[A-Z_]+\]$ ]] || [[ "$l" =~ ^\[scp\ /[A-Za-z0-9_./]+orapw[A-Za-z0-9_]*\]$ ]] \
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
       || [[ "$l" =~ ^sh\ -c\ \'e=\$\(LC_ALL=C\ timeout\ 8\ bash\ -c\ \"exec\ 3\<\>/dev/tcp/[0-9.]+/[0-9]+\"\ 2\>\&1\)\;\ r=\$\?\;\ case\ \"\$r:\$e\"\ in\ 0:\*\)\ echo\ OPEN\;\;\ 124:\*\)\ echo\ TIMEOUT\;\;\ \*refused\*\)\ echo\ REFUSED\;\;\ \*unreachable\*\)\ echo\ UNREACH\;\;\ \*No\\\ route\*\)\ echo\ NOROUTE\;\;\ \*\)\ echo\ BLOCKED\;\;\ esac\'$ ]] \
       || [[ "$l" == "nproc" || "$l" == "hostname -I" || "$l" == "dd if=/dev/zero bs=1M count=64 status=none" ]] \
       || hostres_ok "$l" \
       || [[ "$l" == "ps -eo pid,user:32,args" ]] || [[ "$l" =~ ^readlink\ /proc/[0-9]+/exe$ ]] \
       || [[ "$l" =~ ^tr\ \'\\0\'\ \'\\n\'\ \<\ /proc/[0-9]+/environ\ \|\ grep\ -E\ \'\^\(ORACLE_HOME\|ORACLE_SID\|ORACLE_BASE\|TNS_ADMIN\)=\'$ ]] \
       || [[ "$l" =~ ^md5sum\ /[A-Za-z0-9_./-]+$ ]] || [[ "$l" =~ ^ls\ -1A\ /[A-Za-z0-9_./-]+$ ]] \
       || [[ "$l" == "grep -sE '^[[:space:]]*(export[[:space:]]+)?(ORACLE_HOME|ORACLE_SID|ORACLE_BASE|TNS_ADMIN)=' \$HOME/.bash_profile \$HOME/.bashrc" ]] \
       || [[ "$l" =~ ^sh\ -c\ \'f=~[a-z]+/\.bash_profile\;\ if\ \[\ -r\ \"\$f\"\ \]\;\ then\ grep\ -sE\ .+\ \"\$f\"\ ~[a-z]+/\.bashrc\;\ true\;\ else\ echo\ NOREAD\;\ fi\'$ ]] \
       || [[ "$l" =~ ^env\ (-u\ [A-Z_]+\ )*ORACLE_HOME=/[^\ ]+\ ORACLE_SID=[A-Za-z0-9_]+\ TNS_ADMIN=/[^\ ]+\ timeout\ [0-9]+\ /[^\ ]+/bin/sqlplus\ -S\ /nolog$ ]]; then :; else
      printf '        not whitelisted: %s\n' "$l"; bad=1
    fi
  done < $T/state/primary_cmds.log
  [[ $bad -eq 0 && ! -s $T/state/primary_UNEXPECTED.log ]]
}
safe_primary() { cmds_whitelisted && ! nonselect_on_primary; }
no_secrets() { ! grep -rqE 'Welcome_123|Asm_Pass123|Oracle_os1' $T/log/ "$T/varlib" 2>/dev/null; }
full_ok() { # $1 output
  [[ $(grep -cE '^    [0-9.]+ +(skipped|failed, skipped|to do|UNKNOWN) ' "$1") -eq 0 ]] && grep -q 'Standby setup is complete' "$1" && safe_primary && no_secrets
}
combo() { # $1 tag, then env assignments for setup; runs empty server to the end
  local tag=$1; shift
  ( export "$@"; bash $TD/setup_env.sh empty >/dev/null )
  ( export "$@"; run $T/r_$tag.txt ) >/dev/null
}

ut_lsnr_host_esc() { # step 3.9's listener.ora HOST fix, taken from the script: prints "<escaped old host>|<3 results>"
  # (no Oracle needed; runs on bash 4.2 too: section A)
  local d esc line cmd L39_BADHOST=old.example.com STANDBY_HOST=stby01 L39_LORA besc
  d=$(mktemp -d); L39_LORA=$d/listener.ora
  esc=$(grep -o "sed 's#\[\]\[[^']*'" $T/dg_standby_setup.sh | head -n 1)
  line=$(grep -o "cp_add grid \"sed -i -E 's/(HOST.*" $T/dg_standby_setup.sh | head -n 1); line=${line#cp_add grid }; line=${line% ;;}
  besc=$(printf '%s' "$L39_BADHOST" | eval "$esc")
  printf '%s\n' 'L1 = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = old.example.com)(PORT = 1521)))' \
    'L2 = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = oldxexample.com)(PORT = 1522)))' \
    'L3 = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = old.example.com.x)(PORT = 1523)))' > $L39_LORA
  eval "cmd=$line"
  [[ -n "$esc" && -n "$line" ]] && bash -c "$cmd" >/dev/null 2>&1
  printf '%s|%s|%s|%s\n' "$besc" "$(grep -c '(HOST = stby01)(PORT = 1521)' $L39_LORA)" "$(grep -c '(HOST = oldxexample.com)' $L39_LORA)" "$(grep -c '(HOST = old.example.com.x)' $L39_LORA)"
  rm -rf "$d"
}
#==============================================================================
# Parts: the suite can be run in parts, e.g. one part per CI job (.github/workflows/ci.yml).
#   run_scenarios.sh                    every section, in order
#   run_scenarios.sh --part 3           the sections of part 3 (DG_PART=3 does the same)
#   run_scenarios.sh --sections A,Q     only these sections (DG_SECTIONS=A,Q)
#   run_scenarios.sh --list-parts       the parts and their sections
# Every section is in exactly one part; a part starts from a fresh mock environment, so its first
# section must not need what an earlier section left behind (B, C and D share one, so they stay together).
# A new section needs "if part KEY; then ... fi" around it and its KEY in PARTS, or every run fails.
PARTS=(
  [1]="A B C D E F G H I J K"
  [2]="L M N O Q Z4 Z11"
  [3]="P Z5 Z17 Z19 5.24"
  [4]="R Z16 Z21"
  [5]="S Z1 Z15"
  [6]="T U V Z3 5.22"
  [7]="W X Z6 Z20"
  [8]="Y Z7 Z10 Z18"
  [9]="Z8 Z9 Z14"
  [10]="Z12 Z13"
  [11]="5.23"
)
SEL_PART=${DG_PART:-}; SEL_SECTIONS=${DG_SECTIONS:-}; LIST_PARTS=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --part) SEL_PART=${2:-}; shift 2 || shift ;;
    --part=*) SEL_PART=${1#*=}; shift ;;
    --sections) SEL_SECTIONS=${2:-}; shift 2 || shift ;;
    --sections=*) SEL_SECTIONS=${1#*=}; shift ;;
    --list-parts) LIST_PARTS=1; shift ;;
    *) echo "usage: $0 [--part N | --sections A,B,... | --list-parts]" >&2; exit 2 ;;
  esac
done
SEL_SECTIONS=${SEL_SECTIONS//,/ }
if [[ $LIST_PARTS == 1 ]]; then
  for p in "${!PARTS[@]}"; do printf '%2s  %s\n' "$p" "${PARTS[$p]}"; done; exit 0
fi
if [[ -n "$SEL_PART" ]] && { [[ "$SEL_PART" == *[!0-9]* ]] || [[ -z "${PARTS[$SEL_PART]:-}" ]]; }; then
  echo "no part '$SEL_PART' (parts: ${!PARTS[*]})" >&2; exit 2
fi
CUR=-; RAN_SECTIONS=""; PART_STARTED=""
part() { # $1 = section key; true when the section runs in this run
  local k=$1 p hit=""
  for p in "${!PARTS[@]}"; do [[ " ${PARTS[$p]} " == *" $k "* ]] && hit=$p; done
  if [[ -z "$hit" ]]; then
    CUR=$k; fail "section $k is in no part of PARTS in run_scenarios.sh (CI would never run it)"
    [[ -z "$SEL_PART$SEL_SECTIONS" ]] || return 1
  elif [[ -n "$SEL_SECTIONS" ]]; then [[ " $SEL_SECTIONS " == *" $k "* ]] || return 1
  elif [[ -n "$SEL_PART" ]]; then [[ "$hit" == "$SEL_PART" ]] || return 1
  fi
  # a part on its own starts from a fresh mock environment (the full run has one from the section before)
  if [[ -n "$SEL_PART$SEL_SECTIONS" && -z "$PART_STARTED" ]]; then PART_STARTED=1; fresh; fi
  RAN_SECTIONS+=" $k"
  printf -- '-- section %s starts %ds into this run\n' "$k" "$SECONDS"
}
parts_done() { # every section that should have run did run (a key in PARTS with no section is a typo)
  local p k want=""
  if [[ -n "$SEL_SECTIONS" ]]; then want=$SEL_SECTIONS
  elif [[ -n "$SEL_PART" ]]; then want=${PARTS[$SEL_PART]}
  else for p in "${!PARTS[@]}"; do want+=" ${PARTS[$p]}"; done; fi
  CUR=parts
  for k in $want; do [[ " $RAN_SECTIONS " == *" $k "* ]] || fail "section $k (in PARTS or asked for) does not exist or did not run"; done
  [[ -n "$SEL_PART$SEL_SECTIONS" ]] && echo "This run: ${SEL_PART:+part $SEL_PART, }sections:$RAN_SECTIONS"
  true
}

#==============================================================================
if part A; then
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
ut_lsnr_host_esc > $T/ut_a_lhost.txt
check "unit: 3.9 listener.ora HOST fix: old.example.com escaped to old\\.example\\.com; only that HOST is replaced" "[[ \$(cat $T/ut_a_lhost.txt) == 'old\\.example\\.com|1|1|1' ]]"

fi
#==============================================================================
if part B; then
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
check "RMAN puts the whole database into the data disk group (OMF), one line per channel" "grep -q \"^  set newname for database to '+DATA';\" $T/log/duplicate_*.rman && grep -q \"set control_files='+DATA'\" $T/log/duplicate_*.rman && grep -q \"set db_create_file_dest='+DATA'\" $T/log/duplicate_*.rman && ! grep -q 'disk;  set' $T/log/duplicate_*.rman"
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

fi
if part C; then
CUR=C; echo "== C. Second run on the finished server changes nothing"
: > $T/state/calls.log; : > $T/state/primary_cmds.log
rc=$(run $T/c.txt)
check "exit 0" "[[ $rc -eq 0 ]]"
check "no step DONE now except ssh/discovery/sys password" "! grep -E '^    [0-9.]+ +done ' $T/c.txt | grep -vE '^    1\.[235] ' | grep -q ."
check "second run: the summary screen, started with Enter, no settings question; 1.4 ok (nothing changed)" "grep -q 'Values of this run' $T/c.txt && grep -q 'Same settings as before' $T/c.txt && ! grep -q '\[a\] Accept' $T/c.txt && [[ \$(res 1.4 $T/c.txt) == OK ]]"
check "no installer, no rman, no parted, no groupadd" "! grep -qE '^(gridSetup|runInstaller|rman|parted)' $T/state/calls.log"
check "primary still safe" "safe_primary"

fi
if part D; then
CUR=D; echo "== D. --only 10 (daily check) and --from"
rc=$(run $T/d1.txt --only 10)
check "--only 10 exit 0" "[[ $rc -eq 0 ]]"
check "--only 10 runs phase 1 and 10 only" "grep -q 'Phase 10 of 10' $T/d1.txt && ! grep -qE 'Phase (2|3|4|5|6|7|8|9) of 10' $T/d1.txt"
rc=$(run $T/d2.txt --from 9.3)
check "--from 9.3 starts at 9.3" "grep -q 'Step 9.3  ' $T/d2.txt && ! grep -q 'Step 9.2  ' $T/d2.txt && ! grep -q 'Phase 8 of 10' $T/d2.txt"
rc=$(run $T/d3.txt --from 11); check "--from 11 rejected" "[[ $rc -ne 0 ]] && grep -q 'Use --from' $T/d3.txt"
rc=$(run $T/d4.txt --from 3.99); check "--from 3.99 (no such step) rejected" "[[ $rc -eq 2 ]] && grep -q 'There is no step 3.99' $T/d4.txt"
rc=$(run $T/d5.txt --from 5.1 --only 10); check "--from with --only rejected" "[[ $rc -eq 2 ]] && grep -q 'not both' $T/d5.txt"
rc=$(run $T/d6.txt --from 9.1); check "--from 9.1 does not ask the sys password, says all OK" "! grep -q 'sys password of the primary' $T/d6.txt && grep -q 'Standby setup is complete' $T/d6.txt"

fi
if part E; then
CUR=E; echo "== E. --check on an empty server changes nothing"
fresh empty
rc=$(run $T/e.txt --check)
check "exit non-zero (work to do)" "[[ $rc -ne 0 ]]"
check "no groups/users created" "! getent group oinstall >/dev/null && ! id oracle >/dev/null 2>&1"
check "no dnf/oracleasm configure/parted" "! grep -qE \"^(dnf|parted) |'-u', 'grid'\" $T/state/calls.log"
check "no settings file written" "[[ ! -f $T/varlib/settings.conf ]]"
check "no [y] do it prompt" "! grep -q '\[y\] Yes, do it' $T/e.txt"
check "TODO items listed" "grep -qE '^    2\.1 +to do' $T/e.txt"
check "check mode: waiting steps are WAIT, not FAIL" "grep -q 'Checked after step 2.2 is done' $T/e.txt && ! grep -q 'Not possible yet' $T/e.txt && grep -qE '^    2\.5 +waiting' $T/e.txt"
check "check mode: legend explains TODO / WAITS / PROBLEM" "grep -q 'Only .problem. steps need your attention' $T/e.txt"
check "check mode on a new server with a healthy primary: no PROBLEM (7.6 waits for 7.2)" "! grep -qE '^    [0-9]+\.[0-9]+ +problem' $T/e.txt && grep -qE '^    7\.6 +waiting' $T/e.txt"
check "primary safe" "safe_primary"

fi
if part F; then
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

fi
if part G; then
CUR=G; echo "== G. Installed server: fixes + manual steps"
fresh
rc=$(run $T/g.txt)
check "exit 0" "[[ $rc -eq 0 ]]"
check "oracle missing groups added with usermod" "grep -q 'usermod -a -G oper,backupdba,dgdba,kmdba,racdba,asmdba oracle' $T/g.txt && id -nG oracle | grep -qw kmdba"
check "wrong static ORACLE_HOME detected and the entry replaced (5.14: on its own lines, a backup kept)" "grep -q 'ORACLE_HOME is not' $T/g.txt && grep -q 'Replace the entry of PRODDB_STBY inside SID_LIST_LISTENER' $T/g.txt && grep -q 'ORACLE_HOME = $T/u01/app/oracle/product/19.0.0/dbhome_1' $T/u01/app/19.0.0/grid/network/admin/listener.ora"
check "5.1 recorded DONE" "[[ \$(res 5.1 $T/g.txt) == DONE ]]"
check "ASM disks of an older version (DATA1) are used only after you confirm" "grep -q 'Use the existing ASM disks DATA1 for +DATA' $T/g.txt && grep -qx 'DATA1|/dev/sdb1' $T/varlib/asm_disks"
check "existing proddb alias accepted, standby alias added" "[[ \$(res 5.3 $T/g.txt) == OK && \$(res 5.4 $T/g.txt) == DONE ]]"
check "no installer run (software present)" "! grep -qE '^(gridSetup|runInstaller)' $T/state/calls.log"
check "primary safe" "safe_primary"

fi
if part H; then
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
out=$(cd $T && DG_STATE_DIR=$T/varlib DG_LOG_DIR=$T/log bash ./dg_standby_setup.sh --help-step all 2>&1); n=$(grep -cE 'Help .{1,3} Step [0-9]' <<< "$out")
check "--help-step all prints every step (77, with 9.9) and the help of --health" "[[ $n -eq 77 ]] && grep -q 'Unattended health check' <<< \"\$out\""
check "--help-step uses saved names" "grep -q 'PRODDB_STBY' <<< \"\$out\""
out=$(cd $T && bash ./dg_standby_setup.sh --help-step 9.10 2>&1); check "--help-step unknown -> message" "grep -q 'No help for step' <<< \"\$out\""
out=$(cd $T && bash ./dg_standby_setup.sh --help 2>&1); check "--help shows usage" "grep -q -- '--primary' <<< \"\$out\""
for st in 1.1 1.2 1.3 1.4 1.5 1.6 2.1 2.2 2.3 2.4 2.5 2.6 2.7 2.8 2.9 2.10 2.11 2.12 2.13 2.14 2.15 2.16 3.1 3.2 3.3 3.4 3.5 3.6 3.7 3.8 3.9 3.10 3.11 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9 4.10 4.11 5.1 5.2 5.3 5.4 6.1 6.2 6.3 7.1 7.2 7.3 7.4 7.5 7.6 7.7 8.1 8.2 9.1 9.2 9.3 9.4 9.5 9.6 9.7 9.8 10.1 10.2 10.3 10.4; do
  grep -q "run_step $st " $T/dg_standby_setup.sh || fail "step $st exists in the script"
done
pass "all help ids are real steps"

fi
if part I; then
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

fi
if part J; then
CUR=J; echo "== J. Primary side not done by the DBA"
fresh; rc=$(DG_TEST_NOFIX=4.3,4.8,4.10 run $T/j.txt)
check "4.3 SKIPPED, optional 4.8 / 4.10 SKIPPED_OPTIONAL, others continue" "[[ \$(res 4.3 $T/j.txt) == SKIPPED && \$(res 4.8 $T/j.txt) == SKIPPED_OPTIONAL && \$(res 4.10 $T/j.txt) == SKIPPED_OPTIONAL && \$(res 5.1 $T/j.txt) != '' ]]"
check "commands for primary were printed, never run" "grep -q \"alter system set log_archive_config='dg_config=(PRODDB,PRODDB_STBY)' scope=both;\" $T/j.txt && safe_primary"
fresh; jset $P "d['tns_stby']=1; d['tns_stby_host']='wronghost'"
rc=$(run $T/j2.txt)
check "primary alias pointing to a wrong host detected" "grep -q 'is different: HOST is wronghost' $T/j2.txt"
fresh; jset $P "d['dest2_error']='ORA-16191: Primary log shipping client not logged on standby'; d['params']['log_archive_dest_state_2']='ENABLE'"
rc=$(DG_TEST_NOFIX=9.5 run $T/j3.txt)
check "dest_2 error explained (password file)" "grep -q 'password files differ' $T/j3.txt"

fi
if part K; then
CUR=K; echo "== K. Password file variants"
fresh; jset $P "d['pwfile']='$T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB'"
rc=$(run $T/k1.txt)
check "password file on disk -> copied directly, no primary action" "[[ \$(res 6.1 $T/k1.txt) == DONE ]] && ! grep -q 'asmcmd pwcopy' $T/k1.txt"
fresh; printf 'OLDFILE\n' > $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY; chown oracle:oinstall $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY
rc=$(run $T/k2.txt)
check "invalid existing file replaced, backup kept" "ls $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY.bak_* >/dev/null 2>&1 && grep -q ORAPW-PRIMARY $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY"

fi
if part L; then
CUR=L; echo "== L. Duplicate safety"
fresh; rc=$(DG_TEST_DUP=no run $T/l1.txt)
check "duplicate not confirmed -> not run" "grep -q 'The copy was not started' $T/l1.txt && ! python3 -c \"import json;assert json.load(open('$S')).get('duplicated')\" 2>/dev/null"
check "8.2 SKIPPED (not started is not a failure), 9.x cannot run" "[[ \$(res 8.2 $T/l1.txt) == SKIPPED ]] && grep -q 'does not exist yet (phase 8)' $T/l1.txt"
fresh; jset $S "d['instances']['PRODDB_STBY']={'state':'mounted','datafiles':10,'df_errors':7}"
rc=$(run $T/l2.txt)
check "incomplete standby, no copy of this script recorded -> only [m] (a script file), never [y], no rman" "grep -q 'the database is incomplete' $T/l2.txt && grep -q 'Never touched: +DATA/PRODDB' $T/l2.txt && ! grep -q '\[y\] Clean up for me' $T/l2.txt && ! grep -q \"^rman .*args=\\[\\]\" $T/state/calls.log"
fresh; python3 - <<EOF
import json; f='$T/state/env.json'; d=json.load(open(f)); d['data_free']=1000; json.dump(d,open(f,'w'))
EOF
rc=$(run $T/l3.txt)
check "not enough space in +DATA -> no duplicate" "grep -q 'Not enough space here for the copy' $T/l3.txt && ! grep -q \"^rman .*args=\\[\\]\" $T/state/calls.log"
fresh; jset $P "d['params']['log_archive_dest_3']='service=other'; d['params']['db_create_online_log_dest_1']='+REDO1'"
rc=$(run $T/l4.txt)
check "primary-only parameters remapped/cleared in RMAN script (the logs go to the standby's own disk group, not +REDO1)" "grep -q \"set db_create_online_log_dest_1='+DATA'\" $T/log/duplicate_*.rman && ! grep -q REDO1 $T/log/duplicate_*.rman && grep -q \"set log_archive_dest_state_3='defer'\" $T/log/duplicate_*.rman && grep -q \"dg_config=(PRODDB,PRODDB_STBY)\" $T/log/duplicate_*.rman"
check "rman script has no password" "! grep -q Welcome_123 $T/log/duplicate_*.rman $T/log/duplicate_*.log"

fi
if part M; then
CUR=M; echo "== M. Registration and apply problems"
fresh empty; run $T/m0.txt >/dev/null
jset $S "d['srvctl']['instance']='PRODDB'; d['srvctl']['running']=1; d['instances']['PRODDB']={'state':'mounted','srl':4}; d['instances']['PRODDB_STBY']={'state':'idle','srl':4,'datafiles':10}"
rc=$(run $T/m1.txt --from 9.1)
check "wrong -instance detected and re-registered" "grep -q 'Registered, but these values are wrong: instance' $T/m1.txt && python3 -c \"import json;assert json.load(open('$S'))['srvctl']['instance']=='PRODDB_STBY'\""
check "after fix exit 0" "[[ $rc -eq 0 ]]"

fi
if part N; then
CUR=N; echo "== N. Software problems"
fresh empty; jset $S "d['grid_prereq_fail']=1"
rc=$(run $T/n1.txt)
check "grid prereq failure -> IGNORE retry -> installed" "grep -q 'Retry and ignore the failed prerequisite checks' $T/n1.txt && grep -q 'ignorePrereqFailure' $T/state/calls.log && [[ \$(res 3.2 $T/n1.txt) == DONE ]]"
check "grid prereq failure: the failed checks are read from the installer's log and shown before the question" "grep -q 'Failed prerequisite checks:' $T/n1.txt && grep -q 'Swap Size' $T/n1.txt && grep -q 'PRVF-7573' $T/n1.txt && grep -q 'Installer log: /tmp/GridSetupActions' $T/n1.txt && [[ \$(grep -n 'PRVF-7573' $T/n1.txt | head -n 1 | cut -d: -f1) -lt \$(grep -n 'Retry and ignore the failed prerequisite checks' $T/n1.txt | head -n 1 | cut -d: -f1) ]]"
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

fi
if part O; then
CUR=O; echo "== O. Settings"
fresh; rc=$(DG_TEST_QUIT_AT=2.1 run $T/o1.txt)
rc=$(DG_TEST_QUIT_AT=2.1 run $T/o2.txt --primary 127.0.0.2)
check "saved settings reused without asking IP" "! grep -q 'IP address or host name of the primary' $T/o2.txt && grep -q 'Same settings as before' $T/o2.txt"
rc=$(DG_TEST_QUIT_AT=1.2 run $T/o3.txt --primary 127.0.0.7)
check "other primary IP -> saved settings not used, kept as a copy" "grep -q 'The saved settings are for another primary, so they are not used. A copy ends in' $T/o3.txt && ls $T/varlib/settings.conf.127.0.0.2_* >/dev/null 2>&1"
fresh; jset $P "d['extra_pmon']=['OTHERDB']"
rc=$(DG_TEST_DBPICK=1 DG_TEST_QUIT_AT=2.1 run $T/o4.txt)
check "several running databases -> user chooses" "grep -q 'Running databases on the primary' $T/o4.txt && grep -q 'ORACLE_SID=PRODDB ' $T/o4.txt"
fresh; jset $P "d['unique']='verylongname'"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/o5.txt)
check "long db_unique_name -> standby name within 12 chars" "grep -qE 'Standby names +VERYLONGN_SB, SID VERYLONGN_SB' $T/o5.txt"

fi
if part P; then
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
check "recovery area size as on the primary (its db_recovery_file_dest_size, 50G in the mock), not an estimate" "grep -qE \"set db_recovery_file_dest_size='50G'\" $T/log/duplicate_*.rman"
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
fresh empty; printf '%s\n' "127.0.1.1    $(hostname -s)" > /tmp/claude-hosts.$$; cat /etc/hosts >> /tmp/claude-hosts.$$; cp /tmp/claude-hosts.$$ /etc/hosts; rm -f /tmp/claude-hosts.$$
rc=$(DG_TEST_QUIT_AT=2.8 run $T/p12.txt)
# the address the script puts in: the first non-loopback one of this machine (as in setup_env.sh)
SIPRE=$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -E '^[0-9.]+$' | head -n 1); SIPRE=${SIPRE//./\\.}
check "standby host name on loopback -> found and fixed by the script (backup kept)" "grep -q 'resolves to 127.0.1.1 (loopback)' $T/p12.txt && ! grep -qE '^127\.0\.1\.1[[:space:]].*\b'\$(hostname -s)'\b' /etc/hosts && grep -qE '^${SIPRE}[[:space:]]+(.* )?'\$(hostname -s)'( |$)' /etc/hosts && ls /etc/hosts.bak_* >/dev/null 2>&1 && grep -q '|2.6|EDIT|/etc/hosts|' $T/varlib/changes.log"
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

fi
if part Q; then
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

fi
if part R; then
CUR=R; echo "== R. Combinations: storage x version x owner x media x OS (full runs)"
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

# 21c on OL9 needs a Release Update installed with it (step 1.6, tested in Z); this full run uses OL8 with a non-UEK kernel (udev)
combo mixed21 DGT_STORAGE=mixed DGT_VER=21.13.0.0.0 DGT_OS=8 DGT_UNAME=4.18.0-513.5.1.el8_9.x86_64
check "mixed 21c OL8 (RHCK kernel): complete" "full_ok $T/r_mixed21.txt"
check "mixed: udev rules (no ASMLib on this kernel) and /dev/oraasm disks" "[[ \$(grep -c 'oraasm/' /etc/udev/rules.d/99-oracle-asmdevices.rules) -eq 2 ]] && [[ -e /dev/oraasm/DATA_1 && -e /dev/oraasm/FRA_1 ]] && ! grep -q 'oracleasm user=root args=\\['\\''createdisk' $T/state/calls.log"
check "mixed: Grid installed with the udev discovery path" "grep -q 'oracle.install.asm.diskGroup.disks=/dev/oraasm/DATA_1' $T/state/last_grid_rsp_disks.txt"
check "mixed: udev rule limited to block partitions" "grep -q 'ACTION==\"add|change\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"partition\"' /etc/udev/rules.d/99-oracle-asmdevices.rules"
check "mixed: everything goes to +DATA, so the folder of the primary is not made here" "[[ ! -d $T/u02/oradata/PRODDB ]]"
check "mixed: dnf used on OL8" "grep -q '^dnf user=root' $T/state/calls.log"

combo s121 DGT_VER=12.1.0.2.0 DGT_MEDIA=staged DGT_OS=7
check "12.1 staged OL7: complete" "full_ok $T/r_s121.txt"
check "12.1 OL7: patch 18370031 asked for before the Grid root.sh" "grep -q 'needs patch 18370031 before root.sh' $T/r_s121.txt"
check "12.1: yum and the 12cR1 preinstall package" "grep -q \"yum user=root args=\\['install', '-y', 'oracle-rdbms-server-12cR1-preinstall'\" $T/state/calls.log"
check "12.1: both zip files of each product used" "grep -q 'Database: .*linuxamd64_12102_database_1of2.zip .*linuxamd64_12102_database_2of2.zip' $T/r_s121.txt && grep -q 'DB_MEDIA=.*database_1of2.zip,.*database_2of2.zip' $T/r_s121.txt"
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


fi
if part S; then
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
rc=$(DG_TEST_QUIT_AT=2.1 run $T/s3a.txt); sed -i 's/^DATA_DEST=.*/DATA_DEST=same/; s/^FRA_DEST=.*/FRA_DEST=same/' $T/varlib/settings.conf   # (both disk groups needed: the paths of the primary)
rc=$(DG_TEST_DISK_PICKS=1,3,2 run $T/s3.txt)
check "DATA and DATA2: separate labels DATA_1 / DATA2_1, both disk groups created" "python3 -c \"import json;d=json.load(open('$O'))['asm']['disks'];assert 'DATA_1' in d and 'DATA2_1' in d and d['DATA_1']!=d['DATA2_1'],d\" && grep -qi 'create diskgroup data2 external redundancy disk .*DATA2_1' <<< \"\$(python3 -c \"import json;print(json.load(open('$S'))['dg_sql'])\")\" && [[ $rc -eq 0 ]]"
# S4 settings of version 3 are converted
fresh; mkdir -p $T/varlib; printf 'PRIMARY_IP=127.0.0.2\nPRIMARY_SSH_USER=oracle\nSTANDBY_UNIQUE=TAV_DR\nFRA_DG=FRA\nDATA_DISK=/dev/sdb\nGRID_ZIP=/tmp/dgt/stage/LINUX.X64_193000_grid_home.zip\n' > $T/varlib/settings.conf; chmod 600 $T/varlib/settings.conf
rc=$(DG_TEST_QUIT_AT=2.1 run $T/s4.txt)
check "v3 settings converted (backup kept, old keys dropped, names kept)" "grep -q 'came from an older version of the script' $T/s4.txt && ls $T/varlib/settings.conf.v3_* >/dev/null 2>&1 && grep -qE 'Standby names +TAV_DR' $T/s4.txt && grep -q '^GRID_MEDIA=/tmp/dgt/stage/LINUX.X64_193000_grid_home.zip' $T/varlib/settings.conf && ! grep -q 'FRA_DG' $T/varlib/settings.conf"
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
check "edited but not accepted -> the summary shows what changed and asks again" "grep -qE 'AUX_CHANNELS: [0-9]+ -> 8' $T/s5c.txt && grep -q 'Changed since the last run' $T/s5c.txt && grep -q '\[Enter\] Start   \[number\] Change' $T/s5c.txt"
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


fi
if part T; then
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
mkdir -p $T/u02/oradata/PRODDB; head -c 1048576 /dev/zero > $T/u02/oradata/PRODDB/system01.dbf; chown -R oracle $T/u02/oradata     # what the failed copy left
rm -rf $T/sd; rc=$(DG_SHORT_DIR=$T/sd DG_TEST_L72=m DG_TEST_QUIT_AT=8.1 run $T/t3.txt)
check "file-system cleanup of a copy the script did not start: only [m], a script file with ONE host check and the rm lines" "grep -q 'the database is incomplete' $T/t3.txt && ! grep -q '\[y\] Clean up for me' $T/t3.txt && [[ \$(grep -c 'hostname -s' $T/sd/c72) -eq 1 ]] && grep -q 'rm -f $T/u02/oradata/PRODDB/system01.dbf' $T/sd/c72"


fi
if part U; then
CUR=U; echo "== U. Audit round 3"
# U1 the same file system UUID as on primary, test file not seen: copy or the SAME disk -> not proven
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']='/dev/vdb aaaa1111-2222-3333-4444-555566667777'"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u1a.txt)
check "same file system UUID -> not accepted, compare the disks, no advice to change the disk" "grep -q 'same file system UUID (aaaa1111' $T/u1a.txt && ! grep -q 'xfs_admin' $T/u1a.txt && grep -q 'Type SEPARATE to continue' $T/u1a.txt && ! grep -qE '^    2\.15 +(ok|done)' $T/u1a.txt"
touch $T/varlib/storage_clone_confirmed; echo bbbb1111-2222-3333-4444-555566667777 > $T/varlib/storage_clone_ok
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u1b.txt)
check "... a general confirmation file or another UUID does not count" "! grep -qE '^    2\.15 +ok' $T/u1b.txt"
echo aaaa1111-2222-3333-4444-555566667777 >> $T/varlib/storage_clone_ok
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u1c.txt)
check "... accepted after the confirmation for exactly this UUID" "grep -qE '^    2\.15 +ok' $T/u1c.txt && grep -q 'you confirmed it is a separate disk' $T/u1c.txt"
# U1d same UUID on the same disk WWN -> shared (DANGER)
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']='/dev/vdb aaaa1111-2222-3333-4444-555566667777'"
jset $O "d['disks']['/dev/vdb']={'mnt':'/u02','size_mb':102400,'wwn':'0x5000c500aaaa0001'}"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u1d.txt)
check "same UUID on the same disk WWN -> DANGER, shared" "grep -q 'DANGER' $T/u1d.txt && grep -q 'on the same disk 0x5000c500aaaa0001 as on the primary' $T/u1d.txt"
# U1e same UUID, other disk ids -> still not proven (ids that differ do not prove two disks)
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']='/dev/vdb aaaa1111-2222-3333-4444-555566667777'"
jset $O "d['disks']['/dev/vdb']={'mnt':'/u02','size_mb':102400,'wwn':'0x5000c500bbbb0002','serial':'STBYDISK1'}"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u1e.txt)
check "same UUID, other disk ids -> not accepted without confirmation" "! grep -qE '^    2\.15 +ok' $T/u1e.txt && grep -q 'or the same disk mounted on both servers' $T/u1e.txt"
# U2 same UUID and the primary user cannot look into the folder -> not proven
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']='/dev/vdb aaaa1111-2222-3333-4444-555566667777'; d['canlook']='NO'"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u2.txt)
check "same UUID, folder not visible on primary -> not accepted" "grep -q 'same file system UUID (aaaa1111' $T/u2.txt && ! grep -qE '^    2\.15 +ok' $T/u2.txt"
# U3 the primary does not show a UUID for one of its file systems, folder not visible -> not proven
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['fsid']=''; d['canlook']='NO'"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u3.txt)
check "primary list of UUIDs incomplete, folder not visible -> not proven" "grep -q 'It cannot be proven that this is not the storage of the primary' $T/u3.txt && grep -q 'does not show the UUID of every file system' $T/u3.txt && ! grep -qE '^    2\.15 +ok' $T/u3.txt"
# U4 folder not visible, but the primary shows all its file systems and this UUID is not one of them -> not shared
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['canlook']='NO'"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u4.txt)
check "UUID not mounted on primary (complete list) -> accepted" "grep -qE '^    2\.15 +ok' $T/u4.txt && grep -q 'is not mounted on the primary' $T/u4.txt"
# U5 test file not seen, but the list of the primary is incomplete -> not proven; U6 confirmed -> accepted
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['mount_uuids']=['']"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u5.txt)
check "incomplete UUID list on primary -> not accepted even when the test file is not seen" "! grep -qE '^    2\.15 +ok' $T/u5.txt && grep -q 'does not show the UUID of every file system' $T/u5.txt"
echo aaaa1111-2222-3333-4444-555566667777 > $T/varlib/storage_clone_ok
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u6.txt)
check "... accepted after the confirmation for this disk" "grep -qE '^    2\.15 +ok' $T/u6.txt"
# U7 the local file system UUID is a file system the primary mounts at ANOTHER path -> not accepted
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['mount_uuids']=['aaaa1111-2222-3333-4444-555566667777']"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u7.txt)
check "UUID mounted on primary at another path -> not accepted" "grep -q 'same file system UUID (aaaa1111' $T/u7.txt && ! grep -qE '^    2\.15 +ok' $T/u7.txt"
# U8 a local disk WWN is a disk under a file system of the primary (other UUID) -> not accepted
( export DGT_STORAGE=fs; bash $TD/setup_env.sh empty >/dev/null ); jset $P "d['devid']='TYPE=\"disk\" WWN=\"0x5000c500cccc0003\" SERIAL=\"X\"'"
jset $O "d['disks']['/dev/vdb']={'mnt':'/u02','size_mb':102400,'wwn':'0x5000c500cccc0003'}"
rc=$(DG_TEST_QUIT_AT=3.2 run $T/u8.txt)
check "local disk WWN is under a file system of the primary -> not accepted" "! grep -qE '^    2\.15 +ok' $T/u8.txt && grep -q 'is also under a file system of the primary' $T/u8.txt"

fi
if part V; then
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
check "--from 7.3 on a stopped standby -> 7.3 waiting (not ok: tested after 9.2)" "grep -qE '^    7\.3 +waiting' $T/v2.txt && ! grep -q 'The instance is not started (step 7.2)' $T/v2.txt"
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

fi
if part W; then
CUR=W; echo "== W. Field report 1 (check mode on a real server)"
# W1 software installed here, no instance yet: check mode shows no PROBLEM for 1.4 / 4.2 / 7.6
fresh; jset $S "d['instances']={}"
rc=$(run $T/w1.txt --check)
check "check mode, software installed, no instance: 4.2 query works, 7.4/7.6 wait for 7.2" "! grep -q 'ORA-00937' $T/w1.txt && ! grep -qE '^ +(1\.4|4\.2|7\.6) +problem' $T/w1.txt && grep -qE '^    7\.6 +waiting' $T/w1.txt && grep -qE '^    7\.4 +waiting' $T/w1.txt"
# W2 Grid home inside the Grid base on primary (works there): kept, only noted
fresh; jset $P "d['grid_base']='$T/u01/app'"
rc=$(run $T/w2.txt --check)
check "Grid home inside Grid base as on primary -> 1.4 not a problem, noted" "! grep -qE '^    1\.4 +problem' $T/w2.txt && grep -q 'is inside the Grid base' $T/w2.txt"
# W3 a failed login shows the real error (printed before the marker), not only SP2-0640
fresh; jset $S "d['instances']={'PRODDB_STBY':{'state':'started'}}"; jset $P "d['tns_stby']=0"
rc=$(DG_TEST_NOFIX=4.9 DG_TEST_QUIT_AT=7.7 run $T/w3.txt --from 7.6)
check "login from primary fails -> ORA-12154 and its explanation, not only SP2-0640" "grep -q 'sys@proddb_stby failed (ORA-12154' $T/w3.txt && grep -q 'The alias is missing in tnsnames.ora' $T/w3.txt"

fi
if part X; then
CUR=X; echo "== X. Pass 1 of the final review (flow, questions, rollback, Oracle, OS)"
# X1 a full run: no [y] question for 1.2/1.3/1.5, the progress board, the end hints, the journal
fresh empty
rc=$(run $T/x1.txt)
check "no [y] question before the settings (1.2, 1.3 only read)" "! sed -n '/Step 1.2  /,/Step 1.4  /p' $T/x1.txt | grep -q '\[y\] Yes, do it'"
check "progress board at the start, with the legend" "grep -q '  Progress' $T/x1.txt && grep -q 'Nothing is set up yet' $T/x1.txt"
check "phase 4 offered first after phase 1" "grep -q 'Do phase 4 (primary) first' $T/x1.txt"
check "one box with every primary command of phase 4 (batch)" "grep -q 'steps need commands on the primary. They are shown together below, in order.' $T/x1.txt && grep -q -- '-- Step 4.2: Standby redo logs' $T/x1.txt && grep -qE -- '-- Undo, if ever needed: .*alter database drop standby logfile' $T/x1.txt"
check "run-mode summary has a legend and the changes of this run" "grep -qE '[0-9]+ already ok, [0-9]+ done in this run' $T/x1.txt && grep -q 'ok = was already correct' $T/x1.txt && grep -q 'Changes on this server in this run' $T/x1.txt"
check "end hints: archivelog deletion, password file, reboot" "grep -qi 'archivelog deletion policy' $T/x1.txt && grep -q 'Plan one reboot' $T/x1.txt"
check "journal records the primary commands with their undo" "grep -q '|PRIMARY|4.4|' $T/varlib/changes.log && grep -q 'alter system reset log_archive_dest_2' $T/varlib/changes.log"
check "progress and last_run files written" "grep -q '^9.7|DONE|' $T/varlib/progress && grep -q 'every step OK' $T/varlib/last_run"
check "RMAN plan is short: where the files go instead of one line per datafile; size and time estimate" "grep -q 'Database files go to: +DATA (ASM)' $T/x1.txt && grep -q 'Rough time:' $T/x1.txt && ! grep -q 'set newname for datafile' $T/x1.txt"
check "duplicate: audit folder of the standby, convert pair against ORA-19527 noise" "grep -q \"audit_file_dest='$T/u01/app/oracle/admin/PRODDB_STBY/adump'\" $T/log/duplicate_*.rman && grep -q '__dg_no_rename__' $T/log/duplicate_*.rman"
# X2 --status and --show-changes without a connection; a second run shows the board as DONE
rc=$(run $T/x2.txt --status)
check "--status: every phase DONE, no connection, no password asked" "grep -qE '^ +1  Connect to the primary +done' $T/x2.txt && grep -qE '^ +10  Health check +done' $T/x2.txt && ! grep -qE \"'s password:|^ +[?] \" $T/x2.txt && [[ $rc -eq 0 ]]"
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
check "leftovers of an earlier copy (+DATA/PRODDB_STBY) named with the clean-up commands" "grep -q 'files already exist where the standby database will be written' $T/x12.txt && grep -q 'asmcmd rm -rf +DATA/PRODDB_STBY' $T/x12.txt && grep -q 'Never touched: +DATA/PRODDB' $T/x12.txt && ! grep -q '\[y\] Clean up for me' $T/x12.txt"
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
rc=$(DG_TEST_TDEPW=Wrong_pw9 DG_TEST_QUIT_AT=8.2 run $T/x15.txt --from 6.1)
check "TDE without cwallet.sso, wrong keystore password -> orapki fails, the command is shown; 8.1 blocked" "grep -q 'orapki did not make' $T/x15.txt && grep -q 'orapki wallet create -wallet .* -auto_login' $T/x15.txt && grep -q 'no auto-login file (cwallet.sso)' $T/x15.txt && ! grep -q '^rman ' $T/state/calls.log && ! grep -q 'Wrong_pw9' $T/x15.txt $T/log/run_*.log"
fresh; jset $P "d['tde']=['FILE|$T/pwallet/|OPEN']; d['files']={'$T/pwallet/ewallet.p12':'EWALLET\\n'}"
rc=$(DG_TEST_QUIT_AT=7.1 run $T/x15b.txt --from 6.1)
check "TDE without cwallet.sso -> made here with orapki after one password question, 6.3 done, password not logged" "grep -q 'MOCK-ORAPKI -auto_login' $T/pwallet/cwallet.sso && grep -qE '^    6\.3 +done' $T/x15b.txt && ! grep -q 'Wallet_pw1' $T/x15b.txt $T/log/run_*.log"
# X16 Standard Edition primary -> stop at 1.3, nothing installed
fresh empty; jset $P "d['banner']='Oracle Database 19c Standard Edition 2 Release 19.0.0.0.0 - Production'"
rc=$(run $T/x16.txt)
check "Standard Edition -> stop at discovery, before any install" "[[ $rc -ne 0 ]] && grep -q 'Standard Edition' $T/x16.txt && ! grep -q 'gridSetup.sh user=' $T/state/calls.log && ! id oracle >/dev/null 2>&1"
# X17 patched primary + base media: told at 3.1, before installing
fresh empty
rc=$(DG_TEST_QUIT_AT=3.2 run $T/x17.txt)
check "3.1 says the primary has patches and how to avoid patching by hand" "grep -q 'The primary has patches' $T/x17.txt && grep -q 'set the value .Release Update.' $T/x17.txt && grep -q 'RU_DIR and OPATCH_ZIP' $T/x17.txt"
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


fi
if part Y; then
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
# (the installer runs 90 s: it starts in the middle of y3a, and --status and --check must still see it
# running afterwards, also on a fast machine; y3b waits until it has ended)
fresh empty; jset $T/state/env.json "d['installer_sleep']=90"
rc=$(DG_TEST_HUP_ON_JOB='Grid installer' run $T/y3a.txt)
rc=$(run $T/y3s.txt --status)
check "--status during the installer: 'Running now' with the job" "grep -q 'Running now: Grid installer' $T/y3s.txt"
rc=$(run $T/y3c.txt --check)
check "--check during the installer: phase 3 and later WAITS, no clean-up plan" "grep -qE '^    3\.2 +waiting' $T/y3c.txt && grep -qE 'is still running \(session|has ended but is not recorded yet' $T/y3c.txt && ! grep -q 'deinstall' $T/y3c.txt"
for _ in $(seq 150); do pgrep -u grid >/dev/null || break; sleep 1; done   # the installer runs as grid
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
rc=$(DG_TEST_QUIT_AT=7.1 run $T/y10.txt --from 6.1)
check "LOCAL auto-login wallet: not copied, made here with orapki -auto_login_local" "grep -q 'MOCK-ORAPKI -auto_login_local' $T/pwallet/cwallet.sso && [[ -f $T/pwallet/ewallet.p12 ]]"
# Y11 typed word: an Enter by mistake asks again
fresh; rc=$(DG_TEST_DUP= DG_TEST_QUIT_AT=9.1 run $T/y11.txt)
check "Enter at DUPLICATE asks again (does not skip the copy)" "grep -q 'Nothing was typed. Type DUPLICATE' $T/y11.txt"

fi
#==============================================================================
if part Z1; then
CUR=Z; echo "== Z. External review fixes (5.1 - 5.10)"
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

fi
if part Z3; then  CUR=Z
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

fi
if part Z4; then  CUR=Z
# ---- 5.4: the database installer waits for the inventory (field report: INS-32035 / INS-32039) ----
fresh; rm -f /etc/oraInst.loc $T/varlib/db_install.done
sed -i '\#dbhome_1#d' $T/u01/app/oraInventory/ContentsXML/inventory.xml
rc=$(DG_TEST_NOFIX=3.6 DG_TEST_QUIT_AT=3.7 run $T/z9.txt --from 3.6)
check "no /etc/oraInst.loc with Grid -> 3.6 waits for the Grid root scripts, installer not started" "grep -q '/etc/oraInst.loc is missing' $T/z9.txt && ! grep -q 'runInstaller user=' $T/state/calls.log"

fi
if part Z5; then  CUR=Z
# ---- 5.5: a sys password with @ / $ is accepted (it travels in double quotes, through stdin) ----
fresh; jset $T/state/env.json "d['pw']='Pass@word/1\$x'"
rc=$(DG_TEST_PW='Pass@word/1$x' DG_TEST_QUIT_AT=2.1 run $T/z10.txt)
check "sys password with @ / \$ accepted and working" "grep -q 'The sys password works on the primary' $T/z10.txt && ! grep -q 'Pass@word' $T/log/run_*.log"

fi
if part Z6; then  CUR=Z
# ---- 5.6: memory of the standby against SGA + PGA of the primary (step 2.16, and again before the copy) ----
fresh
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z11.txt)
check "2.16: enough RAM -> ok, SGA and PGA shown" "grep -q 'Enough RAM' $T/z11.txt && grep -q 'SGA 1024 MB + PGA 512 MB' $T/z11.txt && grep -qE '^    2\.16 +ok' $T/z11.txt"
fresh; jset $P "d['mem']={'sga_target':str(5*1024**3),'sga_max_size':str(5*1024**3),'memory_target':'0','memory_max_target':'0','pga_aggregate_target':str(3*1024**3),'use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z12.txt)
check "2.16: SGA fits, SGA + PGA over 90% -> ok with a warning (PGA is only a target)" "grep -q 'Warning: SGA + PGA is more than 90%' $T/z12.txt && grep -qE '^    2\.16 +ok' $T/z12.txt"
fresh; jset $P "d['mem']={'sga_target':str(7*1024**3),'sga_max_size':str(7*1024**3),'memory_target':'0','memory_max_target':'0','pga_aggregate_target':str(1024**3),'use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
rc=$(run $T/z13.txt)
check "SGA over 80% of RAM: 2.16 refuses, the minimum shown; skipped -> the copy is still refused" "grep -q 'Not enough RAM. This server needs at least' $T/z13.txt && grep -q 'Step 2.16 shows what to do' $T/z13.txt && ! grep -qE '^    2\.16 +ok' $T/z13.txt && ! grep -q '^rman' $T/state/calls.log"
fresh; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':'0','memory_max_target':'0','pga_aggregate_target':str(256*1024**2),'use_large_pages':'ONLY','db_recovery_file_dest_size':'0'}"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z14.txt)
check "2.16: use_large_pages=ONLY without HugePages -> ok, with the HugePages note" "grep -q 'HugePages: the primary requires them' $T/z14.txt && grep -qE '^    2\.16 +ok' $T/z14.txt"

fresh; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':'0','memory_max_target':str(7680*1024**2),'pga_aggregate_target':str(256*1024**2),'use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z15.txt)
check "2.16: memory_max_target bigger than /dev/shm -> made bigger by the script (remount + fstab, other options kept)" "grep -q '/dev/shm is too small' $T/z15.txt && grep -q 'mount -o remount,size=9728m /dev/shm' $T/z15.txt && grep -qE '^    2\.16 +done' $T/z15.txt && grep -qE '^tmpfs +/dev/shm +tmpfs +defaults,nodev,size=9728m' $T/fstab && grep -q '^/dev/mapper/ol-root' $T/fstab && ls $T/fstab.bak_* >/dev/null 2>&1"

fi
if part Z7; then  CUR=Z
# 5.7: the host key of the primary is shown and must be confirmed before the password is typed
fresh
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z16.txt)
check "new primary: host key fingerprint shown with the command to compare, saved after y, ssh strict" "grep -q 'This server does not know the primary yet' $T/z16.txt && grep -q 'SHA256:' $T/z16.txt && grep -q 'MD5:' $T/z16.txt && grep -q 'for f in /etc/ssh/ssh_host_\*_key.pub; do ssh-keygen -lf' $T/z16.txt && [[ \$(stat -c %a $T/varlib/primary_known_hosts) == 600 ]] && grep -q '^\[master opened' $T/state/primary_cmds.log && [[ ! -s $T/state/primary_UNEXPECTED.log ]] && ! grep -q 'answer yes' $T/z16.txt"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z16b.txt)
check "known primary: no host key question the next time" "! grep -q 'does not know the primary' $T/z16b.txt && grep -q 'Connected to' $T/z16b.txt"
fresh; mkdir -p $T/varlib; printf '127.0.0.2 ssh-dss AAAAB3NzaC1kc3MOldKey\n' > $T/varlib/primary_known_hosts; chmod 600 $T/varlib/primary_known_hosts
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z16c.txt)
check "only an old ssh-dss key saved -> not counted as known, the new key is shown" "grep -q 'does not know the primary' $T/z16c.txt && grep -q 'Connected to' $T/z16c.txt"
fresh
rc=$(DG_TEST_HOSTKEY=n DG_TEST_QUIT_AT=2.1 run $T/z17.txt)
check "host key not confirmed -> no password, no connection, nothing saved" "grep -q 'Host key not accepted' $T/z17.txt && ! grep -q '^\[master opened' $T/state/primary_cmds.log && ! grep -q \"'s password:\" $T/z17.txt && [[ ! -e $T/varlib/primary_known_hosts ]]"
fresh; jset $P "d['keyscan_fail']=1"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z18.txt)
check "host key cannot be read -> stop with a clear message" "grep -q 'Cannot read the ssh host key of 127.0.0.2' $T/z18.txt && ! grep -q '^\[master opened' $T/state/primary_cmds.log"
fresh
rc=$(DG_TEST_QUIT_AT=1.3 run $T/z19a.txt); jset $P "d['hostkey']='AAAAC3NzaC1lZDI1NTE5AAAAIOtherMachineKey9999'"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z19.txt)
check "host key changed -> refused, warned not to remove it unless the primary was reinstalled" "grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' $T/z19.txt && grep -q 'Remove the saved key ONLY if' $T/z19.txt && grep -q \"ssh-keygen -R 127.0.0.2 -f $T/varlib/primary_known_hosts\" $T/z19.txt && ! grep -q 'does not know the primary' $T/z19.txt"

# 5.7: --check keeps the progress and last-run files of the real runs
fresh
rc=$(DG_TEST_QUIT_AT=2.2 run $T/z20a.txt); m1=$(md5sum < $T/varlib/progress); m2=$(md5sum < $T/varlib/last_run)
rc=$(run $T/z20.txt --check)
check "--check does not change the progress or last-run files" "[[ \"$m1\" == \"\$(md5sum < $T/varlib/progress)\" && \"$m2\" == \"\$(md5sum < $T/varlib/last_run)\" ]] && grep -q 'Check mode changes nothing in Oracle, the OS or the primary' $T/z20.txt"

# 5.7: small fixes
check "run id has the process id: two runs in one second never share a log" "ls $T/log/ | grep -qE '^run_[0-9]{8}_[0-9]{6}_[0-9]+\.log$'"
fresh; printf 'X=$(touch %s/osrel_canary)\n' "$T" >> $T/os-release
rc=$(DG_TEST_QUIT_AT=1.3 run $T/z21.txt)
check "os-release is read, never run as code" "[[ ! -e $T/osrel_canary ]] && grep -q 'Oracle Linux Server 8.9' $T/z21.txt"
fresh; jset $P "d['version']='26.1.0.0.0'"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z22.txt)
check "Oracle major newer than 23 -> refused, not guessed" "grep -q 'tested for 12.1 to 23ai only' $T/z22.txt && [[ $rc -ne 0 ]]"
DGT_OS=10 fresh
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z23.txt)
check "Oracle Linux 10 -> not tested, shown as not supported" "grep -q 'Oracle Linux 10 was not tested with this script' $T/z23.txt"
ut_guard() { bash <<EOF
source <(sed -n '/^readonly_guard()/,/^}/p' $T/dg_standby_setup.sh)
readonly_guard 'select "SYS"."DBMS_LOCK".sleep(1) from dual;' && echo BAD1
readonly_guard 'select sys . dbms_x.f from dual;' && echo BAD2
readonly_guard 'select 1 from dual;' || echo BAD3
echo END
EOF
}
check "read-only guard: quoted or spaced package names are blocked" "[[ \$(ut_guard) == END ]]"
ut_pparam() { bash <<EOF
fatal() { echo FATAL; exit 3; }; prim_sql() { echo SENT; }; first_line() { :; }
source <(sed -n '/^p_param()/,/^}/p' $T/dg_standby_setup.sh)
p_param "x' or name='y"
EOF
}
check "p_param refuses a name that is not a plain parameter name (nothing sent)" "[[ \$(ut_pparam) == FATAL ]]"

fi
if part Z8; then  CUR=Z
# 5.8: checks that passed when they should not
fresh; printf 'grid  soft  nofile  4096\ngrid  hard  nofile  70000\n' > /etc/security/limits.d/oracle-grid.conf
rc=$(DG_TEST_QUIT_AT=2.5 run $T/z26.txt)
check "2.4: only nofile set -> the other three limits are added, the admin's nofile stays" "grep -q 'Missing or too low limits: .*grid:nproc' $T/z26.txt && ! grep -q 'grid:nofile' $T/z26.txt && grep -qE '^grid +hard +nproc' /etc/security/limits.d/oracle-grid.conf && [[ \$(grep -cE '^grid +hard +nofile' /etc/security/limits.d/oracle-grid.conf) -eq 1 ]] && grep -qE '^grid +hard +nofile +70000' /etc/security/limits.d/oracle-grid.conf"
fresh; jset $O "d['services']['firewalld']=True; d['fw']={'runtime':['1521/tcp'],'permanent':[]}"
rc=$(DG_TEST_QUIT_AT=2.10 run $T/z27.txt)
check "2.9: port open only until the next reboot -> saved with --permanent" "grep -q 'not saved: it closes at the next reboot' $T/z27.txt && python3 -c \"import json;f=json.load(open('$O'))['fw'];assert '1521/tcp' in f['permanent'] and '1521/tcp' in f['runtime'],f\""
fresh; jset $O "d['chrony_unsync']=True"
rc=$(DG_TEST_QUIT_AT=2.11 run $T/z28.txt)
check "2.10: chronyd runs but the clock is not in sync -> ok with a warning" "grep -q 'the clock is not in sync' $T/z28.txt && grep -q 'chronyc sources -v' $T/z28.txt && grep -qE '^    2\.10 +ok' $T/z28.txt"
fresh empty; mkdir -p $T/u01/app/19.0.0/grid; chown root:root $T/u01/app/19.0.0/grid
rc=$(DG_TEST_QUIT_AT=2.6 run $T/z29.txt)
check "2.5: an EMPTY Grid home owned by root -> given to grid (the installer must write there)" "[[ \$(stat -c %U $T/u01/app/19.0.0/grid) == grid ]]"
ut_copy_mb() { bash <<EOF
num() { [[ -n "\${1:-}" && "\${1:-}" != *[!0-9]* ]]; }
source <(sed -n '/^earlier_copy_mb()/,/^}/p' $T/dg_standby_setup.sh)
d=\$(mktemp -d); FS_FILENAMES="\$d/system01.dbf"; STANDBY_UNIQUE=X; mkdir -p \$d/X/datafile \$d/OTHERDB/archivelog
head -c 3145728 /dev/zero > \$d/system01.dbf; head -c 5242880 /dev/zero > \$d/unrelated.bin; head -c 2097152 /dev/zero > \$d/X/datafile/o1_mf_x.dbf
head -c 4194304 /dev/zero > \$d/OTHERDB/archivelog/o1_mf_1_9.arc
earlier_copy_mb "\$d"; rm -rf "\$d"
EOF
}
check "2.14: only files of an earlier copy count as already used (not other files, not another database's OMF files)" "[[ \$(ut_copy_mb) == 5 ]]"
fresh; jset $P "d['params']['log_archive_dest']='/arch'; d['params'].pop('log_archive_dest_1', None); d['params']['log_archive_duplex_dest']='/arch2'"
rc=$(DG_TEST_NOFIX=4.4 DG_TEST_QUIT_AT=4.5 run $T/z30.txt)
check "4.4: old-style log_archive_dest with a duplex folder -> the duplex goes to a free dest (3), the standby to 2" "grep -q \"log_archive_dest_3='location=/arch2'\" $T/z30.txt && grep -q \"log_archive_dest_2='service=proddb_stby\" $T/z30.txt"
fresh; jset $P "d['params']['fal_server']='OTHERSB'"
rc=$(DG_TEST_QUIT_AT=4.9 run $T/z31.txt)
check "4.8: an existing fal_server is kept, the standby is added, the undo restores it" "grep -q \"alter system set fal_server='OTHERSB','proddb_stby' scope=both;\" $T/z31.txt && grep -q \"alter system set fal_server='OTHERSB' scope=both;\" $T/z31.txt"
fresh; jset $P "d['pw_tmp']=1; d['pw_tmp_mode']='644'"
rc=$(DG_TEST_QUIT_AT=6.2 run $T/z32.txt)
check "6.1: a temporary password file copy that others can read is not used" "grep -q 'mode 640 or stricter' $T/z32.txt"
ut_wallet() { bash <<EOF
norm() { printf '%s' "\$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'; }
sq=\$(mktemp); sqlnet_file() { echo \$sq; }
source <(sed -n '/^sqlnet_has_wallet()/,/^}/p' $T/dg_standby_setup.sh)
printf 'ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = /u01/wallet/tde/)))\n' > \$sq
sqlnet_has_wallet /u01/wallet/tde && echo A; sqlnet_has_wallet /u01/wallet && echo BAD; rm -f \$sq
EOF
}
check "6.3: a wallet folder written with a final / is the same folder" "[[ \$(ut_wallet) == A ]]"
fresh; rc=$(DG_TEST_QUIT_AT=2.1 run $T/z33s.txt); sed -i 's/^DATA_DEST=.*/DATA_DEST=same/; s/^FRA_DEST=.*/FRA_DEST=same/' $T/varlib/settings.conf     # the logs keep the primary's disk groups
jset $S "d['sector_sizes']={'FRA':4096}; d['instances']['PRODDB_STBY']={'state':'idle'}"; jset $P "d['log_dgs']=['DATA','FRA']"     # no standby yet: the copy is planned
rm -f $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/.dg_duplicate_done_PRODDB_STBY $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(run $T/z33.txt)
check "8.1: DATA_DEST=same, a log disk group (+FRA) with 4K sectors for 512-byte redo -> copy refused" "grep -q '+FRA has a sector size of 4096 bytes' $T/z33.txt && ! grep -q '^rman.*duplicate' $T/state/calls.log && ! grep -qE '^ +Fix +[+]FRA has' $T/z33.txt"
fresh; jset $S "d['sector_sizes']={'FRA':4096}; d['instances']['PRODDB_STBY']={'state':'idle'}"; jset $P "d['log_dgs']=['DATA','FRA']"     # no standby yet: the copy is planned
rc=$(DG_TEST_QUIT_AT=8.2 run $T/z33b.txt)
check "8.1: everything into +DATA (the default) -> +FRA holds no logs, its 4K sectors do not block the copy" "! grep -q '+FRA has a sector size' $T/z33b.txt && grep -q '+DATA: sector size 512 bytes fits' $T/log/*.log"
ut_boot() { bash <<'EOF'
source <(sed -n '/^script_text()/,/^}/p' /tmp/dgt/dg_standby_setup.sh)
use_grid() { false; }
d=$(mktemp -d); mkdir -p $d/bin
printf '#!/bin/bash\nexit 0\n' > $d/bin/lsnrctl
printf '#!/bin/bash\nq=$(cat); case "$q" in *v\\$instance*) echo "${DGT_ST:-MOUNTED}" ;; *database_role*) echo "${DGT_ROLE:-PHYSICAL STANDBY}" ;; *recover*) echo "ORA-01034: ORACLE not available" ;; esac\n' > $d/bin/sqlplus
chmod 755 $d/bin/*
STANDBY_UNIQUE=X DB_HOME=$d ORACLE_BASE=/b STANDBY_SID=S SB_LSNR=L script_text > $d/s.sh
out=$(bash $d/s.sh start); rc=$?
rm -rf $d; echo "rc=$rc $out"
EOF
}
check "9.7: boot script reports a failed apply (journal) and stays active, so the shutdown still stops the standby" "[[ \$(ut_boot) == 'rc=0 <3>DG-BOOT-ERROR: redo apply did not start: ORA-01034: ORACLE not available' ]]"
check "9.7: boot script with a database that is not a physical standby -> no apply started, unit stays active" "[[ \$(DGT_ROLE=PRIMARY ut_boot) == 'rc=0 <3>DG-BOOT-ERROR: the database role is PRIMARY, not PHYSICAL STANDBY: redo apply is not started' ]]"
check "9.7: boot script with an OPEN standby -> apply is not started (Active Data Guard), error in the journal" "[[ \$(DGT_ST='OPEN' ut_boot) == 'rc=0 <3>DG-BOOT-ERROR: the standby is open (OPEN), not mounted: redo apply is not started (Active Data Guard needs its own license)' ]]"
fresh empty; run $T/z34a.txt >/dev/null; jset $S "d['srvctl']['startopt']='open'"
rc=$(DG_TEST_SKIP=9.1 DG_TEST_QUIT_AT=9.2 run $T/z34.txt --from 9.1)
check "9.1: registration with start option open -> only the start option is changed (the standby is not stopped)" "grep -q 'these values are wrong: start-option' $T/z34.txt && grep -q 'srvctl modify database' $T/z34.txt && grep -qE 'srvctl modify database -db [A-Z_]+ .*-startoption MOUNT' $T/z34.txt && ! grep -q 'srvctl stop database' $T/z34.txt"
rc=$(DG_TEST_QUIT_AT=9.2 run $T/z34b.txt --from 9.1)
check "... and with [y] the start option becomes mount" "python3 -c \"import json;assert json.load(open('$S'))['srvctl'].get('startopt')=='mount'\" && grep -q 'Done. Registered in Oracle Restart' $T/z34b.txt"
ut_timer() { bash <<'EOF'
source <(sed -n '/^arch_timer_state()/,/^}/p' /tmp/dgt/dg_standby_setup.sh)
arch_timer() { echo t.timer; }; arch_service() { echo s.service; }
d=$(mktemp -d); arch_timer_text() { echo T; }; arch_service_text() { echo S; }; arch_script_text() { echo C; }; arch_script() { echo $d/c; }
echo T > /etc/systemd/system/t.timer; echo S > /etc/systemd/system/s.service; echo C > $d/c
systemctl() { case "$1 $3" in "is-enabled t.timer") return 0 ;; "is-active t.timer") return $ACT ;; "is-failed s.service") return $FAIL ;; esac; return 1; }
ACT=0 FAIL=1; a=$(arch_timer_state); ACT=3 FAIL=1; b=$(arch_timer_state); ACT=0 FAIL=0; c=$(arch_timer_state)
rm -rf $d /etc/systemd/system/t.timer /etc/systemd/system/s.service; echo "$a $b $c"
EOF
}
check "9.8: the clean-up timer must be running, and its last run must not have failed" "[[ \$(ut_timer) == 'ok off failed' ]]"
fresh; rc=$(DG_TEST_QUIT_AT=1.3 run $T/z35.txt --from 10.0)
check "--from 10.0 is the same as --from 10" "! grep -q 'There is no step 10.0' $T/z35.txt"

fi
if part Z9; then  CUR=Z
# 5.9
fresh; jset $P "d['mem']={'sga_target':'0','sga_max_size':'0','memory_target':'0','memory_max_target':'0','pga_aggregate_target':str(256*1024**2),'use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}; d['sgainfo']=7*1024**3"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z36.txt)
check "2.16: manual SGA (both targets 0) -> the real size from v\$sgainfo is checked: not enough RAM" "grep -q 'Not enough RAM' $T/z36.txt && ! grep -qE '^    2\.16 +ok' $T/z36.txt"
fresh; jset $T/state/env.json "d['rman_error_after_finish']=1"
rc=$(run $T/z37.txt)
check "8.2: RMAN printed Finished but ended with an error stack and exit code 1 -> the copy is NOT recorded as done" "grep -q 'The copy did not finish' $T/z37.txt && ! grep -q 'The database was copied' $T/z37.txt"
fresh; jset $P "d['tns_stby']=1; d['stby_fw_drop']=1"
rc=$(DG_TEST_QUIT_AT=4.10 run $T/z38.txt)
check "4.9: a timeout (firewall drop) is not 'no listener yet' -> warned" "grep -q 'no answer at all' $T/z38.txt && grep -q 'A firewall probably drops the connection' $T/z38.txt"
fresh; jset $P "d['blocksize']='x'"
rc=$(run $T/z39.txt)
check "8.1: redo block size of the primary unreadable -> copy refused (not assumed 512)" "grep -q 'redo block size of the primary could not be read' $T/z39.txt && ! grep -q 'The database was copied' $T/z39.txt"
ut_settings() { bash <<EOF
num() { [[ -n "\${1:-}" && "\${1:-}" != *[!0-9]* ]]; }
source <(sed -n '/^load_settings()/,/^}/p' $T/dg_standby_setup.sh)
SETTINGS_FILE=\$(mktemp); settings_file_safe() { return 0; }; SETTING_SPECS="PORT:num"; OLD_KEYS=" "; DERIVED_KEYS=" "
valid_value() { return 0; }; is_standby_key() { return 0; }; assumed_key() { return 1; }; fatal() { echo "FATAL \$*"; exit 3; }
printf 'PORT=1521\nPORT=1522\n' > \$SETTINGS_FILE; load_settings soft; echo "[\$LOAD_ERR]"; rm -f \$SETTINGS_FILE
EOF
}
check "settings: a key set twice is an error, not a silent last-wins" "[[ \$(ut_settings) == '[PORT is set twice. Keep one line.]' ]]"
ut_alias() { bash <<EOF
tf=\$(mktemp); tns_file() { echo \$tf; }
source <(sed -n '/^tns_alias_present()/,/^}/p' $T/dg_standby_setup.sh)
printf 'myXdb = (DESCRIPTION=)\n' > \$tf; tns_alias_present my.db && echo BAD; printf 'my.db = (DESCRIPTION=)\n' > \$tf; tns_alias_present my.db && echo OK; rm -f \$tf
EOF
}
check "tns alias with a dot is matched as text (my.db does not match myXdb)" "[[ \$(ut_alias) == OK ]]"
ut_sidlist() { bash <<EOF
source <(sed -n '/^sidlist_of()/,/^}/p' $T/dg_standby_setup.sh)
SB_LSNR=LISTENER; sidlist_of 'SID_LIST_LISTENER_OTHER=(SID_LIST=(SID_DESC=(SID_NAME=A)))SID_LIST_LISTENER=(SID_LIST=(SID_DESC=(SID_NAME=B)))'
EOF
}
check "5.1: only the SID_LIST of this listener counts" "[[ \$(ut_sidlist) == '(SID_LIST=(SID_DESC=(SID_NAME=B)))' ]]"
fresh empty; run $T/z40a.txt >/dev/null; jset $S "d['srvctl']['pwfile']='/tmp/old_orapw'"
rc=$(DG_TEST_SKIP=9.1 DG_TEST_QUIT_AT=9.2 run $T/z40.txt --from 9.1)
check "9.1: a registration with another password file is found and changed in place (no stop)" "grep -q 'these values are wrong: password-file' $T/z40.txt && grep -q 'srvctl modify database' $T/z40.txt && grep -qE 'srvctl modify database -db [A-Z_]+ .*-pwfile ' $T/z40.txt && ! grep -q 'srvctl remove database' $T/z40.txt"

# 5.9: files of an earlier, failed Grid installer run in the inventory folder (no /etc/oraInst.loc): INS-32035 before
fresh empty; rc=$(DG_TEST_QUIT_AT=3.2 run $T/z41a.txt)
mkdir -p $T/u01/app/oraInventory/logs; echo old > $T/u01/app/oraInventory/logs/GridSetupActions.log; chown -R grid:oinstall $T/u01/app/oraInventory; rm -f /etc/oraInst.loc
rc=$(DG_TEST_QUIT_AT=3.3 run $T/z41.txt)
check "3.2: leftover inventory of a failed Grid run -> moved aside (nothing deleted), Grid installs, no INS-32035" "grep -q 'no Oracle home is registered in it' $T/z41.txt && ls -d $T/u01/app/oraInventory.old_* >/dev/null 2>&1 && [[ -f \$(ls -d $T/u01/app/oraInventory.old_* | head -n 1)/logs/GridSetupActions.log ]] && ! grep -qF '[INS-32035]' $T/z41.txt && grep -q 'Successfully Setup Software' $T/log/Grid_installer_*.log"

fi
if part Z10; then  CUR=Z
# 5.10: fewer questions
fresh
rc=$(DG_TEST_QUIT_AT=4.1 run $T/z42.txt --yes)
check "--yes: actions on this server run without the [y] question (phase 2 and 3), shown as 'Yes (yes to all)'" "grep -q 'Yes (yes to all)' $T/z42.txt && ! grep -E '^  Step 2\.' -A30 $T/z42.txt | grep -q '\[y\] Yes, do it' && grep -q 'without asking' $T/z42.txt"
fresh
rc=$(DG_TEST_BATCH=q run $T/z43.txt)
check "phase 4: the file changes on the primary (4.9 4.10 4.11) are in the same batch, as shell commands" "grep -q 'Then, in a shell on the PRIMARY' $T/z43.txt && grep -q '# Step 4.9' $T/z43.txt"
fresh empty; run $T/z44a.txt >/dev/null; jset $S "d['instances']['PRODDB_STBY']['state']='idle'; d['srvctl']['running']=0"
rc=$(DG_TEST_QUIT_AT=9.3 run $T/z44.txt --from 7.3)
check "a built standby that is down: logins 'not tested now' in phase 7, then tested after 9.2 starts it" "grep -q 'Not tested now' $T/z44.txt && grep -q 'The logins of steps 7.3, 7.4 and 7.6 work now' $T/z44.txt"
fresh; jset $O "d['shm_mb']=2048"; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':str(3*1024**3),'memory_max_target':str(3*1024**3),'pga_aggregate_target':'0','use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z45.txt)
check "2.16: AMM primary, /dev/shm too small here -> the script makes it bigger (remount, fstab), then ok" "grep -qE '^    2\.16 +done' $T/z45.txt && python3 -c \"import json;assert json.load(open('$O'))['shm_mb']==5120\" && grep -q 'size=5120m' $T/fstab"
ut_restore() { bash <<EOF
source <(sed -n '/^_cfgv()/p;/^SRV_OLD_ARGS=()/,/^srv_cfg_norm/p' $T/dg_standby_setup.sh)
f=\$(mktemp); DB_HOME=/u01/db; STANDBY_UNIQUE=X_STBY
printf 'Database unique name: X_STBY\nDatabase name: x\nOracle home: /u01/db\nSpfile: /u01/db/dbs/spfileX.ora\nPassword file: \nStart options: read only\nDatabase role: PHYSICAL_STANDBY\nDatabase instance: X\nDisk Groups: DATA, FRA\n' > \$f
srv_add_cmd_from \$f; echo; srv_old_args \$f && printf '<%s>' "\${SRV_OLD_ARGS[@]}"; rm -f \$f
EOF
}
check "9.1: the old registration can be put back from its saved config (exact srvctl add, spaces kept in one value)" "ut_restore > $T/ut_restore.txt; [[ \"\$(head -n 1 $T/ut_restore.txt)\" == \"/u01/db/bin/srvctl add database -db X_STBY -oraclehome /u01/db -spfile /u01/db/dbs/spfileX.ora -role PHYSICAL_STANDBY -startoption 'read only' -dbname x -instance X -diskgroup DATA,FRA\" ]] && grep -qF '<-startoption><read only><-dbname>' $T/ut_restore.txt"
ut_sidlast() { bash <<EOF
source <(sed -n '/^sidlist_of()/,/^}/p' $T/dg_standby_setup.sh)
SB_LSNR=L; sidlist_of 'SID_LIST_L=(SID_LIST=(SID_DESC=(SID_NAME=OLD)))SID_LIST_L=(SID_LIST=(SID_DESC=(SID_NAME=NEW)))'
EOF
}
check "5.1: of two SID_LIST blocks of one listener, the last one counts (as in Oracle)" "[[ \$(ut_sidlast) == '(SID_LIST=(SID_DESC=(SID_NAME=NEW)))' ]]"

fi
if part Z11; then  CUR=Z
# 5.11: start menu and parts (--only os, grid, db, primary, A-B)
fresh empty
rc=$(DG_TEST_MENU=3 run $T/z46.txt)
check "menu 3 (OS only): phase 1, then phase 2, and nothing of phase 3" "grep -q 'What do you want to do?' $T/z46.txt && grep -q 'This run: phase 2 only' $T/z46.txt && grep -q '^  Step 2.16' $T/z46.txt && ! grep -q '^  Step 3\.' $T/z46.txt"
rc=$(DG_TEST_MENU=4 run $T/z47.txt)
check "menu 4 (Grid only): steps 3.1 to 3.5 run, it stops before 3.6" "grep -q '^  Step 3.5' $T/z47.txt && ! grep -q '^  Step 3.6' $T/z47.txt && ! grep -q '^  Step 2\.' $T/z47.txt && grep -q 'Done: steps 3.1 to 3.5, every step OK' $T/z47.txt && [[ $rc -eq 0 ]]"
rc=$(DG_TEST_QUIT_AT=3.7 run $T/z48.txt --only db)
check "--only db: starts at 3.6; a stop inside the range points back to the same part" "grep -q '^  Step 3.6' $T/z48.txt && ! grep -q '^  Step 3.5' $T/z48.txt && ! grep -q 'What do you want to do?' $T/z48.txt && grep -q 'next: run the script --only 3.7-3.11' $T/varlib/last_run"
fresh
rc=$(run $T/z49.txt --only 2.1-2.4)
check "--only 2.1-2.4: only steps 2.1 to 2.4 (after phase 1), then it stops" "grep -q '^  Step 2.4' $T/z49.txt && ! grep -q '^  Step 2.5' $T/z49.txt && grep -q 'Done: steps 2.1 to 2.4' $T/z49.txt"
fresh empty
rc=$(DG_TEST_MENU=7 DG_TEST_MENU_STEPS=x9,2.1-2.2 DG_TEST_SUMMARY=2, run $T/z50.txt)
check "menu 7 with --yes: a wrong range is asked again, then 2.1-2.2 runs without the [y] question" "grep -q 'This is not a step or a range of steps' $T/z50.txt && grep -q '^  Step 2.2' $T/z50.txt && ! grep -q '^  Step 2.3' $T/z50.txt && grep -q 'Yes (yes to all)' $T/z50.txt && ! grep -q '\[y\] Yes, do it' $T/z50.txt"
rc=$(DG_TEST_MENU=12,q DG_TEST_MENU_REC=s run $T/z51.txt)
check "menu 12 then q: shows the status again and stops without running a step (exit 0)" "[[ $rc -eq 0 ]] && [[ \$(grep -c '^  Progress' $T/z51.txt) -ge 2 ]] && ! grep -q '^  Step ' $T/z51.txt"
rc1=$(run $T/z52a.txt --only 3.6-3.1); rc2=$(run $T/z52b.txt --only 3.99); rc3=$(run $T/z52c.txt --only grid --from 3.1)
check "--only: a reversed range, an unknown step, or --only with --from are refused (exit 2)" "[[ $rc1 -eq 2 && $rc2 -eq 2 && $rc3 -eq 2 ]]"

fi
if part Z12; then  CUR=Z
# 5.12: a step that could not check is never OK; persistence of /dev/shm; 9.1 rollback; threads; ranges
ut_goon() { bash <<EOF
source <(sed -n '/^step_num()/p;/^go_on_cmd()/,/^}/p' $T/dg_standby_setup.sh)
SELF=S; ONLY_PHASE=""
FROM_STEP=2.1; TO_STEP=2.4; TO_TEXT=2.4; ONLY_TEXT=2.1-2.4
echo "\$(go_on_cmd 4)|\$(go_on_cmd 2)|\$(go_on_cmd 2.3)"
FROM_STEP=3.6; TO_STEP=4.5; TO_TEXT=4.5; ONLY_TEXT=3.6-4.5
echo "\$(go_on_cmd 4)|\$(go_on_cmd 3)|\$(go_on_cmd 2.9)"
EOF
}
fresh; ut_goon > $T/ut_goon.txt
check "range runs: a bare phase gives a valid command (inside the range, before it, after it)" "[[ \$(sed -n 1p $T/ut_goon.txt) == 'S --from 4|S --only 2-2.4|S --only 2.3-2.4' && \$(sed -n 2p $T/ut_goon.txt) == 'S --only 4-4.5|S --only 3-4.5|S --only 2.9-4.5' ]]"
fresh empty; run $T/z53a.txt >/dev/null; jset $S "d['instances']['PRODDB_STBY']['mrp']=0"
rc=$(run $T/z53.txt --check)
check "9.7: the unit is enabled but redo apply is not running -> not OK" "[[ \$(res 9.7 $T/z53.txt) != OK ]] && grep -q 'but redo apply (MRP) is not running' $T/z53.txt"
fresh empty; run $T/z54a.txt >/dev/null; jset $S "d['instances']['PRODDB_STBY']['state']='idle'; d['srvctl']['running']=0"
rc=$(run $T/z54.txt --only 7.3-7.7)
check "a built standby that is down: the logins of 7.3, 7.4, 7.6 are 'waiting', not ok" "[[ \$(res 7.3 $T/z54.txt) == WAITS && \$(res 7.4 $T/z54.txt) == WAITS ]] && grep -q '^7.3|WAITS|' $T/varlib/progress"
jset $S "d['instances']['PRODDB_STBY']['state']='mounted'; d['instances']['PRODDB_STBY']['mrp']=0; d['srvctl']['running']=1"
rc=$(DG_TEST_QUIT_AT=9.5 run $T/z54b.txt --from 9.4)
check "... a later run that starts at 9.4 tests them, and records 7.3, 7.4, 7.6 as OK" "grep -q 'The logins of steps 7.3, 7.4 and 7.6 work now' $T/z54b.txt && grep -q '^7.3|OK|' $T/varlib/progress && grep -q '^7.6|OK|' $T/varlib/progress"
fresh; jset $O "d['shm_mb']=8192"; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':str(3*1024**3),'memory_max_target':str(3*1024**3),'pga_aggregate_target':'0','use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
sed -i 's|^tmpfs  /dev/shm  tmpfs  defaults,nodev  0 0|tmpfs  /dev/shm  tmpfs  defaults,nodev,size=2048m  0 0|' $T/fstab
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z55.txt)
check "2.16: /dev/shm big enough now, but fstab gives too little after a reboot -> fstab set to the live size" "grep -q 'after a reboot it gets only' $T/z55.txt && grep -q 'nodev,size=8192m' $T/fstab && [[ \$(res 2.16 $T/z55.txt) == DONE ]]"
fresh; jset $O "d['shm_mb']=8192"; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':str(3*1024**3),'memory_max_target':str(3*1024**3),'pga_aggregate_target':'0','use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
printf '[Mount]\nWhat=tmpfs\nWhere=/dev/shm\nType=tmpfs\nOptions=mode=1777,size=2g\n' > $T/dev-shm.mount
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z55b.txt)
check "2.16: a dev-shm.mount unit (wins over fstab) gets the size too, other options kept" "grep -qx 'Options=mode=1777,size=8192m' $T/dev-shm.mount && ls $T/dev-shm.mount.bak_* >/dev/null 2>&1 && [[ \$(res 2.16 $T/z55b.txt) == DONE ]]"
fresh empty; run $T/z56a.txt >/dev/null; jset $P "d['seq_t']={'1':42,'2':30}; d['applied_t']={'1':42,'2':10}"
rc=$(run $T/z56.txt --only 10)
check "10.3: every redo thread is compared (thread 2 behind -> not OK)" "grep -q 'Thread 2: last log archived on the primary 30, applied on the standby 10' $T/z56.txt && [[ \$(res 10.3 $T/z56.txt) != OK ]]"
fresh; sed -i '/^VERSION_ID=/d' $T/os-release
rc=$(run $T/z57.txt --check)
check "1.6: the OS version cannot be read -> 'cannot be checked' (problem), not OK" "grep -q 'Cannot be checked: the version of this operating system' $T/z57.txt && [[ \$(res 1.6 $T/z57.txt) == PROBLEM ]]"
DGT_OS=9 DGT_VER=21.8.0.0.0 fresh empty
rc=$(run $T/z58.txt --check)
check "1.6: 21c below 21.12 on Oracle Linux 9 -> not supported" "grep -q '21c on Oracle Linux 9 is certified from Release Update 21.12' $T/z58.txt"
DGT_OS=9 DGT_VER=21.13.0.0.0 fresh empty
rc=$(run $T/z58b.txt --check)
check "1.6: 21.13 on Oracle Linux 9 without RU_DIR -> install with the Release Update" "grep -q '21c on Oracle Linux 9 must be installed together with Release Update 21.12' $T/z58b.txt && ! grep -q 'certified from Release Update 21.12' $T/z58b.txt"
fresh empty; rc=$(DG_TEST_QUIT_AT=3.2 run $T/z59a.txt)
mkdir -p $T/u01/app/oraInventory/logs; echo old > $T/u01/app/oraInventory/logs/GridSetupActions.log; chown -R grid:oinstall $T/u01/app/oraInventory; rm -f /etc/oraInst.loc
rc=$(DG_TEST_QUIT_AT=3.3 run $T/z59.txt --yes)
check "--yes: moving a leftover inventory aside is still asked (3.2)" "sed -n '/^  Step 3.2/,/^  Step 3.3/p' $T/z59.txt | grep -q '\[y\] Yes, do it' && ls -d $T/u01/app/oraInventory.old_* >/dev/null 2>&1"
DGT_STORAGE=fs fresh empty; rc=$(DG_TEST_QUIT_AT=3.6 run $T/z60a.txt)
mkdir -p $T/u01/app/oraInventory/logs; echo old > $T/u01/app/oraInventory/logs/installActions.log; chown -R oracle:oinstall $T/u01/app/oraInventory; rm -f /etc/oraInst.loc
rc=$(DG_TEST_QUIT_AT=3.7 run $T/z60.txt)
check "3.6 without Grid: a leftover inventory is moved aside by the install (as in 3.2), no manual plan" "grep -q 'no Oracle home is registered in it' $T/z60.txt && ls -d $T/u01/app/oraInventory.old_* >/dev/null 2>&1 && ! grep -q 'If it is left over from an earlier attempt' $T/z60.txt"
fresh
rc=$(DG_TEST_MENU=7 DG_TEST_MENU_STEPS=10 run $T/z61.txt)
check "menu 7 with phase 10: no --yes question (as for menu 9)" "grep -q 'This run: phase 10 only' $T/z61.txt && ! grep -q 'Answer y automatically' $T/z61.txt"
fresh; jset $P "d['tns_stby']=1; d['stby_fw_drop']=1"
rc=$(DG_TEST_QUIT_AT=4.10 run $T/z62.txt)
check "4.9: no answer from this server after 2.9 opened the port -> a problem, not OK" "[[ \$(res 4.9 $T/z62.txt) != OK ]] && grep -q 'must be allowed from the primary' $T/z62.txt"
fresh; jset $P "d['tns_stby']=1; d['stby_fw_drop']=1"; jset $O "d['services']['firewalld']=True; d['fw']={'runtime':[],'permanent':[]}"
rc=$(run $T/z62b.txt --only 4)
check "4.9: no answer before step 2.9 opened the port -> waiting (tested again later)" "[[ \$(res 4.9 $T/z62b.txt) == WAITS ]] && grep -q 'Step 2.9 opens port' $T/z62b.txt"
fresh; jset $P "d['blocksize']='x'"
rc=$(DG_TEST_QUIT_AT=2.14 run $T/z63a.txt)
grep -q '^REDO_BLOCKSIZE=' $T/varlib/settings.conf && sed -i 's/^REDO_BLOCKSIZE=.*/REDO_BLOCKSIZE=512/' $T/varlib/settings.conf
rc=$(DG_TEST_QUIT_AT=2.14 run $T/z63.txt)
check "REDO_BLOCKSIZE: blocks 2.13 while unset, is used (with a warning) when set" "grep -q 'set REDO_BLOCKSIZE (512 or 4096)' $T/z63a.txt && grep -q 'REDO_BLOCKSIZE=512 from the settings is used' $T/z63.txt && [[ \$(res 2.13 $T/z63.txt) != PROBLEM ]]"

fresh; jset $P "d['ssh_users']=d.get('ssh_users',['oracle'])+['dgcheck']; d['profile_noread']=1"
rc=$(run $T/z64.txt --only 4 --user dgcheck)
check "4.11: another ssh user that cannot read oracle's .bash_profile -> 'cannot be checked', never OK (read-only probe)" "grep -q 'Cannot be checked: the ssh user dgcheck cannot read' $T/z64.txt && [[ \$(res 4.11 $T/z64.txt) != OK ]] && cmds_whitelisted"

fi
if part Z13; then  CUR=Z
# 5.13: sixth external review
ut_513() { bash <<EOF
source <(sed -n '/^norm()/p;/^sidlist_of()/,/^}/p;/^sqlnet_wallet_replaced()/,/^}/p;/^sid_desc_block()/,/^}/p;/^sidlist_insert()/,/^}/p;/^num()/p;/^hugepages_kb()/,/^}/p;/^lim_min()/,/^}/p;/^lim_enough()/,/^}/p' $T/dg_standby_setup.sh)
d=\$(mktemp -d); MEMINFO_FILE=/nonexistent
printf 'NAMES.DIRECTORY_PATH=(TNSNAMES)\nENCRYPTION_WALLET_LOCATION =\n  (SOURCE = (METHOD = FILE)\n    (METHOD_DATA = (DIRECTORY = /old/w)))\nSQLNET.X=1\n' > \$d/s
r=\$(sqlnet_wallet_replaced \$d/s /new/w) && [[ "\$r" == *"(DIRECTORY = /new/w)))"* && "\$r" != *old* && "\$r" == *SQLNET.X=1* ]] && echo A
printf 'ENCRYPTION_WALLET_LOCATION=(x)\nENCRYPTION_WALLET_LOCATION=(y)\n' > \$d/t; sqlnet_wallet_replaced \$d/t /n >/dev/null || echo B
SB_LSNR=LISTENER STANDBY_SERVICE=svc STANDBY_SID=S1 DB_HOME=/h
printf 'SID_LIST_LISTENER =\n  (SID_LIST =\n    (SID_DESC = (SID_NAME = OTHER)(ORACLE_HOME = /x))\n  )\nX = 1\n' > \$d/l
r=\$(sidlist_insert \$d/l) && [[ "\$r" == *"(SID_NAME = OTHER)"*"(SID_NAME = S1)"* ]] && ! grep -q '^)' <<< "\$r" && echo C
printf 'SID_LIST_LISTENER=(SID_LIST=(SID_DESC=(SID_NAME=A)\n' > \$d/u; sidlist_insert \$d/u >/dev/null || echo D
lim_enough nofile 1024 || echo E; lim_enough nofile unlimited && lim_enough memlock 64 && lim_enough stack 32768 && echo F
printf 'SID_LIST_LISTENER = (SID_DESC = (SID_NAME = A)(ORACLE_HOME = /x))\n' > \$d/v; sidlist_insert \$d/v >/dev/null || echo G
printf 'ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = /o))) # see (x\nSQLNET.Y=2\n' > \$d/w
r=\$(sqlnet_wallet_replaced \$d/w /n) && [[ "\$r" == *SQLNET.Y=2* ]] && echo H
rm -rf \$d
EOF
}
fresh; ut_513 > $T/ut_513.txt
check "unit: sqlnet.ora wallet entry replaced (multi-line, comments), two entries refused; SID_DESC put inside SID_LIST only (never in column 1), unclosed or unusual block refused; limit minimums" "[[ \$(paste -sd' ' $T/ut_513.txt) == 'A B C D E F G H' ]]"

fresh empty; rc=$(run $T/z70a.txt)
check "8.2: after RMAN success the new standby itself is checked (mounted, role, every datafile)" "grep -q 'Checked: mounted, physical standby' $T/z70a.txt"
jset $S "d['instances']['PRODDB_STBY']['mrp']=0"
rc=$(run $T/z70.txt --check)
check "9.7: unit in place but apply stopped -> not OK, and the action starts it" "[[ \$(res 9.7 $T/z70.txt) != OK ]] && grep -q 'but redo apply (MRP) is not running' $T/z70.txt"
rc=$(run $T/z70b.txt --only 9.7)
check "... --only 9.7 starts apply (asked) and the step is done" "[[ \$(res 9.7 $T/z70b.txt) == DONE ]] && python3 -c \"import json;assert json.load(open('$S'))['instances']['PRODDB_STBY']['mrp']==1\""
jset $S "d['instances']['PRODDB_STBY']['state']='idle'; d['srvctl']['running']=0"
rc=$(run $T/z71.txt --only 9.7)
check "9.7 with Grid: standby down -> waiting for Oracle Restart, not OK" "[[ \$(res 9.7 $T/z71.txt) == WAITS ]] && grep -q 'Oracle Restart mounts it' $T/z71.txt"
jset $S "d['instances']['PRODDB_STBY']['state']='mounted'; d['srvctl']['running']=1; d['instances']['PRODDB_STBY']['dg_errors_recent']=2"
rc=$(run $T/z72.txt --only 10.4)
check "10.4: Data Guard errors in the last 15 minutes -> waiting (messages shown), not OK" "[[ \$(res 10.4 $T/z72.txt) == WAITS ]] && grep -q 'in the last 15 minutes' $T/z72.txt && grep -q 'ORA-16401' $T/z72.txt"
jset $S "d['instances']['PRODDB_STBY']['dg_errors_recent']=0; d['instances']['PRODDB_STBY']['srl']=0; d['instances']['PRODDB_STBY']['mrp']=1"
rc=$(run $T/z73.txt --only 9.3)
check "9.3: apply stopped to add standby logs is started again" "[[ \$(res 9.3 $T/z73.txt) == DONE ]] && grep -q 'Redo apply is running again' $T/z73.txt && python3 -c \"import json;assert json.load(open('$S'))['instances']['PRODDB_STBY']['mrp']==1\""
jset $S "d['srvctl']['spfile']='/wrong/spfileX.ora'; d['srvctl']['policy']='MANUAL'; d['srvctl']['stopopt']='abort'"
rc=$(run $T/z74.txt --only 9.1)
check "9.1: a new registration keeps the old management policy and stop option" "grep -q 'Kept from the old registration: -policy MANUAL -stopoption abort' $T/z74.txt && python3 -c \"import json;r=json.load(open('$S'))['srvctl'];assert r['policy']=='MANUAL' and r['stopopt']=='abort'\""
jset $O "d['parts'].pop('/dev/sdc1', None)"
rc=$(run $T/z75.txt --only 2.13 --check)
check "2.13: an ASM label whose disk is gone -> 'cannot be checked' with the label named, never used" "grep -q 'These ASM disk labels have no disk behind them now:  FRA_1' $T/z75.txt && [[ \$(res 2.13 $T/z75.txt) != OK ]]"

fresh; printf 'grid  hard  nofile  1024\n' > /etc/security/limits.d/50-low.conf
rc=$(DG_TEST_QUIT_AT=2.5 run $T/z76.txt)
rm -f /etc/security/limits.d/50-low.conf
check "2.4: a limit set too low (nofile 1024) -> reported with the minimum and the right value added" "grep -q 'grid:nofile=1024(min 65536)' $T/z76.txt && grep -qE '^grid +hard +nofile +65536' /etc/security/limits.d/oracle-grid.conf && [[ \$(res 2.4 $T/z76.txt) == DONE ]]"
fresh; printf 'grid  hard  nofile  1024\n' > /etc/security/limits.d/zz-low.conf
rc=$(DG_TEST_QUIT_AT=2.5 run $T/z76b.txt)
rm -f /etc/security/limits.d/zz-low.conf
check "2.4: a too low user line in a file read later wins -> that line is named (manual), nothing appended that would lose" "grep -q 'zz-low.conf:  grid  hard  nofile  1024' $T/z76b.txt && [[ \$(res 2.4 $T/z76b.txt) != DONE && \$(res 2.4 $T/z76b.txt) != OK ]]"

fresh empty; rc=$(DG_TEST_QUIT_AT=2.1 run $T/z77a.txt)
mkdir -p $T/ru/99999999; touch $T/p6880880_190000_Linux-x86-64.zip
printf 'RU_DIR=%s\nOPATCH_ZIP=%s\n' "$T/ru" "$T/p6880880_190000_Linux-x86-64.zip" >> $T/varlib/settings.conf
sed -i '/^RU_DIR=$/d;/^OPATCH_ZIP=$/d' $T/varlib/settings.conf
rc=$(DG_TEST_QUIT_AT=3.2 run $T/z77.txt)
check "3.1: RU_DIR that is not the primary's Release Update -> stop before any install" "grep -q 'is not the Release Update of the primary' $T/z77.txt && ! grep -q '^gridSetup.sh user=' $T/state/calls.log"

fresh; sed -i 's/(GLOBAL_DBNAME = proddb_stby)/(GLOBAL_DBNAME = other_svc)/; s/(SID_NAME = PRODDB_STBY)/(SID_NAME = OTHERDB)/' $T/u01/app/19.0.0/grid/network/admin/listener.ora
rc=$(run $T/z78.txt --only 5.1)
check "5.1: SID_LIST block without this SID -> the entry is put inside it (other entry kept, backup kept)" "[[ \$(res 5.1 $T/z78.txt) == DONE ]] && [[ \$(grep -c '^SID_LIST_LISTENER' $T/u01/app/19.0.0/grid/network/admin/listener.ora) -eq 1 ]] && grep -q 'SID_NAME = OTHERDB' $T/u01/app/19.0.0/grid/network/admin/listener.ora && grep -q 'SID_NAME = PRODDB_STBY' $T/u01/app/19.0.0/grid/network/admin/listener.ora && ls $T/u01/app/19.0.0/grid/network/admin/listener.ora.bak_* >/dev/null"

fresh; jset $O "d['shm_mb']=8192"; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':str(3*1024**3),'memory_max_target':str(3*1024**3),'pga_aggregate_target':'0','use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
mkdir -p $T/dev-shm.mount.d; printf '[Mount]\nOptions=mode=1777,size=1g\n' > $T/dev-shm.mount.d/50-size.conf
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z79.txt)
check "2.16: a drop-in of dev-shm.mount sets the boot size -> found, and its size is set" "grep -q 'dev-shm.mount.d/50-size.conf' $T/z79.txt && grep -q 'Options=mode=1777,size=8192m' $T/dev-shm.mount.d/50-size.conf && [[ \$(res 2.16 $T/z79.txt) == DONE ]]"
fresh; jset $O "d['shm_mb']=8192"; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':str(3*1024**3),'memory_max_target':str(3*1024**3),'pga_aggregate_target':'0','use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
sed -i 's|^tmpfs  /dev/shm  tmpfs  defaults,nodev  0 0|tmpfs  /dev/shm  tmpfs  defaults,nodev,size=1.5G  0 0|' $T/fstab
rc=$(DG_TEST_QUIT_AT=3.1 run $T/z80.txt)
check "2.16: a boot size that cannot be read (size=1.5G) counts as too small, never OK" "grep -q 'the size it gets after a reboot cannot be read' $T/z80.txt && grep -q 'nodev,size=8192m' $T/fstab"

DGT_OS=9 DGT_UNAME=5.14.0-427.el9.x86_64 fresh empty; jset $O "d['udevd_down']=1"
rc=$(DG_TEST_QUIT_AT=2.13 run $T/z81.txt)
check "2.12: udev rules but systemd-udevd not running -> found, not OK" "grep -q 'systemd-udevd is not running' $T/z81.txt && [[ \$(res 2.12 $T/z81.txt) != OK ]]"

fresh; jset $P "d['stby_fw_drop']=1"
rc=$(run $T/z82.txt --only 2.9)
check "2.9: the primary cannot reach this server's port -> warned already in phase 2 (read-only connect probe)" "grep -q 'The primary cannot reach' $T/z82.txt && cmds_whitelisted"

fresh; cp /etc/oratab $T/oratab.real; rm -f /etc/oratab; ln -s $T/oratab.real /etc/oratab; sed -i '/^PRODDB_STBY:/d' $T/oratab.real
rc=$(run $T/z83.txt --only 7.7)
rm -f /etc/oratab; cp $T/oratab.real /etc/oratab
check "7.7: /etc/oratab is a link -> the line to set is shown (no write through the link), not a dead end" "grep -q 'is a link to' $T/z83.txt && ! grep -q '^PRODDB_STBY:' $T/oratab.real"

fresh empty; mkdir -p $T/u01/app/otherInventory; printf 'inventory_loc=%s/u01/app/otherInventory\ninst_group=oinstall\n' "$T" > /etc/oraInst.loc
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z84.txt)
check "an inventory this server already has (/etc/oraInst.loc) is the one used, not the primary's path" "grep -q 'inventory: this server uses $T/u01/app/otherInventory' $T/log/run_*.log"
rm -f /etc/oraInst.loc

fi
if part Z14; then  CUR=Z
# 5.14: seventh external review
ut_514() { bash <<EOF
source <(sed -n '/^norm()/p;/^num()/p;/^sidlist_of()/,/^}/p;/^sid_desc_block()/,/^}/p;/^sidlist_replace()/,/^}/p;/^tns_block()/,/^}/p;/^tns_replace()/,/^}/p;/^sqlnet_wallet_replaced()/,/^}/p;/^hugepages_kb()/,/^}/p;/^lim_min()/,/^}/p;/^lim_enough()/,/^}/p;/^dg_union()/,/^}/p;/^ru_root()/,/^}/p' $T/dg_standby_setup.sh)
d=\$(mktemp -d)
SB_LSNR=LISTENER STANDBY_SERVICE=svc STANDBY_SID=S1 DB_HOME=/h
printf 'SID_LIST_LISTENER =\n  (SID_LIST =\n    (SID_DESC =\n      (SID_NAME = OTHER)(ORACLE_HOME = /x)\n    )\n    (SID_DESC =   # old one\n      (SID_NAME = s1)\n      (ORACLE_HOME = /wrong)\n    )\n  )\n' > \$d/l
r=\$(sidlist_replace \$d/l) && [[ "\$r" == *"(SID_NAME = OTHER)"*"(SID_NAME = S1)"*"(ORACLE_HOME = /h)"* && "\$r" != *wrong* ]] && echo A
printf 'SID_LIST_LISTENER =\n  (SID_LIST = (SID_DESC = (SID_NAME = S1)(ORACLE_HOME = /w))\n  )\n' > \$d/m; sidlist_replace \$d/m >/dev/null || echo B
printf 'SID_LIST_LISTENER =\n  (SID_LIST =\n    (SID_DESC = (SID_NAME = S1))\n    (SID_DESC = (SID_NAME = S1))\n  )\n' > \$d/n; sidlist_replace \$d/n >/dev/null || echo C
PORT=1521 T_ALIAS=PRIM T_HOST=h1 T_SVC=prim
printf 'X = (DESCRIPTION=(ADDRESS=(HOST=x)))\nprim =\n  (DESCRIPTION =\n    (ADDRESS = (PROTOCOL = TCP)(HOST = old)(PORT = 1521))\n  )\nY = (z)\n' > \$d/t
r=\$(tns_replace \$d/t PRIM) && [[ "\$r" == *"X = "*"(HOST = h1)"*"(UR = A)"*"Y = (z)"* && "\$r" != *old* ]] && echo D
printf 'PRIM = (DESCRIPTION=(ADDRESS=(HOST=a))) Z=(1)\n' > \$d/u; tns_replace \$d/u PRIM >/dev/null || echo E
printf 'ENCRYPTION_WALLET_LOCATION = # main\n  (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = /o)))\n' > \$d/s
r=\$(sqlnet_wallet_replaced \$d/s /n) && [[ "\$r" == "# main"*"(DIRECTORY = /n)))" ]] && echo F
printf 'HugePages_Total:    1024\nHugepagesize:       2048 kB\n' > \$d/mi; MEMINFO_FILE=\$d/mi
! lim_enough memlock 64 && lim_enough memlock 2097152 && lim_enough memlock unlimited && echo G
MEMINFO_FILE=/nonexistent; lim_enough memlock 64 && echo H
[[ \$(dg_union "data,FRA" "FRA,EXTRA") == "DATA,FRA,EXTRA" ]] && echo I
mkdir -p \$d/ru/1111111 \$d/ru/2222222; RU_DIR=\$d/ru; [[ -z \$(ru_root) ]] && rmdir \$d/ru/2222222 && [[ \$(ru_root) == \$d/ru/1111111 ]] && echo J
printf 'SID_LIST_LISTENER =\n  (SID_LIST =\n    (SID_DESC =\n      (GLOBAL_DBNAME = S1_DGMGRL)(SID_NAME = S1)(ORACLE_HOME = /old)\n    )\n  )\n' > \$d/k; sidlist_replace \$d/k >/dev/null || echo K
printf 'ORCLXWORLD = (DESCRIPTION=(ADDRESS=(HOST=keep)))\nORCL.WORLD =\n  (DESCRIPTION = # first\n    (ADDRESS = (HOST = old)))\n' > \$d/w
T_ALIAS=ORCL.WORLD; r=\$(tns_replace \$d/w ORCL.WORLD) && [[ "\$r" == *"(HOST=keep)"*"# first"*"ORCL.WORLD ="*"(HOST = h1)"* && "\$r" != *old* ]] && echo L
printf 'ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = /o)))  SQLNET.EXPIRE_TIME = 10\n' > \$d/x; sqlnet_wallet_replaced \$d/x /n >/dev/null || echo M
printf 'SID_LIST_LISTENER =\n  (SID_LIST =\n    (SID_DESC = (GLOBAL_DBNAME = svc)(SID_NAME = S1)(ORACLE_HOME = /old)) (SID_DESC = (SID_NAME = X))\n  )\n' > \$d/o; rr=0; sidlist_replace \$d/o >/dev/null || rr=\$?; [[ \$rr -eq 1 ]] && echo N
printf 'ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = /x))) WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = /y)))\n' > \$d/y; sqlnet_wallet_replaced \$d/y /n >/dev/null || echo O
rr=0; sidlist_replace \$d/k >/dev/null || rr=\$?; [[ \$rr -eq 3 ]] && echo P
rm -rf \$d
EOF
}
fresh; ut_514 > $T/ut_514.txt
check "unit: wrong SID_DESC replaced (own lines only, one entry only, never another service's entry), tnsnames alias replaced (literal name, comments kept), sqlnet text after the entry refused, sqlnet comment kept, memlock with HugePages, disk group union, RU folder" "[[ \$(paste -sd' ' $T/ut_514.txt) == 'A B C D E F G H I J K L M N O P' ]]"
ut_timer2() { bash <<'EOF'
source <(sed -n '/^arch_timer_state()/,/^}/p' /tmp/dgt/dg_standby_setup.sh)
arch_timer() { echo t.timer; }; arch_service() { echo s.service; }
d=$(mktemp -d); arch_timer_text() { echo T; }; arch_service_text() { echo S; }; arch_script_text() { echo C; }; arch_script() { echo $d/c; }
echo T > /etc/systemd/system/t.timer; echo S > /etc/systemd/system/s.service; echo C > $d/c
systemctl() { case "$1 $3" in "is-enabled t.timer") return 0 ;; "is-active t.timer") return 3 ;; "is-failed s.service") return 0 ;; esac; return 1; }
a=$(arch_timer_state); rm -rf $d /etc/systemd/system/t.timer /etc/systemd/system/s.service; echo "$a"
EOF
}
check "9.8: a failed clean-up with the timer off -> 'failed' first (its fix turns the timer on too)" "[[ \$(ut_timer2) == failed ]]"

fresh empty; rc=$(run $T/z90a.txt)
check "8.2 copy recorded as verified (marker 'duplicate')" "grep -q 'Checked: mounted, physical standby' $T/z90a.txt"
jset $S "d['instances']['PRODDB_STBY']['df_errors']=3"
rc=$(run $T/z90.txt --only 10.4 --check)
check "a verified standby (marker 'duplicate') with header errors now -> warned, not passed in silence" "grep -q 'datafile header(s) show an error' $T/z90.txt"
jset $S "d['instances']['PRODDB_STBY']['df_errors']=0; d['instances']['PRODDB_STBY']['dgs_fail']=1"
rc=$(run $T/z91.txt --only 10.4)
check "10.4: v\$dataguard_status cannot be read -> cannot check, never OK" "grep -q 'Cannot read v\$dataguard_status' $T/z91.txt && [[ \$(res 10.4 $T/z91.txt) != OK && \$(res 10.4 $T/z91.txt) != WAITS ]]"
jset $S "d['instances']['PRODDB_STBY']['dgs_fail']=0; d['srvctl']['dg']='DATA'"
rc=$(run $T/z92.txt --only 9.1)
check "9.1: a registration without a disk group the standby needs -> changed in place (srvctl modify), old value journaled" "grep -q 'these values are wrong: diskgroup' $T/z92.txt && python3 -c \"import json;assert json.load(open('$S'))['srvctl']['dg']=='DATA,FRA'\" && grep -q 'olddg=DATA' $T/varlib/changes.log"
jset $S "d['srvctl']['spfile']='/wrong/spfileX.ora'; d['srvctl']['dg']='DATA,FRA,EXTRA'; d['srvctl']['domain']='corp.local'; d['dgs']=d.get('dgs',['DATA','FRA'])+['EXTRA']"
rc=$(run $T/z93.txt --only 9.1)
check "9.1: a new registration keeps the extra disk group and the domain of the old one" "python3 -c \"import json;r=json.load(open('$S'))['srvctl'];assert r['dg']=='DATA,FRA,EXTRA' and r.get('domain')=='corp.local',r\" && grep -q 'Kept from the old registration:.*-diskgroup DATA,FRA,EXTRA' $T/z93.txt"
jset $S "d['instances']['PRODDB_STBY']['state']='idle'; d['srvctl']['running']=0"
rc=$(run $T/z94.txt --only 8.2 --check)
check "8.2: a standby that is down counts as built only by its record, and says so" "grep -q 'Recorded as built, not checked now' $T/z94.txt"
rc=$(run $T/z95.txt --only 9.7)
check "9.7 with Grid: standby down -> looked at again (6 times) before 'waiting'" "grep -q 'Checked again in 1 seconds (6 of 6)' $T/z95.txt && [[ \$(res 9.7 $T/z95.txt) == WAITS ]]"

fresh empty; rc=$(DG_TEST_QUIT_AT=3.2 run $T/z96a.txt)
mkdir -p $T/ru/99999999; touch $T/p6880880_190000_Linux-x86-64.zip
printf 'RU_DIR=%s\nOPATCH_ZIP=%s\n' "$T/ru" "$T/p6880880_190000_Linux-x86-64.zip" >> $T/varlib/settings.conf
sed -i '/^RU_DIR=$/d;/^OPATCH_ZIP=$/d' $T/varlib/settings.conf
rc=$(DG_TEST_QUIT_AT=3.3 run $T/z96.txt --from 3.2)
check "3.2 run with --from (3.1 skipped): a wrong RU_DIR still stops before the install" "grep -q 'is not the Release Update of the primary' $T/z96.txt && ! grep -q '^gridSetup.sh user=.*-silent' $T/state/calls.log"
mkdir -p $T/ru2/1111111 $T/ru2/2222222; sed -i "s|^RU_DIR=.*|RU_DIR=$T/ru2|" $T/varlib/settings.conf
rc=$(DG_TEST_QUIT_AT=3.2 run $T/z97.txt --from 3.1)
check "3.1: RU_DIR with two patch folders -> which one is not guessed" "grep -q 'holds 2 patch folders' $T/z97.txt"

fresh; jset $P "d['tde']=['FILE|$T/pwallet/|OPEN']; d['wallet_root']='$T/pwroot'; d['exists_fail']=['$T/pwroot/tde_seps']; d['files']={'$T/pwallet/ewallet.p12':'EWALLET\\n','$T/pwallet/cwallet.sso':'CWALLET\\n'}"
rc=$(DG_TEST_QUIT_AT=7.1 run $T/z98.txt)
check "6.3: whether WALLET_ROOT/tde_seps exists cannot be asked -> the step stops, the folder is not left out" "grep -q 'Cannot tell whether $T/pwroot/tde_seps exists' $T/z98.txt && [[ \$(res 6.3 $T/z98.txt) != DONE ]]"
fresh; jset $P "d['tde']=['FILE|$T/pwallet/|OPEN']; d['wallet_root']='$T/pwroot'; d['lsdir']={'$T/pwroot/tde_seps':['cwallet.sso']}; d['files']={'$T/pwallet/ewallet.p12':'EWALLET\\n','$T/pwallet/cwallet.sso':'CWALLET\\n','$T/pwroot/tde_seps/cwallet.sso':'SEPS\\n'}"
rc=$(DG_TEST_QUIT_AT=7.1 run $T/z98b.txt)
check "6.3: WALLET_ROOT/tde_seps with cwallet.sso -> copied too" "[[ \$(cat $T/pwroot/tde_seps/cwallet.sso 2>/dev/null) == SEPS ]]"
fresh; jset $P "d['pw_tmp']=1; d['stat_fail']=['/tmp/orapw_for_standby_PRODDB_STBY']"
rc=$(DG_TEST_QUIT_AT=6.2 run $T/z99.txt)
check "6.1: stat of the temporary copy fails, the file is there -> cannot tell, not 'no copy yet'" "grep -q 'Cannot tell whether the temporary copy' $T/z99.txt && [[ \$(res 6.1 $T/z99.txt) != DONE ]]"

fresh; jset $O "d['nft_ruleset']='table inet filter {\n  chain input {\n    type filter hook input priority 0; policy drop;\n  }\n}'"; jset $P "d['stby_fw_drop']=1"
rc=$(run $T/z100.txt --only 2.9)
check "2.9: firewalld not active, nftables drops input, primary gets no answer -> a note on the rules and a warning without a false premise" "grep -q 'rules outside firewalld that drop or reject' $T/z100.txt && grep -q 'firewalld is not active here, so something else blocks it' $T/z100.txt && ! grep -q 'is open in firewalld here' $T/z100.txt"
fresh; jset $P "d['tcpto']='NOROUTE'"
rc=$(run $T/z101.txt --only 2.9)
check "2.9: 'No route to host' from the primary -> the address is named first, not only a firewall" "grep -q 'no route to host' $T/z101.txt && grep -q 'Check the address first' $T/z101.txt"

DGT_OS=9 DGT_UNAME=5.14.0-427.el9.x86_64 fresh empty; jset $O "d['udevd_down']=1"
rc=$(DG_TEST_QUIT_AT=2.13 run $T/z102.txt)
check "2.12: systemd-udevd not running -> started by the script, step done" "[[ \$(res 2.12 $T/z102.txt) == DONE ]] && python3 -c \"import json;assert not json.load(open('$O')).get('udevd_down')\""

fresh; jset $O "d['shm_mb']=8192; d['shm_cat']='# /usr/lib/systemd/system/dev-shm.mount\n[Mount]\nOptions=mode=1777,size=1g'; d['shm_dropin_path']='$T/dev-shm.mount.d/zz-dg-standby-shm.conf'"; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':str(3*1024**3),'memory_max_target':str(3*1024**3),'pga_aggregate_target':'0','use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
mkdir -p $T/sdrun
rc=$(DG_SYSTEMD_RUN_DIR=$T/sdrun DG_TEST_QUIT_AT=3.1 run $T/z103.txt)
check "2.16: the boot size comes from a unit outside /etc (systemctl cat) -> not changed, an /etc drop-in sets it" "grep -q '/usr/lib/systemd/system/dev-shm.mount sets /dev/shm at boot. It is not changed' $T/z103.txt && grep -q 'Options=mode=1777,size=8192m' $T/dev-shm.mount.d/zz-dg-standby-shm.conf && [[ \$(res 2.16 $T/z103.txt) == DONE ]]"

fresh; jset $O "d['shm_mb']=8192; d['shm_cat']='# /run/systemd/generator/dev-shm.mount\n[Mount]\nOptions=size=1g'"; jset $P "d['mem']={'sga_target':str(1024**3),'sga_max_size':str(1024**3),'memory_target':str(3*1024**3),'memory_max_target':str(3*1024**3),'pga_aggregate_target':'0','use_large_pages':'TRUE','db_recovery_file_dest_size':'0'}"
sed -i 's|^tmpfs  /dev/shm  tmpfs  defaults,nodev  0 0|tmpfs  /dev/shm  tmpfs  defaults,nodev,size=1g  0 0|' $T/fstab; mkdir -p $T/sdrun
rc=$(DG_SYSTEMD_RUN_DIR=$T/sdrun DG_TEST_QUIT_AT=3.1 run $T/z108.txt)
check "2.16: the unit systemd made from fstab is old until a reload -> fstab itself is read; size set and step done" "grep -q 'nodev,size=8192m' $T/fstab && [[ \$(res 2.16 $T/z108.txt) == DONE ]] && ! ls $T/dev-shm.mount.d/zz-dg-standby-shm.conf 2>/dev/null"

fresh; sed -i 's/(GLOBAL_DBNAME = proddb_stby)/(GLOBAL_DBNAME = proddb_stby_DGMGRL)/' $T/u01/app/19.0.0/grid/network/admin/listener.ora
rc=$(run $T/z109.txt --only 5.1)
rc=$(run $T/z109b.txt --only 5.2)
check "5.1: the only entry of this SID is the broker's (_DGMGRL) -> kept, the right entry added; 5.2 then reloads the listener" "grep -q 'GLOBAL_DBNAME = proddb_stby_DGMGRL' $T/u01/app/19.0.0/grid/network/admin/listener.ora && grep -qF 'GLOBAL_DBNAME = proddb_stby)' $T/u01/app/19.0.0/grid/network/admin/listener.ora && [[ \$(res 5.1 $T/z109.txt) == DONE && \$(res 5.2 $T/z109b.txt) == DONE ]] && ! ls $T/varlib/listener_reload_due 2>/dev/null"

fresh; mkdir -p /etc/dgt_safe; chmod 755 /etc/dgt_safe; cp /etc/oratab /etc/dgt_safe/oratab; cp /etc/oratab $T/oratab.keep; sed -i '/^PRODDB_STBY:/d' /etc/dgt_safe/oratab; rm -f /etc/oratab; ln -s /etc/dgt_safe/oratab /etc/oratab
rc=$(run $T/z104.txt --only 7.7)
r104=$(grep -c '^PRODDB_STBY:' /etc/dgt_safe/oratab); l104=0; [[ -L /etc/oratab ]] && l104=1
rm -f /etc/oratab; cp $T/oratab.keep /etc/oratab; rm -rf /etc/dgt_safe
check "7.7: /etc/oratab is a safe link (root, folders only root can change) -> the file it points to gets the line" "[[ $r104 -eq 1 && $l104 -eq 1 ]] && [[ \$(res 7.7 $T/z104.txt) == DONE ]]"

fresh empty; printf 'garbage\n' > /etc/oraInst.loc
rc=$(DG_TEST_QUIT_AT=2.1 run $T/z105.txt)
rm -f /etc/oraInst.loc
check "an /etc/oraInst.loc without a usable inventory_loc -> said, not passed over" "grep -q 'no usable inventory_loc line can be read' $T/z105.txt"

fresh; jset $P "d['params']['db_recovery_file_dest']=''; d['params']['log_archive_dest_1']=''; d['arch_mb_day']=4096; d['dg_names']=['DATA','RECO']"
rc=$(run $T/z106.txt --only 4.6 --check)
check "4.6: no archive destination -> size and disk group filled in from the primary (3 days + 20 %, RECO)" "grep -q 'db_recovery_file_dest_size=15G' $T/z106.txt && grep -q \"db_recovery_file_dest='+RECO'\" $T/z106.txt"

fresh; sed -i 's|(HOST = prim01)|(HOST = wronghost)|' $T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/tnsnames.ora
rc=$(DG_TEST_QUIT_AT=6.1 run $T/z107.txt)
check "5.3: an existing alias with a wrong host -> replaced (backup kept), not a manual edit" "[[ \$(res 5.3 $T/z107.txt) == DONE ]] && grep -q '(HOST = prim01)' $T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/tnsnames.ora && ! grep -q wronghost $T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/tnsnames.ora && ls $T/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/tnsnames.ora.bak_* >/dev/null"

fi
if part Z15; then  CUR=Z
# 5.15: eighth external review
ut_515() { bash <<EOF
source <(sed -n '/^num()/p;/^v_path()/p;/^ru_root()/,/^}/p;/^ru_ids()/,/^}/p;/^ru_matches_primary()/,/^}/p;/^hugepages_kb()/,/^}/p;/^lim_min()/,/^}/p;/^lim_enough()/,/^}/p' $T/dg_standby_setup.sh)
d=\$(mktemp -d); mkdir -p \$d/ru/1111111; RU_DIR=\$d/ru DB_HOME=/d GRID_HOME=/g SELF=x
need_ssh() { true; }; use_grid() { true; }; warn() { :; }; hostname() { echo h; }
primary_patches() { case \$1 in /g) echo 1111111 ;; /d) echo 2222222 ;; esac; }
ru_matches_primary grid && echo A
ru_matches_primary db || echo B
ru_matches_primary "grid db" || echo C
MEMINFO_FILE=/nonexistent; LIM_MEMLOCK_NEED=1000; ! lim_enough memlock 500 && lim_enough memlock 1000 && echo D
! v_path /u01/app/oracle/../../../usr/local/sbin && ! v_path /a/./b && ! v_path //x && v_path /u01/app/x.y && echo E
rm -rf \$d
EOF
}
fresh; ut_515 > $T/ut_515.txt
check "unit: the RU check compares only the home being installed; memlock covers the primary's HugePages SGA; a path with . or .. parts is refused" "[[ \$(paste -sd' ' $T/ut_515.txt) == 'A B C D E' ]]"

fresh empty; rc=$(run $T/z110a.txt)
jset $S "d['srvctl']['dg']='DATA,FRA,GONE'"
rc=$(run $T/z110.txt --only 9.1)
check "9.1: a registered disk group ASM here does not see -> named, never taken out by the script" "grep -q 'disk group(s) that ASM here does not see: GONE' $T/z110.txt && python3 -c \"import json;assert json.load(open('$S'))['srvctl']['dg']=='DATA,FRA,GONE'\""
jset $S "d['srvctl']['dg']='DATA,FRA'; d['srvctl']['spfile']='/wrong/spfileX.ora'; d['srvctl']['policy']='MANUAL'; d['srvctl']['stopopt']='abort'"
rc=$(run $T/z111.txt --only 9.1 --check)
check "9.1: the srvctl add shown for a new registration has the kept values (policy, stop option)" "grep -q 'srvctl add database' $T/z111.txt && grep -qE 'srvctl add database .*-policy MANUAL' $T/z111.txt && grep -qE 'srvctl add database .*-stopoption abort' $T/z111.txt"
jset $S "d['srvctl']['spfile']=d['srvctl']['spfile'] if d['srvctl']['spfile']!='/wrong/spfileX.ora' else '$T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora'; d['instances']['PRODDB_STBY']['hdr_fail']=1"
rc=$(run $T/z112.txt --only 10.4 --check)
check "a built standby whose datafile headers cannot be read -> cannot tell, not OK" "grep -q 'datafile headers of the standby cannot be read' $T/z112.txt && [[ \$(res 10.4 $T/z112.txt) != OK ]]"
jset $S "d['instances']['PRODDB_STBY']['hdr_fail']=0; d['instances']['PRODDB_STBY']['dg_errors']=2; d['instances']['PRODDB_STBY']['dg_err_last']='20261102100000'"
rc=$(run $T/z113a.txt --only 10.4)
jset $S "d['instances']['PRODDB_STBY']['dg_err_last']='20261102110000'"
rc=$(run $T/z113.txt --only 10.4)
check "10.4: old errors -> a warning; new ones since the last run (none in 15 minutes) -> waiting" "[[ \$(res 10.4 $T/z113a.txt) == OK && \$(res 10.4 $T/z113.txt) == WAITS ]] && grep -q 'New Data Guard error messages came since the last run' $T/z113.txt"
printf "*.audit_file_dest='/opt/dgt_audit_x'\n" >> $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(run $T/z114.txt --only 7.1)
check "7.1: the spfile's audit folder outside ORACLE_BASE is missing -> a step by hand, never OK; nothing made there" "grep -q 'mkdir -p /opt/dgt_audit_x' $T/z114.txt && [[ \$(res 7.1 $T/z114.txt) != OK && \$(res 7.1 $T/z114.txt) != DONE ]] && [[ ! -e /opt/dgt_audit_x ]]"

fresh; jset $O "d['nft_ruleset']='table inet filter {\n  chain input {\n    type filter hook input priority 0; policy accept;\n    tcp dport 1521 drop\n  }\n}'"
rc=$(run $T/z115.txt --only 2.9)
check "2.9: a rule outside firewalld that drops the port itself -> that rule is shown" "grep -q 'rules outside firewalld that drop or reject' $T/z115.txt && grep -q 'tcp dport 1521 drop' $T/z115.txt"
fresh; jset $P "d['stby_fw_drop']=1"
rc=$(run $T/z116.txt --only 2.9 --check)
check "2.9 in check mode: the connect from the primary is tried too (read-only)" "grep -q 'The primary cannot reach' $T/z116.txt && cmds_whitelisted"
fresh; jset $P "d['params']['db_recovery_file_dest']=''; d['params']['log_archive_dest_1']=''; d['arch_mb_day']=4096; d['dg_names']=['DATA','FRANKLIN']"
rc=$(run $T/z117.txt --only 4.6 --check)
check "4.6: a disk group named FRANKLIN is not taken for the recovery area" "grep -q \"db_recovery_file_dest='+DATA'\" $T/z117.txt && grep -q 'no FRA or RECO disk group found' $T/z117.txt"
jset $P "d['dg_names']=['DATAC1','RECOC1']"
rc=$(run $T/z118.txt --only 4.6 --check)
check "4.6: the Exadata-style RECOC1 is taken for the recovery area" "grep -q \"db_recovery_file_dest='+RECOC1'\" $T/z118.txt"

fi
if part Z16; then  CUR=Z
# 5.16: ninth external review
fresh; jset $O "d['nft_ruleset']='table inet f {\n chain input {\n  type filter hook input priority 0; policy accept;\n  jump sub\n }\n chain sub {\n  tcp dport 1521 reject\n }\n}'"
rc=$(run $T/z120.txt --only 2.9)
check "2.9: a reject for the port in a chain the input chain jumps to -> shown" "grep -q 'tcp dport 1521 reject' $T/z120.txt"
fresh; jset $O "d['iptables_input']='-P INPUT ACCEPT\n-A INPUT -p tcp -j DROP'"
rc=$(run $T/z121.txt --only 2.9)
check "2.9: a drop of all TCP in INPUT -> shown" "grep -q -- '-A INPUT -p tcp -j DROP' $T/z121.txt"
fresh empty; rc=$(run $T/z122a.txt)
jset $S "d['asm_fail']=1"
rc=$(run $T/z122.txt --only 9.1)
check "9.1: the disk groups of this server cannot be read -> waiting, not OK" "grep -q 'disk groups of this server could not be read' $T/z122.txt && [[ \$(res 9.1 $T/z122.txt) == WAITS ]]"
jset $S "d['asm_fail']=0; d['instances']['PRODDB_STBY']['dg_errors']=2; d['instances']['PRODDB_STBY']['dg_err_last']='bad'"
rc=$(run $T/z123.txt --only 10.4)
check "10.4: the time of the newest error cannot be read -> cannot check, not OK" "grep -q 'Cannot read the time of the newest Data Guard error' $T/z123.txt && [[ \$(res 10.4 $T/z123.txt) != OK && \$(res 10.4 $T/z123.txt) != WAITS ]]"
fresh; jset $P "d['pwfile']=''; d['exists_fail']=['$T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB']"
rc=$(DG_TEST_QUIT_AT=6.2 run $T/z124.txt)
check "6.1: the primary does not answer whether its password file is there -> not called missing" "grep -q 'Cannot tell whether .*orapwPRODDB is on the primary' $T/z124.txt && ! grep -q 'The password file of the primary was not found' $T/z124.txt"

fi
if part Z17; then  CUR=Z
# 5.17: tenth external review
fresh; jset $P "d['tde_fail']=1; d['tde']=['FILE|$T/pwallet/|OPEN']"
rc=$(DG_TEST_QUIT_AT=7.1 run $T/z130.txt)
check "6.3: the wallet query of the primary fails -> not known, never 'does not use TDE'" "grep -q 'Whether it uses TDE is not known' $T/z130.txt && ! grep -q 'The primary does not use a TDE wallet' $T/z130.txt"
fresh empty; rc=$(run $T/z131a.txt)
printf "*.audit_file_dest='/u01/x/../../etc/aud'\n" >> $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(run $T/z131.txt --only 7.1)
check "7.1: an audit_file_dest with '..' -> a step by hand, nothing made" "grep -q 'audit_file_dest to an unusual path' $T/z131.txt && [[ \$(res 7.1 $T/z131.txt) != OK && \$(res 7.1 $T/z131.txt) != DONE ]] && [[ ! -e /etc/aud ]]"
ut_517() { bash <<EOF
source <(sed -n '/^local_fw_rules()/,/^}/p' $T/dg_standby_setup.sh)
PORT=1521 STANDBY_IP=10.1.1.5
ip() { echo "2: eth0    inet 10.1.1.5/24 brd x"; }
t() { NFT="\$1"; IPT="\$2"; nft() { printf '%s\n' "\$NFT"; }; iptables() { printf '%s\n' "\$IPT"; }; NOW=""; local_fw_rules; [[ -n "\$NOW" ]] && echo 1 || echo 0; }
a=\$(t "" \$'-P INPUT ACCEPT\n-A INPUT -d 10.1.1.5/32 -p tcp --dport 1521 -j DROP')
b=\$(t "" \$'-P INPUT ACCEPT\n-A INPUT -p tcp --dport 1521 -j ACCEPT')
c=\$(t "" \$'-P INPUT DROP')
d=\$(t \$'table inet f {\n chain input {\n  type filter hook input priority 0; policy accept;\n  ct state invalid drop\n }\n}' "-P INPUT ACCEPT")
echo "\$a\$b\$c\$d"
EOF
}
fresh; ut_517 > $T/ut_517.txt
check "unit: firewall note shows drop/reject rules and a drop policy, not accept rules or 'ct state invalid drop'" "[[ \$(cat $T/ut_517.txt) == 1010 ]]"

fi
if part Z18; then  CUR=Z
# 5.18: eleventh external review
fresh empty; rc=$(run $T/z140a.txt)
printf "*.audit_file_dest='/srv/dgt518/aud'\n" >> $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(run $T/z140.txt --only 7.1)
check "7.1: an audit folder under /srv (root's) -> a root step by hand, not refused, nothing made" "grep -q 'chown oracle:oinstall /srv/dgt518/aud' $T/z140.txt && ! grep -q 'must not be the audit folder' $T/z140.txt && [[ ! -e /srv/dgt518 ]]"
mkdir -p /srv/dgt518o && chown nobody /srv/dgt518o
sed -i "s|/srv/dgt518/aud|/srv/dgt518o/aud|" $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(run $T/z141.txt --only 7.1)
check "7.1: an audit folder under a folder of another user -> refused, the owner named" "grep -q 'under /srv/dgt518o, which belongs to nobody' $T/z141.txt && [[ ! -e /srv/dgt518o/aud ]]"
mkdir -p /srv/dgt518w && chmod 777 /srv/dgt518w
sed -i "s|/srv/dgt518o/aud|/srv/dgt518w/aud|" $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(run $T/z143.txt --only 7.1)
check "7.1: a parent folder others can write to -> the oracle user makes it, no root chown" "grep -q 'As oracle (not as root' $T/z143.txt && ! grep -q 'chown .*/srv/dgt518w' $T/z143.txt && [[ ! -e /srv/dgt518w/aud ]]"
sed -i "s|/srv/dgt518w/aud|/home/nosuchuser518/aud|" $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(run $T/z144.txt --only 7.1)
check "7.1: a folder under /home outside the oracle home (account not listed) -> refused" "grep -q 'under /home, outside the home folder' $T/z144.txt"
rm -rf /srv/dgt518o /srv/dgt518 /srv/dgt518w
ln -sfn "/srv/q 518" $T/lnk518
sed -i "s|/home/nosuchuser518/aud|$T/lnk518/aud|" $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRODDB_STBY.ora
rc=$(run $T/z145.txt --only 7.1)
check "7.1: a link leads to a path with a space -> refused, no root command shown" "grep -q 'leads, through links, to an unusual path' $T/z145.txt && ! grep -q '^ *chown ' $T/z145.txt && ! grep -q '^ *mkdir -p /srv/q' $T/z145.txt"
rm -f $T/lnk518
fresh empty; rc=$(run $T/z142a.txt)
jset $S "d['srvctl']['dg']='DATA,FRA,GONE'"
rc=$(run $T/z142.txt --only 9.1)
check "9.1: OK still names a registered disk group ASM here does not see" "grep -q 'it still names disk group(s) ASM here does not see: GONE' $T/z142.txt"
ut_518() { bash <<EOF
source <(sed -n '/^srv_add()/,/^}/p' $T/dg_standby_setup.sh)
srv_new_args() { :; }; bad() { echo "BAD \$*"; }; warn() { :; }; say() { :; }; ran=0
srv_shown_add() { SRV_ADD_IDX=0; }; cp_exec() { ran=1; return 0; }
SRV_DG_UNREAD="DATA,FRA" SRV_DG_LOST="" STANDBY_UNIQUE=x; SRV_KEPT=()
srv_add "saved config" >/dev/null; a=\$?; a="\$a\$ran"
ran=0; SRV_DG_UNREAD=""; srv_add "saved config" >/dev/null 2>&1; b="\$ran"
echo "\$a \$b"
EOF
}
fresh; ut_518 > $T/ut_518.txt
check "unit: no new registration while the disk groups cannot be read; added when they can" "[[ \$(cat $T/ut_518.txt) == '10 1' ]]"

ut_518b() { bash <<EOF
source <(sed -n '/^root_holds()/,/^}/p; /^make_dir()/,/^}/p' $T/dg_standby_setup.sh)
INSTALL_GROUP=oinstall; say() { :; }; journal() { :; }; bad() { echo "BAD \$*"; }; warn() { :; }
dir_empty() { [[ -z "\$(ls -A -- "\$1")" ]]; }
rm -rf $T/md518; mkdir -p $T/md518/o; chown oracle:oinstall $T/md518/o; chmod 755 $T/md518/o
make_dir $T/md518/o/a/b oracle >/dev/null; a=\$(stat -c '%U:%G' $T/md518/o/a/b 2>/dev/null)
make_dir $T/md518/o/g/h grid > $T/md518.out; [[ -e $T/md518/o/g ]] && b=made || b=none
grep -q 'cannot be made by grid' $T/md518.out && c=said || c=silent
mkdir -p $T/md518/r; make_dir $T/md518/r/x oracle >/dev/null; d=\$(stat -c '%U' $T/md518/r/x)
rm -rf $T/md518; echo "\$a \$b \$c \$d"
EOF
}
fresh; ut_518b > $T/ut_518b.txt
check "unit: below a folder another user owns, folders are made as their owner (never by root); one the owner cannot make is said, nothing made" "[[ \$(cat $T/ut_518b.txt) == 'oracle:oinstall none said oracle' ]]"
fi
if part Z19; then  CUR=Z
# final audit
fresh empty; rc=$(run $T/z150a.txt)
jset $S "d['instances']['PRODDB_STBY']['no_ms']=1"
rc=$(run $T/z150.txt --only 9.4)
check "9.4: no v\$managed_standby (newer release) -> v\$dataguard_process is used, apply seen" "[[ \$(res 9.4 $T/z150.txt) == OK ]] && ! grep -q 'ORA-00942' $T/z150.txt"
jset $S "d['instances']['PRODDB_STBY']['mrp']=0"
rc=$(run $T/z151.txt --only 9.4 --check)
check "9.4: no v\$managed_standby and no MRP -> not OK" "[[ \$(res 9.4 $T/z151.txt) != OK ]]"
fi
if part Z20; then  CUR=Z
# 5.20: new checks 10.5 and 10.6, --health, --roll-forward, section size
fresh empty; rc=$(run $T/z200.txt)
check "phase 10: NOLOGGING (10.5) and patch level (10.6) OK; the switchover readiness command is shown" "[[ \$(res 10.5 $T/z200.txt) == OK && \$(res 10.6 $T/z200.txt) == OK ]] && grep -q 'alter database switchover to PRODDB_STBY verify;' $T/z200.txt"
check "copy of a small database: no section size; channels on the primary = auxiliary channels (PRIMARY_CHANNELS empty)" "ls $T/log/duplicate_*.rman >/dev/null && ! grep -q 'section size' $T/log/duplicate_*.rman && [[ \$(cat $T/log/duplicate_*.rman | grep -c 'allocate channel p') -ge 1 && \$(cat $T/log/duplicate_*.rman | grep -c 'allocate channel p') -eq \$(cat $T/log/duplicate_*.rman | grep -c 'allocate auxiliary channel a') ]]"
jset $P "d['root_key']=1"
rc=$(run $T/z201.txt --health)
check "--health, all well: exit 0, one line per check, a log readable by root only (640)" "[[ $rc == 0 ]] && grep -q 'Result: OK (exit 0)' $T/z201.txt && [[ \$(grep -cE '^  OK +10\.[1-6] ' $T/z201.txt) == 6 ]] && [[ \$(stat -c %a $T/log/health_*.log | sort -u) == 640 ]]"
check "--health asks nothing and opens no password connection" "! grep -q '\\[y\\]\\|password of' $T/z201.txt && grep -q 'master opened by .* with a key' $T/state/primary_cmds.log"
jset $P "d['root_key']=0"
rc=$(run $T/z202.txt --health)
check "--health without an ssh key: OK from the standby side, the primary checks SKIPPED (not UNKNOWN) with a note naming step 9.9" "[[ $rc == 0 ]] && grep -qE '^OK - ' $T/z202.txt && grep -qE '^  OK +10\.1 ' $T/z202.txt && grep -qE '^  OK +10\.3 ' $T/z202.txt && grep -qE '^  SKIPPED +10\.6 ' $T/z202.txt && grep -q 'primary not checked: no ssh key for root' $T/z202.txt && grep -q 'only 9.9' $T/z202.txt"
jset $P "d['root_key']=1"
jset $S "d['instances']['PRODDB_STBY']['dg_stats']='+00 00:00:00|+00 00:00:01|900'"
rc=$(run $T/z203.txt --health)
check "--health: lag 0 but no data from the primary for 15 minutes -> CRITICAL (exit 2)" "[[ $rc == 2 ]] && grep -qE '^  CRITICAL +10\.1 .*No data from the primary for 900 seconds' $T/z203.txt"
jset $S "d['instances']['PRODDB_STBY']['dg_stats']='+00 00:10:00|+00 00:10:00|5'"
jset $P "d['dest_err']='2|ERROR|ORA-16191: Primary log shipping client not logged on standby'"
rc=$(run $T/z204.txt --health)
check "--health: lag too high -> the primary's destination error and its usual cause are in the log" "[[ $rc == 2 ]] && grep -q 'log_archive_dest_2 for this standby: ERROR, error: ORA-16191' \$(ls -t $T/log/health_*.log | head -1) && grep -q 'password file differs' \$(ls -t $T/log/health_*.log | head -1)"
jset $P "del d['dest_err']"
jset $S "d['instances']['PRODDB_STBY']['dg_stats']='+00 00:00:00|+00 00:00:01|5'"
jset $S "d['instances']['PRODDB_STBY']['nonlogged']='2 64'"
rc=$(run $T/z205.txt --health)
check "--health: nonlogged blocks -> CRITICAL, the RMAN repair in the log" "[[ $rc == 2 ]] && grep -qE '^  CRITICAL +10\.5 ' $T/z205.txt && grep -q 'recover database nonlogged block' \$(ls -t $T/log/health_*.log | head -1)"
jset $S "d['instances']['PRODDB_STBY']['nonlogged']='0 0'"
jset $P "d['force_logging_now']='NO'"
rc=$(run $T/z206.txt --health)
check "--health: force logging off at the primary -> WARNING (exit 1)" "[[ $rc == 1 ]] && grep -qE '^  WARNING +10\.5 .*force logging is off' $T/z206.txt"
jset $P "d['force_logging_now']='STANDBY NOLOGGING FOR DATA AVAILABILITY'"
rc=$(run $T/z207.txt --health)
check "--health: STANDBY NOLOGGING (set on purpose, 18c+) is no warning" "[[ $rc == 0 ]] && grep -qE '^  OK +10\.5 .*set on purpose' $T/z207.txt"
jset $P "del d['force_logging_now']"
mkdir -p $T/u01/app/oracle/product/19.0.0/dbhome_1/inventory/oneoffs/36000001
rc=$(run $T/z208.txt --health)
check "--health: a patch only on the standby -> WARNING with its number" "[[ $rc == 1 ]] && grep -qE '^  WARNING +10\.6 ' $T/z208.txt && grep -q 'only here: 36000001' \$(ls -t $T/log/health_*.log | head -1)"
rm -rf $T/u01/app/oracle/product/19.0.0/dbhome_1/inventory/oneoffs/36000001
jset $S "d['instances']['PRODDB_STBY']['state']='idle'"
rc=$(run $T/z209.txt --health)
check "--health: standby instance down -> CRITICAL at once, no other check" "[[ $rc == 2 ]] && grep -q 'Standby instance: not running' $T/z209.txt && ! grep -qE '^  [A-Z]+ +10\.' $T/z209.txt"
jset $S "d['instances']['PRODDB_STBY']['state']='mounted'"
jset $S "d['instances']['PRODDB_STBY']['dg_stats_seq']=['+00 00:10:00|+00 00:10:00|5','+00 00:00:00|+00 00:00:01|5']"
rc=$(run $T/z209b.txt --health)
check "--health: a lag peak that is gone 60 seconds later -> checked once more, OK" "[[ $rc == 0 ]] && grep -q 'checked once more in 60 seconds: 10.1' \$(ls -t $T/log/health_*.log | head -1)"
jset $S "del d['instances']['PRODDB_STBY']['dg_stats_seq']"
jset $S "d['instances']['PRODDB_STBY']['dg_stats']='+00 00:10:00|+00 00:10:00|5'"
sed -i 's/^HEALTH_LAG_MAX=.*/HEALTH_LAG_MAX=900/' $T/varlib/settings.conf
rc=$(run $T/z209c.txt --health)
check "--health: HEALTH_LAG_MAX=900 accepts a lag of 10 minutes" "[[ $rc == 0 ]]"
sed -i 's/^HEALTH_LAG_MAX=.*/HEALTH_LAG_MAX=/' $T/varlib/settings.conf
jset $S "d['instances']['PRODDB_STBY']['dg_stats']='+00 00:00:00|+00 00:00:01|5'"
rc=$(run $T/z210.txt --health --check); rc2=$(run $T/z211.txt --health --bogus)
check "--health with another option, or a wrong one: exit 3 (unknown), never 2 (critical)" "[[ $rc == 3 && $rc2 == 3 ]]"
( flock $T/varlib/lock -c 'sleep 8' ) & lp=$!; sleep 1
rc=$(run $T/z212.txt --health); wait $lp
check "--health while a setup run holds the lock -> UNKNOWN, nothing checked" "[[ $rc == 3 ]] && grep -q 'Another run of this script' $T/z212.txt"
setsid bash -c "echo \$\$ > $T/jp.pid; exec sleep 30" & sleep 1; jp=$(cat $T/jp.pid)
printf '%s|RMAN roll forward|%s|||%s|10.7\n' "$jp" "$T/log/rf_x.log" "$(cat /proc/sys/kernel/random/boot_id)" > $T/varlib/job
rc=$(run $T/z213.txt --health); kill $jp 2>/dev/null; rm -f $T/varlib/job $T/jp.pid
check "--health while a long job runs (maintenance) -> UNKNOWN" "[[ $rc == 3 ]] && grep -q 'Maintenance is running: RMAN roll forward' $T/z213.txt"
printf '%s|0\n' "$T/log/x.log" > $T/varlib/rollforward_pending
rc=$(run $T/z213b.txt --health); rm -f $T/varlib/rollforward_pending
check "--health: a roll forward that ended but is not finished -> CRITICAL, --roll-forward named" "[[ $rc == 2 ]] && grep -qE '^  CRITICAL +10\.7 .*--roll-forward' $T/z213b.txt"
jset $S "d['instances']['PRODDB_STBY']['gap_rows']=['1 30-35']"
jset $P "d['gap_have']=2"
rc=$(run $T/z214.txt --only 10 --check)
check "10.2: a gap whose logs are gone from the primary -> restore them there, or --roll-forward" "grep -q 'no longer on the disk of the primary' $T/z214.txt && grep -q 'thread 1, sequence 30 to 35' $T/z214.txt && grep -q -- '--roll-forward' $T/z214.txt"
jset $P "del d['gap_have']"
rc=$(run $T/z214b.txt --only 10 --check)
check "10.2: a gap whose logs are still on the primary -> no word of lost logs (fal_server sends them)" "grep -q 'Archive gap' $T/z214b.txt && ! grep -q 'no longer on the disk' $T/z214b.txt"
jset $S "d['instances']['PRODDB_STBY']['gap_rows']=[]"
rc=$(DG_TEST_PSYS=10.7 run $T/z215.txt --roll-forward)
check "--roll-forward: checks pass (OMF names), RMAN rolls forward once, redo apply runs again" "[[ \$(res 10.7 $T/z215.txt) == DONE ]] && [[ \$(grep -c 'rman rollforward' $T/state/calls.log) == 1 ]] && [[ \$(res 10.4 $T/z215.txt) == OK ]] && grep -q 'Redo apply stopped' $T/z215.txt"
check "--roll-forward: the sys password is in no log or file" "! grep -rq 'Welcome_123' $T/log $T/varlib"
check "--roll-forward afterwards: standby redo log entries of the primary dropped and added again, catalog/crosscheck, deletion policy set again" "grep -q 'rman crosscheck' $T/state/calls.log && python3 -c \"import json,sys; d=json.load(open('$S')); i=d['instances']['PRODDB_STBY']; sys.exit(0 if i.get('dropped') and i.get('srl',0)>0 and d.get('rman_adp')=='TO APPLIED ON STANDBY' else 1)\""
check "--roll-forward afterwards: journal entries of 9.3/9.8/9.4 under their own steps (an undo of 10.7 does not stop apply)" "! awk -F'|' '\$4==\"10.7\" && \$5!=\"ROLLFWD\"' $T/varlib/changes.log | grep -q ."
rc=$(run $T/z215b.txt --from 10.7); rc2=$(run $T/z215c.txt --only 10.7)
check "--from 10.7 / --only 10.7: refused, --roll-forward named" "[[ $rc == 2 && $rc2 == 2 ]] && grep -q 'runs only with --roll-forward' $T/z215b.txt"
jset $S "d['instances']['PRODDB_STBY']['rman_sessions']=1"
rc=$(DG_TEST_PSYS=10.7 run $T/z215d.txt --roll-forward)
check "--roll-forward: another RMAN session on the standby -> not started" "grep -q 'An RMAN session is connected' $T/z215d.txt && [[ \$(grep -c 'rman rollforward' $T/state/calls.log) == 1 ]]"
jset $S "d['instances']['PRODDB_STBY']['rman_sessions']=0"
# a roll forward that ended while no run watched (terminal closed): checked and finished by the next run, RMAN not again
printf 'Starting recover\nFinished recover\n' > $T/log/rollforward_old.log; printf '0\n' > $T/log/rollforward_old.log.rc
printf '%s|\n' "$T/log/rollforward_old.log" > $T/varlib/rollforward_pending
printf '%s|RMAN roll forward|%s|||%s|10.7\n' "999999" "$T/log/rollforward_old.log" "$(cat /proc/sys/kernel/random/boot_id)" > $T/varlib/job
jset $S "d['instances']['PRODDB_STBY']['mrp']=0"
rc=$(DG_TEST_PSYS=10.7 run $T/z215e.txt --roll-forward)
check "a roll forward that ended unwatched: next --roll-forward checks it, finishes the clean-up, starts apply, no new RMAN run" "grep -q 'has ended without error' $T/z215e.txt && [[ \$(res 10.7 $T/z215e.txt) == DONE && \$(res 10.4 $T/z215e.txt) == OK ]] && [[ \$(grep -c 'rman rollforward' $T/state/calls.log) == 1 ]] && [[ ! -e $T/varlib/rollforward_pending ]]"
jset $S "d['instances']['PRODDB_STBY']['cfd']='-'"
rc=$(DG_TEST_PSYS=10.7 run $T/z216.txt --roll-forward)
check "--roll-forward: other file names, no convert, no OMF -> refused, RMAN not started" "grep -q 'neither db_file_name_convert nor' $T/z216.txt && [[ \$(grep -c 'rman rollforward' $T/state/calls.log) == 1 ]]"
jset $S "d['instances']['PRODDB_STBY']['cfd']='+DATA'"
jset $S "d['instances']['PRODDB_STBY']['broker']='TRUE'"
rc=$(DG_TEST_PSYS=10.7 run $T/z217.txt --roll-forward)
check "--roll-forward: the broker runs on the standby -> refused, the dgmgrl way is shown" "grep -q \"set state='APPLY-OFF'\" $T/z217.txt && [[ \$(grep -c 'rman rollforward' $T/state/calls.log) == 1 ]]"
jset $S "d['instances']['PRODDB_STBY']['broker']='FALSE'"
jset $T/state/env.json "d['rf_fail']=1"
rc=$(DG_TEST_PSYS=10.7 run $T/z218.txt --roll-forward)
check "--roll-forward: RMAN fails -> step failed, the output named, apply not started again by the script" "grep -q 'The roll forward did not finish' $T/z218.txt && [[ \$(res 10.7 $T/z218.txt) != DONE && \$(res 10.4 $T/z218.txt) != OK ]]"
jset $T/state/env.json "d['rf_fail']=0"
rc=$(run $T/z219.txt --roll-forward --check)
check "--roll-forward with --check: refused (exit 2)" "[[ $rc == 2 ]] && grep -q 'cannot be combined' $T/z219.txt"
fresh empty
rc=$(run $T/z222.txt --health)
check "--health before any setup: UNKNOWN (exit 3), says why" "[[ $rc == 3 ]] && grep -q 'No settings yet' $T/z222.txt"
ut_520() { bash <<EOF
SELF=x PORT=1521
source <(sed -n '/^dg_error_hint()/,/^}/p' $T/dg_standby_setup.sh)
a=\$(dg_error_hint "ORA-16191 and ORA-01017 then ORA-28374, ORA-99999")
printf '%s\n' "\$a" | wc -l
printf '%s\n' "\$a" | grep -c 'password file differs'
printf '%s\n' "\$a" | grep -c 'TDE wallet'
EOF
}
ut_520 > $T/ut_520.txt
check "unit: error hints - one line per cause, unknown codes give nothing" "[[ \$(tr '\n' ' ' < $T/ut_520.txt) == '2 1 1 ' ]]"
fresh empty; jset $P "d['max_df_mb']=70000"
rc=$(run $T/z220.txt)
check "copy with a datafile of 64 GB or more: section size 32G and one channel on the primary" "grep -q 'section size 32G' $T/log/duplicate_*.rman && grep -q 'allocate channel p1 device type disk' $T/log/duplicate_*.rman && grep -q 'copied in sections of 32G' $T/z220.txt"
fresh empty; jset $P "d['max_df_mb']=70000"
rc=$(run $T/z221a.txt --only 1); sed -i 's/^DUP_SECTION_SIZE=.*/DUP_SECTION_SIZE=0/' $T/varlib/settings.conf
rc=$(run $T/z221.txt)
check "DUP_SECTION_SIZE=0: no section size even for a big datafile" "ls $T/log/duplicate_*.rman >/dev/null && ! grep -q 'section size' $T/log/duplicate_*.rman"
fi
if part Z21; then  CUR=Z
# 5.21: findings of the review of 5.20
ut_521() { bash <<EOF
ORACLE_USER=oracle GRID_USER=grid INSTALL_GROUP=oinstall PORT=1521 PRIMARY_IP=10.0.0.1 STANDBY_IP=10.0.0.2
bad() { :; }; warn() { :; }; say() { :; }; _log() { :; }
source <(sed -n '/^rf_wallet_bad()/,/^}/p; /^rf_convert_ok()/,/^}/p; /^srv_notfound()/,/^}/p; /^local_patches()/,/^}/p; /^local_fw_rules()/,/^}/p; /^root_prog_path_ok()/,/^}/p' $T/dg_standby_setup.sh)
printf '1|AUTOLOGIN|OPEN|NONE\n3|UNKNOWN|OPEN|UNITED\n' | rf_wallet_bad | grep -c . || true
printf '1|AUTOLOGIN|OPEN|NONE\n3|PASSWORD|OPEN|ISOLATED\n' | rf_wallet_bad | grep -c 'isolated' || true
printf '1|PASSWORD|CLOSED|NONE\n3|AUTOLOGIN|OPEN|UNITED\n' | rf_wallet_bad | grep -c '^B|root container' || true
printf '' | rf_wallet_bad | grep -c 'no row for the root' || true
printf '1|AUTOLOGIN|OPEN_UNKNOWN_MASTER_KEY_STATUS|NONE\n3|AUTOLOGIN|OPEN_UNKNOWN_MASTER_KEY_STATUS|UNITED\n' | rf_wallet_bad | grep -c . || true
printf '1|HSM|CLOSED|NONE\n1|AUTOLOGIN|OPEN|NONE\n4|AUTOLOGIN|CLOSED|ISOLATED\n' | rf_wallet_bad | tr '\n' ' '; echo
RUN_OUT="PRCR-0000: /u01/app/oracle/admin/proddb_stby/x does not exist"; srv_notfound proddb_stby && echo nf4
nft() { printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy drop;\n  ip saddr 10.9.9.9 tcp dport 1521 accept\n }\n}\n'; }
NOW=""; local_fw_rules; [[ -n "\$NOW" ]] && echo fw_limited_noted
nft() { printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy drop;\n  tcp dport 22 counter packets 1521 bytes 9 accept\n }\n}\n'; }
NOW=""; local_fw_rules; [[ -n "\$NOW" ]] && echo fw_counter_noted
nft() { printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy accept;\n  drop\n  tcp dport 1521 accept\n }\n}\n'; }
NOW=""; local_fw_rules; [[ -n "\$NOW" ]] && echo fw_order_noted
S=\$'1|/u02/stby/system01.dbf\n2|/u02/stby/users01.dbf\n3|/u03/other/x.dbf'
P=\$'1|/u01/prim/system01.dbf\n2|/u01/prim/users01.dbf\n3|/u03/other/x.dbf'
rf_convert_ok "/u01/prim/, /u02/stby/" "\$S" "\$P" && echo conv_ok || echo "conv_bad \$RF_CONV_BAD"
rf_convert_ok "'/u01/prim/','/u09/wrong/'" "\$S" "\$P" && echo conv_ok || echo conv_bad
rf_convert_ok "/u07/x/, /u08/y/" "\$S" "\$P" && echo conv_ok || echo conv_bad
rf_convert_ok "/u01/prim/" "\$S" "\$P" && echo conv_ok || echo conv_bad
RUN_OUT="PRCD-1120 : The resource for database proddb_stby could not be found."; srv_notfound proddb_stby && echo nf1
RUN_OUT="CRS-4639: Could not contact Oracle High Availability Services; /u01/x/ohasd.pid does not exist"; srv_notfound proddb_stby && echo nf2
RUN_OUT="Database PRODDB_STBY does not exist"; srv_notfound proddb_stby && echo nf3
mkdir -p $T/ph/inventory/oneoffs/12345 $T/ph/inventory/oneoffs/36000001
local_patches $T/ph | paste -sd' ' -
ls() { return 2; }; local_patches $T/ph >/dev/null && echo lp_ok || echo lp_fail; unset -f ls
local_patches $T/nohome && echo lp_none
nft() { printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy drop;\n  tcp dport 1521 accept\n }\n}\n'; }; iptables() { :; }
NOW=""; local_fw_rules; [[ -z "\$NOW" ]] && echo fw_quiet
nft() { printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy accept;\n  ip saddr 1.1.1.1 drop\n  ip saddr 2.2.2.2 drop\n  ip saddr 3.3.3.3 drop\n  tcp dport { 22, 1521 } reject\n }\n}\n'; }
NOW=""; local_fw_rules; grep -A1 'for example' <<< "\$NOW" | tail -n 1 | grep -q 'dport { 22, 1521 } reject' && echo fw_port_first
mkdir -p $T/rp/ww/home/bin; chmod 777 $T/rp/ww; chmod 755 $T/rp/ww/home $T/rp/ww/home/bin
root_prog_path_ok $T/rp/ww/home/bin && echo rp_ok || echo rp_refused
chmod 755 $T/rp/ww; root_prog_path_ok $T/rp/ww/home/bin && echo rp_ok2 || echo rp_refused2
EOF
}
ut_521 > $T/ut_521.txt 2>&1
check "unit: wallets - united PDB follows the root, a password wallet refused, no rows refused, open in MOUNT accepted" "[[ \$(sed -n 1,5p $T/ut_521.txt | tr '\n' ' ') == '0 1 1 1 0 ' ]]"
check "unit: wallets - HSM plus an auto-login file wallet is fine; an isolated closed one cannot be judged in MOUNT" "[[ \$(sed -n 6p $T/ut_521.txt) == 'U|container 4: AUTOLOGIN, CLOSED (isolated wallet) ' ]]"
check "unit: srvctl - a path that only contains the name is no 'not registered'; firewall - an accept for one source still noted" "! grep -qx nf4 $T/ut_521.txt && grep -qx fw_limited_noted $T/ut_521.txt && grep -qx fw_counter_noted $T/ut_521.txt && grep -qx fw_order_noted $T/ut_521.txt"
check "unit: db_file_name_convert must give every standby name" "sed -n 10,13p $T/ut_521.txt | tr '\n' ' ' | grep -qx 'conv_ok conv_bad conv_bad conv_bad '"
check "unit: srvctl not registered - own codes or the name; another 'does not exist' is no such answer" "grep -qx nf1 $T/ut_521.txt && ! grep -qx nf2 $T/ut_521.txt && grep -qx nf3 $T/ut_521.txt"
check "unit: patches - 5-digit ids read, an unlistable folder fails, no folder is no patch" "grep -qx '12345 36000001' $T/ut_521.txt && grep -qx lp_fail $T/ut_521.txt && grep -qx lp_none $T/ut_521.txt"
check "unit: firewall note - quiet when the port is accepted, a drop of the port shown first" "grep -qx fw_quiet $T/ut_521.txt && grep -qx fw_port_first $T/ut_521.txt"
check "unit: a world-writable folder above a root-run program is refused" "grep -qx rp_refused $T/ut_521.txt && grep -qx rp_ok2 $T/ut_521.txt"
fresh empty; rc=$(run $T/z300.txt)
jset $P "d['root_key']=1"
jset $S "d['instances']['PRODDB_STBY']['gap_rows']=['1 30-35','2 40-41']"
jset $P "d['gap_have']=2"
rc=$(run $T/z301.txt --only 10 --check)
check "10.2: restore lines only for the gap whose logs are gone (thread 2 is still on the primary)" "grep -q 'restore archivelog from sequence 30 until sequence 35 thread 1;' $T/z301.txt && ! grep -q 'thread 2;' $T/z301.txt"
jset $P "del d['gap_have']"
jset $S "d['instances']['PRODDB_STBY']['gap_rows']=[]"
jset $T/state/env.json "d['local_version']='12.1.0.2.0'"
rc=$(run $T/z302.txt --health)
check "--health on a 12.1 standby: 10.5 is OK from force logging (no v\$nonlogged_block query, no UNKNOWN)" "grep -qE '^  OK +10\.5 .*12\.1 keeps no list' $T/z302.txt && ! grep -q 'nonlogged_block' \$(ls -t $T/log/health_*.log | head -1)"
jset $T/state/env.json "d['local_version']='19.21.0.0.0'"
jset $S "d['instances']['PRODDB_STBY']['version_fail']=1"
rc=$(run $T/z302b.txt --health)
check "--health: standby release unreadable -> 10.5 still decided by the view itself" "grep -qE '^  OK +10\.5 ' $T/z302b.txt"
jset $S "d['instances']['PRODDB_STBY']['version_fail']=0"
jset $S "d['instances']['PRODDB_STBY']['sfiles']=['1|/u02/stby/system01.dbf','2|/u02/stby/users01.dbf']; d['instances']['PRODDB_STBY']['cfd']='-'; d['instances']['PRODDB_STBY']['dfnc']='/u01/x/, /u02/y/'"
rc=$(DG_TEST_PSYS=10.7 run $T/z303.txt --roll-forward)
check "--roll-forward: a db_file_name_convert that does not map the files -> refused, the file named, RMAN not run" "grep -q 'db_file_name_convert does not fit: file 1' $T/z303.txt && [[ \$(grep -c 'rman rollforward' $T/state/calls.log 2>/dev/null || true) == 0 ]]"
jset $S "del d['instances']['PRODDB_STBY']['sfiles']; d['instances']['PRODDB_STBY']['cfd']='+DATA'; d['instances']['PRODDB_STBY']['dfnc']='-'"
rc=$(DG_TEST_PW1=Other_456 DG_TEST_PSYS=10.7 run $T/z304.txt --roll-forward)
check "--roll-forward: a wrong sys password -> typed again in the same run ([p]), then the roll forward runs once" "grep -q '\[p\] Type the sys password' $T/z304.txt && [[ \$(res 10.7 $T/z304.txt) == DONE ]] && [[ \$(grep -c 'rman rollforward' $T/state/calls.log) == 1 ]]"
jset $S "d['instances']['PRODDB_STBY']['flashback']='YES'"
printf 'Starting recover\nFinished recover\n' > $T/log/rollforward_old.log; printf '0\n' > $T/log/rollforward_old.log.rc
printf '%s|0\n' "$T/log/rollforward_old.log" > $T/varlib/rollforward_pending; : > $T/state/calls.log
rc=$(DG_TEST_RF=n DG_TEST_PSYS=10.7 run $T/z305.txt --roll-forward)
check "a roll forward that ended unwatched: finishing it asks ROLLFORWARD; n changes nothing" "grep -q 'Finish the roll forward of the earlier run' $T/z305.txt && [[ -e $T/varlib/rollforward_pending ]] && ! grep -q 'rman crosscheck' $T/state/calls.log 2>/dev/null"
check "... and the flashback reminder is shown on that path too" "grep -q 'Flashback database is on here' $T/z305.txt"
rc=$(DG_TEST_PSYS=10.7 run $T/z305b.txt --roll-forward)
check "... finished when ROLLFORWARD is typed; the flashback note is in the result" "[[ \$(res 10.7 $T/z305b.txt) == DONE ]] && grep -q 'Flashback database: turn it off and on again' $T/z305b.txt && [[ ! -e $T/varlib/rollforward_pending ]]"
jset $S "d['instances']['PRODDB_STBY']['flashback']='NO'"
fi
if part 5.22; then
CUR=5.22; echo "== 5.22  Screen layout, the Grid install check before root.sh"
G=$(mktemp); sed -n '/^ui_fold()/,/^}/p;/^ui_spaces()/p;/^warn()/,/^}/p' $T/dg_standby_setup.sh > "$G"
out=$( _log() { :; }; source "$G"; UI=0; UI_COLS=40; WARN_LIST=(); WARN_COUNT=0; CUR_STEP=3.2; C_Y=""; C_N=""; S_WARN='!'
  printf '    Plan     one two three four five six seven eight nine ten\n' | ui_fold "             "
  warn "same text"; warn "same text"; WARN_DEDUP=0 warn "same text" )
rm -f "$G"
check "screen: a long line is wrapped at a space, its spacing kept, the rest indented" "[[ \$(sed -n 1p <<< \"\$out\") == '    Plan     one two three four five' && \$(sed -n 2p <<< \"\$out\") == '             six seven eight nine ten' ]]"
check "a warning is shown once per step, but 'finished with warnings' of each installer run every time" "[[ \$(grep -c 'same text' <<< \"\$out\") == 2 ]]"
SN=/tmp/dgt_snaps; rm -rf $SN
# a full setup with the screen layout (100 x 30): the map, the step area, the list, the details, the help
fresh empty
# (48 rows: step 3.2 shows its job command lines and the response file; on a smaller screen the step is cut and d shows all of it)
rc=$(DG_TEST_UI=1 DG_TEST_SIZE=48x100 DG_TEST_SNAPDIR=$SN/a DG_TEST_SNAP=3.2,4.1 DG_TEST_KEYS=3.2:l,3.2:d,3.2:h DG_TEST_TIMEOUT=500 run $T/z500.txt)
check "screen: a full setup runs to the end in the screen layout" "[[ $rc -eq 0 ]] && grep -q 'Standby setup is complete' $SN/a/*_end.txt"
check "screen: the map on top (every phase, done/total, totals, keys; 2.7 waits for the primary visit), the step below with this phase so far" "grep -qE 'Data Guard standby setup [0-9]+\.[0-9]+ ' $SN/a/*_step_3.2.txt && grep -qE '! +2 This server +15/16' $SN/a/*_step_3.2.txt && grep -qE '▶ +3 Software +1/11' $SN/a/*_step_3.2.txt && grep -q 'need attention' $SN/a/*_step_3.2.txt && grep -q 'l: all steps   d: details   h: help' $SN/a/*_step_3.2.txt && grep -qE '✔ 3.1 +Installer files +done' $SN/a/*_step_3.2.txt && grep -q '  Step 3.2  Grid Infrastructure' $SN/a/*_step_3.2.txt"
check "screen: the next phase starts on a clean area (phase 3 done, 4 is current)" "grep -qE '✔ +3 Software +11/11' $SN/a/*_step_4.1.txt && grep -qE '▶ +4 Primary' $SN/a/*_step_4.1.txt && ! grep -q 'Step 3\.' $SN/a/*_step_4.1.txt"
check "screen: l lists every step on a separate screen, opened at the current phase (a step number for its details)" "grep -q 'Phase 3  Install the Oracle software   1 of 11 done' $SN/a/*_alt_3.2_l.txt && grep -qE '▶ 3.2 +Grid Infrastructure software' $SN/a/*_alt_3.2_l.txt && grep -q 'a step number: its details' $SN/a/*_alt_3.2_l.txt"
check "screen: d shows the details of the current step (from the log), h its help, both on a separate screen" "grep -q 'Result   in progress (the current step)' $SN/a/*_alt_3.2_d.txt && grep -q 'status Grid is not installed yet' $SN/a/*_alt_3.2_d.txt && grep -q 'Help  ·  step 3.2' $SN/a/*_alt_3.2_h.txt && grep -q 'Where' $SN/a/*_alt_3.2_h.txt"
check "screen: the installer output is not on the screen (in its file only), its result is" "! grep -q 'Successfully Setup Software' $T/z500.txt && grep -q 'Grid installer finished' $T/z500.txt && grep -q 'Successfully Setup Software' $T/log/Grid_installer_*.log"
# a failed install and "try again" in an 80 x 24 terminal: attempt 2 starts on a clean area
# (3.2 fails here because the two ASM passwords typed differ; a prerequisite failure has its own [r]/[i] question)
fresh empty
rc=$(DG_TEST_UI=1 DG_TEST_SIZE=24x80 DG_TEST_SNAPDIR=$SN/b DG_TEST_SNAP=3.2#9 DG_TEST_ASMPW2=Other_999x DG_TEST_RETRY=3.2 DG_TEST_QUIT_AT=3.3 DG_TEST_TIMEOUT=400 run $T/z501.txt)
check "screen: try again -> 'attempt 2' on a clean area (the earlier attempt is not mixed in), short keys in 80 columns" "grep -q 'Step 3.2  Grid Infrastructure software (Oracle Restart)   attempt 2' $SN/b/*_try9.txt && ! grep -q 'Grid installer failed' $SN/b/*_try9.txt && grep -q 'l: steps  d: details  h: help' $SN/b/*_try9.txt"
# a long job: one live line; d shows its output so far; an install with warnings (exit code 6) before root.sh
fresh empty; jset $S "d['installer_sleep']=4; d['grid_warn']=1"
rc=$(DG_TEST_UI=1 DG_TEST_SIZE=30x100 DG_TEST_SNAPDIR=$SN/c DG_TEST_SNAP=3.3 DG_TEST_JOBKEYS="Grid installer:d" DG_TEST_QUIT_AT=3.4 DG_TEST_TIMEOUT=400 run $T/z502.txt)
check "screen: a long job shows one live line (time, keys), d opens its output so far" "grep -q 'Grid installer   running, ' $T/z502.txt && ls $SN/c/*_alt_job_output.txt >/dev/null 2>&1"
check "3.2: an installer that ends with warnings (exit 6) before root.sh -> done, the warning under it; 3.3 runs root.sh" "grep -qE '✔ 3.2 +Grid Infrastructure software… +done' $SN/c/*_step_3.3.txt && grep -q '! Grid installer finished with warnings' $SN/c/*_step_3.3.txt && grep -q 'Its root scripts have not run yet' $SN/c/*_step_3.3.txt"
check "3.2: bin/crsctl does not exist before root.sh (as in a real home), and is there after it" "[[ \$(res 3.3 $T/z502.txt) == DONE && -x \$(ls -d $T/u01/app/*/grid | head -n 1)/bin/crsctl ]] && ! grep -q 'cannot confirm the installation' $T/z502.txt"
# plain output: a small terminal, and --plain
fresh empty
rc=$(DG_TEST_UI=1 DG_TEST_SIZE=20x70 DG_TEST_SNAPDIR=$SN/d DG_TEST_QUIT_AT=2.1 run $T/z503.txt)
rc=$(DG_TEST_UI=1 DG_TEST_SIZE=30x100 DG_TEST_SNAPDIR=$SN/e DG_TEST_QUIT_AT=2.1 run $T/z504.txt --plain)
check "screen: a terminal smaller than 80 x 24, or --plain -> the plain scrolling output" "grep -q '  Step 2.1  Groups' $T/z503.txt && ! grep -q 'need attention' $T/z503.txt && grep -q '  Step 2.1  Groups' $T/z504.txt && ! grep -q 'need attention' $T/z504.txt"
# a half-installed Grid home (installer killed after it registered the home) after an earlier root.sh: not "installed"
fresh empty; rc=$(DG_TEST_QUIT_AT=3.2 run $T/z506a.txt)
gh=$T/u01/app/19.0.0/grid; mkdir -p $gh $T/u01/app/oraInventory/ContentsXML; (cd $gh && unzip -q -o $T/stage/LINUX.X64_193000_grid_home.zip)
printf '<INVENTORY><HOME_LIST>\n<HOME NAME="OraGI19Home1" LOC="%s" TYPE="O" IDX="1"/>\n' "$gh" > $T/u01/app/oraInventory/ContentsXML/inventory.xml
: > $T/varlib/grid_root.done; mkdir -p /etc/oracle; echo "olrconfig_loc=x" > /etc/oracle/olr.loc
rc=$(run $T/z506.txt --check --only grid)
check "3.2: a home registered by a killed installer is not 'installed', even with an old root.sh record and olr.loc" "grep -q 'cannot confirm the installation' $T/z506.txt"
rm -f /etc/oracle/olr.loc
rc=$(run $T/z505.txt --status)
check "--status: every step with its result (not only the phases)" "grep -q 'Every step' $T/z505.txt && grep -qE '✔ 1.1 +Root and tools on this server +ok' $T/z505.txt && grep -qE '✔ 2.1 +Groups .* done' $T/z505.txt && grep -qE '· 3.3 +Grid root scripts +to do' $T/z505.txt"
fi
if part 5.23; then
CUR=5.23; echo "== 5.23  Real-run fixes: hung instance, listener, storage, clean-up, commands"
# a built standby once; later tests start from a copy of it (each full setup takes about a minute)
rm -f /tmp/dgt_built523.tar
built523() {
  if [[ ! -f /tmp/dgt_built523.tar ]]; then
    fresh empty; run $T/b523.txt >/dev/null
    tar -C / -cf /tmp/dgt_built523.tar tmp/dgt etc/oratab $(cd / && ls -d etc/systemd/system/dg-arch-cleanup-* usr/local/sbin/dg_arch_cleanup_* etc/systemd/system/oracle-standby-* 2>/dev/null) 2>/dev/null
  else
    rm -rf $T /etc/systemd/system/dg-arch-cleanup-* /usr/local/sbin/dg_arch_cleanup_*; tar -C / -xf /tmp/dgt_built523.tar
  fi
}
fake_pmon() { ( runuser -u oracle -- bash -c 'exec -a ora_pmon_PRODDB_STBY sleep 300' ) >/dev/null 2>&1 & }
pmon_gone() { ! pgrep -f '^ora_pmon_PRODDB_STBY( |$)' >/dev/null; }

# ---- item 16: 9.2, the instance RMAN started does not stop (ORA-01012) ----
built523; jset $S "d['instances']['PRODDB_STBY']['state']='mounted'; d['instances']['PRODDB_STBY']['shut_hangs']='err'; d['srvctl']['running']=0"; fake_pmon
rc=$(DG_TEST_QUIT_AT=9.3 run $T/h1.txt --from 9.2)
check "9.2: shutdown immediate gives ORA-01012 -> the hang is named, shutdown abort offered and done (-prelim), then srvctl start" "grep -q 'did not stop with shutdown immediate' $T/h1.txt && grep -q 'hangs: its processes run (ora_pmon_PRODDB_STBY), but a login gives ORA-01012' $T/h1.txt && grep -q 'sqlplus -prelim / as sysdba  ->  shutdown abort' $T/h1.txt && pmon_gone && [[ \$(res 9.2 $T/h1.txt) == DONE ]] && python3 -c \"import json;d=json.load(open('$S'));assert d['srvctl']['running']==1 and d['instances']['PRODDB_STBY']['state']=='mounted', d['srvctl']\""
built523; jset $S "d['instances']['PRODDB_STBY']['state']='mounted'; d['instances']['PRODDB_STBY']['hung']='err'; d['srvctl']['running']=0"; fake_pmon
rc=$(DG_TEST_QUIT_AT=9.3 run $T/h2.txt --from 9.2 --yes)
check "9.2: a hung instance at the start -> its own state (not 'cannot tell'), Will run shows -prelim + srvctl, asked even with --yes" "grep -q 'Instance PRODDB_STBY hangs' $T/h2.txt && ! grep -q 'Cannot tell whether the standby' $T/h2.txt && grep -A6 'Will run' $T/h2.txt | grep -q 'sqlplus -S -prelim / as sysdba' && grep -q '\[y\] Stop it with shutdown abort and start it again' $T/h2.txt && pmon_gone && [[ \$(res 9.2 $T/h2.txt) == DONE ]]"
built523; jset $S "d['instances']['PRODDB_STBY']['state']='mounted'; d['instances']['PRODDB_STBY']['shut_hangs']='sleep'; d['srvctl']['running']=0"; fake_pmon
rc=$(DG_TEST_QUIT_AT=9.3 run $T/h3.txt --from 9.2)
check "9.2: shutdown immediate that hangs -> stopped after the time limit, shutdown abort offered" "grep -q 'did not stop with shutdown immediate within' $T/h3.txt && grep -q 'Stop it with shutdown abort' $T/h3.txt && [[ \$(res 9.2 $T/h3.txt) == DONE ]]"
built523; jset $S "d['instances']['PRODDB_STBY']['state']='mounted'; d['instances']['PRODDB_STBY']['hung']='err'"; fake_pmon
rc=$(run $T/h4.txt --health)
check "--health: a hung instance is CRITICAL with the reason" "[[ $rc == 2 ]] && grep -q 'CRITICAL' $T/h4.txt && grep -q 'hangs' $T/h4.txt"
pkill -f '^ora_pmon_PRODDB_STBY( |$)' 2>/dev/null
built523; jset $S "d['srvctl']={}" 2>/dev/null
rc=$(DG_TEST_QUIT_AT=9.2 run $T/h5.txt --from 9.1)
check "9.1: the srvctl add command is shown whole under Will run before [y], and runs as shown" "grep -qE '^ +srvctl add database -db PRODDB_STBY .*-diskgroup [A-Z,]+' $T/h5.txt && grep -qE 'Running as oracle: srvctl add database -db PRODDB_STBY .*-diskgroup' $T/h5.txt"

# ---- item 10: a standby copied outside the script is accepted ----
built523; rm -f $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/.dg_duplicate_done_PRODDB_STBY $T/varlib/dup_attempt
rc=$(run $T/m1.txt --from 8.1)
check "a complete standby made by hand (no marker) -> accepted in one line, phase 9 and 10 run" "grep -q 'Accepted: a complete physical standby' $T/m1.txt && [[ \$(res 8.2 $T/m1.txt) == OK ]] && [[ \$(res 9.3 $T/m1.txt) =~ ^(OK|DONE)$ ]] && grep -q 'Standby setup is complete' $T/m1.txt"
built523; rm -f $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/.dg_duplicate_done_PRODDB_STBY $T/varlib/dup_attempt; jset $S "d['instances']['PRODDB_STBY']['state']='idle'; d['srvctl']['running']=0"
rc=$(DG_TEST_QUIT_AT=9.1 run $T/m2.txt --from 7.2)
check "a standby spfile without the record of a copy (instance down) -> mounted once, compared, accepted (no clean-up offered)" "grep -q 'a standby spfile exists that this script did not make' $T/m2.txt && grep -q 'Accepted: a complete physical standby' $T/m2.txt && ! grep -q 'Clean up for me' $T/m2.txt"

# ---- items 18, 19: the nightly clean-up of archived logs is a setting ----
built523
check "9.8 first time: asked how (timer / crontab / leave it to the recovery area / nothing), timer chosen, saved, set up at 04:30 for 1 day" "grep -q 'Choices: t  a systemd timer' $T/b523.txt && grep -q '\[t\] systemd timer   \[c\] crontab of oracle' $T/b523.txt && grep -q '^ARCH_CLEANUP=timer' $T/varlib/settings.conf && grep -q 'OnCalendar=\\*-\\*-\\* 04:30:00' /etc/systemd/system/dg-arch-cleanup-proddb_stby.timer && grep -q \"completed before 'sysdate-1'\" /usr/local/sbin/dg_arch_cleanup_proddb_stby.sh && ! grep -q force /usr/local/sbin/dg_arch_cleanup_proddb_stby.sh"
sed -i 's/^ARCH_CLEANUP=.*/ARCH_CLEANUP=crontab/; s/^ARCH_CLEANUP_TIME=.*/ARCH_CLEANUP_TIME=02:10/' $T/varlib/settings.conf
rc=$(run $T/a1.txt --only 9.8)
check "ARCH_CLEANUP=crontab: the timer is taken out, one tagged line in the oracle crontab at 02:10, its log owned by oracle (Will run shows it all)" "grep -q '^10 2 \\* \\* \\* /usr/local/sbin/dg_arch_cleanup_proddb_stby.sh >> $T/log/arch_cleanup_proddb_stby.log 2>&1 # dg_standby_setup proddb_stby\$' $T/state/crontab_oracle && [[ \$(grep -c dg_standby_setup $T/state/crontab_oracle) -eq 1 ]] && [[ ! -f /etc/systemd/system/dg-arch-cleanup-proddb_stby.timer ]] && [[ \$(stat -c %U $T/log/arch_cleanup_proddb_stby.log) == oracle ]] && grep -A12 'Will run' $T/a1.txt | grep -q 'systemctl disable --now dg-arch-cleanup-proddb_stby.timer' && [[ \$(res 9.8 $T/a1.txt) == DONE ]]"
printf 'echo old line\n' >> $T/state/crontab_oracle
rc=$(run $T/a2.txt --only 9.8)
check "crontab: a second run changes nothing (other lines of the crontab are kept)" "[[ \$(res 9.8 $T/a2.txt) == OK ]] && grep -q 'echo old line' $T/state/crontab_oracle"
printf '=== dg_arch_cleanup 2026-11-08 02:10:00 ===\nRMAN-06091: no channel allocated for maintenance\n=== end (exit code 1) ===\n' >> $T/log/arch_cleanup_proddb_stby.log
rc=$(run $T/a3.txt --health)
check "--health: the last crontab clean-up printed RMAN- errors -> 10.8 CRITICAL with the line" "[[ $rc == 2 ]] && grep -q '10.8.*RMAN-06091' $T/a3.txt"
: > $T/log/arch_cleanup_proddb_stby.log; chown oracle $T/log/arch_cleanup_proddb_stby.log
sed -i 's/^ARCH_CLEANUP=.*/ARCH_CLEANUP=timer/; s/^ARCH_CLEANUP_TIME=.*/ARCH_CLEANUP_TIME=01:15/; s/^ARCH_CLEANUP_DAYS=.*/ARCH_CLEANUP_DAYS=3/' $T/varlib/settings.conf
rc=$(run $T/a4.txt --only 9.8)
check "back to timer at 01:15, 3 days: the crontab line is taken out (others kept), timer and script as set" "! grep -q dg_standby_setup $T/state/crontab_oracle && grep -q 'echo old line' $T/state/crontab_oracle && grep -q 'OnCalendar=\\*-\\*-\\* 01:15:00' /etc/systemd/system/dg-arch-cleanup-proddb_stby.timer && grep -q \"sysdate-3'\" /usr/local/sbin/dg_arch_cleanup_proddb_stby.sh"
sed -i 's/^ARCH_CLEANUP=.*/ARCH_CLEANUP=oracle/' $T/varlib/settings.conf
rc=$(run $T/a5.txt --only 9.8)
check "ARCH_CLEANUP=oracle (logs in the recovery area): the timer is taken out, 9.8 done" "[[ ! -f /etc/systemd/system/dg-arch-cleanup-proddb_stby.timer ]] && [[ \$(res 9.8 $T/a5.txt) == DONE ]] && grep -q 'the recovery area deletes applied logs by itself' $T/a5.txt"
jset $S "d['instances']['PRODDB_STBY']['fra_usage']='97|95'"
rc=$(run $T/a6.txt --health)
check "--health: recovery area 97% used but 95% reclaimable -> not a problem" "grep -qE 'OK +10.8' $T/a6.txt"
jset $S "d['instances']['PRODDB_STBY']['fra_usage']='96|3'"
rc=$(run $T/a7.txt --health)
check "--health: recovery area 96% used, 3% reclaimable -> CRITICAL" "[[ $rc == 2 ]] && grep -qE 'CRITICAL +10.8.*93% not reclaimable' $T/a7.txt"
sed -i 's/^ARCH_CLEANUP_TIME=.*/ARCH_CLEANUP_TIME=25:00/' $T/varlib/settings.conf
rc=$(run $T/a8.txt --only 9.8)
check "ARCH_CLEANUP_TIME=25:00 is refused (like other wrong values)" "grep -q 'Invalid value: ARCH_CLEANUP_TIME=25:00' $T/a8.txt"

# ---- S1: a step text longer than the screen (80 x 24): nothing scrolls out of view unseen ----
SN=/tmp/dgt_snaps; rm -rf $SN/s1; built523; jset $S "d['srvctl']={}"
rc=$(DG_TEST_UI=1 DG_TEST_SIZE=24x80 DG_TEST_SNAPDIR=$SN/s1 DG_TEST_SNAP=9.1 DG_TEST_QUIT_AT=9.2 DG_TEST_TIMEOUT=300 run $T/w1.txt --from 9.1)
f=$(ls $SN/s1/*step_9.1.txt 2>/dev/null | head -1)
check "screen 80x24: step 9.1 keeps its title, the Will run heading, the srvctl command and the question in view" "[[ -n '$f' ]] && grep -q 'Step 9.1  Registration in Oracle Restart' $f && grep -q 'Yes, do it' $f && grep -q 'Will run as oracle' $f && grep -q 'srvctl add database -db PRODDB_STBY' $f"
# the cut part never holds where the commands run, and d shows the whole text (not the log)
rm -rf $SN/s1b; built523; jset $P "d['static']=0"
rc=$(DG_TEST_UI=1 DG_TEST_SIZE=24x80 DG_TEST_SNAPDIR=$SN/s1b DG_TEST_SNAP=4.10 DG_TEST_KEYS=4.10:d DG_TEST_QUIT_AT=4.10 DG_TEST_TIMEOUT=300 run $T/w2.txt --only 4.10)
f=$(ls $SN/s1b/*step_4.10.txt 2>/dev/null | head -1); g=$(ls $SN/s1b/*alt_4.10_d.txt 2>/dev/null | head -1)
check "screen 80x24: a cut primary step keeps 'Run on the PRIMARY (host), as grid' above its commands, box lines never split by the script; d shows the whole text" "[[ -n '$f' && -n '$g' ]] && grep -q 'more lines: d shows all' $f && grep -q 'Run on the PRIMARY (prim01), as grid' $f && grep -q 'bin/lsnrctl reload LISTENER' $T/w2.txt && ! grep -q '^ (SID_LIST' $T/w2.txt && grep -q 'Step 4.10  (the whole text)' $g && grep -q 'Edit this file' $g"


# ---- item 7: a primary with files in folders and in ASM; this server has ASM -> everything into +DATA ----
combo mix523 DGT_STORAGE=mixed
check "mixed primary: the copy puts everything into +DATA (one newname, control files, OMF dests), no folder path" "full_ok $T/r_mix523.txt && grep -q \"set newname for database to '+DATA'\" $T/log/duplicate_*.rman && grep -q \"set control_files='+DATA'\" $T/log/duplicate_*.rman && grep -q \"set db_create_online_log_dest_1='+DATA'\" $T/log/duplicate_*.rman && ! grep -q oradata $T/log/duplicate_*.rman"
check "mixed primary: 8.1 says where the primary keeps its files and that all go to +DATA here" "grep -q 'The primary keeps files in .*(file system) and .*(ASM); here all of them go to +DATA' $T/r_mix523.txt"
( export DGT_STORAGE=mixed; bash $TD/setup_env.sh empty >/dev/null ); rc=$(DG_TEST_QUIT_AT=2.1 run $T/s1a.txt)
sed -i 's/^DATA_DEST=.*/DATA_DEST=same/; s/^FRA_DEST=.*/FRA_DEST=same/' $T/varlib/settings.conf
( export DGT_STORAGE=mixed; run $T/s1.txt ) >/dev/null
check "DATA_DEST=same (the old way) still works: every file keeps its folder or disk group (set newname per file)" "full_ok $T/s1.txt && grep -q \"set newname for datafile 1 to '\" $T/log/duplicate_*.rman && ! grep -q 'set newname for database' $T/log/duplicate_*.rman"

# ---- items 5, 6, 9: the copy fills the recovery area (ORA-19809) ----
# (the primary's recovery area is 20 GB here: the standby gets the same size, and twice that still fits the
# mock FRA disk of 100 GB, so the second copy is not stopped by 2.13 for lack of disk)
fresh empty; jset $S "d['rman_fra_full']=1"; jset $P "d['params']['db_recovery_file_dest_size']=str(20*1024**3)"
rc=$(run $T/f1.txt)
check "8.2: ORA-19809 -> 'the recovery area on this server is full', the first real error (not RMAN-00571), next step named" "grep -q 'the recovery area on this server is full' $T/f1.txt && grep -A2 'First error:' $T/f1.txt | grep -q 'ORA-19809: limit exceeded' && grep -A3 'First error:' $T/f1.txt | grep -q 'ORA-19804' && ! grep -A3 'First error:' $T/f1.txt | grep -qE 'RMAN-00571|RMAN-03002|ORA-19849' && grep -q 'with a bigger recovery area' $T/f1.txt"
cp $S /tmp/dgt_standby_f1.json; tar -C / -cf /tmp/dgt_f1.tar tmp/dgt
rc=$(run $T/f2.txt)
check "after ORA-19809: 7.2 cleans up on [y] + CLEAN (only the standby's ASM folder; pfile and password file kept), copy again with twice the size" "grep -q 'The copy failed because the recovery area was full' $T/f2.txt && grep -q 'Kept: initPRODDB_STBY.ora, orapwPRODDB_STBY' $T/f2.txt && grep -q 'Checked: this is' $T/f2.txt && python3 -c \"import json;d=json.load(open('$S'));r=d.get('asm_removed',[]);assert '+DATA/PRODDB_STBY' in r and all(x.endswith('/PRODDB_STBY') for x in r), r\" && [[ -f $T/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRODDB_STBY ]] && full_ok $T/f2.txt && [[ \$(grep -o \"db_recovery_file_dest_size='[0-9]*G'\" \$(ls -t $T/log/duplicate_*.rman | head -1) | tr -dc 0-9) -ge \$(( 2 * \$(python3 -c \"import json;print(json.load(open('/tmp/dgt_standby_f1.json'))['fra_size_tried'])\") )) ]]"
# [m]: the same commands as a short script file with one host check
rm -rf $T; tar -C / -xf /tmp/dgt_f1.tar; rm -f /tmp/dgt_f1.tar
rc=$(DG_SHORT_DIR=$T/sd DG_TEST_L72=m DG_TEST_QUIT_AT=8.1 run $T/f3.txt)
mkdir -p $T/fakehost; printf '#!/bin/sh\necho otherhost\n' > $T/fakehost/hostname; chmod 755 $T/fakehost/hostname
check "clean-up [m]: a short script file (one host check at the top) and one short line to run it; it refuses another host" "[[ -x $T/sd/c72 ]] && [[ \$(grep -c 'hostname -s' $T/sd/c72) -eq 1 ]] && grep -q 'asmcmd rm -rf +DATA/PRODDB_STBY' $T/sd/c72 && grep -q '^ *$T/sd/c72' $T/f3.txt && grep -q 'This file is for the server' <(PATH=$T/fakehost:\$PATH bash $T/sd/c72 2>&1) && ! grep -q 'mv -f' <(PATH=$T/fakehost:\$PATH bash -x $T/sd/c72 2>&1)"

# ---- item 17: the primary's service is found under another name before anything is assumed ----
fresh empty; jset $P "d['lsnr_services']=['proddb.corp.local','pdb1.corp.local']"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/v1.txt)
check "1.3: the listener offers proddb.corp.local (a domain not in db_domain) -> used and said, no 'Assuming'" "grep -q 'It offers proddb.corp.local (the unique name with a domain): that one is used' $T/v1.txt && ! grep -q 'Assuming LISTENER' $T/v1.txt && grep -q '^PRIMARY_SERVICE=proddb.corp.local' $T/varlib/settings.conf"
fresh empty; jset $P "d['lsnr_services']=['appsvc','pdb1']; d['params']['service_names']='appsvc'"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/v2.txt)
check "1.3: only a service from service_names is offered -> that one is used (never a PDB service)" "grep -q 'It offers appsvc (a service of this database' $T/v2.txt && ! grep -q 'Assuming LISTENER' $T/v2.txt"
fresh empty; jset $P "d['lsnr_services']=['pdb1']"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/v3.txt)
check "1.3: nothing of this database offered -> the warning as before" "grep -q 'Assuming LISTENER' $T/v3.txt"


# ---- item 15: menu, summary screen; item 14: [a] yes to all ----
fresh empty; jset $P "d['hostres']={'prim01':''}; d['log_mode']='NOARCHIVELOG'"
rc=$(DG_TEST_QUIT_AT=2.1 DG_TEST_SUMMARY=13,450, run $T/u1.txt)
check "summary screen: primary, this server, where the files go, plan, problems (host name of the primary, NOARCHIVELOG), numbered values" "grep -q 'Found on the primary' $T/u1.txt && grep -q 'Standby to build' $T/u1.txt && grep -qE 'Datafiles, tempfiles +\\+DATA \\(ASM\\) +\\+DATA \\(ASM\\)' $T/u1.txt && grep -q 'Host name on the primary: prim01' $T/u1.txt && grep -q 'NOARCHIVELOG mode' $T/u1.txt && grep -qE '^ +13  Health check lag limit' $T/u1.txt"
check "summary: a number changes only that value, it is saved as the new default and the screen is drawn again" "grep -q '^HEALTH_LAG_MAX=450' $T/varlib/settings.conf && [[ \$(grep -c 'Values of this run' $T/u1.txt) -ge 2 ]] && grep -qE '13  Health check lag limit +450 seconds' $T/u1.txt && ls $T/log/summary_*.txt >/dev/null"
fresh
rc=$(DG_TEST_QUIT_AT=2.1 run $T/u2.txt --check)
check "--check prints the summary as a report (no question)" "grep -q 'Values of this run' $T/u2.txt && ! grep -q '\\[Enter\\] Start' $T/u2.txt"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/u2s.txt); rc=$(run $T/u2h.txt --health)   # with settings saved, so --health really runs
check "--health never shows the summary" "grep -q 'Data Guard health check' $T/u2h.txt && ! grep -q 'Stopped:' $T/u2h.txt && ! grep -q 'Values of this run' $T/u2h.txt"
fresh
rc=$(DG_TEST_MENU=2 DG_TEST_QUIT_AT=2.3 run $T/u3.txt)
check "menu: grouped (Setup / After setup / Information) with the switch of each item; 2 = check only" "grep -q 'After setup' $T/u3.txt && grep -qE 'Check only, change nothing +--check' $T/u3.txt && grep -qE 'Roll forward the standby from the primary +--roll-forward' $T/u3.txt && grep -qE '1  Mode +check only' $T/u3.txt && grep -q 'check mode does not save them' $T/u3.txt"
fresh
rc=$(DG_TEST_MENU=8 DG_TEST_SUMMARY=9.6, DG_TEST_QUIT_AT=9.7 run $T/u4.txt)
check "menu 8: start from a step (9.6), like --from" "grep -q 'This run: from step 9.6' $T/u4.txt && grep -q '^  Step 9.6' $T/u4.txt && ! grep -q '^  Step 9.5' $T/u4.txt"
fresh empty
rc=$(DG_TEST_YESALL=2.1 DG_TEST_QUIT_AT=3.1 run $T/u5.txt)
check "[a] yes to all at 2.1: later steps are not asked, the disk erasure (2.13) still is, logged" "grep -q 'a: yes to all from here' $T/log/run_*.log && ! grep -E '^  Step 2\\.(2|3|4|5|9|10|11) ' -A25 $T/u5.txt | grep -q '\\[y\\] Yes, do it' && grep -q 'Yes (yes to all)' $T/u5.txt && grep -qE 'Type /dev/\\S+ to continue' $T/u5.txt"

# ---- item 13: commands for the primary over ssh (PRIMARY_RUN=yes, asked per step, white list only) ----
fresh; rc=$(DG_TEST_QUIT_AT=2.1 run $T/p0.txt); sed -i 's/^PRIMARY_RUN=.*/PRIMARY_RUN=yes/' $T/varlib/settings.conf
jset $P "d['params']['log_archive_config']=''; d['force_logging']='NO'"
: > $T/state/primary_sql.log
rc=$(DG_TEST_ANSWER_PRIM=y DG_TEST_QUIT_AT=5.1 run $T/p1.txt --from 4.1)
check "PRIMARY_RUN=yes: 4.1 (force logging) and 4.3 offer [y] Run it on the primary for me; only the allowed statements ran there; recorded done + journaled" "grep -q '\\[y\\] Run it on the primary for me' $T/p1.txt && grep -qi '^alter database force logging;' $T/state/primary_sql.log && grep -qi \"^alter system set log_archive_config=\" $T/state/primary_sql.log && ! grep -viE '^(select|alter database force logging;|alter system set (log_archive_config|log_archive_dest_[0-9]+|log_archive_dest_state_[0-9]+|standby_file_management|fal_server|db_recovery_file_dest_size|db_recovery_file_dest)=.* scope=both;|alter database add standby logfile .*)' $T/state/primary_sql.log | grep -q . && grep -q 'run by the script over ssh' $T/varlib/changes.log && [[ \$(res 4.3 $T/p1.txt) == DONE ]]"
fresh; rc=$(DG_TEST_QUIT_AT=2.1 run $T/p2a.txt); sed -i 's/^PRIMARY_RUN=.*/PRIMARY_RUN=yes/' $T/varlib/settings.conf
jset $P "d['log_mode']='NOARCHIVELOG'"
rc=$(DG_TEST_QUIT_AT=4.2 run $T/p2.txt --from 4.1)
check "PRIMARY_RUN=yes: ARCHIVELOG (needs a restart of the primary) is never offered to run" "grep -q 'Step 4.1' $T/p2.txt && ! grep -A40 'Step 4.1' $T/p2.txt | grep -q 'Run it on the primary for me'"

# ---- items 1-4: Oracle Restart resources (3.9) ----
DBH=$T/u01/app/oracle/product/19.0.0/dbhome_1
fresh; jset $S "d['lsnr_check']=1"; grep -vw "$(hostname -s)" /etc/hosts > /tmp/dgt_hosts && cat /tmp/dgt_hosts > /etc/hosts
rc=$(DG_TEST_QUIT_AT=3.10 run $T/r1.txt --only 3.9)
if [[ -n "$(timeout 10 getent -s dns ahostsv4 "$(hostname -s)" 2>/dev/null)" ]]; then
# (a machine whose DNS knows its own name, as the GitHub runners: /etc/hosts is not the cause, and the script must not say it is)
check "3.9: listener INTERMEDIATE, host name only in DNS (this machine) -> /etc/hosts not blamed, the commands to compare shown" "grep -q 'INTERMEDIATE (Not All Endpoints Registered)' $T/r1.txt && ! grep -q 'Cause: ' $T/r1.txt && grep -q 'the cause is not known' $T/r1.txt && grep -q 'srvctl stop listener -listener LISTENER' $T/r1.txt"
else
check "3.9: listener INTERMEDIATE because the host name is not in /etc/hosts -> cause named, [y] adds it, srvctl stop + start, then ONLINE" "grep -q 'INTERMEDIATE (Not All Endpoints Registered)' $T/r1.txt && grep -q 'Cause: ' $T/r1.txt && grep -qE \"^[0-9.]+ +.*$(hostname -s)\" /etc/hosts && grep -q 'srvctl stop listener -listener LISTENER' $T/r1.txt && [[ \$(res 3.9 $T/r1.txt) == DONE ]]"
fi
fresh; jset $S "d['lsnr_check']=1"
runuser -u oracle -- perl -e 'use Socket; socket(S, PF_INET, SOCK_STREAM, 0); setsockopt(S, SOL_SOCKET, SO_REUSEADDR, 1); bind(S, sockaddr_in(1521, inet_aton("'"$(hostname -I | tr ' ' '\n' | grep -v '^127' | grep -E '^[0-9.]+$' | head -n 1)"'"))) or exit 1; listen(S, 5); $0 = "'"$DBH"'/bin/tnslsnr LISTENER -inherit"; sleep 300' >/dev/null 2>&1 &
sleep 1; fpid=$(pgrep -f "^$DBH/bin/tnslsnr LISTENER" | head -n 1); jset $S "d['fake_lsnr_pid']=$fpid"
rc=$(DG_TEST_QUIT_AT=3.10 run $T/r2.txt --only 3.9)
check "3.9: INTERMEDIATE because port 1521 is held by a listener of the database home -> named, stopped on [y] (lsnrctl stop), Grid listener restarted" "grep -q 'port 1521 is taken by the listener LISTENER of $DBH' $T/r2.txt && grep -q 'lsnrctl stop LISTENER' $T/r2.txt && ! kill -0 $fpid 2>/dev/null && [[ \$(res 3.9 $T/r2.txt) == DONE ]]"
kill $fpid 2>/dev/null
fresh; jset $S "d['lsnr_off']=1; d['dg_off']=['DATA']"
rc=$(DG_TEST_QUIT_AT=3.10 run $T/r3.txt --only 3.9)
check "3.9: listener and a disk group OFFLINE -> srvctl start listener / diskgroup (never crsctl start res), diskmon and ons not touched" "grep -q 'srvctl start listener -listener LISTENER' $T/r3.txt && grep -q 'srvctl start diskgroup -diskgroup DATA' $T/r3.txt && ! grep -q \"'start', 'res'\" $T/state/calls.log && ! grep -qiE 'diskmon|ora\\.ons' $T/r3.txt && [[ \$(res 3.9 $T/r3.txt) == DONE ]]"
fresh; jset $S "d['asm_down']=1"
rc=$(DG_TEST_QUIT_AT=3.5 run $T/r4.txt --only 3.4)
check "3.4: ASM not ONLINE -> srvctl start asm (Will run shows it), never crsctl start res" "grep -A4 'Will run' $T/r4.txt | grep -q 'srvctl start asm' && ! grep -q \"'start', 'res'\" $T/state/calls.log"
fi
if part 5.24; then
CUR=5.24; echo "== 5.24  Review fixes: force logging modes, 8.1 pre-checks, probes, clean-up script, 10.8, TDE, escaping"
fresh
# ---- 4.1: the STANDBY NOLOGGING modes keep the standby complete (as in 8.1 and 10.5); NO still needs force logging ----
jset $P "d['log_mode']='ARCHIVELOG'; d['force_logging']='STANDBY NOLOGGING FOR DATA AVAILABILITY'"
rc=$(DG_TEST_QUIT_AT=4.1 run $T/r24a.txt --only 4.1)
check "4.1: force_logging 'STANDBY NOLOGGING FOR DATA AVAILABILITY' -> OK, no 'alter database force logging' planned" "[[ \$(res 4.1 $T/r24a.txt) == OK ]] && grep -q 'force_logging is STANDBY NOLOGGING FOR DATA AVAILABILITY' $T/r24a.txt && ! grep -qi 'alter database force logging' $T/r24a.txt"
jset $P "d['force_logging']='NO'"
rc=$(DG_TEST_QUIT_AT=4.1 run $T/r24b.txt --only 4.1)
check "4.1: force_logging NO -> 'alter database force logging;' planned, not OK" "grep -q '^ *alter database force logging;' $T/r24b.txt && [[ \$(res 4.1 $T/r24b.txt) != OK ]]"

# ---- 8.1 pre-checks: the spfile of the primary, force logging, the release of the software here ----
# (each run starts at 8.1 with the instance in NOMOUNT; these checks come before the logins of 7.4)
pre81() { jset $S "d['instances']['PRODDB_STBY']={'state':'started'}"; jset $P "d['log_mode']='ARCHIVELOG'; d['force_logging']='YES'"; }
pre81; jset $P "d['spfile']=''"
rc=$(DG_TEST_QUIT_AT=8.2 run $T/r24c.txt --from 8.1)
check "8.1: the primary answers nothing for its spfile -> stops, 'could not be read' (never taken as an spfile)" "grep -q 'The spfile setting of the primary could not be read' $T/r24c.txt && [[ \$(res 8.1 $T/r24c.txt) != OK && \$(res 8.2 $T/r24c.txt) != DONE ]]"
pre81; jset $P "d['spfile']='ORA-03113: end-of-file on communication channel'"
rc=$(DG_TEST_QUIT_AT=8.2 run $T/r24d.txt --from 8.1)
check "8.1: the spfile query on the primary fails (ORA-03113) -> stops, 'could not be read'" "grep -q 'The spfile setting of the primary could not be read' $T/r24d.txt && grep -q 'ORA-03113' $T/r24d.txt && [[ \$(res 8.1 $T/r24d.txt) != OK ]]"
pre81; jset $P "del d['spfile']; d['force_logging']='NO'"
rc=$(DG_TEST_QUIT_AT=8.2 run $T/r24e.txt --from 8.1)
check "8.1: force logging switched off after 4.1 passed -> stops and shows 'alter database force logging;'" "grep -q 'FORCE LOGGING is off on the primary (force_logging = NO, step 4.1)' $T/r24e.txt && grep -q 'On the primary:  alter database force logging;' $T/r24e.txt && [[ \$(res 8.1 $T/r24e.txt) != OK ]]"
pre81; jset $T/state/env.json "d['local_version']='21.3.0.0.0'"
rc=$(DG_TEST_QUIT_AT=8.2 run $T/r24f.txt --from 8.1)
jset $T/state/env.json "d['local_version']='19.21.0.0.0'"
check "8.1: the database software here is another release than the primary -> stops, step 3.11 named" "grep -q 'The database software here is another release: release 21.0 here, release 19 on the primary' $T/r24f.txt && grep -q 'same release as the primary (step 3.11)' $T/r24f.txt && [[ \$(res 8.1 $T/r24f.txt) != OK ]]"

# ---- 4.4: a log_archive_dest_1 that already ships to the standby alias is used, no second destination ----
fresh; jset $P "d['log_mode']='ARCHIVELOG'; d['force_logging']='YES'; d['params']['log_archive_dest_1']='service=proddb_stby async valid_for=(online_logfiles,primary_role)'"
rc=$(DG_TEST_QUIT_AT=4.4 run $T/r24g.txt --only 4.4)
check "4.4: log_archive_dest_1 already names the standby alias -> that one is used, no log_archive_dest_2 planned" "grep -q 'log_archive_dest_1 already names the alias proddb_stby, so it is used' $T/r24g.txt && grep -q \"log_archive_dest_1='service=proddb_stby async\" $T/r24g.txt && ! grep -qE 'log_archive_dest(_state)?_2=' $T/r24g.txt"

# ---- a channel number with a leading zero is an invalid value, never a bash error ----
# (the settings saved by the runs above; the summary rejects the value on Enter, then q: the driver would press Enter for ever)
sed -i 's/^PRIMARY_CHANNELS=.*/PRIMARY_CHANNELS=08/' $T/varlib/settings.conf
rc=$(DG_TEST_SUMMARY=' ,q' run $T/r24i.txt --only 4.1)
check "settings PRIMARY_CHANNELS=08 -> the invalid-value message, no 'value too great for base'" "grep -q 'PRIMARY_CHANNELS must be a number from 1 to 64' $T/r24i.txt && ! grep -q 'value too great for base' $T/r24i.txt && ! grep -qs 'value too great for base' $T/log/run_*.log"

# ---- --check sends no 64 MB network measure to the primary ----
fresh empty
rc=$(run $T/r24h.txt --check)
check "--check on an empty server: no 'dd if=/dev/zero' sent to the primary, 'not measured in check mode' said" "[[ -s $T/state/primary_cmds.log ]] && ! grep -q 'dd if=/dev/zero' $T/state/primary_cmds.log && grep -q 'not measured in check mode' $T/r24h.txt"

# ---- login noise on the primary that looks like a probe marker ----
fresh empty; jset $P "d['login_noise']='__DG_PROBE_deadbeef__'"
rc=$(DG_TEST_QUIT_AT=2.1 run $T/r24j.txt)
check "login noise like a marker (__DG_PROBE_deadbeef__) does not break reading the primary: 1.3 done, primary host read" "[[ \$(res 1.3 $T/r24j.txt) =~ ^(OK|DONE)\$ ]] && grep -qE 'Primary host: prim01[[:space:]]*\$' $T/r24j.txt && ! grep -q '__DG_PROBE_deadbeef__' $T/varlib/settings.conf"

# ---- srv_notfound: the name is a literal (+ and . are no regex characters) ----
ut_524_srv() { bash <<EOF
source <(sed -n '/^srv_notfound()/,/^}/p' $T/dg_standby_setup.sh)
RUN_OUT="PRCN-2044 : No listener exists ... 
PRCR-1001 : Resource ora.lsnr+x.lsnr does not exist"; srv_notfound 'lsnr+x' && echo p1
RUN_OUT="PRCN-2065 : Listener lsnr+x does not exist"; srv_notfound 'lsnr+x' && echo p2
RUN_OUT="PRCN-2065 : Listener lsnrrx does not exist"; srv_notfound 'lsnr+x' && echo p3
RUN_OUT="PRCD-1120 : The resource for database axb could not be found."; srv_notfound 'a.b' && echo p4
RUN_OUT="PRCD-1120 : The resource for database a.b could not be found."; srv_notfound 'a.b' && echo p5
EOF
}
ut_524_srv > $T/ut524s.txt
check "unit: srv_notfound with '+' in the name: found for lsnr+x (ora.lsnr+x.lsnr, listener lsnr+x), not for lsnrrx" "grep -qx p1 $T/ut524s.txt && grep -qx p2 $T/ut524s.txt && ! grep -qx p3 $T/ut524s.txt"
check "unit: srv_notfound 'a.b' does not match 'axb' (and does match a.b)" "! grep -qx p4 $T/ut524s.txt && grep -qx p5 $T/ut524s.txt"

# ---- 3.9: the old HOST of listener.ora as a literal in the sed fix ----
ut_lsnr_host_esc > $T/ut524h.txt
check "unit: 3.9 listener.ora HOST fix: old.example.com escaped to old\\.example\\.com; only that HOST is replaced" "[[ \$(cat $T/ut524h.txt) == 'old\\.example\\.com|1|1|1' ]]"

# ---- 6.3: a LOCAL auto-login wallet made on another host is on this server already ----
fresh; jset $P "d['tde']=['FILE|$T/pwallet/|OPEN|LOCAL_AUTOLOGIN']; d['files']={'$T/pwallet/ewallet.p12':'EWALLET\\n','$T/pwallet/cwallet.sso':'LOCALSSO\\n'}"
mkdir -p $T/pwallet; printf 'EWALLET\n' > $T/pwallet/ewallet.p12; touch -d '-1 hour' $T/pwallet/ewallet.p12; printf 'LOCALSSO foreign\n' > $T/pwallet/cwallet.sso
chown -R oracle:oinstall $T/pwallet; chmod 700 $T/pwallet; chmod 600 $T/pwallet/*
rc=$(DG_TEST_QUIT_AT=7.1 run $T/r24k.txt --from 6.1)
check "6.3: a foreign LOCAL cwallet.sso here -> 'not usable here' (orapki cannot open it), moved aside as cwallet.sso.old_*, made again with -auto_login_local" "grep -q 'Not usable here' $T/r24k.txt && grep -q 'orapki cannot open it without a password' $T/r24k.txt && grep -q 'LOCALSSO foreign' $T/pwallet/cwallet.sso.old_* && grep -q 'MOCK-ORAPKI -auto_login_local' $T/pwallet/cwallet.sso && [[ \$(res 6.3 $T/r24k.txt) == DONE ]]"

# ---- the nightly clean-up script (needs the oracle user: after the installed server above) refuses a deletion policy that is not TO APPLIED ON STANDBY ----
ut_524_arch() { # $1 = the policy line the fake rman prints; prints the exit code of the script, then its output
  local d=$T/ut524arch; rm -rf $d; mkdir -p $d/bin; chmod 755 $d $d/bin
  printf '%s\n' "$1" > $d/pol; : > $d/del.log; chown oracle $d/del.log
  cat > $d/bin/rman <<EOF
#!/bin/bash
in=\$(cat)
if grep -q 'show archivelog deletion policy' <<< "\$in"; then
  echo 'RMAN configuration parameters for database with db_unique_name PRODDB_STBY are:'; cat $d/pol
else echo "DELETE RAN as \$(id -un): \$in" >> $d/del.log; echo 'deleted archived log'; fi
EOF
  chmod 755 $d/bin/rman
  bash -c "source <(sed -n '/^arch_days()/p; /^arch_script_text()/,/^}/p' $T/dg_standby_setup.sh); STANDBY_UNIQUE=PRODDB_STBY STANDBY_SID=PRODDB_STBY ORACLE_USER=oracle DB_HOME=$d ARCH_CLEANUP_DAYS=1; arch_script_text" > $d/s.sh
  chmod 755 $d/s.sh
  local out rc=0; out=$($d/s.sh 2>&1) || rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}
o=$(ut_524_arch 'CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DEVICE TYPE DISK;')
printf '%s\n' "$o" > $T/ut524a.txt
check "clean-up script: policy '... APPLIED ON ALL STANDBY BACKED UP 1 TIMES ...' -> refuses (exit not 0), prints the policy, deletes nothing" "[[ \$(head -n 1 $T/ut524a.txt) != 0 ]] && grep -q 'the deletion policy is not TO APPLIED ON STANDBY: nothing deleted' $T/ut524a.txt && grep -q 'BACKED UP 1 TIMES TO DEVICE TYPE DISK' $T/ut524a.txt && [[ ! -s $T/ut524arch/del.log ]]"
o=$(ut_524_arch 'CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;')
printf '%s\n' "$o" > $T/ut524b.txt
check "clean-up script: policy '... TO APPLIED ON ALL STANDBY;' -> the delete runs (as oracle), exit 0" "[[ \$(head -n 1 $T/ut524b.txt) == 0 ]] && grep -q 'DELETE RAN as oracle:' $T/ut524arch/del.log && grep -q \"delete noprompt archivelog all completed before 'sysdate-1'\" $T/ut524arch/del.log && grep -q '=== end (exit code 0) ===' $T/ut524b.txt"
rm -rf $T/ut524arch

# ---- 10.8 on a built standby: no clean-up chosen; the free space of the recovery area's disk group unreadable ----
fresh empty; rc=$(run $T/r24l0.txt)
check "a standby built from an empty server (base for the 10.8 tests)" "grep -q 'Standby setup is complete' $T/r24l0.txt"
sed -i 's/^ARCH_CLEANUP=.*/ARCH_CLEANUP=/' $T/varlib/settings.conf
rc=$(run $T/r24l.txt --only 10.8)
check "10.8: ARCH_CLEANUP empty -> not OK (waiting: nothing deletes applied logs)" "grep -q 'Clean-up: not chosen yet (ARCH_CLEANUP is empty)' $T/r24l.txt && [[ \$(res 10.8 $T/r24l.txt) == WAITS ]]"
rc=$(run $T/r24m.txt --health)
check "--health: ARCH_CLEANUP empty -> 10.8 WARNING" "grep -qE 'WARNING +10\\.8' $T/r24m.txt"
sed -i 's/^ARCH_CLEANUP=.*/ARCH_CLEANUP=timer/' $T/varlib/settings.conf
jset $S "d['dg_free_total']='ORA-15001: diskgroup \"FRA\" does not exist or is not mounted'"
rc=$(run $T/r24n.txt --only 10.8)
check "10.8: recovery area in ASM, the disk group's free space query fails -> cannot check, not OK" "grep -q 'Cannot read the free space of disk group +FRA (recovery area +FRA)' $T/r24n.txt && [[ \$(res 10.8 $T/r24n.txt) != OK && \$(res 10.8 $T/r24n.txt) != WAITS ]]"
jset $S "del d['dg_free_total']"
fi
parts_done
echo
echo "RESULT: $PASS passed, $FAILN failed"
for f in ${FAILED[@]+"${FAILED[@]}"}; do echo "  - $f"; done   # bash 4.2: an empty array is "unbound" under set -u
[[ $FAILN -eq 0 ]]
