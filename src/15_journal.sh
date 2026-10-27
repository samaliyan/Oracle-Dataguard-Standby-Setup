#------------------------------------------------------------------------------
# Change journal and undo
#
#   Every change this script makes on THIS server is written to STATE_DIR/changes.log
#   (one line: seq|time|run|step|kind|object|detail). The journal is the base of:
#     --show-changes [STEP]   what was changed, by which step, and how each change is undone
#     --undo STEP             walks the changes of one step backwards and undoes them one by
#                             one, asking before each. Files are put back from their backups
#                             (or an appended block is cut off again), services and
#                             registrations are removed; things that a program must not undo
#                             by itself (disks, software, users, the copied database) are only
#                             printed with the exact commands.
#   Commands the admin ran on the primary are recorded too (kind PRIMARY) with their undo
#   command, so --show-changes also lists what was changed there and how to take it back.
#   Nothing here touches the primary server.
#------------------------------------------------------------------------------
JOURNAL_FILE=""
JOURNAL_STEP_ENTRIES=0
JOURNAL_WARNED=0
declare -A UNDONE_SEQ=()
PLAN_UNDO=""          # set by a check function next to PLAN: how the printed change is taken back

file_md5() { md5sum -- "$1" 2>/dev/null | cut -d' ' -f1; }
text_md5() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }

