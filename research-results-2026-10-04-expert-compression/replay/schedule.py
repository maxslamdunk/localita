#!/usr/bin/env python3
"""Write the read schedule of one decode: which experts each layer reads.

Replays a routing trace through count-aged LFU (decay 0.97, the runtime's
default) and the early read with the fitted guess, exactly as
research-results-2026-10-03-cache-policy/sim does, and prints one line per
(token, layer):

    <token> <layer> <early> <n> <e1> ... <en>

`e1..en` are the foreground reads (misses the early read did not cover) and
`early` is the expert read early for layer + 1 after this layer's reads
(-1 for none). Tokens before sim.WARMUP are skipped.

    schedule.py <trace.npz> <slots> <tokens> > schedule.txt
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../research-results-2026-10-03-cache-policy/sim"))
import numpy as np  # noqa: E402

import sim  # noqa: E402
from policies import DecayLFU  # noqa: E402


def main():
    trace = sim.Trace(sys.argv[1])
    slots, tokens = int(sys.argv[2]), int(sys.argv[3])
    pols = [DecayLFU(slots=slots, decay=0.97, layer=l, trace=trace) for l in range(trace.L)]
    end = min(trace.T, sim.WARMUP + tokens)
    out = []
    for t in range(end):
        guess_expert = None
        for l in range(trace.L):
            chosen = [int(e) for e in trace.experts[t, l]]
            m = pols[l].access(t, chosen)
            fg = [e for e in m if e != guess_expert]
            early = -1
            if l + 1 < trace.L:
                g = trace.guess[t, l].astype(np.float32)
                res = pols[l + 1].resident
                if res:
                    g = g.copy()
                    g[list(res)] = -np.inf
                early = int(np.argmax(g))
            guess_expert = early
            if t >= sim.WARMUP:
                out.append(f"{t} {l} {early} {len(fg)} " + " ".join(map(str, fg)))
    print("\n".join(out))


if __name__ == "__main__":
    main()
