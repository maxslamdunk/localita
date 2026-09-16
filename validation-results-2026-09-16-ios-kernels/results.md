# Results — on-device kernel numerics, iPhone 17, 2026-09-16

Scored against `predictions.md`, committed in `884d0fe` before the run.

## Measured

```
✔ Test run with 142 tests in 46 suites passed after 30.381 seconds.
```

**142 tests, 46 suites, 0 failures, 0 skipped.** Debug configuration,
`arm64-apple-ios26.0`, hosted in the `iOS/` app on the iPhone 17. No model
loaded; every suite builds seeded synthetic data via `SeedTree`.

### The control: nothing was silently filtered

A green run is worthless if the device quietly ran fewer tests than the Mac, so
this was checked rather than assumed:

| | |
| --- | --- |
| Line-anchored `@Test` declarations in the in-scope files | **142** |
| Tests reported by swift-testing | **142** |
| `skipped` / `withKnownIssue` / `disabled` lines | **0** |

The declaration count matches the reported count exactly, and the skip count is
zero. ⚠️ Only **126** individual `✔ Test …passed` lines are printed, which is a
display artifact, not a gap: 15 of the 142 declarations are parameterized
(`arguments:`) and their individual cases are not each given a line at default
verbosity. An earlier reading of this file's counts guessed the 142 was inflated
by doc-comment prose; that guess was **wrong** — the line-anchored count is also
142.

## Scoring

All four predictions held.

- **V1 — the text decode path passes within existing tolerances. HELD.** Every
  non-Vision kernel suite passed unmodified: Primitives (`RMSNormTests`,
  `RoPETests`), Quant (`DequantInt4GEMVTests`, `DequantInt8GEMVTests`,
  `EmbedLookupTests`), MoE (`MoEFusedFFNTests`, `RouterTopKTests`,
  `SharedExpertInt4Tests`, `SharedExpertInt8Tests`), Attention
  (`AttentionTests`, `PrefillAttentionTests`), Fusions (all six, including
  `LMHeadChainInt4Tests`), Sampling (`LogitSoftcapSoftmaxTests`, `SampleTests`,
  `SampleTopK64Tests`), and all thirteen Prefill suites.
- **V2 — the comparator itself is unchanged on the A19. HELD.** All nine
  `Validation/Reference/` suites passed, so Accelerate on the A19 agrees with
  the independent from-scratch scalar formulations to `Tolerance.identity`
  (1e-5). This was the prediction whose failure would have been the more serious
  outcome — it would have meant every kernel comparison in the project was being
  measured against a shifted yardstick. It was not.
- **V3 — Vision passes, at low confidence. HELD.** `VisionAttentionTests` and
  `VisionLinearBF16Tests` both passed. **My risk assessment was more pessimistic
  than reality**, and that is worth recording as a calibration point: `CLAUDE.md`
  named the vision tower as the one place the Apple10 risk was never retired, and
  BF16 handling is where GPU families most plausibly diverge. At kernel level it
  does not diverge here.
- **V4 — `MPPPrefillInt4QMMTests` is the second most likely surprise. HELD.** It
  passed. The TensorOps/MPP staged-affine path behaves within tolerance on
  Apple10, so the prefill chunk-size result does not need re-examination on these
  grounds.

Four-for-four is unusual in this log, and the honest reading is that the
predictions were not very daring: V1 and V2 were high-confidence going in. The
informative ones were V3 and V4, and both resolved toward "no divergence".

## What this does and does not establish

**Establishes.** The Metal kernels of the text decode path, and the prefill and
sampling paths, compute results within the project's existing `Tolerances`
against the CPU reference **on Apple10 silicon**. Track A's numerical requirement
is addressed at kernel level — see **Disposition** below for what that leaves
open. The measured-facts rows for the iPhone 17 rest on kernels that have now
been checked rather than assumed.

**Does not establish, and must not be quoted as:**

1. ~~**Margins.**~~ **RESOLVED, same day — see `margins.md`.** This was correct
   when written: the run was binary conformance, and a subtle Apple10
   degradation inside the bar would have been invisible. `RelError` is now
   instrumented, and the follow-up this item asked for has been done. The answer
   is stronger than "conformant": across **all 41 shared instrumented call sites
   the worst-case relative error is numerically identical on the A19 and the
   M1**, and text-path kernels sit at ≤43% of their bounds.
   ⚠️ Two qualifications carry forward. Coverage is partial — only comparisons
   routing through `RelError` report a margin (42 sites across 25 of 48 files),
   and the rest, **including both Vision suites**, assert bytewise or structural
   equality where a margin is undefined. And the three tightest margins
   (`MPPPrefillInt4QMMTests:179` at 98% on a disjunctive assertion,
   `PrefillAffineTests:169` at 80%, `MPPPrefillInt4QMMTests:189` at 77%) are
   identical on both machines, so they are tolerance tightness, not Apple10
   divergence.
2. **End-to-end equivalence.** These are kernels in isolation against CPU
   references. The device still generates **different text** from the Mac
   (507 / 632 / 602 tokens vs. 511 / 669 / 604). This run does not explain that
   difference and does not show the composed forward pass matches. Kernel-level
   conformance is necessary for end-to-end equivalence, not sufficient.
3. **Timings.** Almost every suite reports ~21.02 s against a 30.381 s total —
   that is a parallel-execution artifact, not per-suite duration. Additionally
   the build is Debug, so the Swift host code is unoptimized. The GPU code *is*
   the benchmarked code (`.metal` sources are compiled at runtime by
   `MetalContext` identically in both configurations), but no timing from this
   run may be quoted anywhere.
4. **The excluded file.** `PrefillGroupedRoutedMoETests+Binding.swift`, 8 tests,
   did not run on device. All eight are orchestration — slot lifetime,
   expert-to-slot binding, tile planning, pread cache-plan hit/miss accounting —
   and none compares a GPU result to a CPU reference, so no numerical coverage is
   lost. Still a real gap in device coverage of that plumbing.

## Why there is no `MEASUREMENTS.md` row

`MEASUREMENTS.md` is the append-only log for **real-model runs**, and its columns
are bytes/token, hit rate, tok/s and thermal. This run loaded no model and has
none of those quantities; a row would be four empty cells. The durable record
therefore goes to `CLAUDE.md`'s measured-facts table and `docs/IOS_PORT.md`
instead. Flagging the judgement call rather than making it silently.

## Disposition

⚠️ **This does not close Track A's numerical bullet.** That bullet asks for
"Same `.gturbo` artifact, same sampling config, output within the existing
`Tolerances` against the CPU reference" — *output* equivalence, end-to-end, on
the real artifact. What is established here is *kernel* conformance in
isolation, on synthetic data, with no model loaded. Necessary, not sufficient.

What has changed is the size of the assumption, not its disappearance. Before
this run, every iPhone 17 row in `CLAUDE.md` rested on "the prose is coherent
and it stops in the right place". Now the kernels underneath those rows are
checked against the same CPU references that gate the Mac, and the residual risk
is confined to **composition** — how conformant pieces combine over a full
forward pass — rather than spread across every kernel in the path.

The other Track A items are unchanged and unaddressed by this run: nothing in
the runtime or harness listens for memory warnings, and `slotCount` is `let`, so
the expert cache cannot shed under pressure.

The natural follow-up, if it is worth the cost, is margin instrumentation — it
would turn "conformant" into a number, and would be the only way to notice
Apple10 drifting toward a tolerance bound before it crosses one.
