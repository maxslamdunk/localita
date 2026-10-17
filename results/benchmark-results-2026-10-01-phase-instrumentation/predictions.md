# Predictions: GPU execution time and per-read latency in the decode footers

Written 2026-10-01, before implementation, on branch
`phase-timing-gpu-and-read-latency` from `e46b8d1`.

## The change

Two new stderr footer lines on the CLI and the iOS benchmark harness. The
existing `[expert-io …]` and `[phase-time …]` lines are not changed.

- `[gpu-time …]`: GPU execution per decode forward, read from each command
  buffer's `gpuStartTime` / `gpuEndTime` after it has completed. Split by
  buffer: embedding, attention + router (`cb1`), shared expert, cache-hit
  experts, routed experts + reduce + layer tail, head. `busy` is the union of
  all of them; `idle` is `wall − busy`.
- `[read-latency …]`: a histogram of how long each routed-expert read takes,
  for decode and prefill separately, timed around `readFull` in
  `PreadExpertStreamer`.

The questions they answer: how `cb1-wait` splits between this layer's
attention and the previous layer's expert work, which the runner queues ahead of
it without waiting; how long the GPU sits idle per token; and how many expert
"misses" iOS actually serves from its file cache rather than from storage.

## Label

**Zero bytes/token change by construction.** The read path gains two clock
reads per expert read and one uncontended lock to record the result; no read is
added, removed or reordered. The ground is measurement of two named phases in
the `[phase-time …]` split, `cb1-wait` and `io`.

## Predictions

**P1. No change to the work done.** On the same seed and prompt, the new binary
reproduces the baseline's generated text byte for byte, and its bytes/tok,
hit rate, req/tok and reads/tok to the digit.
*Falsified by* any difference in any of those.

**P2. No measurable cost.** ms/forward delta 0 ± 1%. Mechanism: no new wait on
any GPU work that has not already finished, no extra GPU work, and on the order
of a hundred property reads per forward. *Falsified by* the new binary being
slower than the baseline by more than the spread between two runs of the same
binary, in an interleaved A/B. A 2+2 smoke run cannot resolve 1%, so it can only
falsify this at about the 3% level.

**P3. The new numbers are internally consistent.** Each guards the
instrumentation itself, not the hardware:
- the attention + router buffer's GPU time is less than `cb1-wait`, since the
  CPU's wait begins at commit and ends at completion, so it contains that
  buffer's execution by causality;
- `busy` is no more than `wall`;
- the read-latency histogram holds exactly as many reads as `reads/tok ×
  forwards`.

*Falsified by* any of these failing, which would mean a units or attribution
bug, not a finding.

**P4. Routed-expert GPU work is a large share of `cb1-wait`** (8 GB M1 host,
16 slots, short case). If decode GPU work is bound by memory bandwidth, its time
tracks the weight bytes each part reads. Per layer, the routed experts read
8 × 3.36 MB = 26.9 MB; everything else resident reads about
(1.35 GB − ~0.37 GB of embedding) / 30 ≈ 33 MB. So the cache-hit plus routed
buffers should be **30–50 ms/forward** of the Mac's ~90 ms `cb1-wait`.
Low confidence: the dims behind the 33 MB are estimated, not read from the
manifest. *Falsified by* hit + routed GPU time outside 20–60 ms/forward.

**P5. The GPU is idle for most of `io`.** During `io` the GPU runs only the
shared expert and any cache-hit experts. Predict `idle` at **50–95% of `io`**.
*Falsified by* `idle` outside that range.

**P6. On the Mac, few decode "misses" come from the file cache.** The host keeps
about 1.44 GB of file cache against a 12.01 GiB expert corpus, and a
file-cache read of 3.36 MB takes about 0.2–0.3 ms against about 2 ms from
storage. Predict **under 10% of decode reads below 0.5 ms**, with the mode in the
1–2 or 2–4 ms bucket. *Falsified by* 10% or more under 0.5 ms. No prediction is
made for the iPhone, which is the question the line exists to answer.
