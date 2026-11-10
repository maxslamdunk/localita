# Slots and expert skipping on an iPhone 18 Pro: predictions

Written 2026-11-10, before the sweep exists and before any run of it. The
phone is a tester's **iPhone 18 Pro** (`iPhone19,2`, A20 Pro, 12 GB, iOS 27.2,
storage capacity unknown). Its one run so far is report `20261109T190357Z`,
app 1.0 (4), 24 slots, skipping off, one early read: **12.35 / 11.00 / 9.51
tok/s**, wall 80.97 / 90.89 / 105.11 ms per token, `io` 38.31 / 41.12 / 48.36
ms, 29.84 / 35.18 / 42.67 foreground reads per token (all reads minus 29.00
early), mean read 1.74 / 1.72 / 1.83 ms. That report was shared as a file and
never sent, so it is not in `benchmark-submissions/`.

The question is whether 32 slots should be the default on 12 GB phones, and
what skipping is worth on a phone whose reads cost about half what they cost
on the iPhone 17.

## Protocol

The in-app **Settings sweep** (app 1.0 (6)), offered only on phones with
12 GB: seven runs of the three `real-generation-v1` cases, one run per
setting, in this order:

| Run | Slots | Skip |
| --- | --- | --- |
| 1 | 24 | `miss:0.08` (the iOS default) |
| 2 | 32 | off |
| 3 | 24 | `miss:0.10` |
| 4 | 32 | `miss:0.08` |
| 5 | 24 | off |
| 6 | 32 | `miss:0.10` |
| 7 | 24 | `miss:0.08` |

Early reads stay at one per layer. Each case is `--max-new 1024 --max-context
4096`, chunk `auto`, T 0.2 / Top-K 64 / Top-P 0.95, seed 1. Cases wait for the
usual cooldown (at least 60 s, until the thermal state is back to where the
sweep began, at most 300 s). Runs wait at least 180 s the same way, at most
600 s. The tester runs it unattended on a charger, so conditions are what the
report records and nothing more.

**One run per setting.** Runs 1 and 7 are the same setting, so their gap is
the noise floor for this sweep. Compare 24 against 32 only where the gap
exceeds it.

## How the numbers were made

From the 18 Pro's own build-4 footers, plus read counts that do not depend on
the phone:

- **Cost of a foreground read here:** `io` per foreground read is 1.13–1.28 ms
  on this phone. On the iPhone 17 the `io` saved per removed read was
  0.75–0.89 of that ratio
  (`results/benchmark-results-2026-11-08-ios-expert-skip/`), so each removed
  read is priced at **0.85–1.15 ms**, and wall falls by what `io` falls.
- **Reads that skipping removes:** the iPhone 17 shares, −42.3 / −33.9 /
  −33.7% at `miss:0.08`. At `miss:0.10`, the Mac's −64 / −59% on short and
  medium, and −55 to −62% assumed for long
  (`results/research-results-2026-10-04-lossy-experts/`).
- **Reads that 32 slots removes:** hit rate +7.2 to +7.4 points on the iPhone
  17 on 2026-09-16, which was **before the early read**. Hit rate itself does
  not depend on the early read (79.1% at 24 slots without it, 79.5% with it).
  How many misses the early read still covers at 32 is unknown, so the 32-slot
  rows take 9.9 to 17.8 fewer foreground reads per token. This is most of the
  width of those rows.
- **Skipping at 32 slots** removes the same share of the foreground reads that
  are left.

## What moves

Decode tok/s, short / medium / long.

| Run | Setting | Predicted tok/s | Against 24 / off |
| --- | --- | --- | --- |
| 5 | 24 / off | 11.4–13.3 / 10.1–11.9 / 8.7–10.3 | the build-4 run ±8% |
| 1, 7 | 24 / 0.08 | 14.2–15.0 / 12.4–13.0 / 10.8–11.3 | +15 to +22 / +13 to +18 / +13 to +19% |
| 3 | 24 / 0.10 | 15.4–16.9 / 13.7–14.9 / 11.7–13.4 | +25 to +37 / +24 to +36 / +23 to +41% |
| 2 | 32 / off | 13.9–16.5 / 12.3–14.1 / 10.3–11.7 | +13 to +34 / +11 to +28 / +9 to +23% |
| 4 | 32 / 0.08 | 15.1–18.3 / 13.4–16.0 / 11.5–13.7 | +22 to +48 / +22 to +46 / +21 to +44% |
| 6 | 32 / 0.10 | 15.9–19.4 / 14.2–17.3 / 12.3–15.0 | +29 to +57 / +29 to +57 / +29 to +58% |

The ranges are against the build-4 run. Score each against run 5, which is
the same setting on the same day.

- **Diminishing returns:** 0.10 over 0.08 adds less at 32 slots than at 24,
  because fewer reads are left to cut.
- **Peak footprint:** 32 slots is **+0.81 GB** over 24 (30 layers × 8 slots ×
  3,358,720 B = 806,092,800 B), so about 4.2–4.4 GB peak in the long case on
  build 6, against the 6.44 GB that `os_proc_available_memory` plus footprint
  reports on every phone so far. No case is killed.

## The controls

1. **Text:** runs 1 and 7 have the same generated SHA-256 in each case (same
   setting, same seed). **Runs 2 and 5 match too:** slot count changes which
   experts come from storage, never the values, so with skipping off the text
   cannot depend on it. Skipping runs differ from off, and from each other
   across slot counts, because what is dropped depends on what is cached.
2. **Early reads:** 29.00 per token in every run.
3. **Prefill bytes:** identical across skip settings at the same slot count
   (skipping is decode only).
4. **Hit rate:** at the same skip setting, 32 slots is +5 to +9 points over 24.
5. **The settings in each report** match its row of the protocol table, and
   each log's `runner-ready` line says the same.

## The mechanism

Decode on this phone is about half waiting for reads (`io` 38–48 ms of 81–105)
and half GPU work and handoff. Slots and skipping both cut the reads `io` waits
for: slots by keeping more experts resident, skipping by not reading
low-weight misses at all. A read costs less here than on the iPhone 17 (1.7 ms
mean against 3.4–4.5), so each removed read buys less, and the gains are
smaller than the iPhone 17's +18 to +33% for skipping. Neither touches the GPU
side, which caps decode at about 23 / 20 / 18 tok/s with no waited-for reads.

## What would falsify it

- **32 / off at or below 24 / off** in any case, by more than the run 1 / run 7
  gap. On the iPhone 17 (8 GB) the user saw 32 slots slower than 24 with the
  early read on, unmeasured. If the 12 GB phone shows it too, the cause is not
  memory pressure.
- **Runs 2 and 5 generating different text** in any case: the cache would be
  changing the arithmetic.
- **0.10 gaining more over 0.08 at 32 slots than at 24.**
- **Any 32-slot case killed**, or a peak footprint more than 0.9 GB above the
  same case at 24.
- **Runs 1 and 7 more than 8% apart** in any case: the sweep then cannot
  resolve the 24 → 32 question on its own, and the result is a hint, not a
  decision.

## The decision rule

32 slots becomes the default on 12 GB phones if **run 2 beats run 5, and run
4 beats both runs 1 and 7, by more than the run 1 / run 7 gap in every case**,
and no case is killed.
The tester also checks by hand, with 32 set in Settings, that the photo picker
works and a long chat is not killed. The skip threshold stays 0.08 whatever
0.10 does here: 0.10 costs about twice the quality on the Mac, and that is a
separate decision for the user.
