/// Cumulative per-phase chunked-prefill timings, in nanoseconds, off the
/// forward runner. The prefill counterpart of `DecodePhaseTimings`.
///
/// Three views of the same chunks, not to be added across:
///
/// - **CPU-side wall** (`attentionBlockNanos` … `headNanos`): each layer of a
///   chunk runs these in sequence, every one waiting on its own GPU work, so
///   they sum to nearly the chunk's wall. `routedNanos` is the whole routed
///   tile loop; `fetchNanos` and `drainNanos` are the parts of it spent in the
///   tile fetch (cache planning plus the `pread`s) and blocked on a tile's
///   command buffer.
/// - **GPU execution** (`gpu…`), from each command buffer's own timestamps.
///   The attention block (norm → QKV → RoPE + KV write → attention → output
///   projection → router) is one command buffer unless phase profiling is on,
///   which commits and waits on it in five pieces so each can be timed alone.
///   Profiling adds about 150 waits per chunk; a profiled run is not a speed
///   measurement.
/// - **Storage**: the union of the routed-expert reads' own intervals, and how
///   much of it the GPU was busy for. Reads overlap one another, so the union
///   is the time storage had at least one read in flight.
public struct PrefillPhaseTimings: Sendable, Equatable {
    /// Chunks executed. A chunk is one pass of every layer over its tokens.
    public var chunks: Int = 0
    /// Chunks executed with the attention block split for profiling.
    public var profiledChunks: Int = 0
    /// Wall time of the chunks themselves, embed to final head.
    public var wallNanos: UInt64 = 0

    /// Encode, commit and wait of the attention block, per layer.
    public var attentionBlockNanos: UInt64 = 0
    /// Reading the routes back and grouping them into expert tiles.
    public var routePlanNanos: UInt64 = 0
    /// The shared-expert command buffer, encode to completion.
    public var sharedNanos: UInt64 = 0
    /// The routed tile loop: fetch, encode, and draining every tile.
    public var routedNanos: UInt64 = 0
    /// The part of `routedNanos` inside the tile fetch.
    public var fetchNanos: UInt64 = 0
    /// The part of `routedNanos` blocked on a tile's command buffer.
    public var drainNanos: UInt64 = 0
    /// Weighted reduce plus layer tail, encode to completion.
    public var tailNanos: UInt64 = 0
    /// Final norm + lm_head on the last chunk.
    public var headNanos: UInt64 = 0

    /// Embedding gather. Only split out when profiling; otherwise it is in
    /// layer 0's attention block.
    public var gpuEmbedNanos: UInt64 = 0
    /// The attention block as one command buffer (unprofiled chunks only).
    public var gpuAttentionBlockNanos: UInt64 = 0
    /// Profiled pieces of the attention block.
    public var gpuQKVProjectionNanos: UInt64 = 0
    public var gpuQKVEpilogueNanos: UInt64 = 0
    public var gpuAttentionNanos: UInt64 = 0
    public var gpuOutputProjectionNanos: UInt64 = 0
    public var gpuRouterNanos: UInt64 = 0
    public var gpuSharedNanos: UInt64 = 0
    /// Every routed tile command buffer, summed. Tiles queue behind each other
    /// and can overlap, so this can exceed their union.
    public var gpuRoutedNanos: UInt64 = 0
    public var gpuTailNanos: UInt64 = 0
    public var gpuHeadNanos: UInt64 = 0
    /// Union of every command buffer's interval above.
    public var gpuBusyNanos: UInt64 = 0

    /// Union of the routed-expert read intervals.
    public var storageBusyNanos: UInt64 = 0
    /// Time both storage and the GPU were busy.
    public var storageGPUOverlapNanos: UInt64 = 0

    public init() {}

    public static let zero = PrefillPhaseTimings()

