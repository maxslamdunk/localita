# Results: a fitted next-layer guess for supergemma4

Scored against `predictions.md`, committed first (`6765ad6`). Ten traced CLI
runs on the 8 GB M1 on 2026-10-04, 01:39–02:08: `.build/release/TurboFieldfareCLI`
built from `6765ad6`, model `scratch/supergemma4.gturbo`, early read off, 16
live slots. AC power, preflight clean, memory 40% free. One row per run is in
`MEASUREMENTS.md`. The traces themselves (1.7 GB) are not kept in the repo.

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

**P1, the train miss.** On training traces, the replayed LFU runs 0.9 pp below
the live cache, against 0.0 on the gemma4 traces of the same prompts. LFU
counts never reset, so the experts prefill used keep their counts all through
decode. The replay starts empty, so it differs for longer than the 32-token
warmup. With byte-identical routers, the different prefill routing has to come
from the other weights, which the fine-tune changed. Count aging was off by
default at `6765ad6`, so it plays no part. The gap biases both predictors'
precision the same way, and the held-out split, which is the one scored, is
inside the bound. I count it as a miss and not as an invalid trace. The phone
A/B measures the live cache directly.

**Per prompt**, at 24 slots, naive / own fit (`fit-output.txt`): short
0.549 / 0.679, medium 0.571 / 0.711, long 0.616 / 0.768. gemma4's study had
0.545 / 0.680, 0.593 / 0.723 and 0.621 / 0.770 on its own traces.

## Why the fit carries over

The guess for layer L+1 is `x_L (W_{L+1} + B)^T`, with `x_L` layer L's router
input. `W` is identical between the models. `B` is a ridge correction for how
the router input drifts from layer L to L+1. That drift does depend on the
weights the fine-tune changed, but the two fits give the same held-out
precision, so whatever moved did not change the drift in a way that matters to
the guess.

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
