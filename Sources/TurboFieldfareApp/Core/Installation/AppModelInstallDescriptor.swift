import Foundation
import TurboFieldfareRepackCore

public struct AppModelInstallDescriptor: Equatable, Sendable {
    public let displayName: String
    /// What a chat calls the model beside an answer and above the
    /// conversation. The full name where none shorter was given.
    public let shortName: String
    public let repoID: String
    public let revision: String
    public let sourceIndexSHA256: String
    public let approximateDownloadBytes: UInt64
    public let installedBytes: UInt64
    public let rangeStagingBytes: UInt64
    public let reserveBytes: UInt64
    /// Short stable name, and the stem of the installed folder. Only text
    /// models have one that means anything; the image pack's is unused.
    public let key: String
    /// Whether an image companion pack exists for this checkpoint.
    public let supportsImages: Bool

    public init(displayName: String,
                repoID: String,
                revision: String,
                sourceIndexSHA256: String,
                approximateDownloadBytes: UInt64,
                installedBytes: UInt64,
                rangeStagingBytes: UInt64,
                reserveBytes: UInt64,
                key: String = SupportedModelSource.gemma4.key,
                supportsImages: Bool = true,
                shortName: String? = nil) {
        self.displayName = displayName
        self.shortName = shortName ?? displayName
        self.repoID = repoID
        self.revision = revision
        self.sourceIndexSHA256 = sourceIndexSHA256
        self.approximateDownloadBytes = approximateDownloadBytes
        self.installedBytes = installedBytes
        self.rangeStagingBytes = rangeStagingBytes
        self.reserveBytes = reserveBytes
        self.key = key
        self.supportsImages = supportsImages
    }

    init(textModel model: SupportedModel) {
        self.init(displayName: model.displayName,
                  repoID: model.repoID,
                  revision: model.revision,
                  sourceIndexSHA256: model.sourceIndexSHA256,
                  approximateDownloadBytes: model.approximateDownloadBytes,
                  installedBytes: model.installedBytes,
                  rangeStagingBytes: UInt64(RemoteChunkPolicy.defaultBytes),
                  reserveBytes: SupportedModelSource.reserveBytes,
                  key: model.key,
                  // Every text model offers images: one without a vision tower
                  // borrows Gemma 4's pack (`AppVisionPackHost`). Checked on
                  // the iPhone 17 with SuperGemma 4 on 2026-09-30.
                  supportsImages: true,
                  shortName: model.shortName)
    }

    /// The folder a text model installs into, beside the others.
    public var directoryName: String { key + ".gturbo" }

    public var requiredFreeBytes: UInt64 {
        installedBytes + rangeStagingBytes + reserveBytes
    }

    public static let `default` = AppModelInstallDescriptor(
        textModel: SupportedModelSource.gemma4)

    public static let supergemma4 = AppModelInstallDescriptor(
        textModel: SupportedModelSource.supergemma4)

    /// Every text model the app can install, in menu order.
    public static let textModels: [AppModelInstallDescriptor] =
        SupportedModelSource.all.map { AppModelInstallDescriptor(textModel: $0) }

    public static func textModel(key: String) -> AppModelInstallDescriptor? {
        textModels.first { $0.key == key }
    }

    /// The text model a manifest or a stored conversation names by its
    /// `modelID`, which the installer sets to the source repository.
    public static func textModel(modelID: String) -> AppModelInstallDescriptor? {
        textModels.first { $0.repoID == modelID }
    }

    /// The name an answer is labelled with: the short name of a model this
    /// app knows, or the last part of the repository it came from.
    public static func shortName(forModelID modelID: String) -> String {
        if let known = textModel(modelID: modelID) { return known.shortName }
        return modelID.split(separator: "/").last.map(String.init) ?? modelID
    }

    public static let visionCompanion = AppModelInstallDescriptor(
        displayName: "Gemma 4 Image Support",
        repoID: "mlx-community/gemma-4-26b-a4b-it-4bit",
        revision: "0d77464eeb233a2da68ebf9d7dc4edaac7db956d",
        sourceIndexSHA256: "bf198c9f5ea6462addca1966e5dd669c407537a876e82cf06db9084c5c850b13",
        approximateDownloadBytes: 1_539_478_890,
        installedBytes: 1_144_373_248 + 4_194_304,
        rangeStagingBytes: UInt64(RemoteChunkPolicy.defaultBytes),
        reserveBytes: 1_073_741_824)
}

public struct AppModelInstallRequirement: Equatable, Sendable {
    public let probePath: String
    public let requiredBytes: UInt64
    public let availableBytes: UInt64

    public init(probePath: String = "", requiredBytes: UInt64, availableBytes: UInt64) {
        self.probePath = probePath
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }

    public var canInstall: Bool { availableBytes >= requiredBytes }

    public var shortfallBytes: UInt64 {
        requiredBytes > availableBytes ? requiredBytes - availableBytes : 0
    }
}

public enum AppModelInstallReadiness: Equatable, Sendable {
    case checking
    case ready(AppModelInstallRequirement)
    case insufficientSpace(AppModelInstallRequirement)
    case failed(String)

    public var requirement: AppModelInstallRequirement? {
        switch self {
        case .ready(let requirement), .insufficientSpace(let requirement):
            return requirement
        case .checking, .failed:
            return nil
        }
    }
}
