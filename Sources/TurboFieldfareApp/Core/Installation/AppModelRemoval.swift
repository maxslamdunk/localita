import Foundation
import TurboFieldfare
import TurboFieldfareRepackCore

/// Removes a text model's files from beside the others: the installed folder,
/// a download in progress with its checkpoint and lock, and the image pack
/// kept beside it, if any. A pack borrowed from another folder is that
/// folder's and stays.
enum AppModelRemoval {
    static func removeTextModel(at directory: URL) throws {
        var folders = [directory.standardizedFileURL]
        if let pack = try? VisionPackLocation.companionURL(forTextModel: directory) {
            folders.append(pack)
        }
        let fm = FileManager.default
        for folder in folders {
            let paths = try RemoteInstallPaths(outputDirectory: folder.path)
            for path in [paths.finalDirectory, paths.partialDirectory,
                         paths.checkpointFile, paths.lockFile]
            where fm.fileExists(atPath: path) {
                try fm.removeItem(atPath: path)
            }
        }
    }
}
