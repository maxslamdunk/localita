import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// Sampling, memory and model controls, as a sheet.
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
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReset = false
    @State private var pendingDeletion: AppModelInstallDescriptor?
    @State private var deletionError: String?

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
        NavigationStack {
            Form {
                generationSection
                memorySection
                // A text-only model has no image pack to download.
                if model.installDescriptor.supportsImages {
                    imageSection
                }
                resetSection
                modelSection
                storedModelsSection
                Section {
                    NavigationLink("Benchmark harness") {
                        harness
                    }
                    // The harness loads its own copy of the model. Two copies
                    // cannot fit: one alone holds the phone in compressor churn.
                    .disabled(model.loadState.isReady || model.loadState.isLoading)
                } footer: {
                    Text(model.loadState.isReady || model.loadState.isLoading
                         ? "Unload the model above to run the benchmark. It "
                           + "loads its own copy, and two do not fit."
                         : "The measurement instrument behind the device rows "
                           + "in MEASUREMENTS.md. Not part of chatting.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Remove image support?",
                                isPresented: $model.isConfirmingVisionPackRemoval,
                                titleVisibility: .visible) {
                Button("Remove Image Support", role: .destructive) {
                    model.removeVisionPack()
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
                Button("Delete", role: .destructive) { delete(descriptor) }
                Button("Cancel", role: .cancel) {}
            } message: { descriptor in
                Text(descriptor.isCommunity
                     ? "Its download is removed and it leaves the model menu. "
                       + "Chats are kept."
                     : "Its download is removed. It stays in the model menu, to "
                       + "download again. Chats are kept.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
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
            Text("Generation")
        } footer: {
            Text("These apply to the next message.")
        }
        .disabled(model.isRunning)
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
            Text("Lets you attach photos to a message. Both models use the same "
                 + "download. Keep the app open while "
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
                Button("Activate", action: model.activateVisionPack)
                    .disabled(!model.canActivateVisionPack)
                    .accessibilityIdentifier(.visionActivate)
            }
            Button("Discard Download", role: .destructive) {
                model.discardVisionPackDownload()
            }
            .disabled(!model.canDiscardVisionPackDownload)
            .accessibilityIdentifier(.visionDiscard)
        } else if model.isVisionPackInstalled {
            Button("Remove Image Support", role: .destructive) {
                model.requestVisionPackRemoval()
            }
            .disabled(!model.canRemoveVisionPack)
            .accessibilityIdentifier(.visionRemove)
        } else {
            if model.isVisionRuntimeSupported {
                Button(visionInstallButtonLabel) { model.installVisionPack() }
                    .disabled(!model.canInstallVisionPack)
                    .accessibilityIdentifier(.visionInstall)
            }
            if model.hasPartialVisionPackDownload {
                Button("Discard Download", role: .destructive) {
                    model.discardVisionPackDownload()
                }
                .disabled(!model.canDiscardVisionPackDownload)
                .accessibilityIdentifier(.visionDiscard)
            }
            if model.hasVisionPackDirectory {
                Button("Remove", role: .destructive) {
                    model.requestVisionPackRemoval()
                }
                .disabled(!model.canRemoveVisionPack)
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
        if !model.isVisionPackInstalled && model.loadState.isReady {
            return ("Unload the model below before downloading image support.",
                    .secondary)
        }
        if model.isVisionPackInstalled && model.loadState.isReady {
            return ("Unload the model below before removing image support.",
                    .secondary)
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

    // MARK: - Model

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Model", value: model.installDescriptor.displayName)
            LabeledContent("Status", value: model.presentation.label)
            if let bytes = model.currentProcessMemoryBytes {
                LabeledContent("App memory",
                               value: ByteCountFormatter.string(
                                   fromByteCount: Int64(bytes), countStyle: .memory))
            }
            if model.canUnloadModel {
                Button("Unload Model", role: .destructive) {
                    model.perform(.unload)
                }
            } else if model.isModelInstalled, !model.loadState.isReady,
                      !model.loadState.isLoading {
                Button("Load Model") { model.perform(.load) }
            }
            Text(model.modelPathText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Models on this iPhone

    /// Every model with files on the phone, and every added one, each with
    /// Delete. A model is about 14 GB, and this is the only way to get the
    /// space back short of deleting the app.
    private var storedModelsSection: some View {
        Section {
            ForEach(storedModels, id: \.key) { descriptor in
                storedModelRow(descriptor)
            }
            if let deletionError {
                Text(deletionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Models on this iPhone")
        } footer: {
            Text("Add more from the model menu under the message box. "
                 + "Community models were added from a Hugging Face link: they "
                 + "run like Gemma 4 but are not tested here.")
        }
    }

    private enum Stored { case installed, partial, none }

    private var storedModels: [AppModelInstallDescriptor] {
        model.availableModels.filter { $0.isCommunity || stored($0) != .none }
    }

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

    private func storedModelRow(_ descriptor: AppModelInstallDescriptor) -> some View {
        let blocker = model.deletionBlocker(for: descriptor)
        var detail: [String] = []
        if descriptor.isCommunity { detail.append("Community") }
        switch stored(descriptor) {
        case .installed: detail.append(MetricFormat.storage(descriptor.installedBytes))
        case .partial: detail.append("Part-downloaded")
        case .none: detail.append("Not downloaded")
        }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                Text(detail.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let blocker {
                    Text(blocker)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Delete", role: .destructive) {
                pendingDeletion = descriptor
            }
            .buttonStyle(.borderless)
            .disabled(blocker != nil)
        }
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

    private var harness: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run generates the frozen real-generation-v1 prompts and writes "
                 + "a timing log to Documents. A run takes minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            HarnessView()
        }
        .navigationTitle("Benchmark harness")
        .navigationBarTitleDisplayMode(.inline)
    }
}
