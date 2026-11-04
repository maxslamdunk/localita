# Variants of skipping a missed expert: predictions

Written 2026-11-04, before the runs that score them. The 2026-10-04 study
(`../research-results-2026-10-04-lossy-experts/`) found that dropping a
low-weight routed expert only when it would be a foreground read (`miss:<t>`)
saves more reads per unit of KL than any other lossy option it tried. That
included cache-prior reranking (Skliar et al. 2024, `bias:<λ>`).

A search of later work turned up three ideas it did not test.

- **HOBBIT** (arXiv 2411.01433) decides by rank: an expert matters less the
  more weight its higher-ranked experts already carry.
- **Prefetch-steered routing**, PSR (arXiv 2610.34721), gives a bonus only to
  the experts the prefetcher brought in. Our `bias:` arm already gives the
  pending early read the same bonus as residents, so it was roughly PSR with
  one prefetch per layer. What it did not test is a bonus for the early read
  **alone**.
- **Cacheable by Design** (arXiv 2608.18261) reports that cache-aware
  rerouting stacks with other miss-reduction methods.

## What is measured, and how

The meter, transcripts, yardstick and setup are those of the 2026-10-04 study:

- `TurboFieldfareScore` scores 12 teacher-forced transcripts at 128 tokens,
  1,536 positions in all.
- KL is KL(reference ‖ run) over the reference's top 64 tokens plus a tail
  bucket.
- The configuration is 24 slots, the early read on with the fitted guess,
  count aging on, and prefill chunk 256.
- Foreground reads per token come from the run's own footer, and they are
  exact.

The code is the research branch merged onto main at `b53c2af`.

**The comparison is against the `miss` curve, not a single point.** These
runs land at different read cuts, so each is set against the `miss` KL
interpolated at its own cut. The interpolation is piecewise linear through
these points, from the 2026-10-04 runs:

| Point | Read cut | KL |
| --- | --- | --- |
| no skip | 0 | 0 |
| `miss05` | −10.2% | 0.0044 |
| `miss08` | −39.1% | 0.0246 |
| `miss10` | −62.0% | 0.0423 |

**Excess** is KL(run) divided by that interpolated KL:

- below 1, the variant is cheaper per read saved than `miss`;
- above 1, it is dearer.

The 95% interval comes from resampling the 12 transcripts, pairing each run's
per-transcript KL with the interpolated `miss` KL of the same transcript.

## Controls

These must reproduce exactly, because the meter and the read counts are
deterministic:

1. **`ref` is byte-identical** (`cmp`) to the 2026-10-04 `refs/ref.ref`. If it
   is not, the merge changed decode, and `miss05`, `miss08`, `miss10` and
   `noise` are re-run before anything is scored against them.
2. **`miss08` reproduces 23.14 foreground reads per token and KL 0.02465,**
   to the printed digit. This checks that changing the early read from a
   single pending expert to a set changed nothing at one early read per
   layer.
3. **The reference run reads 38.00 foreground and 29.00 early experts per
   token,** with hit rate 76.2%.

## The runs, and what each should do

### `cum:<T>`, HOBBIT's rule

Drop a foreground miss at rank i ≥ 2 when the experts ranked above it
already carry at least T of the top-8 weight.

The equivalent statement: drop it when it and everything below it carry at
most 1 − T. Mean weights by rank, from the 2026-10-04 traces:

| Rank | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Mean weight | 0.259 | 0.171 | 0.135 | 0.112 | 0.096 | 0.084 | 0.075 | 0.068 |

The mean weight left at rank 6 and below is 0.227, at rank 7 and below 0.143,
and at rank 8 alone 0.068.

| Run | Read cut | Excess |
| --- | --- | --- |
| `cum0.85` | −25 to −42% | 0.8 to 1.2 |
| `cum0.80` | −38 to −58% | 0.8 to 1.2 |

How the read cuts were reached:

- **`cum0.85`:** rank 8 nearly always qualifies, rank 7 about half the time,
  and rank 6 rarely. That falls between `missrank8` (−22%) and `missrank7`
  (−41%) in the 2026-10-04 offline replay.
- **`cum0.80`:** rank 7 usually qualifies and rank 6 sometimes, between
  `missrank7` and `missrank6` (−57%).

**Mechanism:**

- Both rules drop experts of low weight, which is what the KL follows to
  first order.
- `miss:<t>` is already greedy per expert.
- The rank rule differs only where weight is spread evenly. There it keeps
  experts that `miss:<t>` would drop, and drops ones that `miss:<t>` keeps.
- No reason is known why that should be better or worse on average.

**Falsified if:**

- excess is below 0.8, with the interval below 1, which would mean the rank
  rule is better;
- excess is above 1.2, with the interval above 1;
- or a read cut falls outside its range, which would mean the rank arithmetic
  above is wrong.

