# Results: skipping a missed expert (`miss:0.08`) on the iPhone

Scored against [`predictions.md`](predictions.md), committed first in
`ae91624`. The phone build is `5f5c281`. Logs and texts are in
[`logs/`](logs/). The driver is [`run-ab.sh`](run-ab.sh), with its log in
[`driver-ab.log`](driver-ab.log). [`summarize.py`](summarize.py) prints every
figure below, saved in [`summary-output.txt`](summary-output.txt).
[`measurement_rows.py`](measurement_rows.py) wrote the `MEASUREMENTS.md` rows.
A 16-token smoke check is in [`smoke/`](smoke/), driven by [`smoke.sh`](smoke.sh).

## Answer

**`--expert-skip miss:0.08` is +32.9% / +18.2% / +26.0% tok/s on the iPhone
17 (short / medium / long).** Every predicted range held, and every control
held. The replies stay coherent and complete. It stays an opt-in research
switch: it changes output, and only teacher-forced KL on the Mac has measured
that change.

| case | tok/s A → B | `io` ms/fwd | foreground reads/tok | bytes/tok (footer MB) | hit rate | `cb1-wait` ms/fwd |
| --- | --- | --- | --- | --- | --- | --- |
| short | 6.021 → **8.001 (+32.9%)** | 99.56 → 65.02 (−34.7%) | 30.06 → 17.33 (−42.3%) | 189.18 → 148.42 (−21.5%) | 79.4 → 84.8% | 51.18 → 45.27 |
| medium | 5.820 → **6.878 (+18.2%)** | 98.83 → 73.61 (−25.5%) | 35.65 → 23.58 (−33.9%) | 207.07 → 168.41 (−18.7%) | 76.7 → 81.5% | 57.70 → 56.50 |
| long | 5.086 → **6.410 (+26.0%)** | 111.66 → 78.18 (−30.0%) | 42.54 → 28.22 (−33.7%) | 229.16 → 183.29 (−20.0%) | 73.2 → 79.0% | 68.58 → 62.72 |

These are means of two runs per arm. Foreground reads are all decode reads
minus the 29.00 early reads per token. **Every B run is faster than every A
run** in its case:

- short: B 8.053 and 7.949, A 5.689 and 6.352;
- medium: B 6.881 and 6.875, A 5.965 and 5.675;
- long: B 6.702 and 6.118, A 4.951 and 5.221.

## What was run

The build is `5f5c281` in Release, installed over the app. It is one binary
with a runtime switch:

- **A:** defaults, `expertSkip=off`.
- **B:** `--expert-skip miss:0.08`.

Both arms used the bundled fitted guess (`@b18242445534d452…`), `F_NOCACHE`,
count aging and 24 slots. All runs were at `--max-new 1024 --max-context 4096`
with chunk `auto`. Every log's `runner-ready` line confirms its arm.

The runs were on 2026-11-08 from 04:55 to 06:17 CET, A B B A per case, with
300 s cooldowns. The phone was charging throughout, at 90–100% battery.

- **Thermal:** short and medium were `nominal` at every sample. In long, A1
  was all `nominal`. A2, B1 and B2 had 30, 19 and 28 `fair` samples out of 68,
  so `fair` fell on both arms.
- **Prompt hashes:** `c57da267…` (short), `23add797…` (medium) and
  `b12e4a71…` (long). They match the 2026-10-08 runs.

## Predictions, scored

| Metric | Predicted | short | medium | long | Verdict |
| --- | --- | --- | --- | --- | --- |
| Foreground reads/tok | −30 to −45% | −42.3% | −33.9% | −33.7% | hit |
| Bytes/tok | −15 to −30% | −21.5% | −18.7% | −20.0% | hit |
| Hit rate | +4 to +8 pt | +5.4 | +4.8 | +5.8 | hit |
| `io` | −25 to −45% | −34.7% | −25.5% | −30.0% | hit (medium at the edge) |
| tok/s | +15 to +35% | +32.9% | +18.2% | +26.0% | hit |

**Falsifiers:** none fired.

- Every case gained at least +10% tok/s.
- Foreground reads fell by 33.7–42.3%, inside the 25–50% bound.

**Controls:**

