# Predictions: which layers the early read's hits land in

Written before any run of the instrumented build, and before the friend's
two-stage run on an M1 Pro (16 GB) has reported.

## Why

Two friends' Macs, both 16 GB, ran the old community benchmark at `8fc001f`
(runtime identical to `1a4c9ab`). The early read with the router guess gave
+23 to +30% tok/s over off, but the fitted guess gave about nothing over the
router: −0.6 / −0.6 / −2.8% on the M1 Pro and −2.2 / +1.3 / +6.7% on the M3,
against +3.3 / +3.5 / +3.6% on our 8 GB M1 ([`results.md`](../benchmark-results-2026-10-05-mac-upstream-early-read/results.md)).
The M1 Pro's counters match ours exactly, so the fitted guess ran and its
24.10 early reads per token (short) were adopted, against the router's 19.87.

## Hypothesis under test

A layer reads its misses in parallel (`concurrentPerform` in
`PreadExpertStreamer.executeExpertCachePlan`). On a 16 GB Mac most of those
reads come from the OS file cache, where three parallel copies take about as
long as one. There, an early read pays mainly when it supplies a layer's
**last** miss, so the layer reads nothing. On our 8 GB M1 and the iPhone, reads
go to storage and their time grows with their count, so every used early read
pays.

So the router would already collect most of the valuable hits, and the fitted
guess's extra hits would land mostly in layers that still have other reads.

## Setup

`1a4c9ab` plus a scratch counter on the local branch
`scratch-early-read-cleared-layers` ([`instrumentation.diff`](instrumentation.diff)):
per decode forward, layers by their plan's miss count k (0–8), the used early
reads by k, and **cleared** layers (k ≥ 1 and every miss supplied by an early
read). Printed as a third footer line, `[early-read-layers …]`.

One run per case of router, fitted, router ×2 and fitted ×2
(`TURBO_FIELDFARE_EARLY_EXPERT_READS=2`), M1 MacBook Air 8 GB, community
protocol. Counters only: the runs are instrumented and their tok/s is not
quoted. The counters do not depend on the Mac: the M1 Pro's matched ours to the
last digit.

## What moves

- **cleared/tok, fitted ÷ router: 1.08 or less on every case**, while
  `loaded-early/tok` rises by 1.21 / 1.20 / 1.20.
- **At least 65% of fitted's extra used early reads** (about 4.2 per token)
  **fall in layers with k ≥ 2.**
- **The same at two reads:** cleared/tok, fitted ×2 ÷ router ×2, 1.08 or less.
- **The friend's two-stage run on the M1 Pro:** stage 2 median pair (fitted ×2
  vs router ×2) between −2% and +2%.

## Controls

- `layers-by-misses` identical across the four settings of a case. The cache
  plans the same either way.
- Per token, the layer counts sum to 30.00, and Σ k × count equals
  `needed/tok`.
- `used-by-misses` sums to `loaded-early/tok`.
- `needed/tok`, `loaded-early/tok` and precision exactly as in `results.md`
  for router and fitted, and `results-two-reads.md` for fitted ×2. One output
  per case, the same SHAs as every earlier run (`9c3bd04e…`, `d1f5e61b…`,
  `3fce8764…`).

## What would falsify it

- **cleared/tok, fitted ÷ router, at 1.15 or more on short:** fitted clears
  close to proportionally more layers, so its extra hits are no less valuable
  than the router's, and this mechanism cannot explain the 16 GB results.
- Between 1.08 and 1.15: inconclusive.
- Any control off.
