# Runtime controls

> **Current, macOS runtime.** This is the authoritative list of controls the Mac
> app, CLI, and local server expose. It is not a closed set — the iOS port will
> add controls (expert-cache sizing against the device memory ceiling, jetsam
> policy); document them here when it does.

The Mac app, CLI, and local server expose generation and runtime controls. The
app keeps them in its fixed right settings pane. FP16 is the fixed KV format.
Generation settings apply to the next turn or request; app load-time settings
require a reload.

## Generation controls

The Mac app and CLI expose these generation controls. The iOS app exposes
temperature, Top-K, Top-P and maximum context in its Settings sheet, with the
same ranges except where a row says otherwise.

| Control | Mac values | CLI flag | Default | Effect |
| --- | --- | --- | --- | --- |
| Maximum response | Automatic | `--max-new` | App: remaining context; CLI: 1,024 tokens | The app can use the context space left after the retained conversation and new turn. The CLI uses its explicit or default `--max-new` limit. |
| Maximum context | 4K, 8K, 16K, 32K, 64K, 128K, 256K, depending on your Mac's RAM and cache settings; **iOS: 4K, 8K** | `--max-context` | CLI and app: 8K; server: 16K | ⚠️ **iOS stops at 8K (2026-09-24).** 16K at 32 slots was killed once for `proc-thrashing` at 4.44 GB and completed once, in the same memory state, so it is not offered. KV pages are committed lazily, so the setting is a ceiling and only tokens held cost memory (`benchmark-results-2026-09-24-ios-context/`). Sets the combined capacity for the prompt or conversation and the response. The app shows how much FP16 KV-cache memory each size adds. The server defaults to 16K because agent clients routinely send prompts near 8K. |
| Temperature | 0...2 in 0.05 steps | `--temperature` | 0.2 | `0` is greedy; positive values sample. |
| Top-K | Off or 1...256 | `--top-k` | 64 | Keeps at most K candidates. CLI `0` turns it off. |
| Top-P | Off or 0.01...1 | `--top-p` | 0.95 | Applies nucleus truncation before Top-K and is effective only while Top-K is enabled. |
| Reasoning | Not exposed on macOS; iOS has a status-bar toggle | *(no flag)* | Off | Whether the model reasons on a thought channel before answering. iOS draws that reasoning in grey above the reply as it streams. ⚠️ **The mechanism runs backwards from the obvious reading:** with reasoning *off* the generation prompt ends with an already-closed empty thought block (`<\|channel>thought\n<channel\|>`), which is what makes the model skip to the answer — so enabling it *removes* that suffix and adds a `<\|think\|>` marker to the first system turn. Applies to the next turn and needs no model reload, since it changes only the prompt's tokens. **It costs real latency:** reasoning tokens decode at the same rate as answer tokens, so on a device at single-digit tok/s they are seconds of wait before the first visible word. |

With positive temperature, a CLI Top-P below `1` requires Top-K between `1`
and `256`. To disable both truncation controls, pass `--top-k 0 --top-p 1`.
Generation controls apply to the next request and do not require a model
reload. They are interactive product settings, not the fixed community
benchmark protocol.

## Runtime settings

The CLI and the [local server](OPENAI_SERVER.md) accept these flags with the
same names and values. Their defaults agree except for `--max-context`, which
the server defaults to 16,384 rather than 8,192. The server resolves them before it loads the
model, so an unsupported combination fails immediately with the usage text.

