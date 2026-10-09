import Foundation
import Synchronization
import Testing
import TurboFieldfare
@testable import TurboFieldfareAppCore

@Suite struct GPUWorkGateTests {
    @Test func aStopRequestEndsTheWaitAsAStop() async throws {
        let gate = GPUWorkGate()
        gate.setAvailable(false)
        let decision = try await gate.waitForRetry(shouldStop: { true })
        #expect(decision == .stop)
    }

    @Test func anOpenGateRetriesOnceTheMinimumWaitHasPassed() async throws {
        let gate = GPUWorkGate()
        let clock = ContinuousClock()
        let start = clock.now
        let decision = try await gate.waitForRetry(
            shouldStop: { false }, minimumWait: .milliseconds(50),
            retryInterval: .seconds(60), poll: .milliseconds(10))
        #expect(decision == .retry)
        #expect(clock.now - start >= .milliseconds(50))
    }

    @Test func aClosedGateStillRetriesAfterTheInterval() async throws {
        let gate = GPUWorkGate()
        gate.setAvailable(false)
        let decision = try await gate.waitForRetry(
            shouldStop: { false }, minimumWait: .zero,
            retryInterval: .milliseconds(50), poll: .milliseconds(10))
        #expect(decision == .retry)
    }

    @Test func openingTheGateEndsAWaitEarly() async throws {
        let gate = GPUWorkGate()
        gate.setAvailable(false)
        let waiting = Task {
            try await gate.waitForRetry(
                shouldStop: { false }, minimumWait: .zero,
                retryInterval: .seconds(60), poll: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        gate.setAvailable(true)
        #expect(try await waiting.value == .retry)
    }

    @Test func cancellingTheTaskThrowsOutOfTheWait() async {
        let gate = GPUWorkGate()
        gate.setAvailable(false)
        let waiting = Task {
            try await gate.waitForRetry(
                shouldStop: { false }, minimumWait: .zero,
                retryInterval: .seconds(60), poll: .milliseconds(10))
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func theObserverHearsEachChangeOfTheWaitingFlagOnce() async throws {
        let gate = GPUWorkGate()
        let seen = Mutex<[Bool]>([])
        gate.observeWaiting { seen.withLock { $0.append(gate.isWaiting) } }

        let handler = gate.refusalHandler(shouldStop: { true })
        #expect(try await handler(GPUWorkNotPermitted(detail: "test")) == .stop)
        gate.beginWaiting()
        gate.endWaiting()
        gate.endWaiting()

        #expect(seen.withLock { $0 } == [true, false])
    }
}
