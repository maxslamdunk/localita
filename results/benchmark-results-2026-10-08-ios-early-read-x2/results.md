# Results: two early reads per layer (fitted ×2) on the iPhone

Scored against [`predictions.md`](predictions.md), committed first in
`ec59268`. The phone build is `507642e`. Logs and texts are in
[`logs/`](logs/), the driver is [`run.sh`](run.sh)
([`driver.log`](driver.log)), and [`summarize.py`](summarize.py) prints every
figure below ([`summary-output.txt`](summary-output.txt)). A one-run smoke
check is in [`smoke/`](smoke/).

## Answer

**Two reads per layer are slower than one on the iPhone, by −25.9 / −14.6 /
−20.7% tok/s, with identical output. One read stays the default.**

The second read is right **0.39 / 0.45 / 0.49** of the time. Each wrong one
costs a full serial read, **1.7–2.0 ms**, and each right one saves almost
nothing. The prediction had the direction and mechanism right. It
underestimated the size on short and long, where the GPU also ran slower in
both ×2 runs.

| case | tok/s 1 → 2 reads | `io` ms/fwd | `cb1-wait` ms/fwd | bytes/tok (footer MB) | second-read precision | head GPU ms |
| --- | --- | --- | --- | --- | --- | --- |
| short | 6.950 → **5.150 (−25.9%)** | 81.81 → 117.30 (+35.49) | 47.43 → 59.25 (+11.82) | 188.84 → 245.91 | 0.386 | 8.27 → 10.19 |
| medium | 5.127 → **4.378 (−14.6%)** | 105.76 → 136.83 (+31.07) | 71.22 → 70.90 (−0.33) | 211.83 → 263.11 | 0.448 | 10.74 → 11.17 |
| long | 5.595 → **4.435 (−20.7%)** | 101.12 → 126.75 (+25.63) | 62.09 → 79.58 (+17.49) | 227.02 → 274.45 | 0.489 | 8.60 → 11.16 |

Means of two runs per arm. Second-read precision is Δused/token ÷ 29.

## What was run

`main` at `507642e`, built in Release and installed over the app. One binary:

- **A:** defaults, one early read per layer (`earlyExpertReads=1`).
- **B:** `--early-expert-reads 2` (`earlyExpertReads=2`).

Both arms used the bundled fitted guess (`@b18242445534d452…`), `F_NOCACHE`
and count aging. Every log's `runner-ready` line confirms its arm.

Each case ran A B B A, on 2026-10-08 from 22:37 to 00:07:

- 24 slots, `--max-new 1024 --max-context 4096`, prefill chunk `auto`;
- iPhone 17, iOS 26.6;
- a 300 s cooldown between runs.

The first attempt at 22:36 failed to launch with a dropped devicectl
connection (`NWError 54`) before any run
([`driver-failed-launch.log`](driver-failed-launch.log)). `run.sh` now
retries a launch up to three times.

Conditions:

- **Short:** every sample `nominal`. Battery 90–95%, charging.
- **Medium:** A1, B1 and B2 were `fair`/`nominal`, charging. A2 was `fair`
  for 11 samples and `serious` for 31, full.
- **Long:** every run `fair` for 3 samples and `serious` for 39, battery
  100% full, so the arms are thermally matched.

## Scoring

**Controls: held exactly.** In every case:

- all four texts share one hash: `d32db73b…`, `209ffadb…`, `87f6f357…`, the
  same as every run since the fitted guess;
- hit rate (79.5 / 75.9 / 73.7%) is identical across arms;
- early reads/token are 29.00 in A and **58.00** in B.

**P1, second-read precision 0.40–0.50: held on medium and long, just low on
short.** 0.386 / 0.448 / 0.489. That is Δused/token +11.19 / +12.99 / +14.19,
against a predicted +11.6 to +14.5. Short's 0.386 is inside the 0.35–0.55
falsifier band. Precision rises with prompt length, as the first read's does.

