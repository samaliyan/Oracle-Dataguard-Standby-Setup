#------------------------------------------------------------------------------
# Primary access (READ-ONLY)
#   One ssh master connection (you type the OS password into ssh itself),
#   then a fixed list of read-only probes over that connection.
#------------------------------------------------------------------------------
DISCOVERED=0
SETTINGS_ACCEPTED=0
SYS_VERIFIED=0
PRIMARY_TNS_ADMIN=""

v_name() { [[ "$1" =~ ^[A-Za-z0-9_.+-]+$ && "$1" != -* ]]; }
v_path() { [[ "$1" =~ ^/[A-Za-z0-9_./-]+$ ]]; }

ssh_alive() {
  [[ -n "$SSH_CTL" && -e "$SSH_CTL" ]] || return 1
  ssh -o ControlMaster=no -o ControlPath="$SSH_CTL" -O check "$PRIMARY_SSH_USER@$PRIMARY_IP" >/dev/null 2>&1
}

prim_ssh() {
  # $1 = remote command built by prim_probe / prim_sql only. stdin is passed through.
  # A stuck remote command (a hung NFS path, a wedged listener) ends after PROBE_TIMEOUT seconds (exit 124).
  # ControlMaster=no: a ControlMaster setting in root's ~/.ssh/config must not turn this call into a new master
  timeout --foreground "${PROBE_TIMEOUT:-300}" ssh -o ControlMaster=no -o ControlPath="$SSH_CTL" -o BatchMode=yes -o ConnectTimeout=15 "$PRIMARY_SSH_USER@$PRIMARY_IP" "$1"
}
PROBE_TIMEOUT=300

