import Foundation

/// A Hugging Face checkpoint the installer can take, as read before any weight
/// is downloaded.
public struct RemoteModelInspection: Sendable, Equatable {
    public let repoID: String
    /// The commit the check read. An install is pinned to it, so files the
    /// author uploads later never change a model already added.
    public let resolvedCommit: String
    public let sourceIndexSHA256: String
    public let approximateDownloadBytes: UInt64
    /// What the finished `.gturbo` folder takes, rounded up a little for the
    /// tokenizer and manifest files, which are sized only once fetched.
    public let installedBytes: UInt64
    public let hasVisionTower: Bool

    public init(repoID: String,
                resolvedCommit: String,
                sourceIndexSHA256: String,
                approximateDownloadBytes: UInt64,
                installedBytes: UInt64,
                hasVisionTower: Bool) {
        self.repoID = repoID
        self.resolvedCommit = resolvedCommit
        self.sourceIndexSHA256 = sourceIndexSHA256
        self.approximateDownloadBytes = approximateDownloadBytes
        self.installedBytes = installedBytes
        self.hasVisionTower = hasVisionTower
    }
}

public enum RemoteModelCheck: Sendable, Equatable {
    case compatible(RemoteModelInspection)
    /// `reason` is a sentence for the person who asked. `layoutSHA256` is
    /// set once the weight headers were read, for the CLI.
    case incompatible(reason: String, layoutSHA256: String? = nil)
}

/// Checks whether a Hugging Face repository holds a checkpoint this runtime
/// can run, reading only its `config.json`, its index and each shard's header:
/// a few MB, against the ~14 GB an install downloads.
///
/// A checkpoint fits when the installer's own planner accepts it and its text
/// model matches the reference's layout (`ReferenceLayout`), which is also
/// what the installer enforces again when it runs.
public enum RemoteModelInspector {
    /// Room left for the tokenizer, chat template, manifest and layout files
    /// on top of the planned payload. The reference's come to about 32 MB.
    static let smallFileAllowanceBytes: UInt64 = 64 * 1024 * 1024

    public static func check(
        repoID: String,
        revision: String = "main",
        token: String? = nil,
        downloadSession: RemoteDownloadSession = RemoteDownloadSession(),
        baseURL: URL = URL(string: "https://huggingface.co")!
    ) async throws -> RemoteModelCheck {
        let scratch = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("turbofieldfare-check-\(UUID().uuidString)")
        try Posix.mkdirP(scratch)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let metadata = (scratch as NSString).appendingPathComponent("metadata")
        let remote = HuggingFaceRemoteSource(repoID: repoID,
                                             requestedRevision: revision,
                                             token: token,
                                             downloadSession: downloadSession,
                                             baseURL: baseURL,
                                             tempDirectory: scratch)

        // The config first: it names most misfits in a sentence, before the
        // shard headers are fetched.
        let configInfo: RemoteFileInfo
        do {
            configInfo = try await remote.resolveFileInfo(filename: "config.json")
        } catch RepackError.remoteHTTPResponse(_, let status, _)
                    where [401, 403, 404].contains(status) {
            // Hugging Face answers 401 for a repository that does not exist as
            // well as for a private or gated one, so the two read the same.
            return .incompatible(reason: status == 404
                ? "This repository has no config.json, so it is not a Transformers "
                    + "or MLX checkpoint (GGUF files can't be used)."
                : "No such repository, or it is private or gated. Check the name; "
                    + "signing in to Hugging Face is not supported yet.")
        }
        let pinned = remote.pinned(commit: configInfo.resolvedCommit)
        let configPath = (metadata as NSString).appendingPathComponent("config.json")
        try await pinned.fetchSmallFile(filename: "config.json",
                                        info: configInfo,
                                        capBytes: 1024 * 1024,
                                        outputPath: configPath)
        if let reason = ReferenceLayout.configRejection(
            configData: try Data(contentsOf: URL(fileURLWithPath: configPath))) {
            return .incompatible(reason: reason)
        }

        let snapshot: RemoteSnapshot
        do {
            snapshot = try await RemoteSnapshotLoader.load(remote: pinned,
                                                           requireKnownSource: false,
                                                           metadataDirectory: metadata)
        } catch RepackError.remoteHTTPResponse(_, 404, _) {
            return .incompatible(reason: "It has no model.safetensors.index.json; "
                + "only sharded MLX checkpoints can be converted.")
        }
        let layout = ReferenceLayout.fingerprint(arch: snapshot.arch,
                                                 meta: snapshot.metadata,
                                                 shardHeaders: snapshot.shardHeaders)
        guard layout == ReferenceLayout.gemma4SHA256 else {
            return .incompatible(
                reason: "It is a Gemma 4 26B-A4B build, but its weights are not laid "
                    + "out like Gemma 4's, so it can't run here.",
                layoutSHA256: layout)
        }
        let plan = try RepackPlanner.plan(
            meta: snapshot.metadata,
            arch: snapshot.arch,
            shardHeaders: snapshot.shardHeaders,
            outputDir: (scratch as NSString).appendingPathComponent("plan"))
        let rangePlan = try RangeCopyPlanner.plan(repackPlan: plan,
                                                  rangeChunkBytes: RemoteChunkPolicy.defaultBytes,
                                                  layoutMode: "identity",
                                                  layoutOrderSha256: nil)
        let outputBytes = plan.resident.totalSize
            + plan.layers.reduce(UInt64(0)) { $0 + $1.fileSize }
        return .compatible(RemoteModelInspection(
            repoID: repoID,
            resolvedCommit: snapshot.resolvedCommit,
            sourceIndexSHA256: snapshot.metadata.indexSha256Hex,
            approximateDownloadBytes: rangePlan.remoteBytesToDownload,
            installedBytes: outputBytes + smallFileAllowanceBytes,
            hasVisionTower: plan.excludedMultimodalTensorNames.contains {
                $0.hasPrefix("vision_tower.")
            }))
    }
}
