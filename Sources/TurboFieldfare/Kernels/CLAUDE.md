# Kernel wrappers

Swift-side dispatch wrappers for the shaders in `../Metal/`. This directory owns pipeline selection, buffer binding, and threadgroup sizing — not numerics.

## Directory-local conventions

- Subdirectories mirror `../Metal/` one-to-one. A wrapper lives in the subdirectory matching the shader it dispatches.
- The wrapper is the only place the shader's argument order is written down on the Swift side. It is duplicated by hand from the `.metal` source and is not compiler-checked — when either side changes, change both in the same commit.
- Pipeline state comes from the lock-guarded cache in `MetalContext`. Do not construct pipelines ad hoc, and do not cache an `MTLComputePipelineState` in a wrapper's own storage.
- Wrappers encode into a command buffer supplied by the caller; they do not create, commit, or wait on command buffers. Scheduling is the runtime's job (see `../Runtime/CLAUDE.md`).
- Prefer adding a parameter to an existing wrapper over forking a near-duplicate. The decode and prefill variants are genuinely different paths and stay separate: single-token decode uses the custom affine INT4/INT8 GEMV kernels, prefill uses staged-affine MPP `matmul2d` once rows justify it.

## Ownership hazard

A queued GPU consumer owns its expert slot and scratch bank until completion. A wrapper must never bind a buffer the CPU may recycle before the encoding command buffer finishes. If a change makes a wrapper's lifetime assumptions less obvious, write the assumption down at the call site.

## Stating the effect

Wrapper changes usually have zero bytes/token delta. Say so, and name the phase you expect to move instead (`cb1-wait`, `head`, a `[gpu-time …]` buffer). Changes that do move bytes: anything altering how many expert slots a dispatch needs live at once, prefill tile width (two tiles must fit the expert cache, which is why chunked prefill needs at least 16 slots), and which weights must be resident.

## Tests

Kernel tests compare against the CPU reference in `TurboFieldfareValidationSupport` with a seeded `SplitMix64` and a named tolerance, run via `Scripts/test.sh`. Suites touching process-wide state are `.serialized`.
