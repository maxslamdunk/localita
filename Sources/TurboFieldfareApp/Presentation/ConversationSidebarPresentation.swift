import Foundation
import TurboFieldfareAppCore

/// Which section of the sidebar a conversation belongs in.
///
/// Computed against an injected `now` rather than `Date()` so the day
/// boundaries are testable at all: a grouping that only works when the test
/// happens to run at midday is a grouping nobody has checked.
public enum ConversationDateGroup: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case previousSevenDays = "Previous 7 Days"
    case older = "Older"

    public static func group(for date: Date,
                             now: Date,
                             calendar: Calendar = .current) -> ConversationDateGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
            return .older
        }
        if calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        // Days apart, not hours: a conversation from four days ago belongs in
        // the same bucket whether it was morning or evening.
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents(
            [.day], from: startOfDate, to: startOfToday).day ?? 0
        // A conversation dated in the future — a clock change, a restored
        // backup — is not "older". Today is the least surprising place for it.
        if days < 0 { return .today }
        return days <= 7 ? .previousSevenDays : .older
    }

    /// The stored conversations, grouped and ordered for the list.
    public static func sections(_ entries: [ConversationMeta], now: Date)
        -> [(group: ConversationDateGroup, entries: [ConversationMeta])] {
        var buckets: [ConversationDateGroup: [ConversationMeta]] = [:]
        for entry in entries.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            buckets[group(for: entry.updatedAt, now: now), default: []].append(entry)
        }
        return allCases.compactMap { group in
            guard let entries = buckets[group], !entries.isEmpty else { return nil }
            return (group, entries)
        }
    }
}

/// One row of the sidebar.
public enum ConversationRowPresentation {
    public static func title(_ meta: ConversationMeta) -> String {
        meta.title.isEmpty ? ConversationTitle.untitled : meta.title
    }

    /// The line under the title: how long the chat is.
    ///
    /// Only one state adds to it. A chat too long for the context in force
    /// says what it needs, because that is fixed from settings rather than
    /// from inside the chat. Which model wrote it is not said here: a chat
    /// moves between models, and each answer names its own. The rarer reasons
    /// a chat cannot continue are explained where they can be acted on, in
    /// the notice under the open chat.
    public static func subtitle(_ meta: ConversationMeta,
                                state: ConversationContinuability) -> String {
        let length = meta.kvTokens.map { "\(decimal($0)) tokens" }
            ?? "\(meta.turnCount) turns"
        if case .needsContext(let required) = state {
            return "\(length) \u{00B7} needs \(contextLabel(required)) context"
        }
        return length
    }

    /// Rounded up to the next context the picker offers, because "needs 6,376
    /// tokens" is not something a user can select.
    public static func contextLabel(_ requiredTokens: Int) -> String {
        let option = AppContextLengthOption.allCases.first { $0.tokens >= requiredTokens }
        guard let option else { return "a longer" }
        return option.shortLabel
    }

    static func decimal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        // Pinned, not the user's locale. An unpinned formatter groups by region
        // -- "1 234" on en_NL, "1.234" elsewhere -- so this copy read
        // differently on every machine, and the tests asserting "1,234" passed
        // only on a US-configured host. CI runs US-configured, which is why
        // that stayed green until someone ran the suite on a European Mac.
        // en_US, and deliberately not en_US_POSIX: POSIX suppresses digit
        // grouping altogether ("1234"), which fails the same assertions for a
        // new reason. Measured, after trying it.
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// The notice at the foot of a transcript that cannot be continued.
///
/// Not an alert: the guidelines are explicit that alerts are not for
/// information, and this is information about a conversation the user is
/// looking at. It names what is wrong, what it would take to fix, and what the
/// fix costs — a context change reloads the model and ends the open chat, which
/// is not something to discover afterwards.
public enum ConversationStateNotice {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let message: String
        /// Nil when raising the context cannot help.
        public let requiredContext: Int?
        public let offersReread: Bool
    }

    public static func content(for state: ConversationContinuability,
                               currentContext: Int) -> Content? {
        switch state {
        case .continuable, .cannotReplay(reason: .noModelInstalled):
            // With no model installed, the app says what to do elsewhere (the
            // Mac's install screen, the phone's status and Settings), and the
            // chat is as continuable as any other once there is one.
            return nil
        case .needsContext(let required):
            let label = ConversationRowPresentation.contextLabel(required)
            return Content(
                title: "This chat can't continue at your current context length.",
                message: "It holds \(ConversationRowPresentation.decimal(required)) "
                    + "tokens with room to reply; your context is "
                    + "\(ConversationRowPresentation.decimal(currentContext)). "
                    + "Raising the context to \(label) reloads the model and ends "
                    + "the chat that's currently open.",
                requiredContext: required,
                offersReread: false)
        case .cannotReplay(let reason):
            return Content(
                title: "This chat can't be continued.",
                message: message(for: reason),
                requiredContext: nil,
                offersReread: reason != .newerFormat)
        }
    }

    private static func message(for reason: ConversationContinuability.Reason) -> String {
        switch reason {
        case .newerFormat:
            return "This chat uses a newer history format. Open it with a newer "
                + "version of the app to continue safely. Its saved files are unchanged."
        case .noModelInstalled:
            return "No model is installed. Download one to continue this chat."
        case .differentTokenizer:
            return "Part of it was written by a model that reads text differently "
                + "from the one you're using, so it can't pick up where it left "
                + "off. You can read it here, or re-read it into a new chat, which "
                + "starts a different conversation from the same text."
        case .differentTemplate:
            return "It was recorded with a different chat format, so the tokens "
                + "it kept no longer line up. You can read it here, or re-read "
                + "it into a new chat, which starts a different conversation "
                + "from the same text."
        case .differentImageProcessing:
            return "Its images were prepared by an earlier build and would reach "
                + "the model differently now. You can read it here, or re-read "
                + "it into a new chat."
        case .tokenCountUnknown:
            return "It has no replay record, so there is nothing to put back "
                + "into the model's context. You can read it here, or re-read it "
                + "into a new chat."
        case .imageRecordMissing:
            return "One of its images could not be saved, so putting the chat "
                + "back would give the model a picture with nothing behind it. "
                + "You can read it here, or re-read it into a new chat."
        }
    }
}

/// Copy for the window controls in the status strip.
public enum WindowControlsPresentation {
    public static func sidebarToggleHelp(isVisible: Bool) -> String {
        isVisible ? "Hide Sidebar" : "Show Sidebar"
    }

    public static func sidebarToggleAccessibilityLabel(isVisible: Bool) -> String {
        sidebarToggleHelp(isVisible: isVisible)
    }

    public static func inspectorToggleHelp(isVisible: Bool) -> String {
        isVisible ? "Hide Inspector" : "Show Inspector"
    }

    public static func inspectorToggleAccessibilityLabel(isVisible: Bool) -> String {
        inspectorToggleHelp(isVisible: isVisible)
    }

    public static let newChatHelp = "New Chat"
    public static let newChatAccessibilityLabel = "New Chat"
}
