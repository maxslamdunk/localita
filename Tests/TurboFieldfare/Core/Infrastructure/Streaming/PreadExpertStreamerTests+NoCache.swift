import Foundation
import Testing

@testable import TurboFieldfare

extension PreadExpertStreamerTests {
  /// `F_NOCACHE` follows the platform default unless
  /// `TURBO_FIELDFARE_EXPERT_READ_NOCACHE` is `1` or `0`.
  @Test func fileCacheBypassDefaultAndOverrides() {
    let key = PreadExpertStreamer.readNoCacheEnvironmentKey
    for byDefault in [false, true] {
      #expect(PreadExpertStreamer.readsBypassFileCache(
        environment: [:], enabledByDefault: byDefault) == byDefault)
      #expect(PreadExpertStreamer.readsBypassFileCache(
        environment: [key: "other"], enabledByDefault: byDefault) == byDefault)
      #expect(PreadExpertStreamer.readsBypassFileCache(
        environment: [key: "1"], enabledByDefault: byDefault))
      #expect(!PreadExpertStreamer.readsBypassFileCache(
        environment: [key: "0"], enabledByDefault: byDefault))
    }
  }

  /// On by default on iOS only; the Mac measured neutral (IO-03).
  @Test func fileCacheBypassIsTheIOSDefault() {
    #if os(iOS)
    #expect(PreadExpertStreamer.readsBypassFileCacheByDefault)
    #else
    #expect(!PreadExpertStreamer.readsBypassFileCacheByDefault)
    #endif
  }
}
