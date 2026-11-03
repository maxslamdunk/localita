import Foundation
import Testing
@testable import TurboFieldfareAppCore

/// A draft has to survive iOS ending the suspended app, which it does without
/// warning. A tester lost one that way: the app came back as an empty new chat.
@Suite(.serialized) struct ComposerDraftTests {
    @MainActor
    @Test func aReplyComesBackInTheChatItWasWrittenIn() async throws {
        let harness = try await HistoryHarness(label: "draft-reply")
        defer { harness.tearDown() }

        try await harness.apply(.send(label: 1))
        let id = try #require(harness.model.storedConversationID)
        harness.model.promptText = "half a thought"
        let draft = try #require(harness.model.composerDraft)
        #expect(draft == ComposerDraft(text: "half a thought", conversationID: id))
        harness.model.promptText = ""

        try await harness.apply(.relaunch)
        await harness.model.restoreComposerDraft(draft)

        #expect(harness.model.promptText == "half a thought")
        #expect(harness.model.screen.conversationID == id)
    }

    @MainActor
    @Test func aDraftInANewChatStaysInANewChat() async throws {
        let harness = try await HistoryHarness(label: "draft-new")
        defer { harness.tearDown() }

        try await harness.apply(.send(label: 1))
        try await harness.apply(.newChat)
        harness.model.promptText = "a new question"
        let draft = try #require(harness.model.composerDraft)
        #expect(draft.conversationID == nil)
        harness.model.promptText = ""

        try await harness.apply(.relaunch)
        await harness.model.restoreComposerDraft(draft)

        #expect(harness.model.promptText == "a new question")
        #expect(harness.model.screen.conversationID == nil)
    }

    @MainActor
    @Test func aDraftOutlivesTheChatItBelongedTo() async throws {
        let harness = try await HistoryHarness(label: "draft-deleted")
        defer { harness.tearDown() }

        try await harness.apply(.send(label: 1))
        try await harness.apply(.relaunch)
        await harness.model.restoreComposerDraft(
            ComposerDraft(text: "still mine", conversationID: UUID()))

        #expect(harness.model.promptText == "still mine")
        #expect(harness.model.screen.conversationID == nil)
    }

    @MainActor
    @Test func wordsAlreadyInTheBoxAreNotReplaced() async throws {
        let harness = try await HistoryHarness(label: "draft-typed")
        defer { harness.tearDown() }

        try await harness.apply(.send(label: 1))
        let id = try #require(harness.model.storedConversationID)
        try await harness.apply(.relaunch)
        harness.model.promptText = "typed first"
        await harness.model.restoreComposerDraft(
            ComposerDraft(text: "older", conversationID: id))

        #expect(harness.model.promptText == "typed first")
        #expect(harness.model.screen.conversationID == nil)
    }

    @MainActor
    @Test func aBlankBoxKeepsNothing() async throws {
        let harness = try await HistoryHarness(label: "draft-blank")
        defer { harness.tearDown() }

        #expect(harness.model.composerDraft == nil)
        harness.model.promptText = " \n "
        #expect(harness.model.composerDraft == nil)
    }

    @Test func theStoreKeepsOneDraftAndClearsOnNil() throws {
        let suite = "ComposerDraftTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ComposerDraftStore(defaults: defaults)
        #expect(store.load() == nil)

        let draft = ComposerDraft(text: "kept", conversationID: UUID())
        store.save(draft)
        #expect(ComposerDraftStore(defaults: defaults).load() == draft)

        store.save(nil)
        #expect(store.load() == nil)
    }
}
