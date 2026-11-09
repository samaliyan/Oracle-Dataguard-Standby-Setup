#------------------------------------------------------------------------------
# PHASE 1  Connect to primary and read its configuration
#------------------------------------------------------------------------------
c_1_1() {
  [[ $EUID -eq 0 ]] || { NOW="The script is not running as root"; PLAN="Run the script as root"; return 1; }
  local t missing=()
  for t in runuser getent awk sed grep stat timeout install useradd groupadd usermod lsblk blkid cmp ssh scp paste md5sum df du comm mktemp setsid tail ip flock pgrep pkill unzip; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    NOW="These tools are missing: ${missing[*]}"
    PLAN="${PKG:-yum} install -y util-linux coreutils shadow-utils openssh-clients gawk sed grep iproute diffutils procps-ng unzip"
    return 1
  fi
  local os="unknown"; os=$(os_field PRETTY_NAME); os=${os:-unknown}
  NOW="Running as root on $(hostname -s). All needed tools are present."$'\n'"$os, bash ${BASH_VERSION%%(*}, packages with $PKG"
  if ! [[ "$OS_MAJOR" =~ ^[0-9]+$ && $OS_MAJOR -ge 7 ]]; then
    NOW+=$'\n'"This is not Oracle Linux or RHEL 7 or newer. Packages and kernel settings may need work by hand."
    warn "$os is not Oracle Linux 7, 8 or 9. The script goes on."
  fi
  return 0
}

c_1_6() {
  # Oracle version and Oracle Linux version must be a supported pair (checked when the version is known)
  [[ $DISCOVERED -eq 1 ]] || { NOW="Primary configuration not read (step 1.3)"; return 2; }
  if ! [[ "$OS_MAJOR" =~ ^[0-9]+$ && $OS_MAJOR -gt 0 ]]; then
    NOW="Cannot be checked: the version of this operating system cannot be read (/etc/os-release)."
    PLAN="-- Check by hand that Oracle ${PRIMARY_VERSION:-of the primary} is certified on this operating system:"$'\n'"-- My Oracle Support, Certifications tab. Then answer s to go on."
    MANUAL_WHERE="To check by hand"; MANUAL_HOW="the DBA"
    return 2
  fi
  local v=$PRIMARY_VERSION why="" r w
  # the database release, and the Grid release when there is Grid (Grid may be newer)
  local -a rels=("$(want_rel)")
  [[ -n "$GRID_REL" && "$GRID_REL" != "${rels[0]}" ]] && rels+=("$GRID_REL")    # the same release is checked once
  # Oracle Linux 10 and newer: not tested with this script (no release here was certified on it when it was made)
  [[ $OS_MAJOR -ge 10 ]] && why+="Oracle Linux $OS_MAJOR was not tested with this script. Use Oracle Linux 7, 8 or 9 for the standby."$'\n'
  for r in "${rels[@]}"; do
    w=""
    case "$r" in
      12.1) [[ $OS_MAJOR -ge 8 ]] && w="12.1 is certified on Oracle Linux 7 only."
            [[ "$v" == 12.1.0.1* && $OS_MAJOR -eq 7 ]] && w="12.1.0.1 is not certified on Oracle Linux 7. Only 12.1.0.2 is." ;;
      12.2|18) [[ $OS_MAJOR -ge 8 ]] && w="$r is not certified on Oracle Linux $OS_MAJOR. Its installer stops there."$'\n'"Use Oracle Linux 7 for this standby." ;;
      19)   [[ $OS_MAJOR -ge 9 && -z "$RU_DIR" ]] && w="19c on Oracle Linux 9 must be installed together with Release Update 19.19 or newer."$'\n'"1. Unzip that Release Update on this server. Also get the newest OPatch zip (p6880880)."$'\n'"2. Answer s here. In step 1.4 choose e, then set RU_DIR and OPATCH_ZIP." ;;
      # 21c on Oracle Linux 9: certified from Release Update 21.12 (installed together with that RU, as 19c)
      21)   if [[ $OS_MAJOR -ge 9 ]]; then
              # the RU is judged only from a full 21.x version of the database (21.0.0.0.0 = not known; a 21c Grid
              # with an older database has no 21c database version)
              local ru21=""; [[ "$v" == 21.* ]] && ru21=$(cut -d. -f2 <<< "$v")
              if [[ "$ru21" =~ ^[0-9]+$ && $ru21 -gt 0 && $ru21 -lt 12 ]]; then w="21c on Oracle Linux 9 is certified from Release Update 21.12. The primary has $v."$'\n'"Patch the primary to 21.12 or newer first, or use Oracle Linux 8 for the standby."
              elif [[ -z "$RU_DIR" ]]; then w="21c on Oracle Linux 9 must be installed together with Release Update 21.12 or newer."$'\n'"1. Unzip that Release Update on this server. Also get the newest OPatch zip (p6880880)."$'\n'"2. Answer s here. In step 1.4 choose e, then set RU_DIR and OPATCH_ZIP."; fi
            fi ;;
      *)    [[ $OS_MAJOR -le 7 ]] && w="$r needs Oracle Linux 8 or newer." ;;
    esac
    [[ -n "$w" ]] && why+="$w"$'\n'
  done
  if use_grid && [[ -n "$GRID_REL" ]]; then
    local gm dm; gm=$(rel_major "$GRID_REL"); dm=$DB_MAJOR
    if [[ $gm -lt $dm || ( $gm -eq 12 && $dm -eq 12 && "${GRID_REL#12.}" < "${PRIMARY_VERSION:3:1}" ) ]]; then why+="Grid $GRID_REL is older than the database ($v). Grid must be the same release or newer."$'\n'; fi
  fi
  why=${why%$'\n'}
  if [[ -n "$why" ]]; then NOW="Oracle $v${GRID_REL:+ (Grid $GRID_REL)} on Oracle Linux $OS_MAJOR: not supported as it is. ${why%%$'\n'*}"; PLAN="$why"; return 1; fi
  NOW="Oracle $v${GRID_REL:+ (Grid $GRID_REL)} on Oracle Linux $OS_MAJOR: supported"
  [[ "$DB_MAJOR" == "19" && $OS_MAJOR -ge 8 && -z "$RU_DIR" ]] && NOW+=$'\n'"The 19c installer runs with CV_ASSUME_DISTID=OEL7.8 (19.3 needs it on Oracle Linux 8+)."
  return 0
}

