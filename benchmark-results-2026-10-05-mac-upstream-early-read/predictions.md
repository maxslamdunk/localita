# Predictions: the early read on upstream's code, on the M1

Written before any run. This is the measurement behind the two upstream pull
requests: the early read (CACHE-10) ported onto `upstream/main` `77e8f9c`, with
the next layer's router as the guess (PR 1) and the fitted guess (PR 2).
Earlier Mac figures came from the port's code, from one pair each, not
interleaved (`MEASUREMENTS.md`, 2026-10-03 rows at `dd9dcba` and `25e15c4`).

## Setup

- **Build:** `early-expert-read-fitted` in `../turbo-fieldfare-upstream`,
  release CLI, so all three arms are one binary with a flag.
- **Mac:** M1 MacBook Air 8 GB, macOS 26.6.1, on power, other apps closed, one
  model process, preflight before every run.
- **Protocol:** `docs/COMMUNITY_BENCHMARKS.md` unchanged (one discarded warmup
  per case at defaults, three cases with their seeds, 4K context, 1,024 new
  tokens, T 0.2 / Top-K 64 / Top-P 0.95, upstream defaults otherwise), except
  that each case is measured six times in the order **off, router, fitted,
  fitted, router, off** via `--early-expert-read`, with a 2-minute pause
  between runs. The same loop is what friends will run.

## What moves (tok/s, mean of the two runs per arm)

| | short | medium | long |
| --- | --- | --- | --- |
| router vs off | +10 to +20% | +10 to +20% | +10 to +20% |
| fitted vs router | +2 to +8% | +2 to +8% | +2 to +8% |

Basis: the Mac short pairs measured +16.5% and +5.4%; the iPhone measured
+12 to +15% for the router and +4 to +13% more for the fitted guess.

## Controls

- **Generated text:** byte-identical across all six runs of a case (stdout
  SHA-256), and so `stop=endOfTurn` and the token counts too.
- **`needed/tok`:** identical between router and fitted runs of a case.
- **`reads/tok`:** 29.00 (one read per layer transition) in every on run.
- **Precision, short:** router **0.685**, fitted **0.831**, exactly, if the
  text matches the port's (`9c3bd04e…`); upstream's prefill chunk default
  (128) differs from the port's Mac default (256), so the text may differ, in
  which case within ±0.05 of those.
- Precision is lower on medium and long than offline at 16 slots (0.848 pooled
  for the fitted guess), but within 0.05 of it.

## Mechanism

Each layer's reads are followed by storage idle time while the GPU finishes
the layer and starts the next. A correct guess moves one of the next layer's
reads into that idle time, so the token waits for one fewer read; a wrong one
costs a read nobody waited for. The fitted guess is right more often, so more
reads move.

## What would falsify it

- router vs off below +5% on any case: the M1's idle window is shorter on
  upstream's code than on the port's, or wasted reads delay the demand reads.
- Any text difference between arms: a correctness bug; stop the PR.
- fitted below router on any case.
