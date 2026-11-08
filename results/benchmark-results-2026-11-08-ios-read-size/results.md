# Results: storage read time against read size on the iPhone

Scored against [`predictions.md`](predictions.md), committed first in
`bb98cf7`. The driver is [`run.sh`](run.sh) ([`driver.log`](driver.log)); the
probe logs are in [`logs/`](logs/).

## Answer

**A read of Qwen3.6's expert size, 1,769,472 B, takes 1.133 ms, 0.545× a
Gemma-size read.** Reads on this phone are nearly pure bandwidth: the fixed
cost is **0.108 ms per read**, about 10% of a Qwen-size read. Twice the reads at
half the size costs about the same storage time as Gemma's reads.

| read size | point 1 mean | point 2 mean | mean | GB/s | p99 |
| --- | --- | --- | --- | --- | --- |
| 3,358,720 B (Gemma) | 2,104.3 µs | 2,052.8 µs | **2,078.6 µs** | 1.595 / 1.636 | 2,982 / 2,194 µs |
| 1,769,472 B (Qwen3.6) | 1,134.1 µs | 1,132.1 µs | **1,133.1 µs** | 1.560 / 1.563 | 1,237 / 1,218 µs |
| 884,736 B (check) | 633.6 µs | 631.8 µs | **632.7 µs** | 1.396 / 1.400 | 740 / 703 µs |

The fitted line is time per read = **107.6 µs + size / 1.707 GB/s**, from a
least-squares fit through the three means.

## What was run

iPhone 17 (`iPhone18,3`), 8 GB, iOS 26.6 (23G71), on battery: 90% at the start
of `iosize`, 85% at the end, unplugged. Other apps closed.

- **The probe:** the out-of-repo probe app
  (`~/ml_projects/iphone-port/probes/memory-ceiling`), Release, with the new
  `iosize` mode added for this run. It is the app behind the 2026-09-16
  `ioread` row. It was no longer installed, so it was reinstalled and the
  corpus was rewritten.
- **`ioprep`, 14:27:55:** 30 files of 429,916,160 B (12.01 GiB) of xorshift64\*
  bytes, written in 46 s. 38.2 GB of storage was free after it. The free-space
  read before the write returned −1.
- **The pause:** 300 s.
- **`iosize`, 14:33:46:** random `pread` over the whole corpus, one read in
  flight, into a 2 MiB-aligned buffer. The flags were
  `O_RDONLY|O_NONBLOCK|O_CLOEXEC` with `F_NOCACHE`. Offsets were multiples of
  the read size inside each file. The sizes ran A B C C B A, 60 s each.
- **Thermal:** `nominal` at every 5 s sample.

## Scoring

**P1 held, at the low end of its range.** Mean 1.133 ms against 1.10–1.35, a
ratio of 0.545 against 0.54–0.66. Reads of this size are bandwidth-bound, as
the mechanism said, with an even smaller fixed cost than assumed.

**P2 held.** 1.595 and 1.636 GB/s at the Gemma size, against 1.55–1.85.
2026-09-16 measured 1.650 GB/s without `F_NOCACHE` on a corpus written the same
way.

**P3 held.** The fixed cost is 0.108 ms, against 0.05–0.40. The three means sit
+0.2 / −1.0 / +1.1% off the line.

**P4 held.** The two points at each size agree within 2.5% (Gemma size), 0.2%
and 0.3%. Thermal never left `nominal`. The Gemma-size points carry the only
long tails, with maxima of 16.0 and 23.2 ms. They were the first and last
points.

## What it means for Qwen3.6-35B-A3B

This is a storage measurement, not a Qwen run.

Per-token storage time is reads × time per read.

- **Gemma, today:** 24 slots, short case, 79.1% hits. 240 × 0.209 ≈ 50 reads
  × 2.08 ms ≈ **104 ms**. That matches `io` in the `AGENTS.md` table (104 ms,
  early read off), so the model holds on known ground.
- **Qwen3.6, estimated:** about 34 slots per layer for the same memory.
  TinyTitan's Qwen3.8 runs and our Gemma slot matrix put the hit rate at
  69–75%. That is 80–99 reads × 1.133 ms ≈ **91–112 ms**.

So storage time per token comes out between 12% below and 8% above Gemma's.
Reads are nearly pure bandwidth, so this tracks bytes per token. The read count
does not matter much. This takes away the main way smaller experts could have
lost.

What remains unmeasured:
- the hit rate itself, which needs Qwen routing traces;
- 10 more layers of CPU/GPU handoff, about +5 ms per token;
- Qwen's GPU time, with about 3B active parameters against 3.9B, and the new
  Gated DeltaNet kernels;
- how many early reads fit into each layer's storage-idle time at 1.13 ms per
  read.
