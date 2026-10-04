import Foundation

/// Research only: decode drops some of a layer's routed experts, which
/// changes the model's output on purpose. Off unless the environment variable
/// `TURBO_FIELDFARE_EXPERT_SKIP` is set. Prefill is unaffected.
///
/// Spec `<kind>:<value>[:nonorm]`. Weights `p` are the router's softmax over
/// the top-8 logits (before the per-expert scale), and rank 1 is never dropped.
/// - `topk:<k>`: always keep only the first k.
/// - `wdrop:<t>`: always drop experts with p < t.
/// - `miss:<t>`: drop an expert with p < t only when it would be a
///   foreground read: not resident and not the pending early read.
/// - `missrank:<r>`: drop a foreground miss of rank r or later (1-based).
/// - `misssub:<t>`: like `miss`, but put in its place the best-scoring
///   resident expert outside the top 8, and take the softmax over the new set.
///
/// The kept experts' weights are renormalized to the full set's sum unless
/// `:nonorm`. A dropped expert's slot in the routed kernels is filled by a
/// resident expert at weight 0, so the cache plans it as a hit and no read is
/// issued; the kernels require all eight.
package struct ExpertSkipPolicy: Sendable, Equatable {
    package static let environmentKey = "TURBO_FIELDFARE_EXPERT_SKIP"

    package enum Kind: String, Sendable { case topk, wdrop, miss, missrank, misssub }

    package let kind: Kind
    package let value: Double
    package let renormalize: Bool

    package init(kind: Kind, value: Double, renormalize: Bool = true) {
        self.kind = kind
        self.value = value
        self.renormalize = renormalize
    }

    package init?(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let spec = environment[Self.environmentKey], !spec.isEmpty else { return nil }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 2 || (parts.count == 3 && parts[2] == "nonorm"),
              let kind = Kind(rawValue: parts[0]), let value = Double(parts[1]) else {
            throw ExpertSkipPolicyError.badSpec(spec)
        }
        self.init(kind: kind, value: value, renormalize: parts.count == 2)
    }

    package var description: String {
        "\(kind.rawValue):\(value)" + (renormalize ? "" : ":nonorm")
    }

    package struct Decision: Equatable, Sendable {
        /// Experts for the routed kernels, in router order; a dropped one is
        /// replaced by a resident expert.
        package var experts: [Int]
        /// Final routing weights, per-expert scale applied; 0 where dropped.
        package var weights: [Float]
        package var dropped: Int
        package var droppedMass: Double
        package var substituted: Int
    }

    /// - Parameters:
    ///   - experts: the router's top 8, in rank order.
    ///   - logits: router logits over all experts.
    ///   - perExpertScale: the router's per-expert scale over all experts.
    ///   - resident: experts the layer's cache holds now.
    ///   - residentByUse: the same, most used first; substitutes come from it.
    ///   - pendingEarly: the expert an early read is bringing in, if any.
    package func decide(experts: [Int], logits: [Float], perExpertScale: [Float],
                        resident: Set<Int>, residentByUse: [Int],
                        pendingEarly: Int?) -> Decision {
        let k = experts.count
        let top = experts.map { logits[$0] }
        let maxLogit = top.max() ?? 0
        let exps = top.map { Double(Foundation.exp($0 - maxLogit)) }
        let total = exps.reduce(0, +)
        let p = exps.map { $0 / total }
        func foregroundMiss(_ e: Int) -> Bool { !resident.contains(e) && e != pendingEarly }

        var drop = [Bool](repeating: false, count: k)
        for i in 1..<k {
            switch kind {
            case .topk: drop[i] = i >= Int(value)
            case .wdrop: drop[i] = p[i] < value
            case .miss, .misssub: drop[i] = p[i] < value && foregroundMiss(experts[i])
            case .missrank: drop[i] = i + 1 >= Int(value) && foregroundMiss(experts[i])
            }
        }
        var decision = Decision(experts: experts,
                                weights: (0..<k).map { Float(p[$0]) * perExpertScale[experts[$0]] },
                                dropped: 0, droppedMass: 0, substituted: 0)
        guard drop.contains(true) else { return decision }

        var used = Set(experts)
        var fillers = residentByUse.filter { !used.contains($0) }
        if kind == .misssub {
            fillers.sort { logits[$0] > logits[$1] }
        }
        var substituteLogits: [Int: Float] = [:]
        for i in 0..<k where drop[i] {
            guard !fillers.isEmpty else { drop[i] = false; continue }
            let filler = fillers.removeFirst()
            used.insert(filler)
            decision.experts[i] = filler
            decision.dropped += 1
            decision.droppedMass += p[i]
            if kind == .misssub {
                substituteLogits[i] = logits[filler]
                decision.substituted += 1
            }
        }
        if kind == .misssub {
            let newLogits = (0..<k).map { substituteLogits[$0] ?? top[$0] }
            let m = newLogits.max() ?? 0
            let e = newLogits.map { Double(Foundation.exp($0 - m)) }
            let sum = e.reduce(0, +)
            decision.weights = (0..<k).map {
                Float(e[$0] / sum) * perExpertScale[decision.experts[$0]]
            }
            return decision
        }
        let kept = (0..<k).filter { !drop[$0] }.map { p[$0] }.reduce(0, +)
        let gain = renormalize ? 1 / kept : 1
        for i in 0..<k {
            decision.weights[i] = drop[i] ? 0 : Float(p[i] * gain) * perExpertScale[experts[i]]
        }
        return decision
    }
}

package enum ExpertSkipPolicyError: Error, CustomStringConvertible {
    case badSpec(String)

    package var description: String {
        switch self {
        case .badSpec(let spec):
            return "\(ExpertSkipPolicy.environmentKey): cannot parse '\(spec)'"
        }
    }
}

/// Counts over a run, for the research footer.
package struct ExpertSkipCounts: Sendable, Equatable {
    package var layerSteps = 0
    package var dropped = 0
    package var droppedMass = 0.0
    package var substituted = 0
}
