# Lossless expert compression: results

2026-10-04, M1 MacBook Air 8 GB (macOS 26.6.1), the installed
`scratch/gemma4.gturbo` (`mlx-community/gemma-4-26b-a4b-it-4bit`). No model
process was started and the iPhone was not connected, so every phone figure
below is arithmetic from Mac measurements plus the phone's recorded read
latency. Predictions: `predictions.md`, committed before each measurement.

## The answer

- **The bound is −15.2% of expert bytes.** That is the Shannon entropy of the
  installed experts under the best model found. Every richer context tried is
  worth ≤ 0.3 more points.
- **A purpose-built codec gets −14.0%.** It round-trips bit-exact on all 1,920
  held-out experts and decodes at 1.97 GB/s on one M1 performance core
  (9.45 GB/s on all eight).
- **zstd gets about −10%, LZ4 nothing,** as IO-07 said.
- **On decode, the codec is worth little.** With 24 slots, count aging and the
  early read, the phone does only ~1.2 foreground reads per layer:
  - **40% of layer-steps read nothing,** and 27% read one expert.
  - **Per read, 14% fewer bytes saves ~0.3 ms.** Decoding the last expert of
    a layer costs about the same, ~0.3 ms, even spread across every core.
  - **Predicted foreground `io`: −1 to −7%,** depending mostly on how fast an
    A19 core decodes. That is about +0.5 to +4% tok/s.
  - **The Mac replay measured no gain:** +1.8% `io`, within noise.
