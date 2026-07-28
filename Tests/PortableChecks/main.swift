import Foundation

private var failureCount = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS: \(message)")
    } else {
        failureCount += 1
        print("FAIL: \(message)")
    }
}

let pauseStart: TimeInterval = 1_000
var suspension = TimingSuspension()
suspension.suspend(for: .manualPause, at: pauseStart)
suspension.suspend(for: .systemSleep, at: pauseStart + 10)
expect(
    suspension.resume(for: .systemSleep, at: pauseStart + 100) == nil,
    "overlapping sleep keeps the manual pause active"
)
expect(
    suspension.resume(for: .manualPause, at: pauseStart + 120) == 120,
    "overlapping suspension shifts timers exactly once"
)

let inactiveBeforeSleep: TimeInterval = 900
var sleepSuspension = TimingSuspension()
sleepSuspension.suspend(for: .systemSleep, at: 1_000)
expect(
    sleepSuspension.effectiveNow(at: 4_600) - inactiveBeforeSleep == 100,
    "sleep does not advance effective automation time"
)
let sleptDuration = sleepSuspension.resume(for: .systemSleep, at: 4_600) ?? 0
expect(
    4_600 - (inactiveBeforeSleep + sleptDuration) == 100,
    "resuming shifts an idle timestamp by the captured sleep interval"
)

var retroactiveSuspension = TimingSuspension()
retroactiveSuspension.suspend(for: .systemSleep, at: 1_010)
retroactiveSuspension.suspend(
    for: .automaticWindowProtectionUnavailable,
    at: 1_000
)
expect(
    retroactiveSuspension.effectiveNow(at: 1_020) == 1_000,
    "a late failure report preserves its earlier read start"
)

var retry = ActionRetryState()
retry.recordFailure(at: pauseStart, delay: 30)
expect(!retry.canAttempt(at: pauseStart + 29), "retry observes cooldown")
expect(retry.canAttempt(at: pauseStart + 30), "retry resumes after cooldown")
retry.recordFailure(at: pauseStart + 30, delay: 30)
retry.recordFailure(at: pauseStart + 60, delay: 30)
expect(!retry.canAttempt(at: pauseStart + 1_000), "retry stops after three failures")

let fallbackGenerationA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let fallbackGenerationB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let firstProcessIdentity = RuntimeApplicationIdentity.identifier(
    bundleIdentifier: "com.example.app",
    processIdentifier: 42,
    launchDate: Date(timeIntervalSince1970: 1_000),
    fallbackGeneration: fallbackGenerationA
)
let replacementProcessIdentity = RuntimeApplicationIdentity.identifier(
    bundleIdentifier: "com.example.app",
    processIdentifier: 42,
    launchDate: Date(timeIntervalSince1970: 2_000),
    fallbackGeneration: fallbackGenerationA
)
expect(
    firstProcessIdentity != replacementProcessIdentity,
    "a reused PID with a different launch date is a different process"
)
expect(
    RuntimeApplicationIdentity.identifier(
        bundleIdentifier: "com.example.app",
        processIdentifier: 42,
        launchDate: nil,
        fallbackGeneration: fallbackGenerationA
    ) != RuntimeApplicationIdentity.identifier(
        bundleIdentifier: "com.example.app",
        processIdentifier: 42,
        launchDate: nil,
        fallbackGeneration: fallbackGenerationB
    ),
    "fallback generations separate apps without a launch date"
)
expect(
    ApplicationUnhidePolicy.shouldRestartTimer(
        actionIsAutomated: true,
        applicationIsActive: false
    ),
    "unhiding an inactive automated app starts a new timer"
)
expect(
    !ApplicationUnhidePolicy.shouldRestartTimer(
        actionIsAutomated: true,
        applicationIsActive: true
    ) && !ApplicationUnhidePolicy.shouldRestartTimer(
        actionIsAutomated: false,
        applicationIsActive: false
    ),
    "active or unconfigured apps do not start an unhide timer"
)