journal() {
  # $1 kind, $2 object, $3 detail (optional). Only in a normal run (never in check mode).
  [[ "$MODE" == "run" && -n "$JOURNAL_FILE" ]] || return 0
  local seq o=${2//|/_} d=${3:-}
  o=${o//$'\n'/ }; d=${d//$'\n'/ }
  seq=$(journal_next_seq)
  install -d -m 700 "$STATE_DIR"
  [[ -s "$JOURNAL_FILE" ]] || printf '#journal v1 (seq|time|run|step|kind|object|detail)\n' >> "$JOURNAL_FILE" 2>/dev/null
  if ! printf '%s|%s|%s|%s|%s|%s|%s\n' "$seq" "$(ts)" "$RUN_ID" "${CUR_STEP:-start}" "$1" "$o" "$d" >> "$JOURNAL_FILE" 2>/dev/null; then
    [[ $JOURNAL_WARNED -eq 1 ]] || { JOURNAL_WARNED=1; warn "Cannot write the change journal $JOURNAL_FILE (disk full?): changes of this run may be missing in --show-changes / --undo"; }
    return 0
  fi
  chmod 600 "$JOURNAL_FILE" 2>/dev/null
  JOURNAL_STEP_ENTRIES=$((JOURNAL_STEP_ENTRIES + 1))
  _log CHANGE "[$1] $2${3:+ ($3)}"
  return 0
}
journal_next_seq() {
  local m=0 s
  [[ -s "$JOURNAL_FILE" ]] && m=$(cut -d'|' -f1 "$JOURNAL_FILE" | grep -E '^[0-9]+$' | sort -n | tail -n 1)
  num "$m" || m=0
  printf '%s' $((m + 1))
}
journal_has_file_this_run() {
  # 0 when this run already recorded a change of file $1 (then an EDIT has no exact backup of its own)
  [[ -s "$JOURNAL_FILE" ]] || return 1
  awk -F'|' -v r="$RUN_ID" -v f="$1" '$3 == r && ($5 == "NEW" || $5 == "EDIT" || $5 == "APPEND") && $6 == f { found = 1 } END { exit !found }' "$JOURNAL_FILE"
}
journal_internal_file() {
  # files of the script itself are not changes of the server
  case "$1" in "$LOG_DIR"/*|"$STATE_DIR"/*|*/.dg_duplicate_done_*|/tmp/dg_rsp.*|/tmp/dg_sql.*|*.bak_[0-9]*) return 0 ;; esac
  return 1
}
journal_file_written() {
  # called by write_as after a successful whole-file write: $1 file, $2 existed before (0/1)
  local f=$1 existed=$2 b="$1.bak_$RUN_ID"
  journal_internal_file "$f" && return 0
  if [[ $existed -eq 0 ]]; then journal NEW "$f" "md5=$(file_md5 "$f")"
  elif [[ -f "$b" ]] && ! journal_has_file_this_run "$f"; then journal EDIT "$f" "bak=$b md5=$(file_md5 "$f")"
  else journal EDIT "$f" "bak=- md5=$(file_md5 "$f")"; fi
  return 0
}
journal_file_appended() {
  # called by append_as: $1 file, $2 size before, $3 the text that was added (with its final newline)
  journal_internal_file "$1" && return 0
  # len in bytes (the size difference), lead=1 when a missing final newline was added in front of the block
  local len=${4:-}; num "$len" || len=$(printf '%s' "$3" | wc -c)
  journal APPEND "$1" "off=$2 len=$len md5=$(text_md5 "$3") md5all=$(file_md5 "$1") lead=${5:-0}"
  return 0
}

#---- reading ---------------------------------------------------------------
journal_load_undone() {
  UNDONE_SEQ=()
  [[ -s "$JOURNAL_FILE" ]] || return 0
  local seq kind obj
  while IFS='|' read -r seq _ _ _ kind obj _; do
    [[ "$seq" =~ ^[0-9]+$ && "$kind" == "UNDONE" && "$obj" =~ ^[0-9]+$ ]] && UNDONE_SEQ[$obj]=1
  done < "$JOURNAL_FILE"
  return 0
}
journal_entries() {
  # prints the active (not undone) entries, optionally of one step ($1) or one run ($2), oldest first
  [[ -s "$JOURNAL_FILE" ]] || return 0
  local l seq run step kind
  while IFS= read -r l; do
    IFS='|' read -r seq _ run step kind _ <<< "$l"
    [[ "$seq" =~ ^[0-9]+$ ]] || continue          # the version line, or a damaged line
    [[ "$kind" == "UNDONE" ]] && continue
    [[ -n "${1:-}" && "$step" != "$1" ]] && continue
    [[ -n "${2:-}" && "$run" != "$2" ]] && continue
    [[ -n "${UNDONE_SEQ[$seq]:-}" ]] && continue
    printf '%s\n' "$l"
  done < "$JOURNAL_FILE"
  return 0
}
detail_field() {
  # $1 detail text "k=v k=v", $2 key -> value (empty when absent)
  local w
  for w in $1; do [[ "$w" == "$2="* ]] && { printf '%s' "${w#*=}"; return 0; }; done
  printf ''
}
later_steps_active() {
  # 0 when a step after $1 has active entries (the undo of $1 would pull the ground from under them)
  local l step
  while IFS= read -r l; do
    local kind; IFS='|' read -r _ _ _ step kind _ <<< "$l"
    [[ "$step" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    case "$kind" in SERVICE|ROOHCTL|SETTING|DUPLICATE_DONE) continue ;; esac     # nothing to undo there
    [[ $(step_num "$step") -gt $(step_num "$1") ]] && return 0
  done < <(journal_entries)
  return 1
}

undo_text() {
  # $1 kind, $2 object, $3 detail -> one line: how this change is undone ("auto:" = --undo does it)
  local kind=$1 obj=$2 det=$3 b
  case "$kind" in
    NEW)        printf 'auto: remove the file %s' "$obj" ;;
    APPEND)     printf 'auto: cut the added %s bytes off the end of %s again' "$(detail_field "$det" len)" "$obj" ;;
    EDIT)       b=$(detail_field "$det" bak)
                if [[ -n "$b" && "$b" != "-" ]]; then printf 'auto: put back the copy %s' "$b"; else printf 'rewritten without an exact backup copy of the state before: compare %s with its .bak_ copies (if any) and fix it by hand' "$obj"; fi ;;
    RENAME)     printf 'auto: rename %s back to %s' "$(detail_field "$det" to)" "$obj" ;;
    DIR)        printf 'auto: remove the folder %s (only when it is empty)' "$obj" ;;
    GROUP)      printf 'by hand: groupdel %s   (only when no file and no user uses it)' "$obj" ;;
    USER)       printf 'by hand: userdel -r %s   (removes the home folder of the user too)' "$obj" ;;
    USERMOD)    printf 'by hand: the groups of %s were changed (%s); set them back with usermod if needed' "$obj" "$det" ;;
    PKG)        printf 'by hand (usually not wanted): %s remove %s' "$PKG" "$obj" ;;
    FWPORT)     printf 'auto: firewall-cmd --permanent --zone=%s --remove-port=%s ; firewall-cmd --reload' "${obj%%:*}" "${obj#*:}" ;;
    SERVICE)    printf 'left as it is: %s was enabled and started (a time service is wanted on every server)' "$obj" ;;
    ASMCFG)     printf 'by hand: oracleasm configure -d ; systemctl disable oracleasm   (only when no ASM disk uses ASMLib)' ;;
    SETTING)    printf 'in the settings file: %s' "$det" ;;
    PART)       printf 'by hand, ONLY if the disk is in no ASM disk group: wipefs -a %s ; wipefs -a %s   (%s)' "$(part_name "$obj")" "$obj" "$det" ;;
    ASMLABEL)   if [[ "$(asm_method 2>/dev/null)" == "asmlib" ]]; then printf 'by hand, ONLY if +%s is dropped: oracleasm deletedisk %s' "${obj%_*}" "$obj"
                else printf 'by hand, ONLY if +%s is dropped: remove the line with SYMLINK+="oraasm/%s" from %s ; udevadm control --reload-rules ; udevadm trigger' "${obj%_*}" "$obj" "$UDEV_RULES"; fi
                printf '   and remove the line %s| from %s' "$obj" "$(asm_disks_file 2>/dev/null)" ;;
    UNZIP)      printf 'by hand, ONLY after the SOFTWARE undo of this home (or when it was never installed): rm -rf %s' "$obj" ;;
    SOFTWARE)   if [[ "$obj" == "${GRID_HOME:-/nonexistent}" ]]; then printf 'by hand, after the GRIDCONFIG undo (step 3.3): as %s  %s/deinstall/deinstall' "$GRID_USER" "$obj"
                else printf 'by hand: as the owner  %s/deinstall/deinstall   (removes the Oracle home %s from the inventory and the disk)' "$obj" "$obj"; fi ;;
    ROOTSH)     printf 'nothing separate: it belongs to the home %s and goes with its SOFTWARE undo (deinstall)' "$obj" ;;
    GRIDCONFIG) printf 'by hand: as root  %s/crs/install/roothas.sh -deconfig -force   then the SOFTWARE undo of the Grid home' "$obj" ;;
    ASMINST)    printf 'by hand: the ASM instance and +%s were created by the Grid configuration; roothas.sh -deconfig -force (GRIDCONFIG undo) removes them; the disks keep their ASM headers' "$obj" ;;
    DISKGROUP)  printf 'by hand, destroys everything in it: as %s  export ORACLE_HOME=%s ORACLE_SID=+ASM ; $ORACLE_HOME/bin/sqlplus / as sysasm  ->  drop diskgroup %s including contents;' "$GRID_USER" "$GRID_HOME" "$obj" ;;
    ROOHCTL)    printf 'left as it is: the home %s was made read/write (roohctl -disable); roohctl -enable would make it read-only again' "$obj" ;;
    LSNRRES)    printf 'auto: srvctl stop listener -listener %s ; srvctl remove listener -listener %s   (as %s)' "$obj" "$obj" "$GRID_USER" ;;
    LSNRPORT)   printf 'auto: srvctl modify listener -listener %s -endpoints TCP:%s ; stop and start it   (the port before the change)' "$obj" "$(detail_field "$det" old)" ;;
    LSNRSTART)  printf 'auto: lsnrctl stop %s   (as %s)' "$obj" "$(lsnr_user 2>/dev/null || printf '%s' "$ORACLE_USER")" ;;
    INSTANCE)   printf 'auto: shut the instance %s down (srvctl stop database when it is registered, else shutdown immediate)' "$obj" ;;
    DUPLICATE)  printf 'by hand: see  %s --help-step 8.2  (shutdown abort, then remove the files of %s on THIS server only - never the files of the primary)' "$SELF" "$obj" ;;
    DUPLICATE_DONE) printf 'the copied standby database %s: see the DUPLICATE line above' "$obj" ;;
    SRVCTL)     printf 'auto: srvctl stop database -db %s ; srvctl remove database -db %s -noprompt   (the database files stay)' "$obj" "$obj" ;;
    SRL)        printf 'auto: drop standby logfile group(s) %s on THIS server (apply stopped first, standby_file_management MANUAL for the drop)' "$det" ;;
    MRP)        printf 'auto: alter database recover managed standby database cancel' ;;
    UNIT)       if [[ "$obj" == *.timer ]]; then printf 'auto: systemctl disable --now %s  (the nightly clean-up stops; its files are removed by their own lines)' "$obj"
                else printf 'auto: systemctl disable %s  (the running standby is left running; its files are removed by their own lines)' "$obj"; fi ;;
    OPATCH)     printf 'by hand (only if wanted): rm -rf %s ; mv %s %s   (the OPatch of the media back)' "$obj" "$(detail_field "$det" old)" "$obj" ;;
    SRVCTL_OLD) printf 'by hand: the earlier registration of %s (srvctl config in the log of that run) can be added again with srvctl add database' "$obj" ;;
    RMANCFG)    local ov; ov=$(detail_field "$det" old); ov=${ov//\~/ }
                if [[ -z "$ov" || "$ov" == "-" ]]; then printf 'by hand (usually not wanted): as %s  rman target /  ->  CONFIGURE ARCHIVELOG DELETION POLICY CLEAR;' "$ORACLE_USER"
                else printf 'by hand (usually not wanted): as %s  rman target /  ->  CONFIGURE ARCHIVELOG DELETION POLICY %s;' "$ORACLE_USER" "$ov"; fi ;;
    PRIMARY)    printf 'on the PRIMARY, by hand, only after this standby no longer receives redo: %s' "$det" ;;
    *)          printf '%s' "$det" ;;
  esac
}

