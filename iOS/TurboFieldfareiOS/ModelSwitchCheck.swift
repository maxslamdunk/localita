import Foundation
import TurboFieldfareAppCore

/// `--model-switch-check`: drives the chat's own `AppModel` through a round
/// trip between the two text models and writes what happened to Documents.
///
/// Test-only, like `--autorun`, so `devicectl device process launch` can check
/// on the phone what the Mac tests can only check with mocks: that switching
/// releases one model before loading the other, that each loads and generates
/// from its own folder, and that tapping a chat recorded with the other model
/// switches back to it. It uses the paths the menu and the chat list use
/// (`ChatSession.selectModel`, `ChatSession.modelToSwitch`), not copies.
///
/// It leaves the phone as it found it: back on the model it started on, with
/// the two chats it wrote deleted.
@MainActor
enum ModelSwitchCheck {
    static let isRequested = ProcessInfo.processInfo.arguments.contains("--model-switch-check")

    private static let prompt = "In one short sentence: why is the sky blue?"

    static func run(_ model: AppModel) async {
        let log = RunLog(label: "model-switch")
        func emit(_ event: String, _ detail: String = "") { log.write(event, detail) }
        func state(_ tag: String) {
            emit(tag, "model=\(model.installDescriptor.key) "
                + "installed=\(model.isModelInstalled) "
                + "load=\(model.loadState) "
                + "images=\(model.isImageInputAvailable) "
                + "pack=\(model.visionInstallationStatus) "
                + "visionRuntime=\(model.isVisionRuntimeSupported) "
                + "path=\(model.modelPathText)")
        }

        state("launch")
        // Always from the reference model, and so always back to it: the phone
        // is left on the model it normally runs, whatever a failed earlier
        // run left remembered.
        if model.installDescriptor != .default {
            ChatSession.selectModel(.default, in: model)
        }
        let start = model.installDescriptor
        state("start")
        for descriptor in model.availableModels {
            emit("catalog", "\(descriptor.key) installed="
                + "\(ChatSession.isInstalled(descriptor, current: model)) "
                + "images=\(descriptor.supportsImages)")
        }
        guard let other = model.availableModels.first(where: {
            $0 != start && ChatSession.isInstalled($0, current: model)
        }) else {
            emit("abort", "no second installed model")
            return
        }

        var written: [UUID] = []
        do {
            try await load(model, emit: emit)
            written.append(try await generate(model, emit: emit))
            let first = written[0]

            ChatSession.selectModel(other, in: model)
            state("switched")
            try await waitForLoad(model, emit: emit)
            state("loaded-after-switch")
            written.append(try await generate(model, emit: emit))

            // The chat list's tap on a row recorded with the first model.
            guard let entry = model.history.entry(first) else {
                emit("fail", "first chat is not in the list")
                return cleanUp(model, written, restoring: start, emit: emit)
            }
            emit("row", "continuability=\(model.continuability(of: entry))")
            guard let recorded = ChatSession.modelToSwitch(for: entry, in: model) else {
                emit("fail", "chat list would not offer a switch for the first chat")
                return cleanUp(model, written, restoring: start, emit: emit)
            }
            emit("row-switch", "to=\(recorded.key)")
            ChatSession.selectModel(recorded, in: model, openingConversation: first)
            try await waitForLoad(model, emit: emit)
            try await waitUntil(seconds: 20) { model.history.selection == first }
            state("reopened")
            emit("reopened-chat", "selection=\(model.history.selection?.uuidString ?? "nil") "
                + "continuability=\(model.continuability(of: entry))")
        } catch {
            emit("fail", String(describing: error))
        }
        cleanUp(model, written, restoring: start, emit: emit)
    }

    private static func cleanUp(_ model: AppModel, _ written: [UUID],
                                restoring start: AppModelInstallDescriptor,
                                emit: (String, String) -> Void) {
        model.newChat()
        for id in written { model.deleteConversation(id: id) }
        // A failed run can stop on the other model; the next launch would
        // then open on it, since the choice is remembered.
        if model.installDescriptor != start {
            ChatSession.selectModel(start, in: model)
        }
        emit("done", "deleted \(written.count) chats, model=\(model.installDescriptor.key)")
    }

    private static func load(_ model: AppModel,
                             emit: (String, String) -> Void) async throws {
        if !model.loadState.isReady { model.loadModel() }
        try await waitForLoad(model, emit: emit)
    }

    private static func waitForLoad(_ model: AppModel,
                                    emit: (String, String) -> Void) async throws {
        let started = Date()
        try await waitUntil(seconds: 600) {
            model.loadState.isReady || model.loadState.isFailed
        }
        guard model.loadState.isReady else {
            throw CheckError("load failed: \(model.loadState)")
        }
        emit("loaded", "model=\(model.installDescriptor.key) "
            + "s=\(Int(Date().timeIntervalSince(started)))")
    }

    /// One turn in a fresh chat. Returns the stored conversation's ID.
    private static func generate(_ model: AppModel,
                                 emit: (String, String) -> Void) async throws -> UUID {
        model.newChat()
        model.promptText = prompt
        guard model.canRun else { throw CheckError("cannot run: load=\(model.loadState)") }
        model.send()
        try await waitUntil(seconds: 20) { model.isTurnInFlight }
        try await waitUntil(seconds: 600) { !model.isTurnInFlight }
        let reply = model.outputText.replacingOccurrences(of: "\n", with: " ")
        emit("turn-ended", "model=\(model.installDescriptor.key) "
            + "selection=\(model.history.selection?.uuidString ?? "nil") "
            + "entries=\(model.history.entries.count) "
            + "error=\(model.error.map { String(describing: $0) } ?? "none") "
            + "diagnostic=\(model.historyDiagnostic ?? "none") "
            + "reply=\(reply.prefix(120))")
        try await waitUntil(seconds: 20) { model.history.selection != nil }
        guard let id = model.history.selection else { throw CheckError("no stored chat") }
        emit("generated", "model=\(model.installDescriptor.key) chat=\(id.uuidString) "
            + "error=\(model.error.map { String(describing: $0) } ?? "none") "
            + "reply=\(reply.prefix(200))")
        return id
    }

    private static func waitUntil(seconds: Double,
                                  _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw CheckError("timed out after \(Int(seconds)) s") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private struct CheckError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
