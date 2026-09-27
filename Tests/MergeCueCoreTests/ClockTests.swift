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

    @Test func systemClockIsCloseToNow() {
        let delta = abs(SystemClock().now.timeIntervalSinceNow)
        #expect(delta < 5)
    }
}
