# Lossy routed experts: predictions

Written 2026-10-04, before the quality runs that score them. The lossless
study (`../research-results-2026-10-04-expert-compression/`) found at most
−15% of bytes and almost no decode gain. The user asked for lossy options and
not to trust upstream's word on them. Upstream's word is one line:
"Requantizing weights below INT4 was cancelled by the quality floor; no 3-bit
or 2-bit weight runtime was built", and "cache-conditional routing remains a
quality-changing hypothesis" (`docs/experiments/summaries/09-…`). Neither
gives a number, so both are open.

## What is measured, and how

**Quality** by a new teacher-forced meter, `TurboFieldfareScore`. It feeds 12
chat transcripts through the model and compares each position's next-token
distribution with an unchanged reference run, on exactly the same tokens. The
transcripts are prompts from `scratch/cache-traces` with the answer the
unchanged model generated for them on the Mac. They cover code (Rust, SQL,
Python), math, a logic grid, a table, a multi-turn chat, and Spanish, French,
Russian and Japanese. Each answer is capped at 128 tokens, for about 1,500
scored positions. The meter reports:

- **KL**: KL(reference ‖ variant), nats per token, over the reference's top 64
  tokens plus one bucket for the rest. This is a lower bound on the full KL.
- **top1**: how often the variant's most likely token is the reference's.
- **ΔNLL**: the change in negative log-likelihood of the transcript's own
  tokens.

The meter is deterministic. A second unchanged run gave KL 0 and top1 1.0000
exactly in the smoke test.

**The yardstick: `noise=1/12`.** Each routed-expert INT4 code moves by ±1 with
probability 1/12. That adds error with the variance of one INT4 rounding
(s²/12; the benchmark measured 0.98× on a real expert). The installed experts
already carry about one such rounding from BF16, so this run approximates what
INT4 itself costs over BF16 in the routed experts. **A variant at or below the
yardstick's KL costs no more than INT4 already does.** That is the bar for
"worth a phone A/B and a human read".

**Lossy formats are simulated in place.** Every expert is rewritten right
after it is read, before any kernel sees it
(`TURBO_FIELDFARE_LOSSY_EXPERTS`). A k-bit affine group is also a valid INT4
group, so no kernel changes. Bytes for a real k-bit format are arithmetic. A
real format needs an INT3 or INT2 kernel, or a CPU unpack after the read;
neither is built.

**Expert skipping is real.** `TURBO_FIELDFARE_EXPERT_SKIP` changes decode
routing and the reads it issues, so its read counts are measured directly. It
does not touch prefill.

