import SwiftUI
import TurboFieldfareAppCore
import UIKit
import os

@main
struct TurboFieldfareiOSApp: App {
    /// `--autorun` still launches straight into the benchmark harness.
    ///
    /// That path is how `devicectl device process launch` produces a row in
    /// `MEASUREMENTS.md`, and Track B cannot work without the instrument — so
    /// the chat UI is added *beside* the harness rather than on top of it. A
    /// benchmark run must not have a chat screen in front of it, and the chat
    /// screen keeps the harness reachable by hand through its own sheet.
    private static let isBenchmarkRun =
        ProcessInfo.processInfo.arguments.contains("--autorun")

    @State private var model = ChatSession.makeModel()
    @State private var network = DownloadNetwork()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.isBenchmarkRun {
                    HarnessView()
                } else if BackgroundProbe.isRequested {
                    BackgroundProbeView()
                } else {
                    ChatView(model: model, network: network)
                        .task {
                            if ModelSwitchCheck.isRequested {
                                await ModelSwitchCheck.run(model)
                            } else if BackgroundGenerationCheck.isRequested {
                                await BackgroundGenerationCheck.run(model)
                            }
                        }
                }
            }
            // A turn, a load or an install is minutes long, and a locked phone
            // suspends the app in the middle of it. Only then, though: pinning
            // the screen on for good drained the battery of a phone left
            // sitting on an idle chat.
            .onChange(of: keepsScreenOn, initial: true) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
            }
            // `initial` so a launch counts as a return: a download that iOS
            // stopped, or that died with the app, resumes when it opens.
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard !Self.isBenchmarkRun, !BackgroundProbe.isRequested else { return }
                BackgroundGeneration.shared.attach(model)
                BackgroundGeneration.shared.scenePhaseChanged(phase)
                Suspension.handle(phase, model: model, network: network)
            }
            .onChange(of: model.backgroundGeneration) { _, _ in
                guard !Self.isBenchmarkRun, !BackgroundProbe.isRequested else { return }
                BackgroundGeneration.shared.update()
            }
            .onChange(of: model.isWaitingForGPU) { _, waiting in
                guard !Self.isBenchmarkRun, !BackgroundProbe.isRequested else { return }
                TurnMemoryLog.shared.note(waiting ? "turn-paused" : "turn-resumed")
            }
            // The installer creates the folders as it goes, so the backup mark
            // is applied at launch and again whenever a download starts or ends.
            .onChange(of: model.isInstallingModel || model.isInstallingVisionPack,
                      initial: true) { _, _ in
                BackupExclusion.apply()
            }
            .onChange(of: model.isTurnInFlight) { _, inFlight in
                guard !Self.isBenchmarkRun else { return }
                if !BackgroundProbe.isRequested { BackgroundGeneration.shared.update() }
                if inFlight {
                    TurnMemoryLog.shared.begin()
                } else {
                    TurnMemoryLog.shared.end(images: model.outputImageAttachments.count)
                }
            }
            .onChange(of: model.loadState) { _, state in
                guard !Self.isBenchmarkRun else { return }
                TurnMemoryLog.shared.modelState(
                    state, key: model.installDescriptor.key, path: model.modelPathText)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                // Logged, not acted on. Stopping the turn frees nothing, since
                // the KV and the expert slots stay allocated, and nobody yet
                // knows whether a 4 GB process gets these as routine. Stopping
                // on a routine warning would cut off every reply.
                Suspension.log.warning(
                    "memory warning; turn running: \(model.isRunning, privacy: .public)")
            }
        }
    }

    private var keepsScreenOn: Bool {
        // The benchmark harness drives its own session, so the chat model's
        // state says nothing about it. It keeps the screen on for the whole
        // launch, as it always has.
        Self.isBenchmarkRun
            || model.isTurnInFlight
            || model.loadState.isLoading
            // Not the model download: `BackgroundDownload` keeps it running on
            // a locked phone, so holding the screen on would only cost battery.
            || model.isInstallingVisionPack
    }
}

/// What leaving the app does to a turn in flight.
///
/// The model stays loaded, because reloading takes minutes. With background
/// generation on (the default), the reply carries on in a Picture in Picture
/// window, or waits out a lock (`BackgroundGeneration`). Otherwise the turn is
/// ended and kept, because iOS may end the process at any point after this,
/// and a kept turn reopens from disk while a half-streamed one is simply lost.
@MainActor
enum Suspension {
    static let log = Logger(subsystem: "TurboFieldfare", category: "lifecycle")

