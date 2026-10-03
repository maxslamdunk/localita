import Foundation
import Testing

@testable import TurboFieldfare

extension PreadExpertStreamerTests {
  /// Aging follows its default unless `TURBO_FIELDFARE_EXPERT_CACHE_AGING` is
  /// `1` or `0`.
  @Test func countAgingDefaultAndOverrides() {
    let key = PreadExpertStreamer.countAgingEnvironmentKey
    for byDefault in [false, true] {
      #expect(PreadExpertStreamer.usesCountAging(
        environment: [:], enabledByDefault: byDefault) == byDefault)
      #expect(PreadExpertStreamer.usesCountAging(
        environment: [key: "other"], enabledByDefault: byDefault) == byDefault)
      #expect(PreadExpertStreamer.usesCountAging(
        environment: [key: "1"], enabledByDefault: byDefault))
      #expect(!PreadExpertStreamer.usesCountAging(
        environment: [key: "0"], enabledByDefault: byDefault))
    }
  }

  private func agingStreamer(_ ages: Bool, url: URL) throws -> PreadExpertStreamer {
    try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: MetalContext().device,
      slotCount: 2, fileDescriptor: nil, agesUseCounts: ages)
  }

  /// Expert 0 used 10 times, then expert 1 used 8 times. Plain LFU still
  /// ranks 0 higher (10 against 8) and evicts 1 for the next miss. With
  /// aging 0's count has decayed to about 6.9 against 1's 7.2, so 0 goes.
  @Test(arguments: [false, true])
  func agingEvictsAnExpertWhoseUseIsOld(ages: Bool) throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try agingStreamer(ages, url: url)

    for _ in 0..<10 { _ = try streamer.loadExpertsCached(experts: [0]) }
    for _ in 0..<8 { _ = try streamer.loadExpertsCached(experts: [1]) }
    _ = try streamer.loadExpertsCached(experts: [2])

    #expect(streamer.residentExperts() == (ages ? [1, 2] : [0, 2]))
  }

  /// With aging, `contextDidReset()` forgets the counts: expert 0's ten uses
  /// before the reset no longer outrank expert 1's one use after it. Without
  /// aging it does nothing.
  @Test(arguments: [false, true])
  func contextResetForgetsCountsOnlyWithAging(ages: Bool) throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try agingStreamer(ages, url: url)

    for _ in 0..<10 { _ = try streamer.loadExpertsCached(experts: [0]) }
    streamer.contextDidReset()
    #expect(streamer.residentExperts() == [0])
    _ = try streamer.loadExpertsCached(experts: [1])
    _ = try streamer.loadExpertsCached(experts: [2])

    #expect(streamer.residentExperts() == (ages ? [1, 2] : [0, 2]))
  }
}
