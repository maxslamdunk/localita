import Metal
import Testing

@testable import TurboFieldfare

/// A prefill the GPU refused part way, which the producer kept, carries on
/// without the reset that would discard it.
extension RawCompletionLoopTests {
    /// Refuses its first prefill after `refuseAfter` of the prompt's tokens,
    /// keeping them, as a layer-at-a-time prefill keeps its finished layers.
    final class SuspendingProducer: SuspendedPrefillResuming, @unchecked Sendable {
        let vocabSize: Int
        private let terminalToken: Int32
        private var refuseAfter: Int?
        private var kept: (tokens: [Int32], done: Int)?
        private(set) var resetCalls = 0
        private(set) var prefillDone: [Int] = []

        init(vocabSize: Int, terminalToken: Int32, refuseAfter: Int?) {
            self.vocabSize = vocabSize
            self.terminalToken = terminalToken
            self.refuseAfter = refuseAfter
        }

        var hasSuspendedPrefill: Bool { kept != nil }

        func reset() {
            resetCalls += 1
            kept = nil
        }

        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {
            writeTerminal(to: logits)
        }

        func prefillChunked(tokens: ArraySlice<Int32>,
                            startPosition: Int,
                            outputMode: PrefillOutputMode,
                            config: PrefillRuntimeConfig,
                            into logits: MTLBuffer,
                            onProgress: (Int) -> Void) async throws -> PrefillResult {
            let resumed = kept
            kept = nil
            if let resumed {
                guard resumed.tokens.elementsEqual(tokens), startPosition == 0 else {
                    throw PrefillError.prefillCursorMismatch("not the kept prompt")
                }
            }
            let from = resumed?.done ?? 0
            if let refuseAfter {
                self.refuseAfter = nil
                kept = (Array(tokens), refuseAfter)
                prefillDone.append(refuseAfter - from)
                onProgress(refuseAfter)
                throw GPUWorkNotPermitted(detail: "test refusal")
            }
            prefillDone.append(tokens.count - from)
            onProgress(tokens.count)
            writeTerminal(to: logits)
            return PrefillResult(newPosition: startPosition + tokens.count, seed: .logitsWritten)
        }

        private func writeTerminal(to logits: MTLBuffer) {
            let pointer = logits.contents().bindMemory(to: Float16.self, capacity: vocabSize)
            for index in 0..<vocabSize { pointer[index] = -30 }
            pointer[Int(terminalToken)] = 30
        }
    }

    @Test func aSuspendedPrefillCarriesOnWithoutAReset() async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load()
        let prompt = tokenizer.encode("one two three four five", addBOS: true)
        let producer = SuspendingProducer(vocabSize: tokenizer.vocabSize,
                                          terminalToken: tokenizer.eosID,
                                          refuseAfter: 2)
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)
        func run(_ start: RawCompletionStart) async throws -> RawDecodeResult {
            try await runRawCompletion(
                producer: producer, tokenizer: tokenizer, promptIds: prompt,
                config: GenerationConfig(maxNewTokens: 1, temperature: 0),
                context: context, scratch: scratch,
                prefillConfig: .defaultChunked, start: start) { _ in }
        }

        await #expect(throws: GPUWorkNotPermitted.self) { _ = try await run(.reset) }
        #expect(producer.hasSuspendedPrefill)
        let resets = producer.resetCalls

        let result = try await run(.resumeSuspendedPrefill)
        #expect(producer.resetCalls == resets)
        #expect(producer.prefillDone == [2, prompt.count - 2])
        #expect(result.cachedPromptTokens == 0)
        #expect(result.computedPrefillTokens == prompt.count)
        #expect(result.kvPosition == prompt.count)
        #expect(result.kvBackedTokenIDs == prompt)
    }

    @Test func resumingWithNothingSuspendedThrowsBeforeTouchingTheProducer() async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load()
        let prompt = tokenizer.encode("one two", addBOS: true)
        let producer = SuspendingProducer(vocabSize: tokenizer.vocabSize,
                                          terminalToken: tokenizer.eosID,
                                          refuseAfter: nil)
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)

        await #expect(throws: GeneratorError.self) {
            _ = try await runRawCompletion(
                producer: producer, tokenizer: tokenizer, promptIds: prompt,
                config: GenerationConfig(maxNewTokens: 1, temperature: 0),
                context: context, scratch: scratch,
                prefillConfig: .defaultChunked, start: .resumeSuspendedPrefill) { _ in }
        }
        #expect(producer.resetCalls == 0)
        #expect(producer.prefillDone.isEmpty)
    }
}
