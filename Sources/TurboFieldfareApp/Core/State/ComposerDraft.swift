import Foundation

/// What was in the message box when the app last left the screen.
///
/// iOS ends a suspended app without telling it, and at this app's size that is
/// a matter of minutes, so words held only in `promptText` are gone by the time
/// the user comes back. They are the one thing on screen that has not been
/// written anywhere: the turns already sent are on disk.
public struct ComposerDraft: Codable, Equatable, Sendable {
    public let text: String
    /// The stored chat the words were written in, or nil for a new chat. Kept
    /// because a reply put back without its chat would go out with none of the
    /// context it answers.
    public let conversationID: UUID?

    public init(text: String, conversationID: UUID?) {
        self.text = text
        self.conversationID = conversationID
    }
}

/// Keeps the one draft across launches. `UserDefaults` because the write has to
/// outlive a process that may be ended moments later, and it hands the value to
/// a system daemon rather than leaving it in this one.
public struct ComposerDraftStore {
    private static let key = "composerDraft"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Replaces what is kept. Nil clears it, so a box emptied or sent since the
    /// last save does not bring old words back.
    public func save(_ draft: ComposerDraft?) {
        guard let draft, let data = try? JSONEncoder().encode(draft) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }

    public func load() -> ComposerDraft? {
        defaults.data(forKey: Self.key).flatMap {
            try? JSONDecoder().decode(ComposerDraft.self, from: $0)
        }
    }
}
