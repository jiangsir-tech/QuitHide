import Foundation
import Testing
@testable import QuitHide

@Suite("Stage Manager group protection")
struct StageManagerGroupProtectionTests {
    private let ignoreBundle = "com.example.ignore"
    private let hideBundle = "com.example.hide"
    private let quitBundle = "com.example.quit"
    private let otherBundle = "com.example.other"

    @Test("The new feature is off by default")
    func defaultIsOff() {
        #expect(!AutomationDefaults.stageManagerGroupProtectionEnabled)
    }

    @Test("Feature off and Stage Manager off both preserve legacy behavior")
    func hardGatesPreserveLegacyBehavior() {
        let snapshot = groupingSnapshot([
            group(.foreground, [hideBundle, quitBundle])
        ])

        #expect(evaluate(
            featureEnabled: false,
            state: .available(snapshot)
        ) == .legacy)
        #expect(evaluate(
            featureEnabled: true,
            state: .disabled
        ) == .legacy)
        #expect(evaluate(
            featureEnabled: false,
            state: .permissionRequired
        ) == .legacy)
        #expect(evaluate(
            featureEnabled: false,
            state: .showingDesktop
        ) == .legacy)
        #expect(evaluate(
            featureEnabled: false,
            state: .unavailable
        ) == .legacy)
    }

    @Test("Missing permission or an incomplete snapshot fails closed")
    func unavailableInputsFailClosed() {
        #expect(evaluate(
            state: .permissionRequired
        ) == .unavailable(.permissionRequired))
        #expect(evaluate(
            state: .showingDesktop
        ) == .unavailable(.showingDesktop))
        #expect(evaluate(
            state: .unavailable
        ) == .unavailable(.snapshotUnavailable))
    }

    @Test("An available empty snapshot is valid and protects nothing")
    func availableEmptySnapshotIsValid() {
        #expect(evaluate(
            state: .available(groupingSnapshot([]))
        ) == .evaluated([:]))
    }

    @Test("A sidebar group with an explicit Ignore app protects every member")
    func explicitIgnoreProtectsSidebarGroup() {
        let result = evaluate(
            state: .available(groupingSnapshot([
                group(.sidebar, [ignoreBundle, hideBundle, quitBundle])
            ])),
            explicitActions: [
                ignoreBundle: .ignore,
                hideBundle: .hide,
                quitBundle: .quit
            ]
        )

        #expect(result.protectedBundleIdentifiers == [
            ignoreBundle,
            hideBundle,
            quitBundle
        ])
        #expect(reasons(for: hideBundle, in: result) == [.explicitIgnoreAnchor])
        #expect(reasons(for: quitBundle, in: result) == [.explicitIgnoreAnchor])
    }

    @Test("A sidebar group containing only automatic rules is not held")
    func allAutomaticSidebarGroupRunsSeparateRules() {
        let result = evaluate(
            state: .available(groupingSnapshot([
                group(.sidebar, [hideBundle, quitBundle])
            ])),
            explicitActions: [
                hideBundle: .hide,
                quitBundle: .quit
            ]
        )

        #expect(result == .evaluated([:]))
    }

    @Test("Every app in a foreground group is held")
    func foregroundGroupIsHeld() {
        let result = evaluate(
            state: .available(groupingSnapshot([
                group(.foreground, [hideBundle, quitBundle])
            ])),
            explicitActions: [
                hideBundle: .hide,
                quitBundle: .quit
            ]
        )

        #expect(reasons(for: hideBundle, in: result) == [.foregroundGroup])
        #expect(reasons(for: quitBundle, in: result) == [.foregroundGroup])
    }

    @Test("A foreground Ignore group records both independent hold reasons")
    func foregroundIgnoreGroupHasBothReasons() {
        let result = evaluate(
            state: .available(groupingSnapshot([
                group(.foreground, [ignoreBundle, hideBundle])
            ])),
            explicitActions: [
                ignoreBundle: .ignore,
                hideBundle: .hide
            ]
        )

        #expect(reasons(for: hideBundle, in: result) == [
            .foregroundGroup,
            .explicitIgnoreAnchor
        ])
    }

    @Test("Unset is never an Ignore anchor, even if it may inherit a default")
    func unsetIsNotAnAnchor() {
        let result = evaluate(
            state: .available(groupingSnapshot([
                group(.sidebar, [ignoreBundle, hideBundle])
            ])),
            explicitActions: [
                ignoreBundle: .unset,
                hideBundle: .hide
            ]
        )

        #expect(result == .evaluated([:]))
    }

    @Test("A missing explicit rule is not an Ignore anchor")
    func missingRuleIsNotAnAnchor() {
        let result = evaluate(
            state: .available(groupingSnapshot([
                group(.sidebar, [ignoreBundle, hideBundle])
            ])),
            explicitActions: [
                hideBundle: .hide
            ]
        )

        #expect(result == .evaluated([:]))
    }

    @Test("Protection does not spread transitively through a multi-window app")
    func protectionIsNotTransitive() {
        let result = evaluate(
            state: .available(groupingSnapshot([
                group(.sidebar, [ignoreBundle, hideBundle], displayID: 1),
                group(.sidebar, [hideBundle, otherBundle], displayID: 1)
            ])),
            explicitActions: [
                ignoreBundle: .ignore,
                hideBundle: .hide,
                otherBundle: .quit
            ]
        )

        #expect(result.protectedBundleIdentifiers.contains(hideBundle))
        #expect(!result.protectedBundleIdentifiers.contains(otherBundle))
    }

    @Test("An Ignore group on one display does not affect another display")
    func protectionDoesNotLeakAcrossDisplays() {
        let result = evaluate(
            state: .available(groupingSnapshot([
                group(.sidebar, [ignoreBundle, hideBundle], displayID: 1),
                group(.sidebar, [quitBundle, otherBundle], displayID: 2)
            ])),
            explicitActions: [
                ignoreBundle: .ignore,
                hideBundle: .hide,
                quitBundle: .quit,
                otherBundle: .hide
            ]
        )

        #expect(result.protectedBundleIdentifiers.contains(hideBundle))
        #expect(!result.protectedBundleIdentifiers.contains(quitBundle))
        #expect(!result.protectedBundleIdentifiers.contains(otherBundle))
    }

    @Test("A bundle is held globally when any one of its windows is in a held group")
    func anyHeldWindowProtectsTheBundle() {
        let result = evaluate(
            state: .available(groupingSnapshot([
                group(.sidebar, [ignoreBundle, hideBundle], displayID: 1),
                group(.sidebar, [hideBundle, otherBundle], displayID: 2)
            ])),
            explicitActions: [
                ignoreBundle: .ignore,
                hideBundle: .hide,
                otherBundle: .hide
            ]
        )

        #expect(reasons(for: hideBundle, in: result) == [.explicitIgnoreAnchor])
    }

    private func evaluate(
        featureEnabled: Bool = true,
        state: StageManagerGroupingState,
        explicitActions: [String: AutoAction] = [:]
    ) -> StageManagerProtectionEvaluation {
        StageManagerGroupProtectionPolicy.evaluate(
            featureEnabled: featureEnabled,
            groupingState: state,
            explicitActions: explicitActions
        )
    }

    private func groupingSnapshot(
        _ groups: [StageManagerAppGroup]
    ) -> StageManagerGroupingSnapshot {
        StageManagerGroupingSnapshot(groups: groups)
    }

    private func group(
        _ placement: StageManagerGroupPlacement,
        _ bundleIdentifiers: Set<String>,
        displayID: UInt32 = 1
    ) -> StageManagerAppGroup {
        StageManagerAppGroup(
            displayID: displayID,
            placement: placement,
            bundleIdentifiers: bundleIdentifiers
        )
    }

    private func reasons(
        for bundleIdentifier: String,
        in result: StageManagerProtectionEvaluation
    ) -> Set<StageManagerHoldReason> {
        guard case let .evaluated(reasonsByBundleIdentifier) = result else {
            return []
        }
        return reasonsByBundleIdentifier[bundleIdentifier] ?? []
    }
}

