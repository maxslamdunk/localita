# Predictions: expert-cache count aging, as an app session on the iPhone

Written before any phone run of this change.

## The change

`PreadExpertStreamer` keeps LFU use counts per layer. Today they only grow for
as long as the model stays loaded, and the app keeps one model across every
conversation. With aging (`TURBO_FIELDFARE_EXPERT_CACHE_AGING=1`):

- each cache plan multiplies every count by 0.97 before adding 1 for the
  planned experts (one plan per token per layer in decode);
- `RealForwardRunner.reset()`, which runs whenever the KV starts over (a new
  or restored conversation, a one-shot prompt), zeroes the counts. The
  resident experts stay.

It changes which experts stay resident, never the arithmetic.

## The protocol

The benchmark starts a fresh process per prompt, so it cannot show state that
outlives a chat. The harness's new `--session` mode runs prompts back to back
on one loaded model, each from an empty KV, as the app runs one chat after
another.

- **Session:** 11 prompts in the order `session.py` replays with seed 0: the
  8 validation prompts of `research-results-2026-10-03-cache-policy/` (copied
  to `prompts/`) and the three `real-generation-v1` prompts.
  `val-logic-grid, val-rust-borrow, val-sql-debug, val-es-recipe,
  val-compare-table, val-fr-translate, val-multi-turn, short-explanation,
  medium-review, long-synthesis, val-dialogue`.
- `--slots 24 --max-new 512 --max-context 4096`, chunk `auto`, Release, other
  defaults (early read with the fitted guess, `F_NOCACHE`). 512 rather than
  1024 new tokens per prompt keeps a session near 25 minutes.
- One binary. A = `--no-expert-cache-aging` (today), B =
  `--expert-cache-aging`. A B B A, 300 s cooldowns (`run.sh`).
- Whole-session figures weight each case by its decode tokens; tok/s is total
  new tokens over total decode seconds (`summarize.py`).

## The replay that sizes it

`research-results-2026-10-03-cache-policy/sim/reset_decay.py`, the same order
with each prompt cut at 512 tokens, 24 slots (`reset-decay-output.txt`). These
are Mac traces, so the phone's own tokens will differ:

| | hit rate | foreground reads/token | reads/token (MiB) | early precision |
| --- | --- | --- | --- | --- |
| A, counts never reset | 66.5% | 56.7 | 85.7 (274.6) | 0.819 |
| B, decay 0.97 + reset | 75.7% | 38.3 | 67.3 (215.4) | 0.694 |

Per chat, B is ahead in all 11. The first chat gains only 0.7 points: it has
no earlier chat to be stale about, so it is the single-prompt case.

Decay alone gives 75.2% and the reset alone 74.6%. Both together are best,
which is why both are in the change. At 16 slots the same session goes
57.6% → 65.0%, so the change is not for the iPhone only.

## Predictions, B against A

1. **Decode hit rate, whole session: +6 to +11 points.** A at 63–69%, B at
   73–78%.
2. **bytes/token: −45 to −65 MiB** (the footer's "MB"). A at 255–290, B at
   205–235.
3. **Early reads used per token: −2 to −5.** Fewer misses leave fewer for the
   early read to cover, so its precision falls, as in the replay
   (0.82 → 0.69).
4. **`io` per forward: −25 to −45 ms.** About 18 fewer foreground reads per
   token, at 1.4–2.4 ms of `io` each.
5. **Decode tok/s, whole session: +12 to +30%.** A at about 190–220 ms per
   token, B at 160–180. That holds only where the output head's `[gpu-time]`
   matches between runs. GPU speed alone has moved whole runs by up to 40%.
6. **The first chat, `val-logic-grid`: hit rate −0.5 to +2 points.** Its
   tok/s difference stays within noise.
7. **Chats 2–11: B's hit rate above A's in every one**, by 3–15 points.

### Controls, which should not move

- **Generated text:** each case's text byte-identical across all four runs
  (SHA-256). The sampler seed is fixed, and residency does not touch the
  arithmetic.
- **Prefill bytes per case:** within ±3%. Prefill streams tiles at about a
  0% hit rate whatever is resident.
- **New tokens per case:** identical, since they follow from the text.
- **`cb1-wait` and the head's GPU time:** no systematic change, and read as
  the GPU-speed control.

## Mechanism

Under today's LFU, an expert used heavily in an earlier chat keeps a large
count. When the next chat routes elsewhere, those experts hold their slots and
the new chat's frequent experts evict one another. Decay makes old use fade:
a use 100 tokens ago weighs 0.97^100, about 0.05 of one now. The reset drops
the previous chat's counts at once. More hits mean fewer foreground reads, and
those are about 60% of each token's wall time on this phone.

## What would falsify it

- The B−A whole-session hit rate below +4 points. The replay would then
  overstate the staleness on the phone. Prefill between chats is the
  suspect, since the replay does not model it.
- tok/s below +5% at matched head GPU time, while the hit rate moves as
  predicted. Hits would then not be turning into time.
- Any case's text differing between runs. Residency would then affect the
  output, which it must not.
- B's hit rate below A's in the first chat by more than 1 point. Aging would
  then cost something on the single-prompt workload the benchmark measures.
