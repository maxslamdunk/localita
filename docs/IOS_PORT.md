# iOS port plan

Status: planning. No device code written, no device measurements taken.

This document is the framing and sequencing for the iPhone port. It does not
restate the measured facts — `CLAUDE.md` is the single source of truth for those
and every number below is either quoted from that table or labeled as arithmetic
derived from it.

## The constraint the port inherits

Decode demand is **measured** as of 2026-08-10: **261.9–305.6 MB/token**, rising
with prompt length, at a 16-slot LFU hit rate of 62–68%. The zero-hit ceiling is
806.1 MB/token (`numLayers 30 × topKExperts 8 × expertStride 3358720`); measured
demand is that ceiling times (1 − hit rate). Quote the measured figure, not the
ceiling.

At 261.9 MB/token the 8 GB validation host demands only 0.83 GB/s — about 29% of
its measured 2.7–3.2 GB/s SSD roof. **Decode on that host is not
SSD-bandwidth-bound**, which retracts the earlier claim that it runs at 95% of
its roof, and with it the argument that 16 GB hosts must be page-cache-served.
See the retraction in `CLAUDE.md`.

The phase split (step B0b, 2026-08-10) says where that time actually goes:
**`io` is 59–63% of a decode forward**, so reads bind, and the expert cache
remains the lever that matters — a hit is a read that did not happen, and
two-thirds of requests already are one.

But two things it found reshape the track ordering below:

- **The fetch path achieves 41–50% of the device's bandwidth roof** (1.30–1.34
  GB/s against a probed 2.7–3.2 GB/s at the same block size). Time is being lost
  between the SSD and the runtime, not to the number of bytes. This is a
  quality-free win that no cache-policy change can reach, and it is not
  bytes/token work at all.
- **GPU attention (`cb1-wait`) is 29–35% of a forward and rises with prompt
  length** — 95 ms at a 61-token prompt, 133 ms at 3,015. On device, with long
  context, this only grows. Nothing in either track currently touches it.

So the device I/O probe (step B1) has to be read alongside a device phase split,
not on its own: a phone that is attention-bound needs different work than one
that is fetch-bound, and the Mac is measurably both.

Consequence that survives unchanged: iOS has no page-cache tier and a tighter
memory ceiling, so the memory ceiling caps the expert cache, and the expert
cache is the only second tier the port will have.

## Two tracks

The port has two deliverables with different definitions of done. They are not
phases of one goal.

### Track A — feasibility and the quality reference

Ship a correct port at any speed, with **no quality sacrifice**.

Floor: **0.5 tok/s**. Derived from measured demand: 0.5 × 261.9 MB = **131 MB/s
sustained**, roughly 5% of the Mac's measured SSD roof (0.5 × 806.1 MB = 403
MB/s if the port's cache were sized so small it never hit). Bandwidth is
therefore even less likely to be the risk than previously stated, which makes
Track A's real risk the **memory ceiling**: ~1.35 GB of residents plus the FP16
KV cache plus Metal plus app overhead, under jetsam. Note the coupling — the
ceiling sets the cache size, the cache size sets the hit rate, and the hit rate
sets demand. A port forced down to a much smaller cache moves toward the 806.1
MB figure, not the 261.9 MB one.

Definition of done — reuse the project's existing standard, do not invent a new
one:

- Same `.gturbo` artifact, same sampling config, output within the existing
  `Tolerances` against the CPU reference. Kernels may reorder float ops; exact
  cross-path identity was never the standard here.
- Survives jetsam through a full generation.
- ≥ 0.5 tok/s.

Track A also produces the instrument Track B cannot work without: **a zero-loss
reference running on the device**. There is no way to measure a quality
regression without it. This is why Track A comes first rather than in parallel.

Steps:

1. **Memory-ceiling probe.** Jetsam limit with and without the increased-memory-limit
   entitlement, on the target device. This is the gate.
2. **Model delivery.** Getting ~14.3 GB onto a phone: on-device download plus
   repack, storage provisioning, eviction behavior. A Track A blocker, not a
   later product concern.
3. **Port the runtime.** 16-slot expert cache untouched, no optimization.

### Track B — performance

Push bytes/token as hard as possible, accepting quality cost where it is worth
it. The balance point is decided later, against real numbers — and the ordering
below makes that deferral structural rather than a matter of remembering to.

0. **Mac-side instrumentation — DONE 2026-08-10.** `ExpertIOCounters` counts
   bytes on the `pread` path and hits/misses in the cache planner; the CLI
   prints an `[expert-io …]` footer line and the HUD shows decode bytes/token
   and hit rate. First measured values are in `CLAUDE.md` and `MEASUREMENTS.md`.
   Two follow-ups this exposed: the CLI footer does not print the per-phase
   `cb1`/`io`/`cb2` split the runtime already tracks, which is what would show
   whether decode time is actually going into reads; and **prefill runs at 0.0%
   hit rate**, reading 192.6 GB for a 3,015-token prompt — about half of all
   bytes that run touched.
