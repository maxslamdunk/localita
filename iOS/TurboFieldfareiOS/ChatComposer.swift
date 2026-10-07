import PhotosUI
import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// The message box: the text, and under it a row with photos, the model, the
/// reasoning toggle, and the one control that moves forward: Send or Stop,
/// or Load or Download when there is no model to send to yet.
///
/// This is the surface Liquid Glass belongs on: a floating card over the
/// scrolling conversation, which shows through it, as against decorating the
/// transcript itself. It is one glass shape. The controls inside it are plain
/// fills rather than glass of their own, because glass on glass is the misuse
/// the vendored skill calls out. Every colour is neutral: the send button is
/// the primary colour, white on dark and black on light, and nothing is tinted.
struct ChatComposer: View {
    @Bindable var model: AppModel

    @FocusState private var isFocused: Bool
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// The model picked in the menu, by key. Picking only chooses: nothing
    /// loads or unloads until the button that then reads Load or Download is
    /// pressed, so the top of the chat keeps naming what is in memory.
    @State private var pickedKey: String?

    /// The size of every round control in the bottom row.
    private static let control: CGFloat = 38
    /// The model pill and the reasoning toggle: settings rather than actions,
    /// so a step smaller than the round controls either side of them.
    private static let smallControl: CGFloat = 35
    private static let controlFill = Color.primary.opacity(0.08)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.imageAttachments.isEmpty || model.isAddingImages
                || model.imageAttachmentError != nil {
                attachmentStrip
            }
            TextField("Message", text: $model.promptText, axis: .vertical)
                // Two lines tall while empty, so the box reads as a place to
                // write rather than a search field.
                .lineLimit(2...8)
                .focused($isFocused)
                .submitLabel(.return)
                .padding(.horizontal, 6)
                .accessibilityIdentifier(.composerMessage)
            controls
        }
        .padding(12)
        .contentShape(.rect(cornerRadius: 26))
        .onTapGesture { isFocused = true }
        // Layout first, glass last: applied before the padding, it would take
        // the untouched frame instead.
        // `.regular`, chosen on the device over `.clear`. The API offers only
        // those two strengths; neither the rim's reflection nor its lensing
        // can be tuned between them.
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await attach(items) }
        }
        // A switch made anywhere else settles the question the pick asked.
        .onChange(of: model.installDescriptor.key) { _, _ in
            pickedKey = nil
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if model.isImageInputAvailable {
                photoButton
            }
            modelMenu
            thinkingButton
            Spacer(minLength: 0)
            actionButton
        }
    }

    // MARK: - Model and reasoning

    /// The picked model, when it is not the one the app is on.
    private var pickedModel: AppModelInstallDescriptor? {
        guard let pickedKey,
              let descriptor = AppModelInstallDescriptor.textModel(key: pickedKey),
              descriptor != model.installDescriptor else { return nil }
        return descriptor
    }

    /// The model the pill names and the menu ticks.
    private var shownModel: AppModelInstallDescriptor {
        pickedModel ?? model.installDescriptor
    }

    /// The model the next message goes to, and the others it could.
    ///
    /// Picking one only chooses it. The button beside the box then reads Load
    /// (or Download, for one not on the phone), and pressing that releases
    /// the model in memory before loading the new one, so two are never in
    /// memory together. The chat on screen stays: any chat continues with any
    /// model that shares its tokenizer, and each answer names its model.
    private var modelMenu: some View {
        Menu {
            Section("Model") {
                ForEach(model.availableModels, id: \.key) { descriptor in
                    Button {
                        pickedKey = descriptor == model.installDescriptor
                            ? nil : descriptor.key
                    } label: {
                        if descriptor == shownModel {
                            Label(descriptor.displayName, systemImage: "checkmark")
                        } else {
                            Text(descriptor.displayName)
                        }
                        if let detail = menuDetail(for: descriptor) {
                            Text(detail)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(shortModelName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .padding(.horizontal, 13)
            .frame(height: Self.smallControl)
            .background(Self.controlFill, in: .capsule)
        }
        // A menu takes the app's tint for its label and its checked item.
        // Neutral like the rest of the box.
        .tint(.primary)
        .accessibilityLabel("Model")
        .accessibilityValue(shownModel.displayName)
    }

    /// The menu's second line: what choosing a model would cost, and what it
    /// cannot do.
    private func menuDetail(for descriptor: AppModelInstallDescriptor) -> String? {
        var parts: [String] = []
        if !ChatSession.isInstalled(descriptor, current: model) {
            parts.append("Download " + MetricFormat.storage(descriptor.approximateDownloadBytes))
        }
        if !descriptor.supportsImages {
            parts.append("Text only")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The pill shows the short name, the one each answer and the top of the
    /// chat use. The menu shows it in full.
    private var shortModelName: String {
        shownModel.shortName
    }

    // Applies to the next turn, not the one in flight: `makeRequest` reads the
    // flag at send time. Deliberately left enabled during a run — it changes
    // the token sequence a turn pins, so taking effect mid-turn is the
    // behaviour to avoid, not the behaviour to offer.
    private var thinkingButton: some View {
        Button {
            model.enableThinking.toggle()
        } label: {
            Image(systemName: "brain")
                .font(.system(size: 16))
                .foregroundStyle(model.enableThinking ? .primary : .secondary)
                .frame(width: Self.smallControl, height: Self.smallControl)
                .background(model.enableThinking
                            ? Color.primary.opacity(0.22) : Self.controlFill,
                            in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reasoning")
        .accessibilityValue(model.enableThinking ? "On" : "Off")
        .accessibilityIdentifier(.composerThinking)
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
            Image(systemName: "plus")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: Self.control, height: Self.control)
                .background(Self.controlFill, in: .circle)
        }
        .buttonStyle(.plain)
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

    // MARK: - The button

    /// Send and Stop, or what has to happen before there is anything to send
    /// to. Decided by `ChatControlsPresentation`, so the package tests pin it.
    private var composerAction: ChatControlsPresentation.ComposerAction {
        let picked: ChatControlsPresentation.PickedModel? = pickedModel.map {
            ChatSession.isInstalled($0, current: model) ? .installed : .notInstalled
        }
        return ChatControlsPresentation.composerAction(.init(
            isRunning: model.isRunning,
            canCancel: model.canCancel,
            picked: picked,
            requiresInstallation: model.requiresModelInstallation,
            isVisionFilesystemMutationInProgress: model.isVisionFilesystemMutationInProgress,
            loadState: model.loadState,
            hasStaleRuntime: model.hasStaleLoadedRuntime,
            canSelectModel: model.canSelectModel,
            canLoad: model.canLoadModel,
            canReload: model.canReloadModel,
            canRun: model.canRun))
    }

    @ViewBuilder
    private var actionButton: some View {
        switch composerAction {
        case .send:
            sendButton
        case .stop:
            stopButton
        case .load(let enabled):
            // Load never sends: a message already typed stays in the box.
            labelButton("Load", enabled: enabled) {
                if let pickedModel {
                    ChatSession.switchModel(to: pickedModel, in: model)
                } else {
                    model.perform(.load)
                }
            }
        case .download(let enabled):
            labelButton("Download", enabled: enabled) {
                if let pickedModel {
                    ChatSession.switchModel(to: pickedModel, in: model)
                }
            }
        case .retry(let enabled):
            labelButton("Retry", enabled: enabled) { model.perform(.retryLoad) }
        case .reload(let enabled):
            labelButton("Reload", enabled: enabled) { model.perform(.reload) }
        case .busy:
            ProgressView()
                .controlSize(.small)
                .frame(width: Self.control, height: Self.control)
                .background(Self.controlFill, in: .circle)
                .accessibilityLabel("Working")
        }
    }

    /// A word in the send button's place: the same height and the same solid
    /// primary fill, as a capsule, since a word does not fit a circle.
    private func labelButton(_ title: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(enabled
                                 ? Color(uiColor: .systemBackground)
                                 : Color(uiColor: .tertiaryLabel))
                .padding(.horizontal, 16)
                .frame(height: Self.control)
                .background(enabled ? Color.primary : Self.controlFill,
                            in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(.composerModelAction)
    }

    private var sendButton: some View {
        Button {
            isFocused = false
            model.send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.headline)
                .foregroundStyle(model.canRun
                                 ? Color(uiColor: .systemBackground)
                                 : Color(uiColor: .tertiaryLabel))
                .frame(width: Self.control, height: Self.control)
                .background(model.canRun ? Color.primary : Self.controlFill,
                            in: .circle)
        }
        // The primary action, so the one solid shape in the row, in the
        // primary colour rather than a tint. Disabled, it is a grey circle
        // like the other controls with a faint arrow. Fading the solid one
        // instead left it nearly invisible against the glass.
        .buttonStyle(.plain)
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
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: Self.control, height: Self.control)
                .background(Color.primary, in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!model.canCancel)
        .accessibilityLabel("Stop generating")
        .accessibilityIdentifier(.composerStop)
    }
}
