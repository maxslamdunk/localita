import Foundation
import TurboFieldfare

/// The runtime settings one benchmark run uses. A standard run is at the
/// platform's defaults; a sweep runs several of these in turn.
public struct BenchmarkConfiguration: Equatable, Sendable {
    public var expertCacheSlots: Int
    /// The `miss:<t>` threshold, 0 for off.
    public var expertSkipThreshold: Double
    /// Per layer, 0 for off.
    public var earlyExpertReads: Int

    public init(expertCacheSlots: Int, expertSkipThreshold: Double, earlyExpertReads: Int) {
        self.expertCacheSlots = expertCacheSlots
        self.expertSkipThreshold = expertSkipThreshold
        self.earlyExpertReads = earlyExpertReads
    }

    /// What a chat runs at unless Settings changed it: on a 12 GB iPhone,
    /// 32 slots since 2026-11-12. Each report records its slot count.
    public static var standard: BenchmarkConfiguration {
        .init(expertCacheSlots: AppRuntimeOptions.defaultExpertCacheSlots(
                  physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
              expertSkipThreshold: RuntimeConfiguration.productionExpertSkipMissThreshold ?? 0,
              earlyExpertReads: 1)
    }

    /// For `RuntimeConfiguration.expertSkipMissThreshold`, which takes nil
    /// for off.
    public var expertSkipMissThreshold: Double? {
        expertSkipThreshold > 0 ? expertSkipThreshold : nil
    }

    /// How the runtime names this skip setting (`ExpertSkipPolicy`'s
    /// description), so a run can check it got what it asked for.
    public var expertSkipDescription: String? {
        expertSkipMissThreshold.map { "miss:\($0)" }
    }

    /// For a list: "32 slots · skip 0.08", "24 slots · skip off".
    public var label: String {
        let skip = expertSkipThreshold > 0
            ? String(format: "skip %.2f", expertSkipThreshold) : "skip off"
        let early = earlyExpertReads == 1 ? "" : " · \(earlyExpertReads) early reads"
        return "\(expertCacheSlots) slots · \(skip)\(early)"
    }

    public var runSettings: BenchmarkReport.RunSettings {
        .init(maxContext: BenchmarkProtocol.maxContext,
              maxNewTokens: BenchmarkProtocol.maxNewTokens,
              expertCacheSlots: expertCacheSlots,
              temperature: BenchmarkProtocol.temperature,
              topK: BenchmarkProtocol.topK, topP: BenchmarkProtocol.topP,
              seed: BenchmarkProtocol.seed,
              expertSkipThreshold: expertSkipThreshold,
              earlyExpertReads: earlyExpertReads)
    }
}

/// The settings sweep: the standard run's cases at 24 and 32 expert slots,
/// each with skipping off, at 0.08 and at 0.10, one run each, plus the default
/// again at the end so the first and last runs show how far two runs of one
/// setting land apart. The slot count alternates, so a phone that slows over
/// the hour slows both counts alike. Predictions:
/// `results/benchmark-results-2026-11-10-ios-settings-sweep/predictions.md`.
///
/// Offered only on 12 GB phones: on an 8 GB iPhone 17, 32 slots left no room
/// for the photo picker and, with the early read, ran slower than 24.
public enum BenchmarkSweep {
    public static let configurations: [BenchmarkConfiguration] = [
        .init(expertCacheSlots: 24, expertSkipThreshold: 0.08, earlyExpertReads: 1),
        .init(expertCacheSlots: 32, expertSkipThreshold: 0, earlyExpertReads: 1),
        .init(expertCacheSlots: 24, expertSkipThreshold: 0.10, earlyExpertReads: 1),
        .init(expertCacheSlots: 32, expertSkipThreshold: 0.08, earlyExpertReads: 1),
        .init(expertCacheSlots: 24, expertSkipThreshold: 0, earlyExpertReads: 1),
        .init(expertCacheSlots: 32, expertSkipThreshold: 0.10, earlyExpertReads: 1),
        .init(expertCacheSlots: 24, expertSkipThreshold: 0.08, earlyExpertReads: 1),
    ]

    /// Between runs: at least three minutes, then until the phone is back to
    /// the thermal state the sweep began at, and never more than ten.
    public static let pauseMinimum: TimeInterval = 180
    public static let pauseMaximum: TimeInterval = 600

    /// 12 GB phones report about 12.2–12.3 billion bytes, 8 GB ones about 8.0.
    public static let minimumPhysicalMemoryBytes: UInt64 = 10_000_000_000

    public static func isOffered(physicalMemoryBytes: UInt64) -> Bool {
        physicalMemoryBytes >= minimumPhysicalMemoryBytes
    }
}

/// A line in the results list: a run of its own, or every run of one sweep.
public enum BenchmarkListEntry: Equatable, Sendable, Identifiable {
    case single(BenchmarkReport)
    /// In run order.
    case sweep(id: String, runs: [BenchmarkReport])

    public var id: String {
        switch self {
        case .single(let report): return report.id
        case .sweep(let id, _): return "sweep-" + id
        }
    }

    public var started: Date {
        switch self {
        case .single(let report): return report.started
        case .sweep(_, let runs): return runs.first?.started ?? .distantPast
        }
    }

    /// Every report it stands for.
    public var reports: [BenchmarkReport] {
        switch self {
        case .single(let report): return [report]
        case .sweep(_, let runs): return runs
        }
    }

    /// Newest first, as `BenchmarkStore.list` gives reports, with a sweep's
    /// runs gathered under the sweep's first run.
    public static func group(_ reports: [BenchmarkReport]) -> [BenchmarkListEntry] {
        var sweeps: [String: [BenchmarkReport]] = [:]
        var entries: [BenchmarkListEntry] = []
        for report in reports {
            if let sweep = report.sweep {
                sweeps[sweep.id, default: []].append(report)
            } else {
                entries.append(.single(report))
            }
        }
        for (id, runs) in sweeps {
            entries.append(.sweep(id: id, runs: runs.sorted {
                ($0.sweep?.index ?? 0, $0.started) < ($1.sweep?.index ?? 0, $1.started)
            }))
        }
        return entries.sorted { $0.started > $1.started }
    }
}
