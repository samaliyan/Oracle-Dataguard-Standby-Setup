#------------------------------------------------------------------------------
# Settings: discovered from primary + derived for standby.
# Stored in $STATE_DIR/settings.conf as KEY=VALUE. The file is PARSED and every
# value is validated; it is never executed.
#   Primary values are read again from the primary at every run (a change in the
#   file is not kept). Standby values may be changed by the user.
#   The values the user accepted are kept in settings.accepted; only an accept
#   writes that file.
#------------------------------------------------------------------------------
PRIMARY_HOW_STEP=""; MANUAL_HOW=""

# key:type   (types: name opt_name ip path opt_path num port list locs yesno opt_paths opt_loc dbname asmmethod)
readonly SETTING_SPECS="
PRIMARY_IP:ip PRIMARY_SSH_USER:name PRIMARY_HOST:name PRIMARY_SID:name DB_NAME:name PRIMARY_UNIQUE:name
PRIMARY_CDB:name PRIMARY_VERSION:name DB_MAJOR:num GRID_REL:opt_name PRIMARY_DOMAIN:opt_name PRIMARY_SERVICE:name
PORT:port LISTENER_NAME:name PRIMARY_LISTENER_HOME:path
DB_HOME:path ORACLE_BASE:path USE_GRID:yesno GRID_HOME:opt_path GRID_BASE:opt_path INVENTORY_DIR:path
ORACLE_USER:name GRID_USER:name INSTALL_GROUP:name GRID_PGROUP:name ORACLE_UID:num GRID_UID:num
ORACLE_GROUPS:list GRID_GROUPS:list GROUP_GIDS:list
LOCS:locs DATA_DG:opt_name FRA_LOC:opt_loc FRA_MB:num ARCH_LOC:opt_loc PRIMARY_DB_MB:num
STANDBY_HOST:name STANDBY_IP:ip STANDBY_UNIQUE:dbname STANDBY_SID:name STANDBY_SERVICE:name
PRIMARY_TNS:name STANDBY_TNS:name ASM_METHOD:asmmethod GRID_MEDIA:opt_paths DB_MEDIA:opt_paths RU_DIR:opt_path OPATCH_ZIP:opt_path AUX_CHANNELS:num
"
# may be empty
readonly OPTIONAL_KEYS=" PRIMARY_DOMAIN GRID_REL ORACLE_GROUPS GRID_GROUPS GRID_HOME GRID_BASE DATA_DG FRA_LOC ARCH_LOC ASM_METHOD GRID_MEDIA DB_MEDIA RU_DIR OPATCH_ZIP "
# values the user may change (everything else is read from the primary at every run)
readonly STANDBY_KEYS=" STANDBY_HOST STANDBY_IP STANDBY_UNIQUE STANDBY_SID STANDBY_SERVICE PRIMARY_TNS STANDBY_TNS ASM_METHOD GRID_MEDIA DB_MEDIA RU_DIR OPATCH_ZIP AUX_CHANNELS "
# settings files of version 3.x had these keys; they are converted or dropped
readonly OLD_KEYS=" FRA_DG DATA_DISK FRA_DISK GRID_ZIP DB_ZIP "
SETTINGS_FILE=""; ACCEPTED_FILE=""
SETTINGS_UPGRADED=0; LOAD_ERR=""; DROPPED_KEYS=""

all_setting_keys() { local s; for s in $SETTING_SPECS; do printf '%s\n' "${s%%:*}"; done; }
is_standby_key() { [[ "$STANDBY_KEYS" == *" $1 "* ]]; }

init_settings() {
  local k
  for k in $(all_setting_keys); do printf -v "$k" '%s' ""; done
  AUX_CHANNELS=4
}

