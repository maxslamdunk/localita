# Model installation and expert I/O

[Experiment inventory](../EXPERIMENT_INVENTORY.md) |
[Optimization journey](../../OPTIMIZATION_JOURNEY.md) |
[Next: Decode, MoE, INT4, and router](02-decode-moe-int4-and-router.md)

The model's routed-expert pool is much larger than physical memory, so disk
access is part of every decode step. These experiments established the bounded
remote installer and the demand-read path used by the frozen M2 reference
runtime.
The entries retain their stable ID order, so the installer that creates the
runtime artifact appears last.

| Current result | Disposition |
| --- | --- |
| Remote range repack with 512 KiB peak payload and scratch heap | Production |
| Default bounded parallel miss-read path | Production |
| Whole-pool `mmap`, `mlock`, compression, speculative reads, and MTLIO | Rejected |
| Fetch-path bandwidth gap vs. the SSD roof | Closed as nonexistent |
| Install-time write order (~1.3x on read rate, 0 bytes/token) | **Transient — paid +14–20% at 0 h, decayed to ~0 by 7 d**, [IO-12](#io-12) |
| Read rate falls after write — now the dominant open question | **Open, unexplained; upgraded 2026-08-18**, [IO-13](#io-13) |

## Runtime expert I/O

<a id="io-01"></a>
### IO-01: `mmap` versus `pread`

- **Hypothesis:** Faulting mapped expert pages might avoid copies and beat
  explicit reads.
- **Variants tested:** Cold and warm `mmap`, sequential and
  parallel `pread`, and a full-token simulator.
- **Evidence:** A cold expert read
  took 9.88 ms with `mmap` and 2.79 ms with `pread`, about a 3.5x difference.
  Warm `mmap` won its local comparison, but the expert working set exceeds usable
  cache on the target machine. The simulator reached 3.97 tok/s with parallel `pread` and
  0.50 tok/s with `mmap`.
- **What changed the conclusion:** Warm-file results
  ceased to matter once the gate modeled continual cold misses.
- **Final disposition:** Production uses bounded parallel `pread`.
- **Lesson:** Benchmark
  the cache state the application can sustain, not the cache state a microbench
  can manufacture.

<a id="io-02"></a>
### IO-02: Parallel reads and command-buffer coalescing

- **Hypothesis:** Concurrent expert reads and fewer GPU submissions would reduce
  the two largest early stalls.
- **Variants tested:** The serial stage-0 path,
  parallel `pread`, and parallel `pread` plus command-buffer coalescing.
- **Evidence:** Decode moved from about 1.13 to 2.08 tok/s with parallel reads and
  to about 2.13 tok/s after coalescing.
- **What changed the conclusion:** Nothing;
  later stages kept the structure.
- **Final disposition:** Production.
- **Lesson:**
  Fix the largest wall-time bucket before tuning arithmetic inside a smaller one.

<a id="io-03"></a>
### IO-03: Darwin file hints

- **Hypothesis:** Darwin-specific caching and read-ahead controls could improve
  miss service without changing the data path.
- **Variants tested:** `F_RDAHEAD=0`, `F_NOCACHE`, and Darwin
  [`F_RDADVISE`](04-rdadvise.md), which advises the kernel about upcoming file
  ranges.
- **Evidence:** The first two were neutral.
  Untimed ahead advice reached 3.61-3.78 GB/s and justified a real-decode
  candidate.
- **What changed the conclusion:** Because advice ran outside the
  timed body, the probe justified only a separate real-decode program.
- **Final disposition:** The simple hints are rejected; RDADVISE is evaluated separately.
- **Lesson:** A
  promising system-call probe earns an end-to-end test, not immediate promotion.

<a id="io-04"></a>
### IO-04: Dedicated expert-I/O executor

- **Hypothesis:** A controlled executor and split-read schedule would outperform
  the existing concurrent reads.
- **Variants tested:** Worker and submission
  counts around the production path.
- **Evidence:** The best executor result was
  8.59 ms; the existing path measured 8.42 ms. Real decode was unchanged at four
  and eight workers.
- **What changed the conclusion:** The candidate failed its
  first production comparison.
- **Final disposition:** Rejected.
- **Lesson:** A new
  scheduler must beat the existing concurrency, not merely expose more controls.

<a id="io-05"></a>
### IO-05: Custom I/O worker pool

- **Hypothesis:** A fixed custom worker pool could beat bounded parallel miss
  reads.
- **Variants tested:** The default path and a four-worker override in
  repeated 256-token decode.
- **Evidence:** The pairs were mixed: 5.964 to 6.132
  tok/s, then 6.093 to 6.022; profile I/O stayed at 71.3 ms/token.
- **What changed the conclusion:** The repeated pair reversed the first result.
- **Final disposition:** The custom worker override was rejected; production retains
  parallel reads over the current miss set.
- **Lesson:** A concurrency wrapper
  must beat the existing parallel work distribution across repeated rows.

<a id="io-06"></a>
### IO-06: `mlock` and resident-model pages

- **Hypothesis:** Expert streaming evicted the 1.58 GB resident model, so pinning
  it should restore GPU time.
- **Variants tested:** Locked resident buffers and a
  diagnostic run that skipped streaming.
- **Evidence:** `mlock` recovered
  essentially 0 ms. Skipping expert streaming recovered about 12-14 ms.
- **What changed the conclusion:** The mechanism was memory-system contention,
  not resident-page eviction.
- **Final disposition:** Rejected.
- **Lesson:** Prove
  the mechanism before choosing a remedy with a large memory-policy cost.

<a id="io-07"></a>
### IO-07: Expert compression

- **Hypothesis:** Compressing expert blobs could reduce bytes read enough to pay
  for decompression.
- **Variants tested:** Zstandard and LZ4 over representative
  packed experts.
- **Evidence:** Zstandard saved about 10%; LZ4 saved 0.06%.
- **What changed the conclusion:** Neither ratio supported the required CPU work
  and format complexity.
- **Final disposition:** Rejected.
- **Lesson:** Already
  quantized weights may contain too little redundancy for transparent runtime
  compression.

<a id="io-08"></a>
### IO-08: Speculative expert reads

- **Hypothesis:** Reading or advising likely future experts could convert misses
  into warm page-cache hits.
- **Variants tested:** Entry probes followed by a
  paired real decode with speculative reads enabled.
- **Evidence:** Probes showed post-advice residency and up to 10.63 GB/s. In
  the first end-to-end pair, decode fell from 4.937 to 4.742 tok/s, total
  prefill wall time rose from 82.50 to 123.64 s, and emitted IDs diverged. The
  pair therefore failed both its speed and token-parity gates.
- **What changed the conclusion:** The probe measured page residency,
  not lead time, contention, or pipeline behavior.
- **Final disposition:**
  Rejected.
- **Lesson:** A mechanism probe cannot substitute for the first clean
  end-to-end pair. Cache prediction and replacement are covered in the
  [cache summary](03-expert-cache-prediction-and-layout.md).

<a id="io-09"></a>
### IO-09: MTLIO

- **Hypothesis:** A GPU-oriented I/O queue could remove CPU staging for routed
  experts.
- **Variants tested:** Warm MTLIO reads and production miss-state
  classification.
- **Evidence:** Warm reads reached 13.1-13.3 GB/s, but only
  5.4-7.5% of observed misses were fully warm.
- **What changed the conclusion:**
  The fast state was too rare to control token time.
- **Final disposition:**
  Rejected for the runtime.
- **Lesson:** Optimize the state distribution the
  application occupies, not the fastest state an API exposes.

<a id="io-11"></a>
### IO-11: The fetch-path bandwidth gap that was not there

- **Hypothesis:** The decode `io` phase moved bytes at 41–50% of the device's
  measured SSD roof, so roughly half of 202 ms/forward was being lost between
  the SSD and the runtime — a large, quality-free, non-bytes/token win.
- **Variants tested:** Four standalone probes against the *installed* layer
  files, model process never started: an `F_LOG2PHYS_EXT` extent map; serial
  random `pread` at production shape (30 fds, 3,358,720 B, 12.01 GiB working
  set); `dispatch_apply` fan-out at queue depths 2, 3, and 8; and fresh 6 GiB
  control files filled with zeros and with incompressible data.
- **Evidence:** A bare serial `pread` of the real files reached **1.36 GB/s**,
  against production's in-situ 1.30–1.34 — the runtime achieves **94–96% of
  achievable**. The 2.7–3.2 GB/s "roof" reproduced only on a **zero-filled**
  file (2.36 GB/s); incompressible data at identical fragmentation gave 0.77
  GB/s, 3.1× apart on content alone. Queue depth was flat (1.43–1.55 GB/s
  aggregate). Every production read spans 4.30–8.62 discontiguous extents, yet
  2.3× more extents/read cost only ~11% latency, and a file written on the
  now-92%-full volume lands at 18 extents/read — worse than the installed
  artifact. **Scope limit on that slope:** it was fitted inside the 4.30–8.62
  range the installed files happen to span. No file on this volume has a
  physically adjacent extent boundary, so the cost of a *contiguous* 3,358,720 B
  read is unmeasured here and cannot be obtained by extending the fit. Its
  honest upper bound is the sequential-vs-random gap at equal request size,
  1.71 vs 1.39 GB/s (~19%).
- **What changed the conclusion:** The roof, not the runtime. The original
  probe's file contents were never recorded, and zeros do not pay NAND cost.
  INT4 expert weights are incompressible ([IO-07](#io-07): LZ4 saved 0.06%), so
  no model byte could ever have reached that rate.
- **Final disposition:** The 2.2× gap is closed as nonexistent. State the
  baseline for anything claimed here: production is at **94–96%** of a bare QD1
  serial read, **~90%** of a barrier-synchronized fan-out at its own depth of
  ~2.6 misses/layer, and **~72%** of the 1.82 GB/s steady-state random ceiling —
  a pipeline the cb1/io/cb2 dependency cannot form, since `cb2` needs every
  expert of the layer. [CACHE-09](03-expert-cache-prediction-and-layout.md#cache-09)
  preallocation would *degrade* the installed artifact **on this 92%-full
  volume** and should stay unexecuted here; that is not a verdict on install-time
  layout on an iOS device with free space, which is untested.
- **Open lead, not closed by this entry:** per layer, `io` is 6.74 ms for 2.6
  reads while serial would be 6.43 ms — the `DispatchQueue.concurrentPerform`
  fan-out in `executeExpertCachePlan` is achieving serial-equivalent throughput.
  This probe found the same shape: `dispatch_apply` 1.43–1.55 GB/s vs. real
  pthreads 1.63–1.67, because GCD's cooperative pool need not supply a thread
  per iteration for *blocking* work. [IO-04](#io-04) and [IO-05](#io-05) rejected
  worker pools, but both were judged on end-to-end tok/s before
  `DecodePhaseTimings` existed and could not see whether `io` itself moved.
  Predicted if tested: 0 bytes/token, `io` −10 to −25 ms/forward; falsified if
  `io` is unchanged within run-to-run noise.
- **Lesson:** A bandwidth roof is a property of the bytes as much as the device.
  Probe with data as incompressible as production's, on the production artifact,
  and record the fill — a synthetic file measured the storage stack, not the
  storage. This is the same class of error as [IO-01](#io-01) and
  [IO-09](#io-09): a probe manufacturing a state the application never occupies.

<a id="io-12"></a>
### IO-12: Write order sets read throughput at first — but the gain does not last

- **Hypothesis:** [IO-11](#io-11) closed the bandwidth gap by showing production
  reaches 94-96% of what the installed files deliver. That left an unexplained
  residual — nothing on this host reaches the ~2.6-3.0 GB/s quoted for the drive
  class — and the standing candidate was physical layout, since every installed
  read spans 4.30-8.62 discontiguous extents.
- **Variants tested:** Sequential pass1 across 8 layer files spanning the
  fragmentation range; equal-length flushed A/B between two files with identical
  extents/read; read-offset controls; a new `physorder.c` measuring extent
  ordering, jump distance, and physical spread; single-stream `cp` copies of two
  installed files; a 10-month-old fragmented control. Every read preceded by a
  12.01 GiB flush, 8× the page cache.
- **Evidence:** Fragmentation correlates *within* the layer files — 3.67 to 8.62
  extents/read tracks 1.78 down to 1.54 GB/s, **-13.5%**, replicating IO-11's
  ~11% slope by a different method. It then fails every cross-file test.
  `model_weights.bin` (7.84 extents/read) beats `layer_25.bin` (7.82) by **+17%**
  at equal length and both orderings, and `physorder.c` shows the *faster* file
  has the *worse* ordering (67.4% forward jumps vs 85.9%, mean |jump| 39.6 GiB
  vs 1.1 GiB) — the expected null on flash, which has no seek. What does predict
  the rate is age: a `cp` of `layer_25.bin` reads **3.11-3.37 GB/s** minutes
  after being written against the 29-hour-old original's **1.49-1.51**, and a
  copy of `model_weights.bin` reads **3.17 vs 1.95**. Both copies land at ~3.2
  despite a 1.7× spread in their own fragmentation, which is what rules layout
  out. Matched at 0.40 GiB: fresh `relaid_25.bin` (2.52 extents/read) 3.20 vs
  29-hour-old `layer_09.bin` (3.67) 1.78 — and `relaid_mw.bin`, at 4.28
  extents/read, is *more* fragmented than `layer_09` and still **78% faster**.
- **What changed the conclusion — twice, and the second time reversed it.** The
  first read of the evidence was "recency dominates, layout is a mirage." It came
  from a scramble control that held freshness constant and shuffled write order
  in **8 MiB** blocks, which showed no effect (3.06/3.08 vs 3.03/3.10). That
  block size is too coarse: an 8 MiB run already saturates the channels on its
  own. Re-run at **256 KiB** (`Scripts/probes/scramblewrite.c`), the same control
  gives **1.92-1.98 GB/s scrambled vs 3.16-3.22 sequential — 1.64× from write
  order alone, at equal age.** Not fragmentation (3.05 vs 2.52 extents/read is
  worth ~3% by this entry's own slope) and not APFS-visible ordering (scram256
  has *fewer* forward jumps and is not thereby explained). **So both factors are
  real and roughly multiplicative**, which is also what finally explains why
  `model_weights.bin` outreads `layer_25.bin` at identical extent counts: it is
  written by the installer as one stream, while the 30 layer files are written
  interleaved as remote shards arrive.
- **Final disposition:** **Write order is a persistent lever; recency is not, and
  is still untested.** Measured cells: fresh+sequential 3.19, fresh+scattered
  1.95, old+sequential 1.95-2.02, old+scattered 1.50. Rewriting each layer file
  in a single sequential pass should move production from the last cell toward
  the third — **~1.3× on the read rate at 0 bytes/token** (confirmed at that
  magnitude by the slot-geometry re-measurement below, after an interim ~1.5×
  claim taken with the wrong access pattern), since the same bytes are read and
  only their placement changes. Falsified if a sequentially
  rewritten layer file, once aged, reads no faster than the installed original.
  This reopens [CACHE-09](03-expert-cache-prediction-and-layout.md#cache-09) on a
  new argument — not preallocation, which measured worse here, but *write
  order*, which was never the thing tested.
- **Decay re-test, 2026-08-11 — both terms confirmed, and they are
  independent.** The bare re-read planned for this would not have been
  conclusive: it confounds decay with machine-state drift, and a null is
  unreadable, since SLC folding is triggered by idle and write pressure and
  "no decay" could equally mean "not folded yet." Run instead with **0-hour
  controls written in the same session**, so every cell shares one machine state.
  Sequential 3.23 (0 h) → 2.74 (24 h); shuffled 2.10 (0 h) → 1.80 (24 h);
  installer-written 1.60 (53 h). **Recency decays ~15% per 24 h. Write order is
  1.54× at 0 h and 1.53× at 24 h — the ratio survives the decay intact**, which
  is what proves the two are separate mechanisms rather than one seen twice.
  Extent count is ruled out a third time, by accident: the newer controls landed
  *more* fragmented (4.41 vs 2.52; 8.09 vs 3.05, on less free space) and read
  faster anyway. A "53 h sequential" cell was attempted with `model_weights.bin`
  (2.00 GB/s) and **discarded** — it is 3× the size, worth ~9% on its own, and
  its sequential write pattern was never verified, only inferred.
- **Access geometry corrects the magnitude, 2026-08-11: the lever is ~1.3×, not
  ~1.5×.** Every cell above was measured with whole-file reads; production issues
  *random* 3,358,720 B slot reads, and the ratio does not survive the change of
  geometry. Re-measured with `Scripts/probes/slotscan.c` — every slot read exactly
  once in shuffled order, so repeats cannot be served from the ~1.44 GB page cache
  — the write-order ratio is **1.29× at 0 h (2.30 vs. 1.78 GB/s) and 1.34× at
  25 h (2.08 vs. 1.55)**. The mechanism and the disposition are unchanged and it
  still does not decay; only the size is smaller, at ~85% of what whole-file reads
  implied. Recency shrinks under the same change, to −9.6%/24 h sequential and
  −12.9%/24 h shuffled — figures that are **split out as open in [IO-13](#io-13)**,
  since one interval cannot establish a rate. The probe is validated against the accepted baseline: it
  reads the installed `layer_25.bin` at 1.34–1.41 GB/s, matching the 1.36–1.40
  bare-serial figure in the measured-facts table. **Lesson worth carrying: a
  storage effect measured under one access pattern does not transfer to another
  at face value.** Sequential reads flatter placement, because readahead hides
  part of what bad placement costs.
- **Queue depth stacks with it, and the pair reaches the drive's advertised rate
  (2026-08-11).** `Scripts/probes/slotscanqd.c` partitions the shuffled slot order
  across real pthreads. Queue depth is worth **~1.17–1.19× on both files** —
  installed 1.35 → 1.61 GB/s at QD2–4, sequentially written 2.32 → 2.71 — so it
  is an independent multiplier, not the same headroom seen twice. QD8 collapses on
  both, reproducing the known saturation signature; QD2–4 is the sweet spot, and
  production's own average of ~2.6 misses/layer already sits there. **A file that
  is sequentially written *and* fresh, read at QD2–4, hits 2.64–2.79 GB/s** — the
  ~2.65 GB/s long quoted for this drive class is real and reachable, and every
  earlier failure to reach it was measuring an artifact that had none of the three
  properties. Projected steady state after a sequential rewrite: 1.375 × 1.29 ×
  1.17 ≈ **2.0–2.1 GB/s** vs. 1.30–1.34 today. **Asymmetric confidence: bank the
  ~1.3×, treat the queue-depth term as upside contingent on
  [IO-11](#io-11)**, which records the existing `concurrentPerform` fan-out
  buying ~nothing, and which the cb1/io/cb2 dependency caps because `cb2` needs
  every expert of the layer before it can start.
- **Why the prediction is ~1.3× and not the full 1.67×.** Under slot reads the two
  terms are close to equal — write order 1.29× and age 1.29× (0 h → 53 h) — and
  they compose to the 1.67× between what production reads today (installed,
  53 h, 1.375 GB/s) and a fresh sequential copy (2.30). Only the write-order term
  is claimable, and not because the other is being discarded: the correct
  comparison for the lever is **aged sequential vs. aged scattered**, since both
  arms of a real deployment are old. Recency applies to both and cancels. The
  1.67× is reachable only by keeping the model perpetually freshly written, which
  costs a 12.01 GiB rewrite per session to rent a term that begins decaying
  immediately — rejected on write amplification alone, and flatly impossible on
  iOS.
- **What is still open:** the decay curve past 24 h. Production files only get
  older, and the installed set reads 1.58–1.63 at 53 h, so steady state sits
  below the 24 h figure — but no matched pair exists beyond 24 h. The 53 h
  installer file sits 11.6% below the 24.5 h shuffled control under slot reads,
  which *suggests* decay continues rather than flattening, but the two differ in
  write pattern as well as age. Six controls are retained in `/tmp` for later
  re-reads. This does not gate the write-order lever, which is worth ~1.3× at
  both ages tested.
- **Verified in code, 2026-08-11 — the interleave is confirmed, and its cause is
  the range planner, not concurrency.** There are no concurrent writers:
  `HTTPRangeSourceByteProvider.copyBatch` is a single sequential loop. The
  scattering comes from *what that loop iterates over*.
  `RangeCopyPlanner.plan` builds the copy list in destination order (layer 0..N ×
  expert 0..127 × {gate,up,down} × {weights,scales,biases}), and then `coalesce`
  **re-sorts the whole list by `(shardID, sourceOffset)`** — source order — to
  merge adjacent source ranges into single HTTP requests. So the outer loop walks
  the remote shards front to back, and each coalesced range `pwrite`s into
  whichever layer files its tensors happen to belong to. An `outputFDs` cache
  holds every touched layer file open for the entire copy phase, closed only at
  the end. Writes to a given `layer_NN.bin` are therefore interleaved with the
  other 29 across the whole install, and **non-monotonic in offset even within
  one file**, since gate/up/down and weights/scales/biases live at unrelated
  source offsets. Two incidental findings: the files are pre-sized with
  `ftruncate` before any payload is copied — which on APFS creates a sparse file
  and reserves no extents, so it does not constrain placement — and `fsync` is
  called on every touched fd once per coalesced range to support resumable
  install, i.e. dozens of times per layer file rather than once at close.
- **VALIDATED END-TO-END, 2026-08-11 — the lever paid out, and it is now spent.**
  All 30 `packed_experts/layer_NN.bin` were rewritten sequentially in place with
  `Scripts/probes/seqrewrite.c` (8 MiB read → single ascending `write()` stream
  → `fsync` → hash-verify the temp against the source → atomic `rename` →
  `fsync` the directory; no `F_PREALLOCATE` and no `ftruncate`, matching the
  control that reads 2.30 GB/s, and requiring an explicit `--commit`).
  `--verify-install` clean afterwards: 37 files, 14,291,915,755 bytes. Paired
  cold `slotscan` on three files, before → after: 1.58 → 2.65, 1.39 → 2.16,
  1.39 → 1.91 GB/s. Then `real-generation-v1`, defaults, warmups discarded, all
  three `stop=endOfTurn` with token counts identical to the `ce287b6` baseline:
  **tok/s 3.102 → 3.725, 2.890 → 3.306, 2.592 → 2.978 (+20.1% / +14.4% /
  +14.9%)**; **`io` 202.1 → 152.40, 209.7 → 169.61, 228.4 → 182.64 ms/forward**
  (×1.33 / ×1.24 / ×1.25); **achieved fetch bandwidth 1.30–1.34 → 1.64–1.72
  GB/s**. **Prediction vs. measured: `io` predicted ~155 ms on the short case,
  measured 152.40 — inside the range, marginally better.** **Bytes/token
  predicted 0 ± 0 and measured 0 ± 0** — 249.72 / 265.90 / 291.42 MiB, identical
  to the digit, with hit rate and req/tok also unchanged, which is the control
  proving placement and only placement changed. `cb1-wait` 95.3 → 91.72, so the
  compute phase did not regress. **Two limits on what this licenses.** The files
  were ~0 h old, so part of the gain is the rented recency term ([IO-13](#io-13));
  the measured ×1.24–1.33 lands on the write-order-only prediction and far below
  the 1.54× a fresh single file shows under `slotscan`, which *suggested* recency
  contributes little at 12.01 GiB corpus scale — an inference the t ≥ 24 h re-run
  had to confirm before 3.725 could be quoted as steady state. **It did not. See
  the correction below.** And the lever **cannot be claimed twice**: the artifact
  is sequentially written now.

- **CORRECTION, 2026-08-18 — the gain decayed to nothing.** The re-run was taken
  at **t = 7 d 16.8 h** on the same artifact, same binary, same seeds, artifact
  untouched. **3.725 / 3.306 / 2.978 → 3.271 / 2.858 / 2.674** (−12.2% / −13.5% /
  −10.2%), `io` 152.40 / 169.61 / 182.64 → **187.33 / 213.01 / 216.29**, fetch
  1.718 / 1.644 / 1.673 → **1.333 / 1.248 / 1.347 GB/s**. Against the *scattered*
  artifact the rewrite replaced, what is left is **+5.4% / −1.1% / +3.2%** — and
  that baseline carries a ~3% Spotlight-reindex handicap this run does not, so
  the surviving gain is within noise of zero. On the medium case the rewritten
  artifact is now **slower** than the scattered one. **Prediction vs. measured:
  predicted 3.45–3.55 on short (a one-time step the size of the 0 h→25 h control
  move), measured 3.271 — a miss on the low side.** Controls that make this
  trustworthy: generated text **byte-identical** across all three cases,
  bytes/tok and hit rate and req/tok unchanged to the digit, and `cb1-wait` moved
  only +0.7 to +2.5% while `io` rose 18–26%, so the regression is confined to
  storage rather than a globally slower machine. ⚠️ **Confounded:** ~34 GiB was
  deleted between the runs (volume 91% → 74% full), a TRIM/GC event large enough
  to relocate valid data; "7-day decay" and "GC destroyed the placement" both fit
  and this run could not separate them. **The GC half is now RETRACTED
  (2026-08-19):** a cold probe of the aged artifact taken immediately before it
  was rewritten again read **1.82 GB/s** — against 1.45 for the scattered
  artifact and 2.24 for a fresh rewrite — so its placement was **still largely
  intact**. GC did not destroy it. The files kept most of their advantage while
  production kept none, which moves the question out of storage; see the
  2026-08-19 entry below. **Consequence: the product change is withdrawn.** Teaching
  `RangeCopyPlanner`/`copyBatch` to write sequentially would buy a first-session
  speedup that decays under ordinary use, which does not justify the work against
  the bounded-memory constraint that produced the scattering. It becomes
  justified again only if someone shows the gain persists, or identifies GC as
  the cause and finds a layout that survives it. The **invariant still stands**
  unconditionally — nothing may deliberately scatter the files, because avoiding
  that is free.
  This also settles the [CACHE-09](03-expert-cache-prediction-and-layout.md#cache-09)
  reopening in favour of write order over preallocation.
- **Lesson, independent of how it resolves:** a benchmark taken shortly after
  installing the model can overstate the `io` phase by up to ~2×. Record the
  model's age on disk with every performance number, and treat any community
  figure without it as uncomparable. IO-11 said a bandwidth roof is a property of
  the bytes as much as the device; this adds that it is a property of *when the
  bytes were written*.

- **2026-08-19 — second rewrite, on a 74%-full volume, and an unexpected
  fetch-path finding.** Repeating the rewrite after ~34 GiB was freed (91% →
  74% full) improved the artifact and set a project record on the short case:
  **3.937 tok/s, `io` 141.28 ms/fwd, fetch 1.768 GB/s, bytes/token unchanged at
  249.72 MiB.** Free space is a real factor in placement quality — the
  fresh-rewrite probe mean rose **2.24 → 2.48 GB/s (+10.5%)** for the identical
  operation on the emptier volume. **Prediction vs. measured: predicted 3.8–4.0
  if free space matters, ±3% of 3.725 if not; measured 3.937.** ⚠️ n=1 per
  condition, short case only, 0 h old and therefore rented. Only ~77% of the
  wall gain is storage — `cb1-wait` also fell 91.72 → 88.45, which is compute and
  probably noise. **The finding that matters more:** pairing probe against
  production across four artifacts gives captured fractions of **91% (1.32/1.45),
  73% (1.333/1.82), 77% (1.718/2.24), 71% (1.768/2.48)**. The probe rose 71%
  across that range; production rose 34%, flattening near **1.7–1.8 GB/s**. The
  "94–96% of achievable" result from [IO-11](#io-11) was measured against a
  1.45 GB/s artifact and **does not generalise to a good one**. On a
  well-placed artifact the fetch path leaves ~29% on the table, the structural
  suspect being the `cb2`-needs-every-expert dependency capping queue depth.
  Fetch-path proposals previously dismissed as arguing over 4–6% were dismissed
  against the old artifact and may deserve re-examination against this one.

<a id="io-13"></a>
### IO-13: Read rate falls after write — OPEN, and the rate is not established

Split out of [IO-12](#io-12) on 2026-08-11 so it is not mistaken for settled, and
**upgraded on 2026-08-18 from a footnote to the dominant open question in this
file.** IO-12's *write-order* term looked measured and closed; the 7-day re-run
showed its entire end-to-end gain gone, so whatever this decay term is, it is
large enough to erase the biggest win the log ever recorded. It should still be
treated as a phenomenon we have observed rather than a number we know.

- **New evidence, 2026-08-18 (production artifact, not controls):** the
  sequentially rewritten artifact fell from 1.72 to 1.33 GB/s fetch over 7 d
  16.8 h, landing back at the scattered artifact's rate. This is the first
  measurement of the effect on production data at production geometry rather than
  on `/tmp` controls. **The GC hypothesis raised here on 2026-08-18 is retracted
  (2026-08-19):** the aged artifact still probed at **1.82 GB/s** vs. 1.45 for
  the scattered one, so placement survived the deletion largely intact. That
  makes the phenomenon *harder*, not easier: the storage kept its advantage and
  production lost it anyway. Whatever decayed over that week is only partly a
  property of the files. The next probe should therefore measure the aged
  artifact **through the fetch path** rather than through `slotscan`, since the
  two now disagree. The original `/tmp` controls that would have given the
  multi-day fit were deleted in the cleanup and are gone.

- **What is actually observed:** a sequentially written file reads 2.30 GB/s at
  0 h and 2.08 at 25 h; a shuffled one 1.78 at 0 h and 1.55 at 24.5 h. Whole-file
  reads show the same direction and a steeper slope (3.23 → 2.74, 2.10 → 1.80).
  Something changes in the first day after a write. That much is reproducible
  across two probe geometries and two write patterns.
- **Why "−10–13% per 24 h" overstates what we know.** It is a rate inferred from
  a **single interval**, and one interval cannot tell a continuing rate from a
  one-time step. It is also not dimensionally sane as a sustained rate — compounded,
  the model would be unreadable within a month, and the 53 h installer file
  (1.375) is far above where a compounding curve would put it. A step function
  that completes somewhere inside the first day fits the three points at least as
  well as a decay.
- **"Per day" is probably the wrong unit.** SLC folding and FTL map eviction are
  driven by write pressure and idle garbage collection, not by wall-clock time.
  On a daily-driven laptop those correlate, which is exactly how a
  GC-triggered step would masquerade as a per-day rate. A machine left idle,
  or one under heavy write load, should show the "same" 24 h differently.
- **The pairs are not perfectly matched.** `fresh_seq.bin` and `relaid_25.bin`
  are different files, written a day apart under different free space (18 vs.
  21 GiB) and landing at different fragmentation (4.41 vs. 2.52 extents/read).
  The comparison assumes those do not matter, which IO-12 argues well but has not
  proven for this specific pair.
- **What would settle it, in order of cost:** (1) re-read the *same* retained
  controls on successive days — the only design that holds file identity fixed and
  varies age alone, and the six files in `/tmp` exist for exactly this; (2) three
  or more points, to fit step vs. decay rather than assume; (3) a written-but-idle
  control, to test whether the change tracks elapsed time or subsequent write and
  GC activity.
- **Why it is not on the critical path.** Recency is not claimable even if fully
  understood: it applies equally to any two artifacts of the same age, so it
  cancels out of the write-order comparison, and holding it would require
  rewriting the model before every run. Understanding it changes *predictions*
  and benchmark hygiene, not the plan. Do not let it block
  [IO-12](#io-12).
- **Consequence that holds regardless:** the age of the model on disk belongs
  next to every performance number, because whatever the mechanism is, it moved
  the read rate by 10% or more within a day, twice, under both geometries.

## Model installation

<a id="io-10"></a>
### IO-10: Remote streaming repack

- **Hypothesis:** The installer could convert the source model directly from
  remote byte ranges without storing or loading the complete source checkpoint.
- **Variants tested:** A pinned remote revision, range planning, bounded payload
  copying, durable per-range checkpoints, interruption and process-death
  recovery, explicit discard, and atomic final promotion.
- **Evidence:** A
  validated run downloaded 14,952,958,284 bytes in 229 ranges. Its largest
  transfer was 64 MiB; peak payload and scratch heap were each 524,288 bytes.
  The freshly installed output loaded in 0.97 s. A greedy eight-token smoke
  for `The capital of France is` generated at 5.015 tok/s; this validated the
  install/load path, not answer quality.
- **What changed the conclusion:** Nothing; later installs kept the same
  core path. A later interruption gate reused every checkpointed range,
  redownloaded only the unfinished work, and produced output identical to an
  uninterrupted install.
- **Final disposition:** Production.
- **Lesson:** Model installation must obey the same bounded-memory architecture
  as inference, and resumability must trust only durable, digest-verified
  destination bytes.

[Experiment inventory](../EXPERIMENT_INVENTORY.md) |
[Optimization journey](../../OPTIMIZATION_JOURNEY.md) |
[Next: Decode, MoE, INT4, and router](02-decode-moe-int4-and-router.md)
