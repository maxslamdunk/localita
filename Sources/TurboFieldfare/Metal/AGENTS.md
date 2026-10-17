# Metal shader sources

`.metal` files here are bundle resources, compiled into one `MTLLibrary` at startup by `MetalContext`. Edit a shader, rebuild the Swift target — there is no Xcode metallib step.

Before a shader change is claimed, it needs a kernel test against the CPU reference and a pass of the device kernel suites on the iPhone (Apple10 — the Mac is Apple7, so a Mac pass alone does not cover the target). A performance change also needs a written prediction, per the root `AGENTS.md`. Plan mode is not required.

## Directory-local conventions

- Subdirectories mirror `../Kernels/` one-to-one: `Attention/`, `Fusions/`, `MoE/`, `Prefill/`, `Primitives/`, `Quant/`, `Sampling/`, `TensorCore/`, `Vision/`. A new shader goes in the subdirectory whose Swift wrapper will dispatch it; if there is no matching wrapper directory, create both or neither.
- Most subdirectories hold one `.metal` file; `Primitives/`, `Quant/` and `Vision/` hold several. Add a file when it makes the code easier to find.
- Every kernel name lands in one flat global namespace across the whole library. Prefix names by area so collisions are impossible at link time.
- Kernel argument order is the contract with the Swift wrapper and is duplicated by hand there. Changing a buffer index, adding a parameter, or reordering arguments is a two-file change — the compiler will not catch a mismatch.

## Load-width rule

Packed-weight load width must match the alignment the path actually guarantees, not the alignment that would be convenient:

- Resident INT4 GEMVs and routed **gate/up** projections: offsets can be as loose as 2-byte aligned. Build 4-byte values from two `ushort` loads.
- Routed **down** projections: offsets are 4-byte aligned; `uint` loads are permitted.

Widening a load without proving the alignment invariant holds on that path is the recurring bug in this directory.

## Numerics

- Reordering float operations is allowed. Kernels must stay deterministic within a path and land inside the named `Tolerances`; exact bit identity across paths is not required.
- When a new kernel replaces an old one on the same math, a bitwise identity test against the old kernel is worth having if the reduction order allows it (`GroupedAttentionIdentityTests` is the example). Identical output turns the phone A/B into a clean control: any timing difference is the kernel.
- Gemma 4 specifics any shader touching them must preserve: NeoX RoPE, attention scale `1.0`, no router-logit softcap, parallel shared + routed FFN, learned layer scalar, final logit softcap `30.0`, tied 4-bit embedding/head.
- K and V stay distinct after normalization/RoPE even where the raw projection is shared.

## Validation

Every behavior change needs a kernel test comparing against the CPU reference in `TurboFieldfareValidationSupport`, seeded with `SplitMix64`, using a named tolerance. Run through `Scripts/test.sh` — shared Metal state makes in-process parallelism unreliable. Put it under `Tests/TurboFieldfare/Core/Kernels/` so the device test bundle picks it up.