valid_value() {
  # $1 type, $2 value
  local t=$1 v=$2
  case "$t" in
    name)      [[ "$v" =~ ^[A-Za-z0-9_.+-]+$ && "$v" != -* ]] ;;
    opt_name)  [[ -z "$v" || ( "$v" =~ ^[A-Za-z0-9_.-]+$ && "$v" != -* ) ]] ;;
    dbname)    [[ "$v" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] ;;
    asmmethod) [[ -z "$v" || "$v" == "asmlib" || "$v" == "udev" ]] ;;
    ip)        [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$v" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ;;
    num)       [[ "$v" =~ ^[0-9]{1,9}$ ]] ;;
    port)      [[ "$v" =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )) ;;
    list)      [[ "$v" =~ ^[A-Za-z0-9_.,:+-]*$ ]] ;;
    yesno)     [[ "$v" == "yes" || "$v" == "no" ]] ;;
    path)      [[ "$v" =~ ^/[A-Za-z0-9_./-]+$ ]] ;;
    opt_path)  [[ -z "$v" || "$v" =~ ^/[A-Za-z0-9_./-]+$ ]] ;;
    opt_paths) [[ -z "$v" || "$v" =~ ^/[A-Za-z0-9_./,-]+$ ]] ;;
    locs)      [[ "$v" =~ ^([+/][A-Za-z0-9_./-]*:[0-9]+)(,[+/][A-Za-z0-9_./-]*:[0-9]+)*$ ]] ;;
    opt_loc)   [[ -z "$v" || "$v" == "USE_DB_RECOVERY_FILE_DEST" || "$v" =~ ^[+/][A-Za-z0-9_./-]+$ ]] ;;
    *) return 1 ;;
  esac
}

settings_file_safe() {
  local owner perm
  owner=$(stat -c '%U' "$1"); perm=$(stat -c '%a' "$1")
  [[ ! -L "$1" && "$owner" == "root" && "${perm: -1}" =~ ^[0145]$ && "${perm: -2:1}" =~ ^[0145]$ ]]
}

load_settings() {
  # Parses $SETTINGS_FILE. $1 = soft: problems are returned in LOAD_ERR (rc 1) instead of stopping.
  # Keys of the 3.x settings file are converted (GRID_ZIP, DB_ZIP) or dropped; unknown keys are dropped.
  local soft=${1:-} line key val spec t
  LOAD_ERR=""; DROPPED_KEYS=""
  [[ -f "$SETTINGS_FILE" ]] || return 1
  if ! settings_file_safe "$SETTINGS_FILE"; then
    LOAD_ERR="$SETTINGS_FILE must be a file owned by root and not writable by others"
    [[ "$soft" == "soft" ]] && return 1; fatal "$LOAD_ERR"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$line" != *=* ]]; then LOAD_ERR="Bad line (no KEY=VALUE): $line"; break; fi
    key=${line%%=*}; val=${line#*=}
    case "$key" in
      GRID_ZIP) key=GRID_MEDIA; SETTINGS_UPGRADED=1 ;;
      DB_ZIP)   key=DB_MEDIA;   SETTINGS_UPGRADED=1 ;;
    esac
    if [[ "$OLD_KEYS" == *" $key "* ]]; then DROPPED_KEYS+=" $key"; SETTINGS_UPGRADED=1; continue; fi
    spec=""
    for t in $SETTING_SPECS; do [[ "${t%%:*}" == "$key" ]] && spec=${t#*:}; done
    if [[ -z "$spec" ]]; then DROPPED_KEYS+=" $key"; continue; fi
    if ! valid_value "$spec" "$val"; then
      if is_standby_key "$key"; then LOAD_ERR="Invalid value: $key=$val"; break; fi
      continue        # a primary value is read again from the primary anyway
    fi
    printf -v "$key" '%s' "$val"
  done < "$SETTINGS_FILE"
  if [[ -n "$LOAD_ERR" ]]; then
    [[ "$soft" == "soft" ]] && return 1
    fatal "$SETTINGS_FILE: $LOAD_ERR   (fix or delete the file, then run again)"
  fi
  return 0
}

