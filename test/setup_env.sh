#!/bin/bash
# Mock environment for dg_standby_setup.sh 4.x tests.
#   setup_env.sh [empty|installed]
# Variants (environment):
#   DGT_STORAGE = asm (default) | fs | mixed      primary storage
#   DGT_VER     = 19.21.0.0.0 (default) | 12.1.0.2.0 | 12.2.0.1.0 | 18.14.0.0.0 | 21.13.0.0.0 | 23.5.0.24.07
#   DGT_OWNER   = two (default) | single          grid user, or oracle owns everything
#   DGT_MEDIA   = image (default) | staged | gold | broken
#   DGT_OS      = 8 (default) | 7 | 9
set -euo pipefail
MODE=${1:-empty}
STORAGE=${DGT_STORAGE:-asm}; VER=${DGT_VER:-19.21.0.0.0}; OWNER=${DGT_OWNER:-two}; MEDIA=${DGT_MEDIA:-image}; OSV=${DGT_OS:-8}
MAJ=${VER%%.*}
T=/tmp/dgt
TD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$MAJ" in 12) HV="12.${VER:3:1}.0" ;; *) HV="$MAJ.0.0" ;; esac
DBH=$T/u01/app/oracle/product/$HV/dbhome_1
GH=$T/u01/app/$HV/grid
OB=$T/u01/app/oracle
if [[ "$OWNER" == "single" ]]; then GB=$OB; GU=oracle; else GB=$T/u01/app/grid; GU=grid; fi
INV=$T/u01/app/oraInventory
GRID=true; [[ "$STORAGE" == "fs" ]] && GRID=false
GROUPS_LIST="oinstall:54321 dba:54322 oper:54323 backupdba:54324 dgdba:54325 kmdba:54326 racdba:54330 asmadmin:54327 asmdba:54328 asmoper:54329"
SH=$(hostname -s)
SIP=$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -E '^[0-9.]+$' | head -n 1)

# ---- clean ----
pkill -f 'dgt_port_listener' 2>/dev/null || true
[[ -f /etc/hosts.dgt_orig ]] || cp -p /etc/hosts /etc/hosts.dgt_orig
{ printf '%s    %s\n' "$SIP" "$SH"; grep -vw "$SH" /etc/hosts.dgt_orig; } > /etc/hosts
rm -rf "$T" /etc/oraInst.loc /etc/oracle /etc/security/limits.d/oracle-grid.conf /etc/hosts.bak_* /dev/oraasm \
       /etc/udev/rules.d/99-oracle-asmdevices.rules* /etc/systemd/system/oracle-standby-*.service \
       /usr/local/sbin/dg_standby_*.sh /etc/systemd/system/oracle-ohasd.service.d /etc/oratab.bak_*
[[ -f /etc/oratab.dgt_orig ]] || { [[ -f /etc/oratab ]] && cp -p /etc/oratab /etc/oratab.dgt_orig || : > /etc/oratab.dgt_orig; }
cp -p /etc/oratab.dgt_orig /etc/oratab 2>/dev/null || true
for u in oracle grid; do id $u >/dev/null 2>&1 && userdel -r $u >/dev/null 2>&1 || true; done
for g in $GROUPS_LIST; do getent group "${g%%:*}" >/dev/null && groupdel "${g%%:*}" >/dev/null 2>&1 || true; done

mkdir -p "$T/state" "$T/log" "$T/rootbin" "$T/remotebin" "$T/stage" "$T/devs"
chmod 777 "$T/state"
for f in calls.log primary_sql.log primary_cmds.log primary_UNEXPECTED.log; do : > "$T/state/$f"; chmod 666 "$T/state/$f"; done
cp "$TD/mock_oracle.py" "$TD/mock_root.py" "$TD/mock_ssh.py" "$TD/mock_installer.py" "$T/"; chmod 755 "$T"/mock_*.py
for p in rpm dnf yum oracleasm parted partprobe udevadm lsblk blkid wipefs pvs systemctl chronyc uname cmp findmnt firewall-cmd; do ln -sf "$T/mock_root.py" "$T/rootbin/$p"; done
cp "$TD/mock_ip.sh" "$T/rootbin/ip"; chmod 755 "$T/rootbin/ip"
for p in ssh scp ssh-keyscan ssh-keygen; do ln -sf "$T/mock_ssh.py" "$T/rootbin/$p"; done
cp "$TD/mock_shm.py" "$T/"; chmod 755 "$T/mock_shm.py"; for p in df mount; do ln -sf "$T/mock_shm.py" "$T/rootbin/$p"; done
printf '/dev/mapper/ol-root  /  xfs  defaults  0 0\ntmpfs  /dev/shm  tmpfs  defaults,nodev  0 0\n' > "$T/fstab"
ln -sf "$T/mock_oracle.py" "$T/remotebin/sqlplus"
cat > "$T/os-release" <<EOF
NAME="Oracle Linux Server"
VERSION="$OSV.9"
ID="ol"
VERSION_ID="$OSV.9"
PRETTY_NAME="Oracle Linux Server $OSV.9"
EOF