    static func handle(_ phase: ScenePhase, model: AppModel, network: DownloadNetwork) {
        switch phase {
        case .inactive:
            // With background generation on, nothing stops here: an inactive
            // app still has the GPU, and a refused token now waits and retries
            // rather than failing the turn.
            //
            // Off, stop here, before the app is backgrounded. A backgrounded
            // app may not submit GPU work, and decode submits some for every
            // token, so a stop requested at `.background` could land after the
            // next token's encode had already failed. The cost: pulling down
            // Control Center or taking a call also stops the reply.
            if !model.backgroundGeneration, model.canCancel { model.cancel() }
        case .background:
            pauseDownloads(model, network: network)
            if model.backgroundGeneration && model.isTurnInFlight {
                continueOrStop(model, network: network)
            } else {
                flush(model, network: network)
            }
        case .active:
            resumeDownloads(model, network: network)
            BackgroundDownload.resumeIfWanted(model, network: network)
        @unknown default:
            break
        }
    }

    /// Stops a download at a saved checkpoint rather than letting iOS freeze
    /// it mid-request. A model download that `BackgroundDownload`'s task is
    /// keeping alive is left running.
    ///
    /// A suspended app's connections die, and the installer would find out
    /// only on return, as a failure. Cancelled here, it records where it got
    /// to and says so, and `resumeDownloads` picks it up from there. `flush`
    /// then waits for the cancellation to land, inside the same background
    /// window.
    private static func pauseDownloads(_ model: AppModel, network: DownloadNetwork) {
        if model.isInstallingModel && model.canCancelInstall
            && !BackgroundDownload.keepsDownloadRunning {
            network.resumesModelOnReturn = true
            model.cancelInstall()
            log.info("model download paused for background")
        }
        if model.isInstallingVisionPack && model.canCancelVisionInstall {
            network.resumesImageSupportOnReturn = true
            model.cancelVisionInstall()
            log.info("image support download paused for background")
        }
    }

