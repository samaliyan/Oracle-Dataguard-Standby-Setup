#------------------------------------------------------------------------------
# Help: manual commands for every step  (h at any question, or --help-step X.Y)
# Line format read by show_help: 6-character key (TITLE/WHERE/WHY/RUN/EXPECT/IF), one space,
# text; continuation lines start with 7 spaces.
#------------------------------------------------------------------------------
readonly HELP_IDS=(1.1 1.2 1.3 1.4 1.5 1.6
  2.1 2.2 2.3 2.4 2.5 2.6 2.7 2.8 2.9 2.10 2.11 2.12 2.13 2.14 2.15 2.16
  3.1 3.2 3.3 3.4 3.5 3.6 3.7 3.8 3.9 3.10 3.11
  4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9 4.10 4.11
  5.1 5.2 5.3 5.4 6.1 6.2 6.3 7.1 7.2 7.3 7.4 7.5 7.6 7.7 8.1 8.2
  9.1 9.2 9.3 9.4 9.5 9.6 9.7 9.8 9.9 10.1 10.2 10.3 10.4 10.5 10.6 10.7 10.8)

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
  # (three lines: who, then two complete commands, each one copyable on its own)
  local PSQL="As $OU:"$'\n'"       export ORACLE_HOME=$DBH ORACLE_SID=$PS"$'\n'"       \$ORACLE_HOME/bin/sqlplus / as sysdba"
  local SSQL="As $OU:"$'\n'"       export ORACLE_HOME=$DBH ORACLE_SID=$SID"$'\n'"       \$ORACLE_HOME/bin/sqlplus / as sysdba"
  # 12.1 has no v$dataguard_process: the same information comes from v$managed_standby
  local DGP="v\$dataguard_process" DGN=name DGR=role DGS2=action
  [[ "${PRIMARY_VERSION:-}" == 12.1* ]] && { DGP="v\$managed_standby"; DGN=process; DGR=process; DGS2=status; }
  # TITLE lines match the step titles in run_step (step_title_of() reads them for steps that did not run)
  case "$1" in
  1.1) cat <<EOF
TITLE  Root and tools on this server
WHERE  This server ($S), as root
WHY    The script must run as root on the new standby server, never on the primary.
RUN    whoami
       hostname -s
EXPECT root, and the host name of this server (not the primary)
EOF
  ;;
  1.2) cat <<EOF
TITLE  Connect to the primary over ssh
WHERE  This server ($S), as root
WHY    The script opens one ssh connection and sends only read-only commands over it.
       A primary it does not know yet: it shows the host key fingerprints first.
       Compare them with the primary before you answer y.
RUN    On the primary, as root:
       for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "\$f"; done
       On this server:
       ssh ${PRIMARY_SSH_USER:-oracle}@${PRIMARY_IP:-<primary IP>} hostname
EXPECT The same fingerprints on both sides. Then the primary host name, after
       you type the password.
IF     The fingerprints differ: stop. Find out why before you connect.
       "Permission denied": wrong password, or PasswordAuthentication is "no"
       in /etc/ssh/sshd_config on the primary.
       "Connection refused" or "timed out": check sshd and the firewall (port 22)
       on the primary.
EOF
  ;;
  1.3) cat <<EOF
TITLE  Read the primary configuration (read-only)
WHERE  The primary ($P), as ${PRIMARY_SSH_USER:-oracle}
RUN    ps -eo pid,user,args | grep -E 'ora_pmon|tnslsnr'
       cat /etc/oratab ; cat /etc/oraInst.loc
       id $OU ; id $GU
       $DBH/bin/orabase
       $PSQL
       select name, db_unique_name, database_role, cdb from v\$database;
EXPECT database_role is PRIMARY
IF     The ssh user cannot run "sqlplus / as sysdba": add it to the dba group.
EOF
  ;;
  1.4) cat <<EOF
TITLE  Standby settings
WHERE  This server ($S), file ${SETTINGS_FILE:-/var/lib/dg_standby_setup/settings.conf}
WHY    Paths, users and groups are the same as on the primary.
       They are read from it at every run.
       You can change only the values under "This server (standby)": names, installer
       files, RU_DIR, OPATCH_ZIP, the ASM disk method and the RMAN channels.
RUN    Type a to accept, or e to edit (KEY=VALUE lines, no spaces).
       To change them later, run the script with --settings.
EXPECT STANDBY_UNIQUE differs from $PU.
       STANDBY_SID has at most 12 characters.
EOF
  ;;
  1.5) cat <<EOF
TITLE  sys password
WHERE  Asked on this server ($S); the manual test runs on the primary ($P)
WHY    RMAN and the login tests need it.
       It stays in memory only, never on disk or in the log.
RUN    To test it, on the primary ($P) as $OU:
       $DBH/bin/sqlplus sys@//localhost:$PO/$PSV as sysdba
EXPECT Connected.
IF     ORA-01017: wrong password, or SYS is missing from the password file (step 4.7).
EOF
  ;;
  1.6) cat <<EOF
TITLE  Oracle version supported on this Oracle Linux
WHERE  This server ($S)
WHY    Each Oracle release installs only on certain Oracle Linux versions.
RUN    cat /etc/os-release
       For 19c on OL9:
       1. Unzip the Release Update (with Grid: the GI Release Update) into a folder.
       2. Copy the newest OPatch zip (p6880880) to this server.
       3. In the settings (step 1.4, e), set RU_DIR=<folder> and OPATCH_ZIP=<zip>.
EXPECT A supported pair:
       12.1, 12.2, 18c   Oracle Linux 7 only
       19c               OL7, OL8 (the 19.3 installer gets CV_ASSUME_DISTID=OEL7.8),
                         OL9 only with Release Update 19.19 or later,
                         applied by the installer (-applyRU)
       21c               OL7, OL8, OL9
       23ai              OL8, OL9
EOF
  ;;
  2.1) cat <<EOF
TITLE  Groups (same names and ids as primary)
WHERE  This server ($S), as root
RUN    getent group $(tr ',' ' ' <<< "${GROUP_GIDS:-oinstall:54321}" | sed 's/:[0-9]*//g')
       groupadd -g <gid> <name>      (for each missing group, with the gid of the primary)
EXPECT The same gids as on the primary:  ${GROUP_GIDS:-<name:gid list>}
IF     A group exists with another gid and nothing is installed yet:
       groupmod -g <gid> <name>
EOF
  ;;
  2.2)
    printf 'TITLE  Users (same ids as primary)\nWHERE  This server (%s), as root\n' "$S"
    printf 'RUN    useradd -m -s /bin/bash -u %s -g %s%s %s\n' "${ORACLE_UID:-<uid>}" "$IG" "${ORACLE_GROUPS:+ -G $ORACLE_GROUPS}" "$OU"
    [[ $SO -eq 0 && $G -eq 1 ]] && printf '       useradd -m -s /bin/bash -u %s -g %s%s %s\n' "${GRID_UID:-<uid>}" "${GRID_PGROUP:-oinstall}" "${GRID_GROUPS:+ -G $GRID_GROUPS}" "$GU"
    printf '       passwd <user>      (optional)\nEXPECT "id %s" shows the same uid, gid and groups as on the primary\n' "$OU"
  ;;
  2.3) cat <<EOF
TITLE  Required packages
WHERE  This server ($S), as root
RUN    ${PKG:-dnf} install -y <package>
       Packages, one by one: <preinstall> unzip chrony parted bc
       With ASMLib also: oracleasm-support
       <preinstall> by version:
         12.1  oracle-rdbms-server-12cR1-preinstall
         12.2  oracle-database-server-12cR2-preinstall
         18c   oracle-database-preinstall-18c
         19c   oracle-database-preinstall-19c
         21c   oracle-database-preinstall-21c
         23ai  oracle-database-preinstall-23ai
EXPECT Complete!
IF     "No package available": enable the repository,
       for example ol7_latest or ol8_appstream.
       List the repositories with:  yum repolist  (or dnf repolist)
EOF
  ;;
  2.4) cat <<EOF
TITLE  Limits for the Oracle owners
WHERE  This server ($S), as root, file /etc/security/limits.d/oracle-grid.conf
WHY    The preinstall package sets limits only for the user "oracle".
       Every other owner needs them too.
RUN    Add these lines for each owner:
       <user> soft nofile 1024
       <user> hard nofile 65536
       <user> soft nproc 16384
       <user> hard nproc 16384
       <user> soft stack 10240
       <user> hard stack 32768
       <user> soft memlock unlimited
       <user> hard memlock unlimited
EXPECT As <user>, after a new login:  ulimit -Hn  shows 65536
       A limit set by you counts when its hard value is at least the one above.
       memlock: with HugePages set on this server, at least their total size (in KB);
       without HugePages any value. A lower value is reported, and the lines above are added.
