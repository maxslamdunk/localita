import Testing
import Foundation

@testable import TurboFieldfare
@testable import TurboFieldfareCLICore

/// The gpu-time footer splits `cb1-wait` into the work it actually waited on.
/// Pinned here: every part is per forward with the same divisor as `wall`,
/// `idle` is `wall − busy`, and the line says the parts are not to be summed.
@Suite struct CLIGPUTimeFooterTests {

    private func result(newTokens: Int,
                        decodeSeconds: Double = 0.9,
                        phases: DecodePhaseTimings = .zero) -> RawDecodeResult {
        RawDecodeResult(prefillTokens: 61,
                        cachedPromptTokens: 0,
                        computedPrefillTokens: 61,
                        prefillSeconds: 1,
                        newTokens: newTokens,
                        decodeSeconds: decodeSeconds,
                        reason: .maxTokens,
                        kvPosition: 61 + newTokens,
                        kvBackedTokenIDs: [],
                        uncommittedBoundaryTokenIDs: [],
                        decodePhaseTimings: phases)
    }

    @Test func footerReportsEveryPartPerForward() {
        // 4 tokens is 3 forwards, and 0.9s over 3 forwards is 300ms each.
        let footer = gpuTimeFooter(result(
            newTokens: 4,
            phases: DecodePhaseTimings(gpuEmbedNanos: 3 * 100_000,
                                       gpuCb1Nanos: 3 * 50_000_000,
                                       gpuSharedNanos: 3 * 10_000_000,
                                       gpuHitExpertsNanos: 3 * 5_000_000,
                                       gpuRoutedNanos: 3 * 30_000_000,
                                       gpuHeadNanos: 3 * 9_000_000,
                                       gpuBusyNanos: 3 * 104_100_000)))

        #expect(footer.contains("embed=0.10"))
        #expect(footer.contains("cb1=50.00"))
        #expect(footer.contains("shared=10.00"))
        #expect(footer.contains("hit-experts=5.00"))
        #expect(footer.contains("routed=30.00"))
        #expect(footer.contains("head=9.00"))
        #expect(footer.contains("busy=104.10"))
        #expect(footer.contains("idle=195.90"))
        #expect(footer.contains("wall=300.00"))
        #expect(footer.contains("forwards=3"))
        #expect(footer.hasPrefix("[gpu-time decode ms/fwd "))
        #expect(footer.hasSuffix("]\n"))
    }

    @Test func footerRefusesToDivideByZeroForwards() {
        let footer = gpuTimeFooter(result(
            newTokens: 1,
            phases: DecodePhaseTimings(gpuBusyNanos: 80_000_000)))

        #expect(footer.contains("busy=n/a"))
        #expect(footer.contains("idle=n/a"))
        #expect(footer.contains("wall=n/a"))
        #expect(footer.contains("forwards=0"))
    }

    @Test func footerSaysThePartsOverlap() {
        let footer = gpuTimeFooter(result(newTokens: 4))
        #expect(footer.contains("parts may overlap, busy is their union"))
    }
}
