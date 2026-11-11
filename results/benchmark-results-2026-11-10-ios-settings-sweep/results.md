# Results: slots and expert skipping on an iPhone 18 Pro

Scored against [`predictions.md`](predictions.md), committed first in
`0202785`. The sweep is report `20261111T061352Z`: seven runs from a tester's
iPhone 18 Pro, sent to the Worker on 2026-11-11 at 07:16Z and exported into
[`benchmark-submissions/submissions.jsonl`](../../benchmark-submissions/submissions.jsonl).
[`summarize.py`](summarize.py) prints every figure below from that file, saved
in [`summary-output.txt`](summary-output.txt).
[`measurement_rows.py`](measurement_rows.py) wrote the `MEASUREMENTS.md` rows.
The logs stayed on the tester's phone, so the reports' footers are all there
is.

## Answer

**32 slots is faster than 24 on this phone at both skip settings, and the
decision rule passes, but only as a hint.** Run 1 and run 7, the same
setting, are 11.1% apart in the long case. The predictions said a gap over 8%
makes the sweep a hint, not a decision, and the long case passes the rule by
0.04 tok/s over that gap.

| Run | Slots / skip | short | medium | long | against run 5 |
| --- | --- | --- | --- | --- | --- |
| 5 | 24 / off | 13.81 | 11.55 | 10.70 | |
| 1 | 24 / 0.08 | 16.15 | 15.52 | 14.00 | +16.9 / +34.4 / +30.9% |
| 7 | 24 / 0.08 | 17.19 | 15.54 | 12.61 | +24.4 / +34.5 / +17.9% |
| 3 | 24 / 0.10 | 17.15 | 18.40 | 16.68 | +24.1 / +59.3 / +55.9% |
| 2 | 32 / off | 16.89 | 15.44 | 13.82 | +22.3 / +33.7 / +29.2% |
| 4 | 32 / 0.08 | 19.59 | 17.88 | 15.44 | +41.9 / +54.8 / +44.3% |
| 6 | 32 / 0.10 | 21.30 | 20.05 | 18.65 | +54.2 / +73.6 / +74.3% |

Decode tok/s, `newTokens / decodeSeconds` from each report.

At the iOS default skip of 0.08, 32 slots (run 4) is **+21.3 / +15.2 /
+10.2%** over run 1 and **+14.0 / +15.0 / +22.4%** over run 7. Every one of
those clears the project's 8% run-to-run noise, the long case against run 1
only just.

**32 slots with skipping off matches the current default's speed with the
output unchanged.** Run 2 reads 17.79 / 23.37 / 28.22 foreground experts per
token against 17.68 / 22.61 / 27.83 for 24 / 0.08, and decodes at 16.89 /
15.44 / 13.82 tok/s against 16.15–17.19 / 15.52–15.54 / 12.61–14.00. On a
12 GB phone, the extra slots can buy back what skipping costs in quality. That
choice, like the 32-slot default, is the user's.

## What was run

- **Device:** iPhone 18 Pro (`iPhone19,2`), 12 GB (12,195,266,560 B), iOS
  27.2.1, storage capacity unknown. A tester's phone, not ours.
- **Build:** app 1.0 (6), from `c414fa3`. Report format 3.
- **Protocol:** the in-app Settings sweep, in the order of the predictions'
  table. Early reads stayed at one per layer, and every report's settings
  match its row. Each case loads the model fresh.
- **Timing:** 06:13:52Z to 07:03:30Z. Cases waited 60–61 s, the minimum,
  because thermal never left `nominal`. Runs started 180–181 s after the
  previous one finished, again the minimum.
- **Conditions:** unattended, charging throughout, battery 45% → 95%.
  Thermal was `nominal` at the start and end of every case. The report has no
  thermal samples in between, and no compressor figure.
- **Prompt hashes:** `c57da267…` (short), `23add797…` (medium) and
  `b12e4a71…` (long), the same in all 21 cases and in every earlier
  submission. The model manifest is `1cb53c24…` everywhere.

All 21 cases stopped at end of turn. None was killed.

## Predictions, scored

### Absolute tok/s

