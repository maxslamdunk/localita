#!/usr/bin/env python3
"""Compare the two quality-gate logs (gate-A, gate-B) endpoint by endpoint.

Usage: python3 -I gate.py [logs-dir]
Scores Q1 (mean and worst |dNLL|) and Q2 (top-1 agreement where B's top-2 gap
exceeds 0.1 nats) from predictions.md.
"""
import re
import sys
from pathlib import Path

logs = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent / "logs")
prefix = sys.argv[2] if len(sys.argv) > 2 else "gate"


def load(label):
    files = sorted(logs.glob(f"decode-{label}-*.log"))
    if not files:
        sys.exit(f"no log for {label}")
    # Every log of the arm, oldest first, so a rerun's endpoints fill in or
    # replace an interrupted run's (gate2-B, then gate2-B-r2).
    rows = {}
    for line in "\n".join(f.read_text() for f in files).splitlines():
        if ", endpoint, " not in line:
            continue
        f = dict(re.findall(r"([a-z0-9-]+)=(\S+)", line[line.index(", endpoint, "):]))
        top = [(int(t.split(":")[0]), float(t.split(":")[1])) for t in f["top"].split(",")]
        nll = None if f["nll"] == "n/a" else float(f["nll"])
        rows[(f["case"], int(f["endpoint"]))] = (nll, top)
    return ", ".join(f.name for f in files), rows


name_a, a = load(f"{prefix}-A")
name_b, b = load(f"{prefix}-B")
print(f"A: {name_a}\nB: {name_b}")
deltas = []
disagree = []
print(f"{'case':18} {'end':>5} {'nll A':>9} {'nll B':>9} {'dNLL':>9} {'top1 A':>7} {'top1 B':>7} {'B gap':>6}")
for key in sorted(b):
    if key not in a:
        print("missing in A:", key)
        continue
    (na, ta), (nb, tb) = a[key], b[key]
    gap = tb[0][1] - tb[1][1]
    d = None if na is None or nb is None else na - nb
    if d is not None:
        deltas.append(d)
    same = ta[0][0] == tb[0][0]
    if not same:
        disagree.append((key, gap))
    print(f"{key[0]:18} {key[1]:>5} {na if na is not None else float('nan'):9.4f} "
          f"{nb if nb is not None else float('nan'):9.4f} {d if d is not None else float('nan'):9.4f} "
          f"{ta[0][0]:>7} {tb[0][0]:>7} {gap:6.3f}{'' if same else '  <- top-1 differs'}")
mean = sum(deltas) / len(deltas)
worst = max(abs(x) for x in deltas)
print(f"\nscored endpoints {len(deltas)}; mean dNLL {mean:+.5f}; worst |dNLL| {worst:.5f}")
print(f"Q1 {'held' if abs(mean) <= 0.01 and worst <= 0.05 else 'FAILED'} (mean within 0.01, worst within 0.05)")
bad = [k for k, gap in disagree if gap > 0.1]
print(f"top-1 agreement {len(b) - len(disagree)}/{len(b)}; disagreements at B gap > 0.1: {bad}")
print(f"Q2 {'held' if not bad else 'FAILED'}")

# The amended gate (predictions.md, "Amendment"): Q1' mean within 0.02,
# Q2' |dNLL| <= 0.10 where B's NLL <= 5, Q3' as Q2.
in_dist = [(k, a[k][0] - b[k][0]) for k in b if k in a and b[k][0] is not None and b[k][0] <= 5]
worst_in = max((abs(d) for _, d in in_dist), default=0.0)
print(f"\nQ1' {'held' if abs(mean) <= 0.02 else 'FAILED'} (mean {mean:+.5f}, within 0.02)")
print(f"Q2' {'held' if worst_in <= 0.10 else 'FAILED'} (worst |dNLL| {worst_in:.5f} over {len(in_dist)} endpoints with B NLL <= 5)")
print(f"Q3' {'held' if not bad else 'FAILED'}")
