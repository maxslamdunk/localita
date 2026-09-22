# Prefill chunk cap above 256 — results

Scored against `predictions.md`, which was committed in `60d7c7b` before the
cap change and before any run. Binary at `78ac25d`, clean tree. iPhone 17,
8 GB, iOS 26.6. Side-loaded `gemma4.gturbo`, installed 2026-09-16, so **6 days
old** at these runs. Seven runs, logs in `logs/`.

Every arm ran on the **same binary**. The 2026-09-16 chunk-256 rows were taken
on a different one, so they are not used as the baseline; each case has its own
baseline run here.

## The matrix

| case | arm | chunk | chunks | prefill bytes (MiB) | reads | prefill s | tok/s | thermal |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| long (3,015 tok) | baseline | 256 | 12 | 104,248.91 | 32,546 | 120 | 4.490 | nominal |
| long | baseline r2 | 256 | 12 | 104,248.91 | 32,546 | 121 | 4.802 | fair |
| long | treatment | **1024** | 3 | **30,605.86** | 9,555 | 90.5 | 3.696 | fair→**serious** |
| long | treatment cooled | **1024** | 3 | **30,605.86** | 9,555 | **76** | 4.392 | mostly fair |
| medium (430 tok) | baseline | 256 | 2 | 15,317.34 | 4,782 | 17 | 5.388 | nominal/fair |
| medium | treatment | **512** | **1** | **8,875.86** | 2,771 | 13 | 4.894 | nominal/fair |
| short (61 tok) | control | 64 | 1 | 6,950.78 | 2,170 | 9 | 6.781 | nominal |

## Scoring

### P1 — prefill bytes. **HELD, precisely.**

Predicted 30–42 GB on the long case at chunk 1024; measured **32.09 GB**
(30,605.86 MiB). Predicted −68%; measured **−70.6%**. Falsifier F1 (>45 GB) did
not fire.

The underlying model was confirmed to three digits *before* the treatment ran:
it predicted 90.48 distinct experts per layer per chunk at 256, and the baseline
measured **90.4** (32,546 ÷ 30 ÷ 12). At 1024 it predicted 116.6 and measured
**106.2**, i.e. the distinct-expert count saturates faster than +13.5%/doubling
— which is why the bytes came in at the low end of the band rather than the
middle. The conservative direction, as intended.

Medium: **−42.1%** (16.06 → 9.31 GB), not separately predicted.

### P2 — prefill time. **MISSED. F2 fired on one run of two.**

Predicted −35 to −42%, with "less than 25% falsifies".

| | prefill s |
| --- | --- |
| baseline | 120, 121 (mean 120.5) |
| treatment | 90.5 (hot), 76 (cooled) — mean 83.3 |

Mean **−30.9%**, below the predicted band. On the hot run, **−24.6% — F2 fired**
by four tenths of a point. On the cooled run, −36.9%, inside the band.

**The baselines are tight (120, 121) and the treatments are not (76, 90.5).**
That 19% spread between two byte-identical runs is the finding: on this device
prefill *time* carries thermal noise comparable to the effect being measured,
while prefill *bytes* are deterministic. Recording the point prediction as
missed rather than rescuing it on the cooled run alone.

⚠️ A "prefill compute grows with chunk size" explanation was drafted from the hot
run, where the implied fetch rate exceeded anything the device can do. It
**weakens substantially on the cooled run** and is recorded here as unresolved,
not as a finding.

### P3 — no tok/s effect. **HELD as stated; the observed moves are not this change.**

The prediction was that decode is untouched. Decode byte profiles confirm it:
bytes/token 147.89 (baseline) against 147.52 MiB (both treatment runs, identical
to the digit), hit rate 80.8% throughout.

tok/s nonetheless moved run to run (long: 4.490, 4.802, 3.696, 4.392). The 3.696
run reached `serious` and shows the documented thermal signature — `io` +25.4%
against `cb1-wait` +10.9% at constant bytes. Medium's −9.2% is **left
unattributed**: its byte profile is unchanged but it was only mildly hotter, so
that sits at the edge of the ~8% device variance rather than inside it.

### P4 — memory. **HELD.**

Peak `phys_footprint` 3.92 / 3.97 / 4.04 / 4.18 GB against F3's 4.3 GB
threshold and the 5.60 GB jetsam floor.

An unplanned confirmation of the ring arithmetic: the baseline arm peaks at
**3.97 GB against 3.81 GB on record** for the same case and settings on the old
binary — **+160 MB measured against +152.4 MB predicted** for the KV ring. This
binary pays the ring on every run because the cap is static, so only the ~+94 MB
of scratch separates the two arms.

### P5 — quality. **HELD.**

Token counts identical within every case: long 602 / 602, medium 632 / 632,
short 507. F4 did not fire. Quality-neutral by construction, as with the slot
and chunk sweeps before it.

## The short control, and what it caught

Short was run because `auto` resolves a 61-token prompt to 64 **both before and
after** the cap change, so its chunk is untouched while it still pays the ring.
It answers what the long case cannot: does a prompt that gains nothing get hurt?

It does not. Peak 3.92 GB, all `nominal`, and prefill bytes **6,950.78 MiB —
identical to the digit** to the 2026-09-16 record.

**All three baselines reproduce the 2026-09-16 chunk-256 figures exactly:**
6,950.78 / 15,317.34 / 104,248.91 MiB. Prefill read volume is deterministic and
binary-independent, which is what makes these baselines trustworthy.

## An unrelated regression this surfaced, not caused by this change

At **identical prefill byte volume and identical decode byte profiles**, decode
is slower than the 2026-09-16 rows across all three cases:

| case | tok/s here | 2026-09-16 | |
| --- | --- | --- | --- |
| short | 6.781 | 7.596 | −10.7% |
| medium | 5.388 | 6.204 | −13.2% |
| long | 4.490 / 4.802 | 5.206 | −7.8 to −13.8% |

Short is the clean case: same chunk, same bytes, same slots, all `nominal`, and
still −10.7%. So this is not chunk size and not thermal. Long-case decode `io`
is 127.13 ms/forward against 109.69 at the same 32 slots — **+15.9% at constant
bytes**, which is a storage signature, not a compute one.

The leading candidate is **artifact aging**: the device corpus was written
2026-09-16 and is 6 days old here, against 0 h then, and `CLAUDE.md` documents
exactly this decay on the Mac ([IO-13](../docs/experiments/summaries/01-model-install-and-expert-io.md#io-13)). The 0.8 merge is a second candidate and
has never been measured on device. **n=1, unseparated, and not a claim** — it is
logged so it is not mistaken for an effect of the cap change, and because it is
the first device-side evidence bearing on IO-13.

## Disposition

Keep the cap at 1024 on iOS. The byte result is large, deterministic,
quality-neutral and reproduced; the time result is real but noisier than
predicted.

**Medium is now at the floor** — `auto` gives it 512, one chunk, every expert
read once (92.4 of 128 per layer). No further cap raise can help a prompt of
≤512 tokens.

**Long is not at its floor.** Three chunks at 1024 read 32.09 GB against a
~12.1 GB one-chunk floor, so ~2.6x remains. Taking it would need the cap at
4096, costing ~377 MB of scratch and a further ring increase, and P2 says the
time return on that is smaller than the byte return. Not proposed here; it needs
its own prediction.