c_1_2() {
  if is_local_ip "$(ipv4_of "$PRIMARY_IP")"; then
    fatal "$PRIMARY_IP is an address of this server, but you gave it as the primary.
Run the script on the standby server."
  fi
  if ssh_alive; then NOW="Connected to $PRIMARY_SSH_USER@$PRIMARY_IP"; return 0; fi
  if [[ "$MODE" == "check" ]]; then open_ssh && { NOW="Connected to $PRIMARY_SSH_USER@$PRIMARY_IP"; return 0; }; NOW="The ssh connection failed. The reason is shown above."; return 2; fi
  NOW="Not connected to the primary yet"
  PLAN="Open one ssh connection to $PRIMARY_SSH_USER@$PRIMARY_IP (read-only commands only)."
  return 1
}
d_1_2() { open_ssh; }

c_1_3() {
  if [[ $DISCOVERED -eq 1 ]]; then NOW="Primary configuration read: $PRIMARY_UNIQUE on $PRIMARY_HOST"; return 0; fi
  need_ssh || { NOW="No ssh connection to the primary (step 1.2)"; return 2; }
  if [[ "$MODE" == "check" ]]; then discover_primary && { NOW="Primary configuration read"; return 0; }; NOW="Reading the primary failed. The reason is shown above."; return 2; fi
  NOW="The primary configuration is not read yet"
  PLAN="Read the primary configuration. Nothing is changed there:
  running instances and listeners, and the home of the database
  /etc/oratab, /etc/oraInst.loc, the Oracle users and groups, the Oracle bases
  name, role, version, storage and size of the database (SELECT only)
  listener port and service (lsnrctl status)"
  return 1
}
d_1_3() { discover_primary; }

