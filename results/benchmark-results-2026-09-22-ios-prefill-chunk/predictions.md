# Prefill chunk cap above 256 — predictions

Written **before** implementation and before any run, per the working agreement
in `CLAUDE.md`. Device: iPhone 17, 8 GB, iOS 26.6. Artifact: the side-loaded
`gemma4.gturbo`, same bytes as the Mac reference.

## The finding this rests on

Prefill's 0.0% expert-cache hit rate is **structural, not a defect**, and three
independent sources in the repo already say so:

- `docs/RUNTIME_CONTROLS.md`: "Chunks loop outside layers, so each one re-reads
  that layer's routed experts."
- `PrefillRuntimeConfig.swift:222`: "read volume tracks chunk count ... On an
  11,612-token prompt that meant 578 GB read from a 12 GB pool with no cache
  hits at all."
- Confirmed in code: `RealForwardRunner.prefillChunked` (:537) drives
  `forEachSpan` (outer = chunks), and `executePrefillChunk` (:694) opens
  `for L in 0..<cfg.numLayers` at :944 (inner = layers).

Within one chunk, `PrefillMoEGrouping.groupTokenExpertPairs` already coalesces
the chunk's token×top-8 pairs into **one group per distinct expert**, so each
expert is read at most once per (chunk, layer). There is no repeat request left
inside a chunk for a cache to hit. Across chunks, a layer is revisited only
after all 30 layers have been walked, so retaining it would need the whole
12.9 GB corpus resident.

**Therefore the metric to move is prefill bytes, not prefill hit rate.** At the
floor — one chunk covering the prompt — every expert is read exactly once and
the hit rate is *still* 0.0%. A run that "fixes" the hit rate without lowering
bytes has achieved nothing.

## Mechanism

Reads = `chunks × layers × D(chunk)`, where `D` is the distinct experts a chunk
selects in one layer, out of 128. Fewer, larger chunks cut the `chunks` factor
faster than `D` grows toward its 128 cap. The floor is one chunk:
`30 × 128 × 3,358,720 B = 12.9 GB`, the corpus read once.

`D` is measured, not assumed, from the two existing long-case runs
(3,015-token prompt):

| chunk | chunks | prefill bytes | D (distinct/layer/chunk) |
| --- | --- | --- | --- |
| 128 | 24 | 192.7 GB (measured) | 79.68 |
| 256 | 12 | 109.4 GB (measured) | 90.48 |

That is +13.5% in `D` per doubling, which matches the 13.6–20.8% per-chunk
growth `docs/IOS_PORT.md` records. Projections below carry that same +13.5%
forward and cap `D` at 128 — deliberately conservative, since `D` must saturate
as it approaches the cap, so this **over**-predicts bytes and **under**-predicts
the saving.

## Predicted prefill bytes, long case (3,015 tokens)

Baseline is chunk 256 = 109.4 GB, which is what iOS `auto` resolves to today for
this prompt.

| chunk | chunks | D | predicted bytes | vs. 256 | vs. 128 |
| --- | --- | --- | --- | --- | --- |
| 512 | 6 | 102.7 | **62.1 GB** | −43% | −68% |
| 1024 | 3 | 116.6 | **35.3 GB** | −68% | −82% |
| 2048 | 2 | 128.0 | **25.8 GB** | −76% | −87% |
| one chunk | 1 | ≤128 | **12.9 GB** | −88% | −93% |

**Headline prediction, the one to score: chunk 1024 reads 30–42 GB of prefill on
the long case, against 109.4 GB at chunk 256.**

## Predicted prefill time

Decomposing the chunk-256 baseline (prefill 113.7 s, from 168 s at −32.3%):
at the device's measured 1.7 GB/s fetch, 109.4 GB is ~64 s of reads, leaving
~50 s of compute that chunk size does not remove.

| chunk | predicted io | + compute | prefill time | vs. 256 |
| --- | --- | --- | --- | --- |
| 1024 | ~21 s | ~50 s | **~71 s** | **−35 to −42%** |
| one chunk | ~8 s | ~50 s | **~58 s** | −45 to −52% |

So the lever **saturates against compute**, and the floor is worth only ~13 s
more than chunk 1024. That is the honest shape of it.

