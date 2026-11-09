"""Refit the next-layer guess: how much training data, and which loss.

Usage: fit.py <traces-dir> {anchors|all}

<traces-dir> holds collect.py's train-*.npy, val-*.npy and test-*.npy plus
routers/. Every predictor scores layer L+1's experts from layer L's router
input x as x (W + B)^T, with W layer L+1's router; only B differs:

  naive     B = 0
  shipped   the runtime's fitted guess file (scratch/next-layer-guess.bin),
            dequantized, fitted on the 2026-10-02 traces of 7 other prompts
  ridge     squared error on L+1's router scores, penalty lambda * |B|^2
            (the shipped method, closed form)
  ce-soft   cross-entropy against softmax(L+1's router scores), same penalty
  ce-top8   cross-entropy against the uniform distribution over L+1's top-8

Scored as in ../research-results-2026-10-02-next-layer-prediction: precision@1
at 24 replayed LFU slots, the best-scoring expert not already cached, pooled
over transitions L -> L+1 (L = 0..28) and decode tokens after the first 32 of
each run. Lambda is chosen on val; test is scored once per final predictor.
"""
import glob, importlib.util, json, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT, MODE = sys.argv[1], sys.argv[2]
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# score.py reads its traces dir from argv at import; it is only used for its
# LFU replay and evaluate(), which take arrays.
_argv, sys.argv = sys.argv, [sys.argv[0], ROOT]
score = load_module("score", os.path.join(
    HERE, "..", "research-results-2026-10-02-next-layer-prediction", "analysis", "score.py"))
sys.argv = _argv

SLOTS, WARMUP = 24, score.WARMUP
LAMBDAS = (0.01, 0.1, 1.0, 10.0)
CURVE_PROMPTS = (1, 2, 4, 6, 9, 12, 18)
CURVE_ORDERS = 3
SEED = 20261108

meta = json.load(open(os.path.join(ROOT, "routers", "meta.json")))
nL, E, D, K = meta["numLayers"], meta["numExperts"], meta["hiddenSize"], meta["topK"]
W = [np.fromfile(os.path.join(ROOT, "routers", "router_L%02d.f32" % L), dtype="<f4").reshape(E, D)
     for L in range(nL)]


def split(name):
    paths = sorted(glob.glob(os.path.join(ROOT, name + "-*.npy")))
    return [os.path.basename(p)[len(name) + 1:-4] for p in paths], \
        [np.load(p, mmap_mode="r") for p in paths]


class Scored:
    """A set of runs with their replayed cache state, ready to score."""

    def __init__(self, runs):
        self.runs = runs
        rep = score.replay(runs, SLOTS, meta)
        self.before = [b[WARMUP:] for b, _ in rep]
        self.misses = [m[WARMUP:] for _, m in rep]

    def precision(self, B=None):
        useful = picked = 0
        for r, before, misses in zip(self.runs, self.before, self.misses):
            for L in range(nL - 1):
                x = np.asarray(r[WARMUP:, L]["router_input"], dtype=np.float32)
                M = W[L + 1] if B is None else W[L + 1] + B[L]
                u, p, _ = score.evaluate(x @ M.T, before[:, L + 1], misses[:, L + 1], 1)
                useful, picked = useful + u, picked + p
        return useful / picked


