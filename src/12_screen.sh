#------------------------------------------------------------------------------
# Screen layout (a terminal of at least 80 x 24, the default when the script runs in one):
#
#   rows 1-9   a fixed map: every phase with its done / total steps, and the totals
#   below      the current step only: the steps of this phase done before it (one line each),
#              then the step itself. A retry starts it again on a clean area ("attempt 2").
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
readonly UI_TOP=9     # rows of the fixed map
UI_PHASE=""           # the phase the run is in (for the map)
UI_PREV_PHASE=""      # the phase that ran before it (phase 4 can run right after phase 1)
UI_ATTEMPT=1          # attempt of the current step (shown from 2 on)
UI_RETRY=0            # set where the user answered "try again": the step starts again on a clean area
UI_KEEP_ONCE=0        # the first step keeps what was printed before it (start of the run)
UI_LIVE=0             # a live line ("checking ...") is on the screen and is cleared by the next output
UI_ALT=0              # the separate screen (list, details, help) is open
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
ui_region() {
  # the area under the map scrolls; the map stays (the cursor is kept where it is)
  printf '\e7\e[%d;%dr\e8' $((UI_TOP + 1)) "$UI_ROWS"
}
ui_start() {
  ui_wanted || return 0
  UI=1; load_progress
  printf '\e[H\e[2J'
  ui_region; ui_header
  printf '\e[%d;1H' $((UI_TOP + 1))
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
  [[ $UI_BUF_ON -eq 1 ]] && { UI_BUF_ON=0; cat -- "$UI_BUF_FILE" 2>/dev/null; : > "$UI_BUF_FILE" 2>/dev/null; }
  printf '\e[r\e[?25h\e[%d;1H\n' "$UI_ROWS"
  return 0
}
ui_check_size() {
  # a resized terminal: the map is drawn for the new size, or the plain output takes over when it is too small
  [[ $UI -eq 1 ]] || return 1
  local r=$UI_ROWS c=$UI_COLS
  ui_size || return 0
  [[ $UI_ROWS -eq $r && $UI_COLS -eq $c ]] && return 0
  if [[ $UI_ROWS -lt 24 || $UI_COLS -lt 80 ]]; then ui_end; say "The terminal is now too small for the screen layout: plain output from here on."; return 1; fi
  ui_region
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

# ---- printing (used by say, ok, bad, warn, block, hint) ----
ui_fold() {
  # stdin lines wrapped to the terminal width at a space (the spacing of each line is kept);
  # $1 = indent of the continued part. A word longer than the line (a path) is cut at the width.
  # bytes in every awk (LC_ALL=C): a UTF-8 continuation byte (the line and mark characters) takes no column
  LC_ALL=C awk -v w="$((UI_COLS - 1))" -v ind="$1" '
    function vis(s,   t, n) { t = s; gsub(/\033\[[0-9;?]*[a-zA-Z]/, "", t); n = length(t); return n - gsub(/[\200-\277]/, "", t) }
    {
      s = $0; match(s, /^ */); lead = RLENGTH
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
        while (i <= L && substr(s, i, 1) ~ /[\200-\277]/) i++     # never inside a character
        if (cut == 0) {
          # no space to cut at (a long path): cut at the width itself, the rest goes on indented
          # (only when the indent leaves room, else the terminal wraps it)
          if (i - 1 <= length(ind) + 10) break
          print substr(s, 1, i - 1)
          s = ind substr(s, i); lead = length(ind); continue
        }
        print substr(s, 1, cut - 1)
        rest = substr(s, cut + 1); sub(/^ +/, "", rest)
        s = ind rest; lead = length(ind)
      }
      print s
    }'
}
ui_out() {
  # $1 indent of continued lines, $2 text (may have several lines): printed, long lines wrapped
  ui_live_clear
  local l
  if [[ ${#2} -lt $((UI_COLS - 1)) && "$2" != *$'\n'* ]]; then ui_emit "$2"
  else while IFS= read -r l; do ui_emit "$l"; done < <(printf '%s\n' "$2" | ui_fold "$(ui_spaces "$1")"); fi
}

# ---- the step area: what a step prints before its question is laid out so that nothing scrolls away unseen ----
#   From the start of a step (or of a phase) to its first question, the lines are kept (UI_BUF) instead of printed.
#   ui_flush prints them. When they do not fit between the map and the question: a clean area, the earlier steps of
#   the phase folded into one line, and if it is still too long, the text cut with one line "N more lines: d shows all"
#   (d shows the step from the log, where every line is). Flushed at every question, before an action, at the end of a
#   step, and when the screen layout ends.
UI_BUF_ON=0; UI_BUF=(); UI_USED=0        # UI_USED: rows printed in the step area since it was last cleared
UI_BUF_FILE=""                           # the collected lines (a file: block, hint and the command boxes run in a pipe)
UI_TITLE_IDX=-1; UI_CUT=0                # the step title in UI_BUF; 1 = the text of this step was cut (d shows all)
UI_REC_A=-1; UI_REC_B=-1; UI_REC_TXT=""  # the lines of the earlier steps in UI_BUF (from A to before B), and their one-line form
ui_rows() {
  # rows that line $1 takes on the screen
  local n=${#1}
  [[ $n -lt $UI_COLS ]] && { printf 1; return 0; }
  n=$(ui_vislen "$1"); [[ $n -le 0 ]] && n=1
  printf '%d' $(( (n - 1) / UI_COLS + 1 ))
}
ui_emit() {
  # one line for the step area: kept while the step text is collected, else printed
  if [[ $UI_BUF_ON -eq 1 && -t 1 ]] && printf '%s\n' "$1" >> "$UI_BUF_FILE" 2>/dev/null; then return 0; fi
  printf '%s\n' "$1"
  UI_USED=$((UI_USED + $(ui_rows "$1")))
}
ui_area_clear() { printf '\e[%d;1H\e[J' $((UI_TOP + 1)); UI_USED=0; }
ui_buf_n() { local n; n=$(grep -c '' "$UI_BUF_FILE" 2>/dev/null); printf '%d' "${n:-0}"; }   # lines collected so far
ui_buf_start() {
  # $1 = 1: a clean area first. Lines collected before (a phase intro) stay in the collection.
  [[ $UI -eq 1 ]] || return 0
  if [[ -z "$UI_BUF_FILE" ]]; then
    UI_BUF_FILE=$(mktemp /tmp/dg_screen.XXXXXXXX 2>/dev/null) || { UI_BUF_FILE=""; return 0; }
    CLEANUP_FILES+=("$UI_BUF_FILE" "$UI_BUF_FILE.cut")
  fi
  if [[ "$1" == 1 ]]; then ui_area_clear; : > "$UI_BUF_FILE"; UI_REC_A=-1; UI_REC_B=-1
  elif [[ $UI_BUF_ON -eq 0 ]]; then : > "$UI_BUF_FILE"; UI_REC_A=-1; UI_REC_B=-1; fi
  UI_BUF_ON=1
}
ui_flush() {
  [[ $UI_BUF_ON -eq 1 ]] || return 0
  UI_BUF_ON=0
  UI_BUF=(); mapfile -t UI_BUF < "$UI_BUF_FILE" 2>/dev/null; : > "$UI_BUF_FILE" 2>/dev/null
  local l i need=0 avail n=${#UI_BUF[@]}
  [[ $n -gt 0 ]] || return 0
  if [[ $UI -ne 1 ]]; then printf '%s\n' "${UI_BUF[@]}"; UI_BUF=(); return 0; fi
  ui_live_clear
  # the question needs two rows (an empty one and itself)
  avail=$((UI_ROWS - UI_TOP - 2))
  local -a rows=()
  for ((i = 0; i < n; i++)); do rows[$i]=$(ui_rows "${UI_BUF[$i]}"); need=$((need + rows[i])); done
  if [[ $((UI_USED + need)) -le $avail ]]; then
    printf '%s\n' "${UI_BUF[@]}"; UI_USED=$((UI_USED + need)); UI_BUF=(); return 0
  fi
  # too long for what is left of the area: a clean area, and the earlier steps of the phase as one line
  local fold=0 recrows=0
  if [[ $UI_REC_A -ge 0 && $UI_REC_B -gt $((UI_REC_A + 1)) && $need -gt $avail ]]; then
    for ((i = UI_REC_A; i < UI_REC_B; i++)); do recrows=$((recrows + rows[i])); done
    fold=1; need=$((need - recrows + 1))
  fi
  ui_area_clear
  local keep=$avail shown=0
  local -a vis=()                      # the lines to show, in order (the one-line form of the earlier steps)
  local -a vrows=()
  for ((i = 0; i < n; i++)); do
    if [[ $fold -eq 1 && $i -ge $UI_REC_A && $i -lt $UI_REC_B ]]; then
      [[ $i -eq $UI_REC_A ]] && { vis+=("$UI_REC_TXT"); vrows+=(1); }
      continue
    fi
    vis+=("${UI_BUF[$i]}"); vrows+=("${rows[$i]}")
  done
  local m=${#vis[@]} tot=0
  for ((i = 0; i < m; i++)); do tot=$((tot + vrows[i])); done
  if [[ $tot -le $keep ]]; then
    printf '%s\n' "${vis[@]}"; shown=$tot
  else
    # too long: the beginning up to the step title and its first line, then "N more lines", then as much of the
    # end as fits (the end holds the commands of "Will run" and the last lines before the question)
    UI_CUT=1
    printf '%s\n' "${vis[@]}" > "$UI_BUF_FILE.cut" 2>/dev/null     # the whole text, for d
    local t=-1 hend hr=0 tr=0 tstart
    for ((i = 0; i < m; i++)); do [[ "${vis[$i]}" == *"Step ${CUR_STEP:-x}"* ]] && { t=$i; break; }; done
    hend=$(( t >= 0 ? t + 1 : 0 )); [[ $hend -ge $m ]] && hend=$((m - 1))
    for ((i = 0; i <= hend; i++)); do hr=$((hr + vrows[i])); done
    # cut: the lines before the step title go first (the phase intro, the earlier steps; the map names the phase
    # and d shows them), so the commands at the end get the room
    local dropped=0
    while [[ $t -gt 0 && $hend -gt 0 ]]; do hr=$((hr - vrows[0])); dropped=$((dropped + vrows[0])); vis=("${vis[@]:1}"); vrows=("${vrows[@]:1}"); m=$((m - 1)); hend=$((hend - 1)); t=$((t - 1)); done
    # still too long: the lines after the title go into the cut part (the title itself always stays)
    while [[ $hr -gt $((keep / 2)) && $hend -gt $(( t > 0 ? t : 0 )) ]]; do hr=$((hr - vrows[hend])); hend=$((hend - 1)); done
    tstart=$m
    while [[ $tstart -gt $((hend + 1)) && $((hr + tr + vrows[tstart - 1] + 1)) -le $keep ]]; do tstart=$((tstart - 1)); tr=$((tr + vrows[tstart])); done
    # the heading of the commands that are still on the screen ("── Run on the PRIMARY (host), as grid ──",
    # "Will run as oracle ...") stays with them: where and as whom they run must never be in the cut part
    local hd=-1 e=$'\e' rh rb
    rh="^[[:space:]]*(${e}\[[0-9;]*m)*[[:space:]]*(── [A-Za-z]|Will run )"; rb="^[[:space:]]*(${e}\[[0-9;]*m)*[[:space:]]*──────"
    for ((i = tstart - 1; i > hend; i--)); do
      [[ "${vis[$i]}" =~ $rb ]] && break                 # a box that closed before the shown lines: not theirs
      [[ "${vis[$i]}" =~ $rh ]] && { hd=$i; break; }
    done
    if [[ $hd -ge 0 ]]; then
      while [[ $tstart -lt $((m - 1)) && $((hr + tr + vrows[hd] + 1)) -gt $keep ]]; do tr=$((tr - vrows[tstart])); tstart=$((tstart + 1)); done
      tr=$((tr + vrows[hd]))
    fi
    local hidden=$dropped; for ((i = hend + 1; i < tstart; i++)); do [[ $i -ne $hd ]] && hidden=$((hidden + vrows[i])); done
    for ((i = 0; i <= hend; i++)); do printf '%s\n' "${vis[$i]}"; done
    if [[ $hidden -gt 0 ]]; then printf '    %s%s %d more lines: d shows all%s\n' "$C_D" "$S_WAIT" "$hidden" "$C_N"; shown=1; else shown=0; UI_CUT=0; fi
    [[ $hd -ge 0 ]] && printf '%s\n' "${vis[$hd]}"
    for ((i = tstart; i < m; i++)); do printf '%s\n' "${vis[$i]}"; done
    shown=$((shown + hr + tr)); [[ $shown -gt $avail ]] && shown=$avail
    _log INFO "screen: the step text was cut to fit ($hidden rows not shown; all of them are in this log)"
  fi
  UI_USED=$shown; UI_BUF=()
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
  # the fixed map (rows 1-9). Drawn without moving the cursor of the step area.
  [[ $UI -eq 1 && -t 1 ]] || return 0
  ui_check_size || return 0
  local -a pt=(0 0 0 0 0 0 0 0 0 0 0) pd=(0 0 0 0 0 0 0 0 0 0 0) pa=(0 0 0 0 0 0 0 0 0 0 0)
  local i p c nd=0 na=0 nt=0 cur=${UI_PHASE:-${CUR_STEP%%.*}}
  num "$cur" || cur=0
  for i in "${HELP_IDS[@]}"; do
    on_demand "$i" && [[ -z "${STEP_RESULT[$i]:-}" ]] && continue
    p=${i%%.*}; pt[$p]=$((pt[$p] + 1))
    c=$(ui_class "$(ui_result_of "$i")")
    case "$c" in done) pd[$p]=$((pd[$p] + 1)); nd=$((nd + 1)) ;; attn) pa[$p]=$((pa[$p] + 1)); na=$((na + 1)) ;; *) nt=$((nt + 1)) ;; esac
  done
  local cw=$(( (UI_COLS - 4) / 2 )) row cell mark left right lp rp mode
  mode=$([[ "$MODE" == check ]] && printf 'check only' || printf 'setup')
  [[ ${ROLL_FORWARD:-0} -eq 1 ]] && mode="roll forward"
  [[ $YES_MODE -eq 1 ]] && mode="yes to all"
  local st=""
  if [[ "${CUR_STEP:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then st="step $CUR_STEP  ${STEP_TITLE[$CUR_STEP]:-}"; fi
  left=" Data Guard standby setup $SCRIPT_VERSION"
  [[ "$mode" != setup ]] && left+="  ($mode)"
  right="$(hostname -s 2>/dev/null)   $(ui_dur $(( $(date +%s) - RUN_START ))) "
  local room=$((UI_COLS - ${#left} - ${#right} - 6))
  if [[ -n "$st" && $room -gt 12 ]]; then [[ ${#st} -gt $room ]] && st="${st:0:$((room - 3))}..."; left+="  $S_DOT  $st"; fi
  lp=$((UI_COLS - ${#left} - ${#right})); [[ $lp -lt 1 ]] && lp=1
  printf '\e7\e[?25l'
  printf '\e[1;1H\e[2K%s%s%s%s%s%s' "$C_W" "$left" "$C_N" "$(ui_spaces "$lp")" "$C_D" "$right"; printf '%s' "$C_N"
  printf '\e[2;1H\e[2K %s%s%s' "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
  for row in 1 2 3 4 5; do
    printf '\e[%d;1H\e[2K' $((row + 2))
    for p in $row $((row + 5)); do
      if [[ $p -eq $cur ]]; then mark="$C_C$UI_S_CUR$C_N"
      elif [[ ${pt[$p]} -gt 0 && ${pd[$p]} -eq ${pt[$p]} ]]; then mark="$C_G$S_OK$C_N"
      elif [[ ${pa[$p]} -gt 0 ]]; then mark="$C_Y$S_WARN$C_N"
      else mark="$C_D$S_DOT$C_N"; fi
      cell=$(printf '%2d %-16s' "$p" "${PHASE_SHORT[$p]}")
      if [[ $p -eq $cur ]]; then cell="$C_W$cell$C_N"; fi
      printf '   %s %s %s%5s%s' "$mark" "$cell" "$C_D" "${pd[$p]}/${pt[$p]}" "$C_N"
      [[ $p -le 5 ]] && printf '%s' "$(ui_spaces $((cw - 30)))"
    done
  done
  if [[ $UI_COLS -ge 100 ]]; then
    left="   $C_G$S_OK$C_N $nd done    $C_Y$S_WARN$C_N $na need attention    $C_D$S_DOT$C_N $nt to go"
    right="l: all steps   d: details   h: help "
  else
    left="   $C_G$S_OK$C_N $nd done   $C_Y$S_WARN$C_N $na need attention   $C_D$S_DOT$C_N $nt to go"
    right="l: steps  d: details  h: help "
  fi
  lp=$((UI_COLS - $(ui_vislen "$left") - ${#right})); [[ $lp -lt 1 ]] && lp=1
  printf '\e[8;1H\e[2K%s%s%s%s%s' "$left" "$(ui_spaces "$lp")" "$C_D" "$right" "$C_N"
  printf '\e[9;1H\e[2K %s%s%s' "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
  printf '\e8\e[?25h'
  return 0
}

# ---- the step area ----
ui_one_line() {
  # one line for a step that has a result in this run, and its warnings under it
  local id=$1 r=${STEP_RESULT[$1]:-} t now w x first col
  col=$(result_color "$r")
  t=${STEP_TITLE[$id]:-$(step_title_of "$id" 2>/dev/null)}; t=${t:0:30}
  now=${STEP_NOW[$id]:-}
  w=$((UI_COLS - 54)); [[ $w -lt 10 ]] && w=10
  [[ ${#now} -gt $w ]] && now="${now:0:$((w - 3))}..."
  ui_emit "$(printf '  %s %-5s %-30s %s%-8s%s %s%s%s' "$(ui_sym "$r")" "$id" "$t" "$col" "$(ui_short_label "$r")" "$C_N" "$C_D" "$now" "$C_N")"
  for x in "${WARN_LIST[@]+"${WARN_LIST[@]}"}"; do
    [[ "$x" == "[$id] "* ]] || continue
    first=${x#"[$id] "}; first=${first%%$'\n'*}
    [[ ${#first} -gt $((UI_COLS - 12)) ]] && first="${first:0:$((UI_COLS - 15))}..."
    ui_emit "$(printf '          %s%s %s%s' "$C_Y" "$S_WARN" "$first" "$C_N")"
  done
}
ui_has_warning() { local x; for x in "${WARN_LIST[@]+"${WARN_LIST[@]}"}"; do [[ "$x" == "[$1] "* ]] && return 0; done; return 1; }
ui_recent() {
  # the steps of this phase done before step $1 in this run. UI_REC_A / UI_REC_B mark their lines in the collection,
  # UI_REC_TXT is their one-line form (used when the step text needs the room)
  local id=$1 p=${1%%.*} x n=0 max skip nw=0
  local -a ids=()
  UI_REC_A=-1; UI_REC_B=-1; UI_REC_TXT=""
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
  UI_REC_B=$(ui_buf_n)
  UI_REC_TXT=$(printf '  %s%s %s earlier %s of this phase%s (l: all steps)%s' "$C_D" "$S_WAIT" "$n" "$([[ $n -eq 1 ]] && printf step || printf steps)" "$([[ $nw -gt 0 ]] && printf ', %s with warnings' "$nw")" "$C_N")
  [[ $UI_BUF_ON -eq 1 ]] || { UI_REC_A=-1; UI_REC_B=-1; }
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
  ui_emit "$(printf '  %sStep %s%s  %s%s%s%s' "$C_B" "$1" "$C_N" "$C_W" "$2" "$C_N" "$([[ $UI_ATTEMPT -gt 1 ]] && printf '   %sattempt %s%s' "$C_D" "$UI_ATTEMPT" "$C_N")")"
}
ui_step_begin() { UI_ATTEMPT=1; UI_RETRY=0; ui_body_reset "$1" "$2"; }

# ---- the separate screen: a pager for the list, the details and the help ----
ui_page() {
  # $1 file, $2 title, $3 = steps: a typed step number opens its details, $4 first line shown (0 = top)
  local f=$1 title=$2 steps=${3:-} top=${4:-0} h n i k rest id first_alt=0
  local -a L=()
  ui_flush
  mapfile -t L < <(ui_fold "             " < "$f")
  n=${#L[@]}
  if [[ $UI_ALT -eq 0 ]]; then printf '\e[?1049h'; UI_ALT=1; first_alt=1; fi
  printf '\e[r'
  while true; do
    h=$((UI_ROWS - 5))
    printf '\e[?25l\e[H\e[2J %s%s%s\n %s%s%s\n' "$C_W" "$title" "$C_N" "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N"
    for ((i = top; i < top + h && i < n; i++)); do printf '%s\n' "${L[$i]}"; done
    printf '\e[%d;1H %s%s%s\n\e[%d;1H\e[2K ' $((UI_ROWS - 1)) "$C_B" "$(rule $((UI_COLS - 2)))" "$C_N" "$UI_ROWS"
    if [[ $n -gt $h ]]; then printf '%s%d-%d of %d   Enter: more   b: back   q: close%s' "$C_D" $((top + 1)) $(( top + h < n ? top + h : n )) "$n" "$C_N"
    else printf '%sEnter or q: close%s' "$C_D" "$C_N"; fi
    [[ -n "$steps" ]] && printf '%s   a step number: its details%s' "$C_D" "$C_N"
    printf '\e[?25h'
    k=""; IFS= read -rsn1 k < "$PROMPT_IN" || break
    case "$k" in
      q|Q) break ;;
      b) top=$((top - h)); [[ $top -lt 0 ]] && top=0 ;;
      ""|" ") [[ $((top + h)) -ge $n ]] && break; top=$((top + h)) ;;
      $'\e') rest=""; IFS= read -rsn2 -t 0.1 rest < "$PROMPT_IN"
             case "$rest" in
               "[A") [[ $top -gt 0 ]] && top=$((top - 1)) ;;
               "[B") [[ $((top + h)) -lt $n ]] && top=$((top + 1)) ;;
               "[5") IFS= read -rsn1 -t 0.1 rest < "$PROMPT_IN"; top=$((top - h)); [[ $top -lt 0 ]] && top=0 ;;
               "[6") IFS= read -rsn1 -t 0.1 rest < "$PROMPT_IN"; [[ $((top + h)) -lt $n ]] && top=$((top + h)) ;;
             esac ;;
      [0-9])
        if [[ -n "$steps" ]]; then
          printf '\e[%d;1H\e[2K Step: %s' "$UI_ROWS" "$k"; rest=""
          IFS= read -r rest < "$PROMPT_IN"; id="$k${rest//[[:space:]]/}"
          if valid_step "$id"; then
            local df; df=$(mktemp) && CLEANUP_FILES+=("$df") && { ui_details_text "$id" > "$df"; ui_page "$df" "Step $id  $(step_title_of "$id" 2>/dev/null)"; rm -f -- "$df"; }
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
  awk -v id="[$id]" '
    function tag(l) { split(l, f, " \\| "); gsub(/ +$/, "", f[2]); return f[2] }
    {
      if (index($0, " | STEP   | ") && index($0, " | STEP   | " id " ")) { on = 1; print ""; print "  " substr($0, 12, 8) "  " substr($0, index($0, "] ") + 2); out = 0; next }
      if (on && (index($0, " | STEP   | ") || index($0, " | PHASE  | ") || index($0, " | SUM    | "))) { on = 0; next }
      if (!on) next
      if (substr($0, 1, 10) == "          ") { if (inblk) { nb++; if (nb <= 40) print "            " substr($0, 11); else if (nb == 41) print "            ..." } ; next }
      t = tag($0); txt = $0; sub(/^[^|]*\| [^|]*\| /, "", txt)
      if (txt ~ /^--- end ---$/) { inblk = 0; if (nb > 41) print "            (" nb - 40 " more lines in the log)"; next }
      if (t == "OUT") { inblk = 1; nb = 0; sub(/^--- /, "", txt); sub(/ ---$/, "", txt); print "  " substr($0, 12, 8) "  output: " txt; next }
      if (t == "DO" || t == "RESULT") next
      if (t == "ASK" && txt ~ /  -> [ldh]$/) next
      printf "  %s  %-6s %s\n", substr($0, 12, 8), tolower(t), txt
    }' "$log"
}
ui_details() {
  local id=${1:-}
  [[ -n "$id" && "$id" == *.* && "$id" != *.x ]] || { ui_list; return 0; }
  local f; f=$(mktemp) || return 0; CLEANUP_FILES+=("$f")
  ui_details_text "$id" > "$f"
  ui_page "$f" "Step $id  ${STEP_TITLE[$id]:-$(step_title_of "$id" 2>/dev/null)}"
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
  local -a L=(); local n h i f mine=0
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
  for ((i = 0; i < n && i < h - 1; i++)); do printf '%s\n' "${L[$i]}"; done
  [[ $n -ge $h ]] && printf ' %s%s %d more lines: d shows them%s\n' "$C_D" "$S_WAIT" $((n - h + 1)) "$C_N"
  [[ -n "${SUM_NOTE:-}" ]] && printf '\e[%d;1H\e[2K    %s%s %s%s' $((UI_ROWS - 1)) "$C_Y" "$S_WARN" "${SUM_NOTE:0:$((UI_COLS - 8))}" "$C_N"
  SUM_NOTE=""
  printf '\e[%d;1H\e[2K    %s%s %s%s %s ' "$UI_ROWS" "$C_C" "$S_ASK" "[Enter] Start   [number] Change   [d] Details   [e] Edit the file   [h] Help   [q] Quit" "$C_N" "$S_END"
  ANSWER=""; IFS= read -r ANSWER < "$PROMPT_IN" || ANSWER=q
  _log ASK "[1.4] summary -> ${ANSWER:-Enter}"
  [[ $mine -eq 1 ]] && { printf '\e[?1049l'; UI_ALT=0; }
  ui_header; ui_region
  return 0
}
