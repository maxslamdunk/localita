"""Shrink a routing trace (RoutingTraceWriter) to what cache-policy replay needs.

Usage: compact.py <trace-dir> <out.npz> [guess.bin]

Keeps, per decode token and layer: the top-8 expert IDs, the router's scores
over all experts, and the early-read guess's scores for the NEXT layer,
computed from this layer's router input the way the runtime does it (the
fitted guess file, dequantized: w = q * scale + bias per 64-wide group, unit
effective scale). Without a guess file, the next layer's own router is used,
which is the runtime's fallback. Row L of `guess` scores layer L + 1; the last
layer's row is unused.
"""
import json, os, sys
import numpy as np


def load_trace(directory):
    meta = json.load(open(os.path.join(directory, "meta.json")))
    D, E, K = meta["hiddenSize"], meta["numExperts"], meta["topK"]
    rec = np.dtype([
        ("position", "<i4"), ("layer", "<i4"), ("miss_count", "<i4"),
        ("experts", "<i4", K), ("misses", "<i4", K),
        ("scores", "<f4", E),
        ("router_input", "<f2", D), ("layer_output", "<f2", D),
    ])
    assert rec.itemsize == meta["recordBytes"], (rec.itemsize, meta)
    data = np.memmap(os.path.join(directory, "trace.bin"), dtype=rec, mode="r")
    L = meta["numLayers"]
    T = data.shape[0] // L
    data = data[: T * L].reshape(T, L)
    assert (data["layer"] == np.arange(L)).all(), "records not in layer order"
    return meta, data


def bf16_to_f32(u16):
    return (u16.astype(np.uint32) << 16).view(np.float32)


def load_guess(path, meta):
    """Returns a list indexed by target layer (1..L-1) of dense float32 [E][D]."""
    raw = open(path, "rb").read()
    assert raw[:8] == b"TFNLG1\0\0", "not a guess file"
    nL, E, D, G, first, count = (int(v) for v in np.frombuffer(raw, "<u4", 6, 8))
    assert (nL, E, D) == (meta["numLayers"], meta["numExperts"], meta["hiddenSize"])
    assert first == 1 and count == nL - 1
    off, mats = 64, [None]
    n, ng = E * D, E * D // G
    for _ in range(count):
        q = np.frombuffer(raw, np.uint8, n, off).reshape(E, D // G, G); off += n
        s = bf16_to_f32(np.frombuffer(raw, "<u2", ng, off)).reshape(E, D // G, 1); off += 2 * ng
        b = bf16_to_f32(np.frombuffer(raw, "<u2", ng, off)).reshape(E, D // G, 1); off += 2 * ng
        mats.append((q * s + b).reshape(E, D).astype(np.float32))
    assert off == len(raw), (off, len(raw))
    return mats


def main():
    src, out = sys.argv[1], sys.argv[2]
    meta, data = load_trace(src)
    T, L = data.shape
    E, D = meta["numExperts"], meta["hiddenSize"]
    if len(sys.argv) > 3:
        mats = load_guess(sys.argv[3], meta)
        guess_name = os.path.basename(sys.argv[3])
    else:
        mats = [None] + [np.fromfile(os.path.join(src, "router_L%02d.f32" % l), "<f4").reshape(E, D)
                         for l in range(1, L)]
        guess_name = "router"
    guess = np.zeros((T, L, E), np.float16)
    for l in range(L - 1):
        x = np.asarray(data[:, l]["router_input"], np.float32)
        guess[:, l] = (x @ mats[l + 1].T).astype(np.float16)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    np.savez_compressed(
        out,
        position=np.asarray(data[:, 0]["position"]),
        experts=np.asarray(data["experts"], np.int16),
        scores=np.asarray(data["scores"], np.float16),
        guess=guess,
        guess_name=np.array(guess_name))
    print("%s: %d tokens -> %s (%.1f MB)" % (src, T, out, os.path.getsize(out) / 1e6))


if __name__ == "__main__":
    main()
