#!/usr/bin/env python3
"""Count symbol statistics over every routed expert of an installed .gturbo.

Reads one expert (3.36 MB) at a time, never the whole file. Writes the counts
to an .npz; entropy.py turns them into bits. Usage:

    collect_hists.py <model.gturbo> <out.npz> [--layers 0,1,...] [--experts N]
"""
import argparse
import json
import os
import sys
import time

import numpy as np

KINDS = ["gate", "up", "down"]
BIAS_RES = 64  # bias residuals in [-BIAS_RES, BIAS_RES) are counted, others escape


def bf16_to_f32(u16):
    return (u16.astype(np.uint32) << 16).view(np.float32)


def f32_to_bf16_bits(f):
    b = f.astype(np.float32).view(np.uint32)
    b = b + 0x7FFF + ((b >> 16) & 1)
    return (b >> 16).astype(np.uint16)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("out")
    ap.add_argument("--layers", default=None)
    ap.add_argument("--experts", type=int, default=None)
    args = ap.parse_args()

    layout = json.load(open(os.path.join(args.model, "packed_experts", "layout.json")))
    nlayers = layout["numLayers"]
    layers = range(nlayers) if args.layers is None else [int(x) for x in args.layers.split(",")]
    tens = layout["layers"][0]["experts"][0]["tensors"]
    stride = layout["expertStride"]
    end_used = max(t["offset"] + t["size"] for t in tens.values())

    L, K = nlayers, len(KINDS)
    h = {
        "code": np.zeros((L, K, 16), np.int64),
        "z_code": np.zeros((L, K, 16, 16), np.int64),
        "byte": np.zeros((L, K, 256), np.int64),
        "z_byte": np.zeros((L, K, 16, 256), np.int64),
        "z_prev_code": np.zeros((L, K, 16, 16, 16), np.int64),
        "scale16": np.zeros((L, K, 65536), np.int64),
        "scale_hi_prevhi": np.zeros((L, K, 256, 256), np.int64),
        "bias16": np.zeros((L, K, 65536), np.int64),
        "z_biasres": np.zeros((L, K, 16, 2 * BIAS_RES + 1), np.int64),
        "z": np.zeros((L, K, 16), np.int64),
        "groups_with_0": np.zeros((L, K), np.int64),
        "groups_with_15": np.zeros((L, K), np.int64),
        "groups": np.zeros((L, K), np.int64),
        "z_out_of_range": np.zeros((L, K), np.int64),
        "neg_scale": np.zeros((L, K), np.int64),
        "padding_nonzero": np.zeros((L,), np.int64),
    }
    t0 = time.time()
    for li in layers:
        entry = layout["layers"][li]
        path = os.path.join(args.model, "packed_experts", entry["file"])
        experts = entry["experts"][: args.experts] if args.experts else entry["experts"]
        with open(path, "rb") as f:
            for ex in experts:
                f.seek(ex["offset"])
                blob = np.frombuffer(f.read(stride), np.uint8)
                h["padding_nonzero"][li] += int(np.count_nonzero(blob[end_used:]))
                t = ex["tensors"]
                for ki, kind in enumerate(KINDS):
                    rows, cols = t[kind]["shape"]
                    ng = cols // 64
                    o = t[kind]["offset"]
                    by = blob[o : o + t[kind]["size"]].reshape(rows, ng, 32)
                    lo = by & 15
                    hi = by >> 4
                    codes = np.empty((rows, ng, 64), np.uint8)
                    codes[:, :, 0::2] = lo
                    codes[:, :, 1::2] = hi
                    so = t[kind + "_scales"]["offset"]
                    bo = t[kind + "_biases"]["offset"]
                    s16 = blob[so : so + rows * ng * 2].view(np.uint16).reshape(rows, ng)
                    b16 = blob[bo : bo + rows * ng * 2].view(np.uint16).reshape(rows, ng)
                    sf = bf16_to_f32(s16)
                    bf = bf16_to_f32(b16)
                    with np.errstate(divide="ignore", invalid="ignore"):
                        q0 = np.rint(bf / sf)
                    q0 = np.where(np.isfinite(q0), q0, 0)
                    z = -q0
                    h["z_out_of_range"][li, ki] += int(np.count_nonzero((z < 0) | (z > 15)))
                    z = np.clip(z, 0, 15).astype(np.int64)
                    h["neg_scale"][li, ki] += int(np.count_nonzero(sf < 0))

                    c = codes.astype(np.int64)
                    h["code"][li, ki] += np.bincount(c.ravel(), minlength=16)
                    zc = z[:, :, None] * 16 + c
                    h["z_code"][li, ki] += np.bincount(zc.ravel(), minlength=256).reshape(16, 16)
                    b = by.astype(np.int64)
                    h["byte"][li, ki] += np.bincount(b.ravel(), minlength=256)
                    zb = z[:, :, None] * 256 + b
                    h["z_byte"][li, ki] += np.bincount(zb.ravel(), minlength=4096).reshape(16, 256)
                    # previous code in the same group; the first code of a group uses prev = z
                    prev = np.concatenate([np.broadcast_to(z[:, :, None], (rows, ng, 1)), c[:, :, :-1]], axis=2)
                    zpc = (z[:, :, None] * 16 + prev) * 16 + c
                    h["z_prev_code"][li, ki] += np.bincount(zpc.ravel(), minlength=4096).reshape(16, 16, 16)
                    h["groups_with_0"][li, ki] += int(np.count_nonzero((codes == 0).any(axis=2)))
                    h["groups_with_15"][li, ki] += int(np.count_nonzero((codes == 15).any(axis=2)))
                    h["groups"][li, ki] += rows * ng

                    h["scale16"][li, ki] += np.bincount(s16.ravel().astype(np.int64), minlength=65536)
                    shi = (s16 >> 8).astype(np.int64)
                    prevhi = np.concatenate([np.zeros((rows, 1), np.int64), shi[:, :-1]], axis=1)
                    h["scale_hi_prevhi"][li, ki] += np.bincount((prevhi * 256 + shi).ravel(), minlength=65536).reshape(256, 256)
                    h["bias16"][li, ki] += np.bincount(b16.ravel().astype(np.int64), minlength=65536)
                    pred = np.where(z == 0, 0, f32_to_bf16_bits(-z.astype(np.float32) * sf))
                    res = b16.astype(np.int64) - pred.astype(np.int64)
                    res = np.where((res >= -BIAS_RES) & (res < BIAS_RES), res + BIAS_RES, 2 * BIAS_RES)
                    h["z_biasres"][li, ki] += np.bincount((z * (2 * BIAS_RES + 1) + res).ravel(), minlength=16 * (2 * BIAS_RES + 1)).reshape(16, 2 * BIAS_RES + 1)
                    h["z"][li, ki] += np.bincount(z.ravel(), minlength=16)
        print(f"layer {li} done, {time.time() - t0:.0f}s", file=sys.stderr, flush=True)
    np.savez_compressed(args.out, layers=np.array(list(layers)), **h)


if __name__ == "__main__":
    main()
