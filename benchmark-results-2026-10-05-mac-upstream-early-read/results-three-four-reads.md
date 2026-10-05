# Results: three and four early reads per layer on the M1

Scored against
[`predictions-three-four-reads.md`](predictions-three-four-reads.md),
committed first in `87dfa23`. Runs in
[`runs-three-four-reads/`](runs-three-four-reads/) (driver:
[`run-three-four-reads.sh`](run-three-four-reads.sh)), 19 rows in
`MEASUREMENTS.md`, the warmup included. Same build (`1a4c9ab`) and Mac as
[`results-two-reads.md`](results-two-reads.md). On power, 18 GiB free,
thermal nominal throughout, 2026-10-05 23:56 to 2026-10-06 01:40.

## Answer

**Two reads per layer is the best count on the M1.** Three are slightly
slower and four clearly slower, with identical output. Mean of two runs each,
fitted guess:

| | ×2 | ×3 | ×4 | ×3 vs ×2 | ×4 vs ×2 |
| --- | --- | --- | --- | --- | --- |
| short | 4.892 | 4.648 | 3.828 | −5.0% | **−21.7%** |
| medium | 4.508 | 4.319 | 3.716 | −4.2% | **−17.6%** |
| long | 4.293 | 4.184 | 3.782 | −2.6% | **−11.9%** |

Per token, with the derived storage rate (reads from storage × 3,358,720 B ×
tok/s, where reads from storage = `needed/tok` − `loaded-early/tok` +
`reads/tok`):

| | loaded early ×2 / ×3 / ×4 | precision ×2 / ×3 / ×4 | storage GB/s ×2 / ×3 / ×4 |
| --- | --- | --- | --- |
| short | 41.51 / 53.03 / 60.25 of 77.45 | 0.716 / 0.610 / 0.519 | 1.54 / 1.74 / 1.71 |
| medium | 42.73 / 55.16 / 63.14 of 83.93 | 0.737 / 0.634 / 0.544 | 1.50 / 1.68 / 1.71 |
| long | 44.91 / 58.91 / 68.15 of 92.08 | 0.774 / 0.677 / 0.588 | 1.52 / 1.69 / 1.78 |

## Scoring

- **×3 vs ×2, −10% to +5%:** held, −5.0 / −4.2 / −2.6%.
- **×4 vs ×2, −25% to 0%, and below ×3 on at least two cases:** held,
  −21.7 / −17.6 / −11.9%, below ×3 on all three.
- **`loaded-early/tok` on short, ×3 49–56 and ×4 54–62:** held, 53.03 and
  60.25.
- **Storage rate below 2.3 GB/s:** held, at most 1.78.
- **Controls:** `reads/tok` exactly 87.00 and 116.00; `needed/tok` and the
  text (`9c3bd04e…`, `d1f5e61b…`, `3fce8764…`) identical to every earlier
  run. **The in-session ×2 runs were to land within 3% of the earlier ×2
  means: short +0.7%, medium −2.0%, long +3.1%, so long missed by 0.1
  point.**
- **Falsifiers:** none triggered.

## Noise

Runs of the same setting agreed within 0.1–4.4%, except medium ×2 (4.344 /
4.672, 7.5%), medium ×3 (4.167 / 4.471, 7.3%) and long ×3 (4.385 / 3.982,
10.1%), wider than in the earlier sessions. The ×4 loss is far outside that.
The ×3 loss is smaller than the widest pairs, but has the same sign on all
three cases: read it as "no gain over two", not as a precise loss.

## Why

At three and four reads, storage runs at 1.68–1.78 GB/s. That is this
Mac's random-read ceiling: 1.67 GB/s with 2–4 reads in flight measured in
August with Spotlight indexing, 1.82 GB/s without (`MEASUREMENTS.md`,
2026-08-10). At two reads it runs at 1.50–1.54. So from the third read on the
drive is saturated, and each wasted early read takes time from a read the
token needs. The guesses also get worse: the third read alone is used 0.40 of
the time on short, (53.03 − 41.51) / 29, and the fourth 0.25.

This does not settle why two beat one (`results-two-reads.md`): a longer idle
window per layer, or the drive's gain from a second request in flight.

## What this changes

- On the M1, two is the best fixed count; there is no case for more.
- The limit is the drive's saturation, so a Mac with a faster SSD, or with
  enough RAM to serve the model from the file cache, may peak elsewhere.
  Friends' runs measure ×2 on their Macs, and the optional
  `benchmark-early-read-counts.sh` measures ×3 and ×4.
