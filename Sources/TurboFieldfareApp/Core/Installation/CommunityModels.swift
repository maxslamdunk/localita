import Foundation
import TurboFieldfareRepackCore

/// A model someone added by pasting a Hugging Face link, as saved.
///
/// It passed `RemoteModelInspector`'s check: a Gemma 4 26B-A4B checkpoint laid
/// out exactly as the reference, so the runtime runs it the way it runs Gemma 4.
/// Nobody here has tested its answers; that is what "community" means in the
/// app. It is pinned to the commit the check read, so the author's later
/// uploads never change it.
public struct CommunityModelRecord: Codable, Equatable, Sendable {
    public let repoID: String
    public let revision: String
    public let sourceIndexSHA256: String
    public let approximateDownloadBytes: UInt64
    public let installedBytes: UInt64
    /// The name the chat shows, chosen when it was added.
    public var name: String
    public let addedAt: Date

    public init(repoID: String,
                revision: String,
                sourceIndexSHA256: String,
                approximateDownloadBytes: UInt64,
                installedBytes: UInt64,
                name: String,
                addedAt: Date = Date()) {
        self.repoID = repoID
        self.revision = revision
        self.sourceIndexSHA256 = sourceIndexSHA256
        self.approximateDownloadBytes = approximateDownloadBytes
        self.installedBytes = installedBytes
        self.name = name
        self.addedAt = addedAt
    }

    public init(_ inspection: RemoteModelInspection, name: String, addedAt: Date = Date()) {
        self.init(repoID: inspection.repoID,
                  revision: inspection.resolvedCommit,
                  sourceIndexSHA256: inspection.sourceIndexSHA256,
                  approximateDownloadBytes: inspection.approximateDownloadBytes,
                  installedBytes: inspection.installedBytes,
                  name: name,
                  addedAt: addedAt)
    }
}

/// What checking a pasted repository found.
public enum CommunityModelCheck: Equatable, Sendable {
    /// It runs here. The record carries a suggested name, to be changed
    /// before it is added if wanted.
    case compatible(CommunityModelRecord)
    /// The app already lists this repository.
    case listed(AppModelInstallDescriptor)
    /// It can't run here; a sentence saying why.
    case incompatible(reason: String)
}

/// The added models, kept as `community-models.json` beside the model
/// folders, the settings file and the conversations.
///
/// Each installs into its own `hf-<owner>--<name>.gturbo` folder. The prefix
/// is what marks a folder as a community model's without reading this file,
/// which is how `AppVisionPackHost` knows it borrows Gemma 4's image pack.
public enum CommunityModelStore {
    public static let fileName = "community-models.json"
    public static let keyPrefix = "hf-"

    public static func fileURL(forModelDirectory modelDirectory: URL) -> URL {
        modelDirectory.standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    /// The saved models, oldest first. A missing or unreadable file is an
    /// empty list: losing it forgets the entries, not the downloads, which a
    /// person can add again.
    public static func load(forModelDirectory modelDirectory: URL) -> [CommunityModelRecord] {
        guard let data = try? Data(contentsOf: fileURL(forModelDirectory: modelDirectory)),
              let records = try? decoder.decode([CommunityModelRecord].self, from: data) else {
            return []
        }
        return records
    }

    public static func save(_ records: [CommunityModelRecord],
                            forModelDirectory modelDirectory: URL) throws {
        let url = fileURL(forModelDirectory: modelDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    /// The folder stem for a repository: stable, lowercase, one path segment.
    public static func key(forRepoID repoID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        let flat = repoID.lowercased().replacingOccurrences(of: "/", with: "--")
        return keyPrefix + String(flat.map { allowed.contains($0) ? $0 : "-" })
    }

    /// Checks a repository with `RemoteModelInspector`, which reads a few MB
    /// of config and headers. It fails fast offline rather than waiting for a
    /// network, as a download does: someone is watching it.
    static func check(_ link: HuggingFaceLink) async throws -> CommunityModelCheck {
        let session = RemoteDownloadSession(policy: RemoteDownloadSessionPolicy(
            requestTimeoutSeconds: 30,
            resourceTimeoutSeconds: 120,
            waitsForConnectivity: false))
        switch try await RemoteModelInspector.check(
            repoID: link.repoID, revision: link.revision, downloadSession: session) {
        case .compatible(let inspection):
            return .compatible(CommunityModelRecord(
                inspection, name: suggestedName(forRepoID: inspection.repoID)))
        case .incompatible(let reason, _):
            return .incompatible(reason: reason)
        }
    }

    public static func isCommunityKey(_ key: String) -> Bool {
        key.hasPrefix(keyPrefix)
    }

    /// A name short enough for the chat's model pill, from a repository name:
    /// the format words every such build carries (MLX, 4-bit, 26B, A4B, it)
    /// are dropped. `gemma-4-26B-A4B-it-abliterated-MLX-4bit` reads
    /// `gemma-4-abliterated`.
    public static func suggestedName(forRepoID repoID: String) -> String {
        let repoName = repoID.split(separator: "/").last.map(String.init) ?? repoID
        let noise: Set<String> = ["mlx", "4bit", "q4", "26b", "a4b", "it", "lm"]
        var kept: [Substring] = []
        let words = repoName.split(whereSeparator: { $0 == "-" || $0 == "_" })
        var index = 0
        while index < words.count {
            let word = words[index].lowercased()
            if word == "4", index + 1 < words.count, words[index + 1].lowercased() == "bit" {
                index += 2
                continue
            }
            if !noise.contains(word) { kept.append(words[index]) }
            index += 1
        }
        let name = kept.joined(separator: "-")
        return name.isEmpty ? repoName : name
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension AppModelInstallDescriptor {
    public init(community record: CommunityModelRecord) {
        self.init(displayName: record.repoID.split(separator: "/").last.map(String.init)
                    ?? record.repoID,
                  repoID: record.repoID,
                  revision: record.revision,
                  sourceIndexSHA256: record.sourceIndexSHA256,
                  approximateDownloadBytes: record.approximateDownloadBytes,
                  installedBytes: record.installedBytes,
                  rangeStagingBytes: UInt64(RemoteChunkPolicy.defaultBytes),
                  reserveBytes: SupportedModelSource.reserveBytes,
                  key: CommunityModelStore.key(forRepoID: record.repoID),
                  // Every community model borrows Gemma 4's image pack
                  // (`AppVisionPackHost`), whether it has a vision tower or not.
                  supportsImages: true,
                  shortName: record.name,
                  isCommunity: true)
    }
}
