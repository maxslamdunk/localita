# Predictions — iPhone 17 expert-cache slot count, 2026-09-16

Written **before** the runs, per the working agreement in `CLAUDE.md`.

## What is being tested

`--slots 24` and `--slots 32` against the measured 16-slot baseline, on all
three frozen `real-generation-v1` cases. Slots are **per layer**: 30 layers ×
`slotCount` buffers of 3,358,720 B each.

| slots/layer | buffers | slot memory | projected peak footprint |
| --- | --- | --- | --- |
| 16 (measured baseline) | 480 | 1.61 GB | 2.13 GB measured |
| 24 | 720 | 2.42 GB | ~2.94 GB |
| 32 | 960 | 3.22 GB | ~3.75 GB |

No code change: `RuntimeConfiguration.allowedExpertCacheSlots` already permits
`[8, 16, 24, 32]`.

## Why this is not a repeat of CACHE-03

[CACHE-03](../../docs/experiments/summaries/03-expert-cache-prediction-and-layout.md#cache-03)
tested exactly these slot counts and its disposition was **"Conditional +memory
experiment; production stays at 16"** — the hit-rate win "remained real, but it
violated the memory objective for the default." It was deferred on memory, not
refuted. The iPhone 17 supplies the missing condition: a measured 5.60 GB
ceiling with only 2.13 GB in use, and mmapped resident weights costing ~16.6 MB
rather than coming out of the budget.

CACHE-03's memory figures independently corroborate the arithmetic above: it
measured +769 MiB for 24 slots and +1.54 GiB for 32, against +0.81 GB and
+1.61 GB derived from `PreadExpertStreamer`.

## Predictions

Baseline, measured 2026-09-16: hit rate **67.7 / 64.9 / 62.3%**, bytes/token
**260.6 / 283.2 / 304.2 MB**, `io` **147.41 / 160.80 / 171.46** ms/forward,
tok/s **4.395 / 3.961 / 3.571**.

- **P1 — hit rate.** CACHE-03's trace replay gave +12.6–14.9 points at 24 slots
  and +20.9–23.7 at 32. Predict the same direction and rough magnitude here:
  **24 slots reaches 77–83%** and **32 slots reaches 83–89%** on the short case,
  with medium and long a few points lower.
  *Falsified if* either configuration gains fewer than **10 points** over its
  baseline case, which would mean device routing locality differs from the
  traces the replay used.
- **P2 — bytes/token.** Follows from P1 mechanically, since bytes/token =
  240 × (1 − hit rate) × 3,358,720 B. Predict **−35 to −50% at 24 slots** and
  **−45 to −65% at 32**.
  *Falsified if* the measured reduction is smaller than **20%** at 32 slots.
- **P3 — tok/s.** If `io` falls in proportion to bytes and nothing else moves,
  32 slots gives roughly **7.5 / 6.6 / 5.8 tok/s**. This is the weakest
  prediction: `io` hides the shared-expert branch, so shrinking it below that
  branch's duration buys nothing, and the prediction is deliberately stated so
  it can fail. Predict **at least +25%** on the short case.
  *Falsified if* tok/s improves by less than 10%, or falls.
- **P4 — footprint.** Peak `phys_footprint` **≤ 3.1 GB at 24 slots** and
  **≤ 4.0 GB at 32**, both under the 5.60 GB floor.
  *Falsified if* either exceeds 4.5 GB, or the app is killed by jetsam.
- **P5 — the failure mode to watch.** CACHE-03's **live** 32-slot row on the
  8 GB Mac collapsed to **1.578 tok/s** with `io` 318.3 ms/token and pipeline
  wait 238.3 — the signature of a host thrashing under memory pressure rather
  than of the cache being wrong. Predict the phone does **not** reproduce it.
  *Falsified if* `io` per forward rises above its baseline at any slot count.
  **If that happens it is the more important result**, because it would mean the
  measured ceiling headroom is illusory, and it would invalidate the memory
  budget every later Track B step is planned against.
- **P6 — quality.** Slot count changes only which expert bytes are already
  resident, never what is computed, so this is **quality-neutral by
  construction** and costs no accuracy. Bytes/token is memory-funded here, so
  per CACHE-03's lesson it must be reported as memory-funded speed, not as a
  memory-free optimization.

## Confounds to control

- **Thermal.** Six runs back-to-back heat the phone, and the long case already
  reached `fair` at 16 slots. Runs are separated by a cooldown, thermal is
  sampled every 16 tokens, and the order is alternated within each case pair
  (24→32, 32→24, 24→32) so monotonic heating does not systematically favour one
  slot count.
- **Artifact age.** Unchanged across all runs, so it cancels out of this
  comparison even though it makes the absolute numbers a fresh-artifact best case.
- **Verification policy.** `.fullSha256` throughout, as in the baseline.
