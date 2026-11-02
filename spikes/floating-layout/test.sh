#!/bin/bash
# Usage: ./test.sh NAME BACKDROP_RECT -- <spike args>
# Runs one short (about 10 s) scripted session: backdrop process behind, spike in front, then
# screenshot, clicks in gaps and on a card, Tab / Cmd-`, an animated add with window sampling,
# screenshot, cleanup. Kills only the two pids it started and hands focus back to the app that
# was frontmost before.
set -u
cd "$(dirname "$0")"
NAME=$1; BDRECT=$2; shift 3
P=build/probe; BIN=build/FloatingLayout.app/Contents/MacOS/FloatingLayout
mkdir -p logs shots
ORIG=$($P front | sed 's/.*pid=//')
$BIN --backdrop "$BDRECT" --autoquit 25 > "logs/$NAME-backdrop.log" 2>&1 & BD=$!
sleep 0.8
$BIN "$@" --autoquit 25 > "logs/$NAME.log" 2>&1 & APP=$!
trap 'kill $APP $BD 2>/dev/null; $P activate $ORIG >/dev/null' EXIT
sleep 1.5
OUT="logs/$NAME-probe.txt"; : > "$OUT"
screencapture -x "shots/$NAME-1.png"
echo "## order at start" >> "$OUT"; $P order $BD,$APP >> "$OUT"
# gap coordinates from the layout line
read -r GX GY HX HY <<<"$(python3 -I -c "
import json,sys
L=[json.loads(l) for l in open('logs/$NAME.log') if '\"layout\"' in l][-1]['cards']
s=L[0]['rect']; c2=[c for c in L if c['id']==2][0]['rect']
print(s['x']+s['w']+6, 500, c2['x']+150, c2['y']+c2['h']+6)")"
echo "## click vertical gap $GX,$GY (backdrop behind)" >> "$OUT"; $P click $GX $GY >> "$OUT"
echo "## order after gap click" >> "$OUT"; $P order $BD,$APP >> "$OUT"
$P activate $APP >/dev/null
echo "## click horizontal gap $HX,$HY" >> "$OUT"; $P click $HX $HY >> "$OUT"
$P activate $APP >/dev/null
echo "## click inside term 2" >> "$OUT"; $P click 1300 300 >> "$OUT"
echo "## Tab" >> "$OUT"; $P key 48 >> "$OUT"
echo "## Cmd-backtick" >> "$OUT"; $P key 50 cmd >> "$OUT"
echo "## add card (animated), sampling window bounds" >> "$OUT"
$P sample $APP 450 > "logs/$NAME-sample.jsonl" & SP=$!
sleep 0.05; $P cmd add; wait $SP
sleep 0.3
screencapture -x "shots/$NAME-2.png"
$P cmd dump; sleep 0.2
echo "## order at end" >> "$OUT"; $P order $BD,$APP >> "$OUT"
for f in shots/$NAME-1.png shots/$NAME-2.png; do sips -Z 1400 "$f" --out "$f" >/dev/null; done
cat "$OUT"; echo "## spike log"; grep -v '"layout"' "logs/$NAME.log"; grep '"layout"' "logs/$NAME.log" | tail -1
echo "## backdrop log"; cat "logs/$NAME-backdrop.log"
