"""Score next-layer expert predictors on routing traces.

Usage: score.py <traces-dir>
  Training traces are <traces-dir>/train-*, held-out test traces test-*.

Definitions are in ../predictions.md. For each decode token and each
transition L -> L+1 (L = 0..28):
  R = layer L+1's real top-8, C = layer L+1's cache contents just before its
  plan, M = R - C. A predictor scores all experts from layer L's data; prefetch
  at budget k reads the k best-scoring experts not in C.
"""
import glob, os, sys
import numpy as np
import trace as tr

ROOT = sys.argv[1]
SLOT_COUNTS = (16, 24)
BUDGETS = (1, 2)
RIDGE_LAMBDAS = (1e-3, 1e-2, 1e-1, 1.0)
# The replayed cache starts empty while the live one starts with prefill's
# experts, so the first decode tokens of every run are replayed but not scored.
WARMUP = 32


class LFU:
    """Mirror of the runtime's per-layer LFU (`shouldEvictSlot`): evict the
    expert with the lowest use count, ties to the least recently used; use
    counts never reset. Starts empty at decode, whereas the live cache starts
    with whatever prefill left, so early decode tokens differ."""

    def __init__(self, slots, layers, experts):
        self.slots = slots
        self.count = np.zeros((layers, experts), dtype=np.int64)
        self.last = np.zeros((layers, experts), dtype=np.int64)
        self.clock = np.zeros(layers, dtype=np.int64)
        self.cached = [set() for _ in range(layers)]

    def access(self, layer, chosen):
        """Returns the misses, then admits them."""
        cached = self.cached[layer]
        self.clock[layer] += 1
        misses = [e for e in chosen if e not in cached]
        self.count[layer, chosen] += 1
        self.last[layer, chosen] = self.clock[layer]
        for e in misses:
            if len(cached) >= self.slots:
                victim = min((c for c in cached if c not in chosen),
                             key=lambda c: (self.count[layer, c], self.last[layer, c]))
                cached.remove(victim)
            cached.add(e)
        return misses


def rmsnorm(x):
    x = x.astype(np.float32)
    return x / np.sqrt((x * x).mean(axis=1, keepdims=True) + 1e-6)


def load_run(directory):
    meta, data = tr.load(directory)
    nL = meta["numLayers"]
    tokens = len(data) // nL
    data = data[: tokens * nL]
    return meta, data.reshape(tokens, nL)


def replay(runs, slots, meta):
    """Per run: cache contents before each layer's plan, and its misses."""
    out = []
    nL, E = meta["numLayers"], meta["numExperts"]
    for data in runs:
        lfu = LFU(slots, nL, E)
        tokens = data.shape[0]
        before = np.zeros((tokens, nL, E), dtype=bool)
        misses = np.zeros((tokens, nL, E), dtype=bool)
        for t in range(tokens):
            for L in range(nL):
                before[t, L, list(lfu.cached[L])] = True
                m = lfu.access(L, [int(e) for e in data[t, L]["experts"]])
                misses[t, L, m] = True
        out.append((before, misses))
    return out


def evaluate(scores, before, misses, budget):
    """scores [N, E] for N transitions; before/misses [N, E] for layer L+1.
    Returns (useful, prefetched, total misses)."""
    s = np.where(before, -np.inf, scores)
    pick = np.argsort(-s, axis=1)[:, :budget]
    useful = np.take_along_axis(misses, pick, axis=1).sum()
    return int(useful), pick.size, int(misses.sum())


