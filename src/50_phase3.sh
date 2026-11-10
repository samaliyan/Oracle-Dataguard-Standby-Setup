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
media_room() {
  # $1 Grid media, $2 database media (comma lists; empty = not unpacked now) -> 1 (NOW/PLAN set) when a file
  # system has not about 2.5 times the size of the zips free. They are unpacked into the home (image) or the
  # stage folder (staged 12.x media). A home that already holds files (an unzip that stopped) is not counted:
  # step 3.2 / 3.6 deal with it.
  local -A need_mnt=(); local x fl dest zmb mnt short="" unread="" f
  for x in grid db; do
    if [[ $x == grid ]]; then fl=$1; dest=$GRID_HOME; else fl=$2; dest=$DB_HOME; fi
    [[ -n "$fl" ]] || continue
    local -a mfl=(); IFS=',' read -ra mfl <<< "$fl"
    # readable by the user who unpacks it (root reads any file; the unzip runs as the owner of the home)
    local uu; [[ $x == grid ]] && uu=$GRID_USER || uu=$ORACLE_USER
    for f in "${mfl[@]}"; do [[ -r "$f" ]] && runuser -u "$uu" -- test -r "$f" 2>/dev/null || unread+="  $f  (as $uu)"$'\n'; done
    zmb=$(for f in "${mfl[@]}"; do stat -c '%s' -- "$f" 2>/dev/null; done | awk '{s += $1} END {printf "%d", s / 1048576}')
    # staged media (12.x): unpacked into the stage folder, then installed into the home: both count
    local dd; for dd in $(media_is_staged "$fl" && printf '%s ' "$(stage_dir "$x")"; printf '%s' "$dest"); do
      [[ -d "$dd" ]] && ! dir_empty "$dd" && continue
      mnt=$(mnt_of "$dd")
      [[ -n "$mnt" ]] || { short+="The free space for $dd could not be measured (df)."$'\n'; continue; }
      need_mnt[$mnt]=$(( ${need_mnt[$mnt]:-0} + zmb * 25 / 10 ))
    done
  done
  for mnt in "${!need_mnt[@]}"; do
    [[ $(free_mb_of "$mnt") -ge ${need_mnt[$mnt]} ]] || short+="$mnt has $(human_mb "$(free_mb_of "$mnt")") free. Unpacking the installer files needs about $(human_mb "${need_mnt[$mnt]}")."$'\n'
  done
  if [[ -n "$unread" ]]; then
    NOW="These installer files are missing or cannot be read:"$'\n'"${unread%$'\n'}"
    KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
    PLAN="-- Put them back (owner root, mode 644), or set GRID_MEDIA / DB_MEDIA again:  $SELF --settings  (choose e)."$'\n'"-- Every folder above a file must be open to that user too. To see where it stops:  namei -l <file>"$'\n'"-- Then answer r."
    return 1
  fi
  [[ -z "$short" ]] && return 0
  NOW="Not enough space to unpack the installer files:"$'\n'"${short%$'\n'}"
  KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
  local m; PLAN="-- See how full it is, and the largest folders on it:"
  for m in "${!need_mnt[@]}"; do [[ $(free_mb_of "$m") -ge ${need_mnt[$m]} ]] && continue; PLAN+=$'\n'"df -h $m"$'\n'"du -xh $m 2>/dev/null | sort -h | tail -n 15"; done
  PLAN+=$'\n'"-- Move or delete what is not needed there (never files of a running database), or make the file system bigger."$'\n'"-- You should then see more free space with df -h. Then answer r."
  return 1
}
F_GRID=""; F_DB=""
c_3_1() {
  users_ok || { NOW="The Oracle users do not exist yet (step 2.2)"; return 2; }
  local need_g=0 need_d=0
  local inst=""
  if use_grid; then grid_state; [[ "$GSTATE" == "NEED_UNZIP" ]] && need_g=1; [[ "$GSTATE" == NEED_UNZIP || "$GSTATE" == NEED_INSTALL ]] && inst+=" grid"; fi
  db_state; [[ "$DSTATE" == "NEED_UNZIP" ]] && need_d=1; [[ "$DSTATE" == NEED_UNZIP || "$DSTATE" == NEED_INSTALL ]] && inst+=" db"
  # a Release Update in RU_DIR is applied by the installer: it must be one the primary has (found now, not after
  # two installs at step 3.11), also when the software is unpacked but not installed yet; only the homes that
  # are installed now are compared
  [[ -n "$inst" ]] && { ru_matches_primary "$inst" || return 1; }
  if [[ $need_g -eq 0 && $need_d -eq 0 ]]; then NOW="Not needed: the software is already unpacked or installed"; return 0; fi
  # files already named in the settings are checked like found ones: right kind (Grid / database) and release
  if { [[ $need_g -eq 0 ]] || { media_ok "$GRID_MEDIA" && media_matches "$GRID_MEDIA" grid; }; } \
     && { [[ $need_d -eq 0 ]] || { media_ok "$DB_MEDIA" && media_matches "$DB_MEDIA" db; }; }; then
    media_room "$([[ $need_g -eq 1 ]] && printf '%s' "$GRID_MEDIA")" "$([[ $need_d -eq 1 ]] && printf '%s' "$DB_MEDIA")" || return 1
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
    # one line of each kind per missing file (12.1 with Grid: both 2of2 files can be missing)
    local m2 cpl="" chl="" lsl=""
    for m2 in $miss2; do
      cpl+=$'\n'"scp <user>@<server>:<folder>/$(basename "$m2") $(dirname "$m2")/"
      chl+=$'\n'"chmod 644 $m2"
      [[ "$lsl " == *" $(dirname "$m2") "* ]] || lsl+=" $(dirname "$m2")"
    done
    KIND_NOW=manual; MANUAL_HOW="root"; PLAN="-- Copy$miss2 into the folder of the first file, for example:$cpl$chl"$'\n'"ls -l$lsl"$'\n'"-- Then answer r."
    return 1
  fi
  if [[ ( $need_g -eq 1 && -z "$F_GRID" ) || ( $need_d -eq 1 && -z "$F_DB" ) ]]; then
    NOW="No installer files found for:$([[ $need_g -eq 1 && -z "$F_GRID" ]] && printf ' Grid %s' "$(want_rel grid)")$([[ $need_d -eq 1 && -z "$F_DB" ]] && printf ' database %s' "$(want_rel)")"
    NOW+=$'\n'"Searched in: ${ZIP_DIRS[*]}"
    [[ -n "$MEDIA_REFUSED" ]] && NOW+=$'\n'"Not used, because of their owner or mode:"$'\n'"${MEDIA_REFUSED%$'\n'}"
    KIND_NOW=manual; MANUAL_HOW="the user named on each line"; MANUAL_WHERE="Run on the PRIMARY ($PRIMARY_HOST) and on this server ($(hostname -s))"
    local wg=""; [[ $need_g -eq 1 ]] && wg=" and grid"
    PLAN="-- On this server, as root:"$'\n'"mkdir -p /stage"
    PLAN+=$'\n'"-- Copy the files into /stage (with WinSCP, or from the server that has them), for example:"
    # every file of the media: 12.1 has two zips each (1of2 and 2of2)
    local mk mn mfound
    for mk in db grid; do
      [[ $mk == db && $need_d -eq 1 && -z "$F_DB" ]] || [[ $mk == grid && $need_g -eq 1 && -z "$F_GRID" ]] || continue
      mfound=0
      for mn in $(base_media_name $mk "$(want_rel "$mk")"); do
        [[ "$mn" == *.zip ]] && { PLAN+=$'\n'"scp <user>@<server>:<folder>/$mn /stage/"; mfound=1; }
      done
      [[ $mfound -eq 1 ]] || PLAN+=$'\n'"scp <user>@<server>:<folder>/<the $mk zip file> /stage/"
    done
    PLAN+=$'\n'"chmod 644 /stage/*.zip"$'\n'"ls -l /stage"$'\n'"-- ls must show the zip file(s), owner root. Then answer r."
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
  media_room "$F_GRID" "$F_DB" || return 1
  NOW="Installer files found"
  # only the settings of this script change (nothing on the server): saved without a question (kind ask: the do
  # part runs at once, and its result shows them again)
  KIND_NOW=ask
  PLAN="Use these installer files:"
  [[ $need_g -eq 1 ]] && PLAN+=$'\n'"  Grid:      $(media_desc "$F_GRID")"
  [[ $need_d -eq 1 ]] && PLAN+=$'\n'"  Database:  $(media_desc "$F_DB")"
  if [[ "$MODE" == check ]]; then PLAN+=$'\n'"A normal run saves them in $SETTINGS_FILE, without a question (only the script's settings change):"
  else PLAN+=$'\n'"Saved now in $SETTINGS_FILE (only the script's settings change, so there is no question):"; fi
  [[ $need_g -eq 1 ]] && PLAN+=$'\n'"  GRID_MEDIA=$F_GRID"
  [[ $need_d -eq 1 ]] && PLAN+=$'\n'"  DB_MEDIA=$F_DB"
  USING="Files of another release than $(want_rel) are ignored."$'\n'"A gold image must come from the primary."
  # base media + a patched primary: say it now, not after two hours of installing
  local pp; pp=$(primary_patches "$DB_HOME" 2>/dev/null | head -n 3 | paste -sd' ' -)
  if [[ -n "$pp" && -z "$RU_DIR" ]] && media_is_gold "${F_DB:-${F_GRID:-}}"; then :   # gold image: same patches
  elif [[ -n "$pp" && -z "$RU_DIR" ]]; then
    USING+=$'\n'"The primary has patches ($pp ...). These base files do not have them."
    USING+=$'\n'"Step 3.11 then asks you to apply them by hand (opatchauto, about an hour)."
    USING+=$'\n'"Faster: unzip the primary's Release Update on this server and set the value \"Release Update\""
    USING+=$'\n'"(RU_DIR and OPATCH_ZIP) on the summary screen of step 1.4: the installer then applies it."
    USING+=$'\n'"To do that now: answer q at the next question and run $SELF again (or $SELF --settings)."
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
d_3_1() {
  # no question before it (kind ask): it only records the files the check found and showed
  [[ -n "$F_GRID" ]] && GRID_MEDIA=$F_GRID; [[ -n "$F_DB" ]] && DB_MEDIA=$F_DB
  save_settings || return 1
  DONE_MSG="Installer files saved in $SETTINGS_FILE"
}

#------------------------------------------------------------------------------
# Response files: copy the template from the media, set only the keys it has
#------------------------------------------------------------------------------
RSP=""; RSP_MISSING=""
RSP_NEXT=""        # the private folder of the next response file: named by the check, so its path is shown before [y]
rsp_plan_dir() {
  # names (does not make) the folder of the next response file: a random name, made with mkdir when it is used
  [[ -n "$RSP_NEXT" ]] || RSP_NEXT=$(mktemp -u -d /tmp/dg_rsp.XXXXXXXX) || RSP_NEXT=""
  printf '%s' "$RSP_NEXT"
}
secure_rsp() {
  # $1 name. Sets RSP: a file in a new private folder (root-owned while it is written). The folder named by the
  # check (shown before [y]) is used; a name that exists already is refused (mkdir never takes an existing entry)
  local d
  if [[ -n "$RSP_NEXT" ]]; then
    d=$RSP_NEXT; RSP_NEXT=""
    ( umask 077; mkdir -m 700 -- "$d" ) || { bad "Cannot create the private folder $d for the response file (does it exist already?)."; return 1; }
  else
    d=$(mktemp -d /tmp/dg_rsp.XXXXXXXX) || return 1
  fi
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
  [[ ${RSP_SHOW:-0} -eq 1 ]] && { rsp_show_key "$v" "$@"; return; }
  for k in "$@"; do
    # the same plain-text test as the replacement (no regular expression: the dots in the keys stay dots)
    if DG_K=$k awk 'BEGIN{k=ENVIRON["DG_K"]} { t=$0; sub(/^[[:space:]]*/, "", t); if (index(t, k "=") == 1) f=1 } END { exit !f }' "$f"; then
      local rc=0
      # the value may be a password: it reaches awk through a pipe, never in its environment or arguments
      ( umask 077; DG_K=$k awk 'BEGIN{k=ENVIRON["DG_K"]; if ((getline v < "/dev/fd/3") <= 0) v = ""}
        { t=$0; sub(/^[[:space:]]*/, "", t)
          if (index(t, k "=") == 1) { print k "=" v; next } print }' "$f" 3< <(printf '%s\n' "$v") > "$f.new" ) && cat "$f.new" > "$f" || rc=1
      rm -f -- "$f.new"          # it may hold a password: never left behind
      return $rc
    fi
  done
  return 1
}
rsp_need() { rsp_set "$@" || RSP_MISSING+=" $3"; }       # a key the installation cannot work without
# ---- what the script sets in a response file, shown before [y] (the same key functions that write it) ----
RSP_SHOW=0; RSP_SHOW_OUT=""; RSP_SHOW_TPL=""; RSP_SHOW_READ=0
rsp_show_key() {
  # $1 value, rest = key names: the line the key function would set (a password is *****). With the template read
  # (RSP_SHOW_READ=1): the key name the template has, and 1 when it has none of them (as rsp_set)
  local v=$1 k; shift
  [[ "$*" == *[Pp]assword* ]] && v='*****'
  if [[ $RSP_SHOW_READ -eq 1 ]]; then
    for k in "$@"; do
      if DG_K=$k awk 'BEGIN{k=ENVIRON["DG_K"]} { t=$0; sub(/^[[:space:]]*/, "", t); if (index(t, k "=") == 1) f=1 } END { exit !f }' <<< "$RSP_SHOW_TPL"; then
        RSP_SHOW_OUT+="  $k=$v"$'\n'; return 0
      fi
    done
    return 1
  fi
  # the template is not on this server yet (it is in the zip): the first name, and the others the media may use
  RSP_SHOW_OUT+="  $1=$v$([[ $# -gt 1 ]] && printf '   (or %s)' "${*:2}")"$'\n'
  return 0
}
rsp_show_text() {
  # $1 template, $2 its owner, rest = the key function and its arguments. Prints the key=value lines it sets
  # (run in a subshell: nothing of it stays)
  (
    RSP_SHOW=1; RSP_SHOW_OUT=""; RSP_MISSING=""; RSP_SHOW_READ=0; RSP_SHOW_TPL=""
    # read as its owner, as make_rsp does
    [[ -f "$1" ]] && RSP_SHOW_TPL=$(runuser -u "$2" -- cat -- "$1" 2>/dev/null) && RSP_SHOW_READ=1
    local tpl=$1; shift 2
    "$@" > /dev/null 2>&1
    printf '%s' "$RSP_SHOW_OUT"
    [[ -n "$RSP_MISSING" ]] && printf '  Not in the template %s (the step stops before the installer):%s\n' "$tpl" "$RSP_MISSING"
    return 0
  )
}
make_rsp() {
  # $1 template, $2 owner. Copies the template into a private file (RSP).
  local tpl=$1 name; name=$(basename "$tpl")
  RSP_TEMPLATE=$tpl
  [[ -f "$tpl" ]] || { bad "The response file template is not in the media: $tpl"; return 1; }
  secure_rsp "$name" || return 1
  # read as its owner: the media folder belongs to $2, who could put a link to a root-only file in its place
  # (the copy is given to $2 later)
  ( umask 077; set -C; runuser -u "$2" -- cat -- "$tpl" > "$RSP" ) || { bad "The response file template cannot be read as $2: $tpl"; return 1; }
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
# Jobs shown before [y]
#   Unzip, the installers and the root scripts run as jobs (run_long: their own session), not from the cp list.
#   The check adds each job's exact command line with job_show_add (built by the same functions the do part
#   uses) and puts the list into PLAN ("In this order"); job_launch starts only a job that was shown so,
#   with the line "Running as <user> (a job): <command>".
#------------------------------------------------------------------------------
JOB_SHOWN=(); ORDER_LINES=()
job_show_reset() { JOB_SHOWN=(); ORDER_LINES=(); }
argv_text() {
  # words -> one command line as a person would type it (a word with other characters is quoted)
  local w out="" q="'"
  for w in "$@"; do
    if [[ -n "$w" && "$w" =~ ^[A-Za-z0-9_./,:+=@%-]+$ ]]; then out+="$w "; else out+="$q${w//$q/$q\\$q$q}$q "; fi
  done
  printf '%s' "${out% }"
}
job_user() { case "$1" in grid) printf '%s' "$GRID_USER" ;; oracle) printf '%s' "$ORACLE_USER" ;; *) printf 'root' ;; esac; }
role_of_user() { if [[ "$1" == "$GRID_USER" ]]; then printf grid; elif [[ "$1" == "$ORACLE_USER" ]]; then printf oracle; else printf root; fi; }
job_env_note() {
  # a CV_ASSUME_DISTID the installer gets in its environment is part of what runs
  local x; local -a e=()
  case "$1" in grid) e=("${GRID_ENV[@]+"${GRID_ENV[@]}"}") ;; oracle) e=("${ORA_ENV[@]+"${ORA_ENV[@]}"}") ;; esac
  for x in "${e[@]+"${e[@]}"}"; do [[ "$x" == CV_ASSUME_DISTID=* ]] && printf '   (environment: %s)' "$x"; done
  return 0
}
order_add() { ORDER_LINES+=("$1"); }
job_show_add() {
  # $1 who (root | grid | oracle), rest = the command of a job the do part starts
  local who=$1; shift
  JOB_SHOWN+=("$who|$(argv_text "$@")")
  order_add "as $(job_user "$who") (a job):  $(argv_text "$@")$(job_env_note "$who")"
}
order_text() {
  # the numbered list for PLAN (empty when there is nothing): every job and command of the step, in the order
  # they run, once. A job is shown here with its exact command; a command of the "Will run" list is named here
  # and shown there (the jobs are not in that list: they do not run from it)
  local i n=${#ORDER_LINES[@]}
  [[ $n -gt 0 ]] || return 0
  printf 'In this order (a job runs in its own session; its output goes to a file in %s):\n' "$LOG_DIR"
  for ((i = 0; i < n; i++)); do printf '  %s. %s\n' "$((i + 1))" "${ORDER_LINES[$i]}"; done
}
job_say() { local who=$1; shift; say "${C_D}Running as $(job_user "$who") (a job):${C_N} $(argv_text "$@" | mask_pw)"; }
job_launch() {
  # $1 title, $2 output file, $3 who, rest = command. Starts it with run_long only when exactly this job was shown
  # before [y]; else nothing runs (what runs must have been shown)
  local title=$1 out=$2 who=$3; shift 3
  local txt e ok=0; txt=$(argv_text "$@")
  for e in "${JOB_SHOWN[@]+"${JOB_SHOWN[@]}"}"; do [[ "$e" == "$who|$txt" ]] && { ok=1; break; }; done
  if [[ $ok -eq 0 ]]; then
    _log FAIL "job not in the shown list: as $who: $txt"
    bad "Internal error: this job was not shown before, so it is not started:"$'\n'"  as $(job_user "$who"): $txt"$'\n'"Answer r: the step shows what it runs now."
    RUN_OUT=""; JOB_KEEP=""; return 1
  fi
  job_say "$who" "$@"
  run_long "$title" "$out" "" "$who" "$@"
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

#------------------------------------------------------------------------------
# The installer's own log after a failure (the failed prerequisite checks are only there)
#   19c/21c/23ai: /tmp/GridSetupActions<date>/gridSetupActions<date>.log, /tmp/InstallActions<date>/installActions<date>.log
#   (copied to <inventory>/logs/GridSetupActions<date>/ at the end); 12.x: <inventory>/logs/installActions<date>.log
#   (/tmp/OraInstall<date>/ while it runs). The installer names its log in its output; else the newest one is taken.
#------------------------------------------------------------------------------
installer_log_find() {
  # $1 installer output, $2 start time (epoch seconds), $3 user the installer ran as. Prints the log file: the first
  # one the output names that this user can read, else the newest installer log written since $2
  local f u=$3 t inv; inv=$(inventory_dir)
  while IFS= read -r f; do
    [[ -n "$f" && "$f" != *..* && -f "$f" && ! -L "$f" ]] || continue
    runuser -u "$u" -- test -r "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
  done < <(grep -oE '/[A-Za-z0-9_.,:+@%=/-]+\.log' <<< "$1" | awk -v d="$LOG_DIR/" 'index($0, d) != 1 && !s[$0]++')
  # newest first; only files of this run of the installer (written since it started)
  while IFS= read -r f; do
    [[ -n "$f" && ! -L "$f" ]] || continue
    t=$(stat -c '%Y' -- "$f" 2>/dev/null) || continue
    [[ $t -ge $(( $2 - 5 )) ]] || continue
    runuser -u "$u" -- test -r "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
  done < <(ls -1t -- /tmp/GridSetupActions*/gridSetupActions*.log /tmp/InstallActions*/installActions*.log \
             /tmp/OraInstall*/installActions*.log "$inv"/logs/*Actions*/*Actions*.log "$inv"/logs/[Ii]nstallActions*.log 2>/dev/null)
  return 1
}
installer_failed_checks() {
  # $1 log file, $2 user who can read it (the installer user: never root, so the output names no other file).
  # Prints the failed checks: the "List of failed Tasks" section (name and severity), then the PRVF-/PRVG-/PRVE-
  # messages; without either, the lines that say a check failed. At most 15 lines.
  runuser -u "$2" -- cat -- "$1" 2>/dev/null | awk '
    { l = $0; sub(/\r$/, "", l)
      # INFO:  [Mar 21, 2020 10:56:20 AM] text   (12.x: INFO: text)
      sub(/^(INFO|WARNING|SEVERE|CONFIG|FINE|ERROR):[[:space:]]*(\[[^]]*\][[:space:]]*)?/, "", l)
      sub(/^[[:space:]]+/, "", l); sub(/[[:space:]]+$/, "", l) }
    l ~ /List of failed Tasks/ { sec = 1; want = 1; next }
    l ~ /End of failed Tasks/  { sec = 0; next }
    sec && l ~ /^\*+$/ { want = 1; next }
    sec && want && l != "" { t = l; if (match(l, /: This is /)) t = substr(l, 1, RSTART - 1); else sub(/: .*/, "", t); if (!(t in seen)) { seen[t] = 1; task[++nt] = t }; cur = t; want = 0; next }
    sec && l ~ /^Severity:/ { s = l; sub(/^Severity:[[:space:]]*/, "", s); if (cur != "") sev[cur] = s; next }
    # PRVF-7573 : Sufficient swap size is not available ...   (the message of a failed check; once per id)
    match(l, /PRV[FGE]-[0-9]+ *:/) { m = substr(l, RSTART); if (length(m) > 150) m = substr(m, 1, 147) "..."
      id = m; sub(/ *:.*/, "", id); if (!(id in pseen)) { pseen[id] = 1; prv[++np] = m }; next }
    l ~ /Verification .*(failed|FAILED)|Status:[[:space:]]*FAILED|:[[:space:]]*FAILED$|\.\.\.FAILED|^Result: .*failed/ {
      if (length(l) > 150) l = substr(l, 1, 147) "..."; if (!(l in fseen)) { fseen[l] = 1; other[++no] = l } }
    END {
      n = 0
      for (i = 1; i <= nt && n < 10; i++) { printf "%s%s\n", task[i], (sev[task[i]] != "" ? "  (" sev[task[i]] ")" : ""); n++ }
      for (i = 1; i <= np && n < 15; i++) { print prv[i]; n++ }
      if (n == 0) for (i = 1; i <= no && i <= 10; i++) print other[i]
    }'
}
PREREQ_NAMES=""
prereq_report() {
  # after a failed installer run: $1 output, $2 start time, $3 user. Shows its log and the failed checks in it.
  # PREREQ_NAMES: the names of the failed checks, for the summary
  local log chk
  PREREQ_NAMES=""
  log=$(installer_log_find "$1" "$2" "$3") || log=""
  if [[ -z "$log" ]]; then
    local named; named=$(grep -oE '/[A-Za-z0-9_.,:+@%=/-]+\.log' <<< "$1" | awk -v d="$LOG_DIR/" 'index($0, d) != 1' | head -n 1)
    printf 'Installer log: %s\n' "${named:-not named in its output, and none found in /tmp or $(inventory_dir)/logs}${named:+  (not found, or $3 cannot read it)}" | hint
    printf 'The failed checks are listed in that log only.\n' | hint
    return 0
  fi
  printf 'Installer log: %s\n' "$log" | hint
  chk=$(installer_failed_checks "$log" "$3")
  if [[ -z "$chk" ]]; then
    printf 'No failed check could be read from it. Look for "List of failed Tasks" or PRVF- / PRVG- in it:\n  grep -nE "List of failed Tasks|PRV[FGE]-" %s\n' "$log" | hint
    return 0
  fi
  printf 'Failed prerequisite checks:\n' | hint
  sed 's/^/  /' <<< "$chk" | hint
  PREREQ_NAMES=$(grep -vE '^PRV|^Verification|Status:|^Result:' <<< "$chk" | sed 's/  (.*//' | head -n 4 | paste -sd',' - | sed 's/,/, /g')
  [[ -n "$PREREQ_NAMES" ]] || PREREQ_NAMES=$(grep -oE '^PRV[FGE]-[0-9]+' <<< "$chk" | head -n 4 | paste -sd',' - | sed 's/,/, /g')
  return 0
}
installer_prereq_failed() { grep -qE 'INS-13013|INS-13014|INS-13016|PRVF-|PRVG-|PRVE-' <<< "$1"; }
strip_ru_args() {
  # the words of $@ without -applyRU / -applyPSU and their folder, into STRIP_ARGV (a retry never applies a Release
  # Update a second time: the failed try may have applied it already)
  STRIP_ARGV=(); local -a a=("$@"); local i=0
  while [[ $i -lt ${#a[@]} ]]; do
    if [[ "${a[$i]}" == "-applyRU" || "${a[$i]}" == "-applyPSU" ]]; then i=$((i + 2)); continue; fi
    STRIP_ARGV+=("${a[$i]}"); i=$((i + 1))
  done
}
STRIP_ARGV=()

INS08101_RETRIED=0
run_installer() {
  # $1 title, $2 runner (as_oracle | as_grid), $3 "ignore prerequisites" flag of this installer, rest = command.
  # Exit codes 0 and 6 are success. After failed prerequisite checks: shows them, then offers to run it again
  # (after a fix) or to run it again ignoring them (typed IGNORE).
  local title=$1 runner=$2 ign=$3; shift 3
  INS08101_RETRIED=0
  local who=oracle; [[ "$runner" == "as_grid" ]] && who=grid
  # an old success record (an earlier install, removed by hand since) must not count for this run of the installer
  case "$title" in
    "Grid installer"*) rm -f -- "$STATE_DIR/grid_install.done" ;;
    "Database installer"*) rm -f -- "$STATE_DIR/db_install.done" ;;
    "Grid configuration tools"*) rm -f -- "$STATE_DIR/grid_config.done" ;;
  esac
  local out; out="$LOG_DIR/$(tr -c 'A-Za-z0-9\n' '_' <<< "$title" | tr -s '_' | tr -d '\n')_$RUN_ID.log"
  say "Starting the $title. It runs silently and takes several minutes."
  local rc=0 keep=$JOB_KEEP t0; t0=$(date +%s)
  job_launch "$title" "$out" "$who" "$@" < /dev/null || rc=$?
  if [[ $rc -eq 0 || $rc -eq 6 ]]; then [[ $rc -eq 6 ]] && WARN_DEDUP=0 warn "$title finished with warnings. Output: ${RUN_LONG_OUT:-$out}"; installer_done_record "$title"; return 0; fi
  bad "$title failed (exit code $rc)"
  grep -E 'INS-[0-9]+|PRVF-|PRVG-|PRVE-|PRCZ-|\[FATAL\]|\[WARNING\]|SEVERE' <<< "$RUN_OUT" | head -n 15 | hint
  # a prerequisite failure: its log and the failed checks are shown below, before the question
  local lg=""
  if ! { [[ -n "$ign" ]] && installer_prereq_failed "$RUN_OUT"; }; then
    lg=$(installer_log_find "$RUN_OUT" "$t0" "$(job_user "$who")") && printf 'Installer log: %s\n' "$lg" | hint
  fi
  # the retries below never apply a Release Update a second time (the failed try may have applied it already)
  local -a args=("$@"); local home; home=$([[ "$who" == "grid" ]] && printf '%s' "$GRID_HOME" || printf '%s' "$DB_HOME")
  if ru_applied "$home"; then
    strip_ru_args "${args[@]}"; args=("${STRIP_ARGV[@]}")
    say "The Release Update is already in $home. A retry does not apply it again."
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
      rc=0; JOB_KEEP=$keep; t0=$(date +%s)
      say "The same command again, with CV_ASSUME_DISTID=$did in its environment:"
      job_say "$who" "${args[@]}"
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
  # prerequisite checks failed: show which (from the installer's log), then [r] run it again after a fix,
  # [i] run it again ignoring them (typed IGNORE), [q] quit. Each run is a job shown before it starts.
  local n=1 asked=0
  while [[ -n "$ign" ]] && installer_prereq_failed "$RUN_OUT"; do
    if [[ $asked -eq 0 ]]; then
      prereq_report "$RUN_OUT" "$t0" "$(job_user "$who")"
      ru_applied "$home" && { strip_ru_args "${args[@]}"; args=("${STRIP_ARGV[@]}"); }
      printf 'Fix them if you can. Then:
  r runs, as %s (a job):  %s
  i runs, as %s (a job):  %s
    (%s: the installer goes on although these checks fail)
' \
        "$(job_user "$who")" "$(argv_text "${args[@]}")" "$(job_user "$who")" "$(argv_text "${args[@]}" "$ign")" "$ign" | hint
      asked=1
    fi
    ask_choice "[r] I fixed them, run it again   [i] Run it again, ignore them   [q] Quit" "riq"
    case "$ANSWER" in
      q) user_stop "Stopped by you" ;;
      i)
        confirm_word "Retry and ignore the failed prerequisite checks" "IGNORE" || continue
        rc=0; JOB_KEEP=$keep
        job_say "$who" "${args[@]}" "$ign"
        run_long "$title (ignore prereq)" "${out%.log}_ign.log" "" "$who" "${args[@]}" "$ign" < /dev/null || rc=$?
        if [[ $rc -eq 0 || $rc -eq 6 ]]; then
          warn "$title finished. Failed prerequisite checks were ignored${PREREQ_NAMES:+: $PREREQ_NAMES}."
          installer_done_record "$title"; return 0
        fi
        bad "$title failed again (exit code $rc)"
        grep -E 'INS-[0-9]+|\[FATAL\]|SEVERE' <<< "$RUN_OUT" | head -n 10 | hint
        return 1 ;;
      r)
        n=$((n + 1)); rc=0; JOB_KEEP=$keep; t0=$(date +%s); asked=0
        job_say "$who" "${args[@]}"
        run_long "$title (run $n)" "${out%.log}_$n.log" "" "$who" "${args[@]}" < /dev/null || rc=$?
        if [[ $rc -eq 0 || $rc -eq 6 ]]; then
          [[ $rc -eq 6 ]] && WARN_DEDUP=0 warn "$title finished with warnings. Output: ${RUN_LONG_OUT:-${out%.log}_$n.log}"
          installer_done_record "$title"; return 0
        fi
        bad "$title failed again (exit code $rc)"
        grep -E 'INS-[0-9]+|PRVF-|PRVG-|PRVE-|\[FATAL\]|SEVERE' <<< "$RUN_OUT" | head -n 10 | hint
        # another error this time: its log (a prerequisite failure again: shown at the top of the loop)
        installer_prereq_failed "$RUN_OUT" || { lg=$(installer_log_find "$RUN_OUT" "$t0" "$(job_user "$who")") && printf 'Installer log: %s\n' "$lg" | hint; } ;;
    esac
  done
  return 1
}

