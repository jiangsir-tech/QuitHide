import Foundation
import Testing
@testable import QuitHide

@Suite("App automation deferral")
struct AppAutomationDeferralTests {
    @Test("Deferral presets are 15, 30, and 60 minutes")
    func presetDurationsAre15_30And60Minutes() {
        #expect(AppAutomationDeferralDuration.allCases.map(\.seconds) == [900, 1_800, 3_600])
    }

    @Test("A stopped app cannot be deferred")
    func cannotDeferWhenTheAppIsNotRunning() {
        #expect(!AppAutomationDeferralEligibilityPolicy.canDefer(
            isRunning: false,
            actionIsAutomated: true,
            hasUncancelableQuit: false
        ))
    }

    @Test("An app with a non-automated rule cannot be deferred")
    func cannotDeferWhenTheRuleIsNotAutomated() {
        #expect(!AppAutomationDeferralEligibilityPolicy.canDefer(
            isRunning: true,
            actionIsAutomated: false,
            hasUncancelableQuit: false
        ))
    }

    @Test("An app with an outstanding quit request cannot be deferred")
    func cannotDeferWhenAQuitHasBeenRequested() {
        #expect(!AppAutomationDeferralEligibilityPolicy.canDefer(
            isRunning: true,
            actionIsAutomated: true,
            hasUncancelableQuit: true
        ))
        #expect(AppAutomationDeferralEligibilityPolicy.canDefer(
            isRunning: true,
            actionIsAutomated: true,
            hasUncancelableQuit: false
        ))
    }

    @Test("A deferral stays active until its deadline")
    func deferralIsActiveBeforeItsDeadline() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )

        #expect(registry.isDeferred(for: "com.example.editor", at: 1_899))
        #expect(registry.remainingTime(for: "com.example.editor", at: 1_000) == 900)
        #expect(registry.remainingTime(for: "com.example.editor", at: 1_060) == 840)
        #expect(!registry.isDeferred(for: "com.example.editor", at: 1_900))
    }

    @Test("A deferral scheduled during async validation blocks automatic action")
    func deferralScheduledDuringAsyncValidationBlocksAction() {
        var registry = AppAutomationDeferralRegistry()
        let validationRevision = registry.revision(for: "com.example.editor")

        // MainActor work can run while screen fingerprint validation is suspended.
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )

        #expect(!AppAutomationActionValidationPolicy.shouldProceed(
            deferralStateChanged:
                registry.revision(for: "com.example.editor") !=
                    validationRevision,
            isDeferredNow: registry.isDeferred(
                for: "com.example.editor",
                at: 1_001
            ),
            isStillIdleEligible: true
        ))
    }

    @Test("An unchanged deferral and eligible idle timer may proceed after validation")
    func unchangedDeferralStateCanProceedAfterValidation() {
        let registry = AppAutomationDeferralRegistry()
        let validationRevision = registry.revision(for: "com.example.editor")

        #expect(AppAutomationActionValidationPolicy.shouldProceed(
            deferralStateChanged:
                registry.revision(for: "com.example.editor") !=
                    validationRevision,
            isDeferredNow: registry.isDeferred(
                for: "com.example.editor",
                at: 1_001
            ),
            isStillIdleEligible: true
        ))
    }

    @Test("A deferral cancelled during validation blocks the stale action")
    func cancelledDeferralDuringValidationBlocksAction() {
        var registry = AppAutomationDeferralRegistry()
        let validationRevision = registry.revision(for: "com.example.editor")
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )
        _ = registry.endDeferral(for: "com.example.editor", at: 1_001)

        #expect(!AppAutomationActionValidationPolicy.shouldProceed(
            deferralStateChanged:
                registry.revision(for: "com.example.editor") !=
                    validationRevision,
            isDeferredNow: registry.isDeferred(
                for: "com.example.editor",
                at: 1_002
            ),
            isStillIdleEligible: true
        ))
    }

    @Test("Another app's deferral does not invalidate this app's validation")
    func unrelatedDeferralDoesNotInvalidateValidation() {
        var registry = AppAutomationDeferralRegistry()
        let validationRevision = registry.revision(for: "com.example.editor")
        registry.deferAutomation(
            for: "com.example.player",
            duration: .minutes15,
            at: 1_000
        )

        #expect(AppAutomationActionValidationPolicy.shouldProceed(
            deferralStateChanged:
                registry.revision(for: "com.example.editor") !=
                    validationRevision,
            isDeferredNow: registry.isDeferred(
                for: "com.example.editor",
                at: 1_001
            ),
            isStillIdleEligible: true
        ))
    }

    @Test("An expired deferral during async validation still restarts the idle timer")
    func expiredDeferralDuringAsyncValidationBlocksAction() {
        var registry = AppAutomationDeferralRegistry()
        let validationRevision = registry.revision(for: "com.example.editor")
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )

        let resets = registry.expire(at: 1_900)

        #expect(resets.first?.timerRestartAt == 1_900)
        #expect(!AppAutomationActionValidationPolicy.shouldProceed(
            deferralStateChanged:
                registry.revision(for: "com.example.editor") !=
                    validationRevision,
            isDeferredNow: registry.isDeferred(
                for: "com.example.editor",
                at: 1_900
            ),
            isStillIdleEligible: true
        ))
    }

    @Test("A deferral expires at its exact deadline")
    func deferralExpiresAtItsExactDeadline() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )

        #expect(registry.expire(at: 1_899).isEmpty)
        let resets = registry.expire(at: 1_900)
        #expect(resets.count == 1)
        #expect(resets.first?.bundleIdentifier == "com.example.editor")
        #expect(resets.first?.timerRestartAt == 1_900)
        #expect(!registry.isDeferred(for: "com.example.editor", at: 1_900))
    }

    @Test("Scheduling another duration replaces the old deadline")
    func reschedulingReplacesTheExistingDeadline() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes30,
            at: 1_200
        )

        #expect(registry.expire(at: 1_900).isEmpty)
        #expect(registry.isDeferred(for: "com.example.editor", at: 2_999))
        #expect(registry.expire(at: 3_000).count == 1)
    }

    @Test("Expiring a deferral returns the exact timer restart instant")
    func expiredBundlesReturnTheTimerRestartInstant() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 10
        )

        let reset = registry.expire(at: 910).first
        #expect(reset?.bundleIdentifier == "com.example.editor")
        #expect(reset?.timerRestartAt == 910)
    }

    @Test("Ending a deferral returns the exact timer restart instant")
    func endingDeferralReturnsTheTimerRestartInstant() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes30,
            at: 10
        )

        let reset = registry.endDeferral(for: "com.example.editor", at: 75)
        #expect(reset?.bundleIdentifier == "com.example.editor")
        #expect(reset?.timerRestartAt == 75)
        #expect(registry.endDeferral(for: "com.example.editor", at: 80) == nil)
    }

    @Test("Stopping an app removes its deferral")
    func stoppingAnAppRemovesItsDeferral() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )

        #expect(registry.removeStoppedApps(runningBundleIdentifiers: []) == true)
        #expect(registry.removeStoppedApps(runningBundleIdentifiers: []) == false)

        #expect(!registry.isDeferred(for: "com.example.editor", at: 1_001))
        #expect(registry.remainingTime(for: "com.example.editor", at: 1_001) == nil)
    }

    @Test("Disabling inherited automatic policy can remove only selected deferrals")
    func removingInheritedPolicyDeferralsLeavesExplicitAppsAlone() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.inherited",
            duration: .minutes15,
            at: 1_000
        )
        registry.deferAutomation(
            for: "com.example.explicit",
            duration: .minutes15,
            at: 1_000
        )

        let removed = registry.removeDeferrals(for: ["com.example.inherited"])
        #expect(removed)
        #expect(!registry.isDeferred(for: "com.example.inherited", at: 1_001))
        #expect(registry.isDeferred(for: "com.example.explicit", at: 1_001))
    }

    @Test("A deferral stays while another instance of the app runs")
    func deferralRemainsWhileAnyInstanceOfTheBundleRuns() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )

        registry.removeStoppedApps(
            runningBundleIdentifiers: ["com.example.editor"]
        )
        #expect(registry.isDeferred(for: "com.example.editor", at: 1_001))

        registry.removeStoppedApps(runningBundleIdentifiers: [])
        #expect(!registry.isDeferred(for: "com.example.editor", at: 1_002))
    }

    @Test("Deferrals do not affect other apps")
    func deferralsDoNotAffectOtherBundles() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )

        #expect(registry.isDeferred(for: "com.example.editor", at: 1_001))
        #expect(!registry.isDeferred(for: "com.example.player", at: 1_001))
    }

    @Test("Overlapping pauses shift a deferral deadline once")
    func overlappingPausesShiftDeferralDeadlineOnce() {
        var registry = AppAutomationDeferralRegistry()
        registry.deferAutomation(
            for: "com.example.editor",
            duration: .minutes15,
            at: 1_000
        )
        var suspension = TimingSuspension()
        suspension.suspend(for: .manualPause, at: 1_100)
        suspension.suspend(for: .systemSleep, at: 1_120)

        #expect(suspension.resume(for: .systemSleep, at: 1_300) == nil)
        let suspendedDuration = suspension.resume(
            for: .manualPause,
            at: 1_400
        )
        #expect(suspendedDuration == 300)
        registry.shiftDeadlines(by: suspendedDuration ?? 0)

        #expect(registry.isDeferred(for: "com.example.editor", at: 2_199))
        let resets = registry.expire(at: 2_200)
        #expect(resets.count == 1)
        #expect(resets.first?.timerRestartAt == 2_200)
    }
}
