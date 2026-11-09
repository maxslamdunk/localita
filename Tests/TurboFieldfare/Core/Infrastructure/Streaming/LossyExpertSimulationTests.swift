import Foundation
import Testing
import TurboFieldfareValidationSupport

@testable import TurboFieldfare

@Suite struct LossyExpertSimulationTests {
    private typealias Sim = LossyExpertSimulation

    /// 64 INT4 codes packed two per byte, low nibble first.
    private static func pack(_ codes: [Int]) -> [UInt8] {
        stride(from: 0, to: 64, by: 2).map { UInt8(codes[$0] | (codes[$0 + 1] << 4)) }
    }

    private static func unpack(_ bytes: [UInt8]) -> [Int] {
        bytes.flatMap { [Int($0 & 0x0F), Int($0 >> 4)] }
    }

    private static func values(_ codes: [Int], scale: UInt16, bias: UInt16) -> [Float] {
        codes.map { Float($0) * Sim.bf16ToFloat(scale) + Sim.bf16ToFloat(bias) }
    }

    private static func requantized(_ codes: [Int], scale: Float, bias: Float, levels: Int)
        -> (codes: [Int], original: [Float], result: [Float]) {
        var bytes = pack(codes)
        var s = Sim.floatToBF16(scale)
        var b = Sim.floatToBF16(bias)
        let original = values(codes, scale: s, bias: b)
        bytes.withUnsafeMutableBufferPointer {
            Sim.requantize($0.baseAddress!, scale: &s, bias: &b, levels: levels)
        }
        let newCodes = unpack(bytes)
        return (newCodes, original, values(newCodes, scale: s, bias: b))
    }

    @Test func unsetEnvironmentMeansNoSimulation() throws {
        #expect(try Sim(environment: [:], tensors: []) == nil)
        #expect(throws: LossyExpertSimulationError.self) {
            try Sim(environment: [Sim.environmentKey: "all=5"], tensors: [])
        }
    }

    @Test func aGroupThatFitsInEightLevelsSurvivesThreeBits() {
        let codes = (0..<64).map { 4 + $0 % 8 }
        let r = Self.requantized(codes, scale: 0.01, bias: -0.08, levels: 8)
        #expect(r.codes.allSatisfy { $0 < 8 })
        for (a, b) in zip(r.original, r.result) {
            // Only the new bias is rounded to BF16: well under a step.
            #expect(abs(a - b) < 0.002)
        }
    }

    @Test func searchBeatsPlainMinMaxAtThreeBits() {
        var rng = SplitMix64(seed: 7)
        var searched = 0.0
        var minMax = 0.0
        for _ in 0..<200 {
            // Bell-shaped codes around 8, as installed groups are.
            let codes = (0..<64).map { _ in
                min(15, max(0, 8 + Int(rng.next() % 5) + Int(rng.next() % 5) - 4))
            }
            let r = Self.requantized(codes, scale: 0.02, bias: -0.16, levels: 8)
            for (a, b) in zip(r.original, r.result) {
                let e: Float = a - b
                searched += Double(e * e)
            }
            let lo = Float(codes.min()!), hi = Float(codes.max()!)
            let alpha = max(1, (hi - lo) / 7)
            for q in codes {
                let c = min(7, max(0, ((Float(q) - lo) / alpha).rounded()))
                let d = Double((Float(q) - (c * alpha + lo)) * 0.02)
                minMax += d * d
            }
        }
        #expect(searched <= minMax * 1.01)
    }

    @Test func twoBitCodesStayInRange() {
        let codes = (0..<64).map { $0 % 16 }
        let r = Self.requantized(codes, scale: 0.01, bias: -0.08, levels: 4)
        #expect(r.codes.allSatisfy { $0 < 4 })
    }

    @Test func expertsListLimitsTheRewrite() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lossy-experts-\(UUID().uuidString).txt")
        try "3 5\n".write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        let tensor = Sim.Tensor(codesOffset: 0, scalesOffset: 32, biasesOffset: 34, rows: 1, cols: 64)
        let sim = try #require(try Sim(
            environment: [Sim.environmentKey: "all=2,experts=\(path.path)"], tensors: [tensor]))
        var buffer = Self.pack((0..<64).map { $0 % 16 })
            + [0x24, 0x3C, 0x00, 0x00] as [UInt8]  // scale ≈ 0.01, bias 0: BF16, little-endian
        let before = buffer
        buffer.withUnsafeMutableBytes { sim.apply(to: $0.baseAddress!, layer: 3, expert: 4) }
        #expect(buffer == before)
        buffer.withUnsafeMutableBytes { sim.apply(to: $0.baseAddress!, layer: 3, expert: 5) }
        #expect(Self.unpack(Array(buffer[0..<32])).allSatisfy { $0 < 4 })
    }
}
