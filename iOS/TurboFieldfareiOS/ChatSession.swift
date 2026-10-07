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
        ModelLocation.applyLaunchArguments()
        // Before the model, whose store takes the writer lock.
        MockChats.applyLaunchArguments(modelDirectory: ModelLocation.directory)
        let model = AppModel(
            // Where `devicectl` pushes the model, and what
            // `AppModelLocation.resolve` falls through to inside a bundle,
            // where the package-root probe cannot match.
            modelDirectory: ModelLocation.directory,
            // The installer is bound to one checkpoint, so it has to be the one
            // the folder holds, or a finished install reads as a mismatch.
            installer: RepackModelInstallerClient(descriptor: descriptor(
                forFolder: ModelLocation.folderName)),
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
        // `setModelURL`, which the model menu reaches through `selectModel`
        // below, and that re-pins it.
        model.runtimeOptions.prefillChunkTokens = prefillChunkTokens
        return model
    }

    /// The text model a folder holds. A folder no model is named for is a
    /// `--model-dir` test copy, which is always the default model.
    static func descriptor(forFolder name: String) -> AppModelInstallDescriptor {
        AppModelInstallDescriptor.textModels.first { $0.directoryName == name }
            ?? .default
    }

    /// Switches the phone to another text model: its own folder, its own
    /// install, and the same conversations and settings.
    ///
    /// A `--model-dir` launch keeps its folder pinned, since that flag exists
    /// so a test copy is never mistaken for the real install; the switch still
    /// happens for this run but is not remembered.
    static func selectModel(_ descriptor: AppModelInstallDescriptor,
                            in model: AppModel,
                            openingConversation conversationID: UUID? = nil) {
        guard model.canSelectModel, descriptor != model.installDescriptor else { return }
        let wasLoaded = model.loadState.isReady || model.loadState.isLoading
        if !ModelLocation.isFolderPinnedByLaunchArgument {
            ModelLocation.rememberSelectedFolder(descriptor.directoryName)
        }
        model.selectModel(descriptor,
                          at: ModelLocation.directory(named: descriptor.directoryName),
                          openingConversation: conversationID)
        // `setModelURL` re-applies the settings file, which does not carry the
        // chunk size and resets it to the shared 128.
        model.runtimeOptions.prefillChunkTokens = prefillChunkTokens
        // Swapping one loaded model for another should leave a loaded model,
        // not a Load button. `beginLoad` waits for the unload the switch just
        // started, so the two are never resident together.
        if wasLoaded, model.canLoadModel {
            model.loadModel()
        }
    }

    /// The composer's Load or Download for a model picked in its menu.
    ///
    /// Switches to it with the chat on screen kept on screen: the chat is
    /// reopened from its stored copy, and its next send replays it into the
    /// new model. An installed model is then loaded; one that is not opens
    /// its download in place of the chat, which comes back once it is done.
    static func switchModel(to descriptor: AppModelInstallDescriptor,
                            in model: AppModel) {
        guard model.canSelectModel, descriptor != model.installDescriptor else { return }
        selectModel(descriptor, in: model,
                    openingConversation: model.history.selection)
        if model.canLoadModel {
            model.loadModel()
        }
    }

    /// Whether a text model is installed on the phone, judged the same way the
    /// app judges the one it is running.
    static func isInstalled(_ descriptor: AppModelInstallDescriptor,
                            current model: AppModel) -> Bool {
        if descriptor == model.installDescriptor { return model.isModelInstalled }
        // The probe hashes the manifest, and the chat list asks once per row
        // on every render, so the answer is kept until the manifest changes.
        let directory = ModelLocation.directory(named: descriptor.directoryName)
        let manifest = directory.appendingPathComponent("manifest.json")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: manifest.path))?[
            .modificationDate] as? Date
        if let cached = installedCache[descriptor.key], cached.stamp == stamp {
            return cached.installed
        }
        let installed = stamp != nil && AppModelInstallationProbe.status(
            at: directory, descriptor: descriptor) == .complete
        installedCache[descriptor.key] = (stamp, installed)
        return installed
    }

    private static var installedCache: [String: (stamp: Date?, installed: Bool)] = [:]
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
    /// The tail is auto-closed so a half-typed marker does not sit on screen as
    /// raw source. Unlike the Mac's progressive pass, an equation the model is
    /// still writing is left off screen rather than shown as LaTeX, which is
    /// what lets every equation that *is* on screen be typeset: each one
    /// appears once, already rendered, instead of jumping from source to
    /// formula when its block seals. Finished equations cost one typeset each,
    /// since `MathRenderCache` serves every later tick. See `StreamingHoldback`.
    func renderedOpen(
        _ block: ResponseBlockSplitter.Block,
        in source: String
    ) -> NSAttributedString {
        let text = StreamingHoldback.visible(
            ResponseBlockSplitter.text(block.utf8Range, in: source), kind: block.kind)
        // Closing an unfinished `$$` is not wanted even though math is typeset:
        // the hold-back already removed it, except past its limit, where a
        // closed copy would be re-typeset on every token as it grew.
        let closed = TailAutoClose.close(text, typesetsMath: false)
        return renderer.render(closed, typesetsMath: true).attributedString
    }
}
