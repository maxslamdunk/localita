"""Per-run figures from logs/decode-*.log, then B-against-A per case.

A = early read off, B = on; each case runs A1 B1 B2 A2. Thermal is the share
of the run's samples in each state.
"""
import collections, glob, os, re

here = os.path.dirname(os.path.abspath(__file__))
KEYS = ("done", "expert-io", "phase-time", "gpu-time", "generated")
runs = {}
for path in sorted(glob.glob(os.path.join(here, "logs", "decode-*.log"))):
    label = re.match(r"decode-(\w+-[AB]\d)-", os.path.basename(path)).group(1)
    pick, thermal = {}, collections.Counter()
    for line in open(path).read().splitlines():
        m = re.match(r"(?:\d+, )+(%s), (.*)" % "|".join(KEYS), line)
        if m:
            pick[m.group(1)] = m.group(2)
        t = re.search(r"thermal=(\w+)", line)
        if t:
            thermal[t.group(1)] += 1

    def num(key, name):
        return float(re.search(r"(?<![\w-])%s=([\d.]+)" % re.escape(name), pick[key]).group(1))

    r = dict(
        tps=num("done", "tok/s"), new=int(num("done", "new")),
        mb=num("expert-io", "bytes/tok"), hit=num("expert-io", "hit-rate"),
        reads=num("expert-io", "reads/tok"),
        io=num("phase-time", "io"), wait=num("phase-time", "cb1-wait"),
        wall=num("phase-time", "wall"), gcb1=num("gpu-time", "cb1"),
        sha=re.search(r"sha256=(\w{8})", pick["generated"]).group(1),
        thermal=" ".join("%s %d" % kv for kv in sorted(thermal.items())),
        early=0.0, used=0.0)
    if "early decode" in pick["expert-io"]:
        r["early"] = float(
            re.search(r"early decode reads/tok=([\d.]+)", pick["expert-io"]).group(1))
        r["used"] = float(re.search(r"used/tok=([\d.]+)", pick["expert-io"]).group(1))
    runs[label] = r

print("%-10s %6s %4s %8s %8s %6s %7s %7s %7s %7s %6s %6s %-9s %s" % (
    "run", "tok/s", "new", "MB/tok", "hit", "reads", "early", "used", "io", "cb1w",
    "gcb1", "wall", "sha", "thermal"))
for label, r in runs.items():
    print("%-10s %6.3f %4d %8.2f %7.1f%% %6.2f %7.2f %7.2f %7.2f %7.2f %6.2f %6.1f %-9s %s" % (
        label, r["tps"], r["new"], r["mb"], r["hit"], r["reads"], r["early"], r["used"],
        r["io"], r["wait"], r["gcb1"], r["wall"], r["sha"], r["thermal"]))

print()
for case in ("short", "medium", "long"):
    a = [runs[k] for k in (case + "-A1", case + "-A2") if k in runs]
    b = [runs[k] for k in (case + "-B1", case + "-B2") if k in runs]
    if not a or not b:
        continue
    mean = lambda xs, k: sum(x[k] for x in xs) / len(xs)
    d_io = mean(b, "io") - mean(a, "io")
    print("%s: tok/s A %.3f B %.3f (%+.1f%%) | io %+.2f ms | cb1-wait %+.2f ms | "
          "reads/tok %+.2f (issued - used %.2f) | precision %.3f | io per used read %.2f ms | "
          "texts %s, hit %s" % (
              case, mean(a, "tps"), mean(b, "tps"), 100 * (mean(b, "tps") / mean(a, "tps") - 1),
              d_io, mean(b, "wait") - mean(a, "wait"),
              mean(b, "reads") - mean(a, "reads"), mean(b, "early") - mean(b, "used"),
              mean(b, "used") / mean(b, "early"), -d_io / mean(b, "used"),
              "identical" if len({x["sha"] for x in a + b}) == 1 else "DIFFER",
              "identical" if len({x["hit"] for x in a + b}) == 1 else "DIFFER"))
