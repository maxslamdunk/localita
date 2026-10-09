# Background probes — results

iPhone 17 (A19, 8 GB), iOS 26.6, 2026-10-09. App Release at `0b316ea` plus
`BackgroundProbe.swift` and the Info.plist keys it needs (uncommitted when run),
installed over the app. Launched with `devicectl … --background-probe`
(run 1 also had `--probe-gpu --probe-ane`). The phone was driven by hand,
unplugged, battery 100 → 85%. Predictions in [`predictions.md`](predictions.md).

**Answer: a reply can keep generating with the app in the background, at full
speed, as long as the app is in Picture in Picture and the phone is unlocked.**
Locking the phone stops GPU work within about a second, with or without PiP.

## Scored

| # | Probe | Predicted | Measured | Verdict |
| --- | --- | --- | --- | --- |
| 1 | `supportedResources` | no `.gpu` | `rawValue=0 gpu=false` | ✅ |
| 2a | GPU, background, continued-processing task | refused, code 7 | refused on all 86 background beats, `MTLCommandBufferErrorDomain` 7 | ✅ |
| 2b | Core ML in the background | runs on the NE | runs, at the foreground speed (2.3–5.6 ms, outliers 10.7, 26.8 and 98.0), locked included. **Unit not resolved:** the CPU-only reference was 2.4–2.5 ms, too close to tell CPU from NE | ⚠️ inconclusive; moot after 4b |
| 3 | 3.1 GB app kept alive under the task | killed under heavy use | not tested under the task alone. Under PiP (run 2) the app held 3.09–3.12 GB through other-app use and was not killed. The task itself was ended by iOS after 186 s, at an unlock, when free memory fell to 317 MB | partly answered |
| 4a | Proximity screen-off | app stays active, GPU works | `app=active` and GPU status 4 for all 12 covered beats | ✅ |
| 4b | PiP, app in background | GPU refused | **GPU allowed:** status 4, 6.9–9.3 ms, all 21 background beats, with no background task | ❌ prediction wrong |

## Real decode in PiP (runs 2 and 3)

Model loaded as the harness does (24 slots, `.fullSha256` because the receipt
path does not match on iOS), warmed with 48 tokens, then 512-token replies to
an ad-hoc prompt. Instrumented, ad-hoc prompt: **not protocol tok/s.**

| Case | What happened |
| --- | --- |
| Run 2: PiP, home screen, other apps | 512/512 tokens, `reason=maxTokens`, 5.914 tok/s overall. Tokens 128–512 were generated with `app=background pip=true`, at 2.3–3.6 s per 16 tokens against 2.4–2.7 in the foreground. Footprint 3.11–3.12 GB, not killed. |
| Run 3A: PiP, then locked | GPU refused about 0.2 s after `locked` (1.2 s after leaving the app): `generate-failed`, code 7, a thrown error. No crash; the model stayed loaded and the next reply ran. |
| Run 3B: PiP window stashed at the edge | Tokens 16–416 all in the background, 2.2–3.6 s per 16, 5.633 tok/s overall. The log cannot show when the window was stashed; the user was asked to stash it for ~20 s mid-reply. |
| Run 3C: PiP closed with ✕ | `pip-stopped` at 354.7 s. No token followed: the app was suspended at once, mid-reply, **with no error**. On return 42.7 s later, decode resumed at the next token and finished 512/512. |
| Run 2, later: PiP gone, app left in background | Reply stuck at 0 tokens from the moment of leaving; process alive but silent at +2 min; killed some minutes later (no log line, as for a jetsam kill of a suspended app). |

## What it means for the app

- **PiP is the way to generate in the background.** Nothing else measured
  here allows GPU work there. App Store review would likely object to PiP
  without video, but this app is side-loaded.
- **Locking stops it.** The failure is a clean thrown error, so the reply can
  be paused and resumed on unlock rather than lost. Resuming needs a restart
  from the last committed KV position, since the failed command buffer may have
  left the current token half-written.
- **Closing PiP freezes the app,** and it resumes by itself on return. A
  suspended 3.1 GB app is killed after a while, so the turn must already be
  saved when that happens.
- **Proximity screen-off keeps the app active,** so "phone face down or in a
  pocket" is a substitute for locking, with the GPU still allowed.
- Not tested: how long PiP keeps a 3.1 GB app alive under heavy memory
  pressure from other apps, thermal behavior over long replies, and the
  ANE question (moot unless the GPU path closes).

## PiP controls (follow-up, same day)

With the window's content reported as live (`timeRangeForPlayback` from
−∞ for +∞), iOS 26.6 still showed −10/+10, play/pause and a timeline.
`requiresLinearPlayback = true` plus the private `controlsStyle = 1`
(`--pip-controls-style 1`, set by key-value coding after a `responds(to:)`
check) hid all three. Only the close and return-to-app buttons were left,
checked by eye on the phone. Style 2 (no controls at all) is untested.