EOF
  ;;
  2.5)
    printf 'TITLE  Software folders (same paths as primary)\nWHERE  This server (%s), as root\n' "$S"
    printf 'WHY    The script never changes the owner of a folder that already contains files.\n'
    if [[ $G -eq 1 ]]; then
      printf 'RUN    mkdir -p %s %s %s %s %s\n' "$GB" "$GH" "$INV" "$OB" "$DBH"
      printf '       chown %s:%s %s %s %s ; chown %s:%s %s %s\n' "$GU" "$IG" "$GB" "$GH" "$INV" "$OU" "$IG" "$OB" "$DBH"
    else
      printf 'RUN    mkdir -p %s %s %s\n' "$INV" "$OB" "$DBH"
      printf '       chown %s:%s %s %s %s\n' "$OU" "$IG" "$INV" "$OB" "$DBH"
    fi
    printf 'EXPECT ls -ld %s  shows owner %s\n' "$DBH" "$OU"
  ;;
  2.6) cat <<EOF
TITLE  Host names on this server
WHERE  This server ($S), as root, file /etc/hosts
RUN    getent ahostsv4 $P ; getent ahostsv4 $S
       If a name is missing, add its line to /etc/hosts:
       ${PRIMARY_IP:-<primary IP>}  $P
       ${STANDBY_IP:-<standby IP>}  $S
EXPECT The right IPv4 address for both names (never 127.x for $S)
EOF
  ;;
  2.7) cat <<EOF
TITLE  Primary resolves the standby host name
WHERE  The primary ($P), as root, file /etc/hosts
RUN    getent hosts $S
       If it is missing:
       echo '${STANDBY_IP:-<standby IP>}    $S' >> /etc/hosts
EXPECT The IP address of this server
EOF
  ;;
  2.8) cat <<EOF
TITLE  Network to the primary listener
WHERE  This server ($S), as root
RUN    timeout 5 bash -c "</dev/tcp/${PRIMARY_IP:-<primary IP>}/$PO" && echo OPEN
EXPECT OPEN
IF     No output: open the port on the primary, as root:
       firewall-cmd --permanent --add-port=$PO/tcp ; firewall-cmd --reload
EOF
  ;;
  2.9) cat <<EOF
TITLE  Firewall on this server
WHERE  This server ($S), as root
RUN    firewall-cmd --get-active-zones
       firewall-cmd --permanent --zone=<zone> --add-port=$PO/tcp
       firewall-cmd --reload
       <zone> is the zone of the network interface, from the first command.
EXPECT firewall-cmd --zone=<zone> --query-port=$PO/tcp  shows yes
       (or firewalld is not running)
       The script then lets the primary try a connection to port $PO here (nothing is sent).
       "Connection refused" is fine at this point (no listener yet); no answer at all
       means a firewall blocks the port: in the network, or rules here outside firewalld
       (nft list ruleset). "No route to host": a wrong address, or a reject by a firewall.
       With firewalld not running, up to three rules here that drop or reject traffic are
       shown as a note (nft or iptables). The script does not judge them: check that they
       let port $PO/tcp from the primary in.
EOF
  ;;
  2.10) cat <<EOF
TITLE  Time synchronization
WHERE  Both servers, as root
RUN    systemctl enable --now chronyd
       chronyc tracking
EXPECT Leap status : Normal   (a running ntpd is also fine)
       A chronyd or ntpd that has just started is looked at again for about 2 minutes (once per run);
       a clock still not in sync then is a warning, not a stop.
EOF
  ;;
  2.11)
    printf 'TITLE  Environment (.bash_profile) of the Oracle users\nWHERE  This server (%s), ~/.bash_profile of %s%s\n' "$S" "$OU" "$([[ $G -eq 1 && $SO -eq 0 ]] && printf ' and of %s' "$GU"; [[ -z "${USE_GRID:-}" ]] && printf ' (with Grid: also of %s)' "$GU")"
    printf 'WHY    The script does not need it, but sqlplus, rman and srvctl by hand do.\n'
    printf 'RUN    %s:\n         export ORACLE_BASE=%s\n         export ORACLE_HOME=%s\n         export ORACLE_SID=%s\n' "$OU" "$OB" "$DBH" "$SID"
    printf '         export PATH=$ORACLE_HOME/bin:$PATH\n'
    if [[ ( $G -eq 1 && $SO -eq 0 ) || -z "${USE_GRID:-}" ]]; then
      printf '       %s%s:\n         export ORACLE_BASE=%s\n         export ORACLE_HOME=%s\n         export ORACLE_SID=+ASM\n' "$([[ -z "${USE_GRID:-}" ]] && printf 'with Grid, ')" "$GU" "$GB" "$GH"
      printf '         export PATH=$ORACLE_HOME/bin:$PATH\n'
    fi
    printf "EXPECT su - %s -c 'echo \$ORACLE_SID \$ORACLE_HOME'  shows:\n       %s %s\n       (upper/lower case must match)\n" "$OU" "$SID" "$DBH"
    printf 'IF     A wrong value comes from ~/.bashrc or /etc/profile.d: the last export wins.\n       Fix those lines.\n'
  ;;
  2.12) cat <<EOF
TITLE  ASM disk method (ASMLib or udev)
WHERE  This server ($S), as root
WHY    ASMLib needs the UEK kernel (Oracle Linux 7 or 8). Otherwise udev rules are used;
       they work on every kernel.
RUN    ASMLib:
       oracleasm configure -u $GU -g $AG -e -s y
       oracleasm init
       systemctl enable oracleasm
       oracleasm status
       udev: one rule per disk in step 2.13. systemd-udevd must run (the script starts it).
       Set ASM_METHOD=udev in the settings.
       systemctl start systemd-udevd
EXPECT ASMLib: "Checking if ASM is loaded: yes",
       and  systemctl is-enabled oracleasm  shows enabled
EOF
  ;;
  2.13) cat <<EOF
TITLE  ASM disks
WHERE  This server ($S), as root
WHY    Each disk group of the primary ($DGS) needs one or more disks here.
       Labels: <DG>_1, <DG>_2 ...
       The disks must be empty, including the first MiB. Everything on them is erased.
RUN    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,WWN
       For every disk:
       parted -s <disk> mklabel gpt mkpart primary 1MiB 100% ; partprobe <disk>
       The partition is <disk>1, or <disk>p1 for nvme disks.
       ASMLib:
       oracleasm createdisk ${DD}_1 <partition> ; oracleasm scandisks ; oracleasm listdisks
       udev:
       udevadm info --query=property --name=<partition> | grep ID_PART_ENTRY_UUID
       echo 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition",' \\
         'ENV{ID_PART_ENTRY_UUID}=="<uuid>", SYMLINK+="oraasm/${DD}_1",' \\
         'OWNER="$GU", GROUP="$AG", MODE="0660"' >> /etc/udev/rules.d/99-oracle-asmdevices.rules
       udevadm control --reload-rules ; udevadm trigger --action=change ; ls -lL /dev/oraasm/
       Then add the label to ${STATE_DIR}/asm_disks as  LABEL|partition
       (or answer y when the script asks to use the disk).
       A disk that is already in a disk group is used only when
       this server's ASM has that group mounted.
EXPECT ${DD}_1 (${DD}_2 ...) for every disk group, big enough (database size + 10%)
IF     The script says a disk has data, and you are sure it is not in use:
       wipefs -a <disk> ; dd if=/dev/zero of=<disk> bs=1M count=10
       Multipath (SAN): match a partition with ENV{DM_UUID}=="part1-mpath-<wwid>"
       (the whole device: "mpath-<wwid>").
       Then add this line to ${STATE_DIR}/asm_disks:
       <LABEL>|/dev/mapper/<name>
EOF
  ;;
  2.14) cat <<EOF
TITLE  Database folders and free space (file system)
WHERE  This server ($S), as root
WHY    The primary keeps its database files in folders, not in ASM.
       This server uses exactly the same paths (no file name conversion).
RUN    df -h <each folder of primary>
       mkdir -p <folder> ; chown $OU:$IG <folder>
       Not enough space: format a new, empty disk, mount it at the same path,
       and add it to /etc/fstab:
       mkfs.xfs /dev/<empty disk>
EXPECT Every folder exists, is owned by $OU, and has the space used on the primary + 10%.
EOF
  ;;
  2.15) cat <<EOF
TITLE  Database folders are not shared with the primary
WHERE  This server ($S) and the primary ($P), as root
WHY    The paths are the same. If a folder is the primary's NFS export or SAN volume,
       the copy would overwrite the primary's files.
RUN    touch <folder>/test_from_standby
       On the primary:
       ls -l <folder>/test_from_standby
       Back on this server:
       rm <folder>/test_from_standby
EXPECT The primary says: No such file or directory
       On a standby that is already built, this was checked before the copy.
IF     The file system UUID is the same on both servers
       (findmnt -o SOURCE,UUID --target <folder>): the disk is a copy of the primary's disk,
       or the same disk mounted twice. Compare the disks on both servers:
       lsblk -s -o NAME,TYPE,WWN,SERIAL,SIZE \$(findmnt -n -o SOURCE --target <folder>)
       Change nothing on such a disk until you know which it is.
EOF
  ;;
  2.16) cat <<EOF
TITLE  Memory (RAM) for the database
WHERE  This server ($S), as root
WHY    The copy gives the standby the same memory settings (SGA, PGA) as the primary.
       With too little RAM the standby does not start (ORA-27102, ORA-00845, ORA-04031).
RUN    On the primary, as oracle in sqlplus:
       show parameter sga_max_size
       show parameter pga_aggregate_target
       show parameter memory_target
       On this server:
       free -g
