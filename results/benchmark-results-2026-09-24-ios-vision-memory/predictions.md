# Predictions: what one image costs in memory on the iPhone 17

Written before any run. This is the second half of the Phase 4 gate. The first
half, kernel margins, passed (`results/validation-results-2026-09-24-ios-vision/`). This
is a memory-ceiling item, not an optimization.

## Configuration

This is the chat app as a user gets it: 8K context, 32 expert-cache slots, the
1024 prefill chunk cap, sampling defaults, and vision residency `.onDemand` (the
tower is mapped for each image and released after it). The pack downloads in the
app from Settings.

## Instrument

The harness cannot send an image, so the app logs every turn to
`Documents/app-memory.log`:

- **`turn-start` and `turn-end`:** footprint, lifetime peak, and phone-wide VM
  counters (`Mem.line()`, the same one the harness uses).
- **`turn-max`:** the turn's own maximum footprint, sampled every 0.5 s. This is
  needed because the lifetime peak cannot tell turns apart.

A 0.5 s sampler can miss a spike shorter than that. The lifetime peak on the
`turn-end` line bounds it from above whenever that turn set a new peak.

## Procedure

1. Fresh launch. The model loads on the first send.
2. **Text turn:** "Describe what a good photo of a street at night looks like,
   in three sentences." This is the baseline.
3. **Image turn**, in the same chat: one photo from the library, a 12 MP HEIC
   from the camera, with "Describe this photo in three sentences."
4. **A second image turn** with another photo, to see whether the cost repeats
   or is paid once.

## Where the memory goes, from code

- **Tower weights:** the 1.08 GB the tower reads is mmapped read-only and
  wrapped without a copy (`ResidentBuffer`). The measured facts table says
  1.26 GiB mapped this way cost about 16.6 MB of footprint. So the weights
  should add **≤ 20 MB** of footprint. Their cost falls on the file cache
  instead.
- **Scratch:** `VisionScratch`, BF16, private buffers, allocated per image.
  At the 2,520-patch maximum, padded to 2,560 rows, it holds:
  - the patches, 3.9 MB
  - four hidden-sized buffers, 23.6 MB
  - K and V only if not fused, up to 11.8 MB
  - `gate` and the optional `up`, 22 MB each

  That totals **50–85 MB**.
- **Decoding the photo:** a 12 MP image decoded to RGBA is about 48 MB, held
  for a moment. `VisionImageLimits` caps it at 200 MB.
- **Image tokens in the KV cache:** about 280 tokens. The 5 full-attention
  layers cost 20,480 B/token, so about 6 MB. The sliding-window ring is fixed.

## Predictions

| # | Prediction | Falsifier |
| --- | --- | --- |
| M1 | The text turn's `turn-max` is **3.9–4.1 GB**: 3.77 GB at 32 slots (2026-09-16), plus the cap's +152 MB ring and +94 MB scratch, and a short prompt. | Outside 3.8–4.2 GB. |
| M2 | The first image turn's `turn-max` exceeds the text turn's by **+50 to +200 MB**: scratch, decode and image tokens. The mapped weights add ≤ 20 MB of that. | More than +300 MB, or less than +20 MB. |
| M3 | The second image turn's `turn-max` is within ±100 MB of the first's. The scratch is freed after each image, so nothing accumulates. | More than +100 MB over the first image turn. |
| M4 | The image turns churn the compressor harder than the text turn, because about 1 GB of tower weights has to pass through the file cache: more compressions per second of turn. | Compressions per second no higher than the text turn's. |
| M5 | No jetsam kill in any of the three turns. | The app dies. |

## Reading rules

- **What gates Phase 4:** if an image turn goes past **4.3 GB**, the level
  `results/benchmark-results-2026-09-24-ios-context/` says to budget against, then image
  input does not ship at 32 slots. The fallback is to measure at 24 slots
  (−0.8 GB) before shipping.
- **How one run can be read:** each turn is a single run, so this is a sizing
  check, not a distribution. M4 is directional only.
