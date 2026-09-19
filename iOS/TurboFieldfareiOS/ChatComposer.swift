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

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
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
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
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
