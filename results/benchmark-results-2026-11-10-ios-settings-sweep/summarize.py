#!/usr/bin/env python3
"""Prints every figure in results.md from the sweep's seven reports.

    python3 results/benchmark-results-2026-11-10-ios-settings-sweep/summarize.py \
        benchmark-submissions/submissions.jsonl
"""
import json
import re
import sys

SWEEP = "20261111T061352Z"
CASES = ["short-explanation", "medium-review", "long-synthesis"]
SHORT = {"short-explanation": "short", "medium-review": "medium", "long-synthesis": "long"}

# predictions.md, "What moves": absolute tok/s, and % against 24 / off.
PRED_ABS = {
    (24, 0.0): [(11.4, 13.3), (10.1, 11.9), (8.7, 10.3)],
    (24, 0.08): [(14.2, 15.0), (12.4, 13.0), (10.8, 11.3)],
    (24, 0.1): [(15.4, 16.9), (13.7, 14.9), (11.7, 13.4)],
    (32, 0.0): [(13.9, 16.5), (12.3, 14.1), (10.3, 11.7)],
    (32, 0.08): [(15.1, 18.3), (13.4, 16.0), (11.5, 13.7)],
    (32, 0.1): [(15.9, 19.4), (14.2, 17.3), (12.3, 15.0)],
}
PRED_REL = {
    (24, 0.08): [(15, 22), (13, 18), (13, 19)],
    (24, 0.1): [(25, 37), (24, 36), (23, 41)],
    (32, 0.0): [(13, 34), (11, 28), (9, 23)],
    (32, 0.08): [(22, 48), (22, 46), (21, 44)],
    (32, 0.1): [(29, 57), (29, 57), (29, 58)],
}


def footer(case, prefix):
    line = next(f for f in case["footers"] if f.startswith(prefix))
    return line


def num(line, key):
    return float(re.search(re.escape(key) + r"=([\d.]+)", line).group(1))


def parse(case):
    io = footer(case, "[expert-io")
    pt = footer(case, "[phase-time")
    gt = footer(case, "[gpu-time")
    rl = footer(case, "[read-latency")
    reads = num(io, "reads/tok")
    early = float(re.search(r"early decode reads/tok=([\d.]+)", io).group(1))
    return {
        "tps": case["newTokens"] / case["decodeSeconds"],
        "mib": case["decodeMiBPerToken"],
        "hit": case["decodeCacheHitRate"] * 100,
        "reads": reads,
        "early": early,
        "used": num(io, "used/tok"),
        "fg": reads - early,
        "prefill_mb": float(re.search(r"prefill bytes=([\d.]+)", io).group(1)),
        "io": num(pt, "io"),
        "cb1w": num(pt, "cb1-wait"),
        "head": num(pt, "head"),
        "wall": num(pt, "wall"),
        "g_cb1": num(gt, " cb1"),
        "g_shared": num(gt, "shared"),
        "g_hit": num(gt, "hit-experts"),
        "g_routed": num(gt, "routed"),
        "g_head": num(gt, "head"),
        "g_busy": num(gt, "busy"),
        "g_idle": num(gt, "idle"),
        "read_mean": float(re.search(r"mean=([\d.]+)ms", rl).group(1)),
        "sha": case["generatedSHA256"],
        "tokens": case["newTokens"],
        "stop": case["stopReason"],
        "peak": case["peakFootprintBytes"] / 1e9,
        "foot": case["footprintBytes"] / 1e9,
        "avail": case["availableMemoryBytes"] / 1e9,
        "th": f'{case["thermalAtStart"]}/{case["thermalAtEnd"]}',
        "prefill_s": case["prefillSeconds"],
        "cool": case["cooldownSeconds"],
        "prompt": case["promptSHA256"],
    }


def load(path):
    runs = []
    for line in open(path):
        r = json.loads(line)["report"]
        if (r.get("sweep") or {}).get("id") == SWEEP:
            runs.append(r)
    runs.sort(key=lambda r: r["sweep"]["index"])
    assert [r["sweep"]["index"] for r in runs] == list(range(1, 8)), "need all 7 runs"
    return runs


