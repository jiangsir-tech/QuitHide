import Foundation
import Testing
@testable import QuitHide

@Suite("Automatic window protection mode routing")
struct AutomaticWindowProtectionTests {
    @Test("Both settings off always preserve legacy automation")
    func bothFeaturesOff() {
        for state in groupingStates {
            #expect(mode(
                groupProtection: false,
                visibilityProtection: false,
                state: state
            ) == .legacy)
        }
    }

    @Test("Stage Manager on uses only group protection")
    func stageManagerOnUsesOnlyGroupProtection() {
        #expect(mode(
            groupProtection: true,
            visibilityProtection: true,
            state: .enabled
        ) == .stageManager)
        #expect(mode(
            groupProtection: false,
            visibilityProtection: true,
            state: .enabled
        ) == .legacy)
    }

    @Test("Stage Manager off uses visibility protection when enabled")
    func stageManagerOffUsesVisibilityProtection() {
        #expect(mode(
            groupProtection: true,
            visibilityProtection: true,
            state: .disabled
        ) == .screenVisibility)
        #expect(mode(
            groupProtection: false,
            visibilityProtection: true,
            state: .disabled
        ) == .screenVisibility)
        #expect(mode(
            groupProtection: true,
            visibilityProtection: false,
            state: .disabled
        ) == .legacy)
    }

    @Test("An uncertain Stage Manager state fails closed")
    func uncertainStageManagerStateFailsClosed() {
        #expect(mode(
            groupProtection: true,
            visibilityProtection: false,
            state: .unavailable
        ) == .unavailable)
        #expect(mode(
            groupProtection: false,
            visibilityProtection: true,
            state: .unavailable
        ) == .unavailable)
        #expect(mode(
            groupProtection: true,
            visibilityProtection: true,
            state: .unavailable
        ) == .unavailable)
    }

    @Test("Dragging pauses automatic actions in both protection modes")
    func draggingPausesProtectedAutomaticActions() {
        #expect(AutomaticWindowProtectionInteractionPolicy
            .shouldPauseAutomaticActions(
                activeMode: .stageManager,
                isPointerInteractionInProgress: true
            ))
        #expect(AutomaticWindowProtectionInteractionPolicy
            .shouldPauseAutomaticActions(
                activeMode: .screenVisibility,
                isPointerInteractionInProgress: true
            ))
        #expect(!AutomaticWindowProtectionInteractionPolicy
            .shouldPauseAutomaticActions(
                activeMode: .legacy,
                isPointerInteractionInProgress: true
            ))
        #expect(!AutomaticWindowProtectionInteractionPolicy
            .shouldPauseAutomaticActions(
                activeMode: .stageManager,
                isPointerInteractionInProgress: false
            ))
    }

    @Test("Only consecutive read failures show a warning")
    func repeatedFailuresShowWarning() {
        let first = AutomaticWindowProtectionFailurePresentationPolicy
            .recordFailure(
                previousConsecutiveFailureCount: 0
            )
        let second = AutomaticWindowProtectionFailurePresentationPolicy
            .recordFailure(
                previousConsecutiveFailureCount:
                    first.consecutiveFailureCount
            )
        let third = AutomaticWindowProtectionFailurePresentationPolicy
            .recordFailure(
                previousConsecutiveFailureCount:
                    second.consecutiveFailureCount
            )

        #expect(first.consecutiveFailureCount == 1)
        #expect(first.presentation == .waitingForStability)
        #expect(second.consecutiveFailureCount == 2)
        #expect(second.presentation == .unavailable)
        #expect(third == second)
    }

    @Test("Concurrent waiters count one observation only once")
    func duplicateObservationDoesNotEscalateWarning() {
        var tracker =
            AutomaticWindowProtectionFailurePresentationTracker()
        let firstObservation = UUID()

        #expect(tracker.recordFailure(
            observationID: firstObservation
        ) == .waitingForStability)
        #expect(tracker.recordFailure(
            observationID: firstObservation
        ) == .waitingForStability)
        #expect(tracker.consecutiveFailureCount == 1)
        #expect(tracker.recordFailure(
            observationID: UUID()
        ) == .unavailable)

        tracker.reset()
        #expect(tracker.consecutiveFailureCount == 0)
        #expect(tracker.lastObservationID == nil)
        #expect(tracker.recordFailure(
            observationID: UUID()
        ) == .waitingForStability)
    }

    @Test("Protected status presentation preserves alert priority")
    func protectedStatusPresentationPreservesAlertPriority() {
        #expect(
            AppAutomationStatus(text: "Waiting").tone == .standard
        )
        #expect(
            AppAutomationStatus(
                text: "Protected",
                isProtected: true
            ).tone == .protected
        )
        #expect(
            AppAutomationStatus(
                text: "Warning",
                isWarning: true,
                isProtected: true
            ).tone == .warning
        )
        #expect(
            AppAutomationStatus(
                text: "Error",
                isError: true,
                isWarning: true,
                isProtected: true
            ).tone == .error
        )
    }

    @Test("A dynamic protection snapshot is used for only one automatic action")
    func dynamicSnapshotIsSingleUse() {
        #expect(AutomaticWindowProtectionInteractionPolicy
            .requiresFreshSnapshotAfterAutomaticAction(
                activeMode: .stageManager
            ))
        #expect(AutomaticWindowProtectionInteractionPolicy
            .requiresFreshSnapshotAfterAutomaticAction(
                activeMode: .screenVisibility
            ))
        #expect(!AutomaticWindowProtectionInteractionPolicy
            .requiresFreshSnapshotAfterAutomaticAction(
                activeMode: .legacy
            ))
        #expect(!AutomaticWindowProtectionInteractionPolicy
            .requiresFreshSnapshotAfterAutomaticAction(
                activeMode: .unavailable
            ))
    }

    private var groupingStates: [StageManagerSystemState] {
        [.disabled, .enabled, .unavailable]
    }

    private func mode(
        groupProtection: Bool,
        visibilityProtection: Bool,
        state: StageManagerSystemState
    ) -> AutomaticWindowProtectionMode {
        AutomaticWindowProtectionModePolicy.mode(
            stageManagerGroupProtectionEnabled: groupProtection,
            screenVisibilityProtectionEnabled: visibilityProtection,
            stageManagerSystemState: state
        )
    }
}
