# Predictions: a fitted next-layer guess for supergemma4

Written 2026-10-04 on branch `supergemma4-next-layer-guess` from `611c5e5`,
before any supergemma4 trace exists.

## Why

The early read is on by default for every model, but the fitted guess file is
matched to the model by manifest `sourceSnapshotHash`, and only gemma4 has one
(`Sources/TurboFieldfare/NextLayerGuess/index.json`). supergemma4
(`Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2` @ `1ecb758`,
`sha256:df3133d5…`) falls back to the next layer's own router. On gemma4 that
fallback was right less often on the phone (precision 0.55–0.61 against
0.68–0.75) and gained +12–15% tok/s against +17–20% for the fitted file
(`results/benchmark-results-2026-10-02-ios-next-layer-prefetch/`,
`results/benchmark-results-2026-10-03-ios-fitted-guess/`). supergemma4 has never been
measured with either.

## Label

Offline fit and score, Mac. **This run changes no runtime behaviour.** Shipping
the file would change supergemma4's default early-read guess. That is a
performance claim, and the phone A/B that scores it gets its own predictions
before it runs.

## Method

Unchanged from gemma4, so the two fits compare directly:

- **Traces:** `collect.sh`, the 2026-10-02 collection with the model as an
  argument. The early read is off, to match the conditions of the gemma4
  traces. Training uses the seven app prompts at `--max-new 400`. The held-out
  test is the three `real-generation-v1` cases, run to the end of the turn.
  Same seeds, same sampling, 16 live slots (the Mac default).
- **Fit:** `results/benchmark-results-2026-10-03-ios-fitted-guess/fit_guess.py`,
  unchanged. It fits a per-layer ridge correction (λ = 1) on the training
  traces, quantizes to the router's 8-bit format, and scores precision@1 on
  the held-out traces at 16 and 24 replayed slots, warmup 32.
- **Extra:** `cross_score.py` scores gemma4's shipped file on the supergemma4
  held-out traces. It also measures how far supergemma4's routers moved from
  gemma4's, using the exported router matrices of both models.

## Predictions

Held-out, 24 replayed slots unless marked. gemma4's values are in brackets.

| | Predicted | gemma4 (fit-output.txt) |
| --- | --- | --- |
| P1. Trace valid: replay hit rate vs live at 16 slots, from token 32 | within 0.5 pp | 0.0 pp |
| P2. naive (router) precision@1 | **0.54–0.64** | 0.588 |
| P3. fitted 8-bit precision@1 | **0.67–0.78** | 0.726 |
| P4. fitted − naive | **+0.09 to +0.17** | +0.138 |
| P5. 8-bit vs float fitted | within 0.005 | 0.000 |
| P6. 16 slots, fitted 8-bit | 0.80–0.89 | 0.848 |
| P7. File size | 11,106,368 B exactly (same shape) | same |
| P8. Live hit rate, test runs at 16 slots | 61–68% | 64.7% |

**P9, the open one:** how gemma4's file does on supergemma4. I lean towards
"between naive and supergemma4's own fit" (0.60–0.72), but I'm not confident.
supergemma4's bytes/token and hit rate on the Mac were within 2.5% and 0.9 pp
of gemma4's (`results/benchmark-results-2026-09-27-supergemma/`), so its routing
statistics barely moved. The file holds gemma4's `W + B`, though, and if the
fine-tune moved the routers much, it could score below naive. Either outcome
is informative. If it lands within 0.02 of supergemma4's own fit, one file
could serve both models, but a per-model file stays the safer choice.

## Mechanism

supergemma4 is a fine-tune of gemma4 with the same architecture and layout.
The ridge correction captures how the residual stream drifts between layer L's
router input and layer L+1's. That drift comes from the architecture and from
weights the fine-tune mostly kept, so supergemma4's own fit should lift
precision about as much as gemma4's did.

## What would falsify it

- **fitted − naive < +0.05** at 24 slots: the correction does not carry over.
  Don't ship the file; supergemma4 keeps the router guess.
- **Replay hit rate off by > 0.5 pp** (P1): the trace or the replay is wrong
  for this model, and nothing downstream counts.
- **Live hit rate outside 61–68%** (P8): this run's routing differs from the
  2026-09-27 supergemma4 runs. Look at that before trusting the fit.

## Decision rule

If P4 holds (fitted beats naive by ≥ 0.05), add the file to
`NextLayerGuess/index.json` on this branch, with a focused test, and leave the
branch unmerged until a phone A/B against the router guess scores it.
