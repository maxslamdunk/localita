#!/usr/bin/env python3
"""Entropy bounds for the routed experts, from collect_hists.py's counts.

Every figure is the Shannon entropy of an empirical distribution, with one
table per (layer, tensor) unless marked "pooled" (one table per tensor kind
for all layers). Table cost is ignored: a 16x256 table is ~4 KiB against
~430 MB of experts per layer.

    entropy.py <hists.npz>
"""
import heapq
import sys

import numpy as np

KINDS = ["gate", "up", "down"]
STRIDE = 3_358_720


def bits(counts, axis=-1):
    """Total bits to code `counts` with their own empirical distribution, summed
    over all leading (context) axes."""
    c = counts.astype(np.float64)
    n = c.sum(axis=axis, keepdims=True)
    with np.errstate(divide="ignore", invalid="ignore"):
        p = np.where(c > 0, c / n, 1.0)
    return float(-(c * np.log2(p)).sum())


def huffman_lengths(counts):
    syms = [(int(c), i) for i, c in enumerate(counts) if c > 0]
    if len(syms) <= 1:
        return {s: 1 for _, s in syms}
    heap = [(c, [s]) for c, s in syms]
    heapq.heapify(heap)
    length = {s: 0 for _, s in syms}
    while len(heap) > 1:
        c1, s1 = heapq.heappop(heap)
        c2, s2 = heapq.heappop(heap)
        for s in s1 + s2:
            length[s] += 1
        heapq.heappush(heap, (c1 + c2, s1 + s2))
    return length


def huffman_bits(counts):
    """Bits with a Huffman code per context row (no length limit)."""
    flat = counts.reshape(-1, counts.shape[-1])
    total, maxlen = 0.0, 0
    for row in flat:
        if row.sum() == 0:
            continue
        lens = huffman_lengths(row)
        total += sum(row[s] * l for s, l in lens.items())
        maxlen = max(maxlen, max(lens.values()))
    return total, maxlen


def main():
    h = np.load(sys.argv[1])
    layers = h["layers"]
    nexp = 128 * len(layers)
    sel = lambda k: h[k][layers]
    groups = sel("groups")  # (L, K)
    ncodes = groups * 64
    total_groups = groups.sum()
    total_codes = ncodes.sum()
    raw_bytes = nexp * STRIDE
    code_bytes = total_codes / 2
    print(f"experts: {nexp}, layers {layers.min()}..{layers.max()}")
    print(f"z out of [0,15]: {sel('z_out_of_range').sum()} groups; negative scales {sel('neg_scale').sum() / total_groups:.1%}")
    print(f"groups containing code 0: {sel('groups_with_0').sum() / total_groups:.2%}, code 15: {sel('groups_with_15').sum() / total_groups:.2%}")
    print(f"padding bytes nonzero: {sel('padding_nonzero').sum()}")
    zc = sel("z").sum(axis=(0, 1))
    print("z distribution (code of 0.0):", {i: f"{c / zc.sum():.3%}" for i, c in enumerate(zc) if c})

    # --- codes ---
    print("\n## 4-bit codes, bits per code")
    rows = []
    o0 = bits(sel("code"))
    rows.append(("order-0, per layer x tensor", o0))
    rows.append(("order-0, pooled per tensor kind", bits(sel("code").sum(axis=0))))
    rows.append(("byte (two codes) order-0 / 2", bits(sel("byte"))))
    zc_bits = bits(sel("z_code"))
    rows.append(("given z", zc_bits))
    rows.append(("given z, pooled per tensor kind", bits(sel("z_code").sum(axis=0))))
    rows.append(("byte given z / 2", bits(sel("z_byte"))))
    rows.append(("given z and the previous code in the group", bits(sel("z_prev_code"))))
    for name, b in rows:
        print(f"  {name:48s} {b / total_codes:.4f}  ({1 - b / total_codes / 4:+.2%} vs 4 bits)".replace("+-", "-"))
    hb, hmax = huffman_bits(sel("z_byte"))
    print(f"  {'Huffman over bytes, table per (layer,tensor,z)':48s} {hb / total_codes:.4f}  (max code length {hmax})")
    hb0, hmax0 = huffman_bits(sel("byte"))
    print(f"  {'Huffman over bytes, table per (layer,tensor)':48s} {hb0 / total_codes:.4f}  (max code length {hmax0})")
    per_kind = [bits(sel("z_code")[:, k]) / ncodes[:, k].sum() for k in range(3)]
    print("  given z, by kind:", {KINDS[k]: round(v, 4) for k, v in enumerate(per_kind)})
    per_layer = [bits(sel("z_code")[i]) / ncodes[i].sum() for i in range(len(layers))]
    print("  given z, by layer:", " ".join(f"{v:.3f}" for v in per_layer))

    # --- scales ---
    print("\n## BF16 scales, bits per scale")
    s16 = sel("scale16")
    s_o0 = bits(s16)
    hi = s16.reshape(*s16.shape[:2], 256, 256).sum(axis=3)
    h_hi = bits(hi)
    h_lo_given_hi = s_o0 - h_hi
    h_hi_prev = bits(sel("scale_hi_prevhi"))
    lo_only = bits(s16.reshape(*s16.shape[:2], 256, 256).sum(axis=2))
    print(f"  16-bit order-0                          {s_o0 / total_groups:.3f}")
    print(f"  high byte {h_hi / total_groups:.3f}, low byte alone {lo_only / total_groups:.3f}, low given high {h_lo_given_hi / total_groups:.3f}")
    print(f"  high byte given previous high byte in the row {h_hi_prev / total_groups:.3f}")
    s_best = min(s_o0, h_hi_prev + h_lo_given_hi)
    print(f"  best: {s_best / total_groups:.3f}")

    # --- biases ---
    print("\n## BF16 biases, bits per bias")
    b_o0 = bits(sel("bias16"))
    zres = sel("z_biasres")
    esc = zres[..., -1].sum()
    b_given_scale = bits(zres.reshape(*zres.shape[:2], -1)) + esc * 16
    print(f"  16-bit order-0                          {b_o0 / total_groups:.3f}")
    print(f"  given the scale: (z, residual) jointly   {b_given_scale / total_groups:.3f}  (escapes {esc}, charged 16 bits each)")
    res = zres.sum(axis=(0, 1, 2))
    mid = (len(res) - 1) // 2
    print("  residual (bias bits - bf16(-z*scale) bits):", {i - mid: int(res[i]) for i in range(len(res) - 1) if res[i]})

    # --- totals ---
    print("\n## Whole expert, entropy bound (bytes, all experts)")
    pad = nexp * STRIDE - code_bytes - 4 * total_groups
    bound = (zc_bits + s_best + b_given_scale) / 8
    o0_bound = (o0 + s_o0 + b_o0) / 8
    for name, b in [("order-0 everything, padding dropped", o0_bound), ("conditioned (codes|z, scales, bias|scale)", bound)]:
        print(f"  {name:44s} {b / raw_bytes:.4f} of raw  ({b / raw_bytes - 1:+.2%})")
    print(f"  shares of the saving: codes {(code_bytes - zc_bits / 8) / raw_bytes:.2%}, scales {(2 * total_groups - s_best / 8) / raw_bytes:.2%}, "
          f"biases {(2 * total_groups - b_given_scale / 8) / raw_bytes:.2%}, padding {pad / raw_bytes:.2%}")
    hb_total = (hb + s_best + b_given_scale) / 8
    print(f"  Huffman bytes|z for codes + bounds for the rest: {hb_total / raw_bytes - 1:+.2%}")


if __name__ == "__main__":
    main()
