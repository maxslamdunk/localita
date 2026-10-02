# Results: can layer L predict layer L+1's expert misses?

Scored against [`predictions.md`](predictions.md), committed first in
`d4082f1`. The trace code and scripts are in `e083e54`. Raw script output is in
[`score-output.txt`](score-output.txt) and
[`controls-output.txt`](controls-output.txt).

## Answer

**Yes, by a wide margin.** Layer L+1's own router, applied to layer L's
router input, picks a real layer-L+1 miss with its single best uncached guess
**59% of the time** at 24 replayed slots, on prompts it never saw. A per-layer
linear correction fitted on seven other prompts raises that to **73%**. The
threshold set in advance was 40%. Fed a different token's state, the same
predictor falls to 6–8%, so it reads the current token, not a general pattern.

This is an offline result about **predictability only**. It does not show that
prefetch makes the phone faster; that depends on timing, which this does not
measure (see [What this does not show](#what-this-does-not-show)).

## What was run

Ten traced CLI runs on the 8 GB M1, all at 16 live slots, sampling defaults:

- **Training:** the seven built-in app prompts, `--max-new 400`, 2,119 decode
  tokens in total. Six of the seven ended their turn before 400.
- **Held-out test:** the three `real-generation-v1` cases with their seeds, run
  to the end of the turn, 1,786 decode tokens.

The first 32 decode tokens of each run are replayed but not scored, because
the replayed cache starts empty while the live one starts with what prefill
left. This rule was added after the smoke run and before any real trace was
scored.

## Scoring

**P1, trace valid: held.**

- **Router export.** It reproduces the GPU's logged scores to a max abs error
  of 1.3e-5 to 1.9e-5 per run. The top-8 matches on 117,148 of 117,150
  records. The two misses are ties at the 8th place: the 8th and 9th scores
  differ by 7e-7 and 4e-6, so summation order decides.
- **Cache replay.** The 16-slot replay's hit rate is within 0.2 points of the
  live run's:
  - training: 63.7% vs. 63.9% from token 0; 63.9% vs. 63.9% from token 32;
  - test: 64.7% vs. 64.7%.
- **Extra control, not predicted.** The three test runs reproduce HEAD's
  2026-09-15 rows to the digit: 527 / 665 / 597 new tokens, 248.10 / 268.84 /
  294.93 MiB per token, and 67.7 / 65.0 / 61.6% hit rate. So the trace changed
  nothing about routing.

**P2, top-8 overlap: held.** naive-late **6.26** of 8 (predicted 5–7),
naive-early **5.51** (predicted 3–6).

**P3, precision@1 at 24 slots: falsified high on three of four.**

| predictor | predicted | measured |
| --- | --- | --- |
| popularity | < 0.10 | **0.030** |
| naive-early | 0.15–0.40 | **0.588** |
| fitted-early | 0.25–0.50 | **0.726** |
| naive-late | 0.30–0.60 | **0.711** |

The mechanism behind the ranges was wrong. I expected the misses to be a tail
that is hard to predict, because the cache already holds the predictable
experts. That holds for popularity, which is useless here, but not for the
hidden state. Which experts a token needs is mostly decided by the token
itself, and the cache's frequency ordering does not remove that.

**P4, fitting helps: held.** fitted-early beats naive-early by **+0.138**
(predicted ≥ +0.05).

**Decision threshold: passed.** The best early-input predictor is at 0.726
against the 0.40 threshold.

## Full table, held-out prompts

Precision@k is the share of prefetch reads that land on a real miss. Coverage@k
is the share of all misses that get prefetched.

| | top-8 overlap | 16 slots P@1 | P@2 | 24 slots P@1 | C@1 | P@2 | C@2 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| popularity | 1.24 | 0.041 | 0.040 | 0.030 | 0.016 | 0.027 | 0.029 |
| naive-early | 5.51 | 0.705 | 0.596 | 0.588 | 0.310 | 0.467 | 0.493 |
| fitted-early | 6.62 | 0.848 | 0.742 | 0.726 | 0.383 | 0.589 | 0.621 |
| naive-late | 6.26 | 0.830 | 0.720 | 0.711 | 0.375 | 0.572 | 0.603 |
| fitted-late | 7.03 | 0.893 | 0.795 | 0.776 | 0.409 | 0.638 | 0.673 |
| oracle | 8 | 0.940 | | 0.830 | | | |

The oracle's precision@1 is below 1 because 17% of transitions at 24 slots
have no miss at all. Any prefetch there is wasted. Measured against the
oracle, fitted-early gets **87%** of what is possible at k = 1.

There are 1.90 misses per layer transition at 24 replayed slots, against
2.78 at 16.

## Controls

**Wrong token.** naive-early precision@1 is 0.588 with this token's state,
**0.081** with the previous token's, and 0.065 with the state from eight
tokens back.

**Per prompt.** Precision@1 for naive-early / fitted-early at 24 slots:

| prompt | naive-early | fitted-early |
| --- | --- | --- |
| short | 0.545 | 0.680 |
| medium | 0.593 | 0.723 |
| long | 0.621 | 0.770 |

All three clear the threshold, and they rise with prompt length.

**Per layer.** Every transition is above 0.40 after fitting. The weakest is
9→10, at 0.495 fitted and 0.446 naive. The early layers are
weakest unfitted (2→3 at 0.281) and gain most from fitting (0→1: 0.382 →
0.752). Full list in `controls-output.txt`.

**Ridge strength.** It was chosen on two held-back training prompts and landed
at the top of the first grid (λ = 1). Extending the grid to 100 after the test
scores were seen still chooses λ = 1, so the held-out figure does not change.

## What this means in reads, on the phone's 24 slots

This is arithmetic from the table, not a measurement. At k = 1 with
fitted-early, each token issues 29 prefetch reads:

- **About 21 useful.** They replace reads the token would otherwise wait for.
- **About 8 wasted.**

Against about 57 misses per token, the reads a token waits for fall by about
**37%**. Total reads rise by about **14%**. **So bytes/token goes up, not
down.** The gain only exists if the extra reads fit in time storage would
otherwise spend idle. Under this project's rules, any prefetch design has to
state that trade up front.

## What this does not show

- **Whether the reads fit the idle time.** The early input is ready at the end
  of layer L's attention, but storage is then busy with layer L's own misses.
  On the phone the window per layer is around 1.7 ms against a ~2 ms read.
  Only the phone's `[gpu-time]` and `[read-latency]` lines can say how much of
  each read hides. The upper bound is 29 × 0.726 × ~2 ms ≈ 42 ms per token,
  of ~166 ms.
- **What wasted prefetches do to the cache.** The replay ignores prefetch's
  own effect on the cache. A prefetched expert that goes unused must not push
  out a useful one, which argues for a separate staging slot. That is the
  correctness rule [CACHE-06](../docs/experiments/summaries/03-expert-cache-prediction-and-layout.md#cache-06)
  broke.
- **The phone's own routing.** The phone generates slightly different text,
  but routing is a property of the model and the prompt, and the A19 matches
  the M1's kernel margins exactly. The 24-slot misses are replayed, not live.
  The live check at 16 slots agreed within 0.2 points.
- **More data.** Training is 2,119 tokens from seven prompts. The fitted gain
  is real on held-out prompts, but more varied training data could change it
  either way.

## Bounded memory

The router export holds one layer's dense matrix (1.4 MB) at a time, below one
expert slot (3.36 MB). The per-layer record is 11.8 KB. Both apply only when
the environment variable is set.
