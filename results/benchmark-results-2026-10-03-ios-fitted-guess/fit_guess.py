"""Fit the next-layer guess and write it in the router's own 8-bit format.

Usage: fit_guess.py <traces-dir> <output.bin>

The fit is the research study's fitted-early predictor, unchanged: per target
layer L+1, a ridge correction B (lambda = 1, the value the study chose) fitted
on the seven train-* traces, so the guess for L+1 is x_L (W_{L+1} + B)^T with
x_L layer L's router input. The three test-* traces stay held out.

W + B is then quantized the way the runtime stores routers: one byte per
weight, one BF16 scale and bias per 64-wide group, so `router_gemv_gemma4_r4`
runs it unchanged with an effective scale of 1. The script scores the
quantized matrix against the float one on the held-out traces before writing.

Output layout, little-endian:
  64-byte header: 8-byte magic "TFNLG1\\0\\0", then UInt32 numLayers,
  numExperts, hiddenSize, groupSize, firstTargetLayer, targetLayerCount,
  zero padding.
  Then per target layer 1..numLayers-1: UInt8 weights [E][D], BF16 scales
  [E][D/64], BF16 biases [E][D/64].
"""
import hashlib, os, struct, sys
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                "research-results-2026-10-02-next-layer-prediction",
                                "analysis"))
import glob
import score  # reads sys.argv[1] as the traces dir
import trace as tr

LAMBDA = 1.0
GROUP = 64
MAGIC = b"TFNLG1\0\0"


def bf16(x):
    """Round float32 to the nearest BF16 (ties to even); returns uint16 bits."""
    u = np.ascontiguousarray(x, dtype=np.float32).view(np.uint32)
    u = u + 0x7FFF + ((u >> 16) & 1)
    return (u >> 16).astype(np.uint16)


def from_bf16(bits):
    return (bits.astype(np.uint32) << 16).view(np.float32)


def quantize(W):
    """W [E, D] float32 -> (q uint8 [E, D], scales, biases uint16 [E, D/64])."""
    E, D = W.shape
    g = W.reshape(E, D // GROUP, GROUP)
    lo, hi = g.min(axis=2), g.max(axis=2)
    b = bf16(lo)
    s = bf16(np.maximum(hi - from_bf16(b), 1e-12) / 255.0)
    q = np.rint((g - from_bf16(b)[..., None]) / from_bf16(s)[..., None])
    q = np.clip(q, 0, 255).astype(np.uint8).reshape(E, D)
    return q, s, b


def dequantize(q, s, b):
    E, D = q.shape
    g = q.reshape(E, D // GROUP, GROUP).astype(np.float32)
    return (g * from_bf16(s)[..., None] + from_bf16(b)[..., None]).reshape(E, D)


def main():
    root, out_path = sys.argv[1], sys.argv[2]
    pick = lambda pat: sorted(d for d in glob.glob(os.path.join(root, pat))
                              if os.path.exists(os.path.join(d, "done")))
    train_dirs, test_dirs = pick("train-*"), pick("test-*")
    meta, _ = score.load_run(train_dirs[0])
    nL, E, D = meta["numLayers"], meta["numExperts"], meta["hiddenSize"]
    W = [tr.router(train_dirs[0], L, meta) for L in range(nL)]
    train = [score.load_run(d)[1] for d in train_dirs]
    test = [score.load_run(d)[1] for d in test_dirs]
    names = [os.path.basename(d) for d in test_dirs]

    def inputs(runs, L):
        return np.concatenate([r[:, L]["router_input"] for r in runs]).astype(np.float32)

    fitted, quant, worst = [], [], 0.0
    for L in range(nL - 1):
        x = inputs(train, L)
        y = np.concatenate([r[:, L + 1]["scores"] for r in train]).astype(np.float32)
        resid = y - x @ W[L + 1].T
        A = x.T @ x + LAMBDA * len(x) * np.eye(D, dtype=np.float32)
        Wf = W[L + 1] + np.linalg.solve(A, x.T @ resid).T
        q, s, b = quantize(Wf)
        Wq = dequantize(q, s, b)
        worst = max(worst, float(np.abs(Wq - Wf).max() / np.abs(Wf).max()))
        fitted.append(Wf)
        quant.append((q, s, b, Wq))
    print("quantization: worst |error| / max |weight| over layers %.4f" % worst)

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

    naive = [W[L + 1] for L in range(nL - 1)]
    quantized = [m[3] for m in quant]
    for slots in (16, 24):
        print("held-out precision@1 at %d slots: naive %.3f, fitted float %.3f, "
              "fitted 8-bit %.3f" % (slots, precision(test, slots, naive),
                                     precision(test, slots, fitted),
                                     precision(test, slots, quantized)))
    for name, run in zip(names, test):
        print("  %s at 24 slots: naive %.3f, fitted 8-bit %.3f" % (
            name, precision([run], 24, naive), precision([run], 24, quantized)))

    with open(out_path, "wb") as f:
        header = MAGIC + struct.pack("<6I", nL, E, D, GROUP, 1, nL - 1)
        f.write(header + b"\0" * (64 - len(header)))
        for q, s, b, _ in quant:
            f.write(q.tobytes()); f.write(s.tobytes()); f.write(b.tobytes())
    data = open(out_path, "rb").read()
    print("wrote %s: %d bytes, sha256 %s" % (
        out_path, len(data), hashlib.sha256(data).hexdigest()))


if __name__ == "__main__":
    main()
