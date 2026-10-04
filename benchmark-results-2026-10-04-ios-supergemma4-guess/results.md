# Results: supergemma4 on the iPhone, fitted guess against the router

Scored against [`predictions.md`](predictions.md), committed first in
`db63f0c`. The phone build is `db63f0c`. Logs and texts are in
[`logs/`](logs/), the driver is [`run.sh`](run.sh) ([`driver.log`](driver.log)),
and [`summarize.py`](summarize.py) prints every figure below
([`summary-output.txt`](summary-output.txt)).

## Answer

**gemma4's fitted guess does for supergemma4 on the phone what it did for
gemma4. The output is identical.**

- **Precision:** the guess is right more often on every case, from **0.530 /
  0.555 / 0.597** to **0.657 / 0.698 / 0.746**.
- **Bytes:** bytes/token fell **−11.8 / −13.3 / −13.8 MB**, and reads/token
  fell by exactly the rise in used early reads.
- **Speed:** tok/s rose **+4.4 / +11.3 / +2.9%**, but medium's figure is
  mostly GPU speed. Its two N runs had a slow GPU and its two F runs a fast
  one: head GPU time 9.93 against 8.15 ms. Where GPU speed matched (long,
  head 8.33 against 8.46 ms), the gain was **+2.9%**. Short was +4.4% at a
  5% head difference.

| case | tok/s N → F | `io` ms/fwd | bytes/tok (footer MB) | precision N → F | head GPU ms N → F |
| --- | --- | --- | --- | --- | --- |
| short | 6.784 → **7.085 (+4.4%)** | 83.79 → 81.64 (−2.14) | 198.14 → 186.38 | 0.530 → 0.657 | 8.47 → 8.04 |
| medium | 5.719 → **6.365 (+11.3%)** | 90.59 → 88.73 (−1.87) | 218.67 → 205.36 | 0.555 → 0.698 | 9.93 → 8.15 |
| long | 5.591 → **5.752 (+2.9%)** | 103.34 → 98.19 (−5.15) | 240.65 → 226.81 | 0.597 → 0.746 | 8.33 → 8.46 |

N is the next layer's router, which is what supergemma4 runs on main. F is
the default on this branch: gemma4's shipped file, picked up through the new
`index.json` entry. Figures are means of two runs per arm.

**These are supergemma4's first phone figures.** F is what supergemma4 will
run by default once this branch merges: **7.085 / 6.365 / 5.752 tok/s**, with
hit rates 79.9 / 76.9 / 73.6%. Don't compare them with the gemma4 table in
`CLAUDE.md`. That table predates the early read, `F_NOCACHE` and count aging,
all of which are on here.

## What was run

The branch `supergemma4-next-layer-guess` at `db63f0c`, built in Release and
installed over the app. It is one binary. Every run is pinned to
`supergemma4.gturbo` with `--model-dir`. N adds `--early-expert-guess router`.
Every F log's `runner-ready` line names
`gemma-4-26b-a4b-it-4bit.bin@b1824244…`, and every N log says `router`. The
early read, count aging and `F_NOCACHE` are on in both arms.

Each case ran N F F N with 300 s cooldowns, on 2026-10-04 from 02:29 to 04:30.
iPhone 17, iOS 26.6, battery 100% full. Thermal was `nominal` for every short
and medium sample. The long runs were partly `fair`: N1 37 of 40 samples, N2
35, F2 23, F1 0.

**One failed run.** The first long F1 exited about 80 s after launch, after
decode token 48. Its footprint was 3.23 GB with 3.2 GB still available, and
the phone has no crash, jetsam or resource report for it. The cause is
unknown. Its log is in [`logs/failed/`](logs/failed/), and it has a row in
`MEASUREMENTS.md`. Long F1, F2 and N2 were rerun from 04:10, after the phone
had rested 32 minutes. The first rerun attempt idled through the skipped
labels' cooldowns and was stopped before it launched anything. `run.sh` now
skips without cooling down.

## Scoring

**P1, identical work: held for the work. The peak-footprint control missed on
one run.**

- Every case's four texts share one hash: `6a90d4c5…`, `ee39a822…` and
  `236be50a…`.
- Hit rate, req/tok (240.00) and long's prefill bytes (30,554.61 MB) are
  identical across arms.
- Peak footprint was within 1.3 MB across arms on medium and long. On short,
  F1 peaked 19 MB above the other three runs. F2 matched N to 0.3 MB, so the
  extra is not the arm. I count it as a miss of the 2 MB bound rather than
  explain it away.

**P2, live precision: held on all three cases.**

| case | N predicted | N measured | F − N predicted | F − N measured |
| --- | --- | --- | --- | --- |
| short | 0.51–0.59 | **0.530** | +0.10 to +0.17 | **+0.127** |
| medium | 0.53–0.61 | **0.555** | +0.10 to +0.18 | **+0.143** |
| long | 0.57–0.66 | **0.597** | +0.11 to +0.19 | **+0.149** |

As on gemma4, the offline Mac numbers transferred to the phone. Live N sits
0.016–0.019 below the offline per-prompt figures (0.549 / 0.571 / 0.616). The
gains are 0.004–0.005 below the offline per-prompt gains (+0.131 / +0.141 /
+0.154), except medium, which is 0.002 above.

**P3, the arithmetic: held exactly.** Used early reads per token rose +3.67 /
+4.15 / +4.32, against point predictions of +3.8 / +4.1 / +4.5. Reads per
token fell −3.67 / −4.16 / −4.32. bytes/token fell −11.76 / −13.31 /
−13.84 MB, inside every range.

**P4, `io` −4 to −15 ms: missed on short and medium, held on long.** `io` fell
−2.14 / −1.87 / −5.15 ms. That is 0.58 / 0.45 / 1.19 ms of `io` per extra
used read. gemma4's fitted-guess A/B saved 2.21 / 3.66 / 1.61 ms per read
(its results.md: `io` −8.57 / −14.94 / −6.84 over −3.88 / −4.08 / −4.25 reads).
Mean time per read is the same in both arms here (3.57–3.94 ms), so each
read's cost did not change. Fewer reads simply took less `io` off than
before. Two things changed since the gemma4 A/B, and both are on in these
runs: `F_NOCACHE` and count aging. I can't separate them, or rule out
supergemma4 itself, from this data. See [What is open](#what-is-open).

**P5, tok/s +2 to +9%: held on short and long, above the range on medium.**
The falsifier, tok/s falling on two or more cases at matched GPU speed, did
not fire: tok/s rose on every case. Medium's +11.3% comes with an 18% faster
head GPU in F. Its `cb1-wait` fell 13 ms, mostly attention and router GPU
time (−7.8 ms), which a guess file cannot change. So medium is not evidence
of a larger gain.

## Decision

Under `predictions.md`'s rule (P1 holds, and P2 and P3 hold on at least two
cases), **the branch merges.** The text, hit rate and req/tok controls held
on every case. The one peak-footprint blip was a single run that its own
twin did not repeat. P2 and P3 held on all three. supergemma4 then uses
gemma4's guess file by default, with no new bytes in the app.

## What is open

- **Why a used early read saves less `io` than it did on 2026-10-03.** The
  data here can't settle it. One A/B could: the same N/F pair on gemma4 with
  aging off, then with `F_NOCACHE` off. The answer matters for any future
  early-read work, such as two reads per layer, because it says how much `io`
  a correct guess still buys.
- **What the failed long F1 was.** One unexplained exit in thirteen runs, with
  no system report. Watch for a repeat.
