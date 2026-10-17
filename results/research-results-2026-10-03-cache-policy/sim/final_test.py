"""Score the candidates chosen on val, once, on the held-out test traces.

Usage: final_test.py <traces-dir> <slots> <model-out.json>

Chosen on val (fit-output.txt) before this ran: the linear pairwise-ranking
model at lambda 10 (the quadratic one gained 0.1 point on val and is dropped
for simplicity) and decayed LFU at 0.97.
"""
import sys
import numpy as np

import learned
import sim
from policies import POLICIES, decay_lfu

DECAY = 0.97
LAMBDA = 10


def main():
    directory, slots, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    train = sim.load(directory, "train-")
    parts = [learned.samples(t, slots, every=3) for t in train]
    X = np.concatenate([p[0] for p in parts])
    y = np.concatenate([p[1] for p in parts])
    g, off = [], 0
    for p in parts:
        g.append(p[2] + off); off += p[2].max() + 1
    model = learned.fit_rank(X, y, np.concatenate(g), LAMBDA)
    model["quadratic"] = False
    model["slots"] = slots
    learned.save(model, out)
    print("model: linear rank, lambda %g, %d pairs; weights (standardized):" % (LAMBDA, model["pairs"]))
    for n, w in zip(model["names"], model["w"]):
        print("  %-12s %+.3f" % (n, w))

    test = sim.load(directory, "test-")
    print("\ntest, %d slots, scored once:" % slots)
    for name, f in (("lfu", POLICIES["lfu"]), ("lru", POLICIES["lru"]), ("arc", POLICIES["arc"]),
                    ("decay%g" % DECAY, decay_lfu(DECAY)), ("learned", learned.learned(model)),
                    ("belady", POLICIES["belady"])):
        rows = [sim.summarize(t, sim.replay(t, f, slots)) for t in test]
        for t, r in zip(test, rows):
            print("  %-10s %-24s %s" % (name, t.name, sim.fmt(r)))
        print("  %-10s %-24s %s" % (name, "pooled", sim.fmt(sim.pooled(rows))), flush=True)


if __name__ == "__main__":
    main()
