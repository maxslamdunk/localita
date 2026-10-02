# Predictions: reading one of the next layer's experts early, unfitted guess

Written 2026-10-02, before any code. Step 1 of 2: the guess is layer L+1's own
router applied to layer L's router input, with no fitted correction. Step 2
(the fitted correction) happens only if step 1 passes the decision rule at the
end.

## Why, and what is different from the attempts that failed

- [`research-results-2026-10-02-next-layer-prediction`](../research-results-2026-10-02-next-layer-prediction/results.md):
  this guess picks a real layer-L+1 miss with its best uncached choice **59%**
  of the time at 24 replayed slots, on held-out prompts (short / medium / long
  0.545 / 0.593 / 0.621). The wrong-token control falls to 6–8%.
- [`benchmark-results-2026-10-02-ios-gpu-time`](../benchmark-results-2026-10-02-ios-gpu-time/results.md):
  on the phone, storage is idle **1.88 / 2.26 / 2.47 ms** per layer between one
  layer's reads and the next, against **2.23 / 2.23 / 2.13 ms** of storage time
  per read. One extra read per layer roughly fits; two do not.

Earlier attempts, and how this design answers each:

- **CACHE-05** predicted from the previous layer's expert IDs (Jaccard 0.039,
  7% hit). This predicts from the hidden state, which the study above measured
  at 59%.
- **CACHE-06** let background reads compete with the reads a token waits for,
  and reused the cache's own slots, which changed output. Here the early read
  starts only after layer L's own reads finish, one at a time, into a buffer
  outside the cache. A wrong guess changes nothing in the cache.
- **IO-08** relied on the OS file cache, and emitted IDs diverged. On the phone
  the file cache serves about 1% of reads. Here the bytes go straight into app
  memory, and identical text is a gate (P1).

## Design

Off by default, enabled by a runtime option on the CLI and the iOS harness.
Decode only; prefill is untouched.

1. **The guess, on the GPU.** At the end of layer L's attention + router
   command buffer (cb1), for L = 0..28, encode one more `router_gemv_gemma4_r4`
   with layer L+1's router weights and effective scale over layer L's
   `routerInput`, writing 128 scores into a new buffer. This is the existing
   kernel with different buffers. No `.metal` change, and the dispatch shape is
   unchanged. It needs a small wrapper in `MoE.swift` that encodes the GEMV
   without the top-k.
2. **The choice, on the CPU.** After cb1(L) completes, take the highest-scoring
   expert that layer L+1's cache does not hold. That cache cannot change before
   layer L+1's own plan, so the choice stays valid until it is used.
3. **The read.** When layer L's own reads finish, issue one `pread` of that
   expert into a staging buffer on a dedicated serial queue. The CPU goes on to
   encode cb2(L) and cb1(L+1) without waiting.
4. **Using it.** At layer L+1's plan:
   - **Guess was a miss:** swap the staging buffer into the slot the plan
     assigned to that expert, and skip reading it. The slot's old buffer becomes
     the next staging buffer. The swap happens before the plan's buffers are
     bound, so every command buffer sees the new one. Layer L+1's `io` waits for
     the early read along with its own reads.
   - **Guess was not used:** nothing changes, and the staging buffer is reused.
     Before the next early read is issued, the code waits for the previous one,
     which by then has long finished.

   The cache decides exactly what it decides today: same plan, same LFU counts,
   same evictions. An early read only changes where one miss's bytes come from,
   so hit rate is unchanged by construction, and the expert's GPU work stays in
   cb2 as before.
5. **Ownership.** Each slot buffer frees its own memory, so a buffer can move
   between layers safely. The buffer leaving a slot was last used by an earlier
   token's routed work for that layer, which has completed by the time that
   layer is planned again. That is the same guarantee today's eviction relies
   on when it reads into a victim slot.
6. **Counters.** Early reads go through the same `readFull` path, so bytes/token
   and reads/token include them honestly. Two new totals, early reads issued and
   early reads used, are appended to the end of the `[expert-io …]` line only
   when the option is on, so existing parsers are unaffected.

Memory: one staging buffer, **+3.36 MB**, plus 512 B of scores.

## Label

**bytes/token goes up.** The study's precision means about 29 × 0.41 ≈ 12
wasted reads per token. Justified on the `io` phase of the `[phase-time …]`
split, with a predicted ms/forward saving and a falsifier below.

## Runs

Same binary, option off (A) and on (B), on the iPhone 17. Each
`real-generation-v1` case runs A B B A: 12 runs, 24 slots,
`--max-new 1024 --max-context 4096`, prefill chunk `auto`. A cooldown between
runs, thermal state recorded. Expected duration about 1.5 hours.

Before the phone: one Mac CLI run per arm on the short case, to check
identical text and the counters. Plus unit tests for the swap and for an
unused guess.

## Predictions

Baseline figures are main `f6345d1` on the phone. The A arm of this run
replaces them for scoring.

**P1. Identical work.** On every case, B's generated text is byte-identical to
A's. Hit rate and requests/token are identical to the digit.

*Falsified by* any difference. That would be a correctness bug, and it stops
the run.

**P2. Live precision.** Early reads used ÷ issued is **0.50–0.65** on every
case. That is the Mac study's 0.55–0.62 per prompt, widened because the phone
routes its own text.

*Falsified by* any case outside that range.

**P3. bytes/token rises by the wasted reads.** Total reads per token go up by
29 × (1 − precision):

| case | reads/tok, A → B | bytes/tok (footer MB), A → B |
| --- | --- | --- |
| short | 50.2 → 63.4 (+26%) | 160.7 → 203.0 |
| medium | 58.4 → 70.2 (+20%) | 187.1 → 224.9 |
| long | 63.9 → 74.9 (+17%) | 204.6 → 239.8 |

These are point values at the study's precision. The test is the identity:
reads added = issued − used, to within 0.5 reads/token.

*Falsified by* a break in that identity.

**P4. `io` falls.** Ceiling arithmetic:

- each used early read saves min(read, idle window) of storage time;
- each wasted one costs whatever it runs past the window.

That gives **−26 / −38 / −38 ms per forward**. Predicted, allowing for the
thread hop, the phone's own precision and reads that do not fully hide:

| case | A `io` (f6345d1) | predicted change in `io` |
| --- | --- | --- |
| short | 111.89 | **−12 to −26 ms** |
| medium | 129.94 | **−18 to −38 ms** |
| long | 135.94 | **−18 to −38 ms** |

The mechanism check is the `io` saving divided by early reads used per token.
The prediction is **1.0–2.2 ms per used read**.

*Falsified by* any case outside its range, or below 1.0 ms per used read. The
latter would mean the early reads do not hide in idle storage time, which is
CACHE-06's failure.

**P5. The extra GEMV is cheap.** `cb1-wait` rises by **0 to +2 ms per forward**:
29 GEMVs over 0.36 MB of weights each.

*Falsified by* a rise above 3 ms.

**P6. tok/s.** B against A in the same session:

- short **+6 to +16%**;
- medium **+8 to +21%**;
- long **+8 to +20%**.

The ceiling is +15.6 / +21.1 / +19.7%.

*Falsified by* any case outside its range. A thermal note goes with any run
that reached `serious`.

## Decision rule for step 2

- **Proceed to the fitted correction** if P1 holds and medium and long each
  gain at least +5% tok/s.
- **Stop and look at the timing first** if P1 holds but P4's per-read check
  is below 1.0 ms. The fitted guess would not fix that.
- **Fix before anything else** if P1 fails.
