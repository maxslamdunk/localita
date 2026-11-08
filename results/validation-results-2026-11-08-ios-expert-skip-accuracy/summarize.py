#!/usr/bin/env python3
"""Prints each arm's per-problem decode footers pooled over its 50 problems, weighted by
forwards, with the thermal samples. The expert-skip line is cumulative since load, so its
last value is used. Speed is a by-product here: the arms were not cooled."""
import glob, os, re
from collections import Counter

here = os.path.dirname(os.path.abspath(__file__))

def pooled(log):
    text = open(log).read()
    cases, skip = {}, (None, None)
    for line in text.splitlines():
        case = re.search(r" case=(gsmp2-\d+)", line)
        if not case:
            continue
        c = cases.setdefault(case.group(1), {})
        if m := re.search(r"\[expert-io decode bytes/tok=([\d.]+)MB hit-rate=([\d.]+)% req/tok=[\d.]+ "
                          r"reads/tok=([\d.]+) forwards=(\d+)", line):
            c["bytes"], c["hit"], c["reads"], c["fwd"] = map(float, m.groups())
        if m := re.search(r"\[phase-time decode ms/fwd cb1=[\d.]+ cb1-wait=([\d.]+) io=([\d.]+) .*?"
                          r"head=([\d.]+) wall=([\d.]+)", line):
            c["cb1-wait"], c["io"], c["head"], c["wall"] = map(float, m.groups())
        if m := re.search(r"\[read-latency decode reads=(\d+) mean=([\d.]+)ms", line):
            c["read-mean"] = float(m.group(2))
        if m := re.search(r"dropped/layer ([\d.]+), dropped mass/layer ([\d.]+)", line):
            skip = tuple(map(float, m.groups()))  # cumulative since load, so the last line is the session's
        if m := re.search(r"new=(\d+)tok decode=([\d.]+)s", line):
            c["new"], c["decode-s"] = int(m.group(1)), float(m.group(2))
    rows = [c for c in cases.values() if "fwd" in c]
    fwd = sum(c["fwd"] for c in rows)
    mean = lambda k: sum(c[k] * c["fwd"] for c in rows) / fwd if all(k in c for c in rows) else None
    out = {k: mean(k) for k in ("bytes", "hit", "reads", "cb1-wait", "io", "head", "wall", "read-mean")}
    out["dropped"], out["mass"] = skip
    out["tok/s"] = sum(c["new"] for c in rows) / sum(c["decode-s"] for c in rows)
    out["cases"] = len(rows)
    out["thermal"] = Counter(re.findall(r"thermal=(\w+)", text))
    return out

arms = {}
for label in ("acc-A", "acc-B"):
    (log,) = glob.glob(os.path.join(here, "logs", f"decode-{label}-*Z.log"))
    arms[label] = pooled(log)
    a = arms[label]
    fmt = lambda v: "—" if v is None else f"{v:.3f}"
    print(f"{label}: cases {a['cases']}, tok/s {a['tok/s']:.3f}, " +
          ", ".join(f"{k} {fmt(a[k])}" for k in ("bytes", "hit", "reads", "io", "cb1-wait", "head", "wall",
                                                  "read-mean", "dropped", "mass")) +
          f"; thermal {dict(a['thermal'])}")
A, B = arms["acc-A"], arms["acc-B"]
for k in ("tok/s", "bytes", "reads", "io", "cb1-wait", "head", "wall", "read-mean"):
    print(f"B vs A {k}: {100 * (B[k] / A[k] - 1):+.1f}%")
print(f"B vs A hit: {B['hit'] - A['hit']:+.1f} pt; foreground reads/tok {A['reads'] - 29:.2f} -> {B['reads'] - 29:.2f} "
      f"({100 * ((B['reads'] - 29) / (A['reads'] - 29) - 1):+.1f}%)")
