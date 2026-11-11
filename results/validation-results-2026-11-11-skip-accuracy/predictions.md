# Predictions: what expert skipping costs in accuracy, on 3,321 graded questions

Written on 2026-11-11, before any run of the simulation on the model. Nothing
here has been measured yet. The only runs so far are the local tests in
[`jobs/test_skipsim.py`](jobs/test_skipsim.py), with no model.

## The question

iOS has skipped experts by default since 2026-11-08 (`miss:0.08`), and
Settings also offers `miss:0.10`. The accuracy evidence so far is thin:

- **Teacher-forced KL on the Mac:** 0.55× of one INT4 rounding at 0.08, and
  0.94× at 0.10. This is a per-token measure. It does not show what happens
  once a reply runs on its own text
  (`results/research-results-2026-10-04-lossy-experts/`).
- **One graded run on the phone:** 47 of 50 GSM-Symbolic problems right both
  ways. It cannot see a loss of 1–3 problems
  (`results/validation-results-2026-11-08-ios-expert-skip-accuracy/`).
- **No graded run of 0.10 at all.**

This run grades both thresholds on the QAT study's benchmark. Each question is
paired across arms, so a loss of about 1.3 MMLU-Pro points can be seen.

## The method

The phone is too slow for 3,321 questions per arm: about 1.7 minutes a
problem, or 4 days per arm. So the runtime's decisions are simulated on a GPU
instead, around HF transformers' Gemma 4.
[`jobs/skipsim.py`](jobs/skipsim.py) reproduces, per question, what the app
at `9bbc435` does:

- **The expert cache:** 24 slots per layer, LFU with count aging (×0.97 per
  plan, +1 per planned expert), evicting empty slots first, then the lowest
  count, then the oldest last use. Every question starts from empty slots and
  zero counts, as a fresh load does.
- **Prefill, layer at a time:** each layer's distinct experts in ID order, in
  tiles of 8. Nothing is skipped in prefill, on the phone or here.
- **The early read:** one per layer. At layer L, the bundled fitted guess
  (`gemma-4-26b-a4b-it-4bit.bin`, SHA-256 `b1824244…`) scores layer L+1's
  experts from L's router input. The best one L+1's cache lacks is pending,
  and a pending expert is not a foreground miss. The user asked that the early
  read stay in: without it, more of each layer's top 8 would be skippable
  misses than on the phone.
- **The skip rule** of `ExpertSkipPolicy.decide`, kind `miss`:
  - p is the softmax over the top-8 logits;
  - a rank-2-or-later expert with p < t is dropped, unless it is resident or
    pending;
  - its place goes to the most used resident expert outside the top 8, at
    weight 0;
  - the kept weights are renormalized, then given the per-expert scale.

The scalar port and the batched version agree in 40 random traces: identical
expert choices, cache contents, use counts and counters, including the ties.
The Swift test cases pass on both.

**The model:** the app's own 4-bit weights (`mlx-community/gemma-4-26b-a4b-it-4bit`),
dequantized to BF16. It is the `default` model of the QAT study
(`results/validation-results-2026-11-08-qat-bf16-quality/`). Routing,
the router's 8-bit weights included, differs from the phone's only by
arithmetic: BF16 here, FP16 on the phone.

**The benchmark,** as in the QAT study, except the engine:

- MMLU-Pro, 5-shot chain of thought, the first 143 of each of the 14 subjects
  (2,002 questions);
- GSM8K `gsm8k_cot_llama`, 8-shot chain of thought, all 1,319, up to 1,024 new
  tokens;
- lm-evaluation-harness 0.4.13, chat template on, thinking off, greedy;
- HF transformers 5.19.0 with grouped-matmul experts (vLLM cannot change
  routing per sequence), on one H100 94 GB per arm.

Every arm runs the same batches in the same order, and every question is
logged with its own simulated counters.

## The arms

| Arm | Threshold | Slots | Run |
| --- | --- | --- | --- |
| `off` | none | 24 | always |
| `0.08` | `miss:0.08` (the iOS default) | 24 | always |
| `0.10` | `miss:0.10` (offered in Settings) | 24 | always |
| `32-0.08` | `miss:0.08` | 32 | if the smoke job puts an arm under 2.5 hours |

`off` generates the same text at any slot count, so 32 / off needs no arm.

## Before the arms: the simulation against the phone

[`jobs/teacher.py`](jobs/teacher.py) teacher-forces the iPhone 17's six
distinct replies from the 2026-11-08 skip A/B (3 cases, off and 0.08)
and compares the counters with the phone's footers.

| Quantity | Predicted |
| --- | --- |
| Prompt tokens | equal to the phone's 61 / 430 / 3,015 |
| Prefill reads | within ±2% of the phone's 2,171 / 2,773 / 3,478 |
| Decode hit rate | within ±1.5 points of the phone |
| Early reads used per token | within ±1.5 of the phone's 19.2–22.1 |
| Dropped per layer, at 0.08 | within ±15% of the phone's 0.438 / 0.486 / 0.538 |
| Teacher-forced top-1 agreement with the phone's tokens | 90–98%. The phone sampled at T 0.2, and its arithmetic differs. |

