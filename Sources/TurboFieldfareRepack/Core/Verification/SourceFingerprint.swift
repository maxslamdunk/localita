import Foundation

/// Snapshot fingerprints pinned by the project. Adding a new entry means the
/// importer has been validated against a fresh upload of the source.
///
/// The digest is of `model.safetensors.index.json`, which maps tensor names to
/// shard files and says nothing of the weights. Any checkpoint sharded the
/// same way shares it: an abliterated Gemma 4 has gemma4's, and some re-tunes
/// have supergemma4's. It pins a layout; the revision pins the weights.
public enum SourceFingerprint {
    public static let knownFingerprints: [String: String] = Dictionary(
        uniqueKeysWithValues: SupportedModelSource.all.map {
            ($0.repoID, $0.sourceIndexSHA256)
        })

    /// Returns the recognised model ID for a given index.json SHA-256, or nil.
    public static func modelID(forIndexSha256 sha256Hex: String) -> String? {
        for (id, sha) in knownFingerprints where sha == sha256Hex { return id }
        return nil
    }
}