expect(
    HideActionPresentationPolicy.presentation(
        isHidden: false,
        hasConfirmedCompletion: false,
        hasOperationInFlight: true
    ) == .inProgress &&
        HideActionPresentationPolicy.presentation(
            isHidden: false,
            hasConfirmedCompletion: false,
            hasOperationInFlight: false
        ) == .none,
    "only a real hide operation is presented as in progress"
)
expect(
    HideActionPresentationPolicy.presentation(
        isHidden: false,
        hasConfirmedCompletion: true,
        hasOperationInFlight: false
    ) == .completed &&
        HideActionPresentationPolicy.presentation(
            isHidden: true,
            hasConfirmedCompletion: false,
            hasOperationInFlight: true
        ) == .completed,
    "confirmed or observed hiding is presented as completed"
)
expect(
    HideCompletionLifecyclePolicy.shouldPreserveOnDeactivate(
        hasOperationToken: true,
        hasRowHideOwnership: false,
        hasConfirmedCompletion: false,
        isAlreadyHandled: false
    ) &&
        HideCompletionLifecyclePolicy.shouldPreserveOnDeactivate(
            hasOperationToken: false,
            hasRowHideOwnership: true,
            hasConfirmedCompletion: true,
            isAlreadyHandled: false
        ) &&
        HideCompletionLifecyclePolicy.shouldPreserveOnDeactivate(
            hasOperationToken: false,
            hasRowHideOwnership: false,
            hasConfirmedCompletion: true,
            isAlreadyHandled: true
        ) &&
        !HideCompletionLifecyclePolicy.shouldPreserveOnDeactivate(
            hasOperationToken: false,
            hasRowHideOwnership: false,
            hasConfirmedCompletion: true,
            isAlreadyHandled: false
        ),
    "hide-driven deactivation preserves only an owned hide lifecycle"
)
expect(
    !AutomaticHideAttemptPolicy.shouldAttempt(
        hasConfirmedCompletion: true,
        isAlreadyHandled: false,
        canRetry: true,
        elapsed: 600,
        actionDelay: 300
    ) &&
        AutomaticHideAttemptPolicy.shouldAttempt(
            hasConfirmedCompletion: false,
            isAlreadyHandled: false,
            canRetry: true,
            elapsed: 300,
            actionDelay: 300
        ),
    "a confirmed hide completion blocks a repeated automatic hide"
)
var hideCompletionDrift = HideCompletionRuntimeState()
expect(
    hideCompletionDrift.observe(
        isHidden: false,
        hasVisibleTransitionEvidence: true,
        at: 100,
        confirmationDelay: 5
    ) == .retainCompletion &&
        hideCompletionDrift.observe(
            isHidden: false,
            hasVisibleTransitionEvidence: true,
            at: 104.999,
            confirmationDelay: 5
        ) == .retainCompletion &&
        hideCompletionDrift.observe(
            isHidden: false,
            hasVisibleTransitionEvidence: true,
            at: 105,
            confirmationDelay: 5
        ) == .clearAsUnhidden,
    "a sustained non-hidden state clears a stale hide completion"
)
var resetHideCompletionDrift = HideCompletionRuntimeState()
_ = resetHideCompletionDrift.observe(
    isHidden: false,
    hasVisibleTransitionEvidence: true,
    at: 100,
    confirmationDelay: 5
)
_ = resetHideCompletionDrift.observe(
    isHidden: true,
    hasVisibleTransitionEvidence: false,
    at: 104,
    confirmationDelay: 5
)
expect(
    resetHideCompletionDrift.firstObservedNotHiddenAt == nil &&
        resetHideCompletionDrift.observe(
            isHidden: false,
            hasVisibleTransitionEvidence: true,
            at: 200,
            confirmationDelay: 5
        ) == .retainCompletion &&
        resetHideCompletionDrift.observe(
            isHidden: false,
            hasVisibleTransitionEvidence: true,
            at: 205,
            confirmationDelay: 5
        ) == .clearAsUnhidden,
    "a hidden observation resets stale-state confirmation"
)
var invisibleHideCompletionDrift = HideCompletionRuntimeState()
expect(
    invisibleHideCompletionDrift.observe(
        isHidden: false,
        hasVisibleTransitionEvidence: false,
        at: 100,
        confirmationDelay: 5
    ) == .retainCompletion &&
        invisibleHideCompletionDrift.observe(
            isHidden: false,
            hasVisibleTransitionEvidence: false,
            at: 1_000,
            confirmationDelay: 5
        ) == .retainCompletion &&
        invisibleHideCompletionDrift.firstObservedNotHiddenAt == nil,
    "a drifting hidden flag without visibility evidence stays completed"
)

