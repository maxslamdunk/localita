# Results: the fitted guess beats the router outside its training set

Scored against [`predictions.md`](predictions.md), committed first in
`9723b3a`. Runs in [`runs/`](runs/) (driver: [`run.sh`](run.sh)), rows in
`MEASUREMENTS.md` (2026-10-05, `1a4c9ab`). Build: the upstream contribution
branch `early-expert-read-fitted` at `1a4c9ab`, on the M1, 16 slots.

## Answer

**Yes, on all six prompts, by about the same margin as in English.** Precision
of the one early read per layer, router → fitted:

| prompt | router | fitted | gain |
| --- | --- | --- | --- |
| `ru-history` (Russian) | 0.492 | 0.606 | +0.114 |
| `zh-explain` (Chinese) | 0.507 | 0.641 | +0.134 |
| `es-recipe` (Spanish) | 0.568 | 0.696 | +0.128 |
| `story` | 0.683 | 0.813 | +0.130 |
| `multi-turn` | 0.690 | 0.835 | +0.145 |
| `sql-debug` | 0.704 | 0.839 | +0.135 |

Per token, the fitted guess has 3.3–4.2 more of the misses already loaded than
the router (e.g. `zh-explain` 14.72 → 18.60 of 58.57; `sql-debug` 20.43 →
24.33 of 91.00).

## Scoring

1. **English and code, +0.08 to +0.18: held.** +0.130 / +0.145 / +0.135.
2. **Russian, Chinese, Spanish, 0.00 to +0.15: held, but the reasoning was
   wrong.** I expected a smaller gain than in English. The gains, +0.114 /
   +0.134 / +0.128, are as large. What differs is the router: it guesses
   worse in those languages (0.49–0.57 against 0.68–0.70), and the fit adds
   the same amount on top. So the correction captures how the hidden state
   changes from one layer to the next, not the training prompts' vocabulary.
3. **Fitted precision within ±0.08 of the port's: held, exactly.** All six
   match the port's 2026-10-03 trace rows to three digits (0.606 / 0.641 /
   0.696 / 0.813 / 0.835 / 0.839). Upstream's code routes these prompts
   exactly as the port's code did then.

**Controls: held.** Per prompt, router and fitted produced byte-identical text
(SHA-256 in `runs/summary.txt`), identical `needed/tok`, and 29.00 early reads
per token.

**Falsifiers:** none triggered.

## Smoke run

Before these, `short-explanation` at `--max-new 64` with the read off, fitted
and router: identical text, `needed/tok` 82.46 in both on runs, precision
0.822 fitted and 0.682 router. Logs in `runs/smoke/`.

## Not shown

tok/s from these runs: one run per setting, not interleaved. The Mac A/B
(`benchmark-results-2026-10-05-mac-upstream-early-read/`) measures speed.
