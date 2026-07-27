import Foundation

enum AutomaticWindowProtectionMode: Sendable, Equatable {
    case legacy
    case stageManager
    case screenVisibility
    case unavailable
}

enum AutomaticWindowProtectionModePolicy {
    static func mode(
        stageManagerGroupProtectionEnabled: Bool,
        screenVisibilityProtectionEnabled: Bool,
        stageManagerSystemState: StageManagerSystemState
    ) -> AutomaticWindowProtectionMode {
        guard stageManagerGroupProtectionEnabled ||
                screenVisibilityProtectionEnabled else {
            return .legacy
        }

        switch stageManagerSystemState {
        case .disabled:
            return screenVisibilityProtectionEnabled
                ? .screenVisibility
                : .legacy
        case .enabled:
            return stageManagerGroupProtectionEnabled
                ? .stageManager
                : .legacy
        case .unavailable:
            return .unavailable
        }
    }
}

enum AutomaticWindowProtectionInteractionPolicy {
    static func requiresFreshSnapshotAfterAutomaticAction(
        activeMode: AutomaticWindowProtectionMode
    ) -> Bool {
        activeMode == .stageManager || activeMode == .screenVisibility
    }

    static func shouldPauseAutomaticActions(
        activeMode: AutomaticWindowProtectionMode,
        isPointerInteractionInProgress: Bool
    ) -> Bool {
        guard isPointerInteractionInProgress else { return false }
        return requiresFreshSnapshotAfterAutomaticAction(
            activeMode: activeMode
        )
    }
}
