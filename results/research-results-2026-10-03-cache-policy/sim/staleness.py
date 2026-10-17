"""How long stale LFU counts hurt within each chat of a session: hit rate by
token position within chats 2+, never-reset LFU against a per-chat reset,
and per chat in session order.

Usage: staleness.py <traces-dir> [slots]
"""
import sys
import numpy as np

import session
import sim
from policies import LFU


def main():
    directory = sys.argv[1]
    slots = int(sys.argv[2]) if len(sys.argv) > 2 else 24
    traces = sim.load(directory, "val-") + sim.load(directory, "test-")
    order = np.random.default_rng(0).permutation(len(traces))
    s = session.Concat([traces[i] for i in order])
    starts = [int(a) for a in s.starts]
    ends = starts[1:] + [s.T]
    start_set = set(starts)

    class ResetLFU(LFU):
        def access(self, t, chosen):
            if t in start_set:
                self.count[:] = 0
            return super().access(t, chosen)

    per = s.L * s.K
    res = {n: sim.replay(s, f, slots)[0] for n, f in (("never reset", LFU), ("reset per chat", ResetLFU))}
    wins = [(0, 32), (32, 128), (128, 256), (256, 512), (512, 1100)]
    print("hit rate by position within each chat (chats 2-%d), %d slots" % (len(starts), slots))
    print("%-16s" % "tokens" + "".join("%11s" % ("%d-%d" % w) for w in wins))
    for n, m in res.items():
        row = []
        for a, b in wins:
            idx = np.concatenate([np.arange(st + a, min(st + b, en))
                                  for st, en in zip(starts[1:], ends[1:]) if st + a < en])
            row.append("%10.1f%%" % (100 * (1 - m[idx].sum() / (len(idx) * per))))
        print("%-16s" % n + "".join(row))
    print("\nper chat in session order, whole chat:")
    for n, m in res.items():
        print("%-16s" % n + " ".join("%5.1f" % (100 * (1 - m[a:b].sum() / ((b - a) * per)))
                                      for a, b in zip(starts, ends)))


if __name__ == "__main__":
    main()