ru_applied() {
  # 0 when a patch of RU_DIR (its numbered folders) is already registered in the home $1
  [[ -n "${RU_DIR:-}" && -d "$RU_DIR" && -d "$1/inventory/oneoffs" ]] || return 1
  local d id r; r=$(ru_root); [[ -n "$r" ]] || return 1
  for d in "$r" "$r"/*/; do
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
root_prog_ok() {
  # $1 a program of an Oracle home that root must run (root.sh, orainstRoot.sh, crsctl, setasmgidwrap). Oracle
  # requires it, so it cannot be avoided; but only a real file that root, oracle or grid own, in a folder of
  # theirs, and that neither group nor others can change. Else it is said, and nothing runs
  # (group write is accepted only for the Oracle install group: oraInventory is 770 grid:oinstall by design)
  local f=$1 d x u g m ok=1; d=$(dirname -- "$f")
  [[ ! -L "$f" && -f "$f" && ! -L "$d" ]] || ok=0
  for x in "$f" "$d"; do
    [[ $ok -eq 1 ]] || break
    IFS=' ' read -r u g m <<< "$(stat -c '%U %G %a' -- "$x" 2>/dev/null)"
    [[ ( "$u" == root || "$u" == "$ORACLE_USER" || "$u" == "$GRID_USER" ) && "$m" =~ ^[0-7]+$ ]] || { ok=0; break; }
    (( (8#$m & 8#002) == 0 )) || { ok=0; break; }
    (( (8#$m & 8#020) == 0 )) || [[ "$g" == "$INSTALL_GROUP" || "$g" == root ]] || ok=0
  done
  # every folder above it too (else another user could rename a folder on the way and put another program there
  # between this check and the run): the path as given, and the real path behind any link on it
  if [[ $ok -eq 1 ]]; then
    local real; real=$(readlink -f -- "$d" 2>/dev/null) || real=""
    [[ -n "$real" ]] && root_prog_path_ok "$(dirname -- "$d")" && root_prog_path_ok "$(dirname -- "$real")" || ok=0
  fi
  [[ $ok -eq 1 ]] && return 0
  bad "Not run as root: $f (or a folder above it) is a link, belongs to another user, or others can change it. Check:  ls -ld $d $f"$'\n'"and every folder above $d."
  return 1
}
root_prog_path_ok() {
  # $1 a folder: it and each folder above it up to / belong to root, oracle or grid, and no other user can rename
  # what is in them (no write for others, except a sticky folder whose next entry is theirs; group write only for
  # the install group or root). A link on the way may stand (its owner counts; the caller checks the real path)
  local p=$1 next="" u g m nu
  while :; do
    if [[ -L "$p" ]]; then
      u=$(stat -c '%U' -- "$p" 2>/dev/null)
      [[ "$u" == root || "$u" == "$ORACLE_USER" || "$u" == "$GRID_USER" ]] || return 1
    else
      IFS=' ' read -r u g m <<< "$(stat -c '%U %G %a' -- "$p" 2>/dev/null)"
      [[ ( "$u" == root || "$u" == "$ORACLE_USER" || "$u" == "$GRID_USER" ) && "$m" =~ ^[0-7]+$ ]] || return 1
      if (( (8#$m & 8#002) != 0 )); then
        # world-writable: only a sticky folder (/tmp), and only when the entry below it is not someone else's
        (( (8#$m & 8#1000) != 0 )) && [[ -n "$next" ]] || return 1
        nu=$(stat -c '%U' -- "$next" 2>/dev/null)
        [[ "$nu" == root || "$nu" == "$ORACLE_USER" || "$nu" == "$GRID_USER" ]] || return 1
      fi
      (( (8#$m & 8#020) == 0 )) || [[ "$g" == "$INSTALL_GROUP" || "$g" == root ]] || (( (8#$m & 8#1000) != 0 )) || return 1
    fi
    [[ "$p" == / ]] && return 0
    next=$p; p=$(dirname -- "$p")
  done
}
run_root_script() {
  # root scripts get no input: their questions (local bin folder, TFA) take the default answer
  [[ -x "$1" ]] || { bad "Root script not found: $1"; return 1; }
  root_prog_ok "$1" || return 1
  local out; out="$LOG_DIR/root_$(basename "$(dirname "$1")")_$(basename "$1" .sh)_$RUN_ID.log"
  local t0; t0=$(date +%s)
  if job_launch "root script $1" "$out" root "$1" < /dev/null; then say "$1 finished without error."; return 0; fi
  bad "$1 failed. The last lines of its output:"; printf '%s\n' "$RUN_OUT" | tail -n 15 | hint
  # the reason is often only in its own log (Grid: roothas_<date>.log, named in the output)
  root_log_report "$RUN_OUT" "$t0"
  return 1
}
root_log_report() {
  # $1 output of a failed root script, $2 its start time: its log (the one the output names, else the newest
  # roothas / rootcrs log written since $2) and the error lines at its end
  local f lg="" t d
  while IFS= read -r f; do
    [[ -n "$f" && "$f" != *..* && -f "$f" && ! -L "$f" ]] && { lg=$f; break; }
  done < <(grep -oE '/[A-Za-z0-9_.,:+@%=/-]+\.log' <<< "$1" | awk -v d="$LOG_DIR/" 'index($0, d) != 1' | tail -n 3 | tac)
  if [[ -z "$lg" ]]; then
    # 12.2+: <Grid base>/crsdata/<host>/crsconfig; 12.1: <Grid home>/cfgtoollogs/crsconfig
    for d in "${GRID_BASE:-/nonexistent}/crsdata/$(hostname -s)/crsconfig" "${GRID_HOME:-/nonexistent}/cfgtoollogs/crsconfig"; do
      f=$(ls -1t -- "$d"/roothas_*.log "$d"/rootcrs_*.log 2>/dev/null | head -n 1)
      [[ -n "$f" && ! -L "$f" ]] || continue
      t=$(stat -c '%Y' -- "$f" 2>/dev/null) || continue
      [[ $t -ge $(( $2 - 5 )) ]] && { lg=$f; break; }
    done
  fi
  [[ -n "$lg" ]] || return 0
  printf 'Its log: %s\n' "$lg" | hint
  local err; err=$(tail -n 400 -- "$lg" 2>/dev/null | grep -E 'CLSRSC-[0-9]+|CRS-[0-9]+|PRC[A-Z]-[0-9]+|ORA-[0-9]+|Died at|[Ee]rror|[Ff]ailed' | grep -vE 'CRS-4123|CLSRSC-4002|CLSRSC-4003' | tail -n 10 | cut -c 1-200)
  [[ -n "$err" ]] && { printf 'The last error lines in it:\n'; sed 's/^/  /' <<< "$err"; } | hint
  return 0
}
ru_args() {
  # with RU_DIR the image installer (gridSetup.sh, 18c+ runInstaller) applies that Release Update first
  # ($1 = grid: 12.2 gridSetup.sh calls the option -applyPSU; $2 = fresh: the home is emptied before, so what
  # it has now does not count)
  [[ -n "$RU_DIR" && -d "$RU_DIR" ]] || return 0
  # a home that already has the Release Update (an earlier try applied it) does not get it again
  local h; [[ "${1:-}" == "grid" ]] && h=$GRID_HOME || h=$DB_HOME
  if [[ "${2:-}" != fresh ]] && ru_applied "$h"; then say "The Release Update is already in $h. It is not applied again." >&2; return 0; fi
  # the folder of the Release Update itself (RU_DIR, or the one numbered folder in it)
  local r; r=$(ru_root); [[ -n "$r" ]] || r=$RU_DIR
  if [[ "${1:-}" == "grid" && "$(want_rel grid)" == "12.2" ]]; then printf '%s\n' -applyPSU "$r"
  else printf '%s\n' -applyRU "$r"; fi
}
OP_CMDS=""; OP_HAVE=""; OP_WANT=""; OP_ERR=""
opatch_cmds() {
  # $1 home, $2 "now" or "media=<comma list of zips>" (the home is empty now and gets that media first).
  # OP_CMDS: the commands (one per line) that put the OPatch of OPATCH_ZIP into the home: none without RU_DIR,
  # or when the home has that OPatch (or a newer one) already. The old OPatch is kept next to it (no rm -rf of a
  # part of a home), except the half copy of a failed try in this run. 1 = OPATCH_ZIP cannot be used (OP_ERR).
  local h=$1 src=$2 exists=0 bak=0 f
  OP_CMDS=""; OP_HAVE=""; OP_WANT=""; OP_ERR=""
  [[ -n "$RU_DIR" ]] || return 0
  [[ -n "$OPATCH_ZIP" && -f "$OPATCH_ZIP" ]] || { OP_ERR="RU_DIR is set, but OPATCH_ZIP is not. It must name the newest OPatch zip (p6880880).
Set it with:  $SELF --settings   (choose e)"; return 1; }
  media_trusted "$OPATCH_ZIP" || { OP_ERR="$OPATCH_ZIP is not used: its owner or mode is not safe.
The owner must be root, $ORACLE_USER or $GRID_USER, and only the owner may change it."; return 1; }
  OP_WANT=$(unzip -p "$OPATCH_ZIP" OPatch/version.txt 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)
  if [[ "$src" == now ]]; then
    OP_HAVE=$(grep -oE '[0-9]+(\.[0-9]+)+' "$h/OPatch/version.txt" 2>/dev/null | head -n 1)
    [[ -e "$h/OPatch" ]] && exists=1
    [[ -e "$h/OPatch" && -e "$h/OPatch.bak_$RUN_ID" ]] && bak=1
  else
    # the OPatch the media brings
    local -a mz=(); IFS=',' read -ra mz <<< "${src#media=}"
    for f in "${mz[@]}"; do
      unzip -Z1 "$f" 2>/dev/null | grep -q '^OPatch/' || continue
      exists=1; OP_HAVE=$(unzip -p "$f" OPatch/version.txt 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)
    done
  fi
  if [[ -n "$OP_WANT" && -n "$OP_HAVE" ]] && ! ver_lt "$OP_HAVE" "$OP_WANT"; then return 0; fi
  if [[ $bak -eq 1 ]]; then OP_CMDS+="$(argv_text rm -rf --one-file-system -- "$h/OPatch")"$'\n'
  elif [[ $exists -eq 1 ]]; then OP_CMDS+="$(argv_text mv -T -- "$h/OPatch" "$h/OPatch.bak_$RUN_ID")"$'\n'; fi
  OP_CMDS+="$(argv_text unzip -q -o "$OPATCH_ZIP" -d "$h")"
  return 0
}
opatch_plan() {
  # check: $1 home, $2 role (grid | oracle), $3 as for opatch_cmds. Adds the commands to the shown list
  local c
  # the do part stops there and says what is wrong with OPATCH_ZIP
  opatch_cmds "$1" "$3" || { order_add "(the step stops here: RU_DIR is set, but OPATCH_ZIP cannot be used: ${OP_ERR%%$'\n'*})"; return 0; }
  [[ -n "$OP_CMDS" ]] || return 0
  while IFS= read -r c; do [[ -n "$c" ]] && cp_add "$2" "$c"; done <<< "$OP_CMDS"
  order_add "as $(job_user "$2"): put the newer OPatch into $1 (the commands under \"Will run\"; the Release Update needs it)"
}
new_opatch() {
  # $1 home, $2 runner, $3 owner: the Release Update needs a newer OPatch than the base media has.
  # Runs the commands shown before [y] (opatch_plan); a command that was not shown is refused.
  [[ -n "$RU_DIR" ]] || return 0
  local role=grid c; [[ "$2" == as_oracle ]] && role=oracle
  opatch_cmds "$1" now || { bad "$OP_ERR"; return 1; }
  if [[ -z "$OP_CMDS" ]]; then say "$1/OPatch is already version $OP_HAVE. The zip has $OP_WANT: nothing to do."; return 0; fi
  say "Replacing $1/OPatch with the one in $OPATCH_ZIP. The Release Update needs it."
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    if ! cp_run_one "$role" "$c"; then
      case "$c" in
        rm\ *) bad "Cannot remove $1/OPatch." ;;
        mv\ *) bad "Cannot move $1/OPatch aside." ;;
        *) bad "The unzip of OPatch failed: $(tail -n 3 <<< "$RUN_OUT")" ;;
      esac
      return 1
    fi
    [[ "$c" == "mv "* ]] && journal OPATCH "$1/OPatch" "old=$1/OPatch.bak_$RUN_ID"
  done <<< "$OP_CMDS"
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
    PLAN="Nothing is installed there: it is emptied, then the files are unpacked again."
    local i; for i in "${!SW_UNZIP_DIRS[@]}"; do [[ -d "${SW_UNZIP_DIRS[$i]}" ]] && sw_empty_plan "${SW_UNZIP_DIRS[$i]}"; done
    order_add "as root: empty the incomplete folder (the command under \"Will run\")"
    return 1
  fi
  SW_UNZIP_DIRS=(); SW_UNZIP_OUTS=()
  KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
  # the exact commands: the check that no installed home uses the folder, then emptying it (one per line)
  local chk="" emp=""
  while IFS='|' read -r t o dest; do
    [[ -n "$t" && -n "$dest" ]] || continue
    chk+="grep -c '\"$dest\"' $INVENTORY_DIR/ContentsXML/inventory.xml"$'\n'
    emp+="find $dest -xdev -mindepth 1 -delete"$'\n'
  done < "$(unzip_marker)"
  PLAN="-- First check that nothing is installed there (each command must print 0):"$'\n'"${chk:-# the folder is not recorded: it is the home or stage folder of that file}"
  PLAN+=$'\n'"-- Then empty it (hidden files too), and nothing else:"$'\n'"${emp:-find <that folder> -xdev -mindepth 1 -delete}"
  PLAN+=$'\n'"-- Then remove its line from the list of failed unzips:"$'\n'"${rmcmd%$'\n'}"
  PLAN+=$'\n'"-- Then answer r. The files are unpacked again."
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
sw_empty_cmd() {
  # $1 folder (a plain path, checked with sw_folder_ok): the command that empties it, run as root.
  # find -delete works relative to the folders it has open (no path is read again): a folder above that the
  # software owner swaps for a link meanwhile cannot lead the deletion anywhere else.
  # The plain command; only a folder that is a mount point with lost+found gets the guard that keeps it (shown
  # so on the screen too: the same text runs). A lost+found made between the check and [y] makes the do part
  # refuse: the command it would build is no longer the one shown.
  if [[ -d "$1/lost+found" ]]; then printf "find %s -xdev -mindepth 1 ! -path '%s/lost+found' ! -path '%s/lost+found/*' -delete" "$1" "$1" "$1"
  else printf 'find %s -xdev -mindepth 1 -delete' "$1"; fi
}
sw_empty_plan() { cp_add root "$(sw_empty_cmd "$1")" "" 3600; }     # check: the emptying of folder $1 in the shown list
sw_empty_folder() {
  # $1 folder (checked with sw_folder_ok). Everything in it goes, hidden files too; the folder itself and a
  # lost+found of a mount point stay.
  local d=$1
  sw_folder_ok "$d" || { bad "Not emptied: $d is not a software folder of this setup, or a program of it runs."; return 1; }
  [[ -d "$d" ]] || return 0
  # the command shown before [y] (sw_empty_cmd)
  cp_run_one root "$(sw_empty_cmd "$d")" || { bad "Emptying $d failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
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
INVMARK_FILE=""; INVMARK_MD5=""; INVMARK_USER=""; INVMARK_CMD=""; INVMARK_BAK=""
inventory_mark_plan() {
  # check: $1 home. The way the Oracle installer detaches a home - its HOME entry gets REMOVED="T". The whole new
  # inventory.xml goes into the shown list, written in place by the owner of the file (cat > file: owner, group
  # and mode stay); before it, a backup made by the owner (--undo puts the file back). Nothing set when the home
  # is not in it; 1 when it cannot be marked.
  INVMARK_FILE=""; INVMARK_MD5=""; INVMARK_USER=""; INVMARK_CMD=""; INVMARK_BAK=""
  local inv u new r; inv="$(inventory_dir)/ContentsXML/inventory.xml"
  [[ -f "$inv" ]] || return 0
  in_inventory "$1" || return 0
  [[ ! -L "$inv" ]] || return 1
  new=$(awk -v loc="LOC=\"$1\"" 'index($0, "<HOME ") && index($0, loc) && !index($0, "REMOVED=") { sub(/[[:space:]]*\/?>/, " REMOVED=\"T\"&") } { print }' "$inv") || return 1
  grep -q "LOC=\"$1\"[^>]*REMOVED=\"T\"" <<< "$new" || return 1
  u=$(stat -c '%U' -- "$inv"); r=$(role_of_user "$u")
  INVMARK_FILE=$inv; INVMARK_MD5=$(file_md5 "$inv"); INVMARK_USER=$u
  # the backup (as backup_file makes it: never readable by others), then the new content
  INVMARK_BAK="$(argv_text cp -p -- "$inv" "$inv.bak_$RUN_ID") && $(argv_text chmod o-rwx -- "$inv.bak_$RUN_ID")"
  INVMARK_CMD="cat > $(argv_text "$inv")"
  cp_add "$r" "$INVMARK_BAK"
  cp_add "$r" "$INVMARK_CMD" "$new"
  return 0
}
inventory_mark_removed() {
  # do: $1 home. Writes the inventory shown before [y] (inventory_mark_plan)
  if [[ -z "$INVMARK_FILE" ]]; then
    in_inventory "$1" || return 0
    bad "The HOME entry of $1 in $(inventory_dir)/ContentsXML/inventory.xml could not be marked."; return 1
  fi
  [[ "$(file_md5 "$INVMARK_FILE")" == "$INVMARK_MD5" ]] || { bad "$INVMARK_FILE has changed since it was shown. Nothing was changed. Answer r to see it again."; return 1; }
  local r b="$INVMARK_FILE.bak_$RUN_ID"; r=$(role_of_user "$INVMARK_USER")
  # a backup name that this run did not make is not taken (the owner could have put it there), as backup_file
  if [[ -e "$b" || -L "$b" ]]; then
    [[ -n "${BACKUPS_MADE[$b]:-}" ]] || { bad "$b exists already, but this run did not make it. Nothing is changed in $INVMARK_FILE."; return 1; }
  else
    cp_run_one "$r" "$INVMARK_BAK" || { bad "Cannot keep a backup of $INVMARK_FILE: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
    BACKUPS_MADE[$b]=1; say "Backup: $b"
  fi
  cp_run_one "$r" "$INVMARK_CMD" || { bad "$INVMARK_FILE could not be written: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  journal_file_written "$INVMARK_FILE" 1
  say "Marked $1 as removed in $INVMARK_FILE"
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
  # (found by the check, so the unzip shown before is the one that runs)
  local kind=$5 mvar=DB_MEDIA f; [[ "$kind" == grid ]] && mvar=GRID_MEDIA
  if ! media_ok "${!mvar}"; then
    f=$SW_HALF_MEDIA
    if [[ -z "$f" ]] || ! media_ok "$f"; then
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
  # a Grid home installed again: the record of its earlier root scripts no longer applies
  [[ "$kind" == grid ]] && rm -f -- "$(GRID_ROOT_DONE_FILE)"
  return 10
}
stage_dir() { printf '%s/dg_stage_%s' "$(dirname "$INVENTORY_DIR")" "$1"; }   # for staged (12.x) media
unpack_plan() {
  # check: $1 comma list of zip files, $2 target folder, $3 who (grid | oracle): the unzip jobs of unpack_media
  local f; local -a uz=(); IFS=',' read -ra uz <<< "$1"
  [[ -d "$2" ]] || order_add "as root: make the folder $2 (owner $(job_user "$3"), group $INSTALL_GROUP, mode 775)"
  for f in "${uz[@]}"; do job_show_add "$3" unzip -q -o "$f" -d "$2"; done
}
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
    job_launch "unzip $(basename "$f")" "$uo" "$who" unzip -q -o "$f" -d "$dest" < /dev/null \
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
    # installed, root.sh not run yet: bin/crsctl is made by root.sh, so the installer's own files count too
    # (only with the success record of the installer: root.sh and crsctl.bin are already in an unpacked image)
    if { [[ -f "$STATE_DIR/grid_install.done" ]] && [[ -x "$GRID_HOME/bin/crsctl" || -s "$GRID_HOME/bin/crsctl.bin" || -x "$GRID_HOME/root.sh" ]]; } \
       || { [[ -f /etc/oracle/olr.loc || -f "$(GRID_ROOT_DONE_FILE)" ]] && [[ -x "$GRID_HOME/bin/crsctl" ]]; }; then GSTATE=NEED_ROOT
    else GSTATE=HALF_INSTALLED; fi
    return
  fi
  if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then GSTATE=NEED_INSTALL; return; fi
  GSTATE=NEED_UNZIP
}
SW_HALF_MEDIA=""
half_installed_plan() {
  # $1 home, $2 owner, $3 the success record, $4 grid | db, $5 its stage folder: an installer that registered the
  # home but did not finish (relink error, killed), or a home installed by hand before this script ran.
  # The shown list holds what c runs: the inventory entry, the emptying of the home (and stage folder); the
  # caller adds the unzip and the installer (SW_HALF_MEDIA: the installer files c uses)
  NOW="$1 is in the Oracle inventory, but the script cannot confirm the installation."$'\n'"There is no record that its installer finished, or its programs are missing."
  KIND_NOW=ask; SW_FIX=half
  PLAN="You choose:
  m  you installed it yourself and the installer finished without error: the script records that
  c  clean it and install again: the home is marked as removed in the inventory (a backup is kept),
     $1 is emptied, and the installer runs again"
  # the installer files must be there before anything is deleted: found now (the same search as step 3.1)
  local mvar=DB_MEDIA; [[ "$4" == grid ]] && mvar=GRID_MEDIA
  SW_HALF_MEDIA=""
  if media_ok "${!mvar}"; then SW_HALF_MEDIA=${!mvar}
  else
    scan_media; SW_HALF_MEDIA=$(pick_media "$4")
    [[ "$SW_HALF_MEDIA" == MISSING:* ]] && SW_HALF_MEDIA=""
    [[ -n "$SW_HALF_MEDIA" ]] && PLAN+=$'\n'"     Installer files: $SW_HALF_MEDIA (saved in $SETTINGS_FILE)"
  fi
  if [[ -z "$SW_HALF_MEDIA" ]]; then
    PLAN+=$'\n'"     (c is not possible now: no installer files for it were found on this server)"
    return 0
  fi
  PLAN+=$'\n'"     c asks you to type CLEAN first. The commands and jobs below are what c runs."
  inventory_mark_plan "$1" || PLAN+=$'\n'"     (c stops: the HOME entry of $1 in the inventory cannot be marked)"
  sw_empty_plan "$1"
  [[ -d "$5" ]] && sw_empty_plan "$5"
  order_add "as the owner of the inventory, then as root: mark $1 as removed in the inventory, then empty it (the commands under \"Will run\")"
  return 0
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
  grid_rsp_keys
  finish_rsp "$RSP" "$GRID_USER"
  rsp_review
}
grid_rsp_keys() {
  # the keys of the Grid response file (written by write_grid_rsp, shown before [y] by rsp_show_text)
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
  return 0
}
INST_ARGV=()
grid_inst_argv() {
  # $1 installer, $2 response file, $3 fresh (optional, see ru_args): INST_ARGV, the command of the Grid installer
  INST_ARGV=("$1" -silent -waitforcompletion -responseFile "$2")
  if [[ "$1" == */gridSetup.sh ]]; then
    local -a ru=(); mapfile -t ru < <(ru_args grid "${3:-}")
    INST_ARGV+=("${ru[@]+"${ru[@]}"}")
  fi
  return 0
}
rsp_plan_text() {
  # $1 response file, $2 template, $3 owner, rest = key function: the lines PLAN shows about the response file.
  # The values it sets (20 or more lines) go into a file, so the job command lines stay on the screen; a key
  # the template lacks (the step then stops) is shown here
  local rsp=$1 tpl=$2 owner=$3 vals vf; shift 3
  vals=$(rsp_show_text "$tpl" "$owner" "$@")
  printf 'Response file %s: a copy of %s (owner %s, mode 600,\nremoved when the installer has ended).' "$rsp" "$tpl" "$owner"
  vf="$LOG_DIR/response_values_${CUR_STEP:-x}_$RUN_ID.txt"
  if ( umask 077; printf 'Values the script sets in %s (a copy of %s; passwords *****):\n%s\n' "$rsp" "$tpl" "$(grep -v '^  Not in the template' <<< "$vals")" > "$vf" ) 2>/dev/null; then
    printf '\nThe values the script sets in it (passwords *****):  %s\n' "$vf"
  else
    printf ' The values the script sets in it (passwords *****):\n%s\n' "$(grep -v '^  Not in the template' <<< "$vals")"
  fi
  grep '^  Not in the template' <<< "$vals" || true
}
grid_plan_jobs() {
  # check: $1 now | fresh (the home and stage folder are emptied first), $2 the installer files. Adds the unzip
  # jobs, the OPatch commands and the installer job of d_3_2 (in its order), and their text to PLAN
  local st=$GSTATE media=$2 inst tpl rspd
  [[ "$1" == fresh ]] && st=NEED_UNZIP
  if [[ "$st" == NEED_UNZIP ]]; then
    if media_is_staged "$media"; then
      unpack_plan "$media" "$(stage_dir grid)" grid
      inst="$(stage_dir grid)/grid/runInstaller"; tpl="$(stage_dir grid)/grid/response/grid_install.rsp"
    else
      unpack_plan "$media" "$GRID_HOME" grid
      inst="$GRID_HOME/gridSetup.sh"; tpl="$GRID_HOME/install/response/gridsetup.rsp"
    fi
  else inst=$(grid_installer); tpl=$(grid_template); fi
  if [[ "$inst" == */gridSetup.sh ]]; then
    if [[ "$st" == NEED_UNZIP ]]; then opatch_plan "$GRID_HOME" grid "media=$media"; else opatch_plan "$GRID_HOME" grid now; fi
  fi
  rsp_plan_dir >/dev/null; rspd=$RSP_NEXT   # (not in $( ): the name must stay for the action)
  grid_inst_argv "$inst" "$rspd/$(basename "$tpl")" "$([[ "$st" == NEED_UNZIP ]] && printf fresh)"
  job_show_add grid "${INST_ARGV[@]}"
  plan_jobs_text "$inst" "$rspd/$(basename "$tpl")" "$tpl" "$GRID_USER" grid_rsp_keys
}
plan_jobs_text() {
  # $1 installer, $2 response file, $3 template, $4 owner, rest = key function: the order, the retry and the
  # response file, added to PLAN
  local inst=$1; shift
  PLAN+="${PLAN:+$'\n'}$(order_text)"
  PLAN+=$'\n'"If prerequisite checks fail, they are shown. You then choose: run it again after a fix,"$'\n'"or run it again with $([[ "$inst" == */gridSetup.sh || "$inst" == "$DB_HOME/runInstaller" ]] && printf -- '-ignorePrereqFailure' || printf -- '-ignorePrereq') added (you type IGNORE)."
  PLAN+=$'\n'"$(rsp_plan_text "$@")"
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
  # $1 owner of the inventory. Sets NOW and PLAN for a state that is not ok (INS-32035 otherwise), and adds the
  # commands to the shown list (inventory_fix runs them)
  case "$(inventory_state)" in
    leftover)
      NOW+="${NOW:+$'\n'}$INVENTORY_DIR is not empty, but no Oracle home is registered in it and /etc/oraInst.loc is missing."
      NOW+=$'\n'"These are files of an earlier installer run that did not finish. The installer would stop with INS-32035."
      cp_add root "$(inv_move_cmd)"
      order_add "as root: move $INVENTORY_DIR aside to $INVENTORY_DIR.old_$RUN_ID, nothing is deleted (the command under \"Will run\"), then make it again, empty (owner $1, group $INSTALL_GROUP, mode 775)" ;;
    registered)
      NOW+="${NOW:+$'\n'}$INVENTORY_DIR holds an inventory with Oracle homes, but /etc/oraInst.loc is missing."
      cp_add_file /etc/oraInst.loc 644 "$(inv_loc_text)"
      order_add "as root: write /etc/oraInst.loc (shown under \"Will run\"), so the installer uses that inventory" ;;
  esac
}
inv_move_cmd() { argv_text mv -T -- "$INVENTORY_DIR" "$INVENTORY_DIR.old_$RUN_ID"; }
inv_loc_text() { printf 'inventory_loc=%s\ninst_group=%s' "$INVENTORY_DIR" "$INSTALL_GROUP"; }
inventory_fix() {
  # $1 owner. Puts the inventory folder in a state the installer accepts (see inventory_state): runs the commands
  # shown before [y] (inventory_fix_plan)
  case "$(inventory_state)" in
    ok) return 0 ;;
    leftover)
      local old="$INVENTORY_DIR.old_$RUN_ID"
      [[ -e "$old" ]] && { bad "$old already exists. Nothing is moved."; return 1; }
      cp_run_one root "$(inv_move_cmd)" || { bad "Cannot move $INVENTORY_DIR aside."; return 1; }
      journal RENAME "$INVENTORY_DIR" "to=$old"
      say "Moved the files of the earlier attempt to $old"
      make_dir "$INVENTORY_DIR" "$1" || return 1 ;;
    registered)
      cp_run_one file /etc/oraInst.loc || return 1
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
  SW_FIX=""; job_show_reset
  use_grid || { NOW="Not needed (the primary does not use ASM)"; return 0; }
  users_ok || { NOW="The Oracle users do not exist yet (step 2.2)"; return 2; }
  grid_state
  case "$GSTATE" in
    DONE|ASM_DOWN|HAS_DOWN|NEED_CONFIGTOOLS|NEED_ROOT) NOW="Grid software is installed in $GRID_HOME"; return 0 ;;
    UNKNOWN) NOW="Cannot read the Grid state: $(head -n 2 <<< "$GSTATE_OUT")"; return 2 ;;
    HALF_INSTALLED)
      half_installed_plan "$GRID_HOME" "$GRID_USER" "$STATE_DIR/grid_install.done" grid "$(stage_dir grid)"
      [[ -n "$SW_HALF_MEDIA" ]] && grid_plan_jobs fresh "$SW_HALF_MEDIA"
      return 1 ;;
  esac
  if ! unzip_failed_check "$GRID_HOME" "$(stage_dir grid)"; then
    SW_FIX=unzip; YES_HOLD=1
    # after emptying, the files are unpacked again and installed (what the do part runs then)
    [[ "$KIND_NOW" != manual ]] && media_ok "$GRID_MEDIA" && grid_plan_jobs fresh "$GRID_MEDIA"
    return 1
  fi
  grid_ready || return 2
  # the Release Update the installer applies (also when 3.1 was skipped with --from)
  ru_matches_primary grid || return 1
  # room to unpack (also when 3.1 was skipped with --from)
  [[ "$GSTATE" == "NEED_UNZIP" ]] && { media_room "$GRID_MEDIA" "" || return 1; }
  NOW="Grid is not installed yet"
  PLAN=""
  # an inventory folder that an earlier, failed installer run left behind is moved aside first (else INS-32035)
  local ist; ist=$(inventory_state)
  [[ "$ist" != ok ]] && SW_FIX=inv
  [[ "$ist" == leftover ]] && YES_HOLD=1      # moving the inventory folder aside: asked also with --yes
  # (the unzip and the installer are jobs: the numbered list below shows them)
  PLAN+="Install Grid silently as $GRID_USER: Oracle Restart for a single server${RU_DIR:+,}
