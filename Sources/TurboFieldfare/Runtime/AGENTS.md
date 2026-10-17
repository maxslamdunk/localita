# Runtime

Orchestration: configuration, the forward runner, KV cache, prefill scheduling, sampling, and generation. This directory decides *when* work is scheduled and *what is read from disk* — which makes it the directory where bytes/token is actually set.

## Directory-local conventions

- `Configuration/` — `RuntimeConfiguration` is the only place a runtime control is defined. Public controls are limited to those documented in `docs/RUNTIME_CONTROLS.md`, which also holds the current defaults; adding or changing a control means updating that doc in the same change. Defaults may differ by platform when their cost does (expert-cache slots: 16 macOS, 24 iOS; prefill chunk cap: 256 macOS, 1024 iOS).
- `Inference/` — `RealForwardRunner` owns the per-layer schedule; `ModelExpertIO` owns expert read planning. Anything that changes how many experts are fetched belongs here, not in a kernel wrapper.
- `Generation/` — sampling and stop handling. No Metal, no disk I/O.
- `KVCache/`, `Prefill/` — FP16 KV cache and chunk scratch. Both are sized against the memory ceiling, not against convenience.

## The cb1 / io / cb2 handoff

Per layer: `cb1` (Metal) runs norm → QKV → RoPE + KV write → attention → output projection → router, stopping when the top-8 expert IDs are CPU-readable. `io` plans against the layer's LFU expert cache and `pread`s only the misses, while Metal concurrently runs the resident shared-expert branch. `cb2` finishes the routed branch, reduces by router weights, combines with shared, and applies the layer tail.

Two things follow, and both get violated by well-meaning refactors:

- **The three original counters are CPU encode cost, not phase duration.** `totalCb1Nanos` subtracts its own `waitUntilCompleted`; `totalCb2Nanos` counts encode-and-commit and never the routed buffer's execution. `totalCb1WaitNanos` and `totalRoutedDrainNanos` hold the GPU execution they exclude. All use `CLOCK_UPTIME_RAW` — there is no clock-mismatch problem, only a scope one. Read the breakdown through `DecodePhaseTimings`, which carries all six.
- **`io` hides GPU work.** It is the fetch window, and the resident shared-expert branch executes throughout it. Shrinking `io` below the shared branch's duration buys nothing; the branch's own time is counted nowhere.
- **The overlap is the design.** Any change that makes `io` wait on `cb1` completion, or `cb2` start before `io` has issued, converts a hidden read into a visible stall. That is a regression even if bytes/token is unchanged.

## Where bytes/token and decode time are set

Most of what decides how many bytes are read, and when, lives here. A performance change needs a written prediction before the run that scores it (root `AGENTS.md`), stating the bytes/token delta and the time delta separately — they do not always move together.

- Expert-cache slot count, eviction policy, and admission — a hit is a read that did not happen.
- Read planning in `ModelExpertIO`: coalescing, tile width, and speculative reads. The early expert read raises bytes/token and still cuts `io`, because it reads during storage-idle time; a speculative read is judged on time, with its bytes counted as a cost.
- Prefill chunking and tile size — prefill streams experts in tiles of ≤8, and two tiles must fit the expert cache.
- Context length, which sets KV residency and therefore how much memory is left for cache slots.
- Scheduling of `cb1`/`io`/`cb2` and command buffers — the 14–17 ms/token of CPU/GPU handoff and the GPU's idle time inside `io` are set here too.

Report prefill and decode byte profiles separately; they are not comparable.

## Bounded memory

No path here may hold a whole model, shard, expert, or source tensor in Swift heap memory. `model_weights.bin` is mmapped read-only and wrapped in `MTLBuffer`s without copying; routed experts land in pre-allocated 2 MiB-aligned slot buffers via `makeBuffer(bytesNoCopy:)` + `pread`. A change that buffers a full tensor breaks the project's premise regardless of what it does to throughput.

## Tests

Behavior changes need a focused test via `Scripts/test.sh`. Suites touching process-wide state are `.serialized`. Exactly one model-owning process may run at a time on the Mac validation host.
