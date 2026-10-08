import Foundation
import TurboFieldfareAppCore

/// The phone's chat controls, split by one rule: the top of the chat says what
/// is in memory and offers only what frees it (Unload, or Cancel during a
/// load), and the composer's button moves forward (Load, Send, Stop).
///
/// Downloading and deleting models happen in Settings. With no model on the
/// phone, the chat stays a chat: stored conversations still read, the top says
/// there is no model, and the composer's button says where to get one.
///
/// Picking a model in the composer only chooses it. Nothing loads, unloads or
/// downloads until the composer's button is pressed, so the top of the chat
/// keeps naming the model actually in memory until then.
public enum ChatControlsPresentation {
    /// The model picked in the composer, when it is not the one the app is on.
    public enum PickedModel: Equatable, Sendable {
        case installed
        case notInstalled
    }

    /// What the composer's button does.
    public enum ComposerAction: Equatable, Sendable {
        case send(enabled: Bool)
        case stop(enabled: Bool)
        /// Load the picked model. When it differs from the one the app is on,
        /// the switch releases that one first, so two are never in memory.
        case load(enabled: Bool)
        /// The picked model is not on the phone yet.
        case download(enabled: Bool)
        case retry(enabled: Bool)
        /// A runtime setting changed since the load.
        case reload(enabled: Bool)
        /// A load, an unload or an image-support change is running. The top
        /// of the chat shows which, and offers Cancel where it can.
        case busy
        /// The model the app is on is not on the phone, so there is nothing to
        /// load. Pressing the button says where models are downloaded.
        case noModel
    }

    public struct ComposerInput: Equatable, Sendable {
        public var isRunning: Bool
        public var canCancel: Bool
        public var picked: PickedModel?
        public var requiresInstallation: Bool
        public var isVisionFilesystemMutationInProgress: Bool
        public var loadState: AppModelLoadState
        public var hasStaleRuntime: Bool
        public var canSelectModel: Bool
        public var canLoad: Bool
        public var canReload: Bool
        public var canRun: Bool

        public init(isRunning: Bool = false,
                    canCancel: Bool = false,
                    picked: PickedModel? = nil,
                    requiresInstallation: Bool = false,
                    isVisionFilesystemMutationInProgress: Bool = false,
                    loadState: AppModelLoadState = .notLoaded,
                    hasStaleRuntime: Bool = false,
                    canSelectModel: Bool = true,
                    canLoad: Bool = false,
                    canReload: Bool = false,
                    canRun: Bool = false) {
            self.isRunning = isRunning
            self.canCancel = canCancel
            self.picked = picked
            self.requiresInstallation = requiresInstallation
            self.isVisionFilesystemMutationInProgress = isVisionFilesystemMutationInProgress
            self.loadState = loadState
            self.hasStaleRuntime = hasStaleRuntime
            self.canSelectModel = canSelectModel
            self.canLoad = canLoad
            self.canReload = canReload
            self.canRun = canRun
        }
    }

    public static func composerAction(_ input: ComposerInput) -> ComposerAction {
        if input.isRunning { return .stop(enabled: input.canCancel) }
        // Before the load state: a pick is a request about a different model,
        // and the button has to say what pressing it would do to that one.
        switch input.picked {
        case .installed: return .load(enabled: input.canSelectModel)
        case .notInstalled: return .download(enabled: input.canSelectModel)
        case nil: break
        }
        if input.requiresInstallation { return .noModel }
        if input.isVisionFilesystemMutationInProgress { return .busy }
        switch input.loadState {
        case .loading, .cancelling, .unloading:
            return .busy
        case .failed:
            return .retry(enabled: input.canLoad)
        case .notLoaded:
            return .load(enabled: input.canLoad)
        case .ready:
            return input.hasStaleRuntime
                ? .reload(enabled: input.canReload)
                : .send(enabled: input.canRun)
        }
    }

    /// The top of the chat's one button: the shared presentation's Unload or
    /// Cancel Load, and nothing that moves forward. Load, Retry and Reload are
    /// the composer's.
    public static func statusAction(_ presentation: AppPresentationState) -> AppModelAction? {
        [presentation.primaryAction, presentation.secondaryAction]
            .compactMap { $0 }
            .first { $0 == .unload || $0 == .cancelLoad }
    }

    /// The top of the chat's text: the model in memory, then what it is doing.
    ///
    /// A loaded model at rest is named alone. "Ready" beside it says nothing
    /// the green dot does not. With nothing in memory it says so in those
    /// words, rather than the shared "Installed · Not loaded".
    public static func statusLabel(_ presentation: AppPresentationState,
                                   loadState: AppModelLoadState,
                                   modelName: String) -> String {
        switch loadState {
        case .ready:
            return presentation.severity == .success
                ? modelName : "\(modelName) \u{00B7} \(presentation.label)"
        case .loading:
            return "\(modelName) \u{00B7} \(presentation.label)"
        case .notLoaded:
            return presentation.primaryAction == .load
                ? "No model loaded" : presentation.label
        case .cancelling, .unloading, .failed:
            return presentation.label
        }
    }

    /// The top of the chat's text while the model the app is on is not on the
    /// phone: downloading, paused, waiting, or never asked for.
    ///
    /// Until a download has been asked for, the chat says only what is
    /// missing: "No model installed", or, with other models on the phone,
    /// which one. The shared labels before that ("Model required", "Not
    /// enough storage") are about a download nobody started, and Settings
    /// shows them where Download is. Once one has been started, its state
    /// ("Download paused", "Installation failed") is kept, with the model's
    /// name.
    public static func notInstalledLabel(_ presentation: AppPresentationState,
                                         modelName: String,
                                         isAnyModelInstalled: Bool,
                                         isDownloadStarted: Bool,
                                         downloadFraction: Double?) -> String {
        if let downloadFraction {
            let percent = Int((min(max(downloadFraction, 0), 1) * 100).rounded(.down))
            return "Downloading \(modelName) \u{00B7} \(percent)%"
        }
        guard isDownloadStarted else {
            return isAnyModelInstalled ? "\(modelName) not downloaded" : "No model installed"
        }
        return "\(modelName) \u{00B7} \(presentation.label)"
    }
}
