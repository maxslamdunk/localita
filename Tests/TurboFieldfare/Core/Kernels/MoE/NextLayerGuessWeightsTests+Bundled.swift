import Foundation
import Metal
import Testing
@testable import TurboFieldfare

extension NextLayerGuessWeightsTests {
    private static let gemma4Snapshot =
        "sha256:bf198c9f5ea6462addca1966e5dd669c407537a876e82cf06db9084c5c850b13"

    /// The runtime ships the fitted guess for gemma4, intact, and none for
    /// any other model, which then falls back to the router.
    @Test func shipsFittedGuessForGemma4Only() throws {
        let device = try MetalContext().device
        func lookup(_ hash: String?) throws -> NextLayerGuessWeights? {
            try NextLayerGuessWeights.bundled(sourceSnapshotHash: hash, numLayers: 30,
                                              numExperts: 128, hiddenSize: 2816,
                                              device: device)
        }
        let gemma4 = try #require(try lookup(Self.gemma4Snapshot))
        #expect(gemma4.sha256
            == "b18242445534d452b7efb9c7d1c358884ef56637ad6003c187e5bced50dc3dcd")
        // supergemma4 shares the architecture but not the router weights.
        #expect(try lookup(
            "sha256:df3133d5e9e400092664cb2197413a32035189ab7c41f4b000f75a284abdc512") == nil)
        #expect(try lookup(nil) == nil)
    }

    @Test func earlyReadIsOnByDefaultAndTheEnvironmentOverrides() {
        let key = NextLayerExpertPrefetcher.environmentKey
        #expect(RuntimeConfiguration.production.earlyExpertRead)
        #expect(NextLayerExpertPrefetcher.isEnabled(environment: [:], enabledByDefault: true))
        #expect(!NextLayerExpertPrefetcher.isEnabled(environment: [:], enabledByDefault: false))
        #expect(!NextLayerExpertPrefetcher.isEnabled(environment: [key: "off"],
                                                     enabledByDefault: true))
        #expect(NextLayerExpertPrefetcher.isEnabled(environment: [key: "next-layer"],
                                                    enabledByDefault: false))
    }
}