show_changes_cli() {
  # $1 step or empty
  local l seq t run step kind obj det n=0 last_step=""
  [[ -s "$JOURNAL_FILE" ]] || { printf 'No change is recorded yet (%s).\n' "$JOURNAL_FILE"; return 0; }
  journal_load_undone
  printf 'Changes made by %s (%s)\n' "$(basename "$SELF")" "$JOURNAL_FILE"
  printf 'auto = "%s --undo STEP" can undo it;  by hand = commands for you;  PRIMARY = you ran it on the primary\n' "$(basename "$SELF")"
  while IFS= read -r l; do
    IFS='|' read -r seq t run step kind obj det <<< "$l"
    [[ "$step" != "$last_step" ]] && { printf '\n[%s] %s\n' "$step" "$(step_title_of "$step")"; last_step=$step; }
    printf '  %4s  %s  %-10s %s\n' "$seq" "${t:0:16}" "$kind" "$obj"
    printf '        undo: %s\n' "$(undo_text "$kind" "$obj" "$det")"
    n=$((n + 1))
  done < <(journal_entries "${1:-}")
  if [[ $n -eq 0 ]]; then [[ -n "${1:-}" ]] && printf 'No change is recorded for step %s.\n' "$1" || printf 'No change is recorded (or every change was taken back).\n'; fi
  return 0
}
journal_run_summary() {
  # the changes of THIS run, under the summary
  [[ "$MODE" == "run" && -s "$JOURNAL_FILE" ]] || return 0
  journal_load_undone
  local l seq t run step kind obj det n=0 lines=""
  while IFS= read -r l; do
    IFS='|' read -r seq t run step kind obj det <<< "$l"
    n=$((n + 1))
    [[ $n -le 12 ]] && lines+="    $step  $kind  $obj"$'\n'
  done < <(journal_entries "" "$RUN_ID")
  [[ $n -gt 0 ]] || return 0
  printf '  Changes made by this run (%s):\n%s' "$n" "$lines"
  [[ $n -gt 12 ]] && printf '    ... and %s more\n' "$((n - 12))"
  printf '  Every change with its undo:  %s --show-changes      undo one step:  %s --undo STEP\n' "$SELF" "$SELF"
  return 0
}