def main():
    train_dirs = sorted(glob.glob(os.path.join(ROOT, "train-*")))
    test_dirs = sorted(glob.glob(os.path.join(ROOT, "test-*")))
    train_dirs = [d for d in train_dirs if os.path.exists(os.path.join(d, "done"))]
    test_dirs = [d for d in test_dirs if os.path.exists(os.path.join(d, "done"))]
    print("train:", [os.path.basename(d) for d in train_dirs])
    print("test: ", [os.path.basename(d) for d in test_dirs])
    meta, _ = load_run(train_dirs[0])
    nL, E, K = meta["numLayers"], meta["numExperts"], meta["topK"]
    W = [tr.router(train_dirs[0], L, meta) for L in range(nL)]
    train = [load_run(d)[1] for d in train_dirs]
    test = [load_run(d)[1] for d in test_dirs]
    print("decode tokens: train %d, test %d" % (
        sum(r.shape[0] for r in train), sum(r.shape[0] for r in test)))

    # P1 second half: replay at 16 slots against the live 16-slot misses.
    for name, runs in (("train", train), ("test", test)):
        rep = replay(runs, 16, meta)
        for skip in (0, WARMUP):
            live = sum(int(r[skip:]["miss_count"].sum()) for r in runs)
            replayed = sum(int(m[skip:].sum()) for _, m in rep)
            n = sum(r[skip:].size for r in runs) * K
            print("%s hit rate @16 from token %d: live %.1f%%, replay %.1f%%" % (
                name, skip, 100 * (1 - live / n), 100 * (1 - replayed / n)))

    def layer_input(runs, L, kind):
        """Layer L's data for predicting L+1, [tokens, D] float32."""
        if kind == "early":
            return np.concatenate([r[:, L]["router_input"] for r in runs]).astype(np.float32)
        return rmsnorm(np.concatenate([r[:, L]["layer_output"] for r in runs]))

    def fit(runs, kind, lam):
        """Per layer: ridge-regressed correction B to layer L+1's router, so
        predicted scores = x (W + B)^T, with B fitted to the residual. Built
        one layer at a time to keep memory bounded."""
        Bs = []
        for L in range(nL - 1):
            x = layer_input(runs, L, kind)
            y = np.concatenate([r[:, L + 1]["scores"] for r in runs]).astype(np.float32)
            # Fitting may use warm-up tokens: the cache plays no part in it.
            resid = y - x @ W[L + 1].T
            A = x.T @ x + lam * len(x) * np.eye(x.shape[1], dtype=np.float32)
            Bs.append(np.linalg.solve(A, x.T @ resid).T)
        return Bs

    def stack(runs, rep, kind, Bs=None, popularity=None):
        """Scores, cache-before and misses for every transition, flattened."""
        S, Cb, M, overlap = [], [], [], []
        for L in range(nL - 1):
            for data, (before, misses) in zip(runs, rep):
                data, before, misses = data[WARMUP:], before[WARMUP:], misses[WARMUP:]
                if popularity is not None:
                    s = np.broadcast_to(popularity[L + 1], (data.shape[0], E))
                else:
                    x = layer_input([data], L, kind)
                    Wl = W[L + 1] if Bs is None else W[L + 1] + Bs[L]
                    s = x @ Wl.T
                real = data[:, L + 1]["experts"]
                top = np.argsort(-s, axis=1)[:, :K]
                overlap.append(np.array([len(set(a) & set(b)) for a, b in zip(top, real)]))
                S.append(s); Cb.append(before[:, L + 1]); M.append(misses[:, L + 1])
        return (np.concatenate(S), np.concatenate(Cb), np.concatenate(M),
                np.concatenate(overlap).mean())

    # Popularity from training traces.
    pop = np.zeros((nL, E))
    for r in train:
        for L in range(nL):
            np.add.at(pop[L], r[:, L]["experts"].ravel(), 1)

    # Ridge strength chosen on training prompts only: fit on all but the last
    # two training runs, validate on those two.
    fitted = {}
    for kind in ("early", "late"):
        fit_runs, val_runs = train[:-2], train[-2:]
        val_rep = replay(val_runs, 24, meta)
        best = None
        for lam in RIDGE_LAMBDAS:
            Bs = fit(fit_runs, kind, lam)
            S, Cb, M, _ = stack(val_runs, val_rep, kind, Bs)
            u, p, _ = evaluate(S, Cb, M, 1)
            print("  ridge %s lambda=%g: validation precision@1 %.3f" % (kind, lam, u / p))
            if best is None or u / p > best[0]:
                best = (u / p, lam)
        fitted[kind] = fit(train, kind, best[1])
        print("  ridge %s: chose lambda=%g" % (kind, best[1]))

    for slots in SLOT_COUNTS:
        rep = replay(test, slots, meta)
        print("\n=== held-out test, %d replayed slots ===" % slots)
        rows = [
            ("popularity", dict(kind="early", popularity=pop)),
            ("naive-early", dict(kind="early")),
            ("fitted-early", dict(kind="early", Bs=fitted["early"])),
            ("naive-late", dict(kind="late")),
            ("fitted-late", dict(kind="late", Bs=fitted["late"])),
        ]
        total_misses = None
        for name, kw in rows:
            S, Cb, M, overlap = stack(test, rep, **kw)
            total_misses = int(M.sum())
            cells = []
            for k in BUDGETS:
                u, p, m = evaluate(S, Cb, M, k)
                cells.append("precision@%d %.3f coverage@%d %.3f" % (k, u / p, k, u / m))
            print("%-13s top-8 overlap %.2f | %s" % (name, overlap, " | ".join(cells)))
        n = S.shape[0]
        has_miss = (M.sum(axis=1) > 0).mean()
        print("%-13s precision@1 %.3f (transitions with any miss) | misses/transition %.3f"
              % ("oracle", has_miss, total_misses / n))


if __name__ == "__main__":
    main()