    /// Resumes the image-support download `pauseDownloads` paused, and only
    /// that. A quick return can arrive before the cancellation has finished,
    /// so this waits it out first; starting over a cancelling install is
    /// refused. The model download is resumed by
    /// `BackgroundDownload.resumeIfWanted`, which also covers a download iOS
    /// stopped or that died with the app.
    private static func resumeDownloads(_ model: AppModel, network: DownloadNetwork) {
        network.resumesModelOnReturn = false
        guard network.resumesImageSupportOnReturn else { return }
        let resumesImageSupport = network.resumesImageSupportOnReturn
        network.resumesImageSupportOnReturn = false
        Task {
            while model.isInstallingModel || model.isInstallingVisionPack {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if resumesImageSupport {
                model.installVisionPack()
                log.info("image support download resumed")
            }
        }
    }

    /// Lets the turn carry on if the window opened or the phone was locked,
    /// and otherwise stops and saves it as before.
    ///
    /// The window opens as the app leaves, and the lock notification can land
    /// after the scene change, so both get a short grace period. Without
    /// either, nothing will let the turn run again before iOS suspends the
    /// app, and a suspended 3 GB app is soon killed (2026-10-09, run 2): a
    /// stopped turn is kept, a frozen one would be lost.
    private static func continueOrStop(_ model: AppModel, network: DownloadNetwork) {
        let app = UIApplication.shared
        let task = BackgroundTask()
        task.id = app.beginBackgroundTask(withName: "Keep generating") {
            task.end()
        }
        Task {
            let deadline = ContinuousClock.now + .milliseconds(1500)
            while !BackgroundGeneration.shared.continuesInBackground
                    && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Back already, or the turn ended in the meantime: nothing to do.
            let leftWithoutWindow = !BackgroundGeneration.shared.continuesInBackground
                && !BackgroundGeneration.shared.isForeground
            if leftWithoutWindow && model.isTurnInFlight {
                log.info("no picture-in-picture window and not locked; stopping the turn")
                TurnMemoryLog.shared.note("background-without-window stopping-turn")
                flush(model, network: network)
            }
            task.end()
        }
    }

    /// Waits for the stopped turn to be written, and for any paused download
    /// to reach its checkpoint, inside the time iOS grants a backgrounded app.
    private static func flush(_ model: AppModel, network: DownloadNetwork) {
        let app = UIApplication.shared
        let task = BackgroundTask()
        task.id = app.beginBackgroundTask(withName: "Save conversation") {
            task.end()
        }
        Task {
            // Under the roughly 30 s iOS grants, so it ends the task itself
            // instead of being cut off by expiry.
            // One deadline for both waits, under the roughly 30 s iOS grants.
            let deadline = ContinuousClock.now + .seconds(25)
            let saved = await model.prepareForSuspension(timeout: .seconds(20))
            if !saved {
                log.error("conversation not saved before suspension")
            }
            // Only for the downloads that were paused; one the background
            // task keeps running is not going to stop.
            while ((network.resumesModelOnReturn && model.isInstallingModel)
                   || (network.resumesImageSupportOnReturn && model.isInstallingVisionPack))
                && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            task.end()
        }
    }

    private final class BackgroundTask {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}

struct HarnessView: View {
    @StateObject private var harness = Harness()
    /// Set by `--autorun`, so `devicectl device process launch` can drive a run
    /// without anyone touching the screen.
    private let autorun = ProcessInfo.processInfo.arguments.contains("--autorun")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TurboFieldfare").font(.headline)
                Spacer()
                if harness.running {
                    ProgressView()
                } else {
                    Button("Run") {
                        Task { await harness.run() }
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(harness.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                }
                .onChange(of: harness.lines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .padding()
        .task {
            if autorun { await harness.run() }
        }
        // Started by hand from the chat screen, a run is minutes long and the
        // chat model's state does not cover it. Under `--autorun` the app
        // already holds the screen on for the whole launch.
        .onChange(of: harness.running) { _, running in
            guard !autorun else { return }
            UIApplication.shared.isIdleTimerDisabled = running
        }
    }
}

/// Memory around each chat turn and each model load and unload, appended to
/// `Documents/app-memory.log`.
///
/// It is also where the chat app's diagnostics live: the model's path and the
/// app's footprint used to be rows in Settings, and are read from here now.
///
/// The harness cannot send an image, so the chat app is the instrument for
/// what image input costs, and it runs the exact configuration a user gets.
/// Lifetime peak alone cannot separate turns: an image turn peaking below an
/// earlier text turn would read the same. So the turn is also sampled every
/// 0.5 s and its own maximum logged. The sampler reads counters only; it does
/// not touch the GPU, so it is safe while the app is backgrounded.
@MainActor
final class TurnMemoryLog {
    static let shared = TurnMemoryLog()

    private let url = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask)[0]
        .appendingPathComponent("app-memory.log")
    private var sampler: Task<Void, Never>?
    private var turnMax: UInt64 = 0
    private var started: ContinuousClock.Instant?

    func begin() {
        turnMax = Mem.footprint()
        started = .now
        write("turn-start " + Mem.line() + " thermal=\(DeviceState.thermal())")
        sampler?.cancel()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.turnMax = max(self.turnMax, Mem.footprint())
            }
        }
    }

    func end(images: Int) {
        sampler?.cancel()
        sampler = nil
        turnMax = max(turnMax, Mem.footprint())
        let seconds = started.map { (ContinuousClock.now - $0).components.seconds } ?? 0
        write("turn-end images=\(images) seconds=\(seconds) turn-max=\(turnMax) "
              + Mem.line() + " thermal=\(DeviceState.thermal())")
    }

    /// One line when a load finishes or an unload completes, so the resting
    /// footprint of each model sits beside the turns that follow.
    func modelState(_ state: AppModelLoadState, key: String, path: String) {
        switch state {
        case .ready(_, let loadSeconds):
            write("model-ready model=\(key) load-seconds="
                  + String(format: "%.1f", loadSeconds) + " path=\(path) "
                  + Mem.line() + " thermal=\(DeviceState.thermal())")
        case .notLoaded:
            write("model-unloaded model=\(key) " + Mem.line())
        default:
            return
        }
    }

    /// One line for a background-generation event: the window, the lock, the
    /// GPU gate, a pause.
    func note(_ event: String) {
        write("background " + event + " " + Mem.line())
    }

    private func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        } else {
            try? data.write(to: url)
        }
    }
}
