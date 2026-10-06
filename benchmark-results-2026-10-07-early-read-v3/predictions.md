# Predictions: the v3 early-read community benchmark

Written before any v3 run, on any Mac. v3 is meant to be the last benchmark of
the early read before the upstream PRs, so the decision rules are fixed here
too.

## Setup

`Scripts/benchmark-early-read.sh` v3 on the fork branch
`early-expert-read-benchmark`; the runtime is `1a4c9ab`'s. Each case runs
off, router, fitted, fitted ×2, fitted ×2, fitted, router, off twice in a row
after one discarded warmup, with a 2-minute pause before each run. That gives,
per case, 4 adjacent pairs for each of router vs off, fitted vs router and
fitted ×2 vs fitted, and 3 adjacent pairs of identical settings (the noise).
The report gives each pair's change, the median and the count of pairs in
favour, and flags runs more than 3% from their setting's median.

Why a third version: v1 reported means of 2 runs, and one of its sessions was
disturbed by 5–19% between runs
([`results.md`](../benchmark-results-2026-10-06-mac-early-read-cleared-layers/results.md)).
v2 was clean but compared router ×2, which no PR ships.

## Decision rules

Applied to every v3 report whose noise median is 2% or less and that has no
warning (fallback guess, battery, mixed commits, missing runs). A report that
fails this is shown in the PR but not used for the decisions.

1. **PR 1 (router guess)** claims a speedup if, on every Mac, router beats off
   in at least 3 of 4 pairs in every case.
2. **PR 2 (fitted guess)** claims fitted beats router if, on every Mac, the
   median of its 12 pairs is above 0. A Mac where it is not is named in the
   PR.
3. **The Mac default becomes two reads** if, on every Mac, fitted ×2 beats
   fitted in at least 3 of 4 pairs in every case. Otherwise it stays one read,
   with two as the documented opt-in `TURBO_FIELDFARE_EARLY_EXPERT_READS=2`.
   The iPhone stays at one either way.

## What moves

Medians of each case's 4 pairs.

**Our M1 MacBook Air, 8 GB**, from
[`results.md`](../benchmark-results-2026-10-05-mac-upstream-early-read/results.md)
and [`results-two-reads.md`](../benchmark-results-2026-10-05-mac-upstream-early-read/results-two-reads.md):

| | short | medium | long |
| --- | ---: | ---: | ---: |
| router vs off | +14 to +25% | +13 to +24% | +10 to +20% |
| fitted vs router | +1.5 to +5.5% | +1.5 to +5.5% | +1.5 to +5.5% |
| fitted ×2 vs fitted | +4 to +12% | +8 to +19% | +9 to +20% |

So rule 3 passes on this Mac.

**The M1 Pro, 16 GB**, from its v2 run (fork issue #3):

| | short | medium | long |
| --- | ---: | ---: | ---: |
| router vs off | +20 to +35% | +20 to +35% | +18 to +32% |
| fitted vs router | +0.5 to +4% | +0.5 to +4% | +0.5 to +4% |
| fitted ×2 vs fitted | −1.5 to +3% | −1.5 to +3% | −1.5 to +3% |

The last row is the least certain. On this Mac a second router read added
13.3 hits and 15.7 wasted reads per token and gained nothing, so a hit and a
wasted read there are worth about the same, with opposite signs. Fitted ×2's
second read adds 17.4 hits and 11.6 wasted reads (short), which nets to about
+1%. If so, rule 3 fails on this Mac, and the default stays one read.

**Every other Mac:** router beats off in every case; fitted's median over
router is above 0.

**Noise:** the median difference between adjacent identical runs is 2% or less
on our M1 and 1.5% or less on the M1 Pro.

## Controls

- One output per case across all 16 runs, with the SHAs of every earlier run on
  the M1 family: `9c3bd04e…`, `d1f5e61b…`, `3fce8764…`. Other GPU families may
  produce other text, but still one per case.
- Counters exact on the M1 family: `needed/tok` 77.45 / 83.93 / 92.08; loaded
  early and precision 19.87 / 20.41 / 20.96 and 0.685 / 0.704 / 0.723
  (router), 24.10 / 24.44 / 25.23 and 0.831 / 0.843 / 0.870 (fitted), 41.51 /
  42.73 / 44.91 and 0.716 / 0.737 / 0.774 (fitted ×2).
- `guess=fitted` on every fitted run.

## What would falsify it

- Any median outside its range above.
- Rule 1 failing on any Mac.
- A second distinct output in any case, a counter off on the M1 family, or a
  fitted run with `guess=router`.
