#------------------------------------------------------------------------------
# PHASE 5  Network files on this server
#------------------------------------------------------------------------------
lsnr_file() { printf '%s/network/admin/listener.ora' "$(lsnr_home)"; }
tns_file()  { printf '%s/network/admin/tnsnames.ora' "$DB_HOME"; }

#---- the commands of phases 5 and 6 ("Will run": what is shown is what runs) -----------------
# The check functions build the list with nf_add (cp_add plus a tag); the do functions run it with nf_run.
# The tag says what is done after an entry ran (journal, backup record, md5 check of a copy) or how its
# failure counts. Files of oracle / grid are written by that user (owner, group and mode stay as they are).
declare -a NF_TAG=()
NF_SUMS=""            # md5|file of the files whose new content was worked out in the check
nf_reset() { NF_TAG=(); NF_SUMS=""; }
nf_add() { NF_TAG[${#CP_CMD[@]}]=$1; shift; cp_add "$@"; }      # $1 tag (may be empty), then as cp_add
nf_q() {
  # one word of a shell command line: as it is when plain, else in single quotes
  if [[ "$1" =~ ^[A-Za-z0-9_./,:+=@%-]+$ ]]; then printf '%s' "$1"; else printf "'%s'" "${1//\'/\'\\\'\'}"; fi
}
nf_lsnr_role() { if use_grid; then printf 'grid'; else printf 'oracle'; fi; }
nf_role_user() { case "$1" in grid) printf '%s' "$GRID_USER" ;; oracle) printf '%s' "$ORACLE_USER" ;; *) printf 'root' ;; esac; }
nf_sum() { if [[ -e "$1" || -L "$1" ]]; then md5sum -- "$1" 2>/dev/null | cut -d' ' -f1; else printf 'none'; fi; }
nf_sum_add() { NF_SUMS+="$(nf_sum "$1")|$1"$'\n'; }
nf_sums_ok() {
  # the files are as they were when the new content was worked out (else nothing is written)
  local s f
  while IFS='|' read -r s f; do
    [[ -n "$f" ]] || continue
    [[ "$(nf_sum "$f")" == "$s" ]] || { bad "$f was changed after the check. Nothing was changed. Answer r to check it again."; return 1; }
  done <<< "$NF_SUMS"
  return 0
}
nf_bak_add() {
  # $1 role, $2 file: "keep a backup" (once per run; as backup_file: as the owner, never readable by everyone)
  local f=$2 b="$2.bak_$RUN_ID"
  [[ -f "$f" && ! -L "$f" ]] || return 0
  [[ ( -e "$b" || -L "$b" ) && -n "${BACKUPS_MADE[$b]:-}" ]] && return 0      # made earlier in this run
  nf_add "bak:$f" "$1" "cp -p -- $(nf_q "$f") $(nf_q "$b") && chmod o-rwx -- $(nf_q "$b")"
}
nf_baks_ok() {
  # before anything is changed: a backup name that exists but was not made by this run is never overwritten
  local i t b
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    t=${NF_TAG[$i]:-}; [[ "$t" == bak:* ]] || continue
    b="${t#bak:}.bak_$RUN_ID"
    [[ -e "$b" || -L "$b" ]] && { bad "$b exists already, but this run did not make it. Nothing is changed in ${t#bak:}."; return 1; }
  done
  return 0
}
nf_write_cmd() {
  # $1 file, $2 mode, $3 user that writes it: the whole new content (on the input) through a temporary file in the
  # same folder and a rename (a crash never leaves half a file); the group of the old file is kept
  local f=$1 d g gc=""; d=$(dirname -- "$f")
  if [[ -e "$f" ]]; then
    g=$(stat -c '%G' -- "$f" 2>/dev/null)
    [[ -n "$g" ]] && id -nG "$3" 2>/dev/null | tr ' ' '\n' | grep -qxF -- "$g" && gc=" && chgrp $(nf_q "$g") \"\$t\""
  fi
  # (in braces: the text given on the input is for the whole command)
  printf '{ t=$(mktemp %s/.dgtmp.XXXXXX) && cat > "$t" && chmod %s "$t"%s && mv -fT -- "$t" %s || { rm -f -- "$t"; exit 1; }; }' \
    "$(nf_q "$d")" "$2" "$gc" "$(nf_q "$f")"
}
nf_app_add() {
  # $1 role, $2 file, $3 text: added at the end (a missing final newline of the file is added first, as append_as)
  local lead=0 nl=""
  [[ -s "$2" && -n "$(tail -c 1 -- "$2")" ]] && { lead=1; nl=$'\n'; }
  nf_add "app:$2|$lead" "$1" "cat >> $(nf_q "$2")" "$nl$3"
}
nf_inst_cmd() {
  # $1 user, $2 group, $3 mode, $4 private copy of root, $5 target: written by the user itself (temporary file and
  # rename in the target folder, as install_as: root never writes, chmods or chowns a path in that user's folder)
  # (runuser -g: the new file gets the group at once, no chgrp)
  printf "runuser -u %s -g %s -- sh -c 'umask 077; t=\$(mktemp %s/.dgtmp.XXXXXX) && cat > \"\$t\" && chmod %s \"\$t\" && mv -fT -- \"\$t\" %s || { rm -f -- \"\$t\"; exit 1; }' < %s" \
    "$1" "$2" "$(dirname -- "$5")" "$3" "$5" "$(nf_q "$4")"
}
nf_scp_to() { if [[ ${OS_MAJOR:-0} -ge 9 ]]; then printf '1200'; else printf '600'; fi; }
nf_scp_cmd() {
  # $1 file on the primary, $2 private copy here: the scp of prim_scp (over the open ssh connection, read-only
  # on the primary). On OL9 scp uses SFTP; a primary without the sftp subsystem needs the old protocol (-O).
  local o s
  o="-o ControlMaster=no -o ControlPath=$(nf_q "$SSH_CTL") -o BatchMode=yes -o StrictHostKeyChecking=yes -o CheckHostIP=no -o $(nf_q "UserKnownHostsFile=$ROOT_KH $KH_FILE")"
  s=$(nf_q "$PRIMARY_SSH_USER@$PRIMARY_IP:$1")
  # (umask 077: the copy is made with mode 600; nf_fetch_add removes an old copy first, as an entry of its own)
  printf 'umask 077; scp -q %s %s %s' "$o" "$s" "$(nf_q "$2")"
  [[ ${OS_MAJOR:-0} -ge 9 ]] && printf ' || scp -O -q %s %s %s' "$o" "$s" "$(nf_q "$2")"
  return 0
}
nf_fetch_add() {
  # $1 file on the primary, $2 private copy here: two shown entries, the clean-up of an old copy and the scp
  # (the scp line is then only the copy itself; its md5 is checked after it, tag fetch)
  nf_add "" root "rm -f -- $(nf_q "$2")"
  nf_add "fetch:$1|$2" root "$(nf_scp_cmd "$1" "$2")" "" "$(nf_scp_to)"
}
nf_fetch_ok() {
  # $1 file on the primary, $2 the copy here: 0 only when the copy is byte-identical (md5)
  local src=$1 tmp=$2 rmd lmd
  [[ -s "$tmp" && -f "$tmp" && ! -L "$tmp" ]] || { bad "The copy of $src is empty"; return 1; }
  prim_probe md5 "$src" || { bad "Cannot get the md5sum of $src on the primary. The copy is not used."; return 1; }
  rmd=$(awk '{print $1; exit}' <<< "$RUN_OUT"); lmd=$(md5sum "$tmp" | awk '{print $1}')
  [[ "$rmd" =~ ^[0-9a-f]{32}$ && "$rmd" == "$lmd" ]] || { bad "The copy differs from $src on the primary (md5 here $lmd, there $rmd)"; return 1; }
  say "Checksum (md5) is the same as the file on the primary."
}
nf_mkdir_add() {
  # $1 folder, $2 role of its owner: the commands of make_dir for it (made with the same rules; NF_ERR when
  # make_dir would refuse). Nothing when the folder is there and not empty.
  local path=$1 role=$2 owner p="" par="/" comp held=1 lo
  local -a parts=()
  owner=$(nf_role_user "$role"); NF_ERR=""
  [[ "$path" == /* && ! "$path" =~ (^|/)\.\.?(/|$) && "$path" != *//* ]] || { NF_ERR="$path is not a plain absolute path. It is not created or changed."; return 1; }
  case "$path" in /etc/ORACLE|/etc/ORACLE/*) ;;
    /|/usr|/usr/*|/etc|/etc/*|/var|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/root|/tmp)
    NF_ERR="$path is a system folder. It is not created or changed."; return 1 ;; esac
  IFS='/' read -ra parts <<< "${path#/}"
  local made=0
  for comp in "${parts[@]}"; do
    [[ -n "$comp" ]] || continue
    p+="/$comp"
    if [[ -L "$p" ]]; then
      lo=$(stat -c '%U' "$p")
      [[ "$lo" == "root" ]] || { NF_ERR="$p is a symbolic link owned by $lo. It is not used."; return 1; }
    fi
    # (a folder made by this list belongs to the owner: root does not hold the ones below it, as in make_dir)
    [[ $held -eq 1 ]] && ! root_holds "$par" "$p" && held=0
    if [[ $made -eq 1 || ( ! -e "$p" && ! -L "$p" ) ]]; then
      made=1
      if [[ $held -eq 1 ]]; then nf_add "dir:$p|$owner" root "install -d -o $owner -g $INSTALL_GROUP -m 775 $(nf_q "$p")"
      elif [[ "$(id -gn "$owner" 2>/dev/null)" == "$INSTALL_GROUP" && ! -g "$par" ]]; then
        # made as $owner, whose own group is $INSTALL_GROUP (the folder above is not setgid): it has the group at once
        nf_add "dir:$p|$owner" "$role" "mkdir -m 775 -- $(nf_q "$p")"
      else
        nf_add "" "$role" "mkdir -m 775 -- $(nf_q "$p")"
        # a folder with the wrong group is taken back at once (it is empty and new)
        nf_add "dirgrp:$p|$owner" "$role" "chgrp -h $INSTALL_GROUP -- $(nf_q "$p") || { rmdir -- $(nf_q "$p"); exit 1; }"
      fi
    else
      [[ -d "$p" ]] || { NF_ERR="$p exists, but it is not a folder. It is not changed."; return 1; }
    fi
    par=$p
  done
  [[ -L "$path" ]] && return 0
  if [[ $made -eq 1 ]] || dir_empty "$path"; then
    nf_add "" root "chown -h $owner:$INSTALL_GROUP $(nf_q "$path")"
    if [[ $held -eq 1 ]]; then nf_add "" root "chmod 775 $(nf_q "$path")"
    else nf_add "" "$role" "chmod 775 -- $(nf_q "$path")"; fi
  fi
  return 0
}
NF_ERR=""
nf_exec() {
  # entry $1 of the list, then what its tag says. 0 = go on
  local i=$1 t=${NF_TAG[$1]:-} f="" rc=0 before=0 existed=0 lead after
  case "$t" in
    write:*|inst:*)
      f=${t#*:}
      [[ -L "$f" ]] && { bad "Not changed: $f is a symbolic link."; return 1; }
      [[ -d "$f" ]] && { bad "Not changed: $f is a folder, not a file."; return 1; }
      [[ -e "$f" ]] && existed=1 ;;
    app:*)
      f=${t#app:}; f=${f%|*}
      [[ -L "$f" ]] && { bad "Not changed: $f is a symbolic link."; return 1; }
      [[ -f "$f" ]] && before=$(stat -c '%s' -- "$f") ;;
  esac
  cp_exec "$i" || rc=$?
  if [[ $rc -ne 0 ]]; then
    case "$t" in
      chmodq|rmtmp|sso1:*|gp_stop) return 0 ;;          # as before: these never stopped the step
      fetch:*)
        f=${t#fetch:}; f=${f%|*}
        bad "scp failed: $(tail -n 2 <<< "$RUN_OUT")"
        [[ $rc -eq 124 ]] && say "No answer from the primary within ${CP_TO[$i]} s."
        printf 'The ssh user %s must be able to read %s on the primary.\n' "$PRIMARY_SSH_USER" "$f" | hint
        return 1 ;;
      dirgrp:*)
        f=${t#dirgrp:}
        bad "${f#*|} cannot give ${f%|*} the group $INSTALL_GROUP (${f#*|} is not a member of it). Step 2.2 adds the users to the groups."; return 1 ;;
      *)
        bad "This command failed:  $(head -n 1 <<< "${CP_CMD[$i]}" | mask_pw)"$'\n'"$(tail -n 4 <<< "$RUN_OUT" | mask_pw)"; return 1 ;;
    esac
  fi
  case "$t" in
    bak:*)   BACKUPS_MADE["${t#bak:}.bak_$RUN_ID"]=1 ;;
    write:*) journal_file_written "$f" "$existed" ;;
    inst:*)  say "Installed $f"; journal_file_written "$f" "$existed" ;;
    app:*)
      lead=${t##*|}; after=$(stat -c '%s' -- "$f" 2>/dev/null)
      journal_file_appended "$f" "$before" "${CP_IN[$i]}"$'\n' "$((after - before))" "$lead" ;;
    fetch:*) f=${t#fetch:}; nf_fetch_ok "${f%|*}" "${f#*|}" || return 1 ;;
    dir:*|dirgrp:*) f=${t#*:}; say "Created ${f%|*}"; journal DIR "${f%|*}" "owner ${f#*|}" ;;
    sso1:*)  journal RENAME "${t#sso1:}/cwallet.sso" "to=${t#sso1:}/cwallet.sso.old_$RUN_ID"
             say "The old auto-login file of ${t#sso1:} is kept as cwallet.sso.old_$RUN_ID. It is made again." ;;
    sso2:*)  journal RENAME "${t#sso2:}/cwallet.sso" "to=${t#sso2:}/cwallet.sso.old_$RUN_ID"
             say "The auto-login file of ${t#sso2:} that is not usable here is kept as cwallet.sso.old_$RUN_ID. It is made again." ;;
    lsnrstart) journal LSNRSTART "$SB_LSNR" "started from $(lsnr_home)" ;;
    gp_modify) journal LSNRPORT "$SB_LSNR" "old=${L310_CUR:-unknown} new=$PORT" ;;
  esac
  return 0
}
nf_run() {
  # the entries $1 (default 0) up to before $2 (default: all), in order; the first that fails stops
  local i from=${1:-0} to=${2:-${#CP_CMD[@]}}
  for ((i = from; i < to; i++)); do
    nf_exec "$i" || { [[ $((i + 1)) -lt $to ]] && say "The commands after it were not run."; return 1; }
  done
  return 0
}

net_dir_note() {
  # $1 a network file: its folder may be a link to a TNS_ADMIN shared with other homes or servers. Said in the
  # plan, and asked also with --yes
  local d r; d=$(dirname "$1"); [[ -L "$d" ]] || return 0
  r=$(readlink -e -- "$d" 2>/dev/null) || return 0
  PLAN+=$'\n'"-- Note: $d is a link to $r. That folder may be shared with other homes or servers."
  YES_HOLD=1
  return 0
}
static_entry_state() {
  # 0 = correct, 1 = missing, 2 = present but not right (ORACLE_HOME, GLOBAL_DBNAME, ENVS)
  local f; f=$(lsnr_file)
  [[ -f "$f" ]] || return 1
  local flat seg found=1 sidn homen
  STATIC_WHY=""
  flat=$(norm "$(sed 's/#.*//' "$f")")
  sidn="(SID_NAME=${STANDBY_SID^^})"; homen="(ORACLE_HOME=${DB_HOME^^})"
  while IFS= read -r seg || [[ -n "$seg" ]]; do
    if [[ "$seg" == *"$sidn"* ]]; then
      # the home and the service name (GLOBAL_DBNAME) the copy connects to must both be right
      local hok=0 gok=0
      [[ "$seg" == *"$homen"* || "$seg" == *"(ORACLE_HOME=${DB_HOME^^}/)"* ]] && hok=1
      [[ "$seg" == *"(GLOBAL_DBNAME=${STANDBY_SERVICE^^})"* ]] && gok=1
      # a listener of the Grid home: the entry must also give the server processes the TNS_ADMIN of the database
      # home (sid_envs_line)
      local eok=1
      [[ -n "$(sid_envs_line)" && "$seg" != *"(ENVS="*"TNS_ADMIN=${DB_HOME^^}/NETWORK/ADMIN"* ]] && eok=0
      [[ $hok -eq 1 && $gok -eq 1 && $eok -eq 1 ]] && return 0
      STATIC_WHY=""
      [[ $hok -eq 1 ]] || STATIC_WHY+="ORACLE_HOME is not $DB_HOME"$'\n'
      [[ $gok -eq 1 ]] || STATIC_WHY+="GLOBAL_DBNAME is missing or not $STANDBY_SERVICE"$'\n'
      [[ $eok -eq 1 ]] || STATIC_WHY+="ENVS with TNS_ADMIN=$DB_HOME/network/admin is missing (the listener runs from the Grid home; the copy needs it to find the primary)"$'\n'
      found=2
    fi
  done < <(sidlist_of "$flat" | sed 's/(SID_DESC=/\n(SID_DESC=/g')
  return $found
}
sidlist_of() {
  # $1 listener.ora flattened by norm -> only the (...) that belongs to SID_LIST_<this listener>
  # (an entry under another listener's SID_LIST is not served by this one)
  # the LAST block counts: listener.ora with two blocks of one name uses the last one
  awk -v key="SID_LIST_${SB_LSNR^^}=" '{
    t = $0; i = 0; while ((j = index(t, key)) > 0) { i += j; t = substr(t, j + 1) }; if (!i) exit
    s = substr($0, i + length(key)); d = 0; out = ""
    for (j = 1; j <= length(s); j++) { c = substr(s, j, 1); out = out c; if (c == "(") d++; else if (c == ")") { d--; if (d == 0) break } }
    print out }' <<< "$1"
}
lsnr_has_sidlist() { local f; f=$(lsnr_file); [[ -f "$f" ]] && grep -qiE "^[[:space:]]*SID_LIST_${SB_LSNR}[[:space:]]*=" "$f"; }
sid_envs_line() {
  # A listener of the Grid home runs with TNS_ADMIN of the Grid home, and the server processes it starts inherit
  # that. During the copy those processes connect to the primary by its alias (RMAN "from service"), which is
  # only in the tnsnames.ora of the database home: without this line the copy ends with ORA-17629 / ORA-12154.
  # (A listener of the database home is started by this script with the right TNS_ADMIN.)
  [[ "$(lsnr_home)" != "$DB_HOME" ]] && printf '      (ENVS = "TNS_ADMIN=%s/network/admin")\n' "$DB_HOME"
  return 0
}
static_block() {
  local e; e=$(sid_envs_line); [[ -n "$e" ]] && e+=$'\n'
  printf 'SID_LIST_%s =\n  (SID_LIST =\n    (SID_DESC =\n      (GLOBAL_DBNAME = %s)\n      (SID_NAME = %s)\n      (ORACLE_HOME = %s)\n%s    )\n  )\n' \
    "$SB_LSNR" "$STANDBY_SERVICE" "$STANDBY_SID" "$DB_HOME" "$e"
}

sid_desc_block() {
  local e; e=$(sid_envs_line); [[ -n "$e" ]] && e+=$'\n'
  printf '    (SID_DESC =\n      (GLOBAL_DBNAME = %s)\n      (SID_NAME = %s)\n      (ORACLE_HOME = %s)\n%s    )\n' "$STANDBY_SERVICE" "$STANDBY_SID" "$DB_HOME" "$e"
}
sidlist_insert() {
  # $1 listener.ora -> the file with the SID_DESC of this standby put just before the closing parenthesis of
  # (SID_LIST = ...) in SID_LIST_<listener>. 1 when there is not exactly one such block, or it does not close.
  local n; n=$(grep -ciE "^[[:space:]]*SID_LIST_${SB_LSNR}[[:space:]]*=" "$1")
  [[ "$n" == 1 ]] || return 1
  # only the usual form SID_LIST_<listener> = (SID_LIST = (SID_DESC = ...) ...): the entry goes into (SID_LIST
  [[ "$(sidlist_of "$(norm "$(sed 's/#.*//' "$1")")")" == "(SID_LIST="* ]] || return 1
  awk -v key="SID_LIST_${SB_LSNR^^}" -v desc="$(sid_desc_block)" '
    function cl(s) { t = s; sub(/#.*/, "", t); return t }
    !inb && !done && toupper($0) ~ ("^[[:space:]]*" key "[[:space:]]*=") { inb = 1; d = 0; opened = 0 }
    inb {
      line = $0; code = cl(line); out = ""
      for (j = 1; j <= length(code); j++) {
        c = substr(code, j, 1)
        if (c == "(") { d++; opened = 1 }
        else if (c == ")") {
          if (d == 1) {   # this closes (SID_LIST = ...): the new entry goes in front of it
            # a line that starts in column 1 is a new parameter in listener.ora: the rest stays indented
            pre = substr(line, 1, j - 1)
            if (pre ~ /^[[:space:]]*$/) { print desc; print line }
            else { print pre; print desc; print "  " substr(line, j) }
            inb = 0; done = 1; next
          }
          d--
        }
      }
      print line; next
    }
    { print }
    END { if (!done) exit 1 }' "$1"
}
sidlist_replace() {
  # $1 listener.ora -> the file with the SID_DESC of this SID (the one that is not right) replaced by the right
  # one. 1 unless: exactly one SID_LIST_<listener> block in the usual form, exactly one SID_DESC of this SID in it,
  # and that SID_DESC on lines of its own (nothing else before its "(" or after its ")" on those lines).
  local n; n=$(grep -ciE "^[[:space:]]*SID_LIST_${SB_LSNR}[[:space:]]*=" "$1")
  [[ "$n" == 1 ]] || return 1
  [[ "$(sidlist_of "$(norm "$(sed 's/#.*//' "$1")")")" == "(SID_LIST="* ]] || return 1
  awk -v key="SID_LIST_${SB_LSNR^^}" -v sid="${STANDBY_SID^^}" -v svc="${STANDBY_SERVICE^^}" -v desc="$(sid_desc_block)" '
    function cl(s) { t = s; sub(/#.*/, "", t); return t }
    # an entry of this SID for another service (for example <db>_DGMGRL of the broker) is never replaced
    function flush(   x) { x = toupper(bufc); gsub(/[ \t\r\n]/, "", x)
      if (index(x, "(SID_NAME=" sid ")") && (!index(x, "(GLOBAL_DBNAME=") || index(x, "(GLOBAL_DBNAME=" svc ")"))) {
        if (!safe) bad = 1; hits++; printf "%s", com; print desc }
      else { if (index(x, "(SID_NAME=" sid ")")) others++; printf "%s", buf }
      buf = ""; bufc = ""; com = ""; ind = 0 }
    !inb && !done && toupper($0) ~ ("^[[:space:]]*" key "[[:space:]]*=") { inb = 1; d = 0 }
    inb {
      line = $0; code = cl(line); startl = 0; endl = 0
      for (j = 1; j <= length(code); j++) {
        c = substr(code, j, 1)
        if (c == "(") { d++; if (d == 2) { ind = 1; safe = (substr(code, 1, j - 1) ~ /^[[:space:]]*$/); startl = 1 } }
        else if (c == ")") { d--; if (d == 1 && ind) { if (substr(code, j + 1) !~ /^[[:space:]]*$/) safe = 0; endl = 1 }
                             if (d == 0) { inb = 0; done = 1 } }
      }
      if (ind || endl) { buf = buf line "\n"; bufc = bufc code "\n"; i = index(line, "#"); if (i) com = com "    " substr(line, i) "\n"; if (endl) flush(); next }
      print line; next
    }
    { print }
    # 3 = every entry of this SID serves another service (none to replace: one may be added next to them)
    END { if (!done || bad) exit 1; if (hits == 0 && others > 0) exit 3; if (hits != 1) exit 1 }' "$1"
}
lsnr_desc_block() {
  printf '%s =\n  (DESCRIPTION_LIST =\n    (DESCRIPTION =\n      (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))\n    )\n  )\n' \
    "$SB_LSNR" "$STANDBY_HOST" "$PORT"
}
lsnr_has_desc() { local f; f=$(lsnr_file); [[ -f "$f" ]] && grep -qiE "^[[:space:]]*${SB_LSNR}[[:space:]]*=" "$f"; }

# ---- 5.1 ----
L51_MODE=""
port_owner_pid() {
  # pid of a program that listens on TCP port $1 (empty when nobody does)
  # iproute 3.10 of OL7 < 7.5 prints users:(("tnslsnr",1234,8)); newer ones users:(("tnslsnr",pid=1234,fd=8))
  ss -ltnp "( sport = :$1 )" 2>/dev/null | grep -oE 'users:\(\("[^"]*",(pid=)?[0-9]+' | head -n 1 | grep -oE '[0-9]+$'
}
l51_list() {
  # the commands of 5.1 for L51_MODE, worked out from listener.ora as it is now (the do function writes only
  # while the file is still the same)
  local f u r new mode txt; f=$(lsnr_file); u=$(lsnr_user); r=$(nf_lsnr_role)
  txt="# Added by dg_standby_setup.sh $RUN_ID"
  nf_sum_add "$f"
  nf_bak_add "$r" "$f"
  case "$L51_MODE" in
    insert|insert_desc|replace|replace_desc)
      if [[ "$L51_MODE" == insert* ]]; then new=$(sidlist_insert "$f") || return 1; else new=$(sidlist_replace "$f") || return 1; fi
      [[ "$L51_MODE" == *_desc ]] && new+=$'\n'"$txt"$'\n'"$(lsnr_desc_block)"
      mode=$(stat -c '%a' -- "$f")
      nf_add "write:$f" "$r" "$(nf_write_cmd "$f" "$mode" "$u")" "$new" ;;
    both)   nf_app_add "$r" "$f" "$txt"$'\n'"$(lsnr_desc_block)"$'\n'"$(static_block)" ;;
    desc)   nf_app_add "$r" "$f" "$txt"$'\n'"$(lsnr_desc_block)" ;;
    *)      nf_app_add "$r" "$f" "$txt"$'\n'"$(static_block)" ;;
  esac
  return 0
}
c_5_1() {
  nf_reset
  lsnr_sw_ok || { NOW="The listener software is not installed yet (phase 3)"; return 2; }
  local st=0 f; f=$(lsnr_file)
  # on a server that already runs something else: port $PORT must be free or ours
  local opid oexe; opid=$(port_owner_pid "$PORT")
  if [[ -n "$opid" ]]; then
    oexe=$(readlink "/proc/$opid/exe" 2>/dev/null); oexe=${oexe% (deleted)}
    # both paths resolved (a home under a symbolic link is still our listener)
    if [[ "$(readlink -f -- "$oexe" 2>/dev/null || printf '%s' "$oexe")" != "$(readlink -f -- "$(lsnr_home)/bin/tnslsnr" 2>/dev/null || printf '%s' "$(lsnr_home)/bin/tnslsnr")" ]]; then
      NOW="Port $PORT on this server is used by another program: $oexe (pid $opid)"
      KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
      PLAN="-- The standby listener of $(lsnr_home) must use port $PORT.
-- The primary and the RMAN copy connect to it there.
-- Stop the other program or move it to another port, then answer r. To see what it is:
  ps -fp $opid
  ss -ltnp '( sport = :$PORT )'"
      return 1
    fi
  fi
  static_entry_state || st=$?
  if [[ $st -eq 0 ]] && { use_grid || lsnr_has_desc; }; then NOW="listener.ora has the static entry for $STANDBY_SID with the database home."; return 0; fi
  USING="SID $STANDBY_SID, service $STANDBY_SERVICE
ORACLE_HOME (database home, not Grid):
  $DB_HOME"
  L51_MODE=""
  # a link is never written through: what is missing is shown, to add by hand in the file it points to
  if [[ -L "$f" ]]; then
    NOW="listener.ora is a link to $(readlink -f -- "$f" 2>/dev/null || printf 'a missing file'). The script does not write through a link."$'\n'"  $f"
    KIND_NOW=manual; MANUAL_HOW="$(lsnr_user)  ->  shell"; MANUAL_WHERE="To do on this server ($(hostname -s))"
    PLAN="-- Edit the file the link points to. SID_LIST_$SB_LSNR must hold this entry:"$'\n'"$(sid_desc_block)"
    ! use_grid && ! lsnr_has_desc && PLAN+=$'\n'"-- and this listener address:"$'\n'"$(lsnr_desc_block)"
    PLAN+=$'\n'"-- Then answer r."
    net_dir_note "$f"
    return 1
  fi
  if ! use_grid && ! lsnr_has_desc; then
    if [[ $st -eq 1 ]] && ! lsnr_has_sidlist; then
      # no Grid: the listener lives in the database home and must be defined completely
      L51_MODE=both
      NOW="No listener is defined in listener.ora. There is no Grid on this server."$'\n'"  $f"
      PLAN="Write the listener address and the static entry to listener.ora (owner $ORACLE_USER; a backup is kept)."
      net_dir_note "$f"
      l51_list
      return 1
    fi
    if [[ $st -eq 0 ]]; then
      L51_MODE=desc
      NOW="listener.ora has the static entry, but no address for the listener $SB_LSNR:"$'\n'"  $f"
      PLAN="Add the address of the listener $SB_LSNR to listener.ora (a backup is kept)."
      net_dir_note "$f"
      l51_list
      return 1
    fi
  fi
  if [[ $st -eq 1 ]] && ! lsnr_has_sidlist; then
    L51_MODE=static
    NOW="listener.ora has no static entry for $STANDBY_SID:"$'\n'"  $f"
    PLAN="Add the static entry SID_LIST_$SB_LSNR to listener.ora (owner $(lsnr_user); a backup is kept)."
    net_dir_note "$f"
    l51_list
    return 1
  fi
  # the block is there, without this SID: the entry is put inside it (one block of that name, written the usual
  # way; a backup is kept). The address of the listener is added too when it is missing (no Grid).
  if [[ $st -eq 1 ]] && sidlist_insert "$f" >/dev/null 2>&1; then
    L51_MODE=insert; ! use_grid && ! lsnr_has_desc && L51_MODE=insert_desc
    NOW="listener.ora has a SID_LIST_$SB_LSNR block without $STANDBY_SID:"$'\n'"  $f"
    PLAN="Add this entry inside SID_LIST_$SB_LSNR (owner $(lsnr_user); a backup is kept; the other entries stay):
$(sid_desc_block)"
    [[ "$L51_MODE" == insert_desc ]] && PLAN+=$'\n'"and this listener address:"$'\n'"$(lsnr_desc_block)"
    PLAN+=$'\n'"listener.ora is written whole with this change (below)."
    net_dir_note "$f"
    l51_list
    return 1
  fi
  # the entry of this SID is there but not right: it is replaced (one block, one entry of this SID, on lines of
  # its own; a backup is kept). Other entries stay as they are.
  if [[ $st -eq 2 ]] && sidlist_replace "$f" >/dev/null 2>&1; then
    # an existing entry is changed: asked also with --yes (another database may have set it up)
    L51_MODE=replace; YES_HOLD=1; ! use_grid && ! lsnr_has_desc && L51_MODE=replace_desc
    NOW="The static entry for $STANDBY_SID is not right:"$'\n'"${STATIC_WHY%$'\n'}"$'\n'"Logins through the listener would fail (ORA-01017 or ORA-12514)."$'\n'"  $f"
    PLAN="Replace the entry of $STANDBY_SID inside SID_LIST_$SB_LSNR with this (a backup is kept; the other entries stay):
$(sid_desc_block)"
    [[ "$L51_MODE" == replace_desc ]] && PLAN+=$'\n'"and add this listener address:"$'\n'"$(lsnr_desc_block)"
    PLAN+=$'\n'"listener.ora is written whole with this change (below). A running listener reads it at the next reload (step 5.2)."
    net_dir_note "$f"
    l51_list
    return 1
  fi
  # the wrong entry of this SID serves another service (the broker's _DGMGRL): it stays, the entry of
  # $STANDBY_SERVICE is added next to it
  local rr=0; [[ $st -eq 2 ]] && { sidlist_replace "$f" >/dev/null 2>&1 || rr=$?; }
  if [[ $st -eq 2 && $rr -eq 3 ]] && sidlist_insert "$f" >/dev/null 2>&1; then
    L51_MODE=insert; ! use_grid && ! lsnr_has_desc && L51_MODE=insert_desc
    NOW="listener.ora has an entry for $STANDBY_SID, but for another service:"$'\n'"${STATIC_WHY%$'\n'}"$'\n'"  $f"
    PLAN="Add this entry inside SID_LIST_$SB_LSNR (a backup is kept; the other entry stays, it may be used by the broker):
$(sid_desc_block)"
    [[ "$L51_MODE" == insert_desc ]] && PLAN+=$'\n'"and this listener address:"$'\n'"$(lsnr_desc_block)"
    PLAN+=$'\n'"listener.ora is written whole with this change (below)."
    net_dir_note "$f"
    l51_list
    return 1
  fi
  KIND_NOW=manual; MANUAL_HOW="$(lsnr_user)  ->  shell"
  if [[ $st -eq 2 ]]; then
    NOW="The static entry for $STANDBY_SID is not right:"$'\n'"${STATIC_WHY%$'\n'}"$'\n'"Logins through the listener would fail (ORA-01017 or ORA-12514)."
    NOW+=$'\n'"It is written in a form the script does not change (more than one entry or block, or other text"$'\n'"on its lines). Please correct this entry by hand."
  else
    NOW="listener.ora has a SID_LIST_$SB_LSNR block without $STANDBY_SID, written in a form the script does not change"$'\n'"(more than one such block, or its parentheses do not close). Please add the entry by hand."
  fi
  PLAN="-- Edit this file:
--   $f
-- Inside SID_LIST_$SB_LSNR, the (SID_LIST = ...) must contain exactly this SID_DESC:
    (SID_DESC =
      (GLOBAL_DBNAME = $STANDBY_SERVICE)
      (SID_NAME = $STANDBY_SID)
      (ORACLE_HOME = $DB_HOME)
    )"
  ! use_grid && ! lsnr_has_desc && PLAN+=$'\n'"-- and this listener address:"$'\n'"$(lsnr_desc_block)"
  net_dir_note "$f"
  return 1
}
lsnr_reload_flag() { printf '%s/listener_reload_due' "$STATE_DIR"; }
lsnr_changed() { install -d -m 700 "$STATE_DIR" 2>/dev/null; : > "$(lsnr_reload_flag)"; }
d_5_1() {
  # the commands shown: the backup, then listener.ora written whole (by its owner) or the block added at its end
  nf_sums_ok || return 1
  nf_baks_ok || return 1
  nf_run || return 1
  # a running listener reads the change only at a reload (step 5.2 does it): the flag is set only now
  lsnr_changed
  return 0
}

# ---- 5.2 ----
L52_START=0
c_5_2() {
  nf_reset
  lsnr_sw_ok || { NOW="The listener software is not installed yet (phase 3)"; return 2; }
  static_entry_state || { NOW="The static entry is not correct yet (step 5.1)"; return 2; }
  L52_START=0; L52_GRIDPORT=0
  if ! run_logged "lsnrctl status" as_lsnr timeout 60 "$(lsnr_home)/bin/lsnrctl" status "$SB_LSNR"; then
    if use_grid; then NOW="Listener $SB_LSNR is not running. It is an Oracle Restart resource, set up in step 3.9."; return 2; fi
    L52_START=1
    NOW="Listener $SB_LSNR is not running"
    PLAN="Start it:  lsnrctl start $SB_LSNR   (as $ORACLE_USER, from $DB_HOME)"
    nf_add lsnrstart "$(nf_lsnr_role)" "$(lsnr_home)/bin/lsnrctl start $SB_LSNR" "" 120
    return 1
  fi
  # an address the primary can reach: not only 127.x / localhost
  if ! grep -oE "\(PROTOCOL=TCP\)\(HOST=[^)]*\)\(PORT=$PORT\)" <<< "$(norm "$RUN_OUT")" | grep -vqE "\(HOST=(127\.[0-9.]+|LOCALHOST|LOCALHOST\.LOCALDOMAIN|::1|\[::1\])\)"; then
    NOW="Listener $SB_LSNR does not listen on port $PORT, the port the primary uses"
    KIND_NOW=manual; MANUAL_HOW="$(lsnr_user)  ->  shell"
    PLAN="-- Edit this file:
--   $(lsnr_file)
-- Set (PORT = $PORT) in the $SB_LSNR address, then restart the listener:
$(lsnr_home)/bin/lsnrctl stop $SB_LSNR ; $(lsnr_home)/bin/lsnrctl start $SB_LSNR"
    if use_grid; then
      # an Oracle Restart listener: the same change as step 3.10 (asked first, also with --yes: it restarts the listener)
      KIND_NOW=""; L52_GRIDPORT=1; YES_HOLD=1
      L310_CUR=$(as_grid timeout 600 "$GRID_HOME/bin/srvctl" config listener -listener "$SB_LSNR" 2>/dev/null | sed -n 's/.*End points:[[:space:]]*TCP:\([0-9]*\).*/\1/Ip' | head -n 1)
      PLAN="Set port $PORT for the Oracle Restart listener $SB_LSNR (as step 3.10 does), as $GRID_USER."
      PLAN+=$'\n'"The listener restarts; connections to it are cut for a moment."
      nf_add gp_modify grid "srvctl modify listener -listener $SB_LSNR -endpoints TCP:$PORT"
      nf_add gp_stop grid "srvctl stop listener -listener $SB_LSNR"
      nf_add "" grid "srvctl start listener -listener $SB_LSNR"
    fi
    net_dir_note "$(lsnr_file)"
    return 1
  fi
  # step 5.1 changed listener.ora while the listener ran: an old entry of this SID may still show, so the reload
  # is due whatever the status says
  if [[ -f "$(lsnr_reload_flag)" ]]; then
    NOW="Step 5.1 changed listener.ora. The running listener $SB_LSNR still has the old entries."
    PLAN="Reload it:  lsnrctl reload $SB_LSNR   (as $(lsnr_user); open connections stay)"
    nf_add "" "$(nf_lsnr_role)" "$(lsnr_home)/bin/lsnrctl reload $SB_LSNR" "" 120
    return 1
  fi
  if grep -qF "Instance \"$STANDBY_SID\", status UNKNOWN" <<< "$RUN_OUT"; then NOW="The listener shows Instance \"$STANDBY_SID\", status UNKNOWN (port $PORT)"; return 0; fi
  NOW="The listener does not show the static instance $STANDBY_SID yet"
  PLAN="Reload it:  lsnrctl reload $SB_LSNR   (as $(lsnr_user); open connections stay)"
  nf_add "" "$(nf_lsnr_role)" "$(lsnr_home)/bin/lsnrctl reload $SB_LSNR" "" 120
  return 1
}
L52_GRIDPORT=0
d_5_2() {
  # the shown commands: lsnrctl start or reload, or (Oracle Restart, wrong port) srvctl modify / stop / start as
  # in step 3.10 (a failed stop does not stop the step). A started or restarted listener reads listener.ora:
  # no reload is due any more
  nf_run || return 1
  rm -f -- "$(lsnr_reload_flag)"
  return 0
}

# ---- 5.3 / 5.4 ----
T_ALIAS=""; T_HOST=""; T_SVC=""
tns_alias_present() {
  # the alias as plain text (a . in my.db is a dot, not "any character")
  local f a; f=$(tns_file); [[ -f "$f" ]] || return 1
  a=$(sed 's/[][\.*^$+?(){}|]/\\&/g' <<< "$1")
  grep -qiE "^[[:space:]]*${a}[[:space:]]*=" "$f"
}
tns_replace() {
  # $1 tnsnames.ora, $2 alias -> the file with the entry of that alias replaced by the right one (tns_block).
  # 1 unless: exactly one entry starts with "<alias> =" on its own line, its parentheses close, and nothing
  # else follows on the line where it ends. Comments inside it are kept above the new entry; other entries stay.
  local a n; a=$(sed 's/[][\.*^$+?(){}|]/\\&/g' <<< "$2")
  n=$(grep -ciE "^[[:space:]]*${a}[[:space:]]*=" "$1"); [[ "$n" == 1 ]] || return 1
  # the alias is compared as text (an awk pattern from -v would turn "\." into "any character")
  DG_ALIAS="$2" awk -v blk="$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")" '
    function cl(s) { t = s; sub(/#.*/, "", t); return t }
    function name(s,   t) { t = cl(s); if (!index(t, "=")) return ""; t = substr(t, 1, index(t, "=") - 1); gsub(/[ \t\r]/, "", t); return toupper(t) }
    !inb && !done && name($0) == toupper(ENVIRON["DG_ALIAS"]) { inb = 1; d = 0; opened = 0 }
    inb {
      code = cl($0); i = index($0, "#"); if (i) com = com substr($0, i) "\n"
      for (j = 1; j <= length(code); j++) {
        c = substr(code, j, 1)
        if (c == "(") { d++; opened = 1 }
        else if (c == ")") { d--; if (d < 0) bad = 1
          if (d == 0 && opened) { if (substr(code, j + 1) !~ /^[[:space:]]*$/) bad = 1; inb = 0; done = 1; printf "%s", com; print blk; next } }
      }
      next
    }
    { print }
    END { if (!done || bad) exit 1 }' "$1"
}
TNS_MODE=""
tns_list() {
  # the commands of 5.3 / 5.4 for TNS_MODE, worked out from tnsnames.ora as it is now (written only while the
  # file is still the same): the entry replaced (the whole file written by its owner), or added at its end
  local f new; f=$(tns_file)
  nf_sum_add "$f"
  nf_bak_add oracle "$f"
  if [[ "$TNS_MODE" == replace ]]; then
    new=$(tns_replace "$f" "$T_ALIAS") || return 1
    nf_add "write:$f" oracle "$(nf_write_cmd "$f" "$(stat -c '%a' -- "$f")" "$ORACLE_USER")" "$new"
  else
    nf_app_add oracle "$f" "$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
  fi
}
c_tns() {
  TNS_MODE=""; nf_reset
  db_sw_ok || { NOW="The database software is not installed yet (phase 3)"; return 2; }
  rw_home_ok || { NOW="The Oracle home is read-only (step 3.8)"; return 2; }
  local f; f=$(tns_file)
  USING="Host $T_HOST, port $PORT, service $T_SVC"
  if tns_alias_present "$T_ALIAS" && run_logged "tnsping $T_ALIAS" as_oracle timeout 60 "$DB_HOME/bin/tnsping" "$T_ALIAS" 1 && grep -q '^OK' <<< "$RUN_OUT"; then
    if tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC"; then NOW="tnsping $T_ALIAS works ($T_HOST:$PORT/$T_SVC, UR=A)"; return 0; fi
    NOW="The alias $T_ALIAS exists but is different: $TNS_WHY"
    # the right entry is known: the old one is replaced (a backup is kept) when it is written the usual way
    if [[ ! -L "$f" ]] && tns_replace "$f" "$T_ALIAS" >/dev/null 2>&1; then
      # an existing entry is changed: asked also with --yes (another database of this home may use the alias)
      TNS_MODE=replace; YES_HOLD=1
      PLAN="Replace the entry $T_ALIAS in tnsnames.ora with this (a backup is kept; other entries stay):
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
      PLAN+=$'\n'"tnsnames.ora is written whole with this change (below)."
      net_dir_note "$f"
      tns_list
      return 1
    fi
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
    PLAN="-- Edit this file:
--   $f
-- The entry must be:
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
    net_dir_note "$(tns_file)"
    return 1
  fi
  if tns_alias_present "$T_ALIAS"; then
    case "$(tnsping_class "$RUN_OUT")" in
      BLOCKED)
        if tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC"; then
          NOW="The alias $T_ALIAS is right, but $T_HOST:$PORT gives no answer at all (timeout)."$'\n'"A firewall on $T_HOST or between the servers probably drops port $PORT."; return 2
        fi ;;
      NOLISTENER)
        if tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC"; then
          NOW="The alias $T_ALIAS is right, but nothing answers at $T_HOST:$PORT yet: $(grep -oE 'TNS-[0-9]+' <<< "$RUN_OUT" | head -n 1)"
          [[ "$T_HOST" == "$STANDBY_HOST" ]] && { NOW+=$'\n'"The listener on this server is not running (step 5.2)"; return 2; }
          NOW+=$'\n'"The listener on $T_HOST is not running. Check $LISTENER_NAME on the primary (port $PORT)."; return 2
        fi ;;
    esac
    # the entry itself is wrong (tnsping read it, "Attempting to contact ..."): replaced as when tnsping works
    if grep -qi 'Attempting to contact' <<< "$RUN_OUT" && ! tns_desc_ok "$RUN_OUT" "$T_HOST" "$T_SVC" && [[ ! -L "$f" ]] && tns_replace "$f" "$T_ALIAS" >/dev/null 2>&1; then
      NOW="The alias $T_ALIAS exists but is different: $TNS_WHY"
      TNS_MODE=replace; YES_HOLD=1
      PLAN="Replace the entry $T_ALIAS in tnsnames.ora with this (a backup is kept; other entries stay):
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
      PLAN+=$'\n'"tnsnames.ora is written whole with this change (below)."
      net_dir_note "$f"
      tns_list
      return 1
    fi
    NOW="The alias $T_ALIAS is in tnsnames.ora, but tnsping fails: $(grep -E 'TNS-[0-9]+' <<< "$RUN_OUT" | head -n 1)"
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
    PLAN="-- Edit this file:
--   $f
-- Fix the entry. Check the brackets and the host name:
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
    net_dir_note "$(tns_file)"
    return 1
  fi
  NOW="The alias $T_ALIAS is missing from tnsnames.ora:"$'\n'"  $f"
  if [[ -L "$f" ]]; then
    NOW+=$'\n'"tnsnames.ora is a link to $(readlink -f -- "$f" 2>/dev/null || printf 'a missing file'). The script does not write through a link."
    KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
    PLAN="-- Add this to the file the link points to, then answer r:
$(tns_block "$T_ALIAS" "$T_HOST" "$T_SVC")"
    net_dir_note "$f"
    return 1
  fi
  PLAN="Add the entry $T_ALIAS to the end of tnsnames.ora (a backup is kept)."
  net_dir_note "$f"
  tns_list
  return 1
}
d_tns() {
  # the commands shown: the backup, then the entry added at the end of tnsnames.ora, or the file written whole
  # with the entry replaced (as $ORACLE_USER)
  nf_sums_ok || return 1
  nf_baks_ok || return 1
  nf_run
}
c_5_3() { T_ALIAS=$PRIMARY_TNS; T_HOST=$PRIMARY_HOST; T_SVC=$PRIMARY_SERVICE; c_tns; }
c_5_4() { T_ALIAS=$STANDBY_TNS; T_HOST=$STANDBY_HOST; T_SVC=$STANDBY_SERVICE; c_tns; }

