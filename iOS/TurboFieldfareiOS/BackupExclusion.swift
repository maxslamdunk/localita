import Foundation
import os

/// Keeps the model out of iCloud backups.
///
/// iOS backs up Application Support by default, and nothing marked the model
/// folder otherwise. So the 14.3 GB model, the image pack beside it, and any
/// half-finished download of either were all candidates for the user's
/// backup: bytes that can be downloaded again, at a size that fills most
/// iCloud plans.
///
/// Every `.gturbo` entry under `ModelLocation.root` is marked: the model and
/// image-pack folders, their `.partial` folders, and the resume checkpoints.
/// The conversations and the settings file live beside them and are left
/// alone, since those cannot be downloaded again. The mark is an extended
/// attribute on the item, so a `.partial` folder renamed into place keeps it.
/// It is applied again whenever a download starts or ends, because the
/// installer creates new entries as it goes.
enum BackupExclusion {
    private static let log = Logger(subsystem: "TurboFieldfare", category: "backup")

    static func apply() {
        let root = ModelLocation.root
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            // No folder yet: nothing has been downloaded or pushed.
            return
        }
        for name in names where name.contains(".gturbo") {
            var url = root.appendingPathComponent(name)
            do {
                if try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
                    .isExcludedFromBackup == true {
                    continue
                }
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
                log.info("excluded from backup: \(name, privacy: .public)")
            } catch {
                log.error("""
                    could not exclude \(name, privacy: .public) from backup: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }
}
