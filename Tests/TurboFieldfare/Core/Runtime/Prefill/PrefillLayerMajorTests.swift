import Metal
import Testing
@testable import TurboFieldfare

/// Which prompts run one layer at a time across their chunks, and what the
/// prompt-wide rows cost. The output itself is checked on the real model,
/// which no package test loads.
@Suite struct PrefillLayerMajorTests {
    @Test func aMultiChunkPromptFromAnEmptyKVRunsLayerMajor() {
        #expect(PrefillLayerMajorPolicy.applies(enabled: true, spanCount: 3, startPosition: 0,
                                                tokenCount: 3015))
        #expect(PrefillLayerMajorPolicy.applies(enabled: true, spanCount: 4, startPosition: 0,
                                                tokenCount: PrefillLayerMajorPolicy.maxTokens))
    }

    /// One chunk reads each expert once either way.
    @Test func aSingleChunkKeepsTheChunkPath() {
        #expect(!PrefillLayerMajorPolicy.applies(enabled: true, spanCount: 1, startPosition: 0,
                                                 tokenCount: 430))
    }

    /// Past position 0 a failed turn rewinds, and the rings it wrapped while
    /// nothing had committed would no longer hold the prefix it rewinds to.
    @Test func aPromptAfterCachedTokensKeepsTheChunkPath() {
        #expect(!PrefillLayerMajorPolicy.applies(enabled: true, spanCount: 3, startPosition: 1,
                                                 tokenCount: 3015))
    }

    @Test func thePromptWideRowsAreCapped() {
        #expect(!PrefillLayerMajorPolicy.applies(enabled: true, spanCount: 5, startPosition: 0,
                                                 tokenCount: PrefillLayerMajorPolicy.maxTokens + 1))
    }

    @Test func theControlTurnsItOff() {
        #expect(!PrefillLayerMajorPolicy.applies(enabled: false, spanCount: 3, startPosition: 0,
                                                 tokenCount: 3015))
    }

    /// Gemma 4: D 2816, top-8. 62,000 bytes a token; the doc comments and
    /// `docs/RUNTIME_CONTROLS.md` quote these sizes.
    @Test func promptWideBytesPerToken() {
        #expect(PrefillLayerMajorBuffers.bytes(tokenCount: 1, hiddenSize: 2816, topK: 8) == 62_000)
        #expect(PrefillLayerMajorBuffers.bytes(tokenCount: 3015, hiddenSize: 2816, topK: 8)
            == 186_930_000)
        #expect(PrefillLayerMajorBuffers.bytes(tokenCount: PrefillLayerMajorPolicy.maxTokens,
                                               hiddenSize: 2816, topK: 8) == 253_952_000)
    }

    @Test func buffersMatchTheirByteCount() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let buffers = try PrefillLayerMajorBuffers(device: device, tokenCount: 3, hiddenSize: 16, topK: 2)
        let total = [buffers.hidden, buffers.h1, buffers.routedX, buffers.routePartials,
                     buffers.routeIDs, buffers.routeWeights].map(\.length).reduce(0, +)
        #expect(total == PrefillLayerMajorBuffers.bytes(tokenCount: 3, hiddenSize: 16, topK: 2))
    }
}