- **Compressing only the scales and biases is the better lever:**
  - **−7.4% of bytes.** Biases are almost a function of the scale: 1.4 bits
    instead of 16. Scales take 9.4 of their 16 bits.
  - **About a twelfth of the decode work** of the full codec.
  - **The 4-bit codes stay byte-identical.** They can be read straight into
    the slot.
  - **Predicted foreground `io`: −5 to −6%** across all parameters, about +2
    to +3% tok/s.
  - **Measured on the Mac replay: −5.8% `io`,** inside its prediction, with
    every compressed arm beating its raw neighbour
    ([below](#side-only-replay)).
- **TurboQuant does not help a lossless format:**
  - **It is a lossy quantizer** for the KV cache and vector search.
  - **Its random rotation makes weights more Gaussian,** which spreads the
    codes more evenly and so *raises* their entropy.
  - **Its ideas bear on a different, lossy experiment:** 3-bit rotated experts
    would cut code bytes by 25%. That needs the BF16 checkpoint and a quality
    measurement (see [TurboQuant](#turboquant)).
- **The +6–8% tok/s estimate behind this study does not survive.** It assumed
  the decode would hide behind reads. At ~1.2 reads per layer, there is too
  little read time to hide it behind.

## 1. What is in an expert, measured over all 3,840

From `collect_hists.py` and `entropy.py`; full output in `entropy-output.txt`.

| part | share of bytes | bits now | entropy | saving, share of all bytes |
| --- | --- | --- | --- | --- |
| 4-bit codes | 88.54% | 4 | 3.6835 given z | 7.01% |
| BF16 scales | 5.53% | 16 | 8.04 | 2.75% |
| BF16 biases | 5.53% | 16 | 1.38 given the scale | 5.06% |
| padding to the stride | 0.40% | | 0 | 0.40% |
| **whole expert** | | | | **15.21%** |

**Why the biases are nearly free.** MLX's affine quantizer:

- stores the bias as the group's larger-magnitude edge weight;
- stores the scale as `edge / q0` for an integer `q0`;
- so `bias = bf16(-z × scale)` exactly in 96.7% of groups, where z is the code
  of 0.0, and within one BF16 ulp in the rest. No group needed an escape.
- z is 8 in 65.3% of groups, 9 in 28.7% and 10 in 5.3%.

**Why the codes are not.** Given z, the codes are close to independent:

- the previous code in the group adds 0.0005 bits;
- the same position in the neighbouring expert adds 0.0001 bits;
- encoder-chosen classes of distribution lose more in side information than
  they gain.

The one context that helps is the group's scale relative to its row's median,
−0.0125 bits per code (0.3% of the codes). That figure comes from 4 layers × 8
experts, fitted and scored on the same data, in `contexts.py`.

3.68 bits is about what a 64-weight group of Gaussian weights quantized
between its own extremes gives: the step is ~0.32σ. There is no hidden
structure for a better coder to find.

## 2. Off-the-shelf codecs

`codecs.py`, 30 experts (one per layer), one thread. The padding is dropped
in every row, so 0.40 points of each saving is the padding.

| codec | size of raw | decode, GB/s |
| --- | --- | --- |
| zstd −1 / −3 / −19, whole expert | −9.59 / −9.89 / −10.39% | 1.09 / 1.06 / 0.86 |
| zstd −3, 64 / 128 / 256 KiB chunks | −9.76 / −9.02 / −9.33% | 1.03 / 0.96 / 0.96 |
| zstd −19, split streams | −11.13% | 1.05 |
| Apple LZ4 / LZBITMAP | −0.67 / −2.68% | 22.3 / 17.5 |
| Apple LZFSE / ZLIB / BROTLI / LZMA | −8.88 / −9.62 / −9.75 / −10.47% | 0.67 / 0.24 / 0.19 / 0.03 |

## 3. A purpose-built codec (`codec/excodec.c`)

**Format.** One expert is 24 independent chunks of 3,872 groups. Per group:

- the scale's high byte, Huffman-coded;
- the scale's low byte, raw;
- a (z, residual) symbol for the bias;
- 32 code bytes, Huffman over bytes with the table chosen by z.

All codes are limited to 11 bits. Each chunk is split into 8 bitstreams so the
decoder runs 8 independent chains. Tables are per layer and tensor, fitted on
even-numbered experts and scored on odd ones.

| | result |
| --- | --- |
| size, 1,920 held-out experts | **0.8596 of raw (−14.04%)**, 4 KiB-aligned −13.98% |
| codes, bits per code | 3.7034 (entropy 3.6835: Huffman's whole-bit loss) |
| round trip | **bit-exact, 0 of 1,920 differ** |
| decode, one M1 P core | **1.97 GB/s** of output |
| decode, all 8 M1 cores | 9.45 GB/s |
| one table set for all layers | −14.00% (per-layer tables are not needed) |
| 12-bit code limit | −14.13%, 1.77 GB/s (not worth it) |
| decoder progression | 1.0 GB/s (4 streams), 1.5 (8), 1.72 (unrolled), 1.96 (state in registers) |

**On the GPU** (`codec/gpudecode.metal`, `gpubench.swift`): same symbols, 32
streams per chunk, one thread per stream.

- **Correct:** bit-exact on 16 experts. It costs nothing in ratio (−14.01%).
- **Slow on the M1:**
  - **1.17 ms of GPU time for one expert,** 2.1 ms for three;
  - **4.4–5.1 GB/s at best** with 16 experts in flight, over two runs
    (`codec/gpubench-output.txt`).
  - Each thread walks a long serial Huffman chain, with its lookup tables in
    device memory. That is latency-bound, and the CPU is faster.

## 4. Does it pay on the storage path? The replay

`replay/replay.c` replays a decode's actual read schedule on the Mac's SSD.
`schedule.py` produced the schedule from the medium `real-generation-v1` trace
with 24 slots, count aging and the fitted early read: 36.7 foreground and 29
early reads per token. The replay uses F_NOCACHE and a 2.7 ms idle gap per
layer for the GPU work; there is no model.

### Two confounds found on the way

1. **File placement dominates on this disk.** A freshly written raw copy of
   the same experts read at **123.5 ms/token against 63 ms** for the installed
   files. The volume is 97–99% full, the same mechanism as IO-12. The
   compressed file was just as new.
   - The first replay, against that file, said +28%; it measured placement,
     not compression.
   - Every later replay **emulates** the compressed arm instead. It reads the
     compressed record's length at the expert's own place in the installed
     file, and decodes the real compressed bytes from RAM.
2. **Each read command costs ~0.2 ms here.** `replay/sizelat.c` measured QD1
   latency against size on the installed files as **t = 206 µs + bytes /
   2.30 GB/s**. A repeat gave 198 µs + bytes / 2.36 GB/s
   (`replay/sizelat-output.txt`). The first run:

   | size | mean |
   | --- | --- |
   | 64 KiB | 222 µs |
   | 512 KiB | 446 µs |
   | 3.36 MB | 1,711 µs |

   So splitting an expert into pieces, so that decoding can start early,
   costs more than it hides.

### Scored runs (emulated, means of A B B A, io = foreground read phase per token)

64 tokens, A B B A:

| compressed-arm schedule | reads only | with decode |
| --- | --- | --- |
| whole expert, fanned out like production | **−19.3%** | +7.3% |
| 6 sequential pieces per expert | +12.1% | +18.0% |
| 6 pieces, all concurrent | +2.5% | +4.4% |
| 12 pieces, all concurrent | | +19.2% |
| serial whole experts, last one split rest/3/1 chunks | −1.5% | −1.5% |

192 tokens, A B B A A B B A (`replay/replay-output.txt`):

| compressed-arm schedule | reads only | with decode |
| --- | --- | --- |
| serial whole experts | **−18.7%** | **+1.8%** |
| serial, last expert split rest/3/1 chunks | | +5.6% |
| whole experts, fanned out like production | | +5.1% |

- **The bytes do turn into time:** reads alone are 19% faster for 14% fewer
  bytes, under either schedule.
- **The decode takes it all back:** 13 ms per token, 0.7 ms for each layer
  that reads anything.
  - **That is twice** the 0.36 ms that 9.45 GB/s of all-core throughput
    implies for one expert.
  - **The likely cause is the slow cores.** Chunks that land on the M1's
    efficiency cores decode several times slower and set the tail. The
    A19's six cores are four efficiency and two performance.
- **Run-to-run noise is about ±5%.** Arms of the same configuration ranged
  63.5–71.5 ms/token.

<a id="side-only-replay"></a>
### Side-only replay

**The variant.** The 4-bit codes stay raw and only scales and biases are
compressed:

- **Record:** `[codes of gate, up, down: 2,973,696 B][side block]`. It is
  0.9258 of raw with 4 KiB alignment, and bit-exact on 256 held-out experts
  (`replay side-bench`).
- **Side block:** per tensor, 8 bitstreams of (scale-high, bias) symbol pairs,
  plus the raw low bytes of the scales. These are excodec's tables.
- **Decode:** 212 µs per expert on one M1 thread, run as three tasks, one per
  tensor.
- **Reads:** whole experts, fanned out as in production. The read lengths are
  placement-matched as above.

192 tokens, A B B A A B B A, `replay/replay-side-output.txt`:

| | raw `io` | side-only `io` | change |
| --- | --- | --- | --- |
| with decode | 65.60 | 61.80 | **−5.8%** |
| reads only | 65.09 | 59.73 | −8.2% |

Every compressed arm beat the raw arm before it: 60.3 < 63.2, 61.0 < 63.2,
61.9 < 64.6, 64.1 < 64.6. Decoding costs ~2.1 ms per token, a quarter of the
saving. The full codec's decode cost 13 ms per token and gave the saving back.

## 5. What it would do on the phone (`replay/model.py`, arithmetic)

The model's inputs:

- **Read time** is a + bytes / B, with a + S/B = 2.142 ms, the phone's
  measured QD1 p50 at the slot size.
- **The fixed cost a** is unknown on the phone, so it is swept over 0.05,
  0.1 and 0.2 ms.
- **A19 decode speed** is 1.0× or 1.5× an M1 performance core. All six cores
  together are 3.4× one.
- **Foreground reads per layer** come from the three test traces' schedules.

Change in foreground `io` per token:

| trace (fg reads/token) | full codec, whole reads | full codec, last expert split | side only |
| --- | --- | --- | --- |
| short (29.1) | −0.9 to −6.2% | −0.4 to −6.2% | −4.9 to −6.1% |
| medium (35.2) | −0.8 to −6.7% | −1.2 to −6.7% | −5.0 to −6.1% |
| long (41.1) | −1.4 to −7.1% | −1.8 to −7.1% | −5.1 to −6.2% |

In ms these are −0.3 to −6.2 for the full codec and −3.1 to −5.4 for side
only, against a wall of ~150–195 ms per token with the early read on: about
**+0.2 to +4%** and **+2 to +3% tok/s** respectively. Full output:
`replay/model-output.txt`.

**Prefill:**

- **The reads are worth −14% (full) or −7.4% (side only).** The phone's long
  prefill reads 30.6 GB in 76–90 s, about 19 s of storage time.
- **Production prefill already overlaps one tile of reads with compute**
  (PF-03), so the saving in time is at most the share of reads that is not
  hidden.
- **Unmeasured; bounded at about −3 to −6%** of prefill time for the full
  codec.

## 6. Predictions, scored

| # | predicted | measured | |
| --- | --- | --- | --- |
| 1 | codes order-0 3.70–3.85 bits | 3.7059 | held |
| 2 | z lowers codes by 0.05–0.20 bits | 0.022 | **missed**: the codes depend on z less than assumed |
| 3 | byte entropy / 2 within 0.03 of nibble | 0.0006 | held |
| 4 | scales 9–11 bits | 8.04 | **missed**: more compressible |
| 5 | biases given the scale 3–6 bits | 1.38 | **missed**: much more compressible; MLX's edge-as-bias rule was not fully used |
| 6 | whole expert bound −11 to −17% | −15.21% | held |
| 7 | zstd −3 −8 to −11%; LZ4 ±0.5%; 128 KiB chunks within 0.5 points | −9.89%; −0.67% (−0.27% without the padding); −9.02% (0.87 points) | held, held on used bytes, **missed** |
| 8 | own coder within 1 point of bound, ≥ 1.5 GB/s/core | −14.04% (1.17 points), 1.97 GB/s | **missed** by 0.17 points, held |
| value | +6–8% tok/s | model +0.2 to +4% (full); Mac replay ~0 | **missed** |
| 9 | raw `io` 75–95 ms/token | 61–68 | **missed** |
| 10 | 6 pieces −9 to −13% | +18.0% | **missed**: each extra read costs ~0.2 ms |
| 11 | one read −4 to −9%, worse than (10) | +7.3%, better than (10) | **missed** |
| 12 | falsifier | fired | |
| 13 | side only −4 to −9% `io` | −5.8% | held |
| 14 | falsifier: not below raw by > 2%, or a B arm not beating the A before it | −5.8%; all four B arms beat their A | held (not fired) |

**What the misses taught.** The saving had been reasoned per byte. On this
storage it has to be reasoned per read, against a fixed cost per command and
a decode tail per layer.

- At ~1.2 foreground reads per layer, the tail is the same size as the saving.
- This is the same lesson as IO-11: the device's roof is a property of the
  access pattern, not only of the bytes.

## 7. What to do with this

**Recommendation.** Drop the full codec for decode. If any compressed format
is built, it should be **side-only**.

- **Expected effect:** +2 to +3% tok/s and −7.4% prefill bytes. The CPU cost
  is about 7 ms of one core per token.
- **The codes stay byte-identical,** so no kernel changes.
- **It is modest,** and it costs a `.gturbo` format change. That trade is the
  user's call.

**Before deciding, two phone measurements would settle what the Mac cannot:**

1. **Read latency against size on the iPhone 17** (`replay/sizelat.c`'s
   protocol in the harness). This gives the per-command cost a. If a is
   small, split reads become viable and the full codec's tail can be hidden.
2. **excodec's decode speed on the A19's performance and efficiency cores.**
   The full codec's value swings between +0.2% and +4% on this one figure.

**What a side-only build needs** (the runtime side is mapped in this study's
notes):

- **The routed kernels take every tensor offset from `layout.json`**
  (`ModelExpertIO.routedExpertOffsets`, checked in `Model.swift`). The
  repacker can therefore write a slot layout with the three code blocks first
  and the scales and biases after, with no kernel change.
- **Records stop being one stride long,** and `GTurboPackedExpertsLayoutV1`
  requires `size == expertStride`. The layout needs a v2 with per-expert
  lengths.
- **The read** would be a `preadv`: codes into the slot, the side block into a
  small staging buffer.
- **The decode is then three tasks** writing scales and biases into the slot,
  before the slot is marked resident.
- **A small extra saving is available:** Huffman-coding the scales' low byte
  (7.05 bits for 8) would add ~0.3 points.

<a id="turboquant"></a>
## 8. TurboQuant

**What it is.** TurboQuant (Zandieh et al., arXiv 2504.19874, ICLR 2026) is a
lossy, data-oblivious vector quantizer:

- a random rotation;
- a per-coordinate Lloyd–Max quantizer;
- a 1-bit QJL residual for unbiased inner products.

Its paper evaluates the KV cache and nearest-neighbour search, not weights.
Upstream tried it on this model's KV cache: K4/V4 saved ~82 MiB at 4K and
failed the quality gate (`docs/OPTIMIZATION_JOURNEY.md`).

**For a lossless format it cannot help.**

- Lossless coding exploits a skewed code distribution.
- Rotation makes weights more Gaussian and outlier-free, so min/max affine
  codes fill their 16 levels more evenly. That raises the entropy this study
  measures.
- Rotation and entropy coding compete for the same redundancy.

**Where its idea does bear: a lossy 3-bit expert format.**

- **Rotated 3-bit experts** (Hadamard plus a Gaussian-optimal grid, as in
  HIGGS, QuIP# or a community turboquant-mlx port) would cut code bytes by
  25%, about 22% of every read. Unlike this study's tail-limited saving, that
  needs no decode step if the GEMV kernel dequantizes it.
- **It would also need:**
  - the BF16 checkpoint, about 52 GB, which does not fit on this Mac's 3 GB of
    free space;
  - a new kernel;
  - a quality measurement, kept opt-in until the user decides.
- **Not attempted here.**

## Files

| file | what |
| --- | --- |
| `collect_hists.py`, `entropy.py`, `entropy-output.txt` | Counts over all 3,840 experts; entropy bounds |
| `contexts.py`, `contexts-output.txt` | Richer contexts for the codes, on a subset |
| `codecs.py`, `codecs-output.txt` | zstd and Apple libcompression |
| `codec/excodec.c`, `excodec-output.txt` | The CPU codec: ratio, round trip, speed |
| `codec/gpucodec.c`, `gpudecode.metal`, `gpubench.swift`, `gpubench-output.txt` | GPU layout, Metal decoder, harness |
| `replay/schedule.py`, `schedule-*.txt` | Read schedules from the routing traces |
| `replay/replay.c`, `replay-output.txt`, `replay-side-output.txt` | Storage replay, raw against the full codec and against side-only |
| `replay/sizelat.c`, `sizelat-output.txt` | Read latency against size |
| `replay/model.py`, `model-output.txt` | The phone arithmetic |
