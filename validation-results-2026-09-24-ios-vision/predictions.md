# Predictions: Vision kernel margins on the iPhone 17

Written before the run. This is a correctness gate for Phase 4 (image input in
the iOS app), not an optimization, so there is no bytes/token prediction. The
discipline is the same as `validation-results-2026-09-16-ios-kernels/`: the
reading rules are fixed here, so a result cannot be relabelled afterwards.

## Why this is needed

`CLAUDE.md` names Vision as the one unretired Apple10 risk. The 2026-09-16
device run passed both Vision kernel suites, but they assert against absolute
bounds with no margin reported, so a kernel at 0.99 of its bound looked the same
as one at 0.01. `margins.md` from that run says so explicitly.

## What changed to make it measurable

- `Margin.recordAbsolute` prints `[margin] abs=<value> at <file>:<line> [label]`
  for comparisons bounded by an absolute tolerance. `abs=` keeps these from being
  read against a relative bound.
- Every numeric comparison in `VisionAttentionTests` and `VisionLinearBF16Tests`
  now reports its worst error. One comparison was already relative (parallel vs.
  serial softmax) and reports `rel=`. The bytewise `registerMatchesMPPReduction…`
  has no margin by construction.
- `VisionResizeParityTests` (GPU bicubic resize, byte-identical to the CPU
  oracle) joins the iOS test bundle by file reference. It was not in the
  2026-09-16 run, because `Runtime/Vision` is not a synchronized group.

## What the Mac can and cannot anchor

⚠️ **The Mac is not a reference for the production vision path.** Production
vision (`VisionRuntime.resolvedKernelEnvironment`) uses the MPP attention kernel
(`mppTensorOps72`) and the register GEMM, both gated on Apple8. This M1 is
Apple7, and the image tower refuses to run on it at all. So:

- **Shared with the Mac:** only `onlineAttentionMatchesFP32Reference` in the three
  native variants (Q8, default Q16, PAD80), at lengths 5 and 200: six lines.
- **Device only:** every MPP attention variant, both linear-kernel tests, the
  fused-vs-fallback and roundtrip-vs-native cross-checks, and the softmax pair.
  These are judged against their CPU FP32 reference and their bound, not against
  another GPU.

⚠️ **One Apple10-only path has no kernel test at all:** `usesBF16Projector` is on
only when `supportsFamily(.apple10)`. No suite here exercises it. This run cannot
retire it. The end-to-end check (describe a real photo) is the only cover it
will get.

## Predictions

| # | Prediction | Falsifier |
| --- | --- | --- |
| P1 | Every Vision test passes on the device, including the newly added resize parity test. | Any failure. |
| P2 | The six shared native-variant lines are **identical** on the Mac and the device, as all 41 text-path sites were on 2026-09-16. | Any of the six differs in any printed digit. |
| P3 | The FP32-reference errors are **≤ 0.004 on the native variants** (about one BF16 half-ulp at the fixture's output magnitude below 1) and **≤ 0.010 on the MPP variants**, i.e. at most 50% of the 0.02 bound. MPP is given more room because its intermediates may round to half precision. | Any variant above 0.010, or a native one above 0.004. |
| P4 | The constant-product linear test reports exactly 0 on both variants, since 1,152 × 0.125 × 0.25 = 36 is exact in BF16 and FP32. | Anything but 0. The assertion is `== 0`, so this would also fail the test. |
| P5 | The register GEMM's wide and tail errors are **≤ 0.004** (25% of the 0.016 bound). K is 23 and products are small, so BF16 output rounding dominates. | Either above 0.004. |
| P6 | Parallel vs. serial softmax `rel` is **≤ 0.004** (40% of the 0.01 bound). | Above 0.004. |
| P7 | The GPU-vs-GPU cross-checks (fused vs. fallback, roundtrip vs. native) are **≤ 0.008** (40% of 0.02). | Either above 0.008. |

## Reading rules, fixed now

- A test failure is a failure. It is not relabelled "tolerance noise".
- A margin above its predicted level, but inside the bound, is a **missed
  prediction**, recorded as such. It gates Phase 4 only if it is above 50% of the
  bound on a production-path variant (`mppTensorOps72`, the register GEMM). In
  that case the tolerance-tightness question is answered before shipping image
  input.
- If P2 fails, the Mac and the A19 differ on the shared native kernels. That is
  investigated before Phase 4, whatever the margin sizes.
- The join between the Mac and device logs must strip `\r` and be checked to
  cover all six shared lines before any "0 differences" is quoted. See
  `validation-results-2026-09-16-ios-kernels/margins.md` for why.
