import Foundation
import TurboFieldfareAppCore

/// `--background-generation-check`: sends one long message through the chat's
/// own `AppModel` and logs, every two seconds, how far the reply has got and
/// whether the app is in front, in the Picture in Picture window, paused, or
/// locked. Writes `Documents/decode-background-generation-<stamp>.log`.
///
/// Test-only, like `--model-switch-check`. It does not leave the app by
/// itself: whoever runs it does that, by hand or by launching another app with
/// `devicectl`, and comes back the same way. It turns the setting on for the
/// run, since it is off by default, and leaves the phone as it found it: the
/// setting restored and the chat it wrote deleted.
@MainActor
enum BackgroundGenerationCheck {
    static let isRequested = LaunchArguments.all.contains("--background-generation-check")

    private static let prompt = "Write a detailed essay of about 700 words on the history of the "
        + "bicycle, from the draisine to modern carbon racing bikes."

    static func run(_ model: AppModel) async {
        let log = RunLog(label: "background-generation")
        func emit(_ event: String, _ detail: String = "") { log.write(event, detail) }
        let background = BackgroundGeneration.shared
        func state() -> String {
            "tokens=\(model.liveTokenCount) phase=\(model.phase) inFlight=\(model.isTurnInFlight) "
                + "waiting=\(model.isWaitingForGPU) "
                + "gpu=\(model.gpuWorkGate?.isAvailable.description ?? "none") "
                + "foreground=\(background.isForeground) pip=\(background.isPiPActive) "
                + "locked=\(background.isLocked) setting=\(model.backgroundGeneration)"
        }

        emit("launch", state())
        if !model.loadState.isReady { model.loadModel() }
        while !(model.loadState.isReady || model.loadState.isFailed) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard model.loadState.isReady else {
            return emit("abort", "load failed: \(model.loadState)")
        }
        emit("loaded", state())

        let settingWasOn = model.backgroundGeneration
        model.setBackgroundGeneration(true)
        defer { model.setBackgroundGeneration(settingWasOn) }

        model.newChat()
        model.promptText = prompt
        guard model.canRun else { return emit("abort", "cannot run") }
        model.send()
        while !model.isTurnInFlight { try? await Task.sleep(for: .milliseconds(100)) }
        emit("sent", state())
        let started = ContinuousClock.now
        while model.isTurnInFlight {
            try? await Task.sleep(for: .seconds(2))
            emit("progress", state())
            if ContinuousClock.now - started > .seconds(1200) {
                emit("timeout", state())
                model.cancel()
                break
            }
        }
        while model.isTurnInFlight { try? await Task.sleep(for: .milliseconds(200)) }
        let reply = model.outputText
        emit("turn-ended", state() + " error=\(model.error.map { String(describing: $0) } ?? "none") "
            + "chars=\(reply.count) tail=\(reply.suffix(80).replacingOccurrences(of: "\n", with: " "))")

        // Saved before it is deleted, so the store's write is not racing it.
        try? await Task.sleep(for: .seconds(2))
        if let id = model.history.selection {
            model.newChat()
            model.deleteConversation(id: id)
            emit("done", "deleted the chat")
        } else {
            emit("done", "no stored chat to delete")
        }
    }
}