expect(
    !AutomationDefaults.unconfiguredHideEnabled &&
        !AutomationDefaults.preQuitHideEnabled &&
        !AutomationDefaults.stageManagerGroupProtectionEnabled &&
        !AutomationDefaults.screenVisibilityProtectionEnabled,
    "all additional rules are disabled for a new user"
)
expect(
    AutomaticWindowProtectionModePolicy.mode(
        stageManagerGroupProtectionEnabled: true,
        screenVisibilityProtectionEnabled: true,
        stageManagerSystemState: .enabled
    ) == .stageManager,
    "Stage Manager on routes exclusively to group protection"
)
let transientWindowFailure =
    AutomaticWindowProtectionFailurePresentationPolicy.recordFailure(
        previousConsecutiveFailureCount: 0
    )
let repeatedWindowFailure =
    AutomaticWindowProtectionFailurePresentationPolicy.recordFailure(
        previousConsecutiveFailureCount:
            transientWindowFailure.consecutiveFailureCount
    )
expect(
    transientWindowFailure.presentation == .waitingForStability &&
        repeatedWindowFailure.presentation == .unavailable,
    "window protection warns only after consecutive read failures"
)
expect(
    AutomaticWindowProtectionFailurePresentationPolicy.recordFailure(
        previousConsecutiveFailureCount:
            repeatedWindowFailure.consecutiveFailureCount
    ) == repeatedWindowFailure,
    "window protection warning count saturates"
)
var windowFailureTracker =
    AutomaticWindowProtectionFailurePresentationTracker()
let repeatedObservationID = UUID()
expect(
    windowFailureTracker.recordFailure(
        observationID: repeatedObservationID
    ) == .waitingForStability &&
        windowFailureTracker.recordFailure(
            observationID: repeatedObservationID
        ) == .waitingForStability &&
        windowFailureTracker.consecutiveFailureCount == 1,
    "duplicate window observations do not escalate the warning"
)
expect(
    AutomaticWindowProtectionModePolicy.mode(
        stageManagerGroupProtectionEnabled: true,
        screenVisibilityProtectionEnabled: true,
        stageManagerSystemState: .disabled
    ) == .screenVisibility,
    "Stage Manager off routes to screen visibility protection"
)
expect(
    AutomaticWindowProtectionModePolicy.mode(
        stageManagerGroupProtectionEnabled: false,
        screenVisibilityProtectionEnabled: true,
        stageManagerSystemState: .unavailable
    ) == .unavailable,
    "an uncertain Stage Manager mode fails closed"
)

