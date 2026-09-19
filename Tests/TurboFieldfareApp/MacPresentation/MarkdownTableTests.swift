import Foundation
import Testing
@testable import TurboFieldfareAppPresentation

@Suite struct MarkdownTableTests {
    @Test func parsesHeaderAndBody() throws {
        let table = try #require(MarkdownTable.parse("""
            | Feature | GCD Queues | Swift Actors |
            | :--- | :--- | :--- |
            | **Model** | Low-level. | High-level. |
            """))
        #expect(table.headers == ["Feature", "GCD Queues", "Swift Actors"])
        #expect(table.rows == [["**Model**", "Low-level.", "High-level."]])
        #expect(table.columnCount == 3)
    }

    @Test func readsEveryAlignment() throws {
        let table = try #require(MarkdownTable.parse("""
            | l | c | r | d |
            | :--- | :-: | ---: | --- |
            | 1 | 2 | 3 | 4 |
            """))
        #expect(table.alignment(0) == .leading)
        #expect(table.alignment(1) == .center)
        #expect(table.alignment(2) == .trailing)
        #expect(table.alignment(3) == .leading)
    }

    /// Past the end of the delimiter row rather than crashing — a ragged table
    /// is what a model that stopped mid-row leaves behind.
    @Test func alignmentBeyondTheDelimiterRowIsLeading() throws {
        let table = try #require(MarkdownTable.parse("""
            | a | b |
            | --- | --- |
            | 1 | 2 | 3 |
            """))
        #expect(table.columnCount == 3)
        #expect(table.alignment(2) == .leading)
    }

    @Test func rejectsProseThatMerelyContainsAPipe() {
        #expect(MarkdownTable.parse("Use a | b to pipe it\nand then continue") == nil)
    }

    /// The gate that matters while streaming: the header has arrived but the
    /// delimiter row has not, so there is nothing to draw a grid from yet.
    @Test func rejectsATableWithNoDelimiterRowYet() {
        #expect(MarkdownTable.parse("| Feature | Result |") == nil)
    }

    @Test func rejectsADelimiterRowWithContentInIt() {
        #expect(MarkdownTable.parse("""
            | a | b |
            | --- | not a delimiter |
            | 1 | 2 |
            """) == nil)
    }

    @Test func keepsAnEscapedPipeInsideACell() throws {
        let table = try #require(MarkdownTable.parse("""
            | expression | meaning |
            | --- | --- |
            | `a \\| b` | union |
            """))
        // The backslash survives: the markdown pass downstream is what turns
        // it into a bare pipe, and stripping it here would lose the pipe.
        #expect(table.rows == [["`a \\| b`", "union"]])
    }

    /// A paragraph is offered to this parser speculatively, because a table
    /// written without outer pipes opens as one. So the GFM rule that the
    /// delimiter row must match the header's cell count has to be enforced:
    /// `a | b` over a bare `---` is a setext heading, not a one-column table.
    @Test func rejectsADelimiterRowThatDoesNotMatchTheHeaderWidth() {
        #expect(MarkdownTable.parse("a | b\n---") == nil)
        #expect(MarkdownTable.parse("| a | b | c |\n| --- | --- |") == nil)
    }

    @Test func keepsAnEmptyLeadingCell() throws {
        let table = try #require(MarkdownTable.parse("""
            |  | count |
            | --- | --- |
            |  | 12 |
            """))
        #expect(table.headers == ["", "count"])
        #expect(table.rows == [["", "12"]])
    }

    @Test func acceptsRowsWithoutOuterPipes() throws {
        let table = try #require(MarkdownTable.parse("""
            a | b
            --- | ---
            1 | 2
            """))
        #expect(table.headers == ["a", "b"])
        #expect(table.rows == [["1", "2"]])
    }

    /// Blank lines inside the block are separators, not rows: a blank row would
    /// otherwise draw as an empty stripe.
    @Test func skipsBlankLines() throws {
        let table = try #require(MarkdownTable.parse("""
            | a | b |
            | --- | --- |

            | 1 | 2 |
            """))
        #expect(table.rows == [["1", "2"]])
    }
}
