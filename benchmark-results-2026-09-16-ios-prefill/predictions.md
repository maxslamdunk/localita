# Predictions — iPhone 17 prefill chunk size, 2026-09-16

Written **before** the runs, per the working agreement in `CLAUDE.md`.

## What is being tested

`--prefill-chunk-tokens 256` against the production default of 128, at **32
expert-cache slots**, on all three frozen `real-generation-v1` cases. Chunk size
is the only variable: the 32-slot / chunk-128 runs from
`benchmark-results-2026-09-16-ios-slots/` are the baseline.

## Why, and why this is not a repeat

`docs/RUNTIME_CONTROLS.md` states the mechanism: chunks loop **outside** layers,
so each chunk re-reads that layer's routed experts and **read volume tracks
chunk count and nothing else**. That is also why prefill runs at a 0.0% cache
hit rate no matter how large the expert cache is — by the time a chunk comes
back to a layer, the cache has turned over. Only fewer chunks can help.

[PF-02](../docs/experiments/summaries/06-prefill.md#pf-02) tested 32 against 128
on an M2 and adopted 128. **256 is not untested** — `RUNTIME_CONTROLS.md`
records it as **16% faster than 128 on a 7,019-token prompt with byte-identical
output**, and the server already resolves `auto` to 256. What is untested is
256 **on this device**, where the balance between reads and compute differs: the
A19 is 26–33% faster than the M1 host on the compute phases, so a saving that is
mostly read-side should translate *better* here than it did on the Mac.

Memory is not a gate. The scratch is ~125.5 KB per chunk token over a fixed
328 KB, so 256 holds ~32.5 MB against 16.4 MB at 128 — **+16 MB**, against
~1.8 GB of headroom.

## Baseline (32 slots, chunk 128, measured 2026-09-16)

| case | prompt tok | chunks | prefill MiB | prefill s | decode s | tok/s |
| --- | --- | --- | --- | --- | --- | --- |
| short | 61 | 1 | 6,950.78 | ~1.4 | 72.38 | 7.005 |
| medium | 430 | 4 | 25,362.34 | ~24.1 | 102.25 | 6.181 |
| long | 3,015 | 24 | 183,609.53 | ~185.7 | 125.77 | 4.786 |

Prefill seconds are derived as `done − prompt-encoded − decode`, not measured
directly. ⚠️ The long baseline ran at thermal `serious` throughout, which the
thermal control measured as costing ~18% on the fetch path, so its prefill
figure is inflated by an unknown part of that.

## Predictions

- **P1 — prefill bytes.** Chunk count halves on medium (4 → 2) and long
  (24 → 12), and read volume tracks chunk count, so predict
  **−45 to −55%**: medium ~12,700 MiB, long ~91,800 MiB.
  *Falsified if* either falls by less than **40%**, which would mean read volume
  depends on something other than chunk count on this path.
- **P2 — the null control.** The short case is **one chunk at both sizes**, so
  predict **no change** in prefill bytes: 6,950.78 MiB, unchanged.
  *Falsified if* it moves by more than 2%. This is the control that catches a
  mislabelled or misconfigured run, which is why it is worth spending a run on.
- **P3 — prefill time.** The Mac measured 16% on a 7,019-token prompt. Predict
  the phone does **better than 16%**, because the compute half that ate the
  Mac's saving is 26–33% cheaper here: **−20 to −40%** on the long case.
  *Falsified if* the improvement is **≤16%**, which would mean my model of where
  prefill time goes is wrong — that it is compute-bound on the phone too, and
  reducing reads cannot help it much.
- **P4 — decode is untouched.** Chunk size affects only prefill, so decode
  ms/forward, bytes/token and hit rate should be unchanged within run-to-run
  noise. Predict **within 3%** of baseline on all three.
  *Falsified if* any moves more than 5%, which would mean chunk size leaks into
  the decode path.
- **P5 — output.** The Mac measured byte-identical output. Predict **identical
  generated token counts** (507 / 632 / 602).
  *Falsified if* any token count changes, which would mean chunk size perturbs
  numerics more on this GPU than on the Mac — a correctness question, not a
  performance one, and more important than the speedup if it fires.
- **P6 — memory.** Predict peak `phys_footprint` rises by **less than 100 MB**
  over the 3.77 GB baseline, consistent with the documented +16 MB of scratch.
  *Falsified if* it rises by more than 200 MB.

## Confounds

- **Thermal.** The baseline long run was at `serious`; these runs follow a
  cooldown and thermal is sampled every 16 tokens. If the new run is cooler than
  its baseline, P3's gain is **overstated** — the opposite of the slot matrix,
  where heat understated the gains. Compare thermal columns before believing the
  delta.
- **Artifact age and verification policy** are unchanged, so both cancel.
