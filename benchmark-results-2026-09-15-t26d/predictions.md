# Predictions — aged re-run of the 2026-08-19 artifact

Written before any probe or model run in this session. Binary unchanged since
2026-08-10 19:52 (the one behind every run 2026-08-11 → 2026-08-19). Artifact:
30 layer files rewritten sequentially 2026-08-19 22:40 on the 74%-full volume,
untouched since; volume still 74% full. Only age has changed.

## Controls (a miss here invalidates the run, not the hypothesis)

- Bytes/token **249.72 / 265.90 / 291.42 MiB**, hit rate **67.5% / 65.4% / 62.1%**,
  req/tok **240.00** — identical to the digit.
- Generated tokens 511 / 669 / 604, all `stop=endOfTurn`, stdout byte-identical
  to `benchmark-results-2026-08-11-t0h/measured/`.
- `cb1-wait` within **±3%** of 2026-08-18: 92.34 / 110.15 / 131.28 ms/fwd.

## Central prediction

- Cold `slotscan`, layers 07/18/25: mean **1.8–2.2 GB/s** (down from 2.48 at 0 h,
  at or above the 1.82 the 7-day-old 2026-08-11 artifact probed).
- Production fetch: **1.30–1.50 GB/s** on all three cases.
- Captured fraction (production ÷ probe mean): **≤ 75%**.
- Short case **3.25–3.50 tok/s**; medium and long within ±8% of 2026-08-18
  (2.858 / 2.674).

## What each outcome means

- **Probe ≥ ~1.9 and production fetch ≤ 1.50** → the gap is in-situ, not storage.
  The "fetch path leaves ~29%" reading stands and becomes the next thing to
  instrument (per-read latency inside `io`, slowest vs. mean per layer batch).
- **Probe ≤ 1.60, tracking production down** → storage aging explains the decay;
  retract the "~29% on the table" paragraph and treat rewrites as dead on this host.
- **Production fetch ≥ 1.60 on all three cases** → placement written on the emptier
  volume persisted; reopens the installer change (IO-12).

## Outcome (appended after the run, 2026-09-15 19:37)

| Prediction | Measured | Verdict |
| --- | --- | --- |
| Bytes/token, hit rate, req/tok identical | identical to the digit | held |
| 511 / 669 / 604 tokens, `endOfTurn`, stdout identical to 2026-08-11 | all identical, warmups too | held |
| `cb1-wait` within ±3% of 2026-08-18 | −0.9% / −2.4% / −2.1% | held |
| Probe mean 1.8–2.2 GB/s | 1.99 (round 1), 1.92 (round 2) | held |
| Production fetch 1.30–1.50 GB/s | 1.744 / 1.676 / 1.674 | **missed high** |
| Captured ≤ 75% | 88% (1.744 / 1.99) | **missed high** |
| Short 3.25–3.50 tok/s | 3.745 | **missed high** |
| Medium / long within ±8% of 2.858 / 2.674 | +17.1% / +11.7% | **missed high** |

The branch that fired: **production fetch ≥ 1.60 on all three cases — placement
persisted.**

Found while scoring: the 2026-08-18 and 2026-08-19 fetch figures were GiB/s
labelled GB/s (4.9% low). The correction row is in `MEASUREMENTS.md`; with it,
the "≤ 75% captured" prediction was itself built on the understated figures.
