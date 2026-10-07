import Foundation
import Testing
import TurboFieldfareRepackCore
@testable import TurboFieldfareAppCore

/// Models added from a Hugging Face link: the saved list, how each is named
/// and foldered, the image pack it borrows, and deleting models.
@Suite(.serialized)
struct CommunityModelsTests {
    private let inspection = RemoteModelInspection(
        repoID: "Someone/gemma-4-26B-A4B-it-abliterated-MLX-4bit",
        resolvedCommit: String(repeating: "a", count: 40),
        sourceIndexSHA256: String(repeating: "b", count: 64),
        approximateDownloadBytes: 14_620_479_420,
        installedBytes: 14_318_364_732,
        hasVisionTower: true)

    private func temporaryParent(_ tag: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("turbofieldfare-community-\(tag)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }

    /// A complete install named as the app names a model's folder.
    private func install(_ descriptor: AppModelInstallDescriptor, in parent: URL) throws -> URL {
        let made = try makeCompleteModelInstall(descriptor.key, descriptor: descriptor, in: parent)
        let named = parent.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        try FileManager.default.moveItem(at: made, to: named)
        return named.standardizedFileURL
    }

    @Test func aRepositoryGetsOneStableFolder() {
        #expect(CommunityModelStore.key(forRepoID: "Some_One/Model.v1 (x)")
            == "hf-some_one--model.v1--x-")
        let descriptor = AppModelInstallDescriptor(
            community: CommunityModelRecord(inspection, name: "gemma-4-abliterated"))
        #expect(descriptor.directoryName
            == "hf-someone--gemma-4-26b-a4b-it-abliterated-mlx-4bit.gturbo")
        #expect(descriptor.isCommunity)
        #expect(descriptor.supportsImages)
        #expect(descriptor.revision == inspection.resolvedCommit)
        #expect(descriptor.shortName == "gemma-4-abliterated")
        #expect(descriptor.displayName == "gemma-4-26B-A4B-it-abliterated-MLX-4bit")
        #expect(!AppModelInstallDescriptor.default.isCommunity)
    }

    @Test func suggestedNamesDropTheFormatWords() {
        let cases = [
            "x/gemma-4-26B-A4B-it-abliterated-MLX-4bit": "gemma-4-abliterated",
            "x/Orion-26B-A4B-v1.1-mlx-4Bit": "Orion-v1.1",
            "x/supergemma4-26b-uncensored-mlx-4bit-v2": "supergemma4-uncensored-v2",
            "x/gemma-4-26b-a4b-it-4-bit": "gemma-4",
            "x/mlx-4bit": "mlx-4bit",
        ]
        for (repo, name) in cases {
            #expect(CommunityModelStore.suggestedName(forRepoID: repo) == name, "\(repo)")
        }
    }

    @Test func theListSurvivesARoundTripAndAMissingFileIsEmpty() throws {
        let parent = try temporaryParent("store")
        defer { try? FileManager.default.removeItem(at: parent) }
        let modelDirectory = parent.appendingPathComponent("gemma4.gturbo")
        #expect(CommunityModelStore.load(forModelDirectory: modelDirectory).isEmpty)

        let record = CommunityModelRecord(inspection, name: "abliterated",
                                          addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try CommunityModelStore.save([record], forModelDirectory: modelDirectory)
        #expect(CommunityModelStore.load(forModelDirectory: modelDirectory) == [record])
        #expect(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("community-models.json").path))
    }

    @Test func aCommunityModelBorrowsTheReferencePack() throws {
        let parent = try temporaryParent("borrow")
        defer { try? FileManager.default.removeItem(at: parent) }
        let community = AppModelInstallDescriptor(
            community: CommunityModelRecord(inspection, name: "abliterated"))
        let gemma = try install(.default, in: parent)
        let added = try install(community, in: parent)

        #expect(AppVisionPackHost.borrowsPack(community))
        #expect(AppVisionPackHost.textModelDirectory(for: added) == gemma)
    }

    @MainActor
    @Test func addingListsTheModelOnceAndAPinnedRepoIsNotAddedAgain() throws {
        let model = AppModel(client: MockLifecycleInferenceClient(),
                             installer: MockModelInstallerClient())
        let added = try model.addCommunityModel(
            CommunityModelRecord(inspection, name: "abliterated"))
        #expect(added.isCommunity)
        #expect(model.availableModels.map(\.key)
            == ["gemma4", "supergemma4", added.key])
        #expect(try model.addCommunityModel(
            CommunityModelRecord(inspection, name: "again")) == added)
        #expect(model.communityModels.count == 1)
        #expect(model.modelName(forModelID: inspection.repoID) == "abliterated")

        let pinned = RemoteModelInspection(
            repoID: AppModelInstallDescriptor.supergemma4.repoID,
            resolvedCommit: inspection.resolvedCommit,
            sourceIndexSHA256: inspection.sourceIndexSHA256,
            approximateDownloadBytes: 1, installedBytes: 1, hasVisionTower: false)
        #expect(try model.addCommunityModel(
            CommunityModelRecord(pinned, name: "copy")) == .supergemma4)
        #expect(model.communityModels.count == 1)
    }

    /// A repository already listed is answered without asking Hugging Face,
    /// whatever case it is pasted in.
    @MainActor
    @Test func checkingAListedRepositoryNeedsNoNetwork() async throws {
        let model = AppModel(client: MockLifecycleInferenceClient(),
                             installer: MockModelInstallerClient())
        let link = try #require(HuggingFaceLink(
            "https://huggingface.co/MLX-Community/gemma-4-26b-a4b-it-4bit"))
        #expect(try await model.checkCommunityModel(link) == .listed(.default))
    }

    @MainActor
    @Test func deletingRemovesEveryFileAndTheListEntry() throws {
        let parent = try temporaryParent("delete")
        defer { try? FileManager.default.removeItem(at: parent) }
        let gemma = try install(.default, in: parent)
        let model = AppModel(modelDirectory: gemma,
                             client: MockLifecycleInferenceClient(),
                             installer: MockModelInstallerClient())
        let added = try model.addCommunityModel(
            CommunityModelRecord(inspection, name: "abliterated"))
        let folder = try install(added, in: parent)
        let fm = FileManager.default
        for leftover in [".partial", ".resume.json", ".install.lock"] {
            fm.createFile(atPath: folder.path + leftover, contents: Data())
        }
        try fm.createDirectory(
            at: parent.appendingPathComponent(added.key + ".vision.gturbo"),
            withIntermediateDirectories: true)

        #expect(model.deletionBlocker(for: added) == nil)
        try model.deleteModel(added)

        let remaining = try fm.contentsOfDirectory(atPath: parent.path)
        #expect(!remaining.contains { $0.hasPrefix(added.key) })
        #expect(remaining.contains("gemma4.gturbo"))
        #expect(model.communityModels.isEmpty)
    }

    @MainActor
    @Test func theCurrentModelAndThePackItBorrowsCannotBeDeleted() throws {
        let parent = try temporaryParent("blocked")
        defer { try? FileManager.default.removeItem(at: parent) }
        let gemma = try install(.default, in: parent)
        let superGemma = try install(.supergemma4, in: parent)
        let model = AppModel(modelDirectory: superGemma,
                             client: MockLifecycleInferenceClient(),
                             installer: MockModelInstallerClient(descriptor: .supergemma4))

        #expect(model.deletionBlocker(for: .supergemma4) != nil)
        #expect(model.deletionBlocker(for: .default)?.contains("image support") == true)
        try model.deleteModel(.default)
        #expect(FileManager.default.fileExists(atPath: gemma.path))
    }
}