17 of 18 numbers came in **above** their predicted ranges; only run 5's
medium (11.55, range 10.1–11.9) is inside. The ranges were built from the
phone's build-4 run (12.35 / 11.00 / 9.51 at 24 / off), and run 5 is
+11.8 / +5.0 / +12.5% over that, so part of the miss is the baseline. Most of
it is the mechanism, below.

### Against run 5, as the predictions asked

| Setting | Predicted | short | medium | long |
| --- | --- | --- | --- | --- |
| 24 / 0.08 (run 1) | +15–22 / +13–18 / +13–19% | +16.9, in | +34.4, above | +30.9, above |
| 24 / 0.08 (run 7) | same | +24.4, above | +34.5, above | +17.9, in |
| 24 / 0.10 | +25–37 / +24–36 / +23–41% | +24.1, below | +59.3, above | +55.9, above |
| 32 / off | +13–34 / +11–28 / +9–23% | +22.3, in | +33.7, above | +29.2, above |
| 32 / 0.08 | +22–48 / +22–46 / +21–44% | +41.9, in | +54.8, above | +44.3, above |
| 32 / 0.10 | +29–57 / +29–57 / +29–58% | +54.2, in | +73.6, above | +74.3, above |

Short lands inside its ranges in 5 of 6 rows. Medium and long are above in
11 of 12. **The model underpredicted every gain beyond the short case.**

### Controls

| Control | Predicted | Measured | Verdict |
| --- | --- | --- | --- |
| Text, run 1 = run 7 | identical | identical in all three cases | held |
| Text, run 2 = run 5 | identical | identical in all three cases | held |
| Early reads | 29.00/tok | 29.00 in all 21 cases | held |
| Prefill bytes | same across skip at a slot count | 6,941.17 / 8,869.45 / 11,124.45 MB in all 21 cases, across slot counts too | held |
| Hit rate, 32 − 24 | +5 to +9 pt | off +7.2 / +7.2 / +7.3; 0.08 +5.1 / +5.0 / +5.7; **0.10 +4.3 / +3.7 / +4.0** | held at off and 0.08, **missed at 0.10** |
| Settings in each report | match the protocol | match | held (the `runner-ready` lines are in logs that stayed on the phone) |

The 0.10 miss fits the mechanism: with more experts skipped, fewer misses are
left for the extra slots to turn into hits. The range should have narrowed
with the threshold.

### Footprint

32 slots peaked **+0.792 / +0.793 / +0.822 GB** over 24 (run 2 against run 1),
against +0.81 predicted, at 3.956 / 4.079 / 4.399 GB. Footprint plus
available memory is 6.442 GB in every case, as on every phone so far. At
32 slots 2.41–2.51 GB stayed available. No case was killed. Held.

**The report's peak is the process's peak since launch** (`ledger_phys_footprint_peak`,
`iOS/TurboFieldfareiOS/BenchmarkHarness.swift:120`). A sweep runs in one
process, so every case from run 2's long one on reports 4.399 GB, including
the 24-slot runs. Only runs 1 and 2 have a usable peak.

### Diminishing returns

What 0.10 adds over 0.08, against the mean of runs 1 and 7 at 24 slots:

| | at 24 | at 32 | foreground reads removed, 24 / 32 |
| --- | --- | --- | --- |
| short | +2.9% (+6.2 vs run 1, −0.2 vs run 7) | +8.7% | 6.05 / 3.70 |
| medium | +18.4% | +12.1% | 8.84 / 5.56 |
| long | +25.3% (+19.1 vs run 1, +32.3 vs run 7) | +20.8% | 10.03 / 6.59 |

Fewer reads are left to remove at 32 slots in every case, as predicted.
Medium and long gain less at 32. **Short gains more, which the predictions
named as a falsifier.** The short figure at 24 depends on which of runs 1 and
7 it is measured against, by more than the gap it would have to explain, so
this is within the sweep's noise. It is recorded as a miss all the same.

### The decision rule

| | run 2 − run 5 | run 4 − max(run 1, run 7) | run 1 / run 7 gap | |
| --- | --- | --- | --- | --- |
| short | +3.08 | +2.41 | 1.04 (6.4%) | pass |
| medium | +3.89 | +2.34 | 0.02 (0.1%) | pass |
| long | +3.12 | +1.43 | 1.39 (11.1%) | pass, by 0.04 |