# ---- media ----
db_payload() {   # $1 dir
  local d=$1 p
  mkdir -p "$d/bin" "$d/OPatch" "$d/network/admin" "$d/dbs"
  for p in sqlplus srvctl rman tnsping orapwd oraversion lsnrctl orapki; do cp "$TD/mock_oracle.py" "$d/bin/$p"; done
  if [[ $MAJ -ge 18 ]]; then cp "$TD/mock_oracle.py" "$d/bin/orabasehome"; cp "$TD/mock_oracle.py" "$d/bin/roohctl"; fi
  cp "$TD/mock_oracle.py" "$d/OPatch/opatch"
  printf 'mock\n' > "$d/bin/oracle"; printf 'mock\n' > "$d/bin/oradism"
  mkdir -p "$d/inventory/oneoffs/35643107"
  cp "$TD/zipsrc/dbroot.sh" "$d/root.sh"; touch "$d/network/admin/README" "$d/dbs/init.ora"
}
grid_payload() { # $1 dir
  local d=$1 p
  mkdir -p "$d/bin" "$d/OPatch" "$d/network/admin" "$d/cfgtoollogs"
  for p in crsctl lsnrctl sqlplus srvctl asmcmd setasmgidwrap; do cp "$TD/mock_oracle.py" "$d/bin/$p"; done
  cp "$TD/mock_oracle.py" "$d/OPatch/opatch"; printf 'mock\n' > "$d/bin/oracle"
  mkdir -p "$d/inventory/oneoffs/35643107"
  cp "$TD/zipsrc/root.sh" "$d/root.sh"; touch "$d/network/admin/README"
  cp "$TD/mock_installer.py" "$d/cfgtoollogs/configToolAllCommands"
}
Z=$T/zipbuild; rm -rf "$Z"; mkdir -p "$Z"
mkzip() { ( cd "$1" && zip -qr "$2" . ); chmod 644 "$2"; }
db_tpl=$TD/templates/db19.rsp; [[ $MAJ -ge 23 ]] && db_tpl=$TD/templates/db23.rsp; [[ "$MEDIA" == "broken" ]] && db_tpl=$TD/templates/db_broken.rsp
case "$MAJ" in 18) vtag=180000 ;; 19) vtag=193000 ;; 21) vtag=213000 ;; 23) vtag=237000 ;; *) vtag="" ;; esac
if [[ "$MEDIA" == "staged" || "$MAJ" == "12" ]]; then
  if [[ "$VER" == 12.1* ]]; then
    # 12.1: both staged, two zip files each
    mkdir -p "$Z/g1/grid/response" "$Z/g2/grid/stage/payload"; cp "$TD/mock_installer.py" "$Z/g1/grid/runInstaller"
    cp "$TD/templates/grid121.rsp" "$Z/g1/grid/response/grid_install.rsp"; grid_payload "$Z/g2/grid/stage/payload"
    mkzip "$Z/g1" "$T/stage/linuxamd64_12102_grid_1of2.zip"; mkzip "$Z/g2" "$T/stage/linuxamd64_12102_grid_2of2.zip"
    mkdir -p "$Z/d1/database/response" "$Z/d2/database/stage/payload"; cp "$TD/mock_installer.py" "$Z/d1/database/runInstaller"
    cp "$TD/templates/db121.rsp" "$Z/d1/database/response/db_install.rsp"; db_payload "$Z/d2/database/stage/payload"
    mkzip "$Z/d1" "$T/stage/linuxamd64_12102_database_1of2.zip"; mkzip "$Z/d2" "$T/stage/linuxamd64_12102_database_2of2.zip"
  else
    # 12.2: grid image, database staged in one zip
    mkdir -p "$Z/g/install/response"; grid_payload "$Z/g"; cp "$TD/mock_installer.py" "$Z/g/gridSetup.sh"
    cp "$TD/templates/grid19.rsp" "$Z/g/install/response/gridsetup.rsp"; mkzip "$Z/g" "$T/stage/linuxx64_12201_grid_home.zip"
    mkdir -p "$Z/d/database/response" "$Z/d/database/stage/payload"; cp "$TD/mock_installer.py" "$Z/d/database/runInstaller"
    cp "$TD/templates/db19.rsp" "$Z/d/database/response/db_install.rsp"; db_payload "$Z/d/database/stage/payload"
    mkzip "$Z/d" "$T/stage/linuxx64_12201_database.zip"
  fi
