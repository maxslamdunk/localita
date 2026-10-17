"""Fit the learned eviction policy on train-, choose the ridge strength on val-,
and with --test score the chosen model once on test-.

Usage: fit_learned.py <traces-dir> <slots> <model-out.json> [--test]
"""
import sys
import numpy as np

import learned
import sim
from policies import LFU, POLICIES, decay_lfu

LAMBDAS = (0.01, 0.1, 1, 10, 100)
DECAYS = (0.9, 0.95, 0.97, 0.98, 0.99, 0.995, 0.998, 0.999)


def score(traces, factory, slots):
    return sim.pooled([sim.summarize(t, sim.replay(t, factory, slots)) for t in traces])


def main():
    directory, slots, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    train, val = sim.load(directory, "train-"), sim.load(directory, "val-")
    print("train %d traces, %d tokens; val %d traces, %d tokens" % (
        len(train), sum(t.T for t in train), len(val), sum(t.T for t in val)), flush=True)
    parts = [learned.samples(t, slots, every=3) for t in train]
    X = np.concatenate([p[0] for p in parts])
    y = np.concatenate([p[1] for p in parts])
    g, off = [], 0
    for p in parts:
        g.append(p[2] + off); off += p[2].max() + 1
    g = np.concatenate(g)
    print("training samples: %d" % len(y), flush=True)

    print("\nval, %d slots:" % slots)
    for name in ("lfu", "lru", "arc", "belady"):
        print("  %-14s %s" % (name, sim.fmt(score(val, POLICIES[name], slots))), flush=True)
    best_decay = None
    for d in DECAYS:
        s = score(val, decay_lfu(d), slots)
        print("  %-14s %s" % ("decay%g" % d, sim.fmt(s)), flush=True)
        if best_decay is None or s["fg"] < best_decay[1]["fg"]:
            best_decay = (d, s)
    best = None
    Xq = learned.expand(X)
    for objective, quad, lams in (("regress", False, (1,)), ("rank", False, (1, 10)),
                                  ("rank", True, (1, 10, 100))):
        for lam in lams:
            XX = Xq if quad else X
            model = learned.fit(XX, y, lam) if objective == "regress" else learned.fit_rank(XX, y, g, lam)
            model["objective"] = objective + ("-quad" if quad else "")
            model["quadratic"] = quad
            s = score(val, learned.learned(model), slots)
            print("  %-14s %s" % ("%s l=%g" % (model["objective"], lam), sim.fmt(s)), flush=True)
            if best is None or s["fg"] < best[1]["fg"]:
                best = (model, s)
    model = best[0]
    model["decay_chosen_on_val"] = best_decay[0]
    learned.save(model, out)
    print("\nchosen: %s, lambda %g, decay %g; weights (standardized):" % (
        model["objective"], model["lam"], best_decay[0]))
    if not model["quadratic"]:
        for n, w in zip(model["names"], model["w"]):
            print("  %-12s %+.3f" % (n, w))

    if "--test" in sys.argv:
        test = sim.load(directory, "test-")
        print("\ntest, %d slots, scored once:" % slots)
        for name, f in (("lfu", LFU), ("decay%g" % best_decay[0], decay_lfu(best_decay[0])),
                        ("learned", learned.learned(model))):
            rows = [sim.summarize(t, sim.replay(t, f, slots)) for t in test]
            for t, r in zip(test, rows):
                print("  %-12s %-26s %s" % (name, t.name, sim.fmt(r)))
            print("  %-12s %-26s %s" % (name, "pooled", sim.fmt(sim.pooled(rows))), flush=True)


if __name__ == "__main__":
    main()
