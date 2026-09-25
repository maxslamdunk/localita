import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation
import UIKit

/// The conversation, oldest turn first.
///
/// Unlike the Mac's transcript this is not an incremental document. The Mac
/// drives an `NSTextView` that appends and cannot take pairs back, which is why
/// `TranscriptSyncPlanner` exists to tell it what to draw, seal and reset.
/// SwiftUI renders declaratively from `model.transcriptHistory`, so there is no
/// append to plan and the planner has no analogue here — using it would be
/// ceremony around a diff SwiftUI already does. `ResponseBlockSplitter` and
/// `TranscriptScrollFollow` *are* used, because their logic is platform-neutral
/// and re-deriving either would be a second implementation that drifts.
struct ChatTranscriptView: View {
    let model: AppModel
    let blocks: StreamingBlocks
    /// Reasoning's own scan state. Separate from `blocks` because reasoning
    /// streams independently of the answer and is often long enough that
    /// re-parsing it per tick is the same quadratic `StreamingBlocks` exists
    /// to avoid.
    let thinkingBlocks: StreamingBlocks

    @State private var follow = TranscriptScrollFollow()

    private static let bottomAnchor = "transcript.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(model.transcriptHistory.enumerated()),
                            id: \.element.user.id) { index, pair in
                        // The rule the live conversation draws under the turns
                        // the model can no longer see. A fact about the live
                        // chat only, which is why `transcriptContextBreak` is
                        // nil for a stored copy.
                        if model.transcriptContextBreak == index {
                            contextBreak
                        }
                        // Empty, and not because it was dropped on the way here:
                        // `AppChatTurn` has no reasoning field, so an archived
                        // turn has none to draw. Reasoning is visible for the
                        // newest answer and goes when that answer becomes
                        // history — populating `ConversationRecord.thinking`,
                        // which exists and is unused, is what would change that.
                        turn(prompt: pair.user.text,
                             images: pair.user.images,
                             response: pair.assistant.text,
                             responseSplit: nil)
                    }

                    if model.showsLiveTurn, model.hasOutputTranscript {
                        liveTurn
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            // A new run is pinned to the bottom and held there until the reader
            // takes over. `TranscriptScrollFollow` owns that decision; only the
            // signal differs from the Mac's. The Mac has to infer a reader
            // scroll from geometry — the view moved while the document did not
            // — because AppKit gives it nothing better. iOS reports the gesture
            // directly, which the type explicitly allows ("the reader scrolled
            // in a way the platform reported directly") and which avoids
            // mistaking our own programmatic scroll for the reader's.
            .onScrollPhaseChange { _, phase in
                if phase.isScrolling { follow.end() }
            }
            .onChange(of: model.isTranscriptTurnInFlight) { _, inFlight in
                if inFlight {
                    follow.beginRun()
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: model.outputText) { _, text in
                blocks.update(text)
                if follow.isFollowing { scrollToBottom(proxy) }
            }
            // Reasoning can run for many seconds before the first visible token,
            // and during that stretch `outputText` never changes — so without
            // this the view would sit still while grey text grew past the
            // bottom of the screen.
            .onChange(of: model.thinkingText) { _, text in
                thinkingBlocks.update(text)
                if follow.isFollowing { scrollToBottom(proxy) }
            }
            .onChange(of: model.displayedTranscriptID) { _, _ in
                // A different conversation: the split belongs to the old one.
                blocks.reset()
                blocks.update(model.outputText)
                thinkingBlocks.reset()
                thinkingBlocks.update(model.thinkingText)
            }
            .onAppear {
                blocks.update(model.outputText)
                thinkingBlocks.update(model.thinkingText)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }

    private var liveTurn: some View {
        turn(prompt: model.outputPromptText,
             images: model.outputImageAttachments,
             response: model.outputResponsePlainText,
             responseSplit: blocks.split,
             streaming: blocks,
             thinking: model.thinkingText,
             thinkingSplit: thinkingBlocks.split,
             thinkingStreaming: thinkingBlocks,
             // The finalize the Mac does in `closeTail`, which this port was
             // missing entirely. Once nothing more is arriving the trailing
             // block stops being an open block: its math is typeset and its
             // auto-closed tail goes away. Without it the last block of every
             // answer kept its streaming dress permanently, because the
             // splitter never commits a trailing block.
             isTerminal: !model.isTranscriptTurnInFlight)
    }

    @ViewBuilder
    private func turn(prompt: String,
                      images: [ChatImage] = [],
                      response: String,
                      responseSplit: ResponseBlockSplitter.Split?,
                      streaming: StreamingBlocks? = nil,
                      thinking: String = "",
                      thinkingSplit: ResponseBlockSplitter.Split? = nil,
                      thinkingStreaming: StreamingBlocks? = nil,
                      isTerminal: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Above the prompt, on the user's side, in the order attached.
            if !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(images) { image in
                        ImageThumbnail(image: image, side: 96)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !prompt.isEmpty {
                Text(prompt)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: .rect(cornerRadius: 18))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Above the answer, in grey, streaming as it arrives.
            //
            // This was a plain `Text`, on the stated grounds that reasoning is
            // prose with "no fences worth typesetting". That was wrong about
            // the model: it writes headings, lists and equations while it
            // reasons, and a plain `Text` put them on screen as literal `**`
            // and `\[`. It goes through the same splitter and the same
            // renderer as an answer now — the second scan state that argument
            // was avoiding is the price, and it is the same price the answer
            // already pays for the same reason.
            if !thinking.isEmpty {
                reasoning(thinking,
                          split: thinkingSplit,
                          streaming: thinkingStreaming,
                          isTerminal: isTerminal)
            }

            if let responseSplit {
                ResponseBlocksView(response: response,
                                   split: responseSplit,
                                   blocks: streaming,
                                   isTerminal: isTerminal)
            } else if !response.isEmpty {
                // A frozen turn is split once, on the pass that draws it. Only
                // the live answer is worth keeping resumable scan state for.
                ResponseBlocksView(response: response,
                                   split: ResponseBlockSplitter.split(response))
            }

            // Once the answer is complete: a half-streamed answer copied now
            // would be missing its end without saying so.
            if isTerminal, !response.isEmpty {
                CopyResponseButton(markdown: response)
            }

            if model.isTranscriptTurnInFlight, response.isEmpty {
                prefillNotice
            }
        }
    }

    /// Reasoning: the same markdown and LaTeX an answer gets, in grey, behind
    /// a rule that says where it stops.
    ///
    /// The grey comes from the renderer rather than a `.foregroundStyle` over
    /// the top, because a typeset equation is a bitmap by the time SwiftUI sees
    /// it — an outside tint would recolour the prose and leave the maths at
    /// full contrast.
    private func reasoning(_ text: String,
                           split: ResponseBlockSplitter.Split?,
                           streaming: StreamingBlocks?,
                           isTerminal: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: 2)
            ResponseBlocksView(response: text,
                               split: split ?? ResponseBlockSplitter.split(text),
                               blocks: streaming,
                               isTerminal: isTerminal,
                               isReasoning: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prefillNotice: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(model.presentation.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        // A reply on this device begins after a full prefill of the prompt,
        // which is tens of seconds. Without this the app looks like it dropped
        // the message — the same reason the Mac draws a placeholder.
        .accessibilityIdentifier(.hudPhase)
    }

    private var contextBreak: some View {
        HStack(spacing: 10) {
            line
            Text("Earlier turns are no longer in context")
                .font(.caption)
                .foregroundStyle(.secondary)
            line
        }
        .padding(.vertical, 4)
    }

    private var line: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1)
    }
}

/// Copies an answer as the model wrote it: the markdown source, not the
/// rendered text, so it pastes into anything that reads markdown with its
/// headings, lists, code fences and LaTeX intact.
private struct CopyResponseButton: View {
    let markdown: String

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = markdown
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .accessibilityLabel(copied ? "Copied" : "Copy answer")
        .padding(.leading, -8)
    }
}
