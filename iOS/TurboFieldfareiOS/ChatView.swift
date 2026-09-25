import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// The chat screen: status, transcript, composer, with the chats and settings
/// in a side panel (`SideDrawer`) that the menu button or a sideways drag
/// opens.
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
    @State private var isShowingChats = false
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    var body: some View {
        SideDrawer(isOpen: $isShowingChats) {
            chat
        } drawer: {
            HistoryView(model: model,
                        close: { isShowingChats = false },
                        // The panel stays open under the sheet, so closing
                        // Settings goes back to the chats it was opened from.
                        openSettings: { isShowingSettings = true })
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(model: model)
        }
    }

    private var chat: some View {
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
    }

    // MARK: - Status

    private var statusBar: some View {
        let presentation = model.presentation
        return HStack(spacing: 10) {
            Button {
                isShowingChats = true
            } label: {
                MenuGlyph()
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
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

            // `.install` and `.cancelInstall` are dropped deliberately. The
            // download screen owns those: it asks about mobile data before it
            // starts a 14.6 GB download, and a small button here would skip
            // that question. The load actions are kept, `.cancelLoad`
            // included, because a load takes minutes and is worth being able
            // to abandon.
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

/// The menu button's icon: two long lines over a short one, left-aligned.
private struct MenuGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().frame(width: 18, height: 2)
            Capsule().frame(width: 18, height: 2)
            Capsule().frame(width: 10, height: 2)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
