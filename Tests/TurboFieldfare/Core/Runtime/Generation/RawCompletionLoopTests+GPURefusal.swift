import Foundation
import Metal
import Synchronization
import Testing
import TurboFieldfareValidationSupport

@testable import TurboFieldfare

/// A refused forward (an iPhone app in the background, or a locked phone) is
/// retried in place or ends the turn at a token boundary, and never loses the
/// tokens before it.
extension RawCompletionLoopTests {
  /// Refuses the forward at each listed position once, as iOS does while the
  /// app may not use the GPU, and otherwise defers to `inner`.
  final class RefusingProducer: LogitProducer, @unchecked Sendable {
    private let inner: ScriptedLogitProducer
    private var refusals: Set<Int>
    private(set) var produced: [Int] = []

    init(_ inner: ScriptedLogitProducer, refusingAt positions: Set<Int>) {
      self.inner = inner
      self.refusals = positions
    }

    func reset() { inner.reset() }

    func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {
      if refusals.remove(position) != nil {
        throw GPUWorkNotPermitted(detail: "test refusal at \(position)")
      }
      produced.append(position)
      try await inner.produce(token: token, position: position, into: logits)
    }
  }

  private func decode(
    refusingAt positions: Set<Int>,
    onGPURefused: GPURefusalHandler?
  ) async throws -> (result: RawDecodeResult, tokens: [Int32], prompt: [Int32]) {
    let ctx = try MetalContext()
    let tok = try await GFTokenizer.load()
    let ids = ["a", "b", "c", "d"].map { tok.encode($0, addBOS: false).first! }
    let prompt = tok.encode("go", addBOS: true)
    let producer = RefusingProducer(
      ScriptedLogitProducer(vocabSize: tok.vocabSize, step: automaton(ids, end: tok.eosID)),
      refusingAt: positions)
    var tokens: [Int32] = []
    let result = try await runRawCompletion(
      producer: producer, tokenizer: tok, promptIds: prompt,
      config: GenerationConfig(maxNewTokens: 64, temperature: 0),
      context: ctx, scratch: try RawCompletionScratch(context: ctx, vocab: tok.vocabSize),
      prefillConfig: .off,
      onGPURefused: onGPURefused
    ) { progress in
      if case .token(_, let id, _) = progress { tokens.append(id) }
    }
    return (result, tokens, prompt)
  }

  @Test func aRefusedTokenIsRetriedInPlaceAndTheReplyIsUnchanged() async throws {
    let plain = try await decode(refusingAt: [], onGPURefused: nil)
    let asked = Mutex(0)
    // The prompt replays through `produce` under `.off`, so decode's second
    // forward sits at prompt + 1.
    let position = plain.prompt.count + 1
    let refused = try await decode(refusingAt: [position]) { _ in
      asked.withLock { $0 += 1 }
      return .retry
    }

    #expect(asked.withLock { $0 } == 1)
    #expect(refused.tokens == plain.tokens)
    #expect(refused.result.reason == plain.result.reason)
    #expect(refused.result.kvPosition == plain.result.kvPosition)
    #expect(refused.result.kvBackedTokenIDs == plain.result.kvBackedTokenIDs)
  }

  @Test func aStopWhileRefusedKeepsEverythingBeforeTheRefusedToken() async throws {
    let plain = try await decode(refusingAt: [], onGPURefused: nil)
    let position = plain.prompt.count + 1
    let stopped = try await decode(refusingAt: [position]) { _ in .stop }

    // Two tokens were shown; the second never reached the KV.
    #expect(stopped.result.reason == .cancelled)
    #expect(stopped.tokens == Array(plain.tokens.prefix(2)))
    #expect(stopped.result.kvPosition == position)
    #expect(stopped.result.kvBackedTokenIDs == plain.prompt + [plain.tokens[0]])
    #expect(stopped.result.uncommittedBoundaryTokenIDs == [plain.tokens[1]])
  }

  @Test func withoutAHandlerARefusalStillThrows() async throws {
    let plain = try await decode(refusingAt: [], onGPURefused: nil)
    await #expect(throws: GPUWorkNotPermitted.self) {
      _ = try await self.decode(refusingAt: [plain.prompt.count + 1], onGPURefused: nil)
    }
  }

  @Test func aHandlerThatThrowsEndsTheRunWithItsError() async throws {
    let plain = try await decode(refusingAt: [], onGPURefused: nil)
    await #expect(throws: CancellationError.self) {
      _ = try await self.decode(refusingAt: [plain.prompt.count + 1]) { _ in
        throw CancellationError()
      }
    }
  }

  @Test func onlyThePermissionCodeCountsAsARefusal() {
    let refused = NSError(
      domain: MTLCommandBufferErrorDomain,
      code: Int(MTLCommandBufferError.Code.notPermitted.rawValue))
    let failed = NSError(
      domain: MTLCommandBufferErrorDomain,
      code: Int(MTLCommandBufferError.Code.internal.rawValue))
    let elsewhere = NSError(
      domain: NSCocoaErrorDomain, code: Int(MTLCommandBufferError.Code.notPermitted.rawValue))
    #expect(isGPUWorkRefusal(refused))
    #expect(!isGPUWorkRefusal(failed))
    #expect(!isGPUWorkRefusal(elsewhere))
    #expect(!isGPUWorkRefusal(nil))
  }
}