EXPECT SGA is at most 80% of the RAM here. SGA + PGA over 90% is only a warning
       (the PGA is a target, not taken at startup).
       With memory_target: /dev/shm (df -h /dev/shm) is at least memory_target + 1 GB,
       now and after a reboot. The size after a reboot: the size= option of the /dev/shm line in
       /etc/fstab, and, when a mount unit for /dev/shm sets Options (the last Options line that
       systemctl cat dev-shm.mount shows, in /etc, /run or /usr/lib; else the unit and its drop-ins
       in /etc), the smaller of the two. No size = half the RAM. A size that cannot be read (for
       example 1.5G, which tmpfs does not take) counts as too small.
       A file outside /etc is not changed: a drop-in in /etc/systemd/system/dev-shm.mount.d sets
       the size over it.
IF     Too little RAM: add RAM to this server (virtual machine settings), then answer r.
       /dev/shm too small: the script does it (answer y). By hand:
       mount -o remount,size=<MB>m /dev/shm
       Then the same size in /etc/fstab (and in dev-shm.mount, if it exists), and:
       systemctl daemon-reload
EOF
  ;;
  3.1)
    printf 'TITLE  Installer files\nWHERE  The primary (%s) for a gold image, then this server (%s) as root\n' "$P" "$S"
    if [[ ${DB_MAJOR:-19} -ge 18 ]]; then
      printf 'RUN    Best: a gold image of the primary home. It has the same patches.\n'
      printf '       On the primary, as %s:\n       mkdir -p /tmp/gold ; %s/runInstaller -silent -createGoldImage -destinationLocation /tmp/gold\n' "$OU" "$DBH"
      [[ $G -eq 1 ]] && printf '       On the primary, as %s:\n       mkdir -p /tmp/gold ; %s/gridSetup.sh -silent -createGoldImage -destinationLocation /tmp/gold\n' "$GU" "$GH"
      printf '       On this server, as root:\n       mkdir -p /stage ; scp %s@%s:/tmp/gold/*.zip /stage/\n' "${PRIMARY_SSH_USER:-oracle}" "${PRIMARY_IP:-<primary IP>}"
      printf '       Or the base files: LINUX.X64_<180000|193000|213000>_db_home.zip (and _grid_home.zip);\n'
      printf '       23ai from edelivery.\n'
      printf '       For either kind of file:\n'
    else
      printf 'RUN    The base files:\n'
      printf '       12.1  linuxamd64_12102_database_1of2.zip + 2of2  (Grid: linuxamd64_12102_grid_1of2.zip + 2of2)\n'
      printf '       12.2  linuxx64_12201_database.zip  (Grid: linuxx64_12201_grid_home.zip)\n'
    fi
    printf '       chmod 644 /stage/*.zip\n'
    printf '       The owner must be root, %s or %s. Nobody else may be able to change the files.\n' "$OU" "$GU"
    printf 'EXPECT The script finds them. It searches: %s\n' "${ZIP_DIRS[*]}"
    printf '       With RU_DIR in the settings: RU_DIR is the numbered folder of the Release Update (or holds\n'
    printf '       exactly one). One of its patches must be on the database home of the primary, and with\n'
    printf '       Grid also on its Grid home (opatch lspatches on the primary). Otherwise this step stops.\n'
    printf '       Steps 3.2 and 3.6 check this again before they install (also when 3.1 was skipped).\n'
    printf '       Only the home that is installed is compared (3.2: Grid, 3.6: database).\n'
    printf '       The file system of each home needs about 2.5 times the size of its zip files free.\n'
  ;;
  3.2) cat <<EOF
