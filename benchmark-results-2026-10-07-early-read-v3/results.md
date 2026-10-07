# Results: the v3 early-read benchmark

Scores [`predictions.md`](predictions.md). Friends' reports are added below as
they arrive.

## Our M1 MacBook Air, 8 GB

macOS 26.6.1, Swift 6.3.3, on AC power, thermal nominal and 69–75% memory free
at every run. `43da4c2` (runtime `1a4c9ab`), 2026-10-07 01:37–06:26. All 48
runs finished, none failed. The script's last steps (opening the issue form and
copying Results) were stubbed out; nothing was posted. Logs in
[`runs/`](runs/), the report in [`runs/results.md`](runs/results.md), rows in
`MEASUREMENTS.md`.

**Every prediction holds, and all three decision rules pass on this Mac.**

Median of each case's 4 adjacent pairs, against the predicted range:

| | short | medium | long |
| --- | ---: | ---: | ---: |
| router vs off | **+18.7%** (+14 to +25) | **+18.9%** (+13 to +24) | **+16.8%** (+10 to +20) |
| fitted vs router | **+4.3%** (+1.5 to +5.5) | **+4.7%** (+1.5 to +5.5) | **+4.0%** (+1.5 to +5.5) |
| fitted ×2 vs fitted | **+11.5%** (+4 to +12) | **+13.7%** (+8 to +19) | **+14.8%** (+9 to +20) |

Every step won all 12 of its pairs. The smallest single pairs were +15.8%
(router vs off), +1.5% (fitted vs router) and +7.7% (fitted ×2 vs fitted).

Mean tok/s of each setting's 4 runs:

| | off | router | fitted | fitted ×2 |
| --- | ---: | ---: | ---: | ---: |
| short | 3.652 | 4.341 | 4.527 | 5.011 (+37.2%) |
| medium | 3.302 | 3.913 | 4.117 | 4.697 (+42.3%) |
| long | 3.036 | 3.542 | 3.674 | 4.241 (+39.7%) |

**Noise:** adjacent identical runs differ by a median of 1.0% (largest 4.2%,
9 pairs), inside the predicted 2%. Two runs are flagged as more than 3% from
their setting's median, both fitted ×2 and both fast: medium run 4 (+4.6%) and
long run 13 (+3.5%).

**Controls, all exact:** one output per case across 16 runs (`9c3bd04e…`,
`d1f5e61b…`, `3fce8764…`). `needed/tok` 77.45 / 83.93 / 92.08. Loaded early
and precision 19.87 / 20.41 / 20.96 and 0.685 / 0.704 / 0.723 for router;
24.10 / 24.44 / 25.23 and 0.831 / 0.843 / 0.870 for fitted; 41.51 / 42.73 /
44.91 and 0.716 / 0.737 / 0.774 for fitted ×2. No fallback to the router
guess.

**Decision rules on this Mac:** rule 1 (router beats off in ≥ 3 of 4 pairs
every case), rule 2 (fitted's median over router above 0) and rule 3 (fitted
×2 beats fitted in ≥ 3 of 4 pairs every case) all pass. The rules apply across
every Mac, so the decisions wait for the friends' reports.
