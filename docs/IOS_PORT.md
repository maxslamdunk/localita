# iOS port plan

Status: **Track A closed 2026-09-17**; Track B step 2 partly done and where work
continues. Target device chosen 2026-09-15: **iPhone 17** (see
[Target device](#target-device)). The runtime runs on the device and beats the
8 GB M1 validation host on every benchmark case.

This document is the framing and sequencing for the iPhone port. It does not
restate the measured facts — `CLAUDE.md` is the single source of truth for those
and every number below is either quoted from that table or labeled as arithmetic
derived from it.

## The constraint the port inherits

> **Superseded as guidance on 2026-10-03.** The project goal is now end-to-end
> decode and prefill time on the iPhone, with bytes/token as one lever among
> several (see "The goal" and "Where the time goes on the phone" in `CLAUDE.md`).
> On the phone, `io` is ~60% of a decode forward and GPU work plus handoff ~30%,
> and the best result so far, the early expert read, raises bytes/token. The text
> below is the 2026-08/09 framing from the Mac, kept as the plan's history.

Decode demand is **measured** as of 2026-08-10: **261.9–305.6 MB/token**, rising
with prompt length, at a 16-slot LFU hit rate of 62–68%. The zero-hit ceiling is
806.1 MB/token (`numLayers 30 × topKExperts 8 × expertStride 3358720`); measured
demand is that ceiling times (1 − hit rate). Quote the measured figure, not the
ceiling.

At 261.9 MB/token the 8 GB validation host demands 0.83 GB/s averaged over the
whole token — but it spends only the `io` window actually reading, and inside
that window it moves bytes at **1.30–1.34 GB/s against the 1.36–1.39 GB/s these
files can deliver**. So decode on that host *is* storage-bound after all, at
94–96% of the achievable rate. The intermediate claim that it ran at 29% of a
2.7–3.2 GB/s roof was arithmetic against a roof measured on zero-filled data;
that roof is withdrawn. See the resolution in `CLAUDE.md`.

The phase split (step B0b, 2026-08-10) says where that time actually goes:
**`io` is 59–63% of a decode forward**, so reads bind, and the expert cache
remains the lever that matters — a hit is a read that did not happen, and
two-thirds of requests already are one.

But two things it found reshape the track ordering below:

- **The fetch path has no slack left.** A same-day probe of the installed layer
  files put a bare serial `pread` at 1.36 GB/s against production's in-situ
  1.30–1.34 — **94–96% of achievable** — with queue depth, fd count, planning
  cost, and fragmentation all measured and ruled out as levers. The earlier
  entry here claimed a 2.2× quality-free win between the SSD and the runtime;
  **that win does not exist** and the work it justified is struck below. Fewer
  bytes is the only remaining lever on `io`.
- **GPU attention (`cb1-wait`) is 29–35% of a forward and rises with prompt
  length** — 95 ms at a 61-token prompt, 133 ms at 3,015. On device, with long
  context, this only grows. Nothing in either track currently touches it.

So the device I/O probe (step B1) has to be read alongside a device phase split,
not on its own: a phone that is attention-bound needs different work than one
that is fetch-bound, and the Mac is measurably both.

⚠️ **Corrected 2026-09-16 on the device.** This plan said iOS has no page-cache
tier. It does: on the iPhone 17, random reads at the production slot size run
~6× the uncached rate for working sets up to 1 GiB, with the knee between 1 and
4 GiB (step B1 below).

What survives is the part that binds. The routed-expert corpus is 12.01 GiB,
far past that knee, so the OS cache cannot serve the working set decode actually
touches, and the expert cache under the memory ceiling is still the only tier
the port controls. Two things change:

- **The OS cache is a real second tier for anything that fits**, which the plan
  assumed away.
- **Cache-resident bytes look cheap against the memory ceiling.** Mapped clean
  file pages cost ~16.6 MB of footprint for 1.26 GiB (step A1), so bytes the OS
  holds for us are not bytes charged to the app's 5.60 GB. Whether that can be
  turned into a design — mapping expert files rather than `pread`-ing them, and
  letting the OS cache absorb re-reads — is **untested and belongs in Track B
  step 2**, with a predicted bytes/token delta like anything else.

## Target device

Chosen 2026-09-15: **iPhone 17** (model A3258). Everything below is from spec
sheets or from reading this repo's code, not from measurement. Sources are in
[`IMPLEMENTATION_REFERENCES.md`](IMPLEMENTATION_REFERENCES.md#ios-target-platform).
(Written before any device measurement; measured values are now in `CLAUDE.md`'s iPhone table.)

| | iPhone 17 | Mac validation host |
| --- | --- | --- |
| Chip | A19: 6-core CPU (2 performance, 4 efficiency), 5-core GPU with Neural Accelerators, 16-core Neural Engine | M1 |
| Metal GPU family | **Apple10** | **Apple7** |
| RAM | 8 GB. Apple does not publish it; MacRumors read it from Xcode 26 | 8 GB |
| Storage | 256 GB or 512 GB | 256 GB |
| OS | iOS 27, per Apple's spec page | macOS 26.6.1 |

The iPhone Air, 17 Pro and 17 Pro Max have 12 GB of RAM.

**Unknown from any public source.** Each is already a scheduled measurement:

- **App memory limit.** Apple publishes no number. The `increased-memory-limit`
  entitlement raises the limit "on supported devices", and
  `os_proc_available_memory()` returns the current limit minus the app's
  footprint. Step A1 reads it with and without the entitlement.
- **Storage read rate.** There is no trustworthy public figure. Step B1 measures
  it. Record the phone's storage tier beside the result, since base-capacity
  units can ship fewer NAND chips (see `CLAUDE.md`).
- **NAND part and supplier.** One uncited source names Kioxia. The TechInsights
  teardown that would confirm it is paywalled. The plan doesn't need it, because
  B1 measures the rate directly.

### What differs from the Mac validation host

The RAM is the same but the GPU family is not, so the Mac does not exercise
every path the phone will run. Checked in code on 2026-09-15:

- **Prefill attention.** Before the upstream 0.8.0 merge, the TensorOps 2D
  full-attention prefill pipeline was built only when `supportsFamily(.apple10)`
  passed, so the M1 ran causal-tiled. Upstream #159 removed that check in
  `PrefillAttention.swift`, and both machines now try TensorOps by default. The
  phone would have run it before the merge too.
- **No GPU timing transfers.** The A19 GPU is a different architecture with
  Neural Accelerators the M1 lacks, so neither prefill timing nor `cb1-wait`
  carries over from the Mac. Measure both on the device.
- **Text prefill projections are the same.** `RealForwardRunner` builds
  `MPPPrefillInt4QMM` with its default `.control` variant, so that kernel's
  Apple10 variant is not used for text.
- **Vision.** The image tower requires `.apple8` (`VisionRuntime.isSupported`),
  so it has never run on the M1 host. On the phone it would run, and Apple10
  also selects the BF16 projector. If the port ships image input, the Mac cannot
  validate that path.
- **The GPU watchdog mitigation is macOS-only.**
  `MetalContext.relaxInteractivityWatchdog` sets
  `AGX_RELAX_CDM_CTXSTORE_TIMEOUT` under `#if os(macOS)`, because long prefill
  dispatches could otherwise be killed as compositor-impacting on macOS 26.
  Nothing does this on iOS, and whether iOS kills long dispatches is unknown.
  Treat it as a risk for step A3.

### What this changes in the plan

- **A1 budgets the KV cache at both 4K and 8K context.** The benchmark protocol
  passes `--max-context 4096`, but the CLI and app default became 8K in the
  0.8.0 merge.
- **Check extended virtual addressing in A1.** `model_weights.bin` (1.26 GiB) is
  memory-mapped, and the `extended-virtual-addressing` entitlement exists for
  apps that map large assets. Whether the runtime needs it is unknown.
- **The fallback device is a 12 GB model.** Use it if 8 GB cannot hold the
  residents, the KV cache and a useful expert cache. Switching target is a
  recorded decision, like a quality spend; do not drift onto a Pro silently.

## Two tracks

The port has two deliverables with different definitions of done. They are not
phases of one goal.

### Track A — feasibility and the quality reference

Ship a correct port at any speed, with **no quality sacrifice**.

Floor: **0.5 tok/s**. Derived from measured demand: 0.5 × 261.9 MB = **131 MB/s
sustained**, roughly 5% of the Mac's measured SSD roof (0.5 × 806.1 MB = 403
MB/s if the port's cache were sized so small it never hit). Bandwidth is
therefore even less likely to be the risk than previously stated, which makes
Track A's real risk the **memory ceiling**: ~1.35 GB of residents plus the FP16
KV cache plus Metal plus app overhead, under jetsam. Note the coupling — the
ceiling sets the cache size, the cache size sets the hit rate, and the hit rate
sets demand. A port forced down to a much smaller cache moves toward the 806.1
MB figure, not the 261.9 MB one.

Definition of done — reuse the project's existing standard, do not invent a new
one:

- Same `.gturbo` artifact, same sampling config, output within the existing
  `Tolerances` against the CPU reference. Kernels may reorder float ops; exact
  cross-path identity was never the standard here.
- Survives jetsam through a full generation.
- ≥ 0.5 tok/s.

**CLOSED 2026-09-17 — all three are met.** *≥ 0.5 tok/s:* **7.596 / 6.204 /
5.206**, fifteen times the floor. *Survives jetsam:* peak `phys_footprint`
**3.81 GB** against the measured 5.60 GB ceiling, on every run to date, all
ending `stop=endOfTurn`. *`Tolerances` against the CPU reference:* **142 tests
in 46 suites, 0 failures**, with worst-case relative error **numerically
identical on Apple10 and Apple7 at all 41 shared instrumented sites**. That
third bullet is met as written — it asks for the project's existing standard
against the CPU reference, and the existing standard is the kernel tolerance
suite, which the device now passes in full. The residual this close accepts,
and the gate that pays it off, are the last three bullets of step 3.

Track A also produces the instrument Track B cannot work without: **a zero-loss
reference running on the device**. There is no way to measure a quality
regression without it. This is why Track A comes first rather than in parallel.

Steps:

1. **Memory-ceiling probe — DONE 2026-09-16, iPhone 17 (8 GB, iOS 26.6).** The gate
   is open. Usable ceiling **5.60 GB** with the increased-memory-limit entitlement,
   which a free personal team can sign, and **3.53 GB** without it.
   `os_proc_available_memory` predicts the unentitled kill to within 3.2 MB but
   overstates the entitled one by 841 MB, so the ceiling is the measured kill
   point, never what that API reports. **Mapped file pages are nearly free
   against it:** 1.26 GiB mmapped, page-touched, wrapped in an `MTLBuffer` and
   GPU-resident cost ~16.6 MB of footprint (16.61 and 16.78 MB in two runs), so
   the ~1.35 GB of resident shared weights need not come out of the budget — the
   ceiling is spent on the KV cache, expert slots and scratch. Mapping that much
   needed no extended-virtual-addressing entitlement. ⚠️ **The entitled ceiling
   varies with system state** — 5.60 GB twice, then 5.67 and 5.87 GB, the last
   right after a reboot — so size against 5.60 GB as a floor and expect no
   guarantee. The unentitled limit reproduced to the byte. Numbers, caveats and
   logs: the four 2026-09-16 rows in `MEASUREMENTS.md`; probe at
   `~/ml_projects/iphone-port/probes/memory-ceiling`. Still open: the KV budget at
   4K against 8K context.
2. **Model delivery — split 2026-09-16 into bring-up and product.** Getting
   ~14.3 GB onto a phone: on-device download plus repack, storage provisioning,
   eviction behavior. **For bring-up this is side-loaded, not installed:** the
   Mac's existing `scratch/gemma4.gturbo` is pushed into the app data container
   with `devicectl device copy to`, which needs no code and — the reason it is
   the right call rather than the lazy one — keeps the device running the
   **byte-identical artifact** the Mac reference was measured on, which Track A's
   definition of done requires anyway. The phone had **50.5 GB free** before the
   copy (measured on-device 2026-09-16; `devicectl` reports total capacity only).
   Porting the installer stays on the plan as the product answer, and its
   **prerequisite is met as of 2026-09-17.** `TurboFieldfareAppCore` did not
   build for iOS because `Inference/DecodeServiceInferenceClient.swift` uses
   `Process`, which iOS does not have. That was never a bug — the Mac app is two
   processes so its UI never holds a second model, and on iOS a second process
   would be actively harmful under jetsam. ✅ **The split is done:** that file and
   its `DecodeServiceResponseRouter` moved to a macOS-only
   `TurboFieldfareMacInference` target, and `TurboFieldfareAppCore` **also
   dropped its `TurboFieldfareDecodeProtocol` dependency** — those two files were
   its only importers, so the socket transport is now entirely out of the iOS
   build. ⚠️ **The boundary is the client, not `Inference/`**, which this entry
   had assumed: the half the phone wants *includes*
   `Inference/RealInferenceClient.swift`, because `AppModel`'s default client is
   the in-process one and only `TurboFieldfareMacApp` overrides it. So the phone
   needs no new inference path — it needs the default. `TurboFieldfareAppCore` is
   now a library product, and the `iOS/` app target links it and compiles for
   `generic/platform=iOS`, so this is verified rather than asserted. The
   `Installation/` half is therefore reachable and on-device install is unblocked.
   ✅ **In-app download added 2026-09-24.** When no model is installed, the
   chat is replaced by a download screen driving the Mac's
   `RepackModelInstallerClient`, unchanged apart from a network flag. It runs
   only in the foreground:
   - The screen is kept on while it runs.
   - Leaving the app cancels it at a checkpoint, and returning resumes it.
   - It never uses mobile data or a hotspot without asking first
     (`RemoteDownloadSessionPolicy.allowsExpensiveNetworkAccess`).

   Two fixes came with it:
   - **Free space was undercounted.** `DiskSpaceChecker` counted only `statfs`
     free blocks, which leaves out the purgeable space iOS reports as free. It
     refused a 15.43 GB install on a phone with 66.4 GB available. On iOS it
     now uses "available for important usage".
   - **Nothing marked the model to skip iCloud backup.** Every `.gturbo`
     folder and download file is now excluded (`BackupExclusion`).

   The first real download on the iPhone 17 took about an hour, including one
   pause, and passed its own verification. A test-only `--model-dir <name>`
   launch argument installs it beside the side-loaded model without touching
   it. Whether the scattered write order it inherits costs read speed on the
   phone is measured in `results/benchmark-results-2026-09-24-ios-download-order/`.

   ✅ **The download keeps running in the background since 2026-10-07**
   (`BackgroundDownload`). The download is wrapped in an iOS 26
   `BGContinuedProcessingTask`, whose system Live Activity shows the progress
   on the Lock Screen. Background `URLSession` was the alternative. It was not
   tried, because the installer writes ranges into the layer files as they
   arrive and would need rebuilding around whole-file transfers.

   Tested on the iPhone 17 with a full download into a test folder:
   - **It keeps going** with the app in the background, with other apps in use
     and with the phone locked. One run completed and installed entirely in
     the background.
   - **iOS ends it about 25 s after the phone leaves Wi-Fi**, because no bytes
     arrive (24 s measured). Swiping the app away ends it too.
   - **It cannot restart itself.** iOS only lets the task start while the app
     is open, so getting Wi-Fi back changes nothing until the app is opened.

   What covers a stop:
   - **A notification** says why it stopped: waiting for Wi-Fi, no
     connection, or paused. A swipe-away is caught by one notification kept
     two minutes ahead and pushed back while bytes arrive.
   - **The Live Activity title** says "paused at N% · open the app to
     continue". iOS's own "Task Failed" line under it cannot be changed.
   - **Opening the app resumes it** from the last 64 MiB checkpoint without a
     tap.

   The screen is no longer kept on during the download. If the task cannot
   start, the old behaviour remains as the fallback: leaving the app pauses
   the download at a checkpoint, and returning resumes it. The image-support
   download still works that way.

   ✅ **A reply can keep generating in the background since 2026-10-09**
   (`BackgroundGeneration`, opt-in; tried by hand on the phone, no
   scripted run). The probes in
   `results/validation-results-2026-10-09-ios-background-probes/` found one way for a
   backgrounded app to use the GPU: showing Picture in Picture. So when the
   user leaves mid-reply, the reply moves to a small window that shows its
   last lines, with Markdown styled, and offers only close and return-to-app
   controls (`controlsStyle` 1; 2, with no controls at all, was tried and
   dropped). Locking the
   phone refuses GPU work even then. The decode loop now catches that refusal
   (`GPUWorkNotPermitted`, Metal's code 7) and asks a `GPURefusalHandler`
   what to do. The app's handler waits in `GPUWorkGate` and runs the same
   token again when the GPU is back. That is safe because the KV advances
   only after a whole forward succeeds. A prefill refusal resumes after the
   chunks that committed.
   - **Lock:** the reply pauses, and unlocking resumes it.
   - **Closing the window:** suspends the app, and coming back resumes the
     reply.
   - **Leaving without a window** (it failed to open, and the phone is not
     locked): stops the turn and saves it, as before.
   - **The setting** "Keep generating in background" is off by default,
     which keeps the old stop-on-leave behavior.
   - **Returning** through the app icon closes the window cleanly. Its
     full-screen button still grows the window to full screen before it
     goes, which was judged acceptable.

   Known risk: a paused turn lives only in memory, and iOS kills a frozen
   3 GB app after a few minutes (probe run 2). The window uses the private
   `controlsStyle` key and has no video, which App Review would refuse. The
   app is side-loaded.

   ✅ **Community models from a pasted link since 2026-10-07.** Add Model in
   the composer's model menu takes a Hugging Face link or `owner/name`.
   `RemoteModelInspector` reads only the config, the index and each shard's
   header (a few MB). It accepts a checkpoint only when its text model is
   Gemma 4 26B-A4B laid out exactly as the reference's
   (`ReferenceLayout`):
   - same architecture;
   - every text tensor with the same name, dtype, shape and bit width;
   - vision and audio tensors left out.

   gemma4 and supergemma4 give the same layout fingerprint. The installer
   enforces the layout again when it runs. An added model:
   - is pinned to the commit the check read;
   - installs into `hf-<owner>--<name>.gturbo`;
   - borrows Gemma 4's image pack;
   - is listed in `community-models.json` beside the model folders.

   Settings lists every model on the phone with Delete. (Superseded below:
   since 2026-10-08 any model can be deleted, and Add Model lives in
   Settings.)

   - **The check, on real repositories (Mac CLI `--check-source`):**
     - Passed: an abliterated Gemma 4, an uncensored re-tune, Orion,
       Hermes-VLM, and a QAT build with the plain layout.
     - Refused, each with a reason: LM Studio's QAT build (8-bit shared
       expert, never run here), an 8-bit build, a GGUF repository, Qwen,
       and a repository that does not exist.
     - The 8-bit shared expert is the one refusal that could be lifted. The
       runtime's manifest check allows it, but it has never been run or
       measured on the phone.
     - **Lifted 2026-10-13 in the check.** The same day,
       `lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit` installed in
       the app on the iPhone 17 (b3e0034) and chatted normally (checked by
       hand; speed not measured).
       `ReferenceLayout` now accepts a second fingerprint: the reference
       with the shared expert's 90 packed weights at 8 bits (twice the
       packed width) and every other text tensor identical, scales and
       biases included, by a header diff against LM Studio's QAT build.
       Six repositories give that fingerprint: LM Studio's QAT and non-QAT
       4-bit builds (about 349k and 157k downloads, the most-used Gemma 4
       26B MLX builds), mlx-community's QAT, heretic and base 4-bit builds,
       and a Huihui abliterated build. The runtime already ran both widths
       (`SharedExpertRuntime`, decode and prefill), and `SharedExpertInt8`
       is in the device kernel suites. Arithmetic: the shared expert grows
       from ~287 to ~542 MiB of mmapped resident weights.
   - **Finding: the pinned "source fingerprint" does not identify weights.**
     It is the SHA-256 of `model.safetensors.index.json`, which maps tensor
     names to shard files. Any re-tune sharded the same way shares it: the
     abliterated Gemma 4 has gemma4's, and two re-tunes have supergemma4's.
     It pins a layout; the revision pins the weights. The installer used to
     record the matched pinned model as the manifest's `modelID`. It now
     records the repository actually downloaded.
   ✅ **Models are managed in Settings since 2026-10-08, and the chat stays
   a chat without one.** The full-screen download page is gone. Decided with
   the user:
   - **Settings → Models** lists every model the app knows, with Download,
     its progress and Cancel, or Delete, plus Add Model. It asks about mobile
     data before a download, as the page did.
   - **The chat's model menu lists only downloaded models**, with Manage
     Models… opening that tab. With none downloaded, the menu pill is hidden.
   - **With no model, stored chats still read.** The top of the chat says "No
     model installed", an empty chat shows a short page with Open Settings,
     and Load explains where to get a model instead of sitting greyed out.
   - **Any model can be deleted.** If it is in memory, it unloads first. If
     it is the model the app is on, the app first moves to the next
     downloaded model in the menu, or, with none left, to the no-model state.
     Deleting Gemma 4 takes SuperGemma 4's image support with it, and the
     confirmation says so; `AppModel` only refuses it while SuperGemma 4 is
     in memory.
   - **A download switches the app to that model.** `AppModel` has one
     installer, bound to the selected model, so Download on another model
     selects it (unloading the one in memory) and downloads it. One download
     runs at a time. A separate installer, so that chatting could continue
     during a download, was weighed and not built: it is a larger change to
     shared code, and a 14.6 GB write would compete with expert reads.

3. **Port the runtime — started 2026-09-16, app target building and running on
   the device.** 16-slot expert cache untouched, no optimization.
   - **The runtime needed no porting to compile.** `TurboFieldfare` (85 files,
     17,704 lines) and `TurboFieldfareFormat` (6 files, 1,262) build clean for
     `arm64-apple-ios26.0` against the iPhoneOS26.5 SDK with **zero errors**.
     `Package.swift` already declared `.iOS(.v26)`. The only error in the whole
     package was `homeDirectoryForCurrentUser` in `AppModelLocation.swift`
     (fixed, platform-neutral, macOS build and tests green).
   - **The Apple10 risk is narrower than the plan assumed.** `RealForwardRunner`
     builds `MPPPrefillInt4QMM` with the default `.control` variant, and only
     `VisionRuntime` opts into the Apple10 kernels. **Text prefill and decode are
     GPU-family-independent**; the divergence from this Apple7 host is confined
     to the vision tower. Confirmed on hardware: the device reports
     `Apple A19 GPU` with `supportsFamily(.apple10) == true`.
   - **Shaders compile on-device in 281 ms.** All 14 `.metal` modules (5,480
     lines) resolve through `Bundle.module` from inside an app bundle and
     compile at startup, as on the Mac. This was the untested runtime risk of
     shipping shader *sources* rather than a metallib; it is retired.
   - **The increased-memory-limit entitlement works in a real app**, not just a
     throwaway probe: `os_proc_available_memory` reports 6.43 GB at launch,
     matching the A1 entitled figure, signed by a free personal team.
   - The harness copies `expertIOFooter` and `phaseTimeFooter` **verbatim** from
     `Sources/TurboFieldfareCLI/Run.swift`. That duplication is deliberate and
     hand-maintained: it is what makes a device number comparable with a row in
     `MEASUREMENTS.md`. Change both in the same commit.
   - It loads the model with `.sizeCheckTrustedReceipt`, not `.fullSha256`. The
     latter verifies each 410 MiB layer file on its **first routed touch**,
     landing a SHA-256 of 12.01 GiB inside the `io` phase it is meant to measure.
   - **Track A's feasibility gate is met (2026-09-16).** First on-device
     generation: 36-token prompt, 64 new tokens, `stop=maxTokens`, 17.99 s
     decode, **3.558 tok/s** — seven times the 0.5 tok/s floor. **No jetsam:**
     peak `phys_footprint` **2.145 GB** against the measured 5.60 GB ceiling,
     with 4.30 GB still reported available, so the ceiling is not close to
     binding at 16 slots and 4K context.
   - **The A19 GPU beats this M1 on the compute phases.** `cb1-wait` **64.44**
     ms/forward against the Mac's 91.55, and `head` **11.84** against 15.09.
     The phone's deficit is entirely in `io` — **199.92** against 150.18 —
     which is the direction Track B step 1 predicted from storage. The second
     half of the binding constraint therefore looks *better* on the phone than
     on the host, and `cb1-wait`, named in `CLAUDE.md` as the most likely place
     for the next win on the Mac, is a smaller problem here.
   - ⚠️ **These figures are not comparable with the Mac rows**, for two reasons
     that are both about workload rather than the device. The prompt was an
     ad-hoc one rather than the frozen `real-generation-v1` set, so routing and
     therefore hit rate differ — 57.5% against the Mac's 67.7%, and 326.72
     MB/token against 260.2. And `--max-new 64` amortizes the one-time SHA-256
     of the 12.01 GiB corpus over 63 forwards where the protocol's
     `--max-new 1024` spreads it over roughly 600. **Both platforms pay that
     verification** — the Mac CLI hardcodes `.fullSha256` at `Run.swift:183` —
     so this is a dilution difference, not a contamination peculiar to the phone.
   - **The trusted-receipt path cannot bind on iOS, and this blocks clean
     measurement.** `validateManifestBinding` compares
     `receipt.modelDirectoryPath` against the live directory. A side-loaded
     artifact still names the Mac path it was verified at, and more
     fundamentally an app container's UUID changes on **every install** — three
     distinct UUIDs observed across installs on 2026-09-16 — so even a receipt
     regenerated on the device would be void after the next one. Until that
     binding is relaxed, every device run pays `.fullSha256`. Fixing it touches
     shared validation code that the installer and verifier also use, so it is
     a change to raise rather than make quietly; see
     [Coordination hazard](#coordination-hazard).
   - **DONE 2026-09-16 — the comparable run, and the phone beats the host.**
     All three frozen `real-generation-v1` cases at `--max-new 1024
     --max-context 4096`, every one `stop=endOfTurn`:
     **4.395 / 3.961 / 3.571 tok/s** against this Mac's 3.745 / 3.346 / 2.987
     pre-merge and 3.729 / 3.255 / 2.897 at HEAD — **+17 to +23%**. Prompts were
     pushed to the device rather than bundled, and each file's SHA-256 is in the
     log and matches the canonical hash, so the run proves which bytes made it.
     - **The controls hold, which is what makes the comparison legitimate:**
       hit rate 67.7 / 64.9 / 62.3% against the Mac's 67.7 / 65.0 / 61.6, and
       bytes/token 260.6 / 283.2 / 304.2 MB against 260.2 / 281.9 / 309.3.
       Same workload, same byte profile.
     - **The win is entirely GPU.** `cb1-wait` −31 to −33% and `head` −26 to
       −28%, while `io` is at parity (147.41 / 160.80 / 171.46 against 150.18 /
       166.39 / 182.59). **This inverts the plan's working assumption for the
       port:** the phone's problem was supposed to be that its storage is
       slower, and instead its compute is so much faster that it wins outright.
     - ⚠️ **`io` parity is not a result about the device.** The phone's artifact
       is 0 h old; the Mac's is 26.8 d. Track B step 1 measured the phone's
       storage as *slower* than this Mac's like-for-like, and nothing here
       contradicts that — the aged re-run is what settles it.
     - ⚠️ Generated token counts differ (507 / 632 / 602 against 511 / 669 /
       604), so the text is not byte-identical: near-identical work, not
       identical. And the long case ran its whole decode at thermal `fair`
       while short and medium stayed `nominal`, so its figures were taken in a
       hotter state than the other two.
     - **Prefill is the unflattering half.** The long case spent **168 s in
       prefill against 169 s in decode** for a 3,015-token prompt, reading
       192.7 GB at a 0.0% hit rate. On a phone, a long prompt costs as much as
       the entire answer.
   - **Kernel numerics checked on device — DONE 2026-09-16.** Track A's
     definition of done also asks for output within the existing `Tolerances`
     against the CPU reference. The package's own kernel suites now run on the
     device as an Xcode test bundle hosted in the `iOS/` app — the same
     assertions that gate the Mac, not a reimplementation, which would drift and
     then lie. **142 tests in 46 suites, 0 failures, 0 skipped**
     (`results/validation-results-2026-09-16-ios-kernels/`). Every text-path kernel
     conforms on Apple10, as do the nine Accelerate-vs-scalar reference suites,
     which is what establishes that the *comparator* is sound on this silicon.
     Vision and the TensorOps/MPP path — the two flagged in advance as most
     likely to diverge — both passed.
   - ✅ **Margins measured the same day, and the A19 matches the M1 exactly
     (`b6cac0a`).** The objection that stood here until 2026-09-17 — that the run
     was "binary pass/fail rather than a margin measurement, so an Apple10 drift
     that stays inside a tolerance bound would be invisible to it" — is
     **answered and withdrawn**. `RelError` reports every comparison, and across
     all 41 shared instrumented call sites the worst-case relative error is
     identical on both chips to every printed digit, 0 differing; text-path
     kernels sit at ≤43% of their bounds. Such a drift would now show as a
     changed margin.
   - **What closing Track A accepts, stated rather than buried.** Kernel tests
     exercise kernels *in isolation* on seeded synthetic data with no model
     loaded, so they do not test **composition** — orchestration, KV cursor
     arithmetic over long context, layer scalars, the sampled output head. A
     binding or ordering bug would pass all 142 and still generate wrong text.
     Two things bound that risk without eliminating it: the device runs the
     byte-identical artifact, and its **hit rate (67.7 / 64.9 / 62.3%) and
     bytes/token land within 0.7pp and 2% of the Mac's** — routing is the
     router's output, which depends on the whole forward being right, so a
     composition bug is unlikely to leave a byte profile that close.
   - ⚠️ **Differing generated text is not evidence of a defect and should stop
     being cited as one.** The device produces 507 / 632 / 602 tokens against the
     Mac's 511 / 669 / 604, but these runs *sample* (temperature 0.2, Top-K 64,
     Top-P 0.95): a 1-ULP logit difference near a tie flips one draw, and the
     sequences diverge permanently after it. The Mac does the same to itself —
     HEAD after the 0.8.0 merge generated 527 / 665 / 597 on the same machine and
     artifact, which `CLAUDE.md` records as a changed routing workload, not a
     regression. The standing lesson is
     [METH-01](experiments/summaries/09-validation-and-measurement-lessons.md#meth-01):
     numerical equivalence is a distributional claim, not a bit-identity claim,
     and four candidates were once falsely rejected on exactly this gate.
   - **The gate that pays off the residual: a greedy A/B before Track B step 3.**
     Run the same prompt and artifact at `--temperature 0` on both the Mac CLI
     and the device, and compare token IDs; greedy removes the sampling noise
     above, so a divergence there is real. This is owed before **step 3**, the
     quality-spending levers — the only work whose measurements depend on the
     device reference being calibrated. Step 2's remaining levers are
     quality-neutral by construction, as the slot-count and chunk-size wins were;
     both changed zero tokens. ⚠️ Greedy and sampled generation use different
     output-head paths (`forceLogitsHead: !config.isPureGreedy`), so a greedy
     match validates the numerics and the greedy head, not the sampled head.
   - The app target lives at `iOS/`, is hand-written, and is tracked despite the
     blanket `*.xcodeproj` ignore rule — losing it would leave the port
     unbuildable from a clone.

### Track B — performance

Push bytes/token as hard as possible, accepting quality cost where it is worth
it. The balance point is decided later, against real numbers — and the ordering
below makes that deferral structural rather than a matter of remembering to.

0. **Mac-side instrumentation — DONE 2026-08-10.** `ExpertIOCounters` counts
   bytes on the `pread` path and hits/misses in the cache planner; the CLI
   prints an `[expert-io …]` footer line and the HUD shows decode bytes/token
   and hit rate. First measured values are in `CLAUDE.md` and `MEASUREMENTS.md`.
   Two follow-ups this exposed: the CLI footer does not print the per-phase
   `cb1`/`io`/`cb2` split the runtime already tracks, which is what would show
   whether decode time is actually going into reads; and **prefill runs at 0.0%
   hit rate**, reading 192.6 GB for a 3,015-token prompt — about half of all
   bytes that run touched.
0b. **Per-phase time split on the Mac — DONE 2026-08-10, `ce287b6`.** The CLI
   prints a `[phase-time …]` footer. Printing the three counters the runtime
   already had would not have answered the question — `cb1` and `cb2` exclude
   GPU execution by construction — so the two waits that were being computed and
   discarded were added with them. Predicted 0 bytes/token; measured bytes/token
   came back identical to the digit against the previous session, confirming it.
   Findings are in `CLAUDE.md`; the two that change this plan are quoted above.
1. **Device I/O probe — DONE 2026-09-16, iPhone 17 (iOS 26.6).** Sustained random
   reads at the production 3,358,720 B slot size, one read in flight, over a
   12.01 GiB corpus of incompressible bytes shaped like the 30 installed layer
   files, 60 s per working-set point.
   - **Uncached rate: 1.650 GB/s** (p50 2,142 µs, p95 2,623, p99 5,052).
   - **The page-cache assumption was wrong.** 256 MiB reads at 9.829 GB/s and
     1 GiB at 10.456 — roughly 6× uncached — with the knee between 1 and 4 GiB
     (4 GiB gives 2.606). See the correction under
     [The constraint the port inherits](#the-constraint-the-port-inherits).
   - **The corpus was 0 h old and sequentially written**, so 1.650 is a best
     case. Against the Mac's comparable 0 h control (2.30 GB/s at the same
     granularity) the phone's storage is **slower**, so no Mac fetch figure
     transfers to the device.
   - **Thermal reached `fair` and never `serious`**, and throughput stayed flat
     inside every point, so this is a sustained number rather than a burst.

   Numbers, predictions and misses: the 2026-09-16 rows in `MEASUREMENTS.md`.
   Two predictions failed (the 4 GiB/full-corpus agreement, and the page-cache
   assumption); both are recorded rather than dropped. Still open: the same sweep
   on an aged corpus, and a queue-depth sweep — production issues one read at a
   time, and whether the phone rewards more is unmeasured.
2. **Quality-neutral levers** — exhaust these before spending any accuracy:
   - ~~**Close the fetch-path gap.**~~ **Struck 2026-08-10, diagnosed and
     closed.** This was listed as the largest known quality-free win on the
     strength of `io` running at "41–50% of the device roof". The roof was
     measured on a zero-filled probe file; on the real, incompressible expert
     bytes the same probe gives 1.36–1.39 GB/s and production already achieves
     94–96% of it. Queue depth (k=2/3/8: flat), 30 fds vs. one, planning cost
     (outside the `io` timer) were each measured and are not levers. There is
     ~4–6% here against a QD1 serial read, not 2.2×. Two honest residuals
     survive, and both belong to the port rather than to the Mac:
     - **Steady queue depth.** Random reads saturate at 1.82 GB/s at QD4 on a
       quiet disk and production sits at 1.30–1.34, so a *steady* pipeline is
       worth ~27% of `io`. `cb2` needs every expert of the layer before it starts, so the
       fan-out is burst-and-drain by construction and pays the batch's slowest
       read, not its mean; ORCH-09 through ORCH-15 are the record of what
       happens to schemes that try to break that. But per layer `io` is 6.74 ms
       for 2.6 reads against 6.43 ms serial, i.e. the existing
       `concurrentPerform` fan-out buys ~nothing — and the probe suite found
       `dispatch_apply` (1.43–1.55 GB/s) below real pthreads (1.63–1.67),
       because GCD may not supply threads for blocking work. Cheap to test, and
       [IO-11](experiments/summaries/01-model-install-and-expert-io.md#io-11)
       carries the prediction.
     - **Install-time write order — promoted 2026-08-10, validated 2026-08-11,
       WITHDRAWN 2026-08-18 when the first artifact decayed, and REOPENED
       2026-09-15 when a second artifact held at 27 days.** The falsifier
       written into this entry — *"falsified if a sequentially rewritten layer
       file, once aged, reads no faster than the installed original"* — **fired.**
       Read the correction at the end of this entry before acting on anything in
       it. Superseding the earlier "upper bound ~19% from
       fragmentation" framing here, which was wrong: APFS extent count explains
       ~13% and predicts nothing across files. What predicts read rate is the
       order bytes were *written* relative to their logical order, because that
       sets NAND page placement. Same bytes, same age, read at production's slot
       granularity: sequential write **2.30 GB/s** vs. shuffled 256 KiB write
       **1.78** at 0 h, and **2.08** vs. **1.55** at 25 h — a ratio of 1.29–1.34×
       that does not decay. The installed `layer_25.bin` reads **1.34–1.41**.
       The installer writes 30 layer files interleaved as remote shards arrive,
       which is the scattered case (confirmed in code — see prerequisite 2).
       Rewriting each layer file in one sequential
       pass predicted **0 bytes/token, `io` read rate ~1.3×** (~−47 ms/forward on
       the short case, 202.1 → ~155 ms, wall 323.0 → ~276, 3.10 → ~3.6 tok/s);
       falsified if a sequentially rewritten layer file, once aged, reads no
       faster than the installed original.
       **DONE on 2026-08-11 — the prediction held at t≈0.** All 30 layer files
       were rewritten in place (hash-verified per file, atomic rename,
       `--verify-install` clean) and `real-generation-v1` gave
       **3.725 / 3.306 / 2.978 tok/s, +20.1% / +14.4% / +14.9%**, with `io`
       **152.40 / 169.61 / 182.64 ms** (predicted ~155 on the short case) and
       **bytes/token unchanged to the digit**. Achieved fetch bandwidth
       1.30–1.34 → **1.64–1.72 GB/s**.

       **WITHDRAWN 2026-08-18 — the aged re-run falsified it.** Same artifact
       untouched at **7 d 16.8 h**, same binary, same seeds:
       **3.271 / 2.858 / 2.674 tok/s** (−12.2% / −13.5% / −10.2%), `io` back to
       **187.33 / 213.01 / 216.29 ms**, fetch back to **1.31–1.41 GB/s** (units-corrected 2026-09-15) — the
       scattered artifact's rate. What survives against the artifact this
       replaced is **+5.4% / −1.1% / +3.2%**, i.e. nothing once that baseline's
       ~3% Spotlight handicap is removed; the medium case is now *slower*.
       Generated text was byte-identical and `cb1-wait` moved <2.5%, so the
       regression is storage-specific and not machine drift. ⚠️ Confounded by a
       ~34 GiB deletion in the same window (91% → 74% full), so GC-triggered
       relocation is at least as likely as time decay. See
       [IO-12](experiments/summaries/01-model-install-and-expert-io.md#io-12) and
       [IO-13](experiments/summaries/01-model-install-and-expert-io.md#io-13).
       **REOPENED 2026-09-15 — the persistence condition below has now been met
       once.** The second rewrite (2026-08-19, on a 74%-full volume) was re-run
       untouched at **26.8 d**: **3.745 / 3.346 / 2.987 tok/s**, fetch
       **1.67–1.74 GB/s**, bytes/token and output identical — +20.7% / +15.8% /
       +15.2% over the scattered artifact. The first artifact's decay was a
       property of that artifact (written onto a 91%-full volume, then a ~34 GiB
       deletion), not of age. Before the installer change is worth building,
       IO-13 has to say which of those two killed it: if it was free space at
       write time, the installer needs a free-space precondition as well as
       sequential order.
       **The product change was taken off the plan on 2026-08-18.** Making the installer write
       sequentially would buy a first-session speedup that decays under ordinary
       use, which does not justify reworking the streaming copy path against the
       bounded-memory rule. It returns to the plan only if the gain is shown to
       persist, or GC is confirmed as the cause and a layout is found that
       survives it. The **invariant stands regardless**: nothing may deliberately
       scatter the files, since avoiding that is free. This no longer settles
       CACHE-09. Two things were settled before implementing, in order:
       1. **The decay re-test — DONE 2026-08-11, both terms confirmed.** Run with
          0-hour controls written in-session rather than as a bare re-read, since
          a cross-day comparison confounds decay with machine-state drift and a
          null would have been unreadable. **Recency decays ~15% per 24 h**
          (sequential 3.23 → 2.74, shuffled 2.10 → 1.80). **Write order is
          1.54× at 0 h and 1.53× at 24 h — it does not decay**, which is what
          makes it a lever rather than an artifact. **Magnitude corrected the same
          day to ~1.3×:** those cells were read whole-file, production reads
          random slots, and re-measured under that geometry the ratio is 1.29× at
          0 h and 1.34× at 25 h — still undecaying, but ~85% the claimed size.
          Consequence for benchmarking:
          record the model's age on disk beside every performance number, and
          treat community figures without it as age-contaminated — a run taken
          the day of install reads ~10–15% faster than the same model a day later.
          Still open, and not a blocker: the curve past 24 h. Six controls are
          retained in `/tmp` for later re-reads.
       2. **Confirm the installer actually interleaves — DONE 2026-08-11,
          confirmed, and the cause is not what the wording here assumed.** It is
          not concurrency: `HTTPRangeSourceByteProvider.copyBatch` is a single
          sequential loop with no task group. `RangeCopyPlanner.coalesce` builds
          the copy list in destination order and then **re-sorts it by
          `(shardID, sourceOffset)`** so adjacent source ranges merge into single
          HTTP requests. The install therefore walks the remote shards front to
          back and scatters each range into whichever layer files own it, holding
          every touched fd open in an `outputFDs` cache for the whole phase —
          interleaved across the 30 files *and* non-monotonic in offset within
          each one. **This is a direct consequence of the bounded-memory rule**:
          streaming source-ordered ranges straight to their destination offsets is
          what avoids buffering a tensor, and scattered write order is its
          by-product. Any fix has to keep that property (see the sequential
          rewrite pass below), not undo it.
   - Expert cache sizing against the ceiling from A1. ⚠️ **Corrected
     2026-09-16 — the "54 MB" figure that stood here was wrong by 30×.** Slots
     are allocated **per layer**: `Model.load` builds one `PreadExpertStreamer`
     per layer, each with `slotCount` buffers of 3,358,720 B, so 16 slots means
     30 × 16 = 480 buffers = **1.61 GB already allocated**, not 54 MB. 54 MB is
     one layer's share. The phone therefore does not "afford 1 GB+" as an
     upgrade — it is already spending that — and the move actually available is
     roughly one doubling: 24 slots costs +0.81 GB and 32 costs +1.61 GB,
     against a measured 5.60 GB ceiling with 2.13 GB in use. 48 slots/layer
     would reach ~5.35 GB, too close to a kill point that varied by 270 MB
     across runs. This is the condition
     [CACHE-03](experiments/summaries/03-expert-cache-prediction-and-layout.md#cache-03)
     was deferred on — "conditional +memory experiment" — so the phone reopens
     it with a new argument rather than repeating it. Predictions for the 24 and
     32 slot runs are in `results/benchmark-results-2026-09-16-ios-slots/predictions.md`.
     **DONE 2026-09-16 — the largest win in this log, and it is memory-funded.**
     32 slots per layer gives **7.005 / 6.181 / 4.786 tok/s**: +59 / +56 / +34%
     over the 16-slot baseline and **1.87× / 1.85× / 1.60× the Mac host**, for
     +1.61 GB of buffers and a peak footprint of 3.77 GB against the 5.60 GB
     ceiling. 24 slots gives 6.028 / 5.079 / 4.328 (+37 / +28 / +21%) at
     2.96 GB. Hit rate reaches 86.5 / 83.0 / 80.6% and bytes/token falls
     48.7–58.3%. Scoring is in `results.md` beside the predictions.
     - **CACHE-03's thrashing failure does not reproduce.** Its live 32-slot row
       on the 8 GB Mac collapsed to 1.578 tok/s with `io` at 318.3 ms/token; on
       the phone `io` falls monotonically at every slot count and in every case.
       **The measured 5.60 GB ceiling headroom is real**, which is the premise
       the rest of Track B is planned against.
     - **Two predictions missed, and both trace to one cause.** Bytes/token at 24
       slots came in under its predicted −35 to −50% band on medium and long
       (−31.0 / −29.2%), and the tok/s point estimate overshot the long case by
       17%. `io` does not fall in proportion to bytes: achieved fetch *drops* as
       the cache grows (1.767 → 1.708 → 1.400 GB/s on the short case, because
       the reads that remain are the scattered ones), and `cb1-wait` does not
       shrink with bytes at all.
     - **So the next win on the phone is attention, not bytes.** At 32 slots
       `cb1-wait` is **39% of the long case's wall**. `CLAUDE.md` already names
       it as the most likely place for the next win on the Mac; shrinking the
       byte half has now made it the dominant term here too.
     - **Trace replay over-predicts live gain** by 2–5 hit-rate points, worth
       knowing before any future cache work is justified on replay alone.
     - ⚠️ **Thermal is a measured confound now, not a caveat.** A 16-slot control
       repeated hot against the same case cool cost **11.6% of throughput**, with
       bytes/token and hit rate identical to the digit. `serious` throttles the
       fetch path (`io` +18.3%) far more than the GPU (`cb1-wait` +3.6%), so
       record thermal beside every device number and treat a run that reached
       `serious` as **understating** its gain — which includes the long case
       above, whose baseline ran cooler than its 24- and 32-slot runs.
     - ⚠️ **Lowered to 24 on 2026-09-24.** At 32 the chat app rests at about
       4.1 GB, and the system photo picker could not open beside it without the
       app being killed. See `results/benchmark-results-2026-09-24-ios-vision-memory/`.
     - **32 is now the iOS default — DONE 2026-09-16 (`bf95248`).** Expressed as
       `RuntimeConfiguration.productionExpertCacheSlots`: 32 on iOS, 16 on
       macOS, because CACHE-03 measured 32 as actively harmful on the 8 GB Mac
       and the cost is real — slots are per layer, so 16 → 32 is **+1.61 GB**.
       A named constant in `Configuration/` rather than an `#if os(iOS)` at call
       sites, per `Infrastructure/CLAUDE.md`.
       - ⚠️ **The default alone was not enough.** `HarnessSettings` hardcoded its
         own `expertCacheSlots = 16`, which silently overrode the new default and
         would have held every device run at 16 while the runtime claimed
         otherwise. It now reads the shared constant. Verified by a run passing
         **no** `--slots`, which logged `slots=32`.
       - Test coverage was the other trap. `RuntimeConfigurationTests` asserts the
         default but runs under `swift test`, which is macOS-only — so a
         per-platform default would keep passing on the Mac while the iOS value
         went entirely unasserted. The assertion is now platform-split and the
         suite runs in the on-device bundle: 145 tests in 47 suites, 0 failures.
   - **Prefill chunk size — DONE 2026-09-16, and it is the other half of the
     win.** 256 against the default 128, at a fixed 32 slots:
     **7.596 / 6.204 / 5.206 tok/s**, prefill bytes −39.6 / −43.2% on medium and
     long, prefill time **−31.9 / −32.3%**, and end-to-end wall on the long case
     **313.4 → 243.3 s (−22.4%)**. Costs ~36 MB and changes no output. Combined
     with 32 slots the device now runs at **2.03× / 1.85× / 1.74× the Mac host**.
     Predictions and scoring are in `results/benchmark-results-2026-09-16-ios-prefill/`.
     - **This was a default nobody revisited, not a new idea.**
       `docs/RUNTIME_CONTROLS.md` already recorded 256 as 16% faster than 128 on
       the Mac with byte-identical output, and the server already resolves
       `auto` to 256 — but the CLI and app default to 128, so every Mac
       benchmark row and every device run before this one used 128. I twice
       asserted 256 was untested; the controls doc carries measurements, not
       just descriptions, and reading it would have prevented that.
     - **Two predictions were falsified.** Prefill bytes missed the 40% floor on
       medium (−39.6%), because halving the chunk count does not halve the
       bytes: per-chunk volume grows 13.6–20.8% with chunk size as a wider chunk
       routes to more distinct experts. And decode phases moved 5–10% on short
       and long despite an unchanged decode byte profile — plausibly thermal on
       long, **unexplained on short**, where both runs were `nominal`.
       - ⚠️ **The candidate explanation is refuted, same day, without needing its
         falsifier run.** It held that 40% fewer prefill bytes leave the OS file
         cache less thrashed entering decode. A third short-case run — the `auto`
         verification, which resolved to chunk 64 — gave **7.209 tok/s**, between
         c128's 7.005 and c256's 7.596, with the same byte-identical decode
         profile and all three sampling `nominal` throughout, so thermal is
         unavailable too. Decisively, **all three read identical prefill bytes**
         (6,950.78 MB), because a 61-token prompt is one chunk at 64, 128 *and*
         256. Prefill volume never differed on the short case, so the proposed
         mechanism could not have applied there at all.
       - Short is therefore **ordinary device run-to-run variance, ~8% across
         three runs** with identical bytes, hit rate and thermal state — not a
         prefill→decode coupling. The long case's 5.5% stays open and still
         plausibly thermal. Either way, no decode effect may be quoted from a
         prefill change.
     - ⚠️ The long-case prefill gain is **inflated by thermal** in the direction
       the prediction warned about, so **−20 to −25% is the conservative
       attribution** to chunk size rather than the measured −32.3%.
     - **`auto` is now the iOS default — DONE 2026-09-16.** ⚠️ **And the plan
       this line replaced was wrong about what that meant.** `auto` is *not* a
       shared default that can be switched: `Run.swift` shows it is a
       parse-level alias resolved from the prompt length *before* the config is
       built, and `RuntimeConfiguration.prefillChunkTokens` is always a concrete
       `Int`. It cannot be expressed as a constant, so **the shared default stays
       128 on every platform**. What changed is that the iOS app leaves the size
       unset and resolves `PrefillRuntimeConfig.autoChunkTokens` once the prompt
       is tokenized — which required hoisting prompt encoding above the runtime
       configuration, mirroring the CLI's ordering.
       - Verified on device with neither knob passed: `prefill-chunk-auto
         resolved=64 for 61 prompt tokens`, `prefillChunkSource=auto`, and
         prefill bytes **6,950.78 MB — identical to the digit** to both the 128
         and 256 runs, which is the control confirming one chunk is one chunk.
       - ⚠️ Also not upstreamable as that line claimed: the slot default is
         iOS-only by design, and the `auto` policy lives in the iOS app rather
         than in shared code. Nothing here is a platform-neutral change.
   - **Prefill chunk cap 256 → 1024 on iOS — DONE 2026-09-22 (`78ac25d`).** The
     0.0% prefill hit rate that stood as an open item since step 0 is
     **structural and cannot be fixed**: chunks loop outside layers, and within a
     chunk `PrefillMoEGrouping` already coalesces the token×top-8 pairs to one
     read per distinct expert, so no repeat request exists for a cache to hit.
     At the floor — one chunk covering the prompt — every expert is read once and
     the hit rate is *still* 0.0%. The metric is prefill bytes, and it moved:
     **−70.6% long** (104,248.91 → 30,605.86 MiB) and **−42.1% medium**, with
     short unchanged by construction. Token counts identical.
     - **Medium reached the floor.** `auto` gives a 430-token prompt 512, one
       chunk, 92.4 of 128 experts per layer read once. No further cap raise can
       help a prompt of ≤512 tokens. Long is not at its floor — 32.09 GB against
       ~12.1 — but taking it needs cap 4096, ~377 MB of scratch, and its own
       prediction.
     - ⚠️ **The time prediction missed and its falsifier fired on one run of
       two.** Predicted −35 to −42%, measured −24.6% hot and −36.9% cooled, mean
       −30.9%, against a tight 120/121 s baseline. **The 19% spread between two
       byte-identical treatment runs is the lesson**: prefill bytes are
       deterministic on this device, prefill time is not.
     - ⚠️ **The cap costs +152.4 MB of KV ring unconditionally**, because
       `RealForwardRunner` sizes the ring from the static cap rather than the
       configured chunk. Hence platform-split, with macOS on 256.
       `KVRingChunkCapTests` pins it, filed under `Runtime/Configuration` because
       that is the directory the iOS test bundle compiles.
     - ⚠️ **An unrelated regression surfaced and is logged, not claimed:** decode
       is 7.8–13.2% slower than the 2026-09-16 rows at identical byte profiles,
       with long-case `io` +15.9% at constant bytes. Artifact aging (6 days vs
       0 h) and the 0.8 merge are both candidates and are unseparated at n=1.
       See the second 2026-09-22 row in `MEASUREMENTS.md`.
   - Routing locality, prefetch, router lookahead.
   - Disk layout, expert co-location, read coalescing.
   - **Attention over long context**, which is not a bytes lever at all but is
     29–35% of a forward and growing with prompt length. Listed here because it
     is quality-neutral and because ignoring it means the port optimizes two
     thirds of a forward and calls it done.
3. **Quality-spending levers** — only once 2 is exhausted: expert quantization,
   top-K reduction, layer-selective routing, smaller variant.
4. **Floor / kill criterion**, if wanted, set here against measured numbers.

Every item follows the existing working agreement: predicted bytes/token delta,
mechanism, and falsification condition stated *before* implementation, measured
delta recorded in `MEASUREMENTS.md` afterward — including when the prediction
missed.

### The rule that keeps the split honest

**Any quality spend is a recorded decision, including one forced by the memory
ceiling.** The failure mode of a two-track plan is Track B's costs leaking
silently into Track A — you shrink something to fit under jetsam and never write
down that you paid for it.

## What is deliberately not decided

- ~~**Target device.**~~ **Decided 2026-09-15: iPhone 17.** See
  [Target device](#target-device).
- **Target tok/s.** Deliberately absent: faster is better, and each change is
  judged on its measured gain. (The reason once given here, that tok/s is just
  bytes/token ÷ bandwidth, was wrong: GPU work and the CPU/GPU handoff are ~30%
  of a forward on the phone.) The 0.5 tok/s floor was a feasibility threshold,
  long since passed.
- **Quality budget.** Not needed until Track B step 3. Steps 0–2 cost no
  accuracy.

## Repository layout

This repo is a **separate repository**, not a GitHub fork, derived from
`drumih/turbo-fieldfare` (Apache-2.0). History is shared with upstream
deliberately — that is the expensive thing to reverse, and keeping it preserves
two options at no cost.

| Remote | Points at | Use |
| --- | --- | --- |
| `origin` | `maxslamdunk/localita` (private; `turbo-fieldfare-ios` until 2026-10-17) | Everything. |
| `upstream` | `drumih/turbo-fieldfare` | Fetch only; push URL is set to `DISABLED`. |

- `git fetch upstream && git merge upstream/main` pulls upstream work in for
  free. Upstream is live, so this matters.
- Contributing something back stays a `git cherry-pick` rather than a
  re-implementation. Create a GitHub fork at the moment a PR is actually wanted —
  forking later is free *because* history is shared.
- `main` tracks `origin/main`. `upstream/main` is the pristine reference, which
  is why no "keep it as is" branch exists.
- Branch by **upstreamability**, not by track. Track A/B is work sequencing.
  Anything platform-neutral — instrumentation, and most of Track B step 2, which
  lowers bytes/token on the Mac too — belongs on a topic branch off `main`, not
  stranded on an iOS branch. Only the genuinely platform-specific delta
  (`Package.swift` platforms, app target, jetsam handling, on-device delivery,
  no-AppKit paths) is iOS-only.
  - **Worked example, 2026-09-17 — the app-layer split.**
    `TurboFieldfareMacInference` takes the `Process`-using socket client out of
    `TurboFieldfareAppCore` (step 2 above), and `TurboFieldfareAppPresentation`
    takes the 18 AppKit-free presentation files out of
    `TurboFieldfareMacPresentation` — streamed-markdown block splitting, fence
    and math span detection, transcript sync planning, formatting policy. Both
    are platform-neutral, leave the Mac app's behaviour unchanged, and were
    recorded by git as renames, which is what keeps them cherry-pickable rather
    than stranded. Consequence worth stating plainly: an iOS chat UI is a **view
    layer against `AppModel`**, not a second application, because the state,
    persistence and formatting layers are now shared and the inference seam's
    default client is already the in-process one. ⚠️ Nothing about that UI is on
    this plan yet, and two things would gate it if it were — reopening a
    conversation replays its history through prefill, which the long case
    measures at 168 s, and the KV budget at 8K context is still open from step 1.

### Coordination hazard

The quality-spending levers — expert quantization in particular — change
`TurboFieldfareFormat`, which the installer, verifier, and runtime all validate
against. That is a `.gturbo` v2 contract, not a local edit, and it makes later
upstream merges harder. Weigh that cost; it is not by itself a reason not to do it.

### Probes are not in this repo

The measured SSD-bandwidth row came from a standalone probe with the model
untouched. The jetsam and device-bandwidth probes follow the same pattern: a
throwaway Xcode project, no branch and no changes here. This also keeps clear of
`AGENTS.md` on worktrees and model duplication, and of the one-model-process
memory invariant.

## Related

- `CLAUDE.md` — the goal, measured facts, working agreements.
- `MEASUREMENTS.md` — append-only run log. iOS rows go here, kept separate from
  Mac rows; they are not comparable.
- `docs/EXTERNAL_PRIOR_ART.md` — currently a stub. Nothing on iOS recorded yet.
- `docs/experiments/summaries/03-expert-cache-prediction-and-layout.md` — read
  before Track B step 2.
- `docs/experiments/summaries/09-validation-and-measurement-lessons.md` — read
  before Track B step 0.
