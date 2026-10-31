#------------------------------------------------------------------------------
# PHASE 2  Standby OS (users, groups, packages, folders, hosts, ASM disks)
#------------------------------------------------------------------------------
in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx -- "$2"; }

run_cmds() {
  # stdin: one command per line (built by this script from validated values only). Stops at first error.
  local c
  while IFS= read -r c || [[ -n "$c" ]]; do
    [[ -z "$c" ]] && continue
    if ! run_logged "$c" bash -c "$c"; then bad "Failed: $c"; printf '%s\n' "$RUN_OUT" | tail -n 5 | hint; return 1; fi
    [[ "$PLAN" == *"$c"* ]] || say "Ran: $c"      # a command the Plan already shows is not repeated
  done
  return 0
}

# ---- 2.1 groups ----
G_TODO=""
c_2_1() {
  local e name gid cur miss="" diff="" fix=""
  IFS=',' read -ra _ge <<< "$GROUP_GIDS"
  for e in "${_ge[@]}"; do
    name=${e%%:*}; gid=${e#*:}
    cur=$(getent group "$name" | cut -d: -f3)
    if [[ -z "$cur" ]]; then
      local other; other=$(getent group "$gid" | cut -d: -f1)
      if [[ -n "$other" ]]; then
        diff+="Group id $gid is needed for $name, but group $other uses it here"$'\n'
        fix+="groupmod -g <a free gid> $other"$'\n'"groupadd -g $gid $name"$'\n'
      else miss+="groupadd -g $gid $name"$'\n'; fi
    elif [[ "$cur" != "$gid" ]]; then
      diff+="Group $name has id $cur here and $gid on the primary"$'\n'
      fix+="groupmod -g $gid $name"$'\n'
    fi
  done
  if [[ -n "$diff" ]]; then
    NOW="${diff%$'\n'}"
    MANUAL_HOW="root  ->  shell Do this only while no Oracle software is installed here."
    PLAN="${fix%$'\n'}
-- The group ids must be the same on both servers, for ASM and the password file.
-- Files of the old id keep it. To list them: find / -xdev -gid <old gid>"
    return 2
  fi
  if [[ -z "$miss" ]]; then NOW="All ${#_ge[@]} groups exist with the same ids as on the primary"; return 0; fi
  G_TODO=${miss%$'\n'}
  NOW="Missing groups: $(grep -oE '[^ ]+$' <<< "$G_TODO" | paste -sd' ' -)"
  PLAN="$G_TODO"
  USING="Group names and ids from the primary"
  return 1
}
d_2_1() {
  # each command is journaled as soon as it worked (a later failure does not hide an earlier change)
  local c; while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    run_cmds <<< "$c" || return 1
    [[ "$c" =~ ^groupadd\ -g\ ([0-9]+)\ ([A-Za-z0-9_.-]+)$ ]] && journal GROUP "${BASH_REMATCH[2]}" "gid ${BASH_REMATCH[1]}"
  done <<< "$G_TODO"
  return 0
}

# ---- 2.2 users ----
U_TODO=""
c_2_2() {
  local spec name uid pg supp g miss_g todo="" err="" fix="" why="" ge
  # the users need their groups: without them useradd fails
  for ge in ${GROUP_GIDS//,/ }; do
    getent group "${ge%%:*}" >/dev/null 2>&1 || { NOW="The group ${ge%%:*} does not exist yet (step 2.1)"; return 2; }
  done
  local -a specs=("$ORACLE_USER|$ORACLE_UID|$INSTALL_GROUP|$ORACLE_GROUPS")
  single_owner || specs+=("$GRID_USER|$GRID_UID|$GRID_PGROUP|$GRID_GROUPS")
  for spec in "${specs[@]}"; do
    IFS='|' read -r name uid pg supp <<< "$spec"
    if ! id "$name" >/dev/null 2>&1; then
      local other; other=$(getent passwd "$uid" | cut -d: -f1)
      if [[ -n "$other" ]]; then
        err+="User id $uid is needed for $name, but user $other uses it here"$'\n'
        fix+="usermod -u <a free uid> $other"$'\n'; continue
      fi
      todo+="useradd -m -s /bin/bash -u $uid -g $pg${supp:+ -G $supp} $name"$'\n'; why+="$name does not exist yet"$'\n'; continue
    fi
    [[ "$(id -u "$name")" == "$uid" ]] || { err+="User $name has id $(id -u "$name") here and $uid on the primary"$'\n'; fix+="usermod -u $uid $name"$'\n'; continue; }
    [[ "$(id -gn "$name")" == "$pg" ]] || { todo+="usermod -g $pg $name"$'\n'; why+="$name has another primary group than on the primary ($pg)"$'\n'; }
    miss_g=""
    IFS=',' read -ra _gl <<< "$supp"
    for g in "${_gl[@]}"; do [[ -n "$g" ]] && ! in_group "$name" "$g" && miss_g+="$g,"; done
    [[ -n "$miss_g" ]] && { todo+="usermod -a -G ${miss_g%,} $name"$'\n'; why+="$name is missing groups it has on the primary: $(sed 's/,$//; s/,/, /g' <<< "$miss_g")"$'\n'; }
  done
  if [[ -n "$err" ]]; then
    NOW="${err%$'\n'}"
    MANUAL_HOW="root  ->  shell Do this only while no Oracle software is installed here."
    PLAN="${fix%$'\n'}
-- Files of the old id keep it. To list them: find / -xdev -uid <old uid>"
    return 2
  fi
  if [[ -z "$todo" ]]; then
    if single_owner; then NOW="$ORACLE_USER ($ORACLE_UID) exists with the same groups as on the primary"
    else NOW="$ORACLE_USER ($ORACLE_UID) and $GRID_USER ($GRID_UID) exist with the same groups as on the primary"; fi
    return 0
  fi
  U_TODO=${todo%$'\n'}
  NOW="${why%$'\n'}"
  PLAN="$U_TODO"
  USING="Id, primary group and other groups of each user, from the primary"
  return 1
}
d_2_2() {
  local c; while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    run_cmds <<< "$c" || return 1
    [[ "$c" =~ ^useradd\ .*\ ([A-Za-z0-9_.-]+)$ ]] && journal USER "${BASH_REMATCH[1]}" "$c"
    [[ "$c" =~ ^usermod\ .*\ ([A-Za-z0-9_.-]+)$ ]] && journal USERMOD "${BASH_REMATCH[1]}" "$c"
  done <<< "$U_TODO"
  return 0
}

# ---- 2.3 packages ----
P_TODO=""
preinstall_pkg() {
  # Oracle preinstall package for the primary version (sets kernel parameters, limits, oracle user defaults)
  case "$DB_MAJOR" in
    12) if [[ "$PRIMARY_VERSION" == 12.1* ]]; then printf 'oracle-rdbms-server-12cR1-preinstall'; else printf 'oracle-database-server-12cR2-preinstall'; fi ;;
    18) printf 'oracle-database-preinstall-18c' ;;
    19) printf 'oracle-database-preinstall-19c' ;;
    21) printf 'oracle-database-preinstall-21c' ;;
    *)  printf 'oracle-database-preinstall-23ai' ;;       # 23ai (newer majors are refused in phase 1)
  esac
}
need_pkgs() {
  printf '%s\n' "$(preinstall_pkg)" unzip chrony parted bc
  use_grid && [[ "$(asm_method)" == "asmlib" ]] && printf '%s\n' oracleasm-support
  return 0
}
P_MISS=()
c_2_3() {
  command -v rpm >/dev/null 2>&1 || { NOW="rpm is not found. This server is not Oracle Linux or RHEL."; return 2; }
  local p; P_MISS=()
  while IFS= read -r p; do rpm -q "$p" >/dev/null 2>&1 || P_MISS+=("$p"); done < <(need_pkgs)
  if [[ ${#P_MISS[@]} -eq 0 ]]; then NOW="Required packages are installed"; return 0; fi
  NOW="Missing packages: ${P_MISS[*]}"
  PLAN="Install with $PKG, one package at a time:
  ${P_MISS[*]}"
  USING="Oracle Linux $OS_MAJOR, database $DB_MAJOR
$(preinstall_pkg) sets kernel parameters and limits for the user oracle.
It does not change existing users."
  return 1
}
d_2_3() {
  local p failed=()
  for p in "${P_MISS[@]}"; do
    if run_logged "$PKG install -y $p" "$PKG" install -y "$p" && rpm -q "$p" >/dev/null 2>&1; then say "Installed: $p"; journal PKG "$p"
    else failed+=("$p"); bad "Not installed: $p ($(grep -iE 'no package|unable to find|error' <<< "$RUN_OUT" | head -n 1))"; fi
  done
  [[ ${#failed[@]} -eq 0 ]] && return 0
  local repo
  case "$OS_MAJOR" in 7) repo="ol7_latest ol7_addons" ;; 8) repo="ol8_baseos_latest ol8_appstream ol8_addons" ;; *) repo="ol${OS_MAJOR}_baseos_latest ol${OS_MAJOR}_appstream ol${OS_MAJOR}_addons" ;; esac
  {
    printf 'Usually a repository is not enabled, or there is no internet or local repository.\n'
    printf 'Check:   %s repolist   (needed: %s)\n' "$PKG" "$repo"
    if [[ "$PKG" == "yum" ]]; then printf 'Enable:  yum-config-manager --enable <repo>\n'; else printf 'Enable:  dnf config-manager --set-enabled <repo>\n'; fi
    printf 'Some preinstall packages do not exist for every release, for example 12c on OL8 or OL9.\n'
    [[ " ${failed[*]} " == *" oracleasm-support "* ]] && printf 'Without oracleasm-support, the ASM disks can use udev rules instead.\nTo do that, skip this step. Step 2.12 then offers udev.\n'
    printf 'Then install them yourself and answer r:\n  %s install -y %s\n' "$PKG" "${failed[*]}"
  } | hint
  return 1
}

# ---- 2.4 limits ----
LIMITS_FILE=/etc/security/limits.d/oracle-grid.conf
limit_users() {
  # the preinstall package sets limits only for the user named "oracle"; every other Oracle owner needs its own
  [[ "$ORACLE_USER" != "oracle" ]] && printf '%s\n' "$ORACLE_USER"
  use_grid && ! single_owner && [[ "$GRID_USER" != "oracle" ]] && printf '%s\n' "$GRID_USER"
  return 0
}
LIM_TODO=()
c_2_4() {
  local u miss=()
  LIM_TODO=()
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    grep -qsE "^[[:space:]]*$u[[:space:]]+hard[[:space:]]+nofile" /etc/security/limits.d/*.conf /etc/security/limits.conf 2>/dev/null || miss+=("$u")
  done < <(limit_users)
  if [[ -z "$(limit_users)" ]]; then NOW="Not needed: the only Oracle owner is oracle, and $(preinstall_pkg) sets its limits"; return 0; fi
  if [[ ${#miss[@]} -eq 0 ]]; then NOW="Limits are set for: $(limit_users | paste -sd' ' -)"; return 0; fi
  LIM_TODO=("${miss[@]}")
  NOW="No limits are set for: ${miss[*]}
The preinstall package sets limits only for the user named oracle."
  PLAN="Add limits for ${miss[*]} to $LIMITS_FILE:
nofile 1024/65536, nproc 16384, stack 10240/32768, memlock unlimited"
  [[ "$ORACLE_USER" != "oracle" ]] && ! id oracle >/dev/null 2>&1 && \
    PLAN+=$'\n'"The preinstall package may create a user named oracle (uid 54321). This standby does not use it."
  return 1
}
d_2_4() {
  backup_file "$LIMITS_FILE" || return 1
  local u txt=""
  for u in "${LIM_TODO[@]}"; do
    txt+="$u  soft  nofile   1024"$'\n'"$u  hard  nofile   65536"$'\n'"$u  soft  nproc    16384"$'\n'"$u  hard  nproc    16384"$'\n'
    txt+="$u  soft  stack    10240"$'\n'"$u  hard  stack    32768"$'\n'"$u  soft  memlock  unlimited"$'\n'"$u  hard  memlock  unlimited"$'\n'
  done
  # other lines in the file (limits of other users on a shared server) stay
  printf '# added by dg_standby_setup.sh %s\n%s' "$RUN_ID" "$txt" | append_as root "$LIMITS_FILE" || return 1
  chmod 644 "$LIMITS_FILE"
  printf '%s' "$txt" | log_block "added to $LIMITS_FILE"
}

# ---- 2.5 folders ----
make_dir() {
  # $1 path, $2 owner. Creates missing components owned by $2 (group INSTALL_GROUP, 775).
  # Changes the owner of an existing directory only when it is empty. Never recursive, never through a link.
  local path=$1 owner=$2 p="" comp
  local -a parts=()
  case "$path" in /etc/ORACLE|/etc/ORACLE/*) ;;   # Oracle's default wallet location
    /|/usr|/usr/*|/etc|/etc/*|/var|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/root|/tmp)
    bad "$path is a system folder. It is not created or changed."; return 1 ;; esac
  IFS='/' read -ra parts <<< "${path#/}"
  for comp in "${parts[@]}"; do
    [[ -n "$comp" ]] || continue
    p+="/$comp"
    if [[ -L "$p" ]]; then
      local lo; lo=$(stat -c '%U' "$p")
      [[ "$lo" == "root" ]] || { bad "$p is a symbolic link owned by $lo. It is not used."; return 1; }
    fi
    if [[ ! -e "$p" ]]; then install -d -o "$owner" -g "$INSTALL_GROUP" -m 775 "$p" || return 1; say "Created $p"; journal DIR "$p" "owner $owner"; fi
  done
  [[ -L "$path" ]] && { warn "$path is a symbolic link. Its owner is not changed."; return 0; }
  if dir_empty "$path"; then chown -h "$owner:$INSTALL_GROUP" "$path" && chmod 775 "$path"; fi
}
dir_specs() {
  if use_grid; then printf '%s\n' "$GRID_BASE:$GRID_USER" "$GRID_HOME:$GRID_USER"; fi
  printf '%s\n' "$INVENTORY_DIR:$GRID_USER" "$ORACLE_BASE:$ORACLE_USER" "$DB_HOME:$ORACLE_USER"
}
existing_parent() { local p=$1; while [[ ! -e "$p" && "$p" != "/" ]]; do p=$(dirname "$p"); done; printf '%s' "$p"; }
mnt_of() { df --output=target -- "$(existing_parent "$1")" 2>/dev/null | tail -n 1; }
free_mb_of() { local f; f=$(df -m --output=avail -- "$(existing_parent "$1")" 2>/dev/null | tail -n 1 | tr -d ' '); num "$f" && printf '%s' "$f" || printf '0'; }
c_2_5() {
  users_ok || { NOW="The users do not exist yet (step 2.2)"; return 2; }
  local d own miss="" wrong="" fixw=""
  while IFS=: read -r d own; do
    if [[ ! -d "$d" ]]; then miss+="  $d  (owner $own)"$'\n'; continue; fi
    local cur; cur=$(stat -c '%U' "$d")
    if [[ "$cur" != "$own" && ! ( "$cur" == "root" && "$d" == "$GRID_HOME" ) ]]; then
      if dir_empty "$d"; then miss+="  $d  (owner $cur, becomes $own)"$'\n'
      else wrong+="$d is not empty and belongs to $cur, not $own"$'\n'; fixw+="chown $own:$INSTALL_GROUP $d"$'\n'; fi
    fi
  done < <(dir_specs)
  if [[ -n "$wrong" ]]; then
    NOW="${wrong%$'\n'}"
    MANUAL_HOW="root  ->  shell Only if these files belong to this standby setup."
    PLAN="-- First check what is in the folder (ls -la).
-- Change the owner only if that is right:
${fixw%$'\n'}"
    return 2
  fi
  # an empty home needs room for the software (about 15 GB each)
  local short="" h
  for h in "$DB_HOME" ${GRID_HOME:+"$GRID_HOME"}; do
    dir_empty "$h" || continue
    use_grid || [[ "$h" != "$GRID_HOME" ]] || continue
    [[ $(free_mb_of "$h") -ge 15360 ]] || short+="$(mnt_of "$h") has $(human_mb "$(free_mb_of "$h")") free for $h. It needs about 15 GB."$'\n'
  done
  [[ -n "$short" ]] && warn "Little free space for the software:"$'\n'"${short%$'\n'}"
  if [[ -z "$miss" ]]; then NOW="The folders exist and have the right owners"; return 0; fi
  NOW="Some folders are missing, or an empty folder has the wrong owner"
  PLAN="Create these folders, or set their owner (group $INSTALL_GROUP, mode 775):
${miss%$'\n'}
Folders that are not empty keep their owner."
  USING="Same paths as on the primary"
  return 1
}
d_2_5() { local d own; while IFS=: read -r d own; do make_dir "$d" "$own" || return 1; done < <(dir_specs); }

# ---- 2.6 /etc/hosts on standby ----
# The script fixes /etc/hosts itself (a backup is kept, --undo puts it back):
#   a name that does not resolve gets a line; a name on a 127.x line or on a wrong address is taken off
#   that line and gets its own correct line (lines of other names are never changed).
H_TODO=""; H_FIX=""
v4_of() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }
host_fq() {   # the full name of this server when it is <short name>.<domain>
  local fq; fq=$(hostname 2>/dev/null)
  [[ "$fq" == *.* && "${fq%%.*}" == "$STANDBY_HOST" ]] && printf '%s' "$fq"
}
c_2_6() {
  local todo="" fix="" h ip want why=""
  H_TODO=""; H_FIX=""
  for h in "$PRIMARY_HOST|$PRIMARY_IP" "$STANDBY_HOST|$STANDBY_IP"; do
    IFS='|' read -r h want <<< "$h"
    ip=$(v4_of "$h")
    local fq=""; [[ "$h" == "$STANDBY_HOST" ]] && fq=$(host_fq)
    if [[ -z "$ip" ]]; then
      [[ "$want" =~ ^[0-9.]+$ ]] || { NOW="$h does not resolve, and its IP address is not known"; return 2; }
      todo+="$want    ${fq:+$fq }$h"$'\n'
    elif [[ "$want" =~ ^[0-9.]+$ && "$ip" != "$want" ]]; then
      if [[ "$ip" == 127.* ]]; then why+="$h resolves to $ip (loopback). The primary could not reach this server's listener."$'\n'
      else why+="$h resolves to $ip here, but it is $want"$'\n'; fi
      fix+="$h|$want"$'\n'; todo+="$want    ${fq:+$fq }$h"$'\n'
    fi
  done
  if [[ -z "$todo" ]]; then NOW="Names resolve: $PRIMARY_HOST = $(v4_of "$PRIMARY_HOST"), $STANDBY_HOST = $(v4_of "$STANDBY_HOST")"; return 0; fi
  H_TODO=${todo%$'\n'}; H_FIX=${fix%$'\n'}
  if [[ -L /etc/hosts ]]; then
    NOW="${why:-The host names do not resolve on this server}"$'\n'"/etc/hosts is a symbolic link, so the script does not change it."
    KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
    PLAN="-- Correct the names in DNS or in the file /etc/hosts points to:"$'\n'"$H_TODO"
    return 1
  fi
  if [[ -n "$why" ]]; then
    NOW="${why%$'\n'}"
    PLAN="Correct /etc/hosts (a backup is kept; --undo puts it back):"
    local f; while IFS='|' read -r h want; do [[ -n "$h" ]] && PLAN+=$'\n'"  take $h off the lines with another address"; done <<< "$H_FIX"
    PLAN+=$'\n'"  then add:"$'\n'"$(sed 's/^/    /' <<< "$H_TODO")"
    grep -qE '^hosts:.*dns.*files' /etc/nsswitch.conf 2>/dev/null && PLAN+=$'\n'"Note: /etc/nsswitch.conf asks DNS before /etc/hosts. Correct DNS too."
  else
    NOW="The host names do not resolve on this server"
    PLAN="Add these lines to /etc/hosts (a backup is kept):"$'\n'"$H_TODO"
  fi
  return 1
}
d_2_6() {
  backup_file /etc/hosts || return 1
  local tmp h want fq
  tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
  cp -- /etc/hosts "$tmp" 2>/dev/null || : > "$tmp"
  # take each name (and this server's full name) off every line whose address is not the right one
  while IFS='|' read -r h want; do
    [[ -n "$h" ]] || continue
    fq=""; [[ "$h" == "$STANDBY_HOST" ]] && fq=$(host_fq)
    awk -v n="$h" -v f="$fq" -v w="$want" '
      /^[[:space:]]*(#|$)/ { print; next }
      {
        if ($1 == w || index($1, ":")) { print; next }      # the right line, and IPv6 lines, stay as they are
        out = $1; kept = 0
        for (i = 2; i <= NF; i++) {
          if (substr($i, 1, 1) == "#") { for (j = i; j <= NF; j++) out = out " " $j; break }
          if (tolower($i) == tolower(n) || (f != "" && tolower($i) == tolower(f))) continue
          out = out " " $i; kept++
        }
        if (kept > 0 || NF == 1) print out
      }' "$tmp" > "$tmp.n" && mv -f -- "$tmp.n" "$tmp" || return 1
  done <<< "$H_FIX"
  # a last line without its newline gets one first (else the new line would be glued to it)
  [[ -s "$tmp" && -n "$(tail -c 1 -- "$tmp")" ]] && printf '\n' >> "$tmp"
  local l; while IFS= read -r l; do [[ -n "$l" ]] && ! grep -qxF -- "$l" "$tmp" && printf '%s\n' "$l" >> "$tmp"; done <<< "$H_TODO"
  # written in place: the file keeps its owner, mode and SELinux label; a failed write puts the backup back
  cat -- "$tmp" > /etc/hosts || { [[ -f "/etc/hosts.bak_$RUN_ID" ]] && cat -- "/etc/hosts.bak_$RUN_ID" > /etc/hosts; bad "/etc/hosts could not be written. The old content was put back."; return 1; }
  rm -f -- "$tmp"
  journal_file_written /etc/hosts 1
  say "Corrected /etc/hosts."
  return 0
}

# ---- 2.7 primary resolves standby ----
c_2_7() {
  need_ssh || return 2
  if prim_probe hosts "$STANDBY_HOST" && [[ -n "$(awk '{print $1; exit}' <<< "$RUN_OUT")" ]]; then
    local pip; pip=$(awk '{print $1; exit}' <<< "$RUN_OUT")
    if [[ "$pip" == "$STANDBY_IP" ]]; then NOW="The primary resolves $STANDBY_HOST to $pip"; return 0; fi
    NOW="The primary resolves $STANDBY_HOST to $pip, but this server is $STANDBY_IP"
    PRIMARY_HOW_STEP="root  ->  shell"
    PLAN="-- In /etc/hosts on the primary (or in DNS), change the line for $STANDBY_HOST to:
$STANDBY_IP    $STANDBY_HOST"
    PLAN_UNDO="put back the line '$pip    $STANDBY_HOST' in /etc/hosts on the primary"
    return 1
  fi
  NOW="The primary does not resolve $STANDBY_HOST"
  PRIMARY_HOW_STEP="root  ->  shell"
  PLAN="echo '$STANDBY_IP    $STANDBY_HOST' >> /etc/hosts"
  PLAN_UNDO="remove the line '$STANDBY_IP    $STANDBY_HOST' from /etc/hosts on the primary"
  return 1
}

# ---- 2.8 network to primary listener ----
c_2_8() {
  if timeout 5 bash -c "exec 3<>/dev/tcp/$PRIMARY_IP/$PORT" 2>/dev/null; then NOW="$PRIMARY_IP:$PORT is reachable"; return 0; fi
  NOW="Cannot connect to $PRIMARY_IP:$PORT
A firewall on the primary, or in the network, blocks it."
  KIND_NOW=primary; PRIMARY_HOW_STEP="root  ->  shell Only if the primary runs firewalld. Otherwise ask the network team."
  # added only when it is not open yet, and without a reload (a reload would drop rules the primary admin added at runtime)
  PLAN="firewall-cmd --query-port=$PORT/tcp || { firewall-cmd --add-port=$PORT/tcp ; firewall-cmd --permanent --add-port=$PORT/tcp ; }
# If the port was already open, the network blocks it: ask the network team."
  PLAN_UNDO="only if the port was NOT open before (else clients of the primary lose it): firewall-cmd --remove-port=$PORT/tcp ; firewall-cmd --permanent --remove-port=$PORT/tcp"
  return 1
}

# ---- 2.9 firewall here ----
FW_ZONE=""
c_2_9() {
  if ! systemctl is-active --quiet firewalld 2>/dev/null; then NOW="firewalld is not active"; return 0; fi
  local ifc; ifc=$(ip -o addr show 2>/dev/null | awk -v a="$STANDBY_IP" '{split($4, x, "/"); if (x[1] == a) {print $2; exit}}')
  FW_ZONE=""
  [[ -n "$ifc" ]] && { FW_ZONE=$(firewall-cmd --get-zone-of-interface="$ifc" 2>/dev/null) || FW_ZONE=""; }
  [[ -n "$FW_ZONE" ]] || FW_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
  [[ "$FW_ZONE" =~ ^[A-Za-z0-9_-]+$ ]] || FW_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
  [[ "$FW_ZONE" =~ ^[A-Za-z0-9_-]+$ ]] || FW_ZONE=public
  if firewall-cmd --zone="$FW_ZONE" --query-port="$PORT/tcp" >/dev/null 2>&1; then NOW="Port $PORT/tcp is open (zone $FW_ZONE)"; return 0; fi
  NOW="Port $PORT/tcp is closed in firewalld (zone $FW_ZONE${ifc:+, interface $ifc})"
  PLAN="firewall-cmd --permanent --zone=$FW_ZONE --add-port=$PORT/tcp
firewall-cmd --reload"
  return 1
}
d_2_9() {
  local c; while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    run_cmds <<< "$c" || return 1
    [[ "$c" =~ --zone=([A-Za-z0-9_-]+)\ --add-port=([0-9]+/tcp) ]] && journal FWPORT "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
  done <<< "$PLAN"
  return 0
}

# ---- 2.10 time ----
c_2_10() {
  if systemctl is-active --quiet chronyd 2>/dev/null; then
    if grep -q 'Leap status.*Normal' <<< "$(chronyc tracking 2>/dev/null)"; then NOW="chronyd is running and the clock is in sync"; else NOW="chronyd is running; the sync is not confirmed yet"; fi
    return 0
  fi
  if systemctl is-active --quiet ntpd 2>/dev/null; then NOW="ntpd is running"; return 0; fi
  NOW="No time sync is running (neither chronyd nor ntpd)"
  PLAN="systemctl enable --now chronyd"
  return 1
}
d_2_10() { run_cmds <<< "systemctl enable --now chronyd" && journal SERVICE chronyd; }

# ---- 2.11 profiles ----
PROF_TODO=()
login_env() {
  # what the user really gets after login (the profile is run in a login shell on THIS server)
  timeout 20 runuser -l "$1" -s /bin/bash -c 'printf "%s|%s|%s\n" "${ORACLE_SID:-}" "${ORACLE_HOME:-}" "${ORACLE_BASE:-}"' < /dev/null 2>/dev/null 9>&- | tail -n 1
}
profile_specs() {
  printf '%s\n' "$ORACLE_USER|$ORACLE_BASE|$DB_HOME|$STANDBY_SID"
  if use_grid && ! single_owner; then printf '%s\n' "$GRID_USER|$GRID_BASE|$GRID_HOME|+ASM"; fi
}
profile_block() { printf '# Added by dg_standby_setup.sh (Data Guard standby %s)\nexport ORACLE_BASE=%s\nexport ORACLE_HOME=%s\nexport ORACLE_SID=%s\nexport PATH=$ORACLE_HOME/bin:$PATH\n' "$STANDBY_UNIQUE" "$2" "$3" "$4"; }
c_2_11() {
  users_ok || { NOW="The users do not exist yet (step 2.2)"; return 2; }
  local entry usr base home sid cur csid chome cbase todo=() report="" okl="" over=""
  while IFS= read -r entry; do
    IFS='|' read -r usr base home sid <<< "$entry"
    cur=$(login_env "$usr"); IFS='|' read -r csid chome cbase <<< "$cur"
    if [[ "$csid" == "$sid" && "${chome%/}" == "$home" && "${cbase%/}" == "$base" ]]; then okl+="${okl:+, }$usr ($sid)"; continue; fi
    local prof; prof="$(home_of "$usr")/.bash_profile"
    if [[ -f "$prof" ]] && grep -qxF "export ORACLE_SID=$sid" "$prof" && grep -qxF "export ORACLE_HOME=$home" "$prof" && grep -qF "dg_standby_setup.sh" "$prof"; then
      over+="$usr: the lines are in $prof, but after login the values are:"$'\n'"  ORACLE_SID=${csid:-<not set>}  ORACLE_HOME=${chome:-<not set>}"$'\n'
      continue
    fi
    todo+=("$entry")
    report+="$usr now has: ORACLE_SID=${csid:-<not set>}  ORACLE_HOME=${chome:-<not set>}  ORACLE_BASE=${cbase:-<not set>}"$'\n'
  done < <(profile_specs)
  if [[ -n "$over" ]]; then
    NOW="${over%$'\n'}"
    KIND_NOW=manual; MANUAL_HOW="the Oracle user  ->  shell"
    PLAN="-- A file read after ~/.bash_profile sets other values, often ~/.bashrc or /etc/profile.d/*.sh.
-- To find the lines:
grep -n 'ORACLE_' ~/.bashrc /etc/profile.d/*.sh
-- Remove or correct them, then answer r."
    return 1
  fi
  if [[ ${#todo[@]} -eq 0 ]]; then NOW="Environment is correct: $okl"; return 0; fi
  PROF_TODO=("${todo[@]}")
  NOW="${report%$'\n'}"
  PLAN="Add these settings to ~/.bash_profile of each user (a backup is kept):"
  local others; others=$(grep -vE '^\s*(#|$|\+ASM)' /etc/oratab 2>/dev/null | cut -d: -f1 | grep -vx -- "$STANDBY_SID" | paste -sd' ' -)
  [[ -n "$others" ]] && USING="/etc/oratab lists other databases here: $others
After this, the default ORACLE_SID of $ORACLE_USER is $STANDBY_SID."
  for entry in "${todo[@]}"; do
    IFS='|' read -r usr base home sid <<< "$entry"
    PLAN+=$'\n'"  $usr:"
    PLAN+=$'\n'"    ORACLE_BASE=$base"$'\n'"    ORACLE_HOME=$home"
    PLAN+=$'\n'"    ORACLE_SID=$sid"$'\n'"    PATH=\$ORACLE_HOME/bin:\$PATH"
  done
  PLAN+=$'\n'"Existing lines stay; the new lines come last, so they win."
  return 1
}
d_2_11() {
  local entry usr base home sid prof
  for entry in "${PROF_TODO[@]}"; do
    IFS='|' read -r usr base home sid <<< "$entry"
    prof="$(home_of "$usr")/.bash_profile"
    [[ -L "$prof" ]] && { bad "$prof is a symbolic link. It is not changed."; return 1; }
    backup_file "$prof" "$usr" || return 1
    profile_block "$usr" "$base" "$home" "$sid" | append_as "$usr" "$prof" || { bad "Cannot write $prof"; return 1; }
    profile_block "$usr" "$base" "$home" "$sid" | log_block "added to $prof"
  done
}

# ---- 2.12 ASM disk method ----
# asmlib: Oracle ASMLib (oracleasm), disks in /dev/oracleasm/disks
# udev:   a udev rule per partition, keyed on the GPT partition UUID, disks in /dev/oraasm
#         (works on every kernel; used when ASMLib is not usable, for example Oracle Linux 9 or a non-UEK kernel)
asm_method() {
  if [[ -n "$ASM_METHOD" ]]; then printf '%s' "$ASM_METHOD"; return; fi
  if [[ "$OS_MAJOR" =~ ^[78]$ && "$(uname -r)" == *uek* ]]; then printf 'asmlib'; else printf 'udev'; fi
}
asm_disk_dir() { if [[ "$(asm_method)" == "asmlib" ]]; then printf '/dev/oracleasm/disks'; else printf '/dev/oraasm'; fi; }
# the OSASM group: owner group of the ASM disks, OSASM in the Grid installation, group of the oracle binary
asm_owner_group() { grp_or asmadmin dba "$GRID_PGROUP"; }
readonly UDEV_RULES=/etc/udev/rules.d/99-oracle-asmdevices.rules
A212_MODE=""
c_2_12() {
  use_grid || { NOW="Not needed (the primary does not use ASM)"; return 0; }
  local m; m=$(asm_method); A212_MODE=""
  if [[ "$m" == "udev" ]]; then
    NOW="ASM disks use udev rules, with devices in /dev/oraasm
Rules file: $UDEV_RULES"
    if [[ "$ASM_METHOD" != "udev" && "$MODE" == "run" ]]; then ASM_METHOD=udev; save_settings; journal SETTING ASM_METHOD "ASM_METHOD=udev"; NOW+=$'\n'"This choice is saved in the settings."; fi
    return 0
  fi
  if ! command -v oracleasm >/dev/null 2>&1; then
    if [[ -n "$(asm_labels_all)" ]]; then NOW="oracleasm is not installed, but earlier ASM disks were made with it (step 2.3)"; return 2; fi
    NOW="ASMLib (oracleasm-support) is not installed"
    PLAN="Use udev rules for the ASM disks instead of ASMLib. They work on every kernel.
To use ASMLib instead: answer s, install oracleasm-support (step 2.3), then run the script again."
    A212_MODE=to_udev
    return 1
  fi
  local cfg st need="" ag; ag=$(asm_owner_group)
  cfg=$(oracleasm configure 2>/dev/null); st=$(oracleasm status 2>/dev/null)
  if ! grep -qx "ORACLEASM_UID=$GRID_USER" <<< "$cfg" || ! grep -qx "ORACLEASM_GID=$ag" <<< "$cfg" || ! grep -qx 'ORACLEASM_ENABLED=true' <<< "$cfg"; then
    need+="oracleasm configure -u $GRID_USER -g $ag -e -s y"$'\n'
  fi
  [[ $(grep -c ': yes' <<< "$st") -ge 2 ]] || need+="oracleasm init"$'\n'
  systemctl is-enabled --quiet oracleasm 2>/dev/null || need+="systemctl enable oracleasm"$'\n'
  if [[ -z "$need" && "$ASM_METHOD" == "asmlib" ]]; then NOW="ASMLib is configured for $GRID_USER:$ag, loaded, and starts at boot"; return 0; fi
  if [[ "$need" == "systemctl enable oracleasm"$'\n' ]]; then NOW="ASMLib is configured and loaded, but does not start at boot"
  elif [[ -z "$need" ]]; then NOW="ASMLib is configured and loaded, but not yet chosen for the ASM disks"
  else
    local nl=""
    [[ "$need" == *"oracleasm configure"* ]] && nl+="${nl:+; }not configured for $GRID_USER:$ag"
    [[ "$need" == *"oracleasm init"* ]] && nl+="${nl:+; }not loaded"
    [[ "$need" == *"systemctl enable"* ]] && nl+="${nl:+; }does not start at boot"
    NOW="ASMLib (oracleasm): $nl"
  fi
  PLAN="${need%$'\n'}"
  [[ -n "$PLAN" ]] || PLAN="Use ASMLib for the ASM disks"
  A212_MODE=asmlib
  return 1
}
d_2_12() {
  case "$A212_MODE" in
    to_udev|save) ASM_METHOD=udev; save_settings; return 0 ;;
  esac
  if [[ -n "$PLAN" && "$PLAN" != "Use ASMLib"* ]]; then
    journal ASMCFG oracleasm "$(tr '\n' ';' <<< "$PLAN")"
    if ! run_cmds <<< "$PLAN"; then
      warn "ASMLib does not work on this kernel ($(uname -r)). udev rules are used instead."
      run_logged "oracleasm configure -d" oracleasm configure -d || true
      run_logged "systemctl disable oracleasm" systemctl disable oracleasm || true
      ASM_METHOD=udev; save_settings; return 0
    fi
  fi
  ASM_METHOD=asmlib; save_settings; journal SETTING ASM_METHOD "ASM_METHOD=asmlib"
}

# ---- 2.13 ASM disks ----
# Labels are <DISKGROUP>_<n> (DATA_1, DATA_2, FRA_1). Disks this script made (or that you confirmed)
# are listed in $STATE_DIR/asm_disks as LABEL|partition.
part_name() { if [[ "$1" =~ [0-9]$ ]]; then printf '%sp1' "$1"; else printf '%s1' "$1"; fi; }
asm_disks_file() { printf '%s/asm_disks' "$STATE_DIR"; }
asm_labels_all() {
  if [[ "$(asm_method)" == "asmlib" ]]; then command -v oracleasm >/dev/null 2>&1 && oracleasm listdisks 2>/dev/null
  else ls -1 /dev/oraasm 2>/dev/null; fi
}
asm_labels_any() {
  # every existing label that belongs to disk group $1: DG_<n>, or DG<n> made by an older version
  local dg=${1^^} l other skip
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    if [[ "$l" =~ ^${dg}_[0-9]+$ ]]; then printf '%s\n' "$l"; continue; fi
    [[ "$l" =~ ^${dg}[0-9]+$ ]] || continue
    skip=0
    for other in $(asm_dgs); do
      [[ "$other" != "$dg" && "$other" == "$dg"* && "$l" =~ ^${other}[0-9]+$ ]] && skip=1
    done
    [[ $skip -eq 0 ]] && printf '%s\n' "$l"
  done < <(asm_labels_all) | sort -V
}
asm_label_known() { [[ -f "$(asm_disks_file)" ]] && grep -q "^$1|/" "$(asm_disks_file)"; }        # used by this standby
asm_label_declined() { [[ -f "$(asm_disks_file)" ]] && grep -qx "$1|-" "$(asm_disks_file)"; }       # you said no
asm_labels() {
  # the disks of disk group $1 that this standby uses (made by this script, or confirmed by you)
  local l
  while IFS= read -r l; do [[ -n "$l" ]] && asm_label_known "$l" && printf '%s\n' "$l"; done < <(asm_labels_any "$1")
  return 0
}
asm_foreign() { local l; while IFS= read -r l; do [[ -n "$l" ]] && ! asm_label_known "$l" && ! asm_label_declined "$l" && printf '%s\n' "$l"; done < <(asm_labels_any "$1"); return 0; }
asm_label_exists() {
  if [[ "$(asm_method)" == "asmlib" ]]; then oracleasm listdisks 2>/dev/null | grep -qx -- "$1"; else [[ -e "/dev/oraasm/$1" ]]; fi
}
asm_label_free() { ! asm_label_exists "$1"; }
label_device() {
  # partition behind a label
  # the live mapping first (sd names can change after a reboot), the recorded one only as a fallback
  local l=$1 d
  if [[ "$(asm_method)" == "asmlib" ]]; then d=$(oracleasm querydisk -p "$l" 2>/dev/null | grep -oE '^/dev/[^:]+' | head -n 1)
  else d=$(readlink -f "/dev/oraasm/$l" 2>/dev/null); [[ -b "$d" ]] || d=""; fi
  [[ -n "$d" ]] || d=$( [[ -f "$(asm_disks_file)" ]] && grep -m1 "^$l|/" "$(asm_disks_file)" | cut -d'|' -f2)
  printf '%s' "$d"
}
label_mb() { local d b; d=$(label_device "$1"); [[ -n "$d" ]] || { printf '0'; return; }; b=$(lsblk -dbn -o SIZE "$d" 2>/dev/null | head -n 1); b=${b//[[:space:]]/}; num "$b" || b=0; printf '%s' "$(( b / 1048576 ))"; }
dg_have_mb() { local l t=0; while IFS= read -r l; do [[ -n "$l" ]] && t=$((t + $(label_mb "$l"))); done < <(asm_labels "$1"); printf '%s' "$t"; }
dg_min_mb() { printf '%s' "$(( $(dg_need_mb "$1") * 11 / 10 + 1024 ))"; }
record_label() { install -d -m 700 "$STATE_DIR"; printf '%s|%s\n' "$1" "$2" >> "$(asm_disks_file)"; chmod 600 "$(asm_disks_file)"; }

disk_is_free() {
  # $1 /dev/xxx. 0 = whole local disk, not mounted, not in use, no partitions, no signature and an empty
  # first MiB (an ASM disk of another server, also one without ASMLib, always has a header there). Sets DISK_WHY.
  local disk=$1 sig pt wf rc n
  DISK_WHY=""
  [[ "$disk" =~ ^/dev/(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] || { DISK_WHY="unsupported name"; return 1; }
  n=${disk#/dev/}
  [[ "$(lsblk -dn -o TYPE "$disk" 2>/dev/null)" == "disk" ]] || { DISK_WHY="not a whole disk"; return 1; }
  [[ "$(lsblk -dn -o RM "$disk" 2>/dev/null | tr -d ' ')" != "1" ]] || { DISK_WHY="removable disk"; return 1; }
  [[ -z "$(lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -v '^[[:space:]]*$')" ]] || { DISK_WHY="mounted"; return 1; }
  [[ "$(lsblk -n -o NAME "$disk" 2>/dev/null | tail -n +2 | wc -l)" -eq 0 ]] || { DISK_WHY="has partitions or is in use (LVM, multipath, RAID)"; return 1; }
  [[ -z "$(ls -A "/sys/block/$n/holders" 2>/dev/null)" ]] || { DISK_WHY="in use by $(ls -A "/sys/block/$n/holders" | paste -sd' ' -)"; return 1; }
  rc=0; sig=$(blkid -p -o value -s TYPE "$disk" 2>/dev/null) || rc=$?
  [[ $rc -eq 8 ]] && { DISK_WHY="has data (more than one signature)"; return 1; }
  pt=$(blkid -p -o value -s PTTYPE "$disk" 2>/dev/null || true)
  [[ -z "$sig" && -z "$pt" ]] || { DISK_WHY="has data (${sig}${pt:+ partition-table:$pt})"; return 1; }
  if command -v wipefs >/dev/null 2>&1; then
    # util-linux 2.23 (OL7) prints "offset type [description]"; newer versions print columns. The type is field 2.
    # util-linux 2.29+ (OL8/9): table with an OFFSET column -> ask for TYPE only; 2.23 (OL7): "offset type" lines
    # (-O is the column list; -o would be an offset)
    if wipefs --help 2>&1 | grep -q -- '--output'; then wf=$(wipefs -n -O TYPE --noheadings "$disk" 2>&1 | tr '\n' ' ') || wf="wipefs failed: $wf"
    else wf=$(wipefs -n "$disk" 2>/dev/null | tail -n +2 | grep -v '^-' | grep -v '^[[:space:]]' | awk '{print $2}' | tr '\n' ' ' || true); fi
    [[ -z "${wf// /}" ]] || { DISK_WHY="has signatures ($wf)"; return 1; }
  fi
  if command -v pvs >/dev/null 2>&1 && pvs --noheadings -o pv_name 2>/dev/null | awk -v d="$disk" '$1==d {f=1} END {exit !f}'; then DISK_WHY="LVM"; return 1; fi
  grep -qE "^${disk}[0-9p]*[[:space:]]" /proc/swaps 2>/dev/null && { DISK_WHY="swap"; return 1; }
  cmp -s -n 1048576 -- "$disk" /dev/zero || { DISK_WHY="the first MiB is not empty (old data, or an ASM disk of another server)"; return 1; }
  return 0
}
free_disks() {
  # prints "/dev/x SIZE_MB" for every free whole disk, biggest first. A disk seen twice (same WWN: two paths
  # to one LUN without multipath) is never offered.
  local n w dupw
  dupw=$(lsblk -dn -o WWN 2>/dev/null | tr -d ' ' | grep -v '^$' | sort | uniq -d)
  for n in $(lsblk -dn -o NAME 2>/dev/null); do
    w=$(lsblk -dn -o WWN "/dev/$n" 2>/dev/null | tr -d ' ')
    [[ -n "$w" && -n "$dupw" ]] && grep -qx -- "$w" <<< "$dupw" && continue
    disk_is_free "/dev/$n" && printf '/dev/%s %s\n' "$n" "$(( $(lsblk -dbn -o SIZE "/dev/$n" 2>/dev/null || echo 0) / 1048576 ))"
  done | sort -k2,2nr
}

A213_FOREIGN=""
c_2_13() {
  use_grid || { NOW="Not needed (the primary does not use ASM)"; return 0; }
  [[ "$(asm_method)" == "udev" ]] || command -v oracleasm >/dev/null 2>&1 || { NOW="oracleasm is not installed (step 2.12)"; return 2; }
  local dg have="" miss="" short="" l foreign="" min hv ready="" x fl xm
  for dg in $(asm_dgs); do
    ready+=" +$dg"
    l=$(asm_foreign "$dg")
    if [[ -n "$l" ]]; then
      fl=""; for x in $l; do xm=$(label_mb "$x"); fl+="${fl:+, }$x$([[ $xm -gt 0 ]] && printf ' (%s)' "$(human_mb "$xm")")"; done
      foreign+="  +$dg: $fl"$'\n'
    fi
    min=$(dg_min_mb "$dg"); hv=$(dg_have_mb "$dg")
    if [[ -z "$(asm_labels "$dg")" ]]; then miss+=" +$dg"
    elif [[ $hv -lt $min ]]; then short+=" +$dg"; have+="  +$dg: $(asm_labels "$dg" | paste -sd' ' -)  ($(human_mb "$hv"), needs $(human_mb "$min"))"$'\n'
    else have+="  +$dg: $(asm_labels "$dg" | paste -sd' ' -)  ($(human_mb "$hv"))"$'\n'; fi
  done
  A213_FOREIGN=${foreign%$'\n'}
  if [[ -z "$miss$short$foreign" ]]; then NOW="ASM disks are ready for:$ready"$'\n'"${have%$'\n'}"; return 0; fi
  local fd; fd=$(free_disks)
  NOW=""
  if [[ -n "$miss" ]]; then
    local -a mw=(); read -ra mw <<< "$miss"
    local ml=${mw[${#mw[@]}-1]}
    [[ ${#mw[@]} -gt 1 ]] && ml="$(printf '%s, ' "${mw[@]:0:${#mw[@]}-1}")"; [[ ${#mw[@]} -gt 1 ]] && ml="${ml%, } and ${mw[${#mw[@]}-1]}"
    NOW+="No disks are assigned yet to $ml."$'\n'
  fi
  [[ -n "$short" ]] && NOW+="Too small, more disks are added for:$short"$'\n'
  [[ -n "$foreign" ]] && NOW+="Existing ASM disks found (not created by this script):"$'\n'"$A213_FOREIGN"$'\n'
  [[ -n "$have" ]] && NOW+="ASM disks:"$'\n'"$have"
  [[ -n "$foreign" && -z "$fd" ]] && NOW+="No empty disk was found, so no disk will be partitioned."
  NOW=${NOW%$'\n'}
  PLAN=""
  [[ -n "$foreign" ]] && PLAN="Ask you, for each disk group, whether to use its existing ASM disks."
  if [[ -n "$fd" || -z "$foreign" ]]; then
    [[ -n "$foreign" ]] && PLAN+=$'\n'"Then, for each disk group that still needs disks:"
    PLAN+=$'\n'"Choose one or more empty disks for each disk group (list below)
Each chosen disk gets a GPT label and one partition"
    if [[ "$(asm_method)" == "asmlib" ]]; then PLAN+=$'\n'"Then: oracleasm createdisk <DG>_1, <DG>_2 ..."
    else PLAN+=$'\n'"Then a udev rule makes /dev/oraasm/<DG>_1, owner $GRID_USER:$(asm_owner_group), mode 0660"; fi
    PLAN+=$'\n'"All chosen disks are checked first. Disks with any data are refused."
    PLAN+=$'\n'"You type each disk name to confirm it."
  fi
  PLAN=${PLAN#$'\n'}
  USING="Size needed (database files of the primary + 10%, plus the recovery area):"
  for dg in $(asm_dgs); do USING+=$'\n'"  +$dg  at least $(human_mb "$(dg_min_mb "$dg")")"; done
  if [[ -n "$fd" ]]; then
    USING+=$'\n'"Empty disks found:"
    while read -r l; do USING+=$'\n'"  ${l%% *}  $(human_mb "${l##* }")"; done <<< "$fd"
  else
    [[ -n "$foreign" ]] || USING+=$'\n'"No empty disk was found on this server."
    USING+=$'\n'"Multipath devices are not offered; see --help-step 2.13"
  fi
  return 1
}

udev_uuid() {
  # GPT partition UUID as udev sees it (blkid -p -s PART_ENTRY_UUID prints nothing on OL7 for an empty partition)
  local p=$1 u
  u=$(udevadm info --query=property --name="$p" 2>/dev/null | sed -n 's/^ID_PART_ENTRY_UUID=//p' | head -n 1)
  [[ -n "$u" ]] || u=$(blkid -p -o udev "$p" 2>/dev/null | sed -n 's/^ID_PART_ENTRY_UUID=//p' | head -n 1)
  [[ -n "$u" ]] || u=$(blkid -p -o value -s PART_ENTRY_UUID "$p" 2>/dev/null | head -n 1)
  printf '%s' "$u"
}

make_asm_disk() {
  # $1 label, $2 disk (already validated and confirmed)
  local label=$1 disk=$2 part
  part=$(part_name "$disk")
  disk_is_free "$disk" || { bad "$disk can no longer be used: $DISK_WHY. Nothing was erased."; return 1; }
  journal PART "$disk" "GPT with one partition for ASM disk $label"
  run_cmds <<< "parted -s $disk mklabel gpt mkpart primary 1MiB 100%
partprobe $disk" || return 1
  command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null
  local n=0
  until [[ "$(lsblk -dn -o TYPE "$part" 2>/dev/null)" == "part" ]]; do
    n=$((n + 1)); [[ $n -gt 10 ]] && { bad "Partition $part did not appear"; return 1; }; sleep 1
  done
  if [[ "$(asm_method)" == "asmlib" ]]; then
    if ! run_cmds <<< "oracleasm createdisk $label $part
oracleasm scandisks"; then
      printf 'The disk now has an empty GPT partition, with no data on it.\nTo try again later, clear it first:\n  wipefs -a %s ; wipefs -a %s\n' "$part" "$disk" | hint
      return 1
    fi
  else
    local uuid; uuid=$(udev_uuid "$part")
    if ! [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      bad "Cannot read the partition UUID of $part"
      printf 'The disk now has an empty GPT partition, with no data on it.\nTo try again later, clear it first:\n  wipefs -a %s ; wipefs -a %s\n' "$part" "$disk" | hint
      return 1
    fi
    install -d -m 755 "$(dirname "$UDEV_RULES")" || return 1
    backup_file "$UDEV_RULES" || return 1
    # a retry after a slow udev must not add the same rule twice
    if ! grep -qsF -- "ENV{ID_PART_ENTRY_UUID}==\"$uuid\"" "$UDEV_RULES"; then
      printf 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_UUID}=="%s", SYMLINK+="oraasm/%s", OWNER="%s", GROUP="%s", MODE="0660"\n' \
        "$uuid" "$label" "$GRID_USER" "$(asm_owner_group)" | append_as root "$UDEV_RULES" || return 1
    fi
    chmod 644 "$UDEV_RULES"
    run_cmds <<< "udevadm control --reload-rules
udevadm trigger --action=change --sysname-match=${part#/dev/}
udevadm settle" || return 1
    n=0; until [[ -e "/dev/oraasm/$label" ]]; do n=$((n + 1)); [[ $n -gt 10 ]] && break; sleep 1; done
    local perm; perm=$(stat -L -c '%U:%G:%a' "/dev/oraasm/$label" 2>/dev/null)
    [[ "$perm" == "$GRID_USER:$(asm_owner_group):660" ]] || { bad "/dev/oraasm/$label has owner and mode '$perm', but needs $GRID_USER:$(asm_owner_group):660"; return 1; }
  fi
  asm_label_exists "$label" || { bad "ASM disk $label was created, but it is not visible"; return 1; }
  record_label "$label" "$part"
  journal ASMLABEL "$label" "on $part"
  say "Created ASM disk $label on $part"
}

next_label() {
  # $1 disk group, $2 labels already chosen in this run (space list): the next label that is free everywhere
  local dg=$1 i=1
  while ! asm_label_free "${dg}_$i" || grep -qs "^${dg}_$i|" "$(asm_disks_file)" || [[ " ${2:-} " == *" ${dg}_$i "* ]]; do i=$((i + 1)); done
  printf '%s_%s' "$dg" "$i"
}
asm_header_group() {
  # disk group name in the ASM disk header of label $1 (empty = no ASM header / not in a disk group)
  local d; d=$(label_device "$1"); [[ -n "$d" ]] || { printf '?'; return; }
  # kfdhdb starts at byte 32; its grpname is at +0x48 = byte 104 (dskname is at byte 72)
  dd if="$d" bs=1 skip=104 count=32 2>/dev/null | tr -d '\0 ' | tr -cd 'A-Za-z0-9_$#'
}
asm_group_mounted_here() { use_grid && grid_sw_ok && sql_asm "select name from v\$asm_diskgroup where state in ('MOUNTED','CONNECTED');" && grep -qix -- "$1" <<< "$SQL_OUT"; }

d_2_13() {
  local fd dg i min have total pick n sel=() used=" " def nums l
  # 1) disks that exist but were not made by this script: use them only when you say so
  for dg in $(asm_dgs); do
    l=$(asm_foreign "$dg")
    [[ -n "$l" ]] || continue
    local ok_l="" refused="" reflab="" g
    while IFS= read -r i; do
      [[ -n "$i" ]] || continue
      # a disk that already belongs to a disk group is used only when THIS server's ASM has that group
      # mounted (a disk of the primary, seen here through a shared SAN, must never be taken)
      g=$(asm_header_group "$i")
      if [[ "$g" == "?" ]]; then refused+=$'\n'"  $i: device not found"
      elif [[ -n "$g" ]] && ! asm_group_mounted_here "$g"; then refused+=$'\n'"  $i: in disk group $g, which is not mounted here"; reflab+=" $i"
      else ok_l+=" $i"; fi
    done <<< "$l"
    if [[ -n "$refused" ]]; then
      warn "These existing ASM disks are not used:$refused"$'\n'"They may belong to another server, for example the primary."
      install -d -m 700 "$STATE_DIR"; for i in $reflab; do printf '%s|-\n' "$i" >> "$(asm_disks_file)"; done; chmod 600 "$(asm_disks_file)"
    fi
    [[ -n "$ok_l" ]] || continue
    say "Answer y only if no other database uses$ok_l."
    if confirm "Use the existing ASM disks$ok_l for +$dg"; then
      for i in $ok_l; do record_label "$i" "$(label_device "$i")"; done
    else
      for i in $ok_l; do install -d -m 700 "$STATE_DIR"; printf '%s|-\n' "$i" >> "$(asm_disks_file)"; done; chmod 600 "$(asm_disks_file)"
      say "Not used:$ok_l. This answer is remembered."
      say "New disks are chosen for +$dg instead."
    fi
  done
  # 2) new disks for every disk group that has none or too little space
  fd=$(free_disks)
  local -a disks=(); [[ -n "$fd" ]] && mapfile -t disks <<< "$fd"
  for dg in $(asm_dgs); do
    min=$(dg_min_mb "$dg"); have=$(dg_have_mb "$dg")
    [[ -n "$(asm_labels "$dg")" && $have -ge $min ]] && continue
    local need_more=$(( min - have ))
    [[ ${#disks[@]} -gt 0 ]] || { bad "No empty disk on this server for +$dg. Nothing was erased."$'\n'"Add disks to this server, then try again."; return 1; }
    if [[ $have -gt 0 ]]; then say "+$dg needs at least $(human_mb "$min"). Its disks have $(human_mb "$have"). Empty disks:"
    else say "+$dg needs at least $(human_mb "$min"). Empty disks:"; fi
    def=""
    for i in "${!disks[@]}"; do
      if [[ "$used" == *" ${disks[$i]%% *} "* ]]; then say "  $((i + 1))) ${disks[$i]%% *}  $(human_mb "${disks[$i]##* }")   (chosen)"
      else say "  $((i + 1))) ${disks[$i]%% *}  $(human_mb "${disks[$i]##* }")"; [[ -z "$def" ]] && def=$((i + 1)); fi
    done
    [[ -n "$def" ]] || { bad "Not enough empty disks for +$dg. Nothing was erased."; return 1; }
    local left=0
    for i in "${!disks[@]}"; do [[ "$used" == *" ${disks[$i]%% *} "* ]] || left=$((left + ${disks[$i]##* })); done
    if [[ $left -lt $need_more ]]; then
      bad "The empty disks left have $(human_mb "$left") in total, but +$dg needs $(human_mb "$need_more") more."$'\n'"Add disks to this server. Nothing was erased."
      return 1
    fi
    while true; do
      ask_default "Disk numbers for +$dg, separated by spaces (q = stop, nothing is erased)" "$def"
      [[ "${ANSWER,,}" == "q" ]] && { say "Stopped. Nothing was erased."; return 3; }
      nums=" "; total=0; pick=""
      local -a picks=(); read -ra picks <<< "$ANSWER"
      for n in "${picks[@]}"; do
        if ! [[ "$n" =~ ^[0-9]{1,3}$ ]] || (( 10#$n < 1 || 10#$n > ${#disks[@]} )); then pick="bad"; say "Not a disk number: $n"; break; fi
        n=$((10#$n))
        [[ "$nums" == *" $n "* ]] && continue
        [[ "$used" == *" ${disks[$((n - 1))]%% *} "* ]] && { pick="bad"; say "${disks[$((n - 1))]%% *} is already chosen"; break; }
        nums+="$n "; total=$((total + ${disks[$((n - 1))]##* }))
      done
      [[ "$pick" == "bad" || "$nums" == " " ]] && continue
      if [[ $total -lt $need_more ]]; then bad "These disks have $total MB, but +$dg needs $need_more MB more. Choose more or bigger disks."; continue; fi
      break
    done
    for n in $nums; do
      local lab chosen="" x; for x in "${sel[@]+"${sel[@]}"}"; do chosen+=" ${x%%|*}"; done
      lab=$(next_label "$dg" "$chosen")
      sel+=("$lab|${disks[$((n - 1))]%% *}"); used+="${disks[$((n - 1))]%% *} "
    done
  done
  [[ ${#sel[@]} -gt 0 ]] || return 0
  local p d
  # validate and confirm ALL chosen disks before anything is erased
  for p in "${sel[@]}"; do
    d=${p#*|}
    disk_is_free "$d" || { bad "$d cannot be used: $DISK_WHY. Nothing was erased."; return 1; }
    # online logs with 4096-byte blocks need disks with 4096-byte physical sectors (else ORA-01378 for the standby logs)
    local sb="/sys/block/$(basename "$(readlink -f "$d")")/queue" pbs lbs
    pbs=$(cat "$sb/physical_block_size" 2>/dev/null); lbs=$(cat "$sb/logical_block_size" 2>/dev/null)
    if [[ "${PRIMARY_REDO_BS:-512}" == "4096" ]]; then
      [[ -n "$pbs" && "$pbs" -lt 4096 ]] && { bad "The redo logs of the primary use 4096-byte blocks, but $d has $pbs-byte sectors."$'\n'"The standby logs could not be created (ORA-01378). Use disks with 4K sectors."$'\n'"Nothing was erased."; return 1; }
    else
      [[ -n "$lbs" && "$lbs" -ge 4096 ]] && { bad "$d is a 4K-native disk, but the redo logs of the primary use 512-byte blocks."$'\n'"The standby and online logs could not be created (ORA-01378)."$'\n'"Use disks with 512-byte or 512e sectors. Nothing was erased."; return 1; }
    fi
  done
  for p in "${sel[@]}"; do
    d=${p#*|}
    confirm_word "ALL data on $d ($(lsblk -dn -o SIZE "$d" | tr -d ' ')) will be erased to make ASM disk ${p%%|*}." "$d" \
      || { say "Not confirmed. Nothing was erased."; return 3; }
  done
  for p in "${sel[@]}"; do make_asm_disk "${p%%|*}" "${p#*|}" || return 1; done
}

# ---- 2.14 database folders (file system storage) ----
fs_need_lines() {
  # "dir|MB" for every file system location (database files; recovery area: what a standby needs)
  local d mb
  while IFS= read -r d; do
    mb=$(loc_mb "$d")
    [[ "$d" == "$FRA_LOC" ]] && mb=$((mb + $(fra_need_mb)))
    printf '%s|%s\n' "$d" "$mb"
  done < <(fs_dirs)
}
FS_TODO=()
c_2_14() {
  [[ -n "$(fs_dirs)" ]] || { NOW="Not needed (all database files are in ASM)"; return 0; }
  users_ok || { NOW="The users do not exist yet (step 2.2)"; return 2; }
  local d mb mnt free used missing=() short="" report="" notmine=""
  declare -A need_by_mnt=() free_by_mnt=()
  while IFS='|' read -r d mb; do
    mnt=$(mnt_of "$d"); [[ -n "$mnt" ]] || { NOW="Cannot read the free space of $d (df failed)"; return 2; }
    free=$(free_mb_of "$d")
    # files that are already there (an earlier duplicate) already use their space
    used=0; [[ -d "$d" ]] && used=$(du -smx -- "$d" 2>/dev/null | awk '{print $1+0}'); num "$used" || used=0
    mb=$(( mb > used ? mb - used : 0 ))
    need_by_mnt[$mnt]=$(( ${need_by_mnt[$mnt]:-0} + mb ))
    free_by_mnt[$mnt]=$free
    if [[ -d "$d" && "$(stat -c %U "$d")" == "$ORACLE_USER" ]]; then report+="$d exists (on $mnt)"$'\n'
    elif [[ -d "$d" ]] && ! dir_empty "$d"; then notmine+="$d is owned by $(stat -c %U "$d") and is not empty"$'\n'
    else missing+=("$d"); report+="$d is missing (on $mnt)"$'\n'; fi
  done < <(fs_need_lines)
  if [[ -n "$notmine" ]]; then
    NOW="${notmine%$'\n'}"; MANUAL_HOW="root  ->  shell Check the files first (ls -la)."
    PLAN="$(while IFS= read -r d; do [[ -n "$d" ]] && printf 'chown %s:%s %s\n' "$ORACLE_USER" "$INSTALL_GROUP" "${d%% is owned*}"; done <<< "$notmine")"
    return 2
  fi
  for mnt in "${!need_by_mnt[@]}"; do
    local want=$(( ${need_by_mnt[$mnt]} * 11 / 10 ))
    [[ ${free_by_mnt[$mnt]} -ge $want ]] || short+="File system $mnt has $(human_mb "${free_by_mnt[$mnt]}") free, but needs about $(human_mb "$want")"$'\n'
  done
  if [[ -n "$short" ]]; then
    NOW="${report}${short%$'\n'}"
    MANUAL_HOW="root  ->  shell"
    PLAN="-- Give the database folders enough space, for example a new disk with a new file system.
-- Find an empty disk. Below it is called /dev/<empty disk>.
lsblk
mkfs.xfs /dev/<empty disk>
mkdir -p <mount point, for example $(fs_dirs | head -n 1 | cut -d/ -f1-2)>
echo \"UUID=\$(blkid -s UUID -o value /dev/<empty disk>)  <mount point>  xfs  defaults  0 0\" >> /etc/fstab
mount <mount point>
-- Then answer r. The paths must stay the same as on the primary."
    return 2
  fi
  if [[ ${#missing[@]} -eq 0 ]]; then NOW="${report%$'\n'}"; return 0; fi
  FS_TODO=("${missing[@]}")
  NOW="${report%$'\n'}"
  PLAN="Create these folders (owner $ORACLE_USER:$INSTALL_GROUP, mode 775):"
  for d in "${missing[@]}"; do PLAN+=$'\n'"  $d"; done
  return 1
}
d_2_14() { local d; for d in "${FS_TODO[@]}"; do make_dir "$d" "$ORACLE_USER" || return 1; done; }

# ---- 2.15 storage is not shared with the primary ----
STORAGE_SHARED=""; STORAGE_KEYS=()
disk_ids() {
  # ids of the physical disks below a block device, from lsblk -P output on stdin: W:<wwn> and S:<serial>.
  # Serial numbers that many disks share (QEMU default QM00001, all zeros) are left out.
  grep 'TYPE="disk"' | grep -oE '(WWN|SERIAL)="[^"]+"' | sed -E 's/^WWN="/W:/; s/^SERIAL="/S:/; s/"$//' \
    | grep -vE '^S:(QM[0-9]{5}|0+)$' | sort -u
  return 0
}
storage_clone_file() { printf '%s/storage_clone_ok' "$STATE_DIR"; }
mnt_uuid() { local u=""; [[ "$1" == *" "* ]] && u=${1##* }; [[ "$u" =~ ^[0-9A-Fa-f-]{8,}$ ]] && printf '%s' "$u"; return 0; }
P_MNT_UUIDS=""; P_MNT_COMPLETE=0; P_MNT_RAW=""
read_primary_mounts() {
  # Every file system mounted on the primary from a device, with its UUID and the ids of the disks below it
  # (read-only: findmnt, lsblk; run with sh, whatever the login shell of the user is). Read again at every test.
  # P_MNT_COMPLETE=1 only when every such file system shows a UUID (else a UUID that is not listed proves nothing).
  P_MNT_UUIDS=""; P_MNT_COMPLETE=0; P_MNT_RAW=""
  prim_probe mounts || return 1
  grep -q '^__DG_MOUNTS_END__$' <<< "$RUN_OUT" || return 1
  P_MNT_RAW=$RUN_OUT
  P_MNT_UUIDS=$(awk -F'|' '$1 == "M" && $3 ~ /^[0-9A-Fa-f-]+$/ && length($3) >= 8 { print toupper($3) }' <<< "$RUN_OUT" | sort -u)
  awk -F'|' '$1 == "M" && !($3 ~ /^[0-9A-Fa-f-]+$/ && length($3) >= 8) { bad = 1 } END { exit bad }' <<< "$RUN_OUT" && P_MNT_COMPLETE=1
  return 0
}
primary_ids_of_uuid() {
  # the disk ids below the primary file system(s) with UUID $1
  awk -F'|' -v u="${1^^}" '$1 == "M" { on = (toupper($3) == u); next } on' <<< "$P_MNT_RAW" | disk_ids
}
primary_ids_all() { grep -v '^M|' <<< "$P_MNT_RAW" | disk_ids; }
STORAGE_NET_DONE=" "
storage_not_shared() {
  # Proves for every database folder here that it is not the storage of the primary (same paths on both
  # servers). Only read-only probes run on the primary: test, findmnt, lsblk.
  #   shared:      a network file system from the same source; the test file is seen on primary;
  #                the same file system UUID on the same disk (WWN) as on primary
  #   not shared:  network file system: the test file is not seen after 65 s and the sources differ;
  #                other file systems: the UUID here is known, the primary shows the UUID of every file system
  #                it mounts, and this UUID is not one of them (and no disk of this folder is a disk of the primary)
  #   else not proven: the duplicate is refused until the user confirms exactly that disk.
  # rc 0 = not shared, 1 = shared, 2 = not proven. A folder found shared outranks one that is not proven.
  local d m fst ans lid pid lsrc psrc luuid net lids wcom key ok why plan np=0 info2="" plan2=""
  STORAGE_SHARED=""; STORAGE_INFO=""; STORAGE_PLAN=""; STORAGE_KEYS=()
  read_primary_mounts || { STORAGE_INFO="Cannot read the file systems mounted on the primary (findmnt and lsblk over ssh)"; return 2; }
  for d in $(fs_dirs); do
    ok=0; why=""; plan=""; key=""
    [[ -d "$d" ]] || { [[ -z "$info2" ]] && info2="Folder $d does not exist yet (step 2.14)"; np=1; continue; }
    fst=$(df --output=fstype -- "$d" 2>/dev/null | tail -n 1 | tr -d ' ')
    net=0; case "$fst" in nfs*|cifs|smb*|fuse.*|ceph|glusterfs|9p|lustre|afs) net=1 ;; esac
    # this server: device or export (without a [subvolume] part), file system UUID, disk ids
    lid=$(findmnt -n -o SOURCE,UUID --target "$d" 2>/dev/null | head -n 1); lsrc=${lid%% *}; lsrc=${lsrc%%\[*}
    luuid=$(mnt_uuid "$lid")
    [[ -z "$luuid" && "$lsrc" == /dev/* ]] && { luuid=$(blkid -s UUID -o value -- "$lsrc" 2>/dev/null | head -n 1); [[ "$luuid" =~ ^[0-9A-Fa-f-]{8,}$ ]] || luuid=""; }
    lids=""; [[ "$lsrc" == /dev/* ]] && lids=$(lsblk -nsP -o TYPE,WWN,SERIAL "$lsrc" 2>/dev/null | disk_ids)
    # the primary, same path
    ans=""; prim_probe canlook "$d" && ans=$(head -n 1 <<< "$RUN_OUT")
    [[ "$ans" == "YES" || "$ans" == "NO" ]] || { [[ -z "$info2" ]] && info2="Cannot test $d on the primary (no answer over ssh)"; np=1; continue; }
    pid=""; prim_probe fsid "$d" && pid=$(head -n 1 <<< "$RUN_OUT"); psrc=${pid%% *}; psrc=${psrc%%\[*}
    # 1) a network file system mounted from the same source on both servers
    if [[ $net -eq 1 && -n "$lsrc" && "$lsrc" != /dev/* && "$lsrc" == "$psrc" ]]; then STORAGE_SHARED+="$d ($fst, same source $lsrc on both servers) "; continue; fi
    # 2) a test file written here (as the database owner) must not be visible on the primary
    if [[ "$ans" == "YES" ]]; then
      m="$d/.dg_standby_test_$(hostname -s)_${RUN_ID}_$$"
      CLEANUP_FILES+=("$m")
      runuser -u "$ORACLE_USER" -- sh -c 'umask 077; : > "$1"' sh "$m" 2>/dev/null || ( umask 077; : > "$m" ) 2>/dev/null \
        || { [[ -z "$info2" ]] && info2="Cannot write a test file in $d"; np=1; continue; }
      ans=""; prim_probe exists "$m" && ans=$(head -n 1 <<< "$RUN_OUT")
      if [[ "$ans" == "NO" && $net -eq 1 && "$STORAGE_NET_DONE" != *" $d|$lsrc "* ]]; then
        # a network file system client may cache folder contents for up to a minute: ask again after that (once per run)
        say "$d is $fst. Testing again in 65 seconds, as the primary may cache the folder contents ..."
        sleep 65
        ans=""; prim_probe exists "$m" && ans=$(head -n 1 <<< "$RUN_OUT")
        [[ "$ans" == "NO" ]] && STORAGE_NET_DONE+="$d|$lsrc "
      fi
      rm -f -- "$m"
      case "$ans" in
        YES) STORAGE_SHARED+="$d ($fst, the test file is seen on the primary) "; continue ;;
        NO)  ans=SEEN_NO ;;
        *)   [[ -z "$info2" ]] && info2="Cannot test $d on the primary (no answer over ssh)"; np=1; continue ;;
      esac
    fi
    # 3) the same file system UUID as a file system of the primary (at any path)
    if [[ -n "$luuid" ]] && grep -qxF -- "${luuid^^}" <<< "$P_MNT_UUIDS"; then
      wcom=$(comm -12 <(grep '^W:' <<< "$lids") <(primary_ids_of_uuid "$luuid" | grep '^W:') | sed 's/^W://' | paste -sd' ' -)
      if [[ -n "$wcom" ]]; then STORAGE_SHARED+="$d (file system $luuid on the same disk $wcom as on the primary) "; continue; fi
      key=$luuid
      why="$d has the same file system UUID ($luuid) as a file system of the primary."$'\n'"It is a copy of the primary's disk, or the same disk mounted on both servers."
    elif [[ -n "$lids" ]] && wcom=$(comm -12 <(grep '^W:' <<< "$lids") <(primary_ids_all | grep '^W:') | sed 's/^W://' | paste -sd' ' -) && [[ -n "$wcom" ]]; then
      # 4) a disk of this folder is a disk under a file system of the primary (another partition, or a copied disk id)
      key="disks:$(paste -sd, - <<< "$lids")"
      why="A disk of $d (WWN $wcom) is also under a file system of the primary."$'\n'"It is another partition of the same disk, or a virtual disk copied with its id."
    elif [[ $net -eq 1 ]]; then
      # 5) network file system: only the test file can prove it
      if [[ "$ans" == "SEEN_NO" ]]; then ok=1; STORAGE_INFO+="$d: $fst, the test file is not seen on the primary after 65 seconds ($lsrc here, ${psrc:-?} there)"$'\n'
      else
        why="$d ($fst): the user $PRIMARY_SSH_USER cannot read this folder on the primary, so the test file cannot be used."$'\n'"It cannot be proven that this is not the storage of the primary."
        plan="-- For $d: run the script again with the owner of the database files on the primary:
$SELF --user $ORACLE_USER"
      fi
    elif [[ -n "$luuid" && $P_MNT_COMPLETE -eq 1 ]]; then
      # 6) the primary shows every file system it mounts, and this one is not among them
      ok=1; STORAGE_INFO+="$d: ${fst:-?}, file system $luuid is not mounted on the primary$([[ "$ans" == "SEEN_NO" ]] && printf '; the test file is not seen there')"$'\n'
    else
      if [[ -n "$luuid" ]]; then key=$luuid; elif [[ -n "$lids" ]]; then key="disks:$(paste -sd, - <<< "$lids")"; else key="device:$lsrc"; fi
      if [[ -z "$luuid" ]]; then why="$d: the file system UUID on this server cannot be read."
      else why="$d: the primary does not show the UUID of every file system it mounts."$'\n'"The user $PRIMARY_SSH_USER may not be allowed to read them."; fi
      why+=$'\n'"It cannot be proven that this is not the storage of the primary."
    fi
    [[ $ok -eq 1 ]] && continue
    # not proven: a confirmation for exactly this disk counts
    if [[ -n "$key" && -f "$(storage_clone_file)" ]] && grep -qxF -- "$key" "$(storage_clone_file)"; then
      STORAGE_INFO+="$d: ${fst:-?}, you confirmed it is a separate disk of this server ($key)"$'\n'; continue
    fi
    if [[ -n "$key" ]]; then
      plan="-- $d: do NOT change or format anything until you know which disk this is.
-- Compare the disks on both servers. On this server:
lsblk -s -o NAME,TYPE,WWN,SERIAL,SIZE \$(findmnt -n -o SOURCE --target $d)
-- On the primary:
lsblk -o NAME,TYPE,WWN,SERIAL,SIZE,MOUNTPOINT
-- Or check in the storage or virtualization console whether it is the same volume.${plan:+
$plan}
-- If it is a separate disk of this server, the script asks you to confirm it next."
      STORAGE_KEYS+=("$d|$key")
    fi
    [[ -z "$info2" ]] && { info2=$why; plan2=$plan; }
    np=1
  done
  STORAGE_INFO=${STORAGE_INFO%$'\n'}
  [[ -n "$STORAGE_SHARED" ]] && return 1
  if [[ $np -eq 1 ]]; then STORAGE_INFO=$info2; STORAGE_PLAN=$plan2; return 2; fi
  return 0
}
c_2_15() {
  [[ -n "$(fs_dirs)" ]] || { NOW="Not needed: there are no database folders. ASM disks are checked in step 2.13."; return 0; }
  [[ "$(marker_kind 2>/dev/null)" == "duplicate" ]] && { NOW="The RMAN copy already ran. The storage was checked before it started."; return 0; }
  if [[ "$MODE" == "check" ]]; then NOW="Tested only in a normal run, because it writes a small test file"; return 2; fi
  need_ssh || return 2
  local rc=0; storage_not_shared || rc=$?
  if [[ $rc -eq 2 && ${#STORAGE_KEYS[@]} -gt 0 ]]; then
    # not proven by the script: you compare the disks, then confirm each one here (your answer is kept)
    NOW=$STORAGE_INFO
    PLAN="Compare the disks first:"$'\n'"$STORAGE_PLAN"
    KIND_NOW=ask; return 1
  fi
  if [[ $rc -eq 2 ]]; then NOW=$STORAGE_INFO; [[ -n "$STORAGE_PLAN" ]] && PLAN=$STORAGE_PLAN; return 2; fi
  if [[ $rc -eq 0 ]]; then NOW="Each database folder is on storage of this server only:"$'\n'"$STORAGE_INFO"; return 0; fi
  NOW="DANGER: these folders are the SAME storage as on the primary: $STORAGE_SHARED"$'\n'"The RMAN copy would overwrite the files of the primary database."
  KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do for this server ($(hostname -s))"
  PLAN="-- Give this server its own storage for these paths.
-- Do not use the NFS export or SAN volume of the primary.
-- Mount it at the same path, then answer r.
-- The RMAN copy (step 8.2) is refused until this is fixed."
  :
  return 1
}

d_2_15() {
  # your confirmation for each disk the script could not prove (written only after you typed it)
  local e d key
  for e in "${STORAGE_KEYS[@]+"${STORAGE_KEYS[@]}"}"; do
    d=${e%%|*}; key=${e#*|}
    confirm_word "Is $d ($key) on a separate disk of this server, NOT the storage of the primary?" "SEPARATE" || { say "Not confirmed. The RMAN copy stays refused for $d."; return 3; }
    install -d -m 700 "$STATE_DIR"; printf '%s\n' "$key" >> "$(storage_clone_file)"; chmod 600 "$(storage_clone_file)"
    _log CHANGE "storage confirmed by the admin as separate: $d ($key)"
    journal CONFIRM "storage_clone_ok" "by hand: remove the line $key from $(storage_clone_file)   (your confirmation that $d is a separate disk)"
  done
  return 0
}

# ---- 2.16 memory ----
# The copy gives the standby the primary's memory settings. A server with too little RAM fails at
# startup (ORA-27102, ORA-00845, ORA-04031), so this is checked here, and again just before the copy.
MEM_SGA=0 MEM_PGA=0 MEM_MT=0 MEM_ULP="" MEM_RFS=0 MEM_RAM_MB=0 MEM_FAIL="" MEM_WARN="" MEM_INFO="" MEM_SHM_MB=0 MEM_HP_LOW=0
mem_probe() {
  # 0 fits (MEM_WARN may hold a warning), 1 does not fit (MEM_FAIL), 2 the primary cannot be read
  MEM_SGA=0 MEM_PGA=0 MEM_MT=0 MEM_ULP="" MEM_RFS=0 MEM_RAM_MB=0 MEM_FAIL="" MEM_WARN="" MEM_INFO="" MEM_SHM_MB=0 MEM_HP_LOW=0
  prim_sql "select name||'|'||nvl(value,'0') from v\$parameter where name in ('sga_target','sga_max_size','memory_target','memory_max_target','pga_aggregate_target','use_large_pages','db_recovery_file_dest_size');" || return 2
  local pn pv mmt=0
  while IFS='|' read -r pn pv; do
    case "$pn" in
      sga_target|sga_max_size) num "$pv" && [[ $pv -gt $MEM_SGA ]] && MEM_SGA=$pv ;;
      memory_target) num "$pv" && MEM_MT=$pv ;;
      memory_max_target) num "$pv" && mmt=$pv ;;
      pga_aggregate_target) num "$pv" && MEM_PGA=$pv ;;
      use_large_pages) MEM_ULP=${pv^^} ;;
      db_recovery_file_dest_size) num "$pv" && MEM_RFS=$pv ;;
    esac
  done <<< "$SQL_OUT"
  local kb; kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null); num "$kb" || kb=0
  MEM_RAM_MB=$(( kb / 1024 ))
  local sga_mb=$(( MEM_SGA / 1048576 )) pga_mb=$(( MEM_PGA / 1048576 )) mt_mb=$(( MEM_MT / 1048576 )) mmt_mb=$(( mmt / 1048576 )) need_mb shm_need=0
  # automatic memory (memory_target > 0) holds the SGA and the PGA; otherwise they are added.
  # memory_max_target alone does not turn it on, but the instance then lives in /dev/shm.
  if [[ $mt_mb -gt 0 ]]; then
    [[ $mmt_mb -gt $mt_mb ]] && mt_mb=$mmt_mb
    [[ $mt_mb -gt $sga_mb ]] && sga_mb=$mt_mb
    need_mb=$sga_mb; shm_need=$mt_mb
    MEM_INFO="The primary uses $(human_mb "$need_mb") (memory_target: SGA and PGA together)"
  else
    [[ $mmt_mb -gt 0 ]] && shm_need=$mmt_mb
    need_mb=$(( sga_mb + pga_mb ))
    MEM_INFO="The primary uses $(human_mb "$need_mb"): SGA $(human_mb "$sga_mb") + PGA $(human_mb "$pga_mb")"
  fi
  if [[ $MEM_RAM_MB -gt 0 ]]; then
    MEM_INFO+=$'\n'"This server has $(human_mb "$MEM_RAM_MB") RAM"
    # the SGA is taken at startup: it must fit. The PGA is a target, used as sessions need it.
    if [[ $sga_mb -gt $(( MEM_RAM_MB * 80 / 100 )) ]]; then
      MEM_FAIL="Not enough RAM. This server needs at least $(human_mb $(( sga_mb * 100 / 80 + 1 )))."
      MEM_INFO+=$'\n'"The standby gets the same memory settings as the primary."
      return 1
    fi
    if [[ $need_mb -gt $(( MEM_RAM_MB * 90 / 100 )) ]]; then
      MEM_WARN="SGA + PGA is more than 90% of the RAM here. The standby starts, but with many"
      MEM_WARN+=$'\n'"sessions (after a switchover) it may run short. Better: $(human_mb $(( need_mb * 100 / 90 + 1 ))) RAM or more."
    fi
  else
    MEM_INFO+=$'\n'"The RAM of this server could not be read"
  fi
  if [[ $shm_need -gt 0 ]]; then
    # memory_target / memory_max_target live in /dev/shm (ORA-00845); ASM may use some of it too: 1 GB room
    local shm; shm=$(df -m --output=size /dev/shm 2>/dev/null | tail -n 1 | tr -d ' '); num "$shm" || shm=0
    if [[ $shm -lt $(( shm_need + 1024 )) ]]; then
      MEM_FAIL="/dev/shm is too small: $(human_mb "$shm"). The database needs $(human_mb $(( shm_need + 1024 ))) there"
      MEM_FAIL+=$'\n'"(memory_target or memory_max_target of the primary, plus room for ASM). Otherwise: ORA-00845."
      MEM_SHM_MB=$(( shm_need + 2048 ))
      return 1
    fi
  fi
  if [[ "$MEM_ULP" == "ONLY" || "$MEM_ULP" == "AUTO_ONLY" ]]; then
    local hp hpkb; hp=$(awk '/^HugePages_Total:/{print $2}' /proc/meminfo 2>/dev/null); num "$hp" || hp=0
    hpkb=$(awk '/^Hugepagesize:/{print $2}' /proc/meminfo 2>/dev/null); num "$hpkb" || hpkb=0
    if [[ $(( hp * hpkb / 1024 )) -lt $sga_mb ]]; then
      MEM_HP_LOW=1
      MEM_INFO+=$'\n'"HugePages: the primary requires them (use_large_pages=$MEM_ULP), this server has too few."
      MEM_INFO+=$'\n'"The standby gets use_large_pages=TRUE, so it starts without them. Add HugePages later."
    fi
  fi
  return 0
}

c_2_16() {
  [[ "$(marker_kind 2>/dev/null)" == "duplicate" ]] && { NOW="The RMAN copy already ran. The memory was checked before it started."; return 0; }
  need_ssh || return 2
  local rc=0; mem_probe || rc=$?
  if [[ $rc -eq 2 ]]; then local e; e=$(ora_errors "$SQL_OUT"); NOW="Cannot read the memory settings of the primary${e:+: $e}"; return 2; fi
  if [[ $rc -eq 0 ]]; then
    NOW="Enough RAM:"$'\n'"$MEM_INFO"
    [[ -n "$MEM_WARN" ]] && NOW+=$'\n'"Warning: $MEM_WARN"
    return 0
  fi
  NOW="$MEM_FAIL"$'\n'"$MEM_INFO"
  KIND_NOW=manual
  if [[ $MEM_SHM_MB -gt 0 ]]; then
    MANUAL_HOW="root  ->  shell"
    PLAN="mount -o remount,size=${MEM_SHM_MB}m /dev/shm
-- Keep it after a reboot: in /etc/fstab, the /dev/shm line gets size=${MEM_SHM_MB}m
-- tmpfs  /dev/shm  tmpfs  defaults,size=${MEM_SHM_MB}m  0 0
-- Then answer r."
  else
    MANUAL_HOW="root"; MANUAL_WHERE="To do for this server ($(hostname -s))"
    PLAN="-- Add RAM to the standby, then restart it and answer r.
-- A standby that may become the primary needs as much memory as the primary.
-- The RMAN copy (step 8.2) is refused until this is fixed."
  fi
  return 1
}

phase_2() {
  phase_header 2 "Prepare this server"
  run_step 2.1  auto    "Groups (same names and ids as primary)" c_2_1 d_2_1
  run_step 2.2  auto    "Users (same ids as primary)" c_2_2 d_2_2
  run_step 2.3  auto    "Required packages" c_2_3 d_2_3
  run_step 2.4  auto    "Limits for the Oracle owners" c_2_4 d_2_4
  run_step 2.5  auto    "Software folders (same paths as primary)" c_2_5 d_2_5
  run_step 2.6  auto    "Host names on this server" c_2_6 d_2_6
  run_step 2.7  primary "Primary resolves the standby host name" c_2_7
  run_step 2.8  check   "Network to the primary listener" c_2_8
  run_step 2.9  auto    "Firewall on this server" c_2_9 d_2_9
  run_step 2.10 auto    "Time synchronization" c_2_10 d_2_10
  run_step 2.11 auto    "Environment (.bash_profile) of the Oracle users" c_2_11 d_2_11
  run_step 2.12 auto    "ASM disk method (ASMLib or udev)" c_2_12 d_2_12
  run_step 2.13 auto    "ASM disks" c_2_13 d_2_13
  run_step 2.14 auto    "Database folders and free space (file system)" c_2_14 d_2_14
  run_step 2.15 check   "Database folders are not shared with the primary" c_2_15 d_2_15
  run_step 2.16 check   "Memory (RAM) for the database" c_2_16
  build_envs_if_possible
}
