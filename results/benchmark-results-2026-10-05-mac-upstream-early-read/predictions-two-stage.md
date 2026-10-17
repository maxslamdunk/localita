# Predictions: the two-stage community benchmark on the M1

Written before any run with the router guess at two reads per layer, and
before reading any friend's results from this version of the benchmark.

## Setup

`Scripts/benchmark-early-read.sh` at `fa8bca9` on the fork branch
`early-expert-read-benchmark`. That commit changes only the benchmark scripts
and instructions; the runtime is the same as `1a4c9ab`, the build of
[`results.md`](results.md). Same Mac and protocol as there. One warmup per
case (router ×2), discarded, then:

1. **Stage 1:** each case in the order off, router, router ×2, router ×2,
   router, off.
2. **Stage 2:** short case only, (router ×2, fitted ×2, fitted ×2, router ×2)
   four times, giving eight adjacent pairs. Each pair is scored as fitted ×2 /
   router ×2 − 1.

×2 is `TURBO_FIELDFARE_EARLY_EXPERT_READS=2`. A 2-minute pause precedes each
run.

## What moves

- **Router ×2 vs router, tok/s: +5% to +18% per case.** With the fitted
  guess, the second read gave +7.7 / +13.4 / +14.9%
  ([`results-two-reads.md`](results-two-reads.md)). The router's second guess
  should be right somewhat less often, but the storage side of the gain (the
  M1 reads faster with two requests in flight) is the same.
- **Router ×2 `loaded-early/tok`, short: 32–39.** Router ×1 loads 19.87. The
  fitted guess's second read added 17.41 (0.60 of its 29 reads); the router's
  second pick should hit 0.45–0.60.
- **Fitted ×2 above router ×2 in `loaded-early/tok`, on short:** by 2.5 to
  9.5 per token. At one read the gap is 4.23.
- **Stage 2: median pair +1% to +6%, fitted ×2 faster in at least 6 of 8
  pairs.** At one read, 4.2 more experts loaded early gave +3.3 to +3.6%; the
  gap at two reads should be similar in size.

## Controls

- `reads/tok` exactly 29.00 (router) and 58.00 (×2).
- `needed/tok` 77.45 / 83.93 / 92.08, identical across settings.
- One distinct output per case across both stages, the same as every earlier
  run (`9c3bd04e…`, `d1f5e61b…`, `3fce8764…`).
- Router ×1 `loaded-early/tok` and precision exactly 19.87 / 20.41 / 20.96 and
  0.685 / 0.704 / 0.723; fitted ×2 short exactly 41.51 and 0.716.
- Off and router ×1 tok/s within 5% of [`results.md`](results.md)'s means
  (3.607 / 3.287 / 3.012 and 4.354 / 3.906 / 3.463). Fitted ×2 short within
  5% of 4.859.
- `guess=fitted` on every fitted run.

## What would falsify it

- Router ×2 slower than router ×1 on any case, or more than +18% faster.
- Router ×2 `loaded-early/tok` on short at or above fitted ×2's 41.51: the
  fitted guess's advantage does not survive a second read.
- Stage 2 median pair at or below 0, or above +8%.
- Any control off: a counter not exact, a second distinct output, or a fitted
  run with `guess=router`.
