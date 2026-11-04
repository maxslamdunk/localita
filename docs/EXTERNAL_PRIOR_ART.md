# External prior art

Techniques from outside this project — papers, other inference runtimes, vendor documentation — assessed against TurboFieldfare's binding constraint.


The filter for everything here: **does it reduce bytes read per token on a memory-constrained device?** A technique that improves compute throughput, or that assumes the weights are already resident, does not apply and should be recorded as not applicable rather than left out — knowing something was considered and rejected saves the next session from rediscovering it.

## How to add an entry

One section per technique, newest last. Include:

- **Technique and source** — name, and a link or citation.
- **What it claims** — the mechanism and the reported effect.
- **Applicability here** — does it move bytes/token given SSD-streamed routed experts, a 16-slot cache, and the memory ceiling? Be explicit when the answer is no.
- **What adopting it would cost** — format changes, kernel work, iOS portability.
- **Status** — `not evaluated` / `rejected` / `candidate` / `adopted`. Adopted techniques get an entry in `PRIOR_ART.md` with real measurements.

Related: `PRIOR_ART.md` (what this project tried), `MEASUREMENTS.md` (run log).

## Cache-prior reranking (cache-conditional MoE routing)

- **Technique and source:** Skliar et al. 2024, "Mixture of Cache-Conditional
  Experts for Efficient Mobile Device Inference", arXiv 2412.00099.
- **What it claims:**
  - **The method:** add λ × (average router-logit range) to the logits of
    experts already in DRAM, keep the top J experts regardless, and weight
    the chosen experts by their original logits.
  - **The result:** more than 50% fewer cache misses at a 0.1–3% perplexity
    cost and under 0.1% on MMLU and GSM8K. About 2× faster on phones.
  - **The models:** Mixtral, Phi-3.5-MoE, Qwen1.5-MoE and DeepSeek-V2-Lite,
    with top-2 to top-6 routing.
- **Applicability here:** **Yes; it moves bytes per token directly.**
  - **On gemma4** (8 of 128, 24 slots, Mac, teacher-forced):

| λ | Waited-for reads | KL against one INT4 rounding |
| --- | --- | --- |
| 0.05 | −31.4% | 0.55× |
| 0.10 | −51.3% | 0.92× |

  - **The project's own drop policy** (CACHE-12, drop a low-weight expert only
    on a miss) saves more at the same KL: −39.1% and −62.0%. With 8 flat
    experts, a stand-in is not better than a hole.
- **What adopting it would cost:** a runtime change only: no format or
  kernel change, iOS-portable.
- **Status:** `rejected` in favour of the drop policy. It stays implemented as
  `TURBO_FIELDFARE_EXPERT_SKIP=bias:<λ>` for comparison. See
  `results/research-results-2026-10-04-lossy-experts/results.md`.

## Rank-conditional expert skipping (HOBBIT)

- **Technique and source:** HOBBIT, arXiv 2411.01433.
- **What it claims:** an expert matters less the more weight its
  higher-ranked experts already carry. Low-importance misses are served
  cheaply or skipped.
- **Applicability here:** **Yes, as a variant of the drop policy.**
  - **On gemma4**, implemented as `TURBO_FIELDFARE_EXPERT_SKIP=cum:<T>`, which
    drops a miss at rank ≥ 2 once the experts above it carry T of the top-8
    weight.
  - `cum:0.85` cut waited-for reads 34.1% at 0.69× [0.42, 1.04] of the
    `miss:<t>` curve's KL. `cum:0.80` cut 44.9% at 0.99× (Mac, 24 slots,
    teacher-forced).
  - The gain at 0.85 rests mostly on one token. It is not established.
- **What adopting it would cost:** a runtime change only.
- **Status:** `candidate`, behind `miss:<t>`. It needs a larger transcript
  set. See `results/research-results-2026-11-04-miss-skip-variants/results.md`.

## Prefetch-steered routing

- **Technique and source:** arXiv 2610.34721.
- **What it claims:** a routing bonus given only to the experts the
  prefetcher brought in, so prefetches are used rather than wasted.
- **Applicability here:** **Tested and worse.**
  - The cache-prior arm above already gave the pending early read the
    resident bonus.
  - With a bonus for the early read alone (`early:<λ>`, a swap that always
    saves a read), gemma4 saved 6.6–9.8% of waited-for reads at 2.5–3.2× the
    `miss:<t>` curve's KL per read saved (Mac, teacher-forced).
- **What adopting it would cost:** a runtime change only.
- **Status:** `rejected`. See
  `results/research-results-2026-11-04-miss-skip-variants/results.md`.

## Stacking cache-aware rerouting with other miss reduction (Cacheable by Design)

- **Technique and source:** arXiv 2608.18261.
- **What it claims:** cache-aware rerouting stacks with other
  miss-reduction methods.
- **Applicability here:** **Tested; no gain.** Cache-prior reranking then
  the drop policy (`bias:0.05+miss:0.08`) cut waited-for reads 51.0% at
  0.95–0.99× the `miss:<t>` curve's KL. That is the drop policy's own price
  (Mac, teacher-forced).
- **What adopting it would cost:** a runtime change only.
- **Status:** `rejected` in favour of the drop policy alone. See
  `results/research-results-2026-11-04-miss-skip-variants/results.md`.
