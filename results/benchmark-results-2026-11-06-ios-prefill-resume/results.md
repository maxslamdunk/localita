# Results: resuming a refused layer-at-a-time prefill

Scored against [`predictions.md`](predictions.md), which was committed first
in `4fd99e1`, before any run. The logs are in [`logs/`](logs/) and
[`mac-check/`](mac-check/). The drivers are `run-mac.sh` and `run-phone.sh`;
the phone driver uses step 3's `lib.sh`. The figures are in
[`summary-output.txt`](summary-output.txt), and `measurement_rows.py` prints
the `MEASUREMENTS.md` rows.

## What was run

- **Binary:** branch `prefill-port` at `4fd99e1`, whose code is `f497818`.
  - **Phone:** iOS app Release, installed over the app.
  - **Mac:** `TurboFieldfareCLI` release.
- **Mac check:** M1 MacBook Air 8 GB, macOS 26.6.1, 2026-11-06 16:55–16:58.
  Greedy, `--max-new 48`, defaults (16 slots, chunk 128). Medium and long, once
  each.
- **Phone:** iPhone 17, iOS 26.6, 2026-11-06 16:59–17:06. `long-synthesis`,
  prompt SHA-256 checked. Hashed load, 24 slots, `--max-context 4096`, chunk
  `auto`, `--max-new 32`. Two runs, 300 s apart. `nominal` at every sample;
  battery 85% and 90%, charging; network on.
- **Lock test in the app:** the same build, 2026-11-07 23:42–23:56 UTC
  (2026-11-08 local). Background generation on. The user sent the same long
  first message in a new chat each time, locked the phone partway through the
  prefill, and unlocked after 15 s to 2.6 min. The app's own memory log for the
  test is in [`lock-test-app-memory.log`](lock-test-app-memory.log), with the
  container path removed.

## Scoring

### Phone, long (3015 tokens, 3 chunks)

| | prediction | resume-A1, A2 | step 3's A1, A2 |
| --- | --- | --- | --- |
| text | `30e14eae…` | `30e14eae…`, both | `30e14eae…` |
| prefill bytes, MiB | 11,140.47 exactly | 11,140.47, both | 11,140.47 |
| reads | 3,478 exactly | 3,478, both | 3,478 |
| peak footprint, GB | 3.524–3.534 | 3.531, 3.529 | 3.514, 3.512 |
| prefill wall, s | 43–48 | 47.88, 43.46 | 44.10, 45.51 |

- **Text, bytes and reads: held.**
- **Peak footprint: held,** +17 MB: one more 16.98 MB buffer. Unlike step 3's
  buffers, this one is counted in full.
- **Wall: held,** A1 near the top of the range. A1's GPU was slower throughout
  (busy 43.32 s against A2's 41.24 s), within the known run-to-run GPU spread.
- Decode over 32 tokens was 4.244 and 4.504 tok/s at 273.61 MB/token, the
  same bytes as step 3. Not a control.

### Mac check

| case | text | prefill bytes, MiB | wall, s |
| --- | --- | --- | --- |
| long | `327852ac…`, as step 3's A | 11,118.05, as step 3 | 73.30 (step 3: 74.45) |
| medium | `38a3bf14…`, as step 3's A | 8,885.47, as step 3 | 14.08 (step 3: 12.01) |

**Held.** Each layer reads the rows the layer before it wrote, on both hosts.
Mac decode over 48 tokens was 2.841 tok/s on long and 2.739 on medium,
against step 3's 2.988 and 3.833, at identical bytes/token. One run each, on
a host whose file cache the long prefill churns. Not a control, and not
investigated.

### Lock test

**Held: the prefill carried on after unlock instead of restarting.** In the
app, the gauge picked up where it was. One long first message survived three
locks (15 s, 32 s and 94 s), then finished and was saved normally (the turn
from 23:45:15 to 23:49:53 UTC). Three more resumed, and the user then stopped
them during prefill. A stop during prefill is not saved, so those chats were
left empty too. That is expected behaviour today; see the second note below.

**But iOS ended the app twice while it was locked.** Both turns were the
second after a model load, locked at 3.69 GB and 3.63 GB. The next line in
the log is a new `model-ready` with no `turn-end`. Every lock at 3.13 GB or
less survived. The phone wrote no jetsam or crash report for either, so
memory is the likely cause, not a confirmed one. A paused turn lives only in
memory (`BackgroundGeneration`'s known risk), so both were lost. Each left an
empty chat marked "This chat can't be continued. It has no replay record".

## Decision

**Kept.** A refused layer-at-a-time prefill now resumes from its first
unfinished layer, with output byte-identical and +16.98 MB at 3015 tokens
(+23.07 MB at the cap).

## Notes

- **The fix makes waiting on a lock worth it, and it raises the cost of
  waiting.** Before it, a lock during a long first prefill threw away up to
  ~45 s of work. Now the work is kept, but the app sits frozen at up to
  ~3.7 GB while it waits, and iOS ended it there. Shrinking the app while a
  turn waits on a lock is a to-do in `docs/IOS_PORT.md` (on `main`, `4f3e6de`). About 2.4 GB of that
  is the expert cache, which can be refilled from storage.
- **An unfinished first turn loses the user's message.** The chat file is
  created when the message is sent. The message itself is written only when
  the turn completes. A stop during prefill, a failure, or the app being
  ended leaves a named chat with no turns, which reopens empty and refused.
  This predates this branch and is a to-do beside it.
- The Picture in Picture window never opened in the lock test (`pip=false`
  throughout). The user locked from inside the app, so it was never needed.
