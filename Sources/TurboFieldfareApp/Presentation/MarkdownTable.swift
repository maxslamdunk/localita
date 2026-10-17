import Foundation

/// A pipe table, parsed into rows and columns.
///
/// Platform-neutral on purpose. The drawing is not — iOS has no `NSTextTable`
/// and nothing inside an attributed string can rule a grid there, so the phone
/// builds one out of views — but deciding *what the cells are* is string work,
/// and string work that only exists inside an app target is string work no test
/// can reach.
///
/// Not reused from `ResponseMarkdownRenderer`: that renderer's table walk turns
/// cells into `NSTextTableBlock`s as it goes, so its parse and its layout are
/// the same pass and neither half comes out on its own.
public struct MarkdownTable: Equatable {
    public enum Alignment: Equatable {
        case leading
        case center
        case trailing
    }

    public let headers: [String]
    public let alignments: [Alignment]
    public let rows: [[String]]

    public init(headers: [String], alignments: [Alignment], rows: [[String]]) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
    }

    /// Widest row wins, so a ragged table still draws a rectangle. A model that
    /// stops mid-table leaves a short last row, and dropping it would make the
    /// table jump a column narrower for one tick.
    public var columnCount: Int {
        max(headers.count, max(alignments.count, rows.map(\.count).max() ?? 0))
    }

    public func alignment(_ column: Int) -> Alignment {
        column < alignments.count ? alignments[column] : .leading
    }

    /// Nil when this is not a table after all.
    ///
    /// A block opens as `.table` on its first `|`, which a line of prose
    /// containing a pipe also does, so this gate is what stops that being drawn
    /// as a one-cell grid. GFM's rule is the one applied: a header row, and a
    /// delimiter row directly under it.
    public static func parse(_ source: String) -> MarkdownTable? {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2,
              let alignments = alignmentRow(lines[1]) else { return nil }
        let headers = cells(of: lines[0])
        // GFM requires the delimiter row to have exactly as many cells as the
        // header. Enforced because without it `a | b` over a bare `---` reads
        // as a one-column table, and that shape is a setext heading. The rule
        // only starts to matter now that a paragraph is offered to this parser
        // speculatively, where before only a `|`-led block reached it.
        guard !headers.isEmpty, alignments.count == headers.count else { return nil }
        return MarkdownTable(
            headers: headers,
            alignments: alignments,
            rows: lines.dropFirst(2).map { cells(of: $0) })
    }

    /// Whether `delimiter` is a delimiter row for `header`: GFM's width rule,
    /// the same one `parse` applies. The splitter asks this when a row of
    /// dashes arrives under a line, to tell a table from a setext heading.
    static func isHeader(_ header: String, delimiter: String) -> Bool {
        guard header.contains("|"),
              let alignments = alignmentRow(
                delimiter.trimmingCharacters(in: .whitespaces)) else { return false }
        let headers = cells(of: header.trimmingCharacters(in: .whitespaces))
        return !headers.isEmpty && alignments.count == headers.count
    }

    /// Splits on unescaped pipes.
    ///
    /// A `\|` is content — it is how a pipe gets *inside* a cell — and the
    /// backslash is left in place, because the cell text goes on to the
    /// markdown pass, which is what turns `\|` into `|`. Stripping it here
    /// would put a bare pipe into markdown and lose it again.
    static func cells(of line: String) -> [String] {
        var found: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                found.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        found.append(current)
        // The outer pipes of `| a | b |` are syntax, and each leaves an empty
        // cell behind. One is dropped at each end, never more, so a genuinely
        // empty first or last column survives.
        if found.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            found.removeFirst()
        }
        if found.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            found.removeLast()
        }
        return found.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `| :--- | ---: | :-: |`. Every cell must be dashes and colons and
    /// nothing else, which is what separates the delimiter row from a body row
    /// whose first cell happens to start with a dash.
    private static func alignmentRow(_ line: String) -> [Alignment]? {
        let parts = cells(of: line)
        guard !parts.isEmpty else { return nil }
        var found: [Alignment] = []
        for part in parts {
            guard part.contains("-"),
                  part.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): found.append(.center)
            case (false, true): found.append(.trailing)
            default: found.append(.leading)
            }
        }
        return found
    }
}
