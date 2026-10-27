#------------------------------------------------------------------------------
# Help: manual commands for every step  (h at any question, or --help-step X.Y)
#------------------------------------------------------------------------------
readonly HELP_IDS=(1.1 1.2 1.3 1.4 1.5 1.6
  2.1 2.2 2.3 2.4 2.5 2.6 2.7 2.8 2.9 2.10 2.11 2.12 2.13 2.14 2.15
  3.1 3.2 3.3 3.4 3.5 3.6 3.7 3.8 3.9 3.10 3.11
  4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9 4.10 4.11
  5.1 5.2 5.3 5.4 6.1 6.2 6.3 7.1 7.2 7.3 7.4 7.5 7.6 7.7 8.1 8.2
  9.1 9.2 9.3 9.4 9.5 9.6 9.7 9.8 10.1 10.2 10.3 10.4)

help_text() {
  local P=${PRIMARY_HOST:-<primary>} S=${STANDBY_HOST:-<standby>} SID=${STANDBY_SID:-<standby SID>}
  local PU=${PRIMARY_UNIQUE:-<primary unique>} SU=${STANDBY_UNIQUE:-<standby unique>}
  local PT=${PRIMARY_TNS:-<primary alias>} ST=${STANDBY_TNS:-<standby alias>}
  local DBH=${DB_HOME:-<db home>} GH=${GRID_HOME:-<grid home>} OU=${ORACLE_USER:-oracle} GU=${GRID_USER:-grid}
  local IG=${INSTALL_GROUP:-oinstall} LN=${LISTENER_NAME:-LISTENER} PO=${PORT:-1521} SL=$SB_LSNR
  local DD=${DATA_DG:-DATA} PS=${PRIMARY_SID:-<primary SID>}
  local PSV=${PRIMARY_SERVICE:-<primary service>} SSV=${STANDBY_SERVICE:-<standby service>}
  local OB=${ORACLE_BASE:-<oracle base>} GB=${GRID_BASE:-<grid base>} INV=${INVENTORY_DIR:-<inventory>}
  local PTA=${PRIMARY_TNS_ADMIN:-\$ORACLE_HOME/network/admin} PLH=${PRIMARY_LISTENER_HOME:-<listener home on primary>}
  local G=0 SO=0; [[ "${USE_GRID:-}" == "yes" ]] && G=1; [[ "$OU" == "$GU" ]] && SO=1
  local LH LU; if [[ $G -eq 1 ]]; then LH=$GH; LU=$GU; else LH=$DBH; LU=$OU; fi
  local AG; AG=$( [[ -n "${GRID_PGROUP:-}" ]] && grp_or asmadmin "$GRID_PGROUP" 2>/dev/null || printf 'asmadmin')
  local DGS; DGS=$( [[ -n "${LOCS:-}" ]] && asm_dgs 2>/dev/null | paste -sd' ' - ); DGS=${DGS:-DATA FRA}
  # SQL on the primary by hand: the exact home and SID, so the environment of the user there does not matter
  local PSQL="as $OU:  export ORACLE_HOME=$DBH ORACLE_SID=$PS ; \$ORACLE_HOME/bin/sqlplus / as sysdba"
  local SSQL="as $OU:  export ORACLE_HOME=$DBH ORACLE_SID=$SID ; \$ORACLE_HOME/bin/sqlplus / as sysdba"
  # 12.1 has no v$dataguard_process: the same information comes from v$managed_standby
  local DGP="v\$dataguard_process" DGN=name DGR=role DGS2=action
  [[ "${PRIMARY_VERSION:-}" == 12.1* ]] && { DGP="v\$managed_standby"; DGN=process; DGR=process; DGS2=status; }
  case "$1" in
  1.1) cat <<EOF
TITLE  Run as root on the standby server
WHERE  STANDBY ($S), user root
RUN    whoami
       hostname -s
EXPECT root, and the standby host name (never the primary)
EOF
  ;;
  1.2) cat <<EOF
TITLE  ssh connection to primary
WHERE  STANDBY ($S), user root
WHY    The script opens ONE ssh connection and sends only read-only commands over it.
RUN    ssh ${PRIMARY_SSH_USER:-oracle}@${PRIMARY_IP:-<primary IP>} hostname
EXPECT the primary host name, after you typed the password
IF     "Permission denied": wrong password, or PasswordAuthentication no in /etc/ssh/sshd_config on primary
       "Connection refused/timed out": sshd or firewall on primary (port 22)
EOF
  ;;
  1.3) cat <<EOF
TITLE  Read the primary configuration (read-only)
WHERE  PRIMARY ($P), user ${PRIMARY_SSH_USER:-oracle}
RUN    ps -eo pid,user,args | grep -E 'ora_pmon|tnslsnr'
       cat /etc/oratab ; cat /etc/oraInst.loc
       id $OU ; id $GU
       $DBH/bin/orabase
       $PSQL
       select name, db_unique_name, database_role, cdb from v\$database;
EXPECT role PRIMARY. The ssh user must be able to run "sqlplus / as sysdba" (dba group).
EOF
  ;;
  1.4) cat <<EOF
TITLE  Standby settings
WHERE  STANDBY ($S), file ${SETTINGS_FILE:-/var/lib/dg_standby_setup/settings.conf}
WHY    Paths, users and groups are the same as primary and are read from it at every run.
       Only the values under "Standby values" can be changed (names, installer files, RU_DIR, OPATCH_ZIP).
RUN    choose a to accept, or e to edit (KEY=VALUE lines, no spaces). Later: --settings
EXPECT STANDBY_UNIQUE differs from $PU, STANDBY_SID at most 12 characters
EOF
  ;;
  1.5) cat <<EOF
TITLE  sys password
WHERE  STANDBY ($S)
WHY    Needed for RMAN and the login tests. Kept in memory only, never written to disk or log.
RUN    on primary:  $OU ->  $DBH/bin/sqlplus sys@//localhost:$PO/$PSV as sysdba
EXPECT Connected
IF     ORA-01017: wrong password, or SYS not in the password file (step 4.7)
EOF
  ;;
  1.6) cat <<EOF
