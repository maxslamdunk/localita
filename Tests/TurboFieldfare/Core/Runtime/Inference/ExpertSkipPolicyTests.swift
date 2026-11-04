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
}
