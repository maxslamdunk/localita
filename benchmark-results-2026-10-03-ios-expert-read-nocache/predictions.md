# Predictions: expert reads past the OS file cache (`F_NOCACHE`) on the iPhone

Written before any run. The change: `TURBO_FIELDFARE_EXPERT_READ_NOCACHE=1`
(harness `--expert-read-nocache`) sets `F_NOCACHE` on each layer's expert file
when it is opened, so `pread` skips the OS file cache. Everything else is at
the defaults, including the early read with the fitted guess.

This is a quick first look: **short case only, A B B A**, one binary, 300 s
cooldowns. A = today's reads, B = `F_NOCACHE`. Medium and long follow only if
short looks promising.

Baseline for reference (short, early read on, fitted guess, 2026-10-03, two
runs, `benchmark-results-2026-10-03-ios-fitted-guess/`): 6.626 tok/s, `io`
78.48 ms/fwd, 59.34 reads/token, 190.09 footer MB/token, `read-latency` mean
3.81–3.90 ms.

## What moves

1. **`io`: −2 to −8 ms per forward** (B against A, mean of two runs each).
2. **`read-latency` decode mean: −0.1 to −0.4 ms.**
3. **tok/s: +1 to +5%.**
4. **The OS file cache shrinks:** `sys-filebacked` in the harness samples is
   lower in B, and compressions per token are no higher.

## Controls, which should not move

- Generated text: byte-identical, SHA-256 `d32db73b…` in all four runs.
- bytes/token 190.09 footer MB, hit rate 79.1%, reads/token 59.34, early
  used/token 19.83: exact.
- `cb1-wait` within the GPU-speed noise. Read `head`'s `[gpu-time]` beside it.

## Mechanism

Today each 3,358,720 B read goes through the unified buffer cache: the kernel
fills cache pages and then copies them into our slot buffer, and to make room
it evicts other file pages. The cache serves under 1% of our misses, so this
work buys nothing. The phone's storage probe read at slot size in about
2.04 ms per read (1.650 GB/s); inside the runtime a read takes 2.13–2.23 ms
(`benchmark-results-2026-10-02-ios-gpu-time/results.md`). If most of that gap
is the cache path, removing it saves up to about 0.1–0.2 ms per read. About
30 demand reads per token wait in `io` one after another, which gives the
`io` range above. Early reads are mostly hidden, so their saving counts for
less.

## What would falsify it

- `io` moves by less than 2 ms, or rises: the cache path is not what separates
  the runtime from the probe, and `F_NOCACHE` is neutral here as it was on the
  Mac (IO-03).
- Any control moves: the change did something other than skip the cache.
