#------------------------------------------------------------------------------
# The summary screen (step 1.4): the problems found now (first, so they are seen on a small screen too), what was
# found on the primary and on this server, the names of both sides (Names), where the standby goes, the plan (with
# what you run on the primary and as which user), and the values of this run, numbered. Shown on every setup run after phase 1 read both
# servers:  [Enter] Start   [number] Change   [d] Details   [e] Edit the file   [h] Help   [q] Quit
# A number asks only that value (the same checks as --settings), saves it as the new default and draws the screen
# again. --check prints the same screen as a report (no question); --health never shows it.
# Kept as LOG_DIR/summary_<run>.txt.
#------------------------------------------------------------------------------
SUM_FACTS_READ=0; SUM_LOGMODE=""; SUM_FORCELOG=""; SUM_FLASHBACK=""; SUM_SRL=""; SUM_PDBS=""; SUM_BROKER=""; SUM_DESTS=""
SUM_SPFILE=""; SUM_PWFILE=""; SUM_PROT=""; SUM_DEST_N=""; SUM_P27=""; SUM_PATCHES=""; SUM_PATCHES_READ=0
SUM_MEDIA_DONE=0; SUM_GRID_FOUND=""; SUM_DB_FOUND=""; CHAN_SUGGESTED=0
summary_facts() {
  # read-only, once per run: what phase 4 will check on the primary, for the summary
  summary_media
  [[ $SUM_FACTS_READ -eq 1 ]] && return 0
  # marked as read only after the first query worked: a failed read is tried again at the next summary
  ssh_alive || return 0
  prim_sql "select log_mode||'|'||force_logging||'|'||flashback_on from v\$database;" || return 0
  SUM_FACTS_READ=1
  IFS='|' read -r SUM_LOGMODE SUM_FORCELOG SUM_FLASHBACK <<< "$(first_line)"
  prim_sql "select count(*) from v\$standby_log;" && num "$(first_line)" && SUM_SRL=$(first_line)
  if [[ "$PRIMARY_CDB" == YES ]] && prim_sql "select count(*) from v\$pdbs where name<>'PDB\$SEED';"; then num "$(first_line)" && SUM_PDBS=$(first_line); fi
  prim_sql "select upper(value) from v\$parameter where name='dg_broker_start';" && SUM_BROKER=$(first_line)
  prim_sql "select count(*) from v\$archive_dest where status<>'INACTIVE' and target='STANDBY';" && num "$(first_line)" && SUM_DESTS=$(first_line)
  # the names table: where the spfile and the password file of the primary are, its protection mode, the
  # log_archive_dest_N that step 4.4 uses (the same choice as 4.4: one that names the standby, else 2, else the first free)
  prim_sql "select nvl(value,'-') from v\$parameter where name='spfile';" && SUM_SPFILE=$(first_line)
  prim_sql "select nvl(max(file_name),'-') from v\$passwordfile_info;" && SUM_PWFILE=$(first_line)
  prim_sql "select protection_mode from v\$database;" && [[ "$(first_line)" =~ ^[A-Z\ ]+$ ]] && SUM_PROT=$(first_line)
  find_dest >/dev/null 2>&1 && SUM_DEST_N=$DEST_N
  # step 2.7: does the primary resolve its own name and this server's name (the same tests as 2.7)?
  local pp prc=0; primary_name_problems > /dev/null 2>&1 || prc=$?; pp=$PNP_OUT
  if [[ $prc -eq 0 && -n "$pp" ]]; then SUM_P27="its own name ${PRIMARY_HOST:-}"
  elif prim_probe hosts "$STANDBY_HOST" >/dev/null 2>&1; then
    local pip; pip=$(awk '{print $1; exit}' <<< "$RUN_OUT")
    if [[ -z "$pip" ]]; then SUM_P27="it does not resolve $STANDBY_HOST"
    elif [[ "$pip" != "$STANDBY_IP" ]]; then SUM_P27="it resolves $STANDBY_HOST to $pip"; fi
  fi
  # the patches of the primary's database home, when the software is still to be installed here (Release Update)
  if ! db_sw_ok 2>/dev/null; then
    local pl; if pl=$(primary_patches "$DB_HOME" 2>/dev/null); then SUM_PATCHES_READ=1; SUM_PATCHES=$(head -n 3 <<< "$pl" | paste -sd' ' -); [[ $(grep -c . <<< "$pl") -gt 3 ]] && SUM_PATCHES+=" ..."; fi
  fi
  redo_day_read >/dev/null 2>&1 || true
  [[ -f "$(dup_marker)" ]] || net_speed_read || true
  cpus_read
  chan_default_apply
  return 0
}
summary_media() {
  # the installer zips, searched as step 3.1 does (read-only), so the summary does not say "not found" for zips
  # that 3.1 then finds. Once per run; the settings (GRID_MEDIA, DB_MEDIA) are set by 3.1, not here.
  [[ $SUM_MEDIA_DONE -eq 1 ]] && return 0
  SUM_MEDIA_DONE=1
  local need_g=0 need_d=0
  use_grid && ! grid_sw_ok 2>/dev/null && [[ -z "$GRID_MEDIA" ]] && need_g=1
  ! db_sw_ok 2>/dev/null && [[ -z "$DB_MEDIA" ]] && need_d=1
  [[ $need_g -eq 1 || $need_d -eq 1 ]] || return 0
  declare -F scan_media >/dev/null && declare -F pick_media >/dev/null || return 0
  scan_media 2>/dev/null || true
  [[ $need_g -eq 1 ]] && SUM_GRID_FOUND=$(pick_media grid 2>/dev/null)
  [[ $need_d -eq 1 ]] && SUM_DB_FOUND=$(pick_media db 2>/dev/null)
  [[ "$SUM_GRID_FOUND" == MISSING:* ]] && SUM_GRID_FOUND=""
  [[ "$SUM_DB_FOUND" == MISSING:* ]] && SUM_DB_FOUND=""
  return 0
}
chan_default_apply() {
  # RMAN channels not chosen yet (no value in the settings file): the suggestion (half the CPUs of each server, 2
  # to 8) is the default, so step 8.2 and the summary agree. Not for a standby that is built already.
  [[ ${CHAN_DEFAULT:-0} -eq 1 ]] || return 0
  sum_built && return 0
  local sp sa; read -r sp sa <<< "$(chan_suggest)"
  num "$sp" && num "$sa" || return 0
  AUX_CHANNELS=$sa; if [[ $sp -lt $sa ]]; then PRIMARY_CHANNELS=$sp; else PRIMARY_CHANNELS=""; fi
  CHAN_DEFAULT=0; CHAN_SUGGESTED=1
  _log SETTINGS "RMAN channels: the suggestion is used ($sp on the primary, $sa here; CPUs ${CPU_PRIMARY:-?} / ${CPU_HERE:-?})"
}
yn_word() { case "${1^^}" in YES|ARCHIVELOG|TRUE) printf 'yes' ;; NO|NOARCHIVELOG|FALSE) printf 'no' ;; "") printf 'not read' ;; *) printf '%s' "${1,,}" ;; esac; }
sum_built() { [[ -f "$(dup_marker)" ]]; }
summary_places() {
  # where each kind of file is on the primary, and where it will be here
  local dd fd; dd=$(data_dest); fd=$(fra_dest)
  printf '  %-26s %-34s %s\n' "" "On the primary" "Here"
  printf '  %-26s %-34s %s\n' "Datafiles, tempfiles" "$(primary_where | cut -c1-34)" "$(place_text "$dd")"
  printf '  %-26s %-34s %s\n' "Control files, redo logs" "$( [[ "$CFD" == +* || "$CFD" == /* ]] && printf '%s' "$CFD" || printf 'as the datafiles')" "$(place_text "$dd")"
  printf '  %-26s %-34s %s\n' "Recovery area" "${FRA_LOC:-none}${FRA_MB:+ ($(human_mb "$FRA_MB"))}" "$(place_text "$fd")${fd:+, $(human_mb "$(fra_size_mb)")}"
  printf '  %-26s %-34s %s\n' "Archived logs" "${ARCH_LOC:-recovery area}" "$(arch_dest_sb | sed 's/USE_DB_RECOVERY_FILE_DEST/recovery area/')"
  sum_built || printf '  %-26s %-34s %s\n' "Copies (multiplexing)" "as the primary has them" "control files: 2; redo log members: as on the primary"
}
summary_problems() {
  # one problem per line: "what  ->  what happens / what you do" (the numbers of the values, for the hints)
  summary_values
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && printf 'Host name here: %s  ->  step 2.6 adds it to /etc/hosts (a backup is kept)\n' "$p"; done < <(standby_name_problems 2>/dev/null)
  local pp prc=0; primary_name_problems > /dev/null 2>&1 || prc=$?; pp=$PNP_OUT
  [[ $prc -eq 0 ]] && while IFS= read -r p; do [[ -n "$p" ]] && printf 'Host name on the primary: %s  ->  step 2.7 shows the line for its /etc/hosts\n' "$p"; done <<< "$pp"
  [[ "${SUM_LOGMODE^^}" == NOARCHIVELOG ]] && printf 'The primary is in NOARCHIVELOG mode  ->  phase 4 shows the commands (it needs a restart of the primary)\n'
  [[ "${SUM_FORCELOG^^}" == NO ]] && printf 'Force logging is off on the primary  ->  phase 4 shows the command (no restart)\n'
  [[ "${STEP_RESULT[1.6]:-OK}" != OK ]] && printf 'Version or OS: %s  ->  see step 1.6\n' "${STEP_NOW[1.6]:-check step 1.6}"
  # (the zips are searched as step 3.1 does, in ${ZIP_DIRS[*]})
  if ! grid_sw_ok 2>/dev/null && use_grid && [[ -z "$GRID_MEDIA$SUM_GRID_FOUND" ]]; then printf 'No Grid installer zip found  ->  copy it next to this script (%s) or to /stage (step 3.1 shows how)\n' "$SCRIPT_DIR"; fi
  if ! db_sw_ok 2>/dev/null && [[ -z "$DB_MEDIA$SUM_DB_FOUND" ]]; then printf 'No database installer zip found  ->  copy it next to this script (%s) or to /stage (step 3.1 shows how)\n' "$SCRIPT_DIR"; fi
  # a zip of the settings (an earlier run) that is gone or no longer usable: said now, not only at step 3.1
  if ! grid_sw_ok 2>/dev/null && use_grid && [[ -n "$GRID_MEDIA" ]] && ! media_ok "$GRID_MEDIA"; then printf 'The Grid installer zip of the settings is missing or not usable: %s  ->  copy it back, or change the value "Installer zips"\n' "${GRID_MEDIA//,/ }"; fi
  if ! db_sw_ok 2>/dev/null && [[ -n "$DB_MEDIA" ]] && ! media_ok "$DB_MEDIA"; then printf 'The database installer zip of the settings is missing or not usable: %s  ->  copy it back, or change the value "Installer zips"\n' "${DB_MEDIA//,/ }"; fi
  # base media and a patched primary: said now, not after the installs (step 3.11 would ask for opatchauto by hand)
  if ! db_sw_ok 2>/dev/null && [[ -n "$SUM_PATCHES" && -z "$RU_DIR" ]]; then
    local mf=${DB_MEDIA:-$SUM_DB_FOUND}; mf=${mf%%,*}
    if [[ -z "$mf" ]] || ! media_is_gold "$mf" 2>/dev/null; then
      printf 'The primary has patches (%s) that the base installer does not have  ->  set value %s (Release Update), or step 3.11 asks you to patch by hand\n' "$SUM_PATCHES" "$(sv_num ru)"
    fi
  fi
  primary_mixed && [[ "$(place_mode)" == asm ]] && ! sum_built && printf 'The primary keeps files in folders and in ASM  ->  here all of them go to %s (value 4 changes it)\n' "$(data_dest)"
  [[ "$(place_mode)" != asm ]] && use_grid && grid_sw_ok 2>/dev/null && [[ -n "$(fs_dirs)" ]] && ! sum_built && printf 'This server has ASM, but files go to the file system (%s)  ->  values 4 and 5 change it\n' "$(fs_dirs | paste -sd' ' -)"
  # a recovery area smaller than the primary's: allowed, but it holds fewer days of archived logs
  if ! sum_built && [[ -n "$(fra_dest)" ]] && num "${FRA_MB:-}" && [[ ${FRA_MB:-0} -gt 0 ]]; then
    local fm; fm=$(fra_size_mb 2>/dev/null)
    num "$fm" && [[ $fm -lt $FRA_MB ]] && printf 'Recovery area here %s, smaller than on the primary (%s)  ->  it holds fewer days of archived logs; value %s changes it\n' "$(human_mb "$fm")" "$(human_mb "$FRA_MB")" "$(sv_num fra)"
  fi
  [[ $LSNR_ASSUMED -eq 1 ]] && printf 'No listener on the primary offers the service %s  ->  check PORT, LISTENER_NAME and PRIMARY_SERVICE with [e] (they were assumed)\n' "$PRIMARY_SERVICE"
  # the space for the copy: only where it can be measured now (a disk group needs Grid running here)
  if ! sum_built && { [[ -z "$(asm_dgs)" ]] || grid_sw_ok 2>/dev/null; }; then
    PRE_INFO=""; PRE_FIX=""
    if ! space_check >/dev/null 2>&1; then
      while IFS= read -r p; do [[ "$p" == *Missing:* ]] && printf 'Space: %s  ->  make room or change values 4 and 5\n' "${p#  }"; done <<< "$PRE_FIX"
    fi
  fi
  return 0
}
sum_done() {
  # step $1 is done (in this run or an earlier one)
  local r=${LAST_RESULT[$1]:-}; [[ -n "${STEP_RESULT[$1]:-}" ]] && r=${STEP_RESULT[$1]}
  case "$r" in OK|DONE|DONE_BY_YOU|NOT_ON_RELEASE) return 0 ;; esac
  return 1
}
sum_prim_step() { [[ "$1" == 2.7 || "$1" == 4.* || "$1" == 6.2 || "$1" == 9.5 ]]; }    # the commands are run on the primary
summary_plan() {
  local done_n=0 here=0 i
  for i in "${HELP_IDS[@]}"; do
    on_demand "$i" && continue
    if sum_done "$i"; then done_n=$((done_n + 1)); continue; fi
    sum_prim_step "$i" || here=$((here + 1))
  done
  printf '  Done %s steps. To do: %s steps on this server.\n' "$done_n" "$here"
  summary_primary_visits
  printf '  Restarts: the listener here when its port changes (3.10), the standby instance after the copy (9.2).\n'
  [[ "${SUM_LOGMODE^^}" == NOARCHIVELOG ]] && printf '  The primary needs a restart for ARCHIVELOG mode (phase 4, done by you).\n'
  return 0
}
summary_primary_visits() {
  # what you run on the primary, with the OS user of each part: known before the start, so the sessions (and a
  # change ticket for root) can be prepared. Only the parts that are not done yet.
  local -a L=(); local p4="" lo l i
  if ! sum_done 2.7 && [[ -n "$SUM_P27" ]]; then L+=("2.7|root|one line in /etc/hosts ($SUM_P27)"); fi
  for i in 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8; do
    sum_done "$i" && continue
    [[ "$i" == 4.1 && "${SUM_LOGMODE^^}" == ARCHIVELOG && "${SUM_FORCELOG^^}" == YES ]] && continue
    p4+="${p4:+ }$i"
  done
  if [[ -n "$p4" ]]; then
    l="SQL*Plus as sysdba, only what its check finds missing"
    [[ "${SUM_LOGMODE^^}" == NOARCHIVELOG ]] && l+="; 4.1 restarts the database (ARCHIVELOG mode)"
    L+=("$(sum_range $p4)|$ORACLE_USER|$l")
  fi
  p4=""; sum_done 4.9 || p4="4.9"; sum_done 4.11 || p4+="${p4:+, }4.11"
  [[ -n "$p4" ]] && L+=("$p4|$ORACLE_USER|the standby alias in tnsnames.ora, ~/.bash_profile (shell)")
  lo=$([[ "$PRIMARY_LISTENER_HOME" == "$DB_HOME" ]] && printf '%s' "$ORACLE_USER" || printf '%s' "$GRID_USER")
  sum_done 4.10 || L+=("4.10|$lo|a static entry in listener.ora, lsnrctl reload")
  local asm_pw=0; [[ "$SUM_PWFILE" == +* ]] && ! sum_done 6.1 && asm_pw=1
  [[ $asm_pw -eq 1 ]] && L+=("6.1|$GRID_USER|asmcmd pwcopy of the password file to /tmp (a readable copy for this server)")
  local -a L2=()
  [[ $asm_pw -eq 1 ]] && L2+=("6.2|$GRID_USER|rm of that copy")
  sum_done 9.5 || L2+=("9.5|$ORACLE_USER|enable redo transport (log_archive_dest_state_${SUM_DEST_N:-N})")
  if [[ ${#L[@]} -eq 0 && ${#L2[@]} -eq 0 ]]; then printf '  Nothing is left to do on the primary.\n'; return 0; fi
  printf '  On the primary you run (the script shows the commands and checks them; %s):\n' "$([[ "$PRIMARY_RUN" == yes ]] && printf 'it may run them over ssh after you agree' || printf 'it never changes the primary itself')"
  [[ ${#L[@]} -gt 0 ]] && printf '    %s\n' "First visit, all shown together in phase 4:"
  for l in ${L[@]+"${L[@]}"}; do IFS='|' read -r i lo p4 <<< "$l"; printf '      %-10s as %-8s %s\n' "$i" "$lo" "$p4"; done
  [[ ${#L2[@]} -gt 0 ]] && printf '    %s\n' "After the copy (phases 6 and 9):"
  for l in ${L2[@]+"${L2[@]}"}; do IFS='|' read -r i lo p4 <<< "$l"; printf '      %-10s as %-8s %s\n' "$i" "$lo" "$p4"; done
  return 0
}
sum_range() {
  # "4.1 4.2 4.3 4.5" -> "4.1-4.3, 4.5" (steps of one phase)
  local out="" a="" b="" x n pn=""
  for x in "$@"; do
    n=${x#*.}
    if [[ -n "$a" && $n -eq $((pn + 1)) ]]; then b=$x
    else [[ -n "$a" ]] && out+="${out:+, }$a${b:+-$b}"; a=$x; b=""; fi
    pn=$n
  done
  [[ -n "$a" ]] && out+="${out:+, }$a${b:+-$b}"
  printf '%s' "$out"
}
# ---- the numbered values (only the ones that apply to this run) ----
declare -a SV_ID=() SV_LABEL=() SV_VAL=()
sv_add() { SV_ID+=("$1"); SV_LABEL+=("$2"); SV_VAL+=("$3"); }
sv_num() {
  # the number of value $1 on the screen now (for a hint), or "?" when it is not shown
  local i; for ((i = 0; i < ${#SV_ID[@]}; i++)); do [[ "${SV_ID[$i]}" == "$1" ]] && { printf '%s' "$((i + 1))"; return 0; }; done
  printf '?'
}
fra_why_short() {
  # the reason of the recovery area size, short enough for the values (the whole reason is in d)
  local m; m=$(fra_size_mb 2>/dev/null)
  if [[ -n "${FRA_SIZE:-}" ]]; then printf 'set by you%s' "$( num "${FRA_MB:-}" && [[ ${FRA_MB:-0} -gt 0 ]] && printf '; %s on the primary' "$(human_mb "$FRA_MB")")"
  elif [[ "$(fra_src)" == primary ]]; then printf 'as on the primary'   # (rounded up to whole GB)
  elif num "${REDO_DAY_MB:-}" && [[ ${REDO_DAY_MB:-0} -gt 0 ]]; then printf 'copy time + 1 day of redo at %s/day, + 30 %%' "$(human_mb "$REDO_DAY_MB")"
  else printf 'a tenth of the database, at least 10 GB'; fi
}
sum_media_text() {
  local g=${GRID_MEDIA:-$SUM_GRID_FOUND} d=${DB_MEDIA:-$SUM_DB_FOUND} t=""
  if use_grid && ! grid_sw_ok 2>/dev/null; then t="Grid $( [[ -n "$g" ]] && { printf %s "$(basename "${g%%,*}")"; [[ -n "$GRID_MEDIA" ]] && ! media_ok "$GRID_MEDIA" && printf ' (missing)'; true; } || printf 'not found'); "; fi
  if ! db_sw_ok 2>/dev/null; then t+="database $( [[ -n "$d" ]] && { printf %s "$(basename "${d%%,*}")"; [[ -n "$DB_MEDIA" ]] && ! media_ok "$DB_MEDIA" && printf ' (missing)'; true; } || printf 'not found')"; else t=${t%; }; fi
  [[ -z "$GRID_MEDIA$DB_MEDIA" && -n "$SUM_GRID_FOUND$SUM_DB_FOUND" ]] && t+="   (found; step 3.1 uses them)"
  printf '%s' "$t"
}
sum_ru_text() {
  if [[ -n "$RU_DIR" ]]; then printf '%s%s' "$RU_DIR" "${OPATCH_ZIP:+, OPatch $(basename "$OPATCH_ZIP")}"
  elif [[ -n "$SUM_PATCHES" ]]; then printf 'none (the primary has %s; without it step 3.11 asks you to patch by hand)' "$SUM_PATCHES"
  else printf 'none'; fi
}
summary_values() {
  SV_ID=(); SV_LABEL=(); SV_VAL=()
  local st="all steps"
  if [[ -n "$TO_STEP" ]]; then st=$(range_text); elif [[ -n "$ONLY_PHASE" ]]; then st="phase $ONLY_PHASE"; elif [[ -n "$FROM_STEP" ]]; then st="from $(range_word "${FROM_STEP%.0}")"; else st="continue ($(menu_next))"; fi
  sv_add mode "Mode" "$([[ "$MODE" == check ]] && printf 'check only (changes nothing)' || printf 'setup')"
  sv_add yes "Yes to all" "$([[ $YES_MODE -eq 1 ]] && printf 'yes (risky actions are still asked)' || printf 'no')"
  sv_add range "Steps of this run" "$st"
  if ! sum_built; then
    sv_add data "Database files go to" "$(place_text "$(data_dest)")$([[ -z "${DATA_DEST:-}" ]] && printf '   (automatic)')"
    local fd; fd=$(fra_dest)
    sv_add fra "Recovery area" "$(place_text "$fd")${fd:+, $(human_mb "$(fra_size_mb)") ($(fra_why_short))}"
    local sp sa; read -r sp sa <<< "$(chan_suggest)"
    sv_add chan "RMAN channels" "$(prim_channels) on the primary, $AUX_CHANNELS here   (CPUs: ${CPU_PRIMARY:-?} / ${CPU_HERE:-?}$([[ "$(prim_channels)/$AUX_CHANNELS" == "$sp/$sa" ]] && printf ', as suggested' || printf ', suggested %s and %s' "$sp" "$sa"))"
    sv_add sect "Section size of the copy" "${DUP_SECTION_SIZE:-automatic}"
  fi
  sv_add prun "Run primary commands over ssh" "$([[ "$PRIMARY_RUN" == yes ]] && printf 'yes, asked at each step (as %s)' "$PRIMARY_SSH_USER" || printf 'no (you run them on the primary)')"
  sv_add names "Standby names" "$STANDBY_UNIQUE, SID $STANDBY_SID, alias $STANDBY_TNS"
  if ! db_sw_ok 2>/dev/null || { use_grid && ! grid_sw_ok 2>/dev/null; }; then
    sv_add media "Installer zips" "$(sum_media_text)"
  fi
  use_grid && ! grid_sw_ok 2>/dev/null && sv_add asm "ASM disk method" "${ASM_METHOD:-automatic (ASMLib if it works on this kernel, else udev)}"
  sv_add arch "Archived-log clean-up" "${ARCH_CLEANUP:-not chosen (asked in 9.8)}$([[ "${ARCH_CLEANUP:-}" == timer || "${ARCH_CLEANUP:-}" == crontab ]] && printf ' at %s, keep %s day(s)' "$(arch_time)" "$(arch_days)")"
  sv_add lag "Health check lag limit" "${HEALTH_LAG_MAX:-300} seconds"
  # (last, so the numbers above stay the same): the Release Update the installer applies, only before the installs
  if ! db_sw_ok 2>/dev/null || { use_grid && ! grid_sw_ok 2>/dev/null; }; then sv_add ru "Release Update" "$(sum_ru_text)"; fi
}
summary_text() {
  # the main screen (also the report of --check and the file summary_<run>.txt). The problems come first (they are
  # what you act on, and they must be seen on a small screen too). SUMMARY_COMPACT=1 (the page of the screen layout
  # when the whole text does not fit): then the values, the names and the rest after them
  summary_facts
  local pr; pr=$(summary_problems)
  summary_problems_text "$pr"
  if [[ ${SUMMARY_COMPACT:-0} -eq 1 ]]; then summary_values_text; summary_names_text; summary_main_text 1; return 0; fi
  summary_main_text 0
  [[ -n "${SETTINGS_DIFF:-}" ]] && { printf '%sChanged since the last run%s\n' "$C_B" "$C_N"; sed 's/^/  /' <<< "$SETTINGS_DIFF"; }
  summary_values_text
}
sum_fact() { case "$1" in "") printf 'not read' ;; -) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
summary_names_text() {
  # the names a DBA checks before the start: both sides in two columns (long paths: one line per side)
  local f='  %-17s %-30s %s\n' sp
  printf '%sNames%s%-15s%-30s %s\n' "$C_B" "$C_N" "" "Primary" "Standby (this server)"
  printf "$f" "db_unique_name" "$PRIMARY_UNIQUE" "$STANDBY_UNIQUE"
  printf "$f" "ORACLE_SID" "$PRIMARY_SID" "$STANDBY_SID"
  printf "$f" "Host" "${PRIMARY_HOST:-?}, $PRIMARY_IP" "$STANDBY_HOST, $STANDBY_IP"
  printf "$f" "Service" "$PRIMARY_SERVICE$([[ $LSNR_ASSUMED -eq 1 ]] && printf ' (assumed)')" "$STANDBY_SERVICE"
  printf "$f" "TNS alias" "$PRIMARY_TNS" "$STANDBY_TNS"
  printf "$f" "Listener" "$LISTENER_NAME, port $PORT$([[ $LSNR_ASSUMED -eq 1 ]] && printf ' (assumed)')" "$SB_LSNR, port $PORT"
  printf '  %-17s %s  (the same path on both)\n' "Oracle home" "$DB_HOME"
  use_grid && printf '  %-17s %s  (the same path on both; Oracle Restart here)\n' "Grid home" "$GRID_HOME"
  sp=$(declare -F spfile_path >/dev/null && spfile_path)
  printf '  %-17s primary  %s\n  %-17s standby  %s\n' "spfile" "$(sum_fact "$SUM_SPFILE" 'none (started from a pfile)')" "" "${sp:-$DB_HOME/dbs/spfile$STANDBY_SID.ora} (written by the copy, step 8.2)"
  printf '  %-17s primary  %s\n  %-17s standby  %s\n' "Password file" "$(sum_fact "$SUM_PWFILE" 'none found')" "" "$(declare -F pw_dest >/dev/null && pw_dest) (a copy of the primary's, step 6.1)"
  printf '  %-17s log_archive_dest_%s on the primary: ASYNC to %s (set in 4.4, enabled in 9.5)\n' "Redo transport" "${SUM_DEST_N:-N}" "$STANDBY_TNS"
  printf '  %-17s %s\n' "Protection mode" "$( [[ -n "$SUM_PROT" ]] && printf '%s (this script does not change it)' "$SUM_PROT" || printf 'not read')"
}
summary_values_text() {
  summary_values
  printf '%sValues of this run%s\n' "$C_B" "$C_N"
  local i; for ((i = 0; i < ${#SV_ID[@]}; i++)); do printf '  %2d  %-30s %s\n' "$((i + 1))" "${SV_LABEL[$i]}" "${SV_VAL[$i]}"; done
}
summary_problems_text() {
  local p
  if [[ -n "$1" ]]; then
    printf '%sProblems found now%s\n' "$C_Y" "$C_N"
    while IFS= read -r p; do printf '  %s %s\n' "$S_WARN" "$p"; done <<< "$1"
  else printf '%sProblems found now%s  none\n' "$C_G" "$C_N"; fi
}
summary_main_text() {
  # $1 = 1: without the facts of the primary and of this server (they are in d)
  if [[ "${1:-0}" -eq 0 ]]; then
  printf '%sFound on the primary%s  %s (%s)\n' "$C_B" "$C_N" "${PRIMARY_HOST:-$PRIMARY_IP}" "$PRIMARY_IP"
  printf '  %s, unique name %s, %s%s, %s Edition\n' "$DB_NAME" "$PRIMARY_UNIQUE" "$PRIMARY_VERSION" "$([[ "$PRIMARY_CDB" == YES ]] && printf ', CDB%s' "${SUM_PDBS:+ with $SUM_PDBS PDB(s)}")" "$([[ "$DB_EDITION" == EE ]] && printf 'Enterprise' || printf '%s' "$DB_EDITION")"
  printf '  %s of datafiles; ARCHIVELOG %s, force logging %s, standby logs %s; redo up to %s a day\n' "$(human_mb "$PRIMARY_DB_MB")" "$(yn_word "$SUM_LOGMODE")" "$(yn_word "$SUM_FORCELOG")" "${SUM_SRL:-?}" "$( num "${REDO_DAY_MB:-}" && human_mb "$REDO_DAY_MB" || printf '?')"
  [[ -n "${SVC_FOUND_HOW:-}" ]] && printf '  Service %s found as %s\n' "$PRIMARY_SERVICE" "$SVC_FOUND_HOW"
  printf '%sThis server%s  %s, Oracle Linux %s, %s RAM, %s CPUs\n' "$C_B" "$C_N" "$(hostname -s)" "$OS_MAJOR" "$(human_mb "$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)")" "${CPU_HERE:-?}"
  printf '  Software: Grid %s, database %s\n' "$(use_grid && { grid_sw_ok 2>/dev/null && printf 'installed' || printf 'not yet'; } || printf 'not needed')" "$(db_sw_ok 2>/dev/null && printf 'installed' || printf 'not yet')"
  summary_names_text
  fi
  printf '%sStandby to build%s  %s%s\n' "$C_B" "$C_N" "$STANDBY_UNIQUE" "$(sum_built && printf ' (built already)')"
  summary_places
  if ! sum_built; then
    printf '  Copy: RMAN active duplicate, %s + %s channels, about %s to %s (%s)\n' "$(prim_channels)" "$AUX_CHANNELS" "$(human_min "$(copy_minutes lo)")" "$(human_min "$(copy_minutes hi)")" "$(copy_speed_text)"
  fi
  printf '%sPlan%s\n' "$C_B" "$C_N"; summary_plan
}
summary_details_text() {
  # [d]: the whole summary, everything that was read, and the settings file
  summary_facts
  SUMMARY_COMPACT=0 summary_text; printf '\n'
  printf 'Primary\n'
  printf '  Host %s (%s), ssh user %s, SID %s\n' "${PRIMARY_HOST:-?}" "$PRIMARY_IP" "$PRIMARY_SSH_USER" "$PRIMARY_SID"
  printf '  Oracle home %s%s\n' "$DB_HOME" "$(use_grid && printf ', Grid home %s' "$GRID_HOME")"
  printf '  Storage: %s\n' "$(loc_list | tr '\n' ' ')"
  printf '  Recovery area %s, archive destination %s, db_create_file_dest %s\n' "${FRA_LOC:-none}" "${ARCH_LOC:-?}" "${CFD:--}"
  printf '  Flashback %s, broker %s, standby destinations in use %s, TDE %s\n' "$(yn_word "$SUM_FLASHBACK")" "$(yn_word "$SUM_BROKER")" "${SUM_DESTS:-?}" "${TDE_INFO:-none}"
  printf 'This server\n'
  df -hP 2>/dev/null | awk 'NR==1 || $6 ~ /^\/(u0[0-9]|tmp|var|opt|$)/' | sed 's/^/  /'
  printf '\nSettings file %s\n' "$SETTINGS_FILE"
  grep -vE '^\s*(#|$)' "$SETTINGS_FILE" 2>/dev/null | sed 's/^/  /'
}
summary_save() {
  [[ "$MODE" == run || "$MODE" == check ]] || return 0
  local f="$LOG_DIR/summary_$RUN_ID.txt"
  ( umask 077; summary_text | sed 's/\x1b\[[0-9;]*m//g' > "$f" ) 2>/dev/null && _log INFO "summary saved: $f"
  return 0
}
summary_show() {
  # the screen: on the screen layout on its own page (separate screen), else printed
  local f; f=$(mktemp) || return 0; CLEANUP_FILES+=("$f")
  summary_text > "$f"
  # (--check: a report in the output, never a page that waits for a key)
  if [[ $UI -eq 1 && "$MODE" != check ]]; then ui_page "$f" "Summary of this run"
  elif [[ $UI -eq 1 ]]; then ui_flush; ui_live_clear; UI_TITLE_TXT=""; sed 's/^/    /' -- "$f" | ui_fold "      "; say "${C_D}Also saved in $LOG_DIR/summary_$RUN_ID.txt${C_N}"; UI_USED=$UI_ROWS
  else sed "s/^/    /" -- "$f"; printf "\n"; fi
  rm -f -- "$f"
}
SUM_NOTE=""
sum_note() { say "$1"; SUM_NOTE=$1; }     # a message for the summary page (shown above its question there)
sv_change() {
  # value number $1: asked, checked, saved as the new default. 1 = not accepted (nothing changed)
  local id=${SV_ID[$(( $1 - 1 ))]} v a b k snap=""
  for k in $STANDBY_KEYS; do snap+="$k=${!k}"$'\n'; done
  case "$id" in
    mode)  if [[ "$MODE" == check ]]; then MODE=run; else MODE=check; fi ;;
    yes)   if [[ $YES_MODE -eq 1 ]]; then YES_MODE=0; else YES_MODE=1; fi ;;
    range) ask "Steps of this run: Enter = all, a step to start from (7.2), a range (2.1-2.4), or os, grid, db, primary"
           v=${ANSWER//[[:space:]]/}
           FROM_STEP=""; TO_STEP=""; ONLY_PHASE=""; ONLY_TEXT=""
           if [[ -z "$v" ]]; then :
           elif [[ "$v" =~ ^([1-9]|10)$ ]]; then FROM_STEP="$v.0"; FROM_SEEN=1        # a phase: from there, as menu item 8
           elif valid_step "$v" && ! on_demand "$v"; then FROM_STEP=$v; FROM_SEEN=1
           elif names_on_demand "$v"; then sum_note "Step 10.7 runs only with --roll-forward. All steps are kept."
           elif ! parse_only "$v"; then sum_note "Not a step, range or part: $v. All steps are kept."; fi ;;
    data)  local dgl=""; use_grid && dgl=$(asm_dgs | sed 's/^/+/' | paste -sd' ' -)
           if [[ $UI -eq 1 ]]; then
             local -a po=("|the data disk group when this server has ASM, else the paths of the primary")
             for a in $dgl; do po+=("$a|disk group (Oracle-managed file names)"); done
             po+=("same|the same paths as on the primary" "*|a folder: type its full path")
             ui_pick "Database files go to" "${DATA_DEST:-}" "Where the files of the standby database are put on this server." "${po[@]}"
           else
           ask_default "Database files go to: a disk group (${dgl:-none here}), same (the paths of the primary), a folder, or Enter for automatic" "${DATA_DEST:-}"
           fi
           v=${ANSWER//[[:space:]]/}
           valid_value dest "$v" || { sum_note "Not a disk group (+NAME), same, or a folder (/path): $v"; return 1; }
           [[ "$v" == +* ]] && ! use_grid && { sum_note "This standby has no ASM."; return 1; }
           DATA_DEST=$v ;;
    fra)   if [[ $UI -eq 1 ]]; then
             local -a po=("|as the database files (with ASM: the recovery area disk group of the primary)")
             use_grid && for a in $(asm_dgs | sed 's/^/+/'); do po+=("$a|disk group"); done
             po+=("same|the same place as on the primary" "*|a folder: type its full path")
             ui_pick "Recovery area" "${FRA_DEST:-}" "Where archived logs and the second log members go. Its size is asked next." "${po[@]}"
           else
           ask_default "Recovery area: a disk group, same, a folder, or Enter for automatic" "${FRA_DEST:-}"
           fi
           v=${ANSWER//[[:space:]]/}; valid_value dest "$v" || { sum_note "Not a disk group (+NAME), same, or a folder: $v"; return 1; }
           ask_default "Its size, for example 60G (Enter = $( num "${FRA_MB:-}" && [[ ${FRA_MB:-0} -gt 0 ]] && printf 'as on the primary: %s' "$(human_mb "$FRA_MB")" || printf 'estimate: %s' "$(human_mb "$(fra_estimate_mb)")"))" "${FRA_SIZE:-}"
           a=${ANSWER//[[:space:]]/}; [[ "$a" =~ ^[0-9]+$ ]] && a="${a}G"; valid_value gsize "${a^^}" || { sum_note "Use a size in GB, for example 60G."; return 1; }
           FRA_DEST=$v; FRA_SIZE=${a^^} ;;
    chan)  local sp sa; read -r sp sa <<< "$(chan_suggest)"
           ask_default "Channels on the primary (1-64)" "$(prim_channels)"; a=$ANSWER
           ask_default "Channels on this server ($a-64, not fewer than on the primary)" "$AUX_CHANNELS"; b=$ANSWER
           if [[ "$a" =~ ^[0-9]{1,2}$ && "$b" =~ ^[0-9]{1,2}$ ]] && (( 10#$a >= 1 && 10#$a <= 64 && 10#$b >= 10#$a && 10#$b <= 64 )); then
             PRIMARY_CHANNELS=$((10#$a)); AUX_CHANNELS=$((10#$b))
           else sum_note "Use numbers from 1 to 64, and not fewer on this server than on the primary (suggested: $sp and $sa)."; return 0; fi ;;
    sect)  ask_default "Section size, for example 32G (0 = none, Enter = automatic)" "${DUP_SECTION_SIZE:-}"
           v=${ANSWER//[[:space:]]/}; valid_value secsize "${v^^}" || { sum_note "Use for example 32G, 0, or nothing."; return 1; }; DUP_SECTION_SIZE=${v^^} ;;
    prun)  if [[ "$PRIMARY_RUN" == yes ]]; then PRIMARY_RUN=no; else PRIMARY_RUN=yes; say "The script then offers, step by step, to run the primary commands it shows over ssh (as $PRIMARY_SSH_USER). Never a restart, a stop or a deletion."; fi ;;
    names) ask_default "db_unique_name of the standby (letters, digits, _; at most 30)" "$STANDBY_UNIQUE"
           v=${ANSWER//[[:space:]]/}; valid_value dbname "$v" || { sum_note "Not a valid name: $v"; return 1; }
           if [[ "$v" != "$STANDBY_UNIQUE" ]]; then
             [[ "$STANDBY_SID" == "$STANDBY_UNIQUE" || "$STANDBY_SID" == "${STANDBY_UNIQUE:0:12}" ]] && STANDBY_SID=""
             [[ "$STANDBY_SERVICE" == "${STANDBY_UNIQUE}"* ]] && STANDBY_SERVICE=""
             [[ "$STANDBY_TNS" == "${STANDBY_UNIQUE,,}" ]] && STANDBY_TNS=""
             STANDBY_UNIQUE=$v; derive_standby_settings
           fi ;;
    media) ask_default "Grid installer zip(s), comma separated (Enter = keep)" "$GRID_MEDIA"; a=${ANSWER//[[:space:]]/}
           ask_default "Database installer zip(s), comma separated (Enter = keep)" "$DB_MEDIA"; b=${ANSWER//[[:space:]]/}
           valid_value opt_paths "$a" && valid_value opt_paths "$b" || { sum_note "Use full paths of zip files."; return 1; }
           GRID_MEDIA=$a; DB_MEDIA=$b ;;
    asm)   if [[ $UI -eq 1 ]]; then
             ui_pick "ASM disk method" "${ASM_METHOD:-}" "How the ASM disks get their names and their owner on this server." \
               "|ASMLib if it works on this kernel, else udev" "asmlib|Oracle ASMLib (oracleasm)" "udev|udev rules"
           else
           ask_default "ASM disk method: asmlib, udev, or Enter for automatic" "${ASM_METHOD:-}"
           fi
           v=${ANSWER//[[:space:]]/}; valid_value asmmethod "$v" || { sum_note "Use asmlib, udev or nothing."; return 1; }; ASM_METHOD=$v ;;
    arch)  if [[ $UI -eq 1 ]]; then
             local -a po=("timer|a systemd timer every night (it also runs after a missed time)" "crontab|a line in the crontab of $ORACLE_USER")
             arch_in_fra && po+=("oracle|only the recovery area itself deletes them, when it needs space")
             po+=("none|nothing: the disk fills up unless you delete them yourself")
             ui_pick "Archived-log clean-up" "${ARCH_CLEANUP:-timer}" "How applied archived logs are deleted on the standby. Time and days are asked next." "${po[@]}"
           else
           ask_default "Clean-up: timer, crontab$(arch_in_fra && printf ', oracle'), none" "${ARCH_CLEANUP:-timer}"
           fi
           v=${ANSWER//[[:space:]]/}; valid_value archmode "$v" && [[ -n "$v" ]] || { sum_note "Use timer, crontab, oracle or none."; return 1; }
           [[ "$v" == oracle ]] && ! arch_in_fra && { sum_note "oracle works only when the archived logs go to the recovery area."; return 1; }
           if [[ "$v" == timer || "$v" == crontab ]]; then
             ask_default "Time (HH:MM)" "$(arch_time)"; a=${ANSWER//[[:space:]]/}; valid_value hhmm "$a" && [[ -n "$a" ]] || { sum_note "Use HH:MM, for example 04:30."; return 1; }
             ask_default "Keep applied logs this many days (0-30)" "$(arch_days)"; b=${ANSWER//[[:space:]]/}; valid_value days "$b" && [[ -n "$b" ]] || { sum_note "Use a number from 0 to 30."; return 1; }
             ARCH_CLEANUP_TIME=$a; ARCH_CLEANUP_DAYS=$b
           fi
           ARCH_CLEANUP=$v ;;
    ru)    say "A Release Update unzipped on this server (the folder named by its patch number, or the folder above it)."
           say "The installer applies it (with Grid: the GI Release Update, it covers both homes). Type none for none."
           ask_default "Release Update folder (RU_DIR)" "${RU_DIR:-none}"; v=${ANSWER//[[:space:]]/}; [[ "${v,,}" == none ]] && v=""
           valid_value opt_path "$v" && { [[ -z "$v" ]] || [[ -d "$v" ]]; } || { sum_note "Not a folder: $v"; return 1; }
           a=""
           if [[ -n "$v" ]]; then
             ask_default "The newest OPatch zip (p6880880_*.zip, OPATCH_ZIP)" "${OPATCH_ZIP:-}"; a=${ANSWER//[[:space:]]/}
             valid_value opt_path "$a" && [[ -n "$a" && -f "$a" ]] || { sum_note "Not a file: ${a:-(empty)}. A Release Update needs the newest OPatch zip."; return 1; }
           fi
           RU_DIR=$v; OPATCH_ZIP=$a ;;
    lag)   ask_default "Seconds of lag that the health check accepts" "${HEALTH_LAG_MAX:-300}"
           v=${ANSWER//[[:space:]]/}; [[ "$v" =~ ^[0-9]{1,6}$ ]] || { sum_note "Use a number of seconds."; return 1; }; HEALTH_LAG_MAX=$v ;;
  esac
  if [[ "$id" != mode && "$id" != yes && "$id" != range ]]; then
    if ! validate_settings >/dev/null 2>&1; then
      sum_note "Not saved: $(validate_settings 2>&1 | sed 's/\x1b\[[0-9;]*m//g; s/^[^A-Za-z]*//' | grep -v '^$' | head -n 1)"
      while IFS= read -r k; do [[ -n "$k" ]] && printf -v "${k%%=*}" '%s' "${k#*=}"; done <<< "$snap"     # the values from before
      return 1
    fi
    save_settings; save_accepted
    _log SETTINGS "changed in the summary: ${SV_LABEL[$(( $1 - 1 ))]}"
    journal SETTING "${id}" "changed in the summary screen: ${SV_LABEL[$(( $1 - 1 ))]}"
  else
    _log INFO "this run: ${SV_LABEL[$(( $1 - 1 ))]} changed"
  fi
  return 0
}
