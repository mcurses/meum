#!/bin/bash
# Run INSIDE the zmx session: marker, 300 numbered lines, then an in-place counter that also logs to a file.
OUT="$1"
echo "=== SPIKE-MARKER-7f3a $(date +%T) ==="
for i in $(seq 1 300); do echo "scrollback line $(printf %03d $i) of 300"; done
echo "=== END-OF-LINES (marker2) ==="
n=0
while :; do
  n=$((n+1)); echo "$n $(date +%s)" > "$OUT/counter.txt"
  printf '\rcounter=%05d at %s' "$n" "$(date +%T)"
  sleep 1
done
