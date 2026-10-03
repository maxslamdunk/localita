# Results: the early read with the fitted next-layer guess

Scored against [`predictions.md`](predictions.md), committed first in
`4a77dd5`. The code is `25e15c4`; the phone build is `c3cb85a`. Logs and
saved texts are in [`logs/`](logs/), the driver is [`run.sh`](run.sh), and
[`summarize.py`](summarize.py) prints every figure below
([`summary-output.txt`](summary-output.txt)). The Mac check is in
[`mac/`](mac/).

## Answer

**The fitted guess is better than step 1's on every case, with identical
output.** Precision rose from **0.550 / 0.587 / 0.606** to **0.684 / 0.728 /
0.752**, as predicted. That made bytes/token fall by **−6.1 / −5.8 / −5.6%**
against step 1, and `io` fall by **8.6 / 14.9 / 6.8 ms** per forward.

tok/s rose by **+5.2 / +4.2 / +13.4%** against step 1. The long figure is
inflated: the GPU happened to run fast in one of its fitted runs and slow in
both of the step 1 runs (see [GPU speed](#gpu-speed-varied-between-runs)).

| case | tok/s N → F | `io` ms/fwd | bytes/tok (footer MB) | precision N → F |
| --- | --- | --- | --- | --- |
| short | 6.299 → **6.626 (+5.2%)** | 87.05 → 78.48 (−8.57) | 202.49 → 190.09 | 0.550 → 0.684 |
| medium | 5.510 → **5.744 (+4.2%)** | 101.04 → 86.10 (−14.94) | 225.41 → 212.33 | 0.587 → 0.728 |
| long | 4.517 → **5.123 (+13.4%)** | 108.19 → 101.34 (−6.84) | 241.24 → 227.62 | 0.606 → 0.752 |

N is step 1's guess, the next layer's router. F is the fitted guess. The early
read is on in both arms. Figures are means of two runs per arm.

## What was run

Branch `next-layer-fitted-guess` at `c3cb85a`, built in Release and installed
over the app. The guess file was pushed to the app's `Documents`:
11,106,368 B, SHA-256 `b18242445534d452…`. Every F log's `runner-ready` line
carries that hash, and every N log says `earlyExpertGuess=router`.

Each case ran N F F N, on 2026-10-03 between 03:20 and 04:45:

- 24 slots, `--max-new 1024 --max-context 4096`, prefill chunk `auto`;
- iPhone 17, iOS 26.6;
- a 300 s cooldown between runs.

Thermal was `nominal` for every short and medium run. All four long runs
were mostly `fair`: N1 for 28 of 42 samples, the others for 36–39.

Before the phone, one Mac pair on the short case (16 slots) gave identical
text, precision 0.685 → 0.831, `io` −10.1 ms and +5.4% tok/s. That was one
pair, not interleaved; see the two `25e15c4` rows in `MEASUREMENTS.md`.

## Scoring

**P1, identical work: held.** Every case's four texts share step 1's hashes:
`d32db73b…`, `209ffadb…` and `87f6f357…`. Hit rate (79.1 / 75.7 / 73.4%) and
requests/token are identical across arms. Peak footprint changed by at most
1 MB.

**P2, live precision rises: held.**

| case | N | F predicted | F measured | gain |
| --- | --- | --- | --- | --- |
| short | 0.550 | 0.63–0.74 (point 0.685) | **0.684** | +0.134 |
| medium | 0.587 | 0.66–0.77 (point 0.717) | **0.728** | +0.141 |
| long | 0.606 | 0.69–0.81 (point 0.755) | **0.752** | +0.146 |

Every point prediction landed within 0.011. These were built from the offline
gain on the Mac traces added to step 1's live figure, so the offline study
continues to transfer to the phone.

**P3, fewer wasted reads: held exactly.** Reads/token changed by −3.88 /
−4.08 / −4.25, against −3.88 / −4.09 / −4.25 extra used reads. In footer MB
per token: −12.40 / −13.08 / −13.62, predicted −12.5 / −12.2 / −13.8.

**P4, `io` falls: held by its falsifier, but medium was outside the range.**
`io` fell on all three cases, so the falsifier (a rise on two or more cases)
did not fire. Against the predicted 4–9 ms:

- short **−8.57**;
- medium **−14.94**;
- long **−6.84**.

Medium's saving is high partly because this session's N arm had slower reads
than step 1's: medium N `io` was 101.0 ms here and 92.3 ms in step 1, for
identical work. Pooled over the three cases, each extra used read saved
**2.48 ms** of `io`. In step 1 each used read saved 1.35–2.0 ms.

**P5, `cb1-wait` within 0 ± 2 ms: falsified as written. The cause is GPU
speed, not the guess.**

- short **+0.88**;
- medium **+6.77**;
- long **−15.48**.

Two cases moved by more than 3 ms. Both moves follow runs in which the whole
GPU was slower, which the guess cannot cause:

- the output head runs after the last layer, never overlaps an early read, and
  does the same work in both arms;
- its GPU time moved with every other GPU part.

The next section has the numbers. Among runs where the GPU ran fast:

- medium F2 against N: `cb1-wait` −0.3 ms;
- short, where every run was fast: +0.88 ms.

So the guess GEMV costs what step 1's did. The kernel, the shape and the
weight bytes are the same.

**P6, tok/s +1 to +6%: held on short and medium, falsified high on long.**

| case | predicted | measured | GPU speed matched (after the fact) |
| --- | --- | --- | --- |
| short | +1 to +6% | **+5.2%** | +5.2% (all runs fast) |
| medium | +1 to +6% | **+4.2%** | +9.0% (F2 against both N runs) |
| long | +1 to +6% | **+13.4%** | +7.9% (F1 against both N runs, all slow) |

The last column picks runs after seeing the data, so it is not a test. It
does show that long's +13.4% is mostly GPU speed. Two things point the same
way:

- long's `io` saving (6.84 ms) is the smallest of the three cases;
- `io` alone accounts for about +3.1% at long's wall time.

## GPU speed varied between runs

The output head does the same GPU work in every run of a case. Its time per
forward:

| run | head GPU ms | attention+router GPU ms |
| --- | --- | --- |
| medium N1 / F1 / F2 / N2 | 8.93 / **10.95** / 8.94 / 9.01 | 29.16 / **37.65** / 29.77 / 29.66 |
| long N1 / F1 / F2 / N2 | **11.22** / **10.65** / 8.47 / **12.09** | **45.95** / **44.98** / 33.33 / **50.44** |

Four of the eight runs had every GPU part 20–50% slower than the fastest run of the case. On long that happened
at the same reported thermal state, `fair`, as the one fast run. Step 1's
medium B1 showed the same pattern. On medium it was the second run of the
case both times; the cause is not known.

**Consequence for measurement:** on the phone, consecutive runs of identical
work can differ by about 40% in GPU speed, and the reported thermal state does
not show it. A comparison that depends on `cb1-wait` needs the head's GPU time
beside it as a control.

## Against the early read being off

This is across sessions, so it is not a controlled comparison. Step 1's off
arm (A, 2026-10-03 00:45–02:12) against this run's F arm:

- tok/s **5.644 / 4.774 / 4.375 → 6.626 / 5.744 / 5.123 (+17 / +20 / +17%)**;
- bytes/token 160.71 / 187.08 / 204.59 → 190.09 / 212.33 / 227.62 footer MB,
  i.e. **+18 / +13 / +11%**.

## Decision

P1 and P2 held, so **the fitted guess replaces step 1's whenever the early read
is on.** The code already does this when the guess file is given.

Whether to turn the early read on by default is a product decision:

- **The trade:** about +17–20% tok/s for +11–18% bytes/token.
- **What shipping needs:** the guess file has to be shipped with the model.
- **Robustness:** the file was fitted on 2,119 tokens from seven prompts.
- **Tied to these weights:** a different model, such as `supergemma4`, needs
  its own fit.

Since P2 held and tok/s moved, guess quality was a real limit, not just timing.
The remaining idle time is the next question: whether a second early read per
layer fits on medium and long, where the idle window (2.26 / 2.47 ms) is
longest.
