# Results: Google's QAT checkpoint, LM Studio's QAT build and the app's default build

Scored against [predictions.md](predictions.md), written before the runs (the
fourth model's part before its run, after `original`'s scores were seen).
One H100 94 GB (driver 615.71.09), 2026-11-08; jobs 28997220 (three
models) and 28997559 (`lmstudio`). Scripts in `jobs/`, the scorer is
[paired.py](paired.py), its full output [paired-output.txt](paired-output.txt).

## Scores

Accuracy; every prompt was byte-identical across the four models
(lm-eval's `prompt_hash`, 0 differences).

| | MMLU-Pro (2,002) | no answer | GSM8K (1,319) | no answer |
| --- | --- | --- | --- | --- |
| `original` | **81.72%** | 37 | **94.16%** | 4 |
| `qat` (≈ a faithful 4-bit QAT build) | **79.52%** | 44 | **93.78%** | 3 |
| `lmstudio` (LM Studio's QAT MLX 4-bit) | **78.27%** | 63 | **93.25%** | 5 |
| `default` (the app's 4-bit build) | **77.97%** | 95 | **94.16%** | 6 |

MMLU-Pro is the first 143 questions of each of its 14 subjects, 5-shot chain
of thought, up to 2,048 tokens. GSM8K is `gsm8k_cot_llama`, all of it, strict
match. "No answer" counts replies the harness could not extract a letter or
number from. Most of them are replies still reasoning at the 2,048-token cap,
the rest repetition loops; the cap was the same for every model.

## Paired differences

Points of accuracy, 95% interval from the discordant pairs, exact McNemar.

| Comparison | MMLU-Pro | p | GSM8K | p |
| --- | --- | --- | --- | --- |
| `original` − `qat` | +2.20 (+1.03 to +3.37) | 0.0003 | +0.38 (−0.36 to +1.12) | 0.42 |
| `original` − `default` | +3.75 (+2.45 to +5.04) | 2e-8 | 0.00 (−0.66 to +0.66) | 1 |
| `original` − `lmstudio` | +3.45 (+2.07 to +4.82) | 1e-6 | +0.91 (+0.02 to +1.80) | 0.065 |
| `qat` − `default` | +1.55 (+0.20 to +2.89) | 0.029 | −0.38 (−1.15 to +0.39) | 0.44 |
| `qat` − `lmstudio` | +1.25 (−0.03 to +2.53) | 0.066 | +0.53 (−0.15 to +1.21) | 0.19 |
| `lmstudio` − `default` | +0.30 (−1.18 to +1.78) | 0.74 | −0.91 (−1.80 to −0.02) | 0.065 |

## The predictions, scored

| Comparison | Predicted, MMLU-Pro | Measured | Predicted, GSM8K | Measured |
| --- | --- | --- | --- | --- |
| `qat` − `original` | −0.5 (−1.5 to +0.5) | **−2.20, miss** | −0.5 (−1.5 to +0.5) | −0.38, held |
| `default` − `original` | −2 (−3 to −1) | **−3.75, miss** | −1.5 (−2.5 to −0.5) | **0.00, miss** |
| `qat` − `default` | +1.5 (+0.5 to +3) | +1.55, held | +1 (0 to +2) | **−0.38, miss** |
| `lmstudio` − `qat` | −1.5 (−3 to −0.5) | −1.25, held | −1 (−2 to 0) | −0.53, held |
| `lmstudio` − `default` | +0.5 (−1 to +1.5) | +0.30, held | 0 (−1 to +1) | −0.91, held |

Six of ten held. The misses go two ways:

- **QAT costs more than predicted, and rounding costs more than predicted on
  MMLU-Pro.** The prediction treated QAT as nearly free and 4-bit rounding as a
  couple of points. Both cost about 1.5 points more on reasoning-heavy
  multiple choice.
- **GSM8K is insensitive to all of it.** No pair separates on it. The
  predicted rounding cost on math did not appear.

The falsification tests:

- **"QAT is broken"** (more than 3 points below `original`): not met.
  −2.2 is real but smaller.
- **"Rounding does not matter"** (`default` within ±0.5 of `original` on
  all three): not met, because of MMLU-Pro.
- **"QAT does not help"** (`qat` − `default` ≤ 0 on two of three): undecided.
  GSM8K is at −0.38, MMLU-Pro at +1.55, and the third test (Global-MMLU) is
  unscored, below.
- **"LM Studio's re-rounding is harmless"** (`lmstudio` within 0.5 of `qat`
  on both): not met on MMLU-Pro (−1.25), met on GSM8K (−0.53 is just
  outside). The prediction holds, at p = 0.066 on MMLU-Pro.

## What it shows

1. **QAT is a better starting point for 4 bits than the original, by about
   1.5 points on MMLU-Pro**, nothing on GSM8K. A faithful 4-bit QAT build
   stands in at `qat`'s score, since Unsloth's Q4_0 matches it in 99.79–99.98%
   of values.
2. **QAT itself is not free:** 2.2 points under the original on MMLU-Pro, at
   BF16. Google's QAT model card reuses the original's benchmark table, so it
   does not show this.
3. **LM Studio's QAT build keeps little of QAT's advantage:** 1.25 of the 1.55
   points are lost (p = 0.066), and it is indistinguishable from the app's
   non-QAT default (+0.30, p = 0.74). It is the most-downloaded QAT MLX build of
   this model, about 369k. Its weights are 7.1% (median) off the QAT grid
   (`scores/dequant-errors-lmstudio.json`), about as far as `default`'s are off
   the original (9.5%).
4. **Rounding shows up as getting stuck,** not only as wrong answers.
   `default` gave no answer on 95 MMLU-Pro questions against 37 for the
   original. `lmstudio` 63, `qat` 44.

## For the app

The faithful QAT build would gain about +1.5 points on knowledge and reasoning
(interval +0.2 to +2.9) and nothing on math. It needs kernels for groups of 32
with their own scale type, a repacker path and device kernel tests. The
straightforward layout (MLX affine, scale and offset per 32) is about 5.0 bits
per weight against today's 4.5, so about 11% more bytes per routed expert. On
the phone, bytes are the largest cost; as arithmetic only, that is several
percent of decode tok/s. A no-offset layout keeps today's size, at the price of
a format of our own.

A faithful MLX build already exists:
`mlx-community/gemma-4-26B-A4B-it-qat-q4_0-mlx-aligned` (groups of 32,
recovered QAT scales, BF16 router, 366 downloads). Its card reports 0.18–0.23%
weight error against the QAT checkpoint and KL 0.090 against 0.277 for the
standard conversion. It is not run here; `qat` stands in for it.

Not measured, and a possible alternative: better 4-bit quantization of the
original (AWQ, GPTQ, DWQ) at today's layout, which needs no kernel work.

## Caveats

- **These are the weights, not the phone.** vLLM computes in BF16; the
  runtime uses its own kernels and FP16 activations. `default` and `lmstudio`
  are their 4-bit weights expanded exactly (w = q · scale + bias in float32,
  rounded once to BF16).
- **One greedy run per model.** Greedy is deterministic, but small arithmetic
  differences change near-tied tokens, so a re-run would move individual
  questions. The paired intervals cover sampling of questions, not that.
- **MMLU-Pro is a sample,** the first 143 per subject (2,002 of 12,032). The
  full set would narrow the intervals by about 2.4×. The `qat` − `lmstudio`
  gap is the one that would benefit.
- **The 2,048-token cap** turns a slow but correct reasoner into a wrong
  answer. It counts against the models that ramble, which is what users of a
  capped reply see too, but it is a property of the setup.
- **Global-MMLU is unscored.** The harness scores the likelihood of a bare
  letter as the reply's first token, and Gemma 4 does not answer that way
  unprompted (every letter at log-probability −12 or lower in the sample
  checked). So scores sat at 29–44% with four choices, near chance. The raw
  files are on the cluster. A rescoring job that asks for the letter is in
  `jobs/mc.job`, not run.
- **The image** is `vllm/vllm-openai:v0.32.0-cu129` with a stub for its CUDA 13
  `torchcodec` (`jobs/shim/`), which only affects audio.

## Cost

About 1.1 GPU-hours on the H100 (the benchmark about 40 minutes, then the
fourth model and the smoke tests), plus a few CPU jobs: two image pulls (the
first timed out), the expansions and the download.

## Files

- `jobs/`: every job and script, as run.
- `scores/`: lm-eval's result files per model and test, the dequantization
  error lists, the smoke test.
- `logs/`: the Slurm logs.
- The per-question samples (about 190 MB) stay on the cluster's scratch
  storage, which deletes files 14 days after they are written:
  2026-11-22.
