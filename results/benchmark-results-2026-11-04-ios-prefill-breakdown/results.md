# Results: where text prefill's time goes on the iPhone 17

**Profiling, not a speed measurement.** These runs size the prefill work
ported from [zw5/ane-fieldfare](https://github.com/zw5/ane-fieldfare): routed
experts on the matrix units, and layer-at-a-time prefill across chunks. No
prediction was written, because nothing here was meant to make prefill faster.
The controls that would catch the instrumentation changing the work all held
(see [Controls](#controls)).

`summarize.py` prints every figure below from the logs in [`logs/`](logs/);
its output is [`summary-output.txt`](summary-output.txt). The drivers are
[`run.sh`](run.sh) and [`run-trusted.sh`](run-trusted.sh).

## What was run

- Branch `prefill-port` off main `b53c2af`, iOS app Release, installed over the
  app. The first four runs used `f6627ef` (the `[prefill-time …]` footer and
  `--prefill-profile`). The three `--trust-install` runs used `2355f2c`. The
  runtime is otherwise unchanged from main.
- iPhone 17, iOS 26.6. `real-generation-v1` `medium-review` (430 tokens, one
  chunk of 512) and `long-synthesis` (3015 tokens, three chunks of 1024). Prompt
  SHA-256 `23add797…` and `b12e4a71…`, matching the October runs.
- 24 slots, `--max-context 4096`, prefill chunk `auto`, defaults otherwise.
  **`--max-new 32`**: only prefill was under study.
- 2026-11-04. The first set ran 18:43–19:02 (battery 90–95%, charging). The
  trusted set ran 20:25–20:40 (100%, full). 60 s cooldown before each set, 300 s
  between runs. Thermal was `nominal` at every sample except one `fair` sample
  on the last run. Network on.
- Not held: a `BonsaiSpike` app process was alive on the phone in the
  background during the first set.
- Two attempts failed before producing data; both logs are kept. The first
  trusted run (`failed-decode-medium-trust-…`) was refused by `Model.load`,
  because the trusted path still checked the receipt's absolute path. That is
  what `2355f2c` fixes. The Mac then rebooted, and an install failed on a
  missing bundle (`driver-trusted-failed.log`).

Arms: **prof** adds `--prefill-profile`, which commits each layer's attention
block in five waited command buffers. **trust** adds `--trust-install`, which
loads without hashing the layer files.

## The breakdown

Seconds over the whole prefill, from the `[prefill-time …]` line.

| | medium plain | medium trust | long prof | long plain | long trust | long trust prof |
| --- | --- | --- | --- | --- | --- | --- |
| wall | 12.15 | 11.37 | 67.67 | 67.67 | 78.75 | 72.57 |
| GPU busy (union) | 6.80 | 6.68 | 61.12 | 61.52 | 67.08 | 62.46 |
| GPU routed experts | 3.17 | 3.05 | 22.99 | 23.30 | 26.71 | 23.81 |
| GPU shared expert | 2.51 | 2.52 | 16.97 | 16.92 | 17.27 | 16.75 |
| GPU attention block | 1.08 | 1.09 | 21.02 | 21.16 | 22.95 | 21.77 |
| … attention | | | 16.55 | | | 17.25 |
| … QKV projections | | | 2.42 | | | 2.52 |
| … output projection + norms | | | 1.46 | | | 1.49 |
| … router | | | 0.29 | | | 0.30 |
| … QK norm, RoPE, KV write | | | 0.31 | | | 0.21 |
| storage busy (expert reads) | 0.74 | 7.05 | 15.97 | 15.83 | 25.50 | 23.16 |
| storage overlapped by GPU | 0.57 | 2.74 | 11.48 | 11.45 | 17.27 | 16.34 |
| neither busy | 5.19 | 0.38 | 2.05 | 1.77 | 3.44 | 3.29 |

The medium profiled run (14.08 s wall) is in the summary. Its attention block
splits into attention 0.53, QKV 0.32 and output projection 0.19.

CPU-side wall, long plain: attention block 21.35, shared 18.16, routed 27.84
(fetch 15.97, drain 11.76), and route planning, tail and head 0.32 together.

### What it says

1. **The long prefill is GPU-bound.** The GPU is busy 90% of the hashed long
   run and 85–86% of the trusted ones. Storage is busy a quarter to a third of
   wall, and about 70% of that is under GPU work.
2. **Three GPU parts of about equal size**, long case: routed experts 23–27 s,
   shared expert ~17 s, and attention ~17 s. The projections are 4 s, and the
   router, tail and head under 1 s.
   - The **shared expert** runs the decode GEMV once per token
     (`PrefillSharedExpert.encodeBlock`). 3015 tokens × 30 layers each read
     the 17.8 MB of INT8 shared weights, about 1.6 TB in all. Its 25% share
     on the phone is not the ~10% assumed when a Core ML shared FFN was ruled
     out.
   - **Attention** is the 25 sliding-window layers. They use the scalar causal
     tiled kernel. Only the 5 full layers take the TensorOps path
     (`PrefillAttention.swift`, the 512/16/2 shape guard).
3. **The SHA-256 of the layer files is a cache warm, not a cost, on long
   prompts.** Every iOS load hashes each layer file on first touch: the app
   always loads with `.fullSha256`, and the benchmark falls back to it because
   the receipt's path cannot match. That pass reads each layer file
   sequentially. Its reads are not in the storage figure, which is why medium
   shows 5.19 s with neither part busy. The expert reads that follow then come
   from the file cache: 0.5–2 ms each, against 8–16 ms in the trusted runs.
   - **Medium:** hashing costs +0.8 s (12.15 against 11.37).
   - **Long:** hashing is 5–11 s faster than no hashing (67.67 against 72.57 and
     78.75). Chunk 1 is 18.3 s with the hash and 22.1–22.2 s without it.
   - So a sequential read of a whole 410 MiB layer file beats reading 85% of
     its experts at random. This matters for layer-at-a-time prefill, which
     reads close to a whole layer per layer.
   - **The 68 s benchmark understates a later chat turn.** A turn on an
     already-loaded model does not hash, so it should behave like the trusted
     runs.
4. **Medium is not GPU-bound in the same way.** Without the hash it is
   storage 7.05 s against GPU 6.68 s, overlapped for 2.74 s. Its one chunk gains
   nothing from layer-at-a-time prefill.
5. **Profiling costs nothing visible.** Long prof and long plain both took
   67.67 s; trust prof and trust plain differ by −7.8%, inside the ~8%
   run-to-run noise. GPU busy varied 61.1–67.1 s across the four long runs at
   `nominal`, the known GPU spread.

## Sizing (arithmetic, not predictions)

From the long figures, hashed (as the benchmark runs). Each line assumes the
others unchanged.

| change | long prefill now | after, roughly | basis |
| --- | --- | --- | --- |
| Routed experts on the matrix units (`587953b`) | routed wall 27.8 s, of which GPU 23 s | ~16–18 s, set by storage | GPU 23 → ~4 s at their 6.6×; the phase then waits on storage (~16 s busy) |
| Layer-at-a-time across chunks (`c17d0c2`) | 30.6 GB read | ~12 GB; −4 to −8 s alone | removes storage-only time and drains, but routed GPU (23 s) still dominates |
| Both together | routed wall 27.8 s | ~8–10 s | max(GPU ~4 s, storage for ~12 GB, partly sequential) |
| Shared expert as one INT8 GEMM | 17–18 s | ~2–3 s | dense 3015 × 2816 × 2112 × 3 GEMM on the matrix units. No upstream port fits: ane-fieldfare batches only a 4-bit shared FFN |
| Sliding-window attention on a tensor kernel (`65e3a69`) | ~16.5 s | ~3–5 s | their kernel covers both layer kinds; check its FP16 softmax weights |
| Projection tiles (`373ea28`) | ~4 s | ~2 s | small |

All of them together would bring the long prefill from ~68 s to roughly
15–25 s. Steps 2+3 alone would be ~45–50 s. The shared expert and attention are
each worth about as much as step 2 alone.

## Controls

- **Text:** byte-identical within each case across all arms, profiled, plain
  and trusted. Medium `28ca6ef4…`, long `30e14eae…`. Each 32-token text is a
  prefix of the October 1024-token output.
- **Prefill bytes:** exact and unchanged. Medium 8,875.86 MiB in 2,771 reads,
  long 30,605.86 MiB in 9,555 reads, both at 0.0% hit rate, matching the
  2026-10-02 and 10-08 runs.
- **Decode bytes/token and hit rate:** identical within each case (238.68 MB,
  72.1%; 270.72 MB, 67.2%). These cover a 32-token decode and are not
  comparable with 1024-token rows.