phase_5() {
  phase_header 5 "Listener and tnsnames.ora"
  run_step 5.1 auto "Static listener entry for $STANDBY_SID" c_5_1 d_5_1
  run_step 5.2 auto "Listener shows the static entry" c_5_2 d_5_2
  run_step 5.3 auto "tnsnames.ora entry for the primary ($PRIMARY_TNS)" c_5_3 d_tns
  run_step 5.4 auto "tnsnames.ora entry for the standby ($STANDBY_TNS)" c_5_4 d_tns
}

#------------------------------------------------------------------------------
# PHASE 6  Password file (copy of the primary file), TDE wallet
#------------------------------------------------------------------------------
pw_dest() { printf '%s/dbs/orapw%s' "$DB_HOME" "$STANDBY_SID"; }
pw_tmp_remote() { printf '/tmp/orapw_for_standby_%s' "$STANDBY_SID"; }

pw_prep_extra() {
  # One visit to the primary: when the primary keeps its password file in ASM, the readable copy that step 6.1
  # needs (asmcmd pwcopy to /tmp, as $GRID_USER) is shown in the combined primary block of phase 4. It only prints
  # the commands: step 6.1 checks the copy at its own time (and asks again if it is missing or older than a day),
  # step 6.2 asks you to remove it after the copy. Nothing here when a copy is there already.
  [[ "$MODE" == run && "${PRIMARY_RUN:-no}" != yes ]] || return 0
  step_in_range 6.1 || return 0
  pwfile_ok 2>/dev/null && return 0
  ssh_alive || return 0
  local pfile t
  prim_sql "select file_name from v\$passwordfile_info;" >/dev/null 2>&1 || return 0
  pfile=$(first_line); [[ "$pfile" =~ ^\+[A-Za-z0-9_./+-]+$ ]] || return 0
  t=$(pw_tmp_remote)
  # only when there is no copy at all (a clear "not there"): a copy that is there (usable, too old, of another
  # owner, readable by others) is judged by step 6.1 itself, with its reason
  prim_probe exists "$t" >/dev/null 2>&1 && [[ "$(head -n 1 <<< "$RUN_OUT")" == NO ]] || return 0
  local -a keep=(); local e
  for e in ${PRIMARY_BATCH_EXTRA[@]+"${PRIMARY_BATCH_EXTRA[@]}"}; do [[ "$e" == 6.1\|* ]] || keep+=("$e"); done
  PRIMARY_BATCH_EXTRA=(${keep[@]+"${keep[@]}"} "6.1|$GRID_USER|-- The password file of the primary is in ASM. A readable copy for step 6.1 (it copies it with scp):
export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM PATH=$GRID_HOME/bin:\$PATH
rm -f $t && test ! -e $t && (umask 077; asmcmd pwcopy '$pfile' $t)
chgrp $INSTALL_GROUP $t
chmod 640 $t
-- Step 6.2 asks you to remove it after the copy:  rm -f $t")
  # (as shown: when 6.1 then finds the copy, its own run records it; the undo is the rm of step 6.2)
  local PRIMARY_HOW_STEP; PRIMARY_HOW_STEP=$(prim_grid_how)
  primary_pending_add 6.1 "rm -f $t   (step 6.2 reminds you after the copy)"
  return 0
}
pwfile_ok() {
  local d; d=$(pw_dest)
  [[ -f "$d" && ! -L "$d" ]] || return 1
  [[ "$(stat -c '%U' "$d")" == "$ORACLE_USER" ]] || return 1
  [[ "$(stat -c '%a' "$d")" =~ ^6[04]0$ ]] || return 1
  [[ -s "$d" ]] || return 1
  [[ "$PRIMARY_VERSION" == 12.1* ]] && return 0          # 12.1 orapwd has no "describe"
  run_logged "orapwd describe" as_oracle timeout 60 "$DB_HOME/bin/orapwd" describe file="$d" || return 1
  # any format the primary uses (12, 12.2, or LEGACY on an upgraded database): the file is a byte copy
  grep -qE 'format=[A-Za-z0-9.]+' <<< "$RUN_OUT"
}

PW_SRC=""
pw_incoming() { printf '%s/orapw_incoming.%s' "$STATE_DIR" "$$"; }
pw_list() {
  # the commands of 6.1: copy PW_SRC from the primary into a private file here (then checked with md5sum),
  # keep the old file, install the copy as $ORACLE_USER (mode 640), remove the private copy.
  # 1 when a path is not plain (it goes into a command line)
  local d tmp; d=$(pw_dest); tmp=$(pw_incoming)
  v_path "$PW_SRC" && v_path "$d" || { NOW+=$'\n'"A path is not plain, so no command is built with it: $PW_SRC $d"; return 1; }
  nf_fetch_add "$PW_SRC" "$tmp"
  nf_bak_add oracle "$d"
  nf_add "inst:$d" root "$(nf_inst_cmd "$ORACLE_USER" "$INSTALL_GROUP" 640 "$tmp" "$d")"
  nf_add rmtmp root "rm -f -- $(nf_q "$tmp")"
}
c_6_1() {
  nf_reset
  db_sw_ok || { NOW="The database software is not installed yet (phase 3)"; return 2; }
  rw_home_ok || { NOW="The Oracle home is read-only (step 3.8)"; return 2; }
  local d; d=$(pw_dest)
  if pwfile_ok; then NOW="The password file is in place, owner $ORACLE_USER."$'\n'"  $d"$'\n'"The login test of step 7.4 compares it with the primary."; return 0; fi
  need_ssh || return 2
  # 12.2+: v$passwordfile_info has file_name and format; 12.1: file_name only; else the file in dbs
  local pfile=""
  if prim_sql "select file_name from v\$passwordfile_info;"; then pfile=$(first_line)
  # a failed query is not "no password file": only a view this release does not have (ORA-00942) is
  elif ! grep -q 'ORA-00942' <<< "$SQL_OUT"; then
    local qe; qe=$(ora_errors "$SQL_OUT")
    NOW="Cannot read v\$passwordfile_info on the primary${qe:+ ($qe)}, so it is not known where its password file is."$'\n'"Answer r to check again."; return 2
  fi
  if [[ -z "$pfile" || "$pfile" == "-" ]]; then
    local pex=""; prim_probe exists "$DB_HOME/dbs/orapw$PRIMARY_SID" && pex=$(head -n 1 <<< "$RUN_OUT")
    if [[ "$pex" == YES ]]; then pfile="$DB_HOME/dbs/orapw$PRIMARY_SID"
    elif [[ "$pex" != NO ]]; then NOW="Cannot tell whether $DB_HOME/dbs/orapw$PRIMARY_SID is on the primary (no answer$([[ $PROBE_TIMED_OUT -eq 1 ]] && printf ' in time'))."$'\n'"Answer r to check again."; return 2
    else NOW="The password file of the primary was not found."$'\n'"v\$passwordfile_info is empty and $DB_HOME/dbs/orapw$PRIMARY_SID does not exist."$'\n'"To find it, run on the primary as $ORACLE_USER:"$'\n'"  $DB_HOME/bin/srvctl config database -db $PRIMARY_UNIQUE | grep -i 'password file'"; return 2; fi
  fi
  [[ "$pfile" =~ ^\+[A-Za-z0-9_./+-]+$ || "$pfile" =~ ^/[A-Za-z0-9_./-]+$ ]] || { NOW="The primary password file has an unusual path: '$pfile'"; return 2; }
  if [[ -f "$d" ]]; then NOW="The password file here has the wrong owner, mode or format:"$'\n'"  $d"; else NOW="This server has no password file yet."$'\n'"  $d"; fi
  if [[ "$pfile" == +* ]]; then
    local t towner tg tm tmode ttype tage=""; t=$(pw_tmp_remote)
    # no answer from stat (the file is not there) is "no copy yet", not a copy with an empty owner and mode
    local sx=0; prim_probe statx "$t" || sx=1
    # no answer in time: whether a copy is there is not known (never taken as "no copy")
    [[ $PROBE_TIMED_OUT -eq 1 ]] && { NOW="The primary did not answer in time, so it is not known whether $t is there. Answer r to check again."; return 2; }
    # stat failed for another reason: only a clear "not there" means no copy yet
    if [[ $sx -ne 0 ]]; then
      local ex=""; prim_probe exists "$t" && ex=$(head -n 1 <<< "$RUN_OUT")
      [[ "$ex" == NO ]] || { NOW="Cannot tell whether the temporary copy $t is on the primary (stat failed${ex:+, the file is there})."$'\n'"The ssh user $PRIMARY_SSH_USER must be able to read /tmp there. Answer r to check again."; return 2; }
    fi
    if [[ $sx -eq 0 && -n "$(head -n 1 <<< "$RUN_OUT")" ]]; then
      IFS='|' read -r towner tg tmode ttype tm <<< "$(head -n 1 <<< "$RUN_OUT")"
      if [[ "$ttype" != "regular file" || ( "$towner" != "$GRID_USER" && "$towner" != "$ORACLE_USER" ) || ! "$tmode" =~ ^[0-7]+$ || $(( 8#$tmode & 8#027 )) -ne 0 ]]; then
        NOW+=$'\n'"$t on the primary is not used (owner $towner, type $ttype, mode $tmode)."
        NOW+=$'\n'"It must be a regular file of $GRID_USER or $ORACLE_USER, mode 640 or stricter (it holds the password hashes)."
        KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
        PLAN="rm -f $t && test ! -e $t && (umask 077; asmcmd pwcopy '$pfile' $t)
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 reminds you after the copy)"
        return 1
      fi
      # the age is measured with the clock of the primary
      num "$tm" && tage=$(( $(date +%s) + PRIM_CLOCK_OFFSET - tm ))
    fi
    if [[ -n "$tage" && $tage -gt 86400 ]]; then
      # a copy older than a day (from an earlier attempt) may be from before a sys password change
      NOW+=$'\n'"An old copy $t is on the primary (owner $towner, $((tage / 3600)) hours older than this run)."
      NOW+=$'\n'"It is not used: the sys password may have changed since then."
      KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
      PLAN="rm -f $t && test ! -e $t && (umask 077; asmcmd pwcopy '$pfile' $t)
chgrp $INSTALL_GROUP $t
chmod 640 $t"
      PLAN_UNDO="rm -f $t   (step 6.2 reminds you after the copy)"
      return 1
    fi
    [[ -n "$tage" ]] && NOW="The copy $t is ready on the primary$([[ $tage -ge 60 ]] && printf ' (%s minutes old)' "$((tage / 60))")."$'\n'"$NOW"
    if [[ -n "$tage" ]]; then
      PW_SRC=$t
      PLAN="Copy $t from the primary (scp, checked with md5sum)
Install it here (owner $ORACLE_USER:$INSTALL_GROUP, mode 640):
  $d"
      [[ -f "$d" ]] && PLAN+=$'\n'"Keep the old file as ${d##*/}.bak_$RUN_ID (same folder)"
      USING="Fresh copy of $pfile on the primary (owner $towner)"
      pw_list || return 2
      return 1
    fi
    NOW+=$'\n'"The primary password file is in ASM: $pfile"
    KIND_NOW=primary; PRIMARY_HOW_STEP=$(prim_grid_how)
    PLAN="rm -f $t && test ! -e $t && (umask 077; asmcmd pwcopy '$pfile' $t)
chgrp $INSTALL_GROUP $t
chmod 640 $t"
        PLAN_UNDO="rm -f $t   (step 6.2 reminds you after the copy)"
    USING="After you run the commands below, the script copies the file to this server."$'\n'"Step 6.2 then asks you to delete it on the primary."
    return 1
  fi
  # can the ssh user read it? (md5sum reads the file; a copy would fail the same way)
  if ! prim_probe md5 "$pfile" || ! [[ "$(awk '{print $1; exit}' <<< "$RUN_OUT")" =~ ^[0-9a-f]{32}$ ]]; then
    # no answer in time is not "cannot read": no chmod is advised for it
    [[ $PROBE_TIMED_OUT -eq 1 ]] && { NOW+=$'\n'"The primary did not answer in time, so it is not known whether the ssh user $PRIMARY_SSH_USER can read $pfile."$'\n'"Answer r to check again."; return 2; }
    NOW+=$'\n'"The ssh user $PRIMARY_SSH_USER cannot read $pfile on the primary."
    KIND_NOW=primary; PRIMARY_HOW_STEP="root  ->  shell"
    PLAN="-- Let the ssh user read it (it is in the group $INSTALL_GROUP, or use the oracle user for ssh):
ls -l $pfile
chmod g+r $pfile"
    PLAN_UNDO="chmod g-r $pfile"
    return 1
  fi
  PW_SRC=$pfile
  PLAN="Copy the password file from the primary (scp, checked with md5sum):
  $pfile
Install it here (owner $ORACLE_USER:$INSTALL_GROUP, mode 640):
  $d"
  [[ -f "$d" ]] && PLAN+=$'\n'"Keep the old file as ${d##*/}.bak_$RUN_ID (same folder)"
  pw_list || return 2
  return 1
}
d_6_1() {
  # the commands shown: scp into a private file of root (its md5sum is compared with the primary's before it is
  # used), the backup, the install as $ORACLE_USER, the private copy removed
  install -d -m 700 "$STATE_DIR"
  CLEANUP_FILES+=("$(pw_incoming)")
  nf_baks_ok || return 1
  nf_run || return 1
  DONE_MSG="The primary password file is installed here:"$'\n'"  $(pw_dest)"
}

# ---- 6.2 temporary copy on primary ----
c_6_2() {
  need_ssh || return 2
  local t; t=$(pw_tmp_remote)
  PRIMARY_HOW_STEP="$GRID_USER (or root)  ->  shell"
  # absence must be proven (a failed probe is not "no file": the copy holds the password hashes)
  local ex=""; prim_probe exists "$t" && ex=$(grep -m1 -E '^(YES|NO)$' <<< "$RUN_OUT")
  case "$ex" in
    NO)  NOW="No temporary password file copy on the primary"; return 0 ;;
    YES) ;;
    *)   NOW="Cannot tell whether $t is still on the primary (the check got no answer)"; return 2 ;;
  esac
  pwfile_ok || { NOW="Keep $t for now: the password file is not installed yet (step 6.1)"; return 2; }
  NOW="The temporary copy $t is still on the primary"
  PLAN="rm -f $t"
  not_done_yet
  return 1
}

# ---- 6.3 TDE wallet ----
TDE_DIRS=(); TDE_TODO=(); TDE_SQLNET=0; TDE_NO_AUTOLOGIN=0
tde_dirs() {
  # file-based wallet folders in use on primary (one per line); TDE_INFO lines: type|location|status
  awk -F'|' 'toupper($1)=="FILE" && $2 != "-" && toupper($3) != "NOT_AVAILABLE" {print $2}' <<< "$TDE_INFO" | sed 's#/*$##' | sort -u
}
sqlnet_file() { printf '%s/network/admin/sqlnet.ora' "$DB_HOME"; }
tde_local_autologin() {
  # $1 wallet folder: 0 when the primary's wallet in THAT folder is a LOCAL auto-login one (it opens only on the host
  # where it was made; folders may differ). Without $1: any folder (for notes about the primary as a whole)
  awk -F'|' -v d="${1:-}" '{ p = $2; sub(/\/+$/, "", p) } (d == "" || p == d) && toupper($4) ~ /LOCAL/' <<< "$TDE_INFO" | grep -q .
}
TDE_SSO_WHY=""
tde_sso_stale() {
  # $1 folder with a cwallet.sso for a LOCAL auto-login wallet (never compared with the primary's: it is made here).
  # 0 when it is not usable here (ORA-28365 / ORA-28374 later), the reason in TDE_SSO_WHY: older than ewallet.p12
  # (made before the newer keystore came), or orapki cannot open it without a password (an auto-login wallet opens
  # without one; a LOCAL one made on another host does not). 2 when orapki gave no answer. 1 otherwise, also when
  # orapki fails for another reason (not installed, unknown option): then the age test is all there is. Read-only.
  local d=$1 out rc=0; TDE_SSO_WHY=""
  if [[ -f "$d/ewallet.p12" && "$d/cwallet.sso" -ot "$d/ewallet.p12" ]]; then TDE_SSO_WHY="it is older than ewallet.p12"; return 0; fi
  [[ -x "$DB_HOME/bin/orapki" ]] || return 1
  out=$(timeout 120 runuser -u "$ORACLE_USER" -- env -i "${ORA_ENV[@]}" "$DB_HOME/bin/orapki" wallet display -wallet "$d" < /dev/null 2>&1 9>&-) || rc=$?
  printf '%s\n(exit code %s)\n' "$out" "$rc" | log_block "orapki wallet display -wallet $d (no password: auto-login)"
  [[ $rc -eq 124 ]] && { TDE_SSO_WHY="orapki gave no answer in 120 seconds"; return 2; }
  if grep -qiE 'PKI-02[0-9]+|password|unable to open' <<< "$out"; then
    TDE_SSO_WHY="orapki cannot open it without a password ($({ grep -m1 -E 'PKI-02[0-9]+' <<< "$out" || grep -m1 -iE 'password|unable to open' <<< "$out"; } | sed 's/[[:space:]]*$//'))"; return 0
  fi
  return 1
}
orapki_plan() {
  # creates cwallet.sso next to ewallet.p12 on THIS server; orapki asks for the keystore password itself
  printf 'ORACLE_HOME=%s %s/bin/orapki wallet create -wallet %s %s\n' "$DB_HOME" "$DB_HOME" "$1" "$(tde_local_autologin "$1" && printf -- '-auto_login_local' || printf -- '-auto_login')"
  printf '# orapki asks for the keystore password and writes %s/cwallet.sso here.\n# The primary is not changed. Then answer r.' "$1"
}
tde_autologin_missing() {
  # 0 when the primary uses a file keystore and a keystore folder here has no usable auto-login file (ORA-28365
  # later). Every folder counts (CDB and PDB keystores are separate folders, $WALLET_ROOT/tde among them), as in 6.3
  [[ -n "$TDE_INFO" ]] || return 1
  local d
  while IFS= read -r d; do
    [[ -n "$d" && "$d" == /* ]] || continue
    [[ -n "$WALLET_ROOT" && "$d" == "$WALLET_ROOT/tde_seps" ]] && continue
    [[ -f "$d/cwallet.sso" ]] || return 0
    tde_local_autologin "$d" && { tde_sso_stale "$d"; [[ $? -eq 0 ]]; } && return 0
  done < <(tde_dirs)
  return 1
}
sqlnet_wallet_replaced() {
  # $1 sqlnet.ora, $2 wallet folder -> the file with its ENCRYPTION_WALLET_LOCATION entry (one or more lines,
  # up to the parenthesis that closes it) replaced by one line for $2. Comments on the old lines are kept, as
  # comment lines just above it. 1 when there is not exactly one entry, it does not close, or other text follows
  # its closing parenthesis on that line (another parameter would be lost).
  awk -v dir="$2" '
    function keepc(s,   i) { i = index(s, "#"); if (i) com = com substr(s, i) "\n" }
    function emit() { printf "%s", com; com = ""; print "ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = " dir ")))" }
    # walks the code of one line of the entry; 1 when the entry closed on it
    function scan(s,   k, ch) { for (k = 1; k <= length(s); k++) { ch = substr(s, k, 1)
        if (ch == "(") { dd++; op = 1 }
        else if (ch == ")") { dd--; if (dd < 0) bad = 1; if (dd == 0 && op) { if (substr(s, k + 1) !~ /^[[:space:]]*$/) bad = 1; return 1 } } }
      return 0 }
    !ine && toupper($0) ~ /^[[:space:]]*ENCRYPTION_WALLET_LOCATION/ {
      c0 = $0; sub(/#.*/, "", c0); keepc($0); found++; dd = 0; op = 0
      if (scan(c0)) emit(); else ine = 1
      next }
    ine { c0 = $0; sub(/#.*/, "", c0); keepc($0); if (scan(c0)) { ine = 0; emit() }; next }
    { print }
    END { if (found != 1 || ine || bad) exit 1 }' "$1"
}
sqlnet_has_wallet() {
  # the same folder with or without a final / counts
  local f d=${1%/}; f=$(sqlnet_file); [[ -f "$f" ]] || return 1
  norm "$(sed 's/#.*//' "$f")" | grep -qE "\(DIRECTORY=\"?$(sed 's/[][\.*^$+?(){}|]/\\&/g' <<< "${d^^}")/?\"?\)"
}
TDE_CW_PRED=()      # the folders where orapki makes cwallet.sso after the copy (as the check after the copy will find)
TDE_PW_NOTE="(the keystore password: you type it when this runs; it is not shown, logged or kept)"
tde_incoming() { printf '%s/tde_incoming.%s' "$STATE_DIR" "$$"; }
tde_in_todo() { local x; for x in "${TDE_TODO[@]+"${TDE_TODO[@]}"}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
tde_list() {
  # the commands of 6.3: per wallet folder (made as make_dir does when missing) the files of TDE_TODO copied from
  # the primary (scp into a private file of root, md5sum compared, backup, installed as $ORACLE_USER mode 600),
  # sqlnet.ora (TDE_SQLNET), then the auto-login keystore made with orapki where it will be missing.
  # 1 (with the reason in NOW) when a folder could not be made the way make_dir makes it.
  local f d tmp s txt seen=" " opt x
  tmp=$(tde_incoming)
  for f in "${TDE_TODO[@]+"${TDE_TODO[@]}"}"; do
    d=$(dirname "$f")
    if [[ "$seen" != *" $d "* ]]; then
      seen+="$d "
      nf_mkdir_add "$d" oracle || { NOW+=$'\n'"$NF_ERR"; return 1; }
      nf_add chmodq oracle "chmod 700 -- $(nf_q "$d")"
    fi
    nf_fetch_add "$f" "$tmp"
    nf_bak_add oracle "$f"
    nf_add "inst:$f" root "$(nf_inst_cmd "$ORACLE_USER" "$INSTALL_GROUP" 600 "$tmp" "$f")"
    nf_add rmtmp root "rm -f -- $(nf_q "$tmp")"
    # a new ewallet.p12 (for example after a new master key) makes an auto-login file that was made HERE outdated
    # (ORA-28374): it is moved aside and made again. One that comes from the primary is copied anyway.
    if [[ "$f" == */ewallet.p12 && -f "$d/cwallet.sso" ]] && ! tde_in_todo "$d/cwallet.sso"; then
      nf_add "sso1:$d" oracle "mv -f -- $(nf_q "$d/cwallet.sso") $(nf_q "$d/cwallet.sso.old_$RUN_ID")"
    fi
  done
  s=$(sqlnet_file)
  if [[ $TDE_SQLNET -eq 1 ]]; then
    nf_sum_add "$s"; nf_bak_add oracle "$s"
    nf_app_add oracle "$s" "# Added by dg_standby_setup.sh $RUN_ID (TDE wallet of the standby)"$'\n'"ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${TDE_DIRS[0]})))"
  elif [[ $TDE_SQLNET -eq 2 ]]; then
    nf_sum_add "$s"
    txt=$(sqlnet_wallet_replaced "$s" "${TDE_DIRS[0]}") || { NOW+=$'\n'"The ENCRYPTION_WALLET_LOCATION entry of $s cannot be changed. Edit it by hand."; return 1; }
    nf_bak_add oracle "$s"
    nf_add "write:$s" oracle "$(nf_write_cmd "$s" "$(stat -c '%a' -- "$s")" "$ORACLE_USER")" "$txt"
  fi
  # the auto-login keystore: missing now, or moved aside above (outdated by a new ewallet.p12)
  TDE_CW_PRED=("${TDE_CW_TODO[@]+"${TDE_CW_TODO[@]}"}")
  for f in "${TDE_TODO[@]+"${TDE_TODO[@]}"}"; do
    [[ "$f" == */ewallet.p12 ]] || continue
    d=$(dirname "$f")
    [[ -n "$WALLET_ROOT" && "$d" == "$WALLET_ROOT/tde_seps" ]] && continue
    [[ -f "$d/cwallet.sso" ]] && ! tde_in_todo "$d/cwallet.sso" || continue
    [[ " ${TDE_CW_PRED[*]+"${TDE_CW_PRED[*]}"} " == *" $d "* ]] || TDE_CW_PRED+=("$d")
  done
  # a cwallet.sso that does not open here (LOCAL, made on another host or outdated) is kept aside first
  for d in "${TDE_CW_PRED[@]+"${TDE_CW_PRED[@]}"}"; do
    [[ -f "$d/cwallet.sso" ]] && ! tde_in_todo "$d/ewallet.p12" || continue
    nf_add "sso2:$d" oracle "mv -f -- $(nf_q "$d/cwallet.sso") $(nf_q "$d/cwallet.sso.old_$RUN_ID")"
  done
  for d in "${TDE_CW_PRED[@]+"${TDE_CW_PRED[@]}"}"; do
    opt=$(tde_local_autologin "$d" && printf -- '-auto_login_local' || printf -- '-auto_login')
    nf_add "orapki:$d" oracle "$DB_HOME/bin/orapki wallet create -wallet $(nf_q "$d") $opt" "$TDE_PW_NOTE" 300
  done
  return 0
}
c_6_3() {
  nf_reset
  # the wallet query of the discovery failed: asked again now; still failing = not known (never "no wallet")
  if [[ ${TDE_UNREAD:-0} -eq 1 ]]; then
    need_ssh || return 2
    tde_read
    [[ $TDE_UNREAD -eq 0 ]] || { NOW="Cannot read the TDE settings of the primary${TDE_ERR:+ ($TDE_ERR)}. Whether it uses TDE is not known."; return 2; }
  fi
  # wallet_root of the primary that is not a plain folder: the wallet (and tde_seps) are copied by hand
  [[ -n "${WROOT_BAD:-}" ]] && { NOW="wallet_root on the primary is '$WROOT_BAD', which is not a plain folder."$'\n'"Copy the TDE wallet to the same place for the standby by hand."; return 2; }
  [[ -n "$TDE_INFO" ]] || { NOW="The primary does not use a TDE wallet"; return 0; }
  if awk -F'|' 'toupper($1)!="FILE" && toupper($3)!="NOT_AVAILABLE"' <<< "$TDE_INFO" | grep -q .; then
    NOW="The primary uses a TDE keystore that is not a file (HSM or OKV):"$'\n'"$TDE_INFO"
    PLAN="Set up the same keystore for $STANDBY_UNIQUE on this server, as your HSM or OKV vendor describes."
    return 2
  fi
  local -a dirs=(); local d f seps_note=""; mapfile -t dirs < <(tde_dirs)
  [[ ${#dirs[@]} -gt 0 && -n "${dirs[0]}" ]] || { NOW="The primary does not use a TDE wallet"; return 0; }
  # 18c+: the password for "IDENTIFIED BY EXTERNAL STORE" is in WALLET_ROOT/tde_seps
  # (a folder that cannot be read is not left out silently: the password in it would be missing here)
  if [[ -n "$WALLET_ROOT" ]]; then
    need_ssh || { NOW="Cannot check $WALLET_ROOT/tde_seps on the primary: $NOW"; return 2; }
    local sx=""; prim_probe exists "$WALLET_ROOT/tde_seps" && sx=$(head -n 1 <<< "$RUN_OUT")
    [[ "$sx" == YES || "$sx" == NO ]] || { NOW="Cannot tell whether $WALLET_ROOT/tde_seps exists on the primary (no answer)."; return 2; }
    # "not there" counts only when the ssh user can look into WALLET_ROOT (else test -e says no for anything)
    if [[ "$sx" == NO ]]; then
      local cl=""; prim_probe canlook "$WALLET_ROOT" && cl=$(head -n 1 <<< "$RUN_OUT")
      [[ "$cl" == YES ]] || { NOW="Cannot tell whether $WALLET_ROOT/tde_seps exists on the primary: the ssh user $PRIMARY_SSH_USER cannot look into $WALLET_ROOT."; return 2; }
    fi
    if [[ "$sx" == YES ]]; then
      prim_probe lsdir "$WALLET_ROOT/tde_seps" || { NOW="Cannot list $WALLET_ROOT/tde_seps on the primary. The ssh user must be able to read it."; return 2; }
      if grep -qx 'cwallet.sso' <<< "$RUN_OUT"; then dirs+=("$WALLET_ROOT/tde_seps")
      elif grep -q '[^[:space:]]' <<< "$RUN_OUT"; then seps_note="$WALLET_ROOT/tde_seps on the primary has no cwallet.sso. It is not copied (no external-store password to take)."; warn "$seps_note"; fi
    fi
  fi
  db_sw_ok || { NOW="The database software is not installed yet (phase 3)"; return 2; }
  for d in "${dirs[@]}"; do
    [[ "$d" == /* ]] && v_path "$d" || { NOW="The TDE wallet is at $d, in ASM or at an unusual path"; PLAN="Copy the wallet files by hand to the same location for the standby, for example with asmcmd cp."; return 2; }
  done
  need_ssh || return 2
  TDE_DIRS=("${dirs[@]}"); TDE_TODO=()
  local miss="" diff="" have=""
  for d in "${dirs[@]}"; do
    prim_probe lsdir "$d" || { NOW="Cannot list the wallet folder $d on the primary. The ssh user must be able to read it."; return 2; }
    local found=0
    while IFS= read -r f; do
      [[ "$f" =~ ^(ewallet\.p12|cwallet\.sso)$ ]] || continue
      found=1
      # a LOCAL auto-login wallet of the primary does not open here: it is made again on this server (orapki)
      # (not the tde_seps folder: it holds only the external-store password and is copied as it is)
      if [[ "$f" == cwallet.sso ]] && tde_local_autologin "$d" && ! [[ -n "$WALLET_ROOT" && "$d" == "$WALLET_ROOT/tde_seps" ]]; then continue; fi
      if [[ ! -f "$d/$f" ]]; then miss+=" $d/$f"; TDE_TODO+=("$d/$f"); continue; fi
      # a checksum the primary cannot give (the ssh user cannot read the file) is not "different": it is not known
      local rmd=""; prim_probe md5 "$d/$f" && rmd=$(awk '{print $1; exit}' <<< "$RUN_OUT")
      [[ "$rmd" =~ ^[0-9a-f]{32}$ ]] || { NOW="Cannot read $d/$f on the primary (md5sum). The ssh user $PRIMARY_SSH_USER must be able to read it."; return 2; }
      if [[ "$rmd" == "$(md5sum "$d/$f" | awk '{print $1}')" ]]; then have+=" $d/$f"
      else diff+=" $d/$f"; TDE_TODO+=("$d/$f"); fi
    done <<< "$RUN_OUT"
    [[ $found -eq 1 ]] || { NOW="No ewallet.p12 or cwallet.sso in $d on the primary"; return 2; }
  done
  # without WALLET_ROOT (12c, or 18c-21c set up the old way) the standby finds the wallet only through sqlnet.ora
  TDE_SQLNET=0
  if [[ -z "$WALLET_ROOT" ]]; then
    [[ $DB_MAJOR -ge 23 ]] && { NOW="The primary ($PRIMARY_VERSION) uses TDE without WALLET_ROOT. Set WALLET_ROOT on the primary first."; return 2; }
    if ! sqlnet_has_wallet "${dirs[0]}"; then
      if [[ -f "$(sqlnet_file)" ]] && grep -qiE '^[[:space:]]*ENCRYPTION_WALLET_LOCATION' "$(sqlnet_file)" \
         && sqlnet_wallet_replaced "$(sqlnet_file)" "${dirs[0]}" >/dev/null 2>&1; then
        # exactly one entry, written in the usual form: it is changed by the action (a backup is kept). Asked also
        # with --yes: another database of this home may use that wallet location
        TDE_SQLNET=2; YES_HOLD=1
      elif [[ -f "$(sqlnet_file)" ]] && grep -qiE '^[[:space:]]*ENCRYPTION_WALLET_LOCATION' "$(sqlnet_file)"; then
        NOW="sqlnet.ora has an ENCRYPTION_WALLET_LOCATION that is not ${dirs[0]}:"$'\n'"  $(sqlnet_file)"
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"
        PLAN="-- Edit this file:
--   $(sqlnet_file)
-- Change the ENCRYPTION_WALLET_LOCATION line to:
ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))"
        net_dir_note "$(sqlnet_file)"
        return 1
      else
        TDE_SQLNET=1
      fi
      # a link is never written through: found now, not after the wallet files are copied
      if [[ $TDE_SQLNET -ne 0 && -L "$(sqlnet_file)" ]]; then
        NOW="sqlnet.ora is a link to $(readlink -f -- "$(sqlnet_file)" 2>/dev/null || printf 'a missing file'). The script does not write through a link."$'\n'"  $(sqlnet_file)"
        KIND_NOW=manual; MANUAL_HOW="$ORACLE_USER  ->  shell"; TDE_SQLNET=0
        PLAN="-- In the file the link points to, the wallet entry must be (one entry only):
ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))
-- Then answer r."
        return 1
      fi
    fi
  fi
  # every keystore folder needs its own auto-login file here (CDB and PDB wallets are separate folders);
  # the tde_seps folder holds only the external-store password and is copied as it is
  # a LOCAL auto-login file is not compared with the primary's (it is made here): it must open on this server
  local nocw=() stale="" nloc=0 nport=0 sr
  for d in "${dirs[@]}"; do
    [[ -n "$WALLET_ROOT" && "$d" == "$WALLET_ROOT/tde_seps" ]] && continue
    [[ " ${TDE_TODO[*]+"${TDE_TODO[*]}"} " == *" $d/cwallet.sso "* ]] && continue
    if [[ -f "$d/cwallet.sso" ]]; then
      tde_local_autologin "$d" || continue
      sr=0; tde_sso_stale "$d" || sr=$?
      [[ $sr -eq 2 ]] && { NOW="Cannot check whether $d/cwallet.sso opens on this server: $TDE_SSO_WHY."$'\n'"Answer r to check again."; return 2; }
      [[ $sr -eq 1 ]] && continue
      stale+=$'\n'"  $d/cwallet.sso: $TDE_SSO_WHY"
    fi
    nocw+=("$d")
    if tde_local_autologin "$d"; then nloc=1; else nport=1; fi
  done
  TDE_NO_AUTOLOGIN=0; [[ ${#nocw[@]} -gt 0 ]] && TDE_NO_AUTOLOGIN=1
  TDE_CW_TODO=("${nocw[@]+"${nocw[@]}"}")
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 && $TDE_NO_AUTOLOGIN -eq 1 ]]; then
    NOW="The TDE wallet is copied, but there is no usable auto-login keystore (cwallet.sso) here in:"$'\n'"$(printf '  %s\n' "${nocw[@]}")"$'\n'"Without it, the RMAN copy and redo apply stop with ORA-28365."
    [[ $nloc -eq 1 ]] && NOW+=$'\n'"The primary uses a local auto-login wallet. It opens only on the primary host,"$'\n'"so it is made again here."
    [[ -n "$stale" ]] && NOW+=$'\n'"Not usable here:$stale"
    PLAN="Make cwallet.sso here with orapki, as $ORACLE_USER, in:"$'\n'"$(printf '  %s\n' "${nocw[@]}")"$'\n'"You type the keystore (wallet) password once. It is passed to orapki and not kept anywhere."
    [[ -n "$stale" ]] && PLAN+=$'\n'"A cwallet.sso that is not usable is kept first as cwallet.sso.old_$RUN_ID (same folder)."
    tde_list || return 2
    return 1
  fi
  if [[ -z "$miss$diff" && $TDE_SQLNET -eq 0 ]]; then
    NOW="The TDE wallet is the same as on the primary:$have"
    [[ -n "$WALLET_ROOT" ]] && NOW+=$'\n'"wallet_root=$WALLET_ROOT comes to the standby with the spfile." || NOW+=$'\n'"The wallet location ${dirs[0]} is set in:"$'\n'"  $(sqlnet_file)"
    [[ -n "$seps_note" ]] && NOW+=$'\n'"Note: $seps_note"
    return 0
  fi
  NOW="The primary uses TDE.${miss:+ Missing here:$miss}${diff:+ Different here:$diff}"
  [[ $TDE_SQLNET -ge 1 ]] && NOW+=$'\n'"sqlnet.ora does not point to the wallet ${dirs[0]}:"$'\n'"  $(sqlnet_file)"
  PLAN=""
  [[ ${#TDE_TODO[@]} -gt 0 ]] && PLAN="Copy these files from the primary to the same path here (scp, checked with md5sum):"$'\n'"$(printf '  %s\n' "${TDE_TODO[@]}")"$'\n'"Owner $ORACLE_USER:$INSTALL_GROUP, mode 600. Old files are kept as .bak_$RUN_ID."$'\n'
  [[ $TDE_SQLNET -eq 1 ]] && PLAN+="Add this to sqlnet.ora (a backup is kept):"$'\n'"ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))"$'\n'
  [[ $TDE_SQLNET -eq 2 ]] && PLAN+="Change the ENCRYPTION_WALLET_LOCATION entry of sqlnet.ora to (a backup is kept):"$'\n'"ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${dirs[0]})))"$'\n'
  if [[ $TDE_NO_AUTOLOGIN -eq 1 ]]; then
    [[ $nloc -eq 1 ]] && PLAN+="The primary uses a local auto-login wallet. It opens only on the primary host,"$'\n'"so it is not copied."$'\n'
    [[ $nport -eq 1 ]] && PLAN+="The primary has no auto-login keystore (cwallet.sso)$([[ $nloc -eq 1 ]] && printf ' in the other folders')."$'\n'"Without one here, the RMAN copy and redo apply on the standby stop with ORA-28365."$'\n'
    [[ -n "$stale" ]] && PLAN+="Not usable here, kept as cwallet.sso.old_$RUN_ID:$stale"$'\n'
    PLAN+="After the copy, cwallet.sso is made on this server with orapki (you type the keystore password once)."$'\n'
    PLAN+="The wallet is checked again after the copy: if a folder other than shown needs one, nothing more is done."$'\n'
  fi
  PLAN=${PLAN%$'\n'}
  tde_list || return 2
  return 1
}
d_6_3() {
  # the commands shown, in their order. The ones of the auto-login keystore (mv aside, orapki) run only when the
  # check after the copy finds the same folders without a usable cwallet.sso as shown before
  nf_sums_ok || return 1
  nf_baks_ok || return 1
  install -d -m 700 "$STATE_DIR"; CLEANUP_FILES+=("$(tde_incoming)")
  local i n=${#CP_CMD[@]} first t d
  first=$n
  for ((i = 0; i < n; i++)); do t=${NF_TAG[$i]:-}; [[ "$t" == sso2:* || "$t" == orapki:* ]] && { first=$i; break; }; done
  nf_run 0 "$first" || return 1
  # the auto-login keystore: worked out again after the copy (the copied files may have brought one)
  need_ssh || return 1            # a lost connection is opened again on the screen, not in the quiet check
  # (the check builds a list of its own: the shown list is kept aside meanwhile)
  local -a s_role=("${CP_ROLE[@]+"${CP_ROLE[@]}"}") s_cmd=("${CP_CMD[@]+"${CP_CMD[@]}"}") s_in=("${CP_IN[@]+"${CP_IN[@]}"}") s_to=("${CP_TO[@]+"${CP_TO[@]}"}")
  local -a s_tag=() s_pred=("${TDE_CW_PRED[@]+"${TDE_CW_PRED[@]}"}") got=()
  for ((i = 0; i < n; i++)); do s_tag[i]=${NF_TAG[$i]:-}; done
  local rc=0; cp_reset; TDE_CW_TODO=(); c_6_3 >/dev/null 2>&1 || rc=$?
  got=("${TDE_CW_TODO[@]+"${TDE_CW_TODO[@]}"}")
  CP_ROLE=("${s_role[@]+"${s_role[@]}"}"); CP_CMD=("${s_cmd[@]+"${s_cmd[@]}"}"); CP_IN=("${s_in[@]+"${s_in[@]}"}"); CP_TO=("${s_to[@]+"${s_to[@]}"}")
  NF_TAG=(); for ((i = 0; i < n; i++)); do NF_TAG[i]=${s_tag[$i]}; done
  TDE_CW_PRED=("${s_pred[@]+"${s_pred[@]}"}")
  [[ $rc -eq 0 ]] && return 0
  # only a missing auto-login file is left for orapki; anything else the re-check finds is reported, not hidden
  [[ $rc -eq 2 ]] && { bad "The TDE wallet could not be checked again after the copy: $NOW"; return 1; }
  if [[ ${#got[@]} -eq 0 || ${#TDE_TODO[@]} -gt 0 || $TDE_SQLNET -ne 0 ]]; then bad "The TDE wallet is still not right after the copy: $NOW"; return 1; fi
  if [[ "$(printf '%s\n' "${got[@]}" | sort -u)" != "$(printf '%s\n' "${TDE_CW_PRED[@]+"${TDE_CW_PRED[@]}"}" | sort -u)" ]]; then
    bad "After the copy, these folders have no usable auto-login keystore (cwallet.sso):"$'\n'"$(printf '  %s\n' "${got[@]}")"$'\n'"That is not what was shown before, so nothing more is done. Answer r to check again."
    return 1
  fi
  # a cwallet.sso that does not open here (LOCAL, made on another host or outdated) is kept aside, then made again
  for ((i = first; i < n; i++)); do
    t=${NF_TAG[$i]:-}; [[ "$t" == sso2:* ]] || continue
    [[ -f "${t#sso2:}/cwallet.sso" ]] || continue
    nf_exec "$i" || return 1
  done
  tde_make_autologin
}
tde_orapki_exec() {
  # entry $1 of the shown list (orapki wallet create, as $ORACLE_USER), the password $2 on its input: never in an
  # argument, a file, the log or on the screen ($3: another password to hide in its output). Output in RUN_OUT.
  local i=$1 rc=0
  say "${C_D}Running as $(cp_user "${CP_ROLE[$i]}"):${C_N} ${CP_CMD[$i]}  ->  (the keystore password)"
  RUN_OUT=$(printf '%s\n' "$2" | cp_role_run "${CP_ROLE[$i]}" timeout -k 30 "${CP_TO[$i]}" bash -c "${CP_CMD[$i]}" 2>&1) || rc=$?
  RUN_OUT=${RUN_OUT//"$2"/*****}; [[ -n "${3:-}" ]] && RUN_OUT=${RUN_OUT//"$3"/*****}
  { printf 'as %s: ' "$(cp_user "${CP_ROLE[$i]}")"; cp_entry_text "$i"; printf -- '--- output ---\n%s\n(exit code %s)\n' "$RUN_OUT" "$rc"; } | log_block "RUN"
  return "$rc"
}
TDE_CW_TODO=()
tde_make_autologin() {
  # the orapki entries of the shown list: cwallet.sso for each folder. One password question for all of them;
  # if orapki does not take it, the command is shown. Every folder is tried (one failure does not stop the
  # others); the result is the files that exist at the end
  local i d out failed=0 dirs=() idx=()
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    [[ "${NF_TAG[$i]:-}" == orapki:* ]] && { idx+=("$i"); dirs+=("${NF_TAG[$i]#orapki:}"); }
  done
  [[ ${#idx[@]} -gt 0 ]] || return 0
  ask_secret "TDE keystore password (the wallet password of the primary; one password for: ${dirs[*]})"
  local pw=$SECRET; SECRET=""
  for i in "${idx[@]}"; do
    d=${NF_TAG[$i]#orapki:}
    tde_orapki_exec "$i" "$pw" || true; out=$RUN_OUT
    # a folder whose keystore has another password (a PDB keystore in isolated mode): asked once more, for it only
    # only a wrong password (PKI-02002 / "incorrect"), not a missing or unreadable wallet, earns a second question
    if [[ ! -f "$d/cwallet.sso" ]] && runuser -u "$ORACLE_USER" -- test -r "$d/ewallet.p12" && grep -qiE 'PKI-02002|incorrect' <<< "$out" && ! grep -qiE 'PKI-0200[3-9]|not found|no such|permission' <<< "$out"; then
      warn "The password did not open the keystore in $d. It may have its own password."
      ask_secret "TDE keystore password for $d only"
      local pw2=$SECRET; SECRET=""
      tde_orapki_exec "$i" "$pw2" "$pw" || true; out=$RUN_OUT; pw2=""
    fi
    if [[ -f "$d/cwallet.sso" ]]; then
      say "Made $d/cwallet.sso"; journal_file_written "$d/cwallet.sso" 0
    else
      failed=1; bad "orapki did not make $d/cwallet.sso: $(grep -m1 -iE 'PKI-|error|incorrect' <<< "$out")"
      { printf 'Run it by hand, as %s (orapki asks for the password):\n' "$ORACLE_USER"; orapki_plan "$d"; } | hint
    fi
  done
  pw=""; return $failed
}

phase_6() {
  phase_header 6 "Password file and TDE wallet"
  run_step 6.1 auto    "Password file orapw$STANDBY_SID" c_6_1 d_6_1
  run_step 6.2 primary "Remove the temporary copy on the primary" c_6_2
  run_step 6.3 auto    "TDE wallet (only if the primary uses TDE)" c_6_3 d_6_3
}