### `early:<λ>`, a bonus for the early read alone

A PSR-style swap that never costs quality without saving a read:

- The trigger is a pending early expert e of layer L that is not in its top 8.
- It must beat the lowest-logit foreground miss m at rank ≥ 2 after a bonus:
  z_e + λ·Δ̄ > z_m.
- Then e replaces m.
- Δ̄ is the running average range of the router logits, as for `bias:`.
- The weights are the softmax over the new set's original logits.

Each swap saves exactly one foreground read, because e is already being read.

| Run | Read cut | Excess |
| --- | --- | --- |
| `early0.10` | −3 to −14% | 1.5 to 4 |
| `early0.30` | −8 to −24% | 1.5 to 4 |
| `miss08+early0.30` (drop first, then swap among the misses left) | −42 to −50% | 1.0 to 1.6 |

**Read cut:**

- A swap needs a wasted early read: the guess was wrong, and the guessed
  expert is outside the top 8.
- That happens for 25–32% of the 29 early reads per token, so 7–9 per token.
- It also needs a foreground miss within the bonus of the guessed expert's
  logit.
- **`early0.10`:** a third to a half of the wasted reads swap, so −3 to −14%
  of 38 foreground reads.
- **`early0.30`:** most of them swap, so −8 to −24%.
- **The combination** adds −3 to −10 points to `miss08`'s −39%. The misses
  left after dropping weigh at least 0.08, so fewer of them fall within the
  bonus.

**Excess:**

- A swap removes a weight of about 0.07 and adds a different expert of similar
  weight. That is close to `misssub08`, which cost 1.19× [0.97, 1.53] of
  `miss08` at equal reads.
- At small cuts the `miss` curve is very cheap: `miss05` costs only 0.0044 for
  −10%. So a swap alone should be well above the curve.

**Falsified if:**

- excess is below 1, with the interval below 1. Steering toward the early
  read would then be cheaper per read than dropping, as PSR's results suggest
  for cache-prior.
- either standalone run saves under 3% of reads, which would mean the early
  guess is rarely within reach of the top 8.

### `bias05+miss08`, reranking then dropping

Rerank with `bias:0.05` (residents and the early read get the bonus), then
apply `miss:0.08` to the set that comes out.

| Run | Read cut | Excess |
| --- | --- | --- |
| `bias05+miss08` | −50 to −62% | 0.9 to 1.4 |

**Read cut:** `bias05` alone cut 31.4% and `miss08` alone 39.1%. Some misses
are removed by both, so the combination cuts less than their sum.

**Excess:** the two costs, 0.0248 and 0.0246, should roughly add, to about
0.045–0.05. At about −56%, the `miss` curve gives about 0.038, so the central
excess is about 1.2.

**Falsified if** excess is below 0.9, with the interval below 1. Stacking
would then beat either policy alone, as Cacheable by Design reports for its
models.

## Overall

**None of these is predicted to beat the `miss` curve by more than 10%.** If
one does, the likeliest is `cum:<T>`.

Each run's tok/s on the Mac is not a measurement and will not be quoted.
Only reads and KL decide.

## Addendum 1: more points on the `miss` curve

Written 2026-11-04, after five of the seven runs were scored (`excess.py`)
and before the runs below.

`cum0.85` scored excess 0.67 [0.40, 1.12] at a read cut of −34.1%. That point
lies on the chord from `miss05` (−10.2%, 0.0044) to `miss08` (−39.1%,
0.0246). If the curve is convex between them, as those two points suggest,
the chord overstates the `miss` KL at −34%, and so understates `cum0.85`'s
excess. `cum0.80` (−44.9%) and `miss08+early0.30` (−44.0%) sit on the chord
from `miss08` to `miss10` and have the same bias, likely smaller.

Three `miss` runs close those gaps: `miss:0.07`, `miss:0.075` and
`miss:0.085`. From the 2026-10-04 offline replay, they should land near −30%,
−35% and −46%.

Predictions:

- **Read cuts:** `miss07` −24 to −34%, `miss075` −30 to −38%, `miss085`
  −42 to −52%.
- **The curve is convex.** Each new point's KL lies below the old chord at its
  own cut.
- **`cum0.85`'s excess, rescored on the denser curve, rises to 0.8–1.0.**
  It stays at or below 1, because its read cut and KL are already measured:
  only the baseline moves.
- **`cum0.80` and `miss08+early0.30` move by less than 0.1.**
- **The `early` runs are not rescored.** Their cuts (−7% and −10%) fall below
  `miss05`, where there is still only the chord from no skip, which
  understates their excess.

Falsified if `cum0.85` stays below 0.8 on the denser curve, with its interval
below 1. The rank rule would then be cheaper per read than `miss` there.
