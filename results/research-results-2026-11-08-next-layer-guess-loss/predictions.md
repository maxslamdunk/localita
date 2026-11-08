# Predictions: more data, and a different loss, for the next-layer guess

Written 2026-11-08, after the anchors below and before any training or
validation trace was scored. Offline only: no runtime change, no phone run.

## Question

The shipped early-read guess (CACHE-10) scores layer L+1's experts as
`x_L (W_{L+1} + B)^T`, with `B` a ridge fit (squared error on L+1's router
scores, λ = 1) on 2,119 decode tokens from 7 prompts. Two questions:

1. **Data.** Was 2,119 tokens enough, or does precision still rise with more?
2. **Loss.** Squared error weighs all 128 scores equally; the guess only uses
   the top one not yet cached. Does cross-entropy, which weighs the top of the
   distribution, pick better? PROBE (arXiv 2602.00509) uses cross-entropy
   against the router's softmax, but never compares losses or a linear
   correction.

## What is run

- **Data:** [`collect.py`](collect.py) traces the cache-policy study's 26
  prompts (18 train, 8 val, chosen to differ: code, math, six languages,
  creative, structured, long input, multi-turn) on the M1 at `5f21f6a`, with
  that study's seeds and sampling. Test is the three `real-generation-v1`
  traces taken 2026-10-03 (1,822 decode tokens), never used for fitting or
  choosing.
- **Scoring:** [`fit.py`](fit.py), precision@1 at 24 replayed LFU slots, as in
  `research-results-2026-10-02-next-layer-prediction`. λ is chosen on val.
- **Experiment 1:** ridge at λ = 1 on nested random subsets of 1, 2, 4, 6, 9,
  12 and 18 training prompts, three orders, scored on val.
- **Experiment 2:** on all 18 training prompts, ridge against cross-entropy
  with the same correction and penalty, two targets: the router's softmax
  (`ce-soft`, PROBE's) and the uniform distribution over the router's top-8
  (`ce-top8`). The correction stays linear, so either would ship in the
  existing guess-file format and kernel.

## Anchors, measured before writing this

On the test traces: naive (B = 0) **0.5804**, shipped **0.7189**. The shipped
figure on the 2026-10-02 test traces was 0.726, so these traces agree.

## Size estimate

From the fitted-vs-unfitted phone A/B (`…-10-03-ios-fitted-guess/`): +0.134 to
+0.146 precision gave `io` −6.8 to −14.9 ms per forward, about **0.5–1.1 ms
of `io` per +0.01 precision**, and +4.2 to +5.2% tok/s on short and medium.
So +0.02 precision is worth about 1–2 ms per token, roughly +0.5 to +1%
tok/s: below the phone's ~8% run-to-run noise, readable only through the live
precision counter and `io`. The ceiling for this whole line (precision 1.0,
+0.28) is roughly 14–31 ms per token.

## Predictions

**P1, data (experiment 1).** Mean val precision rises by **+0.04 to +0.10**
from 1 to 18 prompts, and by **≤ +0.02** from 9 to 18: flattening, but not
flat.

**P2, data against the shipped fit.** Ridge on all 18 prompts beats the
shipped guess by **+0.01 to +0.04 on val** (val is drawn like the new training
set) and by **−0.01 to +0.02 on test** (test is English technical writing,
like the shipped fit's 7 prompts).

**P3, loss (experiment 2).** On the same 18 prompts, `ce-soft` beats ridge by
**+0.005 to +0.03** on val and on test. `ce-top8` is within **±0.01** of
`ce-soft`.

**Mechanism.** More data: 2,119 tokens against 2,816 inputs per layer needed
the strongest penalty in the grid, so the shipped fit is held close to the
router; four times the data allows a larger correction. Loss: squared error
spends the fit on scores far below the top 8, which never decide a guess.

**What would falsify them.**
- P1: the curve is flat from 2 prompts on (≤ +0.01 from 2 to 18), or still
  rising by more than +0.02 from 9 to 18.
- P2: ridge on 18 prompts is below shipped on val.
- P3: `ce-soft` is at or below ridge on val (the loss does not matter), or
  above it by more than +0.05 (squared error was far more wasteful than
  thought).

## Decision rule

- **If the best variant beats shipped by ≥ +0.02 on test:** regenerate the
  guess file from it and check it on the phone (live precision and `io`, not
  tok/s), as a separate prediction.
- **Otherwise:** keep the shipped guess and record the result in CACHE-10.
- **Experiment 3 (a nonlinear correction):** worth more data and a new kernel
  only if P1's curve is still rising at 18 prompts or P3 shows the loss
  matters (≥ +0.01).
