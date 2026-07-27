import Foundation
import Testing
@testable import QuitHide

private final class ManualAutomationClock: AutomationClock {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}

@Suite("Automation timing and retry state")
struct AutomationTimingTests {
    @Test("Pause returns the duration used to shift timers")
    func pauseReturnsDuration() {
        let start: TimeInterval = 1_000
        var suspension = TimingSuspension()

        suspension.suspend(for: .manualPause, at: start)
        #expect(suspension.effectiveNow(at: start + 60) == start)
        #expect(suspension.resume(for: .manualPause, at: start + 120) == 120)
    }

    @Test("Overlapping pause and sleep shift timers only once")
    func overlappingPauseAndSleepShiftOnce() {
        let start: TimeInterval = 1_000
        var suspension = TimingSuspension()

        suspension.suspend(for: .manualPause, at: start)
        suspension.suspend(for: .systemSleep, at: start + 10)
        #expect(suspension.resume(for: .systemSleep, at: start + 100) == nil)
        #expect(suspension.resume(for: .manualPause, at: start + 120) == 120)
    }

    @Test("A Stage Manager read failure overlaps other pauses without double shifting")
    func overlappingStageManagerFailureShiftsOnce() {
        let start: TimeInterval = 1_000
        var suspension = TimingSuspension()

        suspension.suspend(for: .automaticWindowProtectionUnavailable, at: start)
        suspension.suspend(for: .systemSleep, at: start + 10)
        #expect(suspension.resume(
            for: .automaticWindowProtectionUnavailable,
            at: start + 100
        ) == nil)
        #expect(suspension.resume(for: .systemSleep, at: start + 120) == 120)
    }

    @Test("A late failure report can move the suspension start backwards")
    func retroactiveFailureStartIsPreserved() {
        var suspension = TimingSuspension()

        suspension.suspend(for: .systemSleep, at: 1_010)
        suspension.suspend(for: .automaticWindowProtectionUnavailable, at: 1_000)
        #expect(suspension.effectiveNow(at: 1_020) == 1_000)
        #expect(suspension.resume(for: .systemSleep, at: 1_100) == nil)
        #expect(suspension.resume(
            for: .automaticWindowProtectionUnavailable,
            at: 1_120
        ) == 120)
    }

    @Test("A captured sleep interval does not advance effective automation time")
    func sleepDoesNotAdvanceEffectiveTime() {
        let inactiveAt: TimeInterval = 900
        let clock = ManualAutomationClock(now: 1_000)
        var suspension = TimingSuspension()

        suspension.suspend(for: .systemSleep, at: clock.now)
        clock.now = 4_600
        #expect(suspension.effectiveNow(at: clock.now) - inactiveAt == 100)

        let slept = suspension.resume(for: .systemSleep, at: clock.now)
        #expect(slept == 3_600)
        #expect(clock.now - (inactiveAt + (slept ?? 0)) == 100)
    }

    @Test("Retries stop after three failures")
    func retryStopsAfterThreeFailures() {
        let start: TimeInterval = 1_000
        var retry = ActionRetryState()

        retry.recordFailure(at: start, delay: 30)
        #expect(!retry.canAttempt(at: start + 29))
        #expect(retry.canAttempt(at: start + 30))

        retry.recordFailure(at: start + 30, delay: 30)
        retry.recordFailure(at: start + 60, delay: 30)
        #expect(!retry.hasAttemptsRemaining)
        #expect(!retry.canAttempt(at: start + 1_000))
    }

    @Test("Retry deadline moves across a suspension")
    func retryDeadlineMovesAcrossSuspension() {
        let start: TimeInterval = 1_000
        var retry = ActionRetryState()
        retry.recordFailure(at: start, delay: 30)
        retry.shiftRetryDate(by: 120)

        #expect(!retry.canAttempt(at: start + 149))
        #expect(retry.canAttempt(at: start + 150))
    }
}

