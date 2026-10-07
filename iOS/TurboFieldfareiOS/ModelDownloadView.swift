import Network
import Observation
import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// What the phone's downloads need to know that `AppModel` does not track:
/// which network the phone is on, whether the user agreed to mobile data, and
/// which downloads the app paused itself when it was sent to the background.
@MainActor
@Observable
final class DownloadNetwork {
    /// Mobile data, or a hotspot: what iOS calls expensive.
    private(set) var isExpensive = false
    private(set) var isSatisfied = true

    /// The user's answer to "download over mobile data?", for this launch.
    /// Never assumed: every download starts Wi-Fi-only unless this is set.
    var allowsMobileData = false

    /// Set when leaving the app paused a download, so that coming back
    /// resumes it. A download the user cancelled stays cancelled.
    var resumesModelOnReturn = false
    var resumesImageSupportOnReturn = false

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.isExpensive = expensive
                self?.isSatisfied = satisfied
            }
        }
        monitor.start(queue: .main)
    }

    /// What a paused download is waiting for, if it is waiting at all.
    var waitingReason: String? {
        if !isSatisfied { return "Waiting for a network connection." }
        if isExpensive && !allowsMobileData {
            return "Waiting for Wi-Fi. The download continues when the phone joins one."
        }
        return nil
    }
}

/// Shown in place of the chat when no usable model is installed.
///
/// The Mac's `ModelInstallView` is the reference for every state here. The
/// download is 14.6 GB and keeps running after the app leaves the screen or
/// the phone locks (`BackgroundDownload`); when iOS stops it, it resumes from
/// its last checkpoint the next time the app opens. It never uses mobile data
/// without asking first.
struct ModelDownloadView: View {
    let model: AppModel
    let network: DownloadNetwork

    @State private var isAskingAboutMobileData = false
    @State private var isConfirmingDiscard = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                identity
                storage
                progress
                actions
                Text("You can leave the app or lock the iPhone while it downloads; "
                     + "the progress shows on the Lock Screen. If iOS pauses it, a "
                     + "notification says so, and opening the app continues from "
                     + "where it stopped.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "Download \(downloadSize) over mobile data?",
            isPresented: $isAskingAboutMobileData,
            titleVisibility: .visible
        ) {
            Button("Use Mobile Data") { start(allowingMobileData: true) }
            Button("Wait for Wi-Fi") { start(allowingMobileData: false) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("This iPhone is not on Wi-Fi. The model is \(downloadSize), "
                 + "which can use up most data plans.")
        }
        .confirmationDialog(
            "Discard the saved download?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Download", role: .destructive) {
                BackgroundDownload.discard(model)
            }
            Button("Keep Download", role: .cancel) {}
        } message: {
            Text("What has been downloaded so far will be removed, and the next "
                 + "download starts from the beginning.")
        }
    }

    private var downloadSize: String {
        MetricFormat.storage(model.installDescriptor.approximateDownloadBytes)
    }

    // MARK: - Sections

    private var identity: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Download the model")
                .font(.title2.bold())
            Text("\(model.installDescriptor.displayName) runs on this iPhone, "
                 + "offline. It is a one-time \(downloadSize) download from "
                 + "Hugging Face.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.installDescriptor.isCommunity {
                Text("A community model, added from huggingface.co/"
                     + "\(model.installDescriptor.repoID). It runs like Gemma 4, "
                     + "but its answers are not tested here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !model.installDescriptor.supportsImages {
                Text("This model reads text only; it cannot look at images.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // A model that is present but unusable says why. The probe's reason
            // is the only account of it, and it was once the difference between
            // an empty screen and a one-line fix.
            if case .partial(let reason) = model.installationStatus,
               !model.hasPartialModelDownload {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
    }

    private var storage: some View {
        VStack(spacing: 10) {
            if let requirement = model.installRequirement {
                row("Space required", MetricFormat.storage(requirement.requiredBytes))
                row("Available", MetricFormat.storage(requirement.availableBytes))
                if requirement.canInstall {
                    Label("Enough space", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label("Free \(MetricFormat.storage(requirement.shortfallBytes)) more",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if case .failed(let message) = model.installReadiness {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking available space").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .font(.callout)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: .rect(cornerRadius: 16))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).monospacedDigit()
        }
    }

    @ViewBuilder
    private var progress: some View {
        if model.isInstallingModel {
            VStack(alignment: .leading, spacing: 8) {
                if let fraction = model.installProgressFraction,
                   let downloaded = model.installDownloadedBytes,
                   let total = model.installTotalBytes {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Model download")
                    HStack {
                        Text("\(MetricFormat.storage(downloaded)) of "
                             + MetricFormat.storage(total))
                        Spacer()
                        if let eta = model.installETAText {
                            Text(eta)
                        } else {
                            Text(MetricFormat.percent(fraction * 100))
                        }
                    }
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.presentation.label).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if let waiting = network.waitingReason {
                    Label(waiting, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)
        } else if case .cancelled = model.installState {
            Label("Download paused", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        } else if case .failed(let message) = model.installState {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        } else if case .recoverable(let message) = model.installState {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if model.isInstallingModel {
                Button("Cancel Download") { BackgroundDownload.cancel(model) }
                    .buttonStyle(.bordered)
                    .disabled(!model.canCancelInstall)
            } else {
                Button {
                    if network.isExpensive && !network.allowsMobileData {
                        isAskingAboutMobileData = true
                    } else {
                        start(allowingMobileData: network.allowsMobileData)
                    }
                } label: {
                    Text(model.hasPartialModelDownload ? "Resume Download" : "Download")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canInstallModel)

                HStack(spacing: 12) {
                    // For a model pushed from the Mac while this screen is up.
                    Button("Check Again", action: model.recheckModelAtCurrentLocation)
                    if model.hasPartialModelDownload {
                        Button("Discard Download", role: .destructive) {
                            isConfirmingDiscard = true
                        }
                        .disabled(!model.canDiscardModelDownload)
                    }
                }
                .buttonStyle(.bordered)
            }
            // Picking a model that is not on the phone yet lands here, and this
            // screen replaces the chat, so the way back has to be on it.
            ForEach(installedAlternatives, id: \.key) { descriptor in
                Button("Use \(descriptor.displayName) Instead") {
                    ChatSession.selectModel(descriptor, in: model)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canSelectModel)
            }
        }
    }

    /// The other text models already on the phone.
    private var installedAlternatives: [AppModelInstallDescriptor] {
        model.availableModels.filter {
            $0 != model.installDescriptor && ChatSession.isInstalled($0, current: model)
        }
    }

    private func start(allowingMobileData: Bool) {
        BackgroundDownload.start(model, network: network,
                                 allowingMobileData: allowingMobileData)
    }
}
