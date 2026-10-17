# Context length on the iPhone 17: results

The predictions are in `predictions.md` beside this file, written before any
run. The binary is `19e6ef0` plus harness-only logging of the kernel's peak
footprint ledger. Settings: 32 expert-cache slots, prefill chunk 1024
(explicit), `--max-new 64`, sampling defaults. The artifact was installed
2026-09-16.

## The headline

**On this phone the practical memory ceiling is about 4.3–4.4 GB, not 5.60 GB.**
The 16K run was killed at **4.44 GB** with reason `proc-thrashing`, 8 minutes
into prefill. The app was not over its own limit. The whole system ran out of
pages, and jetsam had already killed dozens of daemons for `vm-pageshortage`
before it took the largest process.

Earlier jetsam reports on this phone show the same pressure one step earlier.
On 2026-09-18 and 09-19, with the app at **3.86–3.88 GB**, frontmost and
active, iOS killed **146–476 other processes** to keep it alive. That fits the
user's report (2026-09-24) that the phone lags during generation.

## Runs

| Run | Tokens held | `runner-ready` footprint | Peak footprint | Outcome |
| --- | --- | --- | --- | --- |
| 8K, `fill-8k` (7,012 prompt tokens) | 7,076 | 166.7 MB | **4.272 GB** (ledger peak) | done, `stop=maxTokens` |
| 16K, `fill-16k` (14,011 prompt tokens) | unknown, still in prefill | 172.0 MB | **4.44 GB** (jetsam `rpages` 270,797 × 16 KiB; lifetime max 270,991) | **killed**, `proc-thrashing`, about 8 min in |

The 16K log ends at `runner-ready`, because this harness logged nothing during
prefill. The kill is attributed from the jetsam report at 02:47 local time, 8
minutes after launch, which names `TurboFieldfareiOS` as the largest process.
Prefill now logs one line per chunk, so the next run will show how far it got.

Raw jetsam reports are **not** committed, because they list every process on
the phone. The fields used here:

| Report (local time) | Largest process | App footprint | App outcome | Other processes killed |
| --- | --- | --- | --- | --- |
| 2026-09-18 19:15 | TurboFieldfareiOS | 3.87 GB | survived (frontmost) | 476 |
| 2026-09-18 19:17 | TurboFieldfareiOS | 3.86 GB | survived (frontmost) | 146 |
| 2026-09-19 14:07 | TurboFieldfareiOS | 3.88 GB | survived (frontmost) | 172 |
| 2026-09-24 02:47 | TurboFieldfareiOS | **4.44 GB** | **killed, `proc-thrashing`** | dozens, `vm-pageshortage` |

## 8K run detail

- Prefill: 7,012 tokens in about 207 s (from `runner-ready` to token 0),
  68,835.16 MiB read, hit rate 0.0%.
- Decode, 63 forwards: 172.36 MiB per token (the footer prints MiB labelled
  MB), hit rate 77.6%, **4.561 tok/s**, thermal `fair`.
- Phase split (ms per forward): `io` 128.24, `cb1-wait` 78.47, `head` 7.94,
  wall 222.75.
- Decode is 64 tokens at one prompt, so it is not comparable with the
  `real-generation-v1` rows. Recorded for completeness.

## Scoring

- **P1, `runner-ready` independent of context: HELD.** 166.7 MB at 8K against
  172.0 MB at 16K, a 5 MB difference against the 50 MB falsifier. KV pages are
  committed lazily, so the context setting is a ceiling and only the tokens
  held cost memory.
- **P2, 8K peak 4.11–4.25 GB ±150 MB: HELD** at 4.272 GB, inside the band and
  under the 4.40 GB falsifier.
- **P3, 16K peak 4.26–4.40 GB ±150 MB: the memory arithmetic HELD. The
  conclusion drawn from it FAILED.** The app reached about 4.44 GB, inside the
  band, while still in prefill. P3's closing claim, "under 5.60 GB with more
  than 1 GB of margin, and 16K is offerable at 32 slots", is **falsified**. The
  ceiling it assumed does not bind first. System-wide thrashing does.
- **P4, decode slows with context: NOT TESTED** at 16K. The run did not reach
  decode.
- **Prefill time: HELD at 8K** (207 s against the predicted 3–5 min). Not
  tested at 16K.

## Consequences

