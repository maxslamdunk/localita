#!/usr/bin/env python3
"""How many expert reads would lossy routing policies save? An offline probe.

Replays the decode routing traces in scratch/cache-traces through the
runtime's cache (count-aged LFU, decay 0.97, 24 slots) and the early read
with the fitted guess, as research-results-2026-10-03-cache-policy/sim does,
with one change: a policy may drop some of a layer's top-8 experts.

Weights are the router's: softmax over the top-8 logits (the per-expert scale
is left out, so they sum to 1). A dropped expert is not computed and not
read; the rest are renormalized. "mass" is the weight dropped, per
(token, layer), a first proxy for the quality cost, which is measured
separately on the real model.

Policies:
  base            production
  top7 / top6     always drop the lowest ranks (static k)
  wdrop<t>        always drop experts with weight < t (dynamic k)
  miss<t>         drop an expert only when it would be a foreground read
                  (not resident, not covered by the early read) and its
                  weight is < t. Cache-conditional: saves reads only.
  missrank<r>     drop a foreground miss whose rank is >= r (1-based)

The top-1 expert is never dropped.

    trace_policies.py [trace dir]
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../research-results-2026-10-03-cache-policy/sim"))
import sim  # noqa: E402
from policies import DecayLFU  # noqa: E402

SLOTS = 24
TRACES = "/Users/max/ml_projects/iphone-port/turbo-fieldfare/scratch/cache-traces"


def weights(logits_top8):
    x = logits_top8.astype(np.float64)
    e = np.exp(x - x.max())
    return e / e.sum()


def keep_list(policy, w, chosen, resident, guess_expert):
    kind, arg = policy
    if kind == "topk":
        return list(range(arg))
    if kind == "wdrop":
        return [i for i in range(8) if i == 0 or w[i] >= arg]
    if kind in ("miss", "missrank"):
        keep = []
        for i in range(8):
            e = chosen[i]
            fgmiss = e not in resident and e != guess_expert
            drop = (kind == "miss" and w[i] < arg) or (kind == "missrank" and i + 1 >= arg)
            if fgmiss and i > 0 and drop:
                continue
            keep.append(i)
        return keep
    return list(range(8))


def run(trace, policy):
    T, L = trace.T, trace.L
    pols = [DecayLFU(slots=SLOTS, decay=0.97, layer=l, trace=trace) for l in range(L)]
    fg = np.zeros(T)
    mass = np.zeros(T)
    dropped = np.zeros(T)
    for t in range(T):
        guess_expert = None
        for l in range(L):
            chosen = [int(e) for e in trace.experts[t, l]]
            w = weights(trace.scores[t, l, chosen])
            keep = keep_list(policy, w, chosen, pols[l].resident, guess_expert)
            m = pols[l].access(t, [chosen[i] for i in keep])
            hit_early = guess_expert is not None and guess_expert in m
            fg[t] += len(m) - hit_early
            mass[t] += 1.0 - w[keep].sum()
            dropped[t] += 8 - len(keep)
            if l + 1 < L:
                g = trace.guess[t, l].astype(np.float32)
                res = pols[l + 1].resident
                if res:
                    g = g.copy()
                    g[list(res)] = -np.inf
                guess_expert = int(np.argmax(g))
    s = slice(sim.WARMUP, None)
    n = T - sim.WARMUP
    return {"fg": fg[s].sum() / n, "reads": fg[s].sum() / n + (L - 1),
            "mass": mass[s].sum() / (n * L), "dropped": dropped[s].sum() / (n * L), "tokens": n}


POLICIES = [("base", ("none", 0)), ("top7", ("topk", 7)), ("top6", ("topk", 6)), ("top5", ("topk", 5)),
            ("wdrop0.05", ("wdrop", 0.05)), ("wdrop0.08", ("wdrop", 0.08)),
            ("miss0.05", ("miss", 0.05)), ("miss0.08", ("miss", 0.08)), ("miss0.10", ("miss", 0.10)),
            ("miss0.12", ("miss", 0.12)), ("miss0.15", ("miss", 0.15)),
            ("missrank8", ("missrank", 8)), ("missrank7", ("missrank", 7)),
            ("missrank6", ("missrank", 6)), ("missrank5", ("missrank", 5))]


def main():
    traces = sim.load(sys.argv[1] if len(sys.argv) > 1 else TRACES)
    print("# %d traces, %d decode tokens after warmup; %d slots, DecayLFU 0.97, early read on"
          % (len(traces), sum(t.T - sim.WARMUP for t in traces), SLOTS))
    ws = np.array([weights(tr.scores[t, l, tr.experts[t, l]])
                   for tr in traces for t in range(sim.WARMUP, tr.T) for l in range(tr.L)])
    print("mean weight by rank:   " + "  ".join("%d:%.3f" % (i + 1, ws[:, i].mean()) for i in range(8)))
    print("median weight by rank: " + "  ".join("%d:%.3f" % (i + 1, np.median(ws[:, i])) for i in range(8)))
    base = None
    print("%-11s %6s %7s %8s %9s %9s %8s" % ("policy", "fg", "reads", "d fg", "d reads", "mass", "drop/L"))
    for name, pol in POLICIES:
        rows = [run(tr, pol) for tr in traces]
        n = sum(r["tokens"] for r in rows)
        agg = {k: sum(r[k] * r["tokens"] for r in rows) / n for k in rows[0] if k != "tokens"}
        base = base or agg
        print("%-11s %6.2f %7.2f %+7.1f%% %+8.1f%% %9.4f %8.2f" % (
            name, agg["fg"], agg["reads"], 100 * (agg["fg"] / base["fg"] - 1),
            100 * (agg["reads"] / base["reads"] - 1), agg["mass"], agg["dropped"]), flush=True)


if __name__ == "__main__":
    main()
