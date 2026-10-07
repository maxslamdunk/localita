import Foundation

/// A model repository named by what someone pastes: `owner/name`, or a link
/// to the repository or any page or file in it.
public struct HuggingFaceLink: Equatable, Sendable {
    public let repoID: String
    /// The branch, tag or commit the link points at; `main` when it names none.
    public let revision: String

    /// Nil for anything that is not a model repository: another site, a
    /// dataset or a Space, or a name with characters Hugging Face never uses.
    public init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where rest.lowercased().hasPrefix(scheme) {
            rest.removeFirst(scheme.count)
        }
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<cut])
        }
        var parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let host = parts.first?.lowercased(),
           ["huggingface.co", "www.huggingface.co", "hf.co"].contains(host) {
            parts.removeFirst()
        } else if parts.first?.contains(".") == true, parts.count > 2 {
            // Another host. A two-part name such as `owner/model.v1` has dots too.
            return nil
        }
        guard parts.count >= 2 else { return nil }
        if ["datasets", "spaces", "collections", "docs"].contains(parts[0]) { return nil }
        let owner = parts[0]
        let name = parts[1]
        guard Self.isValidPart(owner), Self.isValidPart(name) else { return nil }
        repoID = owner + "/" + name
        if parts.count >= 4, ["tree", "blob", "resolve", "commit"].contains(parts[2]) {
            revision = parts[3]
        } else {
            revision = "main"
        }
    }

    private static func isValidPart(_ part: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !part.isEmpty && part.count <= 96 && part.allSatisfy(allowed.contains)
            && part != "." && part != ".."
    }
}
