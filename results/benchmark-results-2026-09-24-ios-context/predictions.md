# Context length on the iPhone 17: predictions

Written **before** any run, per the working agreement in `CLAUDE.md`. These
runs decide which context lengths the iOS settings sheet may offer against
the 5.60 GB jetsam floor. The binary is `19e6ef0` plus a harness-only change
that logs the kernel's peak footprint ledger. Device: iPhone 17, 8 GB,
iOS 26.6.

**Bytes/token delta: 0 by construction.** No runtime code changes. The grounds
are the memory ceiling.

## What the prediction rests on

- KV is fp16 (`KVCacheManager.swift:81-103`, installed manifest):
  - **Sliding-window layers** (25 of 30) hold a fixed ring of min(context,
    1024 + 1024) = 2,048 tokens: 25 × 2 × 8 heads × 256 × 2 B × 2,048 =
    **419 MB, the same at every context length ≥ 2K.**
  - **Full-attention layers** (5 of 30) are linear in position: 5 × 2 × 2 heads
    × 512 × 2 B = **20,480 B per token**, so 84 / 168 / 336 MB at 4K / 8K / 16K
    *if full*.
- **KV pages are committed lazily.** On 2026-09-22 the footprint at
  `runner-ready` was 166 / 171 MB, after the KV buffers had been allocated. So
  footprint follows the tokens actually held, not the context setting.
- Nothing else scales with context. Attention keeps running `m`/`d` partials
  (`Attention.swift:118-122`), not a score matrix. Prefill scratch is sized by
  the chunk cap, and slot buffers by slot count.
- Anchor: the 2026-09-22 long case (32 slots, 1024 cap, 4K context,
  3,015 + 602 = 3,617 tokens held) peaked at **4.04 / 4.18 GB** across two runs.

## Predictions

The settings are 32 slots, prefill chunk 1024 explicit, `--max-new 64`, and
the frozen sampling defaults. Prompt lengths are chosen to fill each context:
about 7K tokens for 8K and about 14K tokens for 16K.

- **P1: footprint at `runner-ready` does not depend on the context setting.**
  Both runs fall within 166–200 MB. *Falsified* if the 16K run's
  `runner-ready` exceeds the 8K run's by more than 50 MB, which would mean the
  KV is committed at allocation.
- **P2: 8K, about 7.1K tokens held.** Peak is 4.04–4.18 GB plus
  (7.1K − 3.6K) × 20,480 B ≈ +72 MB, giving **4.11–4.25 GB**, ±150 MB for
  allocator and page-cache noise. *Falsified* above 4.40 GB.
- **P3: 16K, about 14.1K tokens held.** Peak is 4.04–4.18 GB plus about
  +215 MB, giving **4.26–4.40 GB**, ±150 MB. *Falsified* above 4.55 GB. Either
  way it stays under 5.60 GB with more than 1 GB of margin, and **16K is
  offerable at 32 slots** unless P3 fails by more than 1 GB.
- **P4: decode slows with context, and not through bytes.** Decode
  bytes/token stays within the 2026-09-22 range, since routing is prompt
  dependent but the mechanism is unchanged. `cb1-wait` grows with the tokens
  held; it is 88.95 ms/forward at about 3.6K on 2026-09-16, and is expected
  here at roughly 1.5–2× that at 14K. This is recorded, not gated.
- **Prefill time (not gated).** About 7K tokens takes 3–5 min and about 14K
  takes 7–12 min at chunk 1024. The 3,015-token long case took about 76–90 s,
  and attention cost grows with position.

## What these runs do not settle

The chat app does not fill its context with one prompt. It reaches the same
token count across turns, through the retained KV. The pages committed are the
same, so the footprint should match, but the chat path is not what is being
run here.

## Addendum, written before the 16K rerun (2026-09-24)

The first 16K run was killed by jetsam (`proc-thrashing`, 4.44 GB). The user
asked whether something else on the phone caused it. The kill report says no:
the other 20 live processes held about 0.6 GB. The report showed 49 MB free,
3.29 GB wired, and the compressor holding about 5.3 GB in about 4.2 GB after
14.2M compressions. Hypothesis: the app is not killed for its size alone. Its
pages cycle through the compressor, because the GPU keeps touching them while
the expert corpus streams through the file cache.

The rerun uses the same binary plus phone-wide VM counters and one log line
per prefill chunk. The phone was freshly restarted, and nothing else is
opened.

- **P5: killed again, at a 4.3–4.5 GB footprint, during prefill.** Before the
  kill, `sys-free` falls below 100 MB and `compressions` climbs by more than 1M
  per chunk. *Falsified* if the run completes, in which case the first kill
  was not reproducible and 16K returns to consideration. *Also falsified* if
  it dies with `sys-free` above 500 MB or compressor traffic flat, in which
  case thrashing is not the mechanism.
