# Expert skipping, graded answers on the phone: predictions

Written 2026-11-08, before any run. The change is `--expert-skip miss:0.08`. It
gave +32.9 / +18.2 / +26.0% tok/s on the iPhone 17
(`results/benchmark-results-2026-11-08-ios-expert-skip/`). On the Mac it cost
KL 0.0246 per position, 0.55× one INT4 rounding, with top-1 agreement 97.7%
(`results/research-results-2026-10-04-lossy-experts/`).

That KL is teacher-forced. It prices each next-token prediction, but never lets
a changed token steer the rest of the reply. This check lets it. The model
solves problems with checkable answers, with and without skipping, and the
answers are graded.

## Protocol

- **Problems:** GSM-Symbolic P2 (`apple/GSM-Symbolic`, `p2/test.jsonl`, SHA-256
  `00496e6c…`, CC BY-NC-ND 4.0, so it is not committed). These are GSM8K
  templates with new names and numbers and two extra clauses each, built to
  resist training-set contamination. The set is instance 0 of each of the 50
  templates. [`make_prompts.py`](make_prompts.py) writes one prompt per
  problem. Each prompt asks for step-by-step work and a last line
  `Final answer: <number>`.
- **Phone:** iPhone 17, with the app at `5f5c281` already installed (the build
  from the speed A/B). The settings are `--slots 24 --max-new 1024
  --max-context 4096` with chunk `auto`, and sampling is the harness default
  (T 0.2, seed 1).
- **Arms:** one `--session` of all 50 per arm, on one loaded model, each
  problem from an empty KV, as the app runs chats.
  - A: defaults.
  - B: adds `--expert-skip miss:0.08`.
  - [`run.sh`](run.sh) runs A, then B.
- **Grading:** [`grade.py`](grade.py) takes the number on the last
  `Final answer` line, falling back to the last number in the reply, and
  compares it to the dataset answer within a relative 1e-4.
  - Pairs are compared by problem, with an exact McNemar test on the
    problems one arm gets right and the other wrong.
  - It also reports where each pair of replies first differs.

**What it can show:** 50 pairs can detect a drop of about 10 points (5
problems). They cannot separate differences of 1–3 problems. A problem the arms
disagree on is not by itself damage: sampling a different path through a reply
can flip an answer either way. The net count is the measure.

## Predictions

| Quantity | Predicted |
| --- | --- |
| A accuracy | 30–45 of 50 (60–90%). P2 is hard, and this model's P2 score is unmeasured. |
| B − A, net problems right | **−3 to +2** |
| Problems the arms disagree on | 2–10 |
| Pairs with identical text | 0–3 |
| First differing character, median over pairs | 50–400 |
| Replies without a `Final answer` line, or stopped at `maxTokens` | B within 1 of A |
| Decode tok/s, B against A | +15 to +35% (a by-product; the run is not cooled for timing) |

**Mechanism:**

- **Why the texts diverge:** at 97.7% top-1 agreement, a reply diverges after
  about 40–45 tokens. So nearly every pair differs, and most differ early.
- **Why accuracy should hold:** after the first difference, B continues from
  its own text with per-step damage of half an INT4 rounding. That should
  behave like another sample from nearly the same model, which reaches the
  same answer about as often.
- **Why disagreements should balance:** they should come in both directions,
  at about equal numbers.

## What would falsify it

- **B gets 5 or more fewer problems right than A.** At this size that is the
  first difference the test can show. It would mean the damage compounds once a
  reply drifts, which KL cannot see.
- **B has at least 2 more broken replies than A:** no final answer, a
  `maxTokens` stop, repetition, or a language switch.
- **B gets 3 or more more problems right than A.** That is not plausible for
  dropping experts, and would point at the grading or the setup.