TITLE  Oracle version supported on this Oracle Linux
WHERE  STANDBY ($S)
WHY    12.1, 12.2 and 18c: Oracle Linux 7 only.  19c: OL7, OL8 (the 19.3 installer gets CV_ASSUME_DISTID=OEL7.8),
       OL9 only with Release Update 19.19+ applied by the installer (-applyRU).  21c: OL7/8/9.  23ai: OL8/9.
RUN    cat /etc/os-release
       for 19c on OL9: unzip the RU (with Grid: the GI Release Update) to a folder, put the newest OPatch zip
       (p6880880) on this server, and set RU_DIR=<folder> and OPATCH_ZIP=<zip> in the settings (step 1.4, e)
EXPECT a supported pair
EOF
  ;;
  2.1) cat <<EOF
TITLE  Groups (same names and ids as primary)
WHERE  STANDBY ($S), user root
RUN    getent group $(tr ',' ' ' <<< "${GROUP_GIDS:-oinstall:54321}" | sed 's/:[0-9]*//g')
       groupadd -g <gid> <name>      for each missing group (gid as on primary)
EXPECT the same gid as on primary:  ${GROUP_GIDS:-<name:gid list>}
IF     a group exists with another gid and nothing is installed yet:  groupmod -g <gid> <name>
EOF
  ;;
  2.2)
    printf 'TITLE  Users (same ids as primary)\nWHERE  STANDBY (%s), user root\n' "$S"
    printf 'RUN    useradd -m -s /bin/bash -u %s -g %s%s %s\n' "${ORACLE_UID:-<uid>}" "$IG" "${ORACLE_GROUPS:+ -G $ORACLE_GROUPS}" "$OU"
    [[ $SO -eq 0 && $G -eq 1 ]] && printf '       useradd -m -s /bin/bash -u %s -g %s%s %s\n' "${GRID_UID:-<uid>}" "${GRID_PGROUP:-oinstall}" "${GRID_GROUPS:+ -G $GRID_GROUPS}" "$GU"
    printf '       passwd <user>      (optional)\nEXPECT id %s   -> same numbers and groups as on primary\n' "$OU"
  ;;
  2.3) cat <<EOF
TITLE  Required packages
WHERE  STANDBY ($S), user root
RUN    ${PKG:-dnf} install -y <package>        one by one: <preinstall> unzip chrony parted bc
       <preinstall> by version:  12.1 oracle-rdbms-server-12cR1-preinstall   12.2 oracle-database-server-12cR2-preinstall
                                 18c oracle-database-preinstall-18c   19c ...-19c   21c ...-21c   23ai ...-23ai
       with ASMLib also:  oracleasm-support
EXPECT Complete!
IF     "No package available": enable the repository (yum repolist / dnf repolist), for example ol7_latest, ol8_appstream
EOF
  ;;
  2.4) cat <<EOF
TITLE  Limits for the Oracle owners
WHERE  STANDBY ($S), user root, file /etc/security/limits.d/oracle-grid.conf
WHY    The preinstall package sets limits only for the user named "oracle". Every other owner needs them.
RUN    <user> soft nofile 1024     <user> hard nofile 65536
       <user> soft nproc 16384     <user> hard nproc 16384
       <user> soft stack 10240     <user> hard stack 32768
       <user> soft memlock unlimited   <user> hard memlock unlimited
EXPECT as <user> after a new login:  ulimit -Hn  -> 65536
EOF
  ;;
  2.5)
    printf 'TITLE  Software folders\nWHERE  STANDBY (%s), user root\n' "$S"
    if [[ $G -eq 1 ]]; then
      printf 'RUN    mkdir -p %s %s %s %s %s\n' "$GB" "$GH" "$INV" "$OB" "$DBH"
      printf '       chown %s:%s %s %s %s ; chown %s:%s %s %s\n' "$GU" "$IG" "$GB" "$GH" "$INV" "$OU" "$IG" "$OB" "$DBH"
    else
      printf 'RUN    mkdir -p %s %s %s\n' "$INV" "$OB" "$DBH"
      printf '       chown %s:%s %s %s %s\n' "$OU" "$IG" "$INV" "$OB" "$DBH"
    fi
    printf 'EXPECT ls -ld %s  -> owner %s\nWHY    The script never changes the owner of a folder that already has files.\n' "$DBH" "$OU"
  ;;
  2.6) cat <<EOF
TITLE  Host names on this server
WHERE  STANDBY ($S), user root, file /etc/hosts
RUN    getent ahostsv4 $P ; getent ahostsv4 $S
       if missing, add:  ${PRIMARY_IP:-<primary IP>}  $P      and   ${STANDBY_IP:-<standby IP>}  $S
EXPECT the right IPv4 address for both names (never 127.x for $S)
EOF
  ;;
  2.7) cat <<EOF
TITLE  Primary resolves the standby host name
WHERE  PRIMARY ($P), user root, file /etc/hosts
RUN    getent hosts $S
       if missing:  echo '${STANDBY_IP:-<standby IP>}    $S' >> /etc/hosts
EXPECT the standby IP
EOF
  ;;
  2.8) cat <<EOF
TITLE  Network to the primary listener
WHERE  STANDBY ($S), user root
RUN    timeout 5 bash -c "</dev/tcp/${PRIMARY_IP:-<primary IP>}/$PO" && echo OPEN
EXPECT OPEN
IF     no output: on PRIMARY as root  firewall-cmd --permanent --add-port=$PO/tcp ; firewall-cmd --reload
EOF
  ;;
  2.9) cat <<EOF
TITLE  Firewall on this server
WHERE  STANDBY ($S), user root
RUN    firewall-cmd --get-active-zones            (the zone of the network interface)
       firewall-cmd --permanent --zone=<zone> --add-port=$PO/tcp
       firewall-cmd --reload
EXPECT firewall-cmd --zone=<zone> --query-port=$PO/tcp  -> yes   (or firewalld not running)
EOF
  ;;
  2.10) cat <<EOF
