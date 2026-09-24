# 24 expert-cache slots on the iPhone 17 — protocol re-run

A measurement, not an optimization, so there is no bytes/token prediction to
score. It re-runs `real-generation-v1` at the new iOS default (24 slots, since
`807065e`). It was prompted by the chat screen showing 7.5–7.8 tok/s at 24 slots,
against the 6.0 tok/s the Settings sheet quotes from 2026-09-16.

## Setup

- **Binary:** `807065e` plus the harness logging change committed alongside
  this file (Low Power Mode and uptime added to the log). Built **Release**,
  installed over the existing app. The previous install was a Debug build.
- **Device:** iPhone 17, 8 GB, iOS 26.6. Model side-loaded on 2026-09-16, so
  it was **8 days old** at these runs. 40.3–41.0 GB free on the volume.
- **Protocol:** `--autorun --case <id> --slots 24 --max-new 1024
  --max-context 4096`. Prefill chunk `auto` (resolved to 64 / 512 / 1024),
  temperature 0.2, Top-K 64, Top-P 0.95, seed 1, `.fullSha256`. Each log's
  prompt SHA-256 matches the canonical hash, and each log states `slots=24`.
- **Order:** short, medium and long back to back, about 2 minutes apart. Then a
  7-minute cooldown and a second medium run.

## Results

| run | tok/s | bytes/tok (MiB) | hit | reads/tok | io | cb1-wait | head | wall | fetch GB/s | compressions/s | thermal | peak footprint |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| short | **5.752** | 160.71 | 79.1% | 50.17 | 105.22 | 52.33 | 9.43 | 174.21 | 1.60 | 4.8K | nominal throughout | 3.109 GB |
| medium | **4.081** | 187.08 | 75.7% | 58.40 | 155.62 | 68.94 | 11.01 | 245.43 | 1.26 | **23K** | nominal → fair (from token ~400) | 3.234 GB |
| long | **3.943** | 204.59 | 73.4% | 63.87 | 143.87 | 89.64 | 10.90 | 254.01 | 1.49 | 10.7K | fair from start → serious (last ~60 tokens) | 3.378 GB |
| medium r2 (cooled) | **4.895** | 187.08 | 75.7% | 58.40 | 120.36 | 65.69 | 10.33 | 204.62 | 1.63 | 6.0K | nominal (fair on 3 of 42 samples) | 3.224 GB |

Phase columns are ms per decode forward. Fetch is 3,358,720 B ÷ (`io` ÷ reads/tok).
Compressions/s is the phone-wide compressor counter's delta from `start` to
`done`, divided by elapsed time, so it includes prefill. All four runs ended
`stop=endOfTurn` with 507 / 632 / 602 / 632 new tokens. Battery 100%/full and
Low Power Mode off throughout. Prefill took about 9 / 11 / 75 / 11 s.

Against 2026-09-16 at 24 slots (6.028 / 5.079 / 4.328 tok/s, prefill chunk
128, a 0-day-old artifact):

- **The workload is identical.** Short bytes/token (160.71 MiB) and hit rate
  (79.1%) match to the digit, and medium is within 0.5%. Every difference
  below is therefore time, not bytes.
- **Short −4.6%**, `io` +6.6%, fully `nominal`. That is inside the ~8% device
  variance recorded on 2026-09-16.
- **Medium −19.6% on the first run, −3.6% on the cooled re-run.** The two
  medium runs read byte-identical data and differ by **29% in `io`** (155.62
  against 120.36). The first was `nominal` for its first ~400 tokens and was
  already slow then.
- **Long −8.9%**, `fair` to `serious`. That is the documented thermal signature:
  `io` +12.9% while `cb1-wait` moved +5.5%.

## What moves the number

1. **Memory-compressor churn is the strongest candidate, with n=2.** The
   compressor counters were added to the harness today, and this is the first
   protocol comparison with them in the log. The slow medium run compressed at
   **23K pages/s**, the cooled re-run at **6K/s**, and fetch fell from 1.63 to
   1.26 GB/s. The short run (4.8K/s) fetched at 1.60. Both medium runs sat at
   `nominal` for most of their length, so thermal state does not separate them.
   Phone-wide free memory stayed at 40–140 MB and wired memory at ~5.1–5.3 GB
   in every run. With so little slack, whatever else the phone does in the
   background competes for the file cache and the CPU. **Not established:**
   this shows two runs moving together, not the mechanism, and nothing on the
   phone records what caused the churn.
2. **Thermal.** The long run reached `serious`; the earlier finding that
   `serious` hits the fetch path rather than the GPU still holds.
3. **Artifact age.** This artifact is 8 days old against 0 h on 2026-09-16.
   The cooled medium re-run lands within 4% of the 0 h figure, so any age
   penalty is small next to the run-to-run spread. It is not separable here.
4. **Not factors in these runs:** Low Power Mode (off), battery (100%/full
   throughout), prefill chunk size (it does not touch decode bytes, which
   match), and slot count (verified in every log).

## The 7.5–7.8 tok/s seen in the chat

The chat footer uses the same formula as the harness: tokens divided by
elapsed decode time. The difference is the workload, not the metric. Within the
short protocol run, individual 16-token windows ranged from **4.12 to 8.58
tok/s**. Stretches of text whose routing stays within the cached experts decode
well above the run average. A short reply to a conversational prompt can
average 7.5–7.8 on a cool phone with a quiet compressor. That is a real
number, but it is not comparable with a protocol row. To make it one, run
that prompt through the harness with `--prompt`, where it is logged as
`ad-hoc-NOT-COMPARABLE`.

## Standing values at 24 slots

Quote the cleanest run of each case, with its conditions: **5.752 / 4.895 /
3.943 tok/s** (short nominal, medium nominal after cooldown, long fair →
serious). The long figure understates a cool-phone rate. The Settings
sheet's "about 6.0 tok/s" remains a fair short-case summary.
