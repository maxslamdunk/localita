# Predictions — upstream 0.9.1 merge, grouped full attention (#182)

Written 2026-10-01 before the merge and before any run. Pre-merge HEAD is
`810068b`; upstream is `77e8f9c` (0.9.1). Of the three upstream commits, only
#182 touches the decode path: `Attention.encodeFull` now defaults to
`attention_decode_full_grouped_vec_partial` for Gemma 4's five full-attention
layers, at every context length. #179 and #186 are Mac UI and build changes.

Upstream's only evidence is one run on an M5 Pro 24 GB with a 110,000-token
prompt, 32 slots and greedy decoding: 8.14 → 18.02 tok/s, with all 256 token
IDs matching. Nothing was measured at 4K context, on Apple7 or on Apple10.

## Measurement plan

Run a same-session A/B on each machine: pre-merge `810068b` against the merge
commit, using `real-generation-v1` with defaults (`--max-context 4096`).
Discard the warmups. Use 16 slots on the Mac and the 24-slot iOS default on the
phone. Interleave A B A B on the long case, since that is the only case where
the effect should be larger than run-to-run noise. Record thermal state beside
every phone run.

## Controls (a miss here invalidates the run, not the hypothesis)

- **Generated text is byte-identical** between the A and B arms on the same
  machine, with token counts equal and `stop=endOfTurn`. Grounds:
  `GroupedAttentionIdentityTests` uses `memcmp` to assert that the new kernel
  matches the old one byte for byte, at lengths 1 to 65,536.
- **Bytes/token, hit rate and req/tok are identical to the digit** across arms.
  This follows from identical text. Predicted bytes/token delta: **exactly 0**.
- `io` stays within ±6% across arms, the same-session spread already observed
  between runs with identical tokens.
- Peak `phys_footprint` stays within ±20 MB. The KV allocation at 4096 is
  unchanged, and #182 adds only a guard and an error case.
- Kernel suites on the phone all pass, including the new
  `GroupedAttentionIdentityTests` at bitwise identity on Apple10.

## Central prediction: `cb1-wait` ms/forward, B minus A

This comes from a two-point fit of `cb1-wait` growth across the three cases.
For the short case, average decode length is ~315 for both SWA and full
attention; for medium, ~750 SWA and ~760 full; for long, 1,024 SWA (capped at
the window) and ~3,320 full. The fit attributes **~4.8 µs per cached token to
the five full-attention layers on the Mac, and ~4.6 µs on the iPhone**. That
puts the full-attention term at about 1.5 / 3.6 / 15.9 ms per forward (Mac)
and 1.5 / 3.5 / 15.3 ms (iPhone) for short / medium / long. The prediction
assumes the new kernel runs that term 1.4–3.5× faster at these lengths. The
upper end is the ~3.6× implied by upstream's 110K result once non-attention
time is removed.

| | short | medium | long |
| --- | --- | --- | --- |
| Mac `cb1-wait` | 0 ± 1.5 ms | −1 to −3 ms | **−4 to −11 ms (−3 to −9%)** |
| iPhone `cb1-wait` | 0 ± 1.5 ms | −1 to −3 ms | **−4 to −10 ms (−4 to −11%)** |
| Mac tok/s | noise | noise | +1 to +4% |
| iPhone tok/s | noise | noise | +2 to +5% |

The iPhone's percentage gain is larger because `cb1-wait` and wall time are
smaller there, while the absolute saving is about the same.

There is a possible regression at short lengths. The grouped kernel launches
2 × 16 threadgroups instead of 16 × 16, and each lane does 9 `simd_sum`s per
cached position. If that underfills the GPU, the short case could get slower.
This prediction assumes the effect is under 1.5 ms.

## What each outcome means

- **Text or bytes differ across arms**: production composition does not
  match the unit-level identity, which is a correctness question. Score
  nothing and investigate first.
- **Long `cb1-wait` improves by less than 3%, or worsens, in both interleaved
  pairs**: the 110K speedup does not carry down to ~3K on this hardware. The
  kernel stays, since it is upstream's default and is bit-identical, but it
  is not a lever for the port's context lengths.
- **Long improves by more than 12%**: the fit underestimates the full-attention
  share of `cb1-wait`, so the per-layer attribution above is wrong and needs a
  direct measurement.
- **Short gets worse by more than 1.5 ms in both arms' runs**: an occupancy
  regression. Before accepting it, look at a length gate such as
  `effLen >= N`.

A single run cannot confirm the low end of the long-case range. On the Mac,
the same-session `cb1-wait` spread is up to 4.7% (~6 ms on the long case),
which is why the long case runs as interleaved pairs.

## Outcome (appended 2026-10-02, iPhone only)

All controls held: identical text in every pair, bytes unchanged to the digit,
peak footprint within 5.2 MB, and 179/179 device kernel tests passing, with
bitwise identity. The one exception is `io` on the medium pair, which differed
by 11% under compressor churn. On `cb1-wait`, short held at −0.51 ms. Medium
and long **missed on the side of a larger gain**: −5.25 against −1 to −3, and
−11.8 to −19.1 against −4 to −10. The branch that fired is "more than 12% on
long", so the fit's attribution is wrong. The Mac arm was not run. See
`results.md`.
