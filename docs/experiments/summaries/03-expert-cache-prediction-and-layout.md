# Expert cache, prediction, and layout experiments

[Previous: Decode, MoE, INT4, and router](02-decode-moe-int4-and-router.md) |
[Experiment inventory](../EXPERIMENT_INVENTORY.md) |
[Optimization journey](../../OPTIMIZATION_JOURNEY.md) |
[Next: RDADVISE](04-rdadvise.md)

The production runtime keeps 16 expert slots per layer and uses LFU
replacement. More memory improves hit rate, but trace-trained allocation,
prediction, and disk-layout policies failed representative holdouts. The
[resource split](../../SYSTEM_DESIGN.md#resource-split) explains the slot
capacity and memory cost.

| Current result | Disposition |
| --- | --- |
| Uniform 16-slot LFU | Production |
| 24/32 slots | Conditional +memory experiments |
| Predictor, Markov, read sorting, and single-trace layout | Rejected |
| Fresh preallocated expert artifact | Unexecuted hypothesis |
| Next-layer early read from the hidden state | Production since 2026-10-03, with the fitted guess: about +17–20% tok/s on iPhone at +11–18% bytes/token |
| LFU count aging (decay and a reset per conversation) | Production; +23% tok/s over an 11-chat session on iPhone, nothing on a fresh single prompt |
| Cache-conditional expert skipping (drop a low-weight expert only when it misses) | **iOS default since 2026-11-08** (a quality spend; off on macOS); −39% waited-for reads at half the KL of one INT4 rounding (Mac); +18 to +33% tok/s on iPhone, 47 of 50 graded problems in both arms; simulated on 3,321 questions, −0.55 MMLU-Pro and −1.06 GSM8K points at 0.08, −0.25 and −0.45 at 0.10, [CACHE-12](#cache-12) |

## Cache policy and capacity

<a id="cache-01"></a>
### CACHE-01: LRU to LFU

- **Hypothesis:** Frequency would retain recurring experts better than recency
  under a fixed 16-slot budget.
- **Variants tested:** LRU and LFU on canonical and
  long decode rows.
- **Evidence:** Canonical decode rose from 5.476 to 5.631 tok/s
  and I/O fell from 72.6 to 64.8 ms. Long-run I/O fell from 110.5 to 97.9 ms.
- **What changed the conclusion:** Nothing.
- **Final disposition:** Production.
- **Lesson:** Replacement policy captured more reuse without spending memory.

<a id="cache-02"></a>
### CACHE-02: Windowed LFU

- **Hypothesis:** Aging frequency counts would adapt faster when routing changed.
- **Variants tested:** Monotonic LFU and a 64-token window.
- **Evidence:** The
  window reduced misses slightly, but two real-decode prompts were neutral or
  mixed. Belady's offline-optimal policy, which knows all future requests,
  remained about 8.4 percentage points above LFU on the France prompt and 10.8
  percentage points above it on the corrected two-prompt corpus.
- **What changed the conclusion:** Better miss counts did not reduce the measured
  step.
- **Final disposition:** Rejected.
- **Lesson:** Cache-policy simulation needs
  an end-to-end I/O gate.

<a id="cache-03"></a>
### CACHE-03: 24 and 32 expert slots

- **Hypothesis:** More resident experts would buy enough I/O reduction to justify
  the memory.
- **Variants tested:** 16, 24, and 32 slots per layer.
- **Evidence:**
  Relative to the 16-slot control, trace replay gave 24 slots another 12.6-14.9
  hit-rate points for 769 MiB and 32 slots another 20.9-23.7 points for 1.54
  GiB. A live 32-slot row fell to 1.578 tok/s as I/O reached 318.3 ms/token and
  pipeline wait reached 238.3 ms/token on the 8 GB Mac.
- **What changed the conclusion:** The hit-rate win remained real,
  but it violated the memory objective for the default.
- **Final disposition:**
  Conditional +memory experiment; production stays at 16.
- **Lesson:** Report
  memory-funded speed separately from memory-free optimization.

<a id="cache-04"></a>
### CACHE-04: Fixed-total heterogeneous allocation

- **Hypothesis:** Layers should receive different slot counts under the same
  480-slot total.
- **Variants tested:** Uniform `16 x 30` allocation and an exact dynamic
  program that distributed the same 480 total slots across layers to minimize
  misses on related training traces.
- **Evidence:** The optimized allocation lost on the
  held-out near-4K trace.
- **What changed the conclusion:** Holdout routing did not
  match the training traces.
- **Final disposition:** Rejected.
- **Lesson:** A
  trace-trained cache layout needs representative holdouts before runtime work.

## Prediction and disk layout

<a id="cache-05"></a>
### CACHE-05: Cross-layer expert predictor

- **Hypothesis:** One layer's expert choices could predict the next layer's
  misses.
- **Variants tested:** Cross-layer set overlap and direct copied-expert
  prediction.
- **Evidence:** Mean Jaccard was 0.039; copied predictions hit only
  7%.
- **What changed the conclusion:** The offline signal failed the threshold
  for a runtime candidate.
- **Final disposition:** Rejected before implementation.
- **Lesson:** Measure predictability before adding speculative I/O.

<a id="cache-06"></a>
### CACHE-06: Markov warming and prefetch

- **Hypothesis:** Recent expert transitions could predict future demand.
- **Variants tested:** Early Markov warming and later demand-adjacent prefetch.
- **Evidence:** The first version was flat or negative. Later rows collapsed from
  values such as 5.413 to 2.256 tok/s and changed output.
- **What changed the conclusion:** Background reads contended with foreground NVMe and memory
  traffic; the later implementation also reused the foreground slot pool and was
  not correctness-safe.
- **Final disposition:** Rejected.
- **Lesson:** Prefetch accuracy alone
  cannot justify traffic that delays the demand path.

<a id="cache-07"></a>
### CACHE-07: File-offset read ordering

- **Hypothesis:** Sorting misses by file offset would improve storage locality.
- **Variants tested:** Route order and physical-offset order.
- **Evidence:** The
  first row improved from 6.012 to 6.117 tok/s. Repeats reversed the result:
  6.099 to 6.067 tok/s, with I/O rising from 75.0 to 76.7 ms.
- **What changed the conclusion:** The first win did not repeat.
- **Final disposition:**
  Rejected.
- **Lesson:** Interleave repeated I/O-policy comparisons.

<a id="cache-08"></a>
### CACHE-08: Packed expert layout

- **Hypothesis:** Reordering experts from a natural-text trace and combining
  adjacent reads would reduce calls and seek distance.
- **Variants tested:** The
  identity layout and one trace-specialized layout with grouped reads.
- **Evidence:** Natural-text replay improved 3.61% with about 49.7 MB extra RSS,
  using the unit recorded by the source artifact.
  The near-4K gate reversed it: decode fell from 4.111 to 3.449 tok/s and prefill
  rose from 168.85 to 312.48 seconds total.
- **What changed the conclusion:** The
  training-like trace did not generalize.
- **Final disposition:** Rejected.
- **Lesson:** On-disk order is a workload policy and needs multi-workload gates.

<a id="cache-09"></a>
### CACHE-09: APFS extent preallocation

- **Hypothesis:** A freshly preallocated expert artifact might reduce file
  fragmentation.
- **Variants tested:** Existing-file extent inspection only.
- **Evidence:** The files were fragmented, but no clean preallocated artifact
  received an end-to-end gate.
- **What changed the conclusion:** No runtime
  conclusion was reached.
- **Final disposition:** Unexecuted hypothesis.
- **Lesson:**
  A plausible filesystem mechanism is neither a win nor a rejection until the
  artifact is built and measured.

<a id="cache-10"></a>
### CACHE-10: Next-layer early read from the hidden state (iPhone)

- **Hypothesis:** Layer L+1's router applied to layer L's router input names
  one of L+1's misses often enough that reading it while storage is idle saves
  more time than the wasted reads cost.
- **Variants tested:** Offline scoring of naive and ridge-fitted guesses on
  Mac routing traces, then the unfitted guess at k = 1 on the iPhone, then the
  fitted guess, stored in the router's own 8-bit format so the same kernel
  runs it, from a file named by `TURBO_FIELDFARE_EARLY_EXPERT_GUESS`. It reads
  into a staging buffer outside the slot pool, issued after layer L's own reads
  finish, and is swapped into the slot the plan assigns. Behind
  `TURBO_FIELDFARE_EARLY_EXPERT_READ`, off by default.
- **Evidence:**
  - Offline, precision@1 at 24 slots was 0.588 naive and 0.726 fitted; the
    wrong-token control was 0.08.
  - On the phone, A B B A per case: **+15.1 / +12.2 / +12.4% tok/s** and
    `io` −22 / −34 / −26 ms per forward.
  - Output was byte-identical in all 12 runs, with live precision 0.55 /
    0.59 / 0.61.
  - bytes/token rose **+26 / +20 / +18%**: about 12 wasted reads per token.
  - Fitted guess against the unfitted one, N F F N per case: precision
    **0.684 / 0.728 / 0.752** (predicted 0.685 / 0.717 / 0.755), about 4 fewer
    wasted reads per token, bytes/token −6%, `io` −8.6 / −14.9 / −6.8 ms,
    tok/s **+5.2 / +4.2 / +13.4%** with long inflated by GPU speed. Output was
    identical. Across sessions, against the early read off: about +17–20%
    tok/s at +11–18% bytes/token.
  - Whole-run GPU speed varied by up to ~40% between consecutive runs at the
    same thermal state; the output head's GPU time is the control.
- **What changed the conclusion:** Unlike CACHE-05, the guess reads the hidden
  state, not expert IDs. Unlike CACHE-06, the read waits for the layer's own
  reads and never touches a slot until the plan has assigned it.
- **Final disposition:** First kept as an experimental switch; **on by
  default on both platforms since 2026-10-03** (`e4eb3a4`), with the fitted
  guess shipped in the runtime's `NextLayerGuess/` resources. Outside the
  fit's training set the fitted guess still beat the router on all six prompts
  tried, Russian, Chinese and Spanish included (+0.11 to +0.15 precision;
  `results/benchmark-results-2026-10-05-mac-early-read-out-of-domain/results.md`). See
  `results/benchmark-results-2026-10-02-ios-next-layer-prefetch/results.md` and
  `results/benchmark-results-2026-10-03-ios-fitted-guess/results.md`.
- **Lesson:** A prefetch that raises bytes/token can still win when it is
  confined to measured idle storage time. Measure the idle window first.
- **Open:**
  - Two reads per layer beat one on the M1 by +7.7 / +13.4 / +14.9%
    (`results/benchmark-results-2026-10-05-mac-upstream-early-read/results-two-reads.md`).
    The cause is unseparated: a longer idle window per layer (the M1's GPU is
    slower), or the drive's gain from a second request in flight.
  - **On the iPhone two reads are slower than one: −25.9 / −14.6 / −20.7%
    tok/s**, with identical output, second-read precision 0.39 / 0.45 /
    0.49 and bytes/token +57 / +51 / +47 MB. Each wrong second guess cost one
    serial read (1.7–2.0 ms of `io`), and right ones saved almost nothing:
    the first read already fills the phone's idle window. Short and long also
    had a slower GPU in both ×2 runs (head +23 / +30%), unattributed
    (`results/benchmark-results-2026-10-08-ios-early-read-x2/results.md`). One read
    stays the default.
  - Three and four were slower than two on the M1: −5.0 / −4.2 / −2.6% and
    −21.7 / −17.6 / −11.9%, with identical output. Storage then ran at
    1.68–1.78 GB/s, this Mac's random-read ceiling, so each extra wasted read
    displaced a needed one
    (`results/benchmark-results-2026-10-05-mac-upstream-early-read/results-three-four-reads.md`).
  - Idea, not built: drop the fixed read count. Read guesses best first, one
    at a time, until the next layer's plan arrives. Keep finished or
    in-flight reads the plan needs, abort an unneeded in-flight read, and drop
    the rest. Not built because aborting needs reads split into chunks, and
    chunks below 1 MiB have never been measured; the 2026-08-10 probe found
    sizes of 1–64 MiB equal. A variant that never aborts needs no chunks and
    risks at most one wasted read per layer. Measure the chunked read rate
    first, on both devices.

<a id="cache-11"></a>
### CACHE-11: Replacement policies in replay, and stale LFU counts

- **Hypothesis:** A policy fitted to Belady's choices from access history
  beats LFU, and LFU's never-reset counts go stale over a long app session.
- **Variants tested:** Offline replay with the early read modelled, at 24
  slots: LFU, LRU, ARC, decayed LFU, a linear learned ranking (12 history and
  router-score features), and Belady. Trained on 18 new prompts, tuned on 8,
  and scored once on the three `real-generation-v1` traces. A session replay
  ran 11 prompts back to back without a reset.
- **Evidence:**
  - The replay matches the live runs within 0.33 hit-rate points on 26 Mac
    traces, and within 2% of the iPhone.
  - Test hit rate: LFU 76.2%, learned 77.5%, decayed LFU 76.7%, ARC 73.9%,
    LRU 73.1%, Belady 84.6%. Foreground reads: LFU 36.2, learned 33.9 per
    token.
  - Session: LFU **66.8–67.1%** against 74.7% with counts reset per prompt
    and 75.2–75.3% decayed. The app keeps one model's counts across all
    conversations.
  - **On the phone, built as count aging** (decay 0.97 per plan, reset when
    the KV resets), in a harness `--session` of 11 prompts, A B B A: **+23.1%
    tok/s** (4.73 → 5.83), hit rate 67.7% → 75.4% (replay: 66.5% → 75.7%),
    bytes/token −18.5%, byte-identical output. The first prompt gained 1
    point. Prefill bytes rose 6.2%: the reset comes before prefill, which
    then loses hits on the previous chat's experts.
- **What changed the conclusion:** CACHE-02's windowed LFU was judged on fresh
  single-prompt runs, which cannot show staleness across conversations.
- **Final disposition:** **Production since 2026-10-03, on both platforms**
  (`TURBO_FIELDFARE_EXPERT_CACHE_AGING`). The Mac's case is replay only. Next
  steps: moving the reset after prefill, and the learned policy (+1.3 points
  in replay). See `results/research-results-2026-10-03-cache-policy/results.md` and
  `results/benchmark-results-2026-10-03-ios-expert-cache-aging/results.md`.
- **Lesson:** The benchmark starts a fresh process, so state that accumulates
  over a session is invisible to it. Replay sessions, not only prompts.

<a id="cache-12"></a>
### CACHE-12: Cache-conditional expert skipping (KL on the Mac; speed and graded answers on the phone)

- **Hypothesis:** Gemma 4's router weights are flat: ranks 1–8 average
  0.26 … 0.07. So dropping a low-weight expert only when it would be a
  foreground read could cut the reads a token waits for at little quality
  cost. Upstream left this as "a quality-changing hypothesis", never run.
- **Variants tested:**
  - **Runtime policies** (`TURBO_FIELDFARE_EXPERT_SKIP`), scored with
    `TurboFieldfareScore` against a reference and a one-INT4-rounding
    yardstick (KL 0.045), at 24 slots with the early read on.
  - **The policies:** drop a miss below weight 0.05, 0.08 or 0.10; drop a
    miss of rank 7 or later; always drop rank 8; swap in the best resident
    expert; no renormalization.
  - **The published baseline:** cache-prior reranking (Skliar et al. 2024,
    arXiv 2412.00099) at λ 0.05 and 0.10.
- **Evidence:**

| Policy | Waited-for reads per token | KL against the yardstick | Top-1 agreement |
| --- | --- | --- | --- |
| `miss:0.05` | −10.2% | 0.10× | 0.986 |
| `miss:0.08` | **−39.1%** | **0.55×** [0.31, 0.90] | 0.977 |
| `miss:0.10` | **−62.0%** | 0.94× [0.64, 1.30] | 0.968 |
| `missrank:7` | −38.4% | 0.54× | 0.977 |
| `top7` (static) | −18.7% | 0.62× | 0.969 |
| Reranking, λ 0.05 | −31.4% | 0.55× | 0.969 |
| Reranking, λ 0.10 | −51.3% | 0.92× | 0.966 |

  - The replay of 29 traces predicted every read cut within its range.
  - Greedy generations of two benchmark prompts under `miss:0.08` and
    `miss:0.10` read as equally good.
- **What changed the conclusion:**
  - **It is cache-conditional.** The policy spends its quality budget only
    where the router rates an expert least and the expert would cost a read.
    Static top-7 drops twice the weight for half the reads.
  - **Swapping in a resident expert is not better than dropping** on this
    model, whether by reranking or substitution: the same KL for fewer reads.
- **Final disposition:** **A research switch, off by default.** It is a
  candidate for a phone A/B. Arithmetic puts `miss:0.08` at +18 to +32%
  tok/s. Needs an iOS harness flag, a quality check beyond KL, and the long
  context. See `results/research-results-2026-10-04-lossy-experts/results.md`.
- **Later variants (2026-11-04, Mac):** none beat `miss:<t>` by a margin
  12 transcripts can show.
  - **HOBBIT's rank rule** (`cum:0.85`, arXiv 2411.01433): −34.1% reads at
    0.69× [0.42, 1.04] of the `miss` curve's KL. Most of the gap is one token
    in one transcript, so separating the two needs a larger transcript set.
  - **A bonus for the early read alone** (`early:<λ>`, after arXiv
    2610.34721): 2.5–3.2× the `miss` cost per read saved. Closed.
  - **Reranking then dropping** (`bias:0.05+miss:0.08`): on the curve.
  - See `results/research-results-2026-11-04-miss-skip-variants/results.md`.
- **Phone A/B (2026-11-08, iPhone 17, `miss:0.08` against defaults):**
  - **tok/s +32.9 / +18.2 / +26.0%** (short / medium / long).
  - Foreground reads −42.3 / −33.9 / −33.7%, bytes per token −21.5 / −18.7 /
    −20.0%, hit rate +4.8 to +5.8 points.
  - Every predicted range and every control held. Each removed read took
    2.1–2.7 ms off `io`, the phone's serial read time.
  - The replies read as coherent and complete.
  - See `results/benchmark-results-2026-11-08-ios-expert-skip/results.md`.
- **Graded answers on the phone (2026-11-08, 50 GSM-Symbolic P2 problems,
  free generation):**
  - **47 of 50 right in both arms.** They disagreed on 2 problems, one each
    way (McNemar p = 1.000). B's loss was a reply that ran out of tokens on an
    ambiguous clause; A's was an arithmetic slip.
  - The replies diverge early (median first difference at character 197), yet
    the answers hold. That is the drift teacher-forced KL cannot see, and it
    did not compound.
  - It cannot resolve a loss of 1–3 problems in 50, and it covers English
    arithmetic only.
  - See `results/validation-results-2026-11-08-ios-expert-skip-accuracy/results.md`.
- **Graded answers in a GPU simulation of the app (2026-11-11, 3,321
  questions):**
  - HF transformers on one H100, with the app's cache, early read and skip
    rule ported. Teacher-forcing the phone's own replies, it matched the
    phone's footers to 0.13 hit-rate points and 0.7% in drops per layer.
  - MMLU-Pro (2,002): `0.08` −0.55 points (−1.67 to +0.57), `0.10` −0.25
    (−1.39 to +0.89).
  - GSM8K (1,319), strict match: `0.08` **−1.06** (−1.76 to −0.37,
    p 0.004), `0.10` −0.45 (−1.15 to +0.24). Of `0.08`'s 18 losses, 8 are
    right answers written as "16.00", and by value it is −0.45 (p 0.18).
  - `0.10` was no worse than `0.08` on either task. Both thresholds change
    most replies, and which questions flip looks like a draw.
  - Both are well under one INT4 rounding's −3.75 MMLU-Pro points.
  - See `results/validation-results-2026-11-11-skip-accuracy/results.md`.
- **Decision (2026-11-08, the user's):** `miss:0.08` is the iOS default, and
  the iOS Settings sheet offers Off, 0.08 and 0.10. 0.10 is not measured on
  the phone. macOS stays off. Recorded in `docs/IOS_PORT.md`, "The rule that
  keeps the split honest".
- **Decision (2026-11-12, the user's):** `miss:0.10` replaces 0.08 as the
  iOS default, on the graded result above and an iPhone 18 Pro sweep where it
  was 13–15% faster. Its speed on the iPhone 17 is unmeasured.
- **Lesson:** A lossy change can be priced against the quantization the
  project already accepts. Measure it with a teacher-forced KL meter against
  a one-rounding yardstick, not by eye and not against "no change".

[Previous: Decode, MoE, INT4, and router](02-decode-moe-int4-and-router.md) |
[Experiment inventory](../EXPERIMENT_INVENTORY.md) |
[Optimization journey](../../OPTIMIZATION_JOURNEY.md) |
[Next: RDADVISE](04-rdadvise.md)
