#------------------------------------------------------------------------------
# Screen layout (a terminal of at least 80 x 24, the default when the script runs in one):
#
#   top        a fixed map: every phase with its done / total steps, the totals, the log file.
#              9 rows; 4 rows on a terminal of less than 30 rows; 6 rows on a very wide one.
#   below      the current step only: the steps of this phase done before it (one line each; the step just
#              done also with its output while there is room), then the step itself. A retry starts it
#              again on a clean area ("attempt 2").
#
#   A step that does not fit loses its less important lines first: the earlier steps, the Details, the end
#   of the Plan, the middle of a command list. Each gap says "… N more lines: d shows all". The step title,
#   the Status, the start of the Plan, where and as whom the commands run, the first and the last commands
#   and the question always stay.
#   Command lines are never broken by the script: a long one is wrapped by the terminal, so a copy of it is
#   still one line. Only text is wrapped (at a space).
#
#   At any question: l lists every step (a number then shows its details), d shows the details of
#   the current step, h the help. They open on a separate screen; closing it returns to the step.
#   A long job (installer, root script, RMAN) shows one live line instead of its output.
#
#   Plain output (as before) without a terminal, in a smaller one, with --plain or DG_PLAIN=1,
#   and always for --health.
#------------------------------------------------------------------------------
UI=0                  # 1 = the screen layout is on
UI_ROWS=0; UI_COLS=0
UI_TOP=9              # rows of the fixed map (ui_set_top: 9, 4 on a low terminal, 6 on a very wide one)
UI_MAP=full           # full | compact | wide
UI_PHASE=""           # the phase the run is in (for the map)
UI_PREV_PHASE=""      # the phase that ran before it (phase 4 can run right after phase 1)
UI_ATTEMPT=1          # attempt of the current step (shown from 2 on)
UI_RETRY=0            # set where the user answered "try again": the step starts again on a clean area
UI_KEEP_ONCE=0        # the first step keeps what was printed before it (start of the run)
UI_LIVE=0             # a live line ("checking ...") is on the screen and is cleared by the next output
UI_ALT=0              # the separate screen (list, details, help) is open
UI_HDR_BUSY=0         # the map is being drawn
UI_SEC=""             # the block the last line of the step text belongs to: cmd ("Will run"), text (Status, Plan, ...)
PLAIN_OPT=0           # --plain
declare -A STEP_WHEN=()
PHASE_SHORT=("" "Connect" "This server" "Software" "Primary" "Listener, TNS" "Password, TDE" "Empty instance" "Copy (RMAN)" "Redo apply" "Health check")

ui_size() {
  local s; s=$(stty size < /dev/tty 2>/dev/null) || return 1
  UI_ROWS=${s% *}; UI_COLS=${s#* }
  num "$UI_ROWS" && num "$UI_COLS"
}
ui_wanted() {
  [[ "${DG_PLAIN:-0}" == 1 || $PLAIN_OPT -eq 1 || ${HEALTH:-0} -eq 1 ]] && return 1
  [[ -t 1 && -n "$C_N" && "$PROMPT_IN" == /dev/tty ]] || return 1
  case "${TERM:-dumb}" in dumb|unknown|"") return 1 ;; esac
  ui_size || return 1
  [[ $UI_ROWS -ge 24 && $UI_COLS -ge 80 ]]
}
ui_set_top() {
  # the size of the map: 4 rows below 30 rows (the step gets the room), the 10 phases in 2 rows when they fit
  if [[ $UI_ROWS -lt 30 ]]; then UI_MAP=compact; UI_TOP=4
  elif [[ $UI_COLS -ge 132 ]]; then UI_MAP=wide; UI_TOP=6
  else UI_MAP=full; UI_TOP=9; fi
}
ui_region() {
  # the area under the map scrolls; the map stays (the cursor is kept where it is)
  printf '\e7\e[%d;%dr\e8' $((UI_TOP + 1)) "$UI_ROWS"
}
ui_start() {
  ui_wanted || return 0
  UI=1; load_progress
  ui_set_top
  printf '\e[H\e[2J'
  ui_region; ui_header
  printf '\e[%d;1H' $((UI_TOP + 1))
  UI_USED=0
  # said once: what leaves the step area is not in the terminal's scrollback (a scroll region), the log has it
  ui_out 6 "$(printf '    %s%s Screen layout: output that leaves this area is not kept by the terminal. All of it is in the log (top line); d shows a step again.%s' "$C_D" "$S_WAIT" "$C_N")"
  UI_KEEP_ONCE=1
  _log INFO "screen layout on (${UI_COLS}x${UI_ROWS})"
  return 0
}
ui_end() {
  # back to plain output (end of the run, a stop, a terminal made too small): the whole screen scrolls again
  [[ $UI -eq 1 ]] || return 0
  ui_live_clear
  UI=0
  [[ $UI_ALT -eq 1 ]] && { printf '\e[?1049l'; UI_ALT=0; }
  # lines still collected for the step area are printed as they are
  [[ $UI_BUF_ON -eq 1 ]] && { UI_BUF_ON=0; tr -d '\001' < "$UI_BUF_FILE" 2>/dev/null; : > "$UI_BUF_FILE" 2>/dev/null; }
  printf '\e[r\e[?25h\e[%d;1H\n' "$UI_ROWS"
  return 0
}
ui_check_size() {
  # a resized terminal: the map is drawn for the new size, or the plain output takes over when it is too small
  [[ $UI -eq 1 ]] || return 1
  local r=$UI_ROWS c=$UI_COLS t=$UI_TOP
  ui_size || return 0
  [[ $UI_ROWS -eq $r && $UI_COLS -eq $c ]] && return 0
  if [[ $UI_ROWS -lt 24 || $UI_COLS -lt 80 ]]; then ui_end; say "The terminal is now too small for the screen layout: plain output from here on."; return 1; fi
  ui_set_top
  ui_region
  if [[ $UI_TOP -ne $t && $UI_ALT -eq 0 ]]; then
    # another map size: the screen is drawn again (the step area starts empty, d shows the step)
    printf '\e[H\e[2J'; ui_region; printf '\e[%d;1H' $((UI_TOP + 1)); UI_USED=0
    [[ $UI_HDR_BUSY -eq 1 ]] || ui_header
  fi
  return 0
}

