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
