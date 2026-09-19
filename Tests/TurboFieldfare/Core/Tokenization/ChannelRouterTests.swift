import Testing
import TurboFieldfare

/// The split between reasoning and answer, asserted directly.
///
/// `StructuredAssistantDecoder`'s own suite covers this state machine, but only
/// through a consumer that *discards* thought text — so every assertion there is
/// about what stays visible. The `.thought(_)` case exists solely for the app,
/// and before this file nothing asserted it at all.
///
/// No tokenizer and no model: the router takes the two control IDs as
/// parameters, so the whole machine is exercisable with numbers chosen here.
@Suite("Channel router")
struct ChannelRouterTests {
    private let start: Int32 = 100
    private let end: Int32 = 101
    private let word: Int32 = 7

    private func feed(
        _ router: inout ChannelRouter,
        _ tokens: [(Int32, String)]
    ) -> [ChannelRouter.Routed] {
        tokens.flatMap {
            router.consume(tokenID: $0.0, delta: $0.1,
                           channelStartID: start, channelEndID: end)
        }
    }

    @Test func textOutsideAnyChannelIsVisible() {
        var router = ChannelRouter()
        #expect(feed(&router, [(word, "Hello")]) == [.visible("Hello")])
    }

    @Test func thoughtChannelTextIsKeptAsThoughtRatherThanDropped() {
        var router = ChannelRouter()
        let routed = feed(&router, [
            (start, ""),
            (word, "thought\n"),
            (word, "weighing it up"),
        ])
        #expect(routed == [.thought("weighing it up")])
    }

    /// The reason this is a type and not a comparison.
    ///
    /// A channel's name arrives as tokens like any other text, so it can be cut
    /// anywhere. Resolving on the first delta would read "tho" as the whole
    /// label and route the rest under a channel nobody opened.
    @Test func aLabelSplitAcrossDeltasResolvesOnlyAtItsNewline() {
        var router = ChannelRouter()
        #expect(feed(&router, [(start, ""), (word, "tho")]).isEmpty)
        #expect(feed(&router, [(word, "ught\n")]).isEmpty)
        #expect(feed(&router, [(word, "after")]) == [.thought("after")])
    }

    @Test func finalAndAnswerLabelsAreTheVisibleChannel() {
        for name in ["final", "answer"] {
            var router = ChannelRouter()
            let routed = feed(&router, [(start, ""), (word, "\(name)\nHi")])
            #expect(routed == [.visible("Hi")])
        }
    }

    /// An unrecognised channel is hidden, not shown.
    ///
    /// Deliberate: a checkpoint that introduces a new internal channel should
    /// have it land behind the toggle rather than spill into the answer.
    @Test func anUnknownLabelIsTreatedAsReasoning() {
        var router = ChannelRouter()
        let routed = feed(&router, [(start, ""), (word, "scratchpad\nnoise")])
        #expect(routed == [.thought("noise")])
    }

    /// The rule that is easiest to get backwards.
    ///
    /// The delta on `<channel|>` is text the detokenizer held back from *before*
    /// that token — a skipped special contributes no characters of its own — so
    /// it belongs to the thought that is ending, not to the answer beginning.
    @Test func aControlTokensOwnDeltaBelongsToTheChannelItCloses() {
        var router = ChannelRouter()
        let routed = feed(&router, [
            (start, ""),
            (word, "thought\n"),
            (word, "reasoning"),
            (end, " still reasoning"),
            (word, "the answer"),
        ])
        #expect(routed == [
            .thought("reasoning"),
            .thought(" still reasoning"),
            .visible("the answer"),
        ])
    }

    @Test func aTailFlushedInsideAThoughtStaysThought() {
        var router = ChannelRouter()
        _ = feed(&router, [(start, ""), (word, "thought\n")])
        #expect(router.routeTail("cut off here") == [.thought("cut off here")])
    }

    @Test func aTailWithNoTextRoutesNothing() {
        var router = ChannelRouter()
        #expect(router.routeTail("").isEmpty)
    }

    /// One token can produce both halves, which is why the event carries two
    /// deltas rather than a string and a flag.
    @Test func theTwoProjectionsSplitASingleRoutingInTwo() {
        var router = ChannelRouter()
        _ = feed(&router, [(start, ""), (word, "thought\n")])
        let routed = feed(&router, [(end, "tail of the thought"), (word, "answer")])
        #expect(routed.thoughtText == "tail of the thought")
        #expect(routed.visibleText == "answer")
    }

    @Test func reasoningStateTracksTheOpenChannel() {
        var router = ChannelRouter()
        #expect(!router.isReasoning)
        _ = feed(&router, [(start, "")])
        #expect(router.isReasoning)          // inside the label, not yet resolved
        _ = feed(&router, [(word, "thought\n")])
        #expect(router.isReasoning)
        _ = feed(&router, [(end, "")])
        #expect(!router.isReasoning)
    }
}
