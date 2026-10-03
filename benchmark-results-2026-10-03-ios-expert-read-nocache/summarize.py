#!/usr/bin/env python3
"""Prints the per-run figures and the A-vs-B means for the F_NOCACHE A/B."""
import glob, hashlib, os, re, statistics as st, sys

here = os.path.dirname(os.path.abspath(__file__))
rows = []
for log in sorted(glob.glob(os.path.join(here, "logs", "decode-*.log"))):
    text = open(log).read()
    if ", generated, " not in text:
        continue
    label = re.search(r"decode-(.+?)-\d{4}-", os.path.basename(log)).group(1)
    def num(pattern):
        m = re.search(pattern, text)
        return float(m.group(1)) if m else float("nan")
    phase = re.search(r"\[phase-time decode [^|]*", text).group(0)
    gpu = re.search(r"\[gpu-time decode [^|]*", text).group(0)
    def field(line, key):
        return float(re.search(rf"\b{key}=([\d.]+)", line).group(1))
    txt = log[:-4] + ".txt"
    sha = hashlib.sha256(open(txt, "rb").read()).hexdigest()[:8] if os.path.exists(txt) else "-"
    filebacked = [int(x) for x in re.findall(r"sys-filebacked=(\d+)", text)]
    thermal = re.findall(r"thermal=(\w+)", text)
    rows.append(dict(
        label=label,
        nocache=re.search(r"expertReadNoCache=(\w+)", text).group(1),
        toks=num(r"decode=[\d.]+s tok/s=([\d.]+)"),
        mb=num(r"\[expert-io decode bytes/tok=([\d.]+)MB"),
        hit=num(r"hit-rate=([\d.]+)%"),
        reads=num(r"reads/tok=([\d.]+) forwards"),
        used=num(r"used/tok=([\d.]+)"),
        io=field(phase, "io"), cb1w=field(phase, "cb1-wait"), wall=field(phase, "wall"),
        gcb1=field(gpu, "cb1"), ghead=field(gpu, "head"),
        lat=num(r"\[read-latency decode reads=\d+ mean=([\d.]+)ms"),
        fb=st.median(filebacked) if filebacked else float("nan"),
        sha=sha,
        thermal=",".join(sorted(set(thermal))) or "-",
    ))

cols = ["label", "nocache", "toks", "mb", "hit", "reads", "used", "io", "cb1w", "wall",
        "gcb1", "ghead", "lat", "fb", "sha", "thermal"]
print(" ".join(f"{c:>9}" for c in cols))
for r in rows:
    print(" ".join(f"{r[c]:>9.2f}" if isinstance(r[c], float) else f"{r[c]:>9}" for c in cols))

for case in sorted({r["label"].split("-")[0] for r in rows}):
    a = [r for r in rows if r["label"].startswith(case + "-A")]
    b = [r for r in rows if r["label"].startswith(case + "-B")]
    if not a or not b:
        continue
    m = lambda rs, k: st.mean(r[k] for r in rs)
    print(f"\n{case}: A n={len(a)} B n={len(b)}")
    for k in ["toks", "io", "lat", "cb1w", "ghead", "gcb1", "wall", "fb", "mb", "reads"]:
        d = m(b, k) - m(a, k)
        pct = f" ({100 * d / m(a, k):+.1f}%)" if k in ("toks", "wall") else ""
        print(f"  {k:>6}: A {m(a, k):9.3f}  B {m(b, k):9.3f}  B-A {d:+8.3f}{pct}")
    print("  texts:", sorted({r["sha"] for r in a + b}))
