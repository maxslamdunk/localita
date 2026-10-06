# Results: which layers the early read's hits land in

Scores [`predictions.md`](predictions.md). Twelve instrumented runs on the M1
MacBook Air (8 GB, macOS 26.6.1, on power, thermal nominal), 2026-10-06
21:23–22:10, at `1a4c9ab` plus [`instrumentation.diff`](instrumentation.diff).
One run per case of router, fitted, router ×2 and fitted ×2. Counters only;
tok/s is not quoted. Logs in [`runs/`](runs/), rows in `MEASUREMENTS.md`.

The first attempt stopped after two runs: the preflight matched the editor's
index build (`swift-build … --target TurboFieldfareMacPresentation`). The
script now skips finished runs and ignores the Swift toolchain's own processes
([`run.sh`](run.sh)).

## Verdict

**Falsified.** The fitted guess clears more layers than the router, more than
in proportion to its extra hits. Its extra hits are at least as valuable as the
router's, so where hits land cannot explain why fitted gained nothing over
router on the two 16 GB Macs.

## Numbers

Per token. A layer is **cleared** when it had at least one miss and an early
read supplied every one, so it read nothing itself.

| | short | medium | long |
| --- | ---: | ---: | ---: |
| loaded early, router / fitted | 19.87 / 24.10 | 20.41 / 24.44 | 20.96 / 25.23 |
| ratio | 1.21 | 1.20 | 1.20 |
| **cleared, router / fitted** | **3.43 / 4.60** | **2.78 / 3.73** | **2.13 / 2.98** |
| **ratio** (predicted ≤ 1.08; falsified at ≥ 1.15) | **1.34** | **1.34** | **1.40** |
| fitted's extra hits in layers with k ≥ 2 (predicted ≥ 65%) | 72% | 76% | 80% |
| loaded early, router ×2 / fitted ×2 | 33.16 / 41.51 | 34.53 / 42.73 | 36.06 / 44.91 |
| cleared, router ×2 / fitted ×2 | 6.93 / 9.76 | 5.73 / 8.24 | 4.81 / 7.17 |
| ratio (predicted ≤ 1.08) | 1.41 | 1.44 | 1.49 |
| precision, router ×2 | 0.572 | 0.595 | 0.622 |

The "≥ 65% in k ≥ 2" bullet holds but says nothing: most layers have two or
more misses, and the router's own hits are 83% in such layers on short. A
larger share of fitted's extra hits fall in single-miss layers (28% on short)
than of the router's hits (17%).

Layers by miss count k, per token, identical across all four settings:

| k | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| short | 2.42 | 6.11 | 7.51 | 6.09 | 3.91 | 2.18 | 1.12 | 0.50 | 0.17 |
| medium | 1.79 | 5.10 | 7.05 | 6.68 | 4.84 | 2.68 | 1.21 | 0.53 | 0.12 |
| long | 1.14 | 4.18 | 6.69 | 6.81 | 5.40 | 3.29 | 1.62 | 0.70 | 0.18 |

## Controls

All hold.

- One output per case across the four settings, the same SHAs as every earlier
  run: `9c3bd04e…`, `d1f5e61b…`, `3fce8764…`.
- `layers-by-misses` identical across settings. Per token the counts sum to
  30.00 and Σ k × count to `needed/tok`, within rounding.
- `used-by-misses` sums to `loaded-early/tok`.
- `needed/tok`, `loaded-early/tok` and precision for router, fitted and
  fitted ×2 exactly as in
  [`results.md`](../benchmark-results-2026-10-05-mac-upstream-early-read/results.md)
  and [`results-two-reads.md`](../benchmark-results-2026-10-05-mac-upstream-early-read/results-two-reads.md).

## What is left

The fitted guess works as designed. It is the same runtime the friends ran, its
counters match theirs exactly, adopted reads are skipped, and the text is
identical. The open question is about time, which counters cannot show. Two
candidates remain:

1. **Noise.** The friends' means are of 2 runs each. The friend's two-stage run
   on the M1 Pro, eight adjacent router ×2 / fitted ×2 pairs, is the test.
2. **On a 16 GB Mac, a skipped read is not always saved time,** for example
   because the router's hits already bring most layers' reads under the GPU
   work they overlap. The upstream build prints no phase timings, so this needs
   a timing footer in the benchmark build.

The prediction in `predictions.md` for the friend's stage 2 (median between
−2% and +2%) followed from the falsified mechanism and has no basis now.

**Scored 2026-10-07: missed.** The friend's run on the M1 Pro (16 GB, macOS
27.0.1, `fa8bca9`, fork issue #3) gave fitted ×2 faster than router ×2 in
**8 of 8 adjacent pairs, median +4.2%** (range +2.8 to +5.3%), with counters
identical to these and one output per case. So candidate 1 holds: the old
2-run means were noise, and the fitted guess helps on that 16 GB Mac too. The
same run gave router ×2 no gain over router (+0.6 / +0.1 / +0.0%).

Router ×2's counters land inside the ranges in
[`predictions-two-stage.md`](../benchmark-results-2026-10-05-mac-upstream-early-read/predictions-two-stage.md):
33.16 loaded early on short (predicted 32–39), 8.35 below fitted ×2
(predicted 2.5–9.5). That file is scored by the uninstrumented two-stage run.
