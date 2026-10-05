# Results: the early read on upstream's code, on the M1

Scored against [`predictions.md`](predictions.md), committed first in
`9723b3a`. Runs in [`runs/`](runs/) (driver:
[`run-early-read-benchmark.sh`](run-early-read-benchmark.sh)), 21 rows in
`MEASUREMENTS.md` (2026-10-05, `1a4c9ab`). Build: the upstream contribution
branch `early-expert-read-fitted` at `1a4c9ab`. M1 MacBook Air 8 GB, on power,
19 GiB free, thermal nominal throughout, 2026-10-05 19:52–21:52.

## Answer

**On upstream's code the early read gives +19 to +25% decode on the M1, with
identical output.** Decode tok/s, mean of two interleaved runs per setting:

| | off | router | fitted | router vs off | fitted vs router | fitted vs off |
| --- | --- | --- | --- | --- | --- | --- |
| short | 3.607 | 4.354 | 4.498 | **+20.7%** | +3.3% | +24.7% |
| medium | 3.287 | 3.906 | 4.043 | **+18.8%** | +3.5% | +23.0% |
| long | 3.012 | 3.463 | 3.587 | **+15.0%** | +3.6% | +19.1% |

Runs of the same setting agree within 0.1–2.5%, except long router (3.407 /
3.519, 3.3%).

Expert reads per token (exact, identical between the two runs of a setting):

| | needed from disk | loaded early: router / fitted | precision: router / fitted |
| --- | --- | --- | --- |
| short | 77.45 | 19.87 / 24.10 | 0.685 / 0.831 |
| medium | 83.93 | 20.41 / 24.44 | 0.704 / 0.843 |
| long | 92.08 | 20.96 / 25.23 | 0.723 / 0.870 |

## Scoring

- **router vs off, +10 to +20%:** held on medium (+18.8%) and long (+15.0%);
  **short +20.7% is just above the range.** The single 2026-10-03 port pair
  measured +16.5%; that pair was not interleaved and ran on a fuller disk.
- **fitted vs router, +2 to +8%:** held, +3.3 / +3.5 / +3.6%. The earlier
  port pair's +5.4% was at the top of this.
- **Controls: held.** One distinct output per case across all six runs, the
  short one `9c3bd04e…`, the port's; `needed/tok` identical across settings;
  29.00 early reads per token; short precision exactly 0.685 / 0.831.
- **"Precision on medium and long lower than offline but within 0.05 of
  0.848": half wrong.** Medium 0.843 is lower; long 0.870 is higher. Both are
  within 0.05.
- **Falsifiers:** none triggered.

## Conditions to note

- The fork was created and the branches pushed at about 20:44, during
  `medium-review` run 3 (fitted, 4.052). Run 4 (fitted, 4.033) agrees with it
  within 0.5%, so no effect is visible.
- Warmups ran at the default (fitted): 4.461 / 4.123 / 3.643, not quoted.
- These are the first interleaved Mac runs of the early read; earlier Mac
  figures were single pairs on the port's code.
