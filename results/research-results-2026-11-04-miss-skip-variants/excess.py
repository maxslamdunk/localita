#!/usr/bin/env python3
"""Score each run against the `miss:<t>` curve, as predictions.md defines it.

For each run, the `miss` KL is interpolated piecewise linearly at the run's
own read cut, through no skip (0, 0) and the 2026-10-04 `miss05`, `miss08`
and `miss10` runs. It is done per transcript, so each run's per-transcript KL
is paired with the interpolated `miss` KL of the same transcript. Excess is
the ratio of the sums. The 95% interval resamples the 12 transcripts: 2,000
draws, 2.5th and 97.5th percentiles.

    excess.py [label ...]
"""
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(HERE, "logs")
OLD = os.path.join(HERE, "..", "research-results-2026-10-04-lossy-experts", "logs")
CURVE = ["miss05", "miss08", "miss10"]
RUNS = ["miss08", "cum0.85", "cum0.80", "early0.10", "early0.30", "miss08+early0.30", "bias05+miss08"]


def fg(path):
    m = re.search(r"^decode: .*fg reads/tok ([\d.]+)", open(path).read(), re.M)
    return float(m[1])


def per_seq(path):
    a = np.loadtxt(path, comments="#")  # seq index kl nll refnll top1
    seqs = np.unique(a[:, 0]).astype(int)
    kl = np.array([a[a[:, 0] == s, 2].sum() for s in seqs])
    return a, kl


def main():
    ref_fg = fg(os.path.join(OLD, "ref.txt"))
    cuts = [0.0] + [1 - fg(os.path.join(OLD, c + ".txt")) / ref_fg for c in CURVE]
    curve = [None] + [per_seq(os.path.join(OLD, c + ".pos"))[1] for c in CURVE]
    curve[0] = np.zeros_like(curve[1])
    print("# miss curve: " + ", ".join("%s −%.1f%%" % (c, 100 * x) for c, x in zip(CURVE, cuts[1:])))
    print("%-18s %9s %8s %16s %8s %8s %18s" % (
        "run", "fg reads", "cut", "KL [95% CI]", "top1", "missKL", "excess [95% CI]"))
    rng = np.random.default_rng(0)
    for label in sys.argv[1:] or RUNS:
        pos = os.path.join(LOGS, label + ".pos")
        if not os.path.exists(pos):
            print("%-18s (not run)" % label)
            continue
        a, kl = per_seq(pos)
        cut = 1 - fg(os.path.join(LOGS, label + ".txt")) / ref_fg
        i = max(1, min(int(np.searchsorted(cuts, cut)), len(cuts) - 1))
        w = (cut - cuts[i - 1]) / (cuts[i] - cuts[i - 1])
        base = (1 - w) * curve[i - 1] + w * curve[i]
        n = len(a) / len(kl)
        draws_kl, draws_ex = [], []
        for _ in range(2000):
            pick = rng.integers(0, len(kl), len(kl))
            draws_kl.append(kl[pick].sum() / (n * len(kl)))
            draws_ex.append(kl[pick].sum() / base[pick].sum())
        klo, khi = np.percentile(draws_kl, [2.5, 97.5])
        elo, ehi = np.percentile(draws_ex, [2.5, 97.5])
        print("%-18s %9.2f %+7.1f%% %.4f [%.4f, %.4f] %7.4f %8.4f %5.2f [%.2f, %.2f]" % (
            label, fg(os.path.join(LOGS, label + ".txt")), -100 * cut, a[:, 2].mean(), klo, khi,
            a[:, 5].mean(), base.sum() / len(a), kl.sum() / base.sum(), elo, ehi))


if __name__ == "__main__":
    main()