prim_probe() {
  # Fixed list of read-only commands. Arguments are validated before use.
  # (No tool that writes files is run on the primary: for example the patch list is read
  #  from the folder names in <home>/inventory/oneoffs, not with opatch, which writes logs.)
  local p=$1 cmd
  shift
  local a
  for a in "$@"; do
    [[ "$a" == "/" && ( "$p" == lsdir || "$p" == canlook ) ]] && continue
    [[ "$a" != -* ]] && { v_name "$a" || v_path "$a"; } || fatal "Safety stop: invalid value for the primary check $p: $a"
  done
  case "$p" in
    host)        cmd='hostname -s; hostname -f' ;;
    oratab)      cmd='cat /etc/oratab' ;;
    orainst)     cmd='cat /etc/oraInst.loc' ;;
    olr)         cmd='cat /etc/oracle/olr.loc' ;;
    ps)          cmd='ps -eo pid,user:32,args' ;;
    exe)         num "$1" || fatal "Safety stop: invalid process id $1"; cmd="readlink /proc/$1/exe" ;;
    environ)     num "$1" || fatal "Safety stop: invalid process id $1"
                 cmd="tr '\\0' '\\n' < /proc/$1/environ | grep -E '^(ORACLE_HOME|ORACLE_SID|ORACLE_BASE|TNS_ADMIN)='" ;;
    ids)         cmd="id $1; id $2" ;;
    owner)       cmd="stat -c '%U %G' $1" ;;
    statx)       cmd="stat -c '%U|%G|%a|%F|%Y' $1" ;;
    # only a real answer of test counts (0 = YES, 1 = NO); a timeout or any other end gives no answer ("not proven")
    # (sh -c: the login shell of the ssh user may be csh)
    exists)      cmd="sh -c 'timeout 120 test -e $1; r=\$?; [ \$r -eq 0 ] && echo YES; [ \$r -eq 1 ] && echo NO; true'" ;;
    canlook)     cmd="sh -c 'timeout 120 test -d $1 -a -x $1; r=\$?; [ \$r -eq 0 ] && echo YES; [ \$r -eq 1 ] && echo NO; true'" ;;
    fsid)        cmd="findmnt -n -o SOURCE,UUID --target $1" ;;
    mounts)      cmd="sh -c 'findmnt -rn -o SOURCE,UUID | while read -r s u; do case \"\$s\" in /dev/*) echo \"M|\$s|\$u\"; lsblk -nsP -o TYPE,WWN,SERIAL \"\${s%%\\[*}\";; esac; done; echo __DG_MOUNTS_END__'" ;;
    now)         cmd='date +%s' ;;
    gridver)     cmd="grep -o 'NAME=\"oracle.crs\" VER=\"[0-9.]*\"' $1/inventory/ContentsXML/comps.xml" ;;
    md5)         cmd="md5sum $1" ;;
    lsdir)       cmd="ls -1A $1" ;;
    profile)     cmd="grep -sE '^[[:space:]]*(export[[:space:]]+)?(ORACLE_HOME|ORACLE_SID|ORACLE_BASE|TNS_ADMIN)=' \$HOME/.bash_profile \$HOME/.bashrc" ;;
    orabase)     cmd="env ORACLE_HOME=$1 $1/bin/orabase" ;;
    orabasehome) cmd="env ORACLE_HOME=$1 $1/bin/orabasehome" ;;
    lsnr)        cmd="env ORACLE_HOME=$1${3:+ TNS_ADMIN=$3} timeout 120 $1/bin/lsnrctl status $2" ;;
    invxml)      cmd="cat $1/ContentsXML/inventory.xml" ;;
    tnsping)     cmd="env ORACLE_HOME=$1 TNS_ADMIN=$2 $1/bin/tnsping $3 1" ;;
    hosts)       cmd="getent ahostsv4 $1" ;;
    *) fatal "Safety stop: unknown primary check $p" ;;
  esac
  # commands that read files or devices end on the primary itself after 120 s (a hung NFS path must not leave
  # a stuck process there for every probe)
  case "$p" in owner|statx|fsid|md5|lsdir|gridver|invxml|tnsping|orabase|orabasehome) cmd="timeout 120 $cmd" ;; esac
  # A marker line separates our output from anything a login script on primary prints;
  # stderr goes to the log only, never into the parsed output.
  local out err rc=0
  err=$(mktemp); CLEANUP_FILES+=("$err")
  # a stuck remote command (a hung NFS path, a wedged listener) must not stop the script for ever
  out=$(prim_ssh "echo $PROBE_MARK; $cmd" < /dev/null 2>"$err") || rc=$?
  PROBE_TIMED_OUT=0; PROBE_ERR=""
  [[ $rc -eq 124 ]] && { printf 'no answer from the primary within %s s (%s)\n' "$PROBE_TIMEOUT" "$p" >> "$err"; PROBE_TIMED_OUT=1; warn "The primary did not answer in time ($p). The result of this check is unknown.
Time limits: 120 s on the primary, $PROBE_TIMEOUT s here."; }
  { printf '%s\n' "$out"; printf -- '--- stderr ---\n'; cat "$err"; printf '(exit code %s)\n' "$rc"; } | log_block "PRIMARY probe $p: $cmd"
  PROBE_ERR=$(head -c 2000 "$err" 2>/dev/null)
  rm -f "$err"
  if [[ "$out" == *"$PROBE_MARK"* ]]; then RUN_OUT=${out#*"$PROBE_MARK"}; RUN_OUT=${RUN_OUT#$'\n'}
  else RUN_OUT=""; [[ $rc -eq 0 ]] && rc=1; fi
  return $rc
}
readonly PROBE_MARK="__DG_PROBE_OUTPUT__"
PROBE_TIMED_OUT=0; PROBE_ERR=""

prim_scp() {
  # Copy ONE file FROM primary to this server over the existing connection (read-only on primary).
  local src=$1 dst=$2
  v_path "$src" || fatal "Safety stop: invalid path on the primary: $src"
  run_logged "scp from primary: $src -> $dst" timeout --foreground 600 scp -q -o ControlMaster=no -o ControlPath="$SSH_CTL" -o BatchMode=yes "$PRIMARY_SSH_USER@$PRIMARY_IP:$src" "$dst" < /dev/null && return 0
  local rc=$?
  # OL9 scp uses the SFTP protocol; a primary without the sftp subsystem needs the old protocol (-O)
  if [[ ${OS_MAJOR:-0} -ge 9 ]] && grep -qiE 'subsystem|sftp|connection closed' <<< "$RUN_OUT"; then
    run_logged "scp (old protocol) from primary: $src -> $dst" timeout --foreground 600 scp -O -q -o ControlMaster=no -o ControlPath="$SSH_CTL" -o BatchMode=yes "$PRIMARY_SSH_USER@$PRIMARY_IP:$src" "$dst" < /dev/null && return 0
    rc=$?
  fi
  [[ $rc -eq 124 ]] && RUN_OUT+=$'\n'"no answer from the primary within 600 s"
  return $rc
}

readonly SQL_MARK="__DG_SQL_OUTPUT__"
sql_result() {
  # $1 raw sqlplus output, $2 rc. SQL_OUT = only the lines after the marker
  # (so login banners, glogin.sql output, "Session altered." are ignored).
  local raw=$1 rc=$2
  if [[ "$raw" == *"$SQL_MARK"* ]]; then SQL_OUT=${raw#*"$SQL_MARK"}
  else SQL_OUT=$raw; [[ $rc -eq 0 ]] && rc=1; fi
  SQL_OUT=$(printf '%s\n' "$SQL_OUT" | sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d')
  if [[ $rc -ne 0 ]] || grep -qE '(ORA|SP2|TNS)-[0-9]+' <<< "$raw"; then
    # keep the error text visible to the caller
    [[ "$raw" == *"$SQL_MARK"* ]] || SQL_OUT=$(printf '%s\n' "$raw" | sed -e '/^[[:space:]]*$/d')
    grep -qE '(ORA|SP2|TNS)-[0-9]+' <<< "$SQL_OUT" || SQL_OUT=$(printf '%s\n%s' "$SQL_OUT" "$(grep -E '(ORA|SP2|TNS)-[0-9]+' <<< "$raw")")
    # a failed connect prints its error BEFORE the marker; after it there is only "SP2-0640: Not connected"
    if [[ "$raw" == *"$SQL_MARK"* ]]; then
      local pre=${raw%%"$SQL_MARK"*} pe
      pe=$(grep -E '(ORA|TNS)-[0-9]+' <<< "$pre")
      [[ -n "$pe" ]] && SQL_OUT=$(printf '%s\n%s' "$pe" "$SQL_OUT")
    fi
    return 1
  fi
  return 0
}

readonly SQL_HEADER='set heading off feedback off pagesize 0 verify off echo off trimspool on linesize 4000 tab off
whenever sqlerror exit 3'

readonly_guard() {
  # 0 only for a single-line, single SELECT without data-changing/procedural keywords.
  local q=$1 l body
  [[ "$q" == *$'\n'* || "$q" == *$'\r'* ]] && return 1
  l=${q,,}
  l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
  [[ "$l" =~ ^select[[:space:]] ]] || return 1
  [[ "$l" == *";" ]] || return 1
  body=${l%;}
  [[ "$body" == *";"* ]] && return 1
  [[ "$l" == *"&"* || "$l" == *"--"* || "$l" == *"/*"* || "$l" == *"@"* ]] && return 1
  # quoted names ("SYS"."DBMS_X") and spaces around a dot (sys . x) are folded before the word test
  l=$(sed -E 's/"//g; s/[[:space:]]*\.[[:space:]]*/./g' <<< "$l")
  if grep -Eq '(^|[^a-z0-9_$#])(insert|update|delete|merge|upsert|alter|drop|create|grant|revoke|truncate|rename|comment|begin|declare|exec|execute|call|commit|rollback|savepoint|lock|shutdown|startup|host|spool|connect|into|nextval|for[[:space:]]+update|dbms_[a-z0-9_]*|utl_[a-z0-9_]*|sys\.[a-z0-9_]*)([^a-z0-9_$#]|$)' <<< "$l"; then
    return 1
  fi
  return 0
}

_prim_sqlplus() {
  # $1 connect line, $2 query (already guarded), $3 title. Runs sqlplus ON PRIMARY over ssh.
  local out rc=0
  v_name "$PRIMARY_SID" && v_path "$DB_HOME" && { [[ -z "$PRIMARY_TNS_ADMIN" ]] || v_path "$PRIMARY_TNS_ADMIN"; } && num "$SQL_TIMEOUT" \
    || fatal "Safety stop: invalid SID, home or TNS_ADMIN of the primary"
  # TWO_TASK / LOCAL in the profile of the primary user would send "connect / as sysdba" over the network
  out=$(printf 'set define off echo off\n%s\n%s\nprompt %s\n%s\nexit\n' "$1" "$SQL_HEADER" "$SQL_MARK" "$2" \
        | PROBE_TIMEOUT=$((SQL_TIMEOUT + 30)) prim_ssh "env -u TWO_TASK -u LOCAL -u SQLPATH -u ORACLE_PATH -u ORACLE_PDB_SID ORACLE_HOME=$DB_HOME ORACLE_SID=$PRIMARY_SID TNS_ADMIN=${PRIMARY_TNS_ADMIN:-$DB_HOME/network/admin} timeout $SQL_TIMEOUT $DB_HOME/bin/sqlplus -S /nolog" 2>&1) || rc=$?
  [[ $rc -eq 124 ]] && out+=$'\n'"SP2-0000: sqlplus on primary did not answer within $SQL_TIMEOUT seconds (stopped)"
  [[ $rc -eq 255 ]] && out+=$'\n'"SP2-0000: ssh connection to primary lost (ssh exit 255)"
  { printf 'SQL> %s\n' "$2"; printf '%s\n(exit code %s)\n' "$out" "$rc"; } | log_block "$3"
  sql_result "$out" "$rc"
}

prim_sql() {
  # READ-ONLY query on primary (OS authentication of the primary oracle user).
  local q=$1
  readonly_guard "$q" || { _log SAFETY "Blocked: $q"; fatal "Safety stop: this statement is not read-only, so it was NOT sent to the primary: $q"; }
  _prim_sqlplus "connect / as sysdba" "$q" "PRIMARY (read-only): ${q:0:150}"
}

prim_sql_as_sys() {
  # READ-ONLY query on primary, logging in as sys through the network ($1 = target).
  local target=$1 q=$2
  readonly_guard "$q" || fatal "Safety stop: this statement is not read-only, so it was NOT sent to the primary: $q"
  [[ "$target" =~ ^(//[A-Za-z0-9_.-]+:[0-9]+/[A-Za-z0-9_.-]+|[A-Za-z0-9_.-]+)$ ]] || fatal "Safety stop: invalid connect target $target"
  _prim_sqlplus "connect sys/\"$SYS_PW\"@$target as sysdba" "$q" "PRIMARY sqlplus as sys@$target (read-only): ${q:0:120}"
}

ssh_diagnose() {
  # $1 = ssh error file. Says what is wrong and prints the commands that fix it.
  local e; e=$(cat "$1" 2>/dev/null)
  local u=$PRIMARY_SSH_USER ip=$PRIMARY_IP
  case "$e" in
    *"Permission denied"*)
      print_commands "Check on the PRIMARY ($ip)" "root  ->  shell" <<EOF
# The password of $u was refused, or password login is turned off.
grep -iE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|AllowUsers|DenyUsers)' /etc/ssh/sshd_config
# PasswordAuthentication must be yes. After a change:
systemctl restart sshd
# To unlock the user or set its password:
passwd $u
EOF
      ;;
    *"Connection refused"*)
      print_commands "Check on the PRIMARY ($ip)" "root  ->  shell" <<EOF
# Nothing listens on port 22: sshd is stopped.
systemctl enable --now sshd
systemctl status sshd
EOF
      ;;
    *"timed out"*|*"No route to host"*|*"Network is unreachable"*)
      print_commands "Check on the PRIMARY ($ip)" "root  ->  shell" <<EOF
# The network or a firewall blocks port 22 between the servers.
firewall-cmd --list-services
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload
EOF
      ;;
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
      print_commands "Run on this server ($(hostname -s))" "root  ->  shell" <<EOF
# The host key of $ip is not the saved one. Remove the saved key ONLY if the primary was
# reinstalled or its ssh keys were renewed; otherwise another machine may answer for $ip.
ssh-keygen -R $ip
ssh-keygen -R $ip -f $KH_FILE
# Then run the script again: it shows the new key to check.
EOF
      ;;
    *"Could not resolve hostname"*)
      say "The name $ip cannot be resolved here. Start the script with the IP address:"
      say "  $SELF --primary <IP>" ;;
    *)
      print_commands "Test on this server ($(hostname -s))" "root  ->  shell" <<EOF
ssh -v $u@$ip hostname
EOF
      ;;
  esac
}

