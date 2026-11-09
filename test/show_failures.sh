#!/bin/bash
# After a failed test run: for each failed check, its name and the end of the newest script outputs it
# kept (run_scenarios.sh copies them to /tmp/dgt_fail/NNN/). Used by CI so the log shows why.
n=${1:-60}
for d in /tmp/dgt_fail/*/; do
  [[ -d "$d" ]] || continue
  echo "::group::FAILED $(cat "$d/CHECK" 2>/dev/null)"
  # the newest outputs (a check often looks at the last two or three runs): the errors of the script
  # (lines with the cross mark) with the lines before them, then the end
  for f in $(ls -t "$d"*.txt 2>/dev/null | head -n 3); do
    if grep -q '✘' "$f"; then echo "--- errors in $(basename "$f")"; grep -B6 -A2 '✘' "$f" | head -n 120; fi
    echo "--- last $n lines of $(basename "$f")"; tail -n "$n" "$f"
  done
  echo "::endgroup::"
done
for f in /tmp/dgt_stuck/*; do [[ -f "$f" ]] && { echo "::group::STUCK $(basename "$f")"; tail -n "$n" "$f"; echo "::endgroup::"; }; done
true