else
  mkdir -p "$Z/g/install/response" "$Z/d/install/response"
  grid_payload "$Z/g"; cp "$TD/mock_installer.py" "$Z/g/gridSetup.sh"; cp "$TD/templates/grid19.rsp" "$Z/g/install/response/gridsetup.rsp"
  db_payload "$Z/d"; cp "$TD/mock_installer.py" "$Z/d/runInstaller"; cp "$db_tpl" "$Z/d/install/response/db_install.rsp"
  if [[ "$MEDIA" == "gold" ]]; then gz=grid_home_2026-10-01_10-00-00AM.zip; dz=db_home_2026-10-01_10-00-00AM.zip
  else gz=LINUX.X64_${vtag}_grid_home.zip; dz=LINUX.X64_${vtag}_db_home.zip; fi
  mkzip "$Z/g" "$T/stage/$gz"; mkzip "$Z/d" "$T/stage/$dz"
fi
rm -rf "$Z"; chmod 755 "$T/stage"

# ---- primary model ----
if [[ "$STORAGE" == "fs" ]]; then
  LOCS='["'$T'/u02/oradata/PRODDB:600"]'
  PARAMS='{"remote_login_passwordfile": "EXCLUSIVE", "log_archive_dest_state_2": "DEFER", "db_create_file_dest": "", "db_recovery_file_dest": "'$T'/u03/fra", "db_recovery_file_dest_size": "2147483648", "log_archive_dest_1": "location=USE_DB_RECOVERY_FILE_DEST valid_for=(all_logfiles,all_roles)"}'
  CF='["'$T'/u02/oradata/PRODDB/control01.ctl", "'$T'/u03/fra/PRODDB/control02.ctl"]'
  REDO="$T/u02/oradata/PRODDB"; PW="$DBH/dbs/orapwPRODDB"; DATAMB=600
elif [[ "$STORAGE" == "mixed" ]]; then
  LOCS='["+DATA:100000", "'$T'/u02/oradata/PRODDB:400"]'
  PARAMS='{"remote_login_passwordfile": "EXCLUSIVE", "log_archive_dest_state_2": "DEFER", "db_create_file_dest": "+DATA", "db_recovery_file_dest": "+FRA", "db_recovery_file_dest_size": "53687091200", "log_archive_dest_1": "location=USE_DB_RECOVERY_FILE_DEST"}'
  CF='["+DATA/PRODDB/CONTROLFILE/current.261.1", "+FRA/PRODDB/CONTROLFILE/current.256.1"]'
  REDO="+DATA/PRODDB/ONLINELOG"; PW="+DATA/PRODDB/PASSWORD/pwdproddb.256.1111"; DATAMB=100400
else
  LOCS='["+DATA:120000"]'
  PARAMS='{"remote_login_passwordfile": "EXCLUSIVE", "log_archive_dest_state_2": "DEFER", "db_create_file_dest": "+DATA", "db_recovery_file_dest": "+FRA", "db_recovery_file_dest_size": "53687091200", "log_archive_dest_1": "location=USE_DB_RECOVERY_FILE_DEST"}'
  CF='["+DATA/PRODDB/CONTROLFILE/current.261.1", "+FRA/PRODDB/CONTROLFILE/current.256.1"]'
  REDO="+DATA/PRODDB/ONLINELOG"; PW="+DATA/PRODDB/PASSWORD/pwdproddb.256.1111"; DATAMB=120000
