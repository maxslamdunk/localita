import Foundation
import Metal

/// Decode control: read the next layer's likeliest routed experts while
/// storage would otherwise sit idle. On by default
/// (`RuntimeConfiguration.earlyExpertRead`, since 2026-10-03); the environment
/// variable `TURBO_FIELDFARE_EARLY_EXPERT_READ` overrides it with `next-layer`
/// or `off`.
///
/// Per layer L < last: cb1(L) also scores layer L+1's experts over L's router
/// input. After L's own reads finish, the best-scoring experts that L+1's cache
/// does not hold are read, best first, into staging buffers outside every
/// slot. Each one L+1's plan then misses has its staging buffer swapped into
/// the slot the plan assigned to it and its read skipped; the rest are simply
/// wasted. The cache plans exactly as it would without this, so hit rate and
/// generated text are unchanged; only where some misses' bytes come from
/// differs. See
/// `results/benchmark-results-2026-10-02-ios-next-layer-prefetch/predictions.md`.
///
/// The scores come from the fitted guess the runtime ships for this model
/// (`NextLayerGuessWeights`) when there is one, and otherwise from layer L+1's
/// own router. `TURBO_FIELDFARE_EARLY_EXPERT_GUESS` overrides that with a file
/// path, or with `router` to force the router. Measured on the iPhone 17: the
/// fitted guess is used 0.68–0.75 of the time against the router's 0.55–0.61
/// (`results/benchmark-results-2026-10-03-ios-fitted-guess/results.md`).
///
/// One read per layer by default: on the iPhone 17 the storage idle time per
/// layer was about one read long. `TURBO_FIELDFARE_EARLY_EXPERT_READS` (1–8)
/// sets more; each costs one more 3.36 MB staging buffer. On the M1 two beat
/// one by +11.5 to +14.8% (`results/benchmark-results-2026-10-07-early-read-v3/`).
final class NextLayerExpertPrefetcher: @unchecked Sendable {
    static let environmentKey = "TURBO_FIELDFARE_EARLY_EXPERT_READ"
    static let readsEnvironmentKey = "TURBO_FIELDFARE_EARLY_EXPERT_READS"
    static let maxReadsPerLayer = 8

    /// Written by the read before `done` is left, read only after waiting.
    private final class Outcome: @unchecked Sendable {
        var error: Error?
    }

    private struct Pending {
        let expert: Int
        let staging: Int
        let done: DispatchGroup
        let outcome: Outcome
        var adopted = false
    }

    private let staging: [ExpertStagingBuffer]
    /// The fitted guess, or nil to score with the next layer's own router.
    let guessWeights: NextLayerGuessWeights?
    private let queue = DispatchQueue(label: "turbo-fieldfare.early-expert-read",
                                      qos: .userInitiated)
    private var pendingLayer: Int?
    private var pending: [Pending] = []

    /// Early reads per layer.
    var readsPerLayer: Int { staging.count }

    init?(environment: [String: String] = ProcessInfo.processInfo.environment,
          enabledByDefault: Bool,
          readsPerLayerByDefault: Int = 1,
          model: Model, config: ArchConfig, device: MTLDevice) throws {
        guard Self.isEnabled(environment: environment, enabledByDefault: enabledByDefault)
        else { return nil }
        let streamer = try model.routedExpertStreamer(layer: 0)
        staging = try (0..<Self.readsPerLayer(environment: environment,
                                              byDefault: readsPerLayerByDefault)).map { _ in
            try streamer.makeStagingBuffer()
        }
        switch environment[NextLayerGuessWeights.environmentKey] {
        case "router":
            guessWeights = nil
        case let path? where !path.isEmpty:
            guessWeights = try NextLayerGuessWeights(
                fileURL: URL(fileURLWithPath: path), numLayers: config.numLayers,
                numExperts: config.numExperts, hiddenSize: config.hiddenSize, device: device)
        default:
            guessWeights = try NextLayerGuessWeights.bundled(
                sourceSnapshotHash: model.sourceSnapshotHash, numLayers: config.numLayers,
                numExperts: config.numExperts, hiddenSize: config.hiddenSize, device: device)
        }
    }

    deinit {
        // A read may still be filling a staging buffer, which is freed with
        // this object.
        for read in pending { read.done.wait() }
    }

