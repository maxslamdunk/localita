# Results — grouped full attention (#182) on the iPhone 17

Predictions are in `predictions.md` (`e46b8d1`). They were committed before
the merge and before any run. The runs took place over two sittings,
2026-10-01 20:10–20:43 UTC and 2026-10-02 00:30–01:04 UTC, with the phone in
use in between.

## Setup

- **A:** `810068b` (pre-merge) with the harness commit `016270a`
  cherry-picked onto it. It uses the old split-KV full attention.
- **B:** `016270a`, i.e. the merge `5820bbd` plus the same harness commit. It
  uses grouped full attention. Both bundles were checked: the grouped kernel
  source is present only in B.
- Release, iPhone 17, iOS 26.6, the side-loaded `gemma4.gturbo` (written
  2026-09-16), 24 slots, `--max-new 1024 --max-context 4096`, prefill chunk
  `auto`, battery 100%/full, Low Power Mode off, other apps closed, network on.
- The harness was driven by `run-ab.sh`, with each arm installed over the
  existing app.
- Order: short A B, medium B A, then the long runs. The first sitting had one
  long A run. The second had a full A B B A. There was a 5-minute cooldown
  between runs.
- Mac arm: **not run.** The Mac predictions are unscored.

## Runs (ms per decode forward)

| run | tok/s | text sha256 | bytes/tok | hit | cb1-wait | io | head | wall | thermal (samples) | compressions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| short-A1 | 5.619 | `d32db73b…` | 160.71 MiB | 79.1% | 53.52 | 107.74 | 9.63 | 178.33 | nominal 34 | 403K |
| short-B1 | 5.750 | `d32db73b…` | 160.71 MiB | 79.1% | 53.01 | 104.13 | 9.67 | 174.27 | nominal 34 | 428K |
| medium-B1 | 4.811 | `209ffadb…` | 187.08 MiB | 75.7% | 63.03 | 126.59 | 10.37 | 208.19 | nominal 42 | 885K |
| medium-A1 | 4.361 | `209ffadb…` | 187.08 MiB | 75.7% | 68.28 | 142.11 | 10.61 | 229.67 | nominal 42 | 1,715K |
| long-A1 (sitting 1) | 4.165 | `87f6f357…` | 204.59 MiB | 73.4% | 83.52 | 138.04 | 10.00 | 240.50 | nominal 42 | 1,450K |
| long-A1 | 4.163 | `87f6f357…` | 204.59 MiB | 73.4% | 83.64 | 138.20 | 9.91 | 240.64 | nominal 42 | 1,442K |
| long-B1 | 4.392 | `87f6f357…` | 204.59 MiB | 73.4% | 71.83 | 137.08 | 10.62 | 228.04 | fair 30 / nominal 12 | 797K |
| long-B2 | 4.319 | `87f6f357…` | 204.59 MiB | 73.4% | 72.32 | 140.26 | 10.65 | 231.90 | fair 39 / nominal 3 | 852K |
| long-A2 | 4.003 | `87f6f357…` | 204.59 MiB | 73.4% | 91.45 | 138.42 | 11.00 | 250.20 | fair 39 / nominal 3 | 1,155K |

- **All runs ended `stop=endOfTurn`**, with 507, 632 and 602 new tokens.
- **Bytes/tok is in MiB.** The footer prints MiB but labels it MB.
- **Compressions** is the phone-wide compressor counter's change from `start`
  to `done`.
- **Not scored:** a short-A1 that the script falsely declared dead, and a
  long-B1 cut off when the phone was needed. Both are in `logs/aborted/`.

## Scoring

| Prediction | Measured | Verdict |
| --- | --- | --- |
| Text byte-identical across arms | identical within every pair; all five long runs identical (`cmp`) | **held** |
| Bytes/token, hit rate, req/tok identical | identical to the digit | **held** |
| `io` within ±6% across arms | short −3.4%, long within 1.7%; **medium −10.9%** | held, except medium |
| Peak footprint within ±20 MB | max 5.2 MB apart | **held** |
| Kernel suites pass on the phone, identity tests bitwise | 179 tests in 51 suites, 0 failures, 0 skipped; `GroupedAttentionIdentityTests` all pass | **held** |
| Short `cb1-wait` 0 ± 1.5 ms | −0.51 | **held** |
| Medium `cb1-wait` −1 to −3 ms | −5.25 | **missed: larger gain** |
| Long `cb1-wait` −4 to −10 ms (−4 to −11%) | −11.8 to −19.1 (−14 to −21%) | **missed: larger gain** |
| Long tok/s +2 to +5% | +5.5% (first pair), +6.7% (A B B A means) | at or above the top |

The branch that fired is **"long improves by more than 12%"**: the fit
underestimated the full-attention share of `cb1-wait`.

## What the long case shows

- **The gain is attention, and only attention.** Across all four long runs in
  the second sitting, `io` stayed within 137.1–140.3 ms. The text, bytes/token
  and hit rate were identical. `cb1-wait` and wall are the only figures that
  moved.
- **Size of the gain:** from −11.8 ms to −19.1 ms per token.
  - −11.8 ms is the first pair: B1, mostly `fair`, against A1, `nominal`. That
    pairing works against B, so it is the conservative figure.
  - −19.1 ms is the second pair: B2 and A2, both `fair` for 39 of 42 samples.
    It is the thermally matched figure.
  - The A B B A means give −15.5 ms (87.55 → 72.08, −17.7%).
- **The old kernel reproduces well.** Long-A1 gave `cb1-wait` 83.52 and 83.64
  across the two sittings, six hours apart, and 4.165 and 4.163 tok/s.
- **The medium pair is not a clean reading.** Its A run had 1.9× the
  compressor churn of its B run, and `io` differed by 11%, so its tok/s gap
  is mostly not the kernel. Its `cb1-wait` delta of −5.25 ms is still informative, because
  the prediction gave the whole full-attention term at medium length as only
  ~3.5 ms. A saving can't exceed that term, so the two-point fit
  misattributed growth between the sliding-window and full layers. It should
  not be reused.

## A thermal observation, not established

Long-A2 ran at `fair` and its `cb1-wait` was 7.8 ms (+9.3%) above long-A1 at
`nominal`. Its `head` rose 11%, and its `io` stayed flat. That is the GPU
slowing at `fair`. The 2026-09-16 finding was that `serious` hit the fetch
path five times as hard as the GPU, so this looks like a different pattern.
But long-B1 and long-B2, at 30 and 39 `fair` samples, differ by only 0.5 ms.
With n=1 per state, this is a note, not a rule. Pairing runs by thermal state
remains the right control.

## Consequences

1. **Grouped full attention is a real, quality-neutral win on the iPhone at
   long context.** It saves 12–19 ms of GPU time per token at ~3.3K context,
   with bit-identical output. It is already on by default after the merge, so
   no action is needed.
2. **The win grows with context**, from ~0 at short length to −5 ms at
   medium to −12 to −19 ms at long. A conversation nearing the 8K iOS cap
   should gain more. That is unmeasured.
3. **`cb1-wait` on the phone is now ~72 ms on the long case at 24 slots.**
   Any decode-phase comparison against an earlier phone row needs to account
   for this.
4. **How `cb1-wait` splits between sliding-window and full attention is
   unknown.** It needs a direct per-kernel GPU timing, not a fit over the
   three protocol cases.
