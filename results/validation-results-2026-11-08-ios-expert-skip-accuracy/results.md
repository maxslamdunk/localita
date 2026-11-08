# Results: expert skipping, graded answers on the phone

Scored against [`predictions.md`](predictions.md), committed first in
`d7b8c05`. The phone build is `5f5c281`. [`run.sh`](run.sh) ran both arms, with
its log in [`driver.log`](driver.log). Logs and replies are in [`logs/`](logs/).
[`grade.py`](grade.py) graded them, saved in
[`grade-output.txt`](grade-output.txt), and [`summarize.py`](summarize.py)
pooled the footers, saved in [`summary-output.txt`](summary-output.txt). The
problems themselves are not here: GSM-Symbolic is CC BY-NC-ND 4.0.
[`make_prompts.py`](make_prompts.py) rebuilds the prompts from the dataset file
and checks its SHA-256.

## Answer

**Skipping cost nothing measurable in task accuracy. Each arm solved 47 of 50
problems.** The arms disagreed on 2 problems, one each way (exact McNemar
p = 1.000), and both failed the same 2.

- The one problem B lost was a reply that ran out of tokens while weighing two
  readings of an ambiguous clause.
- The one problem A lost was an arithmetic slip.

**What it cannot show:** a loss of 1–3 problems in 50. It rules out the
falsifying loss of 5 or more, and a loss that compounds once a reply drifts
would have shown up there. With A at 47, the test can see drops but has
almost no room to see gains.

| | A, defaults | B, `miss:0.08` |
| --- | --- | --- |
| Right | **47 of 50** | **47 of 50** |
| Stops | 49 `endOfTurn`, 1 `maxTokens` | 48 `endOfTurn`, 2 `maxTokens` |
| No `Final answer` line | 1 (`gsmp2-33`) | 2 (`gsmp2-33`, `gsmp2-45`) |
| New tokens, mean | 498 | 505 |
| Decode tok/s (not cooled; see below) | 5.057 | 5.516 (+9.1%) |

## What was run

The build is `5f5c281` in Release, the one installed for the speed A/B in
`results/benchmark-results-2026-11-08-ios-expert-skip/`. Each arm was one
`--session` of all 50 problems on one loaded model, each problem from an empty
KV, at `--slots 24 --max-new 1024 --max-context 4096`, chunk `auto`, with the
harness's sampling (T 0.2, Top-K 64, Top-P 0.95, seed 1).

- **A:** defaults, `expertSkip=off`. Log stamp `2026-11-08T070929Z`, 08:09 to
  09:39 CET.
- **B:** `--expert-skip miss:0.08`. Log stamp `2026-11-08T084120Z`, 09:41 to
  11:05 CET, after a 120 s pause.

Both `runner-ready` lines name the arm and the bundled fitted guess
(`@b18242445534d452…`). The phone was at 100% and full throughout.

- **The problems:** instance 0 of each of the 50 GSM-Symbolic P2 templates
  (`p2/test.jsonl`, SHA-256 `00496e6c…`).
- **Thermal:** A had 1,217 `serious`, 199 `fair` and 261 `nominal` samples. B
  was `serious` at all 1,698 samples. The phone went into B already hot.

## Predictions, scored

| Quantity | Predicted | Measured | Verdict |
| --- | --- | --- | --- |
| A accuracy | 30–45 of 50 | **47** | miss, above the range |
| B − A, net problems right | −3 to +2 | **0** | hit |
| Problems the arms disagree on | 2–10 | 2 | hit, at the low edge |
| Pairs with identical text | 0–3 | 2 | hit |
| First differing character, median | 50–400 | 197 (quartiles 74–451) | hit |
| Broken replies, B against A | B within 1 of A | 2 against 1 | hit, at the edge |
| Decode tok/s, B against A | +15 to +35% | +9.1% | miss, below the range |

**Falsifiers:** none fired. B got 0 fewer problems right, not 5 or more. It had
1 more broken reply, not 2 or more. It did not get 3 or more extra problems
right.

