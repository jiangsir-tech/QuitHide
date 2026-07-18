import Foundation
import Testing
@testable import QuitHide

@Suite("Automation timing and retry state")
struct AutomationTimingTests {
    @Test("Pause returns the duration used to shift timers")
    func pauseReturnsDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        var suspension = TimingSuspension()

        suspension.suspend(for: .manualPause, at: start)
        #expect(suspension.effectiveNow == start)
        #expect(suspension.resume(for: .manualPause, at: start.addingTimeInterval(120)) == 120)
    }

    @Test("Overlapping pause and sleep shift timers only once")
    func overlappingPauseAndSleepShiftOnce() {
        let start = Date(timeIntervalSince1970: 1_000)
        var suspension = TimingSuspension()

        suspension.suspend(for: .manualPause, at: start)
        suspension.suspend(for: .systemSleep, at: start.addingTimeInterval(10))
        #expect(suspension.resume(for: .systemSleep, at: start.addingTimeInterval(100)) == nil)
        #expect(suspension.resume(for: .manualPause, at: start.addingTimeInterval(120)) == 120)
    }

    @Test("Retries stop after three failures")
    func retryStopsAfterThreeFailures() {
        let start = Date(timeIntervalSince1970: 1_000)
        var retry = ActionRetryState()

        retry.recordFailure(at: start, delay: 30)
        #expect(!retry.canAttempt(at: start.addingTimeInterval(29)))
        #expect(retry.canAttempt(at: start.addingTimeInterval(30)))

        retry.recordFailure(at: start.addingTimeInterval(30), delay: 30)
        retry.recordFailure(at: start.addingTimeInterval(60), delay: 30)
        #expect(!retry.hasAttemptsRemaining)
        #expect(!retry.canAttempt(at: start.addingTimeInterval(1_000)))
    }

    @Test("Retry deadline moves across a suspension")
    func retryDeadlineMovesAcrossSuspension() {
        let start = Date(timeIntervalSince1970: 1_000)
        var retry = ActionRetryState()
        retry.recordFailure(at: start, delay: 30)
        retry.shiftRetryDate(by: 120)

        #expect(!retry.canAttempt(at: start.addingTimeInterval(149)))
        #expect(retry.canAttempt(at: start.addingTimeInterval(150)))
    }
}
