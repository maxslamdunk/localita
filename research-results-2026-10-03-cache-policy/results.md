# Cache policy in simulation: results

Scored against `predictions.md` (committed in `8cf10ac`, before any new policy
was scored). Offline replay only: nothing here ran on the phone, and nothing
in the runtime changed.

## Summary

- **The simulator reproduces the hardware's cache behavior almost exactly.** On
  all 26 new traces, replayed LFU at 16 slots lands within 0.33 hit-rate points
  of the live Mac footer (mean −0.09) and within 0.07 of its early reads used
  per token (`replay-check-16.txt`). Against the iPhone at 24 slots it is within
  2% on hit rate, early-read precision and bytes/token (`predictions.md`). A
  policy scores in seconds.
- **The biggest finding is not a better policy but a flaw in the current one
  that the benchmark cannot see.** The app keeps one model, and so one set of
  LFU counts, across every turn and every conversation until the model is
  unloaded. The counts never decay or reset. Replayed as one session of 11
  prompts back to back, **LFU's hit rate falls to 66.8–67.1%, against 74.7%
  with the counts reset per conversation and 75.2–75.3% with decayed counts.
  Foreground reads per token: 55.4–55.9 against 39.0–39.8,** about 40% more
  reads the token waits for. Every benchmark run starts a fresh process, so the
  benchmark never sees this.
- **On a single prompt, a learned eviction policy helps less.** On the held-out
  `real-generation-v1` traces, the learned policy beats LFU by +1.3 hit-rate
  points (+1.1 / +1.5 / +1.3) and cuts foreground reads by 2.3 per token
  (−6.4%). Decayed LFU gains +0.5 points. Belady's offline optimum is
  8.4 points above LFU, so history and the current router scores recover about
  a sixth of the gap; the rest needs knowledge of the future that these features
  don't carry.

## Data

- **Train:** 18 prompts, 8,649 decode tokens. **Val:** 8 prompts, 4,292
  tokens. **Test:** the three `real-generation-v1` traces, 1,822 tokens (1,726
  scored). From `prompts.py` and `collect.py`: code, math, six languages,
  creative, structured, long-input and multi-turn prompts. 26 rows in
  `MEASUREMENTS.md`, marked as traces, not benchmarks.
- The compacted traces live in `scratch/cache-traces/` (gitignored, 7–9 MB
  each): the top-8 experts, the router's scores over all experts, and the
  fitted early-read guess's scores, per token and layer.

## Validation (24 slots, early read on; `fit-output.txt`)

| policy | hit | fg/token | reads/token | early precision |
| --- | --- | --- | --- | --- |
| LFU (runtime) | 74.3% | 40.7 | 69.7 | 0.719 |
| LRU | 72.1% | 46.3 | 75.3 | 0.712 |
| ARC | 72.9% | 44.6 | 73.6 | 0.709 |
| decayed LFU, 0.97 per token (best of 0.9–0.999) | 75.6% | 38.6 | 67.6 | 0.691 |
| learned, linear, regression or pairwise ranking | 76.3% | 37.0–37.1 | 66.0–66.1 | 0.683 |
| learned, quadratic features | 76.4% | 36.8–36.9 | 65.8–65.9 | 0.682 |
| Belady | 84.1% | 23.4 | 52.4 | 0.509 |

The ridge strength made no difference (0.01 to 100 within 0.1 `fg`). The
quadratic model gained 0.1 point, so the linear pairwise-ranking model was
chosen for simplicity before test was scored.

## Test, scored once (`test-output.txt`)

| policy | short | medium | long | pooled hit | pooled fg | pooled reads (MiB) | precision |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LFU | 79.2% | 76.3% | 73.7% | 76.2% | 36.2 | 65.2 (208.8) | 0.719 |
| LRU | 75.8% | 73.5% | 70.5% | 73.1% | 43.4 | 72.4 (232.0) | 0.726 |
| ARC | 76.8% | 74.1% | 71.2% | 73.9% | 41.8 | 70.8 (226.8) | 0.722 |
| decayed LFU 0.97 | 79.9% | 76.9% | 73.9% | 76.7% | 35.5 | 64.5 (206.7) | 0.702 |
| **learned** | **80.3%** | **77.8%** | **75.0%** | **77.5%** | **33.9** | **62.9 (201.6)** | 0.689 |
| Belady | 86.7% | 84.8% | 82.7% | 84.6% | 22.0 | 51.0 (163.5) | 0.516 |