Long-case end-to-end wall: 243.3 s → **~200 s (−18%)** at chunk 1024.

⚠️ **This does not improve tok/s.** Decode reads are untouched, and the
protocol's tok/s is a decode rate. Anyone quoting a tok/s gain from this change
has measured thermal drift or run-to-run variance, not the change — exactly the
error `docs/IOS_PORT.md` records against the chunk-256 run, where a 5–10% decode
move on an unchanged byte profile turned out to be ~8% ordinary variance.

## Predicted cost

Prefill scratch is 125.5 KB/token over a fixed 328 KB:

| chunk | scratch |
| --- | --- |
| 256 (today) | 31.7 MB |
| 512 | 63.1 MB |
| 1024 | **125.8 MB** |
| 3072 | 376.8 MB |

Against 1.79 GB of headroom (3.81 GB peak vs. the measured 5.60 GB jetsam
floor), chunk 1024 costs **+94 MB over today**, ~5% of headroom.

**The KV ring was listed here as the real unknown. It has since been resolved,
before implementing, and it is larger than the scratch.** `RealForwardRunner.swift:250`
sizes `KVCacheManager` with `maxPrefillChunkTokens: max(maxChunkTokens, 280)` —
the **static cap, not the configured chunk**, because the server picks a
per-request size and the ring cannot be reallocated per request. `KVCacheManager`
gives each sliding-window layer `min(maxContext, slidingWindow + that)` tokens of
K and V:

| cap | swaCapacity | ring bytes | delta |
| --- | --- | --- | --- |
| 256 (floors to 280) | 1,304 | 267.1 MB | — |
| 512 | 1,536 | 314.6 MB | +47.5 MB |
| 1024 | 2,048 | 419.4 MB | **+152.4 MB** |

25 sliding-window layers (the mask sets full attention at 5, 11, 17, 23, 29) ×
capacity × 4,096 B/token × 2 for K and V.

**So the total cost at cap 1024 is +246.5 MB, not the +94 MB the scratch line
alone implied**, and the ring half is paid by *every* run on the platform —
decode-only ones included — not only by runs that select a big chunk. That is
what forces the cap to be platform-split rather than simply raised: the 8 GB
macOS validation host would pay 152.4 MB for a ceiling it has no headroom to
use. Peak footprint becomes ~4.06 GB against the 5.60 GB floor, which keeps
falsifier 3 below meaningful rather than pre-satisfied.

`PrefillRuntimeConfig.swift:225` stated the requirement directly: "512 is the
first size that costs anything, and raising this past 280 should come with a
test that asserts ring bytes the way `PrefillChunkScratchTests` asserts
scratch." `KVRingChunkCapTests` is that test, and it is a precondition of this
change rather than a follow-up.

## Falsifiers

Written now so they cannot be chosen after the fact.

1. **Bytes.** Prefill bytes at chunk 1024 exceed **45 GB** on the long case →
   the +13.5%/doubling growth in `D` is wrong and saturation is slower than the
   two measured points imply.
2. **Time.** Prefill time at 1024 falls by **less than 25%** vs. 256 → prefill
   is already compute-bound, the read half is smaller than the byte count
   suggests, and the remaining chunk-size headroom is not worth spending.
3. **Memory.** Peak `phys_footprint` at chunk 1024 exceeds **4.3 GB** → the
   scratch and ring accounting above is wrong and the headroom claim fails.
4. **Quality.** Generated token counts differ from the chunk-256 run at the same
   seed → the change is not quality-neutral, which it must be by construction;
   chunk size changed no output in either prior sweep.

## Recorded non-prediction

A secondary effect was noticed while reading the code and is **not** predicted
or claimed here, because it has no measurement behind it:
`PrefillMoEGrouping.groupTokenExpertPairs` sorts each chunk's tiles by physical
disk offset, so every chunk walks the layer's experts in the same low-to-high
order. The ~32 experts resident when chunk *c* ends are therefore the
highest-offset ones, and chunk *c+1* starts again at the lowest — the classic
sequential-scan eviction pattern, which is a candidate explanation for the hit
rate being *exactly* 0.0% rather than merely low. Alternating that order between
chunks would be the test. It is recorded here only so the observation is not
lost; it is a separate experiment with its own prediction, and raising the cap
makes it less valuable by removing chunk boundaries.
