# Predictions: resuming a refused layer-at-a-time prefill

Written before any run of this change, and committed before them.

## The change

Layer-at-a-time prefill (`../benchmark-results-2026-11-06-ios-prefill-layer-major/`)
commits nothing before its last layer, so a GPU refusal (the phone locking
with background generation on) restarted a long first message from the
embedding. Now the runner keeps the refused prefill and the retry carries on
from its first unfinished layer (`RawCompletionStart.resumeSuspendedPrefill`).

For that, a layer must never overwrite its own input. Each chunk used to
write its post-attention rows back over the layer's input rows, so the
residual stream is now two prompt-wide buffers that alternate by layer. That
is one more row buffer: 5,632 B a token, so 67,632 B a token in all instead
of 62,000. On the long prompt (3015 tokens) that is +16.98 MB, and +23.07 MB
at the 4096-token cap. No GPU work is added; only which buffer each copy
reads or writes changes.

This is a reliability fix, not a speed change. The runs below check that the
normal path is unchanged and score the footprint cost.

## What is run

- **Mac:** `TurboFieldfareCLI` release, greedy, `--max-new 48`, defaults
  (layer at a time on), medium and long, once each, as in the step 3 Mac check.
- **Phone:** iPhone 17, Release, long-synthesis, hashed load, `--max-new 32`,
  24 slots, `--max-context 4096`, chunk `auto`; two runs (resume-A1,
  resume-A2) with 300 s cooldowns. Compared with step 3's arm A (long A1/A2,
  same day, same harness arguments, the binary before this change).
- **App:** with background generation on, a long first message, the phone
  locked part way through the prefill and unlocked after about 10 s. Not a
  measurement: it passes if the prefill gauge carries on rather than starting
  from zero, and the reply is normal.

## Predictions

| | prediction | mechanism |
| --- | --- | --- |
| Mac text | byte-identical to step 3's arm A: medium `38a3bf14…`, long `327852ac…` | the same kernels on the same rows; only the buffer each layer reads changes |
| Phone text | `30e14eae…`, as in all of step 3's long runs | as above |
| Prefill bytes and reads | exactly 11,140.47 MiB and 3,478 reads | no change to routing or to the expert cache |
| Peak footprint | +12 to +20 MB over step 3's A (3.514, 3.512 GB), so 3.524–3.534 GB | one more 16.98 MB private buffer; step 3's footprint counted ~70% of its 186.93 MB buffers |
| Prefill wall | 43–48 s (step 3's A: 44.10, 45.51 s) | no work added |

## What would falsify it

- **Any text difference** on either host: a layer reading the wrong buffer.
  That is a bug, not noise; the change would not ship.
- Bytes or reads moving at all.
- Peak footprint more than +40 MB over step 3's A.
- In the app, the gauge falling back to zero after unlock, or a broken reply.
