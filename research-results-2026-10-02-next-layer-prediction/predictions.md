# Predictions: can layer L predict layer L+1's expert misses?

Written 2026-10-02, before any code, on branch
`research-next-layer-expert-prediction` from `f6345d1`.

## The question

Prefetch would read some of layer L+1's experts before its router has run,
during time when storage is otherwise idle. That only pays if the guess is
right often enough. This measures how often, offline, before any prefetch code
exists. The lesson of [CACHE-05](../docs/experiments/summaries/03-expert-cache-prediction-and-layout.md#cache-05)
is to measure predictability first.

CACHE-05 predicted layer L+1's experts from layer L's **expert IDs** and found
almost no overlap (mean Jaccard 0.039). This uses layer L's **hidden state**,
run through layer L+1's own router weights. Eight IDs are a lossy summary of
that state, so CACHE-05 does not settle this question.

## Label

Measurement only. **Zero bytes/token change**, and production behaviour is
unchanged: the trace is written only when an environment variable is set. The
ground is a named phase, `io`. If a predictor passes, it opens a prefetch design
whose own predictions come later.

## What gets logged

The CLI runs on the Mac with `TURBO_FIELDFARE_ROUTING_TRACE=<dir>` set. For
every decode token and every layer it logs:

- the router input (the normalized hidden state after attention);
- the layer's output, which is the next layer's input;
- the 128 router scores;
- the real top-8;
- which of those eight missed the live 16-slot cache.

At startup it also writes each layer's router as a dense matrix. It does this
by running the production router kernel on unit vectors, so the matrix is
exactly what the GPU applies. With those, all predictors can be scored offline.

Data:

- **Training:** the seven built-in app prompts, `--max-new 400` each.
- **Test, held out by prompt:** the three `real-generation-v1` cases, run to
  the end of the turn.

Sampling uses the defaults and a fixed seed.

## How a predictor is scored

For each transition from layer L to layer L+1 (L = 0…28) in a decode token:

- R is layer L+1's real top-8;
- C is layer L+1's cache contents just before its plan;
- M = R minus C is the misses.

A predictor scores all 128 experts using only what exists when layer L's router
has run. **Prefetch at budget k** reads the k highest-scoring experts that are
not in C.

- **Precision@k:** the share of prefetched experts that are in M. A prefetch on
  a layer with no misses counts as wasted.
- **Coverage@k:** prefetched experts in M divided by all misses.

**k = 1 is the operating point.** On the phone, storage is idle about 1.7 ms
per layer (`cb1-wait` ~50 ms per token across 30 layers), and one expert read
takes about 2 ms, so about one read fits. k = 2 is reported for the Mac.

The 24-slot misses, the phone's default, come from replaying an LFU cache over
the logged top-8 sequence. Live misses are only available at the Mac's 16
slots.

## Predictors

| Name | Input from layer L | Method |
| --- | --- | --- |
| naive-early | router input | layer L+1's router applied as-is |
| naive-late | layer output, RMS-normalized | layer L+1's router applied as-is |
| fitted-early | router input | L+1's router plus a learned correction (ridge regression on the scores, fitted on training prompts only) |
| fitted-late | layer output | same |
| popularity | none | each expert's frequency at L+1 in the training data |
| oracle | n/a | always picks a real miss when one exists |

The obvious "same experts as the previous token" baseline is dropped as
degenerate: every expert a token uses is loaded into the cache, so it is
almost never a miss.

**Only the early input can save much time.** It is ready at the end of layer
L's attention, so a prefetch can overlap layer L's expert compute and layer
L+1's attention. The late input is ready only after layer L finishes, which
leaves just layer L+1's attention, about 1.5 ms on the Mac. That is less than
one read.

## Decision threshold

**Go on to a prefetch design if the best early-input predictor reaches
precision@1 ≥ 0.40 on the held-out prompts, at 24 replayed slots.**

Why 0.40: each useful prefetch takes about one ~2 ms read off the critical
path. 29 transitions × 0.40 × ~2 ms ≈ 23 ms per token. Against the phone's
~166 ms per token at 24 slots (6.03 tok/s, short case, 2026-09-16), that is
about +14% tok/s, and that is an upper bound. Below 0.40 the gain falls under
~10%, which the phone's ~8% run-to-run spread could not tell from noise.

## Predictions

**P1. The trace is valid.**

- The exported router matrix times the logged router input reproduces the
  logged scores (max abs error < 1e-2), and its top-8 equals the logged top-8
  on ≥ 99.9% of records.
- Replaying LFU at 16 slots gives a decode hit rate within 2 percentage points
  of the live run's.

*Falsified by* either failing. That would be a bug in the trace or the replay,
not a finding, and nothing below may be scored until it is fixed.

**P2. Overlap with the real top-8** (mean out of 8, held out):

- naive-late: **5–7**;
- naive-early: **3–6**.

Low confidence. Published work on other MoE models reports high accuracy for
next-layer router prediction from hidden states. This model's 128-way top-8
routing may be harder.

*Falsified by* either mean falling outside its range.

**P3. Precision@1 at 24 replayed slots, held out:**

| predictor | predicted |
| --- | --- |
| popularity | < 0.10 |
| naive-early | 0.15–0.40 |
| fitted-early | 0.25–0.50 |
| naive-late | 0.30–0.60 |

Mechanism: the cache already holds the frequent and recently used experts, so
the misses are the hard-to-predict tail. Precision on misses should therefore
sit well below top-8 overlap.

*Falsified by* any value outside its range.

**P4. Fitting helps.** fitted-early beats naive-early by ≥ 0.05 precision@1 on
the held-out prompts.

*Falsified by* a smaller gain, or fitted-early losing.

## Cost of the run

About 355 KB of trace per decode token. About 2,800 training plus about 1,800
test tokens comes to roughly 1.6 GB, against 13 GiB free on the volume. Waiting
on each layer to capture its output slows the run, but changes no numbers.
