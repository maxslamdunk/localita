import Testing
import Foundation

@testable import TurboFieldfare
@testable import TurboFieldfareCLICore

/// The phase-time footer exists to answer one question — what fraction of a
/// decode forward is expert I/O — so what is pinned here is that each column is
/// per forward, that the wall figure it is read against uses the same divisor,
/// and that the footer never invites the reader to sum the columns.
@Suite struct CLIPhaseTimeFooterTests {

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

    @Test func footerReportsEveryPhasePerForward() {
        // 4 tokens is 3 forwards, and 0.9s over 3 forwards is 300ms each.
        let footer = phaseTimeFooter(result(
            newTokens: 4,
            phases: DecodePhaseTimings(cb1Nanos: 3 * 1_000_000,
                                       cb1WaitNanos: 3 * 200_000_000,
                                       ioNanos: 3 * 80_000_000,
                                       cb2Nanos: 3 * 2_000_000,
                                       routedDrainNanos: 3 * 15_000_000,
                                       headNanos: 3 * 4_000_000)))

        #expect(footer.contains("cb1=1.00"))
        #expect(footer.contains("cb1-wait=200.00"))
        #expect(footer.contains("io=80.00"))
        #expect(footer.contains("cb2=2.00"))
        #expect(footer.contains("routed-drain=15.00"))
        #expect(footer.contains("head=4.00"))
        #expect(footer.contains("forwards=3"))
        #expect(footer.hasSuffix("]\n"))
    }

    @Test func wallUsesTheSameDivisorAsThePhases() {
        // A phase read against a wall figure divided by a different count is
        // not a fraction of anything. Both must be per forward, not per token.
        let footer = phaseTimeFooter(result(newTokens: 4, decodeSeconds: 0.9))
        #expect(footer.contains("wall=300.00"))
    }

    @Test func footerRefusesToDivideByZeroForwards() {
        let footer = phaseTimeFooter(result(
            newTokens: 1,
            phases: DecodePhaseTimings(ioNanos: 80_000_000)))

        #expect(footer.contains("io=n/a"))
        #expect(footer.contains("cb1-wait=n/a"))
        #expect(footer.contains("wall=n/a"))
        #expect(footer.contains("forwards=0"))
    }

    @Test func footerCarriesTheDoNotSumMarker() {
        // The columns do not partition wall: cb1/cb2 exclude GPU execution,
        // the waits are that execution, and io overlaps the shared branch. A
        // reader who adds them gets a number describing nothing, so the line
        // says so on its face rather than in a document they may not have read.
        let footer = phaseTimeFooter(result(newTokens: 4))
        #expect(footer.contains("phases overlap, do not sum"))
    }
}
