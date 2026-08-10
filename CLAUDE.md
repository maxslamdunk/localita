# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

TurboFieldfare is a Swift + Metal inference runtime for Gemma 4 26B-A4B (26B total, ~3.9B active) that runs on 8 GB Apple Silicon Macs. It keeps ~1.35 GB of shared weights plus an FP16 KV cache resident and streams the 8 routed experts each token needs from SSD.

## This repository

This repo is the **iOS port**, a separate repository derived from
[`drumih/turbo-fieldfare`](https://github.com/drumih/turbo-fieldfare) (Apache-2.0),
with upstream history kept and `upstream` wired fetch-only.

**Building the port and lowering bytes/token is the priority.** `docs/IOS_PORT.md`
is the active plan. `AGENTS.md` is the operator contract — it governs *how* to
work safely (model-process invariants, benchmark protocol), not what is in scope.

Much of `docs/` and all of `README.md` predate the port and describe the Mac
project. The table under [Document map](#document-map) says what each one is true
of; check it before trusting a document's framing or its numbers.

## The binding constraint

The binding constraint is inherited by the port and gets stricter there, since
iOS has no page-cache tier to fall back on. The binding constraint is **bytes read per token**, not compute. Every optimization, refactor, and design choice gets justified against bytes/token — a change that lowers GPU time while holding bytes/token flat is, by default, not interesting. State the bytes/token effect first, then everything else.

Corollaries that follow from it, and that should shape proposals before compute ever enters the discussion: expert-cache hit rate is a first-class metric because a hit is a read that did not happen; routing locality across consecutive tokens is worth more than kernel throughput; quantization and layout changes matter mainly for how many bytes they pull per routed expert; prefill and decode have different byte profiles and must be reported separately.

**Established by measurement on 2026-08-10, after a day of being briefly in
doubt:** the routed-expert fetch is **59–63% of a decode forward** on the 8 GB
host, about twice the next-largest phase. Reads are where the time goes.

Two qualifications that came with that measurement and that any proposal has to
respect. First, the fetch runs at **41–50% of the device's bandwidth roof**, so
"bytes/token is the constraint" does not mean "the SSD is saturated" — closing
that gap moves time without moving a single byte, and it is the largest known
quality-free win. Second, GPU attention (`cb1-wait`) is **29–35% of a forward
and rises with prompt length**; it is not bytes, no lever in the port plan
addresses it, and on a long-context device workload it will matter. The rule
still ranks proposals, but a change justified purely on bytes/token now needs to
say which of these two it is not making worse.

## Measured facts

**This section is the single source of truth for these numbers.** Do not re-derive, re-estimate, or re-measure them in a session — read them here. If a number is missing or stale, say so and ask; do not substitute a guess, a figure from `docs/BENCHMARKS.md`, or a value recalled from another session. Any number quoted in analysis must either come from this table or be labeled explicitly as a new measurement being taken right now.

| Fact | Value | Measured on | How measured |
| --- | --- | --- | --- |
| Disk read bandwidth (sequential) | _TBD_ | _TBD_ | _TBD_ |
| Disk read bandwidth (routed-expert random reads) | 2.7–3.2 GB/s from SSD; 15.0–17.4 GB/s when served by the OS page cache | 2026-08-10, `417f389` | Standalone probe, model untouched: random `pread` of 3,358,720 B blobs (production slot size) into one 2 MiB-aligned buffer, plain `O_RDONLY` as in `PreadExpertStreamer`; 6 GiB non-sparse file on the model's volume. Two runs. See `MEASUREMENTS.md`. |
| Page-cache capacity for expert reads (8 GB host) | Knee at 256 MiB–1 GiB working set; ~1.44 GB file cache system-wide at idle | 2026-08-10, `417f389` | Same probe swept by working-set size; `vm_stat` File-backed pages at idle. Above ~4 GiB working set the cache contributes nothing (cold ≈ warm). |
| Current decode rate (tok/s) | 3.340 / 3.053 / 2.642 (short / medium / long) on `417f389`; 3.169 / 2.846 / 2.594 on `d271628`+counters; **3.102 / 2.890 / 2.592 on `ce287b6`** | 2026-08-09 and 2026-08-10 (two sessions) | Community protocol `real-generation-v1`, defaults, warmup discarded; all nine `stop=endOfTurn`, identical token counts throughout. The two instrumented binaries are within ±1.6% of each other, so neither counter set costs measurable throughput; both sit 1.8–6.8% below 2026-08-09, and the 2026-08-10 warmups are down by a similar margin, so that shift is session-level and remains unattributed — no interleaved A/B against a counter-free build has been run. Quote whichever binary you are comparing against and say which. See `MEASUREMENTS.md`. |
| Bytes/token (decode, steady state) | **261.9 / 278.8 / 305.6 MB** (249.72 / 265.90 / 291.42 MiB) for short / medium / long. Rises with prompt length. Zero-hit ceiling is **806.1 MB**; measured = ceiling × (1 − hit rate) | 2026-08-10, `d271628`+counters | Community protocol `real-generation-v1`, defaults, `ExpertIOCounters` on the `pread` path. Ceiling is layout arithmetic: `numLayers: 30` × `topKExperts: 8` × `expertStride: 3358720` from the installed `manifest.json`; each of the 30 `packed_experts/layer_NN.bin` is 429,916,160 B = 128 × 3,358,720. Counter validated by the run reporting exactly 240.00 requests/token = 30 × 8, and by warmup and measured processes agreeing to the digit. See `MEASUREMENTS.md`. |
| Expert-cache hit rate (decode, 16 slots, LFU) | **67.5% / 65.4% / 62.1%** (short / medium / long). Falls as prompt length rises | 2026-08-10, `d271628`+counters | Same runs. Counted where the cache planner adopts a plan; a plan it cannot place is not counted. Prefill hit rate is separately **0.0%** on all three cases. |
| Decode phase split (ms per forward) | `io` **202.1 / 209.7 / 228.4** — 59–63% of wall, the largest consumer. `cb1-wait` (GPU attention + router) 95.3 / 111.2 / 133.3, rising with prompt length. `head` 15.4 / 15.5 / 14.4. CPU encode (`cb1` + `cb2` + `routed-drain`) ~4.3 total. Wall 323.0 / 346.6 / 386.4 | 2026-08-10, `ce287b6` | Community protocol `real-generation-v1`, defaults. CLI `[phase-time …]` footer. Columns are sequential within a layer and cover 98.2–98.5% of wall; the flat ~5.9 ms residual is per-token sampling, outside the layer loop. See `MEASUREMENTS.md`. |
| Achieved routed-expert fetch bandwidth (decode) | **1.30–1.34 GB/s**, i.e. 2,511–2,592 µs per 3,358,720 B read — **41–50% of the 2.7–3.2 GB/s device roof** measured by the standalone probe at the same block size | 2026-08-10, `ce287b6` | Derived from the two rows above: decode bytes ÷ `io` ms, and `io` ms ÷ `reads/tok` from the `[expert-io …]` footer. Same-run arithmetic, not a separate probe. The gap between this and the device roof is unexplained and is the largest known quality-free opportunity. |
| Memory ceiling (working set budget) | _TBD_ | _TBD_ | _TBD_ |

Host and target these apply to: macOS validation host = M1 MacBook Air, 8 GB, macOS 26.6.1 (25G76), Swift 6.3.3, internal SSD 256 GB (`APPLE SSD AP0256Q`). iOS device target: _TBD_ — record separately once it exists.

Record storage capacity, not just the model, for every host quoted here. Base-capacity units can ship fewer NAND chips than higher tiers and lose the read parallelism that goes with them — a real effect on base-storage M2/M3 Macs, and the same class of effect exists on base-capacity iPhones. It does not appear to bite this host (256 GB M1 Airs are dual-chip, and the measured 2.7–3.2 GB/s is consistent with that), but it makes any SSD roof carried over from another machine capacity-dependent, including the 16 GB roof assumed equal to ours above.

Where these come from: the runtime instruments bytes/token and cache hit rate via `ExpertIOCounters` on the `pread` path and the expert-cache planner. A defaults CLI run prints them on a second stderr footer line, `[expert-io …]`, decode per forward and prefill as totals; the Mac HUD shows the decode figures. Prefill and decode are bracketed separately and are not comparable. A third line, `[phase-time …]`, prints the decode phase split from `DecodePhaseTimings` — decode only, since chunked prefill does not drive the cb1/io/cb2 handoff. (Historic note: `rdadviseMegabytesPerToken` is *not* this metric — it counts advisory bytes on a branch that is off under production defaults and reads zero in a valid benchmark.)

**Do not quote the 806.1 MB ceiling as the demand figure.** It is the zero-hit ceiling. Real demand is 3.1× lower because the cache hits about two-thirds of requests, and conflating the two is what produced the retracted analysis below.

### RETRACTED (2026-08-10, same day): "Why the 8 GB host is ~2.3× slower than a 16 GB host"

An earlier version of this section argued that our host runs at 95% of its SSD roof and that a 16 GB host's rate is unreachable from SSD, so ≥50% of its expert bytes must be served by the macOS unified buffer cache at DRAM speed. **The measurement below retracts the arithmetic on both sides.** The retracted text is preserved in git history at `d271628`; it is removed here rather than left standing because it was being quoted as settled.

What broke it: that argument used the **806.1 MB zero-hit ceiling as the demand figure**. Measured demand is 261.9 MB/token, because the 16-slot LFU cache hits 62–68% of requests. Redoing both sides with measured bytes:

- **Ours (8 GB):** 261.9 MB per 315.6 ms token = **0.83 GB/s, ~29% of the measured 2.7–3.2 GB/s SSD roof.** This host is *not* bound by the *device's* bandwidth ceiling during decode. (The inference drawn here on 2026-08-10 — that ~230–280 ms of each token therefore goes somewhere other than expert bytes — was wrong, and is corrected in the resolution below: it goes into the fetch path, which does not reach the device roof.)
- **16 GB M1 Air (7.802 tok/s, issue #76):** identical token counts, so identical routing and — by the same-policy argument — the same hit rate and the same 261.9 MB/token. That needs **2.04 GB/s, which is inside the SSD roof.** No DRAM-speed tier is required to explain it.

So the page cache is not *forced* by bandwidth arithmetic on either host, and the 2.3× gap is now **unexplained**. Do not fill the gap with a new story until it is measured. What is still true and unaffected: `PreadExpertStreamer` sets no `F_NOCACHE`, so the buffer cache is live; this host holds ~1.44 GB of file cache against a 12.01 GiB routed-expert corpus, and the 2026-08-10 probe knee at 256 MiB–1 GiB is real. Those facts permit a page-cache contribution on 16 GB hosts; they no longer demonstrate one.

### RESOLVED in part (2026-08-10, `ce287b6`): decode is expert-read-bound, but not at the device roof

The phase split above was taken and it answers the question the retraction left open. **`io` is 59–63% of a decode forward** — the largest consumer by a wide margin, roughly twice the next one. The binding constraint holds on this host: bytes/token is where the time goes, and the "operating assumption" caveat in [The binding constraint](#the-binding-constraint) is discharged for the Mac host.

What is *new* and was not visible before: `io` moves those bytes at **1.30–1.34 GB/s, 41–50% of the device roof for the same 3,358,720 B block size.** So both of these are true at once, and neither alone describes the host —

- the earlier arithmetic (261.9 MB ÷ 315.6 ms = 0.83 GB/s, 29% of roof) was correct, and
- decode is nevertheless read-bound, because the fetch path achieves only about half the device's bandwidth.

The bullet above concluded from the first that 230–280 ms/token had to be going elsewhere. It is not: only ~120 ms is. That inference is withdrawn.

**Still unexplained, and not to be filled in with a story:** why the fetch path runs at half the roof. Candidates not yet distinguished — per-read latency the probe did not model (30 open layer files vs. the probe's one; ~2.6 reads per layer issued and awaited per layer rather than streamed), planning cost counted inside the `io` window, or queue depth. The probe measured 1,065–1,245 µs per read against 2,511–2,592 µs here for the same block size, and that ~2.2× is the whole gap.

**The 2.3× gap vs. the 16 GB M1 Air is still unexplained, but is now localized:** that host completes a whole forward in ~128 ms while ours spends ~202 ms in `io` alone. Its expert bytes therefore cannot be arriving the way ours do. A page-cache contribution is a live candidate again — but only a candidate; nothing here measures it, and the earlier version of this argument was retracted for exactly this kind of inference.

Second finding, unrelated to bytes: **`cb1-wait` is 95–133 ms per forward (29–35%) and grows with prompt length** — GPU attention and router over a lengthening KV cache. It is the second-largest consumer, it is compute rather than I/O, and no lever in the port plan currently addresses it.

**Consequence for the port, revised:** the claim that 16 GB+ community numbers are partly a page-cache measurement is now unproven, so it cannot be used to dismiss them. The 8 GB row remains the right predictor for iOS on the separate ground that iOS has no comparable page-cache tier and a tighter memory ceiling — but "our host is at its SSD roof, so iOS will be too" is no longer an argument anyone should repeat. Caveats that still stand: the 16 GB host's SSD roof is assumed equal to ours, not measured; community rows are single runs.

Per-run history lives in `MEASUREMENTS.md`; this table holds only the current accepted values. When a run in `MEASUREMENTS.md` supersedes a value here, update this table in the same change.

## Commands

```bash
swift build -c release                       # builds all six products, incl. the Mac app + decode service
Scripts/test.sh                              # the only supported test entry point (swift test --no-parallel)
Scripts/test.sh --filter RouterTopKTests     # single suite; args pass through to swift test
ruby Scripts/check_markdown_links.rb         # CI also gates on this
```

CI (`.github/workflows/ci.yml`, `macos-26`) runs exactly those three. None of them download or load the model.

Model install and run (model lives at `scratch/gemma4.gturbo`, gitignored, ~14.3 GB):

```bash
swift run -c release TurboFieldfareRepack --output scratch/gemma4.gturbo [--overwrite|--resume|--discard-partial]
swift run -c release TurboFieldfareRepack --verify-install --input-gturbo scratch/gemma4.gturbo
.build/release/TurboFieldfareMac
swift run -c release TurboFieldfareCLI --model scratch/gemma4.gturbo --messages-file messages.json
.build/release/TurboFieldfareServer --model scratch/gemma4.gturbo    # loopback only, 127.0.0.1:8080/v1
```

CLI `--prompt` is raw completion (no chat framing); `--messages-file` applies the pinned Gemma 4 IT chat format. Timing footer goes to stderr, generated text to stdout.

### Before any run that touches the real model

Preflight, and stop and tell the user if a check fails — never kill processes, delete, or reinstall the model:

```bash
pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'
memory_pressure -Q
```

Exactly one model-owning process may run at a time (app, decode service, CLI, server, or a model-using test) — this is a memory invariant on the 8 GB validation host, not a convention. Performance numbers must follow `docs/COMMUNITY_BENCHMARKS.md` verbatim, with experimental controls and profiling off.

`.claude/settings.json` denies reads of `**/*.gturbo`.

## Architecture

### Module graph

`TurboFieldfareFormat` (Foundation-only, no Metal) owns the `.gturbo` v1 wire contract — manifest, packed-experts layout, resident index — and is shared by the installer, the verifier, and the runtime so all three validate identically. `TurboFieldfare` is the runtime library (Metal kernels + inference); everything else depends on it.

Every executable is split into a testable `…Core` library target and a thin `…/Command` executable target (`TurboFieldfareRepackCore`, `TurboFieldfareCLICore`, `TurboFieldfareServerCore`, `TurboFieldfareAppCore`). Put logic in the Core target; the executable target should only parse arguments and call in. `TurboFieldfareValidationSupport` holds CPU reference implementations, PRNG, and tolerances used by kernel tests.

The Mac app is two processes: `TurboFieldfareMac` (SwiftUI/AppKit UI, `AppCore` + `MacPresentation`) talks over a Unix socket to a one-shot `TurboFieldfareDecodeService` that solely owns the model and Metal. Codable messages live in `TurboFieldfareDecodeProtocol`. The UI process never loads a second in-process model, which is why the HUD reports *decode-service* memory rather than its own.

### The bounded-memory rule

No install, load, test, or benchmark path may put a whole model, shard, expert, or source tensor into Swift heap memory. Concretely: the installer streams pinned Hugging Face byte ranges straight into `.gturbo` layout through tile-sized scratch (validated max 512 KiB payload and scratch), `model_weights.bin` is mmapped read-only and wrapped in `MTLBuffer`s without copying, and routed experts land in pre-allocated 2 MiB-aligned slot buffers via `makeBuffer(bytesNoCopy:)` + `pread`. Any change that buffers a full tensor breaks the project's core premise.

### Decode: the cb1 / io / cb2 handoff

Per layer, `cb1` (Metal) runs norm → QKV → RoPE + KV write → attention → output projection → router, stopping when the top-8 expert IDs are readable by the CPU. `io` plans against the layer's 16-slot LFU cache and `pread`s only the misses, while Metal runs the resident shared-expert branch concurrently. `cb2` finishes the routed branch, reduces by router weights, combines with the shared branch, and applies the layer tail.

The phases run in sequence within a layer; `DecodePhaseTimings` carries the six figures the CLI's `[phase-time …]` footer prints, and they account for ~98% of a forward's wall time. Two scope traps: `cb1`/`cb2` are CPU encode cost with GPU execution excluded (that execution is the separate `cb1-wait` and `routed-drain` figures), and `io` is a window during which the shared-expert branch is executing on the GPU, so it is not idle time.

Prefill is layer-major in chunks of ≤128 tokens, streams experts in tiles of ≤8 (two tiles must fit the 16-slot cache), and uses staged-affine MPP `matmul2d` for projections with enough rows; single-token decode stays on custom affine INT4/INT8 GEMV kernels.

### Metal

`.metal` sources under `Sources/TurboFieldfare/Metal/` are copied as bundle resources and compiled into one `MTLLibrary` at startup by `MetalContext` (single owner of device, queue, library, and a lock-guarded pipeline cache) — edit a shader, rebuild the Swift target, no Xcode metallib step. Swift-side kernel wrappers live in `Sources/TurboFieldfare/Kernels/`, mirroring the `Metal/` subdirectories.

Load-width gotcha: packed-weight load width must match the alignment the path actually guarantees. Resident INT4 GEMVs and routed gate/up projections build 4-byte values from two `ushort` loads because offsets can be only 2-byte aligned; routed down-projection offsets are 4-byte aligned and may use `uint` loads.

### Invariants worth knowing before editing

- A queued GPU consumer owns its expert slot and scratch bank until completion; CPU reuse must not race an earlier command buffer.
- K and V stay distinct after normalization/RoPE even where the raw projection is shared (full-attention layers derive both from raw K; K gets scaled per-head norm + RoPE, V gets no-scale norm and no RoPE).
- The repacker relayouts quantized values byte-for-byte; it never dequantizes and requantizes.
- Kernels may reorder float ops but must stay deterministic within a path and inside `Tolerances` — exact identity across paths is not required.
- Gemma 4 specifics the runtime must match: NeoX RoPE, attention scale `1.0`, no router-logit softcap, parallel shared + routed FFN, learned layer scalar, final logit softcap `30.0`, tied 4-bit embedding/head.

`docs/SYSTEM_DESIGN.md` has the full picture and a code map to the entry-point files; `docs/RUNTIME_CONTROLS.md` is the authoritative list of exposed controls and defaults.

## Conventions

- Tests use swift-testing (`@Suite` / `@Test`), never XCTest. Shared Metal state makes in-process parallelism unreliable, so always go through `Scripts/test.sh`; add `.serialized` to suites that touch process-wide state. Kernel tests compare against the CPU reference in `TurboFieldfareValidationSupport` with a seeded `SplitMix64` and named tolerances.
- `docs/RUNTIME_CONTROLS.md` documents the controls the Mac runtime exposes; production defaults are 4K context, 16 expert-cache slots, LFU, prefill on with 128-token chunks, RDADVISE off, temperature `0.2` / Top-K `64` / Top-P `0.95`. The port will add controls (cache sizing against the memory ceiling, jetsam policy) — add them there rather than treating the current list as closed.
- Currently macOS 26 / Swift 6.2 / Metal 4, arm64 only; Swift 6 language mode. iOS platforms get added by the port; keep the macOS build working, since it is the reference the port is validated against.
- Behavior changes need a focused test. Keep PRs narrow — good practice here, and it keeps individual changes cherry-pickable back to upstream. Report commit, hardware/RAM, macOS, Swift version, exact command, exit code, and the full timing footer or error for any real-model run.
- The server has no auth or TLS: keep it on `127.0.0.1`, never proxy or tunnel it, and let the client authorize every model-produced tool call.

## Working agreements

These are rules for how work gets done here, not style preferences.

### Every optimization states a predicted bytes/token delta first

Before implementing any change proposed as an optimization, write down:

1. **Predicted bytes/token delta** — a signed number or a tight range (e.g. `−180 KB/tok`, `0 ± 5%`), not "should reduce reads".
2. **The mechanism** — which reads disappear, get coalesced, get cached, or get deferred.
3. **What would falsify it** — the measurement that would show the prediction was wrong.

No prediction, no implementation. A change predicted at zero bytes/token delta is allowed, but must be labeled as such up front and justified on other grounds (correctness, memory ceiling, portability to iOS). After implementation, record the measured delta against the prediction in `MEASUREMENTS.md` — including when the prediction missed. Wrong predictions kept honestly are the point; silently dropping the ones that missed destroys the record's value.

### Use a subagent for codebase search

Do not glob, `find`, or ripgrep the tree into the main context to answer "where is X". Dispatch the `codebase-search` subagent (`.claude/agents/codebase-search.md`) and work from the file paths and line ranges it returns, reading only the specific regions you actually need. The main context is reserved for the code under active discussion and the measured facts above — bulk search output crowds both out.

Direct search is fine when you already know the exact file and are confirming one symbol in it.

### Use plan mode before editing any `.metal` file

Shader edits land in a single `MTLLibrary` compiled at startup, are validated only against the CPU reference in `TurboFieldfareValidationSupport`, and carry the load-width and alignment hazards described above. Enter plan mode, state the change and its bytes/token delta, and get agreement before touching anything under `Sources/TurboFieldfare/Metal/`. Swift-side kernel wrappers in `Sources/TurboFieldfare/Kernels/` do not require plan mode, but a wrapper change that alters dispatch shape or buffer layout should be treated as if it did.

### Persistent memory across sessions

Sessions do not share context; these files do. Read them before proposing work, and write to them when a session produces a durable result:

- `MEASUREMENTS.md` — append-only run log. Every real-model run gets a row. Never edit or delete an existing row.
- `docs/experiments/summaries/` — what has already been tried *in this project*, what it measured, and why it was kept or abandoned. This is the source of truth for in-project prior art; read the file for the phase you are touching (map below) before proposing an optimization. A rejected idea needs a new argument, not a repeat. Do not re-summarize these into a new document.
- `docs/EXTERNAL_PRIOR_ART.md` — techniques from outside the project (papers, other runtimes, vendor docs) with an assessment of whether they apply under the bytes/token constraint.

If a session's conclusion is not written into one of these, it did not happen.

## Document map

Nothing under `docs/` loads unless something routes you there, so the cost of a
document is paid only when it is read — but a document read out of context can
still supply a wrong number or a stale objective. This table says what each one
is true of. Prefer reading none of them over reading the wrong one.

| Document | Status | Read it for |
| --- | --- | --- |
| `docs/IOS_PORT.md` | **current, this project** | The active plan: tracks, sequencing, repo layout. Start here. |
| `MEASUREMENTS.md` | **current, this project** | Append-only run log. Every real-model run gets a row. |
| `docs/EXTERNAL_PRIOR_ART.md` | current, this project | Outside techniques assessed against bytes/token. Stub today. |
| `docs/SYSTEM_DESIGN.md` | current, describes the Mac runtime | The full architecture and the code map to entry-point files. The most useful doc for the port. |
| `docs/RUNTIME_CONTROLS.md` | current, Mac controls only | Exposed controls and defaults. The port extends this list. |
| `docs/COMMUNITY_BENCHMARKS.md` | current, protocol | The benchmark protocol. Follow it verbatim for any performance number. |
| `docs/experiments/summaries/` | current, in-project prior art | What was already tried. See the table below — read only the relevant one. |
| `docs/experiments/EXPERIMENT_INVENTORY.md` | current, index | Index over the summaries. |
| `docs/IMPLEMENTATION_REFERENCES.md` | current, external links | Vendor and spec links. |
| `docs/BENCHMARKS.md` | **superseded — other hardware** | Numbers from an 8 GB M2 Air and a 24 GB M5 Pro, neither of which is this host. Never quote it; use the measured-facts table above. |
| `docs/OPTIMIZATION_JOURNEY.md` | upstream narrative | Prose retelling of what the summaries cover densely. Background reading, not a working reference. |
| `docs/OPENAI_SERVER.md` | upstream, Mac-only | The loopback server. No bearing on the port. |
| `README.md`, `CONTRIBUTING.md` | upstream | Describe the upstream Mac project and its contribution process, not this repo's scope. |

### Which prior-art summary to read

Read only the ones that cover the work in front of you — these are dense, and reading all nine crowds out the code under discussion.

| Summary | Read it before touching |
| --- | --- |
| `01-model-install-and-expert-io.md` | The repacker/installer, `.gturbo` layout on disk, `pread` streaming, slot buffers, anything that changes how expert bytes get off the SSD. |
| `02-decode-moe-int4-and-router.md` | Routed/shared FFN kernels, INT4/INT8 GEMV paths, router top-K, the cb1/io/cb2 decode handoff. |
| `03-expert-cache-prediction-and-layout.md` | Expert-cache policy (LFU, slot count), prefetch or routing prediction, expert ordering/co-location on disk. The primary file for hit-rate and routing-locality work. |
| `04-rdadvise.md` | Anything touching the RDADVISE advisory path or OS-level read hinting. |
| `05-attention-and-kv-cache.md` | Attention kernels, KV cache layout and dtype, RoPE, context-length changes. |
| `06-prefill.md` | Prefill chunking, expert tiling, `matmul2d`/MPP projection paths, prefill-vs-decode byte profiles. |
| `07-fusions-head-and-orchestration.md` | Kernel fusion, the tied embedding/head path, command-buffer scheduling and phase overlap. |
| `08-sampling-tokenization-and-output.md` | Sampling (temperature/Top-K/Top-P), logit softcap, tokenizer, chat formatting, streamed output. |
| `09-validation-and-measurement-lessons.md` | Benchmarking or instrumentation work — read this before taking any new measurement, including the bytes/token and cache-hit counters the table above still needs. |
