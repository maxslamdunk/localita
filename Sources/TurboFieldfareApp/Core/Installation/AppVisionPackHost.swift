import Foundation
import TurboFieldfare
import TurboFieldfareRepackCore

/// Which text model folder an image pack lives beside and is checked against.
///
/// Every pack is cut from the reference checkpoint (`.visionCompanion`), the
/// only installable model with a vision tower. A model without one, such as
/// SuperGemma 4, borrows Gemma 4's pack instead of keeping a second copy: it
/// is found beside `gemma4.gturbo` and verified against that folder's
/// manifest, so every binding check still runs, just against the model the
/// pack was installed for.
///
/// Models live side by side as `<key>.gturbo` (`directoryName`), which is how
/// both the borrowing model and its host are recognised. Any other folder
/// keeps its own pack, as before.
public enum AppVisionPackHost {
    public static func textModelDirectory(for textModelDirectory: URL) -> URL {
        let own = textModelDirectory.standardizedFileURL
        let name = own.lastPathComponent
        guard name.hasSuffix(".gturbo"),
              let model = SupportedModelSource.model(
                key: String(name.dropLast(".gturbo".count))),
              !model.hasVisionTower else { return own }
        // A pack already beside this model, finished or part-downloaded, still
        // serves it; otherwise it could be neither used nor removed.
        let fm = FileManager.default
        if let ownPack = try? VisionPackLocation.companionURL(forTextModel: own),
           let paths = try? RemoteInstallPaths(outputDirectory: ownPack.path),
           fm.fileExists(atPath: paths.finalDirectory)
            || fm.fileExists(atPath: paths.partialDirectory) {
            return own
        }
        // The host has to be installed: the pack binds to its manifest.
        let host = own.deletingLastPathComponent().appendingPathComponent(
            AppModelInstallDescriptor.default.directoryName, isDirectory: true)
        guard fm.fileExists(atPath: host.appendingPathComponent("manifest.json").path) else {
            return own
        }
        return host
    }

    public static func companionURL(forTextModel textModelDirectory: URL) throws -> URL {
        try VisionPackLocation.companionURL(
            forTextModel: self.textModelDirectory(for: textModelDirectory))
    }

    /// Whether this model uses another model's pack when that one is installed.
    public static func borrowsPack(_ descriptor: AppModelInstallDescriptor) -> Bool {
        SupportedModelSource.model(key: descriptor.key)?.hasVisionTower == false
    }
}