| Control | Mac values | CLI and server flag | Production default | Effect |
| --- | --- | --- | --- | --- |
| Expert-cache slots | 8, 16, 24, 32; **iOS Settings: 16, 24, 32** (the counts measured on the phone) | `--expert-cache-slots` | **16 on macOS, 24 on iOS** (32 on iOS until 2026-09-24) | More slots can retain more routed experts and reduce later reads, but values above 16 use more RAM. Chunked prefill requires at least 16 slots. ⚠️ **Slots are per layer**, so the cost is 30 × slots × 3,358,720 B: 16 → 32 is **+1.61 GB**, not a few tens of MB. The default differs by platform because that cost does. On the 8 GB macOS validation host [CACHE-03](experiments/summaries/03-expert-cache-prediction-and-layout.md#cache-03) measured 32 as *actively harmful* — the cache thrashed and decode collapsed to 1.578 tok/s. On the iPhone 17 the same setting measured **+59 / +56 / +34%** with hit rate rising 67.7/64.9/62.3% → 86.5/83.0/80.6% and bytes/token falling 48–58%, at a 3.77 GB peak footprint against a measured 5.60 GB jetsam ceiling; `io` falls monotonically as slots rise there, so the Mac's thrashing failure does not reproduce. Memory-funded speed, not a free win. ⚠️ **The iOS default is 24 since 2026-09-24.** At 32 the chat app rests at about 4.1 GB, and it was killed for `proc-thrashing` with the system photo picker open. At 24 it rests at about 3.3 GB, and the same text-and-two-photos session completed (`benchmark-results-2026-09-24-ios-vision-memory/`). 24 measured +37 / +28 / +21% over 16 on 2026-09-16, against +59 / +56 / +34% at 32. |
| Expert-cache policy | LFU | `--expert-cache-policy lfu\|lru` | LFU | Chooses which expert is evicted when the cache is full. |
| Prompt prefill | On, off | `--prefill on\|off` | On | On processes known prompt tokens through the chunked prefill path. Off disables that path. |
| Prefill chunk size | 128 | `--prefill-chunk-tokens 32\|64\|128\|256\|auto` on macOS; **iOS also offers 512 and 1024** | 128 on macOS; **the 1024 cap in the iOS chat app** (`ChatSession.prefillChunkTokens`, since `f25f390`); `auto` in the iOS benchmark harness | Sets the number of prompt tokens processed by each chunked-prefill step, and has no effect while prefill is off. Chunks loop outside layers, so each one re-reads that layer's routed experts: fewer, larger chunks read less. `auto` picks the smallest size that covers the prompt. On the server `auto` is the cap, 256: a per-request size is the smallest allowed size covering the span, so the cap prefills every prompt in exactly those spans, and the KV ring is sized from the cap either way. Only the prefill scratch is sized from the chunk, at about 125.5 KB per token over a fixed 328 KB, so the cap holds about 32.5 MB of it against 16.4 MB at 128, and a per-request size would reallocate it whenever the chosen size moved. On a 7,019-token prompt, 256 measured 16% faster than 128 with byte-identical output. ⚠️ **The shared `RuntimeConfiguration` default is still 128 on every platform** — the iOS benchmark harness leaves the size unset and resolves `auto` once the prompt is tokenized, because `auto` depends on prompt length and so cannot be expressed as a fixed default. The iOS chat app cannot do that, since `RealInferenceSession.run` reads the prefill config before tokenizing, so it pins the cap instead. The cap is a ceiling, so a prompt shorter than one chunk still runs as one chunk and reads the same bytes. On the iPhone 17, 256 over 128 measured prefill bytes −39.6% (medium) and −43.2% (long), prefill time −31.9% / −32.3%, and long-case wall 313.4 → 243.3 s. ⚠️ Chunk count is the dominant term but **not the only one**: per-chunk read volume also grows with chunk size (6,341 → 7,659 MiB/chunk on the medium case), so doubling the size does not halve the bytes, and assuming it does over-predicts the saving by 6–10 points. ⚠️ **The cap is platform-split as of 2026-09-22: 256 on macOS, 1024 on iOS** (`PrefillRuntimeConfig.maxChunkTokens`). Raising it is not free and the cost is **unconditional** — `RealForwardRunner` sizes the KV ring from the static cap, not from the chunk a run selects, so every run on the platform pays it, including decode-only ones and ones that never ask for a large chunk. At 1024 that is **+152.4 MB of ring** (`swaCapacity` goes 1,304 → 2,048 tokens across the 25 sliding-window layers at 4,096 B/token for K and V each) plus **+94.1 MB of scratch** when such a chunk is actually selected, so **+246.5 MB** in total. The phone has the headroom — ~14% of the 1.79 GB between a measured 3.81 GB peak and the 5.60 GB jetsam floor — and the 8 GB macOS validation host does not, which is the whole reason for the split. `KVRingChunkCapTests` pins those bytes; it lives in `Tests/.../Runtime/Configuration/` because that is the directory the iOS test bundle compiles, so the iOS branch actually runs. **Measured on device 2026-09-22** (`benchmark-results-2026-09-22-ios-prefill-chunk/`): prefill bytes **−70.6% on the long case** (104,248.91 → 30,605.86 MiB) and **−42.1% on medium** (15,317.34 → 8,875.86), unchanged on short because `auto` resolves a 61-token prompt to 64 either side of the change. Token counts identical, so quality-neutral. Prefill *time* fell 24.6–36.9% across two treatment runs against a 120–121 s baseline — the predicted −35 to −42% missed on the mean (−30.9%), and the spread between two byte-identical runs tracks thermal, so quote the bytes and treat the time as noisy. **Medium now runs in one chunk**, the floor, so no further cap raise can help a prompt of ≤512 tokens. |
| RDADVISE | Off, Default, Bounded, Adaptive | `--rdadvise off\|default\|bounded\|adaptive` | Off | Applies experimental read advice. Its effect depends on the workload; it may help a short decode and slow a long one. |
| Early expert read | On, off | *(no flag)*; environment `TURBO_FIELDFARE_EARLY_EXPERT_READ=off\|next-layer`, and `TURBO_FIELDFARE_EARLY_EXPERT_GUESS=router\|<file>`. iOS harness: `--no-early-expert-read`, `--early-expert-read`, `--early-expert-guess router\|<file in Documents>` | **On, both platforms, since 2026-10-03** (`RuntimeConfiguration.earlyExpertRead`) | Per layer, guesses one expert the next layer will miss and reads it while storage would otherwise sit idle, into a separate staging buffer. When the next layer does miss it, that read is skipped. **Output is byte-identical and hit rate unchanged either way.** The trade is bytes/token for time: wrong guesses are extra reads. On the iPhone 17 at 24 slots, against off: about **+17–20% tok/s for +11–18% bytes/token** (cross-session; `benchmark-results-2026-10-03-ios-fitted-guess/`). The guess comes from a fitted file shipped in the runtime's `NextLayerGuess/` resources, matched to the model by its manifest `sourceSnapshotHash`. Only gemma4 (`mlx-community/gemma-4-26b-a4b-it-4bit`) has one; other models, such as supergemma4, use the next layer's own router, which is right less often (0.55–0.61 against 0.68–0.75 on the phone); on gemma4 that router guess alone measured +12–15% tok/s. supergemma4 has not been measured with either. Costs one 3.36 MB staging buffer plus 11.1 MB of mapped file. Logs: the `[expert-io …]` line ends with `early decode reads/tok=… used/tok=…`, and the iOS harness's `runner-ready` line names the guess and its SHA-256. |

In the app, changing context length, expert-cache slots, or RDADVISE requires a
reload. Some sampling changes also require a reload because greedy and sampled
generation use different output-head paths. Prompt-prefill settings apply to
each turn and do not require a reload. A reload ends the retained KV lineage;
the app preserves the visible transcript and marks where the model's new
context begins. Each CLI invocation loads a new model process, so its selected
runtime settings apply immediately. The server fixes its runtime settings at
startup, so changing one means restarting the process;
`--prefill-chunk-tokens auto` resolves to the cap there — 256 on macOS, which
allocates about 32.5 MB of prefill scratch against about 16.4 MB at the 128
default. The server is macOS-only, so the larger iOS cap does not reach it.

### macOS interactivity mitigation

Before the first Metal device is created, TurboFieldfare defaults
`AGX_RELAX_CDM_CTXSTORE_TIMEOUT` to `1`. This relaxes an AGX context-store
deadline that can terminate a long prefill dispatch as
`kIOGPUCommandBufferCallbackErrorImpactingInteractivity` on macOS 26. It is a
mitigation, not a guarantee: failures have also been reported with the setting
enabled.

Export `AGX_RELAX_CDM_CTXSTORE_TIMEOUT=0` before launching TurboFieldfare to
restore stock driver behavior. An explicit environment value is never
overwritten. If a command buffer still fails, the error includes its prefill
phase label, Metal status, domain, code, and IOGPU diagnostic token without
including prompt or generated content.

## Image controls

Image input needs the companion pack installed beside the text model. Without
it, these controls have nothing to select.

| Control | Values | Default | Effect |
| --- | --- | --- | --- |
| Vision pack | directory | `<model>.vision.gturbo` beside the model | Where the companion pack is read from. If you pass a path that does not exist, the load fails. It does not fall back to serving text with the images missing. |
| Vision residency | `on-demand`, `keep-ready` | `on-demand` | `on-demand` releases the routed-expert streamers and their slot scratch before encoding, then recreates them for language prefill. `keep-ready` maps the tower during the load and leaves it mapped. Changing this requires a reload. |

The CLI takes `--vision-pack` and `--vision-residency`, plus `--image <path>`,
which is repeatable, and `--chat-prompt`. The server takes the first two.

A request whose images cannot fit the selected context is refused before any
pixel is decoded. The rejection reports the token cost, not the number of
images, because an image's cost scales with its dimensions.

## Run an experiment

1. Start from the 8K default context, 16 expert-cache slots, prefill on, and
   RDADVISE off.
2. Keep the prompt and generation controls fixed.
3. Record a baseline after a warmup.
4. Change one runtime control and reload the app model, or start a new CLI run.
5. Compare prompt prefill, request TTFT, decode rate, peak memory, and I/O per
   token over repeated runs.
6. Restore the production defaults when the experiment ends.

Use the [community benchmark protocol](COMMUNITY_BENCHMARKS.md) for a standard
production result. A run with changed runtime controls is experimental and must
name the changed setting.

## Read the results

- **Decode rate** measures generated tokens per second after prompt prefill.
- **Request TTFT** includes prompt or new-turn prefill and the wait for the first
  generated token.
- **Peak memory** in Last run is the highest decode-service memory observed
  during the request. The HUD shows the service's current memory instead of the
  much smaller foreground UI process.
- **I/O / token** reports routed-expert read time per generated token.
- **Expert bytes / token** reports routed-expert bytes actually read from disk
  per generated token — the binding constraint. It counts real `pread` traffic
  and is live under production defaults, unlike the RDADVISE data figure, which
  is zero whenever RDADVISE is off.
- **Expert cache hit rate** is the share of routed-expert requests served from a
  resident slot over the decode window, across all layers. A hit is a read that
  did not happen, so it and the bytes figure are the same lever seen twice. An
  em dash means no routed-expert requests were observed.
- **Advanced** shows decode duration and per-token cb1, cb2, and output-head
  time, plus routed-expert requests and slot fills per token. When RDADVISE
  runs, it also shows time, calls, data, and skipped advice.

Both expert figures cover **decode only**; prefill reads are excluded. The CLI
reports the same counters, plus prefill totals, on its own footer line.

During chunked prefill, the phase label reports exact progress, for example
`Prefill (128/514)`. Errors and unsupported configurations appear only when
they occur. RDADVISE remains experimental and is off by default. A measured
result is a data point, not a performance ceiling.

## Context length and memory

Use the default context unless you need a longer conversation: 8K in the app
and CLI, or 16K in the server.

The model supports up to 256K tokens, but larger contexts need more RAM. The
KV cache is allocated when the model loads, even if the conversation is empty.
The server also offers 96K and 192K.

The memory check includes the KV cache, 2 GiB for the runtime with 16
expert-cache slots, and 3 GiB for macOS and the file cache. Choosing 24 or 32
slots adds about 0.75 or 1.50 GiB. On an 8 GB Mac, neither leaves enough room
for 128K under this estimate.

When a setting exceeds the estimate:

- The app hides it and lowers an incompatible saved setting, with a notice.
- The server refuses to load.
- The CLI warns but continues.

For diagnostic runs, `TURBO_FIELDFARE_ALLOW_UNBACKED_CONTEXT=1` bypasses the
server check.

Passing the check doesn't guarantee enough free memory: it uses total RAM,
and other apps need memory too. Answer quality at 256K and memory use at 128K
on an 8 GB Mac still need testing. See the
[long-context report](experiments/summaries/10-long-context.md).

The app allows up to 32 images per message. The remaining context may fit fewer.