${RU_DIR:+  with the Release Update in $RU_DIR}
  Disk group +$DATA_DG, external redundancy, disks $(asm_labels "$DATA_DG" | paste -sd' ' -)
  Grid home $GRID_HOME, base $GRID_BASE
  Inventory $INVENTORY_DIR
Ask you for a new ASM password for SYS and ASMSNMP (used only on this server)"
  USING="Same paths and disk group name as the primary."$'\n'"The response file is made from the template in the media."
  [[ "$SW_FIX" == inv ]] && inventory_fix_plan "$GRID_USER"
  grid_plan_jobs now "$GRID_MEDIA"
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
  make_rsp "$(grid_template)" "$GRID_USER" || return 1
  write_grid_rsp || { remove_rsp "$RSP"; return 1; }
  local inst irc=0 rsp=$RSP; inst=$(grid_installer)
  # the command shown before [y] (grid_plan_jobs builds it with the same function)
  grid_inst_argv "$inst" "$rsp"
  JOB_KEEP=$rsp
  if [[ "$inst" == */gridSetup.sh ]]; then
    run_installer "Grid installer" as_grid -ignorePrereqFailure "${INST_ARGV[@]}" || irc=1
  else
    run_installer "Grid installer (12.1)" as_grid -ignorePrereq "${INST_ARGV[@]}" || irc=1
  fi
  # the installer's own last lines tell to run root.sh and the configuration tools: those are the next steps here
  [[ $irc -eq 0 && $UI -eq 0 ]] && say "The root scripts and the configuration the installer mentions are done by steps 3.3 and 3.4."
  remove_rsp "$rsp"
  return $irc
}

