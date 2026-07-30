import Foundation

enum StageManagerGroupPlacement: Sendable, Equatable {
    case foreground
    case sidebar
}

struct StageManagerAppGroup: Sendable, Equatable {
    let displayID: UInt32
    let placement: StageManagerGroupPlacement
    let bundleIdentifiers: Set<String>
}

struct StageManagerGroupingSnapshot: Sendable, Equatable {
    let groups: [StageManagerAppGroup]
}

struct StageManagerFullscreenContext: Sendable, Equatable {
    let bundleIdentifier: String
    let displayID: UInt32
}

enum StageManagerFullscreenDetectionPolicy {
    static func matchesDisplayBounds(
        windowFrame: CGRect,
        displayFrame: CGRect
    ) -> Bool {
        let tolerance: CGFloat = 2
        let windowFrame = windowFrame.standardized
        let displayFrame = displayFrame.standardized
        return abs(windowFrame.minX - displayFrame.minX) <= tolerance &&
            abs(windowFrame.minY - displayFrame.minY) <= tolerance &&
            abs(windowFrame.width - displayFrame.width) <= tolerance &&
            abs(windowFrame.height - displayFrame.height) <= tolerance
    }
}

enum StageManagerFullscreenFallbackPolicy {
    static let maximumInitialCacheAge: TimeInterval = 15

    static func snapshot(
        cachedSidebarGroups: [StageManagerAppGroup]?,
        cacheAge: TimeInterval,
        fullscreenContext: StageManagerFullscreenContext
    ) -> StageManagerGroupingSnapshot? {
        guard let cachedSidebarGroups,
              cacheAge.isFinite,
              cacheAge >= 0,
              cacheAge <= maximumInitialCacheAge,
              !fullscreenContext.bundleIdentifier.isEmpty else {
            return nil
        }

        var groups = cachedSidebarGroups.filter {
            $0.placement == .sidebar
        }
        groups.append(StageManagerAppGroup(
            displayID: fullscreenContext.displayID,
            placement: .foreground,
            bundleIdentifiers: [fullscreenContext.bundleIdentifier]
        ))
        groups.sort {
            if $0.displayID != $1.displayID { return $0.displayID < $1.displayID }
            if $0.placement != $1.placement {
                return $0.placement == .foreground
            }
            return $0.bundleIdentifiers.sorted().lexicographicallyPrecedes(
                $1.bundleIdentifiers.sorted()
            )
        }
        return StageManagerGroupingSnapshot(groups: groups)
    }
}

struct StageManagerShowDesktopObservation: Sendable, Equatable {
    let frontmostProcessIdentifier: Int32?
    let frontmostBundleIdentifier: String?
    let hasOrdinaryOnscreenApplicationWindow: Bool
}

enum StageManagerShowDesktopWindowPolicy {
    static func isOrdinaryWorkspaceWindow(
        windowFrame: CGRect,
        displayFrames: [CGRect]
    ) -> Bool {
        let windowFrame = windowFrame.standardized
        let intersectsActiveDisplay = displayFrames.contains {
            displayFrame in
            let visibleFrame = windowFrame.intersection(
                displayFrame.standardized
            )
            return !visibleFrame.isNull && !visibleFrame.isEmpty
        }
        guard intersectsActiveDisplay else { return false }
        return !isSidebarThumbnail(
            windowFrame: windowFrame,
            displayFrames: displayFrames
        )
    }

    static func isSidebarThumbnail(
        windowFrame: CGRect,
        displayFrames: [CGRect]
    ) -> Bool {
        let windowFrame = windowFrame.standardized
        return displayFrames.contains { displayFrame in
            let displayFrame = displayFrame.standardized
            let visibleFrame = windowFrame.intersection(displayFrame)
            guard !visibleFrame.isNull,
                  !visibleFrame.isEmpty else {
                return false
            }
            let sidebarWidth = min(
                max(displayFrame.width * 0.15, 180),
                240
            )
            let isAtHorizontalEdge =
                visibleFrame.maxX <= displayFrame.minX + sidebarWidth ||
                visibleFrame.minX >= displayFrame.maxX - sidebarWidth
            return isAtHorizontalEdge &&
                windowFrame.width <= sidebarWidth &&
                windowFrame.height <= 260
        }
    }
}

enum StageManagerShowDesktopDetectionPolicy {
    static func isShowingDesktop(
        normalReadFailedWithCompatibleStructureError: Bool,
        stageManagerIsEnabled: Bool,
        isPointerInteractionInProgress: Bool,
        firstObservation: StageManagerShowDesktopObservation,
        secondObservation: StageManagerShowDesktopObservation
    ) -> Bool {
        guard normalReadFailedWithCompatibleStructureError,
              stageManagerIsEnabled,
              !isPointerInteractionInProgress,
              firstObservation == secondObservation,
              firstObservation.frontmostProcessIdentifier != nil,
              !firstObservation.hasOrdinaryOnscreenApplicationWindow else {
            return false
        }
        return true
    }
}

