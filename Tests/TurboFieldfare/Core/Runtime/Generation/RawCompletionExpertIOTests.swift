import Testing
import Foundation
import Metal
@testable import TurboFieldfare

/// The prefill/decode split of the routed-expert byte profile. The two phases
/// share one streamer and one counter set, so the loop has to bracket them —
/// reporting a single blended bytes/token would mix a tiled, amortized prefill
/// read pattern into the per-token decode number that the constraint is
/// stated in.
@Suite struct RawCompletionExpertIOTests {

    /// Charges a fixed, known amount of expert I/O to every forward pass, so a
    /// window's byte total is exactly `bytesPerForward × forwards`.
    final class ExpertIOProducer: LogitProducer, ExpertIOReporting, @unchecked Sendable {
        let vocabSize: Int
        let bytesPerForward: UInt64
        private let emitted: Int32
        private var stats = ExpertIOStats()
        private(set) var produceCalls = 0

        init(vocabSize: Int, emitted: Int32, bytesPerForward: UInt64) {
            self.vocabSize = vocabSize
            self.emitted = emitted
            self.bytesPerForward = bytesPerForward
        }

        var expertIOStats: ExpertIOStats { stats }

        func reset() {
            produceCalls = 0
            stats = .zero
        }

        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {
            produceCalls += 1
            stats.bytesRead &+= bytesPerForward
            stats.reads &+= 1
            stats.cacheHits &+= 3
            stats.cacheMisses &+= 1
            let ptr = logits.contents().bindMemory(to: Float16.self, capacity: vocabSize)
            for i in 0..<vocabSize { ptr[i] = Float16(-30.0) }
            ptr[Int(emitted)] = Float16(30.0)
        }
    }

    /// Same behaviour, no `ExpertIOReporting`: the loop must degrade to zeros
    /// rather than reporting numbers it did not observe.
    final class SilentProducer: LogitProducer, @unchecked Sendable {
        let vocabSize: Int
        private let emitted: Int32

        init(vocabSize: Int, emitted: Int32) {
            self.vocabSize = vocabSize
            self.emitted = emitted
        }

        func reset() {}

        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {
            let ptr = logits.contents().bindMemory(to: Float16.self, capacity: vocabSize)
            for i in 0..<vocabSize { ptr[i] = Float16(-30.0) }
            ptr[Int(emitted)] = Float16(30.0)
        }
    }

    @Test func prefillAndDecodeByteProfilesAreReportedSeparately() async throws {
        let ctx = try MetalContext()
        let tok = try await GFTokenizer.load()
        let bytesPerForward: UInt64 = 4_194_304
        let producer = ExpertIOProducer(vocabSize: tok.vocabSize,
                                        emitted: 100,
                                        bytesPerForward: bytesPerForward)
        let promptIds = tok.encode("count the bytes", addBOS: true)
        let scratch = try RawCompletionScratch(context: ctx, vocab: tok.vocabSize)

        let result = try await runRawCompletion(
            producer: producer,
            tokenizer: tok,
            promptIds: promptIds,
            config: GenerationConfig(maxNewTokens: 4, temperature: 0),
            context: ctx,
            scratch: scratch,
            prefillConfig: .off) { _ in }

        // Scalar-replay prefill runs one forward per prompt token; decode runs
        // one per generated token except the last, which is only sampled.
        #expect(result.decodeForwards == result.newTokens - 1)
        #expect(result.prefillExpertIO.bytesRead
            == bytesPerForward * UInt64(promptIds.count))
        #expect(result.decodeExpertIO.bytesRead
            == bytesPerForward * UInt64(result.decodeForwards))
        #expect(producer.produceCalls == promptIds.count + result.decodeForwards)

        #expect(result.decodeExpertIO.cacheRequests == UInt64(4 * result.decodeForwards))
        #expect(result.decodeExpertIO.cacheHitRate == 0.75)
        #expect(result.decodeMegabytesPerToken == Double(bytesPerForward) / 1_048_576.0)
    }

    @Test func producerWithoutExpertIOReportsZero() async throws {
        let ctx = try MetalContext()
        let tok = try await GFTokenizer.load()
        let producer = SilentProducer(vocabSize: tok.vocabSize, emitted: 100)
        let promptIds = tok.encode("count the bytes", addBOS: true)
        let scratch = try RawCompletionScratch(context: ctx, vocab: tok.vocabSize)

        let result = try await runRawCompletion(
            producer: producer,
            tokenizer: tok,
            promptIds: promptIds,
            config: GenerationConfig(maxNewTokens: 4, temperature: 0),
            context: ctx,
            scratch: scratch,
            prefillConfig: .off) { _ in }

        #expect(result.prefillExpertIO == .zero)
        #expect(result.decodeExpertIO == .zero)
        // Zero bytes over a real window is a measurement; `nil` hit rate says
        // nothing was requested. The two must not be conflated.
        #expect(result.decodeExpertIO.cacheHitRate == nil)
        #expect(result.decodeMegabytesPerToken == 0)
    }
}
