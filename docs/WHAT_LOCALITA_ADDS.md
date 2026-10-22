# What Localita adds to TurboFieldfare

Localita is built on [TurboFieldfare](https://github.com/drumih/turbo-fieldfare)
by [drumih](https://github.com/drumih), and keeps its history. This page says
what came from there and what this repository added on top, so that credit
goes to the right place.

The work here began on 2026-08-10.

## What upstream built

TurboFieldfare is a Swift and Metal runtime that runs Gemma 4 26B-A4B on 8 GB
Macs. Everything that makes the model run at all is upstream's:

- the idea of keeping the shared weights in memory and streaming the routed
  experts from storage, with a cache of expert slots per layer;
- the `.gturbo` model format, and the installer that repacks a Hugging Face
  checkpoint into it without re-quantizing;
- the Metal kernels for decode and prefill, and the CPU reference they are
  tested against;
- the decode loop, its `cb1` / `io` / `cb2` handoff, and chunked prefill;
- image input;
- the macOS app, the command-line tool and the OpenAI-compatible server.

[`HOW_IT_WORKS.md`](HOW_IT_WORKS.md) explains how these fit together.

## What this repository adds

In short: the iPhone app, the port that makes the runtime work on a phone,
the changes that make it faster there, and the measurements behind each of
them.

| | First run on the phone, 2026-09-16 | In the app, 2026-10-13 |
| --- | --- | --- |
| Short prompt | 4.395 tokens/s | 6.285 tokens/s |
| Medium prompt | 3.961 tokens/s | 5.608 tokens/s |
| Long prompt | 3.571 tokens/s | 5.238 tokens/s |

That is +43%, +42% and +47%, on the same iPhone 17 and the same three
prompts. The first run is the 2026-09-16 `real-generation-v1` row in
[`MEASUREMENTS.md`](../MEASUREMENTS.md). The second is from
[`results/validation-results-2026-10-13-ios-in-app-benchmark/`](../results/validation-results-2026-10-13-ios-in-app-benchmark/results.md),
second run. Each is a single run, and runs of the same work vary by about 8%.

### 1. The port to the iPhone

Upstream ran on Macs only. Getting it onto a phone meant finding out what the
phone allows, since Apple publishes none of the numbers that matter:

- **The memory limit.** A probe app found where iOS kills the app: 3.53 GB
  without the increased-memory-limit entitlement and from 5.60 GB with it.
  The system's own report of available memory overstates the entitled limit by
  841 MB, so the budget is set from the measured kill point. Memory-mapped
  read-only weights turned out to be nearly free against the limit (about
  16.6 MB of footprint for 1.26 GiB), which is what leaves room for the expert
  cache.
- **Storage.** A probe measured random reads at the expert size: 1.650 GB/s,
  one read at a time. Reads issued together slow each other down rather than
  adding up, which later shaped the early read.
- **The GPU.** The iPhone 17's GPU is a newer family (Apple10) than the M1's
  (Apple7). The kernel test suites were made to run on the phone, and pass
  there: 179 tests, with the same worst-case error as on the Mac.
- **The defaults.** The phone gets its own expert-slot count and prefill
  chunk size, chosen by measurement (below).

The first full run on the phone was already faster than the 8 GB M1 Mac on
every prompt, by 17–23%, and the GPU was the reason: storage ran at the same
speed on both.

[`IOS_PORT.md`](IOS_PORT.md) is the port's plan and its full history.

### 2. Making it faster on the phone

Each change below was predicted before it was measured, A/B-tested on the
phone, and checked for identical generated text where the math should not
change. Gains are each against the defaults of their day, so they do not
multiply out.

| Change | Origin | Effect on the iPhone 17 | Source |
| --- | --- | --- | --- |
| **Early expert read.** Guess the next layer's likeliest missing expert and read it while storage is idle, with a guess refitted offline on recorded routing | New here | +17–20% tokens/s at +11–18% bytes per token; identical text | [`…-10-02-ios-next-layer-prefetch`](../results/benchmark-results-2026-10-02-ios-next-layer-prefetch/results.md), [`…-10-03-ios-fitted-guess`](../results/benchmark-results-2026-10-03-ios-fitted-guess/results.md) |
| **Cache count aging.** Expert-use counts decay, so a long app session doesn't keep experts that were popular three chats ago | New here | +23.1% tokens/s over a session of 11 prompts on one loaded model; identical text | [`…-10-03-ios-expert-cache-aging`](../results/benchmark-results-2026-10-03-ios-expert-cache-aging/) |
| **Expert reads skip the OS file cache** (`F_NOCACHE`) | New here | +4 to +8% tokens/s at identical bytes | [`…-10-03-ios-expert-read-nocache`](../results/benchmark-results-2026-10-03-ios-expert-read-nocache/) |
| **24 expert slots per layer** on iOS, against 16 on the Mac | New here | Short prompt 4.40 → 6.03 tokens/s, hit rate 67.7% → about 79%, for about 0.8 GB | [`…-09-16-ios-slots`](../results/benchmark-results-2026-09-16-ios-slots/), [`…-09-24-ios-vision-memory`](../results/benchmark-results-2026-09-24-ios-vision-memory/) |
| **1,024-token prefill chunks** on iOS, against 256 | New here | Long-prompt prefill reads −70.6%, medium −42.1% | [`…-09-22-ios-prefill-chunk`](../results/benchmark-results-2026-09-22-ios-prefill-chunk/) |
| **Grouped full attention** | Upstream (#182), measured here | Long prompt +6.7% tokens/s; bit-identical text | [`…-10-01-grouped-attention`](../results/benchmark-results-2026-10-01-grouped-attention/) |

The early read helps the Mac too. On the 8 GB M1 MacBook Air it is worth
+24.0%, +24.7% and +21.0% at its default of one read per layer, and four more
Macs run by other people showed gains in the same direction
([`…-10-07-early-read-v3`](../results/benchmark-results-2026-10-07-early-read-v3/results.md)).

Some ideas lost, and are kept on record as well. Two early reads per layer are
faster on the Mac but 15–26% slower on the phone, because one read already
fills the phone's idle storage time
([`…-10-08-ios-early-read-x2`](../results/benchmark-results-2026-10-08-ios-early-read-x2/results.md)).
32 expert slots were faster than 24 but left the phone too little memory for
the system photo picker.

### 3. Measuring it

Speed work needs to know where the time goes. These instruments were added
to the runtime and print on every run, on the Mac and in the iOS app alike:

- **Bytes per token and expert-cache hit rate** (`[expert-io …]`), exact
  counters that catch a change doing something other than intended.
- **The time of each decode phase** (`[phase-time …]`), covering about 98% of
  a token.
- **GPU timestamps for each command buffer** (`[gpu-time …]`), which showed
  the GPU idle for more than half of each token.
- **The latency of each storage read** (`[read-latency …]`).
- **Routing traces**, which the early read's guess was fitted on.

The project also has its own measurement rules ([`AGENTS.md`](../AGENTS.md)):
write the prediction before the run that scores it, run A B B A with
cooldowns, record thermal state, and keep the wrong predictions too. The run
log, [`MEASUREMENTS.md`](../MEASUREMENTS.md), has 339 entries, 101 of them on
the iPhone, and [`results/`](../results/) has 34 experiment folders.

Before the port, the same approach was used on the Mac's storage. It found
that the runtime already read at 94–96% of what the installed files allowed,
not at half as first thought, and that the order the installer writes the
files in sets their read speed for good (IO-11, IO-12 and IO-13 in
[`experiments/summaries/01-model-install-and-expert-io.md`](experiments/summaries/01-model-install-and-expert-io.md)).

### 4. The iPhone app

The iOS app is new: about 10,000 lines of Swift in [`iOS/`](../iOS/). Parts of
upstream's Mac app code, such as Markdown and math rendering, moved into
shared modules so both apps use them.

- **Chat** with Markdown, code, tables and math, rendered as the reply
  streams, without flicker from half-written syntax. The model's reasoning
  is shown apart from its answer.
- **Picture in Picture while in the background.** iOS refuses GPU work from an
  app in the background, unless it is showing Picture in Picture. The app
  uses that: leave mid-reply and it continues in a small window. This was
  established with probes on the phone first
  ([`…-10-09-ios-background-probes`](../results/validation-results-2026-10-09-ios-background-probes/)).
- **Installing a 15 GB model on a phone:** a background download that
  survives leaving the app, resumes if it stops, and shows the space it needs
  before it starts.
- **Other builds of the model.** Paste a Hugging Face link and the app reads
  the checkpoint's layout before downloading anything. It accepts only builds
  the runtime can run as-is, including ones with an 8-bit shared expert, and
  pins the exact revision it checked.
- **Image input** as an optional 1.1 GB pack, run on the phone.
- **A built-in benchmark** that runs the project's three standard prompts.
  Sending a result is one tap, after the app shows exactly what will be sent.
  Results go to a small Cloudflare Worker ([`server/benchmark-worker/`](../server/benchmark-worker/))
  and are published in [`benchmark-submissions/`](../benchmark-submissions/).
- **Settings** for sampling and the engine's speed controls, a welcome screen,
  acknowledgements, and a privacy policy.

### 5. Offered back upstream

The early read is offered to upstream as two pull requests, with benchmark
results from five Macs:

- [drumih/turbo-fieldfare#187](https://github.com/drumih/turbo-fieldfare/pull/187):
  read the next layer's likeliest expert while storage is idle.
- [drumih/turbo-fieldfare#188](https://github.com/drumih/turbo-fieldfare/pull/188):
  score it with the fitted guess, and read two experts per layer on the Mac.

## By the numbers

Against upstream at the last merge (`77e8f9c`, 2026-09-27):

| | Lines added |
| --- | ---: |
| iOS app (`iOS/`) | 9,995 |
| Shared runtime and app code (`Sources/`) | 5,901 (515 removed) |
| Tests (`Tests/`) | 4,411 |
| Benchmark Worker (`server/`) | 2,496 |

216 commits, plus the records: [`MEASUREMENTS.md`](../MEASUREMENTS.md),
[`results/`](../results/), and the project's own entries in
[`experiments/summaries/`](experiments/summaries/).