TITLE  Grid Infrastructure software (Oracle Restart)
WHERE  This server ($S), as $GU
WHY    Needed only when the primary uses ASM.
RUN    12.2 and newer:
       cd $GH ; unzip -q <grid zip> ; ./gridSetup.sh
       (with a Release Update, add:  -applyRU <folder>)
       12.1 (both zips into one stage folder):
       cd <stage folder> ; unzip -q <grid zip 1of2> ; unzip -q <grid zip 2of2> ; ./grid/runInstaller
       In the installer choose: Standalone Server (Oracle Restart),
       disk group $DD, External, base $GB,
       discovery path /dev/oracleasm/disks/* (ASMLib) or /dev/oraasm/* (udev).
EXPECT The installer finishes and asks you to run the root scripts (step 3.3).
IF     Logs are in $INV/logs/
       INS-08101 on OL8/9: the OS is newer than the installer.
       Use a Release Update (step 1.6).
EOF
  ;;
  3.3) cat <<EOF
TITLE  Grid root scripts
WHERE  This server ($S), as root
RUN    12.1 on Oracle Linux 7 only, first apply patch 18370031:
       $GH/OPatch/opatch napply -oh $GH -local <patch folder>
       Then:
       $INV/orainstRoot.sh
       $GH/root.sh
EXPECT As $GU:
       $GH/bin/crsctl check has
       It shows: CRS-4638: Oracle High Availability Services is online
IF     root.sh failed: undo it, then run it again:
       $GH/crs/install/roothas.sh -deconfig -force
       $GH/root.sh
EOF
  ;;
  3.4) cat <<EOF
TITLE  ASM and listener (Grid configuration)
WHERE  This server ($S), as $GU
RUN    12.2 and newer:
       $GH/gridSetup.sh -executeConfigTools -responseFile <file> -silent
       12.1:
       $GH/cfgtoollogs/configToolAllCommands RESPONSE_FILE=<file with the ASM passwords>
EXPECT $GH/bin/crsctl stat res -t  shows ora.asm, ora.$SL.lsnr and ora.${DD^^}.dg ONLINE
IF     HAS is stopped, as root:
       $GH/bin/crsctl start has
       ASM is offline, as $GU:
       $GH/bin/srvctl start asm
EOF
  ;;
  3.5) cat <<EOF
TITLE  ASM disk groups (same names as primary)
WHERE  This server ($S), as $GU, in  sqlplus / as sysasm
WHY    Each disk group of the primary ($DGS) needs a disk group with the same name here.
RUN    create diskgroup <DG> external redundancy disk '<disk path>'
         attribute 'compatible.asm'='<as $DD>', 'compatible.rdbms'='<as $DD>';
       asmcmd lsdg
EXPECT Every disk group of the primary is MOUNTED.
IF     A disk group exists but is dismounted:
       alter diskgroup <DG> mount;
EOF
  ;;
  3.6) cat <<EOF
TITLE  Database software (Software Only)
WHERE  This server ($S), as $OU
RUN    18c and newer:
       cd $DBH ; unzip -q <db zip or gold image> ; ./runInstaller
       (with a Release Update, add:  -applyRU <folder>)
       12.x (the zip or zips into one stage folder):
       cd <stage folder> ; unzip -q <db zip> ; ./database/runInstaller
       In the installer choose: Set Up Software Only, Single instance, Enterprise Edition,
       home $DBH, base $OB.
EXPECT The installer finishes. Then step 3.7.
EOF
  ;;
  3.7)
    printf 'TITLE  Database root.sh\nWHERE  This server (%s), as root\n' "$S"
    printf 'RUN    %s/orainstRoot.sh      (only if /etc/oraInst.loc does not exist yet)\n       %s/root.sh\n' "$INV" "$DBH"
    printf 'EXPECT ls -l %s/bin/oradism  shows owner root\n' "$DBH"
  ;;
  3.8) cat <<EOF
TITLE  Read/write Oracle home
WHERE  This server ($S), as $OU
WHY    From 18c a home can be read-only. This setup keeps the spfile, the password file
       and tnsnames.ora in the home, so the home must be read/write.
RUN    $DBH/bin/orabasehome
       $DBH/bin/roohctl -disable      (only on a new home without any database)
EXPECT orabasehome prints $DBH
EOF
  ;;
  3.9) cat <<EOF
TITLE  Oracle Restart resources ONLINE
WHERE  This server ($S), as $GU
RUN    $GH/bin/crsctl stat res -t
       For each resource that is OFFLINE (ora.* resources are started with srvctl, never crsctl):
       $GH/bin/srvctl start asm
       $GH/bin/srvctl start listener -listener $SL
$(for g in $DGS; do printf '       %s/bin/srvctl start diskgroup -diskgroup %s\n' "$GH" "${g#+}"; done)
       If the listener is missing:
       $GH/bin/srvctl add listener -listener $SL -endpoints TCP:$PO
       $GH/bin/srvctl start listener -listener $SL
EXPECT ONLINE: ora.asm, ora.$SL.lsnr, and the disk groups $DGS
       ora.diskmon and ora.ons are OFFLINE in Oracle Restart. That is normal.
IF     ora.$SL.lsnr is INTERMEDIATE (Not All Endpoints Registered): do not start it. First check, as root:
       getent ahostsv4 $S
       It must show an IPv4 address of this server, not nothing, 127.x or fe80::.
       If not, add the line to /etc/hosts. Then, as $GU:
       $GH/bin/srvctl stop listener -listener $SL
       $GH/bin/srvctl start listener -listener $SL
EOF
  ;;
  3.10) cat <<EOF
TITLE  Listener port equal to primary ($PO)
WHERE  This server ($S), as $GU (only with Grid; without Grid this step is not needed)
WHY    The listener here is always $SL (Grid creates it).
       Only its port must match the primary.
RUN    $GH/bin/srvctl modify listener -listener $SL -endpoints TCP:$PO
       $GH/bin/srvctl stop listener -listener $SL
       $GH/bin/srvctl start listener -listener $SL
EXPECT lsnrctl status $SL  shows (PORT=$PO)
EOF
  ;;
  3.11)
    printf 'TITLE  Same release and patches as primary\nWHERE  Both servers, as %s\n' "$OU"
    printf 'RUN    <home>/OPatch/opatch lspatches       (every home, on both servers)\n'
    printf '       %s/bin/sqlplus -V\n' "$DBH"
    printf 'EXPECT The same release and the same patch list on both servers\n'
    printf 'IF     Different: put the newest OPatch (patch 6880880) into the homes, then:\n'
    if [[ $G -eq 1 ]]; then
      printf '       As root:  %s/OPatch/opatchauto apply <RU folder> -oh %s\n' "$GH" "$GH"
      printf '       As root:  %s/OPatch/opatchauto apply <RU folder> -oh %s\n' "$DBH" "$DBH"
    else
      printf '       As %s:  cd <RU folder> ; %s/OPatch/opatch apply\n' "$OU" "$DBH"
    fi
    printf '       One-off patches, as %s:  cd <patch> ; %s/OPatch/opatch apply\n' "$OU" "$DBH"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '       Then, as root:  %s/bin/setasmgidwrap o=%s/bin/oracle\n' "$GH" "$DBH"
    [[ ${DB_MAJOR:-19} -ge 18 ]] && printf '       Easier: install from a gold image of the primary home (step 3.1).\n'
    true
  ;;
  4.1) cat <<EOF
TITLE  ARCHIVELOG and FORCE LOGGING
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       select value from v\$parameter where name='spfile';
       -- empty: the primary runs from a text pfile. Create an spfile first (one restart):
       --   create pfile='?/dbs/init${PS}_before_dg.ora' from memory;
       --   create spfile from memory;
       --   then restart
       select log_mode, force_logging from v\$database;
       alter database force logging;
       -- only for NOARCHIVELOG (short downtime):
       --   shutdown immediate
       --   startup mount
       --   alter database archivelog;
       --   alter database open;
EXPECT log_mode ARCHIVELOG, force_logging YES
EOF
  ;;
  4.2) cat <<EOF
TITLE  Standby redo logs on the primary
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       select thread#, count(*), max(bytes)/1024/1024 mb, max(blocksize) from v\$log group by thread#;
       select thread#, count(*) from v\$standby_log group by thread#;
       -- per thread: online groups + 1; size = the largest online log;
       -- blocksize 4096 if the online logs use it
       -- with OMF or ASM:
       alter database add standby logfile thread 1 size <M>M;
       -- without OMF:
       alter database add standby logfile thread 1 group <n> ('<redo folder>/srl_t1_g<n>.log') size <M>M;
EXPECT For every thread: standby logs = online groups + 1
EOF
  ;;
  4.3) cat <<EOF
TITLE  Data Guard names (log_archive_config)
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       show parameter log_archive_config
       alter system set log_archive_config='dg_config=(<names already in the list>,$PU,$SU)' scope=both;
       -- keep every name that is already in the list,
       -- or another standby stops receiving redo
EXPECT show parameter log_archive_config  shows both names
EOF
  ;;
  4.4) cat <<EOF
TITLE  Redo transport to the standby (log_archive_dest_N)
WHERE  The primary ($P), SQL*Plus as sysdba
WHY    N is usually 2. If log_archive_dest_2 is used for something else,
       the script takes the first free N.
RUN    $PSQL
       alter system set log_archive_dest_state_N=defer scope=both;
       alter system set log_archive_dest_N='service=$ST async
         valid_for=(online_logfiles,primary_role) db_unique_name=$SU' scope=both;
EXPECT show parameter log_archive_dest_N  shows the service $ST
IF     ORA-16018 (the old parameter log_archive_dest is in use): first run
       alter system set log_archive_dest='' scope=both;
       alter system set log_archive_dest_1='location=<same folder>' scope=both;
EOF
  ;;
  4.5) cat <<EOF
TITLE  Automatic standby files (standby_file_management)
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       alter system set standby_file_management=auto scope=both;
EXPECT AUTO
EOF
  ;;
  4.6) cat <<EOF
TITLE  Archive destination and recovery area
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       show parameter log_archive_dest_1
       show parameter db_recovery_file_dest
       -- only if neither is set (the script fills in a size: 3 days of the archived logs of
       -- the last week plus 20 %, at least 10G; and a disk group named FRA or RECO if there is one):
       alter system set db_recovery_file_dest_size=<size>G scope=both;
       alter system set db_recovery_file_dest='<+DG or folder>' scope=both;
EXPECT log_archive_dest_1 has LOCATION=..., or a recovery area is set
EOF
  ;;
  4.7) cat <<EOF
TITLE  Password file and SYS
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       show parameter remote_login_passwordfile
       select username, sysdba from v\$pwfile_users;
       -- SYS is missing, but a password file exists:
       alter user sys identified by "<the same sys password>";
       -- no password file at all: in a shell as $OU (orapwd asks for the password):
       --   file system: orapwd file=\$ORACLE_HOME/dbs/orapw$PS format=12.2     (12.1: format=12)
       --   ASM:         orapwd file='+<DG>/$PU/orapw<db>' dbuniquename=$PU format=12.2
EXPECT EXCLUSIVE (or SHARED), and SYS with sysdba TRUE
EOF
  ;;
  4.8) cat <<EOF
TITLE  fal_server (for switchover)
WHERE  The primary ($P), SQL*Plus as sysdba
WHY    Used only after a switchover. You may skip it.
RUN    $PSQL
       alter system set fal_server='$ST' scope=both;
EXPECT show parameter fal_server  shows $ST
EOF
  ;;
  4.9) cat <<EOF
TITLE  Standby alias in the primary tnsnames.ora
WHERE  The primary ($P), as $OU, file $PTA/tnsnames.ora
RUN    Add this entry:
       $ST =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $S)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $SSV)(UR = A))
         )
       Then test it:
       $DBH/bin/tnsping $ST
EXPECT "Used TNSNAMES adapter" and OK
EOF
  ;;
  4.10) cat <<EOF
TITLE  Static listener entry on the primary
WHERE  The primary ($P), as the owner of the listener home, file:
       $PLH/network/admin/listener.ora
WHY    Needed for switchover and the broker, not to build the standby. You may skip it.
RUN    Add this entry:
       SID_LIST_$LN =
         (SID_LIST =
           (SID_DESC =
             (GLOBAL_DBNAME = $PSV)
             (SID_NAME = $PS)
             (ORACLE_HOME = $DBH)
           )
         )
       Then reload the listener:
       $PLH/bin/lsnrctl reload $LN
EXPECT lsnrctl status $LN  shows Instance "$PS", status UNKNOWN
EOF
  ;;
  4.11) cat <<EOF
TITLE  Environment of $OU on the primary
WHERE  The primary ($P), as $OU, file ~/.bash_profile
WHY    Information only. The script does not use it,
       but sqlplus, rman and dgmgrl by hand need it.
RUN    export ORACLE_BASE=$OB
       export ORACLE_HOME=$DBH
       export ORACLE_SID=$PS
       export PATH=\$ORACLE_HOME/bin:\$PATH
EXPECT After a new login:  echo \$ORACLE_SID  shows $PS
EOF
  ;;
  5.1)
    printf 'TITLE  Static listener entry for %s\n' "$SID"
    if [[ -z "${USE_GRID:-}" ]]; then
      printf 'WHERE  This server (%s), as the listener owner:\n' "$S"
      printf '       with Grid, %s and %s/network/admin/listener.ora;\n' "$GU" "$GH"
      printf '       without Grid, %s and %s/network/admin/listener.ora\n' "$OU" "$DBH"
    else
      printf 'WHERE  This server (%s), as %s, file:\n       %s/network/admin/listener.ora\n' "$S" "$LU" "$LH"
    fi
    printf 'WHY    In NOMOUNT the instance cannot register itself, so the listener needs a static entry.\n'
    printf '       ORACLE_HOME must be the database home.\n'
    printf '       With the Grid home you get ORA-01017 through the listener.\n'
    [[ $G -eq 0 ]] && printf 'RUN    Without Grid, define the listener as well:\n       %s = (DESCRIPTION_LIST = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))))\n       Add this entry:\n' "$SL" "$S" "$PO"
    [[ $G -eq 1 ]] && printf 'RUN    Add this entry:\n'
    printf '       SID_LIST_%s =\n         (SID_LIST =\n           (SID_DESC =\n             (GLOBAL_DBNAME = %s)\n             (SID_NAME = %s)\n             (ORACLE_HOME = %s)\n           )\n         )\n' "$SL" "$SSV" "$SID" "$DBH"
    printf '       If SID_LIST_%s is already there without this SID, the entry goes inside it\n' "$SL"
    printf '       (the script does that, with a backup). A wrong entry of this SID is replaced the same way,\n'
    printf '       when it is on lines of its own; other entries stay. A listener.ora that is a link is\n'
    printf '       never written through: then the entry is added by hand.\n'
    printf 'EXPECT Step 5.2 checks it.\n'
  ;;
  5.2) cat <<EOF
TITLE  Listener shows the static entry
WHERE  This server ($S), as $LU
RUN    $LH/bin/lsnrctl start $SL      (only without Grid, when it is not running)
       $LH/bin/lsnrctl reload $SL
       $LH/bin/lsnrctl status $SL
EXPECT Instance "$SID", status UNKNOWN, and (PORT=$PO)
EOF
  ;;
  5.3|5.4)
    local TA TH TS
    if [[ "$1" == "5.3" ]]; then TA=$PT; TH=$P; TS=$PSV; printf 'TITLE  tnsnames.ora entry for the primary (%s)\n' "$PT"
    else TA=$ST; TH=$S; TS=$SSV; printf 'TITLE  tnsnames.ora entry for the standby (%s)\n' "$ST"; fi
    cat <<EOF
WHERE  This server ($S), as $OU, file $DBH/network/admin/tnsnames.ora
WHY    This server needs two aliases: the primary (step 5.3) and itself (step 5.4).
RUN    Add this entry (an existing entry of $TA that is different is replaced; the script does it,
       with a backup, when the entry is written in the usual way):
       $TA =
         (DESCRIPTION =
           (ADDRESS = (PROTOCOL = TCP)(HOST = $TH)(PORT = $PO))
           (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $TS)(UR = A))
         )
       Then test it:
       tnsping $TA
EXPECT OK, with HOST = $TH
EOF
  ;;
  6.1) cat <<EOF
TITLE  Password file orapw$SID
WHERE  The primary ($P), then this server ($S)
WHY    This server needs an exact copy of the primary's password file.
RUN    On the primary, find the file:
       $PSQL
       select file_name from v\$passwordfile_info;
       -- 12.2 and newer; on 12.1 the file is usually \$ORACLE_HOME/dbs/orapw<SID>
       exit
       If the name starts with +, on the primary as $GU:
         export ORACLE_HOME=$GH ORACLE_SID=+ASM
         rm -f /tmp/orapw_for_standby_$SID
         (umask 077; \$ORACLE_HOME/bin/asmcmd pwcopy '<file_name>' /tmp/orapw_for_standby_$SID)
         chgrp $IG /tmp/orapw_for_standby_$SID ; chmod 640 /tmp/orapw_for_standby_$SID
       On this server, as root:
         scp ${PRIMARY_SSH_USER:-oracle}@$P:<file or /tmp copy> $DBH/dbs/orapw$SID
         chown $OU:$IG $DBH/dbs/orapw$SID ; chmod 640 $DBH/dbs/orapw$SID
EXPECT md5sum is the same on both servers.
       12.2 and newer: this shows a format:
       orapwd describe file=$DBH/dbs/orapw$SID
EOF
  ;;
  6.2) cat <<EOF
TITLE  Remove the temporary copy on the primary
WHERE  The primary ($P)
WHY    The copy of the password file must not stay in /tmp.
RUN    rm -f /tmp/orapw_for_standby_$SID
EXPECT ls /tmp/orapw_for_standby_$SID  shows No such file
EOF
  ;;
  6.3) cat <<EOF
TITLE  TDE wallet (only if the primary uses TDE)
WHERE  The primary ($P), then this server ($S)
RUN    On the primary:
       $PSQL
       select wrl_type, wrl_parameter, status, wallet_type from v\$encryption_wallet;
       exit
       Copy ewallet.p12 to the same folder here.
       Copy cwallet.sso too, unless wallet_type is LOCAL_AUTOLOGIN:
       scp ${PRIMARY_SSH_USER:-oracle}@$P:<folder>/ewallet.p12 <folder>/
       scp ${PRIMARY_SSH_USER:-oracle}@$P:<folder>/cwallet.sso <folder>/
       chown $OU:$IG <folder>/* ; chmod 600 <folder>/*
       No cwallet.sso, or a LOCAL one on the primary: the script makes it (it asks for the
       keystore password once). By hand, as $OU (LOCAL on the primary: -auto_login_local):
       $DBH/bin/orapki wallet create -wallet <folder> -auto_login
       No WALLET_ROOT on the primary (12c, or the old setup):
       add this line to $DBH/network/admin/sqlnet.ora:
       ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = <folder>)))
       (an existing entry is replaced; comments on it are kept above the new line. A sqlnet.ora
       that is a link is not written through.)
       18c and newer: WALLET_ROOT/tde_seps (the external-store password) is copied too. If the
       primary cannot be asked whether it is there, the step stops (it is not left out).
EXPECT md5sum of the wallet files is the same on both servers.
EOF
  ;;
  7.1) cat <<EOF
TITLE  Folders for the instance (audit, diagnostics)
WHERE  This server ($S), as root
RUN    mkdir -p ${ORACLE_BASE:-<oracle base>}/admin/$SU/adump ${DIAG_DEST:-<diagnostic_dest of primary>}
       chown $OU:$IG <each new folder>
EXPECT The audit folder of the standby and the diagnostic_dest of the primary exist
       and are writable by $OU. A standby that exists already: also the audit_file_dest
       set in its spfile, when it is another folder. Under the Oracle base the script makes it;
       outside it, it is a step to do by hand (mkdir, chown $OU:$IG).
       Refused as the audit folder: a system folder (/, /usr, /etc, /tmp, /opt, /run ...,
       and /home and /srv themselves), a folder under /home outside the home of $OU,
       the home of another account, an Oracle home or base (Grid too) or a folder above one,
       and a folder whose nearest existing part belongs to a user other than root or $OU.
       A root step (mkdir, chown) is shown only when no one but root can change the folders
       on the way; otherwise $OU makes the folder itself when it can, or it is refused.
EOF
  ;;
  7.2) cat <<EOF
TITLE  Instance $SID in NOMOUNT
WHERE  This server ($S), as $OU
RUN    Create $DBH/dbs/init$SID.ora with:
         *.db_name='${DB_NAME:-<db_name>}'
         *.db_unique_name='$SU'
         *.enable_pluggable_database=true        (only if the primary is a CDB)
       Then:
       $SSQL
       startup nomount pfile='$DBH/dbs/init$SID.ora'
EXPECT ORACLE instance started.
EOF
  ;;
  7.3|7.4|7.5|7.6)
    case "$1" in
      7.3) printf 'TITLE  Login 1 of 4: sqlplus / as sysdba on this server\n' ;;
      7.4) printf 'TITLE  Login 2 of 4: sys@%s through the listener\n' "$ST" ;;
      7.5) printf 'TITLE  Login 3 of 4: sys@%s from this server\n' "$PT" ;;
      *)   printf 'TITLE  Login 4 of 4: sys@%s from the primary\n' "$ST" ;;
    esac
    if [[ "$1" == "7.6" ]]; then printf 'WHERE  The primary (%s), as %s\n' "$P" "$OU"; else printf 'WHERE  This server (%s), as %s\n' "$S" "$OU"; fi
    printf 'WHY    All four logins (steps 7.3 to 7.6) must work before the RMAN copy.\n'
    case "$1" in
      7.3) printf 'RUN    sqlplus / as sysdba\n' ;;
      7.5) printf 'RUN    sqlplus sys@%s as sysdba\n' "$PT" ;;
      *)   printf 'RUN    sqlplus sys@%s as sysdba\n' "$ST" ;;
    esac
    printf 'EXPECT Connected.\n'
    case "$1" in
      7.3) printf 'IF     ORA-01017: %s is not in the OSDBA group of the home\n' "$OU" ;;
      7.5) printf 'IF     ORA-01017: wrong sys password, or the password files differ (step 6.1)\n'
           printf '       ORA-12154: the alias is missing (step 5.3)\n'
           printf '       ORA-12514 or ORA-12541: the listener on the primary\n' ;;
      *)   printf 'IF     ORA-01017: static entry ORACLE_HOME (step 5.1) or password file (step 6.1)\n'
           printf '       ORA-12528: (UR = A) or the static entry is missing\n'
           printf '       ORA-12514: SERVICE_NAME differs from GLOBAL_DBNAME\n'
           if [[ "$1" == "7.6" ]]; then printf '       ORA-12154: the alias is missing on the primary (step 4.9)\n'
           else printf '       ORA-12154: the alias is missing (step 5.4)\n'; fi ;;
    esac
  ;;
  7.7) cat <<EOF
TITLE  /etc/oratab entry for $SID
WHERE  This server ($S), as root
RUN    echo '$SID:$DBH:N' >> /etc/oratab
       If /etc/oratab is a link: the script writes the file it points to only when the link is
       owned by root and every folder above that file can be changed only by root.
       Otherwise the line is added by hand.
EXPECT As $OU, . oraenv (answer $SID) sets ORACLE_HOME=$DBH
EOF
  ;;
  8.1)
    printf 'TITLE  Pre-checks: space, storage, logins, parameters\nWHERE  This server (%s)\n' "$S"
    printf 'RUN    %s\n       select status from v$instance;      (STARTED)\n       exit\n' "$SSQL"
    [[ $G -eq 1 ]] && printf '       As %s:  asmcmd lsdg      (Free_MB of %s)\n' "$GU" "$DGS"
    [[ -n "${LOCS:-}" ]] && fs_dirs >/dev/null 2>&1 && [[ -n "$(fs_dirs)" ]] && printf '       df -m %s\n' "$(fs_dirs | paste -sd' ' -)"
    printf '       Size of the primary in MB:\n       sqlplus sys@%s as sysdba\n       select round(sum(bytes)/1024/1024) from v$datafile;\n' "$PT"
    [[ $G -eq 1 && $SO -eq 0 ]] && printf '       ls -l %s/bin/oracle      (group %s; if not, as root: %s/bin/setasmgidwrap o=%s/bin/oracle)\n' "$DBH" "$AG" "$GH" "$DBH"
    printf 'EXPECT Free space is larger than the primary size + 10%%.\n'
    printf '       The folders are not the primary storage (step 2.15).\n'
  ;;
  8.2)
    local SUU=$SU PUU=$PU
    [[ -n "${STANDBY_UNIQUE:-}" ]] && SUU=${SU^^}; [[ -n "${PRIMARY_UNIQUE:-}" ]] && PUU=${PU^^}
    cat <<EOF
TITLE  RMAN duplicate for standby
WHERE  This server ($S), as $OU
WHY    The primary only reads its datafiles and sends them.
       Nothing on the primary is changed.
RUN    rman target sys@$PT auxiliary sys@$ST
       Then the run { ... } block from ${LOG_DIR:-/var/log/dg_standby_setup}/duplicate_<date>.rman
EXPECT Finished Duplicate Db.
       RMAN-05535, or ORA-19527 / ORA-00312 about redo log files,
       are normal during the copy.
IF     The copy failed: clean this server before you try again, and check every name twice.
       Run the script with --from 7.2. Its clean-up menu offers:
         [y] Clean up for me      only for a copy this script started that did not finish:
                                  it checks the host and the instance, lists what goes, asks
                                  for the word CLEAN, then: shutdown abort, asmcmd rm -rf
                                  +<DG>/$SUU, the standby's OMF folders, and it renames
                                  spfile$SID.ora to spfile$SID.ora.failed_<run>
         [m] Show the commands    the same commands in a short script file for you to read and run
       NEVER +<DG>/$PUU: those are the primary's files.
       init$SID.ora and orapw$SID are kept. The run then goes on and copies again.
EOF
  ;;
  9.1) cat <<EOF
TITLE  Registration in Oracle Restart (srvctl)
WHERE  This server ($S), as $OU
WHY    Only with Grid. Oracle Restart then mounts the standby after a reboot.
RUN    srvctl config database -db $SU
       srvctl add database -db $SU -oraclehome $DBH -spfile $DBH/dbs/spfile$SID.ora \\
         -pwfile $DBH/dbs/orapw$SID -role PHYSICAL_STANDBY -startoption MOUNT \\
         -dbname ${DB_NAME:-<db_name>} -instance $SID -diskgroup $(tr ' ' ',' <<< "$DGS")${PRIMARY_DOMAIN:+ -domain $PRIMARY_DOMAIN}
EXPECT srvctl config database -db $SU
       shows the instance name exactly $SID, its disk groups include $(tr ' ' ',' <<< "$DGS")${PRIMARY_DOMAIN:+,
       and the domain $PRIMARY_DOMAIN}.
       Missing disk groups or a wrong domain are changed in place (srvctl modify database).
       A new registration keeps the management policy, stop option, disk groups and domain of
       the old one. A registered disk group this server does not
       have is taken out (srvctl modify); a domain the primary does not set is reported. When the
       disk groups of this server cannot be read, the step waits (it is not passed).
IF     "Connected to an idle instance": the -instance value is wrong.
EOF
  ;;
  9.2) cat <<EOF
TITLE  Standby instance running (MOUNT)
WHERE  This server ($S), as $OU
RUN    With Grid (the instance the copy left running is stopped, then Oracle Restart starts it).
       $SSQL
       shutdown immediate
       exit
       srvctl start database -db $SU
       Without Grid:
       $SSQL
       startup mount
       exit
       Check:
       $SSQL
       select instance_name, status from v\$instance;
EXPECT $SID  MOUNTED
       Never OPEN read only without an Active Data Guard license.
EOF
  ;;
  9.3) cat <<EOF
TITLE  Standby redo logs on this server
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       alter database recover managed standby database cancel;
       alter system set standby_file_management=manual scope=memory;
       alter database add standby logfile thread 1 size <same as primary>M;
       (this form is for OMF or ASM; otherwise add a file name)
       alter system set standby_file_management=auto scope=memory;
EXPECT Per thread: online groups + 1
       If apply ran before, it is started again afterwards:
       alter database recover managed standby database disconnect from session;
EOF
  ;;
  9.4) cat <<EOF
TITLE  Redo apply (MRP)
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       alter database recover managed standby database disconnect from session;
       select $DGN, $DGR, $DGS2 from $DGP where $DGN like 'MRP%';
EXPECT MRP0 with APPLYING_LOG or WAIT_FOR_LOG
EOF
  ;;
  9.5) cat <<EOF
TITLE  Redo transport from the primary
WHERE  The primary ($P), SQL*Plus as sysdba
RUN    $PSQL
       alter system set log_archive_dest_state_N=enable scope=both;
       (N from step 4.4, usually 2)
       alter system switch logfile;
       select status, error from v\$archive_dest where dest_id=N;
EXPECT VALID, and error is empty
IF     ORA-16191 or ORA-01017: password file (step 6.1)
       ORA-12154: the standby alias on the primary (step 4.9)
       ORA-12514 or ORA-12541: listener and tnsnames.ora here (phase 5)
EOF
  ;;
  9.6) cat <<EOF
TITLE  Redo arrives on this server (RFS)
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       select $DGN, $DGR, $DGS2 from $DGP where $DGR like 'RFS%';
EXPECT At least one RFS row
EOF
  ;;
  9.7)
    printf 'TITLE  Start at boot (mount and apply)\nWHERE  This server (%s), as root\n' "$S"
    if [[ -z "${USE_GRID:-}" ]]; then
      printf 'WHY    With Grid, Oracle Restart mounts the standby but nothing starts redo apply.\n'
      printf '       Without Grid, nothing starts the listener or the standby after a reboot.\n'
      printf 'RUN    With Grid:\n'
    elif [[ $G -eq 1 ]]; then
      printf 'WHY    Oracle Restart mounts the standby after a reboot, but it does not start apply (MRP).\n'
    else
      printf 'WHY    Without Grid, nothing starts the listener or the standby after a reboot.\n'
    fi
    if [[ $G -eq 1 || -z "${USE_GRID:-}" ]]; then
      printf '%s A script (owned by root, run as %s) that waits until v$instance shows MOUNTED,\n' "$([[ $G -eq 1 ]] && printf 'RUN   ' || printf '      ')" "$OU"
      printf '       then runs:\n'
      printf '         alter database recover managed standby database disconnect from session;\n'
      printf '       A systemd unit that runs it (User=%s, Type=simple, After=oracle-ohasd.service).\n' "$OU"
      printf '       Then:\n'
      printf '       systemctl enable <unit>\n'
    fi
    if [[ $G -eq 0 ]]; then
      [[ -z "${USE_GRID:-}" ]] && printf '       Without Grid:\n'
      printf '%s A script (owned by root, run as %s). At start:\n' "$([[ -z "${USE_GRID:-}" ]] && printf '      ' || printf 'RUN   ')" "$OU"
      printf '       It starts the listener (lsnrctl start %s), then in sqlplus / as sysdba: startup mount,\n' "$SL"
      printf '       and alter database recover managed standby database disconnect from session;\n'
      printf '       At shutdown, in sqlplus / as sysdba: shutdown immediate; then lsnrctl stop %s.\n' "$SL"
      printf '       A systemd unit (User=%s, Type=oneshot + RemainAfterExit,\n' "$OU"
      printf '       LimitNOFILE/NPROC/STACK/MEMLOCK as for %s). Then:\n' "$OU"
      printf '       systemctl enable <unit>\n'
    fi
    printf 'EXPECT After a reboot the standby is MOUNTED and MRP runs.\n'
    printf '       When the unit is in place, the step also checks what it started: a stopped listener\n'
    printf '       or apply is started again (asked first); a database that is not a physical standby\n'
    printf '       is only reported. A standby that is down is started through the unit (no Grid),\n'
    printf '       or the step looks again for up to 6 times %s seconds while Oracle Restart mounts it\n' "${POLL_WAIT:-20}"
    printf '       (Grid; if step 9.2 had mounted it in this run, it stopped: that is reported instead).\n'
    printf '       An OPEN standby: the unit does not start apply there (Active Data Guard license).\n'
    printf '       What the unit reported at this boot is also shown at the end of every run.\n'
    printf '       Errors at boot go to the journal with priority "err":\n'
    printf '         journalctl -p err -u <unit>\n'
    printf '       The unit stays active after such an error on purpose: only an active unit runs its\n'
    printf '       stop at shutdown, the clean stop of the standby.\n'
  ;;
  9.8) cat <<EOF
TITLE  Clean-up of archived logs on the standby
WHERE  This server ($S), as $OU (the timer and the files as root)
WHY    Without a deletion policy the archived logs fill the recovery area or the archive
       destination, and redo transport stops (ORA-19809 / ORA-00257).
       A policy copied from the primary with "BACKED UP n TIMES"
       never deletes anything here.
RUN    rman target /
       CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;
       exit
       Then the nightly clean-up that ARCH_CLEANUP sets ($SELF --settings):
       timer    systemd timer $(STANDBY_SID=$SID arch_timer) runs $(STANDBY_SID=$SID arch_script)
       crontab  a line in the crontab of $OU, marked "$(STANDBY_SID=$SID arch_cron_tag)"
       oracle   nothing: the recovery area deletes applied logs when it needs space
       none     nothing
       The script runs, as $OU:
       rman target /
       delete noprompt archivelog all completed before 'sysdate-${ARCH_CLEANUP_DAYS:-1}';
       Logs that are not applied are kept (the policy). Never "force".
       The primary is not changed here. Its own policy belongs to its backups.
       Never set "BACKED UP n TIMES" on a primary that RMAN does not back up.
EXPECT select value from v\$rman_configuration where name='ARCHIVELOG DELETION POLICY';
       shows TO APPLIED ON STANDBY
       timer:   systemctl list-timers $(STANDBY_SID=$SID arch_timer)
       crontab: crontab -u $OU -l
EOF
  ;;
  9.9)
    local KF="/root/.ssh/dg_health_<standby unique, lower case>"; [[ -n "${STANDBY_UNIQUE:-}" ]] && KF=$(health_key_file)
    local SIP=${STANDBY_IP:-<address of this server>} SU9=${PRIMARY_SSH_USER:-oracle}
    cat <<EOF
TITLE  ssh key for --health (monitoring)
WHERE  This server ($S) as root, then the primary ($P) as $SU9
WHY    --health runs from cron and cannot type a password: it logs in to the primary with this
       key of root. The primary accepts it only from this server, without a terminal or forwarding.
       Optional: without it --health checks this standby only (10.3 and 10.5 on the standby side,
       10.6 SKIPPED), and says so in its output.
RUN    On this server, as root:
       install -d -m 700 $(dirname "$KF")
       ssh-keygen -q -t ed25519 -N '' -C 'dg_standby_setup health $S' -f $KF
       cat $KF.pub
       On the primary, as $SU9 (the line: from="..." options, then the whole line of $KF.pub):
       mkdir -p ~/.ssh
       chmod 700 ~/.ssh
       echo 'from="$SIP",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty <line of $KF.pub>' \\
         >> ~/.ssh/authorized_keys
       chmod 600 ~/.ssh/authorized_keys
       Test, on this server as root:
       ssh -i $KF -o BatchMode=yes -o UserKnownHostsFile=${STATE_DIR:-/var/lib/dg_standby_setup}/primary_known_hosts \\
         $SU9@${PRIMARY_IP:-<primary IP>} echo OK
EXPECT OK, without a password question. The step shows the exact line with the real key.
IF     "Permission denied": the line is not in ~$SU9/.ssh/authorized_keys, the from= address is
       not the one this server uses to reach the primary, or ~/.ssh or the file are writable by others
       (sshd StrictModes). "Host key verification failed": step 1.2 (the primary's host key).
       To take it back: remove that line on the primary, and  $SELF --undo 9.9  here.
EOF
  ;;
  10.1) cat <<EOF
TITLE  Transport and apply lag
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       select name, value, datum_time, time_computed from v\$dataguard_stats where name in ('transport lag','apply lag');
EXPECT Both lags 60 seconds or less (--health: HEALTH_LAG_MAX of the settings, 300 by default).
       datum_time is when the standby last received data from the primary. When it does not
       move, the lag values are old: nothing arrives, even if the lag shows 0.
       Right after setup the values can be empty for some minutes.
IF     The lag is high: the script shows the state and error of the primary's destination for
       this standby, with the usual cause of a known error. On the primary:
       select dest_id, status, error from gv\$archive_dest where upper(db_unique_name)=upper('$SU');
EOF
  ;;
  10.2) cat <<EOF
TITLE  No archive gap
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       select * from v\$archive_gap;
EXPECT no rows selected
       A gap is checked again 6 times (2 minutes) before it is reported:
       fal_server usually fetches the missing logs in that time.
EOF
  ;;
  10.3) cat <<EOF
TITLE  Last log: primary and standby
WHERE  Both servers, as $OU, sqlplus / as sysdba
RUN    On the primary:
       select thread#, max(sequence#) from v\$archived_log where standby_dest='NO'
         and resetlogs_change#=(select resetlogs_change# from v\$database) group by thread#;
       On this server:
       select thread#, max(sequence#) from v\$archived_log where applied in ('YES','IN-MEMORY')
         and resetlogs_change#=(select resetlogs_change# from v\$database) group by thread#;
EXPECT For every thread: equal, or the standby is 1 lower
       A standby that is behind is checked again 6 times (2 minutes) before it is reported.
EOF
  ;;
  10.4) cat <<EOF
TITLE  Redo apply is running
WHERE  This server ($S), SQL*Plus as sysdba
RUN    $SSQL
       select $DGN, $DGR, $DGS2 from $DGP where $DGN like 'MRP%';
       select count(*) from v\$standby_log where status='ACTIVE';
       (1 or more: real-time apply gets redo)
       select timestamp, message from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp;
EXPECT MRP0 runs, at least one standby log is ACTIVE, and no Error or Fatal
       message is newer than 15 minutes. Otherwise the step is "waiting":
       run the script again in a few minutes. Older errors (24 hours) are
       shown as a warning; when new ones came since the last run (but none in the last 15
       minutes), the step is "waiting" too. No standby log at all: step 9.3 adds them.
       A view that cannot be read is a problem, not "running".
       Right after the setup, a few messages from the start of transport are
       normal (for example ORA-16401). New ones that keep coming are not.
       For known error codes the usual cause and the step that fixes it are shown.
EOF
  ;;
  10.5) cat <<EOF
TITLE  No unrecoverable (NOLOGGING) changes
WHERE  The primary ($P) and this server ($S), SQL*Plus as sysdba
WHY    NOLOGGING work on the primary writes no redo for the data. The standby only learns that
       the blocks are invalid; the error (ORA-01578, ORA-26040) shows when the data is read,
       often only after a failover. Force logging on the primary prevents it.
RUN    On the primary, in sqlplus / as sysdba:
       select force_logging from v\$database;
       On this server (12.2 and later), in sqlplus / as sysdba:
       select count(*), sum(blocks) from v\$nonlogged_block;
EXPECT force_logging YES (or STANDBY NOLOGGING ..., set on purpose) and no nonlogged blocks.
       12.1 has no list of nonlogged blocks: only force logging is checked there.
IF     Nonlogged blocks: fetch them from the primary. On this server, as $OU:
       \$ORACLE_HOME/bin/sqlplus / as sysdba
       alter database recover managed standby database cancel;
       exit
       \$ORACLE_HOME/bin/rman target /
       recover database nonlogged block;
       exit
       \$ORACLE_HOME/bin/sqlplus / as sysdba
       alter database recover managed standby database disconnect from session;
       Force logging off: on the primary  alter database force logging;
       (force logging can also be set per PDB or per tablespace; check those if you use them).
EOF
  ;;
  10.6) cat <<EOF
TITLE  Patch level: primary and standby
WHERE  Both servers, as $OU
RUN    \$ORACLE_HOME/OPatch/opatch lspatches      (on the primary and here, database home)
       The script compares the patch folders in $DBH/inventory/oneoffs (read-only).
EXPECT The same patches in both database homes.
IF     Different: normal for a short time while a Release Update is applied standby first
       (Release Updates and patches marked Standby-First allow it). Finish it on both
       servers; datapatch runs only on the primary. The Grid home is not compared here.
       A RAC primary: only the node the script connects to is read.
EOF
  ;;
  10.8) cat <<EOF
TITLE  Archived logs: space and nightly clean-up
WHERE  This server ($S), as $OU
WHY    A recovery area that is full of applied (reclaimable) logs is fine: Oracle deletes them
       when it needs space. One that fills with logs that are not reclaimable stops redo
       transport. The nightly clean-up of step 9.8 must also really run.
RUN    sqlplus / as sysdba
       select file_type, percent_space_used, percent_space_reclaimable from v\$recovery_area_usage;
       exit
       timer:
       systemctl status $(STANDBY_SID=$SID arch_service)
       journalctl -u $(STANDBY_SID=$SID arch_service)
       crontab:
       tail $(STANDBY_SID=$SID arch_cron_log)
EXPECT Not reclaimable below 80 %. The last clean-up without RMAN- or ORA- errors.
EOF
  ;;
  10.7) cat <<EOF
TITLE  Roll forward the standby from the primary
WHERE  This server ($S), as $OU; only with  --roll-forward
WHY    When the standby cannot catch up (archived logs it needs were deleted on the primary),
       or after NOLOGGING work: the standby fetches what it misses as incremental backups,
       instead of a whole new copy. Needs 18c or later.
RUN    $SSQL
       alter database recover managed standby database cancel;
       exit
       \$ORACLE_HOME/bin/rman target sys@$ST
       recover standby database from service $PT;
       exit
       \$ORACLE_HOME/bin/sqlplus / as sysdba
       alter database recover managed standby database disconnect from session;
EXPECT RMAN restarts the standby instance, takes the control file of the primary, copies the
       datafiles added since, and applies the changes. Then redo apply runs again.
       The script checks first: the standby is mounted, no RMAN session or long job runs, the
       broker is off on the standby, RMAN logs in to both databases, the listener has a static
       entry for $SID, every wallet of an encrypted standby (each container) is auto-login and
       open, and RMAN can find the standby's datafiles again: same names, a db_file_name_convert
       that gives the standby's name of every datafile, or Oracle-managed files.
       Afterwards the script drops the standby redo log entries that came with the primary's
       control file and adds the standby's own (9.3), catalogs the recovery area, cross-checks
       the archived logs, and sets the deletion policy again (9.8). The temp files then have
       the primary's names: check them before you open or switch over to this standby.
       A roll forward that ended while no run was watching is finished by the next run of
       --roll-forward (asked with ROLLFORWARD again); RMAN is not run again for it.
IF     12.1 / 12.2: not automated; see Oracle note 1987763.1. Flashback database on the
       standby: its logs are not usable after it; turn it off and on again.
       Test it once on a test standby before you need it on production.
EOF
  ;;
  health) cat <<EOF
TITLE  Unattended health check (--health)
WHERE  This server ($S), as root, from cron or a monitoring agent
WHY    The checks of phase 10 without questions and without changes.
       The first line is the status for a monitoring system (Nagios form), for example:
         OK - standby $SU, redo apply running; lag: transport 0 s, apply 1 s (limit 300 s) | transport_lag=0s;;300;0 apply_lag=1s;;300;0
       Then one line per check, the role and protection mode, and the last line
       "Result: ... Details: $LOG_DIR/health_<time>.log" (logs kept 14 days).
RUN    $SELF --health
       In root's crontab, with the output in the alert (only when not OK):
         17 6 * * *  out=\$($SELF --health) || <your alert command> "\$out"
       (in a crontab file, % must be written \%; the line above has none)
       From a monitoring agent (NRPE and the like): allow 300 seconds (a problem is looked at
       twice, 60 seconds apart), for example  check_nrpe ... -t 300
EXPECT Exit 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (could not check), as monitoring systems
       expect. CRITICAL counts first, then UNKNOWN, then WARNING; SKIPPED counts as nothing.
       A problem in 10.1 to 10.4 (lag, gap, last log, apply) is checked once more after
       60 seconds before it is reported. HEALTH_LAG_MAX in the settings: the accepted lag in
       seconds (300 if empty, at least 30). The standby instance is checked first: down is
       CRITICAL at once. After a switchover (this server is the primary) the result is UNKNOWN.
IF     The checks of the primary need ssh without a password: the key of step 9.9
       ($SELF --only 9.9, or --help-step 9.9 for the commands).
       Without a key the primary is not checked: 10.3 (last log) and 10.5 (NOLOGGING) are done on
       the standby side only, 10.6 (patch level) is SKIPPED, and a note line says so. The result
       comes from the checks that ran. Other ssh errors (no answer, a changed host key): UNKNOWN.
       While another run of the script or a long job (copy, roll forward) runs: UNKNOWN.
EOF
  ;;
  *) return 1 ;;
  esac
}

help_cmd_block() {
  # stdin: the lines of the "How" part of a help text (their 7-space indent removed). stdout: the same in a form
  # that can be copied: commands and file contents at column 0 (a here-document end word, an entry of
  # tnsnames.ora or listener.ora must start in column 1), explanations as notes: "# " in a shell, "-- " inside
  # sqlplus or rman (a line that starts sqlplus or rman opens it, "exit" closes it). A note at the end of a
  # command line ("cmd      (only if ...)") goes on its own line above the command.
  local l prev=cmd sql=0 prose c n
  local re_note='^(.*[^[:space:]])[[:space:]]{4,}(\([^()]*\))$' re_shellish="[;|&>='\"]"
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ -z "$l" ]] && { printf '\n'; prev=cmd; continue; }
    prose=0
    if [[ "$l" == --* ]]; then printf '%s\n' "$l"; prev=cmd; continue        # an SQL remark, as written
    elif [[ "$l" == *: ]]; then prose=1                                            # "On the primary:", "Then:"
    elif [[ "$l" =~ ^[A-Z][a-z] || "$l" =~ ^(A|I)[[:space:]][a-z] ]]; then prose=1  # a sentence (commands start lower case)
    elif [[ "$l" =~ ^\<[^\>]+\>[[:space:]]+(is|are)[[:space:]] ]]; then prose=1      # "<zone> is the zone ..."
    elif [[ "$l" =~ ^\([^\)=]*[[:space:]][a-z] && "$l" != "(umask"* ]]; then prose=1   # "(with a Release Update ...)"
    elif [[ "$l" =~ ^[0-9]\.[[:space:]] ]]; then prose=1                           # "1. Unzip ..."
    elif [[ "$l" =~ ^[0-9][0-9.]*(c|ai)?[[:space:]][a-z\(] ]]; then prose=1         # "18c and newer: ..."
    elif [[ "$l" =~ ^[a-z]+[[:space:]]{2,}[a-z] ]]; then prose=1                    # a table: "timer    systemd ..."
    elif [[ "$l" =~ ^[[:space:]]+[0-9]+(\.[0-9]+|c|ai)?[[:space:]]{2,} ]]; then prose=1   # "  12.1  oracle-rdbms-..."
    elif [[ $prev == prose && ! "$l" =~ ^[[:space:]] ]]; then prose=1                # the sentence goes on
    elif [[ "$l" == *. && ! "$l" =~ $re_shellish && $(wc -w <<< "$l") -ge 6 ]]; then prose=1   # "<zone> is the zone of ..."
    fi
    c="# "; [[ $sql -eq 1 ]] && c="-- "
    if [[ $prose -eq 1 ]]; then
      printf '%s%s\n' "$c" "$l"
      # a sentence that ends (with . or :) does not go on into the next line
      if [[ "$l" == *. || "$l" == *: || "$l" == *\) ]]; then prev=end; else prev=prose; fi
      continue
    fi
    prev=cmd
    if [[ "$l" =~ $re_note ]]; then printf '%s%s\n' "$c" "${BASH_REMATCH[2]}"; l=${BASH_REMATCH[1]}; fi
    printf '%s\n' "$l"
    n=${l#"${l%%[![:space:]]*}"}
    if [[ "$n" =~ ^(exit|EXIT|quit)\;?$ ]]; then sql=0
    elif [[ "$n" =~ (^|/)(sqlplus|rman)([[:space:]]|$) && "$n" != *"|"* && "$n" != *" -V"* ]]; then sql=1; fi
  done
}

show_help() {
  local id=${1:-} txt line key rest title
  if ! txt=$(help_text "$id"); then
    printf '    No help for step "%s". All steps:  %s --help-step all\n' "$id" "$SELF"; return 1
  fi
  title=$(grep -m1 '^TITLE ' <<< "$txt"); title=${title:7}
  local t="Help $S_DOT $([[ "$id" == *.* ]] && printf 'Step ')$id  $title" lbl
  if [[ ${#t} -le 62 ]]; then printf '\n    %s%s %s %s%s\n' "$C_C" "$(rule 2)" "$t" "$(rule $((64 - ${#t})))" "$C_N"
  else printf '\n    %s%s %s%s\n    %s%s%s\n' "$C_C" "$(rule 2)" "$t" "$C_N" "$C_C" "$(rule 70)" "$C_N"; fi   # a long title: the rule goes under it
  # the "How" lines are collected and printed as one block that can be copied (help_cmd_block), between two rules
  local inrun=0 run=""
  _help_flush_run() {
    [[ $inrun -eq 1 ]] || return 0
    printf '\n      %s%-8s%s %s\n' "$C_Y" "How" "$C_N" "(copy the lines between the rules; # and -- lines are notes)"
    printf '%s%s%s\n' "$C_D" "$(rule 70)" "$C_N"
    help_cmd_block <<< "${run%$'\n'}"
    printf '%s%s%s\n' "$C_D" "$(rule 70)" "$C_N"
    inrun=0; run=""
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    key=${line:0:6}; rest=${line:7}
    case "$key" in
      "TITLE ") ;;
      "RUN   ") _help_flush_run; inrun=1; run="$rest"$'\n' ;;
      "WHERE "|"WHY   "|"EXPECT"|"IF    ")
        _help_flush_run
        case "$key" in "WHERE ") lbl="Where" ;; "WHY   ") lbl="Why" ;; "EXPECT") lbl="Expect" ;; *) lbl="Problems" ;; esac
        printf '\n      %s%-8s%s %s\n' "$C_Y" "$lbl" "$C_N" "$rest" ;;
      *) if [[ $inrun -eq 1 ]]; then run+="${line:7}"$'\n'; else printf '               %s\n' "${line:7}"; fi ;;
    esac
  done <<< "$txt"
  _help_flush_run
  printf '    %s%s%s\n\n' "$C_C" "$(rule 70)" "$C_N"
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
  if [[ "$id" == "all" ]]; then for i in "${HELP_IDS[@]}" health; do show_help "$i"; done
  else show_help "$id" || exit 2; fi
}
