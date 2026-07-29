import Foundation

enum AutomaticWindowProtectionMode: Sendable, Equatable {
    case legacy
    case stageManager
    case screenVisibility
    case unavailable
}

enum AutomaticWindowProtectionRowStatus: Sendable, Equatable {
    case inUse
    case stageManagerGroupProtected
}

enum AutomaticWindowProtectionRowStatusPolicy {
    static func status(
        activeMode: AutomaticWindowProtectionMode,
        bundleIsProtected: Bool,
        stageManagerHoldReasons: Set<StageManagerHoldReason>
    ) -> AutomaticWindowProtectionRowStatus? {
        guard bundleIsProtected else { return nil }

        switch activeMode {
        case .screenVisibility:
            return .inUse
        case .stageManager:
            if stageManagerHoldReasons.contains(.foregroundGroup) {
                return .inUse
            }
            if stageManagerHoldReasons.contains(.explicitIgnoreAnchor) {
                return .stageManagerGroupProtected
            }
            return nil
        case .legacy, .unavailable:
            return nil
        }
    }
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

enum AutomaticWindowProtectionFailurePresentation: Equatable {
    case waitingForStability
    case unavailable
}

struct AutomaticWindowProtectionFailurePresentationState: Equatable {
    let consecutiveFailureCount: Int
    let presentation: AutomaticWindowProtectionFailurePresentation
}

enum AutomaticWindowProtectionFailurePresentationPolicy {
    private static let failureCountBeforeWarning = 2

    static func recordFailure(
        previousConsecutiveFailureCount: Int
    ) -> AutomaticWindowProtectionFailurePresentationState {
        let consecutiveFailureCount = min(
            max(previousConsecutiveFailureCount, 0) + 1,
            failureCountBeforeWarning
        )
        return AutomaticWindowProtectionFailurePresentationState(
            consecutiveFailureCount: consecutiveFailureCount,
            presentation: consecutiveFailureCount >= failureCountBeforeWarning
                ? .unavailable
                : .waitingForStability
        )
    }
}

struct AutomaticWindowProtectionFailurePresentationTracker {
    private(set) var consecutiveFailureCount = 0
    private(set) var lastObservationID: UUID?

    mutating func recordFailure(
        observationID: UUID
    ) -> AutomaticWindowProtectionFailurePresentation {
        if lastObservationID != observationID {
            let state = AutomaticWindowProtectionFailurePresentationPolicy
                .recordFailure(
                    previousConsecutiveFailureCount: consecutiveFailureCount
                )
            consecutiveFailureCount = state.consecutiveFailureCount
            lastObservationID = observationID
        }
        return consecutiveFailureCount < 2
            ? .waitingForStability
            : .unavailable
    }

    mutating func reset() {
        consecutiveFailureCount = 0
        lastObservationID = nil
    }
}
