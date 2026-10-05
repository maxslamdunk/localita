# Lossy routed experts: results

2026-10-04/05, Mac (M1 MacBook Air, 8 GB, macOS 26.6.1), gemma4
(`scratch/gemma4.gturbo`). Predictions in `predictions.md`, committed before
the runs (99841bb, Addendum 1 at da57c46). No iPhone run: the phone was not
connected. Phone figures below are arithmetic.

## The answer

**Skipping a low-weight routed expert only when it would be a cache miss is
the lossy option worth taking to the phone. Lower-bit expert formats are not.**

- **`miss:0.08` cuts reads, by measurement:**
  - The reads a decode token waits for drop **39%** (38.0 → 23.1 per token).
  - The quality cost is **0.55× [0.31, 0.90] of the yardstick**: half of what
    one more INT4 rounding of the routed experts costs.
  - Top-1 agreement with the unchanged model is 97.7%.
  - Free-running generations read as equally good.
  - It is a runtime switch: no format or kernel change.
- **`miss:0.10` goes further:** reads **−62%**, at a cost **equal to** the
  yardstick: 0.94× [0.64, 1.30].
- **Re-quantizing the experts to 3 bits costs far more:**
  - All experts at 3 bits saves 22.5% of each read's bytes and costs **3.05×
    [2.21, 4.33]** the yardstick.
  - 3 bits on only part of each expert, or on only the cold half of experts,
    costs 1.2–1.5× the yardstick for 8–15% of the bytes.
  - So upstream's "quality floor" against sub-INT4 holds here, for a
    measured reason it never wrote down. The bound is per byte saved:
    skipping gets about 3–5× more read reduction for the same KL.
- **Skipping beats the published cache-aware routing on this model.** That
  method (Skliar et al. 2024, cache-prior reranking) costs the same KL as
  skipping but saves fewer reads: −31% against −39% at KL 0.025, and −51%
  against −62% at 0.042.
- **On the phone this is about +20 to +30% tok/s for `miss:0.08`**, if the
  smaller `io` carries over as it should. That is arithmetic from the decode
  table in `CLAUDE.md`, not a measurement. It needs the phone A/B, and a human
  read of real chats, before any default changes.

## How quality was measured

`TurboFieldfareScore` (new, research only) teacher-forces 12 transcripts:

- The transcripts are prompts with the unchanged model's own Mac answers:
  code (Rust, SQL, Python), math, a logic grid, a comparison table, a
  multi-turn chat, and Spanish, French, Russian and Japanese.
- Each answer is capped at 128 tokens, for 1,536 scored positions.
- Every run is compared position by position against a reference run on the
  same tokens.
- **KL** is KL(reference ‖ run), in nats per token, over the reference's top
  64 tokens plus a tail bucket. It is a lower bound on the full KL.
- Confidence intervals resample the 12 transcripts, not tokens.
- **The meter is exact.** A second reference run wrote a byte-identical file
  (`cmp` over all 1,536 × 64 entries).

**The yardstick (`noise`)** moves each routed-expert INT4 code by ±1 with
probability 1/12. That adds error of the variance one INT4 rounding has (s²/12;
0.98× on a real expert, `bench/`). The routed experts already carry one such
rounding from BF16, so the yardstick approximates INT4's own cost in the
routed experts. A variant below it costs less than the quantization the
project already accepted.

Lower-bit formats are simulated: each expert is rewritten in its slot right
after the read, to k-bit affine groups that are also valid INT4 groups
(`LossyExpertSimulation`). Codes and ranges are chosen by an error search on
the 16-bin code histogram, then a least-squares refit. The search beats
min-max by test. Expert skipping is real, in the runtime
(`ExpertSkipPolicy`), so its read counts are measured.

Setup: 24 slots, the early read on with the fitted guess, count aging on,
prefill chunk 256. Reference: 38.00 foreground reads per token, hit rate
76.2%, near the phone's medium case (75.7%).

## Results

From `summarize.py`, `PAIRED=1 python3 summarize.py`.