SETTINGS_DIFF=""
summary_wanted() {
  # the summary screen: every setup run (not the daily check of phase 10, not --roll-forward)
  [[ ${HEALTH:-0} -eq 1 || ${ROLL_FORWARD:-0} -eq 1 || "${ONLY_PHASE:-}" == 10 ]] && return 1
  [[ $SUMMARY_DONE -eq 0 ]]
}
SUMMARY_DONE=0
c_1_4() {
  [[ $DISCOVERED -eq 1 ]] || { NOW="The primary configuration is not read yet (step 1.3)"; return 2; }
  derive_standby_settings
  if summary_wanted; then
    SETTINGS_DIFF=$(accepted_diff 2>/dev/null) || SETTINGS_DIFF=""
    # what the settings file had that is converted or not used: said before the summary
    if [[ $SETTINGS_UPGRADED -eq 1 ]]; then
      warn "The settings file came from an older version of the script and was converted.${DROPPED_KEYS:+
No longer used:$DROPPED_KEYS. Disks are now chosen in step 2.13.}$([[ ${PLACEMENT_KEPT:-0} -eq 1 ]] && printf '\nThe standby here was copied by an older version: its files keep the paths of the primary (DATA_DEST=same, FRA_DEST=same).')"
    elif [[ -n "$DROPPED_KEYS" ]]; then
      warn "Unknown keys in $SETTINGS_FILE were ignored:$DROPPED_KEYS"
    fi
    if [[ "$MODE" == check ]]; then
      # the same screen, as a report
      SUMMARY_DONE=1; summary_show; summary_save
    else
      NOW="Summary of this run: what was found, where the standby goes, the plan, and the values of this run."
      KIND_NOW=ask; QUIET_PLAN=1
      return 1
    fi
  fi
  if [[ $SETTINGS_ACCEPTED -eq 1 ]]; then NOW="Settings accepted ($SETTINGS_FILE)"; return 0; fi
  local d rc=0
  d=$(accepted_diff) || rc=1
  # 1.6 found a value that must be set in the settings (for example RU_DIR): show them, do not accept silently
  if [[ $rc -eq 0 && -z "$d" && $REVIEW_SETTINGS -eq 0 && $SETTINGS_UPGRADED -eq 0 && "${STEP_RESULT[1.6]:-OK}" == OK ]] && validate_settings >/dev/null 2>&1; then
    SETTINGS_ACCEPTED=1
    NOW="Same settings as you accepted before ($SETTINGS_FILE)"$'\n'"To see or change them:  $SELF --settings"
    return 0
  fi
  SETTINGS_DIFF=$d
  show_settings
  [[ $rc -eq 0 && -n "$d" ]] && { printf 'Changed since you last accepted the settings:\n%s\n' "$d" | hint; _log INFO "settings changed: $(tr '\n' ';' <<< "$d")"; }
  if [[ $SETTINGS_UPGRADED -eq 1 ]]; then
    warn "The settings file came from an older version of the script and was converted.
Check the values above.${DROPPED_KEYS:+
No longer used:$DROPPED_KEYS. Disks are now chosen in step 2.13.}$([[ ${PLACEMENT_KEPT:-0} -eq 1 ]] && printf '\nThe standby here was copied by an older version: its files keep the paths of the primary (DATA_DEST=same, FRA_DEST=same).')"
  elif [[ -n "$DROPPED_KEYS" ]]; then
    warn "Unknown keys in $SETTINGS_FILE were ignored:$DROPPED_KEYS"
  fi
  if [[ "$MODE" == "check" ]]; then validate_settings && { NOW="Settings worked out; check mode does not save them"; return 0; }; NOW="The settings have problems. They are shown above."; return 2; fi
  NOW="The settings above are not accepted yet"
  PLAN="Save these settings and use them in all later steps
