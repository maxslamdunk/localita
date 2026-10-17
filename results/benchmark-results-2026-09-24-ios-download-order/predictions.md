# Predictions: does the in-app download read slower on the iPhone 17?

Written before the download has run and before any benchmark. This is a
measurement of the fetch path (`io`), not an optimization. The prediction is
**0 bytes/token**: the downloaded model is byte-identical to the side-loaded one,
so hit rate and bytes/token must match to the digit, and only `io` may move.

## The two copies

- **Side-loaded (A):** `gemma4.gturbo`, pushed by `devicectl` on 2026-09-16, so
  about 8 days old at the runs. Its write order is unknown. A file copy most
  likely writes each layer file front to back.
- **Downloaded (B):** `gemma4-download.gturbo`, written by the in-app installer.
  That is `RemoteStreamingRepacker`, whose `RangeCopyPlanner.coalesce` orders
  writes by source offset, so each `layer_NN.bin` is written scattered. It will
  be about 0 hours old.

The two differ in **write order and in age**, and nothing here can separate
the two. On the Mac, the two effects push in opposite directions: fresh reads
faster, while scattered reads slower. Mac cells at the production read size
(GB/s): 0 h sequential **2.30**, 25 h sequential **2.08**, 0 h shuffled
**1.78**. None of this has been measured on the phone.

## Protocol

- The harness, `--autorun --case short --slots 24 --max-new 1024
  --max-context 4096`, chunk `auto`, all other settings at their defaults.
  Copy B is selected with `--model-dir gemma4-download.gturbo`.
- **The runs alternate A, B, A, B, A, B, with at least 5 minutes of cooldown
  between runs.** Short case only, because medium and long reach `fair` or
  `serious` thermal, which costs 11.6% on `io` alone.
- Thermal state, compressions per second and free memory are logged with every
  run. On 2026-09-24, two identical medium runs differed by 29% in `io`.

## Predictions

| # | Prediction | Falsifier |
| --- | --- | --- |
| D1 | **Bytes/token and hit rate are identical** between A and B (160.71 MiB, 79.1% on the short case at 24 slots). | Any difference. That would mean the two copies are not the same model. |
| D2 | **B's median `io` is 5–20% above A's.** If the Mac carries over, B is scattered but fresh (like 1.78) and A is sequential but aged (like 2.08): ×1.17 read time. Age claws some of that back. | B's median `io` is at or below A's. On the phone, then, write order does not cost what it costs on the Mac, or freshness outweighs it. |
| D3 | **The per-arm spread is under 10%** on the short case at `nominal`. | A spread of 10% or more within one arm. Then three runs per arm cannot resolve a 5–20% effect, and D2 is unreadable either way. |

## How the result is read

- **If D2 holds** (B is slower beyond the per-arm spread), add a finishing step
  to the in-app installer that rewrites each layer file front to back, like
  `Scripts/probes/seqrewrite.c`, with an atomic rename per file and the hash
  checked before each rename. It then needs its own prediction and
  measurement.
- **If D2 is falsified,** ship the download as it is. Record that on the phone,
  at 0 hours, write order is not a cost. Age remains unmeasured.
- **If D3 fails,** report the result as inconclusive and don't act on it.
- Copy B is deleted afterwards, with the user's OK. Copy A is never touched.
