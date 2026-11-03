import Foundation
import Testing
@testable import TurboFieldfareAppCore

@Suite(.serialized) struct ComposerQuoteTests {
    @MainActor
    @Test func aSelectionBecomesAQuoteWithRoomForTheQuestion() async throws {
        let harness = try await HistoryHarness(label: "quote")
        defer { harness.tearDown() }

        harness.model.quoteInComposer("  violet scatters most\n")

        #expect(harness.model.promptText == "> violet scatters most\n\n")
        #expect(harness.model.composerFocusRequests == 1)
    }

    @MainActor
    @Test func everyLineIsQuotedAndABlankOneStaysInTheQuote() async throws {
        let harness = try await HistoryHarness(label: "quote-lines")
        defer { harness.tearDown() }

        harness.model.quoteInComposer("first\n\nsecond")

        #expect(harness.model.promptText == "> first\n>\n> second\n\n")
    }

    @MainActor
    @Test func wordsAlreadyInTheBoxStayAboveTheQuote() async throws {
        let harness = try await HistoryHarness(label: "quote-draft")
        defer { harness.tearDown() }

        harness.model.promptText = "Compare these.\n"
        harness.model.quoteInComposer("one")
        harness.model.quoteInComposer("two")

        #expect(harness.model.promptText == "Compare these.\n\n> one\n\n> two\n\n")
        #expect(harness.model.composerFocusRequests == 2)
    }

    @MainActor
    @Test func aBlankSelectionChangesNothing() async throws {
        let harness = try await HistoryHarness(label: "quote-blank")
        defer { harness.tearDown() }

        harness.model.promptText = "kept"
        harness.model.quoteInComposer(" \n ")

        #expect(harness.model.promptText == "kept")
        #expect(harness.model.composerFocusRequests == 0)
    }
}
