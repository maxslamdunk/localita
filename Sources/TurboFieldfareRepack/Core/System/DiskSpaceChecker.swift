import Foundation
import Darwin

public struct DiskSpaceRequirement: Equatable, Sendable {
    public let path: String
    public let requiredBytes: UInt64
    public let availableBytes: UInt64

    public init(path: String, requiredBytes: UInt64, availableBytes: UInt64) {
        self.path = path
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }

    public var canInstall: Bool { availableBytes >= requiredBytes }

    public var shortfallBytes: UInt64 {
        requiredBytes > availableBytes ? requiredBytes - availableBytes : 0
    }
}

public enum DiskSpaceChecker {
    public static func assess(path: String,
                              bytes: UInt64,
                              reserveBytes: UInt64 = 1 * 1024 * 1024 * 1024) throws
        -> DiskSpaceRequirement {
        let requestedDirectory = directoryForProbe(path)
        let probeDirectory = nearestExistingDirectory(requestedDirectory)
        return try requirement(path: probeDirectory,
                               bytes: bytes,
                               reserveBytes: reserveBytes)
    }

    public static func requireAvailable(path: String,
                                        bytes: UInt64,
                                        reserveBytes: UInt64 = 1 * 1024 * 1024 * 1024) throws -> DiskSpaceRequirement {
        let dir = directoryForProbe(path)
        try Posix.mkdirP(dir)
        let result = try requirement(path: dir, bytes: bytes, reserveBytes: reserveBytes)
        guard result.canInstall else {
            throw RepackError.diskSpaceInsufficient(path: dir,
                                                    required: result.requiredBytes,
                                                    available: result.availableBytes)
        }
        return result
    }

    private static func requirement(path: String,
                                    bytes: UInt64,
                                    reserveBytes: UInt64) throws -> DiskSpaceRequirement {
        var st = statfs()
        if statfs(path, &st) != 0 {
            throw RepackError.fileStatFailed(path: path, errno: errno)
        }
        let available = availableBytes(
            free: UInt64(st.f_bavail) * UInt64(st.f_bsize),
            importantUsage: importantUsageCapacity(path: path))
        let sum = bytes.addingReportingOverflow(reserveBytes)
        guard !sum.overflow else {
            throw RepackError.configurationInvalid(
                detail: "disk-space requirement overflows UInt64")
        }
        let required = sum.partialValue
        return DiskSpaceRequirement(path: path,
                                    requiredBytes: required,
                                    availableBytes: available)
    }

    /// The larger of the two ways the system counts free space.
    ///
    /// `statfs` counts only blocks that are free right now. iOS also holds
    /// purgeable space (caches, iCloud copies it can drop), which it clears
    /// when an app needs the room and which the iPhone Storage screen shows as
    /// free. On the iPhone 17 the gap was tens of GB, enough for `statfs` to
    /// refuse a 15.4 GB install that Settings said fits. Apple's measure for a
    /// download the user asked for is "available for important usage", which
    /// includes it. The macOS figure is left as it was.
    static func availableBytes(free: UInt64, importantUsage: Int64?) -> UInt64 {
        guard let importantUsage, importantUsage > 0 else { return free }
        return max(free, UInt64(importantUsage))
    }

    private static func importantUsageCapacity(path: String) -> Int64? {
        #if os(iOS)
        let values = try? URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }

    private static func nearestExistingDirectory(_ path: String) -> String {
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return url.path }
            url = parent
        }
        return url.path
    }

    private static func directoryForProbe(_ path: String) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        if ext.isEmpty {
            return path
        }
        return ns.deletingLastPathComponent
    }
}