1. **Early reads:** 29.00 per token in all 12 runs. **Held.**
2. **Prefill bytes:** identical between the arms in each case: 6,953.98 /
   8,882.27 / 11,140.47 MiB. **Held.**
3. **Text:** byte-identical within each arm and different between the arms.
   **Held.**
   - short: A `088557fa…`, B `6cb36dda…`
   - medium: A `b3911257…`, B `8b58f1cf…`
   - long: A `5b4b32cb…`, B `982d921a…`
4. **The arm in the logs:** every A run says `expertSkip=off`, every B run says
   `expertSkip=miss:0.08`, and every B log has the `expert-skip` line.
   **Held.**
5. **`cb1-wait` within ±15%:** −11.5% / −2.1% / −8.5%. `head`'s GPU figure
   moved −6.2% / −0.9% / −7.3%, which reads as run-to-run GPU speed. **Held.**

## What it says

**The serial storage model carries over.** Each foreground read the policy
removes takes 2.1–2.7 ms off `io`:

| case | `io` saved | foreground reads removed | `io` per removed read |
| --- | --- | --- | --- |
| short | 34.54 ms | 12.73 | 2.71 ms |
| medium | 25.22 ms | 12.07 | 2.09 ms |
| long | 33.48 ms | 14.32 | 2.34 ms |

That is the 2.1–2.2 ms per read the phone's storage serves serially. Wall time
fell by 41.7 / 26.6 / 40.5 ms, a little more than `io` did. `cb1-wait` and the
GPU figures fell a little too, which is inside GPU noise.

**The mean read got faster under B:**

- A: 4.38 / 4.24 / 4.46 ms. B: 3.25 / 3.54 / 3.59 ms.
- Fewer foreground reads queue behind the layer's early read, so each one
  waits less.
- The prediction did not name this. It is part of why `io` kept pace with the
  read cut.

**The phone drops less than the Mac did:**

| | dropped experts/layer | dropped mass/layer |
| --- | --- | --- |
| Mac transcripts | 0.600 | — |
| Phone, short / medium / long | 0.438 / 0.486 / 0.538 | 0.026 / 0.029 / 0.032 |

The Mac figure comes from the 12 scoring transcripts, not these prompts, and
the read cut still landed inside the predicted range. Each dropped expert removed 0.83–0.97 foreground reads, not a full one. A
dropped expert never takes a slot, so it can miss again on a later token.

**Today's baseline was slower than October's.** The A arm read at a 4.2–4.5 ms
mean, against 3.5 ms in the 2026-10-08 one-read arm. Short A was 6.02 tok/s
here and 6.95 then, at the same 59 reads per token. The cause was not
separated. The A/B is paired within the day, so it does not affect the
comparison. It does mean the absolute tok/s here is not a new baseline figure.

## Quality: the texts read

The B texts were read beside the A texts. None is broken. There is no
repetition, no language switch and no dropped requirement.

- **short:** both cover the two mechanisms, two limits and the
  risk-reduction distinction. B names its limits "width and depth" and
  sea-level rise, and adds "coastal squeeze". It is 500 tokens; A is 522.
- **medium:** both find the same four correctness risks and the duplicated
  I/O. B proposes a key → future map with reference-counted buffers, where A
  proposes per-slot read/write locks with request coalescing. Both are sound.
  B adds a short summary.
- **long:** both have the same structure and the same core facts: 1.35 GB
  resident, `pread` streaming, chunked prefill and an LFU cache. A mentions
  the 16-slot cache. B instead names M2 against M5 hardware variance.

This is a reading, not a measurement. Teacher-forced KL on the Mac
([`research-results-2026-10-04-lossy-experts`](../research-results-2026-10-04-lossy-experts/results.md))
is the measured cost: 0.55× of one INT4 rounding. That number does not cover
how a reply drifts after a different token is chosen. A task-accuracy check
with checkable answers would.

## Disposition

**`miss:0.08` stays an opt-in research switch (off).** Making it a default is
a quality trade, and the user decides it (AGENTS.md, "What is
open"). Before that decision:

- **A task-accuracy check:** free generation with graded answers, which
  measures the drift that teacher-forced KL cannot.
- **Optional:** `miss:0.10` (−62% reads at 0.94× on the Mac), if a larger
  gain is wanted at about one rounding's cost.
