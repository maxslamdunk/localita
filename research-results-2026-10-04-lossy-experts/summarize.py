#!/usr/bin/env python3
"""Tabulate the scored runs: quality against the reference, and reads.

Reads logs/<label>.txt (footer lines) and logs/<label>.pos (per-position KL,
NLL, top-1 agreement). Confidence intervals resample whole sequences (12),
not tokens, since tokens within a sequence are correlated: 2,000 bootstrap
draws, 2.5th and 97.5th percentiles.

    summarize.py [label ...]
"""
import glob
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(HERE, "logs")
EXPERT_BYTES = {
    "all=3": 2_601_984, "gate=3,up=3": 2_849_792, "down=3": 3_097_600, "all=2": 1_858_560,
}


def footer(label):
    text = open(os.path.join(LOGS, label + ".txt")).read()
    out = {}
    m = re.search(r"fg reads/tok ([\d.]+), early reads/tok ([\d.]+), MiB/tok ([\d.]+), hit ([\d.]+)%, ([\d.]+) s/tok", text)
    if m:
        out.update(fg=float(m[1]), early=float(m[2]), mib=float(m[3]), hit=float(m[4]), spt=float(m[5]))
    m = re.search(r"dropped/layer ([\d.]+), dropped mass/layer ([\d.]+)", text)
    if m:
        out.update(dropped=float(m[1]), mass=float(m[2]))
    m = re.search(r"env: (.*)", text)
    out["env"] = m[1].strip() if m else ""
    return out


def positions(label):
    path = os.path.join(LOGS, label + ".pos")
    if not os.path.exists(path):
        return None
    a = np.loadtxt(path, comments="#")
    return a  # seq index kl nll refnll top1


def boot(a, stat, rng, draws=2000):
    seqs = np.unique(a[:, 0]).astype(int)
    groups = [a[a[:, 0] == s] for s in seqs]
    vals = []
    for _ in range(draws):
        pick = rng.integers(0, len(groups), len(groups))
        vals.append(stat(np.concatenate([groups[i] for i in pick])))
    return np.percentile(vals, [2.5, 97.5])


def main():
    labels = sys.argv[1:] or sorted(
        os.path.basename(p)[:-4] for p in glob.glob(os.path.join(LOGS, "*.pos"))
        if not os.path.basename(p).startswith("smoke"))
    ref = footer("ref")
    rng = np.random.default_rng(0)
    print("# reference: fg reads/tok %.2f, MiB/tok %.2f, hit %.1f%%" % (ref["fg"], ref["mib"], ref["hit"]))
    print("%-14s %8s %17s %7s %8s %9s %8s %7s" % (
        "run", "KL", "95% CI", "top1", "dNLL", "fg reads", "d fg", "mass/L"))
    for label in labels:
        a = positions(label)
        if a is None:
            continue
        f = footer(label)
        kl = a[:, 2].mean()
        lo, hi = boot(a, lambda x: x[:, 2].mean(), rng)
        top1 = a[:, 5].mean()
        dnll = (a[:, 3] - a[:, 4]).mean()
        print("%-14s %8.4f [%7.4f, %7.4f] %7.4f %+8.4f %9.2f %+7.1f%% %7.4f" % (
            label, kl, lo, hi, top1, dnll, f.get("fg", float("nan")),
            100 * (f.get("fg", np.nan) / ref["fg"] - 1), f.get("mass", 0.0)))


if __name__ == "__main__":
    main()
