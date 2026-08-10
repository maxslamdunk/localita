/// Cumulative per-phase decode timings, in nanoseconds, off the forward runner.
///
/// **These are not a timeline and must never be summed.** The phases overlap by
/// design — `io` runs while Metal executes the resident shared-expert branch —
/// and they measure deliberately different things: `cb1Nanos` and `cb2Nanos` are
/// CPU encode cost with GPU execution excluded, while the wait fields are the
/// GPU execution a forward actually blocked on. A total over all six describes
/// nothing that happened.
///
/// What they are for is comparison against the measured token time: a phase that
/// is a small fraction of it cannot be what a token is spending its time on, and
/// that is a conclusion the individual figures support without any addition.
///
/// All six come from the same monotonic clock (`CLOCK_UPTIME_RAW`); the reason
/// they are not comparable is scope, not timebase.
public struct DecodePhaseTimings: Sendable, Equatable {
    /// CPU cost of encoding and committing the attention + router command
    /// buffer, with the block on its completion excluded.
    public var cb1Nanos: UInt64 = 0
    /// Time blocked on that command buffer, once per layer — the GPU execution
    /// of attention and the router that `cb1Nanos` deliberately excludes.
    public var cb1WaitNanos: UInt64 = 0
    /// Wall time of the routed-expert fetch: cache planning plus `pread` of the
    /// misses. Overlaps the shared-expert branch running on the GPU, so it is
    /// an upper bound on what expert reads cost, not their exclusive cost.
    public var ioNanos: UInt64 = 0
    /// CPU cost of encoding and committing the routed + tail command buffer.
    /// Its GPU execution is not awaited here — the next layer absorbs it.
    public var cb2Nanos: UInt64 = 0
    /// Time blocked draining the final routed command buffer of a forward.
    /// Once per token rather than once per layer, and the only place the routed
    /// branch's GPU execution becomes visible.
    public var routedDrainNanos: UInt64 = 0
    /// Final norm + lm_head. Wall-inclusive: this path waits on its own work,
    /// so unlike `cb1Nanos` it already contains GPU execution.
    public var headNanos: UInt64 = 0

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
        return result
    }

    /// A cumulative nanosecond count as milliseconds per forward pass, or `nil`
    /// when there were no forwards to divide by.
    public static func millisecondsPerForward(_ nanos: UInt64, forwards: Int) -> Double? {
        guard forwards > 0 else { return nil }
        return Double(nanos) / 1_000_000.0 / Double(forwards)
    }
}

/// Implemented by a logit producer that tracks the decode phase breakdown.
/// Mirrors `ExpertIOReporting`: `runRawCompletion` casts for it and reports
/// `.zero` for producers that do not keep these counters.
public protocol DecodePhaseTimingReporting {
    var decodePhaseTimings: DecodePhaseTimings { get }
}
