import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// The stored conversations, in the side panel.
///
/// The Mac's `ConversationSidebarView` is the behavioural reference, and
/// everything it decides that is not AppKit is shared rather than restated:
/// grouping by day, row titles, the line under each title.
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
    /// The search field is out in place of its button. It stays out while it
    /// has text or the keyboard, and goes back into the button otherwise.
    @State private var isSearchOpen = false
    @FocusState private var isSearchFocused: Bool
    @Namespace private var searchGlass
    @State private var renameTarget: ConversationMeta?
    @State private var renameText = ""
    @State private var deleteTarget: ConversationMeta?
    /// Where the list's visible part ends under the two bars, for the blur.
    @State private var scrollEdges = ScrollEdges()
    /// The top bar's bottom edge, and the search field's top edge while it is
    /// out: the top blur starts at whichever is showing.
    @State private var topBarBottom: CGFloat = 0
    @State private var searchFieldTop: CGFloat = 0
    /// The logo row's height, which the top bar keeps with the field out.
    @State private var logoRowHeight: CGFloat?
    /// Grows with the text size, as the name beside it does.
    @ScaledMetric(relativeTo: .title3) private var logoHeight: CGFloat = 58
    /// The search field's height, as the old always-shown field measured: a
    /// line of body text and 9 pt above and below.
    @ScaledMetric(relativeTo: .body) private var searchFieldHeight: CGFloat = 40

    var body: some View {
        Group {
            if visibleSections.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A tap anywhere a row or button does not take, such as the space
        // under the last chat, puts the search's keyboard away.
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
        // Bars rather than rows around the list, so the chats scroll on
        // under the glass search field and the buttons to the edges of the
        // screen. At the bottom the system's edge effect fades them, and each
        // row also blurs by itself (`EdgeBlur`), since the fade alone only
        // shades. At the top `EdgeBlur` does both, from the search field's
        // top edge when it is out: the system's fade would start at the bar's
        // bottom, under the field, and reach only partway up the logo. The top
        // is an inset rather than a bar because a bar's content resized
        // without animation, and the search button's move into the field
        // jumped with it.
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar.onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .global).maxY
            } action: { topBarBottom = $0 }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            bottomBar.onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .global).minY
            } action: { scrollEdges.bottom = $0 }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollEdgeEffectHidden(true, for: .top)
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

    private var blurEdges: ScrollEdges {
        var edges = scrollEdges
        edges.top = isSearchOpen ? searchFieldTop : topBarBottom
        return edges
    }

    /// The logo and name, with the search button beside them. The button
    /// grows into the search field below and shrinks back into itself.
    ///
    /// It is one glass shape that moves between two empty slots, the
    /// button's and the field's, rather than two shapes that morph: two
    /// glass effects sharing a `glassEffectID` swapped in a single frame here.
    ///
    /// The bar keeps the logo row's height, and the field's slot hangs out
    /// of it, over the chats. Counted in the bar's height, it made the bar
    /// taller, and the list moved down and back each time the field opened
    /// and closed.
    private var topBar: some View {
        VStack(spacing: 0) {
            logoRow
            if isSearchOpen {
                Color.clear
                    .frame(height: searchFieldHeight)
                    .matchedGeometryEffect(id: Self.searchSlot, in: searchGlass,
                                           isSource: true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .global).minY
                    } action: { searchFieldTop = $0 }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        // Taller content than this overflows the frame rather than growing it.
        .frame(height: logoRowHeight, alignment: .top)
        .overlay {
            searchControl.matchedGeometryEffect(id: Self.searchSlot, in: searchGlass,
                                                isSource: false)
        }
        .onChange(of: isSearchFocused) { _, focused in
            if !focused && search.isEmpty { closeSearch() }
        }
    }

    private var logoRow: some View {
        HStack {
            brandHeader
            Spacer(minLength: 8)
            Color.clear
                .frame(width: Self.searchButtonSize, height: Self.searchButtonSize)
                .matchedGeometryEffect(id: Self.searchSlot, in: searchGlass,
                                       isSource: !isSearchOpen)
        }
        .padding(.horizontal, 20)
        .padding(.top, -10)
        // The logo row, beside the button, puts the keyboard away too.
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            logoRowHeight = $0
        }
    }

    /// The logo and the app's name. The logo is a template image, so it takes
    /// the text color: black in light mode, white in dark.
    private var brandHeader: some View {
        HStack(spacing: 8) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: logoHeight)
            Text(AppName.display)
                .font(.title3.bold())
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppName.display)
        .accessibilityAddTraits(.isHeader)
    }

    /// The glass, in whichever slot is showing: the button, or the field.
    /// One magnifying glass slides between the button's centre and the
    /// field's leading edge; the field fades in beside it.
    private var searchControl: some View {
        HStack(spacing: isSearchOpen ? 8 : 0) {
            Image(systemName: "magnifyingglass")
                // Body size in the field, title 3 (20 over 17) as the button.
                .scaleEffect(isSearchOpen ? 1 : 20 / 17)
                .opacity(isSearchOpen ? 0.6 : 1)
                .accessibilityHidden(true)
            // Kept in the hierarchy while shut, at no width, so it can take
            // focus before the glass starts to move.
            TextField("Search Chats", text: $search)
                .focused($isSearchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier(.historySearch)
                .frame(width: isSearchOpen ? nil : 0)
                .opacity(isSearchOpen ? 1 : 0)
                .allowsHitTesting(isSearchOpen)
                .accessibilityHidden(!isSearchOpen)
            if isSearchOpen {
                if !search.isEmpty {
                    Button {
                        search = ""
                        closeSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier(.historySearchClear)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: isSearchOpen ? .leading : .center)
        .overlay {
            if !isSearchOpen {
                Button(action: openSearch) {
                    Color.clear.contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search Chats")
            }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private static let searchSlot = "search"
    private static let searchButtonSize: CGFloat = 44
    /// A spring that settles without overshooting the field's edges.
    private static let searchMorph: Animation = .spring(duration: 0.45, bounce: 0.12)

    private func openSearch() {
        // Focus first, then move. Bringing the keyboard up holds the main
        // thread for 40-70 ms on this phone; started together, that pause
        // landed in the move's first frames and made it stutter. Here it
        // comes before the glass moves, and the move then runs at 120 Hz.
        isSearchFocused = true
        Task { withAnimation(Self.searchMorph) { isSearchOpen = true } }
    }

    private func closeSearch() {
        isSearchFocused = false
        withAnimation(Self.searchMorph) { isSearchOpen = false }
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
                    .modifier(EdgeBlur(edges: blurEdges))

                ForEach(visibleSections, id: \.group) { section in
                    Section {
                        ForEach(section.entries, id: \.id) { entry in
                            row(entry)
                                .modifier(EdgeBlur(edges: blurEdges))
                        }
                    } header: {
                        Text(section.group.rawValue)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                            .modifier(EdgeBlur(edges: blurEdges))
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
            // With the search focused and empty, the tap was meant to put the
            // keyboard away: nothing has been searched for. With text, the
            // rows are its results, and a tap opens one.
            if isSearchFocused && search.isEmpty {
                isSearchFocused = false
                return
            }
            // Opens the chat whichever model wrote it. The model in use
            // continues it; the composer is where another one is picked.
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

/// Where the search field begins above and the buttons begin below, on screen.
/// Measured from the bars themselves: the scroll view's own insets include
/// the status bar and home indicator, which put the blur's start in the
/// wrong place.
private struct ScrollEdges: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = .infinity
}

/// Blurs a piece of the chat list by how far it has gone under either bar.
/// Each row blurs as a whole, so the blur moves with the row as it scrolls.
///
/// At the top it runs from the search field's top edge to the top of the
/// screen, and the row also fades there, in place of the system's edge
/// effect: none at the field, rising to `maxFade` at the screen's edge. It
/// never goes fully clear, so the chats stay visible up to the top, as on the
/// chat screen. At the bottom it rises from the buttons' top edge over
/// `distance`, with no fade, which the system's edge effect does there.
private struct EdgeBlur: ViewModifier {
    let edges: ScrollEdges

    nonisolated private static let distance: CGFloat = 120
    nonisolated private static let radius: CGFloat = 2
    nonisolated private static let maxFade: CGFloat = 0.9

    func body(content: Content) -> some View {
        content.visualEffect { [edges] content, proxy in
            let frame = proxy.frame(in: .global)
            // From the search field's top (0) to the screen's (1).
            let top = edges.top > 0
                ? min(max(edges.top - frame.minY, 0) / edges.top, 1) : 0
            // Under the buttons, straight from their top edge. Eased in, it
            // showed only some 40 pt below the New Chat button.
            let bottom = min(max(frame.maxY - edges.bottom, 0) / Self.distance, 1)
            // Eased in at the top, so the blur begins gently.
            let t = max(top * top * (3 - 2 * top), bottom)
            return content.blur(radius: Self.radius * t)
                .opacity(1 - Self.maxFade * top)
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