fi
ORA_IDS="uid=54321(oracle) gid=54321(oinstall) groups=54321(oinstall),54322(dba),54323(oper),54324(backupdba),54325(dgdba),54326(kmdba),54330(racdba),54328(asmdba)"
GRID_IDS="uid=54331(grid) gid=54321(oinstall) groups=54321(oinstall),54322(dba),54330(racdba),54327(asmadmin),54328(asmdba),54329(asmoper)"
[[ "$OWNER" == "single" ]] && ORA_IDS="$ORA_IDS,54327(asmadmin),54329(asmoper)" && GRID_IDS="$ORA_IDS"
LH=$GH; [[ $GRID == false ]] && LH=$DBH
cat > "$T/state/primary.json" <<EOF
{"ip": "127.0.0.2", "ssh_users": ["oracle"], "os_pw": "Oracle_os1",
 "host": "prim01.example.local", "sid": "PRODDB", "db_home": "$DBH", "grid_home": "$GH", "grid": $GRID,
 "single_owner": $([[ $OWNER == single ]] && echo true || echo false), "listener_home": "$LH",
 "inventory": "$INV", "oracle_base": "$OB", "grid_base": "$GB", "service": "proddb",
 "ids": {"oracle": "$ORA_IDS", "grid": "$GRID_IDS"},
 "stby_host": "$SH", "stby_ip": "$SIP", "stby_service": "proddb_stby", "stby_sid": "PRODDB_STBY",
 "unique": "proddb", "role": "PRIMARY", "name": "PRODDB", "cdb": "$([[ $MAJ -ge 21 ]] && echo YES || echo YES)", "domain": "",
 "version": "$VER", "log_mode": "NOARCHIVELOG", "force_logging": "NO",
 "orl": 3, "orl_bytes": 209715200, "srl": 0, "srl_bytes": 0, "threads": 1, "redo_dir": "$REDO",
 "locs": $LOCS, "params": $PARAMS, "controlfiles": $CF,
 "audit_dest": "$OB/admin/proddb/adump", "diag_dest": "$OB",
 "sys_in_pwfile": true, "pwfile": "$PW", "data_mb": $DATAMB, "temp_mb": 0, "seq": 42,
 "patches": ["35643107;Database Release Update : $VER (35643107)"],
 "grid_patches": [$([[ "$VER" == 12.1* ]] && printf '"35643107", "18370031"' || printf '"35643107"')],
 "tns_stby": 0, "static": 0, "hosts_stby": 0, "pw_tmp": 0}
EOF

ASMDIR=/dev/oracleasm/disks
LISTENER_ORA="$GH/network/admin/listener.ora"; [[ $GRID == false ]] && LISTENER_ORA="$DBH/network/admin/listener.ora"
cat > "$T/state/env.json" <<EOF
{"db_home": "$DBH", "grid_home": "$GH", "sid": "PRODDB_STBY", "pw": "Welcome_123", "major": $MAJ,
 "prim_tns": "proddb", "stby_tns": "proddb_stby", "stby_svc": "proddb_stby", "asm_disk_dir": "${DGT_ASMDIR:-$ASMDIR}",
 "listener_ora": "$LISTENER_ORA", "data_free": 500000, "local_version": "$VER"}
EOF

if [[ "$MODE" == "empty" ]]; then
  cat > "$T/state/standby.json" <<EOF
{"instances": {}, "srvctl": null, "srl_after_dup": 0, "has": 0, "asm": 0, "dgs": []}
EOF
  cat > "$T/state/os.json" <<EOF
{"rpms": [], "asm": {"enabled": false, "uid": "", "gid": "", "loaded": false, "disks": {}},
 "disks": {"/dev/sda": {"mnt": "/", "parts": 0, "size_mb": 51200}, "/dev/sdb": {"size_mb": 204800}, "/dev/sdc": {"size_mb": 102400},
           "/dev/sdd": {"fs": "ext4"}, "/dev/sde": {"pttype": "gpt"}},
 "parts": {}, "services": {"firewalld": false, "chronyd": false}}
