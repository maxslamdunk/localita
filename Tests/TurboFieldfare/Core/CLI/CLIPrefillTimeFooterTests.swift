import Testing
import Foundation

@testable import TurboFieldfare
@testable import TurboFieldfareCLICore

/// The prefill-time footer reports whole-prefill seconds, folds the profiled
/// attention pieces into one `attn-block` GPU figure, and derives `both-idle`.
@Suite struct CLIPrefillTimeFooterTests {

    @Test func footerReportsSecondsAndDerivedFigures() {
        var p = PrefillPhaseTimings()
        p.chunks = 3
        p.profiledChunks = 3
        p.wallNanos = 68_000_000_000
        p.fetchNanos = 20_000_000_000
        p.gpuQKVProjectionNanos = 1_000_000_000
        p.gpuAttentionNanos = 2_000_000_000
        p.gpuRouterNanos = 500_000_000
        p.gpuBusyNanos = 40_000_000_000
        p.storageBusyNanos = 20_000_000_000
        p.storageGPUOverlapNanos = 5_000_000_000
        let stats = RawDecodeResult(prefillTokens: 3015,
                                    cachedPromptTokens: 0,
                                    computedPrefillTokens: 3015,
                                    prefillSeconds: 68,
                                    newTokens: 1,
                                    decodeSeconds: 0,
                                    reason: .maxTokens,
                                    kvPosition: 3016,
                                    kvBackedTokenIDs: [],
                                    uncommittedBoundaryTokenIDs: [],
                                    prefillPhaseTimings: p)
        let footer = prefillTimeFooter(stats)
        #expect(footer.hasPrefix("[prefill-time s chunks=3 profiled=3 wall=68.00"))
        #expect(footer.contains(" fetch=20.00"))
        #expect(footer.contains("| gpu embed=0.00 attn-block=3.50 qkv-proj=1.00"))
        #expect(footer.contains("| storage busy=20.00 overlap-gpu=5.00 both-idle=13.00"))
        #expect(footer.hasSuffix("]\n"))
    }
}
