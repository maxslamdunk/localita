import Foundation
import TurboFieldfare

public enum AppModelInstallationStatus: Equatable, Sendable {
    case missing
    case partial(String)
    case complete
}

public enum AppModelInstallationProbe {
    /// Whether the receipt's recorded absolute path is treated as binding.
    ///
    /// False on iOS, and not as a convenience. The OS assigns an app's data
    /// container a fresh UUID on every install, so the path a receipt records
    /// is stale by construction: a side-loaded artifact carries the Mac path it
    /// was verified at, and even a receipt regenerated on the device is void
    /// after the next install. Leaving it enabled reported a complete, correct,
    /// fully present 14.3 GB model as "Model required" — with the real reason
    /// thrown away into a `.partial` nothing displayed — which is how this was
    /// found, on the device, by hand.
    ///
    /// A named constant rather than an `#if` at the call site, per
    /// `Infrastructure/CLAUDE.md`. What it relaxes is narrow: schema version
    /// and manifest digest are still enforced on both platforms, and the app
    /// loads with `.fullSha256`, so every byte is still hashed on first touch.
    /// Nothing is trusted here that was not trusted before.
    public static let receiptBindsDirectoryPath: Bool = {
        #if os(iOS)
        return false
        #else
        return true
        #endif
    }()

    /// - Parameter requiringReceiptDirectoryPath: defaults to the platform
    ///   constant. Exposed so a test can drive both branches on either
    ///   platform: `swift test` is macOS-only, so an iOS-only default would go
    ///   entirely unasserted — the same blind spot that let a hardcoded slot
    ///   count silently override `productionExpertCacheSlots`.
    public static func status(
        at directory: URL,
        descriptor: AppModelInstallDescriptor = .default,
        requiringReceiptDirectoryPath: Bool = receiptBindsDirectoryPath
    ) -> AppModelInstallationStatus {
        let directory = directory.standardizedFileURL
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .missing
        }

        do {
            let manifest = try ManifestReader.load(directoryURL: directory, expecting: .gemma4_26B_A4B)
            let expectedSource = "sha256:" + descriptor.sourceIndexSHA256
            guard manifest.sourceSnapshotHash == expectedSource else {
                return .partial("installed checkpoint does not match \(descriptor.displayName)")
            }
            let layout = directory.appendingPathComponent("packed_experts/layout.json")
            guard FileManager.default.fileExists(atPath: layout.path) else {
                return .partial("packed_experts/layout.json is missing")
            }
            let receipt = try VerifiedInstallReceiptReader.load(directoryURL: directory)
            let manifestHash = try Sha256Verifier.hashFile(at: manifestURL, chunkBytes: 65_536)
            try VerifiedInstallReceiptReader.validateManifestBinding(
                receipt,
                directoryURL: directory,
                manifestSha256: manifestHash,
                requiringDirectoryPath: requiringReceiptDirectoryPath)
            return .complete
        } catch {
            return .partial("\(error)")
        }
    }
}
