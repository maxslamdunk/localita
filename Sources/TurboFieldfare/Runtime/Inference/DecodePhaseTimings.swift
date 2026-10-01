/// Cumulative per-phase decode timings, in nanoseconds, off the forward runner.
///
/// The first six run in sequence within a layer, and all six come from the same
/// monotonic clock (`CLOCK_UPTIME_RAW`), so unlike the three counters they were
/// built from they can be read against each other and against wall time. The
/// 2026-08-10 runs put them at 98.2–98.5% of measured wall on all three
/// benchmark cases, with a flat ~5.9 ms residual: per-token sampling, which
/// runs outside the layer loop and is counted by none of these.
///
/// Two things still have to be said out loud, because the field names do not
/// say them. `cb1Nanos` and `cb2Nanos` are CPU encode cost with GPU execution
/// excluded — that execution is `cb1WaitNanos` and `routedDrainNanos`, which is
/// why a breakdown built from the first three alone accounted for almost none
/// of a token. And `ioNanos` is a window during which the resident
/// shared-expert branch is executing on the GPU: that work is real, and is
/// hidden inside `io` rather than added to it.
///
/// The `gpu…` fields are a second, independent view of the same forwards: GPU
/// execution read from each command buffer's own timestamps after it finished.
/// They overlap the six CPU-side figures by design and are not to be added to
/// them. They exist because the CPU-side waits cannot say which GPU work they
/// waited on — see `cb1WaitNanos`.
public struct DecodePhaseTimings: Sendable, Equatable {
    /// CPU cost of encoding and committing the attention + router command
    /// buffer, with the block on its completion excluded.
    public var cb1Nanos: UInt64 = 0
    /// Time blocked on that command buffer, once per layer. Not just attention
    /// and the router: the previous layer's routed command buffer is committed
    /// and never waited on, so the GPU finishes it first and this wait absorbs
    /// whatever of it was still running. `gpuCb1Nanos` is the buffer alone.
    public var cb1WaitNanos: UInt64 = 0
    /// Wall time of the routed-expert fetch: the `pread`s of the misses, plus
    /// the hop to the I/O queue and back. Cache planning runs before this
    /// window opens and is not in it. Overlaps the shared-expert branch running
    /// on the GPU, so it is an upper bound on what expert reads cost, not their
    /// exclusive cost.
    public var ioNanos: UInt64 = 0
    /// CPU cost of encoding and committing the routed + tail command buffer.
    /// Its GPU execution is not awaited here — the next layer absorbs it.
    public var cb2Nanos: UInt64 = 0
    /// Time blocked draining the final routed command buffer of a forward.
    /// Once per token rather than once per layer: every earlier layer's routed
    /// execution lands in the next layer's `cb1WaitNanos` instead.
    public var routedDrainNanos: UInt64 = 0
    /// Final norm + lm_head. Wall-inclusive: this path waits on its own work,
    /// so unlike `cb1Nanos` it already contains GPU execution.
    public var headNanos: UInt64 = 0

    /// GPU execution of the per-token embedding lookup.
    public var gpuEmbedNanos: UInt64 = 0
    /// GPU execution of the attention + router command buffer: norm, QKV,
    /// RoPE + KV write, attention, output projection, router.
    public var gpuCb1Nanos: UInt64 = 0
    /// GPU execution of the shared-expert branch, which runs during `io`.
    public var gpuSharedNanos: UInt64 = 0
    /// GPU execution of the routed experts that were already resident, which
    /// the runner starts during `io` when a layer has both hits and misses.
    public var gpuHitExpertsNanos: UInt64 = 0
    /// GPU execution of the routed command buffer: the remaining experts (all
    /// eight when the hit/miss split is not taken), the weighted reduce, and
    /// the layer tail.
    public var gpuRoutedNanos: UInt64 = 0
    /// GPU execution of final norm + lm_head.
    public var gpuHeadNanos: UInt64 = 0
    /// Time the GPU was executing any of the above: the union of their
    /// intervals, so overlap between buffers is counted once. Wall time minus
    /// this is time the GPU spent idle.
    public var gpuBusyNanos: UInt64 = 0

    public static let zero = DecodePhaseTimings()

    /// Difference between two snapshots of the same cumulative counters, which
    /// is how a phase-scoped window is taken. Wrapping, to match the `&+`
    /// accumulation on the runner.
    public func delta(since earlier: DecodePhaseTimings) -> DecodePhaseTimings {
        var result = DecodePhaseTimings()
        result.cb1Nanos = cb1Nanos &- earlier.cb1Nanos
        result.cb1WaitNanos = cb1WaitNanos &- earlier.cb1WaitNanos
        result.ioNanos = ioNanos &- earlier.ioNanos
        result.cb2Nanos = cb2Nanos &- earlier.cb2Nanos
        result.routedDrainNanos = routedDrainNanos &- earlier.routedDrainNanos
        result.headNanos = headNanos &- earlier.headNanos
        result.gpuEmbedNanos = gpuEmbedNanos &- earlier.gpuEmbedNanos
        result.gpuCb1Nanos = gpuCb1Nanos &- earlier.gpuCb1Nanos
        result.gpuSharedNanos = gpuSharedNanos &- earlier.gpuSharedNanos
        result.gpuHitExpertsNanos = gpuHitExpertsNanos &- earlier.gpuHitExpertsNanos
        result.gpuRoutedNanos = gpuRoutedNanos &- earlier.gpuRoutedNanos
        result.gpuHeadNanos = gpuHeadNanos &- earlier.gpuHeadNanos
        result.gpuBusyNanos = gpuBusyNanos &- earlier.gpuBusyNanos
        return result
    }

    /// A cumulative nanosecond count as milliseconds per forward pass, or `nil`
    /// when there were no forwards to divide by.
    public static func millisecondsPerForward(_ nanos: UInt64, forwards: Int) -> Double? {
        guard forwards > 0 else { return nil }
        return Double(nanos) / 1_000_000.0 / Double(forwards)
    }

    /// Total length covered by a set of intervals, each `(start, end)` in
    /// seconds, with overlaps counted once. Intervals that are empty or
    /// inverted contribute nothing — a command buffer that never executed
    /// reports zero for both timestamps.
    static func unionNanoseconds(of intervals: [(start: Double, end: Double)]) -> UInt64 {
        let valid = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard var current = valid.first else { return 0 }
        var total = 0.0
        for interval in valid.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                total += current.end - current.start
                current = interval
            }
        }
        total += current.end - current.start
        return UInt64(total * 1_000_000_000)
    }
}

/// Implemented by a logit producer that tracks the decode phase breakdown.
/// Mirrors `ExpertIOReporting`: `runRawCompletion` casts for it and reports
/// `.zero` for producers that do not keep these counters.
public protocol DecodePhaseTimingReporting {
    var decodePhaseTimings: DecodePhaseTimings { get }
}
