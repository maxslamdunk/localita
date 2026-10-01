import Foundation
import Testing
@testable import TurboFieldfareAppCore

/// Switching between the text models the app can install.
///
/// Each model has its own folder and its own installer, and an installer is
/// bound to the one checkpoint it installs, so a switch has to replace both
/// together. What it must never do is judge one model's folder against the
/// other's source hash.
@Suite(.serialized)
struct AppModelSelectionTests {
    @MainActor
    @Test func catalogListsBothModelsWithDistinctFolders() {
        let models = AppModelInstallDescriptor.textModels
        #expect(models.map(\.key) == ["gemma4", "supergemma4"])
        #expect(models.first == .default)
        #expect(AppModelInstallDescriptor.default.directoryName == "gemma4.gturbo")
        #expect(AppModelInstallDescriptor.supergemma4.directoryName == "supergemma4.gturbo")
        #expect(AppModelInstallDescriptor.default.supportsImages)
        #expect(AppModelInstallDescriptor.supergemma4.supportsImages)
        #expect(AppModelInstallDescriptor.textModel(
            modelID: "Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2") == .supergemma4)
        #expect(AppModelInstallDescriptor.textModel(modelID: "someone/else") == nil)
    }

    /// The installed checkpoint's hash is what says which model a folder holds.
    @MainActor
    @Test func probeJudgesAFolderAgainstItsOwnModel() throws {
        let directory = try makeCompleteModelInstall(
            "probe-super", descriptor: .supergemma4)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(AppModelInstallationProbe.status(
            at: directory, descriptor: .supergemma4) == .complete)
        #expect(AppModelInstallationProbe.status(
            at: directory, descriptor: .default) != .complete)
    }

    /// The model's first probe used the default descriptor whatever installer
    /// it was given, so a text-only model's folder read as a mismatch at launch.
    @MainActor
    @Test func launchProbesWithTheInstallersModel() throws {
        let directory = try makeCompleteModelInstall(
            "launch-super", descriptor: .supergemma4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            modelDirectory: directory,
            client: MockLifecycleInferenceClient(),
            installer: MockModelInstallerClient(descriptor: .supergemma4))

        #expect(model.installDescriptor == .supergemma4)
        #expect(model.isModelInstalled)
        #expect(model.canLoadModel)
    }

    @MainActor
    @Test func selectingAModelSwapsInstallerAndLocationTogether() throws {
        let root = try temporaryRoot("swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try makeCompleteModelInstall("ref", in: root)
        let supergemma = try makeCompleteModelInstall(
            "super", descriptor: .supergemma4, in: root)
        let model = AppModel(
            modelDirectory: reference,
            client: MockLifecycleInferenceClient(),
            installer: MockModelInstallerClient(),
            installerFactory: { MockModelInstallerClient(descriptor: $0) })
        #expect(model.isModelInstalled)
        #expect(model.canSelectModel)

        model.selectModel(.supergemma4, at: supergemma)

        #expect(model.installDescriptor == .supergemma4)
        #expect(model.modelPathText == supergemma.standardizedFileURL.path)
        #expect(model.isModelInstalled)
        #expect(model.loadState == .notLoaded)

        model.selectModel(.default, at: reference)

        #expect(model.installDescriptor == .default)
        #expect(model.modelPathText == reference.standardizedFileURL.path)
        #expect(model.isModelInstalled)
    }

    /// Both folders share one store. Opening a second instance on it could
    /// not take the writer lock while the first was still referenced, and a
    /// store without the lock silently drops writes: on the phone, every chat
    /// of the model switched to was lost.
    @MainActor
    @Test func switchKeepsTheSharedConversationStore() async throws {
        let root = try temporaryRoot("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try makeCompleteModelInstall("ref", in: root)
        let supergemma = try makeCompleteModelInstall(
            "super", descriptor: .supergemma4, in: root)
        let model = AppModel(
            modelDirectory: reference,
            client: MockLifecycleInferenceClient(),
            installer: MockModelInstallerClient(),
            installerFactory: { MockModelInstallerClient(descriptor: $0) },
            settingsPersistenceEnabled: true)
        let before = try #require(model.conversationStore)
        try await waitUntilWritable(before)
        // Stands in for the in-flight work that kept the old store alive.
        let held = before

        model.selectModel(.supergemma4, at: supergemma)

        let after = try #require(model.conversationStore)
        #expect(after === held)
        try await waitUntilWritable(after)
        #expect(model.conversationIdentity?.modelID
            == "test/gemma-4-26b-a4b")
    }

    /// Picking a model that is not on disk yet leads to its download, sized and
    /// checked for that model rather than the one just left.
    @MainActor
    @Test func selectingAMissingModelRequiresItsInstall() throws {
        let root = try temporaryRoot("missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try makeCompleteModelInstall("ref", in: root)
        let missing = root.appendingPathComponent("supergemma4.gturbo", isDirectory: true)
        let model = AppModel(
            modelDirectory: reference,
            client: MockLifecycleInferenceClient(),
            installer: MockModelInstallerClient(),
            installerFactory: { MockModelInstallerClient(descriptor: $0) })

        model.selectModel(.supergemma4, at: missing)

        #expect(model.installDescriptor == .supergemma4)
        #expect(model.requiresModelInstallation)
        #expect(model.canInstallModel)
    }

    /// A model without a vision tower still offers the image pack; it borrows
    /// the reference model's (`AppVisionPackHostTests`).
    @MainActor
    @Test func textOnlyModelOffersImagePack() throws {
        let directory = try makeCompleteModelInstall(
            "no-images", descriptor: .supergemma4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            modelDirectory: directory,
            client: MockLifecycleInferenceClient(),
            installer: MockModelInstallerClient(descriptor: .supergemma4),
            visionInstaller: MockVisionPackInstallerClient(),
            visionRuntimeSupported: true)

        #expect(model.isModelInstalled)
        #expect(model.canInstallVisionPack)
        #expect(!model.isImageInputAvailable)
    }

    @MainActor
    @Test func referenceModelStillOffersImages() throws {
        let directory = try makeCompleteModelInstall("images")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            modelDirectory: directory,
            client: MockLifecycleInferenceClient(),
            installer: MockModelInstallerClient(),
            visionInstaller: MockVisionPackInstallerClient(),
            visionRuntimeSupported: true)

        #expect(model.canInstallVisionPack)
    }

    private func waitUntilWritable(_ store: ConversationStore) async throws {
        for _ in 0..<400 {
            if await !store.isReadOnly { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the conversation store never took the writer lock")
    }

    private func temporaryRoot(_ tag: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("turbofieldfare-select-\(tag)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
