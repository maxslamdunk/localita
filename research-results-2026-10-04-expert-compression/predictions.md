# Lossless expert compression: predictions

Written 2026-10-04, before any byte of the installed experts was measured in
this study. It is offline: it decides whether a compressed expert format earns
a runtime prototype and a phone A/B, which would get its own predictions.

IO-07 (upstream, Mac) reported zstd saving about 10% and LZ4 0.06%. Those runs
are not ours and their method is unrecorded, so this study re-derives the
bound from the bytes and treats IO-07 only as a hint.

## What an expert is (from `packed_experts/layout.json` and `manifest.json`)

`mlx-community/gemma-4-26b-a4b-it-4bit`, affine INT4, group size 64, BF16
scales and biases. One expert is 3,358,720 B:

| part | bytes | share |
| --- | --- | --- |
| 4-bit codes, gate + up + down (5,947,392 weights) | 2,973,696 | 88.54% |
| BF16 scales (92,928 groups) | 185,856 | 5.53% |
| BF16 biases | 185,856 | 5.53% |
| padding to the stride | 13,312 | 0.40% |

## Why the bytes should be compressible at all

MLX's affine quantizer (the `quantize` op) sets the bias to the group's
larger-magnitude edge weight and the scale to `edge / q0` for an integer
`q0`, so that the weight 0.0 falls exactly on a code `z = -q0`. So:

- the bias is nearly a function of the scale and a 4-bit integer;
- the codes of each group are a peaked distribution around `z`, and an
  order-0 coder that ignores `z` sees a mixture of shifted peaks, which is
  wider than any one of them;
- BF16 exponents are concentrated, mantissas are not.

LZ4 has no entropy stage and only finds repeats, which quantized weights
barely have; that is why it should save ~0%.

## Predictions

Bits are Shannon entropy of the empirical distribution over the whole model
(30 layers × 128 experts), with tables shared per layer and tensor, so table
cost is negligible.

1. **Codes, order-0:** 3.70–3.85 bits per 4-bit code (−4 to −7.5%).
2. **Codes given `z`** (the group's zero code, recomputed from its bias and
   scale): 0.05–0.20 bits below order-0.
3. **Adjacent codes** add little: H(byte)/2 within 0.03 bits of the
   order-0 nibble entropy.
4. **Scales:** 9–11 bits of 16 (exponent byte concentrated, mantissa near
   uniform).
5. **Biases given the scale:** 3–6 bits of 16.
6. **Whole expert, entropy bound:** −11 to −17% bytes.
7. **zstd** (level 3, whole expert): −8 to −11%. **LZ4:** within ±0.5%.
   zstd with 128 KiB independent chunks: within 0.5 points of whole-expert.
8. **A purpose-built coder** (streams split by kind, Huffman or tANS over
   bytes with a table chosen by `z`) gets within 1 point of the bound in (6)
   and decodes at ≥ 1.5 GB/s of output per M1 performance core.

## What it would be worth on the phone (arithmetic, not a measurement)

`io` is ~60% of a decode forward and storage is serial at ~2.1 ms per
3.36 MB read, so read time scales with bytes. A saving of s on every expert
read cuts `io` by about s, the forward by about 0.6·s, minus the exposed tail
of decompression (one chunk per layer if chunks pipeline with reads). At
s = 12%: about **+6 to +8% tok/s** decode, prefill bytes −12%. Falsified as a
worthwhile path if the bound in (6) is under 6%, or if no decoder reaches
~1 GB/s per core (then decompression, not storage, sets `io`).

## Addendum, before the I/O replay (written after the entropy and codec results)

The codec is built: −14.0% on 1,920 held-out experts, bit-exact, 1.97 GB/s
per M1 performance core. `replay/replay.c` replays the read schedule of the
medium `real-generation-v1` trace (24 slots, count aging, fitted early read;
37.8 foreground + 29 early reads per token) on the Mac's SSD with F_NOCACHE,
with a 2.7 ms idle gap per layer standing in for GPU work. No model is
loaded. Predictions, means of A B B A:

9. **Raw `io`:** 75–95 ms/token (37.8 serial reads at ~1.7 GB/s plus early
   read waits).
10. **Compressed, 6 sequential pieces per expert, decode as pieces land:**
    `io` −9 to −13% against raw. Bytes are −14%; the loss is the decode tail
    of the last piece per layer (~0.1 ms) and the extra read commands.
11. **Compressed, the expert in 1 read:** `io` −4 to −9%, worse than (10),
    because the whole last expert's decode (~0.25 ms on 8 cores) is exposed
    per layer.
12. Falsified if compressed `io` is not below raw in every pairing, or if
    (10) is not better than (11).
