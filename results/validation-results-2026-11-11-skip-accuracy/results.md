# Results: what expert skipping costs in accuracy, on 3,321 graded questions

Scored against [predictions.md](predictions.md), written and committed
(`b46bda4`) before any run on the model. One H100 94 GB (driver 615.71.09),
2026-11-11. Jobs:

- 29128242: `off`;
- 29128245: `0.08`, MMLU-Pro. It hit its 6-hour limit in GSM8K, at 897 of
  1,319 questions;
- 29137372: `0.08`, GSM8K alone, rerun with `ONLY=gsm8k`. The batches are the
  same, since each task is sorted on its own;
- 29128247: `0.10`.

The scripts are in [`jobs/`](jobs/). The scorer is [`jobs/score.py`](jobs/score.py),
and its full output is [score-output.txt](score-output.txt). Every question's
grade and simulated counters, per arm, are in
[per-question.tsv](per-question.tsv). lm-eval's score files and the cache
totals are in [`scores/`](scores/), and the job logs in [`logs/`](logs/).

## In short

- **MMLU-Pro: no cost this run can see.** `0.08` measured −0.55 points
  (−1.67 to +0.57) and `0.10` −0.25 (−1.39 to +0.89).
- **GSM8K: `0.08` cost −1.06 points (−1.76 to −0.37), p 0.004.** This is
  strict match, the metric the predictions named, and the one significant
  difference in the run. `0.10` measured −0.45 (−1.15 to +0.24, p 0.29).
- **About half of that loss is formatting.** 8 of `0.08`'s 18 losses are
  right answers written as "16.00" for 16. Strict match compares strings, so
  it counts them wrong. Graded by value instead (after the fact, not
  predicted), `0.08` − `off` is −0.45 (−1.01 to +0.10, p 0.18). Of the
  other 10 losses:
  - 4 replies keep re-reading the problem until they hit the 1,024-token cap;
  - 6 reach a wrong number.
- **Against one INT4 rounding:**
  - on MMLU-Pro, both thresholds stay well under it. The rounding cost −3.75
    points (−2.45 to −5.04), and the worst end of either skipping interval
    is −1.67;
  - on GSM8K, the rounding cost 0.00 by strict match, so `0.08` costs more
    there than the rounding did.
- **`0.10` was no worse than `0.08` on either task:** +0.30 on MMLU-Pro
  (p 0.68) and +0.61 on GSM8K (p 0.15).
  - The cost does not rise with the threshold at this resolution.
  - Both thresholds change most replies: of 1,319 GSM8K replies, 314 at
    `0.08` and 144 at `0.10` were identical to `off`'s.
  - Which questions flip looks like a draw. Only 7 of `0.08`'s 18 GSM8K
    losses were also lost at `0.10`.
- **The simulation is the app.**
  - It matched the phone's footers to 0.13 hit-rate points and 0.7% in
    dropped per layer.
  - Its `off` arm matched vLLM to −0.50 / +0.15 points on the same
    questions.
- **The cache side, simulated.** Foreground reads are the misses the early
  read did not cover, the reads skipping can remove.
  - `0.08` cut foreground reads per token by 38.4% (MMLU-Pro) and 36.9%
    (GSM8K);
  - `0.10` cut them by 62.4% and 61.4%;
  - 0.10's speed on the phone is still unmeasured.

Every predicted range held except one: `0.08` left 11 GSM8K replies without
an answer against `off`'s 8. That is 1.38×, over the 1.3× allowed. The
`0.08` GSM8K cost did land inside its range, −1.2 to +0.6, but at 3.5 times
the point estimate, and significant. The `0.10` point estimates were too
pessimistic on both tasks.

## The gate: the simulation against the phone

Before any arm ran, [`jobs/teacher.py`](jobs/teacher.py) teacher-forced the
iPhone 17's six replies from the 2026-11-08 skip A/B through the simulation.
Job 29124369, output [smoke/teacher.json](smoke/teacher.json).

