import Foundation

/// One pinned checkpoint the installer accepts. Every entry must share the
/// Gemma 4 26B-A4B text architecture and the MLX 4-bit affine layout, because
/// the repacker copies quantized bytes as they are and never requantizes.
public struct SupportedModel: Equatable, Sendable {
    /// Short stable name: the CLI's `--source` value and the stem of the
    /// installed folder (`<key>.gturbo`).
    public let key: String
    public let displayName: String
    /// The name a chat shows beside an answer and above the conversation,
    /// where the full name is too long to fit.
    public let shortName: String
    public let repoID: String
    public let revision: String
    public let sourceIndexSHA256: String
    public let approximateDownloadBytes: UInt64
    public let installedBytes: UInt64
    /// Whether the checkpoint carries the vision tower the image companion
    /// pack is cut from.
    public let hasVisionTower: Bool
    /// The SHA-256 of the pinned revision's `tokenizer.json`. A chat recorded
    /// before conversations stored this digest is matched by its model ID
    /// and snapshot, and this says which vocabulary its token IDs index.
    public let tokenizerSHA256: String

    public var directoryName: String { key + ".gturbo" }

    public func installOptions(outputDirectory: URL,
                               overwrite: Bool,
                               token: String?,
                               resume: Bool = false)
        -> RemoteStreamingRepackOptions {
        RemoteStreamingRepackOptions(
            repoID: repoID,
            revision: revision,
            outputDir: outputDirectory.path,
            token: token,
            requireKnownSource: true,
            minFreeReserveBytes: SupportedModelSource.reserveBytes,
            overwrite: overwrite,
            resume: resume)
    }
}

public enum SupportedModelSource {
    /// The project's reference checkpoint, and the only one with an image
    /// companion pack.
    public static let gemma4 = SupportedModel(
        key: "gemma4",
        displayName: "Gemma 4 26B-A4B IT 4-bit",
        shortName: "Gemma 4",
        repoID: "mlx-community/gemma-4-26b-a4b-it-4bit",
        revision: "0d77464eeb233a2da68ebf9d7dc4edaac7db956d",
        sourceIndexSHA256:
            "bf198c9f5ea6462addca1966e5dd669c407537a876e82cf06db9084c5c850b13",
        approximateDownloadBytes: 14_620_479_420,
        installedBytes: 14_291_921_884,
        hasVisionTower: true,
        tokenizerSHA256:
            "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f")

    /// A community edit of the same checkpoint. Its 1,339 text tensors match
    /// the reference in name, dtype, shape and quantization; it ships no
    /// vision tower, so the app gives it the reference's image pack.
    public static let supergemma4 = SupportedModel(
        key: "supergemma4",
        displayName: "SuperGemma 4 26B Uncensored 4-bit",
        shortName: "SuperGemma 4",
        repoID: "Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2",
        revision: "1ecb7582718b813fc4c7b5c3131b2b7053787f00",
        sourceIndexSHA256:
            "df3133d5e9e400092664cb2197413a32035189ab7c41f4b000f75a284abdc512",
        // Planned 2026-09-27 against the pinned revision: the same text ranges
        // as the reference, without the 420,423,552 B of vision-tensor gap the
        // reference's coalesced reads pull in. The payload written is
        // identical, 14,251,255,868 B.
        approximateDownloadBytes: 14_200_055_868,
        // Measured on the 2026-09-27 install; 2,633 B under the reference,
        // from a longer model ID and a different chat template.
        installedBytes: 14_291_919_251,
        hasVisionTower: false,
        // The reference's file, byte for byte (hashed from both installs,
        // 2026-10-07), so a chat moves between the two without re-reading.
        tokenizerSHA256:
            "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f")

    public static let all: [SupportedModel] = [gemma4, supergemma4]

    public static func model(key: String) -> SupportedModel? {
        all.first { $0.key == key }
    }

    public static func model(repoID: String) -> SupportedModel? {
        all.first { $0.repoID == repoID }
    }

    public static let displayName = gemma4.displayName
    public static let repoID = gemma4.repoID
    public static let revision = gemma4.revision
    public static let sourceIndexSHA256 = gemma4.sourceIndexSHA256
    public static let approximateDownloadBytes = gemma4.approximateDownloadBytes
    public static let installedBytes = gemma4.installedBytes
    public static let reserveBytes: UInt64 = 1_073_741_824

    public static func installOptions(outputDirectory: URL,
                                      overwrite: Bool,
                                      token: String?,
                                      resume: Bool = false)
        -> RemoteStreamingRepackOptions {
        gemma4.installOptions(outputDirectory: outputDirectory,
                              overwrite: overwrite,
                              token: token,
                              resume: resume)
    }
}