KH_FILE="$STATE_DIR/primary_known_hosts"
ROOT_KH="$(getent passwd root 2>/dev/null | cut -d: -f6)/.ssh/known_hosts"   # root's own file, also after su without -
host_key_ok() {
  # The host key of the primary must be known before the password is typed. A usable key already in root's
  # known_hosts (or saved here by an earlier run) is used as it is. A new key is read with ssh-keyscan,
  # its fingerprints are shown, and the admin compares them with the ones on the primary itself.
  # Only after "y" is the key saved (in $KH_FILE; root's own known_hosts is not changed).
  command -v ssh-keyscan >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1 \
    || { bad "ssh-keyscan and ssh-keygen are needed to check the host key of the primary (package openssh-clients)."; return 1; }
  # host and port as ssh itself will use them (an entry in root's ~/.ssh/config may change both)
  local host=$PRIMARY_IP port=22 cfg
  cfg=$(ssh -G "$PRIMARY_SSH_USER@$PRIMARY_IP" 2>/dev/null)
  [[ -n "$cfg" ]] && { host=$(awk '$1 == "hostname" {print $2; exit}' <<< "$cfg"); port=$(awk '$1 == "port" {print $2; exit}' <<< "$cfg"); }
  [[ -n "$host" ]] || host=$PRIMARY_IP; num "$port" || port=22
  local look=$host; [[ "$port" != "22" ]] && look="[$host]:$port"
  local f
  for f in "$ROOT_KH" "$KH_FILE"; do
    # only a key type ssh still uses counts (an old ssh-dss line alone is not a known key)
    [[ -s "$f" ]] && ssh-keygen -F "$look" -f "$f" 2>/dev/null | grep -qE '[[:space:]](ssh-ed25519|ecdsa-sha2-[a-z0-9]+|ssh-rsa)[[:space:]]' && return 0
  done
  local tmp; tmp=$(mktemp "$STATE_DIR/hostkey.XXXXXX") || return 1
  CLEANUP_FILES+=("$tmp")
  timeout 30 ssh-keyscan -T 10 -p "$port" -t ed25519,ecdsa,rsa "$host" 2>/dev/null | grep -v '^#' > "$tmp"
  if [[ ! -s "$tmp" ]]; then
    rm -f -- "$tmp"
    # why: one ssh attempt that cannot log in (BatchMode, no password) and saves no key (known_hosts = /dev/null)
    local elog="$STATE_DIR/ssh_error.log"
    : > "$elog"; chmod 600 "$elog"
    timeout 30 ssh -E "$elog" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null \
      -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=15 "$PRIMARY_SSH_USER@$PRIMARY_IP" true < /dev/null > /dev/null 2>&1 9>&-
    if grep -qiE 'refused|timed out|no route|unreachable|could not resolve' "$elog"; then
      bad "The ssh connection to $PRIMARY_SSH_USER@$PRIMARY_IP failed."
      { printf 'ssh said:\n'; sed 's/^/  /' "$elog"; } | hint
      ssh_diagnose "$elog"
    else
      bad "Cannot read the ssh host key of $PRIMARY_IP (port $port)."
      print_commands "Test on this server ($(hostname -s))" "root  ->  shell" <<EOF
ssh-keyscan -p $port $host
EOF
    fi
    log_block "ssh error output" < "$elog"
    return 1
  fi
  local fps; fps=$(ssh-keygen -lf "$tmp" 2>/dev/null | awk '{print $2"  "$NF}'
                   ssh-keygen -E md5 -lf "$tmp" 2>/dev/null | awk '{print $2"  "$NF}')
  if [[ -z "$fps" ]]; then rm -f -- "$tmp"; bad "The ssh host key of $PRIMARY_IP cannot be read."; return 1; fi
  say "This server does not know the primary yet. The primary sent these ssh host keys:"
  printf '%s\n' "$fps" | sed 's/^/        /'
  print_commands "Check on the PRIMARY ($PRIMARY_IP): the same values must appear" "root  ->  shell" <<'EOF'
for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done
# An old primary (OpenSSH before 6.8) prints MD5 values: compare them with the MD5 lines above.
EOF
  if ! confirm "The fingerprints match the primary. Save the key and connect?"; then
    rm -f -- "$tmp"
    bad "Host key not accepted. Nothing was sent to $PRIMARY_IP. If the values differ, another machine may answer for this address."
    return 1
  fi
  ( umask 077; cat -- "$tmp" >> "$KH_FILE" ) && chmod 600 "$KH_FILE"
  rm -f -- "$tmp"
  _log SSH "host key of $look accepted by the admin: $(printf '%s' "$fps" | tr '\n' ' ')"
  return 0
}

