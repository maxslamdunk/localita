import Foundation
import Metal

/// One prefill endpoint: the first `endpoint` tokens of a text prefilled from
/// an empty KV, and the next-token distribution the final row predicts.
public struct PrefillEndpointScore: Sendable, Equatable {
    public let endpoint: Int
    /// The text's own next token, or `nil` at the end of the text.
    public let target: Int32?
    /// `-log p(target)` after the softcap, in nats.
    public let nll: Double?
    /// The likeliest tokens, best first, with their log-probabilities.
    public let topIDs: [Int32]
    public let topLogProbs: [Double]
}

/// A quality gate for prefill changes that reorder floating-point work
/// (PF-15, PF-16): prefill a real text to several endpoints and score each
/// endpoint's final-row logits against the text's own next token. Two arms of
/// one binary are compared offline by delta-NLL and top-1 agreement, which
/// tolerates the near ties exact identity falsely rejects (METH-01).
public enum PrefillEndpointScoring {
    /// Gemma 4's final logit softcap; the head writes logits before it.
    public static let logitSoftcap: Float = 30.0

    /// `count` endpoints spread evenly over `1...tokenCount`, the last being
    /// the whole text, which scores the first token a reply would sample.
    public static func endpoints(tokenCount: Int, count: Int) -> [Int] {
        guard tokenCount > 0, count > 0 else { return [] }
        let n = min(count, tokenCount)
        var seen = Set<Int>()
        return (1...n).compactMap { i in
            let endpoint = max(1, (tokenCount * i + n / 2) / n)
            return seen.insert(endpoint).inserted ? endpoint : nil
        }
    }

    /// Log-softmax of the softcapped logits: the target's NLL and the top
    /// `topK` tokens.
    public static func score(logits: UnsafeBufferPointer<Float16>,
                             target: Int32?,
                             topK: Int = 5) -> (nll: Double?, topIDs: [Int32], topLogProbs: [Double]) {
        let capped = logits.map { Double(logitSoftcap) * tanh(Double(Float($0)) / Double(logitSoftcap)) }
        let peak = capped.max() ?? 0
        let logSum = peak + log(capped.reduce(0) { $0 + exp($1 - peak) })
        let nll = target.map { logSum - capped[Int($0)] }
        let top = capped.indices.sorted { capped[$0] > capped[$1] }.prefix(topK)
        return (nll, top.map { Int32($0) }, top.map { capped[$0] - logSum })
    }

    /// Prefills `tokens[..<endpoint]` from an empty KV for each endpoint and
    /// scores the final row. Resets the runner before each, and after the last.
    public static func run(runner: RealForwardRunner,
                           tokens: [Int32],
                           endpoints: [Int],
                           config: PrefillRuntimeConfig,
                           logits: MTLBuffer,
                           vocab: Int,
                           onScore: (PrefillEndpointScore) -> Void = { _ in }) async throws
        -> [PrefillEndpointScore] {
        var scores: [PrefillEndpointScore] = []
        defer { runner.reset() }
        for endpoint in endpoints {
            try Task.checkCancellation()
            runner.reset()
            _ = try await runner.prefillChunked(tokens: tokens[..<endpoint],
                                                startPosition: 0,
                                                outputMode: .logits,
                                                config: config,
                                                into: logits,
                                                onProgress: { _ in })
            let pointer = logits.contents().bindMemory(to: Float16.self, capacity: vocab)
            let target = endpoint < tokens.count ? tokens[endpoint] : nil
            let result = score(logits: UnsafeBufferPointer(start: pointer, count: vocab),
                               target: target)
            let entry = PrefillEndpointScore(endpoint: endpoint,
                                             target: target,
                                             nll: result.nll,
                                             topIDs: result.topIDs,
                                             topLogProbs: result.topLogProbs)
            scores.append(entry)
            onScore(entry)
        }
        return scores
    }
}
