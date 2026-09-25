import Foundation
import Observation
import TurboFieldfare
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation
import TurboFieldfareRichText

/// Builds the `AppModel` the phone runs on.
///
/// `AppModel` is shared with the Mac app and its default inference client is
/// the in-process `RealInferenceClient`, which is the one iOS wants: the Mac
/// runs a second decode process so its UI never holds a model, and on the phone
/// a second process would be actively harmful under jetsam. So this is a view
/// layer over the existing app, not a second application — the only things set
/// here are the ones where the phone's measured answer differs from the Mac's.
@MainActor
enum ChatSession {
    /// Prompt tokens per chunked-prefill step.
    ///
    /// Pinned to the platform's cap rather than left at the shared 128 default,
    /// so it follows `PrefillRuntimeConfig.maxChunkTokens` (1024 on iOS). The
    /// KV ring is sized from that cap whatever is set here, so a smaller pin
    /// pays the ring's +152.4 MB and gets nothing for it. Measured on the
    /// iPhone 17 at a fixed 32 slots (2026-09-22), 1024 against 256 cuts
    /// prefill bytes **−70.6%** on the long case and **−42.1%** on medium, and
    /// changes no output. The cost that is actually this pin's is prefill
    /// scratch, which is sized from the configured chunk: about +94 MB over 256.
    ///
    /// A pin at the cap loses nothing to `auto` on short prompts. The cap is
    /// a ceiling, so a prompt shorter than one chunk still runs as one chunk
    /// and reads the same bytes. The 64-vs-256 short-case gap once cited against
    /// `auto` was run-to-run variance, not an effect.
    /// `auto` stays unreachable from here anyway: `RealInferenceSession.run`
    /// reads `runtimeOptions.prefillConfig` before the turn tokenizes its
    /// prompt.
    ///
    /// Where this pays in a chat: a first turn with a long prompt, and reopening
    /// a stored conversation, which replays the whole lineage through prefill.
    /// A follow-up turn prefills only its new message, since the conversation
    /// path reuses the retained KV.
    ///
    /// Safe to set per session: prefill size is deliberately outside
    /// `AppLoadedRuntimeKey`, so changing it never makes a loaded model stale.
    static let prefillChunkTokens = PrefillRuntimeConfig.maxChunkTokens

    static func makeModel() -> AppModel {
        // Before the model, whose store takes the writer lock.
        MockChats.applyLaunchArguments(modelDirectory: ModelLocation.directory)
        let model = AppModel(
            // Where `devicectl` pushes the model, and what
            // `AppModelLocation.resolve` falls through to inside a bundle,
            // where the package-root probe cannot match.
            modelDirectory: ModelLocation.directory,
            // The image tower needs Apple8; the A19 is Apple10. The pack itself
            // downloads from Settings, beside the model in the container.
            visionRuntimeSupported: AppModel.currentDeviceSupportsVisionRuntime,
            // Settings file and conversation store, both beside the model in
            // Application Support and so inside the container. `HistoryView`
            // is what reopens what the store writes.
            settingsPersistenceEnabled: true)
        // Slot count is *not* set here on purpose — it comes from
        // `MacAppSettings`, which tracks `RuntimeConfiguration
        // .productionExpertCacheSlots` and so resolves to 24 on iOS. That is
        // memory-funded speed, not a free win: slots are per layer, and 24
        // rests at about 3.3 GB in this app against about 4.1 GB at 32, which
        // left no room for the photo picker (2026-09-24). A settings file saved
        // before then keeps the count it holds.
        // After init, which is when the settings file is applied. The file does
        // not carry the chunk size, and `applyPersistedSettings` rebuilds the
        // options without it, back to the shared 128. It runs again only from
        // `setModelURL`, the Mac's model picker, which nothing on iOS calls.
        model.runtimeOptions.prefillChunkTokens = prefillChunkTokens
        return model
    }
}

/// Keeps `ResponseBlockSplitter` resumable across streaming ticks.
///
/// The splitter is incremental for a reason its own header states: re-scanning
/// a 10 KB fenced block on each of the ~1,200 ticks it takes to stream an
/// answer is quadratic. So the scan state is owned here, outside any view body,
/// and a tick costs the bytes that arrived rather than the bytes that are there.
@MainActor
@Observable
final class StreamingBlocks {
    private(set) var split = ResponseBlockSplitter.Split()
    /// The exact string `split` was produced from.
    private(set) var response = ""

    /// Which half of a turn this splits — which is also what colour it draws
    /// in, since reasoning and answer differ in nothing else.
    enum Role {
        case answer
        case reasoning
    }