The rule passes and no case was killed. The falsifier on the noise floor also
fires (long, 11.1% > 8%). Medium's 0.02 tok/s gap is a coincidence, not a
noise floor: the project's measured run-to-run noise is about 8%.

## The mechanism was wrong in one part

The predictions said slots and skipping cut only the reads `io` waits for:
"neither touches the GPU side", and wall falls by what `io` falls. Runs 5 and
2 differ only in slots and generate the same text, so they isolate this:

| | foreground reads removed | `io` | `cb1-wait` | wall | wall per removed read |
| --- | --- | --- | --- | --- | --- |
| short | 12.35 | −7.94 | −4.53 | −13.22 ms | 1.07 ms |
| medium | 13.24 | −10.59 | −9.76 | −21.84 ms | 1.65 ms |
| long | 14.08 | −10.37 | −9.40 | −21.15 ms | 1.50 ms |

**Wall fell about twice what `io` fell.** Each removed read saved 0.64–0.80 ms
of `io`, below the predicted 0.85–1.15, and 1.07–1.65 ms of wall, mostly
above it. The rest came out of `cb1-wait`, and GPU work that does not depend on
the setting ran faster:

| GPU ms per token, run 5 → run 2 | short | medium | long |
| --- | --- | --- | --- |
| shared expert (same work in every run) | 8.45 → 6.77 | 9.36 → 6.84 | 9.43 → 7.09 |
| head (same work in every run) | 4.43 → 4.09 | 4.72 → 4.01 | 4.72 → 4.12 |
| attention + router (`cb1`) | 12.90 → 11.71 | 17.31 → 14.17 | 20.49 → 17.13 |

Across all seven runs, the shared expert's GPU time tracks foreground reads:
5.88–6.20 ms in run 6 (6–11 reads), 8.45–9.43 ms in run 5 (30–42 reads). Two
explanations fit, and this sweep cannot separate them:

1. **The GPU runs slower when it waits more**, through clock scaling or
   memory contention from the reads. The settings would then act on the GPU
   side too, and the gains would be real.
2. **Run 5 was a slow GPU run by chance.** AGENTS.md records up to ~40%
   whole-run GPU variation at the same thermal state. Run 7's long case is one
   here: the same reads as run 1, but shared 9.03 ms against 7.26, and
   11.1% slower. Run 5 is the only run with 30 or more foreground reads, so
   one slow run would produce the same pattern.

The iPhone 17's skip A/B does not show the first effect. There, shared-expert
GPU time is 12.93–13.04 ms with skipping off and 12.85–13.28 ms at 0.08 in the
medium case (`../benchmark-results-2026-11-08-ios-expert-skip/logs/`). That
favours chance, or a difference between the A19 and the A20 Pro. Run 5 itself
is faster than the phone's build-4 run at the same setting, so it was not a
slow run by that measure.

If the first explanation is right, gains measured against a read-heavy
baseline on this phone are larger than `io` alone predicts. If the second is,
every "against run 5" figure above is inflated by run 5's slow GPU. The
comparisons that do not use run 5 (run 4 against runs 1 and 7, run 2 against
runs 1 and 7) hold either way.

## What would settle it

- **Repeat the sweep** on the same phone, so each setting has two runs. That
  resolves the long-case noise and whether run 5's GPU was slow by chance.
- **Fix the report's peak footprint** so each case reports its own peak, or
  at least name it as the process peak, before the next sweep.
- **The tester's manual check** with 32 slots set: the photo picker works and
  a long chat is not killed. Not reported yet.

## Falsifiers

| From the predictions | Result |
| --- | --- |
| 32 / off at or below 24 / off | no: +22.3 / +33.7 / +29.2% |
| Runs 2 and 5 generating different text | no: identical |
| 0.10 gaining more over 0.08 at 32 than at 24 | **yes in short** (+8.7% against +2.9%), within the sweep's noise; no in medium and long |
| A 32-slot case killed, or peak > 0.9 GB above 24 | no: +0.79–0.82 GB, nothing killed |
| Runs 1 and 7 more than 8% apart | **yes in long** (11.1%); short 6.4%, medium 0.1% |
