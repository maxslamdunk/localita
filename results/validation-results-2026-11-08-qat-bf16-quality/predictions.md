# Predictions: Google's QAT checkpoint against the original, and the app's default 4-bit build

Written before any benchmark run, on 2026-11-08. The only runs before it were
a five-prompt smoke test of the two BF16 checkpoints (job 28996287),
with all five answers correct on both.

## The question

Should the app move to a 4-bit build made faithfully from Google's QAT
checkpoint? That build needs a new weight format (groups of 32, an FP16 scale,
no offset), new kernels and device kernel tests. It is worth building only if
the QAT checkpoint is as good as the original, and better than what the app
ships today.

Unsloth's `gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf` is all Q4_0 and matches the
QAT checkpoint in 99.79–99.98% of values, so the QAT checkpoint's score stands
in for a faithful 4-bit QAT build. The QAT MLX builds that exist (LM Studio's,
mlx-community's) re-round onto groups of 64 and match only 17–30% of values.
They are not measured here.

## The models

| Label | Weights | Revision |
| --- | --- | --- |
| `original` | `google/gemma-4-26B-A4B-it`, BF16 | `4d7ae49` |
| `qat` | `google/gemma-4-26B-A4B-it-qat-q4_0-unquantized`, BF16 | `f1e06dc` |
| `default` | the app's `mlx-community/gemma-4-26b-a4b-it-4bit`, dequantized to BF16 | `0d77464` |

`default` is expanded by `dequant_mlx.py`: w = q · scale + bias per group, in
float32, rounded once to BF16. It gets the original's config, tokenizer and
chat template, so the three models differ only in weights. That measures the
weights. It does not measure the phone runtime's arithmetic (FP16 activations,
its own kernels).

## The setup

- One H100 94 GB, `vllm/vllm-openai:v0.32.0-cu129` as an Apptainer
  image (transformers 5.19.0). A stub hides the image's CUDA 13 `torchcodec`,
  which cannot load. It is audio only.
- lm-evaluation-harness 0.4.13, chat template on, thinking off (the template's
  default), greedy decoding (`temperature=0` on every request). The
  checkpoint's generation config stays loaded for its end-of-turn stop
  tokens; its sampling defaults (temperature 1.0, top-k 64) do not apply.
- Tasks, with names and sizes confirmed by the preparation job (job
  28996986) before the run:
  - **MMLU-Pro**, 5-shot chain of thought, up to 2,048 generated tokens, the
    first 143 questions of each of the 14 subjects (2,002 of 12,032);
  - **GSM8K**, `gsm8k_cot_llama`, 8-shot chain of thought as multi-turn, up
    to 1,024 generated tokens, all 1,319;
  - **Global-MMLU-Lite**, zero-shot multiple choice scored by likelihood, 400
    each in Chinese, Spanish, German, French, Japanese, Arabic and Hindi;
  - **Russian**, which Lite lacks: `global_mmlu_full_ru`, the first 7 of each
    of 57 subjects (399 of 14,042). It is reported with the Lite languages
    and on its own.
- `default`'s expansion: 297 tensors differ from `original` (relative error
  median 9.5%, range 0.7% for the 8-bit router to 11.5%); the other 716
  (norms, vision tower, scalars) are byte-identical.
- Every sample is logged, so differences are scored per question, paired.

## Noise

At these sizes one model's accuracy has a standard error of about 0.8–0.9
points (MMLU-Pro, GSM8K). A paired difference between two close models is
smaller, about 0.5–0.8 points; it will be computed from the logged samples
(McNemar). **A gap under about 1.5 points is not a finding.**

## What moves

| Comparison | MMLU-Pro | GSM8K | Global-MMLU, mean of 8 languages |
| --- | --- | --- | --- |
| `qat` − `original` | −0.5 (−1.5 to +0.5) | −0.5 (−1.5 to +0.5) | −1.0 (−2.0 to +0.5) |
| `default` − `original` | −2 (−3 to −1) | −1.5 (−2.5 to −0.5) | −2.5 (−4 to −1) |
| `qat` − `default` | +1.5 (+0.5 to +3) | +1 (0 to +2) | +1.5 (+0.5 to +3) |

Points of accuracy.

## The controls

- **Identical prompts.** The harness records each question's prompt. They
  must be byte-identical across the three models, because all three use the
  same tokenizer and chat template.
- **`original`'s absolute scores** are only a sanity check against Google's
  model card. The harness and prompts differ, so this is not a prediction.

## The mechanism

- **QAT** is the original trained further to tolerate 4-bit rounding. At
  BF16 it should lose a little, mostly from the co-adapted scale changes
  measured on its weights (logits about 0.89×, which acts like a slightly
  higher temperature, and changed norms).
- **The default build** is the original rounded to the nearest 4-bit value
  in groups of 64, with no retraining. Round-to-nearest at 4 bits usually
  costs a point or a few, more in languages other than English.

## What would falsify it

- **QAT is broken:** `qat` more than 3 points below `original` on any of the
  three, significant paired. Then a faithful QAT build is not worth making.
- **Rounding does not matter:** `default` within ±0.5 of `original` on all
  three. Then there is nothing for QAT to win back.
- **QAT does not help:** `qat` − `default` at or below 0 on two of the three.

## The decision it informs

- **`qat` ≈ `original` and `qat` beats `default` by at least 1 point** on
  MMLU-Pro or Global-MMLU-Lite: the faithful QAT format is worth building.
- **`qat` ≈ `default` within noise:** keep the default; the format change
  buys nothing measurable.
- **`qat` clearly below `original`:** QAT is a dead end here. Consider
  better ways to quantize the original instead (AWQ, GPTQ, DWQ).

## Added before its run: LM Studio's QAT build

Added on 2026-11-08 while the three-model job (28997220) ran. By then
`original`'s scores were in (MMLU-Pro 81.7%, GSM8K 94.2%); no score of `qat`,
`default` or this fourth model had been seen.

| Label | Weights | Revision |
| --- | --- | --- |
| `lmstudio` | `lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit`, dequantized to BF16 | `aa5e2e5` |

It is the most-downloaded QAT MLX build (about 369k), and the app accepts it
since 2026-10-13. It is made from the QAT checkpoint by the standard
converter: groups of 64 with a fitted scale and offset, the shared expert and
router at 8 bits. Its expansion is checked against `qat`, not `original`, and
takes `qat`'s config and tokenizer (identical apart from
`transformers_version`).

A faithful MLX build exists, `mlx-community/gemma-4-26B-A4B-it-qat-q4_0-mlx-aligned`
(groups of 32, recovered QAT scales). Its card reports 0.18–0.23% weight error
against the QAT checkpoint, so `qat` stands in for it, and it is not run.

| Comparison | MMLU-Pro | GSM8K | Global-MMLU |
| --- | --- | --- | --- |
| `lmstudio` − `qat` | −1.5 (−3 to −0.5) | −1 (−2 to 0) | unscored |
| `lmstudio` − `default` | +0.5 (−1 to +1.5) | 0 (−1 to +1) | unscored |

**Mechanism.** Re-rounding the QAT grid onto groups of 64 moves weights by
about 7.5–8.2% relative error, about as much as rounding the original moves
`default` (9.5% median). QAT taught the model to tolerate its own grid, not an
arbitrary one, so most of its advantage should be lost; some general
robustness to 4-bit noise may survive, hence a small edge over `default`.

**Falsified if** `lmstudio` is within 0.5 points of `qat` on both MMLU-Pro
and GSM8K: then the re-rounding is harmless on these tasks, and the
unfaithfulness costs nothing measurable.