1. **The measured-facts ceiling needs a caveat.** 5.60 GB is where jetsam
   kills the app for its own limit. Under a long prefill, which streams the
   routed-expert corpus through the file cache, the system runs out of pages
   first. The observed kill was at 4.44 GB.
2. **16K at 32 slots is not offerable.** 8K at 32 slots completed, but at
   4.27 GB it sits within about 170 MB of the observed kill point, and the
   earlier reports show iOS killing other processes from about 3.9 GB. The
   chat app runs 8K at 32 slots today.
3. **Slots and context are one budget.** Sixteen slots frees about 1.61 GB
   (measured 2026-09-16). In throughput, 32 slots measured +34 to +59% over
   16, so 16 slots runs 25–37% slower. The next
   runs should find the configuration that keeps the app below the level where
   iOS starts killing other processes, and measure the throughput it costs.
   Jetsam reports are the instrument: count the other processes killed in each
   run.

## Rerun of 16K, and a correction to the headline above

The user asked whether another app caused the kill. The kill report answers
that: the other 20 live processes held about 0.6 GB between them. The largest
were `kernel_task` (202 MB), `backboardd` (183 MB) and SpringBoard (133 MB).
Nothing large ran alongside.

The run was then repeated on the same binary, now logging phone-wide VM
counters and one line per prefill chunk, on a freshly restarted phone with
nothing else opened. Log: `logs/decode-ctx16k-r2-2026-09-24T015146Z.log`.

**It completed.** Prefill of 14,011 tokens took 497 s, reading 136,859.92 MiB.
Decode ran 64 tokens at **3.324 tok/s**: 169.00 MiB per token, hit rate
78.0%, `cb1-wait` 109.56 and `io` 158.79 ms per forward. Thermal went from
`nominal` through `fair` to `serious`, reaching `serious` at chunk 10.

| Point | Footprint | `sys-wired` | `sys-compressor` | Compressions (cumulative) |
| --- | --- | --- | --- | --- |
| `runner-ready` | 169 MB | 1,644 MB | 640 MB | 142K |
| after chunk 1 | **4.442 GB** | 3,420 MB | 3,616 MB | 511K |
| after chunk 7 | 4.443 GB | 3,273 MB | 4,136 MB | 4.23M |
| after chunk 14 (end of prefill) | 4.392 GB | 3,378 MB | 4,160 MB | 11.81M |
| decode, token 16 | 4.289 GB | **5,376 MB** | **1,812 MB** | 12.13M |

What this shows:

- **The footprint does not grow with tokens held.** It reaches 4.44 GB at the
  first chunk and stays flat. P3 expected about +215 MB of full-attention KV
  over the prefill, and that growth never appears. Either compression absorbs
  it inside the footprint accounting, or something else holds the footprint
  at a level. The data cannot tell which.
- **The compressor churns from the first chunk.** It adds 0.5–1.4M
  compressions per chunk, about 11.7M over prefill, holding about 4 GB. The
  phone is not near thrashing only at the end; it is thrashing throughout. That
  is the likeliest cause of the reported lag.
- **Decode wires about 2 GB more than prefill** and releases most of the
  compressor.
- **`sys-free` sat at 41–61 MB throughout, and was already 49 MB at launch.**
  iOS runs with almost nothing free as a matter of course. The
  `sys-free < 100 MB` part of P5 therefore discriminated nothing; it was a
  badly chosen criterion.

### P5 scored

**FALSIFIED on its main claim.** The rerun completed, where P5 predicted a
kill. The mechanism half held: compressor traffic climbed by 0.5–1.4M per
chunk, as predicted in size. The free-memory half, as above, discriminated
nothing.

### Revised consequences

These replace consequence 2 above, and qualify the headline.

1. **16K at 32 slots is a coin flip, not a hard failure.** Two runs in the
   same memory state gave one kill, about 8 min in, and one completion after
   8.3 min of prefill. It still cannot be offered: a chat that is sometimes
   killed while reading its prompt is not a setting.
2. **The practical ceiling stands as a caveat, not as a number.** 4.44 GB was
   both killed and survived. What is established is that at 32 slots with the
   1024 cap the app holds the phone in continuous compressor churn, well below
   5.60 GB.
3. **Fewer slots is the lever to test next.** It is the only large
   memory-funded term (1.61 GB between 16 and 32). The instrument is now in
   place: compressions per chunk, and whether the churn stops.
