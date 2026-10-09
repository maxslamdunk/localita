# Results: the v3 early-read benchmark

Scores [`predictions.md`](predictions.md). Friends' reports are added below as
they arrive.

## Our M1 MacBook Air, 8 GB

macOS 26.6.1, Swift 6.3.3, on AC power, thermal nominal and 69–75% memory free
at every run. `43da4c2` (runtime `1a4c9ab`), 2026-10-07 01:37–06:26. All 48
runs finished, none failed. The script's last steps (opening the issue form and
copying Results) were stubbed out, and the report was then posted by hand as
fork issue #5. Logs in
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

## An M1 MacBook Pro, 16 GB (fork issue #4)

The predictions call this Mac "the M1 Pro"; its report says MacBook Pro
with an Apple M1 chip, so it is a plain M1.

macOS 27.0.1, Swift 6.4, `43da4c2`, posted 2026-10-07 09:04. All 48 runs
finished; one run flagged (short run 1, off, +3.6%).

| | short | medium | long |
| --- | ---: | ---: | ---: |
| router vs off | **+30.8%** (+20 to +35) | **+30.2%** (+20 to +35) | **+26.6%** (+18 to +32) |
| fitted vs router | **+0.9%** (+0.5 to +4) | **+1.6%** (+0.5 to +4) | **+1.9%** (+0.5 to +4) |
| fitted ×2 vs fitted | **+4.9%** (−1.5 to +3) ✗ | **+2.4%** (−1.5 to +3) | **+3.6%** (−1.5 to +3) ✗ |

Every step won all 12 of its pairs. **Noise: median 0.3%** (largest 0.9%),
inside the predicted 1.5%. Counters and the three output SHAs exactly as on
our M1.

**Missed: fitted ×2 vs fitted, short and long.** The prediction netted the
second read's hits against its wasted reads at the rate router ×2 implied
(about +1%), and so expected rule 3 to fail on 16 GB Macs. It gained +2.4 to
+4.9% instead, every pair positive. The wasted-read cost inferred from router
×2 on this Mac overstates what fitted ×2's wasted reads cost.

**Decision rules on this Mac:** all three pass.

## An M1 MacBook Pro, 8 GB (fork issue #7)

macOS 27.0.1, Swift 6.4, `43da4c2`, posted 2026-10-08 12:10. All 48 runs
finished, none flagged. **Noise: median 0.9%** (largest 3.0%). No ranges were
predicted for this Mac, only that router beats off and fitted's median over
router is above 0; both hold.

| | short | medium | long |
| --- | ---: | ---: | ---: |
| router vs off | **+14.1%** | **+12.9%** | **+11.4%** |
| fitted vs router | **+3.8%** | **+2.3%** | **+2.4%** |
| fitted ×2 vs fitted | **+9.8%** | **+12.6%** | **+12.6%** |

Every step won all 12 of its pairs. Counters and the three output SHAs exactly
as on our M1. It is much faster than our M1 Air at the same counters (off
6.112 / 5.611 / 5.193 tok/s against 3.652 / 3.302 / 3.036), so its time per
read or GPU time is lower, not its bytes; the cause was not measured.

**Decision rules on this Mac:** all three pass.

## The M3 MacBook Air, 16 GB (fork issues #6 and #8)

macOS 26.7.1, Swift 6.4, `43da4c2`. Issue #6 (07:13) was posted with Results
empty; #8 (17:06) is the same run with Results pasted (same token counts and
SHAs). All 48 runs finished. **Noise: median 0.8%**, largest 7.2%. Seven runs
are flagged, all in the long case.

| | short | medium | long |
| --- | ---: | ---: | ---: |
| router vs off | **+29.1%** (4 of 4) | **+16.2%** (4 of 4) | **+1.0%** (3 of 4) |
| fitted vs router | **+1.3%** (3 of 4) | **+1.7%** (4 of 4) | **−3.3%** (1 of 4) |
| fitted ×2 vs fitted | **+12.3%** (4 of 4) | **+23.8%** (4 of 4) | **+65.8%** (4 of 4) |

