#!/usr/bin/env python3
"""Do cache misses concentrate on rarely used experts? An offline probe.

If they do, a format that stores only the cold experts at fewer bits saves a
larger share of read bytes than of expert uses, and the quality cost follows
uses. Popularity (use counts per layer and expert) comes from the training
traces that the quality meter does not score; misses and uses are then
counted on the held-out traces (val-*, test-*) under the runtime's cache
(count-aged LFU 0.97, 24 slots, early read on).

Writes cold-<share>.txt files ("layer expert" per line): the least used
experts of each layer, up to the given share of experts.

    cold_experts.py
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../research-results-2026-10-03-cache-policy/sim"))
import sim  # noqa: E402
from policies import DecayLFU  # noqa: E402

TRACES = "/Users/max/ml_projects/iphone-port/turbo-fieldfare/scratch/cache-traces"
SCORED = {"train-math-proof", "train-ru-history", "train-ja-haiku", "train-py-lru"}
HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    traces = sim.load(TRACES)
    fit = [t for t in traces if t.name.startswith("train-") and t.name not in SCORED]
    held = [t for t in traces if t.name.startswith(("val-", "test-"))]
    L, E = fit[0].L, fit[0].E
    pop = np.zeros((L, E))
    for t in fit:
        for l in range(L):
            np.add.at(pop[l], t.experts[:, l].ravel(), 1)
    uses = np.zeros((L, E))
    fg = np.zeros((L, E))
    for t in held:
        pols = [DecayLFU(slots=24, decay=0.97, layer=l, trace=t) for l in range(L)]
        for tok in range(t.T):
            guess = None
            for l in range(L):
                chosen = [int(e) for e in t.experts[tok, l]]
                m = pols[l].access(tok, chosen)
                if tok >= sim.WARMUP:
                    for e in chosen:
                        uses[l, e] += 1
                    for e in m:
                        if e != guess:
                            fg[l, e] += 1
                if l + 1 < L:
                    g = t.guess[tok, l].astype(np.float32).copy()
                    res = pols[l + 1].resident
                    if res:
                        g[list(res)] = -np.inf
                    guess = int(np.argmax(g))
    print("# popularity from %d training traces; misses and uses on %d held-out traces"
          % (len(fit), len(held)))
    print("cold share of experts -> share of held-out uses, of foreground reads")
    order = np.argsort(pop, axis=1, kind="stable")  # least used first, per layer
    for share in (0.25, 0.5, 0.625, 0.75):
        k = int(round(share * E))
        mask = np.zeros((L, E), bool)
        for l in range(L):
            mask[l, order[l, :k]] = True
        print("  %4.1f%% -> uses %5.1f%%, fg reads %5.1f%%" % (
            100 * share, 100 * uses[mask].sum() / uses.sum(), 100 * fg[mask].sum() / fg.sum()))
        with open(os.path.join(HERE, "cold-%d.txt" % round(100 * share)), "w") as f:
            for l in range(L):
                for e in sorted(order[l, :k]):
                    f.write("%d %d\n" % (l, e))


if __name__ == "__main__":
    main()