enum StageManagerGroupingState: Sendable, Equatable {
    case disabled
    case permissionRequired
    case showingDesktop
    case available(StageManagerGroupingSnapshot)
    case unavailable
}

enum StageManagerHoldReason: Sendable, Hashable {
    case foregroundGroup
    case explicitIgnoreAnchor
}

enum StageManagerProtectionUnavailableReason: Sendable, Equatable {
    case permissionRequired
    case showingDesktop
    case snapshotUnavailable
}

enum StageManagerProtectionEvaluation: Sendable, Equatable {
    case legacy
    case evaluated([String: Set<StageManagerHoldReason>])
    case unavailable(StageManagerProtectionUnavailableReason)

    var protectedBundleIdentifiers: Set<String> {
        guard case let .evaluated(reasonsByBundleIdentifier) = self else {
            return []
        }
        return Set(reasonsByBundleIdentifier.keys)
    }
}

enum StageManagerGroupProtectionPolicy {
    static func evaluate(
        featureEnabled: Bool,
        groupingState: StageManagerGroupingState,
        explicitActions: [String: AutoAction]
    ) -> StageManagerProtectionEvaluation {
        guard featureEnabled else { return .legacy }

        switch groupingState {
        case .disabled:
            return .legacy
        case .permissionRequired:
            return .unavailable(.permissionRequired)
        case .showingDesktop:
            return .unavailable(.showingDesktop)
        case .unavailable:
            return .unavailable(.snapshotUnavailable)
        case let .available(snapshot):
            var reasonsByBundleIdentifier: [String: Set<StageManagerHoldReason>] = [:]

            for group in snapshot.groups {
                let members = group.bundleIdentifiers.filter { !$0.isEmpty }
                guard !members.isEmpty else { continue }

                if group.placement == .foreground {
                    for bundleIdentifier in members {
                        reasonsByBundleIdentifier[bundleIdentifier, default: []]
                            .insert(.foregroundGroup)
                    }
                }

                let containsExplicitIgnore = members.contains {
                    explicitActions[$0] == .ignore
                }
                if containsExplicitIgnore {
                    for bundleIdentifier in members {
                        reasonsByBundleIdentifier[bundleIdentifier, default: []]
                            .insert(.explicitIgnoreAnchor)
                    }
                }
            }

            return .evaluated(reasonsByBundleIdentifier)
        }
    }
}

struct StageManagerProtectionTransition: Sendable, Equatable {
    let protectedBundleIdentifiers: Set<String>
    let pendingReleaseCandidate: Set<String>?
    let enteredProtection: Set<String>
    let leftProtection: Set<String>
}

enum StageManagerProtectionTransitionPolicy {
    static func transition(
        current: Set<String>,
        pendingReleaseCandidate: Set<String>?,
        proposed: Set<String>,
        requireStableRelease: Bool
    ) -> StageManagerProtectionTransition {
        var next = proposed
        var nextPendingReleaseCandidate: Set<String>?
        let removed = current.subtracting(proposed)

        if requireStableRelease, !removed.isEmpty {
            if pendingReleaseCandidate != proposed {
                nextPendingReleaseCandidate = proposed
                next.formUnion(current)
            }
        }

        return StageManagerProtectionTransition(
            protectedBundleIdentifiers: next,
            pendingReleaseCandidate: nextPendingReleaseCandidate,
            enteredProtection: next.subtracting(current),
            leftProtection: current.subtracting(next)
        )
    }
}

enum ApplicationIdleTimerDirective: Equatable {
    case clear
    case preserve
    case startNow
}

enum ApplicationIdleTimerPolicy {
    static func directive(
        actionIsAutomated: Bool,
        applicationIsActive: Bool,
        applicationIsHeld: Bool,
        hasTimer: Bool,
        forceRestart: Bool = false
    ) -> ApplicationIdleTimerDirective {
        guard actionIsAutomated,
              !applicationIsActive,
              !applicationIsHeld else {
            return .clear
        }
        return !hasTimer || forceRestart ? .startNow : .preserve
    }
}

enum StageManagerAutomaticActionPolicy {
    static func shouldAllow(
        isAutomaticAction: Bool,
        bundleIsProtected: Bool,
        groupingIsUnavailable: Bool
    ) -> Bool {
        !isAutomaticAction || (!bundleIsProtected && !groupingIsUnavailable)
    }
}

enum StageManagerRuntimeAvailabilityPolicy {
    static func isUnavailable(
        for evaluation: StageManagerProtectionEvaluation
    ) -> Bool {
        guard case .unavailable = evaluation else { return false }
        return true
    }
}

enum StageManagerObservationPolicy {
    static func shouldApply(
        observationID: UUID,
        lastAppliedObservationID: UUID?
    ) -> Bool {
        observationID != lastAppliedObservationID
    }
}
