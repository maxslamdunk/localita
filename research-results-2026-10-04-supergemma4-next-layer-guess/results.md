# Results: a fitted next-layer guess for supergemma4

Scored against `predictions.md`, committed first (`6765ad6`). Ten traced CLI
runs on the 8 GB M1 on 2026-10-04, 01:39–02:08: `.build/release/TurboFieldfareCLI`
built from `6765ad6`, model `scratch/supergemma4.gturbo`, early read off, 16
live slots. AC power, preflight clean, memory 40% free. One row per run is in
`MEASUREMENTS.md`. The traces themselves (1.7 GB) are not kept in the repo.

**Correction to `predictions.md`:** the branch starts from `43c5574`, not
`611c5e5`. The session's git snapshot was stale, and main had meanwhile merged
expert-cache count aging **on by default** (`7bc3e23`). So every run here,
traces and live check alike, used the aged LFU (counts × 0.97 per plan, reset
when the KV starts over). The predictions assumed plain LFU.

## Headline

**supergemma4's routers are byte-identical to gemma4's.** The fine-tune did
not touch them. All 30 exported router matrices `cmp` equal to the ones in
the 2026-10-02 gemma4 traces, so the relative distance is 0 and top-8 overlap
is 8 / 8 on every layer (`cross-score-output.txt`).

So **gemma4's shipped guess file already does the job for supergemma4.** On
the supergemma4 held-out traces it scores **0.721** precision@1 at 24 slots.
supergemma4's own fit scores **0.720**, and supergemma4's own router 0.579.
The new fit is no better than the file the runtime already ships.

**Decision: supergemma4 uses gemma4's file.** `NextLayerGuess/index.json` gets
a second entry for supergemma4's `sourceSnapshotHash` that points at the same
`.bin`. That adds no bytes to the app. The own fit was 11.1 MB
(SHA-256 `c4b3e742…ede9a37`) and is kept out of the bundle, at
`scratch/supergemma4-next-layer-guess.bin` on the Mac host. It stays unmerged
until a phone A/B of supergemma4, router guess against fitted, scores it.

## Scoring

Held-out traces, 24 replayed slots unless marked.

| | Predicted | Measured | |
| --- | --- | --- | --- |
| P1. Replay vs live hit rate, 16 slots, from token 32 | within 0.5 pp | test 66.0 vs 65.5% (**0.5 pp**); train 64.9 vs 64.0% (**0.9 pp**) | held on test, **missed on train** |
| P2. naive precision@1 | 0.54–0.64 | **0.579** | held |
| P3. fitted 8-bit precision@1 | 0.67–0.78 | **0.720** | held |
| P4. fitted − naive | +0.09 to +0.17 | **+0.141** | held |
| P5. 8-bit vs float | within 0.005 | 0.000 (0.720 / 0.720) | held |
| P6. 16 slots, fitted 8-bit | 0.80–0.89 | **0.844** | held |
| P7. File size | 11,106,368 B | 11,106,368 B | held |
| P8. Live hit rate, test runs | 61–68% | 68.3 / 66.4 / 62.5%; 65.7% pooled | held pooled; short is 0.3 pp over |
| P9. gemma4's file on supergemma4 | 0.60–0.72, low confidence | **0.721** | at the top edge; see below |

