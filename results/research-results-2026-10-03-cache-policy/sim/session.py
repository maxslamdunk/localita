"""A long app session: traces replayed back to back with no reset, as the app
keeps one process and the runtime never resets LFU counts. Prefill between
turns is not in the traces, so this understates churn between topics.

Usage: session.py <traces-dir> <slots> <policy>... [--prefix train-,val-] [--seed N]

Scores the whole concatenation after the first WARMUP tokens, plus the first
64 tokens of every turn after the first (where stale history should hurt).
"""
import sys
import numpy as np

import sim
import learned
from policies import POLICIES, decay_lfu


def policy(name):
    """A POLICIES name, decay:<rate>, or learned:<model.json>."""
    kind, _, arg = name.partition(":")
    if kind == "decay":
        return decay_lfu(float(arg))
    if kind == "learned":
        return learned.learned(learned.load(arg))
    return POLICIES[name]


class Concat:
    def __init__(self, traces):
        self.name = "session"
        self.experts = np.concatenate([t.experts for t in traces])
        self.scores = np.concatenate([t.scores for t in traces])
        self.guess = np.concatenate([t.guess for t in traces])
        self.T, self.L, self.K = self.experts.shape
        self.E = self.scores.shape[2]
        self.starts = np.cumsum([0] + [t.T for t in traces[:-1]])


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    directory, slots, names = args[0], int(args[1]), args[2:]
    traces = [t for p in opts.get("prefix", "train-,val-").split(",") for t in sim.load(directory, p)]
    order = np.random.default_rng(int(opts.get("seed", 0))).permutation(len(traces))
    s = Concat([traces[i] for i in order])
    starts = s.starts[1:]
    head = np.concatenate([np.arange(a, a + 64) for a in starts])
    print("session: %d turns, %d tokens, %d slots" % (len(traces), s.T, slots))
    for name in names:
        misses, fg, used = sim.replay(s, policy(name), slots)
        whole = sim.summarize(s, (misses, fg, used))
        n = len(head)
        print("%-22s all: hit %5.1f%%  fg %5.1f | first 64 tokens of turns 2+: hit %5.1f%%  fg %5.1f" % (
            name, 100 * whole["hit"], whole["fg"],
            100 * (1 - misses[head].sum() / (n * s.L * s.K)), fg[head].mean()), flush=True)


if __name__ == "__main__":
    main()
