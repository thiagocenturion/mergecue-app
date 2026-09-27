import Foundation
import MergeCueCore
import Testing

private actor Recorder {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

@Suite("Clocks")
struct ClockTests {
    @Test func testClockStartsAtAFixedInstantAndAdvances() {
        let clock = TestClock()
        #expect(clock.now == Fixture.date)
        clock.advance(by: 90)
        #expect(clock.now == Fixture.date.addingTimeInterval(90))
        clock.advance(to: Fixture.date)
        #expect(clock.now == Fixture.date.addingTimeInterval(90), "never moves backwards")
        clock.advance(by: -10)
        #expect(clock.now == Fixture.date.addingTimeInterval(90))
    }

    @Test func sleepSuspendsUntilTheDeadlineIsReached() async throws {
        let clock = TestClock()
        let recorder = Recorder()
        let task = Task {
            try await clock.sleep(for: 60)
            await recorder.append("woke at \(clock.now.timeIntervalSince(Fixture.date))")
        }
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines == [Fixture.date.addingTimeInterval(60)])

        clock.advance(by: 59)
        #expect(clock.pendingSleeperCount == 1, "still asleep before the deadline")

        clock.advance(by: 1)
        #expect(clock.pendingSleeperCount == 0)
        try await task.value
        #expect(await recorder.events == ["woke at 60.0"])
    }

    @Test func sleepersWakeInDeadlineOrder() async throws {
        let clock = TestClock()
        let recorder = Recorder()
        let long = Task {
            try await clock.sleep(for: 30)
            await recorder.append("long")
        }
        await clock.waitForSleepers(count: 1)
        let short = Task {
            try await clock.sleep(for: 10)
            await recorder.append("short")
        }
        await clock.waitForSleepers(count: 2)

        clock.advance(by: 15)
        try await short.value
        #expect(await recorder.events == ["short"])
        #expect(clock.pendingSleeperCount == 1)

        clock.advance(by: 100)
        try await long.value
        #expect(await recorder.events == ["short", "long"])
    }

    @Test func zeroOrNegativeSleepReturnsImmediately() async throws {
        let clock = TestClock()
        try await clock.sleep(for: 0)
        try await clock.sleep(for: -5)
        #expect(clock.pendingSleeperCount == 0)
        try await SystemClock().sleep(for: 0)
    }

    @Test func cancellationThrowsAndRemovesTheSleeper() async {
        let clock = TestClock()
        let task = Task { try await clock.sleep(for: 3_600) }
        await clock.waitForSleepers(count: 1)
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test func cancelledBeforeSleepingThrowsImmediately() async {
        let clock = TestClock()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: 10)
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test func manyConcurrentSleepersAllWake() async throws {
        let clock = TestClock()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { try await clock.sleep(for: TimeInterval(index + 1)) }
            }
            await clock.waitForSleepers(count: 50)
            clock.advance(by: 50)
            try await group.waitForAll()
        }
        #expect(clock.pendingSleeperCount == 0)
    }

    // MARK: Hostile durations (Retry-After: inf, overflowing backoff)

    @Test func sanitizedSleepClampsNonFiniteAndHugeValues() {
        #expect(MCClockLimits.sanitizedSleep(.nan) == 0)
        #expect(MCClockLimits.sanitizedSleep(-.infinity) == 0)
        #expect(MCClockLimits.sanitizedSleep(-1) == 0)
        #expect(MCClockLimits.sanitizedSleep(0) == 0)
        #expect(MCClockLimits.sanitizedSleep(1.5) == 1.5)
        #expect(MCClockLimits.sanitizedSleep(.infinity) == MCClockLimits.maxSleep)
        #expect(MCClockLimits.sanitizedSleep(1e19) == MCClockLimits.maxSleep)
        #expect(MCClockLimits.sanitizedSleep(Double.greatestFiniteMagnitude) == MCClockLimits.maxSleep)
    }

    @Test func systemClockReturnsImmediatelyForNaN() async throws {
        let clock = ContinuousClock()
        let elapsed = try await clock.measure { try await SystemClock().sleep(for: .nan) }
        #expect(elapsed < .seconds(1))
    }

    /// These used to trap ("Double value cannot be converted…"); now they sleep (clamped) and stay cancellable.
    @Test(arguments: [Double.infinity, 1e19, Double.greatestFiniteMagnitude])
    func systemClockSurvivesHugeDurations(_ seconds: Double) async {
        let task = Task { try await SystemClock().sleep(for: seconds) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func testClockClampsLikeTheSystemClock() async throws {
        let clock = TestClock()
        try await clock.sleep(for: .nan)
        #expect(clock.pendingSleeperCount == 0)

        let task = Task { try await clock.sleep(for: .infinity) }
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines == [Fixture.date.addingTimeInterval(MCClockLimits.maxSleep)])
        clock.advance(by: MCClockLimits.maxSleep)
        try await task.value
        #expect(clock.pendingSleeperCount == 0)
    }

    /// Cancellation racing `advance`: no double resume, no stuck sleeper, and no leaked bookkeeping.
    @Test func cancellationRacingAdvanceLeaksNothing() async {
        let clock = TestClock()
        for round in 0..<200 {
            await withTaskGroup(of: Void.self) { group in
                var sleepers: [Task<Void, any Error>] = []
                for index in 0..<8 {
                    sleepers.append(Task { try await clock.sleep(for: index.isMultiple(of: 3) ? 0 : 1) })
                }
                group.addTask { clock.advance(by: 1) }
                group.addTask {
                    for (index, sleeper) in sleepers.enumerated() where (index + round).isMultiple(of: 2) {
                        sleeper.cancel()
                    }
                }
                await group.waitForAll()
                // Sleepers that registered after the advance would wait forever: cancel everything left.
                for sleeper in sleepers { sleeper.cancel() }
                for sleeper in sleepers {
                    _ = await sleeper.result
                }
            }
            if clock.pendingSleeperCount != 0 || clock.pendingRegistrationCount != 0 { break }
        }
        #expect(clock.pendingSleeperCount == 0)
        #expect(clock.pendingRegistrationCount == 0)
    }

    @Test func systemClockIsCloseToNow() {
        let delta = abs(SystemClock().now.timeIntervalSinceNow)
        #expect(delta < 5)
    }
}