    @ObservationIgnored private let renderer: ResponseMarkdownRenderer

    init(_ role: Role = .answer) {
        switch role {
        case .answer:
            renderer = ResponseMarkdownRenderer().setting(.phone)
        case .reasoning:
            // Grey, and grey the whole way through. The typesetter takes its
            // tint from the run it sits in, so an equation the model writes
            // while reasoning comes out matching the prose around it instead of
            // sitting inside grey text at full contrast.
            renderer = ResponseMarkdownRenderer()
                .setting(.phone)
                .drawingBody(in: .transcriptSecondaryLabel)
        }
    }

    /// Committed blocks, parsed once each instead of once per tick.
    ///
    /// Keyed by UTF-8 start offset rather than by the block's own text, because
    /// hashing the text would cost the whole response on every tick — the
    /// quadratic this type exists to avoid. The splitter guarantees a committed
    /// block never moves or changes within one scan lineage, so `start`
    /// identifies its bytes; a diverging response breaks that lineage and drops
    /// the table along with the split.
    @ObservationIgnored private var sealed: [Int: NSAttributedString] = [:]

    /// Fragments that are not whole blocks: table cells, and indented reasoning
    /// read back as prose. Keyed by text rather than by offset because a cell
    /// has no block identity of its own — and affordably so, unlike the whole
    /// response, which is what the offset key above exists to avoid hashing.
    @ObservationIgnored private var fragments: [String: NSAttributedString] = [:]

    /// Rescans only what arrived.
    ///
    /// The resume contract is that the new text *extends* the text the previous
    /// split came from; the splitter does not re-examine committed blocks, so a
    /// shorter or diverging response has to go through a full scan. That is not
    /// hypothetical here: a turn the runtime rewound clears `outputText`, and
    /// opening a stored conversation replaces it with a different answer
    /// entirely. Resuming across either would key committed block boundaries to
    /// bytes that are no longer present.
    func update(_ next: String) {
        guard next != response else { return }
        if next.hasPrefix(response) {
            // A fresh `Split()` resumed from is the same scan as a full one, so
            // the first tick of a turn needs no special case.
            split = ResponseBlockSplitter.split(next, resuming: split)
        } else {
            split = ResponseBlockSplitter.split(next)
            sealed.removeAll(keepingCapacity: true)
        }
        response = next
    }

    func reset() {
        split = ResponseBlockSplitter.Split()
        response = ""
        sealed.removeAll(keepingCapacity: true)
        fragments.removeAll(keepingCapacity: true)
    }

    /// A fragment, rendered by *this* role's renderer.
    ///
    /// Math is typeset even while the turn streams, unlike an open block: a
    /// table cell and a dedented paragraph are both complete as written, so
    /// there is no half-typed equation to fail on.
    func renderedText(_ text: String) -> NSAttributedString {
        if let hit = fragments[text] { return hit }
        let drawn = renderer.render(text, typesetsMath: true).attributedString
        // A streaming table rewrites its last row every tick, so this table
        // grows with ticks rather than with cells. Dropping it whole beats
        // ageing it, exactly as the Mac's block cache decided.
        if fragments.count >= 256 { fragments.removeAll(keepingCapacity: true) }
        fragments[text] = drawn
        return drawn
    }

    /// A committed block's markdown and math, rendered once.
    func rendered(
        _ block: ResponseBlockSplitter.Block,
        in source: String
    ) -> NSAttributedString {
        if let hit = sealed[block.start] { return hit }
        let text = ResponseBlockSplitter.text(block.utf8Range, in: source)
        let drawn = renderer.render(text, typesetsMath: true).attributedString
        sealed[block.start] = drawn
        return drawn
    }

    /// The block still arriving, rendered every tick because its bytes change
    /// every tick.
    ///
    /// Mirrors the Mac's progressive pass exactly. The tail is auto-closed so a
    /// half-typed marker does not sit on screen as raw source, and math is
    /// deliberately *not* typeset: a half-written equation cannot parse, and
    /// attempting it per tick would flicker the span between LaTeX and image on
    /// every token. Equations appear when the block seals.
    func renderedOpen(
        _ block: ResponseBlockSplitter.Block,
        in source: String
    ) -> NSAttributedString {
        let text = ResponseBlockSplitter.text(block.utf8Range, in: source)
        let closed = TailAutoClose.close(text, typesetsMath: false)
        return renderer.render(closed, typesetsMath: false).attributedString
    }
}
