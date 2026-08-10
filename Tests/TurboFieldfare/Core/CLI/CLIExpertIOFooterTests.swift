import Testing
import Foundation

@testable import TurboFieldfare
@testable import TurboFieldfareCLICore

/// The CLI footer is where a benchmark run's byte profile is actually read off,
/// so its arithmetic is pinned here: per-forward for decode, totals for
/// prefill, and `n/a` rather than a fabricated zero when a window has no
/// forwards or no requests.
@Suite struct CLIExpertIOFooterTests {

    private func result(newTokens: Int,
                        prefill: ExpertIOStats = .zero,
                        decode: ExpertIOStats = .zero) -> RawDecodeResult {
        RawDecodeResult(prefillTokens: 61,
                        cachedPromptTokens: 0,
                        computedPrefillTokens: 61,
                        prefillSeconds: 1,
                        newTokens: newTokens,
                        decodeSeconds: 1,
                        reason: .maxTokens,
                        kvPosition: 61 + newTokens,
                        kvBackedTokenIDs: [],
                        uncommittedBoundaryTokenIDs: [],
                        prefillExpertIO: prefill,
                        decodeExpertIO: decode)
    }

    @Test func footerReportsDecodePerForwardAndPrefillTotals() {
        // 3 decode forwards: 300 MiB read, 240 requests of which 216 were hits.
        let footer = expertIOFooter(result(
            newTokens: 4,
            prefill: ExpertIOStats(bytesRead: 512 * 1_048_576,
                                   reads: 128,
                                   cacheHits: 64,
                                   cacheMisses: 128),
            decode: ExpertIOStats(bytesRead: 300 * 1_048_576,
                                  reads: 24,
                                  cacheHits: 216,
                                  cacheMisses: 24)))

        #expect(footer.contains("bytes/tok=100.00MB"))
        #expect(footer.contains("hit-rate=90.0%"))
        #expect(footer.contains("req/tok=80.00"))
        #expect(footer.contains("reads/tok=8.00"))
        #expect(footer.contains("forwards=3"))
        #expect(footer.contains("prefill bytes=512.00MB"))
        #expect(footer.contains("hit-rate=33.3%"))
        #expect(footer.contains("reads=128"))
        #expect(footer.hasSuffix("]\n"))
    }

    @Test func footerRefusesToDivideByZeroForwards() {
        // One generated token means zero forwards: there is no per-token
        // quantity to report, and 0.00 MB/tok would read as a measurement.
        let footer = expertIOFooter(result(
            newTokens: 1,
            decode: ExpertIOStats(bytesRead: 100 * 1_048_576, reads: 8)))

        #expect(footer.contains("bytes/tok=n/a"))
        #expect(footer.contains("req/tok=n/a"))
        #expect(footer.contains("reads/tok=n/a"))
        #expect(footer.contains("forwards=0"))
    }

    @Test func footerDistinguishesNoRequestsFromNoHits() {
        let noRequests = expertIOFooter(result(newTokens: 4))
        #expect(noRequests.contains("decode bytes/tok=0.00MB hit-rate=n/a"))

        let allMisses = expertIOFooter(result(
            newTokens: 4,
            decode: ExpertIOStats(bytesRead: 300 * 1_048_576,
                                  reads: 240,
                                  cacheHits: 0,
                                  cacheMisses: 240)))
        #expect(allMisses.contains("hit-rate=0.0%"))
    }
}
