# Localita

**A 26-billion-parameter AI model that runs entirely on your iPhone.**

Localita is an offline chat app for iPhone built around Google's
[Gemma 4 26B-A4B](https://ai.google.dev/gemma/docs/core/model_card_4). The
model runs on the phone itself. What you type and the photos you share never
leave it, and once the model is downloaded the app works without a connection.

<p>
  <img alt="iOS 26 or later" src="https://img.shields.io/badge/iOS-26%2B-000000?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="Metal" src="https://img.shields.io/badge/Metal-4-5E5CE6">
  <a href="LICENSE"><img alt="Apache 2.0 license" src="https://img.shields.io/badge/License-Apache%202.0-2ea44f"></a>
</p>

> **Status:** not yet on TestFlight or the App Store. For now you build it
> from source (see [Build it](#build-it)). It has been developed and tested on
> one phone, an iPhone 17.

<p align="center">
  <img src="docs/assets/localita-chat.png" alt="A chat in Localita: Gemma 4 explains pointwise and uniform convergence, with rendered math" width="250">
  <img src="docs/assets/localita-history.png" alt="The chat list, opened from the side, with the Localita logo, a search button and past conversations" width="250">
  <img src="docs/assets/localita-models.png" alt="The Models screen: Gemma 4, SuperGemma 4 and a community QAT build, with image support installed" width="250">
</p>

## What it does

- **Chat with Gemma 4**, with your conversations kept on the phone. Replies
  render Markdown, code, tables and math.
- **Ask about photos.** An optional image pack (about 1.1 GB) lets the model
  read pictures you attach.
- **Keeps going when you switch apps.** Leave mid-reply and it continues in a
  small Picture in Picture window. Locking the phone pauses it, and it resumes
  when you unlock. You can turn this off in Settings.
- **One download, about 15 GB.** It uses Wi-Fi unless you allow mobile data,
  continues in the background, and resumes if it stops.
- **Other Gemma 4 26B-A4B builds.** Besides Google's model, you can install
  SuperGemma 4 (a community edit) or paste a Hugging Face link to another
  build with the same layout, such as the QAT and LM Studio versions. The app
  checks the layout before downloading and pins the exact revision it checked.
- **Sampling controls:** temperature, top-K and top-P.
- **A built-in benchmark** that runs three standard prompts and keeps the
  results on the phone. You can send a result to the project with one tap,
  after seeing exactly what will be sent (see [Privacy](#privacy)).

## How fast is it

Measured on an iPhone 17 (8 GB) with iOS 26.6, using the app's own benchmark
at default settings, on 2026-10-13, with the phone cool (`nominal`) on every
case. Source: [`results/validation-results-2026-10-13-ios-in-app-benchmark/`](results/validation-results-2026-10-13-ios-in-app-benchmark/results.md),
second run.

| Prompt | Prompt length | Reply speed | Time before the reply starts | App memory, peak |
| --- | --- | --- | --- | --- |
| Short question | 61 tokens | 6.3 tokens/s | 11.5 s | 3.1 GB |
| Medium review | 430 tokens | 5.6 tokens/s | 11.5 s | 3.2 GB |
| Long synthesis | 3,015 tokens | 5.2 tokens/s | 68 s | 3.4 GB |

That is roughly reading pace: slower than a cloud chatbot, and that's the
trade. Expect about 8% variation between runs of the same prompt. When the
phone gets hot, iOS slows it by about 12%. Every run the project has
recorded is in [`MEASUREMENTS.md`](MEASUREMENTS.md).

## How it fits on a phone

Gemma 4 26B-A4B is a mixture-of-experts model. It has 26 billion parameters,
but each token uses only about 3.9 billion of them: in each of its 30 layers,
a router picks 8 of 128 "experts". The whole model is about 14.3 GB, which
does not fit in the memory an iPhone gives an app.

So Localita keeps only the parts every token needs in memory, about 1.35 GB
of shared weights plus the conversation's attention cache, and reads the
experts each token picks from storage as it goes. A cache of recently used
experts in each layer catches about three quarters of them. While storage
would otherwise sit idle, the app reads ahead the expert it predicts the next
layer will want. Reading experts is still the largest part of each token, a
bit over half of it.

The runtime is written for this one model in Swift and Metal, with its own GPU
kernels. It does not use MLX or llama.cpp. For the details:

- [`docs/HOW_IT_WORKS.md`](docs/HOW_IT_WORKS.md): how the engine works, in
  plain terms, with the numbers.
- [`docs/SYSTEM_DESIGN.md`](docs/SYSTEM_DESIGN.md): how the runtime works,
  with a code map.
- [`docs/IOS_PORT.md`](docs/IOS_PORT.md): how it was brought to the iPhone,
  and what was tried along the way.
- [`docs/experiments/summaries/`](docs/experiments/summaries/): optimizations
  tried, kept or dropped, and why.

## What this project adds

Localita is built on [TurboFieldfare](https://github.com/drumih/turbo-fieldfare)
by drumih, which runs this model on 8 GB Macs. The engine is upstream's: the
idea of streaming experts from storage, the model format, the installer and
the Metal kernels. This repository, by Maxim Voronin, brought it to the
iPhone and made it faster there:

- **The port.** Probes on the phone measured what Apple does not publish:
  where iOS kills the app (from 5.60 GB with the increased-memory-limit
  entitlement), how fast its storage reads experts (1.650 GB/s, one read at a
  time), and whether the kernels hold on the iPhone's newer GPU (179 tests
  pass). The first run on the phone was already 17–23% faster than the 8 GB
  M1 Mac.
- **42–47% faster since that first run**, from 4.4 to 6.3 tokens/s on the
  short prompt. The largest gains are new here:
  - an early read that guesses the expert the next layer will need and reads
    it while storage is idle (+17–20%);
  - expert-cache counts that age across chats (+23% over a session of 11
    prompts);
  - expert-slot and prefill settings chosen for the phone.

  Each change was predicted before it was measured, and checked to leave the
  generated text byte-identical.
- **The iPhone app.** Chat, replies that continue in Picture in Picture when
  you leave the app, the 15 GB model download, community model builds, image
  input on the phone, and the benchmark.
- **The early read, offered back upstream** as two pull requests. On an 8 GB
  M1 MacBook Air it is worth 21–25%.

[`docs/WHAT_LOCALITA_ADDS.md`](docs/WHAT_LOCALITA_ADDS.md) has the full
account, with the source of every number.

## Privacy

Chats, photos and the model stay on the phone. The app has no accounts, no
analytics and no automatic telemetry.

The one thing that can leave the phone is a benchmark result, and only when
you tap **Send** on its result screen, after the app shows you the exact data.
A result holds speed and memory figures, the settings the run used, the
phone model, the iOS version, and the battery and thermal state. It holds no
chat text and nothing that identifies you. Accepted results are
published in this repository so anyone can compare how iPhones run the model.
The full policy is at
[localita.maxslamdunk.workers.dev/privacy](https://localita.maxslamdunk.workers.dev/privacy).

## Build it

You need:

- A Mac with Xcode 26.
- An iPhone with **8 GB of memory** on iOS 26. Only the iPhone 17 has been
  tested. Phones with less memory are untested.
- About 16 GB of free space on the phone. The app shows the exact figure
  before it downloads.
- An Apple Account for signing. A free one works, but the app then stops
  launching after 7 days until you build and install it again.

Steps:

1. Open `iOS/TurboFieldfareiOS.xcodeproj` in Xcode.
2. Under **Signing & Capabilities**, choose your own team, and change the
   bundle identifier to one of your own. Keep the **Increased Memory Limit**
   capability: without it, iOS gives the app too little memory to run the
   model.
3. Select your iPhone and run the `TurboFieldfareiOS` scheme with the
   **Release** configuration, which is what every number here was measured
   with.
4. In the app, download Gemma 4.

When you install a new build later, install it over the existing app. If you
delete the app, the downloaded model goes with it.

The code still uses the upstream project's name, TurboFieldfare, for its
modules and targets. This keeps merges from upstream simple.

## The Mac side

This repository also builds upstream's macOS app, command-line tool and
loopback OpenAI-compatible server, which share the runtime with the iPhone
app. They serve as the development and reference host here. See
[upstream's README](docs/UPSTREAM_README.md) for how to use them, and
[`AGENTS.md`](AGENTS.md) for how the project is developed and measured.

```bash
swift build -c release
Scripts/test.sh
```

## Credits and license

Localita is derived from
[**TurboFieldfare**](https://github.com/drumih/turbo-fieldfare) by
[drumih](https://github.com/drumih), the Swift and Metal runtime that runs
Gemma 4 26B-A4B on 8 GB Macs by streaming its experts from storage. This
repository keeps its history and continues to merge from it. The iPhone app,
the port and the work measured here are new (see
[What this project adds](#what-this-project-adds)).

The source is licensed under the [Apache License 2.0](LICENSE), like
upstream's. The model weights are not part of this repository. The app
downloads them from Hugging Face. Google publishes Gemma 4 under Apache 2.0.
Community builds carry their own terms. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the models and the
Swift packages.

Localita is not affiliated with or endorsed by Google. Gemma is a trademark of
Google LLC.