let stageIgnoreBundle = "com.example.ignore"
let stageHideBundle = "com.example.hide"
let stageQuitBundle = "com.example.quit"
let sidebarIgnoreSnapshot = StageManagerGroupingSnapshot(groups: [
    StageManagerAppGroup(
        displayID: 1,
        placement: .sidebar,
        bundleIdentifiers: [stageIgnoreBundle, stageHideBundle]
    )
])
let sidebarIgnoreEvaluation = StageManagerGroupProtectionPolicy.evaluate(
    featureEnabled: true,
    groupingState: .available(sidebarIgnoreSnapshot),
    explicitActions: [
        stageIgnoreBundle: .ignore,
        stageHideBundle: .hide
    ]
)
expect(
    sidebarIgnoreEvaluation.protectedBundleIdentifiers == [
        stageIgnoreBundle,
        stageHideBundle
    ],
    "an explicit Ignore app protects its sidebar group"
)
expect(
    StageManagerGroupProtectionPolicy.evaluate(
        featureEnabled: true,
        groupingState: .available(StageManagerGroupingSnapshot(groups: [
            StageManagerAppGroup(
                displayID: 1,
                placement: .sidebar,
                bundleIdentifiers: [stageHideBundle, stageQuitBundle]
            )
        ])),
        explicitActions: [
            stageHideBundle: .hide,
            stageQuitBundle: .quit
        ]
    ) == .evaluated([:]),
    "an all-automatic sidebar group keeps separate automation"
)
expect(
    StageManagerGroupProtectionPolicy.evaluate(
        featureEnabled: true,
        groupingState: .available(StageManagerGroupingSnapshot(groups: [
            StageManagerAppGroup(
                displayID: 1,
                placement: .foreground,
                bundleIdentifiers: [stageHideBundle, stageQuitBundle]
            )
        ])),
        explicitActions: [
            stageHideBundle: .hide,
            stageQuitBundle: .quit
        ]
    ).protectedBundleIdentifiers == [stageHideBundle, stageQuitBundle],
    "an all-automatic foreground group is held"
)
expect(
    StageManagerGroupProtectionPolicy.evaluate(
        featureEnabled: true,
        groupingState: .disabled,
        explicitActions: [stageIgnoreBundle: .ignore]
    ) == .legacy,
    "Stage Manager being off always preserves legacy behavior"
)
expect(
    StageManagerGroupProtectionPolicy.evaluate(
        featureEnabled: true,
        groupingState: .permissionRequired,
        explicitActions: [:]
    ) == .unavailable(.permissionRequired),
    "missing Accessibility permission fails closed"
)
let firstReleaseObservation = StageManagerProtectionTransitionPolicy.transition(
    current: [stageHideBundle],
    pendingReleaseCandidate: nil,
    proposed: [],
    requireStableRelease: true
)
let secondReleaseObservation = StageManagerProtectionTransitionPolicy.transition(
    current: firstReleaseObservation.protectedBundleIdentifiers,
    pendingReleaseCandidate: firstReleaseObservation.pendingReleaseCandidate,
    proposed: [],
    requireStableRelease: true
)
expect(
    firstReleaseObservation.protectedBundleIdentifiers == [stageHideBundle] &&
        secondReleaseObservation.protectedBundleIdentifiers.isEmpty,
    "protection is released only after two matching snapshots"
)
expect(
    StageManagerAutomaticActionPolicy.shouldAllow(
        isAutomaticAction: false,
        bundleIsProtected: true,
        groupingIsUnavailable: true
    ) && !StageManagerAutomaticActionPolicy.shouldAllow(
        isAutomaticAction: true,
        bundleIsProtected: true,
        groupingIsUnavailable: false
    ),
    "manual actions bypass protection while automatic actions are held"
)