File: $SETTINGS_FILE"
  return 1
}
pick_editor() {
  local e
  for e in "${EDITOR:-}" vi vim nano; do [[ -n "$e" ]] && command -v "${e%% *}" >/dev/null 2>&1 && { printf '%s' "$e"; return 0; }; done
  return 1
}
d_1_4() {
  local ed
  if summary_wanted && [[ "$MODE" != check ]]; then
    local changed_any=0 was_ok=0
    [[ $SETTINGS_ACCEPTED -eq 1 || ( -z "${SETTINGS_DIFF:-}" && $SETTINGS_UPGRADED -eq 0 && -f "$ACCEPTED_FILE" ) ]] && was_ok=1
    while true; do
      summary_values
      if [[ $UI -eq 1 ]]; then ui_summary_ask; else summary_show; ask "[Enter] Start   [number] Change   [d] Details   [e] Edit the file   [q] Quit"; fi
      local a=${ANSWER//[[:space:]]/}; a=${a,,}
      case "$a" in
        "") if ! validate_settings >/dev/null 2>&1; then
              validate_settings
              SUM_NOTE="Not started: $(validate_settings 2>&1 | sed 's/\x1b\[[0-9;]*m//g; s/^[^A-Za-z]*//' | grep -v '^$' | head -n 1)"
              continue
            fi
            save_settings; save_accepted; SETTINGS_ACCEPTED=1; SETTINGS_UPGRADED=0; SUMMARY_DONE=1
            summary_save
            _log INFO "summary accepted, the run starts"
            DONE_MSG="Settings saved to $SETTINGS_FILE. Summary: $LOG_DIR/summary_$RUN_ID.txt"
            [[ $was_ok -eq 1 && $changed_any -eq 0 ]] && { DONE_AS_OK=1; DONE_MSG="Same settings as before. Summary: $LOG_DIR/summary_$RUN_ID.txt"; }
            return 0 ;;
        d)  local f; f=$(mktemp) && CLEANUP_FILES+=("$f") && summary_details_text > "$f"
            if [[ $UI -eq 1 ]]; then ui_page "$f" "Details"; else cat -- "$f"; fi; rm -f -- "$f" ;;
        h)  show_help 1.4 || true ;;
        q)  user_stop "Stopped by you" ;;
        e)  SUMMARY_DONE=1; L14_EDIT=1; break ;;          # the file in an editor: the way below
        *)  if [[ "$a" =~ ^[0-9]{1,2}$ ]] && (( 10#$a >= 1 && 10#$a <= ${#SV_ID[@]} )); then sv_change "$((10#$a))"; changed_any=1
            else sum_note "Type a number from 1 to ${#SV_ID[@]}, d, e or q, or press Enter to start."; fi ;;
      esac
    done
  fi
  while true; do
    if [[ ${L14_EDIT:-0} -eq 1 ]]; then L14_EDIT=0; ANSWER=e; else ask_choice "[a] Accept   [e] Edit   [h] Help   [q] Quit" "aeq"; fi
    case "$ANSWER" in
      a)
        validate_settings || { bad "Fix the settings first: choose e."; continue; }
        [[ ${ED_KEEP_FILE:-0} -eq 1 ]] && warn "Your last edit was not valid, so it is not used. The values from before that edit are saved."
        save_settings; save_accepted; SETTINGS_ACCEPTED=1; SETTINGS_UPGRADED=0
        _log INFO "settings accepted"
        DONE_MSG="Settings saved to $SETTINGS_FILE"; return 0 ;;
      e)
        ed=$(pick_editor) || { bad "No editor found (vi, vim, nano). Edit $SETTINGS_FILE by hand, then run the script again."; continue; }
        [[ ${ED_KEEP_FILE:-0} -eq 1 ]] || save_settings
        ED_KEEP_FILE=0
        say "The settings file opens in $ed. Change only the lines under 'Standby values'."
        say "Each line is NAME=VALUE, for example STANDBY_UNIQUE is the db_unique_name."
        [[ $LSNR_ASSUMED -eq 1 ]] && say "PORT, LISTENER_NAME and PRIMARY_SERVICE were assumed. You may correct them too."
        [[ "$ed" == vi* ]] && say "In vi: i to type, Esc then :wq to save and close, Esc then :q! to close without saving."
        # what the primary told us: an edit of these values is not accepted
        local k snap="" old_unique=$STANDBY_UNIQUE old_sid=$STANDBY_SID old_svc=$STANDBY_SERVICE old_tns=$STANDBY_TNS
        for k in $(all_setting_keys); do is_standby_key "$k" || assumed_key "$k" || snap+="$k=${!k}"$'\n'; done
        $ed "$SETTINGS_FILE" < "$PROMPT_IN" || true
        # check the edited file first (a typo must not stop the script)
        local -A keep=(); local line
        while IFS= read -r line; do [[ -n "$line" ]] && keep[${line%%=*}]=${line#*=}; done <<< "$snap"
        local save_vals=""; for k in $STANDBY_KEYS PORT LISTENER_NAME PRIMARY_SERVICE; do save_vals+="$k=${!k}"$'\n'; done
        if ! load_settings soft; then
          bad "The edited file has an error: $LOAD_ERR"; say "Your edits are still in $SETTINGS_FILE."
          while IFS= read -r line; do [[ -n "$line" ]] && printf -v "${line%%=*}" '%s' "${line#*=}"; done <<< "$save_vals"
          for k in "${!keep[@]}"; do printf -v "$k" '%s' "${keep[$k]}"; done
          say "Choose e to open it again and fix the error."
          ED_KEEP_FILE=1
          continue
        fi
        local changed="" refused=""
        for k in "${!keep[@]}"; do
          if [[ "${!k}" != "${keep[$k]}" ]]; then refused+=" $k"; printf -v "$k" '%s' "${keep[$k]}"; fi
        done
        [[ -n "$refused" ]] && warn "These values come from the primary and cannot be changed here:$refused
The values read from the primary are kept."
        if [[ "$STANDBY_UNIQUE" != "$old_unique" ]]; then
          # values that were derived from the old name are derived again from the new one
          [[ "$STANDBY_SID" == "$old_sid" && ( "$old_sid" == "$old_unique" || "$old_sid" == "${old_unique:0:12}" ) ]] && STANDBY_SID=""
          [[ "$STANDBY_SERVICE" == "$old_svc" ]] && STANDBY_SERVICE=""
          [[ "$STANDBY_TNS" == "$old_tns" ]] && STANDBY_TNS=""
        fi
        derive_standby_settings
        while IFS= read -r line; do
          k=${line%%=*}; [[ -n "$k" && "${!k}" != "${line#*=}" ]] && changed+=" $k=${!k}"
        done <<< "$save_vals"
        _log INFO "settings edited:${changed:- nothing changed}"
        [[ -n "$changed" ]] && say "Changed:$changed"
        save_settings
        show_settings ;;
      q) user_stop "Stopped by you" ;;
    esac
  done
}

