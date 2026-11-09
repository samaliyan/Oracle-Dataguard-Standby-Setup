#------------------------------------------------------------------------------
# The summary screen (step 1.4): what was found on the primary and on this server, where the standby goes, the plan,
# the problems found now, and the values of this run, numbered. Shown on every setup run after phase 1 read both
# servers:  [Enter] Start   [number] Change   [d] Details   [e] Edit the file   [h] Help   [q] Quit
# A number asks only that value (the same checks as --settings), saves it as the new default and draws the screen
# again. --check prints the same screen as a report (no question); --health never shows it.
# Kept as LOG_DIR/summary_<run>.txt.
#------------------------------------------------------------------------------
SUM_FACTS_READ=0; SUM_LOGMODE=""; SUM_FORCELOG=""; SUM_FLASHBACK=""; SUM_SRL=""; SUM_PDBS=""; SUM_BROKER=""; SUM_DESTS=""
summary_facts() {
  # read-only, once per run: what phase 4 will check on the primary, for the summary
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
  redo_day_read >/dev/null 2>&1 || true
  [[ -f "$(dup_marker)" ]] || net_speed_read || true
  cpus_read
  return 0
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
}
summary_problems() {
  # one problem per line: "what  ->  what happens / what you do"
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && printf 'Host name here: %s  ->  step 2.6 adds it to /etc/hosts (a backup is kept)\n' "$p"; done < <(standby_name_problems 2>/dev/null)
  local pp prc=0; primary_name_problems > /dev/null 2>&1 || prc=$?; pp=$PNP_OUT
  [[ $prc -eq 0 ]] && while IFS= read -r p; do [[ -n "$p" ]] && printf 'Host name on the primary: %s  ->  step 2.7 shows the line for its /etc/hosts\n' "$p"; done <<< "$pp"
  [[ "${SUM_LOGMODE^^}" == NOARCHIVELOG ]] && printf 'The primary is in NOARCHIVELOG mode  ->  phase 4 shows the commands (it needs a restart of the primary)\n'
  [[ "${SUM_FORCELOG^^}" == NO ]] && printf 'Force logging is off on the primary  ->  phase 4 shows the command (no restart)\n'
  [[ "${STEP_RESULT[1.6]:-OK}" != OK ]] && printf 'Version or OS: %s  ->  see step 1.6\n' "${STEP_NOW[1.6]:-check step 1.6}"
  if ! grid_sw_ok 2>/dev/null && use_grid && [[ -z "$GRID_MEDIA" ]]; then printf 'No Grid installer zip found  ->  copy it to /stage on this server (step 3.1 shows how)\n'; fi
  if ! db_sw_ok 2>/dev/null && [[ -z "$DB_MEDIA" ]]; then printf 'No database installer zip found  ->  copy it to /stage on this server (step 3.1 shows how)\n'; fi
  primary_mixed && [[ "$(place_mode)" == asm ]] && ! sum_built && printf 'The primary keeps files in folders and in ASM  ->  here all of them go to %s (value 4 changes it)\n' "$(data_dest)"
  [[ "$(place_mode)" != asm ]] && use_grid && grid_sw_ok 2>/dev/null && [[ -n "$(fs_dirs)" ]] && ! sum_built && printf 'This server has ASM, but files go to the file system (%s)  ->  values 4 and 5 change it\n' "$(fs_dirs | paste -sd' ' -)"
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
summary_plan() {
  local done_n=0 here=0 prim=0 i r plist=""
  for i in "${HELP_IDS[@]}"; do
    on_demand "$i" && continue
    r=${LAST_RESULT[$i]:-}; [[ -n "${STEP_RESULT[$i]:-}" ]] && r=${STEP_RESULT[$i]}
    case "$r" in OK|DONE|DONE_BY_YOU|NOT_ON_RELEASE) done_n=$((done_n + 1)); continue ;; esac
    if [[ "$i" == 4.* ]]; then prim=$((prim + 1)); plist+="${plist:+, }$i"; else here=$((here + 1)); fi
  done
  printf '  Done %s steps. To do: %s on this server, %s on the primary%s.\n' "$done_n" "$here" "$prim" "${plist:+ ($plist)}"
  printf '  Restarts: the listener here when its port changes (3.10), the standby instance after the copy (9.2).\n'
  [[ "${SUM_LOGMODE^^}" == NOARCHIVELOG ]] && printf '  The primary needs a restart for ARCHIVELOG mode (phase 4, done by you).\n'
  return 0
}
# ---- the numbered values (only the ones that apply to this run) ----
declare -a SV_ID=() SV_LABEL=() SV_VAL=()
sv_add() { SV_ID+=("$1"); SV_LABEL+=("$2"); SV_VAL+=("$3"); }
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
    sv_add fra "Recovery area" "$(place_text "$fd")${fd:+, $(human_mb "$(fra_size_mb)") ($(fra_size_why | cut -c1-60))}"
    sv_add chan "RMAN channels" "$(prim_channels) on the primary, $AUX_CHANNELS here   (CPUs: ${CPU_PRIMARY:-?} / ${CPU_HERE:-?})"
    sv_add sect "Section size of the copy" "${DUP_SECTION_SIZE:-automatic}"
  fi
  sv_add prun "Run primary commands over ssh" "$([[ "$PRIMARY_RUN" == yes ]] && printf 'yes, asked at each step (as %s)' "$PRIMARY_SSH_USER" || printf 'no (you run them on the primary)')"
  sv_add names "Standby names" "$STANDBY_UNIQUE, SID $STANDBY_SID, alias $STANDBY_TNS"
  if ! db_sw_ok 2>/dev/null || { use_grid && ! grid_sw_ok 2>/dev/null; }; then
    sv_add media "Installer zips" "$( [[ -n "$GRID_MEDIA" ]] && use_grid && printf 'Grid %s; ' "$(basename "${GRID_MEDIA%%,*}")")database ${DB_MEDIA:+$(basename "${DB_MEDIA%%,*}")}${DB_MEDIA:-not found}"
  fi
  use_grid && ! grid_sw_ok 2>/dev/null && sv_add asm "ASM disk method" "${ASM_METHOD:-automatic (ASMLib if it works on this kernel, else udev)}"
  sv_add arch "Archived-log clean-up" "${ARCH_CLEANUP:-not chosen (asked in 9.8)}$([[ "${ARCH_CLEANUP:-}" == timer || "${ARCH_CLEANUP:-}" == crontab ]] && printf ' at %s, keep %s day(s)' "$(arch_time)" "$(arch_days)")"
  sv_add lag "Health check lag limit" "${HEALTH_LAG_MAX:-300} seconds"
}
summary_text() {
  # the main screen (also the report of --check and the file summary_<run>.txt). SUMMARY_COMPACT=1 (the page of the
  # screen layout when the whole text does not fit): the values and the problems first, the rest after them
  summary_facts
  local pr; pr=$(summary_problems)
  if [[ ${SUMMARY_COMPACT:-0} -eq 1 ]]; then summary_values_text; summary_problems_text "$pr"; summary_main_text 1; return 0; fi
  summary_main_text 0
  summary_problems_text "$pr"
  [[ -n "${SETTINGS_DIFF:-}" ]] && { printf '%sChanged since the last run%s\n' "$C_B" "$C_N"; sed 's/^/  /' <<< "$SETTINGS_DIFF"; }
  summary_values_text
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
  printf '  Listener %s port %s, service %s%s\n' "$LISTENER_NAME" "$PORT" "$PRIMARY_SERVICE" "${SVC_FOUND_HOW:+ (found as $SVC_FOUND_HOW)}$([[ $LSNR_ASSUMED -eq 1 ]] && printf ' (assumed)')"
  printf '%sThis server%s  %s, Oracle Linux %s, %s RAM, %s CPUs\n' "$C_B" "$C_N" "$(hostname -s)" "$OS_MAJOR" "$(human_mb "$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)")" "${CPU_HERE:-?}"
  printf '  Software: Grid %s, database %s\n' "$(use_grid && { grid_sw_ok 2>/dev/null && printf 'installed' || printf 'not yet'; } || printf 'not needed')" "$(db_sw_ok 2>/dev/null && printf 'installed' || printf 'not yet')"
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
  elif [[ $UI -eq 1 ]]; then ui_flush; ui_live_clear; sed 's/^/    /' -- "$f" | ui_fold "      "; say "${C_D}Also saved in $LOG_DIR/summary_$RUN_ID.txt${C_N}"; UI_USED=$UI_ROWS
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
           ask_default "Database files go to: a disk group (${dgl:-none here}), same (the paths of the primary), a folder, or Enter for automatic" "${DATA_DEST:-}"
           v=${ANSWER//[[:space:]]/}
           valid_value dest "$v" || { sum_note "Not a disk group (+NAME), same, or a folder (/path): $v"; return 1; }
           [[ "$v" == +* ]] && ! use_grid && { sum_note "This standby has no ASM."; return 1; }
           DATA_DEST=$v ;;
    fra)   ask_default "Recovery area: a disk group, same, a folder, or Enter for automatic" "${FRA_DEST:-}"
           v=${ANSWER//[[:space:]]/}; valid_value dest "$v" || { sum_note "Not a disk group (+NAME), same, or a folder: $v"; return 1; }
           ask_default "Its size, for example 60G (Enter = estimate: $(human_mb "$(fra_estimate_mb)"))" "${FRA_SIZE:-}"
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
    asm)   ask_default "ASM disk method: asmlib, udev, or Enter for automatic" "${ASM_METHOD:-}"
           v=${ANSWER//[[:space:]]/}; valid_value asmmethod "$v" || { sum_note "Use asmlib, udev or nothing."; return 1; }; ASM_METHOD=$v ;;
    arch)  ask_default "Clean-up: timer, crontab$(arch_in_fra && printf ', oracle'), none" "${ARCH_CLEANUP:-timer}"
           v=${ANSWER//[[:space:]]/}; valid_value archmode "$v" && [[ -n "$v" ]] || { sum_note "Use timer, crontab, oracle or none."; return 1; }
           [[ "$v" == oracle ]] && ! arch_in_fra && { sum_note "oracle works only when the archived logs go to the recovery area."; return 1; }
           if [[ "$v" == timer || "$v" == crontab ]]; then
             ask_default "Time (HH:MM)" "$(arch_time)"; a=${ANSWER//[[:space:]]/}; valid_value hhmm "$a" && [[ -n "$a" ]] || { sum_note "Use HH:MM, for example 04:30."; return 1; }
             ask_default "Keep applied logs this many days (0-30)" "$(arch_days)"; b=${ANSWER//[[:space:]]/}; valid_value days "$b" && [[ -n "$b" ]] || { sum_note "Use a number from 0 to 30."; return 1; }
             ARCH_CLEANUP_TIME=$a; ARCH_CLEANUP_DAYS=$b
           fi
           ARCH_CLEANUP=$v ;;
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