| Run | What | Foreground reads per token | KL [95% CI] | KL against the yardstick (paired CI) | Top-1 agreement | ΔNLL |
| --- | --- | --- | --- | --- | --- | --- |
| `noise` | Yardstick: one INT4 rounding of noise | 38.12 (+0.3%) | 0.0452 [0.032, 0.059] | 1 | 0.973 | +0.051 |
| `miss05` | Drop a miss with weight < 0.05 | 34.14 (**−10.2%**) | 0.0044 [0.003, 0.007] | **0.10** [0.06, 0.14] | 0.986 | +0.005 |
| `miss08` | Drop a miss with weight < 0.08 | 23.14 (**−39.1%**) | 0.0246 [0.014, 0.037] | **0.55** [0.31, 0.90] | 0.977 | +0.030 |
| `miss08-nonorm` | As above, no renormalization | 23.15 (−39.1%) | 0.0238 [0.014, 0.035] | 0.97× of `miss08` [0.91, 1.01] | 0.980 | +0.029 |
| `missrank7` | Drop a miss of rank 7 or 8 | 23.39 (−38.4%) | 0.0242 [0.014, 0.036] | 0.54 [0.32, 0.79] | 0.977 | +0.033 |
| `misssub08` | `miss08`, swap in the best resident | 23.00 (−39.5%) | 0.0293 [0.018, 0.043] | 1.19× of `miss08` [0.97, 1.53] | 0.969 | +0.028 |
| `miss10` | Drop a miss with weight < 0.10 | 14.44 (**−62.0%**) | 0.0423 [0.028, 0.057] | **0.94** [0.64, 1.30] | 0.968 | +0.051 |
| `top7` | Always drop rank 8 | 30.89 (−18.7%) | 0.0280 [0.019, 0.039] | 1.14× of `miss08` [0.78, 1.67] | 0.969 | +0.037 |
| `bias05` | Cache-prior reranking, λ 0.05 | 26.08 (−31.4%) | 0.0248 [0.014, 0.039] | 0.55 [0.32, 0.81] | 0.969 | +0.031 |
| `bias10` | Cache-prior reranking, λ 0.10 | 18.51 (−51.3%) | 0.0416 [0.024, 0.065] | 0.92 [0.56, 1.33] | 0.966 | +0.052 |
| `all3` | All experts at 3 bits (−22.5% bytes per read) | 38.01 | 0.1380 [0.104, 0.173] | **3.05** [2.21, 4.33] | 0.929 | +0.139 |
| `gateup3` | Gate and up at 3 bits (−15.2%) | 38.00 | 0.0658 [0.046, 0.093] | ≈1.46 | 0.951 | +0.061 |
| `down3` | Down at 3 bits (−7.8%) | 38.10 | 0.0615 [0.045, 0.079] | ≈1.36 | 0.954 | +0.067 |
| `cold50-3` | 3 bits on the least-used half of experts | 37.95 | 0.0534 [0.030, 0.081] | 1.18 [0.67, 1.86] | 0.960 | +0.055 |

- **Read counts.** For the lower-bit runs they are unchanged by design; the
  bytes per read shrink instead. With `cold50-3`, the cold experts take about
  37% of foreground reads (`cold-experts-output.txt`), so about 8% of the
  waited-for bytes.
- **`all2`** (all at 2 bits) was stopped at the user's request
  (`logs/all2-stopped.txt`). Its added error is 13.4× one rounding, and its
  result could not have changed the decision.
- **The 3-bit costs add up.** `gateup3` + `down3` = 0.127, against `all3`
  0.138. That supports the error-variance model behind P2.

### Byte for byte

| Variant | Waited-for bytes per token | KL |
| --- | --- | --- |
| `miss05` | −10% | 0.004 |
| `miss08` | −39% | 0.025 |
| `miss10` | −62% | 0.042 |
| `bias05` | −31% | 0.025 |
| `bias10` | −51% | 0.042 |
| `top7` | −19% | 0.028 |
| `cold50-3` | about −8% | 0.053 |
| `down3` | −7.8% | 0.062 |
| `gateup3` | −15.2% | 0.066 |
| `all3` | −22.5% | 0.138 |

