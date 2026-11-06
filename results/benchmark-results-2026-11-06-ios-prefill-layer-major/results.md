# Results: prefill layer at a time across chunks

Scored against [`predictions.md`](predictions.md), which was committed first
in `15ad5b6`. Its trusted-load addendum was written after long A1, B1 and B2
and committed in `062a330`, before the trusted runs. The logs are in
[`logs/`](logs/) and [`mac-check/`](mac-check/). The drivers are
`run-mac-check.sh`, `run-ab.sh` and `run-trusted.sh`, all over `lib.sh`.
`summarize.py` prints the figures ([`summary-output.txt`](summary-output.txt)),
and `measurement_rows.py` prints the `MEASUREMENTS.md` rows.

## What was run

- **Binary:** branch `prefill-port` at `15ad5b6`, whose code is `7e239c3`.
  - **Phone:** iOS app Release, installed over the app.
  - **Mac:** `TurboFieldfareCLI` release.

  One binary per host. Arm A is the default (layer at a time). Arm B is
  `--no-layer-major-prefill` on the phone and
  `TURBO_FIELDFARE_PREFILL_LAYER_MAJOR=0` on the Mac.
- **Mac check:** M1 MacBook Air 8 GB, macOS 26.6.1, 2026-11-06 01:35–01:42.
  Greedy, `--max-new 48`, defaults otherwise (16 slots, chunk 128), so medium
  is 4 chunks and long is 24. Each arm ran once.
- **Phone:** iPhone 17, iOS 26.6. `real-generation-v1` prompts, prompt
  SHA-256 checked. 24 slots, `--max-context 4096`, chunk `auto`, defaults
  otherwise. **`--max-new 32`**, because only prefill changes. 60 s before the
  first run and 300 s between runs. Battery 30%, charging; network on.
  - **Main set,** hashed load as the benchmark runs: 02:26–03:08. Long and
    medium A B B A, `nominal` at every sample.
  - **Trusted set,** `--trust-install`: 03:12–03:33. Long A B B A. Thermal
    reached `fair` in B1, B2 and A2.

## Scoring

### Phone, long (3015 tokens, 3 chunks), hashed load

| | A | B | change |
| --- | --- | --- | --- |
| prefill wall, s | 44.10, 45.51 | 54.49, 54.55 | **−9.7 s (−17.8%)** |
| prefill bytes, MiB | 11,140.47 | 30,561.02 | **−63.5%** |
| reads | 3,478 | 9,541 | −63.5% |
| routed phase, s | 4.07, 4.25 | 16.62, 16.75 | −12.5 s |
| storage busy, s | 1.58, 1.58 | 15.63, 15.80 | |
| GPU routed, s | 3.27, 3.49 | 4.39, 4.34 | −23% |
| GPU attention block, s | 20.01, 21.25 | 19.18, 19.12 | +7% |
| GPU shared, s | 16.73, 16.71 | 16.78, 16.82 | 0% |
| peak footprint, GB | 3.514, 3.512 | 3.380, 3.382 | **+132 MB** |

- **Reads 3,700–3,840: missed, low.** 3,478 reads, about 116 of each layer's
  128 experts. The prediction assumed nearly every expert is used over 3015
  tokens; about 12 per layer are not. The Mac read 3,471.
- **Bytes 11,850–12,300 MiB (−60 to −61%): missed, low.** 11,140.47 MiB,
  −63.5%. The miss follows from the reads.
- **Routed phase 6–10 s: missed, low.** 4.07–4.25 s. Storage was busy only
  1.58 s for 11 GB, at a mean of 2.19 ms a read, so the reads came mostly
  from the file cache. The first-touch SHA-256 of a layer file reads it
  sequentially just before that layer's routed step runs. Chunk by chunk,
  only chunk 1 follows the hash closely enough to find its pages still cached.
  The trusted set measures the case with no hash.
- **Wall 43–49 s (−6 to −12 s): held.** 44.10 and 45.51 s, −9.7 s. The
  routed phase saved 12.5 s. The attention block's wall rose 2.3–3.5 s
  (21.63, 22.85 against 19.35, 19.31) and gave some of it back. GPU attention
  rose less, 0.8–2.1 s. In the trusted set, with no hash, A's attention block
  is not slower than B's. So the hash running beside attention is the likely
  cost; it was not separated.
- **Peak footprint +150 to +230 MB: missed, narrowly low.** +132 MB, against
  186.93 MB of prompt-wide buffers. The footprint counts the buffers, but
  where B's own peak falls was not traced.
- **Text byte-identical: held.** `30e14eae…` in all four runs, the same as
  step 2's.