**Gate:** if hit rate is off by more than 3 points in any case, or dropped per
layer by more than 30%, the simulation is not the app. Then I fix it before
any arm runs, and record the miss here.

## The accuracy predictions

The anchor is the QAT study's paired result for one INT4 rounding of the
whole model: −3.75 MMLU-Pro points (−2.45 to −5.04), and 0.00 on GSM8K. Scaled
by KL alone, 0.08 would cost about 2 MMLU-Pro points and 0.10 about 3.5. I
expect less than that. Rounding acts on every token, prefill included, so
it also degrades how the 5-shot prompt is read. Skipping acts only on the
reply. So I put the cost at about half the KL scaling.

| Quantity | Predicted |
| --- | --- |
| `off`, MMLU-Pro | 76.5–79.5% (vLLM: 77.97%) |
| `off`, GSM8K | 93.0–95.3% (vLLM: 94.16%) |
| `off` against vLLM `default`, same questions | within ±1.5 points on each task |
| `0.08` − `off`, MMLU-Pro | **−1.0 points (−2.5 to +0.5)** |
| `0.10` − `off`, MMLU-Pro | **−1.5 points (−3.5 to 0.0)** |
| `0.08` − `off`, GSM8K | **−0.3 points (−1.2 to +0.6)** |
| `0.10` − `off`, GSM8K | **−0.5 points (−1.5 to +0.5)** |
| `0.10` − `0.08`, MMLU-Pro | −0.5 points (−2.0 to +1.0) |
| `32-0.08` − `0.08`, both tasks | between 0 and +1.0 points (fewer drops) |
| Replies with no extracted answer | each skipping arm within 1.3× of `off`'s count |

**Noise:** with about 8% of MMLU-Pro questions discordant between two arms, a
paired difference has a 95% interval of about ±1.2 points. For GSM8K, at
about 3%, it is about ±0.9. So a true cost of −1.0 on MMLU-Pro may or may not
reach significance.

## The controls

| Quantity | Predicted |
| --- | --- |
| Prompts per question across arms | byte-identical (lm-eval `prompt_hash`) |
| Early reads issued per decode forward | exactly 29 |
| `off`'s dropped experts | exactly 0 |
| `off`, decode hit rate | 72–80% |
| Hit rate, `0.08` − `off` | +4 to +7 points (phone: +4.8 to +5.8) |
| Foreground reads per token, `0.08` against `off` | −30 to −45% (phone: −33.7 to −42.3%) |
| Foreground reads per token, `0.10` against `off` | −45 to −65% (Mac: −62.0%) |
| Dropped per layer, `0.08` | 0.42–0.62 (phone: 0.438–0.538) |
| Dropped per layer, `0.10` | 0.65–1.00 |

## The mechanism

A dropped expert carries under 8% (or 10%) of the router's weight, and the
remaining weights are scaled up to cover it. Each drop moves the layer's output
a little. Teacher-forced KL prices that move per token. Generation adds two
effects:

- **Drift:** a changed token changes everything after it. The 2026-11-08 phone
  run showed this does not compound into broken replies at 0.08 (median first
  difference at character 197, answers unchanged).
- **Selection:** drops land only on foreground misses, which are experts this
  question has used little lately. That may be where the reply turns to
  something new, for example the step where a chain of thought picks an
  answer.

The second is why a graded test is needed on top of KL.

## What would falsify it

- **The simulation:** the gate above fails.
- **The size:** `0.08` − `off` worse than −2.5 MMLU-Pro points, or worse than
  −1.2 on GSM8K. Then skipping costs more than the KL said, through drift or
  selection.
- **The order:** `0.10` doing better than `0.08` by more than the noise
  (McNemar p < 0.05).
- **The baseline:** `off` more than 1.5 points from vLLM's `default`. Then the
  HF engine differs, and the arms compare only with each other.

## What it decides

Nothing by itself. The iOS default and the Settings options are the user's
quality decision (AGENTS.md, "What is open"). The run adds:

- a paired accuracy cost for 0.08 and 0.10, with intervals;
- whether that cost is under one INT4 rounding's (−3.75 MMLU-Pro points),
  as the KL said;
- for the 32-slot arm, whether 12 GB phones get the same accuracy back as
  well as the speed.

## Limits

- **Simulated, not run on the phone.** The arithmetic differs: BF16 here, FP16
  and the app's kernels there. Routing near-ties can therefore flip, and the
  cache state can drift from the phone's. The teacher-forcing check measures
  how far.
- **Greedy decoding.** The app samples at T 0.2.
- **A fresh cache for every question.** In the app, a new chat keeps the
  previous chat's experts resident and resets only the counts.
- **Context.** Some MMLU-Pro prompts plus replies exceed the app's 4,096-token
  default. They are kept, as in the QAT study.
