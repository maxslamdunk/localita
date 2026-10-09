import Foundation
import Synchronization
import TurboFieldfare

/// Whether this process may use the GPU right now, and whether a turn is
/// waiting for it.
///
/// iOS refuses GPU work from an app in the background, unless it is showing
/// Picture in Picture, and from any app once the phone locks (iPhone 17,
/// iOS 26.6, `validation-results-2026-10-09-ios-background-probes/`). The
/// decode loop reports a refusal as `GPUWorkNotPermitted`. The turn then waits
/// here with its KV intact and runs the refused token again when the platform
/// layer says the GPU is back. It also retries every few seconds, in case that
/// layer is wrong or a notification never came. A retry costs one refused
/// embedding buffer.
///
/// The Mac never refuses, so the gate never closes there and nothing waits.
public final class GPUWorkGate: Sendable {
    private struct State {
        var available = true
        var waiting = false
        var waitingObserver: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    public init() {}

    /// The platform layer's view: on iOS, the app is active, or it is in
    /// Picture in Picture and the phone is unlocked.
    public var isAvailable: Bool {
        state.withLock { $0.available }
    }

    public func setAvailable(_ available: Bool) {
        state.withLock { $0.available = available }
    }

    /// A turn is paused on a refusal and has not produced anything since.
    public var isWaiting: Bool {
        state.withLock { $0.waiting }
    }

    /// Called, on no particular thread, whenever `isWaiting` changes. Read
    /// `isWaiting` from it rather than trusting the order calls arrive in.
    public func observeWaiting(_ observer: @escaping @Sendable () -> Void) {
        state.withLock { $0.waitingObserver = observer }
    }

    func beginWaiting() { setWaiting(true) }

    func endWaiting() { setWaiting(false) }

    private func setWaiting(_ waiting: Bool) {
        let observer: (@Sendable () -> Void)? = state.withLock {
            guard $0.waiting != waiting else { return nil }
            $0.waiting = waiting
            return $0.waitingObserver
        }
        observer?()
    }

    /// Decides what a refused token does: `.stop` once `shouldStop` says so,
    /// otherwise `.retry` once the gate is open (but not sooner than
    /// `minimumWait`, so a refusal that beats the lock notification does not
    /// spin), or after `retryInterval` whatever the gate says. A cancelled
    /// task throws out of the sleep, which ends the turn as a cancellation.
    func waitForRetry(
        shouldStop: @Sendable () -> Bool,
        minimumWait: Duration = .milliseconds(300),
        retryInterval: Duration = .seconds(5),
        poll: Duration = .milliseconds(100)
    ) async throws -> GPURefusalDecision {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if shouldStop() { return .stop }
            let waited = clock.now - start
            if waited >= minimumWait && (isAvailable || waited >= retryInterval) {
                return .retry
            }
            try await Task.sleep(for: poll)
        }
    }

    /// The handler a turn passes to the decode loop.
    func refusalHandler(shouldStop: @escaping @Sendable () -> Bool) -> GPURefusalHandler {
        { [self] _ in
            beginWaiting()
            return try await waitForRetry(shouldStop: shouldStop)
        }
    }
}

/// A client whose turns pause on a refused GPU rather than failing.
public protocol AppGPUWorkGating: AnyObject {
    var gpuWorkGate: GPUWorkGate { get }
}