@Suite("Stage Manager protection runtime policies")
struct StageManagerProtectionRuntimePolicyTests {
    private let firstBundle = "com.example.first"
    private let secondBundle = "com.example.second"

    @Test("Entering protection is immediate")
    func enteringProtectionIsImmediate() {
        let transition = StageManagerProtectionTransitionPolicy.transition(
            current: [],
            pendingReleaseCandidate: nil,
            proposed: [firstBundle],
            requireStableRelease: true
        )

        #expect(transition.protectedBundleIdentifiers == [firstBundle])
        #expect(transition.enteredProtection == [firstBundle])
        #expect(transition.leftProtection.isEmpty)
        #expect(transition.pendingReleaseCandidate == nil)
    }

    @Test("Leaving protection requires two matching snapshots")
    func leavingProtectionRequiresStableSnapshot() {
        let firstObservation = StageManagerProtectionTransitionPolicy.transition(
            current: [firstBundle, secondBundle],
            pendingReleaseCandidate: nil,
            proposed: [firstBundle],
            requireStableRelease: true
        )
        #expect(firstObservation.protectedBundleIdentifiers == [
            firstBundle,
            secondBundle
        ])
        #expect(firstObservation.leftProtection.isEmpty)
        #expect(firstObservation.pendingReleaseCandidate == [firstBundle])

        let secondObservation = StageManagerProtectionTransitionPolicy.transition(
            current: firstObservation.protectedBundleIdentifiers,
            pendingReleaseCandidate: firstObservation.pendingReleaseCandidate,
            proposed: [firstBundle],
            requireStableRelease: true
        )
        #expect(secondObservation.protectedBundleIdentifiers == [firstBundle])
        #expect(secondObservation.leftProtection == [secondBundle])
        #expect(secondObservation.pendingReleaseCandidate == nil)
    }

    @Test("Idle timers clear while held and restart only after release")
    func heldAppsDoNotAccumulateIdleTime() {
        #expect(ApplicationIdleTimerPolicy.directive(
            actionIsAutomated: true,
            applicationIsActive: false,
            applicationIsHeld: true,
            hasTimer: true
        ) == .clear)
        #expect(ApplicationIdleTimerPolicy.directive(
            actionIsAutomated: true,
            applicationIsActive: false,
            applicationIsHeld: false,
            hasTimer: false
        ) == .startNow)
        #expect(ApplicationIdleTimerPolicy.directive(
            actionIsAutomated: true,
            applicationIsActive: false,
            applicationIsHeld: false,
            hasTimer: true
        ) == .preserve)
    }

    @Test("Manual actions bypass protection while automatic actions fail closed")
    func manualActionsBypassProtection() {
        #expect(StageManagerAutomaticActionPolicy.shouldAllow(
            isAutomaticAction: false,
            bundleIsProtected: true,
            groupingIsUnavailable: true
        ))
        #expect(!StageManagerAutomaticActionPolicy.shouldAllow(
            isAutomaticAction: true,
            bundleIsProtected: true,
            groupingIsUnavailable: false
        ))
        #expect(!StageManagerAutomaticActionPolicy.shouldAllow(
            isAutomaticAction: true,
            bundleIsProtected: false,
            groupingIsUnavailable: true
        ))
        #expect(StageManagerAutomaticActionPolicy.shouldAllow(
            isAutomaticAction: true,
            bundleIsProtected: false,
            groupingIsUnavailable: false
        ))
    }

    @Test("UI permission state cannot make legacy mode fail closed")
    func legacyModeRemainsAvailable() {
        #expect(!StageManagerRuntimeAvailabilityPolicy.isUnavailable(
            for: .legacy
        ))
        #expect(!StageManagerRuntimeAvailabilityPolicy.isUnavailable(
            for: .evaluated([:])
        ))
        #expect(StageManagerRuntimeAvailabilityPolicy.isUnavailable(
            for: .unavailable(.permissionRequired)
        ))
        #expect(StageManagerRuntimeAvailabilityPolicy.isUnavailable(
            for: .unavailable(.showingDesktop)
        ))
    }

    @Test("Multiple waiters cannot apply the same observation twice")
    func duplicateObservationIsIgnored() {
        let observationID = UUID()
        #expect(StageManagerObservationPolicy.shouldApply(
            observationID: observationID,
            lastAppliedObservationID: nil
        ))
        #expect(!StageManagerObservationPolicy.shouldApply(
            observationID: observationID,
            lastAppliedObservationID: observationID
        ))
        #expect(StageManagerObservationPolicy.shouldApply(
            observationID: UUID(),
            lastAppliedObservationID: observationID
        ))
    }
}