@Suite("Application unhide policy")
struct ApplicationUnhidePolicyTests {
    @Test("An inactive automated app starts a new timer when it is unhidden")
    func inactiveAutomatedAppRestartsTimer() {
        #expect(ApplicationUnhidePolicy.shouldRestartTimer(
            actionIsAutomated: true,
            applicationIsActive: false
        ))
    }

    @Test("Active or unconfigured apps do not start a background timer")
    func ineligibleAppsDoNotRestartTimer() {
        #expect(!ApplicationUnhidePolicy.shouldRestartTimer(
            actionIsAutomated: true,
            applicationIsActive: true
        ))
        #expect(!ApplicationUnhidePolicy.shouldRestartTimer(
            actionIsAutomated: false,
            applicationIsActive: false
        ))
    }

    @Test("A protected inactive app does not restart its timer when unhidden")
    func heldAppDoesNotRestartTimer() {
        #expect(!ApplicationUnhidePolicy.shouldRestartTimer(
            actionIsAutomated: true,
            applicationIsActive: false,
            applicationIsHeld: true
        ))
    }
}

@Suite("Runtime application identity")
struct RuntimeApplicationIdentityTests {
    private let fallbackA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let fallbackB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test("A reused PID with a different launch date is a different process")
    func launchDateSeparatesProcessGenerations() {
        let first = identifier(launchDate: Date(timeIntervalSince1970: 1_000), fallback: fallbackA)
        let replacement = identifier(launchDate: Date(timeIntervalSince1970: 2_000), fallback: fallbackA)

        #expect(first != replacement)
    }

    @Test("The same launch date produces a stable identity")
    func launchDateIdentityIsStable() {
        let launchDate = Date(timeIntervalSince1970: 1_000)

        #expect(identifier(launchDate: launchDate, fallback: fallbackA) == identifier(
            launchDate: launchDate,
            fallback: fallbackB
        ))
    }

    @Test("Fallback generations separate apps without a launch date")
    func fallbackSeparatesProcessGenerations() {
        #expect(identifier(launchDate: nil, fallback: fallbackA) != identifier(
            launchDate: nil,
            fallback: fallbackB
        ))
    }

    private func identifier(launchDate: Date?, fallback: UUID) -> String {
        RuntimeApplicationIdentity.identifier(
            bundleIdentifier: "com.example.app",
            processIdentifier: 42,
            launchDate: launchDate,
            fallbackGeneration: fallback
        )
    }
}

@Suite("Pre-quit hide timing")
struct PreQuitHideTimingTests {
    @Test("Disabled pre-hide waits until the quit deadline")
    func disabledPreHide() {
        #expect(decision(enabled: false, elapsed: 5, hideDelay: 5, quitDelay: 20) == .wait)
        #expect(decision(enabled: false, elapsed: 20, hideDelay: 5, quitDelay: 20) == .quit)
    }

