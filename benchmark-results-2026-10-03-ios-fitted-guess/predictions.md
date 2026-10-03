# Predictions: the early read with the fitted next-layer guess

Written 2026-10-03, before any runtime code. This is step 2 of 2. Step 1, the
unfitted guess, is
[`benchmark-results-2026-10-02-ios-next-layer-prefetch`](../benchmark-results-2026-10-02-ios-next-layer-prefetch/results.md):
on the phone it gave +15.1 / +12.2 / +12.4% tok/s at guess precision
0.550 / 0.587 / 0.606, with identical output. Its decision rule passed and
named this step.

## What changes from step 1

Only the matrix that scores layer L+1's experts. Step 1 used layer L+1's own
router over layer L's router input. Step 2 uses the research study's
fitted-early predictor: the same router plus a per-layer ridge correction,
fitted on the seven training traces (λ = 1, the study's choice) with the three
`real-generation-v1` prompts held out.

Everything else is step 1's code: the read timing, the staging buffer, the
swap into the planned slot, and the counters.

## How the guess runs

[`fit_guess.py`](fit_guess.py) fits the correction and quantizes router plus
correction to the format the runtime already stores routers in: one byte per
weight, with one BF16 scale and one BF16 bias per 64-wide group. The existing
`router_gemv_gemma4_r4` kernel runs it with an effective scale of 1. That means
no `.metal` change, the same dispatch shape, and the same weight bytes per
GEMV as step 1.

Quantizing costs nothing measurable. On the held-out traces, precision@1 is the
same for the float fit and the 8-bit fit: 0.848 at 16 replayed slots and 0.726
at 24 ([`fit-output.txt`](fit-output.txt)).

The file is 11,106,368 B, with SHA-256 `b1824244…`. It goes outside the model
directory: `scratch/` on the Mac and the app's `Documents/` on the phone. The
runtime maps it read-only, the same way it maps `model_weights.bin`. Mapped
file pages cost almost nothing against the memory ceiling, so the only new
allocation is the 5.6 KB effective-scale buffer of ones.

The file is not committed, because it is derived data. It can be regenerated
from the training traces with the script; its hash is recorded here.

Switch: when `TURBO_FIELDFARE_EARLY_EXPERT_READ=next-layer` is set and
`TURBO_FIELDFARE_EARLY_EXPERT_GUESS` names the file, the fitted guess is used.
On the iOS harness this is `--early-expert-guess <file in Documents>`. The
harness logs which guess ran.

## Label

**bytes/token goes up against the early read being off, and down against
step 1.** More of the 29 early reads per token are used, so fewer are wasted.
The case is made on the `io` phase, as in step 1.

## Runs

- **Phone:** the same binary for both arms, step 1's guess (N) and the fitted
  guess (F), early read on in both. Each `real-generation-v1` case runs
  N F F N: 12 runs at 24 slots, `--max-new 1024 --max-context 4096`, prefill
  chunk `auto`, 300 s cooldown, thermal state recorded. About 1.5 hours.
- **Mac, first:** one pair on the short case (16 slots), to check that the text
  is identical and that the counters work.
- **Tests:** unit tests for the file loader.

## Predictions

Step 1's B arm gives the reference figures. This run's N arm replaces them for
scoring.

**P1. Identical work.** On every case, F's generated text is byte-identical to
N's and to step 1's: `d32db73b…`, `209ffadb…` and `87f6f357…`. Hit rate and
requests/token are identical to the digit. The guess only changes which
miss's bytes are read early, never what the cache decides.

*Falsified by* any difference. That stops the run.

**P2. Live precision rises.** Early reads used ÷ issued:

| case | N, step 1 | F predicted |
| --- | --- | --- |
| short | 0.550 | 0.63–0.74 |
| medium | 0.587 | 0.66–0.77 |
| long | 0.606 | 0.69–0.81 |

The point values add the offline gain (+0.135 / +0.130 / +0.149) to step 1's
live figures: 0.685 / 0.717 / 0.755. In step 1 the live precision landed within
0.015 of the offline one on every case.

*Falsified by* any case outside its range, or F beating N by less than +0.08
on any case.

**P3. Fewer wasted reads.** Issued reads stay at 29 per token, so every extra
used read is one fewer wasted read:

reads/token(F) − reads/token(N) = −(used/token(F) − used/token(N)), to within
0.5.

At the point precisions that is about −3.9 / −3.8 / −4.3 reads per token, or
**−12.5 / −12.2 / −13.8 footer MB per token**, against step 1's
202.49 / 225.41 / 241.24.

*Falsified by* a break in that identity.

**P4. `io` falls a little more.** Each extra used read saved 1.35–2.0 ms of
`io` in step 1, so about 4 more should save **4 to 9 ms per forward** against
N.

⚠️ This test is weak. In step 1, two runs of identical work differed by up to
22 ms of `io` on long, so two runs per arm cannot resolve a 4–9 ms effect on a
single case. The mechanism check is the `io` saving divided by the extra used
reads, pooled over the three cases.

*Falsified by* `io` rising against N on two or more cases.

**P5. The GEMV costs the same.** Same kernel, same shape, same bytes as step 1:
`cb1-wait` changes by **0 ± 2 ms** against N. Peak footprint changes by less
than 20 MB.

*Falsified by* a `cb1-wait` change above 3 ms on two or more cases, or a
footprint change above 20 MB.

**P6. tok/s.** F against N in the same session: **+1 to +6%** on every case.
That comes from P4's `io` saving over step 1's wall of 154 / 187 / 203 ms.

*Falsified by* any case outside that range. As P4 says, run-to-run noise is of
the same size as the effect, so this can fail on noise. A thermal note goes
with any run that reached `serious`.

## What happens next

- **If P1 holds and P2 holds:** the fitted guess replaces step 1's whenever the
  early read is on. Whether to turn the early read on by default is a separate
  decision for the user to make: it trades bytes/token for tok/s, and the guess
  file would have to be shipped with the model.
- **If P2 holds but tok/s does not move:** guess quality is not what limits the
  early read. The next thing to look at is timing: when the read starts, and
  whether a second read per layer fits.
- **If P1 fails:** fix it before anything else.