#---- undo ------------------------------------------------------------------
_undo_file_ok() {
  # $1 file, $2 recorded md5 of the whole file: 0 when the file is unchanged since the script wrote it (or the user accepts)
  local cur; cur=$(file_md5 "$1")
  [[ -n "$2" && "$cur" == "$2" ]] && return 0
  warn "$1 was changed after this script wrote it."
  confirm "Undo anyway (the later change is lost)?"
}
_hint_after_restore() {
  case "$1" in
    */network/admin/listener.ora) say "Then reload the listener:  lsnrctl reload   (as $(lsnr_user 2>/dev/null || printf '%s' "$ORACLE_USER"))" ;;
    /etc/security/limits.d/*)     say "Limits apply at the next login of the users." ;;
    /etc/udev/rules.d/*)          say "Then:  udevadm control --reload-rules ; udevadm trigger" ;;
    /etc/systemd/system/*)        systemctl daemon-reload 2>/dev/null || true ;;
    */.bash_profile)              say "Applies at the next login of that user." ;;
  esac
  return 0
}
_db_registered() { use_grid && [[ -x "$DB_HOME/bin/srvctl" ]] && run_logged "srvctl config" as_oracle "$DB_HOME/bin/srvctl" config database -db "$STANDBY_UNIQUE" >/dev/null 2>&1; }
_undo_obj_ok() {
  # the journal is root-only, but its fields are checked again before anything is run with them
  local kind=$1 obj=$2 det=$3 x
  case "$kind" in
    NEW|APPEND|EDIT|RENAME|DIR)
      [[ "$obj" == /* ]] && v_path "$obj" || { bad "The journal line names an unusual path ($obj): not undone"; return 1; }
      [[ "$obj" == *"/../"* || "$obj" == *"/./"* || "$obj" == *"//"* || "$obj" == */.. || "$obj" == */. || "$obj" == */ ]] && { bad "The journal line names an unusual path ($obj): not undone"; return 1; }
      [[ "$kind" != DIR && -L "$obj" ]] && { bad "$obj is a symbolic link now: not undone"; return 1; }
      case "$obj" in /|/etc|/usr|/usr/*bin|/bin|/sbin|/lib*|/var|/opt|/home|/root|/boot|/dev|/proc|/sys|/tmp|/u0[0-9]) bad "$obj is a system folder: not undone"; return 1 ;; esac
      [[ "$kind" != DIR && -d "$obj" && ! -L "$obj" ]] && { bad "$obj is a folder; the journal line is for a file: not undone"; return 1; }
      if [[ "$kind" == EDIT ]]; then x=$(detail_field "$det" bak); [[ "$x" == "-" || ( "$x" == "$obj".bak_* && "${x#"$obj".bak_}" =~ ^[0-9]{8}_?[0-9]{6}$ ) ]] || { bad "The backup name $x does not belong to $obj: not undone"; return 1; }; fi
      if [[ "$kind" == RENAME ]]; then x=$(detail_field "$det" to); [[ ( "$x" == "$obj".pre_duplicate_* && "${x#"$obj".pre_duplicate_}" =~ ^[0-9_]+$ ) || ( "$x" == "$obj".failed_* && "${x#"$obj".failed_}" =~ ^[0-9_]+$ ) ]] || { bad "The renamed name $x does not belong to $obj: not undone"; return 1; }; fi ;;
    FWPORT) [[ "$obj" =~ ^[A-Za-z0-9_-]+:[0-9]+/tcp$ ]] || { bad "Bad firewall entry ($obj): not undone"; return 1; } ;;
    UNIT)   [[ "$obj" =~ ^[A-Za-z0-9_.@-]+\.(service|timer)$ ]] || { bad "Bad unit name ($obj): not undone"; return 1; } ;;
    LSNRRES|LSNRPORT|LSNRSTART) v_name "$obj" || { bad "Bad listener name ($obj): not undone"; return 1; } ;;
    SRVCTL) v_name "$obj" || { bad "Bad database name ($obj): not undone"; return 1; } ;;
    INSTANCE|MRP|SRL)
      # the line is for the standby of the current settings only (after a rename or a rebuild it is another database)
      [[ "$obj" == "$STANDBY_SID" ]] \
        || { bad "This line is for the instance $obj; the settings now are for $STANDBY_SID: not undone (do it by hand if still wanted)"; return 1; } ;;
  esac
  return 0
}
_srl_drop() {
  # $1 groups. standby_file_management=AUTO refuses the drop (ORA-01275): MANUAL for the drop, AUTO again in any case
  local g rc=0 have
  sql_local "select group#||'|'||status from v\$standby_log;" || { bad "Cannot read the standby logs ($(ora_errors "$SQL_OUT"))"; return 1; }
  have=$SQL_OUT
  local sfm="AUTO"; sql_local "select upper(value) from v\$parameter where name='standby_file_management';" && [[ "$(first_line)" == "MANUAL" ]] && sfm=MANUAL
  sql_local "alter system set standby_file_management=manual scope=memory;" || { bad "Cannot set standby_file_management=manual ($(ora_errors "$SQL_OUT"))"; return 1; }
  for g in $1; do
    num "$g" || continue
    grep -q "^$g|" <<< "$have" || { say "group $g is already gone"; continue; }
    if grep -q "^$g|ACTIVE" <<< "$have"; then
      bad "group $g is in use (ACTIVE: redo of the primary is written into it). Stop the shipping first (on the primary: alter system set log_archive_dest_state_<N of step 4.4>=defer scope=both; - the undo of step 9.5), then run this undo again."
      rc=1; continue
    fi
    local mem=""; sql_local "select member from v\$logfile where group#=$g and member like '/%' and rownum=1;" && mem=$(first_line)
    if sql_local "alter database drop standby logfile group $g;"; then
      say "standby logfile group $g dropped"
      [[ "$mem" == /* && "$mem" != */o1_mf_* && -e "$mem" ]] && say "Its file stays in the folder; remove it (as $ORACLE_USER):  [ \"\$(hostname -s)\" = \"$(hostname -s)\" ] && rm -f $mem"
    else bad "drop of group $g failed ($(ora_errors "$SQL_OUT"))"; rc=1; fi
  done
  if [[ "$sfm" == AUTO ]]; then
    sql_local "alter system set standby_file_management=auto scope=memory;" || warn "standby_file_management is still MANUAL in memory: alter system set standby_file_management=auto scope=memory;"
  fi
  return $rc
}
_state_or_2() {
  # local_state that is not readable means "cannot check": never treated as done
  local_state
  case "$LSTATE" in NOSW|ERROR|"") bad "Cannot check the instance (settings or software not found: $LSTATE)"; return 2 ;; esac
  return 0
}
undo_one() {
  # $1 kind, $2 object, $3 detail. 0 = undone, 1 = failed, 2 = printed only / skipped
  local kind=$1 obj=$2 det=$3 b m
  _undo_obj_ok "$kind" "$obj" "$det" || return 2
  case "$kind" in
    NEW)
      [[ -e "$obj" || -L "$obj" ]] || { say "$obj is already gone."; return 0; }
      m=$(detail_field "$det" md5); _undo_file_ok "$obj" "$m" || return 2
      rm -f -- "$obj" || return 1
      say "removed $obj"; _hint_after_restore "$obj"; return 0 ;;
    APPEND)
      [[ -f "$obj" ]] || { say "$obj is gone."; return 0; }
      local off len md5 cur_len tail_md5 u tmp
      off=$(detail_field "$det" off); len=$(detail_field "$det" len); md5=$(detail_field "$det" md5)
      num "$off" && num "$len" || return 1
      cur_len=$(stat -c '%s' -- "$obj")
      if [[ $cur_len -lt $((off + len)) ]]; then say "$obj is shorter than when the block was added; fix it by hand."; return 2; fi
      tail_md5=$(tail -c +$((off + 1)) -- "$obj" | head -c "$len" | md5sum | cut -d' ' -f1)
      if [[ "$tail_md5" != "$md5" ]]; then say "The block added to $obj is not there any more (the file was edited); fix it by hand."; return 2; fi
      # the udev rule of a disk that a disk group still uses must stay (the disk group would not mount any more)
      if [[ "$obj" == "${UDEV_RULES:-/nonexistent}" ]]; then
        local lab used_by=""
        for lab in $(tail -c +$((off + 1)) -- "$obj" | head -c "$len" | grep -oE 'SYMLINK\+="oraasm/[A-Za-z0-9_]+"' | sed 's#.*/##; s#"##'); do
          # removed only when proven unused: ASM must answer 0 (no answer = kept)
          if grid_sw_ok 2>/dev/null && sql_asm "select count(*) from v\$asm_disk where path like '%/$lab' and group_number > 0;" && [[ "$(first_line)" == "0" ]]; then :
          elif ! grid_sw_ok 2>/dev/null && [[ ! -e "$(asm_disk_dir 2>/dev/null)/$lab" ]]; then :
          else used_by+=" $lab"; fi
        done
        [[ -z "$used_by" ]] || { bad "ASM disk(s)$used_by may be in a disk group (or ASM cannot tell now): their udev rule stays. Drop the disk group first (see the ASMLABEL lines), with ASM running."; return 2; }
      fi
      u=$(stat -c '%U' -- "$obj")
      backup_file "$obj" "$u" || return 1
      # exactly the added bytes go; text before and after them stays (the newline added in front of the block stays
      # when more text follows it, so two lines are not glued together). The file is rewritten as its owner.
      [[ -L "$obj" ]] && { bad "$obj is a symbolic link now; not changed"; return 2; }
      local lead keep_nl=0; lead=$(detail_field "$det" lead)
      [[ "$lead" == "1" && $cur_len -gt $((off + len)) ]] && keep_nl=1
      tmp=$(mktemp) || return 1; CLEANUP_FILES+=("$tmp")
      { head -c "$off" -- "$obj"; [[ $keep_nl -eq 1 ]] && printf '\n'; tail -c +$((off + len + 1)) -- "$obj"; } > "$tmp" || { rm -f -- "$tmp"; return 1; }
      if [[ "$u" == "root" ]]; then cat "$tmp" > "$obj" || { rm -f -- "$tmp"; return 1; }
      else chmod 644 "$tmp"; runuser -u "$u" -- cp -- "$tmp" "$obj" || { rm -f -- "$tmp"; return 1; }; fi
      rm -f -- "$tmp"
      if [[ $off -eq 0 && ! -s "$obj" ]]; then rm -f -- "$obj"; say "$obj only held the added block: removed"
      else say "the block added to $obj was removed again"; fi
      _hint_after_restore "$obj"; return 0 ;;
    EDIT)
      b=$(detail_field "$det" bak); m=$(detail_field "$det" md5)
      [[ -n "$b" && "$b" != "-" ]] || { say "No exact backup copy for this change: compare $obj with its .bak_ copies and fix it by hand."; return 2; }
      [[ -f "$b" ]] || { bad "The backup copy $b is gone; fix $obj by hand."; return 2; }
      _undo_file_ok "$obj" "$m" || return 2
      cp -p --remove-destination -- "$b" "$obj" || return 1
      say "$obj put back from $b"; _hint_after_restore "$obj"; return 0 ;;
    RENAME)
      local to; to=$(detail_field "$det" to)
      [[ -f "$to" ]] || { say "$to is gone; nothing to rename back."; return 0; }
      [[ -e "$obj" ]] && { say "$obj exists again; the renamed copy $to is left as it is."; return 2; }
      mv -f -- "$to" "$obj" || return 1
      say "$to renamed back to $obj"; return 0 ;;
    DIR)
      [[ -d "$obj" ]] || { say "$obj is already gone."; return 0; }
      if rmdir -- "$obj" 2>/dev/null; then say "removed the empty folder $obj"; return 0; fi
      say "$obj is not empty; left as it is."; return 2 ;;
    FWPORT)
      run_cmds <<< "firewall-cmd --permanent --zone=${obj%%:*} --remove-port=${obj#*:}
