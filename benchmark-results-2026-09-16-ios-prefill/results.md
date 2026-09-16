# Results — iPhone 17 prefill chunk size, 2026-09-16

Scored against `predictions.md`, committed in `46801c8` before these runs.
Three runs at `--slots 32 --prefill-chunk-tokens 256`, against the 32-slot /
chunk-128 runs from `benchmark-results-2026-09-16-ios-slots/`. Chunk size is the
only variable. Every log carries `slots=32 prefillChunk=256 prefill=chunked`, so
the configuration is verified from the run itself rather than from its label.

## Measured

Prefill seconds are **derived** as `done − prompt-encoded − decode`, not measured
directly.

| case | chunk | chunks | prefill MiB | prefill reads | prefill s | decode s | tok/s | peak footprint | thermal |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| short | 128 | 1 | 6,950.78 | 2,170 | 10.1 | 72.38 | 7.005 | 3.770 GB | nominal |
| short | **256** | 1 | 6,950.78 | 2,170 | 10.8 | 66.74 | **7.596** | 3.785 GB | nominal |
| medium | 128 | 4 | 25,362.34 | 7,950 | 24.2 | 102.25 | 6.181 | 3.768 GB | nominal→fair |
| medium | **256** | 2 | 15,317.34 | 4,782 | 16.5 | 101.88 | **6.204** | 3.803 GB | nominal |
| long | 128 | 24 | 183,609.53 | 57,363 | 185.7 | 125.77 | 4.786 | 3.771 GB | serious |
| long | **256** | 12 | 104,248.91 | 32,546 | 125.8 | 115.63 | **5.206** | 3.808 GB | fair/nominal/serious |

End-to-end wall time on the long case: **313.4 s → 243.3 s, −22.4%**.

Against the original 16-slot / chunk-128 baseline, the combined configuration
(32 slots, chunk 256) is **+72.8 / +56.6 / +45.8%**, i.e. **2.03× / 1.85× /
1.74×** the Mac host's 3.745 / 3.346 / 2.987.

## Scoring

- **P2 — the null control. HELD, exactly.** Short is one chunk at both sizes and
  its prefill bytes were **identical to the digit** (6,950.78 MiB, 2,170 reads),
  as were decode bytes/token (103.68 MiB) and hit rate (86.5%). The control was
  worth the run: it is what licenses believing the other two.
- **P1 — prefill bytes. FALSIFIED on medium, missed low on long.** Predicted
  −45 to −55% with a falsifier at 40%. Measured **−39.6% (medium)** — four
  tenths of a point past the falsifier — and **−43.2% (long)**, outside the band
  but not falsified. Read counts agree (−39.8%, −43.3%), so this is real and not
  a byte-accounting artifact.
  **Why:** halving the chunk count does not halve the bytes, because per-chunk
  read volume *grows* with chunk size — 6,341 → 7,659 MiB/chunk on medium
  (+20.8%) and 7,650 → 8,687 on long (+13.6%). A 256-token chunk routes to more
  distinct experts than a 128-token one. ⚠️ This refines the statement in
  `docs/RUNTIME_CONTROLS.md` that "read volume tracks chunk count and nothing
  else": chunk count is the dominant term, but per-chunk volume is a real second
  term, and assuming a clean halving over-predicts the saving by ~6–10 points.
- **P3 — prefill time. HELD, and it beat the Mac.** Predicted better than the
  Mac's 16%, band −20 to −40%, falsified at ≤16%. Measured **−31.9% (medium)**
  and **−32.3% (long)**. The reasoning behind the prediction — that the A19's
  faster compute means a read-side saving translates better here than on the M1
  — survives its test.
  ⚠️ **But the thermal confound flagged in the prediction fired, in the
  direction that inflates this number.** The long baseline ran at `serious`
  throughout; this run was `fair`/`nominal`/`serious`, i.e. cooler for part of
  it. The thermal control measured `serious` as costing ~18% on the fetch path,
  so an unknown part of the 32.3% is temperature. A conservative reading is
  roughly **−20 to −25%** attributable to chunk size, still above the Mac's 16%
  and still above the falsifier.
- **P4 — decode untouched. FALSIFIED on short and long, held on medium.**
  Predicted within 3%, falsified beyond 5%. Medium moved ≤2.9% on every phase.
  But **short** moved −10.0% on `io` and −7.8% on wall, and **long** −5.5% and
  −8.1%, with decode bytes/token and hit rate unchanged in all three.
  Long is plausibly thermal. **Short is not**: both its runs were `nominal`
  throughout, and its decode byte profile is byte-identical, yet `io` fell 10%.
  **This is unexplained and is not being explained away.** One candidate worth
  testing: prefill at 256 reads 40% fewer bytes, so the *OS* file cache is less
  thrashed entering decode, speeding the misses without changing the app's own
  LFU hit rate — consistent with Track B step 1's finding that iOS does serve a
  large file cache. *Falsifier:* run decode-only with prefill disabled at both
  chunk sizes; if `io` is identical, the effect is prefill's cache footprint.
- **P5 — output. HELD.** Token counts identical across both chunk sizes:
  507 / 632 / 602.
- **P6 — memory. HELD.** Peak `phys_footprint` rose **+15.2 / +35.9 / +36.2 MB**,
  under the 100 MB prediction and well under the 200 MB falsifier, broadly
  consistent with the documented ~+16 MB of extra prefill scratch.

## Disposition

256 is better than 128 on this device on every measure that moved, costs ~36 MB,
and changes no output. The remaining question is not whether to use it but
whether to make `auto` the iOS default — `auto` resolves to 256 for any prompt
longer than 256 tokens and to a smaller size below that, which is the right
policy under the corrected model as well as the original one. That is a change
to a shared default and belongs with a `RUNTIME_CONTROLS.md` update in the same
commit.
