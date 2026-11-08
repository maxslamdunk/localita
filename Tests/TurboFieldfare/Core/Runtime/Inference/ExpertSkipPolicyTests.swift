import Foundation
import Testing

@testable import TurboFieldfare

@Suite struct ExpertSkipPolicyTests {
    /// Top 8 are experts 0...7; only 6 and 7 weigh under 0.08 (about 0.02
    /// each, against 0.09 for 5). Experts 8 and 9 come next; the rest are far
    /// below.
    private static func logits() -> [Float] {
        var z = [Float](repeating: -10, count: 16)
        let top: [Float] = [2.0, 1.8, 1.6, 1.4, 1.2, 1.0, -0.5, -0.6]
        for i in 0..<8 { z[i] = top[i] }
        z[8] = 0.5
        z[9] = 0.4
        return z
    }

    private static let unitScale = [Float](repeating: 1, count: 16)

    private static func softmax(_ z: [Float]) -> [Double] {
        let m = z.max()!
        let e = z.map { Foundation.exp(Double($0 - m)) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }

    @Test func unsetEnvironmentMeansNoPolicy() throws {
        #expect(try ExpertSkipPolicy(environment: [:]) == nil)
    }

    /// The line the Mac meter and the iOS harness both log, and that the
    /// results scripts parse.
    @Test func countsSummaryIsPerLayerStep() {
        let counts = ExpertSkipCounts(layerSteps: 4, dropped: 3, droppedMass: 0.1, substituted: 1)
        #expect(counts.summary == "dropped/layer 0.750, dropped mass/layer 0.0250, substituted/layer 0.250")
        #expect(ExpertSkipCounts().summary
            == "dropped/layer 0.000, dropped mass/layer 0.0000, substituted/layer 0.000")
    }

