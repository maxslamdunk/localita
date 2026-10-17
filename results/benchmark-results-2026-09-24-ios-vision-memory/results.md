# Results: what one image costs in memory on the iPhone 17

Predictions are in `predictions.md`, committed first in `44daf87`. Configuration:
8K context, 32 slots, the 1024 chunk cap, reasoning off, and vision `.onDemand`.
The pack was downloaded in the app. The log is
`logs/app-memory.log`. Jetsam and panic reports are summarised below and not
committed, because they list every process on the phone.

## The headline

**An image turn costs about +64 MB, and passes the pre-written 4.3 GB gate
(4.20 GB). But picking a photo does not survive at 32 slots.** The app was killed
for `proc-thrashing` with the system photo picker open. The app idled at
4.11–4.14 GB between turns. The picker is a separate process holding 0.22 GB,
and adding it tipped the phone into thrashing. The image turn itself was never
the problem. The failure happened in a step the feature cannot skip.

## Turns (UTC; the phone runs at +02:00)

| Turn | `turn-max` | Seconds | Compressions/s | Notes |
| --- | --- | --- | --- | --- |
| Text, 13:15:38 | **4.139 GB** | 21 | 46.7K | first send, includes the model load |
| Image 1, 13:16:53 | **4.203 GB** | 27 | 52.4K | same process |
| *app gone between 13:17:20 and 13:18:53* | | | | relaunched, model not loaded |
| Image 2, 13:18:53 | **4.198 GB** | 59 | 40.2K | **new process**, includes the model load |

Between the text turn and image 1, the footprint at rest was 4.11 GB.

## Kill and reboot

- **13:17–13:18 UTC, the crash the user saw while picking the second photo:
  no report exists.** The app's log shows it relaunching before image 2. No
  jetsam, crash or resource report falls in that window. Its cause is **not
  established**.
- **13:23:00 UTC, `JetsamEvent`:** the largest process was TurboFieldfareiOS at
  **4.135 GB**, killed for `proc-thrashing` while active. PhotosPicker was
  active at 0.219 GB and was also killed for `proc-thrashing`. The same event
  killed 159 processes for `proc-thrashing`, 99 for `vm-pageshortage`, 60 for
  `vm-compressor-thrashing`, and 560 for `idle-exit`. A second TurboFieldfareiOS
  entry, `suspended` at 4.128 GB, was killed for `vm-pageshortage`. The report
  does not say why the app appears twice, and it is not interpreted here.
- **13:23:58 UTC, kernel panic, phone reboot:** `busy timeout (60s): multiple
  entries holding the registry busy … 'AppleAPFSMediaBSDClient',
  'AppleAPFSVolumeBSDClient'`. The reset counter records a watchdog reset
  (`rst wdog`). The panic came 58 s after the kill. A storage driver held for
  60 s under this much memory pressure is a plausible link, but one event cannot
  establish it.

## Scoring

- **M1, text turn 3.9–4.1 GB: missed high by 39 MB** at 4.139 GB. That is
  inside the 3.8–4.2 GB falsifier band, so it is not falsified.
- **M2, image turn +50 to +200 MB: HELD** at +64 MB.
- **M3, second image turn within ±100 MB of the first: HELD on the number
  (−5 MB), but not tested as intended.** The second turn ran in a new process
  after the crash, so accumulation within one process was never exercised.
- **M4, image turns churn the compressor harder: WEAK.** Image 1 ran at +12%
  compressions per second over the text turn. Image 2 ran lower, but it included
  the model load. Directional only, as the reading rules said.
- **M5, no jetsam kill: FALSIFIED.** The app was killed with the picker open.
  The phone also panicked and rebooted, with a causal link to the kill
  unestablished.

## Consequences

1. **The 4.3 GB rule was the wrong gate.** It measured the app against a budget
   but ignored what else must run beside it. Attaching a photo requires the
   system picker (0.22 GB) to run while the app sits at 4.1 GB. This matches
   `results/benchmark-results-2026-09-24-ios-context/`, where iOS began killing other
   processes from about 3.9 GB. The picker is the first *required* process to
   lose that fight.
2. **Image input does not ship at 32 slots as measured.** The pre-written
   fallback was to measure at 24 slots, which frees about 0.8 GB and would put
   the app at about 3.3 GB at rest. That is also the first step of the deferred
   lighter-settings work, which targets the lag reported during generation.

## Rerun at 24 slots (the pre-written fallback)

Same procedure: slots set to 24 in Settings, the model reloaded, the app
force-quit, then the text turn and two photo turns in one chat, reasoning off.
The log continues in `logs/app-memory.log`, from 13:55 UTC. **All three turns
completed in one process.** No new jetsam, crash or panic report exists on the
phone.

| Turn | `turn-max` | Lifetime peak at `turn-end` | Rest after | Compressions/s |
| --- | --- | --- | --- | --- |
| Text | **3.332 GB** | 3.333 GB | 3.328 GB | 23.4K |
| Image 1 | **3.394 GB** (+61 MB) | 3.394 GB | 3.353 GB | 20.9K |
| Image 2 | 3.386 GB | **3.403 GB** (+9 MB over image 1) | 3.358 GB | 20.4K |

- **Slots 32 → 24 freed 807 MB** on the text turn, as predicted for 30 × 8 ×
  3,358,720 B = 0.81 GB.
- **An image costs about the same at either count:** +61 MB here, +64 MB at 32.
- **M3 is now tested within one process, and HELD:** +9 MB peak and +4 MB at
  rest from the first image to the second. Nothing accumulates.
- **The sampler missed image 2's peak** by 17 MB; the lifetime peak caught it.
  Where a turn sets a new peak, quote the ledger.
- **The compressor ran at half the rate of 32** during turns, 20–23K/s against
  47–52K/s. That is the pressure behind the reported lag, and it is inferred,
  not measured, that the lag eases too.
- **Throughput is not in this log.** 24 measured +37 / +28 / +21% over 16 on
  2026-09-16, against +59 / +56 / +34% at 32, so about 14% slower than 32 on
  the short case.

One clean session is not proof. At rest the app now sits about 0.6 GB below the
3.9 GB level where iOS began killing other processes. At 32 it sat about 0.2 GB
above it.

**Decision (user, 2026-09-24): 24 becomes the iOS default.** 32 stays
selectable in Settings.
