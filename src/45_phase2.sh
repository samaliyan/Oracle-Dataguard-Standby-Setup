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
    # (the command was shown before it ran: "Running as root: ...")
  done
  return 0
}

# ---- the commands of a step: filled in the check (cp_add, shown under "Will run"), run from that list ----
# P2_META[i]: what the action does around entry i (journal, waits); P2_SNAP: the files the shown content was made
# from, with their md5 at the check (written only while they are still the same)
declare -a P2_META=()
P2_SNAP=""
p2q() { printf '%q' "$1"; }
p2_add() { P2_META[${#CP_CMD[@]}]=$1; shift; cp_add "$@"; }    # $1 tag, then as cp_add
p2_exec() {
  # entry $1 runs; a failure is said (like cp_run). $2 = "alone": the entries after it are not affected
  cp_exec "$1" && return 0
  bad "This command failed:  $(head -n 1 <<< "${CP_CMD[$1]}" | mask_pw)"$'\n'"$(tail -n 4 <<< "$RUN_OUT" | mask_pw)"
  [[ "${2:-}" != alone && $(( $1 + 1 )) -lt ${#CP_CMD[@]} ]] && say "The commands after it were not run."
  return 1
}
p2_md5() { if [[ -e "$1" || -L "$1" ]]; then md5sum -- "$1" 2>/dev/null | cut -d' ' -f1; else printf 'none'; fi; }
p2_snap() { local f; for f in "$@"; do P2_SNAP+="$f|$(p2_md5 "$f")"$'\n'; done; }
p2_unchanged() {
  local l f
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue; f=${l%|*}
    [[ "$(p2_md5 "$f")" == "${l##*|}" ]] || { bad "$f was changed after the check. Nothing was written. Answer r to check again."; return 1; }
  done <<< "$P2_SNAP"
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
  PLAN="Create the missing groups, with the same ids as on the primary."
  USING="Group names and ids from the primary"
  local c; while IFS= read -r c; do [[ -n "$c" ]] && cp_add root "$c"; done <<< "$G_TODO"
  return 1
}
d_2_1() {
  # each command is journaled as soon as it worked (a later failure does not hide an earlier change)
  local i c
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    c=${CP_CMD[$i]}
    p2_exec "$i" || return 1
    [[ "$c" =~ ^groupadd\ -g\ ([0-9]+)\ ([A-Za-z0-9_.-]+)$ ]] && journal GROUP "${BASH_REMATCH[2]}" "gid ${BASH_REMATCH[1]}"
  done
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
  PLAN="Create the users, or give them the primary group and other groups they have on the primary."
  USING="Id, primary group and other groups of each user, from the primary"
  local c; while IFS= read -r c; do [[ -n "$c" ]] && cp_add root "$c"; done <<< "$U_TODO"
  return 1
}
d_2_2() {
  local i c
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    c=${CP_CMD[$i]}
    p2_exec "$i" || return 1
    [[ "$c" =~ ^useradd\ .*\ ([A-Za-z0-9_.-]+)$ ]] && journal USER "${BASH_REMATCH[1]}" "$c"
    [[ "$c" =~ ^usermod\ .*\ ([A-Za-z0-9_.-]+)$ ]] && journal USERMOD "${BASH_REMATCH[1]}" "$c"
  done
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
  printf '%s\n' "$(preinstall_pkg)" unzip
  # chrony only when ntpd does not keep the time here: installed next to a working ntpd, chronyd would be enabled
  # and take over at the next boot (step 2.10 accepts either)
  systemctl is-active --quiet ntpd 2>/dev/null || printf 'chrony\n'
  printf '%s\n' parted bc
  use_grid && [[ "$(asm_method)" == "asmlib" ]] && printf '%s\n' oracleasm-support
  return 0
}
P_MISS=()
p2_proxy_vars() {
  # the proxy variables set in the environment of this script (names only): the commands of the list get them
  local v out=""
  for v in http_proxy https_proxy ftp_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY; do
    [[ -n "${!v:-}" ]] && out+="${out:+, }$v"
  done
  printf '%s' "$out"
}
c_2_3() {
  command -v rpm >/dev/null 2>&1 || { NOW="rpm is not found. This server is not Oracle Linux or RHEL."; return 2; }
  local p pe; P_MISS=()
  while IFS= read -r p; do rpm -q "$p" >/dev/null 2>&1 || P_MISS+=("$p"); done < <(need_pkgs)
  if [[ ${#P_MISS[@]} -eq 0 ]]; then NOW="Required packages are installed"; return 0; fi
  NOW="Missing packages: ${P_MISS[*]}"
  PLAN="Install with $PKG, one package at a time:
  ${P_MISS[*]}"
  USING="Oracle Linux $OS_MAJOR, database $DB_MAJOR
$(preinstall_pkg) sets kernel parameters and limits for the user oracle.
It does not change existing users."
  pe=$(p2_proxy_vars)
  # (proxy values may hold a password: they reach yum / dnf through the environment, never on a command line)
  [[ -n "$pe" ]] && USING+=$'\n'"The proxy settings of this environment are used ($pe)."
  for p in "${P_MISS[@]}"; do cp_add root "$PKG install -y $p" "" 3600; done
  return 1
}
d_2_3() {
  local p failed=() i ok
  # one entry per package: a package that fails does not stop the others
  for ((i = 0; i < ${#P_MISS[@]}; i++)); do
    p=${P_MISS[$i]}; ok=0
    [[ "${CP_CMD[$i]:-}" == *" install -y $p" ]] || { bad "Internal error: the command for $p was not shown before, so it is not run."; return 1; }
    cp_exec "$i" && ok=1
    if [[ $ok -eq 1 ]] && rpm -q "$p" >/dev/null 2>&1; then say "Installed: $p"; journal PKG "$p"
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
  # every Oracle owner. The preinstall package sets limits for the user named "oracle" only; that user is checked
  # as well (the package may be missing or its file changed, and HugePages may need more memlock than it sets)
  printf '%s\n' "$ORACLE_USER"
  use_grid && ! single_owner && [[ "$GRID_USER" != "oracle" ]] && printf '%s\n' "$GRID_USER"
  return 0
}
LIM_TODO=()        # "user item" pairs that are missing (item: nofile nproc stack memlock)
hugepages_kb() {
  # the HugePages set on this server, in KB (0 = none)
  local n sz; n=$(awk '/^HugePages_Total:/{print $2}' "$MEMINFO_FILE" 2>/dev/null); sz=$(awk '/^Hugepagesize:/{print $2}' "$MEMINFO_FILE" 2>/dev/null)
  num "$n" && num "$sz" && printf '%s' $(( n * sz )) || printf 0
}
LIM_MEMLOCK_NEED=0   # KB: the SGA of the primary when it runs only in HugePages (use_large_pages=ONLY or AUTO_ONLY); set by 2.4
lim_min() {
  # memlock (KB): the SGA in HugePages must be lockable: at least the HugePages set here, and the SGA of the
  # primary when it needs HugePages (ONLY or AUTO_ONLY). Without either, the SGA is not locked: any value is enough
  local h
  case "$1" in nofile) printf 65536 ;; nproc) printf 16384 ;; stack) printf 32768 ;;
    memlock) h=$(hugepages_kb); [[ ${LIM_MEMLOCK_NEED:-0} -gt $h ]] && h=$LIM_MEMLOCK_NEED; printf '%s' "$h" ;;
    *) printf 0 ;; esac
}
lim_enough() {
  # $1 item, $2 hard value: at least the Oracle minimum
  [[ "${2,,}" == unlimited || "${2,,}" == infinity || "$2" == "-1" ]] && return 0
  local m; m=$(lim_min "$1"); [[ "$m" == 0 ]] && return 0
  [[ "$2" =~ ^[0-9]+$ ]] && (( 10#$2 >= m ))
}
lim_value() {
  # $1 user, $2 " @group1 @group2 ", $3 item -> "value|file|priority|line" of the hard limit pam_limits uses for
  # it (priority 3 user, 2 group, 1 *; empty = not set)
  local fs=(); [[ -f /etc/security/limits.conf ]] && fs+=(/etc/security/limits.conf)
  local f; for f in /etc/security/limits.d/*.conf; do [[ -f "$f" ]] && fs+=("$f"); done
  [[ ${#fs[@]} -gt 0 ]] || return 0
  awk -v u="$1" -v gs="$2" -v it="$3" '
    { raw = $0; sub(/#.*/, "") }
    NF >= 4 && ($2 == "hard" || $2 == "-") && $3 == it {
      p = 0
      if ($1 == u) p = 3; else if (index(gs, " " $1 " ") > 0) p = 2; else if ($1 == "*") p = 1
      if (p > 0 && p >= best) { best = p; val = $4; wf = FILENAME; wl = raw }
    }
    END { if (best) print val "|" wf "|" best "|" wl }' "${fs[@]}"
}
lim_line() {
  # $1 user, $2 item -> the two lines (soft and hard) this script adds for it
  case "$2" in
    nofile)  printf '%s  soft  nofile   1024\n%s  hard  nofile   65536\n' "$1" "$1" ;;
    nproc)   printf '%s  soft  nproc    16384\n%s  hard  nproc    16384\n' "$1" "$1" ;;
    stack)   printf '%s  soft  stack    10240\n%s  hard  stack    32768\n' "$1" "$1" ;;
    memlock) printf '%s  soft  memlock  unlimited\n%s  hard  memlock  unlimited\n' "$1" "$1" ;;
  esac
}
c_2_4() {
  local u it miss=() users=()
  LIM_TODO=()
  users_ok || { NOW="The users do not exist yet (step 2.2)"; return 2; }
  # every limit the script sets is checked: its hard value as pam_limits uses it (a line for the user beats one
  # for a group, which beats *; among equal ones the last read wins; limits.conf is read before limits.d).
  # A missing limit, or one below the Oracle minimum, is added; the check after the action shows that it counts.
  local who g v over="" w wf wp wl ulp sga
  # the primary needs HugePages for its SGA (use_large_pages=ONLY or AUTO_ONLY): memlock must cover that SGA here too
  LIM_MEMLOCK_NEED=0; local lmnote="" lm_need=0
  if ssh_alive && prim_sql "select upper(value) from v\$parameter where name='use_large_pages';"; then
    ulp=$(first_line)
    if [[ "$ulp" == ONLY || "$ulp" == AUTO_ONLY ]]; then
      # to_char: a number of 10 digits or more would be printed as 1.0E+10
      if prim_sql "select to_char(bytes) from v\$sgainfo where name='Maximum SGA Size';" && sga=$(first_line) && num "$sga"; then lm_need=$(( sga / 1024 ))
      else lmnote="The SGA size of the primary (use_large_pages=$ulp) could not be read: memlock is checked against the HugePages here only."; fi
    fi
  else lmnote="The primary could not be asked whether it needs HugePages: memlock is checked against the HugePages here only."; fi
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    who=" "; for g in $(id -nG "$u" 2>/dev/null); do [[ "$g" =~ ^[A-Za-z0-9_.-]+$ ]] && who+="@$g "; done
    # the SGA of the database is locked by the database owner only (grid runs ASM)
    LIM_MEMLOCK_NEED=0; [[ "$u" == "$ORACLE_USER" ]] && LIM_MEMLOCK_NEED=$lm_need
    for it in nofile nproc stack memlock; do
      w=$(lim_value "$u" "$who" "$it"); IFS='|' read -r v wf wp wl <<< "$w"
      if [[ -z "$v" ]]; then LIM_TODO+=("$u $it"); miss+=("$u:$it")
      elif ! lim_enough "$it" "$v"; then
        # a line for the user in a file read after LIMITS_FILE wins over anything added there: that line is
        # named instead (the script does not change another file)
        if [[ "$wp" == 3 && "$wf" == /etc/security/limits.d/* && "$wf" != "$LIMITS_FILE" && "$wf" > "$LIMITS_FILE" ]]; then
          over+="$wf:  $wl"$'\n'
        else LIM_TODO+=("$u $it"); fi
        miss+=("$u:$it=$v(min $(lim_min "$it"))")
      fi
    done
  done < <(limit_users)
  if [[ ${#miss[@]} -eq 0 ]]; then NOW="Limits (nofile, nproc, stack, memlock) are set for: $(limit_users | paste -sd' ' -)"; [[ -n "$lmnote" ]] && NOW+=$'\n'"$lmnote"; return 0; fi
  if [[ -n "$over" ]]; then
    NOW="Missing or too low limits: ${miss[*]}"$'\n'"A file read after $LIMITS_FILE sets a lower value; it would win over a line added there."
    PLAN="-- Raise these lines to at least the minimum (or remove them):"$'\n'"$(sed '/^$/d; s/^/-- /' <<< "$over")"
    [[ ${#LIM_TODO[@]} -gt 0 ]] && PLAN+=$'\n'"-- and add these lines to $LIMITS_FILE:"$'\n'"$(for it in "${LIM_TODO[@]}"; do lim_line ${it}; done)"
    PLAN+=$'\n'"-- Then answer r."
    KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
    return 1
  fi
  NOW="Missing or too low limits: ${miss[*]}
The preinstall package sets limits only for the user named oracle."
  [[ " ${miss[*]}" == *" oracle:"* ]] && NOW+=$'\n'"Its limits for oracle are missing or too low here as well (the package is not installed, or its file was changed)."
  [[ -n "$lmnote" ]] && NOW+=$'\n'"$lmnote"
  PLAN="Add these limits to $LIMITS_FILE (lines set by you stay as they are):
$(for it in "${LIM_TODO[@]}"; do lim_line ${it}; done)"
  [[ "$ORACLE_USER" != "oracle" ]] && ! id oracle >/dev/null 2>&1 && \
    PLAN+=$'\n'"The preinstall package may create a user named oracle (uid 54321). This standby does not use it."
  # the whole new file: the lines it has (limits of other users on a shared server stay), then the new block
  [[ -L "$LIMITS_FILE" ]] && { NOW+=$'\n'"$LIMITS_FILE is a symbolic link, so the script does not change it."; return 2; }
  local old="" add=""
  [[ -f "$LIMITS_FILE" ]] && { old=$(cat -- "$LIMITS_FILE") || { NOW="Cannot read $LIMITS_FILE"; return 2; }; }
  for it in "${LIM_TODO[@]}"; do add+=$(lim_line ${it})$'\n'; done
  P2_SNAP=""; p2_snap "$LIMITS_FILE"
  cp_add_file "$LIMITS_FILE" 644 "${old:+$old$'\n'}# added by dg_standby_setup.sh $RUN_ID"$'\n'"${add%$'\n'}"
  return 1
}
d_2_4() {
  p2_unchanged || return 1
  cp_run
}

# ---- 2.5 folders ----
root_holds() {
  # 0 when only root can change the entry $2 in folder $1: $1 belongs to root and is not writable by group or
  # others, or it is sticky and $2 is there already, owned by root and not a link (nobody else can rename it)
  local o m; IFS=' ' read -r o m <<< "$(stat -c '%U %a' -- "$1" 2>/dev/null)"
  [[ "$o" == root && "$m" =~ ^[0-7]+$ ]] || return 1
  (( (8#$m & 8#022) == 0 )) && return 0
  (( (8#$m & 8#1000) != 0 )) && [[ -d "$2" && ! -L "$2" && "$(stat -c '%U' -- "$2" 2>/dev/null)" == root ]]
}
make_dir() {
  # $1 path, $2 owner. Creates missing components owned by $2 (group INSTALL_GROUP, 775).
  # Changes the owner of an existing directory only when it is empty. Never recursive, never through a link.
  # Root acts only while no one else can change the folders on the way (root_holds, from / down). Below a
  # folder another user can change (for example the oracle base, or a group-writable /u01/app), the rest is made
  # as $2 itself: a link put in place there between two steps then leads nowhere $2 could not write anyway
  local path=$1 owner=$2 p="" par="/" comp held=1
  local -a parts=()
  # "." or ".." parts would make the system-folder test below meaningless (/u01/../etc)
  [[ "$path" == /* && ! "$path" =~ (^|/)\.\.?(/|$) && "$path" != *//* ]] || { bad "$path is not a plain absolute path. It is not created or changed."; return 1; }
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
    [[ $held -eq 1 ]] && ! root_holds "$par" "$p" && held=0
    if [[ ! -e "$p" && ! -L "$p" ]]; then
      if [[ $held -eq 1 ]]; then install -d -o "$owner" -g "$INSTALL_GROUP" -m 775 "$p" || return 1
      else
        runuser -u "$owner" -- mkdir -m 775 -- "$p" 2>/dev/null \
          || { bad "$p cannot be made by $owner (the folder above can be changed by users other than root, so root does not make it). Make it, as $owner:  mkdir -p $path"; return 1; }
        # the group: a folder with the wrong group is taken back at once (it is empty and new), so a later run
        # does not find it "there" and go on with it
        if ! runuser -u "$owner" -- chgrp -h "$INSTALL_GROUP" -- "$p" 2>/dev/null; then
          runuser -u "$owner" -- rmdir -- "$p" 2>/dev/null
          bad "$owner cannot give $p the group $INSTALL_GROUP ($owner is not a member of it). Step 2.2 adds the users to the groups."; return 1
        fi
      fi
      say "Created $p"; journal DIR "$p" "owner $owner"
    fi
    [[ -d "$p" ]] || { bad "$p exists, but it is not a folder. It is not changed."; return 1; }
    par=$p
  done
  [[ -L "$path" ]] && { warn "$path is a symbolic link. Its owner is not changed."; return 0; }
  if dir_empty "$path"; then
    # the mode is set as the new owner: a link swapped in after chown -h then points only where $owner may write
    if [[ $held -eq 1 ]]; then chown -h "$owner:$INSTALL_GROUP" "$path" && chmod 775 "$path"
    else chown -h "$owner:$INSTALL_GROUP" "$path" && runuser -u "$owner" -- chmod 775 -- "$path"; fi
  fi
}
# make_dir as a list (steps 2.5 and 2.14): the same rules, worked out in the check, so the exact commands are shown
# before [y]. The action works the list out again and runs it only when it is still the same.
#   P2_MDOUT  one line per command: "DIR|<folder>|<owner>|<command>" (makes a folder) or "CMD|||<command>"
#   P2_MADE   the folders the list makes so far ("<folder>=<owner>" lines); P2_MDWHY why a folder is refused
P2_MDOUT=""; P2_MADE=""; P2_MDWHY=""
p2_planned() { local l; while IFS= read -r l; do [[ -n "$l" && "${l%=*}" == "$1" ]] && { printf '%s' "${l##*=}"; return 0; }; done <<< "$P2_MADE"; return 1; }
p2_planned_child() { local l; while IFS= read -r l; do [[ -n "$l" && "${l%=*}" == "$1"/* ]] && return 0; done <<< "$P2_MADE"; return 1; }
make_dir_plan() {
  # $1 path, $2 owner: the commands make_dir would run, added to P2_MDOUT. 1 (P2_MDWHY) where make_dir refuses
  local path=$1 owner=$2 p="" par="/" comp held=1 grp=$INSTALL_GROUP po qp lo cmd
  local -a parts=()
  [[ "$path" == /* && ! "$path" =~ (^|/)\.\.?(/|$) && "$path" != *//* ]] || { P2_MDWHY="$path is not a plain absolute path. It is not created or changed."; return 1; }
  case "$path" in /etc/ORACLE|/etc/ORACLE/*) ;;
    /|/usr|/usr/*|/etc|/etc/*|/var|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/root|/tmp)
    P2_MDWHY="$path is a system folder. It is not created or changed."; return 1 ;; esac
  IFS='/' read -ra parts <<< "${path#/}"
  for comp in "${parts[@]}"; do
    [[ -n "$comp" ]] || continue
    p+="/$comp"; qp=$(p2q "$p")
    # made by an earlier command of this list: a folder of its owner (not held by root)
    if p2_planned "$p" >/dev/null; then held=0; par=$p; continue; fi
    if [[ -L "$p" ]]; then
      lo=$(stat -c '%U' "$p")
      [[ "$lo" == "root" ]] || { P2_MDWHY="$p is a symbolic link owned by $lo. It is not used."; return 1; }
    fi
    [[ $held -eq 1 ]] && ! root_holds "$par" "$p" && held=0
    if [[ ! -e "$p" && ! -L "$p" ]]; then
      if [[ $held -eq 1 ]]; then cmd="install -d -o $owner -g $grp -m 775 $qp"
      else
        # below a folder another user can change: made as $owner, with the group $grp as its process group (runuser
        # -g, root only): the folder gets that group at once, no chgrp and no clean-up guard are needed
        cmd="runuser -u $owner -g $grp -- mkdir -m 775 -- $qp"
      fi
      P2_MDOUT+="DIR|$p|$owner|$cmd"$'\n'; P2_MADE+="$p=$owner"$'\n'
    elif [[ ! -d "$p" ]]; then P2_MDWHY="$p exists, but it is not a folder. It is not changed."; return 1; fi
    par=$p
  done
  [[ -L "$path" ]] && return 0      # (its owner is not changed)
  # an empty folder gets the owner, the group and the mode (a folder this list makes has them already)
  qp=$(p2q "$path")
  if po=$(p2_planned "$path"); then
    # made by this list: empty unless the list makes something in it
    [[ "$po" != "$owner" ]] && ! p2_planned_child "$path" || return 0
  else
    dir_empty "$path" && ! p2_planned_child "$path" || return 0
    [[ "$(stat -c '%U:%G:%a' -- "$path" 2>/dev/null)" == "$owner:$grp:775" ]] && return 0
  fi
  if [[ $held -eq 1 ]]; then cmd="chown -h $owner:$grp $qp && chmod 775 $qp"
  else cmd="chown -h $owner:$grp $qp && runuser -u $owner -- chmod 775 -- $qp"; fi
  P2_MDOUT+="CMD|||$cmd"$'\n'
  return 0
}
dir_plan_all() {
  # stdin: "folder:owner" lines -> P2_MDOUT for all of them, in order. 1 with P2_MDWHY
  local d own
  P2_MDOUT=""; P2_MADE=""; P2_MDWHY=""
  while IFS=: read -r d own; do [[ -n "$d" ]] || continue; make_dir_plan "$d" "$own" || return 1; done
  return 0
}
p2_dirs_add() {
  # P2_MDOUT into the shown list
  local k d o c
  P2_META=()
  while IFS='|' read -r k d o c; do
    [[ -n "$k" ]] || continue
    if [[ "$k" == DIR ]]; then p2_add "DIR|$d|$o" root "$c"; else p2_add "" root "$c"; fi
  done <<< "$P2_MDOUT"
}
p2_dirs_run() {
  # $1 the list shown before [y]; stdin the "folder:owner" lines: worked out again now, run only when the same
  local shown=$1 i m d o
  dir_plan_all || { bad "$P2_MDWHY"; return 1; }
  [[ "$P2_MDOUT" == "$shown" ]] || { bad "The folders were changed after the check. Nothing was done. Answer r to check again."; return 1; }
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    p2_exec "$i" || return 1
    m=${P2_META[$i]:-}
    if [[ "$m" == DIR\|* ]]; then IFS='|' read -r _ d o <<< "$m"; say "Created $d"; journal DIR "$d" "owner $o"; fi
  done
  return 0
}
dir_specs() {
  if use_grid; then printf '%s\n' "$GRID_BASE:$GRID_USER" "$GRID_HOME:$GRID_USER"; fi
  printf '%s\n' "$INVENTORY_DIR:$GRID_USER" "$ORACLE_BASE:$ORACLE_USER" "$DB_HOME:$ORACLE_USER"
}
existing_parent() { local p=$1; while [[ ! -e "$p" && "$p" != "/" ]]; do p=$(dirname "$p"); done; printf '%s' "$p"; }
mnt_of() { timeout 30 df --output=target -- "$(existing_parent "$1")" 2>/dev/null | tail -n 1; }
free_mb_of() { local f; f=$(timeout 30 df -m --output=avail -- "$(existing_parent "$1")" 2>/dev/null | tail -n 1 | tr -d ' '); num "$f" && printf '%s' "$f" || printf '0'; }
c_2_5() {
  users_ok || { NOW="The users do not exist yet (step 2.2)"; return 2; }
  local d own miss="" wrong="" fixw=""
  while IFS=: read -r d own; do
    if [[ ! -d "$d" ]]; then miss+="  $d  (owner $own)"$'\n'; continue; fi
    local cur; cur=$(stat -c '%U' "$d")
    # an installed Grid home belongs to root (root.sh); an EMPTY one must belong to the grid owner, who unpacks it
    if [[ "$cur" != "$own" && ! ( "$cur" == "root" && "$d" == "$GRID_HOME" && -e "$d/bin" ) ]]; then
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
  dir_plan_all < <(dir_specs) || { NOW+=$'\n'"$P2_MDWHY"; return 2; }
  PLAN="Create these folders, or set their owner (group $INSTALL_GROUP, mode 775):
${miss%$'\n'}
Folders that are not empty keep their owner."
  USING="Same paths as on the primary"
  P25_SHOWN=$P2_MDOUT; p2_dirs_add
  return 1
}
P25_SHOWN=""
d_2_5() { p2_dirs_run "$P25_SHOWN" < <(dir_specs); }

# ---- 2.6 /etc/hosts on standby ----
# The script fixes /etc/hosts itself (a backup is kept, --undo puts it back):
#   a name that does not resolve gets a line; a name on a 127.x line or on a wrong address is taken off
#   that line and gets its own correct line (lines of other names are never changed).
H_TODO=""; H_FIX=""
v4_of() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }
# The listener and the database need the host name to give an IPv4 address of the server from /etc/hosts or
# DNS. The systemd "myhostname" module answers too (often with an IPv6 link-local address such as fe80::...):
# that answer does not count (the Grid listener then stays INTERMEDIATE, "Not All Endpoints Registered").
v4_fd() {
  # IPv4 address of $1 from /etc/hosts, else from DNS (empty: neither knows it)
  local a; a=$(getent -s files ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}')
  [[ -n "$a" ]] || a=$(timeout 10 getent -s dns ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}')
  printf '%s' "$a"
}
name_res_local() {
  # $1 name -> "files|dns|first answer of getent ahosts" on this server
  printf '%s|%s|%s' "$(getent -s files ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}')" \
    "$(timeout 10 getent -s dns ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}')" "$(getent ahosts "$1" 2>/dev/null | awk '{print $1; exit}')"
}
name_res_parse() {
  # the output of the primary probe hostres -> "files|dns|first"
  local f d a
  f=$(sed -n 's/^F //p' <<< "$1" | awk '{print $1}'); d=$(sed -n 's/^D //p' <<< "$1" | awk '{print $1}'); a=$(sed -n 's/^A //p' <<< "$1" | awk '{print $1}')
  printf '%s|%s|%s' "$f" "$d" "$a"
}
local_ipv4s() {
  { ip -o addr show 2>/dev/null | awk '$3 == "inet" {split($4, x, "/"); print x[1]}'; hostname -I 2>/dev/null | tr ' ' '\n'; } \
    | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u | paste -sd' ' -
}
name_problem() {
  # $1 name, $2 "files|dns|first", $3 the IPv4 addresses of the server the name belongs to.
  # Prints the problem in one line, or nothing when the name gives one of those addresses.
  local n=$1 f d a ip; IFS='|' read -r f d a <<< "$2"
  ip=${f:-$d}
  if [[ -z "$ip" ]]; then
    if [[ "$a" == *:* ]]; then printf '%s gives only the IPv6 address %s, no IPv4 address in /etc/hosts or DNS' "$n" "$a"
    elif [[ -n "$a" ]]; then printf '%s is not in /etc/hosts or DNS (only %s from another source)' "$n" "$a"
    else printf '%s does not resolve' "$n"; fi
  elif [[ "$ip" == 127.* ]]; then printf '%s resolves to %s (loopback)' "$n" "$ip"
  elif [[ -n "$3" && " $3 " != *" $ip "* ]]; then printf '%s resolves to %s, which is not an address of that server' "$n" "$ip"
  fi
  return 0
}
standby_name_problems() {
  # the host name of this server (short, and the full name when there is one): one problem per line
  local h fq ips; ips=$(local_ipv4s); fq=$(host_fq)
  for h in "$STANDBY_HOST" ${fq:+"$fq"}; do
    local p; p=$(name_problem "$h" "$(name_res_local "$h")" "$ips")
    [[ -n "$p" ]] && printf '%s\n' "$p"
  done
  return 0
}
PNP_OUT=""
primary_name_problems() {
  # the host name of the primary, as the primary itself resolves it (read-only probes): the problems, one per line,
  # in PNP_OUT. 2 = it could not be asked. Called directly, never in $( ): PRIMARY_V4S must reach the caller
  PNP_OUT=""
  ssh_alive || return 2
  prim_probe ipv4s || return 2
  local ips h; ips=$(tr ' ' '\n' <<< "$RUN_OUT" | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u | paste -sd' ' -)
  PRIMARY_V4S=$ips
  for h in "$PRIMARY_HOST" ${PRIMARY_FQ:+"$PRIMARY_FQ"}; do
    prim_probe hostres "$h" || { PNP_OUT=""; return 2; }
    local p; p=$(name_problem "$h" "$(name_res_parse "$RUN_OUT")" "$ips")
    [[ -n "$p" ]] && PNP_OUT+="$p"$'\n'
  done
  PNP_OUT=${PNP_OUT%$'\n'}
  return 0
}
primary_hosts_line() {
  # the /etc/hosts line the primary needs for its own name: its address (the one used for ssh when it is one of
  # its addresses), full name, short name
  local ip=""
  [[ " ${PRIMARY_V4S:-} " == *" $(ipv4_of "$PRIMARY_IP") "* ]] && ip=$(ipv4_of "$PRIMARY_IP")
  [[ -n "$ip" ]] || ip=$(awk '{print $1}' <<< "${PRIMARY_V4S:-}")
  [[ -n "$ip" ]] || ip=$(ipv4_of "$PRIMARY_IP")
  printf '%s    %s%s' "$ip" "${PRIMARY_FQ:+$PRIMARY_FQ }" "$PRIMARY_HOST"
}
host_fq() {   # the full name of this server when it is <short name>.<domain>
  local fq; fq=$(hostname 2>/dev/null)
  [[ "$fq" == *.* && "${fq%%.*}" == "$STANDBY_HOST" ]] && printf '%s' "$fq"
}
c_2_6() {
  local todo="" fix="" h ip want why=""
  H_TODO=""; H_FIX=""
  for h in "$PRIMARY_HOST|$PRIMARY_IP" "$STANDBY_HOST|$STANDBY_IP"; do
    IFS='|' read -r h want <<< "$h"
    # (only /etc/hosts and DNS count: an answer of the "myhostname" module is no entry)
    ip=$(v4_fd "$h")
    local why6=""; [[ -z "$ip" && "$h" == "$STANDBY_HOST" ]] && why6=$(name_problem "$h" "$(name_res_local "$h")" "")
    local fq=""; [[ "$h" == "$STANDBY_HOST" ]] && fq=$(host_fq)
    if [[ -z "$ip" ]]; then
      [[ "$want" =~ ^[0-9.]+$ ]] || { NOW="$h does not resolve, and its IP address is not known${why6:+$'\n'$why6.}"; return 2; }
      [[ "$why6" == *IPv6* || "$why6" == *"another source"* ]] && why+="$why6."$'\n'"The listener needs an IPv4 address for it (else Not All Endpoints Registered)."$'\n'
      todo+="$want    ${fq:+$fq }$h"$'\n'
    elif [[ "$want" =~ ^[0-9.]+$ && "$ip" != "$want" ]]; then
      if [[ "$ip" == 127.* ]]; then why+="$h resolves to $ip (loopback). The primary could not reach this server's listener."$'\n'
      else why+="$h resolves to $ip here, but it is $want"$'\n'; fi
      fix+="$h|$want"$'\n'; todo+="$want    ${fq:+$fq }$h"$'\n'
    fi
  done
  if [[ -z "$todo" ]]; then NOW="Names resolve: $PRIMARY_HOST = $(v4_fd "$PRIMARY_HOST"), $STANDBY_HOST = $(v4_fd "$STANDBY_HOST")"; return 0; fi
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
  # the whole new file, shown and written as it is: in place (it keeps its owner, mode and SELinux label, and a
  # bind-mounted /etc/hosts of a container can be written too)
  local new
  new=$(hosts_new_text) || { NOW+=$'\n'"Cannot read /etc/hosts."; return 2; }
  # a file that had lines never becomes empty
  [[ ! -s /etc/hosts || -n "$new" ]] || { NOW+=$'\n'"The new /etc/hosts would be empty. Nothing is changed."; return 2; }
  P2_SNAP=""; p2_snap /etc/hosts
  cp_add root "cat > /etc/hosts" "$new"
  return 1
}
hosts_new_text() {
  # /etc/hosts as step 2.6 writes it: each name of H_FIX (and this server's full name) taken off every line whose
  # address is not the right one; then the lines of H_TODO that are not there yet
  local txt="" h want fq l
  # a missing /etc/hosts starts empty
  if [[ -e /etc/hosts ]]; then txt=$(cat -- /etc/hosts) || return 1; fi
  while IFS='|' read -r h want; do
    [[ -n "$h" ]] || continue
    fq=""; [[ "$h" == "$STANDBY_HOST" ]] && fq=$(host_fq)
    txt=$(awk -v n="$h" -v f="$fq" -v w="$want" '
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
      }' <<< "$txt") || return 1
  done <<< "$H_FIX"
  while IFS= read -r l; do
    [[ -n "$l" ]] && ! grep -qxF -- "$l" <<< "$txt" && txt+="${txt:+$'\n'}$l"
  done <<< "$H_TODO"
  printf '%s' "$txt"
}
d_2_6() {
  local existed=0; [[ -e /etc/hosts ]] && existed=1
  p2_unchanged || return 1
  [[ -L /etc/hosts ]] && { bad "/etc/hosts is a symbolic link. It is not changed."; return 1; }
  backup_file /etc/hosts || return 1
  if ! p2_exec 0; then
    # a failed write puts the backup back
    [[ -f "/etc/hosts.bak_$RUN_ID" ]] && cat -- "/etc/hosts.bak_$RUN_ID" > /etc/hosts
    bad "/etc/hosts could not be written. The old content was put back."; return 1
  fi
  journal_file_written /etc/hosts "$existed"
  say "Corrected /etc/hosts."
  return 0
}

# ---- 2.7 primary resolves standby ----
PRIMARY_FQ=""; PRIMARY_V4S=""
# One visit to the primary: when /etc/hosts of the primary needs a line, the command is not asked for here. It is
# shown in the combined primary block of phase 4 (PRIMARY_BATCH_EXTRA, the box "as root"), and phase 4 checks this
# step again right after that block (P27_RECHECK). Only in a normal run whose phase 4 comes later in this run, and
# not when the script runs the primary commands itself (PRIMARY_RUN=yes: one step at a time, as before).
P27_DEFERRED=0; P27_RECHECK=0
p27_defer_ok() {
  [[ "$MODE" == run && "${PRIMARY_RUN:-no}" != yes && $P27_RECHECK -eq 0 && ${PHASE4_FIRST:-0} -eq 0 && -z "${BATCH_TTY:-}" ]] || return 1
  [[ "${CUR_STEP:-}" == 2.7 ]] && step_in_range 4.1
}
c_2_7() {
  local rc=0; c_2_7_check || rc=$?
  if [[ $rc -eq 1 && -n "$PLAN" ]] && p27_defer_ok; then
    local -a keep=(); local e
    for e in ${PRIMARY_BATCH_EXTRA[@]+"${PRIMARY_BATCH_EXTRA[@]}"}; do [[ "$e" == 2.7\|* ]] || keep+=("$e"); done
    PRIMARY_BATCH_EXTRA=(${keep[@]+"${keep[@]}"} "2.7|root|$PLAN${PLAN_UNDO:+$'\n'-- Undo, if ever needed: $PLAN_UNDO}")
    # the commands count as shown: when the check passes later, the change is journaled as done by you
    primary_pending_add 2.7 "$PLAN_UNDO"
    P27_DEFERRED=1
    NOW+=$'\n'"The command for /etc/hosts of the primary (as root) is shown with the other primary commands in phase 4,"
    NOW+=$'\n'"so you go to the primary once. This step is checked again there."
    PLAN=""; PLAN_UNDO=""; CHECK_WAITS=1
    return 0
  fi
  [[ $rc -eq 1 ]] && not_done_yet
  return $rc
}
c_2_7_check() {
  need_ssh || return 2
  # first the primary's own name on the primary (its listener needs it, as here)
  local pp prc=0; primary_name_problems > /dev/null || prc=$?; pp=$PNP_OUT
  if [[ $prc -eq 0 && -n "$pp" ]]; then
    NOW="On the primary: ${pp//$'\n'/; }"
    PRIMARY_HOW_STEP="root  ->  shell"
    # run twice, the first backup stays and the line is not added again; a last line without its newline gets one
    PLAN="[ -e /etc/hosts.bak_$RUN_ID ] || cp -p /etc/hosts /etc/hosts.bak_$RUN_ID
[ -z \"\$(tail -c 1 /etc/hosts)\" ] || echo >> /etc/hosts
grep -qxF '$(primary_hosts_line)' /etc/hosts || echo '$(primary_hosts_line)' >> /etc/hosts
getent ahostsv4 $PRIMARY_HOST
-- The last command must show $(primary_hosts_line | awk '{print $1}'). Then answer r."
    PLAN_UNDO="cp -p /etc/hosts.bak_$RUN_ID /etc/hosts   (on the primary)"
    return 1
  fi
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
  # the ssh call itself failed (or timed out): not known, nothing is asked of the primary's /etc/hosts
  [[ $PROBE_REACHED -eq 1 && $PROBE_TIMED_OUT -ne 1 ]] || { NOW="The primary could not be asked how it resolves $STANDBY_HOST. Answer r to check again."; return 2; }
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

fw_path_note() {
  # the port is open on this server: can the primary reach it through the network? (read-only: a connect from
  # the primary, nothing is sent). Only a hint here: steps 4.9, 7.6 and 8.1 test the real connection.
  # $1 = what was found here: "firewalld" (the port is open in it) or "none" (firewalld is not active)
  # (also in check mode: a connect only, nothing is sent and nothing changes)
  [[ $FW_PATH_DONE -eq 1 ]] && return 0
  ssh_alive || return 0
  prim_probe tcpto "$STANDBY_IP" "$PORT" || return 0
  local here
  if [[ "${1:-}" == firewalld ]]; then here="Port $PORT is open in firewalld here, so something else blocks it:"
  else here="firewalld is not active here, so something else blocks it:"; fi
  case "$(head -n 1 <<< "$RUN_OUT")" in
    OPEN) NOW+=$'\n'"The primary reaches $STANDBY_IP:$PORT through the network." ;;
    REFUSED) NOW+=$'\n'"The primary gets an answer from $STANDBY_IP:$PORT (connection refused): nothing listens yet,"$'\n'"or a firewall rejects it. Steps 7.6 and 8.1 test the real connection once the listener runs." ;;
    TIMEOUT|BLOCKED) warn "The primary cannot reach $STANDBY_IP:$PORT (no answer, or the connection is rejected)."$'\n'"$here a firewall in the network, or rules on this server"$'\n'"outside firewalld (check:  nft list ruleset). Ask your network administrator to allow"$'\n'"port $PORT from $PRIMARY_IP to $STANDBY_IP." ;;
    NOROUTE) warn "The primary cannot reach $STANDBY_IP:$PORT: no route to host."$'\n'"Either $STANDBY_IP is not the right address of this server, or a firewall rejects the connection"$'\n'"with icmp-host-prohibited (the reject of firewalld). Check the address first." ;;
    UNREACH) warn "The primary cannot reach $STANDBY_IP:$PORT: the network is unreachable from the primary."$'\n'"The primary has no route to that network, or a firewall rejects it (icmp-net-prohibited)."$'\n'"Check the routes of the primary first (ip route get $STANDBY_IP, on the primary)." ;;
  esac
  return 0
}
local_fw_rules() {
  # firewalld is not active: rules of nftables or iptables on this server (read-only). They are not judged here
  # (sets, maps, jumps and scopes make a sure verdict impossible): the drop and reject rules are shown, so the
  # admin can see at once whether one of them stops port $PORT. The real test is the connect from the primary.
  local r="" nrules="" irules="" rules myif
  command -v nft >/dev/null 2>&1 && nrules=$(nft list ruleset 2>/dev/null | awk '/hook (output|forward)/ { o = 1 } o && /^[[:space:]]*}/ { o = 0; next } !o { print }')
  command -v iptables >/dev/null 2>&1 && irules=$(iptables -S 2>/dev/null | grep -vE '^-(P|A) (OUTPUT|FORWARD)')
  rules=$nrules$'\n'$irules
  # (not "ct state invalid ... drop": it only drops broken packets)
  local dre='policy drop|^-P INPUT DROP|(^|[[:space:]])(drop|reject)([[:space:]].*)?;?[[:space:]]*$|-j (DROP|REJECT)'
  local inv='ct state invalid|--ctstate INVALID|state INVALID'
  local pdre='(^|[[:space:]])(drop|reject)([[:space:]]|;|$)|-j (DROP|REJECT)'
  local drops pdrop v clean pnamed paccept first an dn lets=1
  drops=$(grep -vE "$inv" <<< "$rules" | grep -E "$dre" | sed 's/^[[:space:]]*//')
  [[ -n "$drops" ]] || return 0
  # an explicit accept of port $PORT is the normal default-deny set-up. Each view (nft, iptables) is judged on its
  # own: iptables-nft shows the same rules in both, and an order says something only inside one view.
  for v in "$nrules" "$irules"; do
    grep -vE "$inv" <<< "$v" | grep -qE "$dre" || continue
    # (counters and comments carry numbers too: taken out before the port is looked for)
    clean=$(sed -E 's/counter packets [0-9]+ bytes [0-9]+//g; s/comment "[^"]*"//g; s/--comment ("[^"]*"|[^ ]+)//g; s/^[[:space:]]*//' <<< "$v")
    pnamed=$(grep -E "(tcp dport|-p tcp .*--dports?)[^;]*[^0-9]$PORT([^0-9]|\$)" <<< "$clean")
    # (only an accept that is not limited to some sources or interfaces)
    paccept=$(grep -E '(^|[[:space:]])accept([[:space:]]|;|$)|-j ACCEPT' <<< "$pnamed" | grep -vE 'saddr|(^|[[:space:]])-s[[:space:]]|iifname|iif[[:space:]]|(^|[[:space:]])-i[[:space:]]|--src-range|ipset|match-set|@')
    [[ -n "$paccept" ]] || { lets=0; break; }
    first=$(head -n 1 <<< "$paccept")
    # no catch-all drop or reject before the accept
    awk -v a="$first" '$0 == a {exit} /^-A INPUT -j (DROP|REJECT)/ || /^(drop|reject)( with .*)?;?$/ {f = 1; exit} END {exit !f}' <<< "$clean" && { lets=0; break; }
    # a drop of port $PORT itself counts only before the accept (after it, the packet is already let in)
    an=$(grep -nxF -- "$first" <<< "$clean" | head -n 1 | cut -d: -f1)
    dn=$(grep -nxF -f <(grep -E "$pdre" <<< "$pnamed") <<< "$clean" | head -n 1 | cut -d: -f1)
    [[ -n "$dn" && -n "$an" && $dn -lt $an ]] && { lets=0; break; }
    # only one input chain of this view drops by policy (each base chain must accept the packet: with two, an
    # accept in one says nothing about the other)
    [[ $(grep -cE 'policy drop|^-P INPUT DROP' <<< "$clean") -le 1 ]] || { lets=0; break; }
  done
  [[ $lets -eq 1 ]] && return 0
  pdrop=$(sed -E 's/counter packets [0-9]+ bytes [0-9]+//g; s/comment "[^"]*"//g; s/--comment ("[^"]*"|[^ ]+)//g; s/^[[:space:]]*//' <<< "$rules" \
          | grep -E "(tcp dport|-p tcp .*--dports?)[^;]*[^0-9]$PORT([^0-9]|\$)" | grep -E "$pdre")
  # shown: every rule that drops port $PORT itself, then the first general ones
  r=$( { [[ -n "$pdrop" ]] && printf '%s\n' "$pdrop"; grep -vxF -f <(printf '%s\n' "${pdrop:-#none#}") <<< "$drops" | head -n 3; } | grep -v '^$' | awk '!seen[$0]++')
  [[ -n "$r" ]] || return 0
  myif=$(ip -o addr show 2>/dev/null | awk -v a="$STANDBY_IP" '{split($4, x, "/"); if (x[1] == a) {print $2; exit}}')
  NOW+=$'\n'"Note: this server has firewall rules outside firewalld that drop or reject traffic, for example:"$'\n'"$(sed 's/^/  /' <<< "$r")"
  NOW+=$'\n'"Check that they let port $PORT/tcp from $PRIMARY_IP in${myif:+ (on $myif, the interface of $STANDBY_IP)}:  nft list ruleset  (or:  iptables -S)"
  return 0
}
FW_PATH_DONE=0      # 1 only inside 4.9 (it runs the check of 2.9 quietly, without this probe)
# ---- 2.9 firewall here ----
FW_ZONE=""
c_2_9() {
  if ! systemctl is-active --quiet firewalld 2>/dev/null; then NOW="firewalld is not active"; local_fw_rules; fw_path_note none; return 0; fi
  local ifc; ifc=$(ip -o addr show 2>/dev/null | awk -v a="$STANDBY_IP" '{split($4, x, "/"); if (x[1] == a) {print $2; exit}}')
  FW_ZONE=""
  [[ -n "$ifc" ]] && { FW_ZONE=$(firewall-cmd --get-zone-of-interface="$ifc" 2>/dev/null) || FW_ZONE=""; }
  [[ -n "$FW_ZONE" ]] || FW_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
  [[ "$FW_ZONE" =~ ^[A-Za-z0-9_-]+$ ]] || FW_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
  [[ "$FW_ZONE" =~ ^[A-Za-z0-9_-]+$ ]] || FW_ZONE=public
  # the zone of the interface is the right one; a guess is said
  [[ -z "$ifc" ]] && warn "No interface here has the address $STANDBY_IP, so the firewall zone is a guess: $FW_ZONE."$'\n'"Check:  firewall-cmd --get-active-zones"
  # open now AND after a reboot: the running rules and the saved (permanent) ones are both checked
  local rt=0 pm=0
  firewall-cmd --zone="$FW_ZONE" --query-port="$PORT/tcp" >/dev/null 2>&1 && rt=1
  firewall-cmd --permanent --zone="$FW_ZONE" --query-port="$PORT/tcp" >/dev/null 2>&1 && pm=1
  if [[ $rt -eq 1 && $pm -eq 1 ]]; then NOW="Port $PORT/tcp is open (zone $FW_ZONE), also after a reboot"; fw_path_note firewalld; return 0; fi
  if [[ $rt -eq 1 ]]; then NOW="Port $PORT/tcp is open now, but not saved: it closes at the next reboot (zone $FW_ZONE)"
  elif [[ $pm -eq 1 ]]; then NOW="Port $PORT/tcp is saved as open, but the running firewall does not have it yet (zone $FW_ZONE)"
  else NOW="Port $PORT/tcp is closed in firewalld (zone $FW_ZONE${ifc:+, interface $ifc})"; fi
  # no --reload: it would also drop other rules that are only in the running firewall
  if [[ $pm -eq 1 ]]; then PLAN="Open port $PORT/tcp in the running firewall (zone $FW_ZONE)."
  elif [[ $rt -eq 1 ]]; then PLAN="Save port $PORT/tcp as open (zone $FW_ZONE), so it stays open after a reboot."
  else PLAN="Open port $PORT/tcp in firewalld (zone $FW_ZONE), now and after a reboot."; fi
  PLAN+=$'\n'"No reload: rules that are only in the running firewall stay."
  [[ $pm -eq 1 ]] || cp_add root "firewall-cmd --permanent --zone=$FW_ZONE --add-port=$PORT/tcp"
  [[ $rt -eq 1 ]] || cp_add root "firewall-cmd --zone=$FW_ZONE --add-port=$PORT/tcp"
  return 1
}
d_2_9() {
  # the journal names only the rules this step added (a rule that was there before, saved or running, is not
  # removed by the undo: it may belong to something else)
  local c i perm=0 run=0 obj=""
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    c=${CP_CMD[$i]}
    p2_exec "$i" || { [[ -n "$obj" ]] && journal FWPORT "$obj" "permanent=$perm runtime=$run"; return 1; }
    [[ "$c" =~ --zone=([A-Za-z0-9_-]+)\ --add-port=([0-9]+/tcp) ]] || continue
    obj="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    if [[ "$c" == *--permanent* ]]; then perm=1; else run=1; fi
  done
  [[ -n "$obj" ]] && journal FWPORT "$obj" "permanent=$perm runtime=$run"
  return 0
}

# ---- 2.10 time ----
CHRONY_WAITED=0
c_2_10() {
  # a running service is enough to go on; a clock that is not in sync (yet) is a warning: redo shipping and
  # apply work, but the times in the alert logs and lag reports of the two servers do not match
  if systemctl is-active --quiet chronyd 2>/dev/null; then
    if grep -q 'Leap status.*Normal' <<< "$(chronyc tracking 2>/dev/null)"; then NOW="chronyd is running and the clock is in sync"; return 0; fi
    # a chronyd that has just started needs a minute or two: looked at again a few times (not in check mode, and
    # once per run: a server that cannot reach a time source does not wait at every check)
    local n=0
    [[ $CHRONY_WAITED -eq 1 ]] && n=6; CHRONY_WAITED=1
    while [[ "$MODE" != check && $n -lt 6 ]]; do
      n=$((n + 1)); say "The clock is not in sync yet. Checked again in 20 seconds ($n of 6)"; nap 20
      grep -q 'Leap status.*Normal' <<< "$(chronyc tracking 2>/dev/null)" && { NOW="chronyd is running and the clock is in sync"; return 0; }
    done
    NOW="chronyd is running, but the clock is not in sync"
    warn "The clock of this server is not in sync. Check:  chronyc sources -v  (a time server must be reachable)"
    return 0
  fi
  if systemctl is-active --quiet ntpd 2>/dev/null; then
    if timedatectl status 2>/dev/null | grep -qiE 'synchronized: yes'; then NOW="ntpd is running and the clock is in sync"; return 0; fi
    local m=0
    [[ $CHRONY_WAITED -eq 1 ]] && m=6; CHRONY_WAITED=1
    while [[ "$MODE" != check && $m -lt 6 ]]; do
      m=$((m + 1)); say "The clock is not in sync yet. Checked again in 20 seconds ($m of 6)"; nap 20
      timedatectl status 2>/dev/null | grep -qiE 'synchronized: yes' && { NOW="ntpd is running and the clock is in sync"; return 0; }
    done
    NOW="ntpd is running, but the clock is not in sync"
    warn "The clock of this server is not in sync. Check:  ntpq -p  (a time server must be reachable)"
    return 0
  fi
  NOW="No time sync is running (neither chronyd nor ntpd)"
  PLAN="Start the time service chronyd, also at every boot."
  cp_add root "systemctl enable --now chronyd"
  return 1
}
d_2_10() { cp_run && journal SERVICE chronyd; }

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
  # added at the end, by the user itself (its own file in its own folder); a backup is kept
  local prof lead blk
  P2_META=(); P2_SNAP=""
  for entry in "${todo[@]}"; do
    IFS='|' read -r usr base home sid <<< "$entry"
    prof="$(home_of "$usr")/.bash_profile"
    [[ -L "$prof" ]] && { NOW+=$'\n'"$prof is a symbolic link. It is not changed."; return 2; }
    # a last line without its newline gets one first (else the first new line would be glued to it)
    lead=0; [[ -s "$prof" && -n "$(tail -c 1 -- "$prof" 2>/dev/null)" ]] && lead=1
    blk=$(profile_block "$usr" "$base" "$home" "$sid"); [[ $lead -eq 1 ]] && blk=$'\n'"$blk"
    p2_snap "$prof"
    p2_add "PROF|$usr|$lead|$prof" root "runuser -u $usr -- tee -a -- $(p2q "$prof") > /dev/null" "$blk"
  done
  return 1
}
d_2_11() {
  local i m usr lead prof before after
  p2_unchanged || return 1
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    m=${P2_META[$i]:-}; IFS='|' read -r _ usr lead prof <<< "$m"
    [[ -n "$prof" ]] || { p2_exec "$i" || return 1; continue; }
    [[ -L "$prof" ]] && { bad "$prof is a symbolic link. It is not changed."; return 1; }
    backup_file "$prof" "$usr" || return 1
    before=0; [[ -f "$prof" ]] && before=$(stat -c '%s' -- "$prof")
    p2_exec "$i" || { bad "Cannot write $prof"; return 1; }
    after=$(stat -c '%s' -- "$prof" 2>/dev/null); num "$after" || after=$before
    # journaled as an added block (--undo cuts exactly these bytes off again)
    journal_file_appended "$prof" "$before" "${CP_IN[$i]}"$'\n' "$((after - before))" "$lead"
  done
  return 0
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
asm_owner_group() {
  # the first of asmadmin, dba, the grid user's group that exists here, or that step 2.1 creates (it is in the
  # group list of the primary): --check, before 2.1, then plans the same group as the real run
  local g
  for g in asmadmin dba "$GRID_PGROUP"; do
    [[ -n "$g" ]] || continue
    if getent group "$g" >/dev/null 2>&1 || [[ ",${GROUP_GIDS:-}," == *",$g:"* ]]; then printf '%s' "$g"; return 0; fi
  done
  printf '%s' "$INSTALL_GROUP"
}
readonly UDEV_RULES=/etc/udev/rules.d/99-oracle-asmdevices.rules
A212_MODE=""
c_2_12() {
  use_grid || { NOW="Not needed (the primary does not use ASM)"; return 0; }
  local m; m=$(asm_method); A212_MODE=""
  if [[ "$m" == "udev" ]]; then
    # the rules are applied by systemd-udevd: without it /dev/oraasm stays empty
    if ! systemctl is-active --quiet systemd-udevd 2>/dev/null; then
      NOW="ASM disks use udev rules, but systemd-udevd is not running. The rules would not be applied."
      A212_MODE=udevd; PLAN="Start systemd-udevd, the udev service of the system."
      cp_add root "systemctl start systemd-udevd"
      return 1
    fi
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
  if [[ -n "$need" ]]; then
    PLAN="Make ASMLib ready for the ASM disks ($GRID_USER:$ag, loaded, started at boot), then use it."
    PLAN+=$'\n'"If a command fails (ASMLib does not work on this kernel), these run instead and udev rules are used:"
    PLAN+=$'\n'"  oracleasm configure -d"$'\n'"  systemctl disable oracleasm"
    local c; while IFS= read -r c; do [[ -n "$c" ]] && cp_add root "$c"; done <<< "$need"
  else PLAN="Use ASMLib for the ASM disks"; fi
  A212_MODE=asmlib
  return 1
}
d_2_12() {
  case "$A212_MODE" in
    to_udev|save) ASM_METHOD=udev; save_settings; return 0 ;;
    udevd)
      # the udev service of the system: started (nothing else changes); a part of every Linux system
      cp_run || { bad "systemd-udevd did not start. To see why:  systemctl status systemd-udevd"; return 1; }
      systemctl is-active --quiet systemd-udevd 2>/dev/null || { bad "systemd-udevd is still not running. To see why:  systemctl status systemd-udevd"; return 1; }
      return 0 ;;
  esac
  if cp_any; then
    journal ASMCFG oracleasm "$(printf '%s;' "${CP_CMD[@]}")"
    if ! cp_run; then
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
ASM_DEFERRED=" "    # disks not used in THIS run (Grid not installed yet, or wrong sector size): offered again in a later run
asm_foreign() { local l; while IFS= read -r l; do [[ -n "$l" ]] && ! asm_label_known "$l" && ! asm_label_declined "$l" && [[ "$ASM_DEFERRED" != *" $l "* ]] && printf '%s\n' "$l"; done < <(asm_labels_any "$1"); return 0; }
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
asm_dead_labels() {
  # the labels of disk group $1 that have no disk behind them now (a removed or failed disk): never used
  local l d
  while IFS= read -r l; do [[ -n "$l" ]] || continue; d=$(label_device "$l"); [[ -n "$d" && -n "$(lsblk -dn -o TYPE "$d" 2>/dev/null)" ]] || printf '%s ' "$l"; done < <(asm_labels "$1")
  return 0
}
asm_dead_plan() {
  # $1 the labels: NOW and PLAN for them (nothing is deleted by the script)
  NOW="These ASM disk labels have no disk behind them now:  $1"$'\n'"A disk group cannot be made or used with them."
  if [[ "$(asm_method)" == "asmlib" ]]; then
    PLAN="oracleasm scandisks"$'\n'"oracleasm listdisks"$'\n'"-- For each label:  oracleasm querydisk -p <label>"
  else
    PLAN="udevadm trigger --subsystem-match=block"$'\n'"ls -l $(asm_disk_dir)/"
  fi
  PLAN+=$'\n'"-- If the disk was removed for good, add a new disk to this server and remove the label line from:"$'\n'"--   $(asm_disks_file)"$'\n'"-- Then answer r."
  MANUAL_HOW="root"; MANUAL_WHERE="To check on this server ($(hostname -s))"
}
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
  local dead=""
  for dg in $(asm_dgs); do dead+=$(asm_dead_labels "$dg"); done
  [[ -n "$dead" ]] && { asm_dead_plan "${dead% }"; return 2; }
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
  # new disks must fit the redo block size of the primary: it must be known, not assumed
  redo_bs_known || { NOW="The redo block size of the primary could not be read (step 1.3), so the right disks cannot be chosen. Run the script again, or set REDO_BLOCKSIZE (512 or 4096) in the settings (--settings)."; return 2; }
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
    PLAN+=$'\n'"The exact commands are shown once the disks are chosen. You type each disk name to confirm it."
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

asm_udev_rule() {
  # $1 partition UUID, $2 label: the udev rule of one ASM disk
  printf 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_UUID}=="%s", SYMLINK+="oraasm/%s", OWNER="%s", GROUP="%s", MODE="0660"' \
    "$1" "$2" "$GRID_USER" "$(asm_owner_group)"
}
asm_uuid_mark() { printf '<the partition UUID of %s>' "$1"; }   # in the shown rule: read once the partition exists
P213_RULESDIR=0
asm_disk_cmds() {
  # $1 label, $2 disk (validated): its commands into the shown list. P2_META tags what the action does around them:
  #   PART (checked free again, journaled first)  PROBE (waits for the partition)  RULE (the partition UUID is put in)
  #   CREATE (ASMLib)  FIN (the last one of the disk: the ASM disk is checked and recorded)
  local label=$1 disk=$2 part; part=$(part_name "$disk")
  p2_add "PART|$label|$disk" root "parted -s $disk mklabel gpt mkpart primary 1MiB 100%"
  p2_add "PROBE|$label|$part" root "partprobe $disk"
  if [[ "$(asm_method)" == "asmlib" ]]; then
    p2_add "CREATE|$label|$part" root "oracleasm createdisk $label $part"
    p2_add "FIN|$label|$part" root "oracleasm scandisks"
    return 0
  fi
  if [[ $P213_RULESDIR -eq 0 && ! -d "$(dirname "$UDEV_RULES")" ]]; then
    p2_add "" root "install -d -m 755 $(dirname "$UDEV_RULES")"
  fi
  P213_RULESDIR=1
  # a retry after a slow udev does not add the same rule twice (the action looks for the UUID first)
  p2_add "RULE|$label|$part" root "cat >> $UDEV_RULES" "$(asm_udev_rule "$(asm_uuid_mark "$part")" "$label")"
  p2_add "" root "chmod 644 $UDEV_RULES"
  p2_add "" root "udevadm control --reload-rules"
  p2_add "" root "udevadm trigger --action=change --sysname-match=${part#/dev/}"
  p2_add "FIN|$label|$part" root "udevadm settle"
}
asm_wipe_hint() {
  # $1 the partition (part_name of its disk)
  local d=${1%1}; [[ "$d" =~ [0-9]p$ ]] && d=${d%p}
  printf 'The disk now has an empty GPT partition, with no data on it.\nTo try again later, clear it first:\n  wipefs -a %s ; wipefs -a %s\n' "$1" "$d" | hint
}
asm_disks_run() {
  # runs the shown list of asm_disk_cmds, entry by entry
  local i m k lab x uuid lead before after n perm
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    m=${P2_META[$i]:-}; k=""; lab=""; x=""
    [[ -n "$m" ]] && IFS='|' read -r k lab x <<< "$m"
    case "$k" in
      PART)
        disk_is_free "$x" || { bad "$x can no longer be used: $DISK_WHY. Nothing was erased."; return 1; }
        journal PART "$x" "GPT with one partition for ASM disk $lab" ;;
      RULE)
        uuid=$(udev_uuid "$x")
        if ! [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
          bad "Cannot read the partition UUID of $x"; asm_wipe_hint "$x"; return 1
        fi
        # the rule as shown, with the UUID that was not known before the partition was made
        CP_IN[$i]=${CP_IN[$i]//"$(asm_uuid_mark "$x")"/$uuid}
        if grep -qsF -- "ENV{ID_PART_ENTRY_UUID}==\"$uuid\"" "$UDEV_RULES"; then
          say "The udev rule for $x (UUID $uuid) is in $UDEV_RULES already."; continue
        fi
        [[ -L "$UDEV_RULES" ]] && { bad "Not changed: $UDEV_RULES is a symbolic link."; return 1; }
        dir_root_only "$UDEV_RULES" || { bad "Not changed: $(dirname -- "$UDEV_RULES") must be a folder that only root can write to."; return 1; }
        backup_file "$UDEV_RULES" || return 1
        lead=0; [[ -s "$UDEV_RULES" && -n "$(tail -c 1 -- "$UDEV_RULES")" ]] && { lead=1; CP_IN[$i]=$'\n'"${CP_IN[$i]}"; }
        before=0; [[ -f "$UDEV_RULES" ]] && before=$(stat -c '%s' -- "$UDEV_RULES") ;;
    esac
    if ! p2_exec "$i"; then
      [[ "$(asm_method)" == "asmlib" && ( "$k" == CREATE || "$k" == FIN ) ]] && asm_wipe_hint "$x"
      return 1
    fi
    case "$k" in
      PROBE)
        command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null
        n=0
        until [[ "$(lsblk -dn -o TYPE "$x" 2>/dev/null)" == "part" ]]; do
          n=$((n + 1)); [[ $n -gt 10 ]] && { bad "Partition $x did not appear"; return 1; }; nap 1
        done ;;
      RULE)
        # journaled as an added block (the undo keeps the rule of a disk that a disk group still uses)
        after=$(stat -c '%s' -- "$UDEV_RULES" 2>/dev/null); num "$after" || after=$before
        journal_file_appended "$UDEV_RULES" "$before" "${CP_IN[$i]}"$'\n' "$((after - before))" "$lead" ;;
      FIN)
        if [[ "$(asm_method)" != "asmlib" ]]; then
          n=0; until [[ -e "/dev/oraasm/$lab" ]]; do n=$((n + 1)); [[ $n -gt 10 ]] && break; nap 1; done
          perm=$(stat -L -c '%U:%G:%a' "/dev/oraasm/$lab" 2>/dev/null)
          [[ "$perm" == "$GRID_USER:$(asm_owner_group):660" ]] || { bad "/dev/oraasm/$lab has owner and mode '$perm', but needs $GRID_USER:$(asm_owner_group):660"; return 1; }
        fi
        asm_label_exists "$lab" || { bad "ASM disk $lab was created, but it is not visible"; return 1; }
        record_label "$lab" "$x"
        journal ASMLABEL "$lab" "on $x"
        say "Created ASM disk $lab on $x" ;;
    esac
  done
  return 0
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

disk_sector_ok() {
  # $1 disk. Online logs with 4096-byte blocks need 4K physical sectors; 512-byte redo cannot go on a 4K-native disk
  # (else ORA-01378 for the standby logs). Sectors that cannot be read are a warning: step 8.1 checks the disk group.
  local d=$1 sb pbs lbs n; SECTOR_WHY=""
  # a partition (ASMLib disks, sdb1) has no queue of its own: the sizes are those of its disk
  n=$(basename "$(readlink -f "$d")"); sb="/sys/class/block/$n"
  [[ -e "$sb/partition" ]] && sb=$(dirname "$(readlink -f "$sb")")
  sb="$sb/queue"
  pbs=$(cat "$sb/physical_block_size" 2>/dev/null); lbs=$(cat "$sb/logical_block_size" 2>/dev/null)
  if ! num "$pbs" || ! num "$lbs"; then
    warn "The sector size of $d cannot be read here. Step 8.1 checks the sector size of the disk group before the copy."
    return 0
  fi
  if [[ "${PRIMARY_REDO_BS:-512}" == "4096" && $pbs -lt 4096 ]]; then
    SECTOR_WHY="The redo logs of the primary use 4096-byte blocks, but $d has $pbs-byte sectors."$'\n'"The standby logs could not be created (ORA-01378). Use disks with 4K sectors."; return 1
  fi
  if [[ "${PRIMARY_REDO_BS:-512}" != "4096" && $lbs -ge 4096 ]]; then
    SECTOR_WHY="$d is a 4K-native disk, but the redo logs of the primary use 512-byte blocks."$'\n'"The standby and online logs could not be created (ORA-01378). Use disks with 512-byte or 512e sectors."; return 1
  fi
  return 0
}
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
      if grid_sw_ok; then
        # ASM runs here and does not mount that disk group: remembered as "not used"
        warn "These existing ASM disks are not used:$refused"$'\n'"They may belong to another server, for example the primary."$'\n'"To be asked again later, remove their lines (label|-) from $(asm_disks_file)."
        install -d -m 700 "$STATE_DIR"; for i in $reflab; do printf '%s|-\n' "$i" >> "$(asm_disks_file)"; done; chmod 600 "$(asm_disks_file)"
      else
        # no Grid yet: nothing here can mount a disk group, so this is not a decision; asked again in a later run
        for i in $reflab; do ASM_DEFERRED+="$i "; done
        warn "These existing ASM disks are not used now:$refused"$'\n'"Grid is not installed yet, so it cannot be seen whether this server owns them."$'\n'"They may belong to another server, for example the primary. They are offered again in a later run, once Grid is installed."
      fi
    fi
    [[ -n "$ok_l" ]] || continue
    # existing disks get the same sector test as new ones
    local okl2=""
    for i in $ok_l; do
      if disk_sector_ok "$(label_device "$i")"; then okl2+=" $i"; else warn "ASM disk $i is not used: $SECTOR_WHY"; ASM_DEFERRED+="$i "; fi
    done
    ok_l=$okl2; [[ -n "$ok_l" ]] || continue
    say "Answer y only if no other database uses$ok_l."
    if confirm "Use the existing ASM disks$ok_l for +$dg"; then
      for i in $ok_l; do record_label "$i" "$(label_device "$i")"; done
    else
      for i in $ok_l; do install -d -m 700 "$STATE_DIR"; printf '%s|-\n' "$i" >> "$(asm_disks_file)"; done; chmod 600 "$(asm_disks_file)"
      say "Not used:$ok_l. This answer is remembered (to change it, remove the lines label|- from $(asm_disks_file))."
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
    # only one empty disk is left and it is big enough: there is nothing to choose (its erasure is still asked)
    local nfree=0; for i in "${!disks[@]}"; do [[ "$used" == *" ${disks[$i]%% *} "* ]] || nfree=$((nfree + 1)); done
    local auto1=0; [[ $nfree -eq 1 && ${disks[$((def - 1))]##* } -ge $need_more ]] && auto1=1
    [[ $auto1 -eq 1 ]] && say "Only one empty disk is left, and it is big enough: ${disks[$((def - 1))]%% *} is used for +$dg."
    while true; do
      if [[ $auto1 -eq 1 ]]; then ANSWER=$def; auto1=0
      else ask_default "Disk numbers for +$dg, separated by spaces (q = stop, nothing is erased)" "$def"; fi
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
    disk_sector_ok "$d" || { bad "$SECTOR_WHY"$'\n'"Nothing was erased."; return 1; }
  done
  # the exact commands for all chosen disks, before anything is asked or erased
  cp_reset; P2_META=(); P213_RULESDIR=0
  for p in "${sel[@]}"; do asm_disk_cmds "${p%%|*}" "${p#*|}"; done
  cp_show
  for p in "${sel[@]}"; do
    d=${p#*|}
    confirm_word "ALL data on $d ($(lsblk -dn -o SIZE "$d" | tr -d ' ')) will be erased to make ASM disk ${p%%|*}." "$d" \
      || { say "Not confirmed. Nothing was erased."; return 3; }
  done
  asm_disks_run
}

# ---- 2.14 database folders (file system storage) ----
fs_need_lines() {
  # "dir|MB" for every file system location (database files; recovery area: what a standby needs)
  local d mb
  while IFS= read -r d; do
    mb=$(loc_mb "$d")
    [[ "$d" == "$(fra_dest)" ]] && mb=$((mb + $(fra_need_mb)))     # where it goes HERE (not the primary's place)
    printf '%s|%s\n' "$d" "$mb"
  done < <(fs_dirs)
}
earlier_copy_mb() {
  # $1 folder -> MB of the files in it that a copy of the primary would write. Uses FS_FILENAMES (read by the
  # caller, not here: this runs in a $( ) and its cache would be lost). Only this standby's own OMF folders count.
  local d=$1 f b=0 sz u
  if [[ -n "$FS_FILENAMES" ]]; then
    while IFS= read -r f; do
      [[ "$f" == "$d"/* && "$f" != */o1_mf_* && -f "$f" && ! -L "$f" ]] || continue   # (OMF names: counted below)
      sz=$(stat -c %s -- "$f" 2>/dev/null); num "$sz" && b=$((b + sz))
    done <<< "$FS_FILENAMES"
  fi
  for u in "${STANDBY_UNIQUE^^}" "${STANDBY_UNIQUE,,}"; do
    [[ -n "$STANDBY_UNIQUE" && -d "$d/$u" && ! -L "$d/$u" ]] || continue
    sz=$(find "$d/$u" -xdev -type f -name 'o1_mf_*' \( -path '*/datafile/*' -o -path '*/onlinelog/*' -o -path '*/controlfile/*' -o -path '*/tempfile/*' \) -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
    num "$sz" && b=$((b + sz))
    [[ "${STANDBY_UNIQUE^^}" == "${STANDBY_UNIQUE,,}" ]] && break
  done
  printf '%s' "$((b / 1048576))"
}
FS_TODO=()
c_2_14() {
  [[ -n "$(fs_dirs)" ]] || { NOW="Not needed (all database files are in ASM)"; return 0; }
  users_ok || { NOW="The users do not exist yet (step 2.2)"; return 2; }
  local d mb mnt free used missing=() short="" report="" notmine=""
  declare -A need_by_mnt=() free_by_mnt=()
  sql_or_cached_filenames >/dev/null 2>&1 || FS_FILENAMES=""     # once, here (not in the $( ) below)
  while IFS='|' read -r d mb; do
    mnt=$(mnt_of "$d"); [[ -n "$mnt" ]] || { NOW="Cannot read the free space of $d (df failed)"; return 2; }
    free=$(free_mb_of "$d")
    # files of an earlier copy already use their space: only those count (the primary's file names, or OMF
    # names o1_mf_*); other files in the folder stay and need their own space
    used=0; [[ -d "$d" ]] && used=$(earlier_copy_mb "$d"); num "$used" || used=0
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
  dir_plan_all < <(fs_todo_specs) || { NOW+=$'\n'"$P2_MDWHY"; return 2; }
  PLAN="Create these folders (owner $ORACLE_USER:$INSTALL_GROUP, mode 775):"
  for d in "${missing[@]}"; do PLAN+=$'\n'"  $d"; done
  P214_SHOWN=$P2_MDOUT; p2_dirs_add
  return 1
}
P214_SHOWN=""
fs_todo_specs() { local d; for d in "${FS_TODO[@]+"${FS_TODO[@]}"}"; do printf '%s:%s\n' "$d" "$ORACLE_USER"; done; }
d_2_14() { p2_dirs_run "$P214_SHOWN" < <(fs_todo_specs); }

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
    fst=$(timeout 30 df --output=fstype -- "$d" 2>/dev/null | tail -n 1 | tr -d ' ')
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
      # (a new name at every call: a file an earlier call could not remove must not be in the way)
      m="$d/.dg_standby_test_$(hostname -s)_${RUN_ID}_$$_$RANDOM"
      CLEANUP_FILES+=("$m")
      # (made with noclobber, also by root: a name that is already there, for example a link put there by a member of
      # the Oracle groups, is never written through)
      runuser -u "$ORACLE_USER" -- sh -c 'umask 077; set -C; : > "$1"' sh "$m" 2>/dev/null || { [[ ! -e "$m" && ! -L "$m" ]] && ( umask 077; set -C; : > "$m" ) 2>/dev/null; } \
        || { [[ -z "$info2" ]] && info2="Cannot write a test file in $d"; np=1; continue; }
      ans=""; prim_probe exists "$m" && ans=$(head -n 1 <<< "$RUN_OUT")
      if [[ "$ans" == "NO" && $net -eq 1 && "$STORAGE_NET_DONE" != *" $d|$lsrc "* ]]; then
        # a network file system client may cache folder contents for up to a minute: ask again after that (once per run)
        say "$d is $fst. Testing again in 65 seconds, as the primary may cache the folder contents ..."
        nap 65
        ans=""; prim_probe exists "$m" && ans=$(head -n 1 <<< "$RUN_OUT")
        [[ "$ans" == "NO" ]] && STORAGE_NET_DONE+="$d|$lsrc "
      fi
      runuser -u "$ORACLE_USER" -- rm -f -- "$m" 2>/dev/null; rm -f -- "$m"     # as its maker first (root may not remove it on NFS)
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
  copy_finished 2>/dev/null && { NOW="The RMAN copy already ran. The storage was checked before it started."; return 0; }
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
MEM_SGA=0 MEM_PGA=0 MEM_MT=0 MEM_ULP="" MEM_RFS=0 MEM_RAM_MB=0 MEM_FAIL="" MEM_WARN="" MEM_INFO="" MEM_SHM_MB=0 MEM_HP_LOW=0 MEM_SHM_NEED=0
# the size (MB) of a tmpfs size= value: bytes, k, m, g, t, or % of the RAM; empty when it cannot be read
shm_size_mb() {
  local v=${1,,}
  case "$v" in
    *%) v=${v%\%}; num "$v" && [[ $MEM_RAM_MB -gt 0 ]] && printf '%s' $(( MEM_RAM_MB * v / 100 )) ;;
    *k) v=${v%k}; num "$v" && printf '%s' $(( v / 1024 )) ;;
    *m) v=${v%m}; num "$v" && printf '%s' "$v" ;;
    *g) v=${v%g}; num "$v" && printf '%s' $(( v * 1024 )) ;;
    *t) v=${v%t}; num "$v" && printf '%s' $(( v * 1048576 )) ;;
    *)  num "$v" && printf '%s' $(( v / 1048576 )) ;;
  esac
  return 0
}
SHM_BOOT_FROM="" SHM_BOOT_MB="" SHM_BOOT_RO=0 SHM_BOOT_OPTS="" SHM_UNIT_WIN=""
shm_dropin() {
  # a drop-in outside /etc that wins is masked by one of the same name in /etc; else a name that sorts last
  if [[ $SHM_BOOT_RO -eq 1 && "$SHM_UNIT_WIN" == *.conf ]]; then printf '%s.d/%s' "$SHM_UNIT_FILE" "$(basename "$SHM_UNIT_WIN")"
  else printf '%s.d/zz-dg-standby-shm.conf' "$SHM_UNIT_FILE"; fi
}
shm_opt_mb() {
  # $1 mount options -> the size they give in MB (no size= = the tmpfs default, half the RAM; empty = unreadable)
  local sz=""
  [[ ",$1," =~ ,size=([^,]+), ]] && sz=${BASH_REMATCH[1]}
  if [[ -n "$sz" ]]; then shm_size_mb "$sz"
  elif [[ $MEM_RAM_MB -gt 0 ]]; then printf '%s' $(( MEM_RAM_MB / 2 )); fi
  return 0
}
shm_boot_calc() {
  # SHM_BOOT_MB: the size of /dev/shm after the next boot (empty when it cannot be read); SHM_BOOT_FROM: the file
  # that gives it. /dev/shm is mounted by systemd itself early at boot; the fstab line is applied to it then. A
  # mount unit for it (SHM_UNIT_WIN, the file whose Options line wins) may count too, so the SMALLER of the two
  # sizes is taken: the check never relies on the bigger one.
  local fo uo="" f fmb umb
  fo=$(awk '!/^[[:space:]]*#/ && $2 == "/dev/shm" { o = $4 } END { print o }' "$FSTAB_FILE" 2>/dev/null)
  SHM_UNIT_WIN=""; SHM_BOOT_RO=0
  # the files in /etc: the unit, then its drop-ins (read last, in name order)
  if [[ -f "$SHM_UNIT_FILE" ]]; then SHM_UNIT_WIN=$SHM_UNIT_FILE; uo=$(sed -n 's/^[[:space:]]*Options[[:space:]]*=[[:space:]]*//p' "$SHM_UNIT_FILE" | tail -n 1); fi
  for f in "$SHM_UNIT_FILE.d"/*.conf; do
    [[ -f "$f" ]] && grep -qE '^[[:space:]]*Options[[:space:]]*=' "$f" || continue
    SHM_UNIT_WIN=$f; uo=$(sed -n 's/^[[:space:]]*Options[[:space:]]*=[[:space:]]*//p' "$f" | tail -n 1)
  done
  # with systemd running, what it uses: "systemctl cat" also shows units and drop-ins in /run and /usr/lib (the
  # last Options line wins; a "# /path" line names each file). The unit made from fstab (/run/systemd/generator)
  # is the fstab line itself, read from fstab (the generated copy is old until a daemon-reload). A file outside
  # /etc is never changed: an /etc drop-in sets the size over it (SHM_BOOT_RO).
  if [[ -d "$SYSTEMD_RUN_DIR" ]] && command -v systemctl >/dev/null 2>&1; then
    local cat_out w=""
    if cat_out=$(systemctl cat dev-shm.mount 2>/dev/null) && [[ -n "$cat_out" ]]; then
      w=$(awk '/^# \/[^ ]+\.(mount|conf)$/ { f = substr($0, 3) } /^[[:space:]]*Options[[:space:]]*=/ { v = $0; sub(/^[[:space:]]*Options[[:space:]]*=[[:space:]]*/, "", v); wf = f; wo = v; n = 1 } END { if (n) print wf "\t" wo }' <<< "$cat_out")
      if [[ -n "$w" ]]; then
        f=${w%%$'\t'*}
        if [[ "$f" == /run/systemd/generator* ]]; then SHM_UNIT_WIN=""; uo=""
        else SHM_UNIT_WIN=$f; uo=${w#*$'\t'}; [[ "$f" == /etc/* || "$f" == "$SHM_UNIT_FILE"* ]] || SHM_BOOT_RO=1; fi
      fi
    fi
  fi
  SHM_BOOT_OPTS=$uo
  fmb=$(shm_opt_mb "$fo")
  SHM_BOOT_FROM=$FSTAB_FILE; SHM_BOOT_MB=$fmb
  [[ -n "$SHM_UNIT_WIN" ]] || return 0
  umb=$(shm_opt_mb "$uo")
  if ! num "$umb"; then SHM_BOOT_FROM=$SHM_UNIT_WIN; SHM_BOOT_MB=""
  elif num "$fmb" && [[ $umb -le $fmb ]]; then SHM_BOOT_FROM=$SHM_UNIT_WIN; SHM_BOOT_MB=$umb; fi
  return 0
}
mem_probe() {
  # 0 fits (MEM_WARN may hold a warning), 1 does not fit (MEM_FAIL), 2 the primary cannot be read
  MEM_SGA=0 MEM_PGA=0 MEM_MT=0 MEM_ULP="" MEM_RFS=0 MEM_RAM_MB=0 MEM_FAIL="" MEM_WARN="" MEM_INFO="" MEM_SHM_MB=0 MEM_HP_LOW=0 MEM_SHM_NEED=0
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
  # the SGA as the instance really has it: with a manual SGA (sga_target and memory_target 0) the parameters say
  # nothing, the sizes of its parts (shared_pool_size, db_cache_size, ...) add up to "Maximum SGA Size"
  local smax=""
  prim_sql "select to_char(bytes) from v\$sgainfo where name='Maximum SGA Size';" && smax=$(first_line)
  if num "$smax"; then [[ $smax -gt $MEM_SGA ]] && MEM_SGA=$smax
  elif [[ $MEM_SGA -eq 0 && $MEM_MT -eq 0 ]]; then return 2; fi
  local kb; kb=$(awk '/^MemTotal:/{print $2}' "$MEMINFO_FILE" 2>/dev/null)
  # the RAM of this server must be known: without it, "enough RAM" would be a guess
  num "$kb" && [[ $kb -gt 0 ]] || { SQL_OUT="MemTotal could not be read from $MEMINFO_FILE"; return 2; }
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
    MEM_SHM_NEED=$(( shm_need + 1024 ))
    if [[ $shm -lt $MEM_SHM_NEED ]]; then
      MEM_FAIL="/dev/shm is too small: $(human_mb "$shm"). The database needs $(human_mb "$MEM_SHM_NEED") there"
      MEM_FAIL+=$'\n'"(memory_target or memory_max_target of the primary, plus room for ASM). Otherwise: ORA-00845."
      MEM_SHM_MB=$(( shm_need + 2048 ))
      return 1
    fi
    # big enough now; the size it gets at the next boot must be big enough too
    shm_boot_calc; local boot=$SHM_BOOT_MB
    # a size that cannot be read (for example size=1.5G, which tmpfs does not take) counts as too small
    if ! num "$boot"; then
      MEM_FAIL="/dev/shm is big enough now ($(human_mb "$shm")), but the size it gets after a reboot cannot be read ($SHM_BOOT_FROM)."
      MEM_FAIL+=$'\n'"The database needs $(human_mb "$MEM_SHM_NEED") there. Otherwise: ORA-00845 after the next reboot."
      MEM_SHM_MB=$(( shm_need + 2048 )); [[ $shm -gt $MEM_SHM_MB ]] && MEM_SHM_MB=$shm
      return 1
    elif [[ $boot -lt $MEM_SHM_NEED ]]; then
      MEM_FAIL="/dev/shm is big enough now ($(human_mb "$shm")), but after a reboot it gets only $(human_mb "$boot") ($SHM_BOOT_FROM)."
      MEM_FAIL+=$'\n'"The database needs $(human_mb "$MEM_SHM_NEED") there. Otherwise: ORA-00845 after the next reboot."
      MEM_SHM_MB=$(( shm_need + 2048 )); [[ $shm -gt $MEM_SHM_MB ]] && MEM_SHM_MB=$shm
      return 1
    fi
  fi
  if [[ "$MEM_ULP" == "ONLY" || "$MEM_ULP" == "AUTO_ONLY" ]]; then
    local hp hpkb; hp=$(awk '/^HugePages_Total:/{print $2}' "$MEMINFO_FILE" 2>/dev/null); num "$hp" || hp=0
    hpkb=$(awk '/^Hugepagesize:/{print $2}' "$MEMINFO_FILE" 2>/dev/null); num "$hpkb" || hpkb=0
    if [[ $(( hp * hpkb / 1024 )) -lt $sga_mb ]]; then
      MEM_HP_LOW=1
      MEM_INFO+=$'\n'"HugePages: the primary requires them (use_large_pages=$MEM_ULP), this server has too few."
      MEM_INFO+=$'\n'"The standby gets use_large_pages=TRUE, so it starts without them. Add HugePages later."
    fi
  fi
  return 0
}

c_2_16() {
  copy_finished 2>/dev/null && { NOW="The RMAN copy already ran. The memory was checked before it started."; return 0; }
  need_ssh || return 2
  local rc=0; mem_probe || rc=$?
  if [[ $rc -eq 2 ]]; then
    if [[ "$SQL_OUT" == "MemTotal could not be read"* ]]; then NOW="The RAM of this server cannot be read ($SQL_OUT)"; return 2; fi
    local e; e=$(ora_errors "$SQL_OUT"); NOW="Cannot read the memory settings of the primary${e:+: $e}"; return 2
  fi
  if [[ $rc -eq 0 ]]; then
    NOW="Enough RAM:"$'\n'"$MEM_INFO"
    [[ -n "$MEM_WARN" ]] && NOW+=$'\n'"Warning: $MEM_WARN"
    return 0
  fi
  NOW="$MEM_FAIL"$'\n'"$MEM_INFO"
  if [[ $MEM_SHM_MB -gt 0 ]]; then
    # done by the script: /dev/shm is a memory file system of this server, nothing on it is lost by a larger size
    local cur; cur=$(df -m --output=size /dev/shm 2>/dev/null | tail -n 1 | tr -d ' '); num "$cur" || cur=0
    PLAN=""
    [[ $cur -lt $MEM_SHM_MB ]] && PLAN="Make /dev/shm ${MEM_SHM_MB} MB now ($(human_mb "$MEM_SHM_NEED") needed, plus 1 GB more room):
  mount -o remount,size=${MEM_SHM_MB}m /dev/shm
"
    PLAN+="Keep ${MEM_SHM_MB} MB after a reboot: the /dev/shm line in $FSTAB_FILE gets size=${MEM_SHM_MB}m (a backup is kept)"
    shm_boot_calc
    if [[ $SHM_BOOT_RO -eq 0 && -n "$SHM_UNIT_WIN" && -L "$SHM_UNIT_WIN" ]]; then
      KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
      PLAN="-- $SHM_UNIT_WIN sets /dev/shm at boot, but it is a link: the script does not write through it."$'\n'"-- Set size=${MEM_SHM_MB}m in its Options line (in the file it points to), and in $FSTAB_FILE, then:"$'\n'"systemctl daemon-reload"
      [[ $cur -lt $MEM_SHM_MB ]] && PLAN+=$'\n'"mount -o remount,size=${MEM_SHM_MB}m /dev/shm"
      PLAN+=$'\n'"-- Then answer r."
      return 1
    fi
    if [[ $SHM_BOOT_RO -eq 1 && -L "$(shm_dropin)" ]]; then
      KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
      PLAN="-- $SHM_UNIT_WIN sets /dev/shm at boot. The drop-in that would set the size over it is a link:"$'\n'"--   $(shm_dropin)"$'\n'"-- Remove the link (rm $(shm_dropin)), then answer r: the script writes the drop-in then."
      return 1
    fi
    if [[ $SHM_BOOT_RO -eq 0 && -n "$SHM_UNIT_WIN" ]] && ! grep -qE '^[[:space:]]*Options[[:space:]]*=' "$SHM_UNIT_WIN"; then
      KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
      PLAN="-- $SHM_UNIT_WIN sets /dev/shm at boot, but has no Options line to set the size in."$'\n'"-- Add size=${MEM_SHM_MB}m to its mount options (Options=...,size=${MEM_SHM_MB}m), and to the /dev/shm line in $FSTAB_FILE, then:"$'\n'"systemctl daemon-reload"
      [[ $cur -lt $MEM_SHM_MB ]] && PLAN+=$'\n'"mount -o remount,size=${MEM_SHM_MB}m /dev/shm"
      PLAN+=$'\n'"-- Then answer r."
      return 1
    fi
    if [[ $SHM_BOOT_RO -eq 1 ]]; then PLAN+=$'\n'"$SHM_UNIT_WIN sets /dev/shm at boot. It is not changed; this drop-in sets size=${MEM_SHM_MB}m and wins over it:"$'\n'"  $(shm_dropin)"
    elif [[ -n "$SHM_UNIT_WIN" ]]; then PLAN+=$'\n'"$SHM_UNIT_WIN sets /dev/shm at boot: its Options line gets size=${MEM_SHM_MB}m too (a backup is kept)"; fi
    PLAN+=$'\n'"Then the size for the next boot is read again from these files."
    shm_cmds "$cur" || { NOW+=$'\n'"Cannot read $FSTAB_FILE${SHM_UNIT_WIN:+ or $SHM_UNIT_WIN}."; return 2; }
  else
    KIND_NOW=manual
    MANUAL_HOW="root"; MANUAL_WHERE="To do for this server ($(hostname -s))"
    PLAN="-- Add RAM to the standby, then restart it and answer r.
-- A standby that may become the primary needs as much memory as the primary.
-- The RMAN copy (step 8.2) is refused until this is fixed."
  fi
  return 1
}

shm_cmds() {
  # $1 the size of /dev/shm now (MB): the commands and the whole new files of step 2.16 into the shown list
  local cur=$1 uf=$SHM_UNIT_WIN reload=0 txt
  P2_META=(); P2_SNAP=""
  if [[ $cur -lt $MEM_SHM_MB ]]; then
    local old="-"; [[ $cur -gt 0 ]] && old="${cur}m"
    p2_add "SHM|$old" root "mount -o remount,size=${MEM_SHM_MB}m /dev/shm"
  fi
  # a systemd mount unit for /dev/shm (or a drop-in of it) wins over fstab at boot: the size is set in the file
  # that wins, too
  if [[ $SHM_BOOT_RO -eq 1 ]]; then
    # the winning file is outside /etc (a package or /run owns it): a drop-in in /etc sets the size over it
    local dn dopts="" x ol=(); dn=$(shm_dropin)
    IFS=',' read -ra ol <<< "$SHM_BOOT_OPTS"
    for x in "${ol[@]+"${ol[@]}"}"; do [[ -z "$x" || "$x" == size=* ]] || dopts+="${dopts:+,}$x"; done
    p2_snap "$dn"
    cp_add_file "$dn" 644 "# Written by dg_standby_setup.sh: the size of /dev/shm for the Oracle SGA (wins over $SHM_UNIT_WIN)"$'\n'"[Mount]"$'\n'"Options=${dopts:+$dopts,}size=${MEM_SHM_MB}m"
    reload=1; uf=""
  fi
  if [[ -n "$uf" ]]; then
    txt=$(awk -v sz="size=${MEM_SHM_MB}m" '
      /^[[:space:]]*Options[[:space:]]*=/ { v = $0; sub(/^[[:space:]]*Options[[:space:]]*=[[:space:]]*/, "", v)
        n = split(v, o, ","); opts = ""
        for (i = 1; i <= n; i++) if (o[i] !~ /^size=/ && o[i] != "") opts = opts (opts ? "," : "") o[i]
        print "Options=" (opts ? opts "," : "") sz; next }
      { print }' "$uf") || return 1
    p2_snap "$uf"
    cp_add_file "$uf" 644 "$txt"
    reload=1
  fi
  # a new fstab line keeps the protections /dev/shm has now (nosuid, nodev, noexec): "defaults" would drop them
  local keep="" o; for o in $(findmnt -n -o OPTIONS /dev/shm 2>/dev/null | tr ',' ' '); do
    case "$o" in nosuid|nodev|noexec) keep+=",$o" ;; esac; done
  # /etc/fstab: the size option of the /dev/shm line is set (other options stay), or such a line is added
  txt=$(awk -v sz="size=${MEM_SHM_MB}m" -v keep="$keep" '
    !/^[[:space:]]*#/ && $2 == "/dev/shm" && NF >= 4 {
      n = split($4, o, ","); opts = ""
      for (i = 1; i <= n; i++) if (o[i] !~ /^size=/) opts = opts (opts ? "," : "") o[i]
      $4 = (opts ? opts "," : "") sz; done = 1 }
    { print }
    END { if (!done) print "tmpfs   /dev/shm   tmpfs   defaults" keep "," sz "   0 0" }' "$FSTAB_FILE") || return 1
  [[ -n "$txt" ]] || return 1
  p2_snap "$FSTAB_FILE"
  cp_add_file "$FSTAB_FILE" 644 "$txt"
  # systemd makes its unit from fstab (and reads the unit files) only at a daemon-reload, or the next boot
  [[ -d "$SYSTEMD_RUN_DIR" ]] && reload=1
  [[ $reload -eq 1 ]] && cp_add root "systemctl daemon-reload || true"
  return 0
}
d_2_16() {
  [[ $MEM_SHM_MB -gt 0 ]] || return 1
  local i m
  p2_unchanged || return 1
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    p2_exec "$i" || return 1
    m=${P2_META[$i]:-}
    [[ "$m" == SHM\|* ]] && journal SHM /dev/shm "old=${m#SHM|} new=${MEM_SHM_MB}m"
  done
  # what the next boot gets is read again from the files just written
  shm_boot_calc; local boot=$SHM_BOOT_MB
  if ! num "$boot" || [[ $boot -lt $MEM_SHM_NEED ]]; then
    bad "After a reboot /dev/shm would get ${boot:-an unknown size} MB ($SHM_BOOT_FROM), not ${MEM_SHM_MB} MB."
    printf 'Check the /dev/shm line in %s%s by hand.
' "$FSTAB_FILE" "$([[ -n "$SHM_UNIT_WIN" ]] && printf ' and the Options line in %s' "$SHM_UNIT_WIN")" | hint
    return 1
  fi
  say "/dev/shm is $(human_mb "$MEM_SHM_MB") now, and $(human_mb "$boot") after a reboot ($SHM_BOOT_FROM)."
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
  run_step 2.16 auto    "Memory (RAM) for the database" c_2_16 d_2_16
  build_envs_if_possible
}