TITLE  Time synchronization
WHERE  BOTH servers, user root
RUN    systemctl enable --now chronyd        (a running ntpd is also fine)
       chronyc tracking
EXPECT Leap status : Normal
EOF
  ;;
  2.11)
    printf 'TITLE  Environment (.bash_profile) of the Oracle users\nWHERE  STANDBY (%s), ~/.bash_profile of %s%s\n' "$S" "$OU" "$([[ $G -eq 1 && $SO -eq 0 ]] && printf ' and of %s' "$GU")"
    printf 'WHY    The script itself does not need it, but sqlplus/rman/srvctl by hand do.\n'
    printf 'RUN    %s:  export ORACLE_BASE=%s ; export ORACLE_HOME=%s ; export ORACLE_SID=%s\n' "$OU" "$OB" "$DBH" "$SID"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '       %s:  export ORACLE_BASE=%s ; export ORACLE_HOME=%s ; export ORACLE_SID=+ASM\n' "$GU" "$GB" "$GH"
    printf '       export PATH=$ORACLE_HOME/bin:$PATH\n'
    printf "EXPECT su - %s -c 'echo \$ORACLE_SID \$ORACLE_HOME'   ->  %s %s   (exact case)\n" "$OU" "$SID" "$DBH"
    printf 'IF     a wrong value comes from ~/.bashrc or /etc/profile.d: the last export wins; fix those lines\n'
  ;;
  2.12) cat <<EOF
TITLE  ASM disk method
WHERE  STANDBY ($S), user root
WHY    ASMLib needs the UEK kernel (Oracle Linux 7/8). Otherwise udev rules are used: they work on every kernel.
RUN    ASMLib:  oracleasm configure -u $GU -g $AG -e -s y ; oracleasm init ; systemctl enable oracleasm ; oracleasm status
       udev:    nothing to configure here (one rule per disk in step 2.13); set ASM_METHOD=udev in the settings
EXPECT ASMLib: "Checking if ASM is loaded: yes", and systemctl is-enabled oracleasm -> enabled
EOF
  ;;
  2.13) cat <<EOF
TITLE  ASM disks (one or more per disk group, same disk group names as primary: $DGS)
WHERE  STANDBY ($S), user root
WHY    The disks must be EMPTY (also the first MiB). Everything on them is erased. Labels: <DG>_1, <DG>_2 ...
RUN    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,WWN
       for every disk:  parted -s <disk> mklabel gpt mkpart primary 1MiB 100% ; partprobe <disk>
       (the partition is <disk>1, or <disk>p1 for nvme disks)
       ASMLib:  oracleasm createdisk ${DD}_1 <partition> ; oracleasm scandisks ; oracleasm listdisks
       udev:    udevadm info --query=property --name=<partition> | grep ID_PART_ENTRY_UUID
                echo 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_UUID}=="<uuid>", SYMLINK+="oraasm/${DD}_1", OWNER="$GU", GROUP="$AG", MODE="0660"' >> /etc/udev/rules.d/99-oracle-asmdevices.rules
                udevadm control --reload-rules ; udevadm trigger --action=change ; ls -lL /dev/oraasm/
       then add the label to ${STATE_DIR}/asm_disks as  LABEL|partition  (or answer y when the script asks to use it;
       a disk that already belongs to a disk group is used only when THIS server's ASM has that group mounted)
EXPECT ${DD}_1 (${DD}_2 ...) for every disk group, big enough (database size + 10%)
IF     the script says the disk has data and you are SURE it is free:  wipefs -a <disk> ; dd if=/dev/zero of=<disk> bs=1M count=10
       multipath (SAN): a partition on a multipath device is matched with ENV{DM_UUID}=="part1-mpath-<wwid>"
                (the whole device: "mpath-<wwid>"); then add the line  <LABEL>|/dev/mapper/<name>  to STATE_DIR/asm_disks
EOF
  ;;
  2.14) cat <<EOF
TITLE  Database folders and free space (primary stores files in folders, not in ASM)
WHERE  STANDBY ($S), user root
WHY    The standby uses exactly the same paths as primary (no file name conversion).
RUN    df -h <each folder of primary>
       mkdir -p <folder> ; chown $OU:$IG <folder>
       not enough space: new disk -> mkfs.xfs /dev/<empty disk> ; mount it at the same path ; add it to /etc/fstab
EXPECT every folder exists, owner $OU, and its file system has the space of primary + 10%
EOF
  ;;
  2.15) cat <<EOF
TITLE  Database folders are not shared with the primary
WHERE  STANDBY ($S), user root
WHY    With the same paths, a folder that is the primary's NFS export or SAN volume would be overwritten by the copy.
RUN    touch <folder>/test_from_standby
       on primary:  ls -l <folder>/test_from_standby       -> must say: No such file or directory
       rm <folder>/test_from_standby
EXPECT the primary does not see the file
       (a built standby: the proof was given before the copy; the step says so)
       The same file system UUID on both servers (findmnt -o SOURCE,UUID --target <folder>) means a copy of
       the primary's disk or the SAME disk mounted twice: compare the disks on both servers:
         lsblk -s -o NAME,TYPE,WWN,SERIAL,SIZE \$(findmnt -n -o SOURCE --target <folder>)
       Change nothing on such a disk before you know which it is.
