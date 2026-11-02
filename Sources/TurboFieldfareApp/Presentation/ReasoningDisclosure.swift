/// Decides whether the reasoning above an answer is open.
///
/// Open while the model reasons, because at this speed that text is what shows
/// the app is working, and closed once the answer starts, because the answer is
/// what was asked for. The exception is a reader who scrolled away to read the
/// reasoning: closing it then would take the text out from under them.
public struct ReasoningDisclosure: Equatable, Sendable {
    public private(set) var isOpen = true

    public init() {}

    /// Starts a new run. Whatever the reader chose for the last answer's
    /// reasoning says nothing about this one's.
    public mutating func beginRun() {
        isOpen = true
    }

    /// The answer's first text arrived. `readerIsFollowing` is false once the
    /// reader has scrolled the transcript themselves.
    public mutating func answerStarted(readerIsFollowing: Bool) {
        if readerIsFollowing { isOpen = false }
    }

    /// The reader's own choice, which holds until the next run.
    public mutating func toggle() {
        isOpen.toggle()
    }

    /// For a transcript that appears with a turn already under way or finished,
    /// where neither `beginRun` nor `answerStarted` will be seen.
    public mutating func sync(hasAnswer: Bool) {
        isOpen = !hasAnswer
    }
}