    /// `TURBO_FIELDFARE_EARLY_EXPERT_READ=next-layer` or `off` wins; anything
    /// else, including unset, leaves the configuration's default.
    static func isEnabled(environment: [String: String], enabledByDefault: Bool) -> Bool {
        switch environment[environmentKey] {
        case "next-layer": return true
        case "off": return false
        default: return enabledByDefault
        }
    }

    /// `TURBO_FIELDFARE_EARLY_EXPERT_READS` when it is a whole number from 1
    /// to `maxReadsPerLayer`, otherwise `byDefault` (the configuration's
    /// `earlyExpertReadsPerLayer`), clamped to that range.
    static func readsPerLayer(environment: [String: String], byDefault: Int = 1) -> Int {
        guard let value = environment[readsEnvironmentKey].flatMap({ Int($0) }),
              (1...maxReadsPerLayer).contains(value)
        else { return min(max(byDefault, 1), maxReadsPerLayer) }
        return value
    }

    /// Which guess scores the next layer, for logs: `router`, or the fitted
    /// file's name and SHA-256.
    var guessDescription: String {
        guessWeights.map { "\($0.name)@\($0.sha256)" } ?? "router"
    }

    /// Up to `limit` highest-scoring experts not in `resident`, best first;
    /// ties go to the lower ID.
    static func choose(scores: UnsafePointer<Float>, count: Int,
                       resident: Set<Int>, limit: Int = 1) -> [Int] {
        var best: [Int] = []
        for expert in 0..<count where !resident.contains(expert) {
            let position = best.firstIndex { scores[expert] > scores[$0] } ?? best.count
            if position < limit {
                best.insert(expert, at: position)
                if best.count > limit { best.removeLast() }
            }
        }
        return best
    }

    /// Drops whatever an earlier forward left pending, so an early read never
    /// crosses a forward. Prefill may change the cache in between.
    func beginForward() throws {
        try waitForPending()
        pending = []
        pendingLayer = nil
    }

    /// Starts reading `experts` of `layer`, in order, one into each staging
    /// buffer. Waits first for the previous early reads, whose buffers may
    /// still be filling.
    func issue(layer: Int, experts: [Int], streamer: PreadExpertStreamer) throws {
        precondition(experts.count <= staging.count, "more early reads than staging buffers")
        try waitForPending()
        pending = []
        pendingLayer = layer
        for (index, expert) in experts.enumerated() {
            let done = DispatchGroup()
            let outcome = Outcome()
            // Captured now: an adoption swaps `staging[index].pointer`, but this
            // read's destination must stay the memory it started into.
            nonisolated(unsafe) let destination = staging[index].pointer
            done.enter()
            queue.async {
                do {
                    try streamer.readEarly(expert: expert, into: destination)
                } catch {
                    outcome.error = error
                }
                done.leave()
            }
            pending.append(Pending(expert: expert, staging: index, done: done, outcome: outcome))
        }
    }

    /// For each pending expert `plan` misses, swaps its staging buffer into
    /// that miss's slot. Returns those misses' indices, which the plan's
    /// execution must skip and wait for with `waitForAdopted`. Call before the
    /// plan's buffers are bound.
    func adopt(into plan: RoutedExpertFetchPlan, streamer: PreadExpertStreamer) -> Set<Int> {
        guard pendingLayer == plan.layer else { return [] }
        var adopted: Set<Int> = []
        for i in pending.indices where !pending[i].adopted {
            guard let index = plan.misses.first(where: { plan.experts[$0] == pending[i].expert })
            else { continue }
            streamer.adoptStagedExpert(staging[pending[i].staging], plan: plan.cachePlan,
                                       index: index)
            pending[i].adopted = true
            adopted.insert(index)
        }
        return adopted
    }

    /// Blocks until every adopted early read has finished, and rethrows the
    /// first error. A wasted read still in flight is not waited for.
    func waitForAdopted() throws {
        try wait(for: pending.filter(\.adopted))
    }

    /// Blocks until every pending early read has finished, and rethrows the
    /// first error.
    func waitForPending() throws {
        try wait(for: pending)
    }

    private func wait(for reads: [Pending]) throws {
        for read in reads { read.done.wait() }
        if let error = reads.lazy.compactMap({ $0.outcome.error }).first { throw error }
    }
}
