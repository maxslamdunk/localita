---
description: "STUB — analyze a decode trace for bytes/token and cache behavior"
argument-hint: "[trace path]"
---

# /trace-analyze — stub

**Not implemented yet.** The trace format and harness do not exist. If invoked, tell the user it is a stub and do not fabricate an analysis from timing-footer numbers.

## Intent

Take a decode trace and answer the questions that matter under the bytes/token constraint: how many bytes were read per token, which reads were cache misses, whether misses cluster by layer or by expert, and where `io` failed to hide behind `cb1`/`cb2`.

## To fill in

- [ ] Trace format and how it is produced (does not exist yet — profiling is off in benchmark runs by design).
- [ ] Bytes/token: total, per layer, prefill vs. decode reported separately.
- [ ] Expert-cache hit rate, and miss distribution across layers and experts.
- [ ] Routing locality across consecutive tokens — repeat rate of the top-8 set, since that is the ceiling on achievable hit rate.
- [ ] Read-size histogram: how many reads, how coalesced, how much read amplification over the useful payload.
- [ ] Overlap check: `io` time not hidden by concurrent Metal work. Do not present `cb1`/`io`/`cb2` as a serial timeline — the phases overlap and their counters use different clocks.
- [ ] Output shape: a summary that can be pasted into a `MEASUREMENTS.md` notes field.

## Constraints that hold regardless of implementation

- Analysis is read-only over trace artifacts. Never read `.gturbo` files, model weights, or `docs/experiments/**`.
- Findings that change an accepted number must go to `MEASUREMENTS.md` and the Measured facts table in `CLAUDE.md`; an analysis left in the transcript is lost.