EOF
  ;;
  3.1)
    printf 'TITLE  Installer files\nWHERE  PRIMARY (%s) for a gold image, then STANDBY (%s) as root\n' "$P" "$S"
    if [[ ${DB_MAJOR:-19} -ge 18 ]]; then
      printf 'RUN    best: a gold image of the primary home, it has the same patches:\n'
      printf '         on primary as %s:  mkdir -p /tmp/gold ; %s/runInstaller -silent -createGoldImage -destinationLocation /tmp/gold\n' "$OU" "$DBH"
      [[ $G -eq 1 ]] && printf '         on primary as %s:  mkdir -p /tmp/gold ; %s/gridSetup.sh -silent -createGoldImage -destinationLocation /tmp/gold\n' "$GU" "$GH"
      printf '         here as root:  mkdir -p /stage ; scp %s@%s:/tmp/gold/*.zip /stage/\n' "${PRIMARY_SSH_USER:-oracle}" "${PRIMARY_IP:-<primary IP>}"
      printf '       or the base files: LINUX.X64_<180000|193000|213000>_db_home.zip (and _grid_home.zip), 23ai from edelivery\n'
    else
      printf 'RUN    the base files: 12.1 linuxamd64_12102_database_1of2.zip + 2of2 (grid: linuxamd64_12102_grid_1of2.zip + 2of2)\n'
      printf '                       12.2 linuxx64_12201_database.zip (grid: linuxx64_12201_grid_home.zip)\n'
    fi
    printf '       chmod 644 /stage/*.zip   (owner root, %s or %s; nobody else may be able to change them)\n' "$OU" "$GU"
    printf 'EXPECT the script finds them (it searches %s)\n' "${ZIP_DIRS[*]}"
  ;;
  3.2) cat <<EOF
