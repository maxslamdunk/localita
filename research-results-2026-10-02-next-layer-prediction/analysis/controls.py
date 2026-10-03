"""Controls for score.py, run after it, on the same traces, at 24 replayed slots.

Usage: controls.py <traces-dir>

1. Wrong-token control: naive-early fed the previous token's router input
   instead of this token's. If precision stays high, the predictor is
   picking experts that are often used and often uncached, not reading the
   current token's state.
2. Precision@1 per held-out prompt, for naive-early and fitted-early.
3. Precision@1 per layer transition, for naive-early and fitted-early.
4. Ridge strength beyond score.py's grid, still chosen on training prompts
   only. Secondary: the grid was extended after the test scores were seen.
"""
import glob, os, sys
import numpy as np
import score as sc
import trace as tr

ROOT = sys.argv[1]
SLOTS = 24
W_UP = sc.WARMUP


def runs(prefix):
    dirs = sorted(d for d in glob.glob(os.path.join(ROOT, prefix + "-*"))
                  if os.path.exists(os.path.join(d, "done")))
    return dirs, [sc.load_run(d)[1] for d in dirs]


train_dirs, train = runs("train")
test_dirs, test = runs("test")
meta, _ = sc.load_run(train_dirs[0])
nL, E = meta["numLayers"], meta["numExperts"]
W = [tr.router(train_dirs[0], L, meta) for L in range(nL)]
test_rep = sc.replay(test, SLOTS, meta)


def early(data, L, shift=0):
    x = data[:, L]["router_input"].astype(np.float32)
    return np.roll(x, shift, axis=0) if shift else x


def fit(rs, lam):
    Bs = []
    for L in range(nL - 1):
        x = np.concatenate([early(r, L) for r in rs])
        y = np.concatenate([r[:, L + 1]["scores"] for r in rs]).astype(np.float32)
        resid = y - x @ W[L + 1].T
        A = x.T @ x + lam * len(x) * np.eye(x.shape[1], dtype=np.float32)
        Bs.append(np.linalg.solve(A, x.T @ resid).T)
    return Bs


def precision(rs, reps, Bs=None, shift=0, layers=None):
    u = p = 0
    for L in (layers if layers is not None else range(nL - 1)):
        Wl = W[L + 1] if Bs is None else W[L + 1] + Bs[L]
        for data, (before, misses) in zip(rs, reps):
            s = early(data, L, shift) @ Wl.T
            a, b, _ = sc.evaluate(s[W_UP:], before[W_UP:, L + 1],
                                  misses[W_UP:, L + 1], 1)
            u += a; p += b
    return u / p


print("1. wrong-token control (24 slots, held out)")
print("   naive-early, this token's state:     %.3f" % precision(test, test_rep))
print("   naive-early, previous token's state: %.3f" % precision(test, test_rep, shift=1))
print("   naive-early, state 8 tokens back:    %.3f" % precision(test, test_rep, shift=8))

fitted = fit(train, 1.0)
print("\n2. per held-out prompt, precision@1 (naive-early / fitted-early)")
for d, data, rep in zip(test_dirs, test, test_rep):
    print("   %-24s %.3f / %.3f" % (os.path.basename(d),
                                   precision([data], [rep]),
                                   precision([data], [rep], fitted)))

print("\n3. per transition L->L+1, precision@1 (naive-early / fitted-early)")
for L in range(nL - 1):
    print("   %2d->%2d  %.3f / %.3f" % (L, L + 1,
                                     precision(test, test_rep, layers=[L]),
                                     precision(test, test_rep, fitted, layers=[L])))

print("\n4. ridge strength, chosen on training prompts only (secondary)")
fit_runs, val_runs = train[:-2], train[-2:]
val_rep = sc.replay(val_runs, SLOTS, meta)
best = None
for lam in (1.0, 3.0, 10.0, 30.0, 100.0):
    v = precision(val_runs, val_rep, fit(fit_runs, lam))
    print("   lambda=%g validation %.3f" % (lam, v))
    if best is None or v > best[0]:
        best = (v, lam)
print("   chose lambda=%g: held-out fitted-early precision@1 %.3f"
      % (best[1], precision(test, test_rep, fit(train, best[1]))))
