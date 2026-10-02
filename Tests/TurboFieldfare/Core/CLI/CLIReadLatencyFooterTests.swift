import Testing
import Foundation

@testable import TurboFieldfare
@testable import TurboFieldfareCLICore

/// The read-latency footer is how a file-cache-served miss becomes visible, so
/// its bucket labels and shares are pinned: every bucket printed, shares of the
/// window's own reads, decode and prefill kept apart, and `n/a` for a window
/// with no reads rather than a row of zeros.
@Suite struct CLIReadLatencyFooterTests {

    private func result(prefill: ExpertIOStats = .zero,
                        decode: ExpertIOStats = .zero) -> RawDecodeResult {
        RawDecodeResult(prefillTokens: 61,
                        cachedPromptTokens: 0,
                        computedPrefillTokens: 61,
                        prefillSeconds: 1,
                        newTokens: 4,
                        decodeSeconds: 1,
                        reason: .maxTokens,
                        kvPosition: 65,
                        kvBackedTokenIDs: [],
                        uncommittedBoundaryTokenIDs: [],
                        prefillExpertIO: prefill,
                        decodeExpertIO: decode)
    }

    @Test func footerReportsEveryBucketAsAShareOfReads() {
        // 8 decode reads: 2 under 0.25 ms, 1 at 1–2 ms, 4 at 2–4 ms, 1 over 16.
        let footer = readLatencyFooter(result(
            decode: ExpertIOStats(reads: 8,
                                  readLatencyNanos: 24_000_000,
                                  readLatencyBuckets: [2, 0, 0, 1, 4, 0, 0, 1])))

        #expect(footer.contains("decode reads=8 mean=3.00ms"))
        #expect(footer.contains("<0.25ms=25.0%"))
        #expect(footer.contains("0.25-0.5ms=0.0%"))
        #expect(footer.contains("0.5-1ms=0.0%"))
        #expect(footer.contains("1-2ms=12.5%"))
        #expect(footer.contains("2-4ms=50.0%"))
        #expect(footer.contains("4-8ms=0.0%"))
        #expect(footer.contains("8-16ms=0.0%"))
        #expect(footer.contains(">=16ms=12.5%"))
        #expect(footer.hasSuffix("]\n"))
    }

    @Test func prefillIsReportedSeparately() {
        let footer = readLatencyFooter(result(
            prefill: ExpertIOStats(reads: 2,
                                   readLatencyNanos: 1_000_000,
                                   readLatencyBuckets: [0, 2, 0, 0, 0, 0, 0, 0]),
            decode: ExpertIOStats(reads: 1,
                                  readLatencyNanos: 3_000_000,
                                  readLatencyBuckets: [0, 0, 0, 0, 1, 0, 0, 0])))

        let halves = footer.components(separatedBy: " | ")
        #expect(halves.count == 2)
        #expect(halves[0].contains("decode reads=1 mean=3.00ms"))
        #expect(halves[0].contains("2-4ms=100.0%"))
        #expect(halves[1].contains("prefill reads=2 mean=0.50ms"))
        #expect(halves[1].contains("0.25-0.5ms=100.0%"))
    }

    @Test func emptyWindowSaysNotApplicable() {
        let footer = readLatencyFooter(result())
        #expect(footer.contains("decode reads=0 mean=n/a <0.25ms=n/a"))
        #expect(footer.contains(">=16ms=n/a"))
    }
}
