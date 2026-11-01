#------------------------------------------------------------------------------
# PHASE 3  Oracle software on the standby
#   Grid (Oracle Restart) only when the primary uses ASM. Database software always.
#   Works with: image media (12.2+ Grid, 18c+ DB), staged media (12.1 Grid, 12.x DB,
#   may be several zip files) and gold images made on the primary (same patches).
#   Response files are made from the template shipped in the media.
#------------------------------------------------------------------------------
GSTATE=""; GSTATE_OUT=""; DSTATE=""; DB_EDITION=""; DATA_FREE_MB=0

inventory_dir() {
  local loc=""
  [[ -f /etc/oraInst.loc ]] && loc=$(grep -E '^inventory_loc=' /etc/oraInst.loc | head -n 1 | cut -d= -f2-)
  printf '%s' "${loc:-$INVENTORY_DIR}"
}
in_inventory() {
  local inv; inv="$(inventory_dir)/ContentsXML/inventory.xml"
  [[ -f "$inv" ]] && grep -q "LOC=\"$1\"" "$inv" && ! grep -q "LOC=\"$1\"[^>]*REMOVED=\"T\"" "$inv"
}
grp_or() {
  # first group of the list that exists on this server
  local g
  for g in "$@"; do [[ -n "$g" ]] && getent group "$g" >/dev/null 2>&1 && { printf '%s' "$g"; return 0; }; done
  printf '%s' "$INSTALL_GROUP"
}

#------------------------------------------------------------------------------
# Media (installer zip files)
#------------------------------------------------------------------------------
ZIP_DIRS=(/stage /software /install /tmp /root /home /opt /u01 /mnt /media)
media_kind() {
  # $1 zip -> grid_image | grid_staged | db_image | db_staged | db_staged_part | grid_staged_part | other
  local l; l=$(unzip -Z1 "$1" 2>/dev/null)
  if grep -qx 'gridSetup.sh' <<< "$l"; then printf 'grid_image'
  elif grep -qx 'grid/runInstaller' <<< "$l"; then printf 'grid_staged'
  elif grep -qx 'runInstaller' <<< "$l" && grep -q '^install/response/' <<< "$l"; then printf 'db_image'
  elif grep -qx 'database/runInstaller' <<< "$l"; then printf 'db_staged'
  elif grep -q '^database/stage/' <<< "$l"; then printf 'db_staged_part'
  elif grep -q '^grid/stage/' <<< "$l"; then printf 'grid_staged_part'
  else printf 'other'; fi
}
media_major() {
  # release from the Oracle file name: 12102 -> 12.1, 12201 -> 12.2, 193000 -> 19; for a 12.x zip from
  # edelivery (V12345-01.zip) from products.xml inside it; empty if unknown (gold image)
  local b; b=$(basename "$1")
  if [[ "$b" =~ (LINUX\.X64|linuxx64|linuxamd64)_([0-9]{5,6}) ]]; then
    local d=${BASH_REMATCH[2]}
    if [[ "$d" == 12* ]]; then printf '12.%s' "${d:2:1}"; else printf '%s' "${d:0:2}"; fi
    return 0
  fi
  local px v=""; px=$(unzip -Z1 "$1" 2>/dev/null | grep -m1 -E '^(database|grid)/stage/products\.xml$')
  if [[ -n "$px" ]]; then
    # OUI writes the release as VER="..." (older files VERSION="...")
    v=$(unzip -p "$1" "$px" 2>/dev/null | grep -oE 'NAME="oracle\.(server|crs)" VER(SION)?="1[0-9]\.[0-9]+' | head -n 1 | grep -oE '[0-9]+\.[0-9]+$')
    # older files: the first release attribute of the file
    [[ -n "$v" ]] || v=$(unzip -p "$1" "$px" 2>/dev/null | grep -oE ' VER(SION)?="1[0-9]\.[0-9]+' | head -n 1 | grep -oE '[0-9]+\.[0-9]+$')
  else
    # an image zip (also from edelivery, V982063-01.zip) has its inventory inside
    # VER directly after NAME (the same tag also has REP_VER, ACT_INST_VER, DEINST_VER)
    v=$(unzip -p "$1" inventory/ContentsXML/comps.xml 2>/dev/null | grep -oE 'NAME="oracle\.(server|crs)" VER="[0-9]+\.[0-9]+' | head -n 1 | grep -oE '[0-9]+\.[0-9]+$')
  fi
  case "$v" in 12.*) printf '%s' "$v" ;; 1[89].*|2[0-9].*) printf '%s' "${v%%.*}" ;; esac
  return 0
}
media_is_gold() {
  # a gold image made on the primary: neither an Oracle download name (LINUX.X64_193000_...) nor an edelivery name (V982063-01.zip)
  local b; b=$(basename "$1")
  [[ ! "$b" =~ (LINUX\.X64|linuxx64|linuxamd64)_[0-9]{5,6} && ! "$b" =~ ^[Vp][0-9]+(-[0-9]+|_.*)?\.zip$ ]]
}
want_rel() {
  # release the media must have: $1 = db (default) or grid (Grid may be newer than the database)
  if [[ "${1:-db}" == "grid" && -n "$GRID_REL" ]]; then printf '%s' "$GRID_REL"; return; fi
  if [[ "$DB_MAJOR" == "12" ]]; then printf '%s' "${PRIMARY_VERSION:0:4}"; else printf '%s' "$DB_MAJOR"; fi
}
rel_major() { printf '%s' "${1%%.*}"; }
media_trusted() {
  # an installer runs as oracle/grid and its root.sh as root: only files that root, oracle or grid own
  # and that nobody else can change are used
  local f=$1 u m
  u=$(stat -c '%U' -- "$f" 2>/dev/null); m=$(stat -c '%a' -- "$f" 2>/dev/null)
  [[ "$u" == "root" || "$u" == "$ORACLE_USER" || "$u" == "$GRID_USER" ]] || return 1
  [[ "$m" =~ ^[0-7]+$ ]] || return 1
  (( (8#${m: -2:1} & 2) == 0 && (8#${m: -1} & 2) == 0 ))
}
MEDIA_SCAN=""; MEDIA_REFUSED=""
scan_media() {
  # MEDIA_SCAN lines: kind|release|size|path   (only usable zip files)
  local d f k
  MEDIA_SCAN=""; MEDIA_REFUSED=""
  for d in "${ZIP_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -f "$f" && ! -L "$f" ]] && v_path "$f" || continue
      k=$(media_kind "$f"); [[ "$k" == "other" ]] && continue
      if ! media_trusted "$f"; then MEDIA_REFUSED+="$f (owner $(stat -c '%U' -- "$f"), mode $(stat -c '%a' -- "$f"))"$'\n'; continue; fi
      MEDIA_SCAN+="$k|$(media_major "$f")|$(du -h "$f" | cut -f1)|$f"$'\n'
    done < <(find "$d" -maxdepth 3 -type f -name '*.zip' 2>/dev/null)
  done
  MEDIA_SCAN=$(sort -u <<< "$MEDIA_SCAN" | grep -v '^$')
}
media_desc() { local f; IFS=',' read -ra _md <<< "$1"; for f in "${_md[@]}"; do printf '%s (%s, owner %s)  ' "$f" "$(du -h -- "$f" | cut -f1)" "$(stat -c '%U' -- "$f")"; done; }
pick_media() {
  # $1 = grid | db : prints the comma list of files for one installation (staged media may be 2 files)
  local want=$1 k mj f img="" stg="" parts="" allparts="" wr; wr=$(want_rel "$want")
  local imgu=""
  while IFS='|' read -r k mj _ f; do
    # the second zip of a staged pair has no release of its own: it is matched to the first by its name below
    [[ "$k" == "${want}_staged_part" ]] && { allparts+="$f"$'\n'; continue; }
    [[ -n "$mj" && "$mj" != "$wr" ]] && continue
    [[ -z "$mj" && "$k" == *_staged ]] && continue
    case "$k" in
      # an image whose release could not be read (a gold image) is only a last choice
      "${want}_image")  if [[ -n "$mj" ]]; then [[ -z "$img" ]] && img=$f; else [[ -z "$imgu" ]] && imgu=$f; fi ;;
      "${want}_staged") [[ -z "$stg" ]] && stg=$f ;;
    esac
  done <<< "$MEDIA_SCAN"
  # 12.1 databases exist only as staged media; elsewhere an unknown-release image is used when nothing better is there
  [[ -z "$img" && -z "$stg" && "$wr" != "12.1" ]] && img=$imgu
  if [[ -n "$stg" ]]; then
    local pre=${stg%_[0-9]of[0-9].zip}
    while IFS= read -r f; do [[ -n "$f" && "${f%_[0-9]of[0-9].zip}" == "$pre" && "$f" != "$stg" ]] && parts+=",$f"; done <<< "$allparts"
  fi
  if [[ -n "$img" ]]; then printf '%s' "$img"
  elif [[ -n "$stg" ]]; then
    # the first zip of a pair without its second one cannot be installed
    if [[ "$stg" == *_1of[2-9].zip && -z "$parts" ]]; then printf 'MISSING:%s' "${stg%_1of*}_2of${stg##*_1of}"; return 0; fi
    printf '%s%s' "$stg" "$parts"
  fi
}
media_ok() {
  # $1 comma list -> every file exists and may be used
  local f; IFS=',' read -ra _mf <<< "$1"
  [[ ${#_mf[@]} -gt 0 ]] || return 1
  for f in "${_mf[@]}"; do [[ -f "$f" ]] && media_trusted "$f" || return 1; done
}
media_matches() {
  # $1 comma list, $2 grid | db -> the first file is an installer of that kind and of the release needed
  # (a gold image whose release cannot be read is accepted, as in the scan)
  # (the main file of a staged pair may be listed second: _2of2 first)
  local f k mj; IFS=',' read -ra _mm <<< "$1"
  for f in "${_mm[@]}"; do
    k=$(media_kind "$f")
    [[ "$k" == "${2}_image" || "$k" == "${2}_staged" ]] || continue
    mj=$(media_major "$f")
    [[ -z "$mj" || "$mj" == "$(want_rel "$2")" ]] && return 0
  done
  return 1
}
media_is_staged() { local k; k=$(media_kind "${1%%,*}"); [[ "$k" == *_staged ]]; }

# ---- 3.1 installer files ----
F_GRID=""; F_DB=""
c_3_1() {
  users_ok || { NOW="The Oracle users do not exist yet (step 2.2)"; return 2; }
  local need_g=0 need_d=0
  if use_grid; then grid_state; [[ "$GSTATE" == "NEED_UNZIP" ]] && need_g=1; fi
  db_state; [[ "$DSTATE" == "NEED_UNZIP" ]] && need_d=1
  if [[ $need_g -eq 0 && $need_d -eq 0 ]]; then NOW="Not needed: the software is already unpacked or installed"; return 0; fi
  # files already named in the settings are checked like found ones: right kind (Grid / database) and release
  if { [[ $need_g -eq 0 ]] || { media_ok "$GRID_MEDIA" && media_matches "$GRID_MEDIA" grid; }; } \
     && { [[ $need_d -eq 0 ]] || { media_ok "$DB_MEDIA" && media_matches "$DB_MEDIA" db; }; }; then
    NOW="Installer files are known"
    [[ -n "$GRID_MEDIA" ]] && NOW+=$'\n'"Grid:      $GRID_MEDIA"
    [[ -n "$DB_MEDIA" ]] && NOW+=$'\n'"Database:  $DB_MEDIA"
    return 0
  fi
  [[ $need_g -eq 1 && -n "$GRID_MEDIA" ]] && media_ok "$GRID_MEDIA" && ! media_matches "$GRID_MEDIA" grid && warn "GRID_MEDIA ($GRID_MEDIA) is not a Grid $(want_rel grid) installer. The folders are searched instead."
  [[ $need_d -eq 1 && -n "$DB_MEDIA" ]] && media_ok "$DB_MEDIA" && ! media_matches "$DB_MEDIA" db && warn "DB_MEDIA ($DB_MEDIA) is not a database $(want_rel) installer. The folders are searched instead."
  scan_media
  F_GRID=""; F_DB=""
  [[ $need_g -eq 1 ]] && F_GRID=$(pick_media grid)
  [[ $need_d -eq 1 ]] && F_DB=$(pick_media db)
  # the first file of a staged pair without the second one
  local miss2=""
  [[ "$F_GRID" == MISSING:* ]] && { miss2+=" ${F_GRID#MISSING:}"; F_GRID=""; }
  [[ "$F_DB" == MISSING:* ]] && { miss2+=" ${F_DB#MISSING:}"; F_DB=""; }
  if [[ -n "$miss2" ]]; then
    NOW="The second installer file is missing:$miss2"$'\n'"It must be in the same folder as the first file."
    KIND_NOW=manual; MANUAL_HOW="root"; PLAN="-- Copy$miss2 next to the first file (owner root, mode 644). Then answer r."
    return 1
  fi
  if [[ ( $need_g -eq 1 && -z "$F_GRID" ) || ( $need_d -eq 1 && -z "$F_DB" ) ]]; then
    NOW="No installer files found for:$([[ $need_g -eq 1 && -z "$F_GRID" ]] && printf ' Grid %s' "$(want_rel grid)")$([[ $need_d -eq 1 && -z "$F_DB" ]] && printf ' database %s' "$(want_rel)")"
    NOW+=$'\n'"Searched in: ${ZIP_DIRS[*]}"
    [[ -n "$MEDIA_REFUSED" ]] && NOW+=$'\n'"Not used, because of their owner or mode:"$'\n'"${MEDIA_REFUSED%$'\n'}"
    KIND_NOW=manual; MANUAL_HOW="the user named on each line"; MANUAL_WHERE="Run on the PRIMARY ($PRIMARY_HOST) and on this server ($(hostname -s))"
    local wg=""; [[ $need_g -eq 1 ]] && wg=" and grid"
    PLAN="-- Copy the files to /stage on this server (owner root, mode 644). Then answer r."
    if [[ $DB_MAJOR -ge 18 ]]; then
      PLAN+=$'\n'"-- Use one of these:"
      PLAN+=$'\n'"-- A) A gold image of the primary home, with the same patches. On the primary:"
      [[ $need_d -eq 1 ]] && PLAN+=$'\n'"     as $ORACLE_USER:  mkdir -p /tmp/gold && $DB_HOME/runInstaller -silent -createGoldImage -destinationLocation /tmp/gold"
      [[ $need_g -eq 1 ]] && PLAN+=$'\n'"     as $GRID_USER:  mkdir -p /tmp/gold && $GRID_HOME/gridSetup.sh -silent -createGoldImage -destinationLocation /tmp/gold"
      PLAN+=$'\n'"   Then on this server, as root:  mkdir -p /stage && scp $PRIMARY_SSH_USER@$PRIMARY_IP:/tmp/gold/*.zip /stage/ && chmod 644 /stage/*.zip"
      PLAN+=$'\n'"-- B) The base installation files of release $DB_MAJOR."
      PLAN+=$'\n'"--    Step 3.11 then asks you to apply the same patches as on the primary."
    else
      PLAN+=$'\n'"-- The base installation files of release $(want_rel)."
      PLAN+=$'\n'"-- Step 3.11 then asks you to apply the same patches as on the primary."
    fi
    [[ $need_d -eq 1 ]] && PLAN+=$'\n'"     database: $(base_media_name db "$(want_rel)")"
    [[ $need_g -eq 1 ]] && PLAN+=$'\n'"     grid:     $(base_media_name grid "$(want_rel grid)")"
    return 1
  fi
  NOW="Installer files found"
  PLAN="Use these installer files:"
  [[ $need_g -eq 1 ]] && PLAN+=$'\n'"  Grid:      $(media_desc "$F_GRID")"
  [[ $need_d -eq 1 ]] && PLAN+=$'\n'"  Database:  $(media_desc "$F_DB")"
  PLAN+=$'\n'"Save them in $SETTINGS_FILE"
  USING="Files of another release than $(want_rel) are ignored."$'\n'"A gold image must come from the primary."
  # base media + a patched primary: say it now, not after two hours of installing
  local pp; pp=$(primary_patches "$DB_HOME" 2>/dev/null | head -n 3 | paste -sd' ' -)
  if [[ -n "$pp" && -z "$RU_DIR" ]] && media_is_gold "${F_DB:-${F_GRID:-}}"; then :   # gold image: same patches
  elif [[ -n "$pp" && -z "$RU_DIR" ]]; then
    USING+=$'\n'"The primary has patches ($pp ...). These base files do not have them."
    USING+=$'\n'"Step 3.11 then asks you to apply them by hand (opatchauto, about an hour)."
    USING+=$'\n'"Faster: unzip the primary's Release Update on this server now and set RU_DIR"
    USING+=$'\n'"and OPATCH_ZIP in the settings. The installer then applies it."
    USING+=$'\n'"To do that: answer q, run $SELF --settings and choose e."
  fi
  [[ -n "$MEDIA_REFUSED" ]] && USING+=$'\n'"Not used, because of owner or mode: ${MEDIA_REFUSED//$'\n'/ }"
  return 1
}
base_media_name() {
  # $1 db|grid, $2 release -> file names of the base installation media
  case "$1:$2" in
    db:12.1)   printf 'linuxamd64_12102_database_1of2.zip + linuxamd64_12102_database_2of2.zip' ;;
    grid:12.1) printf 'linuxamd64_12102_grid_1of2.zip + linuxamd64_12102_grid_2of2.zip' ;;
    db:12.2)   printf 'linuxx64_12201_database.zip' ;;
    grid:12.2) printf 'linuxx64_12201_grid_home.zip' ;;
    db:18|db:19|db:21) printf 'LINUX.X64_%s000_db_home.zip' "$2$([[ $2 == 18 ]] && printf 0 || printf 3)" ;;
    grid:18|grid:19|grid:21) printf 'LINUX.X64_%s000_grid_home.zip' "$2$([[ $2 == 18 ]] && printf 0 || printf 3)" ;;
    *) printf 'the %s %s home zip file from edelivery.oracle.com' "$2" "$1" ;;
  esac
}
d_3_1() { [[ -n "$F_GRID" ]] && GRID_MEDIA=$F_GRID; [[ -n "$F_DB" ]] && DB_MEDIA=$F_DB; save_settings; }

