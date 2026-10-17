import Foundation
import Testing
@testable import TurboFieldfareAppPresentation

/// The seam between `ResponseBlockSplitter` and `MarkdownTable`.
///
/// This suite exists because of a bug it would have caught. `MarkdownTableTests`
/// covers the parser against clean strings, and every one of those tests passed
/// while tables still rendered as raw text on the phone — because nothing
/// checked that the splitter ever hands the parser the string. A table written
/// without outer pipes opens as `.paragraph`, since `kind()` classifies a line
/// by its first byte and that byte is `N` in `Name | Role`, so the parser was
/// never reached at all.
///
/// So these assert on the pair: what the splitter called the block, and whether
/// that block's text parses. Testing either half alone is what let the bug
/// through.
@Suite struct TableBlockRoutingTests {
    private struct Found: Equatable {
        let kind: ResponseBlockSplitter.Kind
        let parses: Bool
    }

    private func blocks(_ source: String) -> [Found] {
        let split = ResponseBlockSplitter.split(source)
        let all = split.completed + (split.open.map { [$0] } ?? [])
        return all.map { block in
            Found(kind: block.kind,
                  parses: MarkdownTable.parse(
                    ResponseBlockSplitter.text(block.utf8Range, in: source)) != nil)
        }
    }

    /// The shape reported from the device. It opens as a paragraph, since its
    /// first byte is `N`, and the delimiter row makes it a table.
    @Test func aPipelessTableBecomesATableAtItsDelimiterRow() {
        #expect(blocks("""
            Name | Role | Level
            --- | --- | ---
            Alice | Admin | High
            Bob | User | Low
            """) == [Found(kind: .table, parses: true)])
    }

    /// As the last line of an answer, the delimiter row has no newline and is
    /// never committed, so the block stays a paragraph. The view's paragraph
    /// retry is what draws this one.
    @Test func anUnterminatedDelimiterRowLeavesAParagraphThatParses() {
        #expect(blocks("Name | Role\n--- | ---")
            == [Found(kind: .paragraph, parses: true)])
    }

    /// A table directly under a line of prose. GFM takes the line above the
    /// delimiter row as the header and leaves the rest as a paragraph; kept as
    /// one paragraph, the parser found the header where it wanted the
    /// delimiter, and the phone showed the table as source.
    @Test func aTableDirectlyUnderProseSplitsFromIt() {
        let source = """
            Here is the comparison,
            in short:
            | A | B |
            | :--- | ---: |
            | 1 | 2 |
            """
        #expect(blocks(source) == [
            Found(kind: .paragraph, parses: false),
            Found(kind: .table, parses: true),
        ])
        let split = ResponseBlockSplitter.split(source)
        #expect(ResponseBlockSplitter.text(split.blocks[0].utf8Range, in: source)
            == "Here is the comparison,\nin short:")
        #expect(MarkdownTable.parse(ResponseBlockSplitter.text(
            split.blocks[1].utf8Range, in: source))?.rows == [["1", "2"]])
    }

    /// The same for a pipeless table under prose.
    @Test func aPipelessTableDirectlyUnderProseSplitsFromIt() {
        #expect(blocks("Roster:\nName | Role\n--- | ---\nAlice | Admin\n") == [
            Found(kind: .paragraph, parses: false),
            Found(kind: .table, parses: true),
        ])
    }

    /// A heading, list, quote, rule or display equation directly under a
    /// table ends it, where before it became the table's last row.
    @Test(arguments: ["## Next", "- item", "> quote", "***", "$$x$$"])
    func aBlockDirectlyUnderATableEndsIt(_ next: String) {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\(next)\n"
        let split = ResponseBlockSplitter.split(source)
        #expect(split.blocks.count == 2)
        #expect(split.blocks.first?.kind == .table)
        #expect(MarkdownTable.parse(ResponseBlockSplitter.text(
            split.blocks[0].utf8Range, in: source))?.rows == [["1", "2"]])
        #expect(ResponseBlockSplitter.text(
            split.blocks.last?.utf8Range ?? 0..<0, in: source) == next)
    }

    /// A plain line under a table is still a row: GFM reads it as one, and a
    /// model's pipeless rows look exactly like it.
    @Test func aPlainLineUnderATableIsARow() {
        #expect(blocks("| A |\n| --- |\n| 1 |\nmore\n")
            == [Found(kind: .table, parses: true)])
    }

    /// The scan resumes a line at a time, so the split has to come out the
    /// same however the text arrived.
    @Test func streamedTableUnderProseMatchesAFreshScan() {
        let source = "Intro:\n| A | B |\n| --- | --- |\n| 1 | 2 |\n## Next\nBody\n"
        var split = ResponseBlockSplitter.Split()
        let bytes = Array(source.utf8)
        for end in 1...bytes.count {
            let prefix = String(decoding: bytes[..<end], as: UTF8.self)
            split = ResponseBlockSplitter.split(prefix, resuming: split)
        }
        #expect(split == ResponseBlockSplitter.split(source))
        #expect(split.blocks.map(\.kind) == [.paragraph, .table, .heading, .paragraph])
    }

    /// Blank lines separate it from the prose, so the table is its own block and
    /// the prose either side stays prose.
    @Test func aPipelessTableSeparatesFromTheProseAroundIt() {
        #expect(blocks("""
            Here is the roster:

            Name | Role | Level
            --- | --- | ---
            Alice | Admin | High

            That is everyone.
            """) == [
                Found(kind: .paragraph, parses: false),
                Found(kind: .table, parses: true),
                Found(kind: .paragraph, parses: false),
            ])
    }

    /// Mid-stream: the header has arrived and the delimiter row has not, so
    /// there is nothing to draw a grid from and the source shows for one tick.
    @Test func aHalfArrivedPipelessTableDoesNotParseYet() {
        #expect(blocks("Name | Role | Level") == [Found(kind: .paragraph, parses: false)])
    }

    /// The false positive the paragraph retry could have introduced: ordinary
    /// prose that happens to contain a pipe.
    @Test func proseContainingAPipeIsNotATable() {
        #expect(blocks("""
            Use a | b to pipe it
            and then continue on
            """) == [Found(kind: .paragraph, parses: false)])
    }

    /// The other false positive, and the reason the parser enforces GFM's
    /// header/delimiter width rule: this is a setext heading, not a table.
    @Test func aSetextHeadingIsNotATable() {
        #expect(blocks("a | b\n---") == [Found(kind: .paragraph, parses: false)])
    }

    /// The path that already worked keeps working: a leading `|` classifies as
    /// `.table` at the splitter and never needs the paragraph retry.
    @Test func anOuterPipeTableStillClassifiesAsATable() {
        #expect(blocks("""
            | Feature | GCD | Actors |
            | :--- | :--- | :--- |
            | Model | Low-level. | High-level. |
            """) == [Found(kind: .table, parses: true)])
    }
}
