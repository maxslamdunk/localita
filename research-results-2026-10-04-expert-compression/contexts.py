#!/usr/bin/env python3
"""Does any context beyond z lower the entropy of the 4-bit codes?

A second pass on a subset of layers. Every figure is bits per code, with the
side information an encoder would have to send included when the context is
not recomputable by the decoder. Tables are fitted and scored on the same
experts (8 per layer, 4 layers), which flatters every context equally.

    contexts.py <model.gturbo>
"""
import json
import os
import sys

import numpy as np

KINDS = ["gate", "up", "down"]
STRIDE = 3_358_720


def bf16(u16):
    return (u16.astype(np.uint32) << 16).view(np.float32)


def cond_bits(ctx, sym, nctx, nsym=16):
    c = np.bincount((ctx.astype(np.int64) * nsym + sym).ravel(), minlength=nctx * nsym).reshape(nctx, nsym).astype(np.float64)
    n = c.sum(axis=1, keepdims=True)
    with np.errstate(divide="ignore", invalid="ignore"):
        p = np.where(c > 0, c / n, 1)
    return float(-(c * np.log2(p)).sum())


def ent(x, n):
    c = np.bincount(x.ravel(), minlength=n).astype(np.float64)
    p = c[c > 0] / c.sum()
    return float(-(c[c > 0] * np.log2(p)).sum())


def load(model, layer, experts, kind):
    layout = json.load(open(os.path.join(model, "packed_experts", "layout.json")))
    t = layout["layers"][layer]["experts"][0]["tensors"]
    rows, cols = t[kind]["shape"]
    ng = cols // 64
    codes, sc, bi = [], [], []
    with open(os.path.join(model, "packed_experts", f"layer_{layer:02d}.bin"), "rb") as f:
        for e in experts:
            f.seek(e * STRIDE)
            blob = np.frombuffer(f.read(STRIDE), np.uint8)
            by = blob[t[kind]["offset"] : t[kind]["offset"] + t[kind]["size"]].reshape(rows, ng, 32)
            c = np.empty((rows, ng, 64), np.uint8)
            c[..., 0::2] = by & 15
            c[..., 1::2] = by >> 4
            codes.append(c)
            o = t[kind + "_scales"]["offset"]
            sc.append(blob[o : o + rows * ng * 2].view(np.uint16).reshape(rows, ng))
            o = t[kind + "_biases"]["offset"]
            bi.append(blob[o : o + rows * ng * 2].view(np.uint16).reshape(rows, ng))
    return np.stack(codes), np.stack(sc), np.stack(bi)


def kmeans_classes(hist, k, iters=12, seed=0):
    """Cluster per-group code histograms by code length; return total bits incl. log2(k)-ish side info."""
    rng = np.random.default_rng(seed)
    n = hist.shape[0]
    p = (hist[rng.choice(n, k, replace=False)] + 0.5)
    p /= p.sum(axis=1, keepdims=True)
    for _ in range(iters):
        cost = -hist @ np.log2(p).T  # (n, k) bits
        a = cost.argmin(axis=1)
        for j in range(k):
            m = hist[a == j].sum(axis=0) + 0.5
            p[j] = m / m.sum()
    cost = -hist @ np.log2(p).T
    a = cost.argmin(axis=1)
    side = ent(a, k)
    return float(cost[np.arange(n), a].sum()) + side


def main():
    model = sys.argv[1]
    layers = [0, 10, 20, 29]
    experts = list(range(0, 128, 16))
    tot = {}
    def add(name, b, n):
        tot.setdefault(name, [0.0, 0])
        tot[name][0] += b
        tot[name][1] += n
    for layer in layers:
        for kind in KINDS:
            codes, s16, b16 = load(model, layer, experts, kind)
            E, R, G, _ = codes.shape
            sf, bf = bf16(s16), bf16(b16)
            z = np.clip(-np.rint(bf / sf), 0, 15).astype(np.int64)
            c = codes.astype(np.int64)
            n = c.size
            zc = np.broadcast_to(z[..., None], c.shape)
            add("order-0", cond_bits(np.zeros_like(c), c, 1), n)
            add("given z", cond_bits(zc, c, 16), n)
            # z and the column group (input-dimension block), decoder knows it
            gidx = np.broadcast_to(np.arange(G)[None, None, :, None], c.shape)
            add("given z, column group", cond_bits(zc * G + gidx, c, 16 * G), n)
            # z and the exact column (64 positions inside the group x column group)
            col = np.broadcast_to((np.arange(G)[:, None] * 64 + np.arange(64)[None, :])[None, None], c.shape)
            add("given z, exact input column", cond_bits(zc * G * 64 + col, c, 16 * G * 64), n)
            # z and the scale's size relative to its row's median (decoder knows both)
            a = np.log2(np.abs(sf) / np.median(np.abs(sf), axis=2, keepdims=True))
            rb = np.clip(np.floor(a * 4) + 8, 0, 15).astype(np.int64)
            add("given z, |scale| / row median (16 bins)", cond_bits(zc * 16 + np.broadcast_to(rb[..., None], c.shape), c, 256), n)
            # z and the scale's size relative to the same (row, group) in the expert-mean (decoder knows it from a table)
            # sign of scale: tells which edge is the min
            sg = (sf < 0).astype(np.int64)
            add("given z, scale sign", cond_bits(zc * 2 + np.broadcast_to(sg[..., None], c.shape), c, 32), n)
            # side info: does the group use code 15 (the far edge)? 1 flag per group, coded at its entropy
            has15 = (codes == 15).any(axis=3).astype(np.int64)
            add("given z, has-15 flag (+ flag cost)", cond_bits(zc * 2 + np.broadcast_to(has15[..., None], c.shape), c, 32) + ent(has15, 2), n)
            # forward-adaptive classes: the encoder picks one of K per-z-shifted distributions per group
            d = (c - zc) & 15  # code relative to the zero code
            hist = np.stack([np.bincount((np.arange(d.reshape(-1, 64).shape[0])[:, None] * 16 + d.reshape(-1, 64)).ravel(),
                                         minlength=d.reshape(-1, 64).shape[0] * 16)]).reshape(-1, 16).astype(np.float64)
            for k in (1, 4, 16):
                add(f"shift by z, {k} encoder-chosen classes (+ class cost)", kmeans_classes(hist, k), n)
            # cross-expert: the same position in the neighbouring expert
            add("given z, same position in expert e-1", cond_bits(zc[1:] * 16 + c[:-1], c[1:], 256), c[1:].size)
            add("given z (same sample as above)", cond_bits(zc[1:], c[1:], 16), c[1:].size)
            print(f"layer {layer} {kind} done", file=sys.stderr, flush=True)
    print(f"layers {layers}, experts {experts[0]}..{experts[-1]} step 16, bits per code:")
    for name, (b, n) in tot.items():
        print(f"  {name:58s} {b / n:.4f}")


if __name__ == "__main__":
    main()
