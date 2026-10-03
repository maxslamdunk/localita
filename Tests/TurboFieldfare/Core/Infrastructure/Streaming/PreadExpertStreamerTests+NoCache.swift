import Foundation
import Testing

@testable import TurboFieldfare

extension PreadExpertStreamerTests {
  /// `F_NOCACHE` is opt-in: only `TURBO_FIELDFARE_EXPERT_READ_NOCACHE=1` turns it on.
  @Test func fileCacheBypassIsOptIn() {
    let key = PreadExpertStreamer.readNoCacheEnvironmentKey
    #expect(!PreadExpertStreamer.readsBypassFileCache(environment: [:]))
    #expect(!PreadExpertStreamer.readsBypassFileCache(environment: [key: "0"]))
    #expect(PreadExpertStreamer.readsBypassFileCache(environment: [key: "1"]))
  }
}
