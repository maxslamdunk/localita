import Testing
@testable import TurboFieldfareAppPresentation

@Suite("ReasoningDisclosure")
struct ReasoningDisclosureTests {
    @Test func openWhileReasoningAndClosedWhenTheAnswerStarts() {
        var disclosure = ReasoningDisclosure()
        disclosure.beginRun()
        #expect(disclosure.isOpen)

        disclosure.answerStarted(readerIsFollowing: true)
        #expect(!disclosure.isOpen)
    }

    @Test func aReaderWhoScrolledAwayKeepsTheTextOpen() {
        var disclosure = ReasoningDisclosure()
        disclosure.beginRun()

        disclosure.answerStarted(readerIsFollowing: false)
        #expect(disclosure.isOpen)
    }

    @Test func closingItDuringReasoningHoldsThroughTheAnswer() {
        var disclosure = ReasoningDisclosure()
        disclosure.beginRun()
        disclosure.toggle()

        disclosure.answerStarted(readerIsFollowing: false)
        #expect(!disclosure.isOpen)
    }

    @Test func aNewRunForgetsTheLastChoice() {
        var disclosure = ReasoningDisclosure()
        disclosure.beginRun()
        disclosure.toggle()

        disclosure.beginRun()
        #expect(disclosure.isOpen)
    }

    @Test func aTranscriptOpenedLaterFollowsWhetherThereIsAnAnswer() {
        var disclosure = ReasoningDisclosure()

        disclosure.sync(hasAnswer: true)
        #expect(!disclosure.isOpen)

        disclosure.sync(hasAnswer: false)
        #expect(disclosure.isOpen)
    }
}
