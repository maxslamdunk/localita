import Foundation

public enum StructuredAssistantEvent: Equatable, Sendable {
    case content(String)
    case toolCall(ParsedToolCall)
}

public final class StructuredAssistantDecoder: @unchecked Sendable {
    private let tokenizer: GFTokenizer
    private let allowedTools: Set<String>
    private let idGenerator: @Sendable () -> String
    /// Channel state, shared with the app's streaming path rather than held
    /// privately here. This decoder drops what the router calls thought; the
    /// app draws it. Same machine, two renderings — see `ChannelRouter`.
    private var router = ChannelRouter()
    private var toolTokens: [Int32]?
    private var emittedCalls = 0
    private var failed = false

    public init(tokenizer: GFTokenizer,
                allowedTools: Set<String>,
                idGenerator: @escaping @Sendable () -> String = {
                    "call_" + (0..<24).map { _ in String(format: "%x", UInt8.random(in: 0...15)) }.joined()
                }) {
        self.tokenizer = tokenizer
        self.allowedTools = allowedTools
        self.idGenerator = idGenerator
    }

    public func consume(tokenID: Int32, delta: String) throws -> [StructuredAssistantEvent] {
        guard !failed else { throw GemmaToolCallParserError.malformed }

        // A non-empty delta on a control token is text the detokenizer held
        // back from BEFORE the token (a skipped special contributes nothing of
        // its own), so it belongs to the channel state in effect now — route
        // it before the token changes that state. Inside a tool call the held
        // bytes are part of the payload, which is re-decoded from its IDs at
        // toolCallEnd, so nothing is lost by not routing there.
        let isControl = tokenID == tokenizer.channelStartID
            || tokenID == tokenizer.channelEndID
            || tokenID == tokenizer.toolCallStartID
            || tokenID == tokenizer.toolCallEndID
            || tokenID == tokenizer.toolResponseID
            || tokenID == tokenizer.toolResponseEndID
        var events: [StructuredAssistantEvent] = []
        if isControl, !delta.isEmpty, toolTokens == nil {
            events = routeText(delta)
        }

        if tokenID == tokenizer.channelStartID {
            router.beginLabel()
            return events
        }
        if tokenID == tokenizer.channelEndID {
            router.endChannel()
            return events
        }
        if tokenID == tokenizer.toolCallStartID {
            guard toolTokens == nil else {
                failed = true
                throw GemmaToolCallParserError.malformed
            }
            toolTokens = []
            return events
        }
        if tokenID == tokenizer.toolCallEndID {
            guard let tokens = toolTokens else {
                failed = true
                throw GemmaToolCallParserError.malformed
            }
            toolTokens = nil
            let text = tokenizer.decode(tokens, skipSpecialTokens: false)
            do {
                let call = try GemmaToolCallParser().parse(
                    text, allowedTools: allowedTools, id: idGenerator())
                emittedCalls += 1
                return events + [.toolCall(call)]
            } catch {
                failed = true
                throw error
            }
        }
        if tokenID == tokenizer.toolResponseID || tokenID == tokenizer.toolResponseEndID {
            guard emittedCalls > 0, toolTokens == nil else {
                failed = true
                throw GemmaToolCallParserError.malformed
            }
            return events
        }
        if var tokens = toolTokens {
            tokens.append(tokenID)
            guard tokens.count * MemoryLayout<Int32>.size <= GemmaToolCallParser.maximumBytes else {
                failed = true
                throw GemmaToolCallParserError.oversized
            }
            toolTokens = tokens
            return []
        }
        return routeText(delta)
    }

    /// Route text flushed at a stop boundary through the current channel
    /// state. The flush tail is not tied to a token ID, so it cannot go
    /// through `consume`; without this a generation cut off inside the
    /// thought channel would leak its held-back bytes into visible content.
    public func consumeTail(_ text: String) throws -> [StructuredAssistantEvent] {
        guard !failed else { throw GemmaToolCallParserError.malformed }
        guard toolTokens == nil, !text.isEmpty else { return [] }
        return routeText(text)
    }

    /// Thought text is dropped here, and only here.
    ///
    /// This decoder's contract is visible content plus tool calls, and
    /// reasoning is neither — an OpenAI-shaped response has nowhere to put it.
    /// The drop is therefore this type's policy, not the router's, which is
    /// what lets the app keep the same text instead of re-deriving the split.
    private func routeText(_ delta: String) -> [StructuredAssistantEvent] {
        router.route(delta).compactMap { routed in
            switch routed {
            case .visible(let text): return .content(text)
            case .thought: return nil
            }
        }
    }

    public func finish() throws {
        guard !failed, toolTokens == nil else {
            throw GemmaToolCallParserError.malformed
        }
    }

    public var hasToolCalls: Bool { emittedCalls > 0 }
}
