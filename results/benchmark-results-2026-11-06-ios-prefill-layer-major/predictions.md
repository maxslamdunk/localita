# Predictions: prefill layer at a time across chunks

Written before any run of the change (`7e239c3`), and committed before the
runs that score it, the Mac check included.

## The change

A text prompt from an empty KV that needs more than one chunk now runs one
layer at a time. For each layer, every chunk's attention block and shared
expert run in order. Then the routed experts, reduce and tail run once over
the whole prompt, so each layer's experts are read once rather than once per
chunk. KV advances and the prefill commits only after the last layer. The
idea is from zw5/ane-fieldfare `c17d0c2`. There, layers move outside the
chunk loop; here that alone would read the same bytes, because the expert
cache is per layer, so the routed step is lifted to the whole prompt.

It applies only at `startPosition == 0` and up to 4096 tokens (prompt-wide
rows cost 62,000 B a token: 186.93 MB at 3015 tokens). `--no-layer-major-prefill`
(`TURBO_FIELDFARE_PREFILL_LAYER_MAJOR=0`) keeps chunk by chunk, so both arms
are one binary.

Baseline: arm A of `results/benchmark-results-2026-11-04-ios-prefill-routed-tensorops/`
(long, 3015 tokens, 3 chunks): wall 56.25 / 54.12 s, prefill bytes 30,561.02
MiB in 9,541 reads, routed phase 17.04 / 16.67 s (fetch 16.23 / 15.79, drain
0.72 / 0.80), storage busy 16.10 / 15.67 s, GPU routed 4.31 / 4.20 s, GPU
attention block 19.06 / 19.16 s, GPU shared 16.78 / 16.61 s, peak footprint
3.381 GB.

## Runs

- **Mac check, first:** CLI, greedy, `--max-new 48`, long and medium (both
  multi-chunk at the Mac's cap), each arm once.
- **Phone A/B:** A = default (layer at a time), B = `--no-layer-major-prefill`.
  Long A B B A; medium A B B A as a control (one chunk on iOS, so both arms
  take the chunk path). `--max-new 32`, because only prefill changes. Otherwise
  the protocol: 24 slots, `--max-context 4096`, chunk `auto`, 300 s cooldowns,
  default hashed load.

## What moves (phone, long)

| | B (≈ baseline) | A, predicted |
| --- | --- | --- |
| prefill reads | ≈ 9,541 | **3,700–3,840** (at most 30 × 128) |
| prefill bytes, MiB | ≈ 30,561 | **11,850–12,300 (−60 to −61%)** |
| routed phase wall, s | 16.7–17.0 | **6–10** |
| prefill wall, s | 54–56 | **43–49 (−6 to −12 s)** |
| peak footprint | 3.38 GB | **+150 to +230 MB** |

## Controls

- **Generated text byte-identical** across arms, long and medium, on the
  phone and on the Mac (SHA-256). Every kernel the routed step uses works per
  row or per pair, so running it over the whole prompt does not change any
  row's arithmetic.
- **GPU routed time within ±25% of B.** Same pairs; larger tiles per expert
  could make it slightly faster, which is not the target.
- **GPU attention block and GPU shared within ±10% of B.** The same kernels
  on the same chunks.
- **Medium (one chunk): prefill bytes identical across arms**, 8,882.27 MiB
  in 2,773 reads, and its wall within run-to-run noise.
- Decode bytes/token over 32 tokens are not a control: decode starts from
  whatever each layer's cache holds after prefill, which now differs.

## Mac check

- Text identical across arms for long and medium.
- Long prefill bytes fall by more than 80%, since each of the Mac's chunks
  re-reads nearly all of a layer's experts.

## Mechanism

A 1024-token chunk routes 8,192 pairs over 128 experts, so it touches nearly
every expert of every layer, and 24 slots keep few between chunks: 9,541 reads
for 3 chunks is about 106 per layer per chunk. Over the whole prompt each
layer reads at most its 128 experts once. In step 2 storage became the
routed phase's critical path (overlap with the GPU 3.4–3.6 s of 15.7–16.1 s
busy), so fewer reads shorten the wall almost one for one, down to the GPU's
own routed time (~4.3 s) plus the part of the first-touch hashing that does
not overlap.

## What would falsify it

- Text differs on either host: a row sees the wrong data (offsets, aliasing
  of h2 on routedX, or a KV position).
- Reads above 4,000: the routed step is not running once per layer.
- Wall falling by less than 4 s with the bytes as predicted: something the
  layer order adds (more command buffers, blits, a lost overlap between a
  chunk's routed work and the next chunk's attention) costs what the reads
  saved.
- Footprint above +300 MB: buffers outlive the prefill or are double counted.

## Addendum: trusted load (written 2026-11-06 02:47, before these runs)

Written after long A1, B1 and B2 had run. A1 put its 3,478 reads mostly in
the file cache (fetch 1.60 s, mean 2.19 ms a read), warmed by the first-touch
SHA-256 of each layer file just before that layer's routed step. A new chat on
an already-loaded model does not hash, so the hashed benchmark flatters arm A
there. Long A B B A once more with `--trust-install`, after the main set,
same binary:

| | B, trusted | A, trusted |
| --- | --- | --- |
| prefill bytes, MiB | 30,561.02 (exact, as hashed) | 11,140.47 (exact, as hashed) |
| prefill wall, s | 58–70 | **43–50** |
| A − B | | **−12 to −22 s** |

- Mechanism: without the hash, B's 9,541 reads are random at 8–16 ms and
  A's 3,478 are too, so A's routed phase is bound by about 11 GB from
  storage (6–9 s), against B's ~30 GB.
- Controls: text `30e14eae…` in all four.
- Falsified if A − B is smaller than 8 s, or A's routed phase exceeds 12 s.
