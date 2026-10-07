import Foundation
import Testing
@testable import TurboFieldfareRepackCore

struct SupportedModelSourceTests {
    /// The allowlist is the gate a remote install passes before any payload
    /// byte is read, so every catalog entry has to be in it under its own repo.
    @Test func everyCatalogEntryIsAKnownFingerprint() {
        for model in SupportedModelSource.all {
            #expect(SourceFingerprint.knownFingerprints[model.repoID] == model.sourceIndexSHA256)
            #expect(SourceFingerprint.modelID(forIndexSha256: model.sourceIndexSHA256)
                == model.repoID)
        }
        #expect(SourceFingerprint.modelID(forIndexSha256: String(repeating: "0", count: 64))
            == nil)
    }

    @Test func keysAndFoldersAreDistinct() {
        let keys = SupportedModelSource.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(SupportedModelSource.gemma4.directoryName == "gemma4.gturbo")
        #expect(SupportedModelSource.supergemma4.directoryName == "supergemma4.gturbo")
        #expect(SupportedModelSource.model(key: "supergemma4") == SupportedModelSource.supergemma4)
        #expect(SupportedModelSource.model(key: "nope") == nil)
    }

    /// The legacy statics are what the image-pack installer and the CLI's
    /// vision modes still read; they must keep naming the reference model.
    @Test func legacyStaticsStillNameTheReferenceModel() {
        #expect(SupportedModelSource.repoID == "mlx-community/gemma-4-26b-a4b-it-4bit")
        #expect(SupportedModelSource.revision == SupportedModelSource.gemma4.revision)
        #expect(SupportedModelSource.sourceIndexSHA256
            == "bf198c9f5ea6462addca1966e5dd669c407537a876e82cf06db9084c5c850b13")
    }

    /// The image pack is cut from the vision tower, which only the reference
    /// checkpoint ships.
    @Test func onlyTheReferenceModelHasAVisionTower() {
        #expect(SupportedModelSource.gemma4.hasVisionTower)
        #expect(!SupportedModelSource.supergemma4.hasVisionTower)
    }

    /// A chat moves between models whose tokenizer digests match, and chats
    /// recorded before digests were stored take theirs from here. The two
    /// pinned checkpoints ship the same `tokenizer.json`.
    @Test func everyEntryPinsATokenizerDigestAndTheTwoShareOne() {
        for model in SupportedModelSource.all {
            #expect(model.tokenizerSHA256.range(
                of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        }
        #expect(SupportedModelSource.gemma4.tokenizerSHA256
            == SupportedModelSource.supergemma4.tokenizerSHA256)
    }

    @Test func installOptionsPinTheEntrysSource() {
        let options = SupportedModelSource.supergemma4.installOptions(
            outputDirectory: URL(fileURLWithPath: "/tmp/supergemma4.gturbo"),
            overwrite: false,
            token: nil)
        #expect(options.repoID == "Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2")
        #expect(options.revision == "1ecb7582718b813fc4c7b5c3131b2b7053787f00")
        #expect(options.requireKnownSource)
    }
}
