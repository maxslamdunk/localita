import Foundation
import TurboFieldfare

// Copied verbatim from `Sources/TurboFieldfareCLI/Run.swift`, minus the
// trailing newline the CLI writes to stderr. Do not reimplement, reformat, or
// "improve" these four functions.
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

/// Fourth footer line: GPU execution per decode forward, from command-buffer
/// timestamps. `cb1` is attention + router alone; `hit-experts` + `routed` is
/// the expert work `cb1-wait` absorbs. Parts may overlap; `busy` is their union.
func gpuTimeFooter(_ stats: RawDecodeResult) -> String {
    let forwards = stats.decodeForwards
    let phases = stats.decodePhaseTimings
    func perForward(_ nanos: UInt64) -> String {
        guard let ms = DecodePhaseTimings.millisecondsPerForward(nanos, forwards: forwards) else {
            return "n/a"
        }
        return String(format: "%.2f", ms)
    }
    let wallMs = forwards > 0 ? stats.decodeSeconds * 1000 / Double(forwards) : nil
    let busyMs = DecodePhaseTimings.millisecondsPerForward(phases.gpuBusyNanos, forwards: forwards)
    let idle = wallMs.flatMap { wall in busyMs.map { String(format: "%.2f", wall - $0) } } ?? "n/a"
    let wall = wallMs.map { String(format: "%.2f", $0) } ?? "n/a"
    return "[gpu-time decode ms/fwd embed=\(perForward(phases.gpuEmbedNanos))"
        + " cb1=\(perForward(phases.gpuCb1Nanos))"
        + " shared=\(perForward(phases.gpuSharedNanos))"
        + " hit-experts=\(perForward(phases.gpuHitExpertsNanos))"
        + " routed=\(perForward(phases.gpuRoutedNanos))"
        + " head=\(perForward(phases.gpuHeadNanos))"
        + " busy=\(perForward(phases.gpuBusyNanos))"
        + " idle=\(idle)"
        + " wall=\(wall)"
        + " forwards=\(forwards) | command-buffer timestamps; parts may overlap, busy is their union]"
}

/// Fifth footer line: per-read latency histogram, decode and prefill apart.
/// The low buckets are misses the OS served from its file cache.
func readLatencyFooter(_ stats: RawDecodeResult) -> String {
    func bound(_ micros: UInt64) -> String {
        String(format: "%g", Double(micros) / 1000.0)
    }
    func describe(_ io: ExpertIOStats) -> String {
        let bounds = ExpertIOStats.readLatencyBucketBoundsMicros
        let total = io.timedReads
        let mean = io.meanReadLatencyMilliseconds.map { String(format: "%.2fms", $0) } ?? "n/a"
        var parts = ["reads=\(total)", "mean=\(mean)"]
        for (index, count) in io.readLatencyBuckets.enumerated() {
            let label: String
            if index == 0 {
                label = "<\(bound(bounds[0]))ms"
            } else if index < bounds.count {
                label = "\(bound(bounds[index - 1]))-\(bound(bounds[index]))ms"
            } else {
                label = ">=\(bound(bounds[bounds.count - 1]))ms"
            }
            let share = total > 0
                ? String(format: "%.1f%%", Double(count) / Double(total) * 100)
                : "n/a"
            parts.append("\(label)=\(share)")
        }
        return parts.joined(separator: " ")
    }
    return "[read-latency decode \(describe(stats.decodeExpertIO))"
        + " | prefill \(describe(stats.prefillExpertIO))]"
}
