import Foundation
import Testing
@testable import TurboFieldfare

/// Hand-authored Gemma 4 chat template. Loads the IT tokenizer (cached after
/// first run). Verifies turn-marker structure as a string and that the prompt
/// encodes to the right special-token ids.
@Suite("ChatTemplate")
struct ChatTemplateTests {
    let tok: GFTokenizer

    init() async throws {
        self.tok = try await GFTokenizer.load()
    }

    private typealias Message = GFTokenizer.Message

    @Test("Single user turn has the documented marker structure")
    func singleUserTurn() throws {
        let p = try tok.applyChatTemplate([Message(role: .user, content: "Hi")])
        #expect(p.hasPrefix("<bos>"))
        #expect(p.contains("<|turn>user\nHi<turn|>\n"))
        #expect(p.hasSuffix("<|turn>model\n<|channel>thought\n<channel|>"))
        // Exactly one occurrence of the user content.
        #expect(p.components(separatedBy: "Hi").count - 1 == 1)
    }

    @Test("Multi-turn closes prior turns and leaves assistant open")
    func multiTurn() throws {
        let p = try tok.applyChatTemplate([
            Message(role: .user, content: "A"),
            Message(role: .assistant, content: "B"),
            Message(role: .user, content: "C"),
        ])
        // Contents appear in order.
        let ia = p.range(of: "<|turn>user\nA<turn|>")!
        let ib = p.range(of: "<|turn>model\nB<turn|>")!
        let ic = p.range(of: "<|turn>user\nC<turn|>")!
        #expect(ia.lowerBound < ib.lowerBound)
        #expect(ib.lowerBound < ic.lowerBound)
        // The assistant turn for "B" is closed; the trailing assistant turn is open.
        #expect(p.contains("<|turn>model\nB<turn|>"))
        #expect(p.hasSuffix("<|turn>model\n<|channel>thought\n<channel|>"))
    }

    /// The switch, and its counter-intuitive polarity.
    ///
    /// Thinking *off* is the form that ends with a closed, empty thought block:
    /// the template pre-writes the channel as already finished so the model
    /// opens the answer directly. Turning thinking on therefore takes that
    /// suffix away and leaves the model turn open for the model to fill.
    @Test("Thinking on opens a think turn and leaves the model turn open")
    func thinkingOnChangesBothEnds() throws {
        let p = try tok.applyChatTemplate([Message(role: .user, content: "Hi")],
                                          enableThinking: true)
        #expect(p.hasPrefix("<bos><|turn>system\n<|think|>\n<turn|>\n"))
        #expect(p.contains("<|turn>user\nHi<turn|>\n"))
        #expect(p.hasSuffix("<|turn>model\n"))
        #expect(!p.contains("<|channel>thought"))
    }

