"""Per-run figures from logs/decode-*.log, then B-against-A per case.

Early read on in both arms: N = the next layer's router,
F = the fitted guess shipped for supergemma4; each case runs N1 F1 F2 N2. Thermal is the count of the
run's samples in each state.
"""
import collections, glob, os, re

here = os.path.dirname(os.path.abspath(__file__))
KEYS = ("done", "expert-io", "phase-time", "gpu-time", "generated", "runner-ready")
runs = {}
for path in sorted(glob.glob(os.path.join(here, "logs", "decode-*.log"))):
    label = re.match(r"decode-(\w+-[NF]\d)-", os.path.basename(path)).group(1)
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
        ghead=num("gpu-time", "head"),
        sha=re.search(r"sha256=(\w{8})", pick["generated"]).group(1),
        thermal=" ".join("%s %d" % kv for kv in sorted(thermal.items())),
        guess=re.search(r"earlyExpertGuess=(\S+)", pick["runner-ready"]).group(1)[:30],
        peak=num("done", "peak") / 1e9, early=0.0, used=0.0)
    if "early decode" in pick["expert-io"]:
        r["early"] = float(
            re.search(r"early decode reads/tok=([\d.]+)", pick["expert-io"]).group(1))
        r["used"] = float(re.search(r"used/tok=([\d.]+)", pick["expert-io"]).group(1))
    runs[label] = r

print("%-12s %6s %4s %8s %8s %6s %7s %7s %7s %7s %6s %6s %6s %-9s %-30s %s" % (
    "run", "tok/s", "new", "MB/tok", "hit", "reads", "early", "used", "io", "cb1w",
    "gcb1", "wall", "peakGB", "sha", "guess", "thermal"))
for label, r in runs.items():
    print("%-12s %6.3f %4d %8.2f %7.1f%% %6.2f %7.2f %7.2f %7.2f %7.2f %6.2f %6.1f %6.3f %-9s %-30s %s" % (
        label, r["tps"], r["new"], r["mb"], r["hit"], r["reads"], r["early"], r["used"],
        r["io"], r["wait"], r["gcb1"], r["wall"], r["peak"], r["sha"], r["guess"], r["thermal"]))

print()
for case in ("sg4short", "sg4medium", "sg4long"):
    a = [runs[k] for k in (case + "-N1", case + "-N2") if k in runs]
    b = [runs[k] for k in (case + "-F1", case + "-F2") if k in runs]
    if not a or not b:
        continue
    mean = lambda xs, k: sum(x[k] for x in xs) / len(xs)
    d_io = mean(b, "io") - mean(a, "io")
    d_used = mean(b, "used") - mean(a, "used")
    print("%s: tok/s N %.3f F %.3f (%+.1f%%) | io %+.2f ms | cb1-wait %+.2f ms | "
          "GPU attn+router %+.2f ms | GPU head N %.2f F %.2f ms | reads/tok %+.2f (minus extra used %.2f) | "
          "MB/tok %.2f -> %.2f | precision N %.3f F %.3f | io per extra used read %.2f ms | "
          "peak %+.0f MB | texts %s, hit %s" % (
              case, mean(a, "tps"), mean(b, "tps"), 100 * (mean(b, "tps") / mean(a, "tps") - 1),
              d_io, mean(b, "wait") - mean(a, "wait"), mean(b, "gcb1") - mean(a, "gcb1"),
              mean(a, "ghead"), mean(b, "ghead"),
              mean(b, "reads") - mean(a, "reads"), -d_used,
              mean(a, "mb"), mean(b, "mb"),
              mean(a, "used") / mean(a, "early"), mean(b, "used") / mean(b, "early"),
              -d_io / d_used, 1000 * (mean(b, "peak") - mean(a, "peak")),
              "identical" if len({x["sha"] for x in a + b}) == 1 else "DIFFER",
              "identical" if len({x["hit"] for x in a + b}) == 1 else "DIFFER"))