    @Test("A shorter hide delay creates a pre-hide phase before quitting")
    func preHidePhases() {
        #expect(decision(elapsed: 4, hideDelay: 5, quitDelay: 20) == .wait)
        #expect(decision(elapsed: 5, hideDelay: 5, quitDelay: 20) == .preHide)
        #expect(decision(
            elapsed: 6,
            hideDelay: 5,
            quitDelay: 20,
            hideStage: .inFlight
        ) == .wait)
        #expect(decision(
            elapsed: 6,
            hideDelay: 5,
            quitDelay: 20,
            hideStage: .completed
        ) == .wait)
        #expect(decision(
            elapsed: 6,
            hideDelay: 5,
            quitDelay: 20,
            canAttemptHide: false
        ) == .wait)
        #expect(decision(elapsed: 20, hideDelay: 5, quitDelay: 20) == .quit)
    }

    @Test("An equal hide and quit delay never pre-hides")
    func equalDelays() {
        #expect(decision(elapsed: 9, hideDelay: 10, quitDelay: 10) == .wait)
        #expect(decision(elapsed: 10, hideDelay: 10, quitDelay: 10) == .quit)
    }

    @Test("A longer hide delay never pre-hides")
    func longerHideDelay() {
        #expect(decision(elapsed: 9, hideDelay: 20, quitDelay: 10) == .wait)
        #expect(decision(elapsed: 10, hideDelay: 20, quitDelay: 10) == .quit)
    }

    @Test("An app that is already hidden waits for its quit deadline")
    func alreadyHidden() {
        #expect(decision(
            elapsed: 5,
            hideDelay: 5,
            quitDelay: 20,
            isHidden: true
        ) == .wait)
        #expect(decision(
            elapsed: 20,
            hideDelay: 5,
            quitDelay: 20,
            isHidden: true
        ) == .quit)
    }

    @Test("The quit deadline wins over every hide-stage condition")
    func quitDeadlineWins() {
        #expect(decision(
            elapsed: 20,
            hideDelay: 5,
            quitDelay: 20,
            hideStage: .inFlight,
            canAttemptHide: false
        ) == .quit)
    }

    @Test("A failed manual quit cannot consume the first deadline attempt")
    func failedManualQuitCannotConsumeDeadline() {
        #expect(QuitAutomationTiming.shouldAttemptQuit(
            isFirstDeadlineAttempt: true,
            isAlreadyHandled: true,
            hasActionFailure: true,
            canRetry: false
        ))
    }

    @Test("An accepted manual quit is not duplicated at the deadline")
    func acceptedManualQuitIsNotDuplicated() {
        #expect(!QuitAutomationTiming.shouldAttemptQuit(
            isFirstDeadlineAttempt: true,
            isAlreadyHandled: true,
            hasActionFailure: false,
            canRetry: true
        ))
    }

    @Test("Retries after the deadline still respect cooldown and handling")
    func deadlineRetriesRespectState() {
        #expect(!QuitAutomationTiming.shouldAttemptQuit(
            isFirstDeadlineAttempt: false,
            isAlreadyHandled: false,
            hasActionFailure: true,
            canRetry: false
        ))
        #expect(QuitAutomationTiming.shouldAttemptQuit(
            isFirstDeadlineAttempt: false,
            isAlreadyHandled: false,
            hasActionFailure: true,
            canRetry: true
        ))
        #expect(!QuitAutomationTiming.shouldAttemptQuit(
            isFirstDeadlineAttempt: false,
            isAlreadyHandled: true,
            hasActionFailure: true,
            canRetry: true
        ))
    }

    private func decision(
        enabled: Bool = true,
        elapsed: TimeInterval,
        hideDelay: TimeInterval,
        quitDelay: TimeInterval,
        isHidden: Bool = false,
        hideStage: PreQuitHideStage = .pending,
        canAttemptHide: Bool = true
    ) -> QuitAutomationDecision {
        QuitAutomationTiming.decision(
            enabled: enabled,
            elapsed: elapsed,
            hideDelay: hideDelay,
            quitDelay: quitDelay,
            isHidden: isHidden,
            hideStage: hideStage,
            canAttemptHide: canAttemptHide
        )
    }
}

@Suite("Default automation policy")
struct AutomationPolicyTests {
    @Test("All additional rules are disabled for a new user")
    func additionalRulesDefaultOff() {
        #expect(!AutomationDefaults.unconfiguredHideEnabled)
        #expect(!AutomationDefaults.preQuitHideEnabled)
        #expect(!AutomationDefaults.stageManagerGroupProtectionEnabled)
        #expect(!AutomationDefaults.screenVisibilityProtectionEnabled)
    }

    @Test("Rule picker order matches the visible section semantics")
    func rulePickerOrder() {
        #expect(AutoAction.rulePickerOrder == [.ignore, .unset, .hide, .quit])
    }

    @Test("An app without a rule inherits default hide")
    func unsetInheritsDefaultHide() {
        #expect(AutomationPolicy.effectiveAction(
            explicitAction: .unset,
            defaultHideEnabled: true
        ) == .hide)
    }

    @Test("Disabling default hide preserves the old unset behavior")
    func unsetRemainsUnsetWhenDisabled() {
        #expect(AutomationPolicy.effectiveAction(
            explicitAction: .unset,
            defaultHideEnabled: false
        ) == .unset)
    }

    @Test("Explicit keep and quit rules override the default")
    func explicitRulesWin() {
        #expect(AutomationPolicy.effectiveAction(
            explicitAction: .ignore,
            defaultHideEnabled: true
        ) == .ignore)
        #expect(AutomationPolicy.effectiveAction(
            explicitAction: .quit,
            defaultHideEnabled: true
        ) == .quit)
    }

    @Test("An inherited default ignores stale per-app timing")
    func inheritedDefaultUsesGlobalTiming() {
        #expect(AutomationPolicy.idleMinutes(
            explicitAction: .unset,
            explicitMinutes: 20,
            defaultHideMinutes: 5
        ) == 5)
        #expect(AutomationPolicy.idleMinutes(
            explicitAction: .hide,
            explicitMinutes: 20,
            defaultHideMinutes: 5
        ) == 20)
    }
}
