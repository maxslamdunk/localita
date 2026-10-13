import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// What a new user needs before the first chat, in four pages: what the app
/// is, the download, what to expect of it, and what leaving the app does to a
/// reply. It ends on the way to a model.
///
/// It opens by itself on a launch with no model on the phone, until it has
/// been seen once, and again from Settings. It explains the app rather than
/// pointing at its controls: the chat itself is like any other.
///
/// Memory is left out on purpose. At the default 24 slots the app peaks at
/// about 3.1–3.4 GB of 8 (2026-09-24 rows in `MEASUREMENTS.md`), and other
/// apps were only seen closing with it near 3.9 GB. The memory trade belongs
/// beside the slots control, where it is chosen.
struct WelcomeView: View {
    let model: AppModel
    let network: DownloadNetwork
    /// Closes the welcome; true when Settings → Models should open next.
    let finish: (_ openModels: Bool) -> Void

    @State private var page = 0
    @State private var isAskingAboutMobileData = false

    private static let seenKey = "welcomeSeen"

    /// A first launch: no model anywhere on the phone, and the welcome never
    /// closed. The device checks drive the app by launch argument and must not
    /// have it in front of them.
    static func opensAtLaunch(_ model: AppModel) -> Bool {
        guard !UserDefaults.standard.bool(forKey: seenKey),
              !ModelSwitchCheck.isRequested,
              !BackgroundGenerationCheck.isRequested else { return false }
        return !model.availableModels.contains { ChatSession.isInstalled($0, current: model) }
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finish(false) }
                    .opacity(isLastPage ? 0 : 1)
                    .disabled(isLastPage)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    PageView(page: pages[index]).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots.padding(.bottom, 20)
            controls
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: 480)
        }
        .background(Color(uiColor: .systemBackground))
        .confirmationDialog(
            "Download \(MetricFormat.storage(descriptor.approximateDownloadBytes)) over mobile data?",
            isPresented: $isAskingAboutMobileData,
            titleVisibility: .visible
        ) {
            Button("Use Mobile Data") { download(allowingMobileData: true) }
            Button("Wait for Wi-Fi") { download(allowingMobileData: false) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("This iPhone is not on Wi-Fi. \(descriptor.shortName) is "
                 + "\(MetricFormat.storage(descriptor.approximateDownloadBytes)), which "
                 + "can use up most data plans.")
        }
    }

    // MARK: - Pages

    private struct Page {
        let symbol: String
        let title: String
        let text: String
        var note: String?
    }

    /// The numbers come from the model's own description, so they stay right
    /// when the model changes.
    private var pages: [Page] {
        let gemma = AppModelInstallDescriptor.default
        return [
            Page(symbol: "lock.iphone",
                 title: "A large AI model, running on your iPhone",
                 text: "Gemma 4, Google's 26-billion-parameter model, runs entirely "
                     + "on this phone. What you type and the photos you share "
                     + "never leave it, and it works without a connection."),
            Page(symbol: "arrow.down.circle",
                 title: "One download, about "
                     + MetricFormat.storage(gemma.approximateDownloadBytes),
                 text: "The model is downloaded once and stays on the iPhone. It "
                     + "uses Wi-Fi only unless you allow mobile data, keeps going "
                     + "in the background, and picks up where it left off if it "
                     + "stops.",
                 note: "Needs " + MetricFormat.storage(gemma.requiredFreeBytes)
                     + " of free storage."),
            Page(symbol: "gauge.with.dots.needle.33percent",
                 title: "Slower than a cloud chatbot, and that's the trade",
                 text: "Replies come at roughly reading pace and slow down a little "
                     + "in long chats. The first reply takes a moment while the "
                     + "model loads. The phone can get warm during long replies, "
                     + "and it slows down a bit when it does."),
            Page(symbol: "pip",
                 title: "Replies keep going when you switch apps",
                 text: "Leave mid-reply and it continues in a small Picture in "
                     + "Picture window. Locking the phone pauses it, and it "
                     + "resumes when you unlock.",
                 note: "You can turn this off in Settings."),
        ]
    }

    private struct PageView: View {
        let page: Page

        var body: some View {
            // Scrolls only when the text outgrows the screen, at the largest
            // text sizes; otherwise it sits centred.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: page.symbol)
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                            .padding(.bottom, 8)
                        Text(page.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(page.text)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if let note = page.note {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 32)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
    }

    // MARK: - Ending

    private var isLastPage: Bool { page == pages.count - 1 }

    private var descriptor: AppModelInstallDescriptor { model.installDescriptor }

    private enum Ending { case close, download, openModels }

    /// What the last page offers, from where the phone stands: a model to
    /// chat with, one on its way, or the download.
    private var ending: (title: String, action: Ending) {
        if model.availableModels.contains(where: { ChatSession.isInstalled($0, current: model) }) {
            return ("Start Chatting", .close)
        }
        if model.isInstallingModel { return ("Continue", .close) }
        // Settings says why a download cannot start, such as too little free
        // storage, and runs the switch to another model.
        if model.canInstallModel { return ("Download \(descriptor.shortName)", .download) }
        return ("Open Models", .openModels)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                if isLastPage {
                    run(ending.action)
                } else {
                    withAnimation { page += 1 }
                }
            } label: {
                Text(isLastPage ? ending.title : "Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            // Always laid out, so the main button does not move on the last page.
            Button("Not Now") { finish(false) }
                .opacity(isLastPage && ending.action != .close ? 1 : 0)
                .disabled(!(isLastPage && ending.action != .close))
        }
    }

    private func run(_ action: Ending) {
        switch action {
        case .close: finish(false)
        case .openModels: finish(true)
        case .download:
            // Asks about mobile data first, as Settings does.
            if network.isExpensive && !network.allowsMobileData {
                isAskingAboutMobileData = true
            } else {
                download(allowingMobileData: network.allowsMobileData)
            }
        }
    }

    private func download(allowingMobileData: Bool) {
        // The phone may have changed under the welcome; Settings then says why.
        guard model.canInstallModel else { return finish(true) }
        BackgroundDownload.start(model, network: network,
                                 allowingMobileData: allowingMobileData)
        finish(false)
    }
}
