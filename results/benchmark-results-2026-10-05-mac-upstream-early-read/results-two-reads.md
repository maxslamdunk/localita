# Results: two early reads per layer on the M1

Scored against [`predictions-two-reads.md`](predictions-two-reads.md),
committed first in `f172a5e`. Runs in [`runs-two-reads/`](runs-two-reads/)
(driver: [`run-two-reads.sh`](run-two-reads.sh)), 12 rows in
`MEASUREMENTS.md`. Same build (`1a4c9ab`), Mac and protocol as
[`results.md`](results.md), run right after it, 21:54–23:00, thermal nominal.

## Answer

**Two reads per layer are faster than one on the M1, by +7.7 to +14.9%, with
identical output.** Mean of two interleaved runs each, fitted guess:

| | 1 read | 2 reads | change | loaded early per token, 1 → 2 | precision, 1 → 2 |
| --- | --- | --- | --- | --- | --- |
| short | 4.511 | 4.859 | **+7.7%** | 24.10 → 41.51 of 77.45 | 0.831 → 0.716 |
| medium | 4.056 | 4.599 | **+13.4%** | 24.44 → 42.73 of 83.93 | 0.843 → 0.737 |
| long | 3.625 | 4.163 | **+14.9%** | 25.23 → 44.91 of 92.08 | 0.870 → 0.774 |

Against the read off (`results.md`), two fitted reads are +34.7 / +39.9 /
+38.2%. That comparison crosses sessions; the one-read runs here match the
A/B's fitted runs within 0.3 / 0.3 / 1.1%.

## Scoring

- **tok/s, −3% to +8%: held on short only. Medium (+13.4%) and long (+14.9%)
  triggered the falsifier "above +10%".** The one-read default leaves speed on
  the table on this Mac.
- **`loaded-early/tok` 38–46 on short:** held, 41.51.
- **Controls:** held. `reads/tok` 58.00; text and `needed/tok` identical to
  the one-read runs of the same case.

## Why the prediction was wrong

It assumed storage idles for about one read per layer, as on the iPhone, so a
second read would mostly collide with the next layer's own reads. That is the
phone's rule, not the M1's. The M1's SSD reads faster with two requests in
flight than with one: 1.29 GB/s at queue depth 1 against 1.63 GB/s at depth 2
(`MEASUREMENTS.md`, 2026-08-10 queue-depth probe). The iPhone measured the
opposite: concurrent reads only stretch each other (`CLAUDE.md`). So a second
early read that overlaps the next layer's reads is not pure contention on the
M1: it raises the drive's throughput, and 0.6 of the time it is a read that
layer needed anyway.

## What this changes

- The default of one read was set from the iPhone's storage. On the M1, two
  are better, and three are untested.
- Friends' runs measure fitted ×2 on their Macs; together with these they
  decide whether the upstream default should be 2 on the Mac.
- The iPhone has never run two reads. Its storage argues against it, but
  this result says to measure rather than infer.
