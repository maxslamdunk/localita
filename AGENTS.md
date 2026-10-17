# AGENTS.md

Guidance for coding agents, and for people, working in this repository. Some
directories have their own `AGENTS.md` with rules for that code. Claude Code
reads `CLAUDE.md` instead: put the line `@AGENTS.md` in a `CLAUDE.md` of your
own (it is gitignored), at the root and beside each nested `AGENTS.md`.

TurboFieldfare is a Swift + Metal inference runtime for Gemma 4 26B-A4B (26B total, ~3.9B active). It keeps ~1.35 GB of shared weights plus an FP16 KV cache resident and streams the 8 routed experts each token needs from storage.

This repo is the **iOS port**, a separate repository derived from
[`drumih/turbo-fieldfare`](https://github.com/drumih/turbo-fieldfare) (Apache-2.0),
with upstream history kept and `upstream` wired fetch-only. `docs/IOS_PORT.md`
is the plan and its history. Much of `docs/` and all of `docs/UPSTREAM_README.md` describe the
upstream Mac project; the [Document map](#document-map) says what each one is
true of.

## The goal

**Gemma 4 26B-A4B that is fast and usable on the iPhone 17.** Concretely:

- **Decode tok/s and prefill time on the phone**, measured with the
  `real-generation-v1` prompts. Report decode and prefill separately; they have
  different byte profiles.
- **Inside the memory budget**, with the rest of the phone still usable
  (see the memory row below).
- **Output quality unchanged** unless a trade is chosen on purpose and measured
  (see [What is open](#what-is-open)).
- **The app itself.** Chat UI, settings, model install, and reliability work is
  in scope. It does not need a performance prediction.

The Mac is the development and reference host, not the target. It must keep
building and passing `Scripts/test.sh`, because CI and upstream merges depend
on it. A change that helps the phone and does nothing for the Mac is fine.
Platform-split defaults are fine too: slots and the prefill chunk cap already
differ.

## Where the time goes on the phone

Measured with 24 slots, grouped full attention and the early read off. **The
early read has been on by default since 2026-10-03**, with the fitted guess for
gemma4: about +17–20% tok/s for +11–18% bytes/token against this table
(`results/benchmark-results-2026-10-03-ios-fitted-guess/`). **Expert reads have
skipped the OS file cache (`F_NOCACHE`) on iOS since the same day**, worth
about +4 to +8% more at identical bytes
(`results/benchmark-results-2026-10-03-ios-expert-read-nocache/`). Per decode forward,
iPhone 17, 2026-10-01/02, short / medium / long:

| | short | medium | long |
| --- | --- | --- | --- |
| tok/s | 5.750 | 4.811 | 4.32–4.39 |
| wall, ms | 174 | 208 | 228–232 |
| `io` (reading missed experts) | 104 (60%) | 127 (61%) | 137–140 (60%) |
| `cb1-wait` (GPU work the CPU waited on) | 53 (30%) | 63 (30%) | 72 (31%) |
| `head` | 9.7 | 10.4 | 10.6 |
| bytes/token, MiB | 160.71 | 187.08 | 204.59 |
| expert-cache hit rate | 79.1% | 75.7% | 73.4% |

From the GPU timestamps (`results/benchmark-results-2026-10-02-ios-gpu-time/`):

- **The GPU is idle 62–63% of each token**: 116 / 134 / 140 ms. About 87–106 ms
  of that falls inside `io`.
- **14–17 ms per token is CPU/GPU handoff** that no GPU buffer covers, about
  0.5 ms per layer and 7–8% of wall. A faster CPU did not shrink it, so it is
  not CPU speed.
- **Attention + router is 42–51% of `cb1-wait`.** Most of the rest is the
  previous layer's routed-expert buffer, which the runner never waits on
  directly.
- **Storage works one read at a time.** Storage time per read is 2.1–2.2 ms,
  the device's serial rate, and concurrent reads only stretch each other. The
  OS file cache serves under 1% of misses, because the app's footprint leaves it
  no room.

So reads are the largest phase, but no longer by enough to be the only one that
matters. The levers, none ranked above the others by rule:

- **Read fewer bytes:** hit rate, slot count, routing locality, bytes per
  routed expert, prefill chunking.
- **Hide reads:** issue them while storage would otherwise sit idle. The early
  expert read does this. It **raises** bytes/token by 11–18% and still gains
  about 17–20% tok/s, so bytes/token is a cost to account for, not the goal.
- **Make GPU work faster:** grouped full attention took 12–19 ms off the long
  case at 0 bytes/token. Attention grows with context, and the iOS cap is 8K.
- **Overlap or shrink the handoff and the GPU's idle time.**
- **Spend memory for speed**, inside the budget. Slots are the example.

## What is open

Everything that is not a measured fact or a safety invariant below is a design
choice, and design choices can change. That includes upstream's: an exclusion
like "ANE/Core ML was not used" is an opinion inherited with the code, not a
finding. Argue from measurements.

Changes that trade output quality, such as different expert quantization,
fewer active experts or skipping layers, are allowed as experiments. Measure the
quality cost alongside the speed. Keep them opt-in until the user decides to
change a default. Record the decision either way, including when the memory
ceiling forces it (`docs/IOS_PORT.md`, "The rule that keeps the split honest").
A `.gturbo` format change makes upstream merges harder. Weigh that cost, but it
is not a veto.

## Working agreements

### Predict before you measure

For any change proposed to make the runtime faster or smaller, write a
prediction before the run that scores it. Put it in
`results/benchmark-results-<date>-<topic>/predictions.md` and commit it first:

1. **What moves, by how much:** signed numbers or tight ranges, for the metrics
   the change targets (tok/s, a `[phase-time …]` or `[gpu-time …]` figure,
   prefill bytes or time, peak footprint).
2. **The controls,** which should not move: usually bytes/token, hit rate, and
   generated text (byte-identical, by SHA-256). These counters are exact, so
   they catch a change that did something other than intended.
3. **The mechanism:** why it should move.
4. **What would falsify it.**

Then score it in `results.md` beside it and append the runs to `MEASUREMENTS.md`,
**misses included**. A wrong prediction kept honestly is what makes the record
worth anything. Several have already corrected the project's model of itself:
the grouped-attention miss, for one, showed the attention split had been
mis-fitted.

What this does not require:

- **A prediction before writing code.** Prototypes, probes and instrumentation
  can come first. The prediction has to come before the measurement that
  decides the change. Before a large investment, give a rough size estimate
  ("≤ +25% tok/s, as arithmetic") so effort goes where the headroom is.
- **A bytes/token justification.** Any phase or resource is a legitimate
  target.
- **A prediction for non-performance work.** UI, features, fixes and refactors
  need tests and good sense. "Cleaner" is a fine reason for a refactor; it just
  isn't a performance claim.

### Measuring on the phone

- **The protocol:** the frozen `real-generation-v1` prompts (`short-explanation`,
  `medium-review`, `long-synthesis`) through the iOS harness, at
  `--slots 24 --max-new 1024 --max-context 4096`, chunk `auto`, Release. The
  harness logs each prompt's SHA-256; check it.
- **A/B one variable.** Prefer one binary with a runtime switch. Otherwise
  install two builds over each other. Run in A B B A order per case, with a
  5-minute cooldown between runs.
- **Hold conditions:** other apps closed, network on, battery level and
  charging state recorded. Record thermal state at every sample, and the
  compressor churn.
- **Noise you will see:**
  - About 8% run-to-run on identical work.
  - `serious` thermal costs ~12%, mostly in `io`.
  - **Whole-run GPU speed can differ by up to ~40% between consecutive runs**
    at the same reported thermal state. Read `head`'s `[gpu-time …]` figure
    beside any `cb1-wait` comparison.
  - A run with heavy compressor churn has a noisy `io`.
- **Prefill:** quote bytes, which are exact, rather than seconds, which follow
  thermal.
- **Profiling or instrumented runs** are labelled as such and not quoted as
  tok/s.
- **Mac numbers** follow `docs/COMMUNITY_BENCHMARKS.md`, with the control under
  test as the only change from defaults.
- Read `docs/experiments/summaries/09-validation-and-measurement-lessons.md`
  before designing a new kind of measurement.

### Numbers

Quote numbers from the tables in this file, `MEASUREMENTS.md`, or a results
file, and say which. Don't quote from memory, and don't quote from
`docs/BENCHMARKS.md`, which is other hardware. Re-measuring is welcome whenever the code, the device or the
model artifact has changed since a number was taken; label it as a new
measurement and record it. When a new run supersedes a value here, update the
table in the same change.

### Records

Sessions don't share context; these files do. If a conclusion isn't written into
one of them, it is lost.

- `MEASUREMENTS.md`: the run log, **append-only.** Every real-model run gets a
  row, and no existing row is edited.
- `results/benchmark-results-<date>-<topic>/` and `results/validation-results-…/`:
  predictions, results, logs, and the script that ran them.
- `docs/experiments/summaries/`: what was tried in this project and why it was
  kept or dropped. Read the relevant one before proposing an optimization. A
  rejected idea needs a new argument, or a changed circumstance such as the
  phone, not a repeat. (The phone has overturned several Mac rejections, for
  example 32 slots in CACHE-03.)
- `docs/EXTERNAL_PRIOR_ART.md`: outside techniques and whether they apply.

### Merging upstream

1. `git fetch upstream` and review what changed before merging.
2. If it touches runtime performance, write predictions first, as above.
3. Merge, then run the full `Scripts/test.sh` and build the iOS app.
4. If kernels changed, run the device kernel suites.
5. If the change is performance-relevant, A/B it on the phone.
6. Set `AboutPanelPresentation.fallbackShortVersion` to at least upstream's latest release.
   CI's `check_app_version.rb` warns while it is behind; the warning means a merge is due.
7. Keep our `AGENTS.md`, and carry over any rule from upstream's that applies
   here.

### Shaders

`.metal` changes need, before they are claimed:

- a kernel test against the CPU reference;
- the device kernel suites passing on the phone, because the A19 is Apple10 and
  the Mac is Apple7;
- the load-width rule respected (`Sources/TurboFieldfare/Metal/AGENTS.md`).

When a new kernel replaces an old one on the same math, add a bitwise identity
test if it is feasible. Identical output then makes the phone A/B a clean
control, as it did for grouped attention. A large or multi-kernel change is
worth outlining to the user first.

### Searching the code

A targeted `rg` or `grep` with bounded output is fine. For open-ended searches
that would pull many files into context ("where is X handled", "what touches
Y"), find the locations first and read only those regions, not whole files.

## Safety invariants

These are real constraints, not conventions.

- **Mac, one model-owning process at a time** (app, decode service, CLI, server,
  or a model-using test). It is the 8 GB host's memory. Preflight before any
  real-model run:
  ```bash
  pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'
  memory_pressure -Q
  ```
  If a check fails, stop and tell the user. Never kill processes, and never
  delete or reinstall the model.
- **Phone: never delete the app.** The model lives in its data container.
  Install over it. Free-team signing expires weekly; re-sign and install over.
  With Airplane Mode on, free-team apps refuse to launch.
- **Bounded memory.** No install, load, test, or benchmark path may put a whole
  model, shard, expert, or source tensor into Swift heap memory.
  `model_weights.bin` is mmapped read-only and wrapped in `MTLBuffer`s without
  copying. Routed experts `pread` into pre-allocated 2 MiB-aligned slot buffers
  via `makeBuffer(bytesNoCopy:)`.
- **Nothing may scatter the installed layer files.** Write order measurably sets
  their read rate (IO-12).
- **Never read the big `.gturbo` binaries** (`model_weights.bin`,
  `packed_experts/*.bin`). They are gigabytes. The manifests beside them are
  small and fine to read.
- The server has no auth or TLS. Keep it on `127.0.0.1`, never proxy or tunnel
  it, and let the client authorize every model-produced tool call.

## Commands

```bash
swift build -c release                       # all Mac products, incl. the app + decode service
Scripts/test.sh                              # full suite, serial; always go through this script
Scripts/test.sh --filter RouterTopKTests     # regex over target/suite names; args pass through to swift test
ruby Scripts/check_markdown_links.rb
ruby Scripts/check_swiftui_macros.rb --self-test
```

CI (`.github/workflows/ci.yml`) runs two jobs. One builds on the oldest
supported Xcode, 26.3 on `macos-26`. The other, on `xcode-27`, runs the SwiftUI
macro checks, release and debug builds, `Scripts/test.sh`, and the symlink,
Markdown-link and app-version checks; the app-version check only warns. CI never
loads the model. Pushes that touch only `server/`, `results/` or
`benchmark-submissions/` skip CI, unless they change Markdown. The iOS app is
not built in CI, so build it yourself after touching shared code.

### Which tests to run

The full suite takes about 6.5 minutes plus the build, and CI runs it on every
push. Locally, run what the change can break:

| Change | Run |
| --- | --- |
| Docs, Markdown, benchmark results | `ruby Scripts/check_markdown_links.rb` only |
| `iOS/` only | Build the iOS app; package tests don't cover it |
| App/UI (`Sources/TurboFieldfareApp/`) | `--filter 'TurboFieldfareAppCoreTests\|TurboFieldfareMacPresentationTests'` |
| Runtime, kernels, format, installer | The touched suites while iterating; the matching target before committing (`TurboFieldfareTestsCore`, `TurboFieldfareFormatTests`, `TurboFieldfareRepackTests`) |
| `.metal` | The matching kernel suites, plus the device kernel suites on the phone |
| Upstream merge, `Package.swift`, types shared across modules | Full `Scripts/test.sh` |

CI's full run is the gate before merging. If it goes red in a module you didn't
run, fix it right away. Don't download a checkpoint, copy the model, create a
worktree, or purge caches just to run tests.

Mac model (at `scratch/gemma4.gturbo`, gitignored, ~14.3 GB):

```bash
swift run -c release TurboFieldfareRepack --output scratch/gemma4.gturbo [--overwrite|--resume|--discard-partial]
swift run -c release TurboFieldfareRepack --verify-install --input-gturbo scratch/gemma4.gturbo
swift run -c release TurboFieldfareCLI --model scratch/gemma4.gturbo --messages-file messages.json
```

CLI `--prompt` is raw completion; `--messages-file` applies the Gemma 4 IT chat
format. The footers go to stderr: `[expert-io …]`, `[phase-time …]`,
`[gpu-time …]` and `[read-latency …]`. The iOS harness prints the same lines.

On the iPhone, with bundle `io.github.maxslamdunk.Localita`. Find the
device's devicectl id with `xcrun devicectl list devices` and its UDID with
`xcrun xctrace list devices`:

```bash
xcodebuild -project iOS/TurboFieldfareiOS.xcodeproj -scheme TurboFieldfareiOS \
  -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device <devicectl id> <path>/TurboFieldfareiOS.app
xcrun devicectl device process launch --device <devicectl id> --terminate-existing \
  io.github.maxslamdunk.Localita --autorun --case long-synthesis --label <label> \
  --slots 24 --max-new 1024 --max-context 4096 [--early-expert-read [--early-expert-guess <file>]]
xcodebuild test -project iOS/TurboFieldfareiOS.xcodeproj -scheme TurboFieldfareiOS \
  -destination 'id=<udid>'   # device kernel suites, Debug
```

The harness writes `Documents/decode-<label>-<stamp>.log`, plus the generated
text as `.txt`. Pull them with `devicectl device copy from`. For a scripted
A/B, start from `results/benchmark-results-2026-10-01-grouped-attention/run-ab.sh`. It
handles the devicectl quirks: padded process paths, empty listings while the
phone is busy, and process paths named after the local bundle folder.

## Architecture

### Module graph

`TurboFieldfareFormat` (Foundation-only, no Metal) owns the `.gturbo` v1 wire
contract (manifest, packed-experts layout, resident index). The installer, the
verifier and the runtime all share it, so all three validate identically.
`TurboFieldfare` is the runtime library (Metal kernels + inference). Everything
else depends on it.

Every executable is split into a testable `…Core` library and a thin
`…/Command` executable. Put logic in the Core target.
`TurboFieldfareValidationSupport` holds the CPU reference implementations, PRNG,
and tolerances used by kernel tests.

The app's non-UI layers are platform-neutral and shared with iOS:

- `TurboFieldfareAppCore`: chat state, persistence, install state, and the
  `AppInferenceClient` seam, whose default is the in-process
  `RealInferenceClient`.
- `TurboFieldfareAppPresentation`: streamed-markdown splitting, fence and math
  detection, transcript sync planning.

The iOS app (`iOS/`) is a view layer over `AppModel`. The Mac app is instead two
processes: the UI talks over a Unix socket (`TurboFieldfareMacInference`, which
is macOS-only) to `TurboFieldfareDecodeService`, which solely owns the model.
`TurboFieldfareMacPresentation` keeps the AppKit-bound half.

### Decode: the cb1 / io / cb2 handoff

Each layer runs three phases in sequence:

- **`cb1`** (Metal): norm → QKV → RoPE + KV write → attention → output
  projection → router. It stops when the top-8 expert IDs are CPU-readable.
- **`io`**: plans against the layer's LFU expert cache and `pread`s only the
  misses. The resident shared-expert branch runs on the GPU meanwhile.
- **`cb2`**: finishes the routed branch, reduces by router weights, combines
  with the shared branch, and applies the layer tail.

`DecodePhaseTimings` feeds `[phase-time …]` and covers ~98% of a forward. Scope
traps:

- `cb1`/`cb2` are CPU encode cost. GPU execution is counted in `cb1-wait` and
  `routed-drain`.
- **`cb1-wait` is not GPU attention.** It also absorbs the previous layer's
  routed buffer and the handoff latency.
- `io` is not GPU-idle time.

Making `io` wait on `cb1` completion, or starting `cb2` before `io` has issued,
turns a hidden read into a stall.

Prefill is layer-major in chunks: the cap is 1024 tokens on iOS and 256 on
macOS. It streams experts in tiles of ≤8 and uses MPP `matmul2d` for large
projections. Decode uses custom affine INT4/INT8 GEMV kernels.

### Metal

`.metal` sources under `Sources/TurboFieldfare/Metal/` are bundle resources.
`MetalContext` compiles them into one `MTLLibrary` at startup; it is the single
owner of device, queue, library, and the pipeline cache. There is no metallib
step: edit and rebuild. Swift wrappers live in `Sources/TurboFieldfare/Kernels/`,
mirroring the shader directories, and duplicate each kernel's argument order by
hand.

### Invariants worth knowing before editing

- A queued GPU consumer owns its expert slot and scratch bank until it
  completes. CPU reuse must not race an earlier command buffer.
- K and V stay distinct after normalization/RoPE even where the raw projection
  is shared.
- The repacker relayouts quantized values byte for byte. It never dequantizes
  and requantizes.
- Kernels may reorder float ops, but must stay deterministic within a path and
  inside `Tolerances`.
- Gemma 4 specifics: NeoX RoPE, attention scale `1.0`, no router-logit softcap,
  parallel shared + routed FFN, learned layer scalar, final logit softcap
  `30.0`, tied 4-bit embedding/head.

`docs/SYSTEM_DESIGN.md` has the full picture and a code map.
`docs/RUNTIME_CONTROLS.md` is the authoritative list of controls and defaults.

## Conventions

- Tests use swift-testing (`@Suite` / `@Test`), never XCTest. Always go through
  `Scripts/test.sh`, because shared Metal state makes in-process parallelism
  unreliable. Mark suites that touch process-wide state `.serialized`. Kernel
  tests compare against the CPU reference with a seeded `SplitMix64` and a
  named tolerance.
- **Kernel tests must be visible to the device test bundle.** It compiles
  `Tests/TurboFieldfare/Core/Kernels/**` and `…/Validation/Reference/**`, and
  some runtime configuration tests.
- **SwiftUI state:** use `@StoredState` (from `TurboFieldfareMacPresentation`,
  an alias of `SwiftUI.State`) for view-owned state, and `PreviewProvider` for
  previews. Don't add direct `@State` attributes or `#Preview` macros. Some
  toolchains lack those macro plugins, and CI checks for them. The wrapper
  evaluates inline initializers eagerly, so keep reference construction
  explicit. Run `ruby Scripts/check_swiftui_macros.rb --self-test` when
  changing these surfaces.
- Defaults that differ by platform:
  - expert-cache slots: 16 on macOS, 24 on iOS;
  - prefill chunk cap: 256 on macOS, 1024 on iOS.

  The full list is in `docs/RUNTIME_CONTROLS.md`. Adding a control means
  updating that doc in the same change.
- Swift 6 language mode, arm64 only, macOS 26 and iOS 26.
- Behavior changes need a focused test. Keep commits narrow.
- For any real-model run, report: commit, device and RAM, OS, the exact command
  or harness arguments, thermal state, and the full footer lines or error.

## Measured facts

Current accepted values. Per-run history is in `MEASUREMENTS.md`. The long
August narrative behind the Mac rows is archived in
`docs/experiments/CLAUDE_MD_ARCHIVE_2026-10-03.md`. Byte figures from the footer
are **MiB labelled MB**.

### iPhone 17 (A19, Apple10 GPU, 8 GB, iOS 26.6)

| Fact | Value | Source |
| --- | --- | --- |
| Decode at defaults | In the table under [Where the time goes](#where-the-time-goes-on-the-phone). Rows taken before 2026-10-01 used the old attention kernel; account for that in any `cb1-wait` comparison. | `results/benchmark-results-2026-10-01-grouped-attention/`, `…-10-02-ios-gpu-time/` |
| Memory ceiling | Advertised 6.43 GB with the `increased-memory-limit` entitlement, but the app is killed from **5.60 GB** (5.60–5.87 across runs, tracking system-wide free memory). Without the entitlement: 3.53 GB, exact. Under a real 16K-context load it was killed at **4.44 GB** for `proc-thrashing`. **Budget against ~4.3 GB.** From ~3.9 GB, iOS kills other processes to keep the app alive, and the phone lags. The app rests at ~3.3 GB at 24 slots and ~4.1 GB at 32. Mmapped read-only weights are nearly free: ~16.6 MB of footprint for 1.26 GiB. | 2026-09-16, 2026-09-24 rows in `MEASUREMENTS.md`; `results/benchmark-results-2026-09-24-ios-context/` |
| Storage read | **1.650 GB/s** random at the 3,358,720 B slot size over a 12.01 GiB fresh corpus, serial. OS file cache knee at 1–4 GiB, but at runtime the app's footprint leaves it serving under 1% of misses. ⚠️ Decode was 8–13% slower on 2026-09-22 than on 09-16, at identical bytes. Artifact aging and the 0.8 merge are both candidates, unseparated (n=1). | 2026-09-16 probe; 2026-09-22 row |
| Expert-cache slots | Per layer, 3,358,720 B each, so +8 slots is about +0.8 GB. At 16 / 24 / 32, tok/s was 4.40 / 6.03 / 7.01 (short), 3.57 / 4.33 / 4.79 (long), and hit rate 67.7 / ~79 / 86.5% (short). Default is 24 since 2026-09-24, because 32 left no room for the system photo picker. That was before grouped attention and the 1024 prefill cap. | `results/benchmark-results-2026-09-16-ios-slots/`, `…-09-24-ios-vision-memory/` |
| Prefill chunk cap 1024 | Long-case prefill bytes −70.6% against 256, medium −42.1%; medium now runs in one chunk. Costs +152.4 MB of KV ring on every iOS run, because the ring is sized from the cap. Per-chunk volume grows with chunk size, so doubling the chunk does not halve the bytes. | `results/benchmark-results-2026-09-22-ios-prefill-chunk/` |
| Grouped full attention (upstream #182) | `cb1-wait` −0.5 / −5.3 / −11.8 to −19.1 ms; long +6.7% tok/s. Bit-identical output and 0 bytes/token. Default since `5820bbd`. The gain near the 8K cap is unmeasured. | `results/benchmark-results-2026-10-01-grouped-attention/` |
| Early expert read (on by default since 2026-10-03, `e4eb3a4`) | Reads one predicted expert of layer L+1 during storage-idle time. Storage idle per layer is 1.9–2.5 ms against 2.1–2.2 ms per read, so one fits and two do not: two reads measured **−25.9 / −14.6 / −20.7% tok/s** against one (`…-10-08-ios-early-read-x2/`). With the fitted guess file (11.1 MB, fitted on gemma4; supergemma4 has byte-identical routers and shares it, measured on the phone in `…-10-04-ios-supergemma4-guess/`) it gives about **+17–20% tok/s at +11–18% bytes/token**, with identical output and precision 0.68–0.75. Outside the fit's training set, including Russian, Chinese and Spanish, the fitted guess beat the router on all six prompts tried (+0.11 to +0.15 precision, Mac, `…-10-05-mac-early-read-out-of-domain/`). | `results/benchmark-results-2026-10-02-ios-next-layer-prefetch/`, `…-10-03-ios-fitted-guess/`, CACHE-10 |
| Expert-cache count aging (on) | LFU counts decay 0.97 per plan and reset when the KV resets. Today's benchmark is a fresh process per prompt and cannot see it. Over a `--session` of 11 prompts on one loaded model, as the app runs chats, it gave **+23.1% tok/s** (4.73 → 5.83), hit rate 67.7% → 75.4%, bytes/token −18.5%, with identical output. The first prompt gains ~1 point. Prefill bytes +6.2%, because the reset precedes prefill. | `results/benchmark-results-2026-10-03-ios-expert-cache-aging/`, CACHE-11 |
| Thermal | `serious` costs ~12% tok/s, mostly through `io`. At `fair` the GPU may slow ~9% (n=1). Separately, whole-run GPU speed varies up to ~40% between consecutive runs at the same thermal state. | `results/benchmark-results-2026-09-16-ios-slots/`, `…-10-03-ios-fitted-guess/` |
| Kernel numerics | The device kernel suites pass: 179 tests in 51 suites as of 2026-10-01. Worst-case relative error is identical to the M1 at every shared site. This is conformance in isolation, not a composition test. Device-vs-Mac text differences under sampling are not evidence of a defect. | `results/validation-results-2026-09-16-ios-kernels/`, `…-09-24-ios-vision/` |

### Mac validation host (M1 MacBook Air, 8 GB, 256 GB SSD, macOS 26.6.1, Swift 6.3.3)

| Fact | Value | Source |
| --- | --- | --- |
| Decode at defaults (16 slots) | **3.729 / 3.255 / 2.897 tok/s**; bytes/token 260.2 / 281.9 / 309.3 MB; hit rate 67.7 / 65.0 / 61.6%. `io` 155 / 177 / 196 ms (57–58%), `cb1-wait` 90 / 105 / 125 ms. Measured at `4056bfa`, before grouped attention; the Mac arm of that A/B was not run. | 2026-09-15 rows |
| `cb1-wait` composition | Attention + router is 47–48% of it, the previous layer's routed buffer 30–36 ms, and CPU/GPU handoff 16–17 ms per forward (short case). | `results/benchmark-results-2026-10-01-phase-instrumentation/` |
| Storage | Production fetch 1.67–1.74 GB/s on the 2026-08-19 sequentially rewritten artifact at 26.8 d. A fresh sequential control reads 2.30 GB/s at slot granularity. Install-time write order sets read rate (scattered: 1.30–1.34). Recency effects are real but unquantified (IO-13). | IO-12, IO-13 |
| Page cache and slots | Page cache knee 256 MiB–1 GiB; about 1.44 GB of file cache at idle. 32 slots collapses decode to 1.578 tok/s on this host (CACHE-03), which is why the Mac default stays 16. | 2026-08-10 rows, CACHE-03 |

The zero-hit ceiling is 806.1 MB/token (30 layers × top-8 × 3,358,720 B).
Measured demand is that ceiling × (1 − hit rate). Never quote the ceiling as
demand.

## Document map

| Document | Status | Read it for |
| --- | --- | --- |
| `docs/IOS_PORT.md` | current, this project | The port plan, its tracks and history, and the repo layout. |
| `MEASUREMENTS.md` | current, append-only | Every real-model run. |
| `results/` (benchmark, research and validation folders) | current, this project | Predictions, results and logs per experiment. |
| `docs/experiments/summaries/` | current, prior art | What was tried; see the table below. |
| `docs/RUNTIME_CONTROLS.md` | current | Controls and defaults, both platforms. |
| `docs/SYSTEM_DESIGN.md` | current, Mac runtime | Architecture and the code map. |
| `docs/COMMUNITY_BENCHMARKS.md` | current, protocol | The `real-generation-v1` prompts and Mac protocol. |
| `docs/EXTERNAL_PRIOR_ART.md` | current, thin | Outside techniques. |
| `docs/experiments/CLAUDE_MD_ARCHIVE_2026-10-03.md` | history | The Mac storage investigation as it was told in this guide, then named `CLAUDE.md`. |
| `docs/BENCHMARKS.md` | other hardware | Never quote it. |
| `docs/OPTIMIZATION_JOURNEY.md`, `docs/UPSTREAM_README.md`, `CONTRIBUTING.md`, `docs/OPENAI_SERVER.md` | upstream | The upstream Mac project. |

### Which prior-art summary to read

| Summary | Read it before touching |
| --- | --- |
| `01-model-install-and-expert-io.md` | The installer, the `.gturbo` layout on disk, `pread` streaming, slot buffers. |
| `02-decode-moe-int4-and-router.md` | Routed/shared FFN kernels, INT4/INT8 GEMV, router top-K, the cb1/io/cb2 handoff. |
| `03-expert-cache-prediction-and-layout.md` | Cache policy and slot count, prefetch and the early read, routing prediction, expert ordering. |
| `04-rdadvise.md` | The RDADVISE advisory path or OS read hints. |
| `05-attention-and-kv-cache.md` | Attention kernels, KV layout and dtype, RoPE. |
| `06-prefill.md` | Prefill chunking, expert tiling, MPP projection paths. |
| `07-fusions-head-and-orchestration.md` | Kernel fusion, the head, command-buffer scheduling and phase overlap. |
| `08-sampling-tokenization-and-output.md` | Sampling, softcap, tokenizer, chat format, streamed output. |
| `09-validation-and-measurement-lessons.md` | Any new kind of measurement. |
| `10-long-context.md` | Context length and long-context memory. |
