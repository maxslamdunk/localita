import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// The stored conversations, in the side panel.
///
/// The Mac's `ConversationSidebarView` is the behavioural reference, and
/// everything it decides that is not AppKit is shared rather than restated:
/// grouping by day, row titles, the line that says why a row cannot continue.
/// What differs is only the idiom. Here a row is tapped to open, and renamed
/// or deleted from the menu a long press brings up. There is no swipe on a
/// row, because a sideways swipe closes the panel.
///
/// New Chat and Settings sit at the bottom. New Chat is shown only when the
/// chat on screen has something in it: on an empty chat it would do nothing.
///
/// Opening a row is a disk read. The replay into the KV waits for the next
/// send, which is where the status row shows its progress, so a long
/// conversation costs nothing to look at.
struct HistoryView: View {
    let model: AppModel
    /// Closes the panel. Called after anything that changes what the chat
    /// screen shows.
    let close: () -> Void
    let openSettings: () -> Void
    /// Where the list is scrolled, for the thumb drawn on the panel's seam.
    let seamThumb: SeamThumb

    @State private var search = ""
    @State private var renameTarget: ConversationMeta?
    @State private var renameText = ""
    @State private var deleteTarget: ConversationMeta?
    /// Where the list's visible part ends under the two bars, for the blur.
    @State private var scrollEdges = ScrollEdges()

