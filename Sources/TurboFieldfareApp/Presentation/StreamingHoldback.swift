import Foundation

/// How much of the block still being written can go on screen in its final
/// form.
///
/// `TailAutoClose` heals what can be healed — a half-typed `**`, an open fence,
/// a half-written link — so it can be shown styled while it arrives. Two things
/// cannot be healed, and this holds them back instead:
///
/// - An equation. Half a formula cannot be typeset, and showing it as LaTeX
///   source until it seals is what made each one jump from `$\frac{a` to a
///   rendered formula. Held back, it appears once, already typeset.
/// - A table row. A half-arrived row is a grid with empty cells that fill in.
///   Held back, a table grows a whole row at a time.
///
/// Display only, like `TailAutoClose`: the response string is never touched,
/// and a finished turn renders every byte.
public enum StreamingHoldback {
    /// How much text an unfinished equation may keep off screen. A stray `$$`
    /// or `\(` in prose looks exactly like an opener; past this it is shown as
    /// written instead of hiding the rest of its block until the block ends.
    static let limit = 800

    /// The prefix of an open block's text that is safe to show.
    public static func visible(_ text: String, kind: ResponseBlockSplitter.Kind) -> String {
        switch kind {
        case .fencedCode, .indentedCode, .thematicBreak:
            return text
        case .table:
            return completeLines(text)
        default:
            let (units, start) = MathSpanDetector.unfinishedMath(text)
            guard let start, units.count - start <= limit else { return text }
            return String(units[..<start])
        }
    }

    /// Every line the model has finished, which for a table is every row.
    public static func completeLines(_ text: String) -> String {
        guard let newline = text.lastIndex(of: "\n") else { return "" }
        return String(text[...newline])
    }
}
