#------------------------------------------------------------------------------
# Where the files of the standby go, how big its recovery area is, and the RMAN channels of the copy.
#
#   DATA_DEST  database files (datafiles, tempfiles, control files, online and standby logs):
#                +DG     a disk group here (OMF names)
#                same    the same paths as on the primary
#                /dir    a folder here (OMF names)
#              empty = automatic: the data disk group when this server has ASM, else "same"
#   FRA_DEST   the recovery area (also the archived logs): +DG, same, /dir, or empty = automatic
#   FRA_SIZE   its size, for example 60G (empty = estimated from the redo of the primary)
#   PRIMARY_CHANNELS / AUX_CHANNELS   RMAN channels on the primary and on this server
#
# These functions are the one place for the rules: the RMAN script of the copy, the space checks, the
# clean-up of a failed copy, the summary screen and the standby logs (9.3) all use them. A later copy
# method (backup and restore) can use the same placement and the same RMAN parts.
#------------------------------------------------------------------------------
REDO_DAY_MB=""          # the largest day of archived redo on the primary in the last 7 days (MB); "" = not read
CPU_HERE=""; CPU_PRIMARY=""

dg_of() { local v=${1#+}; v=${v%%/*}; printf '+%s' "${v^^}"; }       # "+data/X/y" -> "+DATA"
data_dest() {
  if [[ -n "${DATA_DEST:-}" ]]; then
    if [[ "$DATA_DEST" == +* ]]; then dg_of "$DATA_DEST"; else printf '%s' "$DATA_DEST"; fi
  elif use_grid && [[ -n "$DATA_DG" ]]; then printf '+%s' "${DATA_DG^^}"
  else printf 'same'; fi
}
place_mode() { local d; d=$(data_dest); case "$d" in same) printf 'same' ;; +*) printf 'asm' ;; *) printf 'dir' ;; esac; }
fra_dest() {
  # the recovery area of the standby ("" = none, only possible with "same" when the primary has none)
  local d; d=$(data_dest)
  if [[ -n "${FRA_DEST:-}" && "$FRA_DEST" != same ]]; then
    if [[ "$FRA_DEST" == +* ]]; then dg_of "$FRA_DEST"; else printf '%s' "$FRA_DEST"; fi; return 0
  fi
  if [[ "${FRA_DEST:-}" == same || "$d" == same ]]; then printf '%s' "$FRA_LOC"; return 0; fi
  # ASM: the recovery area disk group of the primary when it has one, else the data disk group
  if [[ "$d" == +* ]]; then if [[ "$FRA_LOC" == +* ]]; then dg_of "$FRA_LOC"; else printf '%s' "$d"; fi; return 0; fi
  printf '%s' "$d"
}
arch_dest_sb() {
  # where the standby writes its archived logs: as on the primary when the files keep its paths, else the recovery area
  if [[ "$(place_mode)" == same ]]; then printf '%s' "$ARCH_LOC"
  elif [[ -n "$(fra_dest)" ]]; then printf 'USE_DB_RECOVERY_FILE_DEST'
  else printf '%s' "$ARCH_LOC"; fi
}
sb_loc_list() {
  # loc:MB lines of the database files on THIS server
  local d; d=$(data_dest)
  if [[ "$d" == same ]]; then loc_list; return 0; fi
  printf '%s:%s\n' "$d" "$(loc_list | awk -F: '{s+=$2} END {print s+0}')"
}
primary_mixed() {
  # the primary keeps files both in ASM and in folders
  loc_list | grep -q '^+' && loc_list | grep -q '^/'
}
place_text() {
  # one line for a destination: "+DATA (ASM)", "same paths as the primary", "/u02/oradata (folder)"
  case "$1" in same) printf 'the same paths as on the primary' ;; +*) printf '%s (ASM)' "$1" ;; "") printf 'none' ;; *) printf '%s (folder)' "$1" ;; esac
}
primary_where() {
  # where the primary keeps its database files: "+DATA", "/u01/... and +DATA"
  local a f
  a=$(loc_list | cut -d: -f1 | grep '^+' | sort -u | paste -sd' ' -)
  f=$(loc_list | cut -d: -f1 | grep '^/' | sort -u | paste -sd' ' -)
  if [[ -n "$a" && -n "$f" ]]; then printf '%s (file system) and %s (ASM)' "$f" "$a"
  elif [[ -n "$a" ]]; then printf '%s (ASM)' "$a"; else printf '%s (file system)' "$f"; fi
}

