import Foundation
import Metal

/// Decode control: read one of the next layer's routed experts while storage
/// would otherwise sit idle. On by default (`RuntimeConfiguration.earlyExpertRead`,
/// since 2026-10-03); the environment variable
/// `TURBO_FIELDFARE_EARLY_EXPERT_READ` overrides it with `next-layer` or `off`.
///
/// Per layer L < last: cb1(L) also scores layer L+1's experts over L's router
/// input. After L's own reads finish, the best-scoring expert that L+1's cache
/// does not hold is read into a staging buffer outside every slot. If L+1's
/// plan then misses that expert, the staging buffer is swapped into the slot
/// the plan assigned to it and its read is skipped; otherwise the read is
/// simply wasted. The cache plans exactly as it would without this, so hit rate
/// and generated text are unchanged; only where one miss's bytes come from
/// differs. See
/// `benchmark-results-2026-10-02-ios-next-layer-prefetch/predictions.md`.
///
/// The scores come from the fitted guess the runtime ships for this model
/// (`NextLayerGuessWeights`) when there is one, and otherwise from layer L+1's
/// own router. `TURBO_FIELDFARE_EARLY_EXPERT_GUESS` overrides that with a file
/// path, or with `router` to force the router. Measured on the iPhone 17: the
/// fitted guess is used 0.68–0.75 of the time against the router's 0.55–0.61
/// (`benchmark-results-2026-10-03-ios-fitted-guess/results.md`).
final class NextLayerExpertPrefetcher: @unchecked Sendable {
    static let environmentKey = "TURBO_FIELDFARE_EARLY_EXPERT_READ"

    /// Written by the read before `done` is left, read only after waiting.
    private final class Outcome: @unchecked Sendable {
        var error: Error?
    }

    private struct Pending {
        let layer: Int
        let expert: Int
        let done: DispatchGroup
        let outcome: Outcome
        var adopted: Bool
    }

    private let staging: ExpertStagingBuffer
    /// The fitted guess, or nil to score with the next layer's own router.
    let guessWeights: NextLayerGuessWeights?
    private let queue = DispatchQueue(label: "turbo-fieldfare.early-expert-read",
                                      qos: .userInitiated)
    private var pending: Pending?

    init?(environment: [String: String] = ProcessInfo.processInfo.environment,
          enabledByDefault: Bool,
          model: Model, config: ArchConfig, device: MTLDevice) throws {
        guard Self.isEnabled(environment: environment, enabledByDefault: enabledByDefault)
        else { return nil }
        staging = try model.routedExpertStreamer(layer: 0).makeStagingBuffer()
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

    /// `TURBO_FIELDFARE_EARLY_EXPERT_READ=next-layer` or `off` wins; anything
    /// else, including unset, leaves the configuration's default.
    static func isEnabled(environment: [String: String], enabledByDefault: Bool) -> Bool {
        switch environment[environmentKey] {
        case "next-layer": return true
        case "off": return false
        default: return enabledByDefault
        }
    }

    /// Which guess scores the next layer, for logs: `router`, or the fitted
    /// file's name and SHA-256.
    var guessDescription: String {
        guessWeights.map { "\($0.name)@\($0.sha256)" } ?? "router"
    }

    /// The highest-scoring expert not in `resident`; ties go to the lower ID.
    static func choose(scores: UnsafePointer<Float>, count: Int, resident: Set<Int>) -> Int? {
        var best: Int?
        for expert in 0..<count where !resident.contains(expert) {
            if best == nil || scores[expert] > scores[best!] { best = expert }
        }
        return best
    }

    /// Drops whatever an earlier forward left pending, so an early read never
    /// crosses a forward. Prefill may change the cache in between.
    func beginForward() throws {
        try waitForPending()
        pending = nil
    }

    /// Starts reading `expert` of `layer` into the staging buffer. Waits first
    /// for the previous early read, which the staging buffer may still hold.
    func issue(layer: Int, expert: Int, streamer: PreadExpertStreamer) throws {
        try waitForPending()
        let done = DispatchGroup()
        let outcome = Outcome()
        // Captured now: an adoption swaps `staging.pointer`, but this read's
        // destination must stay the memory it started into.
        nonisolated(unsafe) let destination = staging.pointer
        done.enter()
        queue.async {
            do {
                try streamer.readEarly(expert: expert, into: destination)
            } catch {
                outcome.error = error
            }
            done.leave()
        }
        pending = Pending(layer: layer, expert: expert, done: done,
                          outcome: outcome, adopted: false)
    }

    /// If `plan` misses the pending expert, swaps the staging buffer into that
    /// miss's slot and returns the miss's index, which the plan's execution
    /// must skip and wait for with `waitForPending`. Call before the plan's
    /// buffers are bound.
    func adopt(into plan: RoutedExpertFetchPlan, streamer: PreadExpertStreamer) -> Int? {
        guard var current = pending, current.layer == plan.layer, !current.adopted,
              let index = plan.misses.first(where: { plan.experts[$0] == current.expert })
        else { return nil }
        streamer.adoptStagedExpert(staging, plan: plan.cachePlan, index: index)
        current.adopted = true
        pending = current
        return index
    }

    /// Blocks until the pending early read, if any, has finished, and rethrows
    /// its error.
    func waitForPending() throws {
        guard let current = pending else { return }
        current.done.wait()
        if let error = current.outcome.error { throw error }
    }
}