# ---- 3.3 Grid root scripts ----
c_3_3() {
  job_show_reset
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
-- If that fails, read the newest roothas_*.log in ${GRID_BASE:-<Grid base>}/crsdata/$(hostname -s)/crsconfig
-- (12.1: in $GRID_HOME/cfgtoollogs/crsconfig).
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
  [[ -x "$invd/orainstRoot.sh" ]] && job_show_add root "$invd/orainstRoot.sh"
  job_show_add root "$GRID_HOME/root.sh"
  PLAN="root.sh configures Oracle Restart on this server."
  PLAN+=$'\n'"$(order_text)"$'\n'"(as root with a clean environment: PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin;"$'\n'"no input, so their questions get the default answers)"
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
cfgtools_argv() {
  # $1 response file: INST_ARGV, the command of the Grid configuration tools (image: gridSetup.sh; 12.1: configToolAllCommands)
  if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then INST_ARGV=("$GRID_HOME/gridSetup.sh" -executeConfigTools -responseFile "$1" -silent -waitforcompletion)
  else INST_ARGV=("$GRID_HOME/cfgtoollogs/configToolAllCommands" "RESPONSE_FILE=$1"); fi
}
c_3_4() {
  job_show_reset
  use_grid || { NOW="Not needed (no Grid)"; return 0; }
  grid_state
  case "$GSTATE" in
    DONE) NOW="Oracle Restart is running and ASM is ONLINE"; return 0 ;;
    NEED_CONFIGTOOLS)
      NOW="Oracle Restart is running. ASM is not configured yet."
      local rspd; rsp_plan_dir >/dev/null; rspd=$RSP_NEXT   # (not in $( ): the name must stay for the action)
      PLAN="The Grid configuration tools create ASM, +$DATA_DG and the listener."
      [[ -n "$ASM_PW" ]] || PLAN+=$'\n'"Ask you for the ASM password for SYS and ASMSNMP: the one from step 3.2"$'\n'"(it was not used yet), or a new one"
      if [[ -x "$GRID_HOME/gridSetup.sh" ]]; then
        local tpl; tpl=$(grid_template)
        cfgtools_argv "$rspd/$(basename "$tpl")"; job_show_add grid "${INST_ARGV[@]}"
        plan_jobs_text "$GRID_HOME/gridSetup.sh" "$rspd/$(basename "$tpl")" "$tpl" "$GRID_USER" grid_rsp_keys
      else
        cfgtools_argv "$rspd/cfgrsp.properties"; job_show_add grid "${INST_ARGV[@]}"
        PLAN+=$'\n'"$(order_text)"
        PLAN+=$'\n'"Response file $rspd/cfgrsp.properties (owner $GRID_USER, mode 600, removed when it has ended):"
        PLAN+=$'\n'"  oracle.assistants.asm|S_ASMPASSWORD=*****"$'\n'"  oracle.assistants.asm|S_ASMMONITORPASSWORD=*****"
      fi ;;
    HAS_DOWN) NOW="High Availability Services is stopped"
      PLAN="Start it as root:  $GRID_HOME/bin/crsctl start has"$'\n'"Then wait up to 5 minutes for ASM. srvctl start asm runs only if the stack is up but ASM did not start with it."
      cp_add root "$GRID_HOME/bin/crsctl start has" "" 300
      cp_add grid "srvctl start asm" "" 300 ;;
    ASM_DOWN) NOW="ASM is not ONLINE"; PLAN="Start ASM with srvctl."; cp_add grid "srvctl start asm" ;;
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
        make_rsp "$(grid_template)" "$GRID_USER" || return 1
        write_grid_rsp || { remove_rsp "$RSP"; return 1; }
        local rsp=$RSP; JOB_KEEP=$rsp
        cfgtools_argv "$rsp"
        run_installer "Grid configuration tools" as_grid -ignorePrereqFailure "${INST_ARGV[@]}" || crc=1
        remove_rsp "$rsp"
      else
        secure_rsp cfgrsp.properties || return 1
        ( umask 077; set -C
          printf 'oracle.assistants.asm|S_ASMPASSWORD=%s\noracle.assistants.asm|S_ASMMONITORPASSWORD=%s\n' "$ASM_PW" "$ASM_PW" > "$RSP" ) || return 1
        finish_rsp "$RSP" "$GRID_USER"
        local props=$RSP; JOB_KEEP=$props
        cfgtools_argv "$props"
        run_installer "Grid configuration tools (12.1)" as_grid "" "${INST_ARGV[@]}" || crc=1
        remove_rsp "$props"
      fi
      return $crc ;;
    HAS_DOWN)
      root_prog_ok "$GRID_HOME/bin/crsctl" || return 1
      cp_run_one root "$GRID_HOME/bin/crsctl start has" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
      # ASM may take minutes after the stack starts (many disks): up to 5 minutes, then a clear failure
      # measured in time (each check itself may take a while), with a line every minute
      local t0 last=0 el; t0=$(date +%s); say "Waiting for ASM to come online (up to 5 minutes) ..."
      until grid_state; [[ "$GSTATE" == "DONE" || "$GSTATE" == "ASM_DOWN" ]] || (( $(date +%s) - t0 >= 300 )); do
        nap 5; el=$(( ($(date +%s) - t0) / 60 )); [[ $el -gt $last ]] && { last=$el; say "Still waiting ($el min, state $GSTATE)"; }
      done
      # the stack is up but ASM was not started with it (not set to start by itself): started here
      if [[ "$GSTATE" == "ASM_DOWN" ]]; then
        cp_run_one grid "srvctl start asm" || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
        t0=$(date +%s); until grid_state; [[ "$GSTATE" == "DONE" ]] || (( $(date +%s) - t0 >= 120 )); do nap 5; done
      fi
      [[ "$GSTATE" == "DONE" ]] || { bad "Oracle Restart started, but ASM did not come online in time (state $GSTATE)."; return 1; } ;;
    ASM_DOWN) cp_run || return 1 ;;
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
  # REDO_BLOCKSIZE (when the primary's value could not be read) must be in place before the plan is made
  redo_bs_known || true
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
    local dead; dead=$(asm_dead_labels "$dg"); [[ -n "$dead" ]] && { asm_dead_plan "${dead% }"; return 2; }
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
  redo_bs_known || { NOW="The redo block size of the primary could not be read (step 1.3), so the sector size of the new disk groups is not known. Run the script again, or set REDO_BLOCKSIZE (512 or 4096) in the settings (--settings)."; return 2; }
  NOW="Disk groups to create:$todo"
  PLAN="Create the disk groups$todo in ASM (external redundancy), one statement each."
  local st; while IFS= read -r st; do [[ -n "$st" ]] && cp_add grid "sqlplus -S /nolog" "connect / as sysasm"$'\n'"$st" 1800; done <<< "$DG_TODO"
  USING="Same disk group names as the primary."$'\n'"compatible.asm and compatible.rdbms are the same as in +$DATA_DG."
  # the sector size of a disk group cannot be changed later: a value from the settings (not read from the
  # primary) is asked about, also with --yes
  if [[ ${PRIMARY_REDO_BS_KNOWN:-0} -ne 1 ]]; then
    YES_HOLD=1
    NOW+=$'\n'"The redo block size comes from REDO_BLOCKSIZE=$REDO_BLOCKSIZE in the settings, not from the primary."$'\n'"The sector size of a disk group cannot be changed later. Answer y only if you are sure."
  fi
  return 1
}
d_3_5() {
  # the statements shown before [y], one entry each (in the order of DG_TODO)
  local i s
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    s=$(sed -n '2p' <<< "${CP_IN[$i]}")
    if ! cp_exec "$i"; then
      bad "This failed ($(ora_errors "$RUN_OUT")):"$'\n'"$s"
      if grep -qE 'ORA-15018|ORA-15030|ORA-15033' <<< "$RUN_OUT"; then
        printf 'A disk already has an ASM header, probably from an interrupted earlier try.\nOnly if the disks were made by this script (%s), repeat the statement with FORCE:\n  %s\n' "$(asm_disks_file)" "$(sed -E "s/'((\/|ORCL:)[^']*)'/'\1' force/g" <<< "$s")" | hint
      fi
      return 1
    fi
    [[ "$s" =~ ^create\ diskgroup\ ([A-Za-z0-9_]+) ]] && journal DISKGROUP "${BASH_REMATCH[1]^^}" "external redundancy"
  done
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
  db_rsp_keys "$1"
  finish_rsp "$RSP" "$ORACLE_USER"
  rsp_review
}
db_rsp_keys() {
  # $1 = image | staged: the keys of the database response file (written by write_db_rsp, shown by rsp_show_text)
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
  return 0
}
db_inst_argv() {
  # $1 installer, $2 response file, $3 image | staged, $4 fresh (optional): INST_ARGV, the database installer command
  INST_ARGV=("$1" -silent -waitforcompletion -responseFile "$2")
  if [[ "$3" == image && $DB_MAJOR -ge 18 ]]; then
    local -a ru=(); mapfile -t ru < <(ru_args "" "${4:-}")
    INST_ARGV+=("${ru[@]+"${ru[@]}"}")
  fi
  return 0
}
db_plan_jobs() {
  # check: $1 now | fresh (the home and stage folder are emptied first), $2 the installer files. Adds the unzip
  # jobs, the OPatch commands and the installer job of d_3_6 (in its order), and their text to PLAN
  local st=$DSTATE media=$2 inst tpl kind=image rspd
  [[ "$1" == fresh ]] && st=NEED_UNZIP
  if [[ "$st" == NEED_UNZIP ]]; then
    if media_is_staged "$media"; then
      unpack_plan "$media" "$(stage_dir db)" oracle
      inst="$(stage_dir db)/database/runInstaller"; tpl="$(stage_dir db)/database/response/db_install.rsp"
    else
      unpack_plan "$media" "$DB_HOME" oracle
      inst="$DB_HOME/runInstaller"; tpl="$DB_HOME/install/response/db_install.rsp"
    fi
  else inst=$(db_installer); tpl=$(db_template); fi
  [[ "$inst" == "$DB_HOME/runInstaller" ]] || kind=staged
  if [[ "$kind" == image && $DB_MAJOR -ge 18 ]]; then
    if [[ "$st" == NEED_UNZIP ]]; then opatch_plan "$DB_HOME" oracle "media=$media"; else opatch_plan "$DB_HOME" oracle now; fi
  fi
  rsp_plan_dir >/dev/null; rspd=$RSP_NEXT   # (not in $( ): the name must stay for the action)
  db_inst_argv "$inst" "$rspd/$(basename "$tpl")" "$kind" "$([[ "$st" == NEED_UNZIP ]] && printf fresh)"
  job_show_add oracle "${INST_ARGV[@]}"
  plan_jobs_text "$inst" "$rspd/$(basename "$tpl")" "$tpl" "$ORACLE_USER" db_rsp_keys "$kind"
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
  # no Grid: the same two cases as in step 3.2 (files left by a failed installer, or an inventory that is not
  # registered) are put right by the install action (see inventory_fix)
  local ist; ist=$(inventory_state)
  [[ "$ist" != ok ]] && SW_FIX=inv
  [[ "$ist" == leftover ]] && YES_HOLD=1      # moving the inventory folder aside: asked also with --yes
  return 0
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
  SW_FIX=""; job_show_reset
  users_ok || { NOW="The Oracle users do not exist yet (step 2.2)"; return 2; }
  db_state
  case "$DSTATE" in
    DONE|NEED_ROOT) NOW="Database software is installed in $DB_HOME"; return 0 ;;
    HALF_INSTALLED)
      half_installed_plan "$DB_HOME" "$ORACLE_USER" "$STATE_DIR/db_install.done" db "$(stage_dir db)"
      [[ -n "$SW_HALF_MEDIA" ]] && db_plan_jobs fresh "$SW_HALF_MEDIA"
      return 1 ;;
  esac
  primary_edition || { NOW="Cannot read the edition of the primary"; return 2; }
  if ! unzip_failed_check "$DB_HOME" "$(stage_dir db)"; then
    SW_FIX=unzip; YES_HOLD=1
    # after emptying, the files are unpacked again and installed (what the do part runs then)
    [[ "$KIND_NOW" != manual ]] && media_ok "$DB_MEDIA" && db_plan_jobs fresh "$DB_MEDIA"
    return 1
  fi
  inventory_ready || return $?
  db_ready || return 2
  ru_matches_primary db || return 1
  [[ "$DSTATE" == "NEED_UNZIP" ]] && { media_room "" "$DB_MEDIA" || return 1; }
  NOW="Database software is not installed yet"
  PLAN=""
  # (the unzip and the installer are jobs: the numbered list below shows them)
  PLAN+="Install the database software silently as $ORACLE_USER: Software Only, Enterprise Edition${RU_DIR:+,}