# ---- recovery area size ----
redo_day_read() {
  # the largest day of archived redo of the last 7 days on the primary (each log counted once, read-only)
  [[ -n "$REDO_DAY_MB" ]] && return 0
  need_ssh || return 1
  prim_sql "select nvl(round(max(mb)),0) redo_day_max from (select trunc(ft) d, sum(b)/1048576 mb from (select thread#, sequence#, max(blocks*block_size) b, min(first_time) ft from v\$archived_log where first_time > sysdate-7 and standby_dest='NO' group by thread#, sequence#) group by trunc(ft));" || return 1
  num "$(first_line)" || return 1
  REDO_DAY_MB=$(first_line)
}
NET_MBS=""          # measured speed from the primary to this server (MB/s, over ssh); "" = not measured
net_speed_read() {
  # 64 MB of zeros from the primary to this server over the ssh connection (the primary reads and writes no
  # file: dd from /dev/zero to its output). A rough lower bound for the copy (RMAN uses SQL*Net, not ssh).
  [[ -n "$NET_MBS" ]] && return 0
  # not in --check: it only reports, and 64 MB is load on the primary nobody asked for
  [[ "${MODE:-}" == check ]] && return 1
  ssh_alive || return 1
  local t0 t1 rc=0 ms
  t0=$(date +%s%N)
  PROBE_TIMEOUT=60 prim_ssh "dd if=/dev/zero bs=1M count=64 status=none" > /dev/null 2>&1 < /dev/null || rc=$?
  t1=$(date +%s%N)
  [[ $rc -eq 0 ]] || { _log INFO "network speed: the measure failed (exit $rc)"; return 1; }
  ms=$(( (t1 - t0) / 1000000 )); [[ $ms -lt 1 ]] && ms=1
  NET_MBS=$(( 64 * 1000 / ms )); [[ $NET_MBS -lt 1 ]] && NET_MBS=1
  _log INFO "network speed from the primary: about $NET_MBS MB/s (64 MB in $ms ms over ssh)"
  return 0
}
copy_minutes() {
  # $1 lo|hi: a rough time of the copy. Measured network speed: lo = at that speed, hi = at two thirds of it.
  # Not measured: lo = fast storage and network (150 MB/s per channel, at most 1000), hi = a 1 Gbit/s network.
  local rate=100
  if num "${NET_MBS:-}"; then
    rate=$NET_MBS; [[ "${1:-hi}" == hi ]] && rate=$(( NET_MBS * 2 / 3 ))
    local cap=$(( $(chan_n "${AUX_CHANNELS:-}" 4) * 150 )); [[ $rate -gt $cap ]] && rate=$cap
    [[ $rate -lt 1 ]] && rate=1
  elif [[ "${1:-hi}" == lo ]]; then rate=$(( $(chan_n "${AUX_CHANNELS:-}" 4) * 150 )); [[ $rate -gt 1000 ]] && rate=1000; fi
  printf '%s' $(( ${PRIMARY_DB_MB:-0} / rate / 60 + 1 ))
}
copy_speed_text() { num "${NET_MBS:-}" && printf 'network measured: about %s MB/s from the primary' "$NET_MBS" || printf 'network not measured%s' "$([[ "${MODE:-}" == check ]] && printf ' in check mode')"; }
fra_estimate_mb() {
  # the archived logs of the time the copy takes (the copy restores them into the recovery area to recover
  # the new standby), one day more for the standby itself, plus 30 %; at least 10 GB, in whole GB.
  # A copy that already filled the recovery area: at least twice that size.
  local day=${REDO_DAY_MB:-} mb min=10240 h
  h=$(( ($(copy_minutes hi) + 59) / 60 ))
  if num "$day" && [[ $day -gt 0 ]]; then mb=$(( (day * h / 24 + day) * 13 / 10 ))
  else mb=$(( ${PRIMARY_DB_MB:-0} / 10 )); fi
  [[ $mb -lt $min ]] && mb=$min
  local full; full=$(fra_full_mb)
  [[ -n "$full" && $mb -lt $(( full * 2 )) ]] && mb=$(( full * 2 ))
  printf '%s' $(( (mb + 1023) / 1024 * 1024 ))
}
fra_size_mb() {
  # FRA_SIZE when set; but never less than twice the size a copy already filled (ORA-19809): the copy would fail again
  if [[ -n "${FRA_SIZE:-}" ]]; then
    local v=$(( 10#${FRA_SIZE%G} * 1024 )) full; full=$(fra_full_mb)
    [[ -n "$full" && $v -lt $(( full * 2 )) ]] && v=$(( (full * 2 + 1023) / 1024 * 1024 ))
    printf '%s' "$v"; return 0
  fi
  fra_estimate_mb
}
fra_size_why() {
  if [[ -n "${FRA_SIZE:-}" ]]; then
    printf 'set by you (FRA_SIZE=%s)' "$FRA_SIZE"
    local full; full=$(fra_full_mb)
    [[ -n "$full" && $(( 10#${FRA_SIZE%G} * 1024 )) -lt $(( full * 2 )) ]] && printf ', raised: a copy filled %s, so at least twice that' "$(human_mb "$full")"
    return 0
  elif num "${REDO_DAY_MB:-}" && [[ ${REDO_DAY_MB:-0} -gt 0 ]]; then
    printf 'redo of the copy time and one day (%s a day on the primary), plus 30 %%' "$(human_mb "$REDO_DAY_MB")"
  else printf 'a tenth of the database (the redo of the primary could not be read), at least 10 GB'; fi
  [[ -n "$(fra_full_mb)" ]] && printf '; at least twice the %s that a copy filled' "$(human_mb "$(fra_full_mb)")"
  return 0
}
fra_full_file() { printf '%s/fra_full' "$STATE_DIR"; }
fra_full_mb() { local v; [[ -n "$STATE_DIR" && -f "$(fra_full_file)" ]] && v=$(head -n 1 -- "$(fra_full_file)") && num "$v" && printf '%s' "$v"; return 0; }

# ---- RMAN channels ----
cpus_read() {
  [[ -n "$CPU_HERE" ]] || CPU_HERE=$(nproc 2>/dev/null)
  num "$CPU_HERE" || CPU_HERE=""
  if [[ -z "$CPU_PRIMARY" ]] && ssh_alive && prim_probe cpus; then CPU_PRIMARY=$(first_line_of "$RUN_OUT"); num "$CPU_PRIMARY" || CPU_PRIMARY=""; fi
  return 0
}
first_line_of() { printf '%s\n' "$1" | sed -n '/[^[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p; q}'; }
chan_suggest() {
  # half the CPUs of each server, 2 to 8; this server never fewer than the primary (backup sets need that)
  local a=4 p=4
  num "$CPU_HERE" && { a=$(( CPU_HERE / 2 )); [[ $a -lt 2 ]] && a=2; [[ $a -gt 8 ]] && a=8; }
  num "$CPU_PRIMARY" && { p=$(( CPU_PRIMARY / 2 )); [[ $p -lt 2 ]] && p=2; [[ $p -gt 8 ]] && p=8; }
  [[ $p -gt $a ]] && p=$a
  printf '%s %s' "$p" "$a"
}
# a channel count as a plain number: a value that is not 1..64 (08, abc, empty) gives $2 instead. The summary
# and the copy plan use the counts before the settings are checked; raw "08" would be a bash error there.
chan_n() { if [[ "${1:-}" =~ ^[0-9]{1,2}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 64 )); then printf '%s' $((10#$1)); else printf '%s' "$2"; fi; }
prim_channels() {
  local a p; a=$(chan_n "${AUX_CHANNELS:-}" 4); p=$(chan_n "${PRIMARY_CHANNELS:-}" "$a")
  [[ $p -gt $a ]] && p=$a
  printf '%s' "$p"
}

# ---- the RMAN parts that place the files (one source for the copy, and later for a restore) ----
rman_channel_lines() {
  local i out=""
  for ((i = 1; i <= $(prim_channels); i++)); do out+="  allocate channel p$i device type disk;"$'\n'; done
  for ((i = 1; i <= $(chan_n "${AUX_CHANNELS:-}" 4); i++)); do out+="  allocate auxiliary channel a$i device type disk;"$'\n'; done
  printf '%s' "$out"
}
place_newname_lines() {
  # "set newname" lines: one for the whole database (ASM or a folder), or, with the same paths, the per-file
  # lines dup_prechecks built from the primary's file names (NEWNAMES)
  case "$(place_mode)" in
    asm) printf "  set newname for database to '%s';\n" "$(data_dest)" ;;
    dir) printf '  set newname for database to new;\n' ;;
    *)   printf '%s' "${NEWNAMES:-}" ;;
  esac
}
place_spfile_sets() {
  # the "set" lines of the spfile clause that place the files (control files, OMF destinations, recovery area)
  local d f; d=$(data_dest); f=$(fra_dest)
  case "$(place_mode)" in
    asm|dir)
      if [[ "$d" == +* ]]; then printf "      set control_files='%s'\n" "$d"
      else printf "      set control_files='%s/control01.ctl'\n" "$d"; fi
      printf "      set db_create_file_dest='%s'\n" "$d"
      printf "      set db_create_online_log_dest_1='%s'\n" "$d"
      local n; for n in 2 3 4 5; do [[ " ${PRIMARY_OLD_DESTS:-} " == *" $n "* ]] && printf "      set db_create_online_log_dest_%s=''\n" "$n"; done ;;
    *) printf '      set control_files=%s\n' "${CF_LIST:-}" ;;
  esac
  if [[ -n "$f" ]]; then
    printf "      set db_recovery_file_dest='%s'\n" "$f"
    printf "      set db_recovery_file_dest_size='%sG'\n" $(( $(fra_size_mb) / 1024 ))
  fi
  return 0
}
ask_channels() {
  # before the copy: the RMAN channels on both servers, with the CPUs of both and a suggestion. The answer is saved
  # as the default. 1 = do not copy now.
  cpus_read
  local sp sa p a; read -r sp sa <<< "$(chan_suggest)"
  while true; do
    say "RMAN channels: $(prim_channels) on the primary, $AUX_CHANNELS on this server."
    say "${C_D}CPUs: ${CPU_PRIMARY:-not known} on the primary, ${CPU_HERE:-not known} here. Suggested: $sp and $sa.${C_N}"
    [[ $YES_MODE -eq 1 ]] && return 0
    ask_choice "[k] Keep these   [c] Change   [s] Do not copy now" "kcs"
    case "$ANSWER" in
      k) return 0 ;;
      s) return 1 ;;
      c) ask_default "Channels on the primary (1-64)" "$sp"; p=$ANSWER
         # checked before any arithmetic: 08, 1.5 or a word would stop bash itself
         [[ "$p" =~ ^[0-9]{1,2}$ ]] && (( 10#$p >= 1 && 10#$p <= 64 )) || { say "Use a number from 1 to 64."; continue; }
         p=$((10#$p))
         ask_default "Channels on this server ($p-64, not fewer than on the primary)" "$(( sa > p ? sa : p ))"; a=$ANSWER
         if [[ "$p" =~ ^[0-9]{1,2}$ && "$a" =~ ^[0-9]{1,2}$ ]] && (( 10#$p >= 1 && 10#$p <= 64 && 10#$a >= 10#$p && 10#$a <= 64 )); then
           PRIMARY_CHANNELS=$((10#$p)); AUX_CHANNELS=$((10#$a)); save_settings
           _log SETTINGS "RMAN channels: primary $PRIMARY_CHANNELS, auxiliary $AUX_CHANNELS"
         else say "Use numbers from 1 to 64, and not fewer on this server than on the primary."; fi ;;
    esac
  done
}