save_settings() {
  [[ "$MODE" == "check" ]] && return 0
  local k tmp
  install -d -m 700 "$STATE_DIR"
  tmp="$SETTINGS_FILE.tmp.$$"
  {
    printf '# dg_standby_setup.sh %s settings - written %s\n' "$SCRIPT_VERSION" "$(ts)"
    printf '# Format KEY=VALUE, no spaces, no quotes.\n\n'
    printf '# ---- Standby values. You may change these. ----\n'
    printf '# To rename the standby: change STANDBY_UNIQUE and leave STANDBY_SID, STANDBY_SERVICE and\n'
    printf '# STANDBY_TNS empty; they are derived again. ASM_METHOD: asmlib or udev (or empty = automatic).\n'
    printf '# GRID_MEDIA / DB_MEDIA: installer zip files (comma list). RU_DIR: an unzipped Release Update\n'
    printf '# that the installer applies (needed for 19c on Oracle Linux 9; with Grid use the GI Release Update,\n'
    printf '# it covers both homes). OPATCH_ZIP: the newest OPatch (p6880880_*.zip), needed with RU_DIR.\n'
    printf '# AUX_CHANNELS: 1-16 (RMAN channels of the copy). STANDBY_HOST / STANDBY_IP: this server, as the primary\n'
    printf '# must reach it. PRIMARY_TNS / STANDBY_TNS: alias names written into tnsnames.ora on both servers.\n'
    for k in $STANDBY_KEYS; do printf '%s=%s\n' "$k" "${!k}"; done
    printf '\n# ---- Connection (change with --primary / --user, or here between runs) ----\n'
    printf 'PRIMARY_IP=%s\nPRIMARY_SSH_USER=%s\n' "$PRIMARY_IP" "$PRIMARY_SSH_USER"
    if [[ ${LSNR_ASSUMED:-0} -eq 1 ]]; then
      printf '\n# ---- Assumed (no running listener on the primary offered the service): you may correct these ----\n'
      printf 'PORT=%s\nLISTENER_NAME=%s\nPRIMARY_SERVICE=%s\n' "$PORT" "$LISTENER_NAME" "$PRIMARY_SERVICE"
    fi
    printf '\n# ---- Read from the primary at every run (the standby uses the same paths, users and names). A change here is NOT kept. ----\n'
    for k in $(all_setting_keys); do
      is_standby_key "$k" && continue
      [[ "$k" == PRIMARY_IP || "$k" == PRIMARY_SSH_USER ]] && continue
      [[ ${LSNR_ASSUMED:-0} -eq 1 && ( "$k" == PORT || "$k" == LISTENER_NAME || "$k" == PRIMARY_SERVICE ) ]] && continue
      printf '%s=%s\n' "$k" "${!k}"
    done
  } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SETTINGS_FILE" || { rm -f -- "$tmp"; bad "Cannot write $SETTINGS_FILE (disk full?)"; return 1; }
  # values the script itself sets after you accepted (ASM method, installer files) stay accepted
  [[ ${SETTINGS_ACCEPTED:-0} -eq 1 ]] && save_accepted
  return 0
}