def key(r):
    s = r["settings"]
    return (s["expertCacheSlots"], float(s.get("expertSkipThreshold") or 0.0))


def verdict(x, lo, hi):
    return "in" if lo <= x <= hi else ("above" if x > hi else "below")


def main():
    runs = load(sys.argv[1])
    m = {r["sweep"]["index"]: {c["caseID"]: parse(c) for c in r["cases"]} for r in runs}
    k = {r["sweep"]["index"]: key(r) for r in runs}

    print("== Runs")
    for r in runs:
        i = r["sweep"]["index"]
        s = r["settings"]
        print(f"run {i}: slots {k[i][0]} skip {k[i][1]} early {s['earlyExpertReads']} "
              f"{r['started']} → {r['finished']} battery {r['device']['batteryAtStart']} "
              f"outcome {list(r['outcome'])}")
    print("device", runs[0]["device"]["identifier"], runs[0]["device"]["osVersion"],
          runs[0]["device"]["appVersion"], runs[0]["device"]["physicalMemoryBytes"])

    print("\n== Per case")
    for i in range(1, 8):
        for c in CASES:
            d = m[i][c]
            print(f"run {i} {SHORT[c]:6} tps {d['tps']:6.3f} MiB/t {d['mib']:7.2f} hit {d['hit']:5.1f} "
                  f"fg {d['fg']:5.2f} io {d['io']:5.2f} cb1w {d['cb1w']:5.2f} wall {d['wall']:6.2f} "
                  f"gpu cb1 {d['g_cb1']:5.2f} shared {d['g_shared']:5.2f} head {d['g_head']:4.2f} "
                  f"busy {d['g_busy']:5.2f} mean {d['read_mean']:.2f} peak {d['peak']:.3f} "
                  f"foot {d['foot']:.3f} avail {d['avail']:.3f} th {d['th']} cool {d['cool']:.0f} "
                  f"tok {d['tokens']} {d['stop']} sha {d['sha'][:8]}")

    print("\n== Noise floor: run 1 vs run 7")
    gap = {}
    for c in CASES:
        a, b = m[1][c]["tps"], m[7][c]["tps"]
        gap[c] = abs(a - b)
        print(f"{SHORT[c]:6} {a:.3f} vs {b:.3f}: {gap[c]:.3f} tok/s, {100 * gap[c] / min(a, b):.1f}%")

    print("\n== Predicted ranges, absolute")
    for i in range(1, 8):
        for j, c in enumerate(CASES):
            lo, hi = PRED_ABS[k[i]][j]
            x = m[i][c]["tps"]
            print(f"run {i} {k[i]} {SHORT[c]:6} {x:6.2f} in {lo}–{hi}: {verdict(x, lo, hi)}")

    print("\n== Against run 5 (24 / off)")
    for i in range(1, 8):
        if i == 5:
            continue
        for j, c in enumerate(CASES):
            rel = 100 * (m[i][c]["tps"] / m[5][c]["tps"] - 1)
            lo, hi = PRED_REL[k[i]][j]
            print(f"run {i} {k[i]} {SHORT[c]:6} {rel:+6.1f}% in +{lo} to +{hi}: {verdict(rel, lo, hi)}")

    print("\n== Decision rule")
    for c in CASES:
        d25 = m[2][c]["tps"] - m[5][c]["tps"]
        d4 = m[4][c]["tps"] - max(m[1][c]["tps"], m[7][c]["tps"])
        print(f"{SHORT[c]:6} run2−run5 {d25:+.3f}  run4−max(run1,run7) {d4:+.3f}  gap {gap[c]:.3f}  "
              f"pass {d25 > gap[c] and d4 > gap[c]}")

    print("\n== Controls")
    for c in CASES:
        print(f"{SHORT[c]:6} text run1==run7 {m[1][c]['sha'] == m[7][c]['sha']}  "
              f"run2==run5 {m[2][c]['sha'] == m[5][c]['sha']}")
    early = {m[i][c]["early"] for i in m for c in CASES}
    print("early reads/tok values:", early)
    for c in CASES:
        print(f"{SHORT[c]:6} prefill MB values: {sorted({m[i][c]['prefill_mb'] for i in m})}  "
              f"prompt SHA values: {len({m[i][c]['prompt'] for i in m})}")
    pairs = {0.0: (5, 2), 0.08: (1, 4), 0.1: (3, 6)}
    for skip, (a, b) in pairs.items():
        print(f"hit rate 32 − 24 at skip {skip}: " + " / ".join(
            f"{m[b][c]['hit'] - m[a][c]['hit']:+.1f}" for c in CASES))

    print("\n== Diminishing returns: 0.10 over 0.08")
    for c in CASES:
        base24 = (m[1][c]["tps"] + m[7][c]["tps"]) / 2
        g24 = 100 * (m[3][c]["tps"] / base24 - 1)
        g24_1 = 100 * (m[3][c]["tps"] / m[1][c]["tps"] - 1)
        g24_7 = 100 * (m[3][c]["tps"] / m[7][c]["tps"] - 1)
        g32 = 100 * (m[6][c]["tps"] / m[4][c]["tps"] - 1)
        r24 = (m[1][c]["fg"] + m[7][c]["fg"]) / 2 - m[3][c]["fg"]
        r32 = m[4][c]["fg"] - m[6][c]["fg"]
        print(f"{SHORT[c]:6} at 24 {g24:+.1f}% (vs run1 {g24_1:+.1f}, vs run7 {g24_7:+.1f}), "
              f"at 32 {g32:+.1f}%; fg reads removed 24 {r24:.2f}, 32 {r32:.2f}")

    print("\n== Peak footprint (process peak since launch)")
    for c in CASES:
        print(f"{SHORT[c]:6} run1 {m[1][c]['peak']:.3f}  run2 {m[2][c]['peak']:.3f}  "
              f"Δ {m[2][c]['peak'] - m[1][c]['peak']:+.3f} GB; footprint+available run1 "
              f"{m[1][c]['foot'] + m[1][c]['avail']:.3f}, run2 {m[2][c]['foot'] + m[2][c]['avail']:.3f}")

    print("\n== Mechanism: run 5 → run 2 (same text, slots only)")
    for c in CASES:
        a, b = m[5][c], m[2][c]
        dr = a["fg"] - b["fg"]
        print(f"{SHORT[c]:6} fg reads −{dr:.2f}; io {b['io'] - a['io']:+.2f}, cb1-wait "
              f"{b['cb1w'] - a['cb1w']:+.2f}, wall {b['wall'] - a['wall']:+.2f} ms; "
              f"wall per removed read {(a['wall'] - b['wall']) / dr:.2f} ms, io per removed read "
              f"{(a['io'] - b['io']) / dr:.2f} ms; GPU shared {a['g_shared']:.2f}→{b['g_shared']:.2f}, "
              f"head {a['g_head']:.2f}→{b['g_head']:.2f}, cb1 {a['g_cb1']:.2f}→{b['g_cb1']:.2f}")

    print("\n== Run 2 (32 / off) against runs 1 and 7 (24 / 0.08)")
    for c in CASES:
        print(f"{SHORT[c]:6} fg reads {m[2][c]['fg']:.2f} vs {m[1][c]['fg']:.2f}; tok/s "
              f"{m[2][c]['tps']:.2f} vs {m[1][c]['tps']:.2f} / {m[7][c]['tps']:.2f}; "
              f"MiB/t {m[2][c]['mib']:.2f} vs {m[1][c]['mib']:.2f}")

    print("\n== Run 4 (32 / 0.08) against runs 1 and 7 (24 / 0.08)")
    for c in CASES:
        x = m[4][c]["tps"]
        print(f"{SHORT[c]:6} {x:.2f}: +{100 * (x / m[1][c]['tps'] - 1):.1f}% over run 1, "
              f"+{100 * (x / m[7][c]['tps'] - 1):.1f}% over run 7")


if __name__ == "__main__":
    main()
