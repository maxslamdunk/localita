# Results: Vision kernel margins on the iPhone 17

Predictions are in `predictions.md`, committed first in `ecc40ed`. Mac: M1,
Apple7, macOS 26.6.1, `Scripts/test.sh --filter …`. Device: iPhone 17, A19,
Apple10, `xcodebuild test`, Debug build hosted in the app, `-only-testing` on the
three suites. The GPU code under test is compiled at runtime in both
configurations, as in the 2026-09-16 run.

## Outcome

**All 9 tests in 3 suites pass on the device, and none is skipped.** On the Mac,
3 run and 6 are skipped as not Apple8, as predicted. The GPU bicubic resize is
**byte-identical to the CPU oracle on Apple10**, its first run on the device.

## Margins

The Mac and device lines were joined with `\r` and zero-width characters
stripped, and the join was asserted to cover all six shared lines before
comparing.

| Site | What it compares | Device worst | Bound | % of bound | Mac |
| --- | --- | --- | --- | --- | --- |
| `VisionAttentionTests:291`, len 5, all 7 variants | GPU vs. FP32 CPU reference | 0.000799 | 0.02 abs | 4.0% | identical on the 3 native variants |
| `VisionAttentionTests:291`, len 200, all 7 variants | GPU vs. FP32 CPU reference | 0.0000152 | 0.02 abs | 0.08% ⚠️ | identical on the 3 native variants |
| `VisionLinearBF16Tests:107` / `:108` | register GEMM vs. CPU dot product, wide / tail | 0.001953 / 0.001953 | 0.016 abs | 12% | skipped |
| `VisionLinearBF16Tests:48` | constant product, default and register | 0.0 | `== 0` | — | skipped |
| `VisionAttentionTests:355` | parallel vs. serial softmax | rel 0.00117 | rel 0.01 | 12% | skipped |
| `VisionAttentionTests:95` | fused vs. row-major fallback | 0.0 | 0.02 abs | 0% | skipped |
| `VisionAttentionTests:170` | MPP pad roundtrip vs. native | 0.0 | 0.02 abs | 0% | skipped |

The seven attention variants report the same worst error as each other at each
length: Q8, Q16, PAD80, MPP, MPP with pad roundtrip, and MPP with parallel and
serial softmax. So every kernel is exact up to the final BF16 rounding of its
output. The register GEMM's 0.001953 is 2⁻⁹, one BF16 half-ulp for outputs in
[0.5, 1), which is the same statement.

## Scoring

- **P1, all pass: HELD.** 9 of 9, 0 skipped, resize parity included.
- **P2, shared lines identical: HELD.** 6 of 6 identical to every printed digit.
- **P3, FP32-reference error ≤ 0.004 native and ≤ 0.010 MPP: HELD.** 0.0008
  everywhere, 4% of the bound.
- **P4, constant product exactly 0: HELD.**
- **P5, register GEMM ≤ 0.004: HELD** at 0.00195.
- **P6, softmax pair ≤ 0.004: HELD** at 0.00117.
- **P7, GPU cross-checks ≤ 0.008: HELD** at 0.0.

No production-path margin is above 50% of its bound, so under the reading rules
the gate on Phase 4 is **open**.

## ⚠️ The length-200 case cannot fail on a gross error

The CPU reference's largest output magnitude is **0.288 at length 5 but only
0.0078 at length 200**, computed from the fixture by the same formula the test
uses. At length 200 every expected value is below the 0.02 absolute bound, so a
kernel that wrote zeros, or anything else under 0.02, would pass. Length 200 is
the case the test's own comment calls the only one that exercises the online
rescale between tiles.

The kernels themselves are accurate there: 0.0000152 against a magnitude of
0.0078 is **0.19% relative**, against 0.28% at length 5. So this is a weakness of
the test, not of the kernel, and it does not change the verdict above. It does
mean the absolute bound has certified nothing at length 200. A relative bound,
or a fixture whose outputs at 200 are near 1, would close it. It is not changed
here, because this run measures margins and does not move tolerances.
`rowMajorInputsAreHonoured…` already records the same class of problem in its
own comment.

## What this does not cover

- **The Mac anchors only the native attention variants.** The production vision
  path (MPP attention and the register GEMM) needs Apple8, and this M1 is Apple7.
  Those variants are checked against the CPU reference on the device only.
- **`usesBF16Projector`, the Apple10-only projector path, has no kernel test.**
  Only the end-to-end check in Phase 4 (describe a real photo) exercises it.
- These are kernels in isolation on synthetic data, not the image tower
  composed. That was also the scope of the 2026-09-16 run.
- Memory, the gate's second half, is not measured here. It comes next.
