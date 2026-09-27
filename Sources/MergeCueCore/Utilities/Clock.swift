import Foundation
import os

/// Injectable wall clock + sleeping, so schedulers and leases are testable without real time.
public protocol MCClock: Sendable {
    var now: Date { get }
    /// Suspends for `seconds` (≤ 0 or NaN returns immediately; +∞ and huge values are clamped to
    /// `MCClockLimits.maxSleep`). Throws `CancellationError` when the task is cancelled.
    func sleep(for seconds: TimeInterval) async throws
}

/// Shared sanitizing of sleep durations. Delays often come from provider data (`Retry-After`, rate-limit resets,
/// backoff arithmetic), so non-finite or huge values must never reach `Duration` conversion, which traps.
public enum MCClockLimits {
    /// Longest single sleep: 7 days.
    public static let maxSleep: TimeInterval = 7 * 86_400

    /// `seconds` clamped to `0...maxSleep`; NaN and negative values become 0, +∞ becomes `maxSleep`.
    public static func sanitizedSleep(_ seconds: TimeInterval) -> TimeInterval {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        return min(seconds, maxSleep)
    }
}

/// The real clock.
public struct SystemClock: MCClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for seconds: TimeInterval) async throws {
        let duration = MCClockLimits.sanitizedSleep(seconds)
        guard duration > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: .seconds(duration))
    }
}

/// A manually advanced, thread-safe clock for deterministic tests.
///
/// `sleep(for:)` suspends until `advance(by:)`/`advance(to:)` moves `now` to or past the sleeper's deadline.
/// Use `waitForSleepers(count:)` to wait (without real time) until code under test is suspended in `sleep`.
public final class TestClock: MCClock {
    private struct Sleeper: Sendable {
        let deadline: Date
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var now: Date
        var nextID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        /// Sleep calls that have not reached registration yet (between id allocation and the continuation).
        var unregistered: Set<UInt64> = []
        /// Unregistered sleep calls whose task was cancelled; they throw as soon as they register.
        var cancelledBeforeRegistration: Set<UInt64> = []
        var waiters: [Waiter] = []

        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
            let count = sleepers.count
            let ready = waiters.filter { $0.count <= count }
            waiters.removeAll { $0.count <= count }
            return ready.map(\.continuation)
        }
    }

    private enum Registration {
        case resumeNow
        case cancelled
        case suspended([CheckedContinuation<Void, Never>])
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Starts at `now` (default 2026-01-01T00:00:00Z).
    public init(now: Date = Date(timeIntervalSince1970: 1_767_225_600)) {
        state = OSAllocatedUnfairLock(initialState: State(now: now))
    }

    public var now: Date {
        state.withLock { $0.now }
    }

    /// Number of tasks currently suspended in `sleep(for:)`.
    public var pendingSleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Bookkeeping entries for sleep calls that have not registered yet (0 when idle; exposed for leak tests).
    public var pendingRegistrationCount: Int {
        state.withLock { $0.unregistered.count + $0.cancelledBeforeRegistration.count }
    }

    /// Deadlines of suspended sleepers, earliest first.
    public var pendingDeadlines: [Date] {
        state.withLock { $0.sleepers.values.map(\.deadline).sorted() }
    }

    public func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let duration = MCClockLimits.sanitizedSleep(seconds)
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            state.unregistered.insert(state.nextID)
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration = state.withLock { state -> Registration in
                    state.unregistered.remove(id)
                    if state.cancelledBeforeRegistration.remove(id) != nil { return .cancelled }
                    let deadline = state.now.addingTimeInterval(duration)
                    if duration <= 0 || deadline <= state.now { return .resumeNow }
                    state.sleepers[id] = Sleeper(deadline: deadline, sequence: id, continuation: continuation)
                    return .suspended(state.takeSatisfiedWaiters())
                }
                switch registration {
                case .resumeNow:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .suspended(let waiters):
                    waiters.forEach { $0.resume() }
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper.continuation }
                // Only remember the cancellation if the call has not registered yet; once it registered (and was
                // resumed by `advance` or the immediate path) there is nothing left to cancel.
                if state.unregistered.contains(id) { state.cancelledBeforeRegistration.insert(id) }
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward by `seconds` and resumes every sleeper whose deadline is reached.
    public func advance(by seconds: TimeInterval) {
        let target = state.withLock { $0.now.addingTimeInterval(max(0, seconds)) }
        advance(to: target)
    }

    /// Moves time to `date` (never backwards) and resumes due sleepers in deadline order.
    public func advance(to date: Date) {
        let due = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            if date > state.now { state.now = date }
            let now = state.now
            let ready = state.sleepers.values
                .filter { $0.deadline <= now }
                .sorted { ($0.deadline, $0.sequence) < ($1.deadline, $1.sequence) }
            for sleeper in ready { state.sleepers.removeValue(forKey: sleeper.sequence) }
            return ready.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    /// Returns once at least `count` tasks are suspended in `sleep(for:)`.
    public func waitForSleepers(count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.sleepers.count >= count { return true }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