expect(
    QuitAutomationTiming.decision(
        enabled: false,
        elapsed: 5,
        hideDelay: 5,
        quitDelay: 20,
        isHidden: false,
        hideStage: .pending,
        canAttemptHide: true
    ) == .wait,
    "disabled pre-quit hiding leaves the original quit schedule unchanged"
)
expect(
    QuitAutomationTiming.decision(
        enabled: true,
        elapsed: 5,
        hideDelay: 5,
        quitDelay: 20,
        isHidden: false,
        hideStage: .pending,
        canAttemptHide: true
    ) == .preHide,
    "a shorter pre-hide delay adds a hide stage"
)
expect(
    QuitAutomationTiming.decision(
        enabled: true,
        elapsed: 20,
        hideDelay: 5,
        quitDelay: 20,
        isHidden: false,
        hideStage: .inFlight,
        canAttemptHide: false
    ) == .quit,
    "the original quit deadline wins over an unfinished pre-hide"
)
expect(
    QuitAutomationTiming.decision(
        enabled: true,
        elapsed: 5,
        hideDelay: 5,
        quitDelay: 5,
        isHidden: false,
        hideStage: .pending,
        canAttemptHide: true
    ) == .quit,
    "equal hide and quit delays skip the pre-hide stage"
)
expect(
    QuitAutomationTiming.decision(
        enabled: true,
        elapsed: 5,
        hideDelay: 5,
        quitDelay: 20,
        isHidden: true,
        hideStage: .pending,
        canAttemptHide: true
    ) == .wait,
    "an already hidden app waits for its original quit deadline"
)
expect(
    QuitAutomationTiming.shouldAttemptQuit(
        isFirstDeadlineAttempt: true,
        isAlreadyHandled: true,
        hasActionFailure: true,
        canRetry: false
    ),
    "failed manual quits cannot consume the first rule deadline attempt"
)
expect(
    !QuitAutomationTiming.shouldAttemptQuit(
        isFirstDeadlineAttempt: true,
        isAlreadyHandled: true,
        hasActionFailure: false,
        canRetry: true
    ),
    "an accepted manual quit is not duplicated at the rule deadline"
)
expect(
    !QuitAutomationTiming.shouldAttemptQuit(
        isFirstDeadlineAttempt: false,
        isAlreadyHandled: false,
        hasActionFailure: true,
        canRetry: false
    ),
    "post-deadline retries still respect their cooldown"
)

expect(
    MenuHeightPolicy.windowHeight(
        runningAppCount: 0,
        runningSectionCount: 0
    ) == 380,
    "a short running list keeps a usable minimum menu height"
)
expect(
    MenuHeightPolicy.windowHeight(
        runningAppCount: 4,
        runningSectionCount: 1
    ) == 403,
    "four running apps use the compact menu height"
)
expect(
    MenuHeightPolicy.windowHeight(
        runningAppCount: 6,
        runningSectionCount: 2
    ) == 512,
    "running rows and groups determine the dynamic menu height"
)
expect(
    MenuHeightPolicy.windowHeight(
        runningAppCount: 9,
        runningSectionCount: 2
    ) == 620,
    "a long running list stops at the scrolling height"
)

expect(
    AutomationPolicy.effectiveAction(explicitAction: .unset, defaultHideEnabled: true) == .hide,
    "an app without a rule inherits default hide"
)
expect(
    AutoAction.rulePickerOrder == [.ignore, .unset, .hide, .quit],
    "the rule picker follows the visible section order"
)
expect(
    AutomationPolicy.effectiveAction(explicitAction: .unset, defaultHideEnabled: false) == .unset,
    "disabling default hide preserves the old unset behavior"
)
expect(
    AutomationPolicy.effectiveAction(explicitAction: .ignore, defaultHideEnabled: true) == .ignore,
    "an explicit keep rule overrides default hide"
)
expect(
    AutomationPolicy.effectiveAction(explicitAction: .quit, defaultHideEnabled: true) == .quit,
    "an explicit quit rule overrides default hide"
)
expect(
    AutomationPolicy.idleMinutes(
        explicitAction: .unset,
        explicitMinutes: 20,
        defaultHideMinutes: 5
    ) == 5,
    "an inherited default ignores stale per-app timing"
)
expect(
    AutomationPolicy.idleMinutes(
        explicitAction: .hide,
        explicitMinutes: 20,
        defaultHideMinutes: 5
    ) == 20,
    "an explicit rule keeps its per-app timing"
)

