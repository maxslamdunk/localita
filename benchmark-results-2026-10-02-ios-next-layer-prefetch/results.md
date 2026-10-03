# Results: reading one of the next layer's experts early, unfitted guess

Scored against [`predictions.md`](predictions.md), committed first in
`32f707b`. The code is `dd9dcba`. Logs, saved texts and the driver are in
[`logs/`](logs/) and [`run.sh`](run.sh). `summarize.py` prints every figure
below from the logs. The Mac check is in [`mac/`](mac/).

## Answer

**Yes: +15.1% / +12.2% / +12.4% tok/s on the iPhone**, with output
byte-identical in all 12 runs. The cost is **+26 / +20 / +18% bytes/token**,
from about 12 wasted reads per token. Every prediction held except P5 on
medium, which one anomalous run explains (see P5). The decision rule says to
go on to step 2, the fitted guess.

| case | tok/s off → on | `io` ms/fwd | bytes/tok (footer MB) | guess precision |
| --- | --- | --- | --- | --- |
| short | 5.644 → **6.495 (+15.1%)** | 107.00 → 85.42 (−21.6) | 160.71 → 202.49 | 0.550 |
| medium | 4.774 → **5.354 (+12.2%)** | 126.42 → 92.32 (−34.1) | 187.08 → 225.41 | 0.587 |
| long | 4.375 → **4.919 (+12.4%)** | 137.36 → 111.47 (−25.9) | 204.59 → 241.24 | 0.606 |

Means of two runs per arm.

## What was run

Branch `next-layer-expert-prefetch` at `e8fd71f` (code `dd9dcba`), built in
Release and installed over the app. One binary for both arms:

- **A:** early read off.
- **B:** early read on, via `--early-expert-read`. Each B log's `runner-ready`
  line confirms `earlyExpertRead=next-layer`; each A log says `off`.

Each case ran A B B A, on 2026-10-03 between 00:45 and 02:12:

- 24 slots, `--max-new 1024 --max-context 4096`, prefill chunk `auto`;
- iPhone 17, iOS 26.6;
- a 300 s cooldown between runs.

Thermal was `nominal` for all short and medium runs. On long, A1 was
`nominal` and the other three were `fair` for 36–39 of 42 samples, so long's
arms are thermally a little unbalanced against B. Peak footprint did not
change: 3.379 GB on long in both arms.

Before the phone, one Mac pair on the short case (16 slots) gave identical
text, precision 0.685, `io` −40.2 ms and +16.5% tok/s. That was one
non-interleaved pair; see the two 2026-10-03 Mac rows in `MEASUREMENTS.md`.

## Scoring

**P1, identical work: held.**

- **Text:** every case's four texts share one SHA-256: `d32db73b…`,
  `209ffadb…` and `87f6f357…`, which are also the earlier runs' hashes.
- **Cache:** hit rate (79.1 / 75.7 / 73.4%) and requests/token are identical
  across arms.

**P2, live precision 0.50–0.65: held.** Used ÷ issued is **0.550 / 0.587 /
0.606**. That is close to the Mac study's per-prompt 0.545 / 0.593 / 0.621,
even though the phone routes its own text.

**P3, reads added = issued − used: held exactly.** Added reads/token are
13.05 / 11.97 / 11.44, and issued − used is 13.05 / 11.97 / 11.44. The point
values predicted 63.4 / 70.2 / 74.9 reads/token; measured 63.22 / 70.37 /
75.31.

**P4, `io` falls: held.**

| case | predicted | measured | per used read |
| --- | --- | --- | --- |
| short | −12 to −26 | **−21.6** | 1.35 ms |
| medium | −18 to −38 | **−34.1** | 2.00 ms |
| long | −18 to −38 | **−25.9** | 1.47 ms |

Every case is above the 1.0 ms-per-used-read floor, so the early reads do hide
in idle storage time. Short sits lowest, consistent with its idle window being
shorter than a read (1.88 against 2.23 ms).

Long's two B runs differ by 22 ms of `io` (122.52 and 100.42). B1's reads were
slower throughout, with a mean read of 4.91 against 4.13 ms on identical work.
Both B runs were `fair` for most of their samples, so thermal state does not
separate them. Storage speed varies between runs; this is not attributed.

**P5, `cb1-wait` +0 to +2 ms: held on short and long, falsified on medium.**

| case | `cb1-wait` change | GPU attention+router change |
| --- | --- | --- |
| short | −1.91 | −0.20 |
| medium | **+9.35** | +6.14 |
| long | +0.28 | +0.31 |

Medium's mean comes from B1 alone. In that run every GPU part was slower than
in A: attention+router +31%, shared expert +24%, routed +25%, and the output
head +16%. The head runs after the last layer and never overlaps an early read,
so it points to the GPU running slower for that whole run, not to the reads
interfering. Medium B2's GPU parts match A's except attention+router (+2.8 ms)
and routed (+2.1 ms). Excluding B1, medium's `cb1-wait` change is +3.3 ms,
still just above the 3 ms falsifier. The prediction stands falsified on the
record.

Across the B runs, attention+router is about 0–3 ms slower per forward than in
A. That is more than 29 small GEMVs should cost, so storage writing into memory
while the GPU runs attention may be a part. It is not measured separately.

**P6, tok/s: held on all three.**

| case | predicted | measured | ceiling |
| --- | --- | --- | --- |
| short | +6 to +16% | **+15.1%** | +15.6% |
| medium | +8 to +21% | **+12.2%** | +21.1% |
| long | +8 to +20% | **+12.4%** | +19.7% |

Short is close to its ceiling. Medium and long are lower:

- the per-used-read saving there is below the read time;
- medium also carries B1's slow GPU;
- long's B1 had slow storage.

## Decision

P1 held, and medium and long each gained more than +5%. **Proceed to step 2,
the fitted correction.** Offline it raised precision@1 from 0.588 to 0.726 at
24 slots. If the time saved per used read stays where it is, that is roughly
4 more used reads per token: about 6 ms more of `io` saved at the measured
1.35–2.0 ms per used read, and 4 fewer wasted reads.

The early read stays off by default until step 2 is measured. It costs
bytes/token, and the project's rules want that trade made explicitly.