firewall-cmd --reload" ;;
    UNIT)
      if [[ ! -f "/etc/systemd/system/$obj" ]] && ! systemctl cat "$obj" >/dev/null 2>&1; then say "$obj is already gone."; return 0; fi
      if [[ "$obj" == *.timer ]]; then
        # a timer is stopped too (it would fire every night); its files are removed by their own lines
        run_cmds <<< "systemctl disable --now $obj" || return 1
        systemctl daemon-reload 2>/dev/null || true
        say "$obj is stopped and disabled"; return 0
      fi
      run_cmds <<< "systemctl disable $obj" || return 1
      systemctl reset-failed "$obj" 2>/dev/null || true
      say "$obj is disabled (it will not start at boot; the standby itself was not stopped)"; return 0 ;;
    LSNRRES)
      run_logged "srvctl config listener" as_grid "$GRID_HOME/bin/srvctl" config listener -listener "$obj" >/dev/null 2>&1 || { say "listener $obj is not registered (already gone)"; return 0; }
      run_logged "srvctl stop listener" as_grid "$GRID_HOME/bin/srvctl" stop listener -listener "$obj" || true
      run_logged "srvctl remove listener" as_grid "$GRID_HOME/bin/srvctl" remove listener -listener "$obj" || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      say "listener $obj removed from Oracle Restart"; return 0 ;;
    LSNRPORT)
      local old; old=$(detail_field "$det" old); num "$old" || return 2
      run_logged "srvctl modify listener" as_grid "$GRID_HOME/bin/srvctl" modify listener -listener "$obj" -endpoints "TCP:$old" || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      run_logged "srvctl stop listener" as_grid "$GRID_HOME/bin/srvctl" stop listener -listener "$obj" || true
      run_logged "srvctl start listener" as_grid "$GRID_HOME/bin/srvctl" start listener -listener "$obj" || true
      say "listener $obj back on port $old"; return 0 ;;
    LSNRSTART)
      if run_logged "lsnrctl stop" as_lsnr timeout 120 "$(lsnr_home)/bin/lsnrctl" stop "$obj"; then say "listener $obj stopped"; return 0; fi
      grep -qE 'TNS-12541|TNS-12560|TNS-00511|No listener' <<< "$RUN_OUT" && { say "listener $obj was not running"; return 0; }
      bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1 ;;
    INSTANCE)
      _state_or_2 || return 2
      [[ "$LSTATE" == "IDLE" ]] && { say "Instance $obj is not running."; return 0; }
      if [[ "$LSTATE" == "MOUNTED" ]] && mrp_running; then
        warn "The standby is mounted and APPLYING redo. Shutting it down stops the apply (it continues when it is started again)."
        confirm "Shut it down anyway?" || return 2
      fi
      if _db_registered; then
        run_logged "srvctl stop database" as_oracle timeout 1800 "$DB_HOME/bin/srvctl" stop database -db "$STANDBY_UNIQUE" -stopoption immediate || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      else
        sql_local_long "shutdown immediate" || { bad "shutdown immediate failed ($(ora_errors "$SQL_OUT")); trying shutdown abort"; sql_local "shutdown abort" || return 1; }
      fi
      say "instance $obj is down"; return 0 ;;
    SRVCTL)
      run_logged "srvctl config" as_oracle "$DB_HOME/bin/srvctl" config database -db "$obj" >/dev/null 2>&1 || { say "$obj is not registered (already gone)"; return 0; }
      run_logged "srvctl status" as_oracle "$DB_HOME/bin/srvctl" status database -db "$obj" || true
      grep -q 'is running' <<< "$RUN_OUT" && { run_logged "srvctl stop" as_oracle timeout 1800 "$DB_HOME/bin/srvctl" stop database -db "$obj" -stopoption immediate || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }; }
      run_logged "srvctl remove" as_oracle "$DB_HOME/bin/srvctl" remove database -db "$obj" -noprompt || { bad "$(tail -n 2 <<< "$RUN_OUT")"; return 1; }
      say "$obj removed from Oracle Restart (the database files are untouched)"; return 0 ;;
    SRL)
      _state_or_2 || return 2
      [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { bad "The standby must be mounted to drop standby logs (step 9.2)."; return 2; }
      local was_mrp=0
      if mrp_running; then was_mrp=1; sql_local "alter database recover managed standby database cancel;" || { bad "Cannot stop apply first"; return 1; }; fi
      local src=0; _srl_drop "$det" || src=1
      if [[ $was_mrp -eq 1 ]]; then
        warn "Redo apply was stopped for the drop and is NOT running now. Start it again:  $SELF --from 9.4   (or: alter database recover managed standby database disconnect;)"
      fi
      return $src ;;
    MRP)
      _state_or_2 || return 2
      [[ "$LSTATE" == "MOUNTED" || "$LSTATE" == "OPEN" ]] || { say "The standby is not mounted; apply is not running."; return 0; }
      sql_local "alter database recover managed standby database cancel;" || { grep -q 'ORA-16136' <<< "$SQL_OUT" && { say "apply was not running"; return 0; }; bad "cancel failed ($(ora_errors "$SQL_OUT"))"; return 1; }
      say "apply (MRP) stopped"; return 0 ;;
    *)  return 2 ;;
  esac
}