let migratedRules = AppRuleRegistry.migrateLegacyRules(
    policies: [
        "com.example.keep": "never",
        "com.example.hide": "hide",
        "com.example.quit": "quit",
        "com.example.unset": "unset"
    ],
    policyIdleMinutes: ["com.example.hide": 7],
    legacyDefaultIdleMinutes: 20
)
expect(migratedRules.rules["com.example.keep"]?.action == .ignore, "legacy ignore migrates to the explicit ignore rule")
expect(migratedRules.rules["com.example.hide"]?.idleMinutes == 7, "legacy hide timing is preserved")
expect(migratedRules.rules["com.example.quit"]?.idleMinutes == 20, "missing legacy timing uses the fallback")
expect(migratedRules.rules["com.example.unset"] == nil, "unset does not become an offline rule")
expect(
    AppRuleRegistry.visibleBundleIdentifiers(
        runningBundleIdentifiers: ["com.example.running"],
        registry: migratedRules
    ).contains("com.example.keep"),
    "explicit rules stay visible while offline"
)
expect(
    RuleDisplaySection.allCases == [.pin, .unconfigured, .autoHide, .autoQuit],
    "rule sections keep the agreed main-menu order"
)
let mixedNames = [
    (name: "微信 2", bundleIdentifier: "com.example.wechat"),
    (name: "Arc", bundleIdentifier: "com.example.arc"),
    (name: "访达", bundleIdentifier: "com.example.finder"),
    (name: "ChatGPT", bundleIdentifier: "com.example.chatgpt"),
    (name: "App 10", bundleIdentifier: "com.example.app10"),
    (name: "App 2", bundleIdentifier: "com.example.app2")
]
let naturallySortedNames = mixedNames.sorted { lhs, rhs in
    AppRuleRegistry.isNameOrderedBefore(
        lhsDisplayName: lhs.name,
        lhsBundleIdentifier: lhs.bundleIdentifier,
        rhsDisplayName: rhs.name,
        rhsBundleIdentifier: rhs.bundleIdentifier
    )
}
expect(
    naturallySortedNames.map { $0.name } == ["App 2", "App 10", "Arc", "ChatGPT", "访达", "微信 2"],
    "English and Chinese names share one natural Latin and Pinyin order"
)
expect(AppRuleRegistry.nameSortKey(for: "访达") == "fang da", "Chinese names have stable Pinyin keys")
expect(
    AppRuleRegistry.isNameOrderedBefore(
        lhsDisplayName: "Example",
        lhsBundleIdentifier: "com.example.a",
        rhsDisplayName: "Example",
        rhsBundleIdentifier: "com.example.b"
    ),
    "equal names use the bundle identifier as a stable tie breaker"
)
expect(
    AppRuleRegistry.isAppOrderedBefore(
        lhsDisplayName: "微信",
        lhsBundleIdentifier: "com.example.wechat",
        lhsIsRunning: true,
        rhsDisplayName: "Arc",
        rhsBundleIdentifier: "com.example.arc",
        rhsIsRunning: false
    ),
    "running apps sort before offline apps within the same rule group"
)
expect(
    AppRuleRegistry.isAppOrderedBefore(
        lhsDisplayName: "Arc",
        lhsBundleIdentifier: "com.example.arc",
        lhsIsRunning: true,
        rhsDisplayName: "微信",
        rhsBundleIdentifier: "com.example.wechat",
        rhsIsRunning: true
    ),
    "apps with the same running state keep the natural name order"
)
expect(
    AutoAction.allCases.allSatisfy {
        AppRuleRegistry.isVisible(explicitAction: $0, isRunning: true, in: .running)
    },
    "running scope includes every currently running app"
)
expect(
    !AppRuleRegistry.isVisible(explicitAction: .hide, isRunning: false, in: .running),
    "running scope excludes offline rules"
)
expect(
    !AppRuleRegistry.isVisible(explicitAction: .unset, isRunning: true, in: .allRules),
    "all-rules scope excludes apps without an explicit rule"
)
expect(
    [AutoAction.ignore, .hide, .quit].allSatisfy {
        AppRuleRegistry.isVisible(explicitAction: $0, isRunning: false, in: .allRules)
    },
    "all-rules scope includes offline explicit rules"
)
let originalTimedRule = StoredAppRule(
    action: .hide,
    idleMinutes: 120,
    displayName: "Example",
    lastKnownAppPath: nil
)
let pinnedTimedRule = AppRuleRegistry.updatedRule(
    existingRule: originalTimedRule,
    action: .ignore,
    defaultIdleMinutes: 5,
    displayName: "Example",
    lastKnownAppPath: nil
)
let restoredTimedRule = AppRuleRegistry.updatedRule(
    existingRule: pinnedTimedRule,
    action: .hide,
    defaultIdleMinutes: 5,
    displayName: "Example",
    lastKnownAppPath: nil
)
expect(restoredTimedRule?.idleMinutes == 120, "Ignore preserves the previous automated delay")