${RU_DIR:+  with the Release Update in $RU_DIR}
  Home $DB_HOME, base $ORACLE_BASE, OS groups as on the primary"
  USING="Same home and base as the primary."$'\n'"The response file is made from the template in the media."
  [[ "$SW_FIX" == inv ]] && inventory_fix_plan "$ORACLE_USER"
  db_plan_jobs now "$DB_MEDIA"
  return 1
}
d_3_6() {
  local kind=image fx=0
  case "$SW_FIX" in
    half)  sw_half_fix "$DB_HOME" "$ORACLE_USER" "$STATE_DIR/db_install.done" "$(stage_dir db)" db || fx=$?
           [[ $fx -eq 10 ]] || return $fx ;;
    unzip) sw_unzip_fix || return 1 ;;
    inv)   inventory_fix "$ORACLE_USER" || return 1 ;;
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
  make_rsp "$(db_template)" "$ORACLE_USER" || return 1
  write_db_rsp "$kind" || { remove_rsp "$RSP"; return 1; }
  local rsp=$RSP
  # the command shown before [y] (db_plan_jobs builds it with the same function)
  db_inst_argv "$inst" "$rsp" "$kind"
  JOB_KEEP=$rsp
  if [[ "$kind" == "image" ]]; then
    run_installer "Database installer" as_oracle -ignorePrereqFailure "${INST_ARGV[@]}" || irc=1
  else
    run_installer "Database installer (12.x)" as_oracle -ignorePrereq "${INST_ARGV[@]}" || irc=1
  fi
  [[ $irc -eq 0 && $UI -eq 0 ]] && say "The root script the installer mentions is run by step 3.7."
  remove_rsp "$rsp"
  return $irc
}

