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

    /// The shape reported from the device. One block, and it parses — the view
    /// retries the parse on a paragraph precisely so this draws as a grid.
    @Test func aPipelessTableArrivesAsOneParagraphThatParses() {
        #expect(blocks("""
            Name | Role | Level
            --- | --- | ---
            Alice | Admin | High
            Bob | User | Low
            """) == [Found(kind: .paragraph, parses: true)])
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
                Found(kind: .paragraph, parses: true),
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