| Case | Arm | Hit rate, phone / sim | Dropped per layer, phone / sim | Early reads used per token, phone / sim | Prefill reads, phone / sim | Top-1 agreement |
| --- | --- | --- | --- | --- | --- | --- |
| short | off | 79.4 / 79.3 | — | 19.40 / 19.38 | 2,171 / 2,163 | 96.9% |
| short | 0.08 | 84.8 / 84.8 | 0.438 / 0.439 | 19.17 / 19.17 | 2,171 / 2,163 | 97.4% |
| medium | off | 76.7 / 76.8 | — | 20.17 / 20.13 | 2,773 / 2,783 | 94.6% |
| medium | 0.08 | 81.5 / 81.5 | 0.486 / 0.489 | 20.80 / 20.78 | 2,773 / 2,783 | 97.1% |
| long | off | 73.2 / 73.3 | — | 21.79 / 21.77 | 3,478 / 3,481 | 96.9% |
| long | 0.08 | 79.0 / 79.0 | 0.538 / 0.535 | 22.07 / 22.11 | 3,478 / 3,481 | 96.8% |

Prompt tokens were equal: 61, 430 and 3,015.

| Prediction | Measured | |
| --- | --- | --- |
| Prompt tokens equal | equal | held |
| Prefill reads within ±2% | −0.37 to +0.36% | held |
| Hit rate within ±1.5 points | within 0.13 | held |
| Early reads used within ±1.5 per token | within 0.05 | held |
| Dropped per layer within ±15% | +0.2, +0.7, −0.6% | held |
| Top-1 agreement 90–98% | 94.6–97.4% | held |

The gate, more than 3 points of hit rate or 30% of drops, was nowhere near.

## Scores

Accuracy on the same questions in every arm. All 2,002 MMLU-Pro and 1,319
GSM8K prompts were byte-identical across the arms and vLLM's run (lm-eval's
`prompt_hash`, 0 differences). MMLU-Pro is scored by `custom-extract`, GSM8K
by `strict-match`. "No answer" counts replies the harness could not extract
an answer from. The reply length comes from the simulation's own token count.

| | MMLU-Pro (2,002) | no answer | mean reply, tokens | GSM8K (1,319) | no answer | mean reply, tokens |
| --- | --- | --- | --- | --- | --- | --- |
| vLLM `default` (QAT study) | 77.97% | 95 | — | 94.16% | 6 | — |
| `off` | **77.47%** | 106 | 653 | **94.31%** | 8 | 256 |
| `0.08` | **76.92%** | 111 | 662 | **93.25%** | 11 | 258 |
| `0.10` | **77.22%** | 112 | 662 | **93.86%** | 10 | 260 |

## Paired differences

Points of accuracy, with 95% intervals from the per-question differences and
exact McNemar tests. "Gained / lost" counts questions right in one arm only.

| Task | Comparison | Difference | 95% interval | Gained / lost | p |
| --- | --- | --- | --- | --- | --- |
| MMLU-Pro | `0.08` − `off` | **−0.55** | −1.67 to +0.57 | 60 / 71 | 0.382 |
| MMLU-Pro | `0.10` − `off` | **−0.25** | −1.39 to +0.89 | 65 / 70 | 0.731 |
| MMLU-Pro | `0.10` − `0.08` | +0.30 | −0.88 to +1.47 | 75 / 69 | 0.677 |
| MMLU-Pro | `off` − vLLM | −0.50 | −1.56 to +0.56 | 54 / 64 | 0.407 |
| GSM8K | `0.08` − `off` | **−1.06** | −1.76 to −0.37 | 4 / 18 | 0.004 |
| GSM8K | `0.10` − `off` | **−0.45** | −1.15 to +0.24 | 8 / 14 | 0.286 |
| GSM8K | `0.10` − `0.08` | +0.61 | −0.12 to +1.33 | 16 / 8 | 0.152 |
| GSM8K | `off` − vLLM | +0.15 | −0.36 to +0.67 | 7 / 5 | 0.774 |

About 6.5–7.2% of MMLU-Pro questions were discordant between two arms, close
to the 8% the predictions assumed. So the intervals came out at ±1.1 to ±1.2
points, as planned.

## The predictions, scored

