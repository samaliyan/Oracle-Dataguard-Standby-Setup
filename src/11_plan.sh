#------------------------------------------------------------------------------
# The exact commands of a step ("Will run")
#
#   A check function fills one list with cp_add; run_step shows that list before
#   [y], and the do function runs the SAME list (cp_run, or cp_run_one for one
#   entry of it). What is shown is what runs, and every command is logged.
#
#   cp_add ROLE CMD [INPUT] [TIMEOUT]
#     ROLE    root | grid | oracle (the real user names and their environment are used)
#     CMD     one shell command line, run with bash -c as that user. Never a password in it.
#     INPUT   text given on its standard input (SQL, RMAN commands, the body of a file).
#             Passwords may be in it: on the screen and in the log they are *****.
#     TIMEOUT seconds (default 600): a guard of the script, not part of the command.
#------------------------------------------------------------------------------
declare -a CP_ROLE=() CP_CMD=() CP_IN=() CP_TO=()
CP_FILE=""          # the file with the full list, when it is too long for the screen
CP_SHOW_MAX=14      # more lines than this: the first lines on the screen, all of them in a file
cp_reset() { CP_ROLE=(); CP_CMD=(); CP_IN=(); CP_TO=(); CP_FILE=""; }
cp_add() { CP_ROLE+=("$1"); CP_CMD+=("$2"); CP_IN+=("${3:-}"); CP_TO+=("${4:-600}"); }
# cp_add_file PATH MODE CONTENT: "write this file" (as root; the old file is kept as a backup; --undo puts it back).
# Shown with its whole content, written exactly so.
cp_add_file() { CP_ROLE+=("file"); CP_CMD+=("$1"); CP_IN+=("$3"); CP_TO+=("$2"); }
cp_any() { [[ ${#CP_CMD[@]} -gt 0 ]]; }
cp_user() { case "$1" in grid) printf '%s' "$GRID_USER" ;; oracle) printf '%s' "$ORACLE_USER" ;; *) printf 'root' ;; esac; }   # (file: root)
cp_env() {
  case "$1" in
    grid) printf 'ORACLE_HOME=%s  ORACLE_SID=+ASM' "$GRID_HOME" ;;
    oracle) printf 'ORACLE_HOME=%s  ORACLE_SID=%s' "$DB_HOME" "$STANDBY_SID" ;;
  esac
}
cp_entry_text() {
  # entry $1: the command, and its input as a here-document (the way it is given to the command)
  local i=$1 l
  if [[ "${CP_ROLE[$i]}" == file ]]; then
    printf "write %s (mode %s; a backup of the old file is kept):\n" "${CP_CMD[$i]}" "${CP_TO[$i]}"
    while IFS= read -r l || [[ -n "$l" ]]; do printf '  %s\n' "$l"; done <<< "${CP_IN[$i]}"
    return 0
  fi
  printf '%s' "${CP_CMD[$i]}"
  if [[ -n "${CP_IN[$i]}" ]]; then
    printf " <<'EOF'\n"
    while IFS= read -r l || [[ -n "$l" ]]; do printf '  %s\n' "$l"; done <<< "${CP_IN[$i]}"
    printf 'EOF\n'
  else printf '\n'; fi
}
cp_text() {
  # the whole list: grouped by user, with the environment each group runs in
  local i prev="" r e
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    r=${CP_ROLE[$i]}; [[ "$r" == file ]] && r=root      # a file is written by root
    if [[ "$r" != "$prev" ]]; then
      e=$(cp_env "$r")
      printf 'as %s%s\n' "$(cp_user "$r")" "${e:+   ($e)}"
      prev=$r
    fi
    cp_entry_text "$i" | sed 's/^/  /'
  done
}
cp_env_lines() {
  # the environment of role $1 as export lines (the same values the script gives the command: ORA_ENV / GRID_ENV)
  local -a e=(); local v
  case "$1" in
    oracle) e=(${ORA_ENV[@]+"${ORA_ENV[@]}"}); [[ ${#e[@]} -gt 0 ]] || e=("ORACLE_HOME=$DB_HOME" "ORACLE_SID=$STANDBY_SID" "PATH=$DB_HOME/bin:/usr/bin:/bin") ;;
    grid)   e=(${GRID_ENV[@]+"${GRID_ENV[@]}"}); [[ ${#e[@]} -gt 0 ]] || e=("ORACLE_HOME=$GRID_HOME" "ORACLE_SID=+ASM" "PATH=$GRID_HOME/bin:/usr/bin:/bin") ;;
  esac
  for v in ${e[@]+"${e[@]}"}; do printf 'export %s=%q\n' "${v%%=*}" "${v#*=}"; done
}
cp_script_view() {
  # the whole list as a script that can be run as root (bash FILE) or pasted block by block into a root shell:
  # here-documents and their end words at column 0, a file as  cat > FILE <<'EOF' ... EOF  and  chmod MODE FILE,
  # the commands of another user in a  runuser -u USER -- bash -s  block with the same environment the script uses.
  # Never "exit" in the shell of the user: a guard that ends with exit runs in a subshell (paste_safe).
  local i r prev="" u e cmd
  printf '#!/bin/bash\n'
  printf '# Step %s  %s\n' "${CUR_STEP:-?}" "${STEP_TITLE[${CUR_STEP:-x}]:-}"
  printf '# The commands of "Will run", in the order the script runs them (it stops at the first one that fails).\n'
  printf '# Written %s by dg_standby_setup.sh %s. Run as root on %s:  bash %s\n' "$(ts)" "$SCRIPT_VERSION" "$(hostname -s 2>/dev/null)" "${CP_FILE:-FILE}"
  printf '# When you paste it by hand, paste one block at a time and check its output before the next one.\n'
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    r=${CP_ROLE[$i]}; [[ "$r" == file ]] && r=root
    if [[ "$r" != "$prev" ]]; then
      [[ "$prev" == grid || "$prev" == oracle ]] && printf 'END_AS_%s\n' "${prev^^}"
      printf '\n# ---- as %s\n' "$(cp_user "$r")"
      if [[ "$r" != root ]]; then
        # the commands of the block read the script as their input: those without input of their own get /dev/null
        printf "runuser -u %s -- bash -s <<'END_AS_%s'\n" "$(cp_user "$r")" "${r^^}"
        printf 'cd / || exit 1\n'
        cp_env_lines "$r"
      fi
      prev=$r
    fi
    if [[ "${CP_ROLE[$i]}" == file ]]; then
      # (the script keeps the old file first, as here)
      printf 'if [ -e %s ]; then cp -p -- %s "%s.bak_$(date +%%Y%%m%%d_%%H%%M%%S)"; fi\n' "${CP_CMD[$i]}" "${CP_CMD[$i]}" "${CP_CMD[$i]}"
      printf "cat > %s <<'EOF'\n%s\nEOF\n" "${CP_CMD[$i]}" "${CP_IN[$i]}"
      printf 'chmod %s %s\n' "${CP_TO[$i]}" "${CP_CMD[$i]}"
      continue
    fi
    cmd=${CP_CMD[$i]}
    if [[ -n "${CP_IN[$i]}" ]]; then cmd+=$' <<\'EOF\'\n'"${CP_IN[$i]}"$'\nEOF'
    elif [[ "$r" != root ]]; then cmd+=" < /dev/null"; fi
    # (inside a runuser block an exit ends that block only: the guard stays as it is)
    if [[ "$r" == root ]]; then printf '%s\n' "$cmd" | paste_safe; else printf '%s\n' "$cmd"; fi
  done
  [[ "$prev" == grid || "$prev" == oracle ]] && printf 'END_AS_%s\n' "${prev^^}"
  return 0
}
cp_show() {
  # before [y]: the list under "Will run" (masked); a long list: its first lines, and the file with all of it
  # (the file is a script that runs as it is: see cp_script_view)
  cp_any || return 0
  local txt n sv
  txt=$(cp_text | mask_pw)
  n=$(grep -c '' <<< "$txt")
  if [[ $n -gt $CP_SHOW_MAX ]]; then
    CP_FILE="$LOG_DIR/commands_${CUR_STEP:-x}_$RUN_ID.txt"
    sv=$(cp_script_view | mask_pw)
    [[ "$sv" == *'*****'* ]] && sv=$(sed '2a\
# Passwords are shown as *****: put the real ones in before you run it.' <<< "$sv")
    if ( umask 077; printf '%s\n' "$sv" > "$CP_FILE" ) 2>/dev/null; then
      txt="$(head -n $((CP_SHOW_MAX - 2)) <<< "$txt")"$'\n'"... $((n - CP_SHOW_MAX + 2)) more lines. All of them, as a script:  $CP_FILE"
    else CP_FILE=""; fi
  fi
  printf '%s\n' "$txt" | block "Will run"
}
cp_role_run() {
  # $1 role, rest = command: run as that user, in its environment
  local r=$1; shift
  case "$r" in
    grid) as_grid "$@" ;;
    oracle) as_oracle "$@" ;;
    # root: the PATH of root that runs this script (its system tools), a clean environment otherwise
    # The proxy settings of this environment are passed on (yum / dnf need them); their values are never on a
    # command line or in the log.
    *) local -a pv=(); local v
       for v in http_proxy https_proxy ftp_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY; do
         [[ -n "${!v:-}" ]] && pv+=("$v=${!v}")
       done
       ( cd / && env -i "PATH=$PATH" "LANG=C" "LC_ALL=C" "HOME=/root" ${pv[@]+"${pv[@]}"} "$@" 9>&- ) ;;
  esac
}
cp_exec() {
  # run entry $1: "Running as <user>: <command>" on the screen, the full command, its input and output in the log.
  # Output in RUN_OUT, exit code returned.
  local i=$1 rc=0 tmp first inp=""
  if [[ "${CP_ROLE[$i]}" == file ]]; then
    say "${C_D}Writing ${CP_CMD[$i]}${C_N}"
    local f=${CP_CMD[$i]}
    # only a missing folder is made: install -d would also reset the mode of one that exists
    [[ -d "$(dirname "$f")" ]] || install -d -m 755 -- "$(dirname "$f")" || { RUN_OUT="cannot make the folder of $f"; return 1; }
    backup_file "$f" || { RUN_OUT="cannot keep a backup of $f"; return 1; }
    if printf '%s\n' "${CP_IN[$i]}" | write_as root "$f" "${CP_TO[$i]}"; then rc=0; RUN_OUT=""; else rc=1; RUN_OUT="cannot write $f"; fi
    command -v restorecon >/dev/null 2>&1 && restorecon "$f" 2>/dev/null
    { printf 'write %s (mode %s), exit code %s:\n' "$f" "${CP_TO[$i]}" "$rc"; printf '%s\n' "${CP_IN[$i]}"; } | mask_pw | log_block "RUN"
    return "$rc"
  fi
  first=$(head -n 1 <<< "${CP_CMD[$i]}")
  # the input of sqlplus / rman / asmcmd is part of what runs: its first line is shown with the command
  if [[ -n "${CP_IN[$i]}" ]]; then
    local nl; nl=$(grep -c '' <<< "${CP_IN[$i]}")
    inp="  ->  $(head -n 1 <<< "${CP_IN[$i]}")"; [[ $nl -gt 1 ]] && inp+="  (and $((nl - 1)) more lines)"
  fi
  say "${C_D}Running as $(cp_user "${CP_ROLE[$i]}"):${C_N} $(mask_pw <<< "$first$inp")"
  tmp=$(mktemp /tmp/dg_out.XXXXXXXX) || { RUN_OUT="cannot create a temporary file"; return 1; }
  CLEANUP_FILES+=("$tmp")
  if [[ -n "${CP_IN[$i]}" ]]; then
    # the input reaches the command through a pipe (printf is a builtin): never in an argument or a file
    printf '%s\n' "${CP_IN[$i]}" | cp_role_run "${CP_ROLE[$i]}" timeout -k 30 "${CP_TO[$i]}" bash -c "${CP_CMD[$i]}" > "$tmp" 2>&1 || rc=$?
  else
    cp_role_run "${CP_ROLE[$i]}" timeout -k 30 "${CP_TO[$i]}" bash -c "${CP_CMD[$i]}" > "$tmp" 2>&1 < /dev/null || rc=$?
  fi
  RUN_OUT=$(cat -- "$tmp"); rm -f -- "$tmp"
  # sqlplus ends with 0 also after an error: an ORA- or SP2- line in its output is a failure
  # (sqlplus by name or by a full path that ends in /sqlplus)
  [[ $rc -eq 0 && ( "$first" == sqlplus* || "$first" =~ ^[^[:space:]]*/sqlplus([[:space:]]|$) ) ]] && grep -qE '^(ORA|SP2)-[0-9]+' <<< "$RUN_OUT" && rc=1
  { printf 'as %s: ' "$(cp_user "${CP_ROLE[$i]}")"; cp_entry_text "$i"; printf -- '--- output ---\n%s\n(exit code %s)\n' "$RUN_OUT" "$rc"; } | log_block "RUN"
  return "$rc"
}
cp_run() {
  # all entries in order; the first that fails stops the list (what ran is said, the rest is not run)
  local i
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    if ! cp_exec "$i"; then
      bad "This command failed:  $(head -n 1 <<< "${CP_CMD[$i]}" | mask_pw)"$'\n'"$(tail -n 4 <<< "$RUN_OUT" | mask_pw)"
      [[ $((i + 1)) -lt ${#CP_CMD[@]} ]] && say "The commands after it were not run."
      return 1
    fi
  done
  return 0
}
cp_find() {
  # the index of the entry with role $1 and a command line starting with $2 (the do function runs that one)
  local i
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    [[ "${CP_ROLE[$i]}" == "$1" && "${CP_CMD[$i]}" == "$2"* ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}
cp_run_one() {
  # $1 role, $2 the start of a command that is in the shown list: that entry runs. Not in the list: refused
  # (what runs must have been shown).
  local i
  i=$(cp_find "$1" "$2") || { _log FAIL "not in the shown list: as $1: $2"; bad "Internal error: '$2' was not shown before, so it is not run."; return 1; }
  cp_exec "$i"
}

# ---- commands the user runs: a long list becomes a short script file (the console may not allow pasting) ----
SHORT_DIR="${DG_SHORT_DIR:-/root/dg}"
short_script() {
  # $1 name (letters, digits, dots), stdin = the commands. Writes $SHORT_DIR/<name> (root only, mode 700) and prints
  # its path. The first line checks the host: the file refuses to run on another server.
  local name=$1 f
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if [[ ! -d "$SHORT_DIR" ]]; then ( umask 077; mkdir -p -- "$SHORT_DIR" ) || return 1; fi
  # root's own folder that nobody else can write (else another user could swap the file before it runs)
  local own mode; read -r own mode <<< "$(stat -c '%U %a' -- "$SHORT_DIR" 2>/dev/null)"
  [[ ! -L "$SHORT_DIR" && "$own" == root && "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode & 8#022) == 0 )) || return 1
  f="$SHORT_DIR/$name"
  rm -f -- "$f"
  ( umask 077; set -C
    { printf '#!/bin/bash\n# written by dg_standby_setup.sh %s on %s (step %s)\n' "$SCRIPT_VERSION" "$(ts)" "${CUR_STEP:-}"
      printf '[ "$(hostname -s)" = "%s" ] || { echo "This file is for the server %s, not for $(hostname -s). Nothing was done."; exit 1; }\n' "$(hostname -s)" "$(hostname -s)"
      printf 'set -x\n'
      cat
    } > "$f" ) || return 1
  chmod 700 -- "$f" || return 1
  printf '%s' "$f"
}
cp_script_text() {
  # the whole list as a root shell script (for short_script): each entry runs as its user, in its environment;
  # the first command that fails stops the script (set -e)
  local i r u h s
  printf 'set -e\n'
  for ((i = 0; i < ${#CP_CMD[@]}; i++)); do
    r=${CP_ROLE[$i]}
    if [[ "$r" == file ]]; then
      printf "\ninstall -m %s /dev/stdin %s <<'EOF'\n%s\nEOF\n" "${CP_TO[$i]}" "${CP_CMD[$i]}" "${CP_IN[$i]}"; continue
    fi
    case "$r" in
      grid)   u=$GRID_USER;   h=$GRID_HOME; s=+ASM ;;
      oracle) u=$ORACLE_USER; h=$DB_HOME;   s=$STANDBY_SID ;;
      *)      u=root ;;
    esac
    printf '\n'
    if [[ "$u" == root ]]; then printf '%s' "${CP_CMD[$i]}"
    else printf "runuser -u %s -- env -i HOME=/ LANG=C ORACLE_HOME=%s ORACLE_SID=%s PATH=%s/bin:/usr/bin:/bin timeout %s bash -c '%s'" "$u" "$h" "$s" "$h" "${CP_TO[$i]}" "${CP_CMD[$i]//\'/\'\\\'\'}"; fi
    if [[ -n "${CP_IN[$i]}" ]]; then printf " <<'EOF'\n%s\nEOF\n" "${CP_IN[$i]}"; else printf '\n'; fi
  done
}
