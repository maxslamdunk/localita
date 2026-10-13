import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// Sampling, memory and model controls, as a sheet with two tabs.
///
/// **Generation** holds what shapes replies: memory, then sampling, then a
/// reset for both. **Models** holds what is on the phone: every stored model,
/// image support and the benchmark. There is no Load or Unload here: the chat
/// screen has both, and the steps below that need the model out of memory
/// unload it themselves. The model's path and the app's footprint are logged
/// to `Documents/app-memory.log` (`TurnMemoryLog`) instead of shown. The tab bar is the
/// system's; a paged `TabView` was tried first and lost the forms' scroll
/// edge effect under the title bar.
///
/// The Mac's `InspectorView` is the reference for the bindings. The option
/// lists are the phone's own, because the phone measured differently. It
/// offers only what the device has been shown to hold:
///
/// - **Context stops at 8K.** On 2026-09-24, 16K at 32 slots was killed once
///   and completed once in the same memory state
///   (`benchmark-results-2026-09-24-ios-context/`), so it is not a setting.
/// - **Slots are 16, 24 and 32**, the three counts measured on this phone
///   (2026-09-16). 8 was never run here.
///
/// The default is 24, not the fastest 32: at 32 the app rests at about 4.1 GB,
/// and the system photo picker could not open beside it without the app being
/// killed (2026-09-24). Memory labels are relative to that default.
struct SettingsView: View {
    @Bindable var model: AppModel
    let network: DownloadNetwork
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReset = false
    @State private var pendingDeletion: AppModelInstallDescriptor?
    @State private var deletionError: String?
    /// The tab on screen. Owned by the chat screen, which opens Settings on
    /// Models when the way here was about getting a model.
    @Binding var page: Page
    @State private var isAddingModel = false
    /// The model whose info sheet is open.
    @State private var infoModel: AppModelInstallDescriptor?
    /// A download waiting on the answer to "use mobile data?".
    @State private var pendingDownload: AppModelInstallDescriptor?
    @State private var isConfirmingVisionRemoval = false
    @State private var isShowingHarness = false
    /// The step waiting for the unload `start(_:)` began.
    @State private var afterUnload: UnloadedStep?

    enum Page: Hashable { case generation, models }


    /// Context sizes this phone may offer. See the type comment.
    static let contextOptions: [AppContextLengthOption] = [.fourK, .eightK]

    /// Slot counts measured on this phone, with what each measured. The
    /// throughput is the 2026-09-16 short case at 4K. It says how the options
    /// compare, not what any given chat will reach.
    static let slotOptions: [(slots: Int, label: String)] = [
        (16, "16 · about 4.4 tok/s · −0.8 GB"),
        (24, "24 · about 6.0 tok/s · default"),
        (32, "32 · about 7.0 tok/s · +0.8 GB"),
    ]