Mean tok/s, long case: off 6.262, router 6.430, fitted 6.505, fitted ×2
10.445, which is faster than its medium case (10.134).

**Controls:** one output per case across 16 runs, different text from the M1
family (another GPU family, as the predictions allowed). `needed/tok` 78.23 /
84.30 / 91.28 follow from that text. Fitted precision 0.833–0.864, so the
fitted guess loaded.

**Decision rules on this Mac:** the report is usable (noise median 0.8%, no
warning). Rule 1 passes, narrowly in the long case. Rule 2 passes as written:
the median of all 12 pairs is +1.3%. Per case, though, fitted lost 3 of 4
long pairs to router. Rule 3 passes.

**The long case, from the friend's `benchmark-results.zip`** (attached to #8
later; read, then deleted here). In the long case one early read gains little
over off, while two gain +66% over one:

| long, per run | off | router | fitted | fitted ×2 |
| --- | --- | --- | --- | --- |
| tok/s | 6.249, 6.223, 6.275, 6.300 | 6.335, 6.047, 6.317, **7.022** | 6.128, **7.075**, 6.103, **6.713** | 10.171, 10.130, 10.364, 11.113 |
| ms per token, the steady runs | 159–161 | 158–165 | 163–164 | 90–99 |

- Off is steady, fitted ×2 nearly so. The irregular runs are the three bold ones,
  all at one read. Both fitted runs that directly follow a fitted ×2 run (6
  and 14) are fast; the two that follow a router run are not. Router run 15
  is fast and router run 7 is not, so no simple rule covers all three.
- The two fitted-vs-router pairs without a fast run give −3.3% and −3.4%. So
  on this Mac, in the long case, one read gains about nothing and the fitted
  guess does not beat the router.
- Ruled out at every run's start: power (AC throughout), thermal (no warning
  in any of the 48 runs), memory (83–84% free) and other processes (none
  above 8.4% CPU, the same few in fast and slow runs). The friend's Mac is a
  fanless MacBook Air, and conditions are recorded only at each run's start.
- Medium, by contrast: off 145 ms per token, fitted 122, fitted ×2 99. There
  each read saves about 23 ms. In the long case one read saves nothing and
  two save about 62 together.
- **Not explained.** The upstream CLI prints no phase timings, so these
  files hold only tok/s and the early-read counters. Explaining it needs a
  phase-timed run on this Mac.

## The M4 MacBook Air, 16 GB (fork issue #9)

macOS 26.5, Swift 6.3.3, `43da4c2`, posted 2026-10-09 06:51 by the M3's
owner. All 48 runs finished, none flagged. **Noise: median 1.5%** (largest
3.1%), so the report is usable.

| | short | medium | long |
| --- | ---: | ---: | ---: |
| router vs off | **+12.5%** (4 of 4) | **+9.8%** (4 of 4) | **+9.9%** (4 of 4) |
| fitted vs router | **+0.4%** (3 of 4) | **−0.3%** (0 of 4) | **+0.9%** (2 of 4) |
| fitted ×2 vs fitted | **+8.7%** (4 of 4) | **+9.8%** (4 of 4) | **+11.2%** (4 of 4) |

Output SHAs and counters exactly as on the M3 (one output per case; fitted
precision 0.833–0.864).

**Missed: fitted vs router.** The prediction for every other Mac was that
fitted's median over router is above 0. On this Mac the median of its 12
pairs is −0.05% (5 of 12 faster), so **rule 2 fails here**, and by the rule
PR 2 names this Mac. The fitted guess still loads 4.2–4.3 more experts per
token early than the router does, as on every Mac; here those hits buy no
time. Rules 1 and 3 pass.

## Decisions so far

Five Macs: our M1 Air, the two M1 MacBook Pros, the M3 and the M4.

- **Rule 1 passes on all five:** PR 1 claims the speedup.
- **Rule 2 passes on four and fails on the M4** (median −0.05%): PR 2 claims
  fitted beats router and names the M4.
- **Rule 3 passes on all five:** fitted ×2 beat fitted in all 60 pairs, so the
  Mac default becomes two reads (PR 2). The iPhone stays at one.
