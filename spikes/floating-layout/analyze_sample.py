# Reads a probe sample (JSON lines of window bounds) and reports, for each sample, the gap between
# vertically adjacent cards in the right-hand stack. With all cards moved in lockstep the gap
# stays at the configured 12 pt (+-1 for rounding); a different gap means the window server
# showed one window's new frame together with another window's old frame.
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
last = None; distinct = 0; bad = 0; worst = 0; frames = []
for r in rows:
    ws = sorted([w for w in r["w"] if w[0] > 900 and w[2] < 900], key=lambda w: w[1])  # right stack
    key = json.dumps(ws)
    if key == last: continue
    last = key; distinct += 1
    gaps = [round(b[1] - (a[1] + a[3])) for a, b in zip(ws, ws[1:])]
    dev = max([abs(g - 12) for g in gaps] or [0])
    worst = max(worst, dev)
    if dev > 1: bad += 1
    frames.append((round(r["t"], 1), len(ws), gaps))
print(f"samples={len(rows)} distinct_states={distinct} states_with_gap_off_by_>1pt={bad} worst_dev={worst}pt")
for f in frames: print(f)