**P9.** I hedged because I assumed the fine-tune had moved the routers. The
existing test said as much ("shares the architecture but not the router
weights"), but nobody had checked it. The routers did not move, and gemma4's
file scores within 0.001 of supergemma4's own fit, inside the 0.02 margin
`predictions.md` set for "one file could serve both models". The prediction
called a per-model file the safer choice. The identical routers remove the
reason for that, and the 0.001 difference is below anything this data can
resolve.

**P1, the train miss.** On training traces, the replayed cache runs 0.9 pp
below the live one, against 0.0 on the gemma4 traces of the same prompts. The
cause is the correction above. The live cache aged its counts, while
`score.py` replays plain LFU, a mirror of the runtime as it was on 2026-10-02.
Aging raises the live hit rate, as it was built to, so live runs above the
replay. That also explains why these held-out runs hit 0.3–0.7 pp more than the
2026-09-27 supergemma4 rows with identical tokens (P8's short case at 68.3%).
I didn't separate this from prefill's lingering counts, which gemma4's replay
had too. Neither changes the decision. The fit uses only router inputs and
scores, and both models' precision was scored against the same plain-LFU
replay, so 0.720 against 0.721 is like for like. Against an aged replay the
absolute precision would shift, which the phone A/B measures directly.

**Per prompt**, at 24 slots, naive / own fit (`fit-output.txt`): short
0.549 / 0.679, medium 0.571 / 0.711, long 0.616 / 0.768. gemma4's study had
0.545 / 0.680, 0.593 / 0.723 and 0.621 / 0.770 on its own traces.

## The routers, checked in the installed weights

The headline rests on the routers the trace exports, which the runtime
produces by running the production router kernel on unit vectors. Afterwards
I checked them in the installs themselves: `compare_tensors.py` compares
every resident tensor of the two `model_weights.bin` files, byte for byte
(`compare-tensors-output.txt`).

- **Identical in all 30 layers:**
  - the router, meaning `router.proj`, `router.scale` and
    `router.per_expert_scale`;
  - every norm and the layer scalars;
  - the shared MLP's `gate_proj` and `up_proj`.

  The embedding and the final norm are identical too.
- **Changed:**
  - `o_proj` in all 30 layers (11.3% of its weight bytes);
  - the shared MLP's `down_proj` in all 30 (7.2%);
  - `q_proj` and `k_proj` in 8 layers and `v_proj` in 6 (about 15%);
  - every routed-expert layer file (by the manifest hashes).

Those are the weights that write into the residual stream. **So identical
routers do not mean identical routing:** supergemma4's router inputs differ
from gemma4's for the same token. That is why the guess has to be scored on
supergemma4's own hidden states, as P9 did. gemma4's file was fitted on
gemma4's hidden states, and on supergemma4's it scores 0.721 against 0.720 for
supergemma4's own fit. The phone confirmed it: the gain was +0.127 / +0.143 /
+0.149 on supergemma4, against +0.134 / +0.141 / +0.146 for the same file on
gemma4. The edits change the residual stream in ways the layer-to-layer guess
does not depend on.

## Why the fit carries over

The guess for layer L+1 is `x_L (W_{L+1} + B)^T`, with `x_L` layer L's router
input. `W` is identical between the models. `B` is a ridge correction for how
the router input drifts from layer L to L+1. That drift does depend on the
weights the fine-tune changed, but the two fits give the same held-out
precision, so whatever moved did not change the drift in a way that matters to
the guess.

## Live check, Mac

With the index entry in place (`4a95a1f` plus the entry, release CLI), I ran
supergemma4 on `short-explanation` (seed 20260721) twice, back to back. The
first run used the default early read, which now loads gemma4's file. The
second forced the router guess (`TURBO_FIELDFARE_EARLY_EXPERT_GUESS=router`).
Footers are in `live-check/`, and both runs have rows in `MEASUREMENTS.md`.

| | fitted (gemma4's file) | router |
| --- | --- | --- |
| early reads / used per token | 29.00 / 23.94 | 29.00 / 19.78 |
| precision (used / reads) | **0.826** | **0.682** |
| offline prediction, 16 slots, pooled | 0.844 | 0.698 |
| bytes/token | 259.75 MiB | 273.06 MiB |
| hit rate | 68.3% | 68.3% |
| text SHA-256 | `caa1935a…62a3fd` | same |

The file loads for supergemma4 and is used. Live precision sits 0.016 below
the offline pooled figure in both arms. That fits a single short prompt,
which offline was the lowest of the three. The text matches the early-read-off
trace run byte for byte, and the hit rate is unchanged. tok/s was 4.004
against 3.894, but that is one run each on the Mac, so it is not a speed claim.

## What this does not show

- **Speed.** This is offline precision on the Mac. On gemma4, precision
  0.68–0.75 on the phone came with about +17–20% tok/s against the early read
  off, and the router guess alone with +12–15%. supergemma4 has measured
  neither. A phone A/B (fitted against router guess, supergemma4 installed)
  needs its own predictions first.
- **Other fine-tunes.** A fine-tune that does train the routers would need its
  own fit. Comparing the exported router matrices, as `cross_score.py` does,
  takes one traced run and settles it.

## Files

- `collect.sh`: the trace collection, with the model as an argument.
- `cross_score.py`: gemma4's file on supergemma4 traces, plus router drift.
- `check-trace-output.txt`: router export vs logged scores, per run (max error
  1.4e-5 to 1.9e-5; top-8 matches on all but 3 of 117,060 records).
- `score-output.txt`: the full predictor table from the 2026-10-02 scorer.
- `fit-output.txt`: `fit_guess.py` on these traces.
- `cross-score-output.txt`: P9 and the router comparison.
- `compare_tensors.py`, `compare-tensors-output.txt`: every resident tensor of
  the two installs, byte for byte.
