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
/// Tuning these further, and the lag that 32 slots causes through compressor
/// churn, is deliberately left for later.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReset = false

    /// Context sizes this phone may offer. See the type comment.
    static let contextOptions: [AppContextLengthOption] = [.fourK, .eightK]

    /// Slot counts measured on this phone, with what each measured. The
    /// throughput is the 2026-09-16 short case at 4K. It says how the options
    /// compare, not what any given chat will reach.
    static let slotOptions: [(slots: Int, label: String)] = [
        (16, "16 · about 4.4 tok/s · −1.6 GB"),
        (24, "24 · about 6.0 tok/s · −0.8 GB"),
        (32, "32 · about 7.0 tok/s · default"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                generationSection
                memorySection
                resetSection
                modelSection
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
                     + "32 expert slots. If context or slots change, the model "
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
