#!/usr/bin/env python3
"""Per-case and whole-session figures for the expert-cache aging A/B.

Each session log holds one `done` / footer / `generated` group per case,
tagged ` case=<id>`. Whole-session figures weight by decode forwards (tokens):
tok/s is total new tokens over total decode seconds.
"""
import glob, hashlib, os, re, statistics as st

here = os.path.dirname(os.path.abspath(__file__))


def field(line, key):
    m = re.search(rf"(?<![\w-]){re.escape(key)}=([\d.]+)", line)
    return float(m.group(1)) if m else float("nan")


def parse(log):
    lines = open(log).read().splitlines()
    text = "\n".join(lines)
    if ", session-done, " not in text:
        return None
    label = re.search(r"decode-(.+?)-\d{4}-", os.path.basename(log)).group(1)
    cases = {}
    for line in lines:
        m = re.search(r" case=([\w-]+)$", line)
        if not m:
            continue
        c = cases.setdefault(m.group(1), {})
        decode = line.split(" | ")[0]
        if ", done, " in line:
            c["new"] = field(line, "new")
            c["sec"] = float(re.search(r"decode=([\d.]+)s", line).group(1))
            c["toks"] = field(line, "tok/s")
        elif ", expert-io, " in line:
            c["mb"] = float(re.search(r"bytes/tok=([\d.]+)MB", line).group(1))
            c["hit"] = field(decode, "hit-rate")
            c["reads"] = field(decode, "reads/tok")
            c["fwd"] = field(decode, "forwards")
            c["used"] = field(line, "used/tok")
            c["early"] = field(line.split("early decode")[-1], "reads/tok") if "early decode" in line else float("nan")
        elif ", phase-time, " in line:
            c["io"] = field(decode, "io")
            c["wall"] = field(decode, "wall")
            c["cb1w"] = field(decode, "cb1-wait")
        elif ", gpu-time, " in line:
            c["ghead"] = field(decode, "head")
        elif ", generated, " in line:
            c["sha"] = re.search(r"sha256=(\w{8})", line).group(1)
    thermal = re.findall(r"thermal=(\w+)", text)
    return dict(label=label, arm=label.split("-")[1][0],
                aging=re.search(r"expertCacheAging=(\w+)", text).group(1),
                cases=cases, thermal=",".join(sorted(set(thermal))),
                battery=re.search(r"battery=([\w%/]+)", text).group(1))


def whole(r):
    cs = list(r["cases"].values())
    fwd = sum(c["fwd"] for c in cs)
    w = lambda k: sum(c[k] * c["fwd"] for c in cs) / fwd
    return dict(toks=sum(c["new"] for c in cs) / sum(c["sec"] for c in cs),
                mb=w("mb"), hit=w("hit"), reads=w("reads"), used=w("used"),
                io=w("io"), wall=w("wall"), cb1w=w("cb1w"), ghead=w("ghead"), fwd=fwd)


runs = [r for r in (parse(p) for p in sorted(glob.glob(os.path.join(here, "logs", "decode-*.log")))) if r]
keys = ["toks", "mb", "hit", "reads", "used", "io", "wall", "cb1w", "ghead"]
print("whole session, per run")
print("%-9s %5s " % ("label", "aging") + " ".join("%8s" % k for k in keys) + "  battery, thermal")
for r in runs:
    s = whole(r)
    print("%-9s %5s " % (r["label"], r["aging"]) + " ".join("%8.2f" % s[k] for k in keys)
          + "  %s, %s" % (r["battery"], r["thermal"]))

a = [r for r in runs if r["arm"] == "A"]
b = [r for r in runs if r["arm"] == "B"]
if a and b:
    print("\nwhole session, means: A n=%d, B n=%d" % (len(a), len(b)))
    for k in keys:
        ma, mb = st.mean(whole(r)[k] for r in a), st.mean(whole(r)[k] for r in b)
        print("  %6s  A %8.3f  B %8.3f  B-A %+8.3f (%+.1f%%)" % (k, ma, mb, mb - ma, 100 * (mb - ma) / ma))
    print("\nper case, means (hit %, tok/s, io ms, head GPU ms), and texts")
    for case in a[0]["cases"]:
        m = lambda rs, k: st.mean(r["cases"][case][k] for r in rs)
        shas = sorted({r["cases"][case]["sha"] for r in a + b})
        print("  %-18s hit %5.1f -> %5.1f (%+5.1f)  tok/s %6.3f -> %6.3f (%+5.1f%%)  io %6.1f -> %6.1f  head %5.2f -> %5.2f  texts %s" % (
            case, m(a, "hit"), m(b, "hit"), m(b, "hit") - m(a, "hit"),
            m(a, "toks"), m(b, "toks"), 100 * (m(b, "toks") / m(a, "toks") - 1),
            m(a, "io"), m(b, "io"), m(a, "ghead"), m(b, "ghead"),
            shas[0] if len(shas) == 1 else "DIFFER " + ",".join(shas)))