let immediateRegistry = StoredRuleRegistry(rules: [
    "com.example.hide": StoredAppRule(action: .hide, idleMinutes: 5, displayName: "Hide", lastKnownAppPath: nil)
])
expect(
    AppRuleRegistry.immediateTargetRuntimeIdentifiers(
        action: .hide,
        candidates: [
            ImmediateActionSnapshot(runtimeIdentifier: "hide#1", bundleIdentifier: "com.example.hide", isHidden: false, isAlreadyHandled: false),
            ImmediateActionSnapshot(runtimeIdentifier: "hide#2", bundleIdentifier: "com.example.hide", isHidden: true, isAlreadyHandled: false),
            ImmediateActionSnapshot(runtimeIdentifier: "default#1", bundleIdentifier: "com.example.default", isHidden: false, isAlreadyHandled: false)
        ],
        registry: immediateRegistry,
        defaultHideEnabled: true
    ) == Set(["hide#1", "default#1"]),
    "immediate hide selects only eligible running instances"
)

let rowActionCandidates = [
    ImmediateActionSnapshot(runtimeIdentifier: "target#1", bundleIdentifier: "com.example.target", isHidden: false, isAlreadyHandled: true),
    ImmediateActionSnapshot(runtimeIdentifier: "target#2", bundleIdentifier: "com.example.target", isHidden: true, isAlreadyHandled: false),
    ImmediateActionSnapshot(runtimeIdentifier: "target#3", bundleIdentifier: "com.example.target", isHidden: false, isAlreadyHandled: false),
    ImmediateActionSnapshot(runtimeIdentifier: "other#1", bundleIdentifier: "com.example.other", isHidden: false, isAlreadyHandled: false)
]
let rowActionSnapshot: Set<String> = ["target#1", "target#2"]
expect(
    AppRuleRegistry.rowImmediateTargetRuntimeIdentifiers(
        action: .hide,
        bundleIdentifier: "com.example.target",
        snapshotRuntimeIdentifiers: rowActionSnapshot,
        candidates: rowActionCandidates
    ) == Set(["target#1"]),
    "row hide bypasses rule state and selects only visible snapshot instances"
)
expect(
    AppRuleRegistry.rowImmediateTargetRuntimeIdentifiers(
        action: .quit,
        bundleIdentifier: "com.example.target",
        snapshotRuntimeIdentifiers: rowActionSnapshot,
        candidates: rowActionCandidates
    ) == Set(["target#1", "target#2"]),
    "row quit includes hidden snapshot instances and excludes newer processes"
)

let normalQuitRequestedAt = Date(timeIntervalSince1970: 3_000_000)
expect(
    QuitRequestPolicy.status(
        requestedAt: normalQuitRequestedAt,
        now: normalQuitRequestedAt.addingTimeInterval(29.999)
    ) == .waiting,
    "a normal quit request waits for 30 seconds"
)
expect(
    QuitRequestPolicy.status(
        requestedAt: normalQuitRequestedAt,
        now: normalQuitRequestedAt.addingTimeInterval(30)
    ) == .timedOut,
    "a normal quit request times out at 30 seconds"
)

if failureCount > 0 {
    print("\(failureCount) regression check(s) failed.")
    exit(1)
}

print("All portable regression checks passed.")
