# Margins — how much tolerance headroom the kernels actually have

Follow-up to `results.md`, which could establish **conformance** but not
**headroom**: `#expect(relErr < T)` prints `relErr` only on failure, so a kernel
at 0.99× its bound looked identical to one at 0.01×.

`RelError.compute` and `.boundedRel` now report every comparison with its source
location, so a passing suite states how much room it had. Always on rather than
env-gated: reaching an on-device bundle with an environment variable means
editing `EnvironmentVariables` in the generated `.xctestrun`, and ~42 extra lines
in a 1,734-test run is not noise worth plumbing around.

## The headline: the A19 and the M1 agree exactly

| | |
| --- | --- |
| Shared instrumented call sites | **41** |
| Sites where the worst-case relative error **differs** | **0** |
| Device-only site | `MPPPrefillInt4QMMTests.swift:307` (gated on `mppTensorOpsAvailable`; 0.0) |

Every shared call site reports a **numerically identical** worst-case relative
error on Apple10 and Apple7 — same value to all printed digits, at all 41.

⚠️ **This claim survived three broken attempts to check it**, which is worth
recording because the broken ones *looked* like success. `join` and `comm` both
returned "0 differences" while silently matching nothing, because the device log
carries carriage returns and `[^ ]*` captured `\r` into every call-site name. The
verified run strips `\r`, asserts the join covered ≥ 40 sites before drawing any
conclusion, and is corroborated by an independent spot-check of five sites using
a different extraction method. A "0 differences" result from an empty join is the
easiest wrong answer to publish here.

## Where the headroom actually is

Percentages are worst observed relative error ÷ the bound asserted at that line.
Identical on both platforms unless noted.

| call site | worst rel | bound | % of bound |
| --- | --- | --- | --- |
| `MPPPrefillInt4QMMTests:179` | 0.00098 | 1e-3 ⚠️ | **98%** |
| `PrefillAffineTests:169` | 0.000401 | 5e-4 | **80%** |
| `MPPPrefillInt4QMMTests:189` | 0.000768 | 1e-3 | **77%** |
| `SharedExpertInt8Tests:109` | 0.000433 | `quantInt8` 1e-3 | 43% |
| `SharedExpertInt4Tests:51` | 0.000555 | `quantInt4` 1.5e-3 | 37% |
| `PrefillAffineTests:89` | 3.12e-05 | 1e-4 | 31% |
| `EmbedLookupTests:72` | 0.00034 | `quantInt4` 1.5e-3 | 23% |
| `LogitSoftcapSoftmaxReferenceTests:39` | 1.754e-06 | `identity` 1e-5 | 18% |
| `RoPEReferenceTests:74` | 1.713e-06 | `identity` 1e-5 | 17% |
| `DequantInt4GEMVReferenceTests:51` | 1.280e-06 | `identity` 1e-5 | 13% |
| `RoPETests:40` / `:81` | 0.000477 / 0.000470 | `fp16Reduction` 5e-3 | 9.5% / 9.4% |
| `DequantInt8GEMVReferenceTests:42` | 9.854e-07 | `identity` 1e-5 | 9.9% |
| `LogitSoftcapSoftmaxTests:47` | 0.000443 | `fp16Reduction` 5e-3 | 8.9% |
| `DequantInt8GEMVTests:71` | 0.000429 | `fp16Reduction` 5e-3 | 8.6% |
| `RMSNormTests:51` / `:91` | 0.000380 / 0.000280 | `fp16Reduction` 5e-3 | 7.6% / 5.6% |
| `DequantInt4GEMVTests:96` | 0.000349 | `fp16Reduction` 5e-3 | 7.0% |
| `WHTReferenceTests:43` | 5.967e-07 | `identity` 1e-5 | 6.0% |
| `AttentionReferenceTests:75` | 4.179e-07 | `identity` 1e-5 | 4.2% |
| `AttentionTests:100`/`:193`/`:281` | ≤0.000411 | `fp16ChainedReduction` 1e-2 | ≤4.1% |
| `PrefillAttentionTests` (7 sites) | ≤0.000635 | 2e-2 literal | ≤3.2% |
| `MoEFusedFFNTests:157` | 0.000261 | `fp16ChainedReduction` 1e-2 | 2.6% |
| `RMSNormReferenceTests:38` | 2.786e-07 | `identity` 1e-5 | 2.8% |
| 11 further sites | 0.0 | — | 0% |

### Reading the three tight ones

- **`MPPPrefillInt4QMMTests:179` is not as tight as 98% suggests.** Its assertion
  is `baselineRelative <= 1e-3 || baselineMaxAbs <= 0.01` — a **disjunction**, so
  it may be passing on the `maxAbs` arm with the relative arm irrelevant. Quoting
  "98% of its bound" without that qualifier would overstate the risk.
- **`PrefillAffineTests:169`'s 5e-4 bound is inferred, not read directly.** The
  helper defaults to `relTolerance: 2e-4` and one call site (line 229) overrides
  to 5e-4. Since the suite passes, a 0.000401 result cannot have come from the
  2e-4-bounded call, so the max belongs to the 5e-4 one.
- **`MPPPrefillInt4QMMTests:189` at 77% is the genuine tightest hard bound**
  (`relative <= 1e-3`, no disjunction).

**All three are identical on M1 and A19**, so this is tolerance tightness in the
TensorOps/MPP path and one prefill-affine shape — **not** an Apple10 problem, and
not a reason to touch either constant.

## What this does and does not change

**Changes.** This morning's run could say the kernels conform. It can now say the
A19 and the M1 produce identical relative errors at every instrumented
comparison, and that the text-path kernels sit at ≤43% of their bounds with most
far below. The "an Apple10 drift inside a bound would be invisible" caveat in
`results.md` and `CLAUDE.md` is **lifted**: such a drift would now show as a
changed margin.

**Does not change.**
- Still not end-to-end equivalence. These are kernels in isolation on synthetic
  data; the device still generates different text from the Mac.
- **Coverage is partial by construction.** Only comparisons routing through
  `RelError` report a margin — 42 call sites across 25 of 48 in-scope files. The
  other 23 assert bytewise or structural equality, where a margin is undefined.
  ⚠️ That includes **both Vision suites**, the very place `CLAUDE.md` names as the
  unretired Apple10 risk. The place headroom data was most wanted is the one place
  this cannot supply it.
- The reported value is raw `relErr` with a source location, **not** a ratio; the
  bound lives at the call site and `RelError` cannot see it. Every percentage in
  the table above was computed by hand from the assertion, which is fine for a
  one-off and would need real work to automate.
