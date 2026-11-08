# Predictions: storage read time against read size on the iPhone

Written and committed before any run.

## Why

The question is whether Qwen3.6-35B-A3B would decode faster or slower than
Gemma 4 on this phone. Its routed experts are 3 × 2048 × 512 parameters, about
**1,769,472 B** at our INT4 layout, against Gemma's 3,358,720 B slot. Per
token it would read about twice as many experts, each half the size. The phone
reads one expert at a time, so the fixed cost of a read decides whether
"twice the reads at half the size" costs the same as Gemma or more. Nothing
records the phone's read time at any size but 3,358,720 B.

Context for the decision, not scored here. At the memory our 24 slots use, Qwen
gets about 34 slots per layer, 13.3% of its 256 experts. TinyTitan's Qwen3.8
runs and our own Gemma slot matrix both put the hit rate at that share near
69–75%. That is 80–99 reads per token, against about 50 for Gemma.

## What is run

The out-of-repo probe app (`~/ml_projects/iphone-port/probes/memory-ceiling`,
the one behind the 2026-09-16 `ioread` row), with one new mode, `iosize`:

- the same 12.01 GiB corpus (30 files of 429,916,160 B, xorshift64\* bytes),
  rewritten fresh by `ioprep`, because the app was no longer installed;
- random `pread` over the whole corpus, one read in flight, into a 2 MiB-aligned
  buffer, with production's `O_RDONLY|O_NONBLOCK|O_CLOEXEC` **plus `F_NOCACHE`**,
  which production expert reads set on iOS since 2026-10-03;
- offsets are multiples of the read size inside each file, the way a packed
  layer file of that expert size would be laid out;
- three sizes, 60 s each, in the order A B C C B A:
  A = 3,358,720 B (Gemma), B = 1,769,472 B (Qwen3.6), C = 884,736 B (half of B,
  a linearity check);
- a 300 s pause between `ioprep` and `iosize`, so the writes do not heat the
  reads.

## Predictions

Model: time per read = `a + size / bandwidth`.

1. **Qwen-size read time (the question).** Mean time per read at 1,769,472 B
   is **1.10–1.35 ms**, which is **0.54–0.66×** the mean at 3,358,720 B.
   Mechanism: reads of this size are mostly bandwidth, with a fixed cost of a
   few hundred µs at most.
2. **Gemma-size control.** Throughput at 3,358,720 B is **1.55–1.85 GB/s**,
   against 1.650 GB/s on 2026-09-16 without `F_NOCACHE`, on a corpus written the
   same way.
3. **Fixed cost.** Fitting the line through the three sizes gives
   `a` = **0.05–0.40 ms**, and each size's mean lies within 5% of the line.
4. **Stability.** The two points at each size agree within 8%, and thermal
   never reaches `serious`.

## What would falsify it

- P1: a ratio above **0.70**. Then the fixed cost is large, and at 80–99 reads
  per token Qwen's `io` would come out 10–35% above Gemma's, before any other
  difference. A ratio below 0.52 would mean small reads are faster per byte,
  which no measurement here has shown.
- P2: Gemma-size throughput outside 1.55–1.85 GB/s, which would mean the fresh
  corpus or `F_NOCACHE` changed the device's behaviour, and the comparison with
  the 2026-09-16 row does not hold.
- P3: `a` outside 0.05–0.40 ms, or a size more than 5% off the line.
- P4: same-size points more than 8% apart, or `serious` thermal, in which case
  the sizes are not comparable and the run is repeated one size per session.

## How it is used

Qwen's `io` per token is about (reads per token) × (time per read). With 80–99
reads, the time per read at 1,769,472 B sets whether Qwen's `io` lands below
Gemma's 104–140 ms (`AGENTS.md`, 24 slots, early read off) or above it. This is
a storage measurement, not a Qwen run. Routing, hit rate and GPU time are still
estimates.