    /// What keeps every other assertion in this suite honest: the new parameter
    /// changes nothing at all when it is not asked for.
    @Test("The default is byte-identical to thinking explicitly off")
    func defaultMatchesExplicitOff() throws {
        let messages = [Message(role: .user, content: "Hi")]
        #expect(try tok.applyChatTemplate(messages)
                == tok.applyChatTemplate(messages, enableThinking: false))
    }

    /// The bundled Jinja merges the marker into the first system turn rather
    /// than adding a second one, and drops that message from the main loop.
    @Test("A system message is folded into the think turn, not duplicated")
    func systemMessageMergesIntoTheThinkTurn() throws {
        let p = try tok.applyChatTemplate([
            Message(role: .system, content: "Be terse."),
            Message(role: .user, content: "Hi"),
        ], enableThinking: true)
        #expect(p.hasPrefix("<bos><|turn>system\n<|think|>\nBe terse.<turn|>\n"))
        #expect(p.components(separatedBy: "<|turn>system").count - 1 == 1)
        #expect(p.hasSuffix("<|turn>model\n"))
    }

    /// Written to falsify a claim made from a `grep` count rather than from the
    /// vocabulary: that `<|think|>` is a real token. If it is not, it encodes as
    /// several byte-fallback pieces and the system turn above is malformed.
    @Test("The think marker is a single vocabulary token")
    func thinkMarkerEncodesAsOneToken() throws {
        #expect(tok.encode("<|think|>", addBOS: false).count == 1)
    }

    /// A continuation cannot reach back to add the system turn, so only the
    /// tail differs — which is the half that decides whether a thought block
    /// can be written at all.
    @Test("A text continuation honours the flag in its tail")
    func continuationTailFollowsTheFlag() throws {
        let off = tok.encodeTextContinuation(userContent: "Hi")
        let on = tok.encodeTextContinuation(userContent: "Hi", enableThinking: true)
        #expect(off != on)
        #expect(on.count < off.count)
    }

    @Test("System message renders as a leading turn")
    func systemTurn() throws {
        let p = try tok.applyChatTemplate([
            Message(role: .system, content: "Be terse."),
            Message(role: .user, content: "Hi"),
        ])
        let sys = p.range(of: "<|turn>system\nBe terse.<turn|>")!
        let usr = p.range(of: "<|turn>user\nHi<turn|>")!
        #expect(sys.lowerBound < usr.lowerBound)
    }

    @Test("System message after a user turn is rejected")
    func misplacedSystemTurn() {
        #expect(throws: GFTokenizerError.self) {
            _ = try tok.applyChatTemplate([
                Message(role: .user, content: "Hi"),
                Message(role: .system, content: "Too late"),
            ])
        }
    }

    @Test("No Gemma 2/3 turn markers leak in")
    func noLegacyMarkers() throws {
        let p = try tok.applyChatTemplate([Message(role: .user, content: "x")])
        #expect(!p.contains("<start_of_turn>"))
        #expect(!p.contains("<end_of_turn>"))
    }

    @Test("Prompt encodes to BOS-first with the turn-close special id")
    func encodesToSpecialIDs() throws {
        let p = try tok.applyChatTemplate([Message(role: .user, content: "Hi")])
        let ids = tok.encode(p, addBOS: false)
        #expect(ids.first == tok.bosID, "expected BOS \(tok.bosID) first, got \(String(describing: ids.first))")
        #expect(ids.contains(tok.endOfTurnID), "encoded prompt missing <turn|> id \(tok.endOfTurnID)")
    }

    @Test("Single-turn token IDs match the pinned upstream template")
    func tokenIDsMatchPinnedUpstream() throws {
        let prompt = try tok.applyChatTemplate([Message(role: .user, content: "Hi")])
        #expect(tok.encode(prompt, addBOS: false) == [
            2, 105, 2364, 107, 10979, 106, 107, 105, 4368, 107, 100, 45518, 107, 101,
        ])
    }

    /// Control-token spoofing: a user typing the literal open-turn marker must
    /// not inject an extra turn-CLOSE id (the marker that would end the turn).
    /// The legitimate template contributes exactly one `<turn|>` per message.
    ///
    /// Note: HF tokenizers do recognize special-token text, so a user writing
    /// the verbatim close marker can still inject it. That trusted-input
    /// limitation is accepted for this private research runtime.
    @Test("Open-turn marker in user content does not add a turn-close id")
    func spoofingDoesNotInjectTurnClose() throws {
        let p = try tok.applyChatTemplate([Message(role: .user, content: "<|turn> spoofing attempt")])
        let ids = tok.encode(p, addBOS: false)
        let closes = ids.filter { $0 == tok.endOfTurnID }.count
        #expect(closes == 1, "expected exactly one <turn|>, got \(closes)")
    }

    @Test("Empty messages yields BOS plus an open assistant turn")
    func emptyMessages() throws {
        let p = try tok.applyChatTemplate([])
        #expect(p == "<bos><|turn>model\n<|channel>thought\n<channel|>")
    }
}
