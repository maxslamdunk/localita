# Predictions: does the fitted guess beat the router outside its training set?

Written before any run. The fitted next-layer guess (CACHE-10) was fitted on
seven English, mostly technical app prompts (2,119 tokens) and compared with
the router guess only on the three `real-generation-v1` prompts. This check
compares the two live, on prompts the fit never saw, including three languages
other than English, before the fitted guess is offered upstream.

## Setup

- **Build:** the upstream contribution branch with both changes
  (`early-expert-read-fitted` in `../turbo-fieldfare-upstream`, based on
  `upstream/main` `77e8f9c`), release CLI. The port's count aging and other
  port-only changes are not in it.
- **Mac:** M1 MacBook Air 8 GB, macOS 26.6.1, one model process, preflight
  before every run.
- **Settings:** upstream defaults (16 slots, LFU, prefill on, chunk 128),
  `--max-context 4096`, temperature 0.2, Top-K 64, Top-P 0.95.
- **Prompts:** six from `research-results-2026-10-03-cache-policy/prompts.py`,
  frozen in [`prompts/`](prompts/), with the seed and `--max-new` of their
  2026-10-03 trace rows in `MEASUREMENTS.md`:

  | prompt | language / kind | seed | max-new |
  | --- | --- | --- | --- |
  | `ru-history` | Russian | 20261012 | 600 |
  | `zh-explain` | Chinese | 20261015 | 500 |
  | `es-recipe` | Spanish | 20261014 | 500 |
  | `story` | English fiction | 20261018 | 800 |
  | `multi-turn` | English, multi-turn chat | 20261026 | 500 |
  | `sql-debug` | code | 20261005 | 500 |

- **Arms:** `--early-expert-read router` and `--early-expert-read fitted`, one
  run each per prompt, order alternating by prompt (R F, F R, …). The counters
  are exact given identical text, so one run per arm is enough; tok/s from
  these runs is not quoted.

## What moves

Precision = early reads used / early reads, from the `[early-read …]` line.

1. **English and code** (`story`, `multi-turn`, `sql-debug`): fitted − router
   **+0.08 to +0.18** each. On the held-out benchmark prompts at 16 slots it
   was +0.143 offline and +0.146 live (short case).
2. **Russian, Chinese, Spanish:** fitted − router **0.00 to +0.15** each. The
   fit saw only English, so part of the correction may not carry over; I
   expect a smaller gain, not a loss.
3. **Fitted precision, absolute:** within ±0.08 of the port's live figures on
   the same prompts and seeds (0.606 / 0.641 / 0.696 / 0.813 / 0.835 / 0.839
   for ru / zh / es / story / multi-turn / sql). Only roughly comparable: the
   port build differs (count aging and other port changes alter which experts
   miss).

## Controls (should not move between arms)

- Generated text: byte-identical, by SHA-256 of stdout, per prompt.
- `needed/tok`: identical per prompt.
- `reads/tok`: 29.00 in both arms (one read per layer transition).

## Mechanism

The fit is a ridge correction to each next-layer router, applied to the
current layer's router input. If it learned how the hidden state changes
between layers in general, it carries to any text; if it learned the training
prompts' vocabulary, it helps less, or hurts, on other languages. Ridge
shrinks the correction toward the plain router, so a large loss is unlikely.

## What would falsify it

- **Fitted ≤ router on any prompt:** the fit does not generalize there. On a
  non-English prompt that is a reason to state the limit in PR 2 or refit on
  broader data, and to tell the user before opening it.
- **Different text or `needed/tok` between arms:** the guess changed something
  other than which reads are early. That is a bug, and stops the PR.
