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

    /// Gemma 4: D 2816, top-8. 67,632 bytes a token; the doc comments and
    /// `docs/RUNTIME_CONTROLS.md` quote these sizes.
    @Test func promptWideBytesPerToken() {
        #expect(PrefillLayerMajorBuffers.bytes(tokenCount: 1, hiddenSize: 2816, topK: 8) == 67_632)
        #expect(PrefillLayerMajorBuffers.bytes(tokenCount: 3015, hiddenSize: 2816, topK: 8)
            == 203_910_480)
        #expect(PrefillLayerMajorBuffers.bytes(tokenCount: PrefillLayerMajorPolicy.maxTokens,
                                               hiddenSize: 2816, topK: 8) == 277_020_672)
    }

    @Test func buffersMatchTheirByteCount() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let buffers = try PrefillLayerMajorBuffers(device: device, tokenCount: 3, hiddenSize: 16, topK: 2)
        let total = (buffers.hidden + [buffers.h1, buffers.routedX, buffers.routePartials,
                                       buffers.routeIDs, buffers.routeWeights]).map(\.length).reduce(0, +)
        #expect(total == PrefillLayerMajorBuffers.bytes(tokenCount: 3, hiddenSize: 16, topK: 2))
    }

    /// A layer never writes the rows it reads, so a refused layer can run
    /// again from its own input.
    @Test func eachLayerReadsTheRowsTheLayerBeforeWrote() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let buffers = try PrefillLayerMajorBuffers(device: device, tokenCount: 3, hiddenSize: 16, topK: 2)
        for layer in 1..<30 {
            #expect(buffers.input(ofLayer: layer) === buffers.output(ofLayer: layer - 1))
            #expect(buffers.input(ofLayer: layer) !== buffers.output(ofLayer: layer))
        }
    }

    @Test func aSuspensionResumesOnlyItsOwnPrompt() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let spans = PrefillChunkPlanner.spans(tokenCount: 6, startPosition: 0, chunkTokens: 4)
        let suspension = PrefillLayerMajorSuspension(
            tokens: [1, 2, 3, 4, 5, 6], startPosition: 0, spans: spans,
            buffers: try PrefillLayerMajorBuffers(device: device, tokenCount: 6, hiddenSize: 16, topK: 2),
            completedLayers: 7)
        #expect(suspension.resumes(tokens: [1, 2, 3, 4, 5, 6], startPosition: 0, spans: spans))
        #expect(!suspension.resumes(tokens: [1, 2, 3, 4, 5, 7], startPosition: 0, spans: spans))
        #expect(!suspension.resumes(tokens: [1, 2, 3, 4, 5, 6], startPosition: 0,
                                    spans: Array(spans.dropLast())))
    }
}