| Quantity | Predicted | Measured | |
| --- | --- | --- | --- |
| `off`, MMLU-Pro | 76.5–79.5% | 77.47% | held |
| `off`, GSM8K | 93.0–95.3% | 94.31% | held |
| `off` against vLLM | within ±1.5 points | −0.50 / +0.15 | held |
| `0.08` − `off`, MMLU-Pro | −1.0 (−2.5 to +0.5) | −0.55 | held |
| `0.10` − `off`, MMLU-Pro | −1.5 (−3.5 to 0.0) | −0.25 | range held; point estimate 1.25 too pessimistic |
| `0.08` − `off`, GSM8K | −0.3 (−1.2 to +0.6) | −1.06 (p 0.004) | range held, by 0.14 points; 3.5× the point estimate, and significant |
| `0.10` − `off`, GSM8K | −0.5 (−1.5 to +0.5) | −0.45 | held |
| `0.10` − `0.08`, GSM8K | not predicted | +0.61 (p 0.15) | — |
| `0.10` − `0.08`, MMLU-Pro | −0.5 (−2.0 to +1.0) | +0.30 | held |
| `32-0.08` − `0.08` | 0 to +1.0 | not run | — |
| No extracted answer, within 1.3× of `off` | | MMLU-Pro 1.05× / 1.06×; GSM8K 1.38× / 1.25× | **miss** at `0.08` on GSM8K (11 against 8); the rest held |

**`0.10` on MMLU-Pro.** I expected the cost to rise with the threshold, from
about −1.0 to −1.5. It measured −0.55 and −0.25, and the two differ by less
than their noise. At 2,002 questions, 0.10 cannot be told apart from 0.08. That is not evidence that 0.10 is better. The scaling I used,
roughly linear in KL (0.55× and 0.94× of a rounding), is not supported at
this resolution either.

**The 32-slot arm was not run.** The rule was to run it only if an arm ran
under 2.5 hours. The arms took 5.7–6.0 hours.

### Controls

| Quantity | Predicted | Measured | |
| --- | --- | --- | --- |
| Prompts per question across arms | byte-identical | 0 differences, vLLM included | held |
| Early reads issued per decode forward | exactly 29 | 29.00 in every run | held |
| `off`'s dropped experts | exactly 0 | 0 | held |
| `off`, decode hit rate | 72–80% | 77.0% / 75.1% | held |
| Hit rate, `0.08` − `off` | +4 to +7 points | +5.8 (MMLU-Pro) / +6.1 (GSM8K) | held |
| Foreground reads per token, `0.08` | −30 to −45% | −38.4% / −36.9% | held |
| Foreground reads per token, `0.10` | −45 to −65% | −62.4% / −61.4% | held |
| Dropped per layer, `0.08` | 0.42–0.62 | 0.524 / 0.571 | held |
| Dropped per layer, `0.10` | 0.65–1.00 | 0.882 / 0.974 | held |

The simulated cache per decode forward:

| Task | Arm | Hit rate | Foreground reads / token | Early reads used / token | Dropped / layer | Dropped weight / layer |
| --- | --- | --- | --- | --- | --- | --- |
| MMLU-Pro | `off` | 77.0% | 36.37 | 18.72 | 0 | 0 |
| MMLU-Pro | `0.08` | 82.8% | 22.40 | 18.86 | 0.524 | 0.0310 |
| MMLU-Pro | `0.10` | 86.3% | 13.69 | 19.08 | 0.882 | 0.0624 |
| GSM8K | `off` | 75.1% | 39.97 | 19.75 | 0 | 0 |
| GSM8K | `0.08` | 81.2% | 25.23 | 20.01 | 0.571 | 0.0339 |
| GSM8K | `0.10` | 85.2% | 15.44 | 20.15 | 0.974 | 0.0693 |

`0.10` drops about 1.7 times as many experts as `0.08`, and about twice the
router weight. Its foreground reads per token are 39% below `0.08`'s
(MMLU-Pro). Foreground reads are what `io` waits on, so this is
why 0.10 may be worth a phone A/B: the simulation says it costs nothing
measurable here, and it removes 8.7 more reads per token.

## The GSM8K loss at `0.08`, looked at

This analysis was added after the scores were seen. It is not predicted, and
it does not replace the strict-match score. `score.py` prints it.

**The 18 questions `off` got right and `0.08` got wrong:**

- **8 are right in value.** The reply ends "The final answer is 16.00" where
  the target is 16, for example in docs 27 and 36. `off` had written "$16.00"
  in the text, then "16" on the answer line.
- **4 ran out of tokens** at the 1,024 cap (docs 527, 534, 1190 and 1191).
  Each loops on "Let's re-read" or "Let's try another way". `off` had
  answered these in 198–415 tokens.
- **6 reach a wrong number** (docs 267, 406, 926, 990, 1082 and 1297).