EOF
else
  for g in $GROUPS_LIST; do groupadd -g "${g##*:}" "${g%%:*}"; done
  useradd -m -s /bin/bash -u 54321 -g oinstall -G dba oracle          # deliberately missing groups (fixed by 2.2)
  [[ "$OWNER" == "two" ]] && useradd -m -s /bin/bash -u 54331 -g oinstall -G dba,racdba,asmadmin,asmdba,asmoper grid
  mkdir -p "$DBH" "$INV/ContentsXML"; db_payload "$DBH"
  printf '<INVENTORY><HOME_LIST>\n<HOME NAME="d" LOC="%s"/>\n' "$DBH" > "$INV/ContentsXML/inventory.xml"
  if [[ $GRID == true ]]; then
    mkdir -p "$GH" "$GB"; grid_payload "$GH"; printf '<HOME NAME="g" LOC="%s"/>\n' "$GH" >> "$INV/ContentsXML/inventory.xml"
    mkdir -p /etc/oracle; echo "olrconfig_loc=x" > /etc/oracle/olr.loc
    cat > "$GH/network/admin/listener.ora" <<EOF
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = $SH)(PORT = 1521)))
  )
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = proddb_stby)
      (SID_NAME = PRODDB_STBY)
      (ORACLE_HOME = $GH)
    )
  )
EOF
    chown -R "$GU":oinstall "$GH" "$GB"
  fi
  printf 'inventory_loc=%s\ninst_group=oinstall\n' "$INV" > /etc/oraInst.loc
  cat > "$DBH/network/admin/tnsnames.ora" <<EOF
proddb =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = prim01)(PORT = 1521))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = proddb)(UR = A))
  )
EOF
  chown -R oracle:oinstall "$OB"
  if $GRID; then chown -R "$GU":oinstall "$INV"; else chown -R oracle:oinstall "$INV"; fi   # no Grid -> the inventory belongs to oracle
  chown root "$DBH/bin/oradism"
  [[ "$OWNER" == "two" && $GRID == true ]] && chgrp asmadmin "$DBH/bin/oracle"
  chmod -R 755 "$T/u01"; chmod 775 "$T/u01/app"
  if [[ $GRID == true ]]; then
    cat > "$T/state/standby.json" <<EOF
{"instances": {}, "srvctl": null, "srl_after_dup": 0, "has": 1, "asm": 1, "dgs": ["DATA", "FRA"]}
EOF
    DISKS='{"DATA1": "/dev/sdb1", "FRA1": "/dev/sdc1"}'
  else
    cat > "$T/state/standby.json" <<EOF
{"instances": {}, "srvctl": null, "srl_after_dup": 0, "has": 0, "asm": 0, "dgs": []}
EOF
    DISKS='{}'
  fi
  cat > "$T/state/os.json" <<EOF
{"rpms": ["oracle-database-preinstall-19c", "oracle-database-preinstall-21c", "oracle-database-preinstall-18c", "oracle-database-server-12cR2-preinstall", "oracle-rdbms-server-12cR1-preinstall", "oracle-database-preinstall-23ai", "oracleasm-support", "unzip", "chrony", "parted", "bc"],
 "asm": {"enabled": true, "uid": "$GU", "gid": "asmadmin", "loaded": true, "disks": $DISKS},
 "disks": {"/dev/sda": {"mnt": "/", "parts": 1, "size_mb": 51200}, "/dev/sdb": {"parts": 1, "size_mb": 204800}, "/dev/sdc": {"parts": 1, "size_mb": 102400}},
 "parts": {"/dev/sdb1": "/dev/sdb", "/dev/sdc1": "/dev/sdc"},
 "services": {"firewalld": false, "chronyd": true}}
EOF
fi
chmod 666 "$T"/state/*.json
cp "$TD/../dg_standby_setup.sh" "$T/dg_standby_setup.sh"; chmod 750 "$T/dg_standby_setup.sh"

nohup python3 -c "
import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.2',1521)); s.listen(50)
while True:
    c,_=s.accept(); c.close()
" dgt_port_listener >/dev/null 2>&1 &
sleep 0.5
echo "mock environment ($MODE, storage=$STORAGE, version=$VER, owner=$OWNER, media=$MEDIA, OL$OSV) ready in $T"
