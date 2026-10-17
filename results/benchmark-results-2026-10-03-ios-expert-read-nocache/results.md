# Results: expert reads past the OS file cache (`F_NOCACHE`) on the iPhone

Scored against [`predictions.md`](predictions.md), committed first in
`63b30e1`. The phone build is `63b30e1`. Logs are in [`logs/`](logs/), the
driver is [`run.sh`](run.sh) ([`driver.log`](driver.log),
[`driver-medium-long.log`](driver-medium-long.log)), and
[`summarize.py`](summarize.py) prints every figure below
([`summary-output.txt`](summary-output.txt)).

## Answer

**`F_NOCACHE` makes every expert read faster, with identical output. The
tok/s gain is real but smaller than the raw numbers suggest.**

- Mean time per read fell by **0.50–0.67 ms** in every case, and every B run
  was faster per read than every A run of its case.
- tok/s rose **+8.4 / +3.7 / +24.3%** (short / medium / long). Long's figure
  is mostly GPU speed: both of its A runs had a slow GPU and both B runs a
  fast one (head GPU time 11.9 against 8.5 ms). The output head never overlaps
  a read, so `F_NOCACHE` cannot explain that.
- Where GPU speed matched, the gain was **+8.4% on short** (all four runs
  the same speed) and **+6.0% on medium** (B2 against both A runs). Long has no
  matched pair.

| case | tok/s A → B | `io` ms/fwd | read mean ms | head GPU ms A → B |
| --- | --- | --- | --- | --- |
| short | 6.522 → **7.069 (+8.4%)** | 85.33 → 78.68 (−6.66) | 4.10 → 3.43 | 8.30 → 8.36 |
| medium | 5.349 → **5.546 (+3.7%)** | 88.71 → 85.93 (−2.79) | 4.04 → 3.55 | 10.62 → 11.17 |
| long | 4.612 → **5.733 (+24.3%)** | 99.37 → 98.22 (−1.15) | 4.34 → 3.74 | 11.87 → 8.52 |

A = today's reads, B = `--expert-read-nocache`. Means of two runs per arm.

## What was run

Branch `worktree-expert-read-nocache` at `63b30e1`, built in Release and
installed over the app. One binary; B adds `--expert-read-nocache`, and every
log's `runner-ready` line says `expertReadNoCache=` true or false accordingly.
Defaults otherwise: early read on with the bundled fitted guess, 24 slots,
`--max-new 1024 --max-context 4096`, prefill chunk `auto`. iPhone 17, iOS
26.6, battery 100% full.

Each case ran A B B A with 300 s cooldowns, on 2026-10-03 from 12:50 to
14:11. Short first, as a quick look; medium and long followed because short
looked promising. Thermal was `nominal` for every short and medium sample, and
`fair` for 36–39 of 42 samples in every long run.

## Scoring

**Controls: held exactly.** Every case's four texts share one hash
(`d32db73b…`, `209ffadb…`, `87f6f357…`, the same as the fitted-guess runs).
bytes/token, hit rate, reads/token and early used/token are identical across
arms to the digit.

**P1, `io` −2 to −8 ms: held on short and medium, missed on long.** −6.66 /
−2.79 / −1.15 ms. Only short separates cleanly: on medium and long the A and
B runs overlap.

**P2, read mean −0.1 to −0.4 ms: wrong, too small.** It fell 0.50–0.67 ms.
The direction was right and it is the cleanest signal in the set.

**P3, tok/s +1 to +5%: missed high on short, held on medium, unscoreable on
long.** Short +8.4% at matched GPU speed. Long's +24.3% is confounded by GPU
speed, as above.

**P4, the OS file cache shrinks: held on medium and long, not short.**
Median `sys-filebacked` fell by 125 and 139 MB on medium and long and rose by
22 MB on short.

**Not predicted:** on short, `cb1-wait` fell 3.7 ms at unchanged GPU speed.
One possible cause is the kernel's copy competing with the GPU for memory
bandwidth, as the Mac saw in IO-06. That is a guess; n = 2.

## Why the read gets faster

Without `F_NOCACHE`, each 3,358,720 B read fills OS file-cache pages and then
copies them into the slot buffer, and the cache evicts other pages to make
room. On the phone the cache serves under 1% of misses, so that work buys
nothing. A larger saving per read than predicted (0.5–0.67 ms, not 0.1–0.2)
means the cache path cost more than the gap between the storage probe and the
runtime implied. The probe's own flag setting was not checked.

The Mac result (IO-03, neutral) does not carry over. That is consistent with
the phone's memory pressure: the Mac had about 1.44 GB of idle file cache to
spare.

## Decision

**On by default on iOS since 2026-10-03, by the user's decision.** Off on
macOS, where it measured neutral (IO-03). Override with
`TURBO_FIELDFARE_EXPERT_READ_NOCACHE=1|0`, or in the harness with
`--expert-read-nocache` / `--expert-read-cached`. The reasons: identical
output, zero byte change, faster reads in every run, and +6 to +8% tok/s where
GPU speed was matched. Still open: how much of the long case's gain is real.
A long-case repeat with matched GPU speed would settle it.