    var body: some View {
        // One stack around both tabs, not one per tab: with a bar per tab,
        // the scroll edge effect under it blinked off on every switch. The
        // tab bar names the page, so the title bar carries only Done.
        NavigationStack {
            TabView(selection: $page) {
                Tab("Generation", systemImage: "slider.horizontal.3", value: Page.generation) {
                    Form {
                        memorySection
                        generationSection
                        backgroundSection
                        resetSection
                    }
                }
                Tab("Models", systemImage: "square.stack.3d.up", value: Page.models) {
                    Form {
                        modelsSection
                        // A text-only model has no image pack to download, and
                        // a pack is for a model that is on the phone.
                        if model.installDescriptor.supportsImages, model.isModelInstalled {
                            imageSection
                        }
                        harnessSection
                    }
                }
            }
            // Both forms are short enough that the thumb only adds noise.
            .scrollIndicators(.never)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $isShowingHarness) { harness }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isAddingModel) {
            // An added model joins the list below on its own; there is
            // nothing to pick here.
            AddModelView(model: model) { _ in }
        }
        .sheet(isPresented: Binding(get: { infoModel != nil },
                                    set: { if !$0 { infoModel = nil } })) {
            if let infoModel { info(infoModel) }
        }
        .onChange(of: model.loadState) { _, state in
            guard state == .notLoaded, let step = afterUnload else { return }
            afterUnload = nil
            run(step)
        }
        // Asked here rather than through `requestVisionPackRemoval`, which
        // refuses while the model is loaded: the unload comes after the yes.
        .confirmationDialog("Remove image support?",
                            isPresented: $isConfirmingVisionRemoval,
                            titleVisibility: .visible) {
            Button("Remove Image Support", role: .destructive) {
                start(.removeVision)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Text chats keep working. Getting images back means "
                 + "downloading the pack again.")
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.shortName ?? "model")?",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { descriptor in
            Button("Delete", role: .destructive) { start(.deleteModel(descriptor)) }
            Button("Cancel", role: .cancel) {}
        } message: { descriptor in
            Text(deletionMessage(descriptor))
        }
        .confirmationDialog(
            "Download \(pendingDownload.map { MetricFormat.storage($0.approximateDownloadBytes) } ?? "the model") over mobile data?",
            isPresented: Binding(get: { pendingDownload != nil },
                                 set: { if !$0 { pendingDownload = nil } }),
            titleVisibility: .visible,
            presenting: pendingDownload
        ) { descriptor in
            Button("Use Mobile Data") { download(descriptor, allowingMobileData: true) }
            Button("Wait for Wi-Fi") { download(descriptor, allowingMobileData: false) }
            Button("Not Now", role: .cancel) {}
        } message: { descriptor in
            Text("This iPhone is not on Wi-Fi. \(descriptor.shortName) is "
                 + "\(MetricFormat.storage(descriptor.approximateDownloadBytes)), which "
                 + "can use up most data plans.")
        }
    }

    // MARK: - Generation

    /// Applies to the next turn: `makeRequest` reads these at send time, and
    /// none of them is part of `AppLoadedRuntimeKey`.
    private var generationSection: some View {
        Section {
            described("How random the choice of each next word is. Lower gives "
                      + "focused, repeatable replies; higher gives more varied "
                      + "ones, and more mistakes. 0 always takes the most likely "
                      + "word.") {
                LabeledContent("Temperature") {
                    HStack(spacing: 8) {
                        Slider(value: $model.temperature, in: 0...2, step: 0.05)
                            .accessibilityIdentifier(.inspectorTemperature)
                        Text(model.temperature, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            described("Only the K most likely next words are considered. A "
                      + "smaller K keeps replies safe and predictable; a larger K "
                      + "lets rarer words in. Off considers every word.") {
                Toggle("Top-K", isOn: $model.topKEnabled)
                    .accessibilityIdentifier(.inspectorTopK)
            }
            if model.topKEnabled {
                Stepper(value: $model.topK, in: 1...256) {
                    LabeledContent("K", value: "\(model.topK)")
                }
                .accessibilityIdentifier(.inspectorTopKValue)
            }
            // Top-P sits under Top-K in the sampler, so it is only offered
            // while Top-K is on, as on the Mac.
            described("Keeps only the most likely words whose chances add up to "
                      + "P. Lower P drops unlikely words and tightens replies; 1 "
                      + "keeps them all. Needs Top-K on.") {
                Toggle("Top-P", isOn: $model.topPEnabled)
                    .disabled(!model.topKEnabled)
                    .accessibilityIdentifier(.inspectorTopP)
            }
            if model.topKEnabled && model.topPEnabled {
                LabeledContent("P") {
                    HStack(spacing: 8) {
                        Slider(value: $model.topP, in: 0.01...1, step: 0.01)
                            .accessibilityIdentifier(.inspectorTopPValue)
                        Text(model.topP, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("Sampling")
        } footer: {
            Text("These apply to the next message.")
        }
        .disabled(model.isRunning)
    }

    // MARK: - Background

    /// Through the setter, so the choice is saved with the other settings.
    private var backgroundBinding: Binding<Bool> {
        Binding { model.backgroundGeneration } set: { model.setBackgroundGeneration($0) }
    }

    /// iOS lets a backgrounded app use the GPU only while it shows Picture in
    /// Picture, and no app once the phone locks (2026-10-09 probes). So a
    /// reply carries on in a small window, and a lock pauses it.
    private var backgroundSection: some View {
        Section {
            described("When you leave the app mid-reply, the reply keeps "
                      + "generating in a small floating window that shows its "
                      + "text. Locking the phone, or closing the window, pauses "
                      + "it; it picks up again when you unlock or come back. "
                      + "Off stops the reply when you leave, keeping what it "
                      + "wrote.") {
                Toggle("Keep generating in background", isOn: backgroundBinding)
            }
        } header: {
            Text("Background")
        }
    }

    // MARK: - Memory

    /// Through `setMaxContextTokens` rather than a plain binding, so a stored
    /// conversation on screen is redrawn against the new context.
    private var contextBinding: Binding<Int> {
        Binding { model.maxContextTokens } set: { model.setMaxContextTokens($0) }
    }

    private var memorySection: some View {
        Section {
            described("The most one chat can hold: your messages and the replies "
                      + "together, in tokens of about ¾ of a word. Larger lets a "
                      + "chat run longer before its earliest turns drop out of "
                      + "the model's view. Memory grows only as the chat does.") {
                Picker("Context", selection: contextBinding) {
                    ForEach(Self.contextOptions) { option in
                        Text(option == .eightK ? "8K · default" : option.shortLabel)
                            .tag(option.tokens)
                    }
                    // A settings file from before this sheet, or from the Mac,
                    // may hold a size the phone does not offer. Shown rather
                    // than hidden, so the picker never displays a value it
                    // cannot hold.
                    if !Self.contextOptions.map(\.tokens).contains(model.maxContextTokens) {
                        Text("\(model.maxContextTokens / 1_024)K · not offered here")
                            .tag(model.maxContextTokens)
                    }
                }
                .accessibilityIdentifier(.inspectorContext)
            }

            described("How many of the model's experts each layer keeps in "
                      + "memory. More slots mean fewer reads from storage, so "
                      + "faster replies, but more RAM, which can make the rest of "
                      + "the phone sluggish while a reply is written.") {
                Picker("Expert slots", selection: $model.runtimeOptions.expertCacheSlots) {
                    ForEach(Self.slotOptions, id: \.slots) { option in
                        Text(option.label).tag(option.slots)
                    }
                    if !Self.slotOptions.map(\.slots).contains(model.runtimeOptions.expertCacheSlots) {
                        Text("\(model.runtimeOptions.expertCacheSlots) · not offered here")
                            .tag(model.runtimeOptions.expertCacheSlots)
                    }
                }
                .accessibilityIdentifier(.inspectorSlots)
            }

            if model.hasStaleLoadedRuntime {
                Button("Reload Model to Apply") { model.perform(.reload) }
                    .disabled(!model.canReloadModel)
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("Both apply after the model reloads.")
        }
        .disabled(model.isRunning || model.loadState.isLoading)
    }

    // MARK: - Image support

    /// The Mac inspector's Image Support section, which is the reference for
    /// every state below. The pack downloads from Hugging Face into the app
    /// container, beside the model, and only while the app is in front: the
    /// idle timer is held off for it (`TurboFieldfareApp.keepsScreenOn`).
    private var imageSection: some View {
        Section {
            LabeledContent("State", value: visionStatusLabel)
            if model.isVisionRuntimeSupported && !model.isVisionPackInstalled {
                LabeledContent("Download", value: MetricFormat.storage(
                    model.visionInstallDescriptor.approximateDownloadBytes))
            }
            if let fraction = model.visionInstallProgressFraction {
                ProgressView(value: fraction)
                HStack {
                    Text(MetricFormat.percent(fraction * 100))
                    Spacer()
                    if let eta = model.visionInstallETAText { Text(eta) }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if model.isInstallingVisionPack {
                ProgressView()
            }
            if let note = visionNote {
                Text(note.text)
                    .font(.footnote)
                    .foregroundStyle(note.color)
            }
            visionActions
        } header: {
            Text("Image Support")
        } footer: {
            Text("Lets you attach photos to a message, for the model the app is "
                 + "on. Other models use Gemma 4's download. Keep the app open while "
                 + "it downloads; leaving pauses it, and it resumes from where "
                 + "it stopped.")
        }
    }

    @ViewBuilder
    private var visionActions: some View {
        if model.isInstallingVisionPack {
            Button("Cancel Download", action: model.cancelVisionInstall)
                .disabled(!model.canCancelVisionInstall)
                .accessibilityIdentifier(.visionCancel)
        } else if case .readyToActivate = model.visionInstallState {
            if model.isVisionRuntimeSupported {
                Button("Activate") { start(.activateVision) }
                    .disabled(!canStartUnloaded)
                    .accessibilityIdentifier(.visionActivate)
            }
            Button("Discard Download", role: .destructive) {
                start(.discardVision)
            }
            .disabled(!(model.hasPartialVisionPackDownload && canStartUnloaded))
            .accessibilityIdentifier(.visionDiscard)
        } else if model.isVisionPackInstalled {
            Button("Remove Image Support", role: .destructive) {
                isConfirmingVisionRemoval = true
            }
            .disabled(!(model.hasVisionPackDirectory && canStartUnloaded))
            .accessibilityIdentifier(.visionRemove)
        } else {
            if model.isVisionRuntimeSupported {
                Button(visionInstallButtonLabel) { model.installVisionPack() }
                    .disabled(!model.canInstallVisionPack)
                    .accessibilityIdentifier(.visionInstall)
            }
            if model.hasPartialVisionPackDownload {
                Button("Discard Download", role: .destructive) {
                    start(.discardVision)
                }
                .disabled(!(model.hasPartialVisionPackDownload && canStartUnloaded))
                .accessibilityIdentifier(.visionDiscard)
            }
            if model.hasVisionPackDirectory {
                Button("Remove", role: .destructive) {
                    isConfirmingVisionRemoval = true
                }
                .disabled(!(model.hasVisionPackDirectory && canStartUnloaded))
                .accessibilityIdentifier(.visionRemove)
            }
        }
    }

    private var visionInstallButtonLabel: String {
        if model.hasPartialVisionPackDownload { return "Resume Download" }
        if model.hasVisionPackDirectory { return "Repair" }
        return "Download Image Support"
    }

    private var visionStatusLabel: String {
        guard model.isVisionRuntimeSupported else { return "Not supported" }
        if model.visionInstallState != .idle { return model.visionInstallPhaseLabel }
        switch model.visionInstallationStatus {
        case .missing: return "Not installed"
        case .partial: return "Needs repair"
        case .complete: return "Installed"
        case .unsupportedLayout: return "Not available for this model"
        }
    }

    /// One explanatory line, in the Mac's order of precedence.
    private var visionNote: (text: String, color: Color)? {
        if !model.isVisionRuntimeSupported {
            return ("This iPhone's GPU cannot run the image model. Text chats "
                    + "are unaffected.", .secondary)
        }
        if case .failed(let message) = model.visionInstallState { return (message, .red) }
        if case .recoverable(let message) = model.visionInstallState {
            return (message, .orange)
        }
        if case .partial(let message) = model.visionInstallationStatus,
           !model.isInstallingVisionPack {
            return (message, .orange)
        }
        if case .unsupportedLayout = model.visionInstallationStatus {
            return ("Image support needs a model folder named “<name>.gturbo”, "
                    + "which is where the pack lives.", .secondary)
        }
        if case .failed(let message) = model.visionInstallReadiness,
           !model.isInstallingVisionPack {
            return (message, .orange)
        }
        if case .insufficientSpace(let requirement) = model.visionInstallReadiness,
           !model.isInstallingVisionPack {
            return ("Free \(MetricFormat.storage(requirement.shortfallBytes)) more "
                    + "storage.", .orange)
        }
        if model.isVisionFilesystemMutationInProgress {
            return ("Model actions wait until this finishes. Your message, "
                    + "images and chat are kept.", .secondary)
        }
        // Downloading runs beside a loaded model; only the steps after it
        // need the model out of memory.
        if model.loadState.isReady, !model.isInstallingVisionPack,
           model.hasVisionPackDirectory || model.hasPartialVisionPackDownload {
            return ("Activating, discarding or removing unloads the model "
                    + "first. Load it again from the chat.", .secondary)
        }
        return nil
    }

    // MARK: - Reset

    /// Asked first, because it discards every choice above at once.
    private var resetSection: some View {
        Section {
            Button("Reset to Defaults", role: .destructive) {
                isConfirmingReset = true
            }
            .confirmationDialog("Reset settings to defaults?",
                                isPresented: $isConfirmingReset,
                                titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    model.resetSettingsToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Temperature 0.20, Top-K 64, Top-P 0.95, 8K context and "
                     + "24 expert slots. If context or slots change, the model "
                     + "needs a reload.")
            }
        } footer: {
            Text("Restores generation and memory settings to what a fresh "
                 + "install starts with. Chats are not affected.")
        }
        .disabled(model.isRunning || model.loadState.isLoading)
    }

    /// A control with what it is and what moving it does, in one row.
    ///
    /// In the row rather than in the section footer, so each description sits
    /// under the control it explains instead of in a paragraph below all of
    /// them.
    private func described<Control: View>(
        _ description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            control()
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Models

    /// Every model the app knows, downloaded or not, with what can be done to
    /// it: download, its progress and cancel, delete, and an info sheet
    /// (`ModelInfoView`). This is the one place
    /// models are downloaded and deleted; the chat's menu only picks among the
    /// downloaded ones.
    ///
    /// A download runs for the model the app is on (`AppModel` has one
    /// installer), so Download on another model switches the app to it first,
    /// unloading the one in memory. One download runs at a time.
    private var modelsSection: some View {
        Section {
            ForEach(model.availableModels, id: \.key) { descriptor in
                modelRow(descriptor)
            }
            if let deletionError {
                Text(deletionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button("Add Model…", systemImage: "plus") { isAddingModel = true }
        } header: {
            Text("Models")
        } footer: {
            Text("A download keeps going if you leave the app or lock the iPhone, "
                 + "with its progress on the Lock Screen. If iOS pauses it, opening "
                 + "the app continues from where it stopped. Community models are "
                 + "added from a Hugging Face link: they run like Gemma 4 but are "
                 + "not tested here.")
        }
    }

    private enum Stored { case installed, partial, none }

    private func stored(_ descriptor: AppModelInstallDescriptor) -> Stored {
        if ChatSession.isInstalled(descriptor, current: model) { return .installed }
        let folder = ModelLocation.directory(named: descriptor.directoryName).path
        let fm = FileManager.default
        if fm.fileExists(atPath: folder + ".partial")
            || fm.fileExists(atPath: folder + ".resume.json")
            || fm.fileExists(atPath: folder) {
            return .partial
        }
        return .none
    }

    private func isDownloading(_ descriptor: AppModelInstallDescriptor) -> Bool {
        descriptor == model.installDescriptor && model.isInstallingModel
    }

    /// Icons rather than words on the right, as the App Store does it: the
    /// info button, then download, or the progress ring that cancels it.
    /// Delete is a swipe here and a button in the info sheet.
    private func modelRow(_ descriptor: AppModelInstallDescriptor) -> some View {
        let state = stored(descriptor)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName)
                    Text(detail(descriptor, state))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    infoModel = descriptor
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("About \(descriptor.shortName)")
                if isDownloading(descriptor) {
                    Button { BackgroundDownload.cancel(model) } label: {
                        DownloadRing(fraction: model.installProgressFraction)
                    }
                    .disabled(!model.canCancelInstall)
                    .accessibilityLabel("Stop download")
                } else if state != .installed {
                    Button { requestDownload(descriptor) } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .disabled(!canDownload(descriptor))
                    .accessibilityLabel(state == .partial ? "Resume download" : "Download")
                }
            }
            .font(.title2)
            .buttonStyle(.borderless)
            if descriptor == model.installDescriptor, state != .installed {
                downloadStatus
            }
        }
        .swipeActions(edge: .trailing) {
            if state != .none {
                // Tinted rather than `.destructive`, which would animate the
                // row away before the confirmation is answered.
                Button("Delete") { pendingDeletion = descriptor }
                    .tint(.red)
                    .disabled(!canDelete(descriptor))
            }
        }
    }

    private func info(_ descriptor: AppModelInstallDescriptor) -> some View {
        let state = stored(descriptor)
        let storedLabel = switch state {
        case .installed: "Downloaded"
        case .partial: "Part-downloaded"
        case .none: "Not downloaded"
        }
        return ModelInfoView(
            descriptor: descriptor,
            storedLabel: storedLabel,
            deletion: state == .none ? nil : .init(
                isEnabled: canDelete(descriptor),
                message: deletionMessage(descriptor),
                perform: {
                    infoModel = nil
                    start(.deleteModel(descriptor))
                }))
    }

    private func detail(_ descriptor: AppModelInstallDescriptor, _ state: Stored) -> String {
        var parts: [String] = []
        if descriptor.isCommunity { parts.append("Community") }
        switch state {
        case .installed: parts.append(MetricFormat.storage(descriptor.installedBytes))
        case .partial: parts.append("Part-downloaded")
        case .none:
            parts.append(MetricFormat.storage(descriptor.approximateDownloadBytes) + " download")
        }
        if !descriptor.supportsImages { parts.append("Text only") }
        return parts.joined(separator: " · ")
    }

    /// Progress and anything in the download's way, for the model the app is
    /// on. Only that one has an installer to ask.
    @ViewBuilder
    private var downloadStatus: some View {
        if model.isInstallingModel {
            // The row's ring shows the fraction; this is the words for it.
            if let fraction = model.installProgressFraction,
               let downloaded = model.installDownloadedBytes,
               let total = model.installTotalBytes {
                HStack {
                    Text("\(MetricFormat.storage(downloaded)) of "
                         + MetricFormat.storage(total))
                    Spacer()
                    Text(model.installETAText ?? MetricFormat.percent(fraction * 100))
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.presentation.label)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let waiting = network.waitingReason {
                Label(waiting, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } else if let note = downloadNote {
            Text(note.text)
                .font(.footnote)
                .foregroundStyle(note.color)
        }
    }

    private var downloadNote: (text: String, color: Color)? {
        if case .failed(let message) = model.installState { return (message, .red) }
        if case .recoverable(let message) = model.installState { return (message, .orange) }
        if case .insufficientSpace(let requirement) = model.installReadiness {
            return ("Free \(MetricFormat.storage(requirement.shortfallBytes)) more storage "
                    + "to download it.", .orange)
        }
        if case .failed(let message) = model.installReadiness { return (message, .red) }
        if case .cancelled = model.installState { return ("Download paused.", .secondary) }
        // The probe's reason is the only account of a model that is present
        // but unusable.
        if case .partial(let reason) = model.installationStatus,
           !model.hasPartialModelDownload {
            return (reason, .orange)
        }
        return nil
    }

    /// One download at a time, and not while a reply or a load is running.
    private func canDownload(_ descriptor: AppModelInstallDescriptor) -> Bool {
        guard !model.isInstallingModel, !model.isRunning, !model.loadState.isLoading,
              model.canSelectModel else { return false }
        if descriptor == model.installDescriptor { return model.canInstallModel }
        return !model.loadState.isReady || model.canUnloadModel
    }

    private func canDelete(_ descriptor: AppModelInstallDescriptor) -> Bool {
        guard !isDownloading(descriptor), !model.isRunning, !model.loadState.isLoading,
              model.canSelectModel else { return false }
        return !(model.loadState.isReady && needsUnload(.deleteModel(descriptor)))
            || model.canUnloadModel
    }

    /// Asks about mobile data first: a model is about 14.6 GB.
    private func requestDownload(_ descriptor: AppModelInstallDescriptor) {
        if network.isExpensive && !network.allowsMobileData {
            pendingDownload = descriptor
        } else {
            download(descriptor, allowingMobileData: network.allowsMobileData)
        }
    }

    private func download(_ descriptor: AppModelInstallDescriptor, allowingMobileData: Bool) {
        start(.download(descriptor, allowingMobileData: allowingMobileData))
    }

    /// The models on the phone after this one in the list, wrapping round:
    /// where the app goes when the model it is on is deleted.
    private func nextDownloaded(after descriptor: AppModelInstallDescriptor)
        -> AppModelInstallDescriptor? {
        let list = model.availableModels
        guard let index = list.firstIndex(of: descriptor) else { return nil }
        return (list[(index + 1)...] + list[..<index])
            .first { ChatSession.isInstalled($0, current: model) }
    }

    /// Downloaded models that read their image pack from this one's folder.
    private func imageBorrowers(of descriptor: AppModelInstallDescriptor)
        -> [AppModelInstallDescriptor] {
        model.availableModels.filter { other in
            other != descriptor && ChatSession.isInstalled(other, current: model)
                && AppVisionPackHost.textModelDirectory(
                    for: ModelLocation.directory(named: other.directoryName))
                    .lastPathComponent == descriptor.directoryName
        }
    }

    private func deletionMessage(_ descriptor: AppModelInstallDescriptor) -> String {
        var lines = [descriptor.isCommunity
                     ? "Its download is removed and it leaves the list."
                     : "Its download is removed. It stays in the list, to download again."]
        let borrowers = imageBorrowers(of: descriptor)
        if !borrowers.isEmpty {
            lines.append(borrowers.map(\.shortName).joined(separator: " and ")
                         + " loses image support too.")
        }
        if descriptor == model.installDescriptor {
            if let next = nextDownloaded(after: descriptor) {
                lines.append("Chats continue with \(next.shortName).")
            } else {
                lines.append("No model will be left on this iPhone.")
            }
        }
        lines.append("Chats are kept.")
        return lines.joined(separator: " ")
    }

    private func delete(_ descriptor: AppModelInstallDescriptor) {
        do {
            try model.deleteModel(descriptor)
            BackgroundDownload.forget(folder: descriptor.directoryName)
            deletionError = nil
        } catch {
            deletionError = "\(descriptor.shortName) could not be deleted: \(error)"
        }
    }

    // MARK: - Harness

    private var harnessSection: some View {
        Section {
            // A button styled as a link, because opening it may first have to
            // unload the chat model.
            Button { start(.openHarness) } label: {
                HStack {
                    Text("Benchmark").foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(model.loadState.isLoading
                      || (model.loadState.isReady && !model.canUnloadModel))
        } footer: {
            Text("Measure how fast this iPhone runs the model, and help tune the "
                 + "app for it. Opening it unloads the chat model.")
        }
    }

    // MARK: - Steps that need the model unloaded

    /// Pack activation, discard and removal rename files the loaded runtime
    /// maps (`canBeginVisionCompanionOperation`), and the benchmark loads a
    /// second copy of the model. A download switches the app to another
    /// model, and `installModel` refuses while one is unloading. Deleting the
    /// model in memory, or the one whose image pack it reads, removes files
    /// it maps. Each unloads the chat model first.
    private enum UnloadedStep {
        case activateVision, discardVision, removeVision, openHarness
        case download(AppModelInstallDescriptor, allowingMobileData: Bool)
        case deleteModel(AppModelInstallDescriptor)
    }

    private func needsUnload(_ step: UnloadedStep) -> Bool {
        switch step {
        case .deleteModel(let descriptor):
            descriptor == model.installDescriptor || model.hostsCurrentImagePack(descriptor)
        case .download(let descriptor, _):
            descriptor != model.installDescriptor
        case .activateVision, .discardVision, .removeVision, .openHarness:
            true
        }
    }

    /// Runs the step now, or unloads and runs it when `loadState` reaches
    /// `.notLoaded`.
    private func start(_ step: UnloadedStep) {
        guard model.loadState.isReady, needsUnload(step) else { return run(step) }
        guard model.canUnloadModel else { return }
        afterUnload = step
        model.unloadModel()
    }

    private func run(_ step: UnloadedStep) {
        switch step {
        case .activateVision: model.activateVisionPack()
        case .discardVision: model.discardVisionPackDownload()
        case .removeVision: model.removeVisionPack()
        case .openHarness: isShowingHarness = true
        case .download(let descriptor, let allowingMobileData):
            // The chat on screen stays on screen across the switch.
            ChatSession.selectModel(descriptor, in: model,
                                    openingConversation: model.history.selection)
            guard model.installDescriptor == descriptor else { return }
            BackgroundDownload.start(model, network: network,
                                     allowingMobileData: allowingMobileData)
        case .deleteModel(let descriptor):
            if descriptor == model.installDescriptor {
                // Never delete the folder the app points at: move to the next
                // model on the phone, or, with none left, to another listed one,
                // which leaves the chat showing that there is no model.
                guard let next = nextDownloaded(after: descriptor)
                        ?? model.availableModels.first(where: { $0 != descriptor })
                else { return }
                ChatSession.selectModel(next, in: model,
                                        openingConversation: model.history.selection)
                guard model.installDescriptor == next else {
                    deletionError = "\(descriptor.shortName) could not be deleted: "
                        + "the app could not switch away from it."
                    return
                }
            }
            delete(descriptor)
        }
    }

    /// The pack gate, counting the unload `start(_:)` does first: what
    /// `canBeginVisionCompanionOperation` asks, less "not loaded".
    private var canStartUnloaded: Bool {
        model.canBeginVisionCompanionOperation
            || (model.canUnloadModel && !model.isRunning && !model.isInstallingModel
                && !model.isVisionCompanionOperationInProgress)
    }

    private var harness: some View {
        BenchmarkView(model: model)
    }
}

/// A download's progress as a ring around a stop square, the App Store's
/// sign for "downloading, tap to stop". A spinner until the size is known.
private struct DownloadRing: View {
    let fraction: Double?

    var body: some View {
        ZStack {
            if let fraction {
                Circle()
                    .stroke(.tint.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.default, value: fraction)
            } else {
                ProgressView()
            }
            Image(systemName: "stop.fill")
                .font(.system(size: 8))
                .foregroundStyle(.tint)
        }
        .frame(width: 24, height: 24)
    }
}
