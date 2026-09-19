import Foundation

/// Splits streamed assistant text into reasoning and answer.
///
/// The model says which is which. It opens a channel with `<|channel>`, names
/// it on the first line (`thought`, `final`, …), and closes it with `<channel|>`
/// — so this is a matter of reading a marker, not of guessing from the prose.
/// What makes it worth a type is that the markers arrive one token at a time:
/// a channel's name can be split across two deltas, so the label has to be
/// accumulated until its newline before the channel it names is known.
///
/// Extracted from `StructuredAssistantDecoder` rather than copied beside it.
/// That decoder is the server's, and it *discards* thought text, because the
/// OpenAI-shaped contract it serves has nowhere to put reasoning. The app wants
/// the opposite — reasoning on screen, in grey, as it arrives. Those are two
/// renderings of one state machine, and a second implementation of it would be
/// free to drift on exactly the detail nobody re-derives correctly: that a
/// control token's own delta belongs to the channel in effect *before* it.
public struct ChannelRouter: Equatable, Sendable {
    public enum Routed: Equatable, Sendable {
        case visible(String)
        case thought(String)
    }

    private enum Channel: Equatable, Sendable {
        case thought
        case visible
        case label
    }

    private var channel: Channel = .visible
    private var label = ""

    public init() {}

    /// Whether the router is inside a thought block, label included.
    ///
    /// For presentation only — a caller deciding whether to draw a "thinking"
    /// affordance. Routing never consults it.
    public var isReasoning: Bool { channel != .visible }

    /// `<|channel>` — the next line names the channel being opened.
    public mutating func beginLabel() {
        label = ""
        channel = .label
    }

    /// `<channel|>` — back to answer text.
    public mutating func endChannel() {
        channel = .visible
    }

    /// Routes one delta under the current channel.
    public mutating func route(_ delta: String) -> [Routed] {
        switch channel {
        case .thought:
            return delta.isEmpty ? [] : [.thought(delta)]
        case .visible:
            return delta.isEmpty ? [] : [.visible(delta)]
        case .label:
            label += delta
            // Still mid-name: hold, or a label split across two tokens would be
            // read as two labels and the channel resolved from the first half.
            guard let newline = label.firstIndex(of: "\n") else { return [] }
            let name = label[..<newline]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let contentStart = label.index(after: newline)
            let content = String(label[contentStart...])
            // Everything that is not explicitly the answer is reasoning. An
            // unknown channel name is treated as thought deliberately: a new
            // one appearing in a future checkpoint should be hidden behind the
            // toggle, not spilled into the answer.
            channel = name == "final" || name == "answer" ? .visible : .thought
            label = ""
            guard !content.isEmpty else { return [] }
            return channel == .visible ? [.visible(content)] : [.thought(content)]
        }
    }

    /// Routes one token for a caller with no tool-call framing to interleave.
    ///
    /// The delta on a control token is text the detokenizer held back from
    /// *before* that token — a skipped special contributes no characters of its
    /// own — so it is routed under the channel in effect now, before the token
    /// changes it. Getting this backwards moves the last word of a thought into
    /// the answer.
    public mutating func consume(tokenID: Int32,
                                 delta: String,
                                 channelStartID: Int32,
                                 channelEndID: Int32) -> [Routed] {
        let isControl = tokenID == channelStartID || tokenID == channelEndID
        guard isControl else { return route(delta) }
        let carried = delta.isEmpty ? [] : route(delta)
        if tokenID == channelStartID {
            beginLabel()
        } else {
            endChannel()
        }
        return carried
    }

    /// Routes the flush tail, which is not tied to a token ID.
    ///
    /// Without it a generation stopped inside a thought block leaks the bytes
    /// the detokenizer was still holding into visible text.
    public mutating func routeTail(_ text: String) -> [Routed] {
        text.isEmpty ? [] : route(text)
    }
}

public extension Array where Element == ChannelRouter.Routed {
    /// The answer half of one token's routing.
    ///
    /// A single token can yield both halves — the delta arriving on `<channel|>`
    /// closes a thought while what follows opens the answer — so these are two
    /// projections of one array rather than an either/or.
    var visibleText: String {
        reduce(into: "") {
            if case .visible(let text) = $1 { $0 += text }
        }
    }

    /// The reasoning half of one token's routing.
    var thoughtText: String {
        reduce(into: "") {
            if case .thought(let text) = $1 { $0 += text }
        }
    }
}
