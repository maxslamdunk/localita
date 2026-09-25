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

    @State private var search = ""
    @State private var renameTarget: ConversationMeta?
    @State private var renameText = ""
    @State private var deleteTarget: ConversationMeta?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if visibleSections.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
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
        .background(Color(uiColor: .secondarySystemBackground), in: .capsule)
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

    private var list: some View {
        List {
            notices

            ForEach(visibleSections, id: \.group) { section in
                Section(section.group.rawValue) {
                    ForEach(section.entries, id: \.id) { entry in
                        row(entry)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
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

    private func row(_ entry: ConversationMeta) -> some View {
        let state = model.continuability(of: entry)
        let canMutate = model.canMutateConversation(id: entry.id)
        return Button {
            model.openConversation(id: entry.id)
            close()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(ConversationRowPresentation.title(entry))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(ConversationRowPresentation.subtitle(entry, state: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .listRowBackground(model.history.selection == entry.id
                           ? RoundedRectangle(cornerRadius: 12)
                               .fill(Color(uiColor: .tertiarySystemFill))
                               .padding(.horizontal, 8)
                           : nil)
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
                Label("Delete\u{2026}", systemImage: "trash")
            }
            .disabled(!canMutate)
        }
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
