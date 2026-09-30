import Foundation
import Testing
@testable import TurboFieldfareAppPresentation
@testable import TurboFieldfareMacPresentation

@Suite struct StreamingHoldbackTests {
    private func shown(_ text: String, _ kind: ResponseBlockSplitter.Kind = .paragraph) -> String {
        StreamingHoldback.visible(text, kind: kind)
    }

    // MARK: - Inline equations

    @Test func anInlineEquationStillBeingWrittenIsHeldBack() {
        #expect(shown("The value $x_{1") == "The value ")
        #expect(shown("The value $x_{1}$ is small") == "The value $x_{1}$ is small")
    }

    @Test func anEquationClosingAtTheVeryEndWaitsForTheNextCharacter() {
        // One more letter would make `$E=mc^2$b`, which is not math.
        #expect(shown("Energy is $E=mc^2$") == "Energy is ")
        #expect(shown("Energy is $E=mc^2$.") == "Energy is $E=mc^2$.")
    }

    @Test func aLoneDollarAtTheEndWaitsForTheNextCharacter() {
        #expect(shown("so that $") == "so that ")
        #expect(shown("so that $x") == "so that ")
    }

    @Test func currencyAndEscapedDollarsAreNeverHeld() {
        #expect(shown("It costs $20 and") == "It costs $20 and")
        #expect(shown("It costs \\$5 each") == "It costs \\$5 each")
    }

    @Test func aCurrencyLookingEquationIsNeverTakenBack() {
        // Read as currency while it arrives, so only its closer waits: holding
        // the whole span once it closed would take back text already shown.
        #expect(shown("a common denominator ($4a^2") == "a common denominator ($4a^2")
        #expect(shown("a common denominator ($4a^2$") == "a common denominator ($4a^2")
        #expect(shown("a common denominator ($4a^2$)") == "a common denominator ($4a^2$)")
    }

    @Test func dollarsInCodeAreNeverHeld() {
        #expect(shown("Run `echo $HOME` then") == "Run `echo $HOME` then")
        #expect(shown("echo \"$HOME/$PATH", .fencedCode) == "echo \"$HOME/$PATH")
    }

    @Test func anUnfinishedBackslashParenIsHeld() {
        #expect(shown("so \\(a^2 + b") == "so ")
        #expect(shown("so \\(a^2\\) holds") == "so \\(a^2\\) holds")
        #expect(shown("a trailing \\") == "a trailing ")
    }

    @Test func aClosedPairThatIsNotMathIsShown() {
        #expect(shown("Swift writes \\(count\\) inline") == "Swift writes \\(count\\) inline")
    }

    // MARK: - Display equations

    @Test func aDisplayEquationAppearsOnlyWhenClosed() {
        #expect(shown("Area:\n$$\n\\int_0^1 x") == "Area:\n")
        #expect(shown("$$\n\\int_0^1 x", .displayMath) == "")
        let closed = "Area:\n$$\n\\int_0^1 x\\,dx\n$$"
        #expect(shown(closed) == closed)
    }

    @Test func aBracketDisplayAndAnEnvironmentAppearOnlyWhenClosed() {
        #expect(shown("Then\n\\[\na^2") == "Then\n")
        #expect(shown("Then\n\\[\na^2\n\\]") == "Then\n\\[\na^2\n\\]")
        #expect(shown("\\beg") == "")
        #expect(shown("\\begin{align}\nx &= 1") == "")
        let closed = "\\begin{align}\nx &= 1\n\\end{align}"
        #expect(shown(closed) == closed)
    }

    @Test func aStrayOpenerDoesNotHideTextPastTheLimit() {
        let long = "$$ rated " + String(repeating: "word ", count: 200)
        #expect(shown(long) == long)
    }

    // MARK: - Tables

    @Test func aTableShowsOnlyWholeRows() {
        #expect(shown("| a | b |\n|---|---|\n| 1 | 2", .table) == "| a | b |\n|---|---|\n")
        #expect(shown("| a | b", .table) == "")
    }

    // MARK: - Streaming as a whole

    /// Every tick of a real-shaped answer, one character at a time: what is on
    /// screen is always a prefix of the answer and never shrinks, so nothing
    /// that appeared is taken away again.
    @Test func shownTextOnlyEverGrows() {
        let answer = """
        The light scatters as $I \\propto \\lambda^{-4}$, so blue wins. It costs $20.

        $$
        \\frac{I_{blue}}{I_{red}} = \\left(\\frac{700}{450}\\right)^4 \\approx 5.8
        $$

        Use `$HOME` and \\(a^2 + b^2\\) with **bold $x$ text**.
        """
        var previous = ""
        for end in Array(answer.indices) + [answer.endIndex] {
            let now = shown(String(answer[..<end]))
            #expect(answer.hasPrefix(now))
            #expect(now.count >= previous.count, "shrank at \(answer[..<end].count)")
            previous = now
        }
        #expect(previous == answer)
    }

    /// The same over every block of the transcript corpus, each streamed one
    /// character at a time as its own open block. Whether all of a block is on
    /// screen by its last character is not checked: a block ending on an
    /// equation, or on a stray `$$` that reads as an opener, is held until the
    /// block seals, which is by design and costs one line of delay.
    @Test(arguments: TranscriptCorpus.fixtures)
    func corpusBlocksOnlyEverGrow(_ fixture: String) throws {
        let source = try TranscriptCorpus.source(fixture)
        let split = ResponseBlockSplitter.split(source)
        for block in split.completed + [split.open].compactMap({ $0 }) {
            let text = ResponseBlockSplitter.text(block.utf8Range, in: source)
            // Quadratic by construction; the long fixtures prove nothing the
            // first few thousand characters do not.
            let streamed = String(text.prefix(3000))
            var previous = ""
            for end in Array(streamed.indices) + [streamed.endIndex] {
                let now = StreamingHoldback.visible(String(streamed[..<end]), kind: block.kind)
                #expect(streamed.hasPrefix(now), "\(fixture) showed text it was not sent")
                #expect(now.count >= previous.count,
                        "\(fixture) took text back at \(streamed[..<end].count)")
                previous = now
            }
        }
    }
}