# ---- accepted values (only an accept by the user writes them) ----
settings_lines() {
  # the values that matter for the decision (sizes change every day and are left out)
  local k v
  for k in $(all_setting_keys); do
    case "$k" in PRIMARY_DB_MB|FRA_MB) continue ;; LOCS) v=$(tr ',' '\n' <<< "$LOCS" | cut -d: -f1 | sort | paste -sd, -) ;; *) v=${!k} ;; esac
    printf '%s=%s\n' "$k" "$v"
  done
}
save_accepted() {
  [[ "$MODE" == "check" ]] && return 0
  local tmp="$ACCEPTED_FILE.tmp.$$"
  settings_lines > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$ACCEPTED_FILE" || { rm -f -- "$tmp"; bad "Cannot write $ACCEPTED_FILE"; return 1; }
}
accepted_diff() {
  # prints "KEY: old -> new" for every value that differs from the accepted ones; rc 1 = no accepted file
  [[ -f "$ACCEPTED_FILE" ]] && settings_file_safe "$ACCEPTED_FILE" || return 1
  local line k v old
  while IFS= read -r line; do
    k=${line%%=*}; v=${line#*=}
    old=$(grep -m1 "^$k=" "$ACCEPTED_FILE" | cut -d= -f2-)
    if ! grep -q "^$k=" "$ACCEPTED_FILE"; then printf '%s: (new) -> %s\n' "$k" "$v"
    elif [[ "$old" != "$v" ]]; then printf '%s: %s -> %s\n' "$k" "${old:-<empty>}" "${v:-<empty>}"; fi
  done < <(settings_lines)
  return 0
}

validate_settings() {
  # Cross checks. Prints problems, returns 1 if any.
  local bad_n=0 v t s
  for s in $SETTING_SPECS; do
    v=${s%%:*}; t=${s#*:}
    if [[ "$OPTIONAL_KEYS" != *" $v "* ]]; then
      [[ -n "${!v}" ]] || { bad "Setting $v is empty"; bad_n=1; continue; }
    fi
    valid_value "$t" "${!v}" || { bad "Setting $v has an invalid value: ${!v}"; bad_n=1; }
  done
  for v in DB_HOME ORACLE_BASE GRID_HOME GRID_BASE INVENTORY_DIR; do
    case "${!v}" in /|/usr|/usr/*|/etc|/etc/*|/var|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/root|/home|/proc|/sys|/dev|/dev/*|/tmp)
      bad "$v points to a system folder: ${!v}"; bad_n=1 ;; esac
  done
  if [[ "$USE_GRID" == "yes" ]]; then
    [[ -n "$GRID_HOME" && -n "$GRID_BASE" ]] || { bad "GRID_HOME and GRID_BASE are needed (the primary uses ASM)"; bad_n=1; }
    # the standby uses the same paths as the primary: a layout that works on the primary is kept (only noted)
    [[ "$GRID_HOME/" != "$GRID_BASE/"* ]] || warn "GRID_HOME $GRID_HOME is inside GRID_BASE $GRID_BASE (as on primary; kept)"
    [[ "$GRID_HOME/" != "$ORACLE_BASE/"* ]] || warn "GRID_HOME $GRID_HOME is inside ORACLE_BASE $ORACLE_BASE (as on primary; kept)"
    [[ -n "$DATA_DG" ]] || { bad "DATA_DG (the first ASM disk group) is empty"; bad_n=1; }
  elif all_locs | grep -q '^+'; then
    bad "USE_GRID must be yes: the primary keeps files in ASM"; bad_n=1
  fi
  [[ "$DB_NAME" =~ [\$#] || "$PRIMARY_UNIQUE" =~ [\$#] ]] && { bad "Database names with \$ or # ($DB_NAME / $PRIMARY_UNIQUE) are not supported by this script"; bad_n=1; }
  [[ -n "$STANDBY_IP" && "$STANDBY_IP" != 127.* ]] || { bad "STANDBY_IP must be the network address of this server (not empty, not 127.x)"; bad_n=1; }
  [[ "$STANDBY_IP" != "$PRIMARY_IP" ]] || { bad "STANDBY_IP is the primary IP"; bad_n=1; }
  [[ "${STANDBY_HOST,,}" != "${PRIMARY_HOST,,}" ]] || { bad "STANDBY_HOST must differ from the primary host name"; bad_n=1; }
  if [[ "$STANDBY_IP" =~ ^[0-9.]+$ ]] && command -v ip >/dev/null 2>&1 && ! grep -qw -- "$STANDBY_IP" <<< "$(ip -o addr show 2>/dev/null)"; then
    bad "STANDBY_IP $STANDBY_IP is not an address of this server"; bad_n=1
  fi
  [[ "${PRIMARY_UNIQUE^^}" != "${STANDBY_UNIQUE^^}" ]] || { bad "Standby db_unique_name must differ from primary"; bad_n=1; }
  [[ "${PRIMARY_TNS,,}" != "${STANDBY_TNS,,}" ]] || { bad "The two TNS aliases must differ"; bad_n=1; }
  [[ ${#STANDBY_SID} -le 12 ]] || { bad "STANDBY_SID '$STANDBY_SID' is longer than 12 characters"; bad_n=1; }
  [[ "$STANDBY_SID" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || { bad "STANDBY_SID must start with a letter and use only letters, digits and _"; bad_n=1; }
  [[ ${#STANDBY_UNIQUE} -le 30 ]] || { bad "STANDBY_UNIQUE is longer than 30 characters"; bad_n=1; }
  [[ "$AUX_CHANNELS" =~ ^[0-9]+$ && "$AUX_CHANNELS" -ge 1 && "$AUX_CHANNELS" -le 16 ]] || { bad "AUX_CHANNELS must be 1-16"; bad_n=1; }
  [[ -z "$RU_DIR" || -d "$RU_DIR" ]] || { bad "RU_DIR $RU_DIR is not a folder"; bad_n=1; }
  if [[ -n "$RU_DIR" ]]; then
    [[ -n "$OPATCH_ZIP" && -f "$OPATCH_ZIP" ]] || { bad "RU_DIR needs OPATCH_ZIP: the newest OPatch zip (p6880880), the one in the base media is too old"; bad_n=1; }
  fi
  [[ -z "$OPATCH_ZIP" || -f "$OPATCH_ZIP" ]] || { bad "OPATCH_ZIP $OPATCH_ZIP is not a file"; bad_n=1; }
  return $bad_n
}

derive_standby_settings() {
  # Fills standby-side values that are still empty.
  local ls
  ls=$(hostname -s 2>/dev/null || hostname)
  [[ -n "$STANDBY_HOST" ]] || STANDBY_HOST=$ls
  if [[ -z "$STANDBY_IP" ]]; then
    # the address this server uses to reach the primary; never a loopback address
    STANDBY_IP=$(ip -o route get "$PRIMARY_IP" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)
    [[ "$STANDBY_IP" == 127.* ]] && STANDBY_IP=""
    [[ -n "$STANDBY_IP" ]] || STANDBY_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -v '^127\.' | head -n 1)
  fi
  if [[ -z "$STANDBY_UNIQUE" ]]; then
    local u=${PRIMARY_UNIQUE^^}
    u=${u%%.*}
    if [[ ${#u} -le 7 ]]; then STANDBY_UNIQUE="${u}_STBY"     # e.g. PRODDB_STBY (max 12)
    else STANDBY_UNIQUE="${u:0:9}_SB"; fi                     # ORACLE_SID limit is 12 characters
  fi
  [[ -n "$STANDBY_SID" ]] || { STANDBY_SID=${STANDBY_UNIQUE%%.*}; STANDBY_SID=${STANDBY_SID:0:12}; }
  [[ -n "$STANDBY_SERVICE" ]] || STANDBY_SERVICE="${STANDBY_UNIQUE,,}${PRIMARY_DOMAIN:+.$PRIMARY_DOMAIN}"
  [[ -n "$PRIMARY_TNS" ]] || PRIMARY_TNS="${PRIMARY_UNIQUE,,}"
  [[ -n "$STANDBY_TNS" ]] || STANDBY_TNS="${STANDBY_UNIQUE,,}"
  [[ -n "$AUX_CHANNELS" ]] || AUX_CHANNELS=4
}

# ---- helpers on LOCS ("+DATA:120000,/u02/oradata/X:5000") ----
loc_list() { tr ',' '\n' <<< "$LOCS" | grep -v '^$'; }                    # loc:MB lines
all_locs() {
  # every storage location the standby needs: database files, recovery area, archive destination
  loc_list | cut -d: -f1
  [[ -n "$FRA_LOC" ]] && printf '%s\n' "$FRA_LOC"
  [[ -n "$ARCH_LOC" && "$ARCH_LOC" != "USE_DB_RECOVERY_FILE_DEST" ]] && printf '%s\n' "$ARCH_LOC"
  return 0
}
asm_dgs() { all_locs | grep '^+' | sed 's#^+##; s#/.*##' | tr '[:lower:]' '[:upper:]' | sort -u; }   # disk group names
fs_dirs() { all_locs | grep '^/' | sort -u; }                                                          # directories
fra_need_mb() {
  # space the recovery area needs HERE: the primary size, but at most what is sensible for a standby
  # (archived logs of some days). Step 8.1 sets db_recovery_file_dest_size to the space that is free.
  local want=$FRA_MB min=$(( PRIMARY_DB_MB / 10 )); [[ $min -lt 10240 ]] && min=10240
  [[ $want -gt $min ]] && want=$min
  printf '%s' "$want"
}
dg_need_mb() {
  # MB the disk group $1 must hold: database files in it, plus the recovery area when it is there
  local dg=${1^^} total=0 l loc mb
  while IFS= read -r l; do
    loc=${l%%:*}; mb=${l##*:}; loc=${loc#+}; loc=${loc%%/*}
    [[ "${loc^^}" == "$dg" ]] && total=$((total + mb))
  done < <(loc_list | grep '^+')
  local f=${FRA_LOC#+}; f=${f%%/*}
  [[ "$FRA_LOC" == +* && "${f^^}" == "$dg" ]] && total=$((total + $(fra_need_mb)))
  printf '%s' "$total"
}
loc_mb() { loc_list | awk -F: -v l="$1" '$1==l {s+=$2} END {print s+0}'; }  # MB needed in one location
single_owner() { [[ "$ORACLE_USER" == "$GRID_USER" ]]; }
use_grid() { [[ "$USE_GRID" == "yes" ]]; }

show_settings() {
  local fmt='      %-22s %s\n' l
  printf '\n      %sPRIMARY (read from %s at every run)%s\n' "$C_W" "$PRIMARY_IP" "$C_N"
  printf "$fmt" "host" "$PRIMARY_HOST"
  printf "$fmt" "ORACLE_SID" "$PRIMARY_SID"
  printf "$fmt" "db_name / unique" "$DB_NAME / $PRIMARY_UNIQUE"
  printf "$fmt" "version / CDB" "$PRIMARY_VERSION / $PRIMARY_CDB"
  if [[ ${LSNR_ASSUMED:-0} -eq 1 ]]; then printf "$fmt" "service / port" "$PRIMARY_SERVICE / $PORT  (listener $LISTENER_NAME)  ASSUMED"; printf "$fmt" "" "(no running listener on primary offered the service: check them; correct them with e)"
  else printf "$fmt" "service / port" "$PRIMARY_SERVICE / $PORT  (listener $LISTENER_NAME)"; fi
  [[ -n "${DB_EDITION:-}" ]] && printf "$fmt" "edition" "$DB_EDITION"
  printf "$fmt" "database size" "$(human_mb "$PRIMARY_DB_MB")"
  printf "$fmt" "storage" "$(use_grid && printf 'ASM (Oracle Restart will be installed here)' || printf 'file system (no Grid needed here)')"
  while IFS= read -r l; do printf "$fmt" "" "${l%%:*}  ($(human_mb "${l##*:}"))"; done < <(loc_list)
  printf "$fmt" "recovery area" "${FRA_LOC:-not set}${FRA_LOC:+  ($FRA_MB MB on primary)}"
  printf "$fmt" "archive destination" "${ARCH_LOC:-not set}"
  printf "$fmt" "DB home" "$DB_HOME"
  use_grid && printf "$fmt" "Grid home" "$GRID_HOME"
  printf "$fmt" "Oracle base" "$ORACLE_BASE"
  use_grid && printf "$fmt" "Grid base" "$GRID_BASE"
  printf "$fmt" "inventory" "$INVENTORY_DIR"
  if single_owner; then printf "$fmt" "owner" "$ORACLE_USER ($ORACLE_UID) owns everything"
  else printf "$fmt" "users" "$ORACLE_USER ($ORACLE_UID)  $GRID_USER ($GRID_UID)"; fi
  printf "$fmt" "groups" "$GROUP_GIDS"
  printf "$fmt" "homes, users, paths" "the same here (fixed: RMAN copies the files without renaming)"
  printf '\n      %sSTANDBY (this server; you may change these: e)%s   (key in the settings file)\n' "$C_W" "$C_N"
  printf "$fmt" "host / IP" "$STANDBY_HOST / $STANDBY_IP   (STANDBY_HOST, STANDBY_IP)"
  printf "$fmt" "db_unique_name" "$STANDBY_UNIQUE   (STANDBY_UNIQUE)"
  [[ "$STANDBY_UNIQUE" == *_SB ]] && printf "$fmt" "" "(_SB, not _STBY: ORACLE_SID can have at most 12 characters)"
  printf "$fmt" "ORACLE_SID" "$STANDBY_SID   (STANDBY_SID)"
  printf "$fmt" "service" "$STANDBY_SERVICE   (STANDBY_SERVICE)"
  printf "$fmt" "TNS aliases" "$PRIMARY_TNS (primary)   $STANDBY_TNS (standby)   (PRIMARY_TNS, STANDBY_TNS)"
  printf "$fmt" "listener" "$SB_LSNR, port $PORT   (always LISTENER here; with Grid it is created by Grid)"
  printf "$fmt" "installer files" "${GRID_MEDIA:-}${GRID_MEDIA:+  }${DB_MEDIA:-found later (step 3.1)}   (GRID_MEDIA, DB_MEDIA)"
  [[ -n "$RU_DIR" ]] && printf "$fmt" "release update" "$RU_DIR (applied by the installer)   (RU_DIR, OPATCH_ZIP)"
  use_grid && printf "$fmt" "ASM disk method" "${ASM_METHOD:-decided in step 2.12}   (ASM_METHOD)"
  printf "$fmt" "RMAN channels" "$AUX_CHANNELS   (AUX_CHANNELS)"
  printf '\n'
  _log SETTINGS "$(for k in $(all_setting_keys); do printf '%s=%s ' "$k" "${!k}"; done)"
}

group_gid() {
  # $1 group name -> gid from GROUP_GIDS
  local e
  IFS=',' read -ra _gg <<< "$GROUP_GIDS"
  for e in "${_gg[@]}"; do [[ "${e%%:*}" == "$1" ]] && { printf '%s' "${e#*:}"; return 0; }; done
  return 1
}