TITLE  Grid Infrastructure software (Oracle Restart) - only when the primary uses ASM
WHERE  STANDBY ($S), user $GU
RUN    12.2 and newer: cd $GH ; unzip -q <grid zip> ; ./gridSetup.sh   (with an RU: -applyRU <folder>)
       12.1:           unzip both zips into a stage folder ; ./grid/runInstaller
       choices: Standalone Server (Oracle Restart), disk group $DD, External, discovery path
       /dev/oracleasm/disks/* (ASMLib) or /dev/oraasm/* (udev), base $GB
EXPECT installer finishes; it asks to run the root scripts (step 3.3)
IF     logs:  $INV/logs/   INS-08101 on OL8/9: the OS is newer than the installer (use an RU, step 1.6)
EOF
  ;;
  3.3) cat <<EOF
TITLE  Grid root scripts
WHERE  STANDBY ($S), user root
RUN    $INV/orainstRoot.sh
       $GH/root.sh
       12.1 on Oracle Linux 7: patch 18370031 first:  $GH/OPatch/opatch napply -oh $GH -local <patch folder>
EXPECT as $GU:  crsctl check has  -> CRS-4638 Oracle High Availability Services is online
IF     root.sh failed:  $GH/crs/install/roothas.sh -deconfig -force ; then $GH/root.sh again
EOF
  ;;
  3.4) cat <<EOF
TITLE  ASM and listener (Grid configuration)
WHERE  STANDBY ($S), user $GU
RUN    12.2+:  $GH/gridSetup.sh -executeConfigTools -responseFile <file> -silent
       12.1:   $GH/cfgtoollogs/configToolAllCommands RESPONSE_FILE=<file with the ASM passwords>
       if HAS is stopped (root):  $GH/bin/crsctl start has
       if ASM is offline:         crsctl start res ora.asm
EXPECT crsctl stat res -t  ->  ora.asm ONLINE, ora.$SL.lsnr ONLINE, ora.${DD^^}.dg ONLINE
EOF
  ;;
  3.5) cat <<EOF
TITLE  ASM disk groups (same names as primary: $DGS)
WHERE  STANDBY ($S), user $GU, sqlplus / as sysasm
RUN    create diskgroup <DG> external redundancy disk '<disk path>' attribute 'compatible.asm'='<as $DD>', 'compatible.rdbms'='<as $DD>';
       asmcmd lsdg
EXPECT every disk group of primary is MOUNTED
IF     exists but dismounted:  alter diskgroup <DG> mount;
EOF
  ;;
  3.6) cat <<EOF
TITLE  Database software (Software Only)
WHERE  STANDBY ($S), user $OU
RUN    18c and newer: cd $DBH ; unzip -q <db zip or gold image> ; ./runInstaller   (with an RU: -applyRU <folder>)
       12.x:          unzip the zip(s) into a stage folder ; ./database/runInstaller
       choices: Set Up Software Only, Single instance, Enterprise Edition, home $DBH, base $OB
EXPECT installer finishes; then step 3.7
EOF
  ;;
  3.7)
    printf 'TITLE  Database root.sh\nWHERE  STANDBY (%s), user root\n' "$S"
    printf 'RUN    %s/orainstRoot.sh      (only if /etc/oraInst.loc does not exist yet)\n       %s/root.sh\n' "$INV" "$DBH"
    printf 'EXPECT ls -l %s/bin/oradism  -> owner root\n' "$DBH"
  ;;
  3.8) cat <<EOF
TITLE  Read/write Oracle home (18c and newer)
WHERE  STANDBY ($S), user $OU
WHY    18c+ can install a read-only home; this setup keeps spfile, password file and tnsnames.ora in the home.
RUN    $DBH/bin/orabasehome
       $DBH/bin/roohctl -disable      (only on a NEW home without any database)
EXPECT orabasehome prints $DBH
EOF
  ;;
  3.9) cat <<EOF
TITLE  Oracle Restart resources ONLINE
WHERE  STANDBY ($S), user $GU
RUN    crsctl stat res -t
       crsctl start res <name>                   (for each OFFLINE one)
       srvctl add listener -listener $SL -endpoints TCP:$PO ; srvctl start listener -listener $SL   (if missing)
EXPECT ora.asm, ora.$SL.lsnr and ora.<DG>.dg ONLINE for: $DGS
EOF
  ;;
  3.10) cat <<EOF
TITLE  Listener port equal to primary
WHERE  STANDBY ($S), user $GU
WHY    The standby listener is always called $SL (Grid creates it); only the port must be the same as on primary.
RUN    srvctl modify listener -listener $SL -endpoints TCP:$PO
       srvctl stop listener -listener $SL ; srvctl start listener -listener $SL
EXPECT lsnrctl status $SL  ->  (PORT=$PO)
EOF
  ;;
  3.11)
    printf 'TITLE  Same release and patches as primary\nWHERE  BOTH servers, user %s\n' "$OU"
    printf 'RUN    <home>/OPatch/opatch lspatches       (on both servers and for every home: the lists must be equal)\n'
    printf '       %s/bin/sqlplus -V                   (the same release)\n' "$DBH"
    printf 'IF     different:  newest OPatch (patch 6880880) into the homes, then\n'
    if [[ $G -eq 1 ]]; then
      printf '                   as root:  %s/OPatch/opatchauto apply <RU folder> -oh %s\n' "$GH" "$GH"
      printf '                   as root:  %s/OPatch/opatchauto apply <RU folder> -oh %s\n' "$DBH" "$DBH"
    else
      printf '                   as %s:  cd <RU folder> ; %s/OPatch/opatch apply\n' "$OU" "$DBH"
    fi
    printf '                   one-off patches as %s:  cd <patch> ; %s/OPatch/opatch apply\n' "$OU" "$DBH"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '                   then as root:  %s/bin/setasmgidwrap o=%s/bin/oracle\n' "$GH" "$DBH"
    [[ ${DB_MAJOR:-19} -ge 18 ]] && printf '       easier: install from a gold image of the primary home (step 3.1)\n'
    true
  ;;
  4.1) cat <<EOF
TITLE  ARCHIVELOG and FORCE LOGGING
WHERE  PRIMARY ($P), $PSQL
RUN    select value from v\$parameter where name='spfile';
       -- empty: the primary runs from a text pfile; first (one restart):
       --   create pfile='/tmp/init<SID>_before_dg.ora' from memory;  create spfile from memory;  then restart
       select log_mode, force_logging from v\$database;
       alter database force logging;
       -- NOARCHIVELOG only (short downtime): shutdown immediate / startup mount /
       -- alter database archivelog; / alter database open;
EXPECT ARCHIVELOG  YES
EOF
  ;;
  4.2) cat <<EOF
TITLE  Standby redo logs on primary
WHERE  PRIMARY ($P), $PSQL
RUN    select thread#, count(*), max(bytes)/1024/1024 mb, max(blocksize) from v\$log group by thread#;
       select thread#, count(*) from v\$standby_log group by thread#;
       -- per thread: (online groups + 1), size = largest online log (blocksize 4096 if the online logs have it)
       with OMF/ASM:  alter database add standby logfile thread 1 size <M>M;
       without OMF:   alter database add standby logfile thread 1 group <n> ('<redo folder>/srl_t1_g<n>.log') size <M>M;
EXPECT standby logs = online groups + 1 for every thread
EOF
  ;;
  4.3) cat <<EOF
TITLE  log_archive_config
WHERE  PRIMARY ($P), $PSQL
RUN    show parameter log_archive_config
       alter system set log_archive_config='dg_config=(<names already in the list>,$PU,$SU)' scope=both;
       -- keep every name that is already in the list (another standby would stop receiving redo)
EXPECT show parameter log_archive_config  -> both names
EOF
  ;;
  4.4) cat <<EOF
TITLE  log_archive_dest_N for the standby
WHERE  PRIMARY ($P), $PSQL
WHY    Usually N = 2. If dest_2 is already used for something else, the script uses the first free N.
RUN    alter system set log_archive_dest_state_N=defer scope=both;
       alter system set log_archive_dest_N='service=$ST async valid_for=(online_logfiles,primary_role) db_unique_name=$SU' scope=both;
IF     ORA-16018 (the old parameter log_archive_dest is used): first
       alter system set log_archive_dest='' scope=both; alter system set log_archive_dest_1='location=<same folder>' scope=both;
EXPECT show parameter log_archive_dest_N
EOF
  ;;
  4.5) cat <<EOF
TITLE  standby_file_management
WHERE  PRIMARY ($P), $PSQL
RUN    alter system set standby_file_management=auto scope=both;
EXPECT AUTO
EOF
  ;;
  4.6) cat <<EOF
TITLE  Archive destination / recovery area
WHERE  PRIMARY ($P), $PSQL
RUN    show parameter log_archive_dest_1
       show parameter db_recovery_file_dest
       -- if neither is set:
       alter system set db_recovery_file_dest_size=200G scope=both;
       alter system set db_recovery_file_dest='<+DG or folder>' scope=both;
EXPECT log_archive_dest_1 LOCATION=... or a recovery area
EOF
  ;;
  4.7) cat <<EOF
TITLE  Password file and SYS
WHERE  PRIMARY ($P), $PSQL
RUN    show parameter remote_login_passwordfile
       select username, sysdba from v\$pwfile_users;
       alter user sys identified by "<the same sys password>";     -- if SYS is missing and a password file exists
       -- no password file at all (in a SHELL as $OU; orapwd asks for the password):
       --   file system: orapwd file=\$ORACLE_HOME/dbs/orapw$PS format=12.2     (12.1: format=12)
       --   ASM:         orapwd file='+<DG>/$PU/orapw<db>' dbuniquename=$PU format=12.2
EXPECT EXCLUSIVE (or SHARED), and SYS TRUE
EOF
  ;;
  4.8) cat <<EOF
TITLE  fal_server on primary (optional)
WHERE  PRIMARY ($P), $PSQL
WHY    Used only after a switchover. Skip it if you want.
RUN    alter system set fal_server='$ST' scope=both;
EXPECT $ST
EOF
  ;;
  4.9) cat <<EOF
TITLE  Primary tnsnames.ora has the standby alias
WHERE  PRIMARY ($P), user $OU, file $PTA/tnsnames.ora
RUN    $ST =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $S)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $SSV)(UR = A))
         )
       $DBH/bin/tnsping $ST
EXPECT "Used TNSNAMES adapter" and OK
EOF
  ;;
  4.10) cat <<EOF
TITLE  Primary static listener entry (optional, for switchover)
WHERE  PRIMARY ($P), owner of $PLH, file $PLH/network/admin/listener.ora
WHY    Needed for switchover and the broker, not for building the standby. You may skip it.
RUN    SID_LIST_$LN =
         (SID_LIST =
           (SID_DESC =
             (GLOBAL_DBNAME = $PSV)
             (SID_NAME = $PS)
             (ORACLE_HOME = $DBH)
           )
         )
       $PLH/bin/lsnrctl reload $LN
EXPECT lsnrctl status $LN  -> Instance "$PS", status UNKNOWN
EOF
  ;;
  4.11) cat <<EOF
TITLE  Environment of $OU on primary (optional, information only)
WHERE  PRIMARY ($P), user $OU, file ~/.bash_profile
WHY    The script does not use it, but sqlplus / rman / dgmgrl by hand need the right values.
RUN    export ORACLE_BASE=$OB
       export ORACLE_HOME=$DBH
       export ORACLE_SID=$PS
       export PATH=\$ORACLE_HOME/bin:\$PATH
EXPECT after a new login:  echo \$ORACLE_SID  ->  $PS
EOF
  ;;
  5.1)
    printf 'TITLE  Static listener entry on standby\nWHERE  STANDBY (%s), user %s, file %s/network/admin/listener.ora\n' "$S" "$LU" "$LH"
    printf 'WHY    In NOMOUNT the instance cannot register itself. ORACLE_HOME must be the DATABASE home;\n       with the Grid home you get ORA-01017 through the listener.\n'
    [[ $G -eq 0 ]] && printf 'RUN    without Grid, define the listener too:\n       %s = (DESCRIPTION_LIST = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))))\n' "$SL" "$S" "$PO"
    [[ $G -eq 1 ]] && printf 'RUN    add:\n'
    printf '       SID_LIST_%s =\n         (SID_LIST =\n           (SID_DESC =\n             (GLOBAL_DBNAME = %s)\n             (SID_NAME = %s)\n             (ORACLE_HOME = %s)\n           )\n         )\n' "$SL" "$SSV" "$SID" "$DBH"
    printf 'EXPECT see step 5.2\n'
  ;;
  5.2) cat <<EOF
TITLE  Listener shows the static entry
WHERE  STANDBY ($S), user $LU
RUN    $LH/bin/lsnrctl start $SL      (only when it is not running and there is no Grid)
       $LH/bin/lsnrctl reload $SL
       $LH/bin/lsnrctl status $SL
EXPECT Instance "$SID", status UNKNOWN   and   (PORT=$PO)
EOF
  ;;
  5.3|5.4) cat <<EOF
TITLE  tnsnames.ora on standby
WHERE  STANDBY ($S), user $OU, file $DBH/network/admin/tnsnames.ora
RUN    $PT =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $P)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $PSV)(UR = A))
         )
       $ST =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $S)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $SSV)(UR = A))
         )
       tnsping $PT ; tnsping $ST
EXPECT OK for both, with the right HOST
EOF
  ;;
  6.1) cat <<EOF
TITLE  Password file = copy of the primary file
WHERE  PRIMARY then STANDBY
RUN    on primary:  $PSQL  ->  select file_name from v\$passwordfile_info (12.2+; 12.1: file_name only, or \$ORACLE_HOME/dbs/orapw<SID>);
       if it starts with +, on primary as $GU (export ORACLE_HOME=$GH ORACLE_SID=+ASM):
         rm -f /tmp/orapw_for_standby_$SID
         \$ORACLE_HOME/bin/asmcmd pwcopy '<file_name>' /tmp/orapw_for_standby_$SID
         chgrp $IG /tmp/orapw_for_standby_$SID ; chmod 640 /tmp/orapw_for_standby_$SID
       on standby as root:
         scp ${PRIMARY_SSH_USER:-oracle}@$P:<file or /tmp copy> $DBH/dbs/orapw$SID
         chown $OU:$IG $DBH/dbs/orapw$SID ; chmod 640 $DBH/dbs/orapw$SID
EXPECT md5sum equal on both servers; orapwd describe file=$DBH/dbs/orapw$SID shows a format (12.2+)
EOF
  ;;
  6.2) cat <<EOF
TITLE  Remove the temporary copy on primary
WHERE  PRIMARY ($P)
RUN    rm -f /tmp/orapw_for_standby_$SID
EXPECT ls /tmp/orapw_for_standby_$SID  -> No such file
EOF
  ;;
  6.3) cat <<EOF
TITLE  TDE wallet (only if the primary uses encryption)
WHERE  PRIMARY then STANDBY
RUN    on primary:  $PSQL  ->  select wrl_type, wrl_parameter, status, wallet_type from v\$encryption_wallet;
       copy ewallet.p12 (and cwallet.sso, unless wallet_type is LOCAL_AUTOLOGIN) to the SAME folder here:
       scp ${PRIMARY_SSH_USER:-oracle}@$P:<folder>/ewallet.p12 <folder>/
       scp ${PRIMARY_SSH_USER:-oracle}@$P:<folder>/cwallet.sso <folder>/
       chown $OU:$IG <folder>/* ; chmod 600 <folder>/*
       no cwallet.sso (or a LOCAL one on primary): make it here, as $OU (orapki asks the keystore password):
         $DBH/bin/orapki wallet create -wallet <folder> -auto_login      (LOCAL on primary: -auto_login_local)
       without WALLET_ROOT on primary (12c, or set up the old way): in $DBH/network/admin/sqlnet.ora
       ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = <folder>)))
EXPECT md5sum of the files equal on both servers
EOF
  ;;
  7.1) cat <<EOF
TITLE  Folders for the instance
WHERE  STANDBY ($S), user root
RUN    mkdir -p ${ORACLE_BASE:-<oracle base>}/admin/$SU/adump ${DIAG_DEST:-<diagnostic_dest of primary>}
       chown $OU:$IG <each new folder>
EXPECT the audit folder of the standby and the diagnostic_dest of primary exist, writable by $OU
EOF
  ;;
  7.2) cat <<EOF
TITLE  Instance in NOMOUNT
WHERE  STANDBY ($S), user $OU
RUN    file $DBH/dbs/init$SID.ora:
         *.db_name='${DB_NAME:-<db_name>}'
         *.db_unique_name='$SU'
         *.enable_pluggable_database=true        (only if primary is a CDB)
       $SSQL
       startup nomount pfile='$DBH/dbs/init$SID.ora'
EXPECT ORACLE instance started.
EOF
  ;;
  7.3|7.4|7.5|7.6) cat <<EOF
TITLE  Login tests (all four must work before the duplicate)
WHERE  STANDBY ($S) as $OU, and PRIMARY ($P) as $OU for the last one
RUN    sqlplus / as sysdba
       sqlplus sys@$ST as sysdba
       sqlplus sys@$PT as sysdba
       on primary:  sqlplus sys@$ST as sysdba
EXPECT Connected, four times
IF     ORA-01017 only through @  -> static entry ORACLE_HOME (5.1) or password file (6.1)
       ORA-01017 with / as sysdba -> $OU is not in the OSDBA group of the home
       ORA-12528                 -> (UR = A) or static entry missing
       ORA-12514                 -> SERVICE_NAME differs from GLOBAL_DBNAME
       ORA-12154                 -> alias missing (5.3, 5.4 or 4.9 on primary)
EOF
  ;;
  7.7) cat <<EOF
TITLE  /etc/oratab entry
WHERE  STANDBY ($S), user root
RUN    echo '$SID:$DBH:N' >> /etc/oratab
EXPECT . oraenv  (as $OU, answer $SID) sets ORACLE_HOME=$DBH
EOF
  ;;
  8.1)
    printf 'TITLE  Pre-checks for the duplicate\nWHERE  STANDBY (%s)\n' "$S"
    printf 'RUN    %s  ->  select status from v$instance;     (STARTED)\n' "$SSQL"
    [[ $G -eq 1 ]] && printf '       as %s:  asmcmd lsdg                                       (Free_MB of %s)\n' "$GU" "$DGS"
    [[ -n "${LOCS:-}" ]] && fs_dirs >/dev/null 2>&1 && [[ -n "$(fs_dirs)" ]] && printf '       df -m %s\n' "$(fs_dirs | paste -sd' ' -)"
    printf '       sqlplus sys@%s as sysdba  ->  select round(sum(bytes)/1024/1024) from v$datafile;\n' "$PT"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '       ls -l %s/bin/oracle   -> group %s (else as root: %s/bin/setasmgidwrap o=%s/bin/oracle)\n' "$DBH" "$AG" "$GH" "$DBH"
    printf 'EXPECT free space bigger than the primary size + 10%%, the folders are not the primary storage (2.15)\n'
  ;;
  8.2) cat <<EOF
TITLE  RMAN active duplicate
WHERE  STANDBY ($S), user $OU
WHY    Primary only READS its datafiles and sends them. It is not changed.
RUN    rman target sys@$PT auxiliary sys@$ST
       then the run { ... } block from ${LOG_DIR:-/var/log/dg_standby_setup}/duplicate_<date>.rman
EXPECT Finished Duplicate Db. Lines such as RMAN-05535 or ORA-19527 / ORA-00312 about redo
       log files during the copy are expected and harmless.
IF     it failed, clean THIS server before trying again (check names twice; the script
       prints the exact commands: run it with --from 7.2):
         on THIS server only ($S), $SSQL  ->  shutdown abort
         ASM:     as $GU:  [ "\$(hostname -s)" = "$(hostname -s)" ] && ORACLE_HOME=$GH ORACLE_SID=+ASM $GH/bin/asmcmd rm -rf +<DG>/${SU^^}
                  (never +<DG>/${PU^^}: those are the primary's files)
         folders: rm -f the files the copy left (step 7.2 lists them: run the script with --from 7.2)
         as $OU:  [ "\$(hostname -s)" = "$(hostname -s)" ] && rm -f $DBH/dbs/spfile$SID.ora $DBH/dbs/.dg_duplicate_done_$SID
       then run the script with:  --from 7.2
EOF
  ;;
  9.1) cat <<EOF
TITLE  Registration in Oracle Restart (only with Grid)
WHERE  STANDBY ($S), user $OU
RUN    srvctl config database -db $SU
       srvctl add database -db $SU -oraclehome $DBH -spfile $DBH/dbs/spfile$SID.ora \\
         -pwfile $DBH/dbs/orapw$SID -role PHYSICAL_STANDBY -startoption MOUNT \\
         -dbname ${DB_NAME:-<db_name>} -instance $SID -diskgroup $(tr ' ' ',' <<< "$DGS")${PRIMARY_DOMAIN:+ -domain $PRIMARY_DOMAIN}
EXPECT -instance exactly $SID (otherwise "Connected to an idle instance")
EOF
  ;;
  9.2) cat <<EOF
TITLE  Standby instance running (MOUNT)
WHERE  STANDBY ($S), user $OU
RUN    with Grid:    sqlplus / as sysdba -> shutdown immediate ; srvctl start database -db $SU
       without Grid: sqlplus / as sysdba -> startup mount
       sqlplus / as sysdba  ->  select instance_name, status from v\$instance;
EXPECT $SID  MOUNTED   (never OPEN read only without an Active Data Guard license)
EOF
  ;;
  9.3) cat <<EOF
TITLE  Standby redo logs on standby
WHERE  STANDBY ($S), $SSQL
RUN    alter database recover managed standby database cancel;
       alter system set standby_file_management=manual scope=memory;
       alter database add standby logfile thread 1 size <same as primary>M;    (with OMF/ASM; else give a file name)
       alter system set standby_file_management=auto scope=memory;
EXPECT per thread: online groups + 1
EOF
  ;;
  9.4) cat <<EOF
TITLE  Apply (MRP)
WHERE  STANDBY ($S), $SSQL
RUN    alter database recover managed standby database disconnect from session;
       select $DGN, $DGR, $DGS2 from $DGP where $DGN like 'MRP%';
EXPECT MRP0  APPLYING_LOG or WAIT_FOR_LOG
EOF
  ;;
  9.5) cat <<EOF
TITLE  Redo shipping from primary
WHERE  PRIMARY ($P), $PSQL
RUN    alter system set log_archive_dest_state_N=enable scope=both;      (N from step 4.4, usually 2)
       alter system switch logfile;
       select status, error from v\$archive_dest where dest_id=N;
EXPECT VALID, error empty
IF     ORA-16191 / ORA-01017 -> password file (6.1);  ORA-12154 -> 4.9;  ORA-12514/12541 -> phase 5
EOF
  ;;
  9.6) cat <<EOF
TITLE  Redo arrives (RFS)
WHERE  STANDBY ($S), $SSQL
RUN    select $DGN, $DGR, $DGS2 from $DGP where $DGR like 'RFS%';
EXPECT at least one RFS row
EOF
  ;;
  9.7)
    printf 'TITLE  Start at boot (mount and apply)\nWHERE  STANDBY (%s), user root\n' "$S"
    if [[ $G -eq 1 ]]; then
      printf 'WHY    Oracle Restart mounts the standby after a reboot, but does not start apply (MRP).\n'
      printf 'RUN    a script (root-owned, run as %s): wait until v$instance says MOUNTED, then\n' "$OU"
      printf '         alter database recover managed standby database disconnect from session;\n'
      printf '       a systemd unit (User=%s, Type=simple, After=oracle-ohasd.service) that runs it ; systemctl enable <unit>\n' "$OU"
    else
      printf 'RUN    a script (root-owned, run as %s):  lsnrctl start %s ; startup mount ;\n' "$OU" "$SL"
      printf '                         alter database recover managed standby database disconnect from session;\n'
      printf '       and at shutdown: shutdown immediate ; lsnrctl stop %s\n' "$SL"
      printf '       a systemd unit (User=%s, Type=oneshot + RemainAfterExit, LimitNOFILE/NPROC/STACK/MEMLOCK as for %s) ; systemctl enable <unit>\n' "$OU" "$OU"
    fi
    printf 'EXPECT after a reboot: the standby is MOUNTED and MRP runs\n'
  ;;
  9.8) cat <<EOF
TITLE  Archived logs on the standby (deletion)
WHERE  STANDBY ($S), user $OU (the timer: root)
WHY    Without a deletion policy the archived logs fill the recovery area (or the archive
       destination) and redo transport stops (ORA-19809 / ORA-00257). A policy copied from the
       primary with "BACKED UP n TIMES" never deletes anything here.
RUN    rman target /
       CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;
       With a recovery area Oracle then deletes applied logs by itself when space is needed.
       Another archive destination (a folder or a disk group): a daily job as $OU, for example a
       systemd timer that runs:  rman target /  ->  delete noprompt archivelog all completed before 'sysdate-1';
       On the PRIMARY nothing is changed here. Its own policy belongs to its backups (check it there:
       show archivelog deletion policy;). Never set "BACKED UP n TIMES" on a primary that RMAN does not back up.
EXPECT select value from v\$rman_configuration where name='ARCHIVELOG DELETION POLICY';  ->  TO APPLIED ON STANDBY
EOF
  ;;
  10.1) cat <<EOF
TITLE  Transport and apply lag
WHERE  STANDBY ($S), $SSQL
RUN    select name, value from v\$dataguard_stats where name in ('transport lag','apply lag');
EXPECT +00 00:00:00 or a few seconds (empty for some minutes right after setup)
EOF
  ;;
  10.2) cat <<EOF
TITLE  Archive gap
WHERE  STANDBY ($S), $SSQL
RUN    select * from v\$archive_gap;
EXPECT no rows selected
EOF
  ;;
  10.3) cat <<EOF
TITLE  Last sequence on both sides
WHERE  BOTH, user $OU, sqlplus / as sysdba
RUN    primary:  select max(sequence#) from v\$archived_log where standby_dest='NO' and thread#=1
                   and resetlogs_change#=(select resetlogs_change# from v\$database);
       standby:  select max(sequence#) from v\$archived_log where applied in ('YES','IN-MEMORY') and thread#=1
                   and resetlogs_change#=(select resetlogs_change# from v\$database);
EXPECT equal, or standby 1 lower
EOF
  ;;
  10.4) cat <<EOF
TITLE  Apply process
WHERE  STANDBY ($S), $SSQL
RUN    select $DGN, $DGR, $DGS2 from $DGP where $DGN like 'MRP%';
       select count(*) from v\$standby_log where status='ACTIVE';      -- 1 or more: real-time apply gets redo
       select timestamp, message from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp;
EXPECT MRP0; at least one ACTIVE standby log; no new errors
EOF
  ;;
  *) return 1 ;;
  esac
}

show_help() {
  local id=${1:-} txt line key rest title
  if ! txt=$(help_text "$id"); then
    printf '      No help for step "%s". Use: %s --help-step all\n' "$id" "$SELF"; return 1
  fi
  title=$(grep -m1 '^TITLE ' <<< "$txt"); title=${title:7}
  printf '\n      %s+-- HELP  [%s]  %s%s%s\n' "$C_C" "$id" "$C_B" "$title" "$C_N"
  while IFS= read -r line || [[ -n "$line" ]]; do
    key=${line:0:6}; rest=${line:7}
    case "$key" in
      "TITLE ") ;;
      "WHERE "|"WHY   "|"RUN   "|"EXPECT"|"IF    ")
        printf '      %s|%s\n      %s|%s   %s%-7s%s %s\n' "$C_C" "$C_N" "$C_C" "$C_N" "$C_Y" "${key%% *}" "$C_N" "$rest" ;;
      *) printf '      %s|%s           %s\n' "$C_C" "$C_N" "${line:7}" ;;
    esac
  done <<< "$txt"
  printf '      %s+--------------------------------------------------------------%s\n\n' "$C_C" "$C_N"
  _log HELP "Help shown for step $id"
}

help_cli() {
  # --help-step X.Y | all : uses saved settings when they are safe to read (parsed, never executed)
  local id=$1 i
  init_settings
  SETTINGS_FILE="$STATE_DIR/settings.conf"
  if [[ -r "$SETTINGS_FILE" ]]; then
    load_settings soft >/dev/null 2>&1 || { init_settings; printf '(saved settings not usable; showing placeholders)\n'; }
  elif [[ -e "$SETTINGS_FILE" ]]; then
    printf '(the settings file is not readable for this user; run as root to see your values)\n'
  else
    printf '(no saved settings yet; showing placeholders)\n'
  fi
  if [[ "$id" == "all" ]]; then for i in "${HELP_IDS[@]}"; do show_help "$i"; done
  else show_help "$id" || exit 2; fi
}
