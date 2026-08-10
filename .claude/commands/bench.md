---
description: "STUB — run the standard benchmark and append a row to MEASUREMENTS.md"
argument-hint: "[config notes]"
---

# /bench — stub

**Not implemented yet.** The harness this wraps does not exist. If invoked, tell the user it is a stub, do not improvise a benchmark run, and do not start a model process to fake one.

## Intent

One command that runs the standard benchmark, captures bytes/token and hit rate alongside tok/s, and appends a row to `MEASUREMENTS.md`. The point is that a measurement never gets taken without being recorded.

## To fill in

- [ ] Exact command, per `docs/COMMUNITY_BENCHMARKS.md`, run verbatim with experimental controls and profiling off.
- [ ] Preflight: `pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'` and `memory_pressure -Q`. On a failed check, stop and report — never kill a process, delete, or reinstall the model.
- [ ] Where bytes/token and cache hit rate come from. **This is the missing piece:** the only byte counter in the streaming path today is inside the RDADVISE advisory branch of `PreadExpertStreamer` (`adviseRanges`, ~line 375), which is off in benchmark runs; the surfaced `rdadviseMegabytesPerToken` metric therefore reads zero under production defaults. There is no counter on the actual `pread` path and no cache hit/miss counter. Instrumenting those comes before this command is worth writing.
- [ ] Thermal state capture.
- [ ] Row assembly and append to `MEASUREMENTS.md` — append only, existing rows untouched.
- [ ] Whether a measured value supersedes the Measured facts table in `CLAUDE.md`, and prompting to update it if so.

## Constraints that hold regardless of implementation

- Exactly one model-owning process at a time. This is a memory invariant on the 8 GB validation host.
- Build release once; follow `docs/COMMUNITY_BENCHMARKS.md` exactly.
- Report commit SHA, hardware/RAM, macOS, Swift version, exact command, exit code, and the full timing footer.
- Never read `.gturbo` files or `docs/experiments/**`.
