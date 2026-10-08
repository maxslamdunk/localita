import Foundation
import Testing
@testable import TurboFieldfareAppCore
@testable import TurboFieldfareAppPresentation

/// The phone's chat controls: the top of the chat frees memory, the composer
/// moves forward, and picking a model only chooses it.
@Suite struct ChatControlsPresentationTests {
    private typealias Controls = ChatControlsPresentation

    private static let ready = AppModelLoadState.ready(
        modelDirectory: URL(fileURLWithPath: "/tmp/gemma4.gturbo"), loadSeconds: 1)

    // MARK: - The composer's button

    @Test func aLoadedModelAtRestSends() {
        #expect(Controls.composerAction(.init(loadState: Self.ready, canRun: true))
            == .send(enabled: true))
        // Nothing typed yet: Send, greyed, not some other button.
        #expect(Controls.composerAction(.init(loadState: Self.ready, canRun: false))
            == .send(enabled: false))
    }

    @Test func aRunningTurnStopsWhateverIsPicked() {
        #expect(Controls.composerAction(.init(
            isRunning: true, canCancel: true, picked: .installed,
            loadState: Self.ready)) == .stop(enabled: true))
    }

    /// With nothing in memory the button loads; it does not send, so a message
    /// already typed stays in the box.
    @Test func nothingLoadedLoads() {
        #expect(Controls.composerAction(.init(loadState: .notLoaded, canLoad: true))
            == .load(enabled: true))
    }

    /// A pick is about another model, so it decides the button even while the
    /// model in memory could take a message.
    @Test func pickingAnotherModelTurnsSendIntoLoadOrDownload() {
        #expect(Controls.composerAction(.init(
            picked: .installed, loadState: Self.ready, canRun: true))
            == .load(enabled: true))
        #expect(Controls.composerAction(.init(
            picked: .notInstalled, loadState: Self.ready, canRun: true))
            == .download(enabled: true))
        // A switch waits for a companion operation moving the model's files.
        #expect(Controls.composerAction(.init(
            picked: .installed, loadState: Self.ready, canSelectModel: false))
            == .load(enabled: false))
    }

    @Test func aLoadInProgressIsBusyAndAFailedOneRetries() {
        #expect(Controls.composerAction(.init(loadState: .loading(.tokenizer)))
            == .busy)
        #expect(Controls.composerAction(.init(loadState: .unloading)) == .busy)
        #expect(Controls.composerAction(.init(
            loadState: .failed(.cancelled), canLoad: true)) == .retry(enabled: true))
        #expect(Controls.composerAction(.init(
            loadState: Self.ready, hasStaleRuntime: true, canReload: true))
            == .reload(enabled: true))
        #expect(Controls.composerAction(.init(
            isVisionFilesystemMutationInProgress: true, loadState: Self.ready,
            canRun: true)) == .busy)
    }

    /// Downloads live in Settings, so with nothing to load the button says
    /// where to get a model rather than sitting greyed out.
    @Test func aModelNotInstalledPointsToSettings() {
        #expect(Controls.composerAction(.init(requiresInstallation: true))
            == .noModel)
        // A reply still running stops first, whatever is on disk.
        #expect(Controls.composerAction(.init(
            isRunning: true, canCancel: true, requiresInstallation: true))
            == .stop(enabled: true))
    }

    @Test func withoutTheModelTheTopSaysWhatIsMissing() {
        func label(_ presentation: AppPresentationState, anyInstalled: Bool = false,
                   started: Bool = false, fraction: Double? = nil) -> String {
            Controls.notInstalledLabel(presentation, modelName: "Gemma 4",
                                       isAnyModelInstalled: anyInstalled,
                                       isDownloadStarted: started,
                                       downloadFraction: fraction)
        }
        let required = AppPresentationState(label: "Model required",
                                            primaryAction: .install)
        #expect(label(required) == "No model installed")
        #expect(label(required, anyInstalled: true) == "Gemma 4 not downloaded")
        // A storage shortfall matters to a download, which nobody has asked for.
        #expect(label(AppPresentationState(label: "Not enough storage",
                                           severity: .warning)) == "No model installed")
        #expect(label(AppPresentationState(label: "Downloading model",
                                           severity: .active, showsActivity: true),
                      started: true, fraction: 0.426) == "Downloading Gemma 4 \u{00B7} 42%")
        #expect(label(AppPresentationState(label: "Download paused",
                                           severity: .warning, primaryAction: .install),
                      started: true) == "Gemma 4 \u{00B7} Download paused")
    }

    // MARK: - The top of the chat

    @Test func theTopOffersOnlyWhatFreesMemory() {
        #expect(Controls.statusAction(AppPresentationState(
            label: "Ready", severity: .success, secondaryAction: .unload)) == .unload)
        #expect(Controls.statusAction(AppPresentationState(
            label: "Loading tokenizer", primaryAction: .cancelLoad)) == .cancelLoad)
        #expect(Controls.statusAction(AppPresentationState(
            label: "Reload required", primaryAction: .reload,
            secondaryAction: .unload)) == .unload)
        #expect(Controls.statusAction(AppPresentationState(
            label: "Installed · Not loaded", primaryAction: .load)) == nil)
        #expect(Controls.statusAction(AppPresentationState(
            label: "Model required", primaryAction: .install)) == nil)
    }

    @Test func theTopNamesTheModelInMemory() {
        func label(_ presentation: AppPresentationState,
                   _ state: AppModelLoadState) -> String {
            Controls.statusLabel(presentation, loadState: state, modelName: "Gemma 4")
        }
        #expect(label(AppPresentationState(label: "Ready", severity: .success),
                      Self.ready) == "Gemma 4")
        #expect(label(AppPresentationState(label: "Done · eos", severity: .success),
                      Self.ready) == "Gemma 4")
        #expect(label(AppPresentationState(label: "Generating", severity: .active),
                      Self.ready) == "Gemma 4 \u{00B7} Generating")
        #expect(label(AppPresentationState(label: "Loading tokenizer",
                                           severity: .active, showsActivity: true),
                      .loading(.tokenizer)) == "Gemma 4 \u{00B7} Loading tokenizer")
        #expect(label(AppPresentationState(label: "Installed · Not loaded",
                                           primaryAction: .load),
                      .notLoaded) == "No model loaded")
        #expect(label(AppPresentationState(label: "Model required",
                                           primaryAction: .install),
                      .notLoaded) == "Model required")
        #expect(label(AppPresentationState(label: "Unloading model",
                                           severity: .active), .unloading)
            == "Unloading model")
    }
}
