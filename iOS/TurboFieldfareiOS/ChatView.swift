import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// The chat screen: status, transcript, composer.
///
/// Every decision about what the status row may say and which lifecycle action
/// it may offer comes from `AppPresentationState.resolve`, shared with the Mac.
/// Re-deriving that here is how a platform ends up offering a fully enabled
/// button that does nothing — the case its own comments record.
struct ChatView: View {
    let model: AppModel
    let network: DownloadNetwork

    @State private var blocks = StreamingBlocks()
    @State private var thinkingBlocks = StreamingBlocks(.reasoning)
    @State private var isShowingSettings = false
    @State private var isShowingHistory = false
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            if model.requiresModelInstallation {
                ModelDownloadView(model: model, network: network)
            } else {
                ChatTranscriptView(model: model,
                                   blocks: blocks,
                                   thinkingBlocks: thinkingBlocks)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
            ChatComposer(model: model)
        }
        .background(Color(uiColor: .systemBackground))
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
        .sheet(isPresented: $isShowingHistory) {
            HistoryView(model: model)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(model: model)
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        let presentation = model.presentation
        return HStack(spacing: 10) {
            Button {
                isShowingHistory = true
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
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

            // `.install` and `.cancelInstall` are dropped deliberately. There
            // is no in-app installer on iOS: `perform(.install)` would start a
            // 14.3 GB download into the app container, and the model is
            // side-loaded instead — which is what the empty state below says.
            // Offering it anyway is the failure `AppPresentationState`'s own
            // comments describe, one step worse: not a control that does
            // nothing, but one that starts something the port does not support.
            // The load actions are kept, `.cancelLoad` included, because a load
            // takes minutes and is worth being able to abandon.
            if let action = presentation.primaryAction,
               action != .install, action != .cancelInstall {
                Button(actionLabel(action)) { model.perform(action) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityIdentifier(.bannerModelAction)
            }

            // Applies to the next turn, not the one in flight: `makeRequest`
            // reads the flag at send time. Deliberately left enabled during a
            // run — it changes the token sequence a turn pins, so taking effect
            // mid-turn is the behaviour to avoid, not the behaviour to offer.
            Button {
                model.enableThinking.toggle()
            } label: {
                Image(systemName: "brain")
                    .foregroundStyle(model.enableThinking ? Color.accentColor : .secondary)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .accessibilityLabel("Reasoning")
            .accessibilityValue(model.enableThinking ? "On" : "Off")
            .accessibilityIdentifier(.composerThinking)

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .accessibilityLabel("Settings")

            if model.canStartNewChat {
                Button {
                    model.newChat()
                    blocks.reset()
                    thinkingBlocks.reset()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("New chat")
                .accessibilityIdentifier(.stripNewChat)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                .foregroundStyle(.secondary)
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
