# Results — iPhone 17 expert-cache slot count, 2026-09-16

Scored against `predictions.md`, which was committed in `e497101` before any of
these runs. Seven runs, all `stop=endOfTurn`, token counts identical within each
case (507 / 632 / 602) and prompt SHA-256 logged and matching canonical.

## Measured

Bytes/token is quoted as the footer prints it (MiB labelled MB); the MB column
is the conversion.

| case | slots | tok/s | hit rate | bytes/tok (MiB) | io ms/fwd | cb1-wait | head | wall | peak footprint | thermal |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| short | 16 (cool) | 4.395 | 67.7% | 248.48 | 147.41 | 61.15 | 10.89 | 227.96 | 2.138 GB | nominal |
| short | 24 | **6.028** | 79.1% | 160.71 | 98.67 | 51.16 | 9.21 | 166.23 | 2.962 GB | nominal |
| short | 32 | **7.005** | 86.5% | 103.68 | 77.67 | 50.10 | 8.61 | 143.04 | 3.770 GB | nominal |
| short | 16 (control, hot) | 3.884 | 67.7% | 248.48 | 174.46 | 63.37 | 11.35 | 257.98 | 2.165 GB | **serious** |
| medium | 16 | 3.961 | 64.9% | 270.06 | 160.80 | 71.76 | 11.24 | 252.83 | 2.134 GB | nominal |
| medium | 24 | **5.079** | 75.8% | 186.24 | 115.19 | 63.87 | 10.02 | 197.19 | 2.958 GB | fair |
| medium | 32 | **6.181** | 83.0% | 130.31 | 85.17 | 60.69 | 8.66 | 162.05 | 3.768 GB | nominal→fair |
| long | 16 | 3.571 | 62.3% | 290.15 | 171.46 | 88.95 | 10.45 | 280.50 | 2.132 GB | fair |
| long | 24 | **4.328** | 73.3% | 205.52 | 127.45 | 84.93 | 10.22 | 231.43 | 2.961 GB | fair→serious |
| long | 32 | **4.786** | 80.6% | 148.84 | 109.69 | 81.91 | 8.60 | 209.28 | 3.771 GB | **serious** |

Gains over the 16-slot baseline: **+37.2 / +28.2 / +21.2%** at 24 slots and
**+59.4 / +56.0 / +34.0%** at 32. Against the Mac host's 3.745 / 3.346 / 2.987,
the phone at 32 slots is **1.87× / 1.85× / 1.60×**.

## Scoring

- **P1 — hit rate. HELD.** Predicted 77–83% at 24 and 83–89% at 32 on short;
  measured **79.1%** and **86.5%**, both in band, with medium and long a few
  points lower as predicted. ⚠️ But the gains sit **consistently below
  CACHE-03's trace replay**: replay gave +12.6–14.9 points at 24 and +20.9–23.7
  at 32, while live device routing gave **+10.9 to +11.4** and **+18.1 to
  +18.8**. Trace replay over-predicts the live gain by roughly 2–5 points.
- **P2 — bytes/token. HELD at 32, MISSED at 24.** Predicted −45 to −65% at 32;
  measured **−58.3 / −51.7 / −48.7%**, all in band. Predicted −35 to −50% at 24;
  measured **−35.3 / −31.0 / −29.2%** — only the short case landed in the band,
  and medium and long missed on the low side. The miss follows from P1's:
  the hit-rate gain at 24 was smaller than replay suggested.
- **P3 — tok/s. HELD on the threshold, point estimate too optimistic.**
  Predicted "at least +25%" on short; measured **+59.4%**. But the point
  estimate of 7.5 / 6.6 / 5.8 at 32 slots overshot on the long case:
  measured **7.005 / 6.181 / 4.786**, with long **17% below** the estimate.
  The estimate assumed `io` falls in proportion to bytes. It does not, for two
  reasons now visible: `cb1-wait` does not shrink with bytes at all (81.91 ms of
  the long case's 209.28 ms wall, 39%), and achieved fetch bandwidth *falls* as
  the cache grows — 1.767 GB/s at 16 slots, 1.708 at 24, 1.400 at 32 on the
  short case, because the reads that remain are the scattered, hard ones.
- **P4 — footprint. HELD, and precisely.** Predicted ≤3.1 GB at 24 and ≤4.0 GB
  at 32; measured **2.958–2.962 GB** and **3.768–3.771 GB**, against projections
  of ~2.94 and ~3.75 GB. No jetsam. The 4.5 GB falsifier was never approached.
- **P5 — the failure mode. HELD, and this is the important one.** The Mac's live
  32-slot row collapsed to 1.578 tok/s with `io` at 318.3 ms/token. The phone
  shows the opposite: `io` per forward falls monotonically at every slot count
  and in every case. **The measured 5.60 GB ceiling headroom is real**, and the
  memory budget later Track B steps are planned against survives.
- **P6 — quality. Consistent, not proven.** Token counts are identical across
  slot counts within each case, as expected for a change that alters only which
  bytes are resident. This is not a numerical tolerance check; none has been run
  on the device.

## The thermal control, which was not predicted

The seventh run repeated the 16-slot short case at the end, when the phone was
hottest. Same configuration, same 507 tokens, **bytes/token and hit rate
identical to the digit** (248.48 MiB, 67.7%) — the only difference is thermal
state:

| | nominal | serious | delta |
| --- | --- | --- | --- |
| tok/s | 4.395 | 3.884 | **−11.6%** |
| io ms/fwd | 147.41 | 174.46 | **+18.3%** |
| cb1-wait | 61.15 | 63.37 | +3.6% |
| head | 10.89 | 11.35 | +4.2% |
| wall | 227.96 | 257.98 | +13.2% |

Three consequences:

1. **`serious` throttles; `fair` largely does not.** Track B step 1 found `fair`
   did not visibly throttle, and that still stands. `serious` costs 11.6% of
   throughput.
2. **It hits storage, not compute.** `io` moved 18.3% while `cb1-wait` moved
   3.6%, with bytes/token constant — so this is the fetch path slowing, not the
   GPU.
3. **The slot-count gains above are understated where runs ran hot.** The long
   case's 16-slot baseline ran at `fair` while its 24- and 32-slot runs reached
   `serious`, so the true cache benefit at long context is **larger** than the
   +21.2 / +34.0% measured. bytes/token and hit rate are thermally invariant,
   which is what lets the two effects be separated at all.

## Disposition

Per CACHE-03's lesson, this is **memory-funded speed, not a memory-free
optimization**: 32 slots buys 1.60–1.87× the Mac's throughput for +1.61 GB of
resident buffers. It is quality-neutral by construction. Whether it becomes the
iOS default is a separate decision, since `RuntimeConfiguration` defaults to 16
and that default is shared with the Mac, where CACHE-03 showed 32 slots is
harmful.