def shipped():
    """The runtime's guess file, dequantized, as corrections B = (W + B) - W."""
    raw = open(os.path.join(REPO, "scratch", "next-layer-guess.bin"), "rb").read()
    assert raw[:8] == b"TFNLG1\0\0"
    hL, hE, hD, group, first, count = np.frombuffer(raw[8:32], dtype="<u4")
    assert (hL, hE, hD, first, count) == (nL, E, D, 1, nL - 1)
    off, B = 64, []
    for L in range(1, nL):
        q = np.frombuffer(raw, np.uint8, E * D, off).reshape(E, D // group, group); off += E * D
        n = E * D // group
        s = np.frombuffer(raw, "<u2", n, off).astype(np.uint32); off += 2 * n
        b = np.frombuffer(raw, "<u2", n, off).astype(np.uint32); off += 2 * n
        s, b = (s << 16).view(np.float32), (b << 16).view(np.float32)
        Wg = q * s.reshape(E, -1, 1) + b.reshape(E, -1, 1)
        B.append(Wg.reshape(E, D) - W[L])
    return B


def stack(runs, L):
    x = np.concatenate([np.asarray(r[:, L]["router_input"], dtype=np.float32) for r in runs])
    y = np.concatenate([np.asarray(r[:, L + 1]["scores"], dtype=np.float32) for r in runs])
    top = np.concatenate([np.asarray(r[:, L + 1]["experts"]) for r in runs])
    return x, y, top


def fit_ridge(runs, lam):
    """The shipped fit (fit_guess.py): fitting may use warm-up tokens."""
    B = []
    for L in range(nL - 1):
        x, y, _ = stack(runs, L)
        resid = y - x @ W[L + 1].T
        A = x.T @ x + lam * len(x) * np.eye(D, dtype=np.float32)
        B.append(np.linalg.solve(A, x.T @ resid).T)
    return B


def fit_ce(runs, lam, target):
    """Cross-entropy, mean over tokens, plus lam * |B|^2 (the ridge penalty's
    scale: ridge's A = X^T X + lam n I is the gradient of the mean squared
    error plus lam |B|^2, up to a factor 2). L-BFGS from B = 0, on the GPU."""
    import torch
    dev = os.environ.get("FIT_DEVICE") or ("mps" if torch.backends.mps.is_available() else "cpu")
    B = []
    for L in range(nL - 1):
        x, y, top = stack(runs, L)
        X = torch.from_numpy(x).to(dev)
        Wt = torch.from_numpy(W[L + 1]).to(dev)
        if target == "soft":
            P = torch.softmax(torch.from_numpy(y).to(dev), dim=1)
        else:
            P = torch.zeros(len(x), E, device=dev)
            P.scatter_(1, torch.from_numpy(top.astype(np.int64)).to(dev), 1.0 / K)
        Bt = torch.zeros(E, D, device=dev, requires_grad=True)
        opt = torch.optim.LBFGS([Bt], lr=1, max_iter=200, history_size=20,
                                tolerance_grad=1e-7, tolerance_change=1e-10,
                                line_search_fn="strong_wolfe")

        def closure():
            opt.zero_grad()
            logp = torch.log_softmax(X @ (Wt + Bt).T, dim=1)
            loss = -(P * logp).sum(dim=1).mean() + lam * (Bt * Bt).sum()
            loss.backward()
            return loss

        opt.step(closure)
        B.append(Bt.detach().cpu().numpy())
    return B


def main():
    test_names, test = split("test")
    print("test:", test_names, [len(r) for r in test], flush=True)
    T = Scored(test)
    if MODE == "anchors":
        print("test precision@1 at %d slots: naive %.4f, shipped %.4f"
              % (SLOTS, T.precision(), T.precision(shipped())), flush=True)
        return

    train_names, train = split("train")
    val_names, val = split("val")
    print("train:", len(train), "prompts,", sum(len(r) for r in train), "tokens")
    print("val:  ", len(val), "prompts,", sum(len(r) for r in val), "tokens", flush=True)
    V = Scored(val)
    ship = shipped()
    print("\nanchors        val      test")
    print("naive        %.4f   %.4f" % (V.precision(), T.precision()))
    print("shipped      %.4f   %.4f" % (V.precision(ship), T.precision(ship)), flush=True)

    # Experiment 1: learning curve, ridge at the shipped lambda = 1, nested
    # random subsets of the training prompts in three orders.
    print("\nlearning curve (ridge, lambda = 1), val precision@1 per order")
    rng = np.random.default_rng(SEED)
    orders = [rng.permutation(len(train)) for _ in range(CURVE_ORDERS)]
    for n in CURVE_PROMPTS:
        vals, toks = [], []
        for o in orders:
            sub = [train[i] for i in o[:n]]
            vals.append(V.precision(fit_ridge(sub, 1.0)))
            toks.append(sum(len(r) for r in sub))
        print("  %2d prompts, %5d tokens (mean): %s  mean %.4f"
              % (n, np.mean(toks), " ".join("%.4f" % v for v in vals), np.mean(vals)), flush=True)

    # Experiment 2: the loss, each with lambda chosen on val, then test once.
    print("\nloss, all %d training prompts; val precision@1 per lambda" % len(train))
    fitters = {"ridge": lambda lam: fit_ridge(train, lam),
               "ce-soft": lambda lam: fit_ce(train, lam, "soft"),
               "ce-top8": lambda lam: fit_ce(train, lam, "top8")}
    final = {}
    for name, fitter in fitters.items():
        best = None
        for lam in LAMBDAS:
            # CE's lambda is on the mean loss, which is a different scale from
            # squared error on scores, so its grid goes lower.
            lam_used = lam if name == "ridge" else lam * 1e-3
            B = fitter(lam_used)
            v = V.precision(B)
            print("  %-8s lambda %-8g val %.4f" % (name, lam_used, v), flush=True)
            if best is None or v > best[0]:
                best = (v, lam_used, B)
        final[name] = best
    print("\nfinal          lambda     val      test")
    print("naive               -   %.4f   %.4f" % (V.precision(), T.precision()))
    print("shipped           1.0   %.4f   %.4f" % (V.precision(ship), T.precision(ship)))
    for name, (v, lam, B) in final.items():
        print("%-12s %8g   %.4f   %.4f" % (name, lam, v, T.precision(B)), flush=True)
    for name, (v, lam, B) in final.items():
        np.save(os.path.join(ROOT, "B-%s.npy" % name), np.stack(B))


if __name__ == "__main__":
    main()
