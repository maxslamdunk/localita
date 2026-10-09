import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// The chat screen: status, transcript, composer, with the chats and settings
/// in a side panel (`SideDrawer`) that the menu button or a sideways drag
/// opens.
///
/// Every decision about what the status row may say and which lifecycle action
/// it may offer comes from `AppPresentationState.resolve`, shared with the Mac,
/// split between the top of the chat and the composer by
/// `ChatControlsPresentation`. Re-deriving that here is how a platform ends up
/// offering a fully enabled button that does nothing — the case its own
/// comments record.
struct ChatView: View {
    let model: AppModel
    let network: DownloadNetwork

    @State private var blocks = StreamingBlocks()
    @State private var thinkingBlocks = StreamingBlocks(.reasoning)
    @State private var isShowingSettings = false
    /// The tab Settings opens on: Models when the way there was about getting
    /// a model, Generation from the chat list's gear.
    @State private var settingsPage = SettingsView.Page.generation
    @State private var isShowingChats = false
    @State private var seamThumb = SeamThumb()
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    /// The status the top bar shows, which trails the model's by up to
    /// `minimumStatusTime` per status. Nil only before the first one.
    @State private var shownPresentation: AppPresentationState?
    @State private var shownAt = ContinuousClock.now
    /// Statuses the model has moved through that have not been shown yet.
    @State private var statusQueue: [AppPresentationState] = []
    @State private var statusPump: Task<Void, Never>?

    /// Every status stays up at least this long. An unload on the phone takes
    /// a frame or two, and its "Unloading model" flashed too briefly to read.
    private static let minimumStatusTime: Duration = .milliseconds(300)
    private static let statusFade: Animation = .easeInOut(duration: 0.1)

    var body: some View {
        SideDrawer(isOpen: $isShowingChats, seamThumb: seamThumb) {
            chat
        } drawer: {
            HistoryView(model: model,
                        close: { isShowingChats = false },
                        // The panel stays open under the sheet, so closing
                        // Settings goes back to the chats it was opened from.
                        openSettings: { openSettings(.generation) },
                        seamThumb: seamThumb)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(model: model, network: network, page: $settingsPage)
        }
    }

    private func openSettings(_ page: SettingsView.Page) {
        settingsPage = page
        isShowingSettings = true
    }

