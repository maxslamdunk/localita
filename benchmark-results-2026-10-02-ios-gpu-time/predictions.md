# Predictions: the GPU-time and read-latency lines on the iPhone

Written 2026-10-02, before the runs. The binary is main at `f6345d1`.
Against the grouped-attention B arm (`016270a`), the only code change is the
`[gpu-time]` and `[read-latency]` footers.

## Why

The prefetch design from
[`research-results-2026-10-02-next-layer-prediction`](../research-results-2026-10-02-next-layer-prediction/results.md)
needs three numbers from the phone, since all its timing figures so far come
from the Mac:

- how long the GPU, and therefore storage, is busy in each layer;
- how much of `cb1-wait` is handoff latency;
- how much the OS file cache serves the misses.

## Runs

One run of each `real-generation-v1` case, with the same settings as the B
arm: Release, 24 slots, `--max-new 1024 --max-context 4096`, prefill chunk
`auto`. The phone is on mains power, the network is on, other apps are closed,
and there is a cooldown between runs. This is a first look, not an A/B.

## Label

Measurement only. **Zero bytes/token change**, and none in behaviour.

## Predictions

**P1. Identical work.** Each case generates the B arm's text byte for byte,
with SHA-256 `d32db73b…` / `209ffadb…` / `87f6f357…`. bytes/token is
160.71 / 187.08 / 204.59 MB and hit rate 79.1 / 75.7 / 73.4%.

*Falsified by* any difference.

**P2. No visible cost.** tok/s is within 10% of the B arm's: short 5.750,
medium 4.811, long 4.319–4.392.

*Falsified by* a run more than 10% slower without a thermal explanation.

**P3. `cb1-wait` splits like the Mac's, with less handoff.** On the short case:

- the attention + router buffer is **45–65%** of `cb1-wait`;
- the part covered by no GPU buffer is **5–15 ms per token**, below the Mac's
  16–17 ms, because the A19's CPU is faster.

Low confidence.

*Falsified by* either value outside its range.

**P4. The GPU is idle most of the time.** `busy` is **35–55%** of wall on every
case.

*Falsified by* a value outside that range.

**P5. Concurrent reads stretch per-read latency, and the file cache serves
little.** At 24 slots there are about 1.7 misses per layer on the short case,
8 × (1 − 0.791). Predict:

- the mean decode read at **2.5–4.5 ms**;
- under **25%** of decode reads below 0.5 ms.

The 0.5 ms cut separates file-cache hits from storage reads. iOS caches an
app's reads up to a knee between 1 and 4 GiB, but the app itself already holds
about 3.1 GB. Low confidence.

*Falsified by* either value outside its range.
