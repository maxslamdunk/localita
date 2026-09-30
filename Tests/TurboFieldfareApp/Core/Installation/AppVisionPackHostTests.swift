import Foundation
import Testing
@testable import TurboFieldfareAppCore

/// A model without a vision tower borrows Gemma 4's image pack when Gemma 4 is
/// installed beside it, and keeps its own otherwise.
@Suite(.serialized)
struct AppVisionPackHostTests {
    /// Installed models side by side, named as the app names them.
    private func makeModels(_ keys: [String]) throws -> (parent: URL, models: [String: URL]) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("turbofieldfare-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var models: [String: URL] = [:]
        for key in keys {
            let descriptor = try #require(AppModelInstallDescriptor.textModel(key: key))
            let made = try makeCompleteModelInstall(key, descriptor: descriptor, in: parent)
            let named = parent.appendingPathComponent(descriptor.directoryName, isDirectory: true)
            try FileManager.default.moveItem(at: made, to: named)
            models[key] = named.standardizedFileURL
        }
        return (parent, models)
    }

    @Test func referenceModelKeepsItsOwnPack() throws {
        let (parent, models) = try makeModels(["gemma4", "supergemma4"])
        defer { try? FileManager.default.removeItem(at: parent) }
        let gemma = try #require(models["gemma4"])
        #expect(AppVisionPackHost.textModelDirectory(for: gemma) == gemma)
    }

    @Test func textOnlyModelBorrowsTheInstalledReferencePack() throws {
        let (parent, models) = try makeModels(["gemma4", "supergemma4"])
        defer { try? FileManager.default.removeItem(at: parent) }
        let gemma = try #require(models["gemma4"])
        let superGemma = try #require(models["supergemma4"])

        #expect(AppVisionPackHost.textModelDirectory(for: superGemma) == gemma)
        #expect(try AppVisionPackHost.companionURL(forTextModel: superGemma).lastPathComponent
            == "gemma4.vision.gturbo")
        #expect(AppVisionPackInstallationProbe.status(at: superGemma) == .missing)

        try installVisionCompanion(forTextModel: gemma)
        #expect(AppVisionPackInstallationProbe.status(at: superGemma) == .complete)
    }

    /// Without the reference model there is nothing to borrow, and nothing its
    /// pack could be checked against.
    @Test func textOnlyModelAloneKeepsItsOwnPack() throws {
        let (parent, models) = try makeModels(["supergemma4"])
        defer { try? FileManager.default.removeItem(at: parent) }
        let superGemma = try #require(models["supergemma4"])
        #expect(AppVisionPackHost.textModelDirectory(for: superGemma) == superGemma)
    }

    /// A pack installed beside the model before packs were shared stays usable
    /// and removable, whether finished or part-downloaded.
    @Test func existingOwnPackStillServesTheModel() throws {
        for suffix in ["", ".partial"] {
            let (parent, models) = try makeModels(["gemma4", "supergemma4"])
            defer { try? FileManager.default.removeItem(at: parent) }
            let superGemma = try #require(models["supergemma4"])
            try FileManager.default.createDirectory(
                at: parent.appendingPathComponent("supergemma4.vision.gturbo" + suffix),
                withIntermediateDirectories: true)
            #expect(AppVisionPackHost.textModelDirectory(for: superGemma) == superGemma)
        }
    }

    /// A folder the app did not name keeps the old one-pack-per-folder rule.
    @Test func unrecognisedFolderKeepsItsOwnPack() throws {
        let directory = try makeCompleteModelInstall("host-other", descriptor: .supergemma4)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AppVisionPackHost.textModelDirectory(for: directory)
            == directory.standardizedFileURL)
    }

    @MainActor
    @Test func textOnlyModelTakesImagesFromTheSharedPack() throws {
        let (parent, models) = try makeModels(["gemma4", "supergemma4"])
        defer { try? FileManager.default.removeItem(at: parent) }
        try installVisionCompanion(forTextModel: try #require(models["gemma4"]))
        let model = AppModel(
            modelDirectory: try #require(models["supergemma4"]),
            client: MockLifecycleInferenceClient(),
            installer: MockModelInstallerClient(descriptor: .supergemma4),
            visionInstaller: MockVisionPackInstallerClient(),
            visionRuntimeSupported: true)
        #expect(model.isVisionPackInstalled)
        #expect(model.isImageInputAvailable)
    }
}
