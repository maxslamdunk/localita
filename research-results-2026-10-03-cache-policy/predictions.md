# Cache policy in simulation: predictions

Written 2026-10-03, before any policy other than LFU and Belady was scored on
the held-out traces and before the training traces existed. This is an offline
study: it decides whether a policy earns a runtime implementation and a phone
A/B, which would get its own predictions.

## Setup

- **Simulator** (`sim/`): replays decode routing traces through a per-layer
  cache policy at 24 slots, plus the early read exactly as
  `NextLayerExpertPrefetcher` does it (best guess score among experts the next
  layer does not hold, fitted guess `gemma-4-26b-a4b-it-4bit.bin`). The first
  32 decode tokens are replayed but not scored.
- **Metric that decides:** `fg`, foreground reads per token, the misses not
  covered by an early read. Storage is serial, so each one is on the critical
  path. Hit rate, total reads (bytes/token) and early-read precision are
  reported beside it.
- **Data:** the three `real-generation-v1` traces (`test-`, held out, Mac CLI,
  2026-10-03 08:00) and 26 new prompts from `prompts.py` (`train-`, `val-`),
  collected by `collect.py`. Parameters (decay rates, the learned model) are
  chosen on train and val only, and test is scored once per final candidate.

## Simulator check, done before these predictions

LFU at 24 slots replayed on the test traces against the iPhone 17's live runs
with the fitted guess (`benchmark-results-2026-10-03-ios-fitted-guess/`, F arm,
and the CLAUDE.md decode table):

| | short | medium | long |
| --- | --- | --- | --- |
| hit rate, replay / phone | 79.2 / 79.1% | 76.3 / 75.7% | 73.7 / 73.4% |
| early-read precision, replay / phone | 0.683 / 0.684 | 0.715 / 0.728 | 0.752 / 0.752 |
| bytes/token, replay MiB / phone footer MB | 189.0 / 190.09 | 208.7 / 212.33 | 224.9 / 227.62 |

So the replay reproduces the phone's cache behavior to within 2%, without
fitting anything. It does not model timing.

Baselines on test, pooled (1,726 scored tokens):

| policy | hit | misses/token | fg/token | reads/token | early precision |
| --- | --- | --- | --- | --- | --- |
| LFU (runtime) | 76.2% | 57.0 | 36.2 | 65.2 | 0.719 |
| Belady (oracle) | 84.6% | 37.0 | 22.0 | 51.0 | 0.516 |

The oracle cuts foreground reads by 39%, less than its 35% cut in misses would
suggest without the early read: a better cache leaves fewer misses for the
early read to catch, so precision drops from 0.72 to 0.52.

## Predictions (test, pooled, 24 slots, early read on)

1. **LRU and ARC** do not beat LFU: LRU loses about 3 hit-rate points as in the
   earlier replay; ARC lands within ±1.5 points of LFU.
2. **Decayed LFU**, rate chosen on train+val: 0 to +1.5 hit-rate points over
   LFU on test, `fg` −0 to −1.5 per token.
3. **Learned eviction** (ridge regression on access-history features, labels
   from Belady's next-use distance, trained on train, tuned on val):
   **+2 to +4 hit-rate points, `fg` −2 to −4 per token (−5 to −11%)** on test.
   Its early-read precision falls by 0.01–0.05 from LFU's 0.719.
4. **A long app session** (traces replayed back to back without a reset, as
   the app keeps one process and never resets LFU counts): monotonic LFU falls
   1–3 points behind the best decayed LFU, because old counts outvote the
   current topic.
5. **Controls:** the oracle stays the ceiling (no policy beats Belady's hit
   rate); LFU replay figures stay as in the check above.

## What a hit-rate gain is worth, as arithmetic

Each foreground read is about 1.5–2.2 ms of serial storage (2.1–2.2 ms before
`F_NOCACHE`, which took 0.50–0.67 ms off each read). The fitted-guess runs
took 151 / 174 / 195 ms per token (6.626 / 5.744 / 5.123 tok/s). So −3 `fg`
per token is about −5 to −7 ms, **+3 to +4% tok/s**; the oracle's −14 is
about +12 to +20%. A phone A/B decides; the conversion ignores GPU overlap.

## What would falsify it

- The learned policy gains under +1 point on test: frequency and recency
  already hold what the history says, and the remaining gap needs the future.
  Drop the learned idea.
- It gains on val but not on test: the CACHE-04 / CACHE-08 overfitting again.
- Decayed LFU gains more than the learned policy: the model learned little
  beyond forgetting.