    private var chat: some View {
        Group {
            // Without the model, a stored chat still reads; only an empty one
            // has nothing to show, and gets the way to a model instead.
            if model.requiresModelInstallation && isTranscriptEmpty {
                NoModelView(model: model) { openSettings(.models) }
            } else {
                ChatTranscriptView(model: model,
                                   blocks: blocks,
                                   thinkingBlocks: thinkingBlocks)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Bars rather than rows of a stack, so the conversation scrolls on
        // under the menu button and the message box, and the first and last
        // lines still settle clear of them. Bars rather than plain insets
        // because only a bar gives the scroll view the system's edge effect:
        // the text fades out under the box instead of being cut off at a
        // hard edge.
        .safeAreaBar(edge: .top, spacing: 0) {
            statusBar.background(alignment: .top) { topFade }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { bottomControls }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // The system's top edge also blurs the text, and there is no setting
        // for a fade alone. So it is hidden, and `topFade` fades instead.
        .scrollEdgeEffectHidden(true, for: .top)
        .background(Color(uiColor: .systemBackground))
        // Behind the opaque background, so never seen: the layer the
        // background-generation window takes its picture from has to be in the
        // window for the window to open.
        .background(alignment: .topLeading) {
            BackgroundGeneration.SourceView()
                .frame(width: 32, height: 24)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            if GenericErrorBannerPolicy.shouldShow(error: model.error,
                                                   loadState: model.loadState) {
                errorBanner
            }

            ConversationNoticeView(model: model)

            // Not disabled when no model is installed. It was, and that made
            // the keyboard refuse to appear at all — a dead end on top of a
            // dead end, since the reason no model was recognised was itself
            // not being shown. Typing without a model is harmless: `canRun`
            // already gates the send button, so the worst case is a composed
            // message waiting for a load.
            ChatComposer(model: model) { openSettings(.models) }
        }
    }

    /// The text scrolling up under the menu button fades toward the
    /// background, without blur. The fade spans the button's own height: none
    /// at its bottom edge, rising evenly through the lower half, then easing
    /// into 90% at its top edge, and a flat 90% from there up behind the
    /// phone's status bar. It never goes solid, so the text stays readable up
    /// there, only darker.
    private var topFade: some View {
        let background = Color(uiColor: .systemBackground)
        return VStack(spacing: 0) {
            // Takes whatever is above the button: the bar's top padding and,
            // past the safe area, the status bar.
            background.opacity(0.9)
            LinearGradient(stops: Self.fadeStops(background),
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.menuButtonSize)
        }
        // The bar's own space under the button, so the fade ends there.
        .padding(.bottom, Self.statusBarBottomPadding)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private static let menuButtonSize: CGFloat = 46

    /// Opacity over the height x of the button, 0 at its bottom edge and 1 at
    /// its top: a straight line up to halfway, then a curve whose slope falls
    /// to zero at the top, so it meets the flat 90% above without a corner.
    /// A straight line all the way made that corner show as a jump in the
    /// text scrolling past it. Traced by stops, since a gradient takes no
    /// function, and blended smoothly between them.
    private static func fadeStops(_ color: Color) -> [Gradient.Stop] {
        (0...16).map { step in
            let location = CGFloat(step) / 16  // 0 is the top edge
            let x = 1 - location
            let u = max(x - 0.5, 0)
            let opacity = x <= 0.5 ? 1.2 * x : 0.6 + 1.2 * u - 1.2 * u * u
            return .init(color: color.opacity(opacity), location: location)
        }
    }
    private static let statusBarBottomPadding: CGFloat = 10

    // MARK: - Status

    /// The shared status, worded for the top of the chat: the model in memory
    /// first, and only Unload or Cancel Load as its button. Load, Retry and
    /// Reload belong to the composer (`ChatControlsPresentation`).
    private var statusPresentation: AppPresentationState {
        var presentation = model.presentation
        let name = model.installDescriptor.shortName
        if model.requiresModelInstallation {
            presentation.label = ChatControlsPresentation.notInstalledLabel(
                presentation, modelName: name,
                isAnyModelInstalled: model.availableModels.contains {
                    ChatSession.isInstalled($0, current: model)
                },
                isDownloadStarted: model.installState != .idle
                    || model.hasPartialModelDownload,
                downloadFraction: model.isInstallingModel
                    ? model.installProgressFraction : nil)
        } else {
            presentation.label = ChatControlsPresentation.statusLabel(
                presentation, loadState: model.loadState, modelName: name)
        }
        return presentation
    }

    private var isTranscriptEmpty: Bool {
        model.transcriptHistory.isEmpty
            && !(model.showsLiveTurn && model.hasOutputTranscript)
    }

    private var statusBar: some View {
        let presentation = shownPresentation ?? statusPresentation
        return HStack(spacing: 10) {
            Button {
                isShowingChats = true
            } label: {
                // A fixed size rather than a control size: the system's sizes
                // step from 44 to 54 pt with nothing in between.
                MenuGlyph()
                    .frame(width: Self.menuButtonSize, height: Self.menuButtonSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Chats")

            statusPill(presentation)

            Spacer(minLength: 8)

            // Informational only. On this phone `serious` measured 11.6% off
            // throughput, almost all of it in the expert fetch, so a slow reply
            // gets its explanation on screen. `fair` measured as no visible
            // throttling, so it is not shown.
            if thermalState == .serious || thermalState == .critical {
                Image(systemName: "thermometer.high")
                    .font(.caption)
                    .foregroundStyle(thermalState == .critical ? .red : .orange)
                    .accessibilityLabel("Phone is hot")
                    .accessibilityValue(thermalState == .critical
                                        ? "Critical" : "Serious")
            }

            if model.isRunning, model.liveTokensPerSecond > 0 {
                Text("\(MetricFormat.rate(model.liveTokensPerSecond)) tok/s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(.hudRate)
            }

            // Only what frees memory: Unload, or Cancel while a load runs,
            // which takes long enough to be worth abandoning. Downloads belong
            // to Settings, which asks about mobile data before it starts a
            // 14.6 GB download, and Load to the composer.
            if let action = ChatControlsPresentation.statusAction(presentation) {
                Button(actionLabel(action)) { model.perform(action) }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .contentTransition(.opacity)
                    .transition(.opacity)
                    .accessibilityIdentifier(.bannerModelAction)
            }
        }
        .onChange(of: statusPresentation, initial: true) { _, new in
            enqueueStatus(new)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, Self.statusBarBottomPadding)
    }

    /// Queues a status so that each one is shown for `minimumStatusTime`.
    ///
    /// A status that only moves a counter, "Prefill (3/8)" to "(4/8)", takes
    /// the place of the one before it rather than waiting its turn, so a fast
    /// counter cannot build a backlog the bar falls ever further behind.
    private func enqueueStatus(_ status: AppPresentationState) {
        guard let shown = shownPresentation else {
            showStatus(status)
            return
        }
        if let last = statusQueue.last {
            if Self.sameStatus(last, status) {
                statusQueue[statusQueue.count - 1] = status
            } else {
                statusQueue.append(status)
            }
        } else if Self.sameStatus(shown, status) {
            showStatus(status)
            return
        } else {
            statusQueue.append(status)
        }
        guard statusPump == nil else { return }
        statusPump = Task {
            while !statusQueue.isEmpty {
                let remaining = Self.minimumStatusTime - (ContinuousClock.now - shownAt)
                if remaining > .zero { try? await Task.sleep(for: remaining) }
                showStatus(statusQueue.removeFirst())
            }
            statusPump = nil
        }
    }

    private func showStatus(_ status: AppPresentationState) {
        withAnimation(Self.statusFade) { shownPresentation = status }
        shownAt = .now
    }

    /// The same status with a different count: equal up to any "(…)".
    private static func sameStatus(_ a: AppPresentationState,
                                   _ b: AppPresentationState) -> Bool {
        func stem(_ label: String) -> Substring {
            label.split(separator: "(", maxSplits: 1).first ?? Substring(label)
        }
        return a.severity == b.severity
            && a.primaryAction == b.primaryAction
            && stem(a.label) == stem(b.label)
    }

    /// Read-only status, so it is content and not a control: no glass, no
    /// `.interactive()`, and no press affordance. The action beside it is the
    /// control.
    private func statusPill(_ presentation: AppPresentationState) -> some View {
        HStack(spacing: 6) {
            if presentation.showsActivity {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(color(for: presentation.severity))
                    .frame(width: 7, height: 7)
            }
            Text(presentation.label)
                .font(.caption)
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(.hudStatus)
    }

    private func color(for severity: AppPresentationSeverity) -> Color {
        switch severity {
        case .neutral: .secondary
        case .active: .accentColor
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    private func actionLabel(_ action: AppModelAction) -> String {
        switch action {
        case .install: "Install"
        case .cancelInstall: "Cancel"
        case .load: "Load"
        case .retryLoad: "Retry"
        case .cancelLoad: "Cancel"
        case .reload: "Reload"
        case .unload: "Unload"
        }
    }

    // MARK: - Empty and error states

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(model.error?.userMessage ?? "")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.error = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
            .accessibilityIdentifier(.bannerErrorDismiss)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// An empty chat with no model on the phone: where to get one, and a way
/// there. A chat with turns in it shows them instead, model or not.
private struct NoModelView: View {
    let model: AppModel
    let openModels: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings", action: openModels)
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var name: String { model.installDescriptor.shortName }

    /// Another model is on the phone while this one is not: a download the
    /// user started from Settings, running or paused.
    private var hasOtherModel: Bool {
        model.availableModels.contains { ChatSession.isInstalled($0, current: model) }
    }

    private var title: String {
        if model.isInstallingModel { return "\(name) is downloading" }
        return hasOtherModel ? "\(name) is not downloaded" : "No model on this iPhone"
    }

    private var message: String {
        if model.isInstallingModel {
            return "You can chat once it finishes. Its progress is in Settings, "
                + "under Models."
        }
        return hasOtherModel
            ? "Pick another model in the menu below the message box, or finish "
                + "this download in Settings, under Models."
            : "Download a model in Settings, under Models. It runs on this "
                + "iPhone, offline."
    }
}

/// The menu button's icon: two long lines over a short one, left-aligned.
private struct MenuGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4.25) {
            Capsule().frame(width: 19, height: 2)
            Capsule().frame(width: 19, height: 2)
            Capsule().frame(width: 10, height: 2)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