#------------------------------------------------------------------------------
# Response files: copy the template from the media, set only the keys it has
#------------------------------------------------------------------------------
RSP=""; RSP_MISSING=""
secure_rsp() {
  # $1 name. Sets RSP: a file in a new private folder (root-owned while it is written).
  local d
  d=$(mktemp -d /tmp/dg_rsp.XXXXXXXX) || return 1
  RSP="$d/$1"
  CLEANUP_FILES+=("$RSP")
}
finish_rsp() {
  local d; d=$(dirname "$1")
  chown "$2:$INSTALL_GROUP" "$1" && chmod 600 "$1" && chown "$2:$INSTALL_GROUP" "$d" && chmod 700 "$d"
}
remove_rsp() { [[ -n "$1" ]] && rm -f -- "$1" && rmdir -- "$(dirname "$1")" 2>/dev/null; return 0; }
rsp_set() {
  # $1 file, $2 value, $3.. key names (the first one that exists in the template is set).
  # Only a real (uncommented) key line is replaced: the Oracle templates carry commented example lines
  # ("#  oracle.install.asm.diskGroup.disks=/oracle/asm/disk1,...") before the real key, and a Java
  # properties reader takes the LAST line of a key, so a replaced example line would be ignored.
  local f=$1 v=$2 k; shift 2
  for k in "$@"; do
    # the same plain-text test as the replacement (no regular expression: the dots in the keys stay dots)
    if DG_K=$k awk 'BEGIN{k=ENVIRON["DG_K"]} { t=$0; sub(/^[[:space:]]*/, "", t); if (index(t, k "=") == 1) f=1 } END { exit !f }' "$f"; then
      local rc=0
      ( umask 077; DG_K=$k DG_V=$v awk 'BEGIN{k=ENVIRON["DG_K"]; v=ENVIRON["DG_V"]}
        { t=$0; sub(/^[[:space:]]*/, "", t)
          if (index(t, k "=") == 1) { print k "=" v; next } print }' "$f" > "$f.new" ) && cat "$f.new" > "$f" || rc=1
      rm -f -- "$f.new"          # it may hold a password: never left behind
      return $rc
    fi
  done
  return 1
}
rsp_need() { rsp_set "$@" || RSP_MISSING+=" $3"; }       # a key the installation cannot work without
make_rsp() {
  # $1 template, $2 owner. Copies the template into a private file (RSP).
  local tpl=$1 name; name=$(basename "$tpl")
  RSP_TEMPLATE=$tpl
  [[ -f "$tpl" ]] || { bad "The response file template is not in the media: $tpl"; return 1; }
  secure_rsp "$name" || return 1
  ( umask 077; set -C; cat "$tpl" > "$RSP" ) || return 1
  RSP_MISSING=""
}
ver_lt() {
  # 0 when version $1 is lower than $2 (dotted numbers)
  [[ "$1" == "$2" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | head -n 1)" == "$1" ]]
}
RSP_TEMPLATE=""
rsp_review() {
  # after setting the keys: log them (passwords masked) and stop if a needed key is missing
  grep -vE '^[[:space:]]*(#|$)' "$RSP" | log_block "response file $RSP (template from the media)"
  local dup; dup=$(grep -vE '^[[:space:]]*(#|$)' "$RSP" | cut -d= -f1 | tr -d ' ' | sort | uniq -d | paste -sd' ' -)
  [[ -n "$dup" ]] && { bad "The response file has a key twice: $dup
The installer would read only the last one. Fix the template so that each key
is in it once, as an uncommented key= line: $RSP_TEMPLATE"; return 1; }
  if [[ -n "$RSP_MISSING" ]]; then
    bad "The response file template of this media lacks these keys:$RSP_MISSING"
    printf 'This media is newer or older than the script expects. Either install this software\nyourself (h shows the installer choices), or add the missing keys to the template\nas uncommented key= lines and run the step again. The template:\n  %s\n' "$RSP_TEMPLATE" | hint
    return 1
  fi
}

#------------------------------------------------------------------------------
# Installer helpers
#------------------------------------------------------------------------------
ask_asm_password() {
  [[ -n "$ASM_PW" ]] && return 0
  local tries=0 p1
  while [[ $tries -lt 3 ]]; do
    tries=$((tries + 1))
    if [[ -n "$ENV_ASM_PW" ]]; then SECRET=$ENV_ASM_PW; ENV_ASM_PW=""; say "Using the ASM password from DG_ASM_PASSWORD."
    else
      ask_secret "New ASM password for SYS and ASMSNMP (8-30 characters, upper and lower case, a digit)"
      p1=$SECRET
      ask_secret "Type it again"
      [[ "$p1" == "$SECRET" ]] || { SECRET=""; bad "The two passwords are not the same. Type them again."; continue; }
    fi
    p1=$SECRET; SECRET=""
    if [[ ${#p1} -lt 8 || ${#p1} -gt 30 || ! "$p1" =~ [A-Z] || ! "$p1" =~ [a-z] || ! "$p1" =~ [0-9] || "$p1" =~ [[:space:]\"\'@/\\\&\$\`] ]]; then
      bad "The password needs 8-30 characters, upper and lower case letters and a digit.
It must not contain a space, a quote, @ / & \$ \` or a backslash."; continue
    fi
    ASM_PW=$p1
    ok "ASM password set. It is kept only in memory and in a temporary response file."
    mask_pending
    return 0
  done
  return 1
}

INS08101_RETRIED=0
run_installer() {
  # $1 title, $2 runner (as_oracle | as_grid), $3 "ignore prerequisites" flag of this installer, rest = command.
  # Exit codes 0 and 6 are success. Offers one retry that ignores prerequisite failures.
  local title=$1 runner=$2 ign=$3; shift 3
  INS08101_RETRIED=0
  local who=oracle; [[ "$runner" == "as_grid" ]] && who=grid
  local out; out="$LOG_DIR/$(tr -c 'A-Za-z0-9\n' '_' <<< "$title" | tr -s '_' | tr -d '\n')_$RUN_ID.log"
  say "Starting the $title. It runs silently and takes several minutes."
  local rc=0 keep=$JOB_KEEP
  run_long "$title" "$out" "" "$who" "$@" < /dev/null || rc=$?
  if [[ $rc -eq 0 || $rc -eq 6 ]]; then [[ $rc -eq 6 ]] && warn "$title finished with warnings. Output: $out"; installer_done_record "$title"; return 0; fi
  bad "$title failed (exit code $rc)"
  grep -E 'INS-[0-9]+|PRVF-|PRVG-|PRCZ-|\[FATAL\]|\[WARNING\]|SEVERE' <<< "$RUN_OUT" | head -n 15 | hint
  grep -oE '(/[A-Za-z0-9_./-]+/(logs|cfgtoollogs)/[A-Za-z0-9_./-]+\.log)' <<< "$RUN_OUT" | sort -u | head -n 3 | sed 's/^/Installer log: /' | hint
  # the retries below never apply a Release Update a second time (the failed try may have applied it already)
  local -a args=("$@"); local home; home=$([[ "$who" == "grid" ]] && printf '%s' "$GRID_HOME" || printf '%s' "$DB_HOME")
  if ru_applied "$home"; then
    local -a a2=(); local i=0
    while [[ $i -lt ${#args[@]} ]]; do
      if [[ "${args[$i]}" == "-applyRU" || "${args[$i]}" == "-applyPSU" ]]; then i=$((i + 2)); continue; fi
      a2+=("${args[$i]}"); i=$((i + 1))
    done
    args=("${a2[@]}"); say "The Release Update is already in $home. A retry does not apply it again."
  fi
  if grep -qE 'INS-32035|INS-32039' <<< "$RUN_OUT"; then
    if [[ ! -f /etc/oraInst.loc ]]; then
      printf 'Cause: /etc/oraInst.loc is missing, so the installer tried to create a new inventory in a
folder that already has files (%s).
' "$INVENTORY_DIR" | hint
      if [[ "$who" == grid ]]; then printf 'Fix: answer r. The step then moves the files of the earlier attempt aside
(nothing is deleted) and starts the installer again.
' | hint
      elif use_grid; then printf 'Fix: finish Grid first. Its root scripts (step 3.3) create /etc/oraInst.loc.
Answer q, then run the script again: it continues with the Grid steps.
' | hint
      else printf 'Fix: answer q and run the script again: step 3.6 then shows what to do with that folder.
' | hint; fi
    else
      printf 'Cause: the installer user cannot write to the inventory %s.
Its group must be %s with write access for the group (mode 770).
' "$(inventory_dir)" "$INSTALL_GROUP" | hint
    fi
    return 1
  fi
  if grep -q 'INS-08101' <<< "$RUN_OUT"; then
    local did; did=$([[ ${OS_MAJOR:-0} -ge 9 ]] && printf 'OL8' || printf 'OEL7.8')
    if [[ "${INS08101_RETRIED:-0}" -eq 0 ]] && [[ " ${ORA_ENV[*]} ${GRID_ENV[*]} " != *" CV_ASSUME_DISTID=$did "* ]]; then
      INS08101_RETRIED=1
      say "INS-08101: this installer does not know Oracle Linux $OS_MAJOR."
      say "Trying again with CV_ASSUME_DISTID=$did, the usual workaround."
      local -a saved_o=("${ORA_ENV[@]}") saved_g=("${GRID_ENV[@]}")
      ORA_ENV+=("CV_ASSUME_DISTID=$did"); GRID_ENV+=("CV_ASSUME_DISTID=$did")
      rc=0; JOB_KEEP=$keep
      run_long "$title (CV_ASSUME_DISTID=$did)" "${out%.log}_distid.log" "" "$who" "${args[@]}" < /dev/null || rc=$?
      if grep -q 'INS-08101' <<< "$RUN_OUT" || ! { [[ $rc -eq 0 || $rc -eq 6 ]] || grep -qE 'INS-13013|INS-13014|INS-13016|PRVF-|PRVG-' <<< "$RUN_OUT"; }; then
        # kept only when the installer got past the OS check (it finished, or it reached the prerequisite checks)
        ORA_ENV=("${saved_o[@]}"); GRID_ENV=("${saved_g[@]}")
      else
        # the OS check passed with it: kept for the retries below, for 3.4 and for later runs
        install -d -m 700 "$STATE_DIR"; printf '%s\n' "$did" > "$STATE_DIR/distid"; chmod 600 "$STATE_DIR/distid"
        _log INFO "CV_ASSUME_DISTID=$did kept (saved in $STATE_DIR/distid)"
      fi
      if [[ $rc -eq 0 || $rc -eq 6 ]]; then warn "$title finished, with CV_ASSUME_DISTID=$did."; installer_done_record "$title"; return 0; fi
      bad "$title failed again (exit code $rc)"; grep -E 'INS-[0-9]+|\[FATAL\]|SEVERE' <<< "$RUN_OUT" | head -n 10 | hint
    fi
    printf 'INS-08101: this installer does not know this Oracle Linux release.\nUse a newer Release Update: unzip it on this server, then set RU_DIR=<folder>\nand OPATCH_ZIP in the settings:\n  %s --settings   (choose e)\nThen run the script again.\n' "$SELF" | hint
  fi
  if [[ -n "$ign" ]] && grep -qE 'INS-13013|INS-13014|INS-13016|PRVF-|PRVG-' <<< "$RUN_OUT"; then
    printf 'Some prerequisite checks failed (see the lines above). Fix them if you can.\n' | hint
    if confirm_word "Retry and ignore the failed prerequisite checks" "IGNORE"; then
      rc=0
      JOB_KEEP=$keep
      ru_applied "$home" && { local -a a3=(); local j=0; while [[ $j -lt ${#args[@]} ]]; do if [[ "${args[$j]}" == "-applyRU" || "${args[$j]}" == "-applyPSU" ]]; then j=$((j + 2)); continue; fi; a3+=("${args[$j]}"); j=$((j + 1)); done; args=("${a3[@]}"); }
      run_long "$title (ignore prereq)" "${out%.log}_2.log" "" "$who" "${args[@]}" "$ign" < /dev/null || rc=$?
      if [[ $rc -eq 0 || $rc -eq 6 ]]; then warn "$title finished. Failed prerequisite checks were ignored."; installer_done_record "$title"; return 0; fi
      bad "$title failed again (exit code $rc)"
      grep -E 'INS-[0-9]+|\[FATAL\]|SEVERE' <<< "$RUN_OUT" | head -n 10 | hint
    fi
  fi
  return 1
}

ru_applied() {
  # 0 when a patch of RU_DIR (its numbered folders) is already registered in the home $1
  [[ -n "${RU_DIR:-}" && -d "$RU_DIR" && -d "$1/inventory/oneoffs" ]] || return 1
  local d id
  for d in "$RU_DIR" "$RU_DIR"/*/; do
    id=$(basename "$d"); [[ "$id" =~ ^[0-9]{6,}$ ]] || continue
    [[ -d "$1/inventory/oneoffs/$id" ]] && return 0
  done
  return 1
}
installer_done_record() {
  # a success record per installer (the inventory alone does not prove that the installer finished)
  install -d -m 700 "$STATE_DIR"
  case "$1" in
    "Grid installer"*)            : > "$STATE_DIR/grid_install.done"; journal SOFTWARE "$GRID_HOME" "Grid Infrastructure (software only)" ;;
    "Grid configuration tools"*)  : > "$STATE_DIR/grid_config.done";  journal ASMINST "$DATA_DG" "ASM instance, +$DATA_DG and the listener" ;;
    "Database installer"*)        : > "$STATE_DIR/db_install.done";   journal SOFTWARE "$DB_HOME" "Database software (software only)" ;;
  esac
  return 0
}
run_root_script() {
  # root scripts get no input: their questions (local bin folder, TFA) take the default answer
  [[ -x "$1" ]] || { bad "Root script not found: $1"; return 1; }
  local out; out="$LOG_DIR/root_$(basename "$(dirname "$1")")_$(basename "$1" .sh)_$RUN_ID.log"
  if run_long "root script $1" "$out" "" root "$1" < /dev/null; then say "$1 finished without error."; return 0; fi
  bad "$1 failed. The last lines of its output:"; printf '%s\n' "$RUN_OUT" | tail -n 15 | hint
  return 1
}
ru_args() {
  # with RU_DIR the image installer (gridSetup.sh, 18c+ runInstaller) applies that Release Update first
  # ($1 = grid: 12.2 gridSetup.sh calls the option -applyPSU)
  [[ -n "$RU_DIR" && -d "$RU_DIR" ]] || return 0
  # a home that already has the Release Update (an earlier try applied it) does not get it again
  local h; [[ "${1:-}" == "grid" ]] && h=$GRID_HOME || h=$DB_HOME
  if ru_applied "$h"; then say "The Release Update is already in $h. It is not applied again." >&2; return 0; fi
  if [[ "${1:-}" == "grid" && "$(want_rel grid)" == "12.2" ]]; then printf '%s\n' -applyPSU "$RU_DIR"
  else printf '%s\n' -applyRU "$RU_DIR"; fi
}
new_opatch() {
  # $1 home, $2 runner, $3 owner: the Release Update needs a newer OPatch than the base media has
  [[ -n "$RU_DIR" ]] || return 0
  [[ -n "$OPATCH_ZIP" && -f "$OPATCH_ZIP" ]] || { bad "RU_DIR is set, but OPATCH_ZIP is not. It must name the newest OPatch zip (p6880880).
Set it with:  $SELF --settings   (choose e)"; return 1; }
  media_trusted "$OPATCH_ZIP" || { bad "$OPATCH_ZIP is not used: its owner or mode is not safe.
The owner must be root, $ORACLE_USER or $GRID_USER, and only the owner may change it."; return 1; }

  # the old OPatch is kept next to it (no rm -rf of a part of a home)
  # the OPatch of the zip already in place (an earlier try): nothing to do
  local want_v have_v
  want_v=$(unzip -p "$OPATCH_ZIP" OPatch/version.txt 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)
  have_v=$(grep -oE '[0-9]+(\.[0-9]+)+' "$1/OPatch/version.txt" 2>/dev/null | head -n 1)
  if [[ -n "$want_v" && -n "$have_v" ]] && ! ver_lt "$have_v" "$want_v"; then say "$1/OPatch is already version $have_v. The zip has $want_v: nothing to do."; return 0; fi
  say "Replacing $1/OPatch with the one in $OPATCH_ZIP. The Release Update needs it."
  if [[ -e "$1/OPatch" && -e "$1/OPatch.bak_$RUN_ID" ]]; then
    # a retry in this run: the original is kept already; the half copy goes
    run_logged "remove the OPatch of the failed try" "$2" rm -rf -- "$1/OPatch" || { bad "Cannot remove $1/OPatch."; return 1; }
  elif [[ -e "$1/OPatch" ]]; then
    run_logged "keep old OPatch" "$2" mv -T -- "$1/OPatch" "$1/OPatch.bak_$RUN_ID" || { bad "Cannot move $1/OPatch aside."; return 1; }
    journal OPATCH "$1/OPatch" "old=$1/OPatch.bak_$RUN_ID"
  fi
  run_logged "unzip OPatch" "$2" unzip -q -o "$OPATCH_ZIP" -d "$1" || { bad "The unzip of OPatch failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  [[ -x "$1/OPatch/opatch" ]] || { bad "$1/OPatch/opatch is missing after the unzip. Is OPATCH_ZIP the right file?"; return 1; }
}

unzip_marker() { printf '%s/unzip_failed' "$STATE_DIR"; }
unzip_marker_clear() {
  # $1 output file of the unzip that worked: its line goes, and so do older lines of the same zip into the same folder
  [[ -f "$(unzip_marker)" ]] || return 0
  local t="" o="" dest="" ln
  ln=$(grep -F -- "|$1|" "$(unzip_marker)" | head -n 1) || true
  IFS='|' read -r t o dest <<< "$ln"
  if awk -F'|' -v o="$1" -v t="$t" -v d="$dest" '!($2 == o || (t != "" && $1 == t && $3 == d))' "$(unzip_marker)" > "$(unzip_marker).n"; then
    if [[ -s "$(unzip_marker).n" ]]; then cat "$(unzip_marker).n" > "$(unzip_marker)"; else rm -f -- "$(unzip_marker)"; fi
  fi
  rm -f -- "$(unzip_marker).n"
}
unzip_failed_check() {
  # $@ the folders of this software (home and stage folder). An unzip into one of them that did not end with
  # exit code 0 (failed, killed, reboot, closed terminal) leaves a half-filled folder: the installer must not
  # start from it. Lines of an older version have no folder: they count for every folder.
  # Returns 1 with NOW/PLAN set. SW_UNZIP_DIRS / SW_UNZIP_OUTS: what the do function empties and clears
  # (empty when the script must not do it itself: then KIND_NOW=manual).
  SW_UNZIP_DIRS=(); SW_UNZIP_OUTS=()
  [[ -f "$(unzip_marker)" ]] || return 0
  local t o dest list="" f hit rmcmd="" manual=0
  while IFS='|' read -r t o dest; do
    [[ -n "$t" ]] || continue
    hit=0; [[ -z "$dest" ]] && hit=1
    for f in "$@"; do [[ "$dest" == "$f" ]] && hit=1; done
    [[ $hit -eq 1 ]] || continue
    list+="  $t"$'\n'"    into ${dest:-the home or stage folder of that file}"$'\n'
    rmcmd+="grep -vF -- '|${o}|' '$(unzip_marker)' > '$(unzip_marker).n'; mv -f '$(unzip_marker).n' '$(unzip_marker)'"$'\n'
    # the script empties only a folder it knows, that no installed home uses
    if [[ -z "$dest" ]] || in_inventory "$dest" || ! sw_folder_ok "$dest"; then manual=1; fi
    SW_UNZIP_DIRS+=("$dest"); SW_UNZIP_OUTS+=("$o")
  done < "$(unzip_marker)"
  [[ -n "$list" ]] || return 0
  NOW="An earlier unzip did not finish. Its folder is incomplete:"$'\n'"${list%$'\n'}"
  if [[ $manual -eq 0 ]]; then
    PLAN="Empty that folder (nothing is installed there), then unpack the files again"
    return 1
  fi
  SW_UNZIP_DIRS=(); SW_UNZIP_OUTS=()
  KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
  PLAN="-- Empty the folder named above, and nothing else. First check that nothing is
-- installed there: it must not be listed in $INVENTORY_DIR/ContentsXML/inventory.xml.
-- Empty it (hidden files too):  find <folder> -mindepth 1 -delete
-- Then remove its line from the list of failed unzips:
${rmcmd%$'\n'}
-- Then answer r. The files are unpacked again."
  return 1
}
sw_folder_ok() {
  # $1 a software folder the script may empty: the Grid or database home of the settings, or one of their
  # stage folders; a plain path; no program of it runs
  local d=$1 o real fst
  [[ "$d" =~ ^/[A-Za-z0-9_./-]+$ && "$d" != *..* && "$d" != */ && "$d" != *//* ]] || return 1
  [[ "$d" == "$DB_HOME" || ( -n "$GRID_HOME" && "$d" == "$GRID_HOME" ) || "$d" == "$(stage_dir db)" || "$d" == "$(stage_dir grid)" ]] || return 1
  # at least three levels deep (/u01/app/x), not a link, and the same folder when every link is resolved
  [[ $(tr -cd '/' <<< "$d" | wc -c) -ge 3 && ! -L "$d" ]] || return 1
  real=$(readlink -f -- "$d" 2>/dev/null); [[ -z "$real" || "$real" == "$d" ]] || return 1
  # it must not hold (or be) another folder of the setup: base folders, inventory, the other home, database folders
  for o in "$ORACLE_BASE" "${GRID_BASE:-}" "$INVENTORY_DIR" "$DB_HOME" "${GRID_HOME:-}" $(fs_dirs 2>/dev/null); do
    [[ -n "$o" && "$o" != "$d" ]] || continue
    [[ "$o/" == "$d/"* ]] && return 1
  done
  # local storage only, and no other file system mounted inside it (rm -rf would go into it)
  fst=$(findmnt -n -o FSTYPE --target "$(existing_parent "$d")" 2>/dev/null | head -n 1)
  case "$fst" in nfs*|cifs|smb*|acfs|fuse*|glusterfs|ceph*|ocfs2|gfs2|"") return 1 ;; esac
  [[ -d "$d" ]] && findmnt -rn -o TARGET 2>/dev/null | grep -q "^$d/" && return 1
  sw_in_use "$d" && return 1
  return 0
}
sw_in_use() {
  # 0 when a running program comes from folder $1 (the program file of a process is inside it)
  local e r; r=$(readlink -f -- "$1" 2>/dev/null); r=${r:-$1}
  for e in /proc/[0-9]*/exe; do
    e=$(readlink -f -- "$e" 2>/dev/null) || continue
    [[ "$e" == "$1/"* || "$e" == "$r/"* ]] && return 0
  done
  return 1
}
sw_empty_folder() {
  # $1 folder (checked with sw_folder_ok). Everything in it goes, hidden files too; the folder itself and a
  # lost+found of a mount point stay.
  local d=$1
  sw_folder_ok "$d" || { bad "Not emptied: $d is not a software folder of this setup, or a program of it runs."; return 1; }
  [[ -d "$d" ]] || return 0
  find "$d" -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system -- {} + || return 1
  journal DELETED "$d" "cannot be undone: the content of this software folder was deleted (it is installed again)"
  say "Emptied $d"
  _log CHANGE "emptied the software folder $d"
  return 0
}
sw_unzip_fix() {
  # the do part of a failed unzip: empty the folders, then drop their lines from the list of failed unzips
  local i
  for i in "${!SW_UNZIP_DIRS[@]}"; do
    sw_empty_folder "${SW_UNZIP_DIRS[$i]}" || return 1
    grep -vF -- "|${SW_UNZIP_OUTS[$i]}|" "$(unzip_marker)" > "$(unzip_marker).n"
    if [[ -s "$(unzip_marker).n" ]]; then cat "$(unzip_marker).n" > "$(unzip_marker)"; else rm -f -- "$(unzip_marker)"; fi
    rm -f -- "$(unzip_marker).n"
  done
  return 0
}
inventory_mark_removed() {
  # $1 home: the way the Oracle installer detaches a home - its HOME entry gets REMOVED="T" (a backup is kept,
  # --undo puts the file back)
  local inv u tmp; inv="$(inventory_dir)/ContentsXML/inventory.xml"
  [[ -f "$inv" ]] || return 0
  in_inventory "$1" || return 0
  u=$(stat -c '%U' "$inv")
  backup_file "$inv" "$u" || return 1
  tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
  awk -v loc="LOC=\"$1\"" 'index($0, "<HOME ") && index($0, loc) && !index($0, "REMOVED=") { sub(/[[:space:]]*\/?>/, " REMOVED=\"T\"&") } { print }' "$inv" > "$tmp" || return 1
  grep -q "LOC=\"$1\"[^>]*REMOVED=\"T\"" "$tmp" || { bad "The HOME entry of $1 in $inv could not be marked."; return 1; }
  write_as "$u" "$inv" "$(stat -c '%a' "$inv")" < "$tmp" || return 1
  rm -f -- "$tmp"
  say "Marked $1 as removed in $inv"
  return 0
}
sw_half_fix() {
  # $1 home, $2 owner, $3 success record, $4 stage folder. Asks: record it as installed, or clean it.
  # Return: 0 = recorded (nothing more to do), 10 = cleaned (install now), 3 = not done
  local home=$1 owner=$2 rec=$3 stg=$4
  say "Its installer log: the newest file in $INVENTORY_DIR/logs"
  ask_choice "[m] I installed it myself, without error   [c] Clean it and install again   [s] Skip   [q] Quit" "mcsq"
  case "$ANSWER" in
    q) user_stop "Stopped by you" ;;
    s) return 3 ;;
    m) [[ -s "$home/bin/oracle" || -x "$home/bin/crsctl" ]] || { bad "The programs of $home are missing. Choose c to install it again."; return 1; }
       install -d -m 700 "$STATE_DIR"; : > "$rec"; say "Recorded: $home was installed without error."; return 0 ;;
  esac
  sw_folder_ok "$home" || { bad "$home cannot be cleaned by the script: a program of it runs, or it is not the home of the settings."; return 1; }
  if [[ -d "$home/dbs" ]] && ls "$home/dbs" 2>/dev/null | grep -qE '^(spfile|orapw).+'; then
    bad "$home/dbs has an spfile or a password file. A database used this home. It is not cleaned."; return 1
  fi
  # the installer files must be on this server BEFORE the home is emptied (else nothing could install it again)
  local kind=$5 mvar=DB_MEDIA f; [[ "$kind" == grid ]] && mvar=GRID_MEDIA
  if ! media_ok "${!mvar}"; then
    scan_media; f=$(pick_media "$kind")
    if [[ -z "$f" || "$f" == MISSING:* ]]; then
      bad "No installer files for $([[ "$kind" == grid ]] && printf 'Grid %s' "$(want_rel grid)" || printf 'the database %s' "$(want_rel)") were found on this server, so nothing was deleted."
      say "Put them in /stage (owner root, mode 644), then choose c again. Step 3.1 shows where to get them."
      return 1
    fi
    printf -v "$mvar" '%s' "$f"; save_settings; say "Installer files: $f"
  fi
  confirm_word "Everything in $home will be deleted, and it will be installed again." "CLEAN" || return 3
  inventory_mark_removed "$home" || return 1
  sw_empty_folder "$home" || return 1
  [[ -d "$stg" ]] && { sw_empty_folder "$stg" || return 1; }
  rm -f -- "$rec"
  return 10
}
stage_dir() { printf '%s/dg_stage_%s' "$(dirname "$INVENTORY_DIR")" "$1"; }   # for staged (12.x) media
unpack_media() {
  # $1 comma list of zip files, $2 target folder, $3 runner, $4 owner
  local files=$1 dest=$2 runner=$3 owner=$4 f
  [[ -d "$dest" ]] || make_dir "$dest" "$owner" || return 1
  IFS=',' read -ra _uz <<< "$files"
  for f in "${_uz[@]}"; do
    media_trusted "$f" || { bad "$f is not used: its owner or mode has changed."; return 1; }
    runuser -u "$owner" -- test -r "$f" || { bad "$owner cannot read $f. Fix it with:  chmod 644 $f"; return 1; }
    local who=oracle; [[ "$runner" == "as_grid" ]] && who=grid
    local uo="$LOG_DIR/unzip_$(basename "$f" .zip)_$RUN_ID.log"
    # the marker is written first and removed only when the unzip worked: any other end leaves it
    install -d -m 700 "$STATE_DIR"
    printf '%s|%s|%s\n' "unzip $(basename "$f")" "$uo" "$dest" >> "$(unzip_marker)" && chmod 600 "$(unzip_marker)" \
      || { bad "Cannot write $(unzip_marker). Is the disk full? The unzip was not started."; return 1; }
    run_long "unzip $(basename "$f")" "$uo" "" "$who" unzip -q -o "$f" -d "$dest" < /dev/null \
      || { bad "The unzip failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    unzip_marker_clear "$uo"
    journal UNZIP "$dest" "from $(basename "$f")"
  done
}

#------------------------------------------------------------------------------
# Grid
#------------------------------------------------------------------------------
GRID_ROOT_DONE_FILE() { printf '%s/grid_root.done' "$STATE_DIR"; }
grid_state() {
  # DONE | ASM_DOWN | HAS_DOWN | NEED_CONFIGTOOLS | NEED_ROOT | NEED_INSTALL | NEED_UNZIP | UNKNOWN
  GSTATE_OUT=""
  if ! users_ok; then GSTATE=NEED_UNZIP; return; fi
  if [[ -x "$GRID_HOME/bin/crsctl" ]]; then
    local has_on=0
    run_logged "crsctl check has" as_grid timeout 60 "$GRID_HOME/bin/crsctl" check has && grep -q 'CRS-4638' <<< "$RUN_OUT" && has_on=1
    if [[ $has_on -eq 1 ]]; then
      run_logged "crsctl stat res ora.asm" as_grid timeout 60 "$GRID_HOME/bin/crsctl" stat res ora.asm || true
      if grep -q 'CRS-2613' <<< "$RUN_OUT"; then GSTATE=NEED_CONFIGTOOLS
      elif grep -q 'NAME=ora.asm' <<< "$RUN_OUT"; then
        if grep -q 'STATE=ONLINE' <<< "$RUN_OUT"; then GSTATE=DONE; else GSTATE=ASM_DOWN; fi
      else GSTATE=UNKNOWN; GSTATE_OUT=$RUN_OUT; fi
      return
    fi
    # a left-over olr.loc of an earlier install does not make an unpacked home "installed"
    if [[ -f /etc/oracle/olr.loc ]] && in_inventory "$GRID_HOME"; then GSTATE=HAS_DOWN; return; fi
  fi
  if in_inventory "$GRID_HOME"; then
    if [[ -f "$STATE_DIR/grid_install.done" || -f /etc/oracle/olr.loc || -f "$(GRID_ROOT_DONE_FILE)" ]] && [[ -x "$GRID_HOME/bin/crsctl" ]]; then GSTATE=NEED_ROOT
    else GSTATE=HALF_INSTALLED; fi
    return
  fi
  if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then GSTATE=NEED_INSTALL; return; fi
  GSTATE=NEED_UNZIP
}
half_installed_plan() {
  # $1 home, $2 owner, $3 the success record: an installer that registered the home but did not finish
  # (relink error, killed), or a home installed by hand before this script ran
  NOW="$1 is in the Oracle inventory, but the script cannot confirm the installation."$'\n'"There is no record that its installer finished, or its programs are missing."
  KIND_NOW=ask; SW_FIX=half
  PLAN="You choose:
  m  you installed it yourself and the installer finished without error: the script records that
  c  clean it and install again: the home is marked as removed in the inventory (a backup is kept),
     $1 is emptied, and the installer runs again"
}
grid_installer() {
  # prints the installer path for the current media (image: in the home; staged: in the stage folder)
  if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then printf '%s/gridSetup.sh' "$GRID_HOME"
  else printf '%s/grid/runInstaller' "$(stage_dir grid)"; fi
}
grid_template() {
  if [[ -f "$GRID_HOME/install/response/gridsetup.rsp" ]]; then printf '%s/install/response/gridsetup.rsp' "$GRID_HOME"
  else printf '%s/grid/response/grid_install.rsp' "$(stage_dir grid)"; fi
}
write_grid_rsp() {
  # fills RSP (already copied from the template) for Oracle Restart with ASM
  local f=$RSP dl fg
  dl=$(asm_labels "$DATA_DG" | sed "s#^#$(asm_disk_dir)/#" | paste -sd, -)
  fg=$(tr ',' '\n' <<< "$dl" | sed 's/$/,/' | paste -sd, -)     # disk,failgroup,disk,failgroup (empty failgroups)
  rsp_need "$f" HA_CONFIG oracle.install.option installOption
  rsp_need "$f" "$GRID_BASE" ORACLE_BASE oracleBase
  rsp_need "$f" "$INVENTORY_DIR" INVENTORY_LOCATION inventoryLocation
  rsp_set  "$f" "$GRID_HOME" ORACLE_HOME oracleHome || true                 # staged (12.1) installer only
  rsp_set  "$f" "$INSTALL_GROUP" UNIX_GROUP_NAME unixGroupName || true
  rsp_set  "$f" "en" SELECTED_LANGUAGES || true
  rsp_need "$f" "$(grp_or asmdba dba)" oracle.install.asm.OSDBA OSDBA
  rsp_set  "$f" "$(getent group asmoper >/dev/null 2>&1 && printf asmoper)" oracle.install.asm.OSOPER OSOPER || true
  rsp_need "$f" "$(asm_owner_group)" oracle.install.asm.OSASM OSASM
  rsp_need "$f" "$ASM_PW" oracle.install.asm.SYSASMPassword sysasmPassword
  rsp_need "$f" "$ASM_PW" oracle.install.asm.monitorPassword asmsnmpPassword
  rsp_need "$f" "$DATA_DG" oracle.install.asm.diskGroup.name diskGroupName
  rsp_need "$f" EXTERNAL oracle.install.asm.diskGroup.redundancy redundancy
  rsp_set  "$f" 4 oracle.install.asm.diskGroup.AUSize auSize || true
  rsp_need "$f" "$dl" oracle.install.asm.diskGroup.disks diskList
  rsp_set  "$f" "$fg" oracle.install.asm.diskGroup.disksWithFailureGroupNames disksWithFailureGroupNames || true
  rsp_need "$f" "$(asm_disk_dir)/*" oracle.install.asm.diskGroup.diskDiscoveryString diskString
  rsp_set  "$f" false oracle.install.asm.configureAFD configureAFD || true
  rsp_set  "$f" NONE oracle.install.config.managementOption managementOption || true
  rsp_set  "$f" false oracle.install.crs.rootconfig.executeRootScript executeRootScript || true
  rsp_set  "$f" SKIP_UPDATES oracle.installer.autoupdates.option || true
  finish_rsp "$f" "$GRID_USER"
  rsp_review
}

# ---- 3.2 Grid software ----
SW_FIX=""; SW_UNZIP_DIRS=(); SW_UNZIP_OUTS=()
inventory_state() {
  # ok        : /etc/oraInst.loc is there, or the inventory folder is missing or empty (the installer makes it)
  # registered: the folder holds a real inventory (Oracle homes are listed in it), but /etc/oraInst.loc is missing
  # leftover  : the folder only has what a failed installer left (logs, an empty inventory): no home is listed
  [[ -f /etc/oraInst.loc ]] && { printf ok; return; }
  [[ -d "$INVENTORY_DIR" ]] && ! dir_empty "$INVENTORY_DIR" || { printf ok; return; }
  if grep -qs '<HOME ' "$INVENTORY_DIR/ContentsXML/inventory.xml"; then printf registered; else printf leftover; fi
}
inventory_fix_plan() {
  # $1 owner of the inventory. Sets NOW and PLAN for a state that is not ok (INS-32035 otherwise).
  case "$(inventory_state)" in
    leftover)
      NOW+="${NOW:+$'\n'}$INVENTORY_DIR is not empty, but no Oracle home is registered in it and /etc/oraInst.loc is missing."
      NOW+=$'\n'"These are files of an earlier installer run that did not finish. The installer would stop with INS-32035."
      PLAN="Move $INVENTORY_DIR aside to $INVENTORY_DIR.old_$RUN_ID (nothing is deleted),"$'\n'"and create it again empty, owner $1, group $INSTALL_GROUP."$'\n'"${PLAN}" ;;
    registered)
      NOW+="${NOW:+$'\n'}$INVENTORY_DIR holds an inventory with Oracle homes, but /etc/oraInst.loc is missing."
      PLAN="Write /etc/oraInst.loc (inventory_loc=$INVENTORY_DIR, inst_group=$INSTALL_GROUP), so the installer uses it."$'\n'"${PLAN}" ;;
  esac
}
inventory_fix() {
  # $1 owner. Puts the inventory folder in a state the installer accepts (see inventory_state).
  case "$(inventory_state)" in
    ok) return 0 ;;
    leftover)
      local old="$INVENTORY_DIR.old_$RUN_ID"
      [[ -e "$old" ]] && { bad "$old already exists. Nothing is moved."; return 1; }
      mv -T -- "$INVENTORY_DIR" "$old" || { bad "Cannot move $INVENTORY_DIR aside."; return 1; }
      journal RENAME "$INVENTORY_DIR" "to=$old"
      say "Moved the files of the earlier attempt to $old"
      make_dir "$INVENTORY_DIR" "$1" || return 1 ;;
    registered)
      printf 'inventory_loc=%s\ninst_group=%s\n' "$INVENTORY_DIR" "$INSTALL_GROUP" | write_as root /etc/oraInst.loc 644 || return 1
      say "Wrote /etc/oraInst.loc" ;;
  esac
  [[ "$(inventory_state)" == ok ]]
}
grid_ready() {
  # what the install needs (NOW says what is missing)
  [[ -n "$(asm_labels "$DATA_DG")" ]] || { NOW="No ASM disks for +$DATA_DG yet (step 2.13)"; return 1; }
  if [[ "$GSTATE" == "NEED_UNZIP" ]]; then
    media_ok "$GRID_MEDIA" || { NOW="The Grid installer files are not known yet (step 3.1)"; return 1; }
    if ! media_is_staged "$GRID_MEDIA"; then
      dir_empty "$GRID_HOME" || { NOW="$GRID_HOME is not empty, but it has no gridSetup.sh. Check what is in it."; return 1; }
    fi
  fi
  return 0
}
c_3_2() {
  SW_FIX=""
  use_grid || { NOW="Not needed (the primary does not use ASM)"; return 0; }
  users_ok || { NOW="The Oracle users do not exist yet (step 2.2)"; return 2; }
  grid_state
  case "$GSTATE" in
    DONE|ASM_DOWN|HAS_DOWN|NEED_CONFIGTOOLS|NEED_ROOT) NOW="Grid software is installed in $GRID_HOME"; return 0 ;;
    UNKNOWN) NOW="Cannot read the Grid state: $(head -n 2 <<< "$GSTATE_OUT")"; return 2 ;;
    HALF_INSTALLED) half_installed_plan "$GRID_HOME" "$GRID_USER" "$STATE_DIR/grid_install.done"; return 1 ;;
  esac
  if ! unzip_failed_check "$GRID_HOME" "$(stage_dir grid)"; then SW_FIX=unzip; YES_HOLD=1; return 1; fi
  grid_ready || return 2
  NOW="Grid is not installed yet"
  PLAN=""
  # an inventory folder that an earlier, failed installer run left behind is moved aside first (else INS-32035)
  [[ "$(inventory_state)" != ok ]] && SW_FIX=inv
  if [[ "$GSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$GRID_MEDIA"; then PLAN="Unzip ${GRID_MEDIA//,/ + } into $(stage_dir grid), as $GRID_USER"$'\n'
    else PLAN="Unzip $GRID_MEDIA into $GRID_HOME, as $GRID_USER"$'\n'; fi
  fi
  PLAN+="Install Grid silently as $GRID_USER: Oracle Restart for a single server${RU_DIR:+,}
${RU_DIR:+  with the Release Update in $RU_DIR}
  Disk group +$DATA_DG, external redundancy, disks $(asm_labels "$DATA_DG" | paste -sd' ' -)
  Grid home $GRID_HOME, base $GRID_BASE
  Inventory $INVENTORY_DIR
Ask you for a new ASM password for SYS and ASMSNMP (used only on this server)"
  USING="Same paths and disk group name as the primary."$'\n'"The response file is made from the template in the media."
  [[ "$SW_FIX" == inv ]] && inventory_fix_plan "$GRID_USER"
  return 1
}
d_3_2() {
  local fx=0
  case "$SW_FIX" in
    half)  sw_half_fix "$GRID_HOME" "$GRID_USER" "$STATE_DIR/grid_install.done" "$(stage_dir grid)" grid || fx=$?
           [[ $fx -eq 10 ]] || return $fx ;;
    unzip) sw_unzip_fix || return 1 ;;
    inv)   inventory_fix "$GRID_USER" || return 1 ;;
  esac
  if [[ -n "$SW_FIX" ]]; then
    SW_FIX=""; grid_state
    grid_ready || { bad "$NOW"; return 1; }
  fi
  if [[ "$GSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$GRID_MEDIA"; then unpack_media "$GRID_MEDIA" "$(stage_dir grid)" as_grid "$GRID_USER" || return 1
    else
      unpack_media "$GRID_MEDIA" "$GRID_HOME" as_grid "$GRID_USER" || return 1
      [[ -x "$GRID_HOME/gridSetup.sh" ]] || { bad "gridSetup.sh is missing after the unzip. Is GRID_MEDIA the right file?"; return 1; }
    fi
  fi
  [[ -x "$GRID_HOME/gridSetup.sh" ]] && { new_opatch "$GRID_HOME" as_grid "$GRID_USER" || return 1; }
  ask_asm_password || return 1
  make_rsp "$(grid_template)" || return 1
  write_grid_rsp || { remove_rsp "$RSP"; return 1; }
  local inst irc=0 rsp=$RSP; inst=$(grid_installer)
  local -a ru=(); mapfile -t ru < <(ru_args grid)
  JOB_KEEP=$rsp
  if [[ "$inst" == */gridSetup.sh ]]; then
    run_installer "Grid installer" as_grid -ignorePrereqFailure "$inst" -silent -waitforcompletion -responseFile "$rsp" "${ru[@]+"${ru[@]}"}" || irc=1
  else
    run_installer "Grid installer (12.1)" as_grid -ignorePrereq "$inst" -silent -waitforcompletion -responseFile "$rsp" || irc=1
  fi
  remove_rsp "$rsp"
  return $irc
}

# ---- 3.3 Grid root scripts ----
c_3_3() {
  use_grid || { NOW="Not needed (no Grid)"; return 0; }
  grid_state
  case "$GSTATE" in
    DONE|ASM_DOWN|NEED_CONFIGTOOLS)
      [[ "$MODE" == "run" ]] && { install -d -m 700 "$STATE_DIR"; : > "$(GRID_ROOT_DONE_FILE)"; }
      NOW="The Grid root scripts have run. Oracle Restart is configured and running."; return 0 ;;
    HAS_DOWN)
      if [[ -f "$(GRID_ROOT_DONE_FILE)" ]]; then NOW="The Grid root scripts have run. High Availability Services is started in step 3.4."; return 0; fi
      NOW="Oracle Restart is configured (olr.loc exists), but High Availability Services is not running."$'\n'"root.sh may have failed."
      KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
      PLAN="$GRID_HOME/bin/crsctl start has
-- If that fails, read $GRID_HOME/cfgtoollogs/crsconfig/roothas_*.log.
-- Then undo the configuration and run root.sh again:
$GRID_HOME/crs/install/roothas.sh -deconfig -force
$GRID_HOME/root.sh"
      return 1 ;;
    NEED_ROOT) ;;
    *) NOW="Grid is not installed yet (step 3.2)"; return 2 ;;
  esac
  # 12.1 Oracle Restart on Oracle Linux 7 (systemd) starts ohasd only with patch 18370031 (also inside a later PSU)
  if [[ "$(want_rel grid)" == "12.1" && "$OS_MAJOR" == "7" && ! -d "$GRID_HOME/inventory/oneoffs/18370031" ]] \
     && ! grep -qs '18370031' "$GRID_HOME"/inventory/oneoffs/*/etc/config/inventory.xml; then
    NOW="12.1 Grid on Oracle Linux 7 needs patch 18370031 before root.sh."$'\n'"Without it, ohasd does not start under systemd."
    KIND_NOW=manual; MANUAL_HOW="$GRID_USER  ->  shell"
    PLAN="-- Download patch 18370031 from My Oracle Support and unzip it. Then:
$GRID_HOME/OPatch/opatch napply -oh $GRID_HOME -local <folder>/18370031
-- Then answer r. root.sh runs after that."
    return 1
  fi
  NOW="Grid is installed. Its root scripts have not run yet."
  local invd; invd=$(inventory_dir)
  PLAN=""
  [[ -x "$invd/orainstRoot.sh" ]] && PLAN="Run $invd/orainstRoot.sh"$'\n'
  PLAN+="Run $GRID_HOME/root.sh. It configures Oracle Restart on this server."$'\n'"Its questions get the default answers."
  return 1
}
d_3_3() {
  local invd; invd=$(inventory_dir)
  if [[ -x "$invd/orainstRoot.sh" ]]; then run_root_script "$invd/orainstRoot.sh" || return 1; fi
  run_root_script "$GRID_HOME/root.sh" || return 1
  install -d -m 700 "$STATE_DIR"; : > "$(GRID_ROOT_DONE_FILE)"
  journal GRIDCONFIG "$GRID_HOME" "root.sh: Oracle Restart configured (ohasd, /etc/oracle, /etc/oraInst.loc)"
}

# ---- 3.4 Grid configuration (ASM, listener) ----
c_3_4() {
  use_grid || { NOW="Not needed (no Grid)"; return 0; }
  grid_state
  case "$GSTATE" in
    DONE) NOW="Oracle Restart is running and ASM is ONLINE"; return 0 ;;
    NEED_CONFIGTOOLS)
      NOW="Oracle Restart is running. ASM is not configured yet."
      if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then PLAN="Run gridSetup.sh -executeConfigTools -silent as $GRID_USER"
      else PLAN="Run $GRID_HOME/cfgtoollogs/configToolAllCommands as $GRID_USER (12.1)"; fi
      PLAN+=$'\n'"It creates ASM, +$DATA_DG and the listener."
      [[ -n "$ASM_PW" ]] || PLAN+=$'\n'"Ask you for the ASM password for SYS and ASMSNMP: the one from step 3.2"$'\n'"(it was not used yet), or a new one" ;;
    HAS_DOWN) NOW="High Availability Services is stopped"; PLAN="Start it as root:  $GRID_HOME/bin/crsctl start has" ;;
    ASM_DOWN) NOW="ASM is not ONLINE"; PLAN="Start it as $GRID_USER:  crsctl start res ora.asm" ;;
    UNKNOWN) NOW="Cannot read the Grid state: $(head -n 2 <<< "$GSTATE_OUT")"; return 2 ;;
    *) NOW="The Grid root scripts have not run yet (step 3.3)"; return 2 ;;
  esac
  return 1
}
d_3_4() {
  case "$GSTATE" in
    NEED_CONFIGTOOLS)
      ask_asm_password || return 1
      local crc=0
      if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then
        make_rsp "$(grid_template)" || return 1
        write_grid_rsp || { remove_rsp "$RSP"; return 1; }
        local rsp=$RSP; JOB_KEEP=$rsp
        run_installer "Grid configuration tools" as_grid -ignorePrereqFailure "$GRID_HOME/gridSetup.sh" -executeConfigTools -responseFile "$rsp" -silent -waitforcompletion || crc=1
        remove_rsp "$rsp"
      else
        secure_rsp cfgrsp.properties || return 1
        ( umask 077; set -C
          printf 'oracle.assistants.asm|S_ASMPASSWORD=%s\noracle.assistants.asm|S_ASMMONITORPASSWORD=%s\n' "$ASM_PW" "$ASM_PW" > "$RSP" ) || return 1
        finish_rsp "$RSP" "$GRID_USER"
        local props=$RSP; JOB_KEEP=$props
        run_installer "Grid configuration tools (12.1)" as_grid "" "$GRID_HOME/cfgtoollogs/configToolAllCommands" "RESPONSE_FILE=$props" || crc=1
        remove_rsp "$props"
      fi
      return $crc ;;
    HAS_DOWN)
      run_logged "crsctl start has" timeout 300 "$GRID_HOME/bin/crsctl" start has || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
      # ASM may take minutes after the stack starts (many disks): up to 5 minutes, then a clear failure
      # measured in time (each check itself may take a while), with a line every minute
      local t0 last=0 el; t0=$(date +%s); say "Waiting for ASM to come online (up to 5 minutes) ..."
      until grid_state; [[ "$GSTATE" == "DONE" || "$GSTATE" == "ASM_DOWN" ]] || (( $(date +%s) - t0 >= 300 )); do
        sleep 5; el=$(( ($(date +%s) - t0) / 60 )); [[ $el -gt $last ]] && { last=$el; say "Still waiting ($el min, state $GSTATE)"; }
      done
      # the stack is up but ASM was not started with it (not set to start by itself): started here
      if [[ "$GSTATE" == "ASM_DOWN" ]]; then
        run_logged "start ora.asm" as_grid timeout 300 "$GRID_HOME/bin/crsctl" start res ora.asm || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
        t0=$(date +%s); until grid_state; [[ "$GSTATE" == "DONE" ]] || (( $(date +%s) - t0 >= 120 )); do sleep 5; done
      fi
      [[ "$GSTATE" == "DONE" ]] || { bad "Oracle Restart started, but ASM did not come online in time (state $GSTATE)."; return 1; } ;;
    ASM_DOWN) run_logged "start ora.asm" as_grid timeout 300 "$GRID_HOME/bin/crsctl" start res ora.asm || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; } ;;
  esac
}

# ---- 3.5 disk groups ----
dg_list() { sql_asm "select name||'|'||state||'|'||free_mb||'|'||total_mb from v\$asm_diskgroup;"; }
dg_field() {
  local n s f t
  DG_S=""; DG_F=""; DG_T=""
  while IFS='|' read -r n s f t; do [[ "${n^^}" == "${1^^}" ]] && { DG_S=$s; DG_F=$f; DG_T=$t; }; done <<< "$SQL_OUT"
}
DG_TODO=""
c_3_5() {
  use_grid || { NOW="Not needed (no ASM)"; return 0; }
  grid_sw_ok || { NOW="Grid is not installed yet (step 3.2)"; return 2; }
  dg_list || { NOW="Cannot query ASM: $(ora_errors "$SQL_OUT") (step 3.4)"; return 2; }
  local list=$SQL_OUT ca="" cr=""
  dg_field "$DATA_DG"
  if [[ "$DG_S" == "MOUNTED" || "$DG_S" == "CONNECTED" ]]; then
    # the new disk groups take these values from +DATA: a failed query is not passed over silently
    sql_asm "select max(decode(a.name,'compatible.asm',a.value))||'|'||max(decode(a.name,'compatible.rdbms',a.value)) from v\$asm_attribute a, v\$asm_diskgroup g where a.group_number=g.group_number and g.name='$DATA_DG';" \
      || { NOW="Cannot read compatible.asm and compatible.rdbms of +$DATA_DG ($(ora_errors "$SQL_OUT"))"; return 2; }
    IFS='|' read -r ca cr <<< "$(first_line)"
    # a disk group made with the old 10.1 defaults has no attribute rows: the new ones get the defaults too
    [[ "$ca" =~ ^[0-9.]+$ && "$cr" =~ ^[0-9.]+$ ]] || warn "+$DATA_DG does not show both compatible.asm and compatible.rdbms. A value it does not show is the default of this ASM in the new disk groups."
  elif [[ -z "$DG_S" ]]; then
    # the Grid configuration created ASM but not +DATA (it stopped half-way): created here like the others
    warn "+$DATA_DG does not exist, although ASM is running. The Grid configuration did not
finish it. This step creates it, with default attributes."
  fi
  SQL_OUT=$list
  local dg info="" todo="" disks
  DG_TODO=""
  for dg in $(asm_dgs); do
    dg_field "$dg"
    if [[ "$DG_S" == "MOUNTED" || "$DG_S" == "CONNECTED" ]]; then info+="+$dg $DG_S, $(human_mb "$DG_F") free of $(human_mb "$DG_T")"$'\n'; continue; fi
    if [[ -n "$DG_S" ]]; then
      NOW="Disk group +$dg exists here, but it is $DG_S"
      KIND_NOW=manual; MANUAL_HOW="$GRID_USER  ->  export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM ; \$ORACLE_HOME/bin/sqlplus / as sysasm"
      PLAN="-- Mount it only if all its disks belong to this server. NEVER use a disk of the primary.
select path, header_status, name from v\$asm_disk;
alter diskgroup $dg mount;"
      return 1
    fi
    [[ -n "$(asm_labels "$dg")" ]] || { NOW="No ASM disks for +$dg yet (step 2.13)"; return 2; }
    disks=$(asm_labels "$dg" | sed "s#^#'$(asm_disk_dir)/#; s#\$#'#" | paste -sd, -)
    local c="create diskgroup $dg external redundancy disk $disks" attrs=""
    local ca2=$ca cr2=$cr
    if [[ "${PRIMARY_REDO_BS:-${SRL_BLOCKSIZE:-512}}" == "4096" ]]; then
      # a sector size other than the default needs compatible values of 11.2 or newer (12.2 for 512e disks)
      # 12.2 for 512e disks needs a 12.2+ Grid; an older Grid takes 11.2 (enough for sector_size)
      if [[ "$(rel_major "${GRID_REL:-${DB_MAJOR:-19}}")" -ge 18 || "${GRID_REL:-}" == 12.2* ]]; then ver_lt "${ca2:-0}" 12.2 && ca2=12.2.0.1.0
      else ver_lt "${ca2:-0}" 11.2 && ca2=11.2.0.0.0; fi
      ver_lt "${cr2:-0}" 11.2 && cr2=11.2.0.0.0
    fi
    # each value that is known is used (one can be missing on an old disk group)
    # compatible.asm alone is fine; compatible.rdbms only together with it (rdbms may not be above asm)
    [[ "$ca2" =~ ^[0-9.]+$ ]] && attrs+="'compatible.asm'='$ca2'"
    [[ "$ca2" =~ ^[0-9.]+$ && "$cr2" =~ ^[0-9.]+$ ]] && attrs+=", 'compatible.rdbms'='$cr2'"
    [[ "${PRIMARY_REDO_BS:-${SRL_BLOCKSIZE:-512}}" == "4096" ]] && attrs+="${attrs:+, }'sector_size'='4096'"
    [[ -n "$attrs" ]] && c+=" attribute $attrs"
    DG_TODO+="$c;"$'\n'; todo+=" +$dg"
  done
  DG_TODO=${DG_TODO%$'\n'}
  if [[ -z "$DG_TODO" ]]; then NOW="${info%$'\n'}"; return 0; fi
  [[ ${PRIMARY_REDO_BS_KNOWN:-0} -eq 1 ]] || { NOW="The redo block size of the primary could not be read (step 1.3), so the sector size of the new disk groups is not known. Run the script again."; return 2; }
  NOW="Disk groups to create:$todo"
  PLAN="As $GRID_USER:  export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM ; \$ORACLE_HOME/bin/sqlplus / as sysasm
$DG_TODO"
  USING="Same disk group names as the primary."$'\n'"compatible.asm and compatible.rdbms are the same as in +$DATA_DG."
  return 1
}
d_3_5() {
  local s
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if ! sql_asm "$s"; then
      bad "This failed ($(ora_errors "$SQL_OUT")):"$'\n'"$s"
      if grep -qE 'ORA-15018|ORA-15030|ORA-15033' <<< "$SQL_OUT"; then
        printf 'A disk already has an ASM header, probably from an interrupted earlier try.\nOnly if the disks were made by this script (%s), repeat the statement with FORCE:\n  %s\n' "$(asm_disks_file)" "$(sed -E "s/'((\/|ORCL:)[^']*)'/'\1' force/g" <<< "$s")" | hint
      fi
      return 1
    fi
    [[ "$s" =~ ^create\ diskgroup\ ([A-Za-z0-9_]+) ]] && journal DISKGROUP "${BASH_REMATCH[1]^^}" "external redundancy"
  done <<< "$DG_TODO"
  return 0
}

#------------------------------------------------------------------------------
# Database software
#------------------------------------------------------------------------------
db_state() {
  # DONE | NEED_ROOT | HALF_INSTALLED | NEED_INSTALL | NEED_UNZIP
  if in_inventory "$DB_HOME"; then
    if [[ ! -f "$STATE_DIR/db_install.done" && "$(stat -c '%U' "$DB_HOME/bin/oradism" 2>/dev/null)" != "root" ]] || [[ ! -s "$DB_HOME/bin/oracle" || ! -s "$DB_HOME/bin/sqlplus" ]]; then DSTATE=HALF_INSTALLED; return; fi
    if [[ "$(stat -c '%U' "$DB_HOME/bin/oradism" 2>/dev/null)" == "root" ]]; then DSTATE=DONE; else DSTATE=NEED_ROOT; fi
    return
  fi
  if [[ -x "$DB_HOME/runInstaller" ]]; then DSTATE=NEED_INSTALL; return; fi
  DSTATE=NEED_UNZIP
}
db_template() {
  if [[ -f "$DB_HOME/install/response/db_install.rsp" ]]; then printf '%s/install/response/db_install.rsp' "$DB_HOME"
  else printf '%s/database/response/db_install.rsp' "$(stage_dir db)"; fi
}
db_installer() {
  if [[ -x "$DB_HOME/runInstaller" ]]; then printf '%s/runInstaller' "$DB_HOME"
  else printf '%s/database/runInstaller' "$(stage_dir db)"; fi
}
write_db_rsp() {
  # $1 = image | staged
  local f=$RSP
  rsp_need "$f" INSTALL_DB_SWONLY oracle.install.option installOption
  rsp_need "$f" "$INSTALL_GROUP" UNIX_GROUP_NAME unixGroupName
  rsp_need "$f" "$INVENTORY_DIR" INVENTORY_LOCATION inventoryLocation
  # an image installer installs into the folder it was unpacked in; only staged media needs ORACLE_HOME
  if [[ "$1" == "staged" ]]; then rsp_need "$f" "$DB_HOME" ORACLE_HOME oracleHome; else rsp_set "$f" "$DB_HOME" ORACLE_HOME oracleHome || true; fi
  rsp_need "$f" "$ORACLE_BASE" ORACLE_BASE oracleBase
  rsp_need "$f" "${DB_EDITION:-EE}" oracle.install.db.InstallEdition installEdition
  # group names: 12.2+ (OSDBA_GROUP ...), 12.1 (DBA_GROUP ...), 23ai (OSDBA ...)
  rsp_need "$f" "$(grp_or dba)" oracle.install.db.OSDBA_GROUP oracle.install.db.DBA_GROUP OSDBA
  rsp_set  "$f" "$(grp_or oper dba)" oracle.install.db.OSOPER_GROUP oracle.install.db.OPER_GROUP OSOPER || true
  rsp_set  "$f" "$(grp_or backupdba dba)" oracle.install.db.OSBACKUPDBA_GROUP oracle.install.db.BACKUPDBA_GROUP OSBACKUPDBA || true
  rsp_set  "$f" "$(grp_or dgdba dba)" oracle.install.db.OSDGDBA_GROUP oracle.install.db.DGDBA_GROUP OSDGDBA || true
  rsp_set  "$f" "$(grp_or kmdba dba)" oracle.install.db.OSKMDBA_GROUP oracle.install.db.KMDBA_GROUP OSKMDBA || true
  rsp_set  "$f" "$(grp_or racdba dba)" oracle.install.db.OSRACDBA_GROUP OSRACDBA || true
  rsp_set  "$f" false oracle.install.db.rootconfig.executeRootScript executeRootScript || true
  rsp_set  "$f" true DECLINE_SECURITY_UPDATES || true
  rsp_set  "$f" false SECURITY_UPDATES_VIA_MYORACLESUPPORT || true
  rsp_set  "$f" SKIP_UPDATES oracle.installer.autoupdates.option || true
  rsp_set  "$f" en SELECTED_LANGUAGES || true
  finish_rsp "$f" "$ORACLE_USER"
  rsp_review
}
primary_edition() {
  [[ -n "$DB_EDITION" ]] && return 0
  need_ssh || return 1
  prim_sql "select banner from v\$version where banner like 'Oracle%';" || return 1
  local b; b=$(first_line)
  if [[ "$b" == *"Enterprise Edition"* ]]; then DB_EDITION=EE
  elif [[ "$b" == *"Standard Edition"* ]]; then DB_EDITION=SE2
  else DB_EDITION=EE; warn "Edition not recognised in '$b'. Using Enterprise Edition."; fi
  [[ "$DB_EDITION" == "EE" ]] || fatal "The primary is Standard Edition ($b). Data Guard needs Enterprise Edition. This script cannot build a standby for it."
}

# ---- 3.6 DB software ----
inventory_ready() {
  # The database installer uses the central inventory of this server. /etc/oraInst.loc says where it is.
  # Without that file the installer tries to create a NEW inventory and stops (INS-32035 / INS-32039) when
  # the folder already has files (for example from the Grid installer).
  [[ -f /etc/oraInst.loc ]] && return 0
  if use_grid; then
    NOW="The Oracle inventory is not registered on this server yet: /etc/oraInst.loc is missing."$'\n'"The Grid root scripts create it. Grid must be installed and its root scripts run first (step 3.3)"
    return 2
  fi
  dir_empty "$INVENTORY_DIR" && return 0      # the database installer creates it
  NOW="$INVENTORY_DIR has files, but /etc/oraInst.loc is missing, so no installer can use it."$'\n'"The database installer would stop with INS-32035."
  KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
  PLAN="-- If Oracle software on this server uses this inventory, register it:
printf 'inventory_loc=$INVENTORY_DIR\ninst_group=$INSTALL_GROUP\n' > /etc/oraInst.loc
-- If it is left over from an earlier attempt and nothing uses it, move it aside instead:
mv $INVENTORY_DIR $INVENTORY_DIR.old_\$(date +%F)
-- Then answer r."
  return 1
}
db_ready() {
  if [[ "$DSTATE" == "NEED_UNZIP" ]]; then
    media_ok "$DB_MEDIA" || { NOW="The database installer files are not known yet (step 3.1)"; return 1; }
    if ! media_is_staged "$DB_MEDIA"; then
      dir_empty "$DB_HOME" || { NOW="$DB_HOME is not empty, but it has no runInstaller. Check what is in it."; return 1; }
    fi
  fi
  return 0
}
c_3_6() {
  SW_FIX=""
  users_ok || { NOW="The Oracle users do not exist yet (step 2.2)"; return 2; }
  db_state
  case "$DSTATE" in
    DONE|NEED_ROOT) NOW="Database software is installed in $DB_HOME"; return 0 ;;
    HALF_INSTALLED) half_installed_plan "$DB_HOME" "$ORACLE_USER" "$STATE_DIR/db_install.done"; return 1 ;;
  esac
  primary_edition || { NOW="Cannot read the edition of the primary"; return 2; }
  if ! unzip_failed_check "$DB_HOME" "$(stage_dir db)"; then SW_FIX=unzip; YES_HOLD=1; return 1; fi
  inventory_ready || return $?
  db_ready || return 2
  NOW="Database software is not installed yet"
  PLAN=""
  if [[ "$DSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$DB_MEDIA"; then PLAN="Unzip ${DB_MEDIA//,/ + } into $(stage_dir db), as $ORACLE_USER"$'\n'
    else PLAN="Unzip $DB_MEDIA into $DB_HOME, as $ORACLE_USER"$'\n'; fi
  fi
  PLAN+="Install the database software silently as $ORACLE_USER: Software Only, Enterprise Edition${RU_DIR:+,}
${RU_DIR:+  with the Release Update in $RU_DIR}
  Home $DB_HOME, base $ORACLE_BASE, OS groups as on the primary"
  USING="Same home and base as the primary."$'\n'"The response file is made from the template in the media."
  return 1
}
d_3_6() {
  local kind=image fx=0
  case "$SW_FIX" in
    half)  sw_half_fix "$DB_HOME" "$ORACLE_USER" "$STATE_DIR/db_install.done" "$(stage_dir db)" db || fx=$?
           [[ $fx -eq 10 ]] || return $fx ;;
    unzip) sw_unzip_fix || return 1 ;;
  esac
  if [[ -n "$SW_FIX" ]]; then
    SW_FIX=""; db_state
    primary_edition || { bad "Cannot read the edition of the primary"; return 1; }
    db_ready || { bad "$NOW"; return 1; }
  fi
  if [[ "$DSTATE" == "NEED_UNZIP" ]]; then
    if media_is_staged "$DB_MEDIA"; then unpack_media "$DB_MEDIA" "$(stage_dir db)" as_oracle "$ORACLE_USER" || return 1
    else
      unpack_media "$DB_MEDIA" "$DB_HOME" as_oracle "$ORACLE_USER" || return 1
      [[ -x "$DB_HOME/runInstaller" ]] || { bad "runInstaller is missing after the unzip. Is DB_MEDIA the right file?"; return 1; }
    fi
  fi
  local inst irc=0; inst=$(db_installer)
  [[ "$inst" == "$DB_HOME/runInstaller" ]] || kind=staged
  [[ "$kind" == "image" && $DB_MAJOR -ge 18 ]] && { new_opatch "$DB_HOME" as_oracle "$ORACLE_USER" || return 1; }
  make_rsp "$(db_template)" || return 1
  write_db_rsp "$kind" || { remove_rsp "$RSP"; return 1; }
  local rsp=$RSP
  local -a ru=(); [[ $DB_MAJOR -ge 18 ]] && mapfile -t ru < <(ru_args)
  JOB_KEEP=$rsp
  if [[ "$kind" == "image" ]]; then
    run_installer "Database installer" as_oracle -ignorePrereqFailure "$inst" -silent -waitforcompletion -responseFile "$rsp" "${ru[@]+"${ru[@]}"}" || irc=1
  else
    run_installer "Database installer (12.x)" as_oracle -ignorePrereq "$inst" -silent -waitforcompletion -responseFile "$rsp" || irc=1
  fi
  remove_rsp "$rsp"
  return $irc
}

# ---- 3.7 DB root.sh ----
c_3_7() {
  db_state
  case "$DSTATE" in
    DONE) NOW="root.sh of the database home has run"; return 0 ;;
    NEED_ROOT)
      NOW="The database software is installed. Its root.sh has not run yet."
      PLAN=""; [[ -x "$(inventory_dir)/orainstRoot.sh" && ! -f /etc/oraInst.loc ]] && PLAN="Run $(inventory_dir)/orainstRoot.sh"$'\n'
      PLAN+="Run $DB_HOME/root.sh. Its questions get the default answers."; return 1 ;;
    HALF_INSTALLED) NOW="The database installer did not finish (step 3.6)"; return 2 ;;
    *) NOW="Database software is not installed yet (step 3.6)"; return 2 ;;
  esac
}
d_3_7() {
  if [[ ! -f /etc/oraInst.loc && -x "$(inventory_dir)/orainstRoot.sh" ]]; then run_root_script "$(inventory_dir)/orainstRoot.sh" || return 1; fi
  run_root_script "$DB_HOME/root.sh" || return 1
  journal ROOTSH "$DB_HOME" "root.sh of the database home (/usr/local/bin/oraenv, coraenv, dbhome; /etc/oratab)"
  local s; for s in db grid; do [[ -d "$(stage_dir $s)" ]] && say "You can now remove the unpacked installer in $(stage_dir $s) (rm -rf)."; done
  return 0
}

# ---- 3.8 read/write home (18c and newer) ----
OBH=""
c_3_8() {
  db_sw_ok || { NOW="Database software is not installed yet (step 3.6)"; return 2; }
  [[ -x "$DB_HOME/bin/orabasehome" ]] || { NOW="Not needed (read-only homes exist only from 18c)"; return 0; }
  run_logged "orabasehome" as_oracle "$DB_HOME/bin/orabasehome" || { NOW="Cannot run $DB_HOME/bin/orabasehome"; return 2; }
  OBH=$(printf '%s\n' "$RUN_OUT" | grep -E '^/' | head -n 1); OBH=${OBH%/}
  if [[ "$OBH" == "$DB_HOME" ]]; then NOW="The Oracle home is read/write (orabasehome prints the home itself)"; return 0; fi
  NOW="The Oracle home is read-only. orabasehome prints:"$'\n'"  $OBH"
  if [[ -n "$(ls -A "$ORACLE_BASE/dbs" 2>/dev/null)" ]] || pgrep -f "^ora_pmon_" >/dev/null 2>&1; then
    NOW+=$'\n'"A database already uses it: there are files in $ORACLE_BASE/dbs, or an instance runs."$'\n'"The script does not change such a home."
    return 2
  fi
  PLAN="Run roohctl -disable as $ORACLE_USER. The home is new and has no database yet."
  PLAN+=$'\n'"Then the spfile, password file and tnsnames.ora are kept inside $DB_HOME."
  return 1
}
# journaled first: a roohctl that stops half-way has still changed the home, and the undo must be listed
d_3_8() { journal ROOHCTL "$DB_HOME"; run_logged "roohctl -disable" as_oracle "$DB_HOME/bin/roohctl" -disable || { bad "roohctl failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }; }
rw_home_ok() {
  db_sw_ok || return 1
  [[ -x "$DB_HOME/bin/orabasehome" ]] || return 0
  run_logged "orabasehome" as_oracle "$DB_HOME/bin/orabasehome" || return 1
  local o; o=$(printf '%s\n' "$RUN_OUT" | grep -E '^/' | head -n 1)
  [[ "${o%/}" == "$DB_HOME" ]]
}

# ---- 3.9 resources (Grid) ----
RES_TODO=""
c_3_9() {
  use_grid || { NOW="Not needed without Grid. The listener is set up in phase 5."; return 0; }
  grid_sw_ok || { NOW="Grid is not installed yet (step 3.2)"; return 2; }
  local r off=() miss=() on=() dg
  local -a res=(ora.asm "ora.$SB_LSNR.lsnr")
  for dg in $(asm_dgs); do res+=("ora.${dg^^}.dg"); done
  for r in "${res[@]}"; do
    run_logged "crsctl stat res $r" as_grid timeout 60 "$GRID_HOME/bin/crsctl" stat res "$r" || true
    if grep -q 'CRS-2613' <<< "$RUN_OUT" || ! grep -q "NAME=$r" <<< "$RUN_OUT"; then miss+=("$r")
    elif grep -q 'STATE=ONLINE' <<< "$RUN_OUT"; then on+=("$r")
    else off+=("$r"); fi
  done
  if [[ ${#off[@]} -eq 0 && ${#miss[@]} -eq 0 ]]; then NOW="All ONLINE: ${on[*]}"; return 0; fi
  RES_TODO=""
  for r in "${miss[@]+"${miss[@]}"}"; do
    if [[ "$r" == "ora.$SB_LSNR.lsnr" ]]; then
      RES_TODO+="srvctl add listener -listener $SB_LSNR -endpoints TCP:$PORT"$'\n'"srvctl start listener -listener $SB_LSNR"$'\n'
    else
      NOW="Resource $r does not exist (step 3.5)"; return 2
    fi
  done
  for r in "${off[@]+"${off[@]}"}"; do RES_TODO+="crsctl start res $r"$'\n'; done
  RES_TODO=${RES_TODO%$'\n'}
  NOW="Not ONLINE yet: ${off[*]+"${off[*]}"} ${miss[*]+"${miss[*]}"}"
  PLAN="Run as $GRID_USER:
$RES_TODO"
  return 1
}
d_3_9() {
  local c
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    local -a w=(); read -ra w <<< "$c"
    run_logged "$c" as_grid timeout 300 "$GRID_HOME/bin/${w[0]}" "${w[@]:1}" || { bad "$c failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    say "Ran: $c"
    [[ "$c" == "srvctl add listener"* ]] && journal LSNRRES "$SB_LSNR" "srvctl add listener"
  done <<< "$RES_TODO"
}

# ---- 3.10 listener port equal to primary (Grid listener) ----
c_3_10() {
  use_grid || { NOW="Not needed without Grid. Phase 5 creates the listener with port $PORT."; return 0; }
  grid_sw_ok || { NOW="Grid is not installed yet (step 3.2)"; return 2; }
  run_logged "lsnrctl status" as_grid timeout 60 "$GRID_HOME/bin/lsnrctl" status "$SB_LSNR" || { NOW="Listener $SB_LSNR is not running (step 3.9)"; return 2; }
  if grep -q "(PROTOCOL=TCP)(HOST=[^)]*)(PORT=$PORT)" <<< "$(norm "$RUN_OUT")"; then NOW="Listener $SB_LSNR uses port $PORT, the same as the primary"; return 0; fi
  local cur; cur=$(norm "$RUN_OUT" | grep -oE '\(PROTOCOL=TCP\)\(HOST=[^)]*\)\(PORT=[0-9]+\)' | head -n 1 | grep -oE '[0-9]+\)$' | tr -d ')')
  L310_CUR=$cur
  NOW="Listener $SB_LSNR uses port ${cur:-?}. The primary uses $PORT."
  PLAN="Run as $GRID_USER:
srvctl modify listener -listener $SB_LSNR -endpoints TCP:$PORT
srvctl stop listener -listener $SB_LSNR
srvctl start listener -listener $SB_LSNR"
  return 1
}
d_3_10() {
  run_logged "srvctl modify listener" as_grid "$GRID_HOME/bin/srvctl" modify listener -listener "$SB_LSNR" -endpoints "TCP:$PORT" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  journal LSNRPORT "$SB_LSNR" "old=${L310_CUR:-1521} new=$PORT"
  run_logged "srvctl stop listener" as_grid "$GRID_HOME/bin/srvctl" stop listener -listener "$SB_LSNR" || true
  run_logged "srvctl start listener" as_grid "$GRID_HOME/bin/srvctl" start listener -listener "$SB_LSNR" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
}

# ---- 3.11 same software level as primary ----
# The patches of a home are the folder names in <home>/inventory/oneoffs (what opatch lspatches reads).
local_patches() { ls -1 "$1/inventory/oneoffs" 2>/dev/null | grep -E '^[0-9]{6,9}$' | sort -u; }
primary_patches() {
  # $1 home on primary -> patch ids; rc 1 if the inventory of that home cannot be read
  prim_probe owner "$1/inventory" || return 1
  # no oneoffs folder = no patch was ever applied; any other failure (no answer) is not that
  if ! prim_probe owner "$1/inventory/oneoffs"; then
    # the answer of test itself (no error text in any language needed)
    prim_probe exists "$1/inventory/oneoffs" && [[ "$(head -n 1 <<< "$RUN_OUT")" == "NO" ]] && return 0
    return 1
  fi
  prim_probe lsdir "$1/inventory/oneoffs" || return 1           # it exists, so it must be readable
  grep -E '^[0-9]{6,9}$' <<< "$RUN_OUT" | sort -u
  return 0
}
local_release() {
  # base release of the installed database software, from sqlplus -V ("Release 19.0.0.0.0", "Version 19.21.0.0.0")
  run_logged "sqlplus -V" as_oracle "$DB_HOME/bin/sqlplus" -V || return 1
  grep -oE '(Release|Version) [0-9]+\.[0-9]+' <<< "$RUN_OUT" | head -n 1 | awk '{print $2}'
}
c_3_11() {
  db_sw_ok || { NOW="Database software is not installed yet (step 3.6)"; return 2; }
  need_ssh || return 2
  primary_edition || { NOW="Cannot read the edition of the primary"; return 2; }
  local rel want h pp lp missing extra report="" bad_rel=""
  rel=$(local_release || true); want=$(want_rel)
  [[ -n "$rel" ]] || { NOW="The release of the database software here cannot be read (sqlplus -V)"; return 2; }
  if [[ -n "$rel" ]]; then
    if [[ "$DB_MAJOR" == "12" ]]; then [[ "$rel" == "$want" ]] || bad_rel="release $rel here, release $want on the primary"
    else [[ "${rel%%.*}" == "$DB_MAJOR" ]] || bad_rel="release $rel here, release $DB_MAJOR on the primary"; fi
  fi
  if [[ -n "$bad_rel" ]]; then
    NOW="The database software here is another release: $bad_rel"
    KIND_NOW=manual; MANUAL_HOW="root"
    PLAN="-- Remove this installation and install release $want (steps 3.1 and 3.6).
-- The standby must have the same release as the primary."
    return 1
  fi
  for h in "$DB_HOME" ${GRID_HOME:+"$GRID_HOME"}; do
    use_grid || [[ "$h" != "$GRID_HOME" ]] || continue
    pp=$(primary_patches "$h") || { NOW="Cannot read $h/inventory on the primary. The ssh user must be able to read it."; return 2; }
    lp=$(local_patches "$h")
    missing=$(comm -23 <(printf '%s\n' "$pp" | grep -v '^$') <(printf '%s\n' "$lp" | grep -v '^$') | paste -sd' ' -)
    extra=$(comm -13 <(printf '%s\n' "$pp" | grep -v '^$') <(printf '%s\n' "$lp" | grep -v '^$') | paste -sd' ' -)
    if [[ -n "$missing$extra" ]]; then
      report+="$h:${missing:+ missing here: $missing}${extra:+  only here: $extra}"$'\n'
    fi
  done
  if [[ -z "$report" ]]; then
    local np; np=$(local_patches "$DB_HOME" | wc -l)
    NOW="Same release and patches as the primary: release ${PRIMARY_VERSION:-${rel:-$want}}, Enterprise Edition"$'\n'"$np $([[ $np -eq 1 ]] && printf 'patch' || printf 'patches') in the database home${GRID_HOME:+; the Grid home matches too}"
    return 0
  fi
  NOW="The homes here do not have the same patches as the primary:"$'\n'"${report%$'\n'}"
  KIND_NOW=manual; MANUAL_HOW="root or $ORACLE_USER  ->  each step names the user"
  PLAN="-- Apply the primary's patches to the homes on this server.
-- 1) On the primary, as the owner of each home, list its patches:
<home>/OPatch/opatch lspatches
-- 2) Put the newest OPatch (patch 6880880) into $DB_HOME${GRID_HOME:+ and $GRID_HOME}."
  if use_grid; then
    PLAN+=$'\n'"-- 3) Apply the Release Update, as root:"
    PLAN+=$'\n'"$GRID_HOME/OPatch/opatchauto apply <RU folder> -oh $GRID_HOME ; $DB_HOME/OPatch/opatchauto apply <RU folder> -oh $DB_HOME"
  else
    PLAN+=$'\n'"-- 3) Apply the Release Update, as $ORACLE_USER:"
    PLAN+=$'\n'"cd <RU folder> ; $DB_HOME/OPatch/opatch apply"
  fi
  PLAN+=$'\n'"-- 4) Apply the one-off patches, as $ORACLE_USER:"
  PLAN+=$'\n'"cd <patch folder> ; $DB_HOME/OPatch/opatch apply"
  [[ $DB_MAJOR -ge 18 ]] && PLAN+=$'\n'"-- Easier: install from a gold image of the primary home, as shown in step 3.1."
  if use_grid && ! single_owner; then
    PLAN+=$'\n'"-- After opatch on the database home (role separation), as root:"
    PLAN+=$'\n'"$GRID_HOME/bin/setasmgidwrap o=$DB_HOME/bin/oracle"
  fi
  return 1
}

phase_3() {
  phase_header 3 "Install the Oracle software"
  build_envs_if_possible
  run_step 3.1  auto  "Installer files" c_3_1 d_3_1
  run_step 3.2  auto  "Grid Infrastructure software (Oracle Restart)" c_3_2 d_3_2
  run_step 3.3  auto  "Grid root scripts" c_3_3 d_3_3
  run_step 3.4  auto  "ASM and listener (Grid configuration)" c_3_4 d_3_4
  run_step 3.5  auto  "ASM disk groups (same names as primary)" c_3_5 d_3_5
  run_step 3.6  auto  "Database software (Software Only)" c_3_6 d_3_6
  run_step 3.7  auto  "Database root.sh" c_3_7 d_3_7
  run_step 3.8  auto  "Read/write Oracle home" c_3_8 d_3_8
  run_step 3.9  auto  "Oracle Restart resources ONLINE" c_3_9 d_3_9
  run_step 3.10 auto  "Listener port equal to primary ($PORT)" c_3_10 d_3_10
  run_step 3.11 check "Same release and patches as primary" c_3_11
}
