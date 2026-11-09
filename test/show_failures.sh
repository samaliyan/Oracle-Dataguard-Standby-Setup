#!/bin/bash
# After a failed test run: for each failed check, its name and the end of the newest script output it
# kept (run_scenarios.sh copies them to /tmp/dgt_fail/NNN/). Used by CI so the log shows why.
n=${1:-60}
for d in /tmp/dgt_fail/*/; do
  [[ -d "$d" ]] || continue
  echo "::group::FAILED $(cat "$d/CHECK" 2>/dev/null)"
  f=$(ls -t "$d"*.txt 2>/dev/null | head -n 1)
  if [[ -n "$f" ]]; then echo "--- last $n lines of $(basename "$f")"; tail -n "$n" "$f"; fi
  echo "::endgroup::"
done
for f in /tmp/dgt_stuck/*; do [[ -f "$f" ]] && { echo "::group::STUCK $(basename "$f")"; tail -n "$n" "$f"; echo "::endgroup::"; }; done
true