    @Test func parsesKindValueAndNonorm() throws {
        let key = ExpertSkipPolicy.environmentKey
        #expect(try ExpertSkipPolicy(environment: [key: "miss:0.08"])
            == ExpertSkipPolicy(kind: .miss, value: 0.08))
        #expect(try ExpertSkipPolicy(environment: [key: "topk:7:nonorm"])
            == ExpertSkipPolicy(kind: .topk, value: 7, renormalize: false))
        #expect(throws: ExpertSkipPolicyError.self) {
            try ExpertSkipPolicy(environment: [key: "miss"])
        }
    }

    @Test func missDropsOnlyLowWeightForegroundMisses() {
        let z = Self.logits()
        let p = Self.softmax(Array(z[0..<8]))
        // Experts 6 and 7 fall under 0.08; 7 is resident, so only 6 drops.
        #expect(p[6] < 0.08 && p[7] < 0.08 && p[5] >= 0.08)
        let policy = ExpertSkipPolicy(kind: .miss, value: 0.08)
        let d = policy.decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                              resident: [7, 12, 13], residentByUse: [13, 12, 7],
                              pendingEarly: [])
        #expect(d.dropped == 1)
        #expect(d.experts == [0, 1, 2, 3, 4, 5, 13, 7])
        #expect(d.weights[6] == 0)
        // Renormalized: the kept weights still sum to 1.
        #expect(abs(d.weights.reduce(0, +) - 1) < 1e-3)
        #expect(abs(d.droppedMass - p[6]) < 1e-9)
    }

    @Test func pendingEarlyReadIsNotAForegroundMiss() {
        let policy = ExpertSkipPolicy(kind: .missrank, value: 7)
        let d = policy.decide(experts: Array(0..<8), logits: Self.logits(),
                              perExpertScale: Self.unitScale, resident: [12, 13],
                              residentByUse: [12, 13], pendingEarly: [6])
        #expect(d.experts == [0, 1, 2, 3, 4, 5, 6, 12])
        #expect(d.dropped == 1)
    }

    @Test func nonormLeavesKeptWeightsAlone() {
        let z = Self.logits()
        let p = Self.softmax(Array(z[0..<8]))
        let policy = ExpertSkipPolicy(kind: .topk, value: 7, renormalize: false)
        let d = policy.decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                              resident: [12], residentByUse: [12], pendingEarly: [])
        #expect(d.experts[7] == 12 && d.weights[7] == 0)
        #expect(abs(Double(d.weights[0]) - p[0]) < 1e-3)
    }

    @Test func noStandInMeansNoDrop() {
        let policy = ExpertSkipPolicy(kind: .topk, value: 6)
        let d = policy.decide(experts: Array(0..<8), logits: Self.logits(),
                              perExpertScale: Self.unitScale, resident: [], residentByUse: [],
                              pendingEarly: [])
        #expect(d.dropped == 0 && d.experts == Array(0..<8))
    }

    @Test func misssubTakesBestScoringResidentAndResoftmaxes() {
        let z = Self.logits()
        let policy = ExpertSkipPolicy(kind: .misssub, value: 0.08)
        // Resident outside the top 8: 9 (logit 0.4) and 8 (0.5); 8 scores best.
        let d = policy.decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                              resident: [7, 8, 9], residentByUse: [9, 8, 7], pendingEarly: [])
        #expect(d.experts == [0, 1, 2, 3, 4, 5, 8, 7])
        #expect(d.substituted == 1)
        let expected = Self.softmax([z[0], z[1], z[2], z[3], z[4], z[5], z[8], z[7]])
        for i in 0..<8 { #expect(abs(Double(d.weights[i]) - expected[i]) < 1e-3) }
    }

    @Test func biasRerankingKeepsTopOneAndPrefersResident() {
        let z = Self.logits()
        // A bonus of 0.25 × range 12 = 3 lifts resident 8 and 9 above 6 and 7.
        let policy = ExpertSkipPolicy(kind: .bias, value: 0.25)
        let d = policy.decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                              resident: [8, 9, 1], residentByUse: [8, 9, 1], pendingEarly: [],
                              averageLogitRange: 12)
        #expect(d.experts[0] == 0)
        #expect(Set(d.experts) == Set([0, 1, 2, 3, 4, 5, 8, 9]))
        #expect(d.dropped == 2)
        // Weights come from the original logits of the chosen set.
        let expected = Self.softmax(d.experts.map { z[$0] })
        for i in 0..<8 { #expect(abs(Double(d.weights[i]) - expected[i]) < 1e-3) }
    }

    @Test func parsesChainsAndRejectsBadOnes() throws {
        let key = ExpertSkipPolicy.environmentKey
        let chain = try ExpertSkipPolicy(environment: [key: "bias:0.05+miss:0.08"])
        #expect(chain == ExpertSkipPolicy(kind: .bias, value: 0.05,
                                          then: [ExpertSkipPolicy(kind: .miss, value: 0.08)]))
        #expect(chain?.description == "bias:0.05+miss:0.08")
        for bad in ["miss:0.08+bias:0.05", "misssub:0.08+early:0.3", "miss:0.08:nonorm+early:0.3",
                    "miss:0.08+"] {
            #expect(throws: ExpertSkipPolicyError.self) {
                try ExpertSkipPolicy(environment: [key: bad])
            }
        }
    }

    @Test func cumDropsForegroundMissesOnceTheRanksAboveCarryEnough() {
        let z = Self.logits()
        let p = Self.softmax(Array(z[0..<8]))
        // Ranks 1–5 carry 0.869 ≥ 0.85, ranks 1–4 only 0.757: experts 5, 6
        // and 7 qualify, and 7 is resident.
        #expect(p[0..<5].reduce(0, +) >= 0.85 && p[0..<4].reduce(0, +) < 0.85)
        let policy = ExpertSkipPolicy(kind: .cum, value: 0.85)
        let d = policy.decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                              resident: [7, 12, 13], residentByUse: [13, 12, 7],
                              pendingEarly: [])
        #expect(d.experts == [0, 1, 2, 3, 4, 13, 12, 7])
        #expect(d.dropped == 2)
        #expect(d.weights[5] == 0 && d.weights[6] == 0)
    }

    /// Expert 10 sits just below the top 8, at −1.0 against −0.5 for expert 6.
    private static func logitsWithEarlyCandidate() -> [Float] {
        var z = logits()
        z[8] = -2
        z[9] = -2
        z[10] = -1
        return z
    }

    @Test func earlySwapsTheLowestForegroundMissWithinTheBonus() {
        let z = Self.logitsWithEarlyCandidate()
        // Expert 7 is resident, so the lowest foreground miss is 6 (−0.5).
        // A bonus of 0.01 × 12 leaves 10 below it; 0.1 × 12 lifts it above.
        let near = ExpertSkipPolicy(kind: .early, value: 0.01)
            .decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                    resident: [7, 12], residentByUse: [12, 7], pendingEarly: [10],
                    averageLogitRange: 12)
        #expect(near.experts == Array(0..<8) && near.dropped == 0)
        let d = ExpertSkipPolicy(kind: .early, value: 0.1)
            .decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                    resident: [7, 12], residentByUse: [12, 7], pendingEarly: [10],
                    averageLogitRange: 12)
        #expect(d.experts == [0, 1, 2, 3, 4, 5, 10, 7])
        #expect(d.dropped == 1 && d.substituted == 1)
        let expected = Self.softmax(d.experts.map { z[$0] })
        for i in 0..<8 { #expect(abs(Double(d.weights[i]) - expected[i]) < 1e-3) }
    }

    @Test func missThenEarlySwapsAmongTheMissesLeft() {
        let z = Self.logitsWithEarlyCandidate()
        // miss:0.08 drops 6; the lowest miss left is 5 (1.0). 10 needs a
        // bonus above 2.0 to replace it: 0.1 × 12 is not enough, 0.3 × 12 is.
        func run(_ lambda: Double) -> ExpertSkipPolicy.Decision {
            ExpertSkipPolicy(kind: .miss, value: 0.08,
                             then: [ExpertSkipPolicy(kind: .early, value: lambda)])
                .decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                        resident: [7, 12], residentByUse: [12, 7], pendingEarly: [10],
                        averageLogitRange: 12)
        }
        let weak = run(0.1)
        #expect(weak.experts == [0, 1, 2, 3, 4, 5, 12, 7] && weak.dropped == 1)
        let strong = run(0.3)
        #expect(strong.experts == [0, 1, 2, 3, 4, 10, 12, 7])
        #expect(strong.dropped == 2 && strong.substituted == 1 && strong.weights[6] == 0)
        let kept = [0, 1, 2, 3, 4, 10, 7]
        let expected = Self.softmax(kept.map { z[$0] })
        for (j, i) in [0, 1, 2, 3, 4, 5, 7].enumerated() {
            #expect(abs(Double(strong.weights[i]) - expected[j]) < 1e-3)
        }
    }

    @Test func chainedMissMatchesTheSinglePath() {
        let z = Self.logits()
        let policy = ExpertSkipPolicy(kind: .miss, value: 0.08)
        let single = policy.decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                                   resident: [7, 12, 13], residentByUse: [13, 12, 7],
                                   pendingEarly: [])
        let chained = policy.chained(experts: Array(0..<8), logits: z,
                                     perExpertScale: Self.unitScale, resident: [7, 12, 13],
                                     residentByUse: [13, 12, 7], pendingEarly: [],
                                     averageLogitRange: 0)
        #expect(chained.experts == single.experts && chained.dropped == single.dropped)
        for i in 0..<8 { #expect(abs(chained.weights[i] - single.weights[i]) < 1e-6) }
    }

    @Test func biasThenMissDropsFromTheRerankedSet() {
        let z = Self.logits()
        // bias:0.25 swaps 6 and 7 for residents 8 and 9 (as above). In the new
        // set, 5 weighs about 0.086 and is the only foreground miss under 0.09.
        let policy = ExpertSkipPolicy(kind: .bias, value: 0.25,
                                      then: [ExpertSkipPolicy(kind: .miss, value: 0.09)])
        let d = policy.decide(experts: Array(0..<8), logits: z, perExpertScale: Self.unitScale,
                              resident: [8, 9, 1, 13], residentByUse: [13, 8, 9, 1],
                              pendingEarly: [], averageLogitRange: 12)
        #expect(d.experts == [0, 1, 2, 3, 4, 13, 8, 9])
        #expect(d.dropped == 3 && d.substituted == 2 && d.weights[5] == 0)
        let expected = Self.softmax([0, 1, 2, 3, 4, 8, 9].map { z[$0] })
        for (j, i) in [0, 1, 2, 3, 4, 6, 7].enumerated() {
            #expect(abs(Double(d.weights[i]) - expected[j]) < 1e-3)
        }
    }
}