# ---- 3.7 DB root.sh ----
c_3_7() {
  job_show_reset
  db_state
  case "$DSTATE" in
    DONE) NOW="root.sh of the database home has run"; return 0 ;;
    NEED_ROOT)
      NOW="The database software is installed. Its root.sh has not run yet."
      [[ -x "$(inventory_dir)/orainstRoot.sh" && ! -f /etc/oraInst.loc ]] && job_show_add root "$(inventory_dir)/orainstRoot.sh"
      job_show_add root "$DB_HOME/root.sh"
      PLAN="$(order_text)"$'\n'"(as root with a clean environment: PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin;"$'\n'"no input, so their questions get the default answers)"
      return 1 ;;
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
  cp_add oracle "$DB_HOME/bin/roohctl -disable"
  return 1
}
# journaled first: a roohctl that stops half-way has still changed the home, and the undo must be listed
d_3_8() { journal ROOHCTL "$DB_HOME"; cp_run_one oracle "$DB_HOME/bin/roohctl -disable" || { bad "roohctl failed: $(tail -n 3 <<< "$RUN_OUT")"; return 1; }; }
rw_home_ok() {
  db_sw_ok || return 1
  [[ -x "$DB_HOME/bin/orabasehome" ]] || return 0
  run_logged "orabasehome" as_oracle "$DB_HOME/bin/orabasehome" || return 1
  local o; o=$(printf '%s\n' "$RUN_OUT" | grep -E '^/' | head -n 1)
  [[ "${o%/}" == "$DB_HOME" ]]
}