Answers written with a decimal point turn up in every run: 27 in `off`, 35
in `0.08`, 34 in `0.10` and 33 in vLLM's. So the formatting flips look like
a side effect of replies drifting apart, not a habit that skipping
introduces. Which way they fall decides a good part of the strict-match gap.

Graded by value, the strict-match answer counts if it equals the target as a
number:

| | `off` | `0.08` | `0.10` | vLLM `default` |
| --- | --- | --- | --- | --- |
| GSM8K, by value | 96.21% | 95.75% | 96.29% | 96.44% |

| Comparison | Difference | 95% interval | Gained / lost | p |
| --- | --- | --- | --- | --- |
| `0.08` − `off` | −0.45 | −1.01 to +0.10 | 4 / 10 | 0.180 |
| `0.10` − `off` | +0.08 | −0.50 to +0.65 | 8 / 7 | 1.000 |
| `0.10` − `0.08` | +0.53 | −0.08 to +1.14 | 12 / 5 | 0.143 |
| `off` − vLLM | −0.23 | −0.62 to +0.17 | 2 / 5 | 0.453 |

What is left at `0.08` is the 4 truncated loops and 6 wrong numbers, against
4 gained. That is a cost of up to about 1 point, which this run cannot tell
apart from zero.

## What would have falsified it

- **The simulation:** the gate. Not triggered, see above.
- **The size:** `0.08` − `off` worse than −2.5 MMLU-Pro points or −1.2 GSM8K.
  Measured −0.55 and −1.06. Not triggered, though GSM8K came within 0.14
  points.
- **The order:** `0.10` better than `0.08` with p < 0.05. Measured +0.30
  (p 0.68) on MMLU-Pro and +0.61 (p 0.15) on GSM8K. Not triggered.
- **The baseline:** `off` more than 1.5 points from vLLM. Measured −0.50 and
  +0.15. Not triggered.

## What it decides

Nothing by itself; the defaults are the user's call. The run adds:

- **A paired accuracy cost for `0.08`**, on 3,321 questions:
  - MMLU-Pro: no difference beyond the noise, and the interval rules out a
    cost larger than 1.67 points;
  - GSM8K: −1.06 points by strict match, significant. About half of it is
    answer formatting, and by value it is −0.45 (not significant).
- **For `0.10`, no significant cost on either task:** −0.25 on MMLU-Pro and
  −0.45 on GSM8K. Its interval rules out an MMLU-Pro cost larger than 1.39
  points.
- **Against one INT4 rounding,** both thresholds are well under its −3.75
  MMLU-Pro points. On GSM8K the rounding cost nothing by strict match, and
  `0.08` did cost something.
- **Neither threshold is shown better than the other.** On both tasks, the
  point estimates favour `0.10`, the faster setting.
- **Nothing on 32 slots.** That arm was not run.

## Limits

These are as in the predictions:

- **Simulated, not run on the phone.** The arithmetic differs: BF16 here,
  FP16 on the phone.
- **Greedy decoding.** The app samples at T 0.2.
- **A fresh cache for every question.**
- **Context.** Some prompts plus replies exceed the app's 4,096-token
  default.

And from the run itself:

- **`0.08`'s GSM8K ran in its own process** (29137372). It used the same code,
  the same batches and the same expected-length order. The only change was the
  `ONLY` filter, which skips MMLU-Pro. Whether the HF pipeline gives
  identical replies across processes was not tested. A rerun of `off`'s GSM8K
  alone, about 1.1 GPU-hours, would settle it. It matters because the one
  significant result is in this arm.
- **Cost:** about 19.7 GPU-hours on the H100. The three arms took 17.7 hours,
  the six smoke jobs 0.9 and the GSM8K rerun 1.1. That is about 2.2 times
  the bad case I estimated beforehand. The simulation decoded at 72–75
  tokens/s at batch 64 on MMLU-Pro, and the long MMLU-Pro batches ran at
  about 0.7 s per step.
- **What took four smoke jobs:**
  - out of memory three times: the expert matmul, attention, and a norm over
    the whole batch's prefill;
  - a missing import;
  - recomputed router weights, which made the self-check differ from plain HF
    generate on 2 of 4 rows. Rows with no drop now keep HF's own weights;
  - sliding-window cache views that kept the whole prompt allocated.

  The last smoke job (29127417) passed its self-check, identical on 4 of 4
  rows. I cancelled it to sort batches by expected reply length, which saved
  about 60% of the MMLU-Pro decode steps.