What the learned model uses (standardized weights, positive = evict sooner):
recent frequency at three decay rates (−0.10 to −0.18) and lifetime share
(−0.13) keep an expert; age since last use (+0.13) evicts it. **The current
token's router score also counts:** an expert ranked high this token but not
chosen is kept (score −0.06, log rank +0.11), the one signal neither LFU nor
decay can see.

## The long session (`session-output.txt`)

Validation and test prompts replayed back to back, two orders, 24 slots,
6,114 tokens:

| policy | hit, whole session | fg/token | hit, first 64 tokens of each later prompt | fg/token there |
| --- | --- | --- | --- | --- |
| LFU, counts never reset (runtime) | 66.8–67.1% | 55.4–55.9 | 63.1% | 64.2–64.3 |
| LFU, counts reset per prompt | 74.7% | 39.8 | 73.2% | 43.4–43.5 |
| decayed LFU 0.97 | 75.2–75.3% | 39.0–39.1 | 69.1–69.4% | 51.2–51.8 |
| learned | 76.1% | 37.3 | 71.5–71.7% | 46.5–47.0 |
| Belady | 84.1% | 23.3 | 83.1–83.3% | 25.1–25.4 |

The learned model was trained on single prompts and was not refitted for this.
Resetting the counts at a prompt boundary recovers fastest after a change of
topic. Decay and the learned model also adapt when the topic drifts within a
conversation, which a reset cannot see.

Caveats:
- The replay has no prefill between prompts. The runtime's prefill also
  increments LFU counts, by the new prompt's experts, which may soften the
  staleness for long prompts.
- Prompts in one conversation are more alike than these 11, so the effect
  within a single chat should be smaller.

### Scoring

| # | prediction | result | verdict |
| --- | --- | --- | --- |
| 1 | LRU about −3 points; ARC within ±1.5 of LFU | LRU −3.1; **ARC −2.3** | LRU held; **ARC missed**, worse than predicted |
| 2 | decayed LFU 0 to +1.5 points, `fg` 0 to −1.5 | +0.5, −0.7 | held |
| 3 | learned +2 to +4 points, `fg` −2 to −4 (−5 to −11%), precision −0.01 to −0.05 | **+1.3 points**, `fg` −2.3 (−6.4%), precision −0.030 | **hit rate missed** (val gave +2.0); `fg` and precision held |
| 4 | session: LFU 1–3 points behind decay | **8.1–8.5 points behind** | **missed by a factor of three**: staleness is far worse than predicted |
| 5 | controls: Belady the ceiling, LFU replay unchanged | yes | held |

Falsifiers: the learned gain is above the +1-point floor and holds on all three
test prompts, so the idea survives. It did shrink from val to test (+2.0 →
+1.3), a mild version of the CACHE-04 / CACHE-08 overfitting.

## What it is worth, as arithmetic

As in `predictions.md`, each foreground read is about 1.5–2.2 ms of serial
storage, and a token took 151 / 174 / 195 ms in the fitted-guess runs:

- **Single prompt, learned against LFU:** −2.3 `fg`, about 3.5–5 ms per token,
  **+2–3% tok/s**. Decayed LFU: about +1%.
- **Long session, decay or a per-conversation reset against today's LFU:**
  −16 to −17 `fg`, about 24–37 ms per token. Today's LFU in such a session is
  itself slower than the benchmark figures, so this is roughly **+15–25% tok/s
  in sustained use**, recovering speed the app is losing now rather than adding
  new speed. That size is arithmetic, not a measurement.

## Recommendation

1. **Fix the staleness first.** Reset the counts on a new conversation, and
   decay them (0.97 per token per layer) to follow drift within a
   conversation. Either is a few lines in `PreadExpertStreamer`, with no file
   format change and no memory cost. The benchmark protocol cannot measure it:
   the phone A/B needs a session protocol, several `real-generation-v1` prompts
   in one process. That needs a harness option and its own predictions.
2. **The learned policy is a later, smaller step:** +2–3% on a single prompt.
   It is cheap at runtime: 12 features and a dot product per eviction
   candidate, plus reading the router's 128 scores, which are already on the
   GPU. Worth doing after (1), with more training traces.
3. **The remaining 7 points to Belady need knowledge of the future.** Routing
   for tokens ahead is barely predictable from the current state: the
   wrong-token control in the next-layer study was 0.08. So a bigger learned
   model is unlikely to close much more of the gap. That ceiling is real but
   probably out of reach.
