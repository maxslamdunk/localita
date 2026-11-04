# Variants of skipping a missed expert: results

2026-11-04, Mac (M1 MacBook Air, 8 GB, macOS 26.6.1), gemma4
(`scratch/gemma4.gturbo`), binary built at `fa5cc90`. Predictions in
`predictions.md`: the main ones committed before any run (`fa5cc90`),
Addendum 1 before its three runs (`25f524b`). No iPhone run. Mac tok/s is not
quoted; only reads and KL decide.

## The answer

**None of the three ideas beats `miss:<t>` by a margin these 12 transcripts
can show.** `miss:<t>` stays the policy to take to the phone.

- **HOBBIT's rank rule (`cum:<T>`) is the only one that might be better, and
  it is not established.**
  - `cum0.85` cuts foreground reads 34.1% at excess 0.69 [0.42, 1.04]
    against the dense `miss` curve, meaning about 30% less KL per read saved.
  - The interval crosses 1.
  - Most of the gap is one token: a single position in transcript 4 with KL
    5.0 under `miss075` and 5.6 under `miss08`, which `cum0.85` does not hit.
    Leave that transcript out and the excess is 0.84.
  - At a deeper cut, `cum0.80` matches the curve: 0.99 [0.68, 1.34].
- **The early-read swap (`early:<λ>`) is clearly worse.**
  - Alone, it saves 6.6% and 9.8% of reads at 2.5× and 3.2× the `miss` cost
    per read saved, with intervals well above 1.
  - Stacked on `miss08`, it adds 5 points of cut at about the curve's own
    price, 1.08–1.15.
  - So steering toward the early read is not cheaper than dropping, on this
    model.
- **Reranking then dropping (`bias05+miss08`) lands on the curve:** −51.0%
  at 0.95–0.99. Stacking neither helps nor hurts, against Cacheable by
  Design's report for its models.

## Controls

All three reproduced exactly.

1. **`refs/ref.ref` is byte-identical** (`cmp`) to the 2026-10-04 reference,
   so the merge onto main changed nothing in decode.
2. **`miss08` reproduces 23.14 foreground reads per token and KL 0.02465.**
   Its per-position file is byte-identical to 2026-10-04's, so moving the
   early read from one pending expert to a set changed nothing at one early
   read per layer.
3. **The reference reads 38.00 foreground and 29.00 early experts per token,
   at hit rate 76.2%.**

## Results