**Skipping a miss is the cheapest way to remove a waited-for byte.** It acts
only where the router itself rates an expert least, and only when that expert
would cost a read. A lower-bit format spends its error on all 8 experts of
every layer and token, hits included.

### Free-running generations (Mac, greedy, 24 slots)

`generate.sh`, in `gen/`. Two `real-generation-v1` prompts, base against
`miss:0.08` and `miss:0.10`.

**Quality.** All six answers are correct and complete, with the same
structure and substance:

- **The wetlands answer** keeps the same mechanisms, the same two limits and
  the same risk-versus-protection framing.
- **The cache review** names the same correctness and performance risks and
  the same promise-based fix.
- **The wording diverges** after one or two paragraphs, as greedy decoding
  does after the first changed token.
- **No answer showed a fault** under either policy: no repetition, broken
  formatting or wrong claim.

**Reads.** The waited-for reads per token, (reads − early) / forward, fell
by about as much as in the scorer: −42% and −64% on the short prompt, −33%
and −59% on the medium one.

| Prompt | Base | `miss:0.08` | `miss:0.10` |
| --- | --- | --- | --- |
| Short explanation | 30.1 | 17.3 | 10.8 |
| Medium review | 34.9 | 23.5 | 14.2 |

**Mac speed: no clean A/B.** The runs went base first, then the variants, on
a Mac at about 20% free memory and 6 GB of swap. `cb1-wait`, which is GPU
work the policy does not change, swung from 63 to 132 ms/forward between
runs. So the Mac tok/s (4.1 / 5.0 base; 8.0 / 4.3; 9.5 / 7.3) is not quoted
as a result. The phone A/B is the measurement that counts.

## Predictions scored

**P1, the yardstick: missed.**

| Metric | Predicted | Measured | |
| --- | --- | --- | --- |
| KL | 0.012–0.035 | 0.0452 | Missed |
| top1 | ≥ 0.96 | 0.973 | Held |
| ΔNLL | within ±0.02 | +0.051 | Missed |

The scale was set too low. A later estimate from `all3` / 2.93 (0.047) was
right, but it came after the prediction.

**P2, lower bits: mostly held.**

| Variant | Predicted | Measured | |
| --- | --- | --- | --- |
| `all3` against the yardstick | 2–4× | 3.05× | Held |
| `all3` top1 | 0.90–0.95 | 0.929 | Held |
| `gateup3` against `all3` | 0.6–0.75× | 0.48× | Missed (lower) |
| `down3` against `all3` | 0.25–0.45× | 0.446× | Held, at the edge |
| `cold50-3` against `all3` | 0.2–0.4× | 0.387× | Held |
| No lower-bit format of all experts clears the yardstick | | `all3` at 3.05× | Held |

**Down is as sensitive as gate and up together.** Per weight it is about
twice as sensitive, which my equal-share assumption did not expect.

**P3, expert skipping: the read cuts all held; two quality calls missed.**

| Variant | Reads predicted | Reads measured | KL predicted | KL measured |
| --- | --- | --- | --- | --- |
| `miss:0.05` | −8 to −14% | −10.2% ✓ | 0.003–0.015 | 0.0044 ✓ |
| `miss:0.08` | −35 to −45% | −39.1% ✓ | 0.02–0.05 | 0.0246 ✓ |
| `miss:0.10` | −58 to −70% | −62.0% ✓ | 0.04–0.09 | 0.0423 ✓ |
| `missrank:7` | −35 to −45% | −38.4% ✓ | 0.02–0.06 | 0.0242 ✓ |
| `top7` | −16 to −26% | −18.7% ✓ | 0.05–0.12 | 0.028 ✗ (lower) |

The comparisons:

| Prediction | Measured | |
| --- | --- | --- |
| `top7` worse than `miss:0.10` on both reads and KL | Worse on reads; its KL is lower | Half held |
| `misssub` has 15–40% lower KL than `miss:0.08` | 1.19× higher [0.97, 1.53] | Missed |
| `nonorm` has higher KL than `miss:0.08` | 0.97× [0.91, 1.01], no difference | Missed |
| `miss:0.05` clears the yardstick | 0.10× | Held |
| I leaned that `miss:0.08` would not clear it | 0.55× | Missed, in the good direction |

**P4, skipping beats lower bits byte for byte: held, by 3–5×.**

**P5, the phone: open.** It is arithmetic until the phone A/B.

**P6, published reranking: the read cuts held; the comparison missed.**

| | Predicted | Measured | |
| --- | --- | --- | --- |
| `bias05` reads | −28 to −40% | −31.4% | Held |
| `bias05` KL | 0.015–0.04 | 0.0248 | Held |
| `bias10` reads | −48 to −60% | −51.3% | Held |
| `bias10` KL | 0.03–0.07 | 0.0416 | Held |
| Reranking has lower KL than dropping at equal reads | At equal KL it saves fewer reads: −31% against −39%, and −51% against −62% | Missed |

The swapped-in expert is not worth its weight on this model. With 8 of 128
experts and flat weights, a stand-in is about as wrong as a hole, and it
moves the cache too.

## What it would mean on the phone (arithmetic, not measured)

From the medium row in `CLAUDE.md`: wall 208 ms, of which `io` is 127 ms.
Storage serves one read at a time, about 2.1–2.2 ms per expert. With the
early read on, 29 early reads per token are hidden in idle time. The
foreground reads are what `io` waits for.

| | Foreground reads | `io` | tok/s |
| --- | --- | --- | --- |
| `miss:0.08` | −39% | −25 to −39% (32–50 ms) | **+18 to +32%** |
| `miss:0.10` | −62% | −40 to −60% | +32 to +58%, before other phases become the limit |

Prefill is unchanged: skipping is decode only.

## Records and code

- **Runtime, research only, off unless an environment variable is set:**
  - `ExpertSkipPolicy` (`TURBO_FIELDFARE_EXPERT_SKIP=miss:0.08`, …, `bias:<λ>`)
  - `LossyExpertSimulation` (`TURBO_FIELDFARE_LOSSY_EXPERTS=all=3`, …)
  - Tests: `ExpertSkipPolicyTests`, `LossyExpertSimulationTests`, 13 tests.
- **The meter:** `TurboFieldfareScore` (`Sources/TurboFieldfareScore/`), built
  on `scoreTeacherForced`.
- **Every run has a row in `MEASUREMENTS.md`.** That includes the two first
  runs of `noise` and `miss05`, which a bug in `score.sh` made write
  references instead of being scored (`logs/*-refmode.txt`). Only their read
  counts are usable. Both were re-run.
- **Binaries.** The first queue's binary was built at 99841bb. The log
  headers say `da57c46+dirty` because the reranking code was in the tree but
  not in that binary. The second queue (`noise`, `bias05`, `bias10`,
  `miss05`) and the generations ran at 63a1f08.

## What to do next

1. **Phone A/B of `miss:0.08`** against off. It needs an iOS harness flag or
   the environment variable passed at launch. Protocol: three cases, A B B A.
   Prediction: tok/s +18 to +32%, foreground reads −35 to −45%, text not
   byte-identical by design.
2. **A quality check beyond KL** before a default changes:
   - a read of a few real chats under `miss:0.08`;
   - a small task set (arithmetic, code, multilingual) scored as pass/fail;
   - the long-context case, which is not in the 128-token transcripts.
3. **Tuning that might buy more at the same KL:** a threshold per layer
   (never skip in the first and last layers), and keeping the miss's weight
   in reserve for the next token.
4. **Lower-bit formats: not now.** If revisited, put 3 bits on gate and up
   only (lowest cost per byte), stacked on skipping, as its own experiment.
