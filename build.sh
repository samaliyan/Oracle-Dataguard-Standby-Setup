#!/bin/bash
# Joins src/*.sh (in the order of their numbers) into dg_standby_setup.sh. The result replaces the old file only
# when it parses.
set -eu
cd "$(dirname "$0")"
export LC_ALL=C
out=dg_standby_setup.sh
tmp=$out.build.$$
trap 'rm -f -- "$tmp"' EXIT
first=1
for f in src/[0-9][0-9]_*.sh; do
  [ "$first" = 1 ] || printf '\n' >> "$tmp"
  cat "$f" >> "$tmp"; first=0
done
bash -n "$tmp"
chmod 755 "$tmp"
mv -f -- "$tmp" "$out"
echo "built $(wc -l < "$out") lines"