    /// GPU time of the attention block whichever way it was committed.
    public var gpuAttentionBlockTotalNanos: UInt64 {
        gpuAttentionBlockNanos &+ gpuQKVProjectionNanos &+ gpuQKVEpilogueNanos
            &+ gpuAttentionNanos &+ gpuOutputProjectionNanos &+ gpuRouterNanos
    }

    /// Wall time during which neither storage nor the GPU was busy.
    public var bothIdleNanos: UInt64 {
        let either = gpuBusyNanos &+ storageBusyNanos &- storageGPUOverlapNanos
        return wallNanos > either ? wallNanos - either : 0
    }

    /// Counters accumulated between `earlier` and `self`.
    public func delta(since earlier: PrefillPhaseTimings) -> PrefillPhaseTimings {
        combined(with: earlier, nanos: { $0 &- $1 }, count: { $0 - $1 })
    }

    /// `self` with `other`'s counters added in.
    func adding(_ other: PrefillPhaseTimings) -> PrefillPhaseTimings {
        combined(with: other, nanos: { $0 &+ $1 }, count: { $0 + $1 })
    }

    private static var nanosecondFields: [WritableKeyPath<PrefillPhaseTimings, UInt64>] {
        [\.wallNanos, \.attentionBlockNanos, \.routePlanNanos, \.sharedNanos, \.routedNanos,
         \.fetchNanos, \.drainNanos, \.tailNanos, \.headNanos,
         \.gpuEmbedNanos, \.gpuAttentionBlockNanos, \.gpuQKVProjectionNanos,
         \.gpuQKVEpilogueNanos, \.gpuAttentionNanos, \.gpuOutputProjectionNanos,
         \.gpuRouterNanos, \.gpuSharedNanos, \.gpuRoutedNanos, \.gpuTailNanos, \.gpuHeadNanos,
         \.gpuBusyNanos, \.storageBusyNanos, \.storageGPUOverlapNanos]
    }

    private func combined(with other: PrefillPhaseTimings,
                          nanos: (UInt64, UInt64) -> UInt64,
                          count: (Int, Int) -> Int) -> PrefillPhaseTimings {
        var r = self
        r.chunks = count(chunks, other.chunks)
        r.profiledChunks = count(profiledChunks, other.profiledChunks)
        for field in Self.nanosecondFields {
            r[keyPath: field] = nanos(self[keyPath: field], other[keyPath: field])
        }
        return r
    }

    /// Intervals, each `(start, end)` in nanoseconds, merged into sorted
    /// disjoint ones. Empty and inverted intervals are dropped.
    static func mergedIntervals(_ intervals: [(start: UInt64, end: UInt64)])
        -> [(start: UInt64, end: UInt64)] {
        let valid = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [(start: UInt64, end: UInt64)] = []
        for interval in valid {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    static func totalLength(of merged: [(start: UInt64, end: UInt64)]) -> UInt64 {
        merged.reduce(0) { $0 &+ ($1.end - $1.start) }
    }

    /// Length of the intersection of two sets of intervals, each merged first.
    static func overlapNanoseconds(_ a: [(start: UInt64, end: UInt64)],
                                   _ b: [(start: UInt64, end: UInt64)]) -> UInt64 {
        let x = mergedIntervals(a)
        let y = mergedIntervals(b)
        var i = 0, j = 0
        var total: UInt64 = 0
        while i < x.count, j < y.count {
            let start = max(x[i].start, y[j].start)
            let end = min(x[i].end, y[j].end)
            if end > start { total &+= end - start }
            if x[i].end < y[j].end { i += 1 } else { j += 1 }
        }
        return total
    }
}

/// Implemented by a logit producer that tracks the chunked-prefill breakdown.
/// `runRawCompletion` casts for it and reports `.zero` otherwise.
public protocol PrefillPhaseTimingReporting {
    var prefillPhaseTimings: PrefillPhaseTimings { get }
}

/// Which part of a prefill chunk a command buffer carries.
enum PrefillGPUPart {
    case embed, attentionBlock, qkvProjection, qkvEpilogue, attention, outputProjection,
         router, shared, routed, tail, head
}
