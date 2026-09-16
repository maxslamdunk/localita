# Predictions — on-device kernel numerics, iPhone 17, 2026-09-16

Written **before** the run. This is a correctness check, not an optimization, so
the bytes/token working agreement does not apply — but the same discipline does,
because the failure mode here is motivated reasoning: if a suite fails, the
tempting move is to relabel it "tolerance noise" after the fact. The
interpretation rules below are fixed in advance to block that.

## What is being checked, and why it matters

Track A's definition of done requires device output within `Tolerances` against
the CPU reference. **That has never been run on the device.** Every number in
`CLAUDE.md`'s four iPhone 17 rows — the 2.03×/1.85×/1.74× over the Mac host, the
slot-count and prefill-chunk results — assumes the A19 computes the same answers
as the M1. The evidence for that assumption is currently: the prose is coherent
and generation stops correctly. That is not evidence of numerical equivalence.

The device also already produces **different text** from the Mac (507/632/602
tokens vs. 511/669/604). That difference is expected and separately explained,
but it means equivalence has never been demonstrated, only assumed.

## How

The package's own kernel suites, run on the device as an Xcode unit-test bundle
hosted in the existing `iOS/` app. These are **the same assertions that gate the
Mac**, not a reimplementation — a reimplementation would drift and then lie.

In scope: all of `Tests/TurboFieldfare/Core/Kernels/**` (Attention, Fusions, MoE,
Prefill, Primitives, Quant, Sampling, TensorCore, Vision) plus
`Tests/TurboFieldfare/Core/Validation/Reference/**`.

**No model is required** — every suite builds seeded synthetic data via
`SeedTree`. So this is not gated by the preflight or the one-model-owning-process
invariant, and the 14.3 GB artifact on the device is untouched.

### Three caveats on what this run can and cannot show

1. **Debug, not Release.** 33 of the test files use `@testable import`, which
   needs `SWIFT_ENABLE_TESTABILITY`, which means the Debug configuration. The
   Swift host code is therefore unoptimized. **The GPU code under test is not**:
   `.metal` sources are compiled at runtime by `MetalContext` from bundle
   resources, identically in both configurations. So the kernels are the
   benchmarked kernels; the Swift around them is not the benchmarked binary. Do
   not quote timings from this run.
2. **Binary pass/fail, not margins.** `#expect(relErr < Tolerance.x)` prints
   `relErr` only on failure. A suite passing at 0.9× its tolerance and one
   passing at 0.05× are indistinguishable in the output. This run can show
   *conformance*, not *headroom*. Measuring headroom would need the tests
   instrumented to emit margins, which is a separate change.
3. **One known coverage gap.** `PrefillGroupedRoutedMoETests+Binding.swift` is
   excluded (see the comment in `project.pbxproj`). All eight of its tests are
   orchestration — slot lifetime, expert-to-slot binding, tile planning, pread
   cache-plan accounting — and none compares a GPU result to a CPU reference, so
   no numerical coverage is lost. Recorded here so it does not become silent
   drift.

## Predictions

- **V1 — the text decode path passes within existing tolerances.** Every
  non-Vision kernel suite passes unmodified: Primitives, Quant, MoE, Attention,
  Fusions, Sampling, Prefill. Mechanism: these kernels are written against
  portable Metal semantics, and the load-width hazards `CLAUDE.md` documents are
  *alignment* constraints, not GPU-family ones. Supporting evidence: ten device
  runs produced coherent text with correct stop tokens.
  *Falsified if* any non-Vision kernel suite reports a tolerance failure.
- **V2 — the comparator itself is unchanged on the A19.** The nine
  `Validation/Reference/` suites pass. These are Accelerate-vs-independent-scalar
  with no GPU involvement.
  *Falsified if* any fails — which would be **the more serious outcome of the
  two**, because it would mean Accelerate differs across these machines and every
  kernel comparison in the project is being measured against a shifted yardstick.
  A V2 failure invalidates V1's result rather than sitting beside it.
- **V3 — Vision passes, at low confidence.** `VisionAttentionTests` and
  `VisionLinearBF16Tests`. `CLAUDE.md` names the vision tower as the one place
  the Apple10 risk was never retired, and BF16 handling is exactly where families
  diverge. I predict pass but would not be surprised by a failure, and a failure
  here does **not** touch the benchmark numbers, because the text paths use the
  `.control` variant.
- **V4 — `MPPPrefillInt4QMMTests` is the second most likely surprise.** It
  exercises the TensorOps/MPP staged-affine path. Upstream #159 changed which
  prefill attention path runs on the M1 and changed generated text there, so this
  is a path where family-specific behavior is already known to exist.
  *Falsified if* it fails — in which case the prefill chunk-size result needs
  re-examination, since that experiment moved prefill work around.

## How a failure will be classified

Fixed in advance:

- **Kernel wrong on Apple10** — the relative error is large, or scales with
  accumulation depth. A correctness bug. Blocks Track A regardless of speed.
- **Tolerance too tight for this GPU** — the error sits just above the bar and is
  flat across sizes. This is a *recalibration*, and per the project's rules it
  needs its own written argument and a new measurement. It is **not** a licence
  to widen a constant until the suite goes green, and I will not quote a
  recalibrated tolerance as a pass in the same breath as the original prediction.
- **Test-harness artifact** — missing resource, sandbox path, allocation failure.
  Not a numerical result at all; fix and re-run.
