import Foundation
import TurboFieldfare

// Copied verbatim from `Sources/TurboFieldfareCLI/Run.swift`. Do not
// reimplement, reformat, or "improve" these two functions.
//
// They are the reason an on-device number can be compared against a row in
// `MEASUREMENTS.md` at all. Everything they read is public on the runtime
// (`DecodePhaseTimings`, `ExpertIOStats`, `RawDecodeResult`), so the only thing
// that could make the phone's figures incomparable with the Mac's is the
// arithmetic here drifting from the CLI's. When the CLI changes, change both in
// the same commit — this is a hand-maintained duplicate, not a shared symbol.

/// Second footer line carrying the routed-expert byte profile.
func expertIOFooter(_ stats: RawDecodeResult) -> String {
    func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / 1_048_576.0)
    }
    func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "n/a" }
        return String(format: "%.1f%%", fraction * 100)
    }
    func perForward(_ total: UInt64) -> String {
        guard stats.decodeForwards > 0 else { return "n/a" }
        return String(format: "%.2f", Double(total) / Double(stats.decodeForwards))
    }
    let decode = stats.decodeExpertIO
    let prefill = stats.prefillExpertIO
    let bytesPerToken = stats.decodeMegabytesPerToken.map { String(format: "%.2fMB", $0) } ?? "n/a"
    return "[expert-io decode bytes/tok=\(bytesPerToken)"
        + " hit-rate=\(percent(decode.cacheHitRate))"
        + " req/tok=\(perForward(decode.cacheRequests))"
        + " reads/tok=\(perForward(decode.reads))"
        + " forwards=\(stats.decodeForwards)"
        + " | prefill bytes=\(megabytes(prefill.bytesRead))MB"
        + " hit-rate=\(percent(prefill.cacheHitRate))"
        + " reads=\(prefill.reads)]"
}

/// Third footer line: where a decode forward's time goes, in milliseconds per
/// forward. `io` is the fetch window and hides the shared-expert branch
/// executing on the GPU throughout it — it is not idle time waiting on disk.
func phaseTimeFooter(_ stats: RawDecodeResult) -> String {
    let forwards = stats.decodeForwards
    func perForward(_ nanos: UInt64) -> String {
        guard let ms = DecodePhaseTimings.millisecondsPerForward(nanos, forwards: forwards) else {
            return "n/a"
        }
        return String(format: "%.2f", ms)
    }
    let phases = stats.decodePhaseTimings
    let wall = forwards > 0
        ? String(format: "%.2f", stats.decodeSeconds * 1000 / Double(forwards))
        : "n/a"
    return "[phase-time decode ms/fwd cb1=\(perForward(phases.cb1Nanos))"
        + " cb1-wait=\(perForward(phases.cb1WaitNanos))"
        + " io=\(perForward(phases.ioNanos))"
        + " cb2=\(perForward(phases.cb2Nanos))"
        + " routed-drain=\(perForward(phases.routedDrainNanos))"
        + " head=\(perForward(phases.headNanos))"
        + " wall=\(wall)"
        + " forwards=\(forwards) | sequential per layer; io hides the shared-expert branch]"
}
