import Synchronization

/// Cumulative routed-expert I/O totals read out of `ExpertIOCounters`.
///
/// Bytes are the ones the streamer actually pulled through `pread`; a routed
/// expert served from a resident slot contributes to `cacheHits` and to no
/// bytes at all. Totals span every phase that touched the streamer, so prefill
/// and decode are separated by differencing two snapshots rather than by
/// separate counters — see `delta(since:)`.
public struct ExpertIOStats: Sendable, Equatable {
    /// Bytes returned by `pread` on the routed-expert path.
    public var bytesRead: UInt64
    /// Expert-sized slot fills issued (one per cache miss serviced).
    public var reads: UInt64
    /// Routed-expert requests found resident in a slot.
    public var cacheHits: UInt64
    /// Routed-expert requests that had to be read.
    public var cacheMisses: UInt64

    public init(bytesRead: UInt64 = 0,
                reads: UInt64 = 0,
                cacheHits: UInt64 = 0,
                cacheMisses: UInt64 = 0) {
        self.bytesRead = bytesRead
        self.reads = reads
        self.cacheHits = cacheHits
        self.cacheMisses = cacheMisses
    }

    public static let zero = ExpertIOStats()

    /// Counters accumulated between `earlier` and `self`. Wrapping subtraction
    /// mirrors the wrapping adds on the recording side.
    public func delta(since earlier: ExpertIOStats) -> ExpertIOStats {
        ExpertIOStats(bytesRead: bytesRead &- earlier.bytesRead,
                      reads: reads &- earlier.reads,
                      cacheHits: cacheHits &- earlier.cacheHits,
                      cacheMisses: cacheMisses &- earlier.cacheMisses)
    }

    /// Routed-expert requests planned against the cache. At steady-state decode
    /// this is `numLayers * topKExperts` per forward.
    public var cacheRequests: UInt64 { cacheHits &+ cacheMisses }

    /// Fraction of routed-expert requests served without a read; `nil` when
    /// nothing was requested, which is not the same as a 0% hit rate.
    public var cacheHitRate: Double? {
        guard cacheRequests > 0 else { return nil }
        return Double(cacheHits) / Double(cacheRequests)
    }

    /// The headline unit: bytes read per forward pass. `forwards` is the number
    /// of forwards in the window, which for decode is not the number of
    /// generated tokens — the final sampled token never runs a forward.
    public func megabytesPerForward(_ forwards: Int) -> Double? {
        guard forwards > 0 else { return nil }
        return Double(bytesRead) / 1_048_576.0 / Double(forwards)
    }
}

/// Lock-free cumulative counters for the routed-expert read path.
///
/// One instance is shared by every per-layer streamer a `Model` opens, so a
/// snapshot covers the whole model rather than one layer. Recording is a
/// relaxed atomic add on a path whose unit of work is a multi-megabyte `pread`,
/// so it neither orders nor measurably delays the reads it counts.
public final class ExpertIOCounters: Sendable {
    private let bytesRead = Atomic<UInt64>(0)
    private let reads = Atomic<UInt64>(0)
    private let cacheHits = Atomic<UInt64>(0)
    private let cacheMisses = Atomic<UInt64>(0)

    public init() {}

    /// Four independent relaxed loads: a snapshot taken while reads are in
    /// flight can be skewed by the reads outstanding at that instant. That is
    /// bounded by the concurrency of one plan (at most `topK` misses) and does
    /// not accumulate, since every counter is monotonic.
    public func snapshot() -> ExpertIOStats {
        ExpertIOStats(bytesRead: bytesRead.load(ordering: .relaxed),
                      reads: reads.load(ordering: .relaxed),
                      cacheHits: cacheHits.load(ordering: .relaxed),
                      cacheMisses: cacheMisses.load(ordering: .relaxed))
    }

    func recordReadIssued() {
        reads.wrappingAdd(1, ordering: .relaxed)
    }

    func recordBytesRead(_ count: UInt64) {
        bytesRead.wrappingAdd(count, ordering: .relaxed)
    }

    func recordCachePlan(hits: Int, misses: Int) {
        guard hits > 0 || misses > 0 else { return }
        cacheHits.wrappingAdd(UInt64(hits), ordering: .relaxed)
        cacheMisses.wrappingAdd(UInt64(misses), ordering: .relaxed)
    }
}

/// A producer that can report the routed-expert bytes it has read so far.
/// `runRawCompletion` uses this to bracket prefill and decode; conforming is
/// how a producer gets its byte profile into `RawDecodeResult`.
public protocol ExpertIOReporting {
    var expertIOStats: ExpertIOStats { get }
}