sys_needed() {
  # the sys password is used only by the steps 7.4 - 8.2 (login tests and the duplicate)
  [[ "$MODE" == "check" ]] && return 0
  # logins that an earlier run could not test (the standby was down) are tested after 9.2 / 9.4 start it
  [[ -f "$(logins_flag)" ]] && return 0
  if [[ -n "$ONLY_PHASE" ]]; then [[ "$ONLY_PHASE" == "7" || "$ONLY_PHASE" == "8" ]]; return; fi
  [[ -n "$TO_STEP" && $(step_num "$TO_STEP") -lt $(step_num 7.4) ]] && return 1
  [[ -z "$FROM_STEP" ]] && return 0
  [[ $(step_num "$FROM_STEP") -le $(step_num 8.2) ]]
}
c_1_5() {
  if [[ $SYS_VERIFIED -eq 1 ]]; then NOW="The sys password works on the primary"; return 0; fi
  [[ $DISCOVERED -eq 1 ]] || { NOW="The primary configuration is not read yet (step 1.3)"; return 2; }
  sys_needed || { NOW="Not needed in this run. Only the login tests (steps 7.4 to 7.6) and the RMAN copy use it."; return 0; }
  if [[ "$MODE" == "check" ]]; then d_1_5 && { NOW="The sys password works on the primary"; return 0; }; NOW="The sys password is not verified. The reason is shown above."; return 2; fi
  NOW="The sys password is not given yet"
  PLAN="Ask for the sys password. It is hidden while you type and kept only in memory.
Test it on the primary, through its listener:
  sqlplus sys@//$PRIMARY_HOST:$PORT/$PRIMARY_SERVICE  (select 1 from dual)"
  return 1
}
d_1_5() {
  if [[ -n "$ENV_SYS_PW" ]]; then SECRET=$ENV_SYS_PW; ENV_SYS_PW=""; say "Using DG_SYS_PASSWORD from environment"
  else ask_secret "sys password of the primary (hidden while you type)"; fi
  if [[ -z "$SECRET" ]] || ! sys_pw_ok "$SECRET"; then
    SECRET=""
    bad "This password cannot be used. It is empty, or it has a space, a quote,
one of  # & ; \\ \`  or a non-ASCII character."
    printf 'The script cannot pass such a password to sqlplus and RMAN.\nChange it on the primary first, as %s in sqlplus / as sysdba:\n  alter user sys identified by "<new password>";\nFrom 12.2 on, this also updates the password file. Then answer r.\n' "$ORACLE_USER" | hint
    return 1
  fi
  SYS_PW=$SECRET; SECRET=""
  local tgt
  for tgt in "//localhost:$PORT/$PRIMARY_SERVICE" "//$PRIMARY_HOST:$PORT/$PRIMARY_SERVICE" "//$PRIMARY_IP:$PORT/$PRIMARY_SERVICE"; do
    if prim_sql_as_sys "$tgt" "select 1 from dual;"; then
      SYS_VERIFIED=1; DONE_MSG="The sys password works on the primary"
      mask_pending
      # tested in bash: an external grep would show the password in the process list
      local hay="$ORACLE_USER $GRID_USER $DB_HOME $ORACLE_BASE $PRIMARY_SID $STANDBY_SID"
      if [[ ${#SYS_PW} -lt 8 || "${hay,,}" == *"${SYS_PW,,}"* ]]; then
        warn "The sys password is short, or it is part of a name or path.
The log replaces it with ***** everywhere, so some names in the log look odd."
      fi
      return 0
    fi
    # only a network problem is a reason to try the next address
    grep -qE 'ORA-12541|TNS-12541|ORA-12514|ORA-12170|ORA-12545' <<< "$SQL_OUT" || break
  done
  local errs; errs=$(ora_errors "$SQL_OUT")
  bad "The sys login on the primary failed: ${errs:-no error text}
The test ran on the primary itself, through its listener."
  {
    [[ "$errs" == *ORA-01017* ]] && printf 'ORA-01017: wrong sys password, or SYS is not in the password file of the primary.\nTo set it on the primary, in sqlplus / as sysdba:\n  alter user sys identified by "<password>";\n'
    [[ "$errs" == *ORA-12514* ]] && printf 'ORA-12514: the listener on the primary does not know the service %s.\nCheck it on the primary, as the listener owner:\n  ORACLE_HOME=%s %s/bin/lsnrctl status %s\nThe service must be listed. If it is not, check service_names of the database.\n' "$PRIMARY_SERVICE" "$PRIMARY_LISTENER_HOME" "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME"
    [[ "$errs" == *12541* ]] && printf 'ORA-12541: no listener on port %s on the primary. Start it there, as the listener owner:\n  ORACLE_HOME=%s %s/bin/lsnrctl start %s\n' "$PORT" "$PRIMARY_LISTENER_HOME" "$PRIMARY_LISTENER_HOME" "$LISTENER_NAME"
    [[ "$errs" == *ORA-12170* || "$errs" == *ORA-12545* ]] && printf 'ORA-12170/12545: the host name or port cannot be reached from the primary itself.\n'
    [[ "$errs" == *ORA-28000* ]] && printf 'ORA-28000: the SYS account is locked.\n'
    true
  } | hint
  SYS_PW=""
  return 1
}

sys_pw_ok() {
  # characters that cannot travel safely to sqlplus / RMAN (connect strings, quotes, comments) are refused,
  # and so are non-ASCII characters (the two servers may use different character sets)
  local LC_ALL=C
  [[ "$1" =~ ^[[:print:]]+$ ]] || return 1
  # @ / $ ! % and the like are fine: the password always travels in double quotes, through stdin.
  # Refused: space, quotes, backslash, backtick, and # & ; (comment, substitution and end of command in RMAN)
  [[ "$1" =~ [[:space:]\"\'\&\;#\\\`] ]] && return 1
  return 0
}

phase_1() {
  phase_header 1 "Connect to the primary"
  run_step 1.1 check "Root and tools on this server" c_1_1
  # 1.2, 1.3 and 1.5 only read (or ask a password): no [y] question for them
  run_step 1.2 ask   "Connect to the primary over ssh" c_1_2 d_1_2
  run_step 1.3 ask   "Read the primary configuration (read-only)" c_1_3 d_1_3
  # without the primary configuration no other step can do anything
  [[ $DISCOVERED -eq 1 ]] || fatal "Nothing else can run without steps 1.2 and 1.3 (ssh connection, primary configuration).
Fix the problem shown above, then run the script again."
  # [i] at 1.2 gave another address: another database there means another standby (its records are set aside)
  if [[ -n "$OLD_PRIMARY_UNIQUE" && -n "$PRIMARY_UNIQUE" && "${OLD_PRIMARY_UNIQUE^^}" != "${PRIMARY_UNIQUE^^}" ]]; then
    set_aside_state "${OLD_PRIMARY_UNIQUE}_$RUN_ID"; say "This is another primary database: $PRIMARY_UNIQUE (before: $OLD_PRIMARY_UNIQUE)."; say "The records of the old setup are set aside, not deleted."
  fi
  OLD_PRIMARY_UNIQUE=""
  run_step 1.6 check "Oracle version supported on this Oracle Linux" c_1_6
  run_step 1.4 ask   "Standby settings" c_1_4 d_1_4
  # a 1.6 problem that the new settings solved (RU_DIR set in 1.4): checked again, quietly
  if [[ -n "${STEP_RESULT[1.6]:-}" && "${STEP_RESULT[1.6]}" != OK && "$MODE" == "run" ]] && c_1_6 >/dev/null 2>&1; then
    ok_lines "Step 1.6 is fine now with the new settings"; record 1.6 OK
  fi
  run_step 1.5 ask   "sys password" c_1_5 d_1_5
  # nothing below works without these
  if [[ $DISCOVERED -ne 1 || $SETTINGS_ACCEPTED -ne 1 ]]; then
    [[ "$MODE" == "check" && $DISCOVERED -eq 1 ]] || fatal "Nothing else can run without steps 1.2, 1.3 and 1.4 (connection, primary configuration, settings).
Run the script again."
  fi
  build_envs_if_possible
  # (only useful while the long installs of phase 3 are still ahead)
  if [[ "$MODE" == "run" && -z "$ONLY_PHASE" && -z "$FROM_STEP" ]] && ! phase4_all_done && [[ "$(phase_done_result 3)" != "DONE" ]]; then
    say "Phase 4 (on the primary) needs nothing from this server."
    say "You can do it now, before the long software installs."
    CUR_STEP=""
    ask_choice "[4] Do phase 4 (primary) first   [c] Continue in order (phase 4 after the software)   [q] Quit" "4cq"

    case "$ANSWER" in 4) PHASE4_FIRST=1 ;; q) user_stop "Stopped by you" ;; esac
  fi
}
phase4_all_done() { local i; load_progress; for i in 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.9; do case "${LAST_RESULT[$i]:-}" in OK|DONE_BY_YOU) ;; *) return 1 ;; esac; done; return 0; }

build_envs_if_possible() { users_ok && build_envs; return 0; }