**P2, bytes/token +46 to +56 MB: held on medium and long, just high on
short.** +57.07 / +51.28 / +47.43. Reads/token rose by exactly the wasted
second reads: +17.82 / +16.01 / +14.81.

**P3, tok/s falls: the direction held, but short and long fell further than
the range.**

| case | predicted | measured |
| --- | --- | --- |
| short | −10 to −22% | **−25.9%** (miss, low) |
| medium | −6 to −18% | **−14.6%** (held) |
| long | −4 to −16% | **−20.7%** (miss, low) |

The falsifier, ×2 at or above one read on any case, did not fire. Every ×2
run was slower than every one-read run of its case.

**P3b, `io` +15 to +35 ms: held, short at the edge.** +35.49 / +31.07 /
+25.63 ms. Per wasted read that is **1.99 / 1.94 / 1.73 ms**: one serial read
each, as the mechanism says.

**P4, peak footprint +3 to +4 MB: held roughly.** +2.6 MB (short), +5.3 MB
(medium), +0.9 MB (long), from peak means of 3118.5–3122.6, 3230.1–3235.8 and
3383.9–3385.5 MB.

## Why short and long missed: the GPU, not storage

`io` alone accounts for the predicted range. With only `io` added to A's wall,
the losses would be **−19.8 / −13.6 / −12.5%**, all inside their ranges. The
rest is GPU work that got slower in the ×2 runs:

| case | GPU attention + router, A → B | head GPU, A → B |
| --- | --- | --- |
| short | 21.01 → 24.72 (+18%) | 8.27 → 10.19 (+23%) |
| medium | 34.75 → 34.00 (−2%) | 10.74 → 11.17 (+4%) |
| long | 32.63 → 43.37 (+33%) | 8.60 → 11.16 (+30%) |

The head runs after the last layer, with no early read in flight. So where it
is slower, the GPU was slower for the whole run, not just contended during
reads. On short and long both ×2 runs had a slow GPU and both one-read runs a
fast one. On long all four runs had the same thermal profile.

Two explanations remain, and these runs can't separate them:

- **Noise.** Whole-run GPU speed varies up to ~40% between runs at the same
  thermal state (`CLAUDE.md`). Medium, with matched GPU speed, shows the
  pattern does not always appear.
- **Caused by ×2.** Longer `io` leaves the GPU idle about 1 ms longer per
  layer between short bursts. That may let the GPU drop its clock, so each
  burst runs slower. `…-10-02-ios-next-layer-prefetch/results.md` also saw
  attention + router 0–3 ms slower whenever early reads ran, unattributed.

Four of six ×2 runs slow against none of six one-read runs is suggestive, not
settled. The test that would separate them is an A/B that lengthens `io`
without changing GPU work, such as fewer slots. If a longer GPU idle does slow
the GPU, then shortening `io` buys GPU speed too.

## Why the phone differs from the M1

On the M1 the same prediction, made from the same idle-window argument, was
wrong: two reads gained +11.5 to +14.8%
(`results/benchmark-results-2026-10-07-early-read-v3/results.md`). The M1's SSD reads
faster with two requests in flight. Here, each wasted second read costs one
full read, 1.7–2.0 ms, which is the phone's serial read time. So the phone's
storage gains nothing from a second request in flight, as the 2026-10-02
probe found.

The second read's right guesses save almost nothing: `io` rises by about
the wasted reads × one read time. A right second guess moves a read the
layer needed anyway into time storage was already busy.

## What this changes

- **One read stays the iOS default.** The decision rule required +3% on
  every case; every case lost.
- `CLAUDE.md`'s "two would not" is now measured, not inferred.
- The open item in CACHE-10 about the iPhone and two reads is closed.
- **Still open:**
  - Whether a longer `io` slows the GPU.
  - The adaptive idea in CACHE-10, which reads more only while storage is
    truly idle. The phone has no idle storage time left after the first
    read, so it has nothing to gain here.
