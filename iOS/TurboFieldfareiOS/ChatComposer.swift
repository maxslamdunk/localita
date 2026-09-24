import PhotosUI
import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// The message box and the one control that starts or stops a turn.
///
/// This is the surface Liquid Glass belongs on: a floating control cluster over
/// scrolling content, which is what the vendored skill names as the intended
/// use, as against decorating the transcript itself. The two glass children
/// share one `GlassEffectContainer` so they blend as a single cluster rather
/// than as two unrelated shapes.
struct ChatComposer: View {
    @Bindable var model: AppModel

    @FocusState private var isFocused: Bool
    @State private var pickedPhotos: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.imageAttachments.isEmpty || model.isAddingImages
                || model.imageAttachmentError != nil {
                attachmentStrip
            }
            controls
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await attach(items) }
        }
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                if model.isImageInputAvailable {
                    photoButton
                }
                TextField("Message", text: $model.promptText, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .submitLabel(.return)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    // Layout and appearance first, glass last: applied before
                    // the padding it would take the untouched frame instead.
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .accessibilityIdentifier(.composerMessage)

                if model.isRunning {
                    stopButton
                } else {
                    sendButton
                }
            }
        }
    }

    // MARK: - Images

    /// Only as many as still fit. `addImageData` checks capacity against the
    /// attachments already staged, and staging is asynchronous, so a larger
    /// batch would pass that check several times over.
    private var remainingImageSlots: Int {
        max(0, model.maximumImageAttachments - model.imageAttachments.count)
    }

    private var photoButton: some View {
        PhotosPicker(selection: $pickedPhotos,
                     maxSelectionCount: max(1, remainingImageSlots),
                     matching: .images) {
            Image(systemName: "photo.badge.plus")
                .font(.headline)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .disabled(model.isTurnInFlight || model.isAddingImages
                  || remainingImageSlots == 0)
        .accessibilityLabel(remainingImageSlots == 0 && model.imageAttachments.isEmpty
                            ? "No room for images. Start a new chat."
                            : "Add photos")
        .accessibilityIdentifier(.composerAttach)
    }

    /// The photo's own bytes, in its own format (usually HEIC): the pinned
    /// image processor resizes from the original, as the Mac does from a file.
    private func attach(_ items: [PhotosPickerItem]) async {
        for (offset, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    model.reportImageAttachmentError("That photo could not be read.")
                    continue
                }
                let number = model.imageAttachments.count + offset + 1
                model.addImageData(data, displayName: "Photo \(number)")
            } catch {
                model.reportImageAttachmentError(error)
            }
        }
    }

    private var attachmentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.imageAttachments, id: \.id) { attachment in
                        ImageThumbnail(image: .staged(attachment))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    model.removeImage(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .padding(4)
                                .disabled(model.isTurnInFlight)
                                .accessibilityLabel("Remove \(attachment.displayName)")
                            }
                    }
                    if model.isAddingImages {
                        ProgressView()
                            .frame(width: 64, height: 64)
                    }
                }
            }
            .scrollIndicators(.hidden)
            if let error = model.imageAttachmentError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var sendButton: some View {
        Button {
            isFocused = false
            model.send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.headline)
                .frame(width: 26, height: 26)
        }
        // The primary action, so the prominent variant. `.interactive()` is not
        // added by hand: a button style already carries press behaviour, and
        // stacking both is the mistake the skill's checklist calls out.
        .buttonStyle(.glassProminent)
        .disabled(!model.canRun)
        .accessibilityLabel("Send message")
        .accessibilityIdentifier(.composerGenerate)
    }

    private var stopButton: some View {
        Button {
            model.cancel()
        } label: {
            Image(systemName: "stop.fill")
                .font(.headline)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .disabled(!model.canCancel)
        .accessibilityLabel("Stop generating")
        .accessibilityIdentifier(.composerStop)
    }
}
