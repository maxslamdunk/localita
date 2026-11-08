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
///   foreground read: not resident and not a pending early read.
/// - `missrank:<r>`: drop a foreground miss of rank r or later (1-based).
/// - `misssub:<t>`: like `miss`, but put in its place the best-scoring
///   resident expert outside the top 8, and take the softmax over the new set.
/// - `bias:<λ>`: cache-prior reranking (Skliar et al. 2024, arXiv
///   2412.00099). Resident experts' logits (pending early reads count as
///   resident) get λ × the running average logit range, the original top 1
///   is kept, and the top 8 of the biased logits are used, weighted by the
///   softmax of their original logits. Nothing is dropped; experts are swapped.
/// - `cum:<T>`: drop a foreground miss of rank 2 or later when the experts
///   ranked above it carry at least T of the weight (the rule of HOBBIT, Tang
///   et al. 2024, arXiv 2411.01433).
/// - `early:<λ>`: a pending early read outside the top 8 replaces the
///   lowest-logit foreground miss of rank 2 or later when its logit plus
///   λ × the running average logit range beats that miss's, and the softmax
///   is taken over the new set. Each swap saves one read. After
///   prefetch-steered routing (arXiv 2610.34721), narrowed to swaps that save
///   a read.
///
/// Two specs joined by `+` run in order: the second sees the experts the
/// first chose, and a slot the first dropped stays dropped. `bias` may only
/// come first, and neither `misssub` nor `:nonorm` may be chained.
///
/// The kept experts' weights are renormalized to the full set's sum unless
/// `:nonorm`. A dropped expert's slot in the routed kernels is filled by a
/// resident expert at weight 0, so the cache plans it as a hit and no read is
/// issued; the kernels require all eight.
package struct ExpertSkipPolicy: Sendable, Equatable {
    package static let environmentKey = "TURBO_FIELDFARE_EXPERT_SKIP"

    package enum Kind: String, Sendable { case topk, wdrop, miss, missrank, misssub, bias, cum, early }

    package let kind: Kind
    package let value: Double
    package let renormalize: Bool
    /// Policies applied after this one, in order.
    package let then: [ExpertSkipPolicy]

    package init(kind: Kind, value: Double, renormalize: Bool = true,
                 then: [ExpertSkipPolicy] = []) {
        self.kind = kind
        self.value = value
        self.renormalize = renormalize
        self.then = then
    }

    package init?(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let spec = environment[Self.environmentKey], !spec.isEmpty else { return nil }
        var steps: [ExpertSkipPolicy] = []
        for step in spec.split(separator: "+", omittingEmptySubsequences: false) {
            let parts = step.split(separator: ":").map(String.init)
            guard parts.count == 2 || (parts.count == 3 && parts[2] == "nonorm"),
                  let kind = Kind(rawValue: parts[0]), let value = Double(parts[1]) else {
                throw ExpertSkipPolicyError.badSpec(spec)
            }
            steps.append(ExpertSkipPolicy(kind: kind, value: value, renormalize: parts.count == 2))
        }
        if steps.count > 1, steps.contains(where: { $0.kind == .misssub || !$0.renormalize })
            || steps.dropFirst().contains(where: { $0.kind == .bias }) {
            throw ExpertSkipPolicyError.badSpec(spec)
        }
        let first = steps[0]
        self.init(kind: first.kind, value: first.value, renormalize: first.renormalize,
                  then: Array(steps.dropFirst()))
    }

    package var description: String {
        ([self] + then).map { "\($0.kind.rawValue):\($0.value)" + ($0.renormalize ? "" : ":nonorm") }
            .joined(separator: "+")
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
    ///   - pendingEarly: the experts early reads are bringing in.
    package func decide(experts: [Int], logits: [Float], perExpertScale: [Float],
                        resident: Set<Int>, residentByUse: [Int],
                        pendingEarly: Set<Int>, averageLogitRange: Float = 0) -> Decision {
        let k = experts.count
        if !then.isEmpty || kind == .early {
            return chained(experts: experts, logits: logits, perExpertScale: perExpertScale,
                           resident: resident, residentByUse: residentByUse,
                           pendingEarly: pendingEarly, averageLogitRange: averageLogitRange)
        }
        if kind == .bias {
            return rerank(experts: experts, logits: logits, perExpertScale: perExpertScale,
                          resident: resident, pendingEarly: pendingEarly,
                          averageLogitRange: averageLogitRange)
        }
        let top = experts.map { logits[$0] }
        let maxLogit = top.max() ?? 0
        let exps = top.map { Double(Foundation.exp($0 - maxLogit)) }
        let total = exps.reduce(0, +)
        let p = exps.map { $0 / total }
        func foregroundMiss(_ e: Int) -> Bool { !resident.contains(e) && !pendingEarly.contains(e) }

        var drop = [Bool](repeating: false, count: k)
        for i in 1..<k {
            switch kind {
            case .topk: drop[i] = i >= Int(value)
            case .wdrop: drop[i] = p[i] < value
            case .miss, .misssub: drop[i] = p[i] < value && foregroundMiss(experts[i])
            case .missrank: drop[i] = i + 1 >= Int(value) && foregroundMiss(experts[i])
            case .cum: drop[i] = p[0..<i].reduce(0, +) >= value && foregroundMiss(experts[i])
            case .bias, .early: break
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

extension ExpertSkipPolicy {
    func rerank(experts: [Int], logits: [Float], perExpertScale: [Float],
                resident: Set<Int>, pendingEarly: Set<Int>,
                averageLogitRange: Float) -> Decision {
        let k = experts.count
        let bonus = Float(value) * averageLogitRange
        var biased = logits
        for e in resident where e < biased.count { biased[e] += bonus }
        for e in pendingEarly where e < biased.count && !resident.contains(e) {
            biased[e] += bonus
        }
        biased[experts[0]] = .infinity
        let picked = Array(biased.indices.sorted {
            biased[$0] != biased[$1] ? biased[$0] > biased[$1] : $0 < $1
        }.prefix(k))
        let original = experts.map { logits[$0] }
        let maxOriginal = original.max() ?? 0
        let originalExps = original.map { Double(Foundation.exp($0 - maxOriginal)) }
        let originalTotal = originalExps.reduce(0, +)
        var decision = Decision(experts: experts, weights: [], dropped: 0, droppedMass: 0,
                                substituted: 0)
        let pickedSet = Set(picked)
        let originalSet = Set(experts)
        for i in 0..<k where !pickedSet.contains(experts[i]) {
            decision.dropped += 1
            decision.substituted += 1
            decision.droppedMass += originalExps[i] / originalTotal
        }
        // Survivors keep their positions; newcomers fill the vacated ones.
        var newcomers = picked.filter { !originalSet.contains($0) }
        decision.experts = experts.map { pickedSet.contains($0) ? $0 : newcomers.removeFirst() }
        let chosen = decision.experts.map { logits[$0] }
        let m = chosen.max() ?? 0
        let e = chosen.map { Double(Foundation.exp($0 - m)) }
        let sum = e.reduce(0, +)
        decision.weights = (0..<k).map { Float(e[$0] / sum) * perExpertScale[decision.experts[$0]] }
        return decision
    }
}

extension ExpertSkipPolicy {
    /// The chained path, which `early` alone also takes. Each step works on
    /// the slots still active; the weights are the softmax over the final set.
    func chained(experts: [Int], logits: [Float], perExpertScale: [Float],
                 resident: Set<Int>, residentByUse: [Int], pendingEarly: Set<Int>,
                 averageLogitRange: Float) -> Decision {
        let k = experts.count
        func foregroundMiss(_ e: Int) -> Bool { !resident.contains(e) && !pendingEarly.contains(e) }
        // nil marks a dropped slot; `droppedExpert` remembers what was there.
        var slots: [Int?] = experts
        var droppedExpert = [Int?](repeating: nil, count: k)
        for step in [self] + then {
            switch step.kind {
            case .bias:
                slots = step.rerank(experts: experts, logits: logits, perExpertScale: perExpertScale,
                                    resident: resident, pendingEarly: pendingEarly,
                                    averageLogitRange: averageLogitRange).experts
            case .early:
                let bonus = Float(step.value) * averageLogitRange
                for e in pendingEarly.sorted(by: { logits[$0] != logits[$1] ? logits[$0] > logits[$1] : $0 < $1 })
                where e < logits.count && !slots.contains(e) {
                    let misses = (1..<k).filter { slots[$0].map(foregroundMiss) ?? false }
                    guard let i = misses.min(by: { logits[slots[$0]!] < logits[slots[$1]!] }),
                          logits[e] + bonus > logits[slots[i]!] else { continue }
                    slots[i] = e
                }
            case .topk, .wdrop, .miss, .missrank, .cum:
                // Rank and weight among the active slots, as they stand before this step.
                let order = (0..<k).filter { slots[$0] != nil }
                    .sorted { logits[slots[$0]!] > logits[slots[$1]!] }
                let z = order.map { logits[slots[$0]!] }
                let m = z.max() ?? 0
                let e = z.map { Double(Foundation.exp($0 - m)) }
                let total = e.reduce(0, +)
                let p = e.map { $0 / total }
                var above = 0.0
                for (rank, i) in order.enumerated() {
                    defer { above += p[rank] }
                    guard i != 0, let expert = slots[i] else { continue }
                    let drop: Bool
                    switch step.kind {
                    case .topk: drop = rank >= Int(step.value)
                    case .wdrop: drop = p[rank] < step.value
                    case .miss: drop = p[rank] < step.value && foregroundMiss(expert)
                    case .missrank: drop = rank + 1 >= Int(step.value) && foregroundMiss(expert)
                    case .cum: drop = above >= step.value && foregroundMiss(expert)
                    default: drop = false
                    }
                    if drop {
                        slots[i] = nil
                        droppedExpert[i] = expert
                    }
                }
            case .misssub:
                break
            }
        }

        // Dropped slots take a resident stand-in at weight 0; with none left,
        // the dropped expert stays.
        var fillers = residentByUse.filter { !slots.contains($0) && !droppedExpert.contains($0) }
        var final = [Int](repeating: 0, count: k)
        var active = [Bool](repeating: true, count: k)
        for i in 0..<k {
            if let e = slots[i] {
                final[i] = e
            } else if !fillers.isEmpty {
                final[i] = fillers.removeFirst()
                active[i] = false
            } else {
                final[i] = droppedExpert[i]!
            }
        }
        let chosen = (0..<k).filter { active[$0] }
        let m = chosen.map { logits[final[$0]] }.max() ?? 0
        let e = (0..<k).map { active[$0] ? Double(Foundation.exp(logits[final[$0]] - m)) : 0 }
        let sum = e.reduce(0, +)

        let original = experts.map { logits[$0] }
        let maxOriginal = original.max() ?? 0
        let originalExps = original.map { Double(Foundation.exp($0 - maxOriginal)) }
        let originalTotal = originalExps.reduce(0, +)
        let kept = Set(chosen.map { final[$0] })
        var decision = Decision(
            experts: final,
            weights: (0..<k).map { Float(e[$0] / sum) * perExpertScale[final[$0]] },
            dropped: 0, droppedMass: 0, substituted: 0)
        for i in 0..<k where !kept.contains(experts[i]) {
            decision.dropped += 1
            decision.droppedMass += originalExps[i] / originalTotal
        }
        decision.substituted = kept.subtracting(experts).count
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

    /// Per layer step, as `TurboFieldfareScore` and the iOS harness log it.
    package var summary: String {
        let steps = Double(max(1, layerSteps))
        return String(format: "dropped/layer %.3f, dropped mass/layer %.4f, substituted/layer %.3f",
                      Double(dropped) / steps, droppedMass / steps, Double(substituted) / steps)
    }
}