**The two misses:**

- **A accuracy** was underestimated: this model solves P2 better than assumed.
  It makes the test blind to gains, but not to the losses it was built to
  catch.
- **tok/s** is a by-product of a run that was not cooled, and B ran entirely at
  `serious`. The footers separate the two effects:

  | per forward, pooled over 50 | A | B | change |
  | --- | --- | --- | --- |
  | `io`, ms | 109.22 | 70.71 | −38.5 ms (−35.3%) |
  | `cb1-wait`, ms | 68.47 | 85.58 | +17.1 ms (+25.0%) |
  | `head`, ms | 11.59 | 13.82 | +2.2 ms (+19.3%) |
  | wall, ms | 198.16 | 181.66 | −16.5 ms (−8.3%) |
  | foreground reads/tok | 38.52 | 24.36 | −36.7% |
  | bytes/tok (footer MB) | 216.26 | 170.93 | −21.0% |
  | hit rate | 76.1% | 82.0% | +5.8 pt |
  | decode read mean, ms | 4.75 | 3.95 | −16.7% |

  The read-side figures land where the speed A/B put them: foreground reads
  −36.7% against −33.7 to −42.3% there, and `io` −35.3% against −25.5 to
  −34.7%. The GPU phases, which skipping does not touch, got 19–25% slower. That
  is a hot phone's GPU, and it ate half the `io` saving. The speed A/B, with
  cooldowns and A B B A order, stays the speed figure.

**Controls:** 29.00 early reads per token in all 100 problems. B dropped 0.531
experts and 0.031 of router mass per layer over the session, between the speed
A/B's medium and long cases.

## The problems the arms did not share

- **`gsmp2-45`, B lost it.** The problem's spacing clause reads two ways. A took
  the reading the dataset uses and answered in 1,883 characters. B worked
  through the other reading first, rejected it, and ran out of its 1,024 tokens
  partway through the second. The grader fell back to the last number in the
  reply, so B is scored wrong. B's reasoning was sound up to the cut; it ran
  out of room.
- **`gsmp2-47`, A lost it.** Both arms set the problem up the same way. A added
  `15 + 6 + 3` as 21 and answered 21. B added it correctly and answered 18.
- **`gsmp2-33`, both failed.** The problem is ill-posed as written: read
  literally, one sister's weekly rate turns negative, and the dataset's own
  answer reads "reducing her weekly collection by 5" as "collects 5 a week".
  Both arms tried readings until they ran out of tokens.
- **`gsmp2-25`, both failed.** Both answered 56 against 59.

So the one extra broken reply in B is a reply that ran out of room on an
ambiguous problem, not repetition or a language switch. A scan of all 100
replies found no line of over 20 characters repeated more than twice, and no
Cyrillic, CJK or Arabic characters.

## What it says

**Free-running accuracy agrees with teacher-forced KL.** The Mac priced
`miss:0.08` at 0.55× of one INT4 rounding in KL, per position. Here, once
skipping changes a token and the reply continues from its own text, the answer
is still right as often. The replies diverge early, at a median of 197
characters, yet the answers come out the same. B behaves like another sample
from the same model, as predicted.

**What is still unmeasured:**

- Accuracy differences of 1–3 problems in 50. A 200-problem run would
  narrow that, at about 6 hours of phone time per arm (1.6–1.75 minutes per
  problem here).
- Other kinds of task. This is arithmetic word problems in English. The speed
  A/B's long prompts were read, not graded.
- Long contexts. These replies run to about 700 tokens of context.

## Disposition

**`miss:0.08` stays an opt-in research switch, off.** Whether it becomes the
default is the user's quality decision (AGENTS.md, "What is open"). The
evidence for that decision is now:

- +18 to +33% tok/s on the phone;
- 0.55× of one INT4 rounding in teacher-forced KL on the Mac;
- no measurable loss on 50 graded problems.
