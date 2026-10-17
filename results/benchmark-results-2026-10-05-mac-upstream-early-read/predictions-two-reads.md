# Predictions: two early reads per layer on the M1

Written before any run with two reads, while the one-read A/B
([`predictions.md`](predictions.md)) was running. The M1 runs here are the
reference for friends' Macs, which run the same arms.

## Setup

Same build, protocol and Mac as `predictions.md`. Per case, after that A/B:
`fitted`, `fitted ×2`, `fitted ×2`, `fitted`, where `fitted ×2` is
`--early-expert-read fitted` with `TURBO_FIELDFARE_EARLY_EXPERT_READS=2`.
Friends run the eight-run order off, router, fitted, fitted ×2, fitted ×2,
fitted, router, off (`benchmark-early-read.sh`).

## What moves

- **`loaded-early/tok`:** rises from one read's ~24 (short) to **38–46**.
  Offline at 16 slots, two reads land 0.742 of the time against 0.848 for one,
  so the second alone lands about 0.64.
- **`reads/tok`:** 58.00, against 29.00.
- **tok/s, fitted ×2 vs fitted: −3% to +8% per case.** On the M1 a read takes
  about 2 ms and storage idles about one read per layer, so the second read
  usually still runs when the next layer's own reads start. When it is used,
  the layer waits for it instead of reading that expert itself, which is no
  worse. When it is wasted (about a third of the time), it delays a demand
  read by up to one read.

## Controls

- Generated text identical to the one-read runs of the same case.
- `needed/tok` identical to the one-read runs.

## What would falsify it

- tok/s below −5% on any case: wasted second reads cost more than the used
  ones save, even on this drive.
- tok/s above +10%: the M1's idle window is longer than one read on
  upstream's code, and the one-read default leaves speed on the table here.
- `loaded-early/tok` outside 38–46 on short: the offline second-read
  precision does not carry to live runs.