# ---- 3.9 resources (Grid) ----
RES_TODO=""
# ---- 3.9 Oracle Restart resources ----
# Only the resources the standby needs: ora.asm, the listener and the disk groups in use. ora.diskmon and ora.ons
# are OFFLINE in Oracle Restart by design: never reported, never started. ora.* resources are started with srvctl
# (crsctl start res refuses them: CRS-4995).
#   OFFLINE       -> srvctl start ...
#   INTERMEDIATE  -> never "started": the cause is found first (host name, port taken by another listener, a HOST in
#                    listener.ora that is not this server), fixed, then the listener is stopped and started again
L39_CAUSE=""; L39_HOSTS_LINE=""; L39_PID=""; L39_LHOME=""; L39_LUSER=""; L39_LNAME=""; L39_LORA=""; L39_BADHOST=""
res_state() {
  # $1 resource -> RES_STATE: ONLINE | OFFLINE | INTERMEDIATE | MISSING | CRS_UNKNOWN (crsctl says STATE=UNKNOWN) |
  # UNKNOWN (no state could be read) ; RES_DETAIL: the text after the state
  run_logged "crsctl stat res $1" as_grid timeout 60 "$GRID_HOME/bin/crsctl" stat res "$1" -v || true
  RES_DETAIL=""
  if grep -q 'CRS-2613' <<< "$RUN_OUT" || ! grep -q "NAME=$1" <<< "$RUN_OUT"; then RES_STATE=MISSING; return 0; fi
  local st; st=$(sed -n 's/^STATE=\([A-Z_]*\).*/\1/p' <<< "$RUN_OUT" | head -n 1)
  RES_DETAIL=$(sed -n 's/^STATE_DETAILS=//p' <<< "$RUN_OUT" | head -n 1)
  # STATE=UNKNOWN is not OFFLINE: a plain start does not help (Oracle: stop it with -f first)
  case "$st" in ONLINE|OFFLINE|INTERMEDIATE) RES_STATE=$st ;; UNKNOWN) RES_STATE=CRS_UNKNOWN ;; "") RES_STATE=UNKNOWN ;; *) RES_STATE=OFFLINE ;; esac
}
srvctl_start_cmd() {
  # the srvctl command that starts resource $1
  case "$1" in
    ora.asm) printf 'srvctl start asm' ;;
    ora.*.lsnr) local l=${1#ora.}; printf 'srvctl start listener -listener %s' "${l%.lsnr}" ;;
    ora.*.dg) local g=${1#ora.}; printf 'srvctl start diskgroup -diskgroup %s' "${g%.dg}" ;;
  esac
}
lsnr_port_owner() {
  # the program that listens on the port of the listener, when it is not a listener of the Grid home:
  # sets L39_PID, L39_LHOME (the home of a tnslsnr), L39_LUSER, L39_LNAME; 1 = none
  L39_PID=""; L39_LHOME=""; L39_LUSER=""; L39_LNAME=""
  local line pid args exe
  line=$(ss -ltnp "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -n 1)
  pid=${line#pid=}
  num "$pid" || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  exe=$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /\/bin\/tnslsnr$/) {print $i; exit}}' <<< "$args")
  [[ -n "$exe" && "$exe" == "$GRID_HOME/bin/tnslsnr" ]] && return 1
  L39_PID=$pid; L39_LUSER=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
  if [[ -n "$exe" ]]; then
    L39_LHOME=${exe%/bin/tnslsnr}
    L39_LNAME=$(awk -v e="$exe" '{for (i = 1; i < NF; i++) if ($i == e) {print $(i + 1); exit}}' <<< "$args")
    v_path "$L39_LHOME" && v_name "$L39_LNAME" && v_name "$L39_LUSER" || { L39_LHOME=""; L39_LNAME=""; }
  fi
  return 0
}
lsnr_ora_badhost() {
  # a HOST in the Grid listener.ora that is neither this server's name nor one of its addresses
  local f="$GRID_HOME/network/admin/listener.ora" h ips
  L39_LORA=$f; L39_BADHOST=""
  [[ -r "$f" ]] || return 1
  ips=" $(local_ipv4s) "
  for h in $(grep -oiE 'HOST *= *[A-Za-z0-9_.:-]+' "$f" | sed 's/.*= *//' | sort -u); do
    [[ "${h,,}" == "${STANDBY_HOST,,}" || "${h,,}" == "$(host_fq | tr '[:upper:]' '[:lower:]')" || "$ips" == *" $h "* || "$h" == localhost || "$h" == 0.0.0.0 ]] && continue
    [[ "$h" =~ ^[0-9.]+$ ]] || { local hv; hv=$(v4_fd "$h"); [[ -n "$hv" && "$ips" == *" $hv "* ]] && continue; }
    L39_BADHOST=$h; return 0
  done
  return 1
}
lsnr_intermediate_cause() {
  # the cause of an INTERMEDIATE listener, in this order: host name, port taken by another program, a HOST in
  # listener.ora that is not this server. L39_CAUSE: hosts | port_lsnr | port_other | lsnr_host | unknown
  local p; p=$(standby_name_problems)
  local fq; fq=$(host_fq)
  if [[ -n "$p" ]]; then L39_CAUSE=hosts; L39_HOSTS_LINE="$STANDBY_IP    ${fq:+$fq }$STANDBY_HOST"; L39_WHY=${p//$'\n'/; }; return 0; fi
  if lsnr_port_owner; then
    if [[ -n "$L39_LHOME" ]]; then L39_CAUSE=port_lsnr; else L39_CAUSE=port_other; fi
    return 0
  fi
  if lsnr_ora_badhost; then L39_CAUSE=lsnr_host; return 0; fi
  L39_CAUSE=unknown
}
c_3_9() {
  L39_CAUSE=""
  use_grid || { NOW="Not needed without Grid. The listener is set up in phase 5."; return 0; }
  grid_sw_ok || { NOW="Grid is not installed yet (step 3.2)"; return 2; }
  local r dg off=() miss=() on=() mid=() det=""
  local -a res=(ora.asm "ora.$SB_LSNR.lsnr")
  for dg in $(asm_dgs); do res+=("ora.${dg^^}.dg"); done
  for r in "${res[@]}"; do
    res_state "$r"
    case "$RES_STATE" in
      ONLINE) on+=("$r") ;; MISSING) miss+=("$r") ;; INTERMEDIATE) mid+=("$r"); det=$RES_DETAIL ;;
      UNKNOWN) NOW="Cannot read the state of $r: $(head -n 2 <<< "$RUN_OUT" | tr '\n' ' ')"; return 2 ;;
      CRS_UNKNOWN) NOW="Oracle Restart has $r in the state UNKNOWN${RES_DETAIL:+ ($RES_DETAIL)}: it cannot tell whether it runs."
                   NOW+=$'\n'"As $GRID_USER: stop it with -f, then start it:  $(srvctl_start_cmd "$r" | sed 's/ start / stop /') -f ; $(srvctl_start_cmd "$r")"
                   NOW+=$'\n'"Then run this step again."; return 2 ;;
      *) off+=("$r") ;;
    esac
  done
  if [[ ${#off[@]} -eq 0 && ${#miss[@]} -eq 0 && ${#mid[@]} -eq 0 ]]; then NOW="All ONLINE: ${on[*]}"; return 0; fi
  for r in "${miss[@]+"${miss[@]}"}"; do
    if [[ "$r" == "ora.$SB_LSNR.lsnr" ]]; then
      cp_add grid "srvctl add listener -listener $SB_LSNR -endpoints TCP:$PORT"
      cp_add grid "srvctl start listener -listener $SB_LSNR"
    else
      NOW="Resource $r does not exist (step 3.5)"; return 2
    fi
  done
  for r in "${off[@]+"${off[@]}"}"; do cp_add grid "$(srvctl_start_cmd "$r")"; done
  NOW=""
  [[ ${#off[@]} -gt 0 || ${#miss[@]} -gt 0 ]] && NOW="Not ONLINE yet: ${off[*]+"${off[*]}"} ${miss[*]+"${miss[*]}"}"
  if [[ ${#mid[@]} -gt 0 ]]; then
    NOW+="${NOW:+$'\n'}${mid[*]} is INTERMEDIATE${det:+ ($det)}: running, but not all its endpoints are registered."
    lsnr_intermediate_cause
    case "$L39_CAUSE" in
      hosts)
        NOW+=$'\n'"Cause: $L39_WHY."
        if [[ -L /etc/hosts ]]; then
          NOW+=$'\n'"/etc/hosts is a symbolic link, so the script does not change it."
          KIND_NOW=manual; MANUAL_HOW="root  ->  shell"
          PLAN="-- Add this line to the file /etc/hosts points to (or to DNS):"$'\n'"$L39_HOSTS_LINE"$'\n'"-- Then, as $GRID_USER:"$'\n'"srvctl stop listener -listener $SB_LSNR"$'\n'"srvctl start listener -listener $SB_LSNR"
          return 1
        fi
        if grep -qiE "^[^#]*[[:space:]]${STANDBY_HOST}([[:space:].]|\$)" /etc/hosts; then
          NOW+=$'\n'"/etc/hosts has a line for $STANDBY_HOST already, but it is wrong (the first line for a name counts)."
          KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
          PLAN="-- Step 2.6 corrects that line (a backup is kept):"$'\n'"$SELF --only 2.6"$'\n'"-- The line must be:  $L39_HOSTS_LINE"$'\n'"-- Then answer r here."
          return 1
        fi
        # (a file whose last line has no newline gets one first; --undo takes the added text out again)
        L39_LEAD=0; [[ -s /etc/hosts && -n "$(tail -c 1 /etc/hosts)" ]] && L39_LEAD=1
        cp_add root "cp -p /etc/hosts /etc/hosts.bak_$RUN_ID"
        if [[ $L39_LEAD -eq 1 ]]; then cp_add root "printf '\\n%s\\n' '$L39_HOSTS_LINE' >> /etc/hosts"
        else cp_add root "printf '%s\\n' '$L39_HOSTS_LINE' >> /etc/hosts"; fi ;;
      port_lsnr)
        NOW+=$'\n'"Cause: port $PORT is taken by the listener $L39_LNAME of $L39_LHOME (process $L39_PID, user $L39_LUSER), not by the Grid listener."
        cp_add root "runuser -u $L39_LUSER -- env ORACLE_HOME=$L39_LHOME $L39_LHOME/bin/lsnrctl stop $L39_LNAME"
        YES_HOLD=1 ;;          # another program is stopped: always asked, also with yes to all
      port_other)
        NOW+=$'\n'"Cause: port $PORT is taken by another program (process $L39_PID: $(ps -o args= -p "$L39_PID" 2>/dev/null | cut -c1-60))."
        KIND_NOW=manual; MANUAL_HOW="root"
        PLAN="-- That program is not an Oracle listener, so the script does not stop it. To see it:"$'\n'"ss -ltnp 'sport = :$PORT'"$'\n'"ps -o pid,user,args -p $L39_PID"$'\n'"-- Stop it, or move it to another port. Then answer r."
        return 1 ;;
      lsnr_host)
        NOW+=$'\n'"Cause: $L39_LORA has HOST=$L39_BADHOST, which is not this server."
        cp_add grid "cp -p $L39_LORA $L39_LORA.bak_$RUN_ID"
        # the old name as a literal in the pattern (escaped with sed: ${X//./\\.} differs between bash 4.2 and 5)
        local besc; besc=$(printf '%s' "$L39_BADHOST" | sed 's#[][\.*^$/+?(){}|]#\\&#g')
        cp_add grid "sed -i -E 's/(HOST *= *)$besc( *\\))/\\1$STANDBY_HOST\\2/I' $L39_LORA" ;;
      unknown)
        NOW+=$'\n'"The host name, the port and listener.ora look right; the cause is not known."
        KIND_NOW=check
        PLAN="Compare, as $GRID_USER on this server:
lsnrctl status $SB_LSNR
getent ahosts $STANDBY_HOST
cat $GRID_HOME/network/admin/listener.ora
-- The listener log:
less $GRID_BASE/diag/tnslsnr/$STANDBY_HOST/$(tr '[:upper:]' '[:lower:]' <<< "$SB_LSNR")/alert/log.xml
-- After a fix, as $GRID_USER:
srvctl stop listener -listener $SB_LSNR
srvctl start listener -listener $SB_LSNR"
        return 1 ;;
    esac
    cp_add grid "srvctl stop listener -listener $SB_LSNR"
    cp_add grid "srvctl start listener -listener $SB_LSNR"
  fi
  PLAN="Run the commands below. Then the resources are checked again."
  [[ "$L39_CAUSE" == hosts ]] && PLAN="Add the host name of this server to /etc/hosts (a backup is kept), then restart the listener."
  [[ "$L39_CAUSE" == port_lsnr ]] && PLAN="Stop the other listener that holds port $PORT, then restart the Grid listener."
  [[ "$L39_CAUSE" == lsnr_host ]] && PLAN="Put this server's name into listener.ora (a backup is kept), then restart the listener."
  return 1
}
d_3_9() {
  local hsz=""; [[ "${L39_CAUSE:-}" == hosts ]] && hsz=$(stat -c '%s' /etc/hosts 2>/dev/null)
  cp_run || return 1
  if [[ "${L39_CAUSE:-}" == hosts ]]; then
    local txt="$L39_HOSTS_LINE"$'\n'; [[ ${L39_LEAD:-0} -eq 1 ]] && txt=$'\n'"$txt"
    journal_file_appended /etc/hosts "${hsz:-0}" "$txt" "" "${L39_LEAD:-0}"
    say "Added to /etc/hosts:  $L39_HOSTS_LINE"
  fi
  if cp_find grid "srvctl add listener" >/dev/null; then journal LSNRRES "$SB_LSNR" "srvctl add listener"; fi
  # a listener that was INTERMEDIATE gets a moment to register its endpoints before the check
  [[ -n "${L39_CAUSE:-}" ]] && nap 5
  L39_CAUSE=""
  return 0
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
  PLAN="Set port $PORT on listener $SB_LSNR in Oracle Restart, then stop and start it."$'\n'"(A failed stop is passed over: the listener may not be running.)"
  cp_add grid "srvctl modify listener -listener $SB_LSNR -endpoints TCP:$PORT"
  cp_add grid "srvctl stop listener -listener $SB_LSNR"
  cp_add grid "srvctl start listener -listener $SB_LSNR"
  return 1
}
d_3_10() {
  cp_exec 0 || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
  journal LSNRPORT "$SB_LSNR" "old=${L310_CUR:-unknown} new=$PORT"
  cp_exec 1 || true
  cp_exec 2 || { bad "$(tail -n 3 <<< "$RUN_OUT")"; return 1; }
}

# ---- 3.11 same software level as primary ----
# The patches of a home are the folder names in <home>/inventory/oneoffs (what opatch lspatches reads).
ru_root() {
  # the Release Update folder: RU_DIR itself when it is named by its patch number, else its one numbered
  # subfolder (empty when it has none or several: several Release Updates cannot be told apart)
  local d n=0 r=""
  if [[ "$(basename "$RU_DIR")" =~ ^[0-9]{6,9}$ ]]; then printf '%s' "$RU_DIR"; return 0; fi
  for d in "$RU_DIR"/*/; do [[ "$(basename "$d")" =~ ^[0-9]{6,9}$ ]] && { n=$((n + 1)); r=${d%/}; }; done
  [[ $n -eq 1 ]] && printf '%s' "$r"
  return 0
}
ru_ids() {
  # the patch numbers of the Release Update: its folder and its subfolders (a Grid RU holds the database RU,
  # OCW and others as subfolders; a home lists those, not the number of the bundle)
  local d id r; r=$(ru_root); [[ -n "$r" ]] || return 0
  for d in "$r" "$r"/*/; do id=$(basename "$d"); [[ "$id" =~ ^[0-9]{6,9}$ ]] && printf '%s\n' "$id"; done | sort -u
}
ru_matches_primary() {
  # $1 the homes that are installed now: "grid", "db" or "grid db" (only those are compared: the other home
  # may be at another Release Update on the primary). 0 = no RU_DIR, or its patches are on those homes of the
  # primary, or the primary cannot be read (step 3.11 compares later). 1 = RU_DIR is not the primary's Release
  # Update (NOW and PLAN say why). Called by 3.1 and again before each install (3.2, 3.6), so --from cannot skip it.
  [[ -n "${RU_DIR:-}" && -d "$RU_DIR" ]] || return 0
  local which=${1:-grid db} homes=() ids pp h hl n=0 d
  [[ " $which " == *" db "* ]] && homes+=("$DB_HOME")
  [[ " $which " == *" grid "* ]] && use_grid && [[ -n "$GRID_HOME" ]] && homes+=("$GRID_HOME")
  [[ ${#homes[@]} -gt 0 ]] || return 0
  ids=$(ru_ids)
  if [[ -z "$ids" ]]; then
    for d in "$RU_DIR"/*/; do [[ "$(basename "$d")" =~ ^[0-9]{6,9}$ ]] && n=$((n + 1)); done
    if [[ $n -gt 1 ]]; then NOW="RU_DIR ($RU_DIR) holds $n patch folders. It is not known which one is the Release Update."
    else NOW="RU_DIR ($RU_DIR) has no patch folder (a folder named by its patch number, for example 35642822)."; fi
    PLAN="-- Set RU_DIR to the numbered folder of the Release Update that the primary has:  $SELF --settings  (choose e)."$'\n'"-- Then answer r."
    KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
    return 1
  fi
  need_ssh || { warn "The patches of the primary cannot be read now. Step 3.11 compares them after the install."; return 0; }
  for h in "${homes[@]}"; do
    [[ "$h" == "$DB_HOME" ]] && hl="database home" || hl="Grid home"
    pp=$(primary_patches "$h" 2>/dev/null) || { warn "The patches of the primary cannot be read ($h/inventory). Step 3.11 compares them after the install."; continue; }
    [[ -n "$pp" ]] || { NOW="The $hl of the primary has no patches, but RU_DIR is set ($RU_DIR)."$'\n'"The standby must have the same software level as the primary."; PLAN="-- Remove RU_DIR and OPATCH_ZIP from the settings:  $SELF --settings  (choose e). Then answer r."; KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"; return 1; }
    if [[ -z "$(comm -12 <(printf '%s\n' "$ids") <(printf '%s\n' "$pp" | sort -u))" ]]; then
      NOW="RU_DIR ($RU_DIR) is not the Release Update of the primary ($hl $h)."$'\n'"Patches in RU_DIR:  $(paste -sd' ' - <<< "$ids")"$'\n'"Patches on the primary:  $(head -n 6 <<< "$pp" | paste -sd' ' -)$([[ $(wc -l <<< "$pp") -gt 6 ]] && printf ' ...')"
      PLAN="-- Unzip the Release Update that the primary has (see:  opatch lspatches  on the primary),"$'\n'"-- then set RU_DIR to it:  $SELF --settings  (choose e). Then answer r."
      [[ ${#homes[@]} -gt 1 ]] && PLAN+=$'\n'"-- If the Grid home and the database home of the primary have different Release Updates, no one"$'\n'"-- RU_DIR fits both: remove RU_DIR and OPATCH_ZIP, install, and patch each home as step 3.11 shows."
      KIND_NOW=manual; MANUAL_HOW="root"; MANUAL_WHERE="To do on this server ($(hostname -s))"
      return 1
    fi
  done
  return 0
}
# patch ids are the numeric folder names in inventory/oneoffs (5 to 10 digits: every id Oracle has used)
local_patches() {
  # $1 home here -> patch ids; rc 1 when the folder exists but cannot be listed (no folder = no patch applied)
  local d="$1/inventory/oneoffs" out
  [[ -e "$d" ]] || return 0
  out=$(ls -1 -- "$d" 2>/dev/null) || return 1
  grep -E '^[0-9]{5,10}$' <<< "$out" | sort -u
  return 0
}
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
  grep -E '^[0-9]{5,10}$' <<< "$RUN_OUT" | sort -u
  return 0
}
local_release() {
  # base release of the installed database software, from sqlplus -V ("Release 19.0.0.0.0", "Version 19.21.0.0.0")
  # (its "Running as" line during an action must not end up in the captured answer: it is only a read)
  run_logged "sqlplus -V" as_oracle "$DB_HOME/bin/sqlplus" -V > /dev/null || return 1
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
    lp=$(local_patches "$h") || { NOW="Cannot list $h/inventory/oneoffs on this server"; return 2; }
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