Configuration: Mac, 24 slots (the phone's), the early read on with the fitted
guess, count aging on, prefill chunk 256.

## Expert bytes for each format (arithmetic)

One expert holds 5,947,392 weights: 2,973,696 B of INT4 codes, 371,712 B of
BF16 scales and biases, and 13,312 B of padding, 3,358,720 B in all.

| Format | Bytes per expert | Change |
| --- | --- | --- |
| INT4 (installed) | 3,358,720 | — |
| `down` at 3 bits | 3,097,600 | −7.8% |
| `gate`, `up` at 3 bits | 2,849,792 | −15.2% |
| All at 3 bits | 2,601,984 | −22.5% |
| All at 2 bits | 1,858,560 | −44.7% |

Each format is unpadded. Stacking the lossless scales-and-biases coding
(−7.4% of an INT4 expert) would take a further ~249 KB from each.

## Probes already run (not predictions)

`trace_policies.py` (`trace-policies-output.txt`) replays 29 routing traces,
13,835 tokens, at 24 slots:

- **Router weights are flat.** Ranks 1 to 8 average 0.259, 0.171, 0.135,
  0.112, 0.096, 0.084, 0.075 and 0.068.
- **Dropping a low-weight expert only when it is a miss is far cheaper in
  dropped weight than dropping a fixed rank:**

| Policy | Foreground reads per token | Dropped weight per layer |
| --- | --- | --- |
| `top7` | −21.4% | 0.068 |
| `miss:0.05` | −10.2% | 0.005 |
| `miss:0.08` | −40.6% | 0.031 |
| `miss:0.10` | −64.5% | 0.059 |
| `missrank:7` | −40.8% | 0.036 |

`cold_experts.py` (`cold-experts-output.txt`) asks whether misses concentrate
on rarely used experts. The coldest 50% of each layer's experts, ranked on
training traces, take 25.2% of held-out uses and 37.1% of held-out foreground
reads. That is a 1.5× concentration.

Smoke runs of 48 positions, used to check the tools:

- `all=3`: KL 0.065, top1 0.94.
- `miss:0.08`: KL 0.041, top1 0.92, foreground reads 47.6 → 28.9 per token.

They shaped the ranges below.

## Predictions

### P1. Yardstick

| Variant | KL | top1 | ΔNLL |
| --- | --- | --- | --- |
| `noise=1/12` | 0.012–0.035 | ≥ 0.96 | within ±0.02 |

### P2. Lower-bit formats

KL is predicted to scale roughly with the added error variance: 3 bits adds
2.93× one rounding, and 2 bits 13.4×.

| Variant | KL relative to the yardstick | top1 |
| --- | --- | --- |
| `all=3` | 2–4× | 0.90–0.95 |
| `gate=3,up=3` | 0.6–0.75× of `all=3` | |
| `down=3` | 0.25–0.45× of `all=3` | |
| `all=2` | ≥ 8× | ≤ 0.85 |
| `all=3` on the cold 50% only | 0.2–0.4× of `all=3` | |

**Prediction: no lower-bit format of all experts clears the yardstick.**

### P3. Expert skipping

| Variant | Foreground reads per token, against the reference | KL |
| --- | --- | --- |
| `miss:0.05` | −8 to −14% | 0.003–0.015 |
| `miss:0.08` | −35 to −45% | 0.02–0.05 |
| `miss:0.10` | −58 to −70% | 0.04–0.09 |
| `missrank:7` | −35 to −45% | 0.02–0.06 |
| `top7` | −16 to −26% | 0.05–0.12 |

The read ranges come from the replay. The measured run also places a resident
stand-in in each dropped slot, which touches LFU counts. That may shift the
reads by a few points.

- **`top7` against `miss:0.10`:** `top7` drops more weight and saves fewer
  reads, so it should be worse on both axes.
- **`misssub:0.08` against `miss:0.08`:** it swaps a dropped miss for the
  best-scoring resident expert outside the top 8, and should have **lower KL
  by 15–40% at about the same reads.**
- **`miss:0.08:nonorm` against `miss:0.08`:** it does not renormalize, and
  should have **higher KL**.

**Prediction: `miss:0.05` clears the yardstick.** Whether `miss:0.08` does
is the open question. I lean no, at 1–2× the yardstick.

### P4. Byte for byte, skipping beats lower bits

At equal KL, an expert-skip policy removes more foreground bytes per token
than any lower-bit format. A skipped miss saves a whole 3.36 MB read. A 3-bit
expert saves 22.5% of every read, but costs quality on every expert used, hit
or miss.

### P5. What it would mean on the phone (arithmetic, not measured here)

On the phone, `io` is about 60% of a token, and the reads a token waits for
drive it. Read time is about bytes / 1.65 GB/s plus a small per-read cost.

| Change | `io` | tok/s |
| --- | --- | --- |
| Foreground reads −40% (`miss:0.08`) | about −30 to −38% | about +20 to +30% |
| All at 3 bits | about −20% | about +12 to +14% |

Prefill would also read 22.5% fewer bytes with 3 bits. It would not change
under expert skipping, which is decode only.

### Controls

- Every run scores the same token positions (the meter checks each token
  against the reference file).
- The lossy-simulation runs do not change routing, so their read counts should
  match the reference's within run-to-run cache noise. The cache is
  deterministic given routing, but routing itself shifts slightly under a
  changed model.

### What would falsify these

- **The yardstick:** KL outside 0.012–0.035, or not reproducible, which would
  make the scale itself suspect.
- **3 bits clearing the bar:** `all=3` at or below the yardstick would
  overturn upstream's "quality floor" outright.
- **The skip predictions:** a measured read cut outside the ranges, or
  `miss:0.05` above the yardstick.
- **The skip-versus-bits comparison:** a lower-bit format beating a skip
  policy at equal KL.

## Addendum 1: published cache-aware routing as a baseline (before its runs)

Skliar et al. 2024, "Mixture of Cache-Conditional Experts for Efficient
Mobile Device Inference" (arXiv 2412.00099), already does training-free
cache-aware routing. They add λ × (average logit range) to cached experts'
logits, protect the top J, and weight the chosen experts by their original
logits. They report more than 50% fewer misses at a 0.1–3% perplexity cost
and under 0.1% on MMLU and GSM8K. Their models were Mixtral (top 2 of 8),
Phi-3.5-MoE (top 2 of 16), Qwen1.5-MoE (top 4 of 60) and DeepSeek-V2-Lite
(top 6 of 64).

Gemma 4 routes 8 of 128 with flat weights, which none of those resemble. So
their method is added as `bias:<λ>` (J = 1; the pending early read counts as
cached), to be scored beside the drop policies.

Replay (`trace-policies-bias-output.txt`, same 29 traces):

| λ | Foreground reads per token | Original top-8 weight swapped out per layer |
| --- | --- | --- |
| 0.05 | −33.9% | 0.030 |
| 0.10 | −54.7% | 0.052 |

### P6. Reranking against dropping

| Variant | Foreground reads per token | KL |
| --- | --- | --- |
| `bias:0.05` | −28 to −40% | 0.015–0.04 |
| `bias:0.10` | −48 to −60% | 0.03–0.07 |

**At equal reads saved, reranking has lower KL than dropping.** Its stand-ins
are real experts with nonzero router scores, where dropping leaves a hole.
I'd put it at 0.6–1.0× the KL of the drop policy that saves the same reads.

These runs use a binary that has the `bias` kind. The earlier queue's binary
was built at 99841bb, and the `bias` code does not touch any other path.
