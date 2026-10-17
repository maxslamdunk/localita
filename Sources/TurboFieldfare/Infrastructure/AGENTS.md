# Infrastructure

Metal context ownership, model I/O and layout readers, and the expert streaming path. `Streaming/` is the code that issues the reads the whole project is budgeted against.

## Directory-local conventions

- `Metal/MetalContext.swift` is the single owner of device, queue, library, and the lock-guarded pipeline cache. There is exactly one. Do not create a second `MTLDevice` or `MTLCommandQueue` anywhere, and do not cache pipeline state outside this cache.
- `ModelIO/` mirrors the `.gturbo` v1 contract defined in `TurboFieldfareFormat`. The format module is the authority: readers here validate against it rather than reimplementing layout rules, so the installer, the verifier, and the runtime all reject the same files.
- `Streaming/` — `ExpertStreamer` is the protocol, `PreadExpertStreamer` the production implementation, `RDAdvice` the opt-in advisory path (off by default). Keep alternative streamers behind the protocol; do not branch on implementation type at call sites.

## Every read is accounted for

This directory is where bytes/token becomes a real syscall. A performance change here states its predicted bytes/token delta and its predicted `io` delta, with the mechanism named: fewer reads, larger coalesced reads, reads avoided by a cache hit, or reads moved into time when storage would otherwise sit idle. On the iPhone, storage serves one read at a time (~2.2 ms per 3,358,720 B read), so concurrent reads stretch each other rather than adding throughput.

- Reads go through `pread` into pre-allocated 2 MiB-aligned slot buffers wrapped with `makeBuffer(bytesNoCopy:)`. No intermediate `Data`, no `read` into heap, no copy on the way to the GPU.
- Slot alignment is load-bearing for the no-copy path — changing alignment or slot sizing is a bytes/token *and* a correctness change.
- A queued GPU consumer owns its slot until completion. Never `pread` into a slot whose previous consumer may still be in flight.
- RDADVISE stays off in benchmarks. It is an experimental control; results with it enabled are not comparable to the numbers in `MEASUREMENTS.md`.

## Bounded memory

`model_weights.bin` is mmapped read-only. Nothing here may materialize a whole model, shard, expert, or source tensor in Swift heap memory — including in verification and error paths, where it is easiest to do by accident.

## iOS port

This is the directory most likely to need target-conditional code. Keep platform differences behind the existing protocol boundaries (`ExpertStreamer`, the model directory reader) rather than sprinkling `#if os(iOS)` through call sites, and measure iOS byte profiles separately — the storage stack is not the macOS one.
