# App Store Connect: what to enter

The text and answers for Localita's TestFlight and App Store pages. Copy them
into App Store Connect, and change them here first when they change, so the
listing, the app and the privacy policy keep saying the same thing.

The privacy answers must agree with `iOS/TurboFieldfareiOS/PrivacyInfo.xcprivacy`
and the policy at <https://localita.maxslamdunk.workers.dev/privacy>
(`server/benchmark-worker/src/privacy.ts`).

## The app record

| Field | Value |
| --- | --- |
| Platform | iOS |
| Name | Localita |
| Primary language | English (U.S.) |
| Bundle ID | `io.github.maxslamdunk.Localita` |
| SKU | `localita-ios` (internal, never shown) |
| User access | Full access |

## TestFlight

These are needed before external testers can join, and they go to Beta App
Review. Internal testers need none of them.

**Beta App Description**

> Localita runs Google's Gemma 4 26B-A4B, a 26-billion-parameter AI model,
> entirely on your iPhone. Chats and photos never leave the phone, and once
> the model is downloaded the app works offline.
>
> It needs an iPhone with 8 GB of memory (iPhone 15 Pro or later) and about
> 16 GB of free storage. The model is a one-time download of about 15 GB.

**Feedback Email:** maximvoronin8@gmail.com

**Privacy Policy URL:** <https://localita.maxslamdunk.workers.dev/privacy>

**Marketing URL:** leave empty until the repository is public, then
<https://github.com/maxslamdunk/localita>.

**What to Test** (first build)

> Thanks for trying Localita. Please try:
>
> - The download: about 15 GB, on Wi-Fi. Leave the app and come back; it
>   should keep going and resume if it stops.
> - Chatting, including long replies and a photo (after installing image
>   support in Settings → Models).
> - Switching apps mid-reply: the reply should continue in a small Picture in
>   Picture window.
> - Settings → Models → Benchmark, if you have 15 minutes with the phone on a
>   table. Sending the result is optional.
>
> If the app closes by itself, please say what you were doing and which
> iPhone you have.

**Notes for the reviewer** (Beta App Review Information, and later App Review)

> Localita is an offline chat app. The AI model runs on the device.
>
> On first launch the app downloads the model from Hugging Face, a one-time
> download of about 15 GB, about 20 minutes at 100 Mbit/s. It
> needs an iPhone with 8 GB of memory (iPhone 15 Pro, iPhone 16 or iPhone 17
> families) and about 16 GB of free storage. The increased-memory-limit
> entitlement is needed because the model's resident weights and cache take
> about 3.3 GB.
>
> No account or sign-in is needed. The only data that can leave the phone is
> an optional benchmark result (speed and memory figures, no chat text), sent
> only when the user taps Send after seeing it.
>
> The model weights are data read by the app's own Metal code. The app does
> not download or run executable code.

Sign-in required: no. Contact details: your name, phone number and email, which
only Apple sees.

## The App Store page

| Field | Limit | Value |
| --- | --- | --- |
| Subtitle | 30 | Offline AI chat on your iPhone |
| Primary category | | Productivity |
| Secondary category | | Utilities |
| Price | | Free |
| Copyright | | 2026 Maxim Voronin |
| Support URL | | The repository once public, or a support page on the Worker. It must load for the reviewer, so not the private repository. |
| Keywords | 100 | `offline,private,local,llm,ai chat,chatbot,on-device,no internet,assistant,ai model` |

Keywords leave out "Gemma" and "Google": Apple rejects other companies'
trademarks in keywords. The description may name the model, as below.

**Promotional text** (170, can change without a new build)

> A 26-billion-parameter AI model that runs entirely on your iPhone. No
> account, no cloud, no tracking.

**Description** (4,000)

> Localita is an offline AI chat app. It runs Google's Gemma 4 26B-A4B, a
> 26-billion-parameter model, on the iPhone itself. What you type and the
> photos you share never leave the phone, and once the model is downloaded
> the app works without a connection.
>
> PRIVATE BY DESIGN
> • Chats, photos and the model stay on your iPhone.
> • No account, no analytics, no tracking.
> • The only thing that can be sent is an optional benchmark result, and only
>   after you have seen exactly what it holds.
>
> WHAT IT DOES
> • Chat with Gemma 4. Replies render Markdown, code, tables and math.
> • Ask about photos, with an optional image pack of about 1.1 GB.
> • Keep a reply going when you switch apps, in a small Picture in Picture
>   window.
> • Install other builds of the same model from Hugging Face.
> • Adjust temperature, top-K and top-P.
> • Run the built-in benchmark to see how fast your iPhone runs the model.
>
> WHAT TO EXPECT
> Replies come at roughly reading pace, about four to five words a second
> on an iPhone 17. That is slower than a cloud chatbot, and it is the trade for
> keeping everything on the phone.
>
> REQUIREMENTS
> • An iPhone with 8 GB of memory: iPhone 15 Pro or later.
> • About 16 GB of free storage for the one-time download of about 15 GB.
>
> OPEN SOURCE
> Localita is open source under the Apache 2.0 license, and derived from
> TurboFieldfare by drumih. Gemma is a trademark of Google LLC. Localita is not
> affiliated with or endorsed by Google.

"Four to five words a second" is the README's 5.2–6.3 tokens/s
(`results/validation-results-2026-10-13-ios-in-app-benchmark/`) at about
0.75 English words per token. Change it if the numbers move. Drop the
"open source" paragraph if the repository is not public by submission.

**Screenshots:** App Store Connect wants the 6.9-inch iPhone size,
1320 × 2868, and scales it down for smaller phones. The iPhone 17 takes
1206 × 2622, the same shape within 0.1%, so its screenshots can be scaled up
to 1320 × 2868. The simulator cannot run the model.

## App Privacy

**Data collection:** Yes, the app collects data.

| Data type | Linked to the user | Used for tracking | Purpose |
| --- | --- | --- | --- |
| Diagnostics → Performance Data | No | No | App Functionality |
| Diagnostics → Other Diagnostic Data | No | No | App Functionality |

What a sent report holds: speed and memory figures per prompt, the run's
settings, the phone model, total memory, iOS and app versions, battery and
thermal state, and hashes of the prompts and outputs. It holds no chat text
and no identifier. The purpose is App Functionality rather than Analytics,
because Apple's definition of App Functionality includes improving
performance, and Analytics is about user behavior, which a report does not
contain.

The resulting label reads "Data Not Linked to You: Diagnostics".

## Other answers

- **Export compliance:** `ITSAppUsesNonExemptEncryption` is `NO` in the
  build, so App Store Connect does not ask. The app's only encryption is
  HTTPS through the system.
- **Age rating:** answer as a general-purpose chat model that can write about
  any topic. Expect a high rating; that is normal for open chat apps.
- **Availability:** leave out China mainland, where generative AI apps need a
  government licence.
- **EU Digital Services Act:** App Store Connect asks whether you are a
  trader. A trader's address and phone number are shown on the EU store page.
  A free, open-source app from an individual is usually not a trader, but this
  is your call.
- **Content rights:** the app downloads third-party content (the model).
  Gemma 4 is Apache 2.0; see `THIRD_PARTY_NOTICES.md`.
