# iOS port plan

Status: planning. No device code written, no device measurements taken.

This document is the framing and sequencing for the iPhone port. It does not
restate the measured facts — `CLAUDE.md` is the single source of truth for those
and every number below is either quoted from that table or labeled as arithmetic
derived from it.

## The constraint the port inherits

Decode demands a derived ceiling of **806.1 MB/token** at zero cache hits
(`numLayers 30 × topKExperts 8 × expertStride 3358720`). On the 8 GB macOS
validation host that is serviced at the measured 2.7–3.2 GB/s SSD roof, giving
3.340 tok/s — about 95% of the roof.

The 16 GB hosts are faster only because the macOS unified buffer cache holds the
whole 12.01 GiB routed-expert corpus. **iOS has no equivalent tier to rely on.**
The 8 GB row is the honest predictor for the port and, per `CLAUDE.md`, is if
anything optimistic.

Consequence: the memory ceiling caps the expert cache, and the expert cache is
the only thing that can replace the page cache iOS will not provide.

## Two tracks

The port has two deliverables with different definitions of done. They are not
phases of one goal.

### Track A — feasibility and the quality reference

Ship a correct port at any speed, with **no quality sacrifice**.

Floor: **0.5 tok/s**. Derived: 0.5 × 806.1 MB = **403 MB/s sustained**, roughly
14% of the Mac's measured SSD roof. Bandwidth is therefore not expected to be
the risk — this needs confirming on device, but it means Track A's real risk is
the **memory ceiling**: ~1.35 GB of residents plus the FP16 KV cache plus Metal
plus app overhead, under jetsam.

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

0. **Mac-side instrumentation** (prerequisite, no dependency on Track A, can
   start immediately). `CLAUDE.md` lists bytes/token and expert-cache hit rate as
   `_TBD_`; the only byte counter in the streaming path is on the RDADVISE
   advisory branch, which is off under production defaults. Add counters on the
   `pread` path and on cache hit/miss. Do this on macOS, where it is debuggable.
1. **Device I/O probe.** Sustained random-read bandwidth at the production
   3,358,720 B block size over 5–10 minutes (not a burst — thermal and NAND
   controller behavior is the real number), swept by working-set size to find
   whether a page-cache knee exists at all.
2. **Quality-neutral levers** — exhaust these before spending any accuracy:
   - Expert cache sizing against the ceiling from A1. The Mac's 16 slots are
     **54 MB**; a phone may afford 1 GB+ of explicit cache.
   - Routing locality, prefetch, router lookahead.
   - Disk layout, expert co-location, read coalescing.
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
