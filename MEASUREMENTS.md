# MEASUREMENTS

Append-only run log for TurboFieldfare. Every real-model run gets one row.

## Rules

**Do not edit or delete an existing row.** Not to fix a typo, not to correct a number, not to tidy formatting. A row records what was observed at a moment on a specific commit; rewriting it destroys the only record of what was actually true then.

- To correct a row, append a new row and reference the superseded date + SHA in its notes.
- To retract a row, append a new row saying so. Leave the original.
- Rows are appended at the bottom, newest last.
- One row per run. Do not average several runs into a single row — append each, and note the relationship.
- Runs that failed, regressed, or disproved a prediction get rows too. A log that only contains wins is not a measurement record.
- Fill every column. Use `?` for genuinely unknown, never a guess or a carried-over value from an earlier row.

Accepted current values live in the Measured facts table in `CLAUDE.md`; when a row here supersedes one, update that table in the same change. What has been tried and why it was kept or abandoned goes in `docs/PRIOR_ART.md`.

## Column definitions

| Column | Meaning |
| --- | --- |
| Date | `YYYY-MM-DD` of the run. |
| SHA | Short git SHA of the checkout, plus `-dirty` if the tree was not clean. |
| Config | Host, then the controls that differ from production defaults (4K context, 16 slots, LFU, prefill on / 128-token chunks, RDADVISE off, temp `0.2` / Top-K `64` / Top-P `0.95`). Write `defaults` when nothing differs. |
| Bytes/token | Steady-state decode bytes read per token. Note prefill separately in notes; the two are not comparable. |
| Hit rate | Expert-cache hit rate over the measured window. |
| tok/s | Decode rate from the timing footer. |
| Thermal | `nominal` / `fair` / `serious` / `critical`, observed during the run. |
| Notes | Prediction vs. measured delta, prompt or benchmark used, anomalies, supersedes/retracts references. |

## Runs

| Date | SHA | Config | Bytes/token | Hit rate | tok/s | Thermal | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-09 | 417f389-dirty | M1 MacBook Air 8 GB, macOS 26.6.1 (25G76), Swift 6.3.3; defaults, seed 20260721 | ? | ? | 3.340 | nominal | Community protocol `real-generation-v1` short-explanation, 61 prompt / 511 new, decode 153.00s, `stop=endOfTurn`. Discarded warmup on same case: 3.271 tok/s (+2.1% measured vs warmup). Bytes/token and hit rate `?` — no counter exists on the `pread` path or expert cache; `rdadviseMegabytesPerToken` reads zero under RDADVISE off. `-dirty` = 8 untracked markdown/config files only, no source changes; binary is a faithful build of 417f389. Companion rows: medium-review + long-synthesis, same session. |
| 2026-08-09 | 417f389-dirty | M1 MacBook Air 8 GB, macOS 26.6.1 (25G76), Swift 6.3.3; defaults, seed 20260722 | ? | ? | 3.053 | nominal | Community protocol `real-generation-v1` medium-review, 430 prompt / 669 new, decode 219.16s, `stop=endOfTurn`. Discarded warmup on same case: 2.996 tok/s (+1.9%). Bytes/token and hit rate `?` — see companion short-explanation row. Companion rows: short-explanation + long-synthesis, same session. |
| 2026-08-09 | 417f389-dirty | M1 MacBook Air 8 GB, macOS 26.6.1 (25G76), Swift 6.3.3; defaults, seed 20260723 | ? | ? | 2.642 | nominal | Community protocol `real-generation-v1` long-synthesis, 3,015 prompt / 604 new, decode 228.59s, `stop=endOfTurn`. Discarded warmup on same case: 2.729 tok/s (−3.2%). Bytes/token and hit rate `?` — see companion short-explanation row. Cross-host observation, not a measurement of this run: identical token counts to the 16 GB M1 Air in issue #76 (7.802 / 7.173 / 6.093) give a 2.34× / 2.35× / 2.31× ratio at fixed SoC; mechanism unverified without byte counters. Companion rows: short-explanation + medium-review, same session. |
| 2026-08-10 | 417f389-dirty | M1 MacBook Air 8 GB, macOS 26.6.1 (25G76); host I/O probe, **no model run** — model directory untouched | n/a | n/a | n/a | nominal | Standalone `pread` probe at production slot granularity (3,358,720 B), plain `O_RDONLY` as in `PreadExpertStreamer`, one 2 MiB-aligned reusable buffer, 6 GiB non-sparse file on the model's volume (`disk3s5`), working set swept 128 MiB → 6 GiB, 200 reads/pass, two runs, file deleted after. **SSD (≥4 GiB working set): 2.7–3.2 GB/s, 1,065–1,245 µs/read, cold ≈ warm. Page cache (≤256 MiB): 15.0–17.4 GB/s, 193–223 µs/read. Knee 256 MiB–1 GiB.** `vm_stat` at idle: File-backed 87,652 pages = 1.44 GB; free 137 MB; 564,005 pages in compressor. Purpose: explain the 2.3× gap vs the 16 GB M1 Air in issue #76, referenced by the row above. Result — 806.1 MB/token demand ceiling (30 layers × top-8 × 3,358,720 B) at 2.83 GB/s = 285 ms, i.e. 95% of our 299.4 ms token budget, so our rate is SSD-bound; the 16 GB host's 128.2 ms budget cannot source 806.1 MB from any M1 SSD, so ≥50% of its expert bytes must come from the OS page cache. This supersedes the "mechanism unverified" note in the row above by bandwidth arithmetic, not by direct instrumentation — hit rate and true bytes/token remain uninstrumented, and the 16 GB host's SSD roof is assumed equal to ours, not measured. Not a `real-generation-v1` run: tok/s is `n/a` and these numbers are not comparable to the decode rows. |