- **GPU routed within ±25% of B: held,** −23%. Larger same-expert tiles over
  the whole prompt make the routed kernels faster too.
- **GPU attention block and shared within ±10%: held for shared, borderline
  for attention.** A2's attention block is +11%; A1's is +4%.
- **No falsifier fired.** Reads are under 4,000, the wall gained more than
  4 s, the footprint grew by less than 300 MB, and the text matches.

### Phone, medium (430 tokens, one chunk): the control

| | A | B |
| --- | --- | --- |
| prefill wall, s | 10.27, 10.21 | 10.06, 9.77 |
| prefill bytes, MiB | 8,882.27 | 8,882.27 |
| text | `28ca6ef4…` | `28ca6ef4…` |

**Held.** Bytes and reads (2,773) are identical, and so is the text. Wall is
+0.3 s (+3.3%), within run-to-run noise. Medium takes the chunk path in both
arms.

### Phone, long, trusted load (addendum)

| | A | B | change |
| --- | --- | --- | --- |
| prefill wall, s | 46.94, 54.52 | 65.59, 68.94 | **−16.5 s (−24.6%)** |
| routed phase, s | 8.65, 9.07 | 23.94, 24.35 | −15.3 s |
| storage busy, s | 8.38, 8.34 | 23.47, 23.81 | |
| read mean, ms | 11.15, 11.15 | 11.55, 11.72 | |
| GPU busy, s | 39.54, 47.86 | 44.35, 46.51 | |

- **Bytes exact as hashed: held.** 11,140.47 and 30,561.02 MiB.
- **A wall 43–50 s: held for A1 (46.94), missed for A2 (54.52).** A2's GPU was
  slower throughout, not its routed phase: attention block 24.61 against
  A1's 19.77 GPU seconds, and shared 18.97 against 16.49, at `fair`. That
  matches the known run-to-run GPU spread.
- **B 58–70 s: held.** 65.59 and 68.94 s.
- **A − B −12 to −22 s: held.** −16.5 s.
- **Routed phase under 12 s: held.** 8.65 and 9.07 s, bound by about 11 GB of
  random reads at about 11 ms each.
- **Text: held.** `30e14eae…` in all four runs.

The trusted figures are the closer guide to a new chat on an already-loaded
model, which does not hash. There the saving is larger: −16.5 s against
−9.7 s, because B's routed phase is longer without the hash's cache warm.

### Mac check

| case | A | B |
| --- | --- | --- |
| long, wall | 74.45 s | 239.56 s |
| long, bytes | 11,118.05 MiB | 183,539.06 MiB (**−93.9%**) |
| medium, wall | 12.01 s | 27.92 s |
| medium, bytes | 8,885.47 MiB | 25,512.89 MiB (−65.2%) |
| text | identical: long `327852ac…`, medium `38a3bf14…` | |

**Held**: the text is identical, and long bytes fell by more than 80%. Mac
decode over 48 tokens was 2.988 against 1.725 tok/s on long, at near-equal
bytes/token (336.19 against 332.44 MB). This is not a control; B's 183 GB
prefill through the Mac's file cache is a candidate cause, unmeasured.

## Decision

**Kept, on by default.** It applies to a prompt from an empty KV that needs
more than one chunk, up to 4096 tokens. Output is byte-identical by
construction and on both hosts, so this is no quality trade.
`--no-layer-major-prefill` / `TURBO_FIELDFARE_PREFILL_LAYER_MAJOR=0` keeps
chunk by chunk.

On the long benchmark prompt, step 2 and step 3 together take prefill from
67.67 s (`results/benchmark-results-2026-11-04-ios-prefill-breakdown/`, its
hashed plain run) to 44.1–45.5 s. The remaining wall is GPU work: the
attention block (~20 s) and the shared expert (~17 s), with the routed phase
now 4–9 s.

## Notes

- Only the first turn of a chat qualifies. A later turn starts after cached
  tokens, and a failed turn there would rewind into SWA ring slots that this
  order has already overwritten. At position 0 a failure restarts from a
  reset.
- Each layer-at-a-time run logs 30 progress lines, one per layer, where the
  chunk path logs one per chunk.
- Decode bytes/token over 32 tokens moved: 273.61 against 271.03 MB. Decode
  starts from whatever each layer's cache holds after prefill, which now
  differs. This was not a control, and 1024-token decode was not measured.
- Credit: the idea of running prefill's layers outside its chunks is from
  zw5/ane-fieldfare `c17d0c2`; see `THIRD_PARTY_NOTICES.md`.