    var body: some View {
        Group {
            if visibleSections.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Bars rather than rows around the list, so the chats scroll on
        // under the glass search field and the buttons to the edges of the
        // screen. The system's edge effect fades them there, and each row
        // also blurs by itself (`EdgeBlur`), since the fade alone only shades.
        .safeAreaBar(edge: .top, spacing: 0) {
            searchField.onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .global).maxY
            } action: { scrollEdges.top = $0 }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            bottomBar.onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .global).minY
            } action: { scrollEdges.bottom = $0 }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background(Color(uiColor: .systemBackground))
        .alert("Rename Chat", isPresented: isRenaming, presenting: renameTarget) { target in
            TextField("Name", text: $renameText)
                .accessibilityIdentifier(.historyRenameField)
            Button("Rename") {
                model.renameConversation(id: target.id, to: renameText)
                renameTarget = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier(.historyRenameConfirm)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: { target in
            Text("Rename \u{201C}\(ConversationRowPresentation.title(target))\u{201D}.")
        }
        // Asked, as on the Mac, because it cannot be taken back: the store
        // deletes for real and there is no trash to restore from.
        .alert("Delete this chat?", isPresented: isDeleting, presenting: deleteTarget) { target in
            Button("Delete", role: .destructive) {
                model.deleteConversation(id: target.id)
                deleteTarget = nil
            }
            .disabled(!model.canMutateConversation(id: target.id))
            .accessibilityIdentifier(.historyDeleteConfirm)
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text("\u{201C}\(ConversationRowPresentation.title(target))\u{201D} and "
                 + "everything in it will be deleted. This cannot be undone.")
        }
    }

    /// New Chat is offered only when it would change something: a chat with
    /// nothing in it is already a new chat.
    private var showsNewChat: Bool {
        model.canStartNewChat && model.hasOutputTranscript
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if showsNewChat {
                Button {
                    model.newChat()
                    close()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier(.stripNewChat)
            }
            Spacer(minLength: 0)
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.title3)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Chats", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier(.historySearch)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(.historySearchClear)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
    }

    private var visibleSections: [(group: ConversationDateGroup, entries: [ConversationMeta])] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = query.isEmpty
            ? model.history.entries
            : model.history.entries.filter {
                $0.title.localizedCaseInsensitiveContains(query)
            }
        return ConversationDateGroup.sections(entries, now: Date())
    }

    // MARK: - List

    /// A scroll view rather than a `List`. A list lifts its own cell on a long
    /// press: first a light cell-shaped platter, then the row stretched onto
    /// it, and a copy of the row without the selected chat's grey. Here the
    /// view that lifts is the row as drawn.
    ///
    /// The day headers scroll with their rows rather than pinning. A pinned
    /// header needs a solid background to cover the rows under it, and that
    /// strip hid the rows before they reached the search field's blur.
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                notices
                    .padding(.horizontal, 20)
                    .modifier(EdgeBlur(edges: scrollEdges))

                ForEach(visibleSections, id: \.group) { section in
                    Section {
                        ForEach(section.entries, id: \.id) { entry in
                            row(entry)
                                .modifier(EdgeBlur(edges: scrollEdges))
                        }
                    } header: {
                        Text(section.group.rawValue)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                            .modifier(EdgeBlur(edges: scrollEdges))
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .reportsScroll(to: seamThumb)
    }

    /// The same three facts the Mac's sidebar states above its list. A chat
    /// that is missing from the list, or a list that cannot be changed, is
    /// said out loud rather than left for the user to notice.
    @ViewBuilder
    private var notices: some View {
        if model.history.isReadOnlyStore {
            Label("These chats are open elsewhere. They can be read here "
                  + "but not changed.", systemImage: "lock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if model.history.unreadableCount > 0 {
            Label(model.history.unreadableCount == 1
                  ? "1 chat on disk could not be read and is not listed."
                  : "\(model.history.unreadableCount) chats on disk could not "
                    + "be read and are not listed.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// One chat. Every row has the same rounded background, grey for the
    /// chat on screen, and a long press lifts exactly that shape. A tap
    /// rather than a button, so no press animation runs under the lift.
    private func row(_ entry: ConversationMeta) -> some View {
        let state = model.continuability(of: entry)
        let canMutate = model.canMutateConversation(id: entry.id)
        let shape = RoundedRectangle(cornerRadius: 12)
        return VStack(alignment: .leading, spacing: 2) {
            Text(ConversationRowPresentation.title(entry))
                .lineLimit(1)
            Text(ConversationRowPresentation.subtitle(entry, state: state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.history.selection == entry.id
                    ? Color(uiColor: .systemGray6)
                    : Color(uiColor: .systemBackground),
                    in: shape)
        .contentShape(.interaction, shape)
        .contentShape(.contextMenuPreview, shape)
        .onTapGesture {
            model.openConversation(id: entry.id)
            close()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AccessibilityID.row(entry.id))
        .contextMenu {
            Button {
                renameText = entry.title
                renameTarget = entry
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(!canMutate)
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canMutate)
        }
        .padding(.horizontal, 8)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(search.isEmpty ? "No Chats Yet" : "No Matches",
                  systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text(search.isEmpty
                 ? "Chats are kept here once you send a message."
                 : "No chat title contains \u{201C}\(search)\u{201D}.")
        }
    }
}

/// Where the search field ends above and the buttons begin below, on screen.
/// Measured from the bars themselves: the scroll view's own insets include
/// the status bar and home indicator, which put the blur's start in the
/// wrong place.
private struct ScrollEdges: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = .infinity
}

/// Blurs a piece of the chat list by how far it has gone under either bar:
/// none at the bar's edge, rising to full over `distance`. Each row blurs as a
/// whole, so the blur moves with the row as it scrolls.
private struct EdgeBlur: ViewModifier {
    let edges: ScrollEdges

    private static let distance: CGFloat = 120
    private static let radius: CGFloat = 2

    func body(content: Content) -> some View {
        content.visualEffect { [edges] content, proxy in
            let frame = proxy.frame(in: .global)
            // Under the search field, eased in, so the blur begins gently.
            let top = min(max(edges.top - frame.minY, 0) / Self.distance, 1)
            // Under the buttons, straight from their top edge. Eased in as
            // well, it showed only some 40 pt below the New Chat button.
            let bottom = min(max(frame.maxY - edges.bottom, 0) / Self.distance, 1)
            let t = max(top * top * (3 - 2 * top), bottom)
            return content.blur(radius: Self.radius * t)
        }
    }
}

/// Shown above the composer when the chat on screen cannot be continued.
///
/// The phone's counterpart of the Mac's `ConversationStateNoticeView`, with the
/// copy shared through `ConversationStateNotice` so the two cannot disagree
/// about what went wrong or what the fix costs.
struct ConversationNoticeView: View {
    let model: AppModel

    var body: some View {
        if let content = ConversationStateNotice.content(
            for: model.openedConversationState,
            currentContext: model.maxContextTokens) {
            VStack(alignment: .leading, spacing: 8) {
                Text(content.title).font(.subheadline.weight(.semibold))
                Text(content.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // No "Raise Context" button, unlike the Mac. On the phone, a
                // larger context is a larger KV against the memory ceiling, and
                // which sizes fit has not been measured. The settings sheet
                // offers context once that measurement exists.
                HStack(spacing: 12) {
                    Button("New Chat") { model.newChat() }
                        .disabled(!model.canStartNewChat)
                        .accessibilityIdentifier(.noticeNewChat)
                    if content.offersReread {
                        Button("Re-read Into New Chat") { model.rereadIntoNewChat() }
                            .disabled(!model.canRereadIntoNewChat)
                            .accessibilityIdentifier(.noticeReread)
                    }
                }
                .font(.footnote)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}
