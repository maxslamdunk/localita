import Foundation
import Testing
@testable import TurboFieldfareAppCore

/// The three gaps a review of this branch named: unload with a conversation
/// open, the Cancel semantics the app actually ships, and a reset the service
/// never heard. Each of these had no coverage, and each hid a defect.
@Suite struct AppConversationLifecycleTests {
    @MainActor
    @Test func terminationShutdownIsIdempotentAndReleasesAttachments() throws {
        let client = MockLifecycleInferenceClient()
        let attachments = AppImageAttachmentStore(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("shutdown-attachments-\(UUID())", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: attachments.directoryURL) }
        let staged = try attachments.stage(
            data: Data("bounded".utf8), displayName: "attachment.bin")
        let model = AppModel(client: client, attachmentStore: attachments)
        model.setComposerAttachmentsForTesting([staged])

        model.shutdownForTermination()
        model.shutdownForTermination()

        #expect(client.shutdownCount == 1)
        #expect(!FileManager.default.fileExists(atPath: staged.fileURL.path))
        #expect(model.imageAttachments.isEmpty)
    }

    @MainActor
    private func readyModel(_ client: FakeInferenceClient) async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
        let model = AppModel(modelDirectory: directory, client: client)
        model.modelPathText = directory.path
        try await client.ensureLoaded(
            modelDirectory: directory, maxContextTokens: model.maxContextTokens,
            options: model.runtimeOptions, forceLogitsHead: true) { _ in }
        model.loadState = .ready(modelDirectory: directory, loadSeconds: 1)
        return model
    }

    @MainActor
    private func finish(_ model: AppModel) async {
        await SendWaiting.turnEnds(model)
    }

    /// The Mac's client stops cooperatively: the turn ends at a token
    /// boundary and arrives as `.finished`, so it is committed and its partial
    /// reply stays. Most other cancel tests model a client with no cooperative
    /// stop, which does the opposite — so this path had no coverage at all.
    @MainActor
    @Test func acooperativeStopCommitsTheTurnAndKeepsWhatItProduced() async throws {
        let client = FakeInferenceClient(eventDelay: .milliseconds(40),
                                         cancelSemantics: .cooperativeStop)
        let model = try await readyModel(client)
        model.promptText = "one"
        model.send()
        while model.isTurnInFlight, model.liveTokenCount == 0 { await Task.yield() }
        model.cancel()
        await finish(model)

        // Not counting it would put the app behind the service, and the next
        // turn would be refused.
        #expect(model.conversation.committedTurns == 1)
        #expect(model.conversation.turns.map(\.role) == [.user, .assistant])
        #expect(model.diagnostics?.stopReason == .cancelled)
        #expect(model.error == nil, "stopping is not an error")

        // The conversation continues from it, with a turn that really ran:
        // a double that never lowered its stop flag made the next run break at
        // its first token, and this assertion passed on an empty reply.
        model.promptText = "two"
        model.send()
        await finish(model)
        #expect(model.conversation.committedTurns == 2)
        let reply = try #require(model.conversation.turns.last)
        #expect(reply.role == .assistant)
        #expect(!reply.text.isEmpty, "the follow-up turn produced nothing")
        #expect(model.diagnostics?.stopReason != .cancelled,
                "the follow-up turn was stopped by a flag left set")
    }

    /// The in-process client is the only client on iOS, and its `cancel()`
    /// rewinds. Stop called that, so every stopped reply on the phone was
    /// thrown away and its prompt handed back. Stop must reach `stop()`.
    @MainActor
    @Test func stopKeepsTheTurnOnTheInProcessClient() async throws {
        let client = FakeInferenceClient(eventDelay: .milliseconds(40),
                                         cancelSemantics: .inProcess)
        let model = try await readyModel(client)
        model.promptText = "one"
        model.send()
        while model.isTurnInFlight, model.liveTokenCount == 0 { await Task.yield() }
        model.cancel()
        await finish(model)

        #expect(model.conversation.committedTurns == 1)
        #expect(model.conversation.turns.map(\.role) == [.user, .assistant])
        #expect(model.error == nil, "stopping is not an error")
        #expect(model.promptText.isEmpty, "the prompt was handed back as if rewound")
    }

    /// Backgrounding on iOS: the running turn ends as Stop would, is kept, and
    /// the model stays loaded, so coming back costs nothing.
    @MainActor
    @Test func suspensionKeepsTheTurnAndTheModel() async throws {
        let client = FakeInferenceClient(eventDelay: .milliseconds(40),
                                         cancelSemantics: .inProcess)
        let model = try await readyModel(client)
        model.promptText = "one"
        model.send()
        while model.isTurnInFlight, model.liveTokenCount == 0 { await Task.yield() }

        let finished = await model.prepareForSuspension(timeout: .seconds(10))

        #expect(finished)
        #expect(!model.isTurnInFlight)
        #expect(model.conversation.committedTurns == 1)
        #expect(model.loadState.isReady, "suspension unloaded the model")
    }

    /// A slot count changed through a direct binding is saved at the next send
    /// or at termination. iOS never delivers termination to a suspended app,
    /// so without this a force-quit after changing slots lost the change.
    @MainActor
    @Test func suspensionSavesSettingsChangedThroughBindings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("suspend-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("gemma4.gturbo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        let model = AppModel(modelDirectory: directory, client: FakeInferenceClient(),
                             settingsPersistenceEnabled: true)
        let changed = model.runtimeOptions.expertCacheSlots == 24 ? 16 : 24
        model.runtimeOptions.expertCacheSlots = changed

        await model.prepareForSuspension(timeout: .seconds(5))

        let saved = MacAppSettingsFileStore.loadOrCreate(forModelDirectory: directory)
        #expect(saved.expertCacheSlots == changed)
    }

    /// Reset restores what a fresh settings file holds, and saves it, so the
    /// restored values survive a relaunch.
    @MainActor
    @Test func resetRestoresFreshInstallSettingsAndSavesThem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("gemma4.gturbo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        let model = AppModel(modelDirectory: directory, client: FakeInferenceClient(),
                             settingsPersistenceEnabled: true)
        let fresh = MacAppSettings()
        model.temperature = 1.3
        model.topKEnabled = false
        model.topK = 7
        model.topPEnabled = false
        model.topP = 0.4
        model.runtimeOptions.expertCacheSlots = fresh.expertCacheSlots == 24 ? 16 : 24
        model.setMaxContextTokens(AppContextLengthOption.fourK.tokens)

        model.resetSettingsToDefaults()

        #expect(model.temperature == fresh.temperature)
        #expect(model.topKEnabled == fresh.topKEnabled)
        #expect(model.topK == fresh.topK)
        #expect(model.topPEnabled == fresh.topPEnabled)
        #expect(model.topP == fresh.topP)
        #expect(model.runtimeOptions.expertCacheSlots == fresh.expertCacheSlots)
        #expect(model.maxContextTokens == fresh.contextTokens)
        let saved = MacAppSettingsFileStore.loadOrCreate(forModelDirectory: directory)
        #expect(saved.temperature == fresh.temperature)
        #expect(saved.topK == fresh.topK)
        #expect(saved.expertCacheSlots == fresh.expertCacheSlots)
        #expect(saved.contextTokens == fresh.contextTokens)
    }

    /// Nothing running is the common case, and it must return at once.
    @MainActor
    @Test func suspensionWithNothingRunningIsImmediate() async throws {
        let model = try await readyModel(FakeInferenceClient())
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await model.prepareForSuspension(timeout: .seconds(10)))
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(model.loadState.isReady)
    }

    /// Pins the *double's* flag hygiene, which every other cooperative-stop
    /// assertion depends on: a fake that never lowered its stop flag made the
    /// following run break at its first token, quietly emptying them. The real
    /// client's equivalent is pinned in the heavy suite, because only a loaded
    /// model exercises its flags.
    @MainActor
    @Test func astopDoesNotLeakIntoTheNextRun() async throws {
        let client = FakeInferenceClient(eventDelay: .milliseconds(30),
                                         cancelSemantics: .cooperativeStop)
        let model = try await readyModel(client)

        model.promptText = "one"
        model.send()
        while model.isTurnInFlight, model.liveTokenCount == 0 { await Task.yield() }
        model.cancel()
        await finish(model)
        #expect(model.diagnostics?.stopReason == .cancelled)

        model.promptText = "two"
        model.send()
        await finish(model)
        #expect(model.diagnostics?.stopReason != .cancelled,
                "the next run inherited the stop")
        #expect((model.diagnostics?.generatedTokens ?? 0) > 1,
                "the next run stopped at one token")
    }

    /// A client with no cooperative stop rewinds the turn instead, and the app
    /// must not count it. The in-process client does the same during prefill,
    /// where there is no token boundary to stop at.
    @MainActor
    @Test func ahardAbortDoesNotCountTheTurnItRewound() async throws {
        let client = FakeInferenceClient(eventDelay: .milliseconds(40),
                                         cancelSemantics: .hardAbort)
        let model = try await readyModel(client)
        model.promptText = "one"
        model.send()
        while model.isTurnInFlight, model.livePrefillDone == 0 { await Task.yield() }
        model.cancel()
        await finish(model)

        #expect(model.conversation.committedTurns == 0)
        #expect(model.conversation.turns.isEmpty)
        #expect(model.error == .cancelled)
    }

    /// `currentHandles()` is nil when the connection is gone, not when the model
    /// is unloaded. Returning normally let the app record an epoch the service
    /// had never heard of — and because it then matched, the reset was never
    /// retried and every later turn was refused with no way back.
    @MainActor
    @Test func aresetTheServiceNeverHeardIsNotRecordedAsOpen() async throws {
        let client = FakeInferenceClient(eventDelay: .milliseconds(1))
        let model = try await readyModel(client)
        model.promptText = "one"
        model.send()
        await finish(model)
        #expect(client.conversationEpochs.count == 1)

        model.newChat()
        client.failNextReset(with: .unknown("the decode service connection is gone"))
        model.promptText = "after a lost reset"
        model.send()
        await finish(model)

        #expect(model.error != nil, "a lost reset was reported as success")
        #expect(model.conversation.committedTurns == 0,
                "the turn was counted against a lineage the service never opened")

        // And the next attempt opens it again rather than short-circuiting.
        model.promptText = "retry"
        model.send()
        await finish(model)
        #expect(client.conversationEpochs.count == 2,
                "the reset was never retried, so the conversation could not recover")
        #expect(model.conversation.committedTurns == 1)
    }
}
