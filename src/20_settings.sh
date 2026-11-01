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
readonly DERIVED_KEYS=" STANDBY_HOST STANDBY_IP STANDBY_SID STANDBY_SERVICE PRIMARY_TNS STANDBY_TNS AUX_CHANNELS "
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
    ip)        if [[ "$v" =~ ^[0-9.]+$ ]]; then
                 # an IPv4 address: four numbers 0-255 (10.0.0 or 999.1.1.1 are refused)
                 [[ "$v" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
                   && (( 10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 && 10#${BASH_REMATCH[3]} <= 255 && 10#${BASH_REMATCH[4]} <= 255 ))
               else
                 # a host name: letters, digits, dots and dashes, at least one letter, no empty label
                 [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$v" =~ [A-Za-z] && "$v" != *..* ]]
               fi ;;
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
  [[ -f "$SETTINGS_FILE" ]] || { LOAD_ERR="$SETTINGS_FILE is missing"; return 1; }
  if ! settings_file_safe "$SETTINGS_FILE"; then
    LOAD_ERR="$SETTINGS_FILE must be a file owned by root that others cannot write"
    [[ "$soft" == "soft" ]] && return 1; fatal "$LOAD_ERR"
  fi
  local seen_keys=" "
  while IFS= read -r line || [[ -n "$line" ]]; do
    # a comment is a line that starts with #, or # after a space: a # inside a value is kept (and then checked)
    line="${line#"${line%%[![:space:]]*}"}"; [[ "$line" == "#"* ]] && continue
    line=${line%%[[:space:]]#*}; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$line" != *=* ]]; then LOAD_ERR="This line is not KEY=VALUE: $line"; break; fi
    key=${line%%=*}; val=${line#*=}
    local rawkey=$key
    case "$key" in
      GRID_ZIP) key=GRID_MEDIA; SETTINGS_UPGRADED=1 ;;
      DB_ZIP)   key=DB_MEDIA;   SETTINGS_UPGRADED=1 ;;
    esac
    # the same key twice (also under its old name, GRID_ZIP and GRID_MEDIA): which one counts would be a guess
    if [[ "$seen_keys" == *" $key "* ]]; then LOAD_ERR="$key is set twice$([[ "$rawkey" != "$key" ]] && printf ' (also as %s)' "$rawkey"). Keep one line."; break; fi
    seen_keys+="$key "
    if [[ "$OLD_KEYS" == *" $key "* ]]; then DROPPED_KEYS+=" $key"; SETTINGS_UPGRADED=1; continue; fi
    spec=""
    for t in $SETTING_SPECS; do [[ "${t%%:*}" == "$key" ]] && spec=${t#*:}; done
    if [[ -z "$spec" ]]; then DROPPED_KEYS+=" $key"; continue; fi
    # values that are derived again when empty (the settings file says so for a new standby name)
    if [[ -z "$val" && "$DERIVED_KEYS" == *" $key "* ]]; then printf -v "$key" '%s' ""; continue; fi
    if ! valid_value "$spec" "$val"; then
      # a typo in a value you may edit is an error; it is never ignored silently
      if is_standby_key "$key" || assumed_key "$key"; then LOAD_ERR="Invalid value: $key=$val"; break; fi
      continue        # a primary value is read again from the primary anyway
    fi
    printf -v "$key" '%s' "$val"
  done < "$SETTINGS_FILE"
  if [[ -n "$LOAD_ERR" ]]; then
    [[ "$soft" == "soft" ]] && return 1
    fatal "$SETTINGS_FILE: $LOAD_ERR
Fix or delete the file, then run the script again."
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
  } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SETTINGS_FILE" || { rm -f -- "$tmp"; bad "Cannot write $SETTINGS_FILE. Is the disk full?"; return 1; }
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
      [[ -n "${!v}" ]] || { bad "$v is empty."; bad_n=1; continue; }
    fi
    valid_value "$t" "${!v}" || { bad "$v has an invalid value: ${!v}"; bad_n=1; }
  done
  for v in DB_HOME ORACLE_BASE GRID_HOME GRID_BASE INVENTORY_DIR; do
    case "${!v}" in /|/usr|/usr/*|/etc|/etc/*|/var|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/root|/home|/proc|/sys|/dev|/dev/*|/tmp)
      bad "$v is a system folder: ${!v}"; bad_n=1 ;; esac
  done
  if [[ "$USE_GRID" == "yes" ]]; then
    [[ -n "$GRID_HOME" && -n "$GRID_BASE" ]] || { bad "GRID_HOME and GRID_BASE are needed, because the primary uses ASM."; bad_n=1; }
    # the standby uses the same paths as the primary: a layout that works on the primary is kept (only noted)
    [[ "$GRID_HOME/" != "$GRID_BASE/"* ]] || warn "The Grid home $GRID_HOME is inside the Grid base $GRID_BASE. This is the same on the primary, so it is kept."
    [[ "$GRID_HOME/" != "$ORACLE_BASE/"* ]] || warn "The Grid home $GRID_HOME is inside the Oracle base $ORACLE_BASE. This is the same on the primary, so it is kept."
    [[ -n "$DATA_DG" ]] || { bad "DATA_DG (the first ASM disk group) is empty."; bad_n=1; }
  elif all_locs | grep -q '^+'; then
    bad "USE_GRID must be yes, because the primary keeps files in ASM."; bad_n=1
  fi
  [[ "$DB_NAME" =~ [\$#] || "$PRIMARY_UNIQUE" =~ [\$#] ]] && { bad "This script does not support database names with \$ or # ($DB_NAME, $PRIMARY_UNIQUE)."; bad_n=1; }
  # names are resolved first: a host name on one side and its address on the other is the same server
  local sip pip; sip=$(ipv4_of "$STANDBY_IP"); pip=$(ipv4_of "$PRIMARY_IP")
  [[ "$STANDBY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { bad "STANDBY_IP must be an IPv4 address (it is used as an address in the firewall and listener steps)."; bad_n=1; }
  [[ -n "$STANDBY_IP" && "$STANDBY_IP" != 127.* ]] || { bad "STANDBY_IP must be the network address of this server. It cannot be empty or 127.x."; bad_n=1; }
  [[ "$STANDBY_IP" != "$PRIMARY_IP" && ( -z "$sip" || "$sip" != "$pip" ) ]] || { bad "STANDBY_IP is the IP address of the primary."; bad_n=1; }
  [[ "${STANDBY_HOST,,}" != "${PRIMARY_HOST,,}" ]] || { bad "STANDBY_HOST must differ from the host name of the primary."; bad_n=1; }
  # STANDBY_IP is an IPv4 address (checked above): it must be one of this server
  if [[ "$STANDBY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && command -v ip >/dev/null 2>&1 && ! is_local_ip "$STANDBY_IP"; then
    bad "STANDBY_IP $STANDBY_IP is not an address of this server."; bad_n=1
  fi
  [[ "${PRIMARY_UNIQUE^^}" != "${STANDBY_UNIQUE^^}" ]] || { bad "STANDBY_UNIQUE must differ from the db_unique_name of the primary."; bad_n=1; }
  [[ "${PRIMARY_TNS,,}" != "${STANDBY_TNS,,}" ]] || { bad "PRIMARY_TNS and STANDBY_TNS must differ."; bad_n=1; }
  [[ ${#STANDBY_SID} -le 12 ]] || { bad "STANDBY_SID '$STANDBY_SID' is longer than 12 characters."; bad_n=1; }
  [[ "$STANDBY_SID" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || { bad "STANDBY_SID must start with a letter and use only letters, digits and _."; bad_n=1; }
  [[ ${#STANDBY_UNIQUE} -le 30 ]] || { bad "STANDBY_UNIQUE is longer than 30 characters."; bad_n=1; }
  [[ "$AUX_CHANNELS" =~ ^[0-9]+$ && "$AUX_CHANNELS" -ge 1 && "$AUX_CHANNELS" -le 16 ]] || { bad "AUX_CHANNELS must be a number from 1 to 16."; bad_n=1; }
  [[ -z "$RU_DIR" || -d "$RU_DIR" ]] || { bad "RU_DIR $RU_DIR is not a folder."; bad_n=1; }
  if [[ -n "$RU_DIR" ]]; then
    [[ -n "$OPATCH_ZIP" && -f "$OPATCH_ZIP" ]] || { bad "RU_DIR needs OPATCH_ZIP, the newest OPatch zip (p6880880).
The OPatch in the base media is too old."; bad_n=1; }
  fi
  [[ -z "$OPATCH_ZIP" || -f "$OPATCH_ZIP" ]] || { bad "OPATCH_ZIP $OPATCH_ZIP is not a file."; bad_n=1; }

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
  # two short sections; the names of the keys are in the settings file (the editor shows them)
  local fmt='        %-17s %s\n' l first=1
  printf '\n      %sPrimary%s  %s(read from %s at every run)%s\n' "$C_W" "$C_N" "$C_D" "$PRIMARY_IP" "$C_N"
  printf "$fmt" "Host" "$PRIMARY_HOST"
  printf "$fmt" "Database" "$DB_NAME, unique name $PRIMARY_UNIQUE"
  printf "$fmt" "ORACLE_SID" "$PRIMARY_SID"
  printf "$fmt" "Version" "$PRIMARY_VERSION, CDB $PRIMARY_CDB"
  if [[ ${LSNR_ASSUMED:-0} -eq 1 ]]; then
    printf "$fmt" "Service" "$PRIMARY_SERVICE  (assumed)"
    printf "$fmt" "Listener" "$LISTENER_NAME, port $PORT  (assumed)"
    printf "$fmt" "" "${C_Y}No running listener offers this service. Check these two lines.${C_N}"
  else
    printf "$fmt" "Service" "$PRIMARY_SERVICE"
    printf "$fmt" "Listener" "$LISTENER_NAME, port $PORT"
  fi
  printf "$fmt" "Size" "$(human_mb "$PRIMARY_DB_MB")"
  [[ -n "${DB_EDITION:-}" ]] && printf "$fmt" "Edition" "$DB_EDITION"
  printf "$fmt" "Storage" "$(use_grid && printf 'ASM (Oracle Restart will be installed here)' || printf 'File system (no Grid needed here)')"
  while IFS= read -r l; do
    printf "$fmt" "$([[ $first -eq 1 ]] && printf 'Data files')" "${l%%:*}  ($(human_mb "${l##*:}"))"; first=0
  done < <(loc_list)
  printf "$fmt" "Recovery area" "${FRA_LOC:-not set}${FRA_LOC:+  ($(human_mb "$FRA_MB") on the primary)}"
  printf "$fmt" "Archive logs" "${ARCH_LOC:-not set}"
  printf "$fmt" "Database home" "$DB_HOME"
  use_grid && printf "$fmt" "Grid home" "$GRID_HOME"
  printf "$fmt" "Oracle base" "$ORACLE_BASE"
  use_grid && printf "$fmt" "Grid base" "$GRID_BASE"
  printf "$fmt" "Inventory" "$INVENTORY_DIR"
  if single_owner; then printf "$fmt" "Owner" "$ORACLE_USER ($ORACLE_UID), owns all Oracle software"
  else printf "$fmt" "Users" "$ORACLE_USER ($ORACLE_UID), $GRID_USER ($GRID_UID)"; fi
  local gl="" gn=0 g lab="Groups"
  for g in ${GROUP_GIDS//,/ }; do
    gl+="${gl:+, }$g"; gn=$((gn + 1))
    [[ $gn -eq 4 ]] && { printf "$fmt" "$lab" "$gl"; lab=""; gl=""; gn=0; }
  done
  [[ -n "$gl" ]] && printf "$fmt" "$lab" "$gl"
  printf '        %sThis server gets the same homes, users and paths.%s\n' "$C_D" "$C_N"

  printf '\n      %sThis server (standby)%s  %s(change with e)%s\n' "$C_W" "$C_N" "$C_D" "$C_N"
  printf "$fmt" "Host" "$STANDBY_HOST, $STANDBY_IP"
  printf "$fmt" "db_unique_name" "$STANDBY_UNIQUE"
  printf "$fmt" "ORACLE_SID" "$STANDBY_SID"
  [[ "$STANDBY_UNIQUE" == *_SB ]] && printf "$fmt" "" "${C_D}_SB, not _STBY: an ORACLE_SID has at most 12 characters${C_N}"
  printf "$fmt" "Service" "$STANDBY_SERVICE"
  printf "$fmt" "TNS aliases" "$PRIMARY_TNS (primary), $STANDBY_TNS (standby)"
  printf "$fmt" "Listener" "$SB_LSNR, port $PORT"
  if [[ -n "$GRID_MEDIA$DB_MEDIA" ]]; then
    local lab="Installer files"
    for l in ${GRID_MEDIA//,/ } ${DB_MEDIA//,/ }; do printf "$fmt" "$lab" "$l"; lab=""; done
    [[ -z "$DB_MEDIA" ]] && printf "$fmt" "" "database files: found later (step 3.1)"
  else printf "$fmt" "Installer files" "found later (step 3.1)"; fi
  [[ -n "$RU_DIR" ]] && printf "$fmt" "Release Update" "$RU_DIR"
  [[ -n "$OPATCH_ZIP" ]] && printf "$fmt" "OPatch" "$OPATCH_ZIP"
  use_grid && printf "$fmt" "ASM disk method" "${ASM_METHOD:-decided in step 2.12}"
  printf "$fmt" "RMAN channels" "$AUX_CHANNELS"
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
