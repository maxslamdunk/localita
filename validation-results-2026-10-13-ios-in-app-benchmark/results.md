# In-app benchmark: does it measure what `devicectl` measures?

**Question.** The Settings › Models › Benchmark screen (`0a42e3c`, fixed in
`110913f`) runs the three `real-generation-v1` cases inside the chat app,
each from a fresh model load, with a cooldown between them. Does it produce
the same run as the `--autorun` protocol, so that community results can sit
beside the project's own phone rows?

**Answer: yes for everything exact, and within noise for time** (n = 1).

## Run

- iPhone 17 (`iPhone18,3`), 8 GB, iOS 26.6. App Release at `0a42e3c` plus the
  fix committed as `110913f`, installed over the app.
- Started by hand from Settings, the chat model unloaded by the screen.
  Battery 65% → 75%, charging. Low Power Mode off.
- Gemma 4 (`gemma4.gturbo`, manifest SHA-256 `1cb53c24…`). Defaults: 24 slots,
  fitted guess, one early read, `F_NOCACHE`, count aging. Prefill chunk `auto`,
  `.fullSha256` (receipt path mismatch, as in every phone row).
- Cooldowns: 0 s, 61 s (back to `nominal`), and 301 s before long. The phone
  stayed `fair` while charging, so the 5-minute cap ended the wait.
- Files: `run-20261013T143442Z/` (`report.json` plus the logs and texts as the
  app wrote them).

## Against the 2026-10-08 one-read runs (`benchmark-results-2026-10-08-ios-early-read-x2/`, `devicectl`)

| Case | Text SHA-256 | Bytes/token | Hit rate | tok/s in-app | tok/s 10-08 | Thermal in-app |
| --- | --- | --- | --- | --- | --- | --- |
| short | `d32db73b…`, same | 188.84, same | 79.5%, same | 6.475 | 7.010, 6.890 | nominal 32 |
| medium | `209ffadb…`, same | 211.83, same | 75.9%, same | 5.032 | 4.679, 5.574 | nominal 12, fair 28 |
| long | `87f6f357…`, same | 227.02, same | 73.7%, same | 5.415 | 5.521, 5.669 | serious 38 |

- **Exact counters are identical**: generated text, decode bytes/token and hit
  rate on all three cases, and early reads per token (29.00; used 19.35 /
  20.69 / 21.36). The in-app run is the same computation as the protocol run.
- **Short is 6–8% slower.** Wall 154.75 against 142.94 and 145.43 ms per
  forward. Most of it is `io`: 89.71 against 80.84 and 82.77 ms, at identical
  bytes, and mean read latency is 3.86 against 3.48 ms. GPU attention+router
  is 21.94 against 20.94 and 21.08 ms (+4–5%). This is at the edge of the
  ~8% run-to-run noise. A 15 GB model install the same day is a candidate
  for slower storage, but it is not separated from noise (n = 1).
- **Medium and long fall inside the 10-08 range**, at similar thermal state.

## What this does not show

- Whether the gap on short is the app (its process state after a chat) or
  the day. Separating them would take an A B B A of in-app against
  `devicectl` on the same day.
- Anything about other devices.

## Second run: report format 2 (`89fc5a1`)

Same phone and settings, 18:31Z, battery 90% and charging, all three cases at
`nominal` (cooldowns 0, 61 and 61 s). Files: `run-20261013T183100Z/`.

| Case | tok/s | First run | Exact counters |
| --- | --- | --- | --- |
| short | 6.285 | 6.475 | same text, bytes/token, hit rate |
| medium | 5.608 | 5.032 | same |
| long | 5.238 | 5.415 (at `serious`) | same |

- **The format 2 fields are filled** for every case: the four footer lines,
  footprint, process peak (3.145 / 3.240 / 3.410 GB) and available memory,
  plus the run's `submissionID`.
- **No path is left** in the report or the logs. `model-found` reads
  `~/Library/…`, and the receipt line reads `<other install>/Library/…`.
- **The results Worker accepts the report unchanged**
  (`server/benchmark-worker/`, `validateReport`).
- Speed moved both ways at identical counters. Long is 3% slower at `nominal`
  than the first run at `serious`. Medium is 11% faster, almost all in `io`
  (91.42 against 118.68 ms a forward at identical bytes), while its GPU
  attention+router was slower (35.00 against 28.82 ms). That is the storage and
  GPU variance `CLAUDE.md` describes, not a change in the computation (n = 2).
