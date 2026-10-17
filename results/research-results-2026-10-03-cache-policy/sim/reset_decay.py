"""The runtime change before it is built: decayed counts, a reset at each new
chat, and both, against today's LFU. Scores single prompts (the benchmark) and
a session of chats back to back (the app), at 16 and 24 slots, and the phone
session protocol exactly: the val and test prompts in session.py's seed-0
order, each cut at `--max-new` tokens.

Usage: reset_decay.py <traces-dir> [--max-new=N]
"""
import sys
import numpy as np

import session
import sim
from policies import LFU, DecayLFU


def with_reset(base, starts, **kw):
    class Reset(base):
        def access(self, t, chosen):
            if t in starts:
                self.count[:] = 0
                if hasattr(self, "crf"):
                    self.crf[:] = 0
            return super().access(t, chosen)
    return lambda **k: Reset(**kw, **k)


class Cut:
    def __init__(self, t, n):
        self.name, self.T = t.name, min(t.T, n)
        self.experts, self.scores, self.guess = t.experts[:n], t.scores[:n], t.guess[:n]
        self.L, self.K, self.E = t.L, t.K, t.E


def policies(starts):
    return {
        "LFU, never reset": LFU,
        "LFU, reset per chat": with_reset(LFU, starts),
        "decay 0.97": lambda **k: DecayLFU(decay=0.97, **k),
        "decay 0.97 + reset": with_reset(DecayLFU, starts, decay=0.97),
    }


def score_session(s, slots, per_chat=False):
    starts = set(int(a) for a in s.starts)
    bounds = list(zip([int(a) for a in s.starts], [int(a) for a in s.starts[1:]] + [s.T]))
    per = s.L * s.K
    for name, make in policies(starts).items():
        m, fg, used = sim.replay(s, make, slots)
        w = slice(sim.WARMUP, None)
        reads = fg[w].mean() + s.L - 1
        line = "  %-22s hit %5.1f%%  fg %5.1f  reads %5.1f (%5.1f MiB)  prec %.3f" % (
            name, 100 * (1 - m[w].sum() / ((s.T - sim.WARMUP) * per)), fg[w].mean(),
            reads, reads * sim.EXPERT_BYTES / sim.MIB, used[w].mean() / (s.L - 1))
        if per_chat:
            line += "  | per chat hit: " + " ".join(
                "%4.1f" % (100 * (1 - m[a:b].sum() / ((b - a) * per))) for a, b in bounds)
            line += "\n  %-22s                         per chat fg:  " % "" + " ".join(
                "%4.1f" % fg[a:b].mean() for a, b in bounds)
        print(line, flush=True)


def main():
    directory = sys.argv[1]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--"))
    max_new = int(opts.get("max-new", 512))
    tests = sim.load(directory, "test-")
    traces = sim.load(directory, "val-") + tests
    order = np.random.default_rng(0).permutation(len(traces))
    ordered = [traces[i] for i in order]

    for slots in (16, 24):
        print("== %d slots" % slots)
        print("single prompts, test pooled:")
        for name, make in (("LFU", LFU), ("decay 0.97", lambda **k: DecayLFU(decay=0.97, **k))):
            rows = [sim.summarize(t, sim.replay(t, make, slots)) for t in tests]
            print("  %-22s %s" % (name, sim.fmt(sim.pooled(rows))), flush=True)
        print("session, %d chats, full length:" % len(ordered))
        score_session(session.Concat(ordered), slots)
        cut = session.Concat([Cut(t, max_new) for t in ordered])
        print("phone protocol: same order, each chat cut at %d tokens (%d tokens):" % (max_new, cut.T))
        print("  order: " + ", ".join(t.name for t in ordered))
        score_session(cut, slots, per_chat=True)


if __name__ == "__main__":
    main()