open_ssh() {
  install -d -m 700 "$STATE_DIR"
  SSH_CTL="$STATE_DIR/ssh_ctl"
  # an old master (busy or broken) is closed first: once its socket is removed nothing could close it
  [[ -e "$SSH_CTL" ]] && timeout 10 ssh -o ControlPath="$SSH_CTL" -O exit "$PRIMARY_SSH_USER@$PRIMARY_IP" >/dev/null 2>&1
  rm -f -- "$SSH_CTL"
  local elog="$STATE_DIR/ssh_error.log"
  : > "$elog"; chmod 600 "$elog"
  host_key_ok || return 1
  say "Type the password of $PRIMARY_SSH_USER on $PRIMARY_IP when ssh asks. Only ssh sees it."
  # Only options that every OpenSSH since 6.7 knows (Oracle Linux 7 has 7.4, OL8 has 8.0).
  # -E: ssh writes its own error messages to a file, so they can be shown and logged.
  # StrictHostKeyChecking=yes: only a host key checked by the admin (saved by host_key_ok, or already
  # in root's known_hosts) is accepted. ssh never asks to accept a new key.
  if ssh -E "$elog" -o ControlMaster=yes -o ControlPath="$SSH_CTL" -o ControlPersist=12h \
         -o StrictHostKeyChecking=yes -o CheckHostIP=no -o UserKnownHostsFile="$ROOT_KH $KH_FILE" \
         -o ServerAliveInterval=60 -o ConnectTimeout=15 -o NumberOfPasswordPrompts=3 \
         -fN "$PRIMARY_SSH_USER@$PRIMARY_IP" < "$PROMPT_IN" 9>&-; then
    SSH_OPEN=1
  else
    bad "The ssh connection to $PRIMARY_SSH_USER@$PRIMARY_IP failed."
    if [[ -s "$elog" ]]; then printf 'ssh said:\n'; sed 's/^/  /' "$elog"; fi | hint
    ssh_diagnose "$elog"
    log_block "ssh error output" < "$elog"
    return 1
  fi
  ssh_alive || { bad "The ssh connection is not usable."; sed 's/^/  /' "$elog" | hint; return 1; }
  DONE_MSG="Connected to $PRIMARY_SSH_USER@$PRIMARY_IP."

}

