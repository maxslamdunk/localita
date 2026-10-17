# Predictions: three and four early reads per layer on the M1

Written before any run with three or four reads. Follows
[`results-two-reads.md`](results-two-reads.md), where two reads beat one by
+7.7 / +13.4 / +14.9%.

## Setup

Same build (`1a4c9ab`), Mac, protocol and fitted guess as
[`results-two-reads.md`](results-two-reads.md). One warmup run, discarded.
Then per case, in this order: ×2, ×3, ×4, ×4, ×3, ×2, where ×n is
`--early-expert-read fitted` with `TURBO_FIELDFARE_EARLY_EXPERT_READS=n`.
Two reads run again as the in-session reference. The driver is
[`run-three-four-reads.sh`](run-three-four-reads.sh).

## How the code runs n reads

The n early reads run one after another on one serial queue, best guess
first. They start when layer L's own reads finish. Before starting the next
layer's early reads, the runner waits for every one still running, and that
wait comes before layer L+1's cb2 is encoded. So an early read that is still
running at that point delays the token. At two reads the M1 takes 6.86 ms
per layer on short (4.859 tok/s), and one read takes about 2 ms. Three
serial reads take about 6 ms and four about 8 ms, so the chain no longer
fits inside a layer.

Storage load, derived as reads from storage per token × 3,358,720 B × tok/s
(reads from storage = `needed/tok` − `loaded-early/tok` + `reads/tok`): 1.25
GB/s at one read and 1.53 GB/s at two, short case. This artifact's random
read ceiling is somewhere around 1.8–2.3 GB/s, so storage has some headroom
left, but not much.

## What moves

- **tok/s, ×3 vs ×2: −10% to +5% per case.** The third guess is used less
  often than the second (second alone: 0.60 on short), and the chain starts
  to reach the runner's wait.
- **tok/s, ×4 vs ×2: −25% to 0% per case, and below ×3** on at least two of
  the three cases.
- **`loaded-early/tok`, short:** ×3 **49–56**, ×4 **54–62** (two reads:
  41.51; at most `needed/tok`, 77.45).
- **Derived storage rate:** below 2.3 GB/s in every run.

## Controls

- `reads/tok` exactly 87.00 (×3) and 116.00 (×4).
- `needed/tok` 77.45 / 83.93 / 92.08, as in every earlier run.
- Generated text identical to the earlier runs of each case (`9c3bd04e…`,
  `d1f5e61b…`, `3fce8764…`).
- The in-session ×2 runs within 3% of the earlier ×2 means (4.859 / 4.599 /
  4.163).

## What would falsify it

- ×3 more than +5% faster than ×2 on any case: the idle window, or the gain
  from overlapping reads, is larger than this arithmetic assumes.
- ×4 at least as fast as ×2 on any case: the runner's wait on unfinished early
  reads does not cost what the arithmetic says.
- A derived storage rate above 2.3 GB/s: reads are coming from the OS file
  cache, not the SSD.
