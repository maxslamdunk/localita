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
    /// Pinned rather than left at the shared 128 default. Measured on the
    /// iPhone 17 at a fixed 32 slots, 256 gives **7.596 / 6.204 / 5.206 tok/s**
    /// against 128's 7.005 / 6.181 / 4.786, cuts prefill time 31.9–32.3%, and
    /// changes no output — for about 36 MB of prefill scratch.
    ///
    /// `auto` is the measured-best *policy* but is not reachable from here:
    /// it resolves against the prompt length, and `RealInferenceSession.run`
    /// reads `runtimeOptions.prefillConfig` before the turn tokenizes its
    /// prompt. It would also not help — on a short prompt `auto` picks 64,
    /// which measured **slower** than 256 (7.209 against 7.596).
    ///
    /// Safe to set per session: prefill size is deliberately outside
    /// `AppLoadedRuntimeKey`, so changing it never makes a loaded model stale.
    static let prefillChunkTokens = 256

    static func makeModel() -> AppModel {
        let model = AppModel(
            // Where `devicectl` pushes the model, and what
            // `AppModelLocation.resolve` falls through to inside a bundle,
            // where the package-root probe cannot match.
            modelDirectory: ModelLocation.directory,
            // Images are out of this pass: the companion pack is side-loaded
            // and there is no attach affordance to reach it with.
            visionRuntimeSupported: false,
            // No settings file and no conversation store yet. Reopening a chat
            // is the history step; a store writing rows nothing can reopen is
            // state accumulating out of sight. One argument to flip when the
            // history UI lands.
            settingsPersistenceEnabled: false)
        // Slot count is *not* set here on purpose — it comes from
        // `MacAppSettings`, which tracks `RuntimeConfiguration
        // .productionExpertCacheSlots` and so resolves to 32 on iOS. That is
        // memory-funded speed, not a free win: slots are per layer, so 30 × 32
        // buffers is +1.61 GB, taking peak footprint to about 3.77 GB against
        // the measured 5.60 GB ceiling.
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
            renderer = ResponseMarkdownRenderer()
        case .reasoning:
            // Grey, and grey the whole way through. The typesetter takes its
            // tint from the run it sits in, so an equation the model writes
            // while reasoning comes out matching the prose around it instead of
            // sitting inside grey text at full contrast.
            renderer = ResponseMarkdownRenderer()
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
