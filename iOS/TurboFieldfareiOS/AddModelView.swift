import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// Adds a community model from a pasted Hugging Face link.
///
/// The check reads the repository's config and weight headers, a few MB, and
/// says whether this runtime can run it before anything large is downloaded
/// (`RemoteModelInspector`). Most repositories named like Gemma 4 26B cannot:
/// other bit widths, GGUF files, pruned experts. One that can is added to the
/// model menu, pinned to the commit the check read, and picking it opens its
/// download as for any model.
struct AddModelView: View {
    let model: AppModel
    /// Called with the added model, or with the listed one the link names.
    let onChoose: (AppModelInstallDescriptor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var phase = Phase.idle
    @State private var name = ""
    @FocusState private var isLinkFocused: Bool

    private enum Phase: Equatable {
        case idle
        case checking
        case compatible(CommunityModelRecord)
        case listed(AppModelInstallDescriptor)
        case incompatible(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                resultSection
            }
            .navigationTitle("Add Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton
                }
            }
            .onAppear { isLinkFocused = true }
        }
    }

    // MARK: - Sections

    private var linkSection: some View {
        Section {
            TextField("huggingface.co/owner/model", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($isLinkFocused)
                .onSubmit(check)
                .onChange(of: link) { _, _ in
                    if phase != .checking { phase = .idle }
                }
            Button(action: check) {
                if phase == .checking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Checking…")
                    }
                } else {
                    Text("Check")
                }
            }
            .disabled(HuggingFaceLink(link) == nil || phase == .checking)
        } footer: {
            Text("Paste a Hugging Face link or owner/name. Fine-tunes of "
                 + "Gemma 4 26B-A4B in MLX 4-bit run here. The check reads a "
                 + "few MB; nothing large downloads until you choose to.")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch phase {
        case .idle, .checking:
            EmptyView()
        case .compatible(let record):
            Section {
                Label("Runs on this iPhone", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Repository", value: record.repoID)
                TextField("Name in the chat", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledContent("Download",
                               value: MetricFormat.storage(record.approximateDownloadBytes))
                LabeledContent("Images", value: "Gemma 4's image support")
            } header: {
                Text("Community model")
            } footer: {
                Text("It is laid out exactly like Gemma 4, so it runs the same "
                     + "way, but nobody here has tested its answers. It stays at "
                     + "commit \(record.revision.prefix(7)), whatever its author "
                     + "uploads later.")
            }
        case .listed(let descriptor):
            Section {
                Label("\(descriptor.displayName) is already in the model menu.",
                      systemImage: "checkmark.circle")
            }
        case .incompatible(let reason):
            Section {
                Label {
                    Text(reason)
                } icon: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            } header: {
                Text("Can't run here")
            }
        case .failed(let message):
            Section {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Couldn't check")
            }
        }
    }

    @ViewBuilder
    private var confirmButton: some View {
        switch phase {
        case .compatible(var record):
            Button("Add") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { record.name = trimmed }
                do {
                    let added = try model.addCommunityModel(record)
                    dismiss()
                    onChoose(added)
                } catch {
                    phase = .failed("It could not be saved: \(error)")
                }
            }
        case .listed(let descriptor):
            Button("Choose") {
                dismiss()
                onChoose(descriptor)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Checking

    private func check() {
        guard let parsed = HuggingFaceLink(link), phase != .checking else { return }
        isLinkFocused = false
        phase = .checking
        Task {
            do {
                switch try await model.checkCommunityModel(parsed) {
                case .compatible(let record):
                    name = record.name
                    phase = .compatible(record)
                case .listed(let descriptor):
                    phase = .listed(descriptor)
                case .incompatible(let reason):
                    phase = .incompatible(reason)
                }
            } catch let error as URLError {
                phase = .failed("Hugging Face could not be reached. "
                                + error.localizedDescription)
            } catch {
                // The installer's errors describe themselves; their
                // `localizedDescription` is only "the operation couldn't be
                // completed".
                phase = .failed("Hugging Face answered unexpectedly: \(error)")
            }
        }
    }
}
