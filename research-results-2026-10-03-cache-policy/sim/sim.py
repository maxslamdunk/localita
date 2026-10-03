"""Replay routing traces through an expert-cache policy and the early read.

A policy is a per-layer object with `resident` (a set of expert IDs) and
`access(t, chosen) -> misses`, which must admit every chosen expert (the
routed kernels read from slots) and evict only experts not chosen this token.

The early read is replayed as the runtime does it
(`NextLayerExpertPrefetcher`): after layer L-1's reads, the expert with the
best guess score that layer L does not hold is read; if layer L then misses
it, that miss costs no foreground read. It never changes what the cache holds.
Layer 0 has no early read, so a token issues numLayers - 1 of them.

Per run, from token WARMUP on (the replayed cache starts empty, the live one
starts with what prefill left):
  hit      hit rate
  miss     misses per token
  fg       foreground reads per token: misses not covered by an early read;
           these are the reads the token waits for
  reads    all reads per token, early ones included (bytes/token / expert size)
  prec     early-read precision: early reads used / early reads issued
"""
import glob, os
import numpy as np

WARMUP = 32
EXPERT_BYTES = 3_358_720
MIB = 1 << 20


class Trace:
    def __init__(self, path):
        z = np.load(path)
        self.name = os.path.basename(path)[:-4]
        self.experts = z["experts"].astype(np.int64)     # [T, L, K]
        self.scores = z["scores"]                        # [T, L, E] float16
        self.guess = z["guess"]                          # [T, L, E]; row L scores L+1
        self.T, self.L, self.K = self.experts.shape
        self.E = self.scores.shape[2]


def load(directory, prefix=""):
    return [Trace(p) for p in sorted(glob.glob(os.path.join(directory, prefix + "*.npz")))]


def replay(trace, make_policy, slots, early=True):
    """Returns per-token arrays (misses, fg, early_used), each [T]."""
    T, L, K, E = trace.T, trace.L, trace.K, trace.E
    pols = [make_policy(slots=slots, layer=l, trace=trace) for l in range(L)]
    misses = np.zeros(T, np.int64)
    fg = np.zeros(T, np.int64)
    used = np.zeros(T, np.int64)
    for t in range(T):
        guess_expert = None
        for l in range(L):
            chosen = [int(e) for e in trace.experts[t, l]]
            m = pols[l].access(t, chosen)
            hit_early = guess_expert is not None and guess_expert in m
            misses[t] += len(m)
            fg[t] += len(m) - hit_early
            used[t] += hit_early
            if early and l + 1 < L:
                g = trace.guess[t, l].astype(np.float32)
                res = pols[l + 1].resident
                if res:
                    g = g.copy()
                    g[list(res)] = -np.inf
                guess_expert = int(np.argmax(g))  # ties to the lower ID, like `choose`
    return misses, fg, used


def summarize(trace, result, early=True):
    misses, fg, used = (r[WARMUP:] for r in result)
    n = misses.size
    issued = (trace.L - 1) if early else 0
    reads = fg.sum() / n + issued
    return {
        "hit": 1 - misses.sum() / (n * trace.L * trace.K),
        "miss": misses.sum() / n,
        "fg": fg.sum() / n,
        "reads": reads,
        "mib": reads * EXPERT_BYTES / MIB,
        "prec": used.sum() / (n * issued) if issued else float("nan"),
        "tokens": n,
    }


def pooled(rows):
    """Token-weighted mean of summaries."""
    n = sum(r["tokens"] for r in rows)
    return {k: sum(r[k] * r["tokens"] for r in rows) / n for k in rows[0] if k != "tokens"} | {"tokens": n}


def fmt(s):
    return "hit %5.1f%%  miss %5.1f  fg %5.1f  reads %5.1f  (%6.1f MiB)  prec %.3f" % (
        100 * s["hit"], s["miss"], s["fg"], s["reads"], s["mib"], s["prec"])
