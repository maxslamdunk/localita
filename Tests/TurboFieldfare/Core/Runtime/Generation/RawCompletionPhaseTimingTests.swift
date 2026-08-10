import Testing
import Foundation
import Metal
@testable import TurboFieldfare

/// The decode window of the phase breakdown. Production prefill is chunked and
/// never touches these counters, but the scalar-replay prefill path drives the
/// same `produce` call decode does — so the loop has to difference a snapshot
/// rather than read a total at the end, or a long prompt's phase time would be
/// charged to the decode figure and make `io` look enormous.
@Suite struct RawCompletionPhaseTimingTests {

    /// Charges a fixed, known amount to each phase on every forward pass.
    final class PhaseTimingProducer: LogitProducer, DecodePhaseTimingReporting, @unchecked Sendable {
        let vocabSize: Int
        let nanosPerForward: UInt64
        private let emitted: Int32
        private var timings = DecodePhaseTimings()

        init(vocabSize: Int, emitted: Int32, nanosPerForward: UInt64) {
            self.vocabSize = vocabSize
            self.emitted = emitted
            self.nanosPerForward = nanosPerForward
        }

        var decodePhaseTimings: DecodePhaseTimings { timings }

        func reset() { timings = .zero }

        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {
            timings.cb1Nanos &+= nanosPerForward
            timings.cb1WaitNanos &+= nanosPerForward * 2
            timings.ioNanos &+= nanosPerForward * 3
            timings.cb2Nanos &+= nanosPerForward * 4
            timings.routedDrainNanos &+= nanosPerForward * 5
            timings.headNanos &+= nanosPerForward * 6
            let ptr = logits.contents().bindMemory(to: Float16.self, capacity: vocabSize)
            for i in 0..<vocabSize { ptr[i] = Float16(-30.0) }
            ptr[Int(emitted)] = Float16(30.0)
        }
    }

    /// Same behaviour, no `DecodePhaseTimingReporting`.
    final class UntimedProducer: LogitProducer, @unchecked Sendable {
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

    @Test func phaseTimingsCoverDecodeOnly() async throws {
        let ctx = try MetalContext()
        let tok = try await GFTokenizer.load()
        let nanosPerForward: UInt64 = 1_000_000
        let producer = PhaseTimingProducer(vocabSize: tok.vocabSize,
                                           emitted: 100,
                                           nanosPerForward: nanosPerForward)
        let promptIds = tok.encode("where does the time go", addBOS: true)
        let scratch = try RawCompletionScratch(context: ctx, vocab: tok.vocabSize)

        let result = try await runRawCompletion(
            producer: producer,
            tokenizer: tok,
            promptIds: promptIds,
            config: GenerationConfig(maxNewTokens: 4, temperature: 0),
            context: ctx,
            scratch: scratch,
            prefillConfig: .off) { _ in }

        // Scalar replay charges every prompt token too; only the decode
        // forwards may appear here.
        #expect(promptIds.count > 0)
        let forwards = UInt64(result.decodeForwards)
        #expect(result.decodePhaseTimings.cb1Nanos == nanosPerForward * forwards)
        #expect(result.decodePhaseTimings.cb1WaitNanos == nanosPerForward * 2 * forwards)
        #expect(result.decodePhaseTimings.ioNanos == nanosPerForward * 3 * forwards)
        #expect(result.decodePhaseTimings.cb2Nanos == nanosPerForward * 4 * forwards)
        #expect(result.decodePhaseTimings.routedDrainNanos == nanosPerForward * 5 * forwards)
        #expect(result.decodePhaseTimings.headNanos == nanosPerForward * 6 * forwards)
    }

    @Test func producerWithoutPhaseTimingReportsZero() async throws {
        let ctx = try MetalContext()
        let tok = try await GFTokenizer.load()
        let producer = UntimedProducer(vocabSize: tok.vocabSize, emitted: 100)
        let promptIds = tok.encode("where does the time go", addBOS: true)
        let scratch = try RawCompletionScratch(context: ctx, vocab: tok.vocabSize)

        let result = try await runRawCompletion(
            producer: producer,
            tokenizer: tok,
            promptIds: promptIds,
            config: GenerationConfig(maxNewTokens: 4, temperature: 0),
            context: ctx,
            scratch: scratch,
            prefillConfig: .off) { _ in }

        #expect(result.decodePhaseTimings == .zero)
    }

    @Test func millisecondsPerForwardRefusesZeroForwards() {
        #expect(DecodePhaseTimings.millisecondsPerForward(80_000_000, forwards: 4) == 20.0)
        #expect(DecodePhaseTimings.millisecondsPerForward(80_000_000, forwards: 0) == nil)
    }
}
