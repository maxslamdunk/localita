import Synchronization

/// Cumulative routed-expert I/O totals read out of `ExpertIOCounters`.
///
/// Bytes are the ones the streamer actually pulled through `pread`; a routed
/// expert served from a resident slot contributes to `cacheHits` and to no
/// bytes at all. Totals span every phase that touched the streamer, so prefill
/// and decode are separated by differencing two snapshots rather than by
/// separate counters — see `delta(since:)`.
public struct ExpertIOStats: Sendable, Equatable {
    /// Upper bounds of the read-latency buckets, in microseconds. A read lands
    /// in the first bucket whose bound it is under; one more bucket past the
    /// last bound catches everything slower. Doubling from 250 µs puts a
    /// file-cache hit (a few hundred microseconds for 3.36 MB) and a storage
    /// read (about 2 ms) several buckets apart on both the Mac and the iPhone.
    public static let readLatencyBucketBoundsMicros: [UInt64] =
        [250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    public static var readLatencyBucketCount: Int { readLatencyBucketBoundsMicros.count + 1 }

    /// Bytes returned by `pread` on the routed-expert path.
    public var bytesRead: UInt64
    /// Expert-sized slot fills issued (one per cache miss serviced).
    public var reads: UInt64
    /// Routed-expert requests found resident in a slot.
    public var cacheHits: UInt64
    /// Routed-expert requests that had to be read.
    public var cacheMisses: UInt64
    /// Sum over completed reads of each one's own duration. Reads run
    /// concurrently within a layer, so this can exceed the `io` window.
    public var readLatencyNanos: UInt64
    /// Completed reads per latency bucket, `readLatencyBucketCount` entries.
    public var readLatencyBuckets: [UInt64]
    /// Early reads: a next-layer expert read before its layer was planned.
    /// Each is also one of `reads`, and its bytes are in `bytesRead`.
    public var earlyReads: UInt64
    /// Early reads whose expert the layer then missed, so the read replaced
    /// one the layer would have waited for. `earlyReads - earlyReadsUsed`
    /// were wasted.
    public var earlyReadsUsed: UInt64

    public init(bytesRead: UInt64 = 0,
                reads: UInt64 = 0,
                cacheHits: UInt64 = 0,
                cacheMisses: UInt64 = 0,
                readLatencyNanos: UInt64 = 0,
                readLatencyBuckets: [UInt64]? = nil,
                earlyReads: UInt64 = 0,
                earlyReadsUsed: UInt64 = 0) {
        self.bytesRead = bytesRead
        self.reads = reads
        self.cacheHits = cacheHits
        self.cacheMisses = cacheMisses
        self.readLatencyNanos = readLatencyNanos
        self.readLatencyBuckets = readLatencyBuckets
            ?? [UInt64](repeating: 0, count: Self.readLatencyBucketCount)
        self.earlyReads = earlyReads
        self.earlyReadsUsed = earlyReadsUsed
    }

    public static let zero = ExpertIOStats()

    /// The bucket a read of `nanos` lands in.
    public static func readLatencyBucket(forNanos nanos: UInt64) -> Int {
        let micros = nanos / 1_000
        return readLatencyBucketBoundsMicros.firstIndex { micros < $0 }
            ?? readLatencyBucketBoundsMicros.count
    }

    /// Counters accumulated between `earlier` and `self`. Wrapping subtraction
    /// mirrors the wrapping adds on the recording side.
    public func delta(since earlier: ExpertIOStats) -> ExpertIOStats {
        ExpertIOStats(bytesRead: bytesRead &- earlier.bytesRead,
                      reads: reads &- earlier.reads,
                      cacheHits: cacheHits &- earlier.cacheHits,
                      cacheMisses: cacheMisses &- earlier.cacheMisses,
                      readLatencyNanos: readLatencyNanos &- earlier.readLatencyNanos,
                      readLatencyBuckets: zip(readLatencyBuckets, earlier.readLatencyBuckets)
                          .map { $0 &- $1 },
                      earlyReads: earlyReads &- earlier.earlyReads,
                      earlyReadsUsed: earlyReadsUsed &- earlier.earlyReadsUsed)
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

    /// Reads that completed and were timed. Equal to `reads` unless a read
    /// failed partway, which aborts the run.
    public var timedReads: UInt64 { readLatencyBuckets.reduce(0, &+) }

    /// Mean duration of one read, or `nil` when none completed.
    public var meanReadLatencyMilliseconds: Double? {
        guard timedReads > 0 else { return nil }
        return Double(readLatencyNanos) / 1_000_000.0 / Double(timedReads)
    }
}

/// Cumulative counters for the routed-expert read path.
///
/// One instance is shared by every per-layer streamer a `Model` opens, so a
/// snapshot covers the whole model rather than one layer. The byte and request
/// counts are relaxed atomic adds; the latency histogram takes an uncontended
/// lock once per read. Both sit on a path whose unit of work is a
/// multi-megabyte `pread`, so neither orders nor measurably delays the reads
/// it counts.
public final class ExpertIOCounters: Sendable {
    private struct LatencyHistogram {
        var totalNanos: UInt64 = 0
        var buckets = [UInt64](repeating: 0, count: ExpertIOStats.readLatencyBucketCount)
    }

    private let bytesRead = Atomic<UInt64>(0)
    private let reads = Atomic<UInt64>(0)
    private let cacheHits = Atomic<UInt64>(0)
    private let cacheMisses = Atomic<UInt64>(0)
    private let latency = Mutex(LatencyHistogram())
    private let earlyReads = Atomic<UInt64>(0)
    private let earlyReadsUsed = Atomic<UInt64>(0)

    public init() {}

    /// Independent loads: a snapshot taken while reads are in flight can be
    /// skewed by the reads outstanding at that instant. That is bounded by the
    /// concurrency of one plan (at most `topK` misses) and does not accumulate,
    /// since every counter is monotonic.
    public func snapshot() -> ExpertIOStats {
        let histogram = latency.withLock { $0 }
        return ExpertIOStats(bytesRead: bytesRead.load(ordering: .relaxed),
                             reads: reads.load(ordering: .relaxed),
                             cacheHits: cacheHits.load(ordering: .relaxed),
                             cacheMisses: cacheMisses.load(ordering: .relaxed),
                             readLatencyNanos: histogram.totalNanos,
                             readLatencyBuckets: histogram.buckets,
                             earlyReads: earlyReads.load(ordering: .relaxed),
                             earlyReadsUsed: earlyReadsUsed.load(ordering: .relaxed))
    }

    func recordReadIssued() {
        reads.wrappingAdd(1, ordering: .relaxed)
    }

    func recordBytesRead(_ count: UInt64) {
        bytesRead.wrappingAdd(count, ordering: .relaxed)
    }

    /// One completed expert read, timed from before its first `pread` to after
    /// its last.
    func recordReadLatency(nanos: UInt64) {
        let bucket = ExpertIOStats.readLatencyBucket(forNanos: nanos)
        latency.withLock {
            $0.totalNanos &+= nanos
            $0.buckets[bucket] &+= 1
        }
    }

    func recordEarlyRead() {
        earlyReads.wrappingAdd(1, ordering: .relaxed)
    }

    func recordEarlyReadUsed() {
        earlyReadsUsed.wrappingAdd(1, ordering: .relaxed)
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
