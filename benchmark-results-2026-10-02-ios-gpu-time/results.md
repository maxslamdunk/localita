# Results: the GPU-time and read-latency lines on the iPhone

Scored against [`predictions.md`](predictions.md), committed first in
`b0cdc78`. Logs, saved text and the driver are in [`logs/`](logs/) and
[`run.sh`](run.sh). `summarize.py` prints the figures below from the logs.

## What was run

Main at `f6345d1` was built in Release and installed over the app. Then one run
of each `real-generation-v1` case, on 2026-10-02 between 22:58 and 23:16:

- 24 slots, `--max-new 1024 --max-context 4096`, prefill chunk `auto`;
- iPhone 17, iOS 26.6;
- battery 80–85% and charging, Low Power off, network on;
- a 60 s cooldown before the first run, then 300 s between runs.

Thermal was `nominal` throughout on short and medium. On long it was `fair` in
36 of 42 samples.

## Scoring

**P1, identical work: held.** All three texts match the B arm's SHA-256
(`d32db73b…`, `209ffadb…`, `87f6f357…`). bytes/token (160.71 / 187.08 /
204.59 MB) and hit rate (79.1 / 75.7 / 73.4%) match to the digit.

**P2, no visible cost: held.**

| case | B arm tok/s | this run | change |
| --- | --- | --- | --- |
| short | 5.750 | 5.443 | −5.3% |
| medium | 4.811 | 4.666 | −3.0% |
| long | 4.319–4.392 | 4.412 | +0.5% |

Short and medium are slower, but well within 10%. A single run cannot
separate a cost from session noise.

**P3, `cb1-wait` split: half held.**

- The attention + router buffer is **42%** of `cb1-wait` on short (predicted
  45–65%: a narrow miss low), 47% on medium and 51% on long.
- The part no GPU buffer covers is **14.4 ms per token** on short (predicted
  5–15: held), 16.6 on medium and 16.3 on long. That is about **0.5 ms per
  layer**, the same as the Mac's 16–17 ms. The prediction that the A19's
  faster CPU would shrink it was wrong. The handoff cost is not CPU speed.

The uncovered figure is `cb1-wait − cb1 − routed × 29/30`. It assumes each
layer's routed buffer runs entirely inside the next layer's wait, as it did on
the Mac.

**P4, GPU mostly idle: held.** `busy` is **37 / 38 / 38%** of wall. The GPU is
idle **116 / 134 / 140 ms per token**. Of that, about **87 / 101 / 106 ms**
falls inside `io`: `io` minus the shared and cache-hit buffers, assuming both
run inside it.

**P5, reads: falsified on latency, held on the file cache.**

- The mean decode read is **5.88 / 6.09 / 6.12 ms** (predicted 2.5–4.5).
- **0.6–1.0%** of decode reads finish under 0.5 ms (predicted under 25%).

The latency miss has the same cause as on the Mac. A layer's misses are read
concurrently, and each read stretches by the number in flight. Storage time per
read (`io` ÷ reads) is **2.23 / 2.23 / 2.13 ms**, which matches the device's
serial read rate (p50 2,142 µs, 2026-09-16). Concurrency buys no throughput;
it only stretches each read.

The file cache serves essentially none of the misses on the phone, despite the
1–4 GiB knee measured with the probe. The app's own ~3.1 GB footprint leaves
it no room.

## What this means for prefetch

Storage sits idle from the end of one layer's reads until the next layer's
reads start. Per layer, that is (`cb1-wait` + `cb1` + `cb2`) ÷ 30:

| case | storage-idle window per layer | storage time per read | ratio |
| --- | --- | --- | --- |
| short | 1.88 ms | 2.23 ms | 0.84 |
| medium | 2.26 ms | 2.23 ms | 1.01 |
| long | 2.47 ms | 2.13 ms | 1.16 |

**One prefetch read per layer roughly fits.** k = 1, the operating point in
the next-layer prediction study, is the right budget. A second read would
not fit.

The read should be issued **after layer L's own misses finish, not as soon as
the prediction is ready.** Reads that overlap share storage time, so a
prefetch issued during layer L's reads would delay them by about one read.

**Upper bound, as arithmetic and not a measurement.** At fitted-early's 0.726
precision, about 21 useful prefetches per token × 2.2 ms ≈ 47 ms leaves the
critical path on short. On short the window is 0.35 ms shorter than a read,
which takes back about 10 ms. That leaves roughly **37 ms of 184 (≤ +25%
tok/s) on short, and ≤ 45 of 227 on long.** The real figure will be lower:

- the precision comes from Mac-generated traces;
- wasted reads still occupy storage;
- the staging and slot handling has its own cost.

**The handoff is a separate, smaller target.** The 14–17 ms per token that no
GPU work covers is **7–8% of wall** on the phone. That is the ceiling for
cutting the per-layer CPU round trip, independent of prefetch.