ui_dur() {
  # $1 seconds -> "45 s", "6 min 12 s", "2 h 05 min"
  local s=$1
  if [[ $s -lt 60 ]]; then printf '%d s' "$s"
  elif [[ $s -lt 3600 ]]; then printf '%d min %d s' $((s / 60)) $((s % 60))
  else printf '%d h %02d min' $((s / 3600)) $((s % 3600 / 60)); fi
}
ui_spaces() { printf '%*s' "$1" ''; }
ui_vislen() { local t=$1; t=$(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' <<< "$t"); printf '%d' "${#t}"; }
UI_S=""; UI_N=0
ui_strip() {
  # $1 -> UI_S: the text without its color codes. No subshell (used for every line of a step), and no regex:
  # the callers of say, ok, block ... keep their BASH_REMATCH.
  local s=$1 out="" r
  while [[ "$s" == *$'\e['* ]]; do
    out+=${s%%$'\e['*}; r=${s#*$'\e['}
    r=${r#"${r%%[!0-9;?]*}"}; s=${r:1}
  done
  UI_S=$out$s
}
ui_nrows() {
  # $1 line -> UI_N: the rows it takes on the screen (a line longer than the width is wrapped by the terminal)
  if [[ ${#1} -lt $UI_COLS ]]; then UI_N=1; return 0; fi
  ui_strip "$1"; UI_N=${#UI_S}; [[ $UI_N -le 0 ]] && UI_N=1
  UI_N=$(( (UI_N - 1) / UI_COLS + 1 ))
}
ui_rows() { ui_nrows "$1"; printf '%d' "$UI_N"; }   # rows that line $1 takes on the screen

# ---- printing (used by say, ok, bad, warn, block, hint) ----
ui_fold() {
  # stdin lines wrapped to the terminal width at a space (the spacing of each line is kept);
  # $1 = indent of the continued part (at least the indent of the line itself), $2 = lines with this many
  # leading spaces or more are never wrapped (default: none).
  # Never wrapped by the script either: command lines (under "Will run" and "How" at 15 columns or more, and
  # inside a "── Run on ... ──" box), and a word longer than the line (a path). The terminal wraps them, so a
  # copy is still one line.
  # bytes in every awk (LC_ALL=C): a UTF-8 continuation byte (the line and mark characters) takes no column
  LC_ALL=C awk -v w="$((UI_COLS - 1))" -v ind="$1" -v nf="${2:-100000}" '
    function vis(s,   t, n) { t = s; gsub(/\033\[[0-9;?]*[a-zA-Z]/, "", t); n = length(t); return n - gsub(/[\200-\277]/, "", t) }
    function sp(n,   s) { s = ""; while (n-- > 0) s = s " "; return s }
    {
      s = $0; t = s; gsub(/\033\[[0-9;?]*[a-zA-Z]/, "", t); match(t, /^ */); lead = RLENGTH
      # which part of a step or help text the line is in
      if (t ~ /^    (\342\224\200\342\224\200|--) [^ ]/ && t !~ /^    [^ ]+ Help /) { box = 1; cmd = 0; print s; next }
      if (t ~ /^    (\342\224\200\342\224\200\342\224\200\342\224\200|----)/) { box = 0; cmd = 0; print s; next }
      if (t ~ /^    (Status|Plan|Details|Fix) / || t ~ /^      (Where|Why|Expect|Problems) /) { box = 0; cmd = 0 }
      else if (t ~ /^    Will run/) { box = 0; cmd = 1 }
      else if (t ~ /^      How /) { box = 0; cmd = 1; print s; next }
      else if (t != "" && lead < 13 && !box) cmd = 0
      if (box || (cmd && lead >= 15) || lead >= nf || vis(s) <= w) { print s; next }
      # the continued part: under the text of the line (a log line "hh:mm:ss  tag  text": under the text)
      ci = length(ind); if (lead > ci) ci = lead
      if (match(t, /^  [0-9][0-9]:[0-9][0-9]:[0-9][0-9]  [a-z:]+ +/)) ci = RLENGTH
      if (ci + 20 > w) { print s; next }
      cind = sp(ci)
      while (vis(s) > w) {
        cut = 0; v = 0; i = 1; L = length(s)
        while (i <= L && v < w) {
          c = substr(s, i, 1)
          if (c == "\033" && match(substr(s, i), /^\033\[[0-9;?]*[a-zA-Z]/)) { i += RLENGTH; continue }
          if (c ~ /[\200-\277]/) { i++; continue }
          v++
          if (c == " " && v > lead + 1) cut = i
          i++
        }
        # no space to cut at (a long path): the terminal wraps the rest, a word is never broken
        if (cut == 0) break
        print substr(s, 1, cut - 1)
        rest = substr(s, cut + 1); sub(/^ +/, "", rest)
        s = cind rest; lead = ci
      }
      print s
    }'
}
ui_out() {
  # $1 indent of continued lines, $2 text (may have several lines): printed, long text lines wrapped.
  # Command lines are not wrapped: the lines under "Will run" (15 columns or more), command lines in a Plan
  # (15 or more), and "Running as <user>: <command>".
  ui_live_clear
  local l x lead ind nf
  ind=$(ui_spaces "$1")
  while IFS= read -r l || [[ -n "$l" ]]; do
    # the block a line belongs to: block() prints "    Label    text", then its other lines at 13 columns
    if [[ "$l" == "    ${C_D}"* ]]; then
      x=${l:$((4 + ${#C_D})):8}
      case "$x" in "Will run") UI_SEC=cmd ;; "Status  "|"Plan    "|"Details "|"Fix     ") UI_SEC=text ;; *) UI_SEC="" ;; esac
    elif [[ "$l" != "             "* ]]; then UI_SEC=""; fi
    x=${l%%[! ]*}; lead=${#x}; nf=0
    [[ $lead -ge 15 ]] && nf=1
    [[ "$l" == "      ${C_D}Running as "* ]] && nf=1
    if [[ $nf -eq 1 || ${#l} -lt $((UI_COLS - 1)) ]]; then ui_emit "$l"; continue; fi
    x=0
    while IFS= read -r l; do
      if [[ $x -eq 0 ]]; then ui_emit "$l"; x=1; else ui_emit "$l" cont; fi
    done < <(printf '%s\n' "$l" | ui_fold "$ind")
  done <<< "$2"
}

# ---- the step area: what a step prints before its question is laid out so that nothing scrolls away unseen ----
#   From the start of a step (or of a phase) to its first question, the lines are kept (UI_BUF) instead of printed.
#   ui_flush prints them. When they do not fit between the map and the question: a clean area, then lines left out
#   by importance (ui_flush), each gap marked "… N more lines: d shows all" (d shows the whole text).
#   Flushed at every question, before an action, at the end of a step, and when the screen layout ends.
#   The output of the action (after the question) is printed at once. It is kept ($UI_BUF_FILE.res) for the next step,
#   which shows it under the one-line result of this step while there is room. When it would push the step
#   title off the area, the area starts again with the title, a ✘ line and the last lines (ui_redraw).
UI_BUF_ON=0; UI_USED=0                   # UI_USED: rows printed in the step area since it was last cleared
UI_BUF_FILE=""                           # the collected lines (a file: block, hint and the command boxes run in a pipe);
                                         # a wrapped part of a line starts with \001 (it stays with its line)
UI_TITLE_IDX=-1; UI_CUT=0                # the step title in the collection; 1 = the text of this step was cut (d shows all)
UI_TITLE_TXT=""                          # the step title line (shown again by ui_redraw)
UI_REC_A=-1; UI_REC_B=-1; UI_REC_TXT=""  # the lines of the earlier steps in the collection (from A to before B), their one-line form
UI_RES_ID=""                             # the step whose action printed the lines in $UI_BUF_FILE.res (after its question)
UI_RES_A=-1; UI_RES_B=-1                 # those lines in the collection of the next step
# hint, block and the command boxes often run in a pipe (a subshell): what they print is counted in files
# ($UI_BUF_FILE.res: the lines, $UI_BUF_FILE.used: "+N" / "=N" changes of UI_USED), read by the main shell
ui_used() {
  # $1 + or =, $2 rows: UI_USED changed; from a subshell also in the file. ui_used sync: the main shell applies the file
  local f=${UI_BUF_FILE:+$UI_BUF_FILE.used} c v
  if [[ "$1" == sync ]]; then
    [[ -n "$f" && -s "$f" ]] || return 0
    while IFS= read -r c; do v=${c:1}; num "$v" || continue; [[ "${c:0:1}" == = ]] && UI_USED=$v || UI_USED=$((UI_USED + v)); done < "$f"
    [[ $BASHPID == $$ ]] && : > "$f"
    return 0
  fi
  if [[ "$1" == = ]]; then UI_USED=$2; else UI_USED=$((UI_USED + $2)); fi
  [[ -n "$f" ]] || return 0
  if [[ $BASHPID != $$ ]]; then printf '%s%d\n' "$1" "$2" >> "$f" 2>/dev/null
  elif [[ "$1" == = ]]; then : > "$f" 2>/dev/null; fi
  return 0
}
ui_emit() {
  # one line for the step area: kept while the step text is collected, else printed. $2 = cont: a wrapped part.
  local l=$1
  # labels that carry meaning are not dim: "Will run" (checked before y), a DOWNTIME or WARNING line in a box
  if [[ -n "$C_D" ]]; then
    [[ "$l" == "    ${C_D}Will run${C_N}"* ]] && l="    ${C_C}${C_W}Will run${C_N}${l#"    ${C_D}Will run${C_N}"}"
    case "$l" in
      "      ${C_D}-- DOWNTIME"*|"      ${C_D}# DOWNTIME"*|"      ${C_D}-- WARNING"*|"      ${C_D}# WARNING"*) l="      ${C_Y}${C_W}${l#"      ${C_D}"}" ;;
    esac
  fi
  if [[ $UI_BUF_ON -eq 1 && -t 1 ]] && printf '%s%s\n' "${2:+$'\001'}" "$l" >> "$UI_BUF_FILE" 2>/dev/null; then return 0; fi
  ui_used sync
  ui_nrows "$l"
  # the step title would leave the area: it starts again (title, the ✘ line, the last lines)
  # (only for the output of the current step's action: UI_USED >= UI_ROWS means "area full, not counted")
  if [[ $UI -eq 1 && $UI_ALT -eq 0 && -n "$UI_TITLE_TXT" && -t 1 && -s "$UI_BUF_FILE.res" && "$UI_RES_ID" == "${CUR_STEP:-}" \
        && $UI_USED -lt $UI_ROWS && $((UI_USED + UI_N)) -gt $((UI_ROWS - UI_TOP - 1)) ]]; then
    ui_redraw; ui_nrows "$l"
  fi
  printf '%s\n' "$l"
  ui_used + "$UI_N"
  [[ $UI -eq 1 && -n "$UI_BUF_FILE" ]] && printf '%s\n' "$l" >> "$UI_BUF_FILE.res" 2>/dev/null
  return 0
}
ui_redraw() {
  # the output of an action fills the area: a clean area with the step title, the last ✘ line with the 2 lines
  # under it (when they are not among the last lines), and the last lines
  local area=$((UI_ROWS - UI_TOP)) i from n used=0 budget fl=-1 fn=0
  local -a R=(); mapfile -t R < "$UI_BUF_FILE.res" 2>/dev/null; n=${#R[@]}
  ui_area_clear
  printf '%s  %s%s continued%s\n' "$UI_TITLE_TXT" "$C_D" "$S_DOT" "$C_N"; ui_nrows "$UI_TITLE_TXT  $S_DOT continued"; used=$UI_N
  for ((i = n - 1; i >= 0; i--)); do [[ "${R[$i]}" == "    ${C_R}${S_BAD}${C_N} "* ]] && { fl=$i; break; }; done
  if [[ $fl -ge 0 ]]; then fn=1; while [[ $fn -lt 3 && $((fl + fn)) -lt $n && "${R[$((fl + fn))]}" == "      "* ]]; do fn=$((fn + 1)); done; fi
  budget=$((area / 2 - used - 2)); [[ $budget -lt 3 ]] && budget=3
  from=$n
  while [[ $from -gt 0 ]]; do ui_nrows "${R[$((from - 1))]}"; [[ $UI_N -gt $budget ]] && break; budget=$((budget - UI_N)); from=$((from - 1)); done
  # (a ✘ line just above the last lines: shown from it)
  [[ $fl -ge 0 && $fl -lt $from && $((fl + fn)) -gt $from ]] && from=$fl
  if [[ $fl -ge 0 && $fl -lt $from ]]; then
    for ((i = fl; i < fl + fn; i++)); do printf '%s\n' "${R[$i]}"; ui_nrows "${R[$i]}"; used=$((used + UI_N)); done
  else fn=0; fi
  [[ $from -gt 0 ]] && { printf '    %s%s %d more lines: d shows all%s\n' "$C_D" "$S_WAIT" $((from - fn)) "$C_N"; used=$((used + 1)); }
  for ((i = from; i < n; i++)); do printf '%s\n' "${R[$i]}"; ui_nrows "${R[$i]}"; used=$((used + UI_N)); done
  UI_USED=$used
  # d now shows the step from the log (with this output), not the text before the question
  UI_CUT=0
}
ui_area_clear() { printf '\e[%d;1H\e[J' $((UI_TOP + 1)); UI_USED=0; }
ui_buf_n() { local n; n=$(grep -c '' "$UI_BUF_FILE" 2>/dev/null); printf '%d' "${n:-0}"; }   # lines collected so far
ui_buf_start() {
  # $1 = 1: a clean area first. Lines collected before (a phase intro) stay in the collection.
  [[ $UI -eq 1 ]] || return 0
  if [[ -z "$UI_BUF_FILE" ]]; then
    # a folder of its own (mode 700): the .cut / .res / .used files beside the text are not for other users to
    # read, and nobody can put a file of such a name there first
    local sd; sd=$(mktemp -d /tmp/dg_screen.XXXXXXXX 2>/dev/null) || { UI_BUF_FILE=""; return 0; }
    UI_BUF_FILE=$sd/text
    CLEANUP_FILES+=("$UI_BUF_FILE" "$UI_BUF_FILE.cut" "$UI_BUF_FILE.res" "$UI_BUF_FILE.used")
  fi
  if [[ "$1" == 1 ]]; then ui_area_clear; : > "$UI_BUF_FILE"; UI_REC_A=-1; UI_REC_B=-1; UI_RES_A=-1; UI_RES_B=-1
  elif [[ $UI_BUF_ON -eq 0 ]]; then : > "$UI_BUF_FILE"; UI_REC_A=-1; UI_REC_B=-1; UI_RES_A=-1; UI_RES_B=-1; fi
  UI_BUF_ON=1
}
ui_flush() {
  # (called before every question: the empty row and the question with its answer take two rows of the area)
  ui_used sync
  if [[ $UI_BUF_ON -ne 1 ]]; then [[ $UI -eq 1 && $UI_ALT -eq 0 ]] && ui_used + 2; return 0; fi
  UI_BUF_ON=0
  local -a raw=(); mapfile -t raw < "$UI_BUF_FILE" 2>/dev/null; : > "$UI_BUF_FILE" 2>/dev/null
  local n=${#raw[@]} i k l
  if [[ $n -eq 0 ]]; then [[ $UI -eq 1 ]] && UI_USED=$((UI_USED + 2)); return 0; fi
  if [[ $UI -ne 1 ]]; then printf '%s\n' "${raw[@]#$'\001'}"; return 0; fi
  ui_live_clear
  # units: a line with its wrapped parts (never cut apart)
  local -a ut=() ur=() uf=() uk=() uc=() ug=() ud=()
  k=-1
  for ((i = 0; i < n; i++)); do
    l=${raw[$i]}
    if [[ "$l" == $'\001'* && $k -ge 0 ]]; then l=${l#$'\001'}; ut[$k]+=$'\n'"$l"; ui_nrows "$l"; ur[$k]=$((ur[k] + UI_N)); continue; fi
    k=$((k + 1)); ut[$k]=${l#$'\001'}; ui_nrows "${ut[$k]}"; ur[$k]=$UI_N; uf[$k]=$i
  done
  local m=$((k + 1)) need=0
  for ((k = 0; k < m; k++)); do need=$((need + ur[k])); done
  local avail=$((UI_ROWS - UI_TOP - 2))           # the question needs two rows (an empty one and itself)
  printf '%s\n' "${ut[@]}" > "$UI_BUF_FILE.cut" 2>/dev/null     # the whole text, for d
  : > "$UI_BUF_FILE.res" 2>/dev/null; UI_RES_ID=${CUR_STEP:-}
  if [[ $((UI_USED + need)) -le $avail ]]; then
    printf '%s\n' "${ut[@]}"; UI_USED=$((UI_USED + need + 2)); UI_CUT=0; return 0
  fi
  ui_area_clear
  if [[ $need -le $avail ]]; then printf '%s\n' "${ut[@]}"; UI_USED=$((need + 2)); UI_CUT=0; return 0; fi

  # ---- too long: lines are left out by importance ----
  # kind (uk): title, res (the output of the step before), rec (the earlier steps), intro (before the title),
  #   blank, text (Status, Plan, Details), head (Will run / box heading), cmd (a command line), end (box rule), msg.
  # class (uc): the order in which lines are left out, 1 first; 0 = always shown. Commands: the middle of a list.
  local t=-1 sec="" g=-1 cnt=0 s hr2 hr4 x
  hr2="${S_HR}${S_HR}"; hr4="$hr2$hr2"
  for ((k = 0; k < m; k++)); do
    ui_strip "${ut[$k]%%$'\n'*}"
    [[ "$UI_S" == "  Step ${CUR_STEP:-x}  "* || "$UI_S" == "  Step ${CUR_STEP:-x}" ]] && { t=$k; break; }
  done
  local -a gfirst=() glast=() gbox=()
  for ((k = 0; k < m; k++)); do
    i=${uf[$k]}; uk[$k]=""; uc[$k]=0; ug[$k]=-1; ud[$k]=0
    if [[ $k -eq $t ]]; then uk[$k]=title; continue; fi
    if [[ $k -lt $t ]]; then
      if [[ $i -ge $UI_RES_A && $i -lt $UI_RES_B ]]; then uk[$k]=res; uc[$k]=1
      elif [[ $i -ge $UI_REC_A && $i -lt $UI_REC_B ]]; then uk[$k]=rec; uc[$k]=10
      else uk[$k]=intro; uc[$k]=3; fi
      continue
    fi
    ui_strip "${ut[$k]%%$'\n'*}"; s=$UI_S
    if [[ -z "$s" ]]; then
      if [[ "$sec" == box ]]; then uk[$k]=cmd; ug[$k]=$g; else uk[$k]=blank; uc[$k]=3; sec=""; fi
    elif [[ "$s" == "    Status "* || "$s" == "    Plan "* || "$s" == "    Details "* || "$s" == "    Fix "* ]]; then
      sec=${s:4}; sec=${sec%% *}; cnt=1; uk[$k]=text
      case "$sec" in Details) uc[$k]=8 ;; *) uc[$k]=13 ;; esac
    elif [[ "$s" == "    Will run"* ]]; then
      sec=will; g=$((g + 1)); gbox[$g]=0; gfirst[$g]=-1; glast[$g]=-1; uk[$k]=head
    elif [[ "$s" == "    $hr2 "* ]]; then
      sec=box; g=$((g + 1)); gbox[$g]=1; gfirst[$g]=-1; glast[$g]=-1; uk[$k]=head
    elif [[ "$sec" == box && "$s" == "    $hr4"* ]]; then
      uk[$k]=end; sec=""
    elif [[ "$sec" == box || ( "$sec" == will && "$s" == "             "* ) ]]; then
      uk[$k]=cmd; ug[$k]=$g; uc[$k]=9
      [[ ${gfirst[$g]} -lt 0 ]] && gfirst[$g]=$k; glast[$g]=$k
      # "as grid ..." (the next user) and the line that names the file with all of the commands stay
      [[ "$sec" == will && ( "$s" == "             as "* || "$s" == "             ..."* || "$s" == "             $S_WAIT"* ) ]] && uc[$k]=0
    elif [[ -n "$sec" && "$sec" != will && "$s" == "             "* ]]; then
      cnt=$((cnt + 1)); uk[$k]=text
      case "$sec" in
        Status) uc[$k]=6 ;;
        Details) uc[$k]=4 ;;
        *) if [[ "$s" == *DOWNTIME* || "$s" == *ERASE* || "$s" == *"Type "* ]]; then uc[$k]=12
           elif [[ $cnt -le 4 ]]; then uc[$k]=11; else uc[$k]=7; fi ;;
      esac
    else
      sec=""; uk[$k]=msg
      if [[ "$s" == "    $S_BAD "* ]]; then uc[$k]=0
      elif [[ "$s" == "    $S_WARN "* ]]; then uc[$k]=12
      else uc[$k]=5; fi
    fi
  done
  # a command list keeps its first line (a box: its first 3, the environment and the program) and its last line
  for ((x = 0; x <= g; x++)); do
    [[ ${gfirst[$x]} -ge 0 ]] || continue
    i=${gfirst[$x]}; uc[$i]=0
    if [[ ${gbox[$x]} -eq 1 ]]; then
      for ((k = i + 1; k <= glast[x] && k < i + 3; k++)); do [[ "${uk[$k]}" == cmd ]] && uc[$k]=0; done
    fi
    uc[${glast[$x]}]=0
  done
  # the order inside a class: the output of the step before and the intro from the top; the middle of a command
  # list from its middle outwards (its head and tail stay longest); the rest from the end up
  # the order inside a class (_ui_cut_order) and the rows the step text takes with the lines left out so far
  # (_ui_cut_rows): helpers of ui_flush, they use its local arrays
  local -a order=(); local recf=0 tot
  local c j nrec=0
  for ((k = 0; k < m; k++)); do [[ "${uk[$k]}" == rec ]] && nrec=$((nrec + 1)); done
  _ui_cut_rows
  for c in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    [[ $tot -le $avail ]] && break
    if [[ $c -eq 2 ]]; then
      # the earlier steps of the phase as one line
      if [[ $nrec -gt 1 && -n "$UI_REC_TXT" ]]; then
        for ((k = 0; k < m; k++)); do [[ "${uk[$k]}" == rec || "${uk[$k]}" == res ]] && ud[$k]=1; done
        recf=1; _ui_cut_rows
      fi
      continue
    fi
    if [[ $c -eq 10 ]]; then
      for ((k = 0; k < m; k++)); do [[ "${uk[$k]}" == rec ]] && ud[$k]=1; done
      [[ $nrec -gt 0 ]] && recf=2; _ui_cut_rows; continue
    fi
    _ui_cut_order "$c"
    for j in ${order[@]+"${order[@]}"}; do
      ud[$j]=1; _ui_cut_rows
      [[ $tot -le $avail ]] && break
    done
  done
  # still too long (very long command lines): the lines after the title from the top, the last one stays
  for ((k = t + 1; k < m - 1 && tot > avail; k++)); do
    [[ ${ud[$k]} -eq 0 && $k -ne $t ]] && { ud[$k]=1; _ui_cut_rows; }
  done

  # ---- print: the lines kept, a marker for each gap ----
  local pend=0 pind=4 hidden=0 extra recdone=0 nl
  UI_CUT=0
  for ((k = 0; k < m; k++)); do
    if [[ $recf -eq 1 && $recdone -eq 0 && ( "${uk[$k]}" == rec || "${uk[$k]}" == res ) ]]; then printf '%s\n' "$UI_REC_TXT"; recdone=1; fi
    if [[ ${ud[$k]} -eq 1 ]]; then
      case "${uk[$k]}" in
        text|cmd|msg)
          x=${ut[$k]//[!$'\n']/}; nl=$(( ${#x} + 1 ))
          if [[ $pend -eq 0 ]]; then
            ui_strip "${ut[$k]%%$'\n'*}"; x=${UI_S%%[! ]*}; pind=${#x}
            [[ $pind -lt 4 ]] && pind=4; [[ $pind -gt 13 ]] && pind=13
            [[ "${uk[$k]}" == cmd && ${gbox[${ug[$k]}]:-0} -eq 1 ]] && pind=4
            extra=""
          fi
          [[ "${uk[$k]}" == cmd && ${gbox[${ug[$k]}]:-0} -eq 0 && -n "${CP_FILE:-}" ]] && extra=" (all commands: $CP_FILE)"
          pend=$((pend + nl)); hidden=$((hidden + nl)) ;;
      esac
      continue
    fi
    [[ $pend -gt 0 ]] && { ui_cut_marker "$pind" "$pend" "$extra"; pend=0; }
    printf '%s\n' "${ut[$k]}"
  done
  [[ $pend -gt 0 ]] && ui_cut_marker "$pind" "$pend" "$extra"
  [[ $hidden -gt 0 ]] && UI_CUT=1
  _ui_cut_rows
  UI_USED=$((tot + 2))
  _log INFO "screen: the step text was cut to fit ($hidden lines not shown; all of them are in this log)"
}
_ui_cut_order() {
  # (ui_flush) the lines of class $1 in the order they are left out: the output of the step before and the intro
  # from the top; the middle of a command list from its middle outwards (its head and tail stay longest); the rest
  # from the end up
  local c=$1 j p kk hd tl nm
  local -a mid=()
  order=()
  case "$c" in
    1|3) for ((j = 0; j < m; j++)); do [[ ${uc[$j]} -eq $c ]] && order+=("$j"); done ;;
    9) for ((p = g; p >= 0; p--)); do
         [[ ${gfirst[$p]} -ge 0 ]] || continue
         mid=()
         for ((j = gfirst[p]; j <= glast[p]; j++)); do [[ ${uc[$j]} -eq 9 && ${ug[$j]} -eq $p ]] && mid+=("$j"); done
         nm=${#mid[@]}; [[ $nm -gt 0 ]] || continue
         # with kk lines of the middle kept, 2/3 of them are its first lines and 1/3 its last lines:
         # one line less each time, taken from the end of the head or from the start of the tail
         hd=$(( (2 * nm + 2) / 3 )); tl=$((nm - hd))
         for ((kk = nm - 1; kk >= 0; kk--)); do
           if [[ $(( (2 * kk + 2) / 3 )) -lt $hd ]]; then hd=$((hd - 1)); order+=("${mid[$hd]}")
           else order+=("${mid[$((nm - tl))]}"); tl=$((tl - 1)); fi
         done
       done ;;
    *) for ((j = m - 1; j >= 0; j--)); do [[ ${uc[$j]} -eq $c ]] && order+=("$j"); done ;;
  esac
  return 0
}
_ui_cut_rows() {
  # (ui_flush) tot = the rows of the lines kept; a gap in the step text costs one row (its "… N more lines" line);
  # the earlier steps cost one row once they are folded (recf=1), none once they are gone (recf=2)
  local j pend=0
  tot=0
  for ((j = 0; j < m; j++)); do
    if [[ ${ud[$j]} -eq 1 ]]; then
      case "${uk[$j]}" in text|cmd|msg) pend=1 ;; esac
      continue
    fi
    [[ $pend -eq 1 ]] && { tot=$((tot + 1)); pend=0; }
    tot=$((tot + ur[j]))
  done
  [[ $pend -eq 1 ]] && tot=$((tot + 1))
  [[ $recf -eq 1 ]] && tot=$((tot + 1))
  return 0
}
ui_cut_marker() {
  # $1 indent, $2 lines left out, $3 where else they are: one line in place of the lines left out
  local txt
  txt=$(printf '%s %d more %s: d shows all' "$S_WAIT" "$2" "$([[ $2 -eq 1 ]] && printf line || printf lines)")
  [[ -n "$3" && $(( $1 + ${#txt} + ${#3} )) -lt $UI_COLS ]] && txt+=$3
  printf '%s%s%s%s\n' "$(ui_spaces "$1")" "$C_D" "$txt" "$C_N"
}
ui_live() {
  # one live line at the cursor (replaced by the next output)
  [[ $UI -eq 1 && -t 1 ]] || return 0
  printf '\r\e[K    %s%s%s\r' "$C_D" "$1" "$C_N"; UI_LIVE=1
}
ui_live_clear() { [[ $UI_LIVE -eq 1 ]] && { printf '\r\e[K'; UI_LIVE=0; }; return 0; }

# ---- the state of a step, for the map and the lists ----
ui_result_of() {
  # the result shown for step $1: of this run, else of the last run that did it
  if [[ -n "${STEP_RESULT[$1]:-}" ]]; then printf '%s' "${STEP_RESULT[$1]}"; return 0; fi
  if [[ " ${STEP_ORDER[*]+${STEP_ORDER[*]}} " == *" $1 "* ]]; then
    [[ "$1" == "$CUR_STEP" ]] && printf 'CURRENT' || printf 'NOT_FINISHED'; return 0
  fi
  printf '%s' "${LAST_RESULT[$1]:-}"
}
ui_class() {
  # done | cur | todo | attn
  case "$1" in
    OK|DONE|DONE_BY_YOU|SKIPPED_OPTIONAL|NOT_ON_RELEASE) printf 'done' ;;
    CURRENT|RUNNING) printf 'cur' ;;
    ""|TODO) printf 'todo' ;;
    *) printf 'attn' ;;
  esac
}
ui_sym() {
  # $1 result -> colored symbol
  case "$(ui_class "$1")" in
    done) printf '%s%s%s' "$C_G" "$S_OK" "$C_N" ;;
    cur)  printf '%s%s%s' "$C_C" "$UI_S_CUR" "$C_N" ;;
    todo) printf '%s%s%s' "$C_D" "$S_DOT" "$C_N" ;;
    *) case "$1" in FAILED|FAILED_SKIPPED|PROBLEM|NOT_FINISHED) printf '%s%s%s' "$C_R" "$S_BAD" "$C_N" ;;
         *) printf '%s%s%s' "$C_Y" "$S_WARN" "$C_N" ;; esac ;;
  esac
}
ui_short_label() {
  case "$1" in
    OK) printf 'ok' ;; DONE) printf 'done' ;; DONE_BY_YOU) printf 'by you' ;; SKIPPED) printf 'skipped' ;;
    SKIPPED_OPTIONAL) printf 'optional' ;; NOT_ON_RELEASE) printf 'n/a' ;; FAILED) printf 'failed' ;;
    FAILED_SKIPPED) printf 'failed' ;; WAITS) printf 'waiting' ;; RUNNING) printf 'running' ;; TODO) printf 'to do' ;;
    PROBLEM) printf 'problem' ;; UNDONE) printf 'undone' ;; NOT_FINISHED) printf 'stopped' ;; CURRENT) printf 'now' ;;
    "") printf 'to do' ;; *) printf '%s' "${1,,}" ;;
  esac
}
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UI_S_CUR='▶'; UI_SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') ;;
  *) UI_S_CUR='>'; UI_SPIN=('|' '/' '-' '\') ;;
esac

ui_header() {
  # the fixed map (rows 1 to UI_TOP). Drawn without moving the cursor of the step area.
  [[ $UI -eq 1 && -t 1 ]] || return 0
  UI_HDR_BUSY=1
  ui_check_size || { UI_HDR_BUSY=0; return 0; }
  UI_HDR_BUSY=0
  local -a pt=(0 0 0 0 0 0 0 0 0 0 0) pd=(0 0 0 0 0 0 0 0 0 0 0) pa=(0 0 0 0 0 0 0 0 0 0 0) mk=()
  local i p c nd=0 na=0 nt=0 cur=${UI_PHASE:-${CUR_STEP%%.*}}
  num "$cur" || cur=0
  for i in "${HELP_IDS[@]}"; do
    on_demand "$i" && [[ -z "${STEP_RESULT[$i]:-}" ]] && continue
    p=${i%%.*}; pt[$p]=$((pt[$p] + 1))
    c=$(ui_class "$(ui_result_of "$i")")
    case "$c" in done) pd[$p]=$((pd[$p] + 1)); nd=$((nd + 1)) ;; attn) pa[$p]=$((pa[$p] + 1)); na=$((na + 1)) ;; *) nt=$((nt + 1)) ;; esac
  done
  for p in 1 2 3 4 5 6 7 8 9 10; do
    if [[ $p -eq $cur ]]; then mk[$p]="$C_C$UI_S_CUR$C_N"
    elif [[ ${pt[$p]} -gt 0 && ${pd[$p]} -eq ${pt[$p]} ]]; then mk[$p]="$C_G$S_OK$C_N"
    elif [[ ${pa[$p]} -gt 0 ]]; then mk[$p]="$C_Y$S_WARN$C_N"
    else mk[$p]="$C_D$S_DOT$C_N"; fi
  done
  local row cell left right lp mode lg host
  mode=$([[ "$MODE" == check ]] && printf 'check only' || printf 'setup')
  [[ ${ROLL_FORWARD:-0} -eq 1 ]] && mode="roll forward"
  [[ $YES_MODE -eq 1 ]] && mode="yes to all"
  # row 1: the version, the log file (the step area has the step), the host and the run time
  left=" Data Guard standby setup $SCRIPT_VERSION"
  [[ "$mode" != setup ]] && left+="  ($mode)"
  host=$(hostname -s 2>/dev/null)
  right="$host   $(ui_dur $(( $(date +%s) - RUN_START ))) "
  lg=""
  if [[ -n "${LOG_FILE:-}" ]]; then
    lg="  $S_DOT  log $LOG_FILE"
    if [[ $(( ${#left} + ${#lg} + ${#right} + 2 )) -gt $UI_COLS ]]; then lg="  log: ${LOG_FILE##*/}"; fi
    if [[ $(( ${#left} + ${#lg} + ${#right} + 2 )) -gt $UI_COLS ]]; then right="$(ui_dur $(( $(date +%s) - RUN_START ))) "; fi
    [[ $(( ${#left} + ${#lg} + ${#right} + 2 )) -gt $UI_COLS ]] && lg=""
  fi
  lp=$((UI_COLS - ${#left} - ${#lg} - ${#right})); [[ $lp -lt 1 ]] && lp=1
  printf '\e7\e[?25l'
  printf '\e[1;1H\e[2K%s%s%s%s%s%s%s%s' "$C_W" "$left" "$C_N" "$C_D" "$lg" "$C_N" "$(ui_spaces "$lp")" "$C_D"; printf '%s%s' "$right" "$C_N"
  # the totals, and the keys (a 0 is not marked)
  local sa="$C_Y$S_WARN$C_N" att="need attention"
  [[ $na -eq 0 ]] && sa="$C_D$S_WARN$C_N"
  if [[ $UI_COLS -ge 100 ]]; then
    left="   $C_G$S_OK$C_N $nd done    $sa $na $att    $C_D$S_DOT$C_N $nt to go"
    right="l: all steps   d: details   h: help "
  else
    left="   $C_G$S_OK$C_N $nd done   $sa $na $att   $C_D$S_DOT$C_N $nt to go"
    right="l: steps  d: details  h: help "
  fi
  if [[ $(( $(ui_vislen "$left") + ${#right} )) -gt $UI_COLS ]]; then left=${left//"$att"/attention}; fi
  local totals="$left" tright="$right"
  if [[ "$UI_MAP" == compact ]]; then
    # row 2: every phase in one line (the current one with its name and steps), row 3: totals and keys
    local line=" " cl
    for p in 1 2 3 4 5 6 7 8 9 10; do
      if [[ $p -eq $cur ]]; then line+="${mk[$p]}$C_W$p ${PHASE_SHORT[$p]}$C_N $C_D${pd[$p]}/${pt[$p]}$C_N  "
      elif [[ ${pa[$p]} -gt 0 ]]; then line+="${mk[$p]}$p $C_D${pd[$p]}/${pt[$p]}$C_N  "
      else line+="${mk[$p]}$p  "; fi
    done
    if [[ $(ui_vislen "$line") -ge $UI_COLS ]]; then
      line=" "; for p in 1 2 3 4 5 6 7 8 9 10; do line+="${mk[$p]}$p "; [[ $p -eq $cur ]] && line+="$C_D${pd[$p]}/${pt[$p]}$C_N "; done
    fi
    printf '\e[2;1H\e[2K%s' "$line"
    lp=$((UI_COLS - $(ui_vislen "$totals") - ${#tright})); [[ $lp -lt 1 ]] && lp=1
    printf '\e[3;1H\e[2K%s%s%s%s%s' "$totals" "$(ui_spaces "$lp")" "$C_D" "$tright" "$C_N"
    printf '\e[4;1H\e[2K %s%s%s' "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
  elif [[ "$UI_MAP" == wide ]]; then
    # 2 rows of 5 phases
    printf '\e[2;1H\e[2K %s%s%s' "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
    for row in 0 1; do
      printf '\e[%d;1H\e[2K ' $((row + 3))
      for p in $((row * 5 + 1)) $((row * 5 + 2)) $((row * 5 + 3)) $((row * 5 + 4)) $((row * 5 + 5)); do
        cell=$(printf '%3d %-14s' "$p" "${PHASE_SHORT[$p]}")
        [[ $p -eq $cur ]] && cell="$C_W$cell$C_N"
        printf '%s%s%s%5s%s  ' "${mk[$p]}" "$cell" "$C_D" "${pd[$p]}/${pt[$p]}" "$C_N"
      done
    done
    lp=$((UI_COLS - $(ui_vislen "$totals") - ${#tright})); [[ $lp -lt 1 ]] && lp=1
    printf '\e[5;1H\e[2K%s%s%s%s%s' "$totals" "$(ui_spaces "$lp")" "$C_D" "$tright" "$C_N"
    printf '\e[6;1H\e[2K %s%s%s' "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
  else
    local cw=$(( (UI_COLS - 4) / 2 ))
    printf '\e[2;1H\e[2K %s%s%s' "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
    for row in 1 2 3 4 5; do
      printf '\e[%d;1H\e[2K' $((row + 2))
      for p in $row $((row + 5)); do
        cell=$(printf '%2d %-16s' "$p" "${PHASE_SHORT[$p]}")
        if [[ $p -eq $cur ]]; then cell="$C_W$cell$C_N"; fi
        printf '   %s %s %s%5s%s' "${mk[$p]}" "$cell" "$C_D" "${pd[$p]}/${pt[$p]}" "$C_N"
        [[ $p -le 5 ]] && printf '%s' "$(ui_spaces $((cw - 30)))"
      done
    done
    lp=$((UI_COLS - $(ui_vislen "$totals") - ${#tright})); [[ $lp -lt 1 ]] && lp=1
    printf '\e[8;1H\e[2K%s%s%s%s%s' "$totals" "$(ui_spaces "$lp")" "$C_D" "$tright" "$C_N"
    printf '\e[9;1H\e[2K %s%s%s' "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
  fi
  printf '\e8\e[?25h'
  return 0
}

# ---- the step area ----
ui_one_line() {
  # one line for a step that has a result in this run, and its warnings under it
  local id=$1 r=${STEP_RESULT[$1]:-} t now w x first col tw
  col=$(result_color "$r")
  # the title: as wide as the terminal allows (30 to 44 columns), a cut one ends with …
  tw=$(( (UI_COLS - 14) / 3 )); [[ $tw -lt 30 ]] && tw=30; [[ $tw -gt 44 ]] && tw=44
  t=${STEP_TITLE[$id]:-$(step_title_of "$id" 2>/dev/null)}
  if [[ ${#t} -gt $tw ]]; then t=${t:0:$((tw - 1))}; t="${t%"${t##*[! ]}"}$S_WAIT"; fi
  t+=$(ui_spaces $((tw - ${#t})))
  now=${STEP_NOW[$id]:-}; now=${now%%$'\n'*}
  w=$((UI_COLS - tw - 22)); [[ $w -lt 10 ]] && w=10
  [[ ${#now} -gt $w ]] && now="${now:0:$((w - 1))}$S_WAIT"
  ui_emit "$(printf '  %s %-5s %s %s%-8s%s %s%s%s' "$(ui_sym "$r")" "$id" "$t" "$col" "$(ui_short_label "$r")" "$C_N" "$C_D" "$now" "$C_N")"
  for x in "${WARN_LIST[@]+"${WARN_LIST[@]}"}"; do
    [[ "$x" == "[$id] "* ]] || continue
    first=${x#"[$id] "}; first=${first%%$'\n'*}
    [[ ${#first} -gt $((UI_COLS - 12)) ]] && first="${first:0:$((UI_COLS - 13))}$S_WAIT"
    ui_emit "$(printf '          %s%s %s%s' "$C_Y" "$S_WARN" "$first" "$C_N")"
  done
}
ui_has_warning() { local x; for x in "${WARN_LIST[@]+"${WARN_LIST[@]}"}"; do [[ "$x" == "[$1] "* ]] && return 0; done; return 1; }
ui_res_lines() {
  # the output of the step just done (step $1), under its one-line result: at most 12 lines (its start and its end)
  local -a L=(); mapfile -t L < "$UI_BUF_FILE.res" 2>/dev/null; local n=${#L[@]} i
  if [[ $n -le 12 ]]; then for ((i = 0; i < n; i++)); do ui_emit "${L[$i]}"; done; return 0; fi
  ui_emit "${L[0]}"
  ui_emit "$(printf '      %s%s %d more lines: in the log (l, then %s)%s' "$C_D" "$S_WAIT" $((n - 10)) "$1" "$C_N")"
  for ((i = n - 9; i < n; i++)); do ui_emit "${L[$i]}"; done
}
ui_recent() {
  # the steps of this phase done before step $1 in this run. UI_REC_A / UI_REC_B mark their lines in the collection,
  # UI_REC_TXT is their one-line form (used when the step text needs the room). The step just before keeps its
  # output under its line (UI_RES_A / UI_RES_B: left out first when the room is needed).
  local id=$1 p=${1%%.*} x n=0 max skip nw=0
  local -a ids=()
  UI_REC_A=-1; UI_REC_B=-1; UI_REC_TXT=""; UI_RES_A=-1; UI_RES_B=-1
  for x in "${STEP_ORDER[@]+"${STEP_ORDER[@]}"}"; do
    [[ "${x%%.*}" == "$p" && "$x" != "$id" && -n "${STEP_RESULT[$x]:-}" ]] && ids+=("$x")
  done
  n=${#ids[@]}
  if [[ $n -eq 0 ]]; then
    # the first step of a phase: the warnings of the steps of the phase before stay in view
    local pp=${UI_PREV_PHASE:-$((p - 1))} w2=0
    [[ "$pp" == "$p" ]] && return 0
    for x in "${STEP_ORDER[@]+"${STEP_ORDER[@]}"}"; do
      [[ "${x%%.*}" == "$pp" && -n "${STEP_RESULT[$x]:-}" ]] || continue
      ui_has_warning "$x" || continue
      if [[ $w2 -eq 0 ]]; then ui_emit ""; UI_REC_A=$(ui_buf_n); ui_emit "$(printf '  %sWarnings in phase %s:%s' "$C_D" "$pp" "$C_N")"; fi
      w2=$((w2 + 1)); ui_one_line "$x"
    done
    [[ $w2 -gt 0 ]] && { UI_REC_B=$(ui_buf_n); UI_REC_TXT=$(printf '  %s%s %s %s of phase %s had warnings (l: all steps)%s' "$C_D" "$S_WARN" "$w2" "$([[ $w2 -eq 1 ]] && printf step || printf steps)" "$pp" "$C_N"); }
    [[ $UI_BUF_ON -eq 1 ]] || { UI_REC_A=-1; UI_REC_B=-1; }
    return 0
  fi
  max=$(( (UI_ROWS - UI_TOP) / 3 )); [[ $max -lt 3 ]] && max=3
  skip=0; [[ $n -gt $max ]] && skip=$((n - max + 1))
  for x in "${ids[@]}"; do ui_has_warning "$x" && nw=$((nw + 1)); done
  ui_emit ""
  UI_REC_A=$(ui_buf_n)
  [[ $skip -gt 0 ]] && ui_emit "$(printf '  %s%s %s earlier steps of this phase (l: all steps)%s' "$C_D" "$S_WAIT" "$skip" "$C_N")"
  for ((x = skip; x < n; x++)); do ui_one_line "${ids[$x]}"; done
  if [[ -s "$UI_BUF_FILE.res" && "${ids[$((n - 1))]}" == "$UI_RES_ID" && $UI_BUF_ON -eq 1 ]]; then
    UI_RES_A=$(ui_buf_n); ui_res_lines "$UI_RES_ID"; UI_RES_B=$(ui_buf_n)
  fi
  UI_REC_B=$(ui_buf_n)
  UI_REC_TXT=$(printf '  %s%s %s earlier %s of this phase%s (l: all steps)%s' "$C_D" "$S_WAIT" "$n" "$([[ $n -eq 1 ]] && printf step || printf steps)" "$([[ $nw -gt 0 ]] && printf ', %s with warnings' "$nw")" "$C_N")
  [[ $UI_BUF_ON -eq 1 ]] || { UI_REC_A=-1; UI_REC_B=-1; UI_RES_A=-1; UI_RES_B=-1; }
}
ui_body_reset() {
  # $1 step, $2 title: the step area is cleared and starts with this phase so far, then the step.
  # From here to the first question the lines are collected and laid out to fit (ui_flush).
  [[ $UI -eq 1 ]] || return 0
  ui_live_clear
  UI_PHASE=${1%%.*}
  ui_header
  [[ $UI -eq 1 ]] || return 0
  if [[ $UI_KEEP_ONCE -eq 1 ]]; then UI_KEEP_ONCE=0; ui_buf_start 0; else ui_buf_start 1; fi
  ui_recent "$1"
  ui_emit ""
  UI_TITLE_IDX=$(ui_buf_n); UI_CUT=0
  UI_TITLE_TXT=$(printf '  %sStep %s%s  %s%s%s%s' "$C_B" "$1" "$C_N" "$C_W" "$2" "$C_N" "$([[ $UI_ATTEMPT -gt 1 ]] && printf '   %sattempt %s%s' "$C_D" "$UI_ATTEMPT" "$C_N")")
  ui_emit "$UI_TITLE_TXT"
}
ui_step_begin() { UI_ATTEMPT=1; UI_RETRY=0; ui_body_reset "$1" "$2"; }

# ---- the separate screen: a pager for the list, the details and the help ----
ui_page() {
  # $1 file, $2 title, $3 = steps: a typed step number opens its details, $4 first line shown (0 = top),
  # $5 = lines with this many leading spaces or more are not wrapped (the log blocks of the details: 12).
  # Text is wrapped at a space; command lines are not (the terminal wraps them): a page counts their rows.
  local f=$1 title=$2 steps=${3:-} top=${4:-0} nf=${5:-} h n i k rest id first_alt=0 used nx
  local -a L=() R=()
  ui_flush
  mapfile -t L < <(ui_fold "             " $nf < "$f")
  n=${#L[@]}
  for ((i = 0; i < n; i++)); do ui_nrows "${L[$i]}"; R[$i]=$UI_N; done
  if [[ $UI_ALT -eq 0 ]]; then printf '\e[?1049h'; UI_ALT=1; first_alt=1; fi
  printf '\e[r'
  while true; do
    h=$((UI_ROWS - 5))
    printf '\e[?25l\e[H\e[2J %s%s%s\n %s%s%s\n' "$C_W" "$title" "$C_N" "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
    used=0; i=$top
    while [[ $i -lt $n ]]; do [[ $used -gt 0 && $((used + R[i])) -gt $h ]] && break; printf '%s\n' "${L[$i]}"; used=$((used + R[i])); i=$((i + 1)); done
    nx=$i
    printf '\e[%d;1H %s%s%s\n\e[%d;1H\e[2K ' $((UI_ROWS - 1)) "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N" "$UI_ROWS"
    if [[ $top -gt 0 || $nx -lt $n ]]; then printf '%s%d-%d of %d   Enter: more   b: back   q: close%s' "$C_D" $((top + 1)) "$nx" "$n" "$C_N"
    else printf '%sEnter or q: close%s' "$C_D" "$C_N"; fi
    [[ -n "$steps" ]] && printf '%s   a step number: its details%s' "$C_D" "$C_N"
    printf '\e[?25h'
    k=""; IFS= read -rsn1 k < "$PROMPT_IN" || break
    case "$k" in
      q|Q) break ;;
      b) ui_page_back ;;
      ""|" ") [[ $nx -ge $n ]] && break; top=$nx ;;
      $'\e') rest=""; IFS= read -rsn2 -t 0.1 rest < "$PROMPT_IN"
             case "$rest" in
               "[A") [[ $top -gt 0 ]] && top=$((top - 1)) ;;
               "[B") [[ $nx -lt $n ]] && top=$((top + 1)) ;;
               "[5") IFS= read -rsn1 -t 0.1 rest < "$PROMPT_IN"; ui_page_back ;;
               "[6") IFS= read -rsn1 -t 0.1 rest < "$PROMPT_IN"; [[ $nx -lt $n ]] && top=$nx ;;
             esac ;;
      [0-9])
        if [[ -n "$steps" ]]; then
          printf '\e[%d;1H\e[2K Step: %s' "$UI_ROWS" "$k"; rest=""
          IFS= read -r rest < "$PROMPT_IN"; id="$k${rest//[[:space:]]/}"
          if valid_step "$id"; then
            local df; df=$(mktemp) && CLEANUP_FILES+=("$df") && { ui_details_text "$id" > "$df"; ui_page "$df" "Step $id  $(step_title_of "$id" 2>/dev/null)" "" 0 12; rm -f -- "$df"; }
          fi
        fi ;;
    esac
  done
  if [[ $first_alt -eq 1 ]]; then
    printf '\e[?1049l'; UI_ALT=0
    ui_region; ui_header
  fi
  return 0
}
ui_page_back() {
  # (ui_page) one page back: the lines before the top line that fit on a page
  local j=$top u=0
  while [[ $j -gt 0 && $((u + R[j - 1])) -le $h ]]; do j=$((j - 1)); u=$((u + R[j])); done
  [[ $j -eq $top && $top -gt 0 ]] && j=$((top - 1))
  top=$j
}
ui_show() {
  # $1 title, rest = command: its output on the separate screen
  local t=$1 f; shift
  f=$(mktemp) || return 0; CLEANUP_FILES+=("$f")
  "$@" > "$f" 2>&1
  ui_page "$f" "$t"; rm -f -- "$f"
}

ui_list_text() {
  # every step: result, when, and for a step that is not done why. $1 = width (default: the terminal)
  local width=${1:-$UI_COLS} p i r c lab when why col t d tot tw
  tw=$((width - 40)); [[ $tw -gt 56 ]] && tw=56; [[ $tw -lt 30 ]] && tw=30
  load_progress_keep
  for p in 1 2 3 4 5 6 7 8 9 10; do
    d=0; tot=0
    for i in "${HELP_IDS[@]}"; do
      [[ "${i%%.*}" == "$p" ]] || continue; on_demand "$i" && continue
      tot=$((tot + 1)); [[ "$(ui_class "$(ui_result_of "$i")")" == done ]] && d=$((d + 1))
    done
    printf '\n  %sPhase %s  %s%s   %s%s of %s done%s\n' "$C_B" "$p" "${PHASE_TITLES[$p]}" "$C_N" "$C_D" "$d" "$tot" "$C_N"
    for i in "${HELP_IDS[@]}"; do
      [[ "${i%%.*}" == "$p" ]] || continue
      r=$(ui_result_of "$i"); col=$(result_color "$r")
      lab=$(ui_short_label "$r"); [[ -z "$r" ]] && on_demand "$i" && lab="on demand"
      when=""; why=""
      if [[ -n "${STEP_RESULT[$i]:-}" ]]; then when=${STEP_WHEN[$i]:-}; why=${STEP_NOW[$i]:-}
      elif [[ -n "${LAST_RESULT[$i]:-}" && "$r" == "${LAST_RESULT[$i]}" ]]; then when=$(sed -E 's/^[0-9]{4}-([0-9]{2})-([0-9]{2}) ([0-9]{2}:[0-9]{2}).*/\1-\2 \3/' <<< "${LAST_WHEN[$i]:-}"); why=${LAST_REASON[$i]:-}; fi
      [[ "$(ui_class "$r")" == done ]] && why=""
      t=$(step_title_of "$i" 2>/dev/null); [[ ${#t} -gt $tw ]] && t="${t:0:$((tw - 3))}..."
      [[ -z "$r" ]] && col=$C_D
      printf '   %s %-5s %-*s %s%-9s%s %s%-11s%s\n' "$(ui_sym "$r")" "$i" "$tw" "$t" "$col" "$lab" "$C_N" "$C_D" "$when" "$C_N"
      if [[ -n "$why" ]]; then
        [[ ${#why} -gt $((width - 14)) ]] && why="${why:0:$((width - 17))}..."
        printf '            %s%s%s\n' "$C_D" "$why" "$C_N"
      fi
    done
  done
  printf '\n  %sok = was already correct   done = done by the script   by you = you did it, the script checked it%s\n' "$C_D" "$C_N"
}
load_progress_keep() {
  # the results of earlier runs, without losing what this run has (STEP_RESULT is separate)
  [[ ${#LAST_RESULT[@]} -gt 0 ]] || load_progress
  return 0
}
ui_list() {
  # opens at the phase the run is in
  local f s=0 p=${UI_PHASE:-${CUR_STEP%%.*}}; f=$(mktemp) || return 0; CLEANUP_FILES+=("$f")
  ui_list_text > "$f"
  num "$p" && s=$(grep -n "Phase $p  " "$f" | head -n 1 | cut -d: -f1) && num "$s" && s=$((s - 2)); num "$s" && [[ $s -ge 0 ]] || s=0
  ui_page "$f" "All steps" steps "$s"; rm -f -- "$f"
}

ui_details_text() {
  # step $1: its result, and what this run (or the last run that did it) checked, did and showed
  local id=$1 r log="" src="" when
  r=$(ui_result_of "$id")
  local lab; case "$r" in "") lab="not done yet" ;; CURRENT) lab="in progress (the current step)" ;; *) lab=$(result_label "$r") ;; esac
  printf '  Result   %s%s%s\n' "$(result_color "$r")" "$lab" "$C_N"
  if [[ -n "${STEP_RESULT[$id]:-}" || " ${STEP_ORDER[*]+${STEP_ORDER[*]}} " == *" $id "* ]]; then
    log=$LOG_FILE; src="this run"
  elif [[ -n "${LAST_RESULT[$id]:-}" ]]; then
    when=${LAST_WHEN[$id]:-}; src="the run of $when"
    [[ -n "${LAST_RUNID[$id]:-}" ]] && log="$LOG_DIR/run_${LAST_RUNID[$id]}.log"
    [[ -n "${LAST_REASON[$id]:-}" ]] && printf '  Note     %s\n' "${LAST_REASON[$id]}"
  fi
  if [[ -z "$log" ]]; then printf '\n  This step has not run yet.\n'; printf '  What it does:  h at its question, or  %s --help-step %s\n' "$SELF" "$id"; return 0; fi
  printf '  From     %s\n  Log      %s\n\n' "$src" "$log"
  [[ -r "$log" ]] || { printf '  That log is not here any more.\n'; return 0; }
  # each line: "hh:mm:ss  tag    text"; the time and the tag only where they change (a block of the step text has
  # its tag on its first line, as on the screen); a longer line goes on under the text (ui_fold)
  awk -v id="[$id]" -v more="$S_WAIT" '
    function tag(l) { split(l, f, " \\| "); gsub(/ +$/, "", f[2]); return f[2] }
    {
      if (index($0, " | STEP   | ") && index($0, " | STEP   | " id " ")) { on = 1; print ""; print "  " substr($0, 12, 8) "  " substr($0, index($0, "] ") + 2); out = 0; pt = ""; next }
      if (on && (index($0, " | STEP   | ") || index($0, " | PHASE  | ") || index($0, " | SUM    | "))) { on = 0; next }
      if (!on) next
      if (substr($0, 1, 10) == "          ") { if (inblk) { nb++; if (nb <= 40) print "            " substr($0, 11) } ; next }
      t = tag($0); txt = $0; sub(/^[^|]*\| [^|]*\| /, "", txt)
      if (txt ~ /^--- end ---$/) { inblk = 0; if (nb > 40) print "            " more " " nb - 40 " more lines: in the log"; pt = ""; next }
      if (t == "OUT") { inblk = 1; nb = 0; sub(/^--- /, "", txt); sub(/ ---$/, "", txt); print "  " substr($0, 12, 8) "  output: " txt; pt = ""; next }
      if (t == "DO" || t == "RESULT") next
      if (t == "ASK" && txt ~ /  -> [ldh]$/) next
      tm = substr($0, 12, 8); tg = tolower(t)
      if (tg == pt) { tg = ""; if (tm == ptm) tm = "        " } else pt = tg
      if (tm != "        ") ptm = tm
      printf "  %s  %-6s %s\n", tm, tg, txt
    }' "$log"
}
ui_details() {
  local id=${1:-}
  [[ -n "$id" && "$id" == *.* && "$id" != *.x ]] || { ui_list; return 0; }
  local f; f=$(mktemp) || return 0; CLEANUP_FILES+=("$f")
  ui_details_text "$id" > "$f"
  ui_page "$f" "Step $id  ${STEP_TITLE[$id]:-$(step_title_of "$id" 2>/dev/null)}" "" 0 12
  rm -f -- "$f"
}

# ---- a long job: one live line instead of its output ----
ui_job_tick() {
  # $1 title, $2 output file, $3 start (SECONDS). One second: the live line, and the keys l and d.
  local fr=${UI_SPIN[$(( SECONDS % ${#UI_SPIN[@]} ))]} k="" t1=$SECONDS rc=0
  # (the screen layout was switched off, for example a smaller terminal: the loop still waits one second)
  if [[ $UI -ne 1 ]] || ! ui_check_size; then sleep 1; return 0; fi
  printf '\r\e[K    %s%s%s %s   %srunning, %s   l: all steps   d: output so far%s' "$C_C" "$fr" "$C_N" "$1" "$C_D" "$(ui_dur $((SECONDS - $3)))" "$C_N"
  UI_LIVE=1
  IFS= read -rsn1 -t 1 k < "$PROMPT_IN" 2>/dev/null || rc=$?
  case "$k" in
    l) ui_list ;;
    d) ui_show "Output of $1 so far (the last lines)" ui_job_tail "$2" ;;
  esac
  # a read that returns at once (no terminal any more) must not make a busy loop
  [[ $rc -ne 0 && $rc -le 128 && $SECONDS -eq $t1 ]] && sleep 1
  return 0
}
ui_drain() {
  # keys typed while a job ran (or just after it) are dropped: they must not become the answer to the next question
  [[ $UI -eq 1 ]] || return 0
  local junk n=0
  while IFS= read -rs -t 0.05 -n 1 junk < "$PROMPT_IN" 2>/dev/null && [[ $n -lt 1000 ]]; do n=$((n + 1)); done
  return 0
}
ui_job_tail() { tail -n $((UI_ROWS - 6)) -- "$1" 2>/dev/null | mask_pw; }
ui_job_done() {
  # $1 title, $2 exit code, $3 start (SECONDS), $4 output file
  [[ $UI -eq 1 ]] || return 0
  ui_live_clear
  local d; d=$(ui_dur $((SECONDS - $3)))
  # (a failure is reported by the step itself, with the lines that matter)
  if [[ "$2" == 0 || ( "$2" == 6 && ( "$1" == *installer* || "$1" == *"configuration tools"* ) ) ]]; then
    ok "$1 finished ($d)."
    # the notable lines of a job that worked: its warnings, kept with the step and in the summary (full output: its file)
    local wl
    while IFS= read -r wl; do [[ -n "$wl" ]] && warn "$1: $wl"; done < <(grep -E '^ *\[WARNING\]|^WARNING:' "$4" 2>/dev/null | sed 's/^ *//' | awk '!seen[$0]++' | head -n 2 | mask_pw)
  fi
  return 0
}

# ---- the summary screen of step 1.4: on its own page, the question at its bottom ----
ui_summary_ask() {
  local -a L=(); local n h i f mine=0 used=0 q qi="    "
  # the question in one line: below 100 columns with shorter labels (it starts the same way)
  q="[Enter] Start   [number] Change   [d] Details   [e] Edit the file   [h] Help   [q] Quit"
  [[ $UI_COLS -lt 100 ]] && { q="[Enter] Start   [number] Change  [d] Details  [e] Edit  [h] Help  [q] Quit"; qi=""; }
  f=$(mktemp) || { ask "[Enter] Start   [number] Change   [d] Details   [e] Edit the file   [h] Help   [q] Quit"; return 0; }
  CLEANUP_FILES+=("$f")
  h=$((UI_ROWS - 4))
  summary_text > "$f"; mapfile -t L < <(ui_fold "      " < "$f")
  # too long for the screen: the facts of the primary and of this server move to d (details)
  if [[ ${#L[@]} -gt $h ]]; then SUMMARY_COMPACT=1 summary_text > "$f"; mapfile -t L < <(ui_fold "      " < "$f"); fi
  rm -f -- "$f"
  n=${#L[@]}
  ui_live_clear
  # UI_ALT=1: an interrupt (Ctrl-C) at this question then also leaves the separate screen
  if [[ $UI_ALT -eq 0 ]]; then printf '\e[?1049h'; UI_ALT=1; mine=1; fi
  printf '\e[r\e[H\e[2J %sSummary of this run%s   %s%s%s\n %s%s%s\n' "$C_W" "$C_N" "$C_D" "$(hostname -s) -> standby of $PRIMARY_UNIQUE on ${PRIMARY_HOST:-$PRIMARY_IP}" "$C_N" "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
  # (a line longer than the width takes more rows: the terminal wraps it)
  for ((i = 0; i < n; i++)); do
    ui_nrows "${L[$i]}"; [[ $((used + UI_N)) -gt $((h - 1)) ]] && break
    printf '%s\n' "${L[$i]}"; used=$((used + UI_N))
  done
  [[ $i -lt $n ]] && printf ' %s%s %d more lines: d shows all%s\n' "$C_D" "$S_WAIT" $((n - i)) "$C_N"
  [[ -n "${SUM_NOTE:-}" ]] && printf '\e[%d;1H\e[2K    %s%s %s%s' $((UI_ROWS - 1)) "$C_Y" "$S_WARN" "${SUM_NOTE:0:$((UI_COLS - 8))}" "$C_N"
  SUM_NOTE=""
  printf '\e[%d;1H\e[2K%s%s%s %s%s %s ' "$UI_ROWS" "$qi" "$C_C" "$S_ASK" "$q" "$C_N" "$S_END"
  ANSWER=""; IFS= read -r ANSWER < "$PROMPT_IN" || ANSWER=q
  _log ASK "[1.4] summary -> ${ANSWER:-Enter}"
  [[ $mine -eq 1 ]] && { printf '\e[?1049l'; UI_ALT=0; }
  ui_header; ui_region
  return 0
}
