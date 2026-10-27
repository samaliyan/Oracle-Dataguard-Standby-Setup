#!/bin/bash
set -e
cd "$(dirname "$0")"
out=dg_standby_setup.sh
cat src/00_core.sh > $out
for f in src/10_engine.sh src/15_journal.sh src/20_settings.sh src/30_primary.sh src/32_discover.sh src/35_sql.sh src/40_phase1.sh src/45_phase2.sh src/50_phase3.sh src/55_phase4.sh src/60_phase5_6.sh src/70_phase7_8.sh src/80_phase9_10.sh src/90_help.sh src/99_main.sh; do
  printf '\n' >> $out; cat "$f" >> $out
done
chmod 755 $out
bash -n $out
echo "built $(wc -l < $out) lines"
