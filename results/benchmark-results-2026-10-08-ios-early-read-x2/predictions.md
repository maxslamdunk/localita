# Predictions: two early reads per layer (fitted ×2) on the iPhone

Written before any phone run with two reads. The runtime gained
`TURBO_FIELDFARE_EARLY_EXPERT_READS` and the harness `--early-expert-reads <n>`
in the same change as this file; the default stays one read.

## Why run it

The phone's one-read default was set by arithmetic, not a measurement. Storage
idles about one read per layer (1.88 / 2.26 / 2.47 ms against 2.13–2.23 ms
per read, `results/benchmark-results-2026-10-02-ios-gpu-time/results.md`), so a second
read "would not fit". On the M1 the same argument predicted −3 to +8% and two
reads measured **+11.5 / +13.7 / +14.8%** over one
(`results/benchmark-results-2026-10-07-early-read-v3/results.md`), because the M1's SSD
reads faster at queue depth 2. `results-two-reads.md` in
`results/benchmark-results-2026-10-05-mac-upstream-early-read/` says to measure the
iPhone rather than infer it.

## The run

One binary, `run.sh`. Defaults in both arms: early read on, bundled fitted
guess, `F_NOCACHE`, count aging, 24 slots, `--max-new 1024 --max-context
4096`, prefill chunk `auto`, Release.

- **A:** one early read per layer (`earlyExpertReads=1` in `runner-ready`).
- **B:** `--early-expert-reads 2` (`earlyExpertReads=2`).

Each case runs A B B A, with 300 s cooldowns, on all three
`real-generation-v1` cases. `summarize.py` prints every figure.

## Predictions

### Controls, exact

- **Text:** the same SHA-256 in all four runs of each case.
- **Hit rate and `needed`:** identical across arms. The cache plans without
  looking at the early read.
- **Early reads/token:** 29.00 in A, **58.00** in B. There are 30 layers, and
  128 experts against 24 slots always leaves two uncached.
- **The first read is unchanged:** read 1 in B is the same expert A reads, so
  B's used/token minus A's is the second read's hits alone.

### What moves

1. **The second read's precision, Δused/token ÷ 29: 0.40–0.50, point 0.45.**
   The offline study at 24 slots gives fitted P@1 0.726 and P@2 0.589. So the
   second read lands 2 × 0.589 − 0.726 = **0.452** of the time
   (`results/research-results-2026-10-02-next-layer-prediction/results.md`). Live P@1
   matched offline within 0.011 on every case
   (`results/benchmark-results-2026-10-03-ios-fitted-guess/results.md`).
   That is **Δused/token +11.6 to +14.5**.
2. **bytes/token: +46 to +56 MB (footer MiB), point +51.** That is about
   +20 to +29% of the case. Reads/token rise by the second read's misses,
   29 × (1 − p₂) = 14.5–17.4, at 3.203 MiB each.
3. **tok/s falls:**

   | case | range | point |
   | --- | --- | --- |
   | short | −10 to −22% | −17% |
   | medium | −6 to −18% | −12% |
   | long | −4 to −16% | −10% |

   `io` rises by about the same time, **+15 to +35 ms per forward**.
4. **Peak footprint:** +3 to +4 MB, one more staging buffer.

## Mechanism

Phone storage serves one read at a time, and concurrent reads only stretch
each other (`CLAUDE.md`). The per-layer idle window W is already filled by
read 1. So read 2 runs in time that layer L+1's own misses would otherwise
use:

- **Read 2 used (p₂ ≈ 0.45):** a read L+1 needed anyway, done slightly
  earlier. It saves no storage time. Its only gain is the part of W that read 1
  left empty: W − r ≈ 0 on short, a few tenths of a ms on long.
- **Read 2 wasted (≈ 0.55):** one full read, r ≈ 1.6–2.2 ms. (`F_NOCACHE`
  cut 0.5–0.67 ms from mean read latency since the 2.1–2.2 figure.) It lands
  in front of L+1's misses.

Net per layer ≈ (1 − p₂)·r − max(0, W − r), about **+1.0 / +0.85 / +0.7 ms**.
Over 29 transitions that is about **+30 / +25 / +20 ms** per token, against
the latest default-config walls of 142 / 181 / 175 ms
(`results/benchmark-results-2026-10-03-ios-expert-read-nocache/`, B arm).

The M1 escaped this because two requests in flight read faster than one there:
1.29 against 1.63 GB/s (2026-08-10 queue-depth probe). The phone's probe found
no such gain.

## What would falsify it

- **tok/s at or above A on any case** where head GPU time matches within 5%.
  This would mean the phone's storage, with `F_NOCACHE`, does gain from a
  second request in flight, or the idle window is larger than measured. The
  mechanism above would be wrong, as it was on the M1.
- **p₂ outside 0.35–0.55:** the offline P@2 does not transfer live.
- **Any control moving:** a changed text, hit rate or `needed`, or early
  reads/token ≠ 58.00 in B. B would then be doing something other than
  reading a second expert.

## Decision rule

The iOS default becomes two reads only if B beats A on all three cases. On
each case, the margin must be at least +3% in a pair where head GPU time
matches within 5%. Otherwise one read stays, and the result is recorded in
`docs/RUNTIME_CONTROLS.md` and the CACHE summary either way.

## Noise to read beside it

- About 8% run to run.
- Whole-run GPU speed differs by up to 40% between runs: compare `[gpu-time …
  head]` before reading `cb1-wait`.
- `serious` thermal costs about 12%, mostly in `io`, the phase this run moves.
  Long runs were `fair` for most samples in every recent A/B.