UNDO_QUIT=0; UNDO_N_DONE=0
undo_cli() {
  # $1 step id. Walks the journal of that step backwards. Needs the settings (no primary connection).
  # Returns 0 when every line was handled, 1 when a line failed or was left.
  local step=$1 l seq t run step2 kind obj det n=0 rc n_done=0 n_left=0
  [[ -s "$JOURNAL_FILE" ]] || { printf 'No change is recorded yet (%s).\n' "$JOURNAL_FILE"; return 0; }
  job_alive && { bad "A long job of an earlier run is still running ($JOB_TITLE). Wait for it, then try again."; return 1; }
  journal_load_undone
  local -a lines=(); mapfile -t lines < <(journal_entries "$step" | tac)
  [[ ${#lines[@]} -gt 0 ]] || { printf 'No change is recorded for step %s (see --show-changes).\n' "$step"; return 0; }
  printf '%sUndo of step %s%s  %s\n' "$C_B" "$step" "$C_N" "$(step_title_of "$step")"
  printf 'The changes are undone in the reverse order, one by one. Nothing on the primary is touched.\n'
  if later_steps_active "$step"; then
    local later; later=$(journal_entries | awk -F'|' -v s="$step" '$4 ~ /^[0-9]+\.[0-9]+$/ && $5 !~ /^(SERVICE|ROOHCTL|SETTING|DUPLICATE_DONE)$/ {split($4,a,"."); split(s,b,"."); if (a[1]*100+a[2] > b[1]*100+b[2]) print $4}' | sort -t. -k1,1n -k2,2n -u | paste -sd' ' -)
    warn "Later steps have changes that build on this one: $later. Undo them first (the last one first: --undo ${later##* }), or type UNDO to continue anyway."
    confirm_word "Undo step $step although later steps depend on it?" "UNDO" || { printf 'Undo not started.\n'; return 1; }
  fi
  CUR_STEP=$step
  for l in "${lines[@]}"; do
    IFS='|' read -r seq t run step2 kind obj det <<< "$l"
    n=$((n + 1))
    printf '\n  %s%s) %s %s%s   (run %s)\n' "$C_W" "$n" "$kind" "$obj" "$C_N" "$run"
    printf '     undo: %s\n' "$(undo_text "$kind" "$obj" "$det")"
    case "$kind" in
      NEW|APPEND|EDIT|RENAME|DIR|FWPORT|UNIT|LSNRRES|LSNRPORT|LSNRSTART|INSTANCE|SRVCTL|SRL|MRP)
        ask_choice "[y] undo it   [s] skip   [q] quit" "ysq"
        case "$ANSWER" in
          s) n_left=$((n_left + 1)); continue ;;
          q) UNDO_QUIT=1; n_left=$((n_left + 1)); break ;;
        esac
        rc=0; undo_one "$kind" "$obj" "$det" || rc=$?
        if [[ $rc -eq 0 ]]; then journal UNDONE "$seq" "$kind $obj"; ok "undone"; n_done=$((n_done + 1)); UNDO_N_DONE=$n_done
        else
          [[ $rc -eq 1 ]] && bad "could not undo this change (see the log)"
          if confirm "Mark this line as done by you (it is then no longer listed)?"; then journal UNDONE "$seq" "$kind $obj (by you)"; n_done=$((n_done + 1)); UNDO_N_DONE=$n_done
          else n_left=$((n_left + 1)); fi
        fi ;;
      SERVICE|ROOHCTL|SETTING|DUPLICATE_DONE)
        say "Nothing to do for this line." ;;
      *)
        say "This change is undone by hand (command above)."
        if confirm "Mark it as done by you?"; then journal UNDONE "$seq" "$kind $obj"; n_done=$((n_done + 1)); else n_left=$((n_left + 1)); fi ;;
    esac
  done
  # the progress board shows the step as not done any more
  if [[ $n_done -gt 0 ]] && declare -F record >/dev/null; then
    NOW="undone with --undo ($n_done change(s)$([[ $n_left -gt 0 ]] && printf '; %s left' "$n_left"))"; STEP_TITLE[$step]=$(step_title_of "$step"); record "$step" UNDONE
  fi
  if [[ $UNDO_QUIT -eq 1 ]]; then printf '\nUndo of step %s stopped by you. What is left:  %s --show-changes %s\n' "$step" "$SELF" "$step"
  elif [[ $n_left -gt 0 ]]; then printf '\nUndo of step %s finished (%s undone, %s left). %s --show-changes %s shows what is left.\n' "$step" "$n_done" "$n_left" "$SELF" "$step"
  else printf '\nUndo of step %s finished: every change of the step is taken back.\n' "$step"; fi
  [[ $n_done -gt 0 ]] && printf 'The step counts as not done now: a normal run (or  %s --from %s) does it again.\n' "$SELF" "$step"
  _log INFO "undo of step $step: $n_done undone, $n_left left"
  [[ $n_left -eq 0 ]]
}

step_title_of() {
  # title of a step from the help texts (the engine fills STEP_TITLE only for steps that ran)
  local t=${STEP_TITLE[$1]:-}
  [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
  if declare -F help_text >/dev/null && t=$(help_text "$1" 2>/dev/null | sed -n 's/^TITLE  //p' | head -n 1) && [[ -n "$t" ]]; then printf '%s' "$t"; return 0; fi
  printf 'step %s' "$1"
}
