# Results: does the in-app download read slower on the iPhone 17?

Predictions are in `predictions.md`, committed first in `ccff8c1`.

## Setup

- **Binary:** the source of `0d8b314`, built Release. It was installed a few
  minutes before that commit, with no source changes in between.
- **Device:** iPhone 17, iOS 26.6, 51.8–52.2 GB free.
- **Copies:**
  - **A** is `gemma4.gturbo`, side-loaded on 2026-09-16.
  - **B** is `gemma4-download.gturbo`, written by the in-app installer
    (`--model-dir`). It finished at 20:23 local, about 1 h before the first
    B run.
- **Protocol:** `--autorun --case short-explanation --slots 24 --max-new 1024
  --max-context 4096`, chunk `auto`. The runs alternated A, B, A, B, A, B,
  5 min apart. Each log's `model-found` line names the copy it read.
- **Checks before the benchmark:**
  - One chat message on B answered sensibly, confirming B loads and runs.
  - A first set of six launches used the case id `short`, which does not
    exist. All six failed within 1 s, before loading anything. They are not
    results and are not recorded as rows.

## Runs

| Run | Copy | tok/s | `io` ms/fwd | Fetch GB/s | `cb1-wait` | Wall | Compressions/s | Thermal |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | side-loaded | 5.661 | 106.71 | 1.58 | 53.35 | 177.01 | 7.2K | nominal |
| B1 | downloaded | 4.784 | **137.09** | 1.23 | 54.60 | 209.46 | **20.2K** | nominal |
| A2 | side-loaded | 5.675 | 106.85 | 1.58 | 52.94 | 176.57 | 2.6K | nominal |
| B2 | downloaded | 5.535 | 113.79 | 1.48 | 51.13 | 181.04 | 2.6K | nominal |
| A3 | side-loaded | 5.881 | 101.33 | 1.66 | 52.48 | 170.37 | 4.2K | nominal |
| B3 | downloaded | 5.306 | 119.35 | 1.41 | 52.96 | 188.83 | 6.6K | nominal |

- Phase times are in ms per decode forward.
- Fetch is 3,358,720 B × 50.17 reads/token ÷ `io`.
- Compressions/s is the phone-wide counter from `start` to `done`, so it
  includes the model load and prefill.
- Every run ended `stop=endOfTurn` with 507 new tokens.
- Every run peaked at 3.112–3.117 GB footprint.

## Scoring

- **D1, identical bytes and hit rate: HELD.** All six runs:
  - bytes/token: 160.71 MiB
  - hit rate: 79.1%
  - reads/token: 50.17
  - prefill: 6,950.78 MiB

  This matches the 2026-09-24 24-slot short row to the digit. The two copies
  are the same model and did the same work.
- **D2, B's median `io` 5–20% above A's: HELD on the number.** B's median is
  119.35 and A's is 106.71: **+11.8%**, and −6.5% in tok/s (5.306 against
  5.675). **Every B run is slower than every A run.** B's fastest, 113.79, is
  above A's slowest, 106.85.
- **D3, per-arm spread under 10%: FALSIFIED for B.**
  - A spans 101.33–106.85 (5.4%).
  - B spans 113.79–137.09 (20.5%).

  The written reading rule for a failed D3 is to report the comparison as
  **inconclusive and not act on it**. This file follows that rule.

## What the numbers do and do not show

- **`cb1-wait` is flat** at 51.1–54.6 across all six runs, and bytes are
  identical. So the difference sits in the fetch path, as a storage effect
  would, and not in the GPU.
- **B1 is the outlier, and its compressor rate was 20K/s**, 3–8× every other
  run. The first 24-slot medium run earlier today showed the same pairing: a
  slow `io` with a compressor rate of 23K/s. That is an association from two
  runs, not a cause. B1 is kept, and the scoring above includes it.
- **The ordering is the strongest evidence.** Three B runs all slower than
  three A runs happens by chance 1 time in 20, if there were no difference.
  That is suggestive at this sample size, not decisive.
- **Write order and age are confounded, as the predictions said.** B is
  scattered and 1 h old; A has an unknown order and is 8 days old. On the Mac,
  freshness favours B. If that holds here, the order cost may be larger than
  measured, and B may slow further as it ages. Neither is measured.

## Consequence

By the written rule, nothing is done yet: **the in-order rewrite step is not
added on this evidence.** The download ships as it is. To settle it, the next
measurement is more A/B pairs in the same protocol. Their reading rule must
be written down first. A spread rule cannot pass while B1 is in the pool, so
it has to test the ordering instead, for example with a rank test. If B is
still slower, the rewrite step gets its own prediction.

**The order was not balanced, and the next set must fix that.** B always ran
second in its pair, so a position effect is not ruled out. Thermal state was
`nominal` on every sample, but that level covers a range of temperatures, and
on this phone heat mostly slows `io`. Heat carried over from the previous run
does not show: A2 and A3 followed a B run and were no slower than A1, which
followed idle time. The next set should run B, A, A, B, B, A. It is postponed
for now, by the user's choice.
