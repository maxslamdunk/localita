# Metal shader sources

`.metal` files here are bundle resources, compiled into one `MTLLibrary` at startup by `MetalContext`. Edit a shader, rebuild the Swift target — there is no Xcode metallib step.

**Plan mode is required before editing any file in this directory.** State the change and its predicted bytes/token delta, get agreement, then edit.

## Directory-local conventions

- Subdirectories mirror `../Kernels/` one-to-one: `Attention/`, `Fusions/`, `MoE/`, `Prefill/`, `Primitives/`, `Quant/`, `Sampling/`, `TensorCore/`. A new shader goes in the subdirectory whose Swift wrapper will dispatch it; if there is no matching wrapper directory, create both or neither.
- One `.metal` file per subdirectory is the existing shape (`moe.metal`, `attention.metal`, …). Add kernels to the existing file rather than creating a second one, unless the subdirectory is genuinely new.
- Every kernel name lands in one flat global namespace across the whole library. Prefix names by area so collisions are impossible at link time.
- Kernel argument order is the contract with the Swift wrapper and is duplicated by hand there. Changing a buffer index, adding a parameter, or reordering arguments is a two-file change — the compiler will not catch a mismatch.

## Load-width rule

Packed-weight load width must match the alignment the path actually guarantees, not the alignment that would be convenient:

- Resident INT4 GEMVs and routed **gate/up** projections: offsets can be as loose as 2-byte aligned. Build 4-byte values from two `ushort` loads.
- Routed **down** projections: offsets are 4-byte aligned; `uint` loads are permitted.

Widening a load without proving the alignment invariant holds on that path is the recurring bug in this directory.

## Numerics

- Reordering float operations is allowed. Kernels must stay deterministic within a path and land inside the named `Tolerances`; exact bit identity across paths is not required and should not be engineered for.
- Gemma 4 specifics any shader touching them must preserve: NeoX RoPE, attention scale `1.0`, no router-logit softcap, parallel shared + routed FFN, learned layer scalar, final logit softcap `30.0`, tied 4-bit embedding/head.
- K and V stay distinct after normalization/RoPE even where the raw projection is shared.

## Validation

Every behavior change needs a kernel test comparing against the CPU reference in `TurboFieldfareValidationSupport`, seeded with `SplitMix64`, using a named tolerance. Run through `Scripts/test.sh` — shared Metal state makes in-process parallelism unreliable.