0b. **Per-phase time split on the Mac — DONE 2026-08-10, `ce287b6`.** The CLI
   prints a `[phase-time …]` footer. Printing the three counters the runtime
   already had would not have answered the question — `cb1` and `cb2` exclude
   GPU execution by construction — so the two waits that were being computed and
   discarded were added with them. Predicted 0 bytes/token; measured bytes/token
   came back identical to the digit against the previous session, confirming it.
   Findings are in `CLAUDE.md`; the two that change this plan are quoted above.
1. **Device I/O probe.** Sustained random-read bandwidth at the production
   3,358,720 B block size over 5–10 minutes (not a burst — thermal and NAND
   controller behavior is the real number), swept by working-set size to find
   whether a page-cache knee exists at all.
2. **Quality-neutral levers** — exhaust these before spending any accuracy:
   - **Close the fetch-path gap.** The largest known quality-free win and the
     only one measured rather than assumed: `io` runs at 41–50% of the device
     roof, so roughly half of 202 ms/forward is going somewhere other than
     moving bytes. Candidates not yet distinguished: per-read latency the probe
     did not model (30 open layer files vs. one; ~2.6 reads per layer issued and
     awaited per layer rather than streamed), planning cost counted inside the
     `io` window, queue depth. Diagnose before optimizing — this is not a
     bytes/token change and does not get justified as one.
   - Expert cache sizing against the ceiling from A1. The Mac's 16 slots are
     **54 MB**; a phone may afford 1 GB+ of explicit cache.
   - Routing locality, prefetch, router lookahead.
   - Disk layout, expert co-location, read coalescing.
   - **Attention over long context**, which is not a bytes lever at all but is
     29–35% of a forward and growing with prompt length. Listed here because it
     is quality-neutral and because ignoring it means the port optimizes two
     thirds of a forward and calls it done.
3. **Quality-spending levers** — only once 2 is exhausted: expert quantization,
   top-K reduction, layer-selective routing, smaller variant.
4. **Floor / kill criterion**, if wanted, set here against measured numbers.

Every item follows the existing working agreement: predicted bytes/token delta,
mechanism, and falsification condition stated *before* implementation, measured
delta recorded in `MEASUREMENTS.md` afterward — including when the prediction
missed.

### The rule that keeps the split honest

**Any quality spend is a recorded decision, including one forced by the memory
ceiling.** The failure mode of a two-track plan is Track B's costs leaking
silently into Track A — you shrink something to fit under jetsam and never write
down that you paid for it.

## What is deliberately not decided

- **Target device.** `CLAUDE.md` records the iOS device target as `_TBD_`.
- **Target tok/s.** Deliberately absent. tok/s is an output of bytes/token ÷
  bandwidth, not a decision variable; a target chosen before the device I/O
  probe would be picked from nothing. The 0.5 tok/s floor is a feasibility
  threshold, not a goal.
- **Quality budget.** Not needed until Track B step 3. Steps 0–2 cost no
  accuracy.

## Repository layout

This repo is a **separate repository**, not a GitHub fork, derived from
`drumih/turbo-fieldfare` (Apache-2.0). History is shared with upstream
deliberately — that is the expensive thing to reverse, and keeping it preserves
two options at no cost.

| Remote | Points at | Use |
| --- | --- | --- |
| `origin` | `maxslamdunk/turbo-fieldfare-ios` (private) | Everything. |
| `upstream` | `drumih/turbo-fieldfare` | Fetch only; push URL is set to `DISABLED`. |

- `git fetch upstream && git merge upstream/main` pulls upstream work in for
  free. Upstream is live, so this matters.
- Contributing something back stays a `git cherry-pick` rather than a
  re-implementation. Create a GitHub fork at the moment a PR is actually wanted —
  forking later is free *because* history is shared.
- `main` tracks `origin/main`. `upstream/main` is the pristine reference, which
  is why no "keep it as is" branch exists.
- Branch by **upstreamability**, not by track. Track A/B is work sequencing.
  Anything platform-neutral — instrumentation, and most of Track B step 2, which
  lowers bytes/token on the Mac too — belongs on a topic branch off `main`, not
  stranded on an iOS branch. Only the genuinely platform-specific delta
  (`Package.swift` platforms, app target, jetsam handling, on-device delivery,
  no-AppKit paths) is iOS-only.

### Coordination hazard

The quality-spending levers — expert quantization in particular — change
`TurboFieldfareFormat`, which the installer, verifier, and runtime all validate
against. That is a `.gturbo` v2 contract, not a local edit. Worth raising with
upstream before diverging.

### Probes are not in this repo

The measured SSD-bandwidth row came from a standalone probe with the model
untouched. The jetsam and device-bandwidth probes follow the same pattern: a
throwaway Xcode project, no branch and no changes here. This also keeps clear of
`AGENTS.md` on worktrees and model duplication, and of the one-model-process
memory invariant.

## Related

- `CLAUDE.md` — measured facts, the binding constraint, working agreements.
- `MEASUREMENTS.md` — append-only run log. iOS rows go here, kept separate from
  Mac rows; they are not comparable.
- `docs/EXTERNAL_PRIOR_ART.md` — currently a stub. Nothing on iOS recorded yet.
- `docs/experiments/summaries/03-expert-cache-prediction-and-layout.md` — read
  before Track B step 2.
- `docs/experiments/summaries/09-validation-and-measurement-lessons.md` — read
  before Track B step 0.
