"""Score gemma4's shipped guess on supergemma4 traces, and compare the routers.

Usage: cross_score.py <supergemma4-traces> <gemma4-guess.bin> <gemma4-traces>

Prints, on the supergemma4 held-out (test-*) traces at 16 and 24 replayed
slots: precision@1 of supergemma4's own router (naive) and of gemma4's shipped
fitted file. Then, per layer, how far supergemma4's router moved from
gemma4's: relative Frobenius distance, and the mean top-8 overlap of the two
routers applied to the same supergemma4 router inputs.
"""
import glob, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "research-results-2026-10-02-next-layer-prediction",
                                "analysis"))
sys.path.insert(0, os.path.join(HERE, "..", "benchmark-results-2026-10-03-ios-fitted-guess"))
import score  # reads sys.argv[1] as the traces dir
import trace as tr
from fit_guess import dequantize, GROUP

root, guess_path, gemma_root = sys.argv[1], sys.argv[2], sys.argv[3]
pick = lambda r, pat: sorted(d for d in glob.glob(os.path.join(r, pat))
                             if os.path.exists(os.path.join(d, "done")))
test_dirs = pick(root, "test-*")
meta, _ = score.load_run(test_dirs[0])
nL, E, D = meta["numLayers"], meta["numExperts"], meta["hiddenSize"]
test = [score.load_run(d)[1] for d in test_dirs]
W_super = [tr.router(test_dirs[0], L, meta) for L in range(nL)]
gemma_dir = pick(gemma_root, "train-*")[0]
W_gemma = [tr.router(gemma_dir, L, meta) for L in range(nL)]

raw = np.fromfile(guess_path, dtype=np.uint8)
assert raw[:8].tobytes() == b"TFNLG1\0\0"
gb = E * (D // GROUP) * 2
off, gemma_guess = 64, []
for _ in range(nL - 1):
    q = raw[off:off + E * D].reshape(E, D); off += E * D
    s = raw[off:off + gb].view(np.uint16).reshape(E, D // GROUP); off += gb
    b = raw[off:off + gb].view(np.uint16).reshape(E, D // GROUP); off += gb
    gemma_guess.append(dequantize(q, s, b))
assert off == raw.size


def inputs(runs, L):
    return np.concatenate([r[:, L]["router_input"] for r in runs]).astype(np.float32)


def precision(runs, slots, mats):
    rep = score.replay(runs, slots, meta)
    u = p = 0
    for L in range(nL - 1):
        for data, (before, misses) in zip(runs, rep):
            d = data[score.WARMUP:]
            sc = inputs([d], L) @ mats[L].T
            uu, pp, _ = score.evaluate(sc, before[score.WARMUP:, L + 1],
                                       misses[score.WARMUP:, L + 1], 1)
            u, p = u + uu, p + pp
    return u / p


naive = [W_super[L + 1] for L in range(nL - 1)]
for slots in (16, 24):
    print("supergemma4 held-out precision@1 at %d slots: own router (naive) %.3f, "
          "gemma4 shipped file %.3f" % (slots, precision(test, slots, naive),
                                        precision(test, slots, gemma_guess)))
for d, run in zip(test_dirs, test):
    print("  %s at 24 slots: own router %.3f, gemma4 shipped file %.3f" % (
        os.path.basename(d), precision([run], 24, naive), precision([run], 24, gemma_guess)))

print("router drift, supergemma4 vs gemma4, per layer:")
dists, overlaps = [], []
for L in range(nL):
    dist = np.linalg.norm(W_super[L] - W_gemma[L]) / np.linalg.norm(W_gemma[L])
    x = inputs(test, L)
    top = lambda W: np.argsort(-(x @ W.T), axis=1)[:, :8]
    a, b = top(W_super[L]), top(W_gemma[L])
    ov = np.mean([len(set(r) & set(s)) for r, s in zip(a, b)])
    dists.append(dist); overlaps.append(ov)
    print("  L%02d  rel. distance %.4f  top-8 overlap %.2f / 8" % (L, dist, ov))
print("mean rel. distance %.4f, mean top-8 overlap %.2f / 8"
      % (np.mean(dists), np.mean(overlaps)))