From `excess.py` (the pre-registered curve, `excess-output.txt`) and
`DENSE=1 excess.py` (with Addendum 1's three points, `excess-dense-output.txt`).
KL is in nats per token over 1,536 positions. Excess is the run's KL over the
`miss` KL interpolated at its own read cut, paired by transcript.

| Run | Foreground reads per token | Read cut | KL [95% CI] | Top-1 | Excess, predicted curve | Excess, dense curve |
| --- | --- | --- | --- | --- | --- | --- |
| `ref` | 38.00 | 0 | 0 | 1 | | |
| `miss08` (control) | 23.14 | −39.1% | 0.0246 [0.014, 0.036] | 0.977 | 1 | 1 |
| `cum0.85` | 25.03 | −34.1% | 0.0143 [0.009, 0.019] | 0.982 | 0.67 [0.40, 1.12] | **0.69 [0.42, 1.04]** |
| `cum0.80` | 20.92 | −44.9% | 0.0269 [0.016, 0.041] | 0.974 | 0.92 [0.67, 1.18] | 0.99 [0.68, 1.34] |
| `early0.10` | 35.51 | −6.6% | 0.0071 [0.005, 0.010] | 0.980 | **2.49 [1.89, 3.57]** | not rescored |
| `early0.30` | 34.28 | −9.8% | 0.0138 [0.008, 0.021] | 0.979 | **3.24 [2.38, 4.57]** | not rescored |
| `miss08+early0.30` | 21.27 | −44.0% | 0.0307 [0.019, 0.045] | 0.970 | 1.08 [0.86, 1.34] | 1.15 [0.85, 1.53] |
| `bias05+miss08` | 18.61 | −51.0% | 0.0321 [0.020, 0.047] | 0.967 | 0.95 [0.73, 1.24] | 0.99 [0.74, 1.33] |
| `miss07` (curve) | 27.67 | −27.2% | 0.0120 [0.008, 0.017] | 0.982 | 0.73 | 1 |
| `miss075` (curve) | 25.43 | −33.1% | 0.0197 [0.013, 0.027] | 0.981 | 0.96 | 1 |
| `miss085` (curve) | 20.87 | −45.1% | 0.0272 [0.017, 0.038] | 0.971 | 0.93 | 1 |

The `early` runs fall below `miss05`'s −10.2%, where the curve is still only
the chord from no skip. The chord lies above a convex curve, so their excess
is, if anything, understated.

Swaps per token, from `substituted/layer` × 30 layers: 2.6 for `early0.10`,
4.1 for `early0.30`, and 2.1 for `miss08+early0.30`.

### Why one token moves the comparison

Per-token KL is heavy-tailed. In `miss08`, six positions with KL above 1
carry 14.8 of the run's 37.8 nats. `miss075` has five such positions, `cum0.85`
two. Per transcript, the `miss` curve is not smooth either: transcript 4 goes
from 0.39 nats at `miss07` to 5.61 at `miss075`, nearly all of it one
position. With 12 transcripts, one token like that sets the comparison
between two policies of similar cost. Separating them needs more
transcripts, not a finer curve.

## Predictions, scored

| Prediction | Outcome |
| --- | --- |
| Controls 1–3 reproduce exactly | **Held.** |
| `cum0.85` read cut −25 to −42% | **Held:** −34.1%. |
| `cum0.85` excess 0.8 to 1.2 | **Missed low:** 0.67 (0.69 on the dense curve). Not falsified by its own rule, because the interval crosses 1. |
| `cum0.80` read cut −38 to −58%, excess 0.8 to 1.2 | **Held:** −44.9%, 0.92. |
| `early0.10` cut −3 to −14%, excess 1.5 to 4 | **Held:** −6.6%, 2.49. |
| `early0.30` cut −8 to −24%, excess 1.5 to 4 | **Held**, near the bottom of the cut range: −9.8%, 3.24. "Most wasted early reads swap" was wrong: 4.1 swaps per token, not 7–9. |
| `miss08+early0.30` cut −42 to −50%, excess 1.0 to 1.6 | **Held:** −44.0%, 1.08. |
| `bias05+miss08` cut −50 to −62%, excess 0.9 to 1.4 | **Held**, at the bottom of the cut range: −51.0%, 0.95. The reasoning was wrong: the costs did not add. KL is 0.0321, not 0.045–0.05. |
| None beats the `miss` curve by more than 10%; if one does, `cum:<T>` | **Point estimate wrong, significance right:** `cum0.85` is 31% under the curve, but its interval reaches 1.04. It is the `cum` arm, as predicted. |
| Addendum 1: new `miss` points land at −24 to −34%, −30 to −38%, −42 to −52% | **Held:** −27.2%, −33.1%, −45.1%. |
| Addendum 1: the curve is convex; each new point is below the old chord | **Held:** 0.0120 against 0.0163, 0.0197 against 0.0204, 0.0272 against 0.0293. |
| Addendum 1: `cum0.85` rises to 0.8–1.0 on the dense curve | **Missed:** 0.69. The chord was not the reason. The one-token tail above was. |
| Addendum 1: `cum0.80` and `miss08+early0.30` move by less than 0.1 | **Held:** +0.07 each. |

## What follows

- **For the phone, nothing changes.** `miss:<t>` is still the candidate. The
  phone A/B and a human read of real chats come before any default.
- **`cum:0.85` is worth a second look only with more transcripts.** Two
  rules this close will not separate on 12. A set of 50 or more, scored
  against the same reference procedure, would.
- **The early-read swap is closed** for this model.

## Run conditions and incidents

- **The first reference run crashed** with "No space left on device" while
  writing `refs/ref.ref` (`logs/ref-disk-full.txt`). It was re-run after
  space was freed.
- **A model-loading test in another worktree** made `score.sh`'s guard skip
  six runs (`logs/queue-first-pass.out`), and then all six again
  (`logs/queue-rest-blocked.out`). The guard also matches builds of
  model-owning products, so a build counts as busy.
  - `queue-rest.sh` and then `queue-curve.sh` wait before each run until two
    minutes pass with no such process.
  - Every scored run started on a clear check. No run is known to have
    overlapped another model process. The guard checks only at start.
- **Wall time varied** from 0.139 to 0.602 s/tok with what else was running
  on the Mac. It does not affect KL or read counts, which are deterministic
  (control 2).
- Thermal state was not reported (`pmset` gives no `CPU_Speed_Limit` on this
  host).

## Files

- `predictions.md`: the predictions and Addendum 1.
- `queue.sh`, `queue-rest.sh`, `queue-curve.sh`: the runs, in the order they
  ran.
- `score.sh`: one run of the meter.
- `excess.py`: the scoring against the `miss` curve. Its outputs are
  `excess-output.txt` and `excess-dense-output.txt`.
- `measurement_rows.py`: the MEASUREMENTS.md rows.
- `logs/`: footers and per-position files for every run, plus the queue
  logs.
- `refs/ref.ref`: the reference, gitignored (800 KB). It is byte-identical
  to the 2026-10-04 one, which it was checked against.
