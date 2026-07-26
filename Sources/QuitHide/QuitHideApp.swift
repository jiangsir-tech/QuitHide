import AppKit
import OSLog
import ServiceManagement
import SwiftUI

struct ActionSymbol: View {
    let action: AutoAction

    private var tint: Color {
        switch action {
        case .unset, .ignore: return .secondary
        case .hide: return .blue.opacity(0.82)
        case .quit: return .red.opacity(0.82)
        }
    }

    var body: some View {
        Image(systemName: action.symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 20, height: 16, alignment: .center)
    }
}

struct RunningAppItem: Identifiable {
    let id: String
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let name: String
    let icon: NSImage
    let isHidden: Bool
    let isActive: Bool
    let app: NSRunningApplication
}

struct CatalogAppItem: Identifiable {
    var id: String { bundleIdentifier }

    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    let explicitAction: AutoAction
    let bundleURL: URL?
    let runningInstances: [RunningAppItem]

    var isRunning: Bool { !runningInstances.isEmpty }
    var isInstalled: Bool { bundleURL != nil }
    var isActive: Bool { runningInstances.contains(where: \.isActive) }

    var primaryRunningItem: RunningAppItem? {
        runningInstances.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
            return lhs.processIdentifier < rhs.processIdentifier
        }.first
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

struct AppAutomationStatus {
    let text: String
    let isError: Bool
    let isWarning: Bool
    let helpText: String?

    init(
        text: String,
        isError: Bool = false,
        isWarning: Bool = false,
        helpText: String? = nil
    ) {
        self.text = text
        self.isError = isError
        self.isWarning = isWarning
        self.helpText = helpText
    }
}

struct SettingsWarningItem: Identifiable {
    enum ID: String {
        case unreadableRuleRegistry
        case rulePersistence
        case loginItem
    }

    let id: ID
    let message: String
    let showsLoginItemsSettingsButton: Bool
}

enum UpdateViewState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AvailableUpdate)
    case failed
}

@MainActor
final class AppModel: ObservableObject {
    private final class BatchProgress {
        var remaining: Int
        var succeeded = 0
        var failed = 0

        init(total: Int) {
            remaining = total
        }
    }

    private enum ActionSource: String {
        case automatic
        case configuredBatch
        case rowOverride

        var isAutomatic: Bool { self == .automatic }
        var isRowOverride: Bool { self == .rowOverride }
    }

    private struct OneShotActionState {
        let action: AutoAction
        let token: UUID
    }

    private struct QuitRequestRuntimeState {
        let requestedAt: Date
        let token: UUID
    }

    private struct PreQuitHideRuntimeState {
        var stage: PreQuitHideStage = .pending
        var token: UUID?
        var retryState = ActionRetryState()
    }

    private struct FallbackRuntimeGeneration {
        let application: NSRunningApplication
        let generation: UUID
    }

    private struct LoadedRuleRegistry {
        let registry: StoredRuleRegistry
        let isWritable: Bool
        let requiresAutomationPause: Bool
    }

    private static let logger = Logger(subsystem: "com.jiangsir.quithide", category: "automation")
    private static let retryDelay: TimeInterval = 30
    private static let forceQuitVerificationDelay: TimeInterval = 5
    @Published var apps: [RunningAppItem] = []
    @Published private(set) var catalogApps: [CatalogAppItem] = []
    @Published var searchText = ""
    @Published var automationEnabled: Bool {
        didSet {
            if !isRuleRegistryWritable, automationEnabled {
                automationEnabled = false
                statusMessage = "规则来自更高版本，当前版本无法解析，自动处理保持暂停"
                return
            }
            defaults.set(automationEnabled, forKey: Keys.automationEnabled)
            guard automationEnabled != oldValue else { return }

            let now = automationClock.now
            if automationEnabled {
                resumeTiming(for: .manualPause, at: now)
            } else {
                suspendTiming(for: .manualPause, at: now)
            }
        }
    }
    @Published private(set) var defaultHideEnabled: Bool
    @Published private(set) var defaultHideMinutes: Int
    @Published private(set) var preQuitHideEnabled: Bool
    @Published private(set) var preQuitHideMinutes: Int
    @Published private(set) var automaticUpdateChecksEnabled: Bool
    @Published private(set) var updateState: UpdateViewState = .idle
    @Published private(set) var pendingUpdatePrompt: AvailableUpdate?
    @Published private(set) var updateCheckInProgress = false
    @Published private(set) var languagePreference: AppLanguagePreference
    @Published private(set) var resolvedLanguage: ResolvedAppLanguage
    // Operation status is intentionally not user-facing. Keep it out of the
    // published state so frequent automation updates do not invalidate the UI.
    private var statusMessage = ""
    @Published private var rulePersistenceWarningKey: L10n.Key?
    @Published private var loginItemWarningKey: L10n.Key?
    @Published private(set) var launchAtLogin = false

    private enum Keys {
        static let policies = "policies"
        static let policyIdleMinutes = "policyIdleMinutes"
        static let automationEnabled = "automationEnabled"
        static let idleMinutes = "idleMinutes"
        static let defaultHideEnabled = "defaultHideEnabled"
        static let defaultHideMinutes = "defaultHideMinutes"
        static let preQuitHideEnabled = "preQuitHideEnabled"
        static let preQuitHideMinutes = "preQuitHideMinutes"
        static let automaticUpdateChecksEnabled = "automaticUpdateChecksEnabled"
        static let lastAutomaticUpdateCheckAt = "lastAutomaticUpdateCheckAt"
        static let skippedUpdateIdentity = "skippedUpdateIdentity"
        static let updateRemindAfter = "updateRemindAfter"
        static let cachedAvailableUpdate = "cachedAvailableUpdate"
        static let languagePreference = "languagePreference"
        static let ruleRegistry = "ruleRegistryV1"
        static let ruleRegistryBackup = "ruleRegistryV1Backup"
        static let corruptRuleRegistryBackup = "ruleRegistryV1CorruptBackup"
    }

    private let defaults = UserDefaults.standard
    private var localization: AppLocalization
    private let automationClock: any AutomationClock
    private let ruleStore: RuleRegistryFileStore
    private var ruleRegistry: StoredRuleRegistry
    private var isRuleRegistryWritable: Bool
    private var inactiveSince: [String: TimeInterval] = [:]
    private var fallbackRuntimeGenerations: [FallbackRuntimeGeneration] = []
    private var alreadyHandled: Set<String> = []
    private var actionFailures: [String: AutoAction] = [:]
    private var retryStates: [String: ActionRetryState] = [:]
    private var oneShotActionStates: [String: OneShotActionState] = [:]
    private var actionOperationTokens: [String: UUID] = [:]
    private var quitRequestStates: [String: QuitRequestRuntimeState] = [:]
    private var forceQuitOperationTokens: [String: UUID] = [:]
    private var forceQuitFailures: Set<String> = []
    private var quitDeadlineAttempted: Set<String> = []
    private var preQuitHideStates: [String: PreQuitHideRuntimeState] = [:]
    private var timingSuspension = TimingSuspension()
    private var timer: Timer?
    private var automaticUpdateTimer: Timer?
    private var latestAvailableUpdate: AvailableUpdate?
    private var updateCheckTask: Task<Void, Never>?
    private var updateCheckShouldReport = false
    private var updateCheckBeganAutomatically = false
    private var observers: [NSObjectProtocol] = []

    init(
        automationClock: any AutomationClock = SystemAutomationClock(),
        ruleStore: RuleRegistryFileStore = .live()
    ) {
        self.automationClock = automationClock
        self.ruleStore = ruleStore
        let savedLanguagePreference = UserDefaults.standard.string(
            forKey: Keys.languagePreference
        ).flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
        let initialLocalization = AppLocalization(preference: savedLanguagePreference)
        languagePreference = savedLanguagePreference
        resolvedLanguage = initialLocalization.resolvedLanguage
        localization = initialLocalization
        let savedIdleMinutes = defaults.object(forKey: Keys.idleMinutes) as? Int ?? 20
        let legacyPolicies = defaults.dictionary(forKey: Keys.policies) as? [String: String] ?? [:]
        let legacyPolicyIdleMinutes = defaults.dictionary(forKey: Keys.policyIdleMinutes) as? [String: Int] ?? [:]
        let loadedRegistry = Self.loadRuleRegistry(
            from: defaults,
            fileStore: ruleStore,
            legacyPolicies: legacyPolicies,
            legacyPolicyIdleMinutes: legacyPolicyIdleMinutes,
            legacyDefaultIdleMinutes: savedIdleMinutes
        )
        ruleRegistry = loadedRegistry.registry
        isRuleRegistryWritable = loadedRegistry.isWritable
        automationEnabled = loadedRegistry.requiresAutomationPause
            ? false
            : defaults.object(forKey: Keys.automationEnabled) as? Bool ?? true
        defaultHideEnabled = defaults.object(forKey: Keys.defaultHideEnabled) as? Bool
            ?? AutomationDefaults.unconfiguredHideEnabled
        defaultHideMinutes = max(
            defaults.object(forKey: Keys.defaultHideMinutes) as? Int ?? 5,
            1
        )
        preQuitHideEnabled = defaults.object(forKey: Keys.preQuitHideEnabled) as? Bool
            ?? AutomationDefaults.preQuitHideEnabled
        preQuitHideMinutes = max(defaults.object(forKey: Keys.preQuitHideMinutes) as? Int ?? 5, 1)
        automaticUpdateChecksEnabled = defaults.object(
            forKey: Keys.automaticUpdateChecksEnabled
        ) as? Bool ?? UpdateReminderPolicy.automaticChecksDefaultEnabled
        defaults.set(defaultHideEnabled, forKey: Keys.defaultHideEnabled)
        defaults.set(defaultHideMinutes, forKey: Keys.defaultHideMinutes)
        defaults.set(preQuitHideEnabled, forKey: Keys.preQuitHideEnabled)
        defaults.set(preQuitHideMinutes, forKey: Keys.preQuitHideMinutes)
        defaults.set(automaticUpdateChecksEnabled, forKey: Keys.automaticUpdateChecksEnabled)
        if loadedRegistry.requiresAutomationPause {
            statusMessage = "规则来自更高版本，当前版本无法解析，已暂停自动处理"
        }
        if !automationEnabled {
            timingSuspension.suspend(for: .manualPause, at: automationClock.now)
        }

        restoreCachedAvailableUpdate()

        refreshApps()
        installObservers()
        installTimer()
        scheduleAutomaticUpdateCheck()
        refreshLoginStatus()
    }

    deinit {
        timer?.invalidate()
        automaticUpdateTimer?.invalidate()
        updateCheckTask?.cancel()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var filteredCatalogApps: [CatalogAppItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalogApps }
        return catalogApps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var rulesAreEditable: Bool { isRuleRegistryWritable }

    var effectiveLocale: Locale { resolvedLanguage.locale }

    func localized(
        _ key: L10n.Key,
        replacements: [String: String] = [:]
    ) -> String {
        localization.text(key, replacements: replacements)
    }

    func localizedList(_ values: [String]) -> String {
        localization.list(values)
    }

    func setLanguagePreference(_ preference: AppLanguagePreference) {
        guard preference != languagePreference else {
            refreshSystemLanguageIfNeeded()
            return
        }
        defaults.set(preference.rawValue, forKey: Keys.languagePreference)
        languagePreference = preference
        applyLocalization(AppLocalization(preference: preference))
    }

    func refreshSystemLanguageIfNeeded() {
        guard languagePreference == .system else { return }
        let nextLocalization = AppLocalization(preference: .system)
        guard nextLocalization.resolvedLanguage != resolvedLanguage else { return }
        applyLocalization(nextLocalization)
    }

    func actionTitle(for action: AutoAction) -> String {
        switch action {
        case .unset: return localized(.actionUseDefault)
        case .hide: return localized(.actionHide)
        case .quit: return localized(.actionQuit)
        case .ignore: return localized(.actionIgnore)
        }
    }

    func rulePickerTitle(for action: AutoAction) -> String {
        switch action {
        case .ignore: return localized(.ruleIgnore)
        case .unset: return localized(.ruleUnconfigured)
        case .hide: return localized(.ruleAutomaticHide)
        case .quit: return localized(.ruleAutomaticQuit)
        }
    }

    func durationTitle(_ minutes: Int) -> String {
        if minutes < 60 {
            let key: L10n.Key = minutes == 1 ? .durationMinute : .durationMinutes
            return localized(key, replacements: ["count": String(minutes)])
        }
        if minutes.isMultiple(of: 1_440) {
            let days = minutes / 1_440
            let key: L10n.Key = days == 1 ? .durationDay : .durationDays
            return localized(key, replacements: ["count": String(days)])
        }
        if minutes.isMultiple(of: 60) {
            let hours = minutes / 60
            let key: L10n.Key = hours == 1 ? .durationHour : .durationHours
            return localized(key, replacements: ["count": String(hours)])
        }
        return localized(.durationHoursMinutes, replacements: [
            "hours": String(minutes / 60),
            "minutes": String(minutes % 60)
        ])
    }

    private func applyLocalization(_ nextLocalization: AppLocalization) {
        localization = nextLocalization
        resolvedLanguage = nextLocalization.resolvedLanguage
    }

    var settingsWarnings: [SettingsWarningItem] {
        var warnings: [SettingsWarningItem] = []
        if !isRuleRegistryWritable {
            warnings.append(SettingsWarningItem(
                id: .unreadableRuleRegistry,
                message: localized(.warningRuleRegistryNewerReadOnly),
                showsLoginItemsSettingsButton: false
            ))
        }
        if let rulePersistenceWarningKey {
            warnings.append(SettingsWarningItem(
                id: .rulePersistence,
                message: localized(rulePersistenceWarningKey),
                showsLoginItemsSettingsButton: false
            ))
        }
        if let loginItemWarningKey {
            warnings.append(SettingsWarningItem(
                id: .loginItem,
                message: localized(loginItemWarningKey),
                showsLoginItemsSettingsButton:
                    SMAppService.mainApp.status == .requiresApproval
            ))
        }
        return warnings
    }
    var runningAppCount: Int { catalogApps.filter(\.isRunning).count }
    var explicitRuleCount: Int { ruleRegistry.rules.count }

    func policy(for bundleIdentifier: String) -> AutoAction {
        ruleRegistry.rules[bundleIdentifier]?.action ?? .unset
    }

    func effectivePolicy(for bundleIdentifier: String) -> AutoAction {
        AutomationPolicy.effectiveAction(
            explicitAction: policy(for: bundleIdentifier),
            defaultHideEnabled: defaultHideEnabled
        )
    }

    func setPolicy(_ action: AutoAction, for bundleIdentifier: String) {
        guard isRuleRegistryWritable else {
            statusMessage = "规则来自更高版本，当前版本无法解析或修改"
            return
        }
        guard policy(for: bundleIdentifier) != action else { return }
        if action == .unset {
            ruleRegistry.rules.removeValue(forKey: bundleIdentifier)
        } else {
            let catalogItem = catalogApps.first { $0.bundleIdentifier == bundleIdentifier }
            let existingRule = ruleRegistry.rules[bundleIdentifier]
            ruleRegistry.rules[bundleIdentifier] = AppRuleRegistry.updatedRule(
                existingRule: existingRule,
                action: action,
                defaultIdleMinutes: defaultHideMinutes,
                displayName: catalogItem?.name
                    ?? existingRule?.displayName
                    ?? AppRuleRegistry.fallbackDisplayName(for: bundleIdentifier),
                lastKnownAppPath: catalogItem?.bundleURL?.path
            )
        }
        persistRuleRegistry()
        resetRuntimeState(
            for: bundleIdentifier,
            restartTimer: effectivePolicy(for: bundleIdentifier).isAutomated
        )
        rebuildCatalog()
    }

    func idleMinutes(for bundleIdentifier: String) -> Int {
        AutomationPolicy.idleMinutes(
            explicitAction: policy(for: bundleIdentifier),
            explicitMinutes: ruleRegistry.rules[bundleIdentifier]?.idleMinutes,
            defaultHideMinutes: defaultHideMinutes
        )
    }

    func setIdleMinutes(_ minutes: Int, for bundleIdentifier: String) {
        guard isRuleRegistryWritable else {
            statusMessage = "规则来自更高版本，当前版本无法解析或修改"
            return
        }
        guard var rule = ruleRegistry.rules[bundleIdentifier], rule.action.isAutomated else { return }
        rule.idleMinutes = max(minutes, 1)
        ruleRegistry.rules[bundleIdentifier] = rule
        persistRuleRegistry()
        clearActionState(for: bundleIdentifier)
        objectWillChange.send()
    }

    func setDefaultHideEnabled(_ enabled: Bool) {
        guard isRuleRegistryWritable else {
            statusMessage = "规则来自更高版本，当前版本无法解析或修改"
            return
        }
        guard defaultHideEnabled != enabled else { return }
        defaultHideEnabled = enabled
        defaults.set(enabled, forKey: Keys.defaultHideEnabled)
        resetDefaultPolicyRuntimeState(restartTimer: enabled)
        statusMessage = enabled
            ? "未单独设置的 App 将在离开前台后自动隐藏"
            : "未单独设置的 App 将保持原样"
    }

    func setDefaultHideMinutes(_ minutes: Int) {
        guard isRuleRegistryWritable else {
            statusMessage = "规则来自更高版本，当前版本无法解析或修改"
            return
        }
        let clampedMinutes = max(minutes, 1)
        guard defaultHideMinutes != clampedMinutes else { return }
        defaultHideMinutes = clampedMinutes
        defaults.set(clampedMinutes, forKey: Keys.defaultHideMinutes)
        resetDefaultPolicyRuntimeState(restartTimer: defaultHideEnabled)
    }

    func setPreQuitHideEnabled(_ enabled: Bool) {
        guard isRuleRegistryWritable else {
            statusMessage = "规则来自更高版本，当前版本无法解析或修改"
            return
        }
        guard preQuitHideEnabled != enabled else { return }
        preQuitHideEnabled = enabled
        defaults.set(enabled, forKey: Keys.preQuitHideEnabled)
        resetPreQuitHideRuntimeState()
        statusMessage = enabled
            ? "符合时间条件的自动退出 App 将先隐藏，仍按原时间退出"
            : "自动退出的 App 将按设定时间直接退出"
    }

    func setPreQuitHideMinutes(_ minutes: Int) {
        guard isRuleRegistryWritable else {
            statusMessage = "规则来自更高版本，当前版本无法解析或修改"
            return
        }
        let clampedMinutes = max(minutes, 1)
        guard preQuitHideMinutes != clampedMinutes else { return }
        preQuitHideMinutes = clampedMinutes
        defaults.set(clampedMinutes, forKey: Keys.preQuitHideMinutes)
        resetPreQuitHideRuntimeState()
    }

    func setAutomaticUpdateChecksEnabled(_ enabled: Bool) {
        guard automaticUpdateChecksEnabled != enabled else { return }
        automaticUpdateChecksEnabled = enabled
        defaults.set(enabled, forKey: Keys.automaticUpdateChecksEnabled)

        if enabled {
            scheduleAutomaticUpdateCheck()
        } else {
            automaticUpdateTimer?.invalidate()
            automaticUpdateTimer = nil
            pendingUpdatePrompt = nil
            if updateCheckBeganAutomatically {
                updateCheckTask?.cancel()
                finishUpdateCheck()
            }
        }
    }

    func checkForUpdatesManually() {
        startUpdateCheck(manual: true)
    }

    func prepareUpdatePromptForMenuPresentation(now: Date = Date()) {
        guard automaticUpdateChecksEnabled, let update = latestAvailableUpdate else {
            pendingUpdatePrompt = nil
            return
        }

        let shouldPresent = UpdateReminderPolicy.shouldPresent(
            available: update.reminderIdentity,
            skipped: skippedUpdateIdentity,
            remindAfter: defaults.object(forKey: Keys.updateRemindAfter) as? Date,
            now: now
        )
        pendingUpdatePrompt = shouldPresent ? update : nil
    }

    func openAvailableUpdate(_ update: AvailableUpdate) {
        guard let validatedUpdate = UpdateChecker.validatedAvailableUpdate(update),
              NSWorkspace.shared.open(validatedUpdate.downloadURL) else {
            updateState = .failed
            return
        }
        postponeUpdatePrompt(validatedUpdate, until: Date().addingTimeInterval(
            UpdateReminderPolicy.reminderInterval
        ))
    }

    func remindAboutUpdateLater(_ update: AvailableUpdate) {
        postponeUpdatePrompt(update, until: Date().addingTimeInterval(
            UpdateReminderPolicy.reminderInterval
        ))
    }

    func skipUpdateVersion(_ update: AvailableUpdate) {
        latestAvailableUpdate = update
        cacheAvailableUpdate(update)
        pendingUpdatePrompt = nil
        if let data = try? JSONEncoder().encode(update.reminderIdentity) {
            defaults.set(data, forKey: Keys.skippedUpdateIdentity)
        }
        defaults.removeObject(forKey: Keys.updateRemindAfter)
        scheduleAutomaticUpdateCheck()
    }

    func automationStatus(for item: RunningAppItem) -> AppAutomationStatus? {
        let bundleID = item.bundleIdentifier
        let runtimeID = item.id

        if forceQuitOperationTokens[runtimeID] != nil {
            return AppAutomationStatus(text: localized(.statusForceQuitInProgress))
        }
        if forceQuitFailures.contains(runtimeID) {
            return AppAutomationStatus(
                text: localized(.statusForceQuitFailed),
                isError: true,
                helpText: localized(.statusForceQuitFailedHelp)
            )
        }
        if let quitRequest = quitRequestStates[runtimeID] {
            switch QuitRequestPolicy.status(
                requestedAt: quitRequest.requestedAt,
                now: Date()
            ) {
            case .waiting:
                return AppAutomationStatus(
                    text: localized(.statusQuitInProgress),
                    helpText: localized(.statusQuitWaitingHelp)
                )
            case .timedOut:
                return AppAutomationStatus(
                    text: localized(.statusQuitNotCompleted),
                    isWarning: true,
                    helpText: localized(.statusQuitNotCompletedHelp)
                )
            }
        }

        if let oneShotAction = oneShotActionStates[runtimeID]?.action {
            switch oneShotAction {
            case .hide:
                return AppAutomationStatus(
                    text: localized(item.isHidden ? .statusHideHidden : .statusHideInProgress),
                    isError: false
                )
            case .quit:
                return AppAutomationStatus(
                    text: localized(.statusQuitRequestedWaiting),
                    isError: false
                )
            case .unset, .ignore:
                break
            }
        }

        let action = effectivePolicy(for: bundleID)
        guard action.isAutomated else { return nil }

        if let failedAction = actionFailures[runtimeID] {
            let key: L10n.Key = retryStates[runtimeID]?.hasAttemptsRemaining == true
                ? .statusActionFailedRetry
                : .statusActionFailedManual
            return AppAutomationStatus(
                text: localized(key, replacements: [
                    "action": actionTitle(for: failedAction)
                ]),
                isError: true
            )
        }
        if action == .hide, item.isHidden {
            return AppAutomationStatus(text: localized(.statusHideHidden), isError: false)
        }
        if alreadyHandled.contains(runtimeID) {
            let text = action == .quit
                ? localized(.statusQuitRequestedWaiting)
                : localized(.statusHideInProgress)
            return AppAutomationStatus(text: text, isError: false)
        }
        if item.isActive {
            return AppAutomationStatus(text: localized(.statusActive), isError: false)
        }
        guard let inactiveAt = inactiveSince[runtimeID] else {
            return AppAutomationStatus(text: localized(.statusWaitingForBackground), isError: false)
        }

        let elapsed = effectiveNow - inactiveAt
        let actionDelay = thresholdSeconds(for: bundleID)

        if action == .quit,
           preQuitHideEnabled,
           preQuitHideDelaySeconds < actionDelay {
            let quitRemaining = actionDelay - elapsed
            let preHideState = preQuitHideStates[runtimeID]

            if item.isHidden || preHideState?.stage == .completed {
                if quitRemaining <= 0 {
                    return AppAutomationStatus(
                        text: localized(.statusActionAboutToRun, replacements: [
                            "action": actionTitle(for: .quit)
                        ]),
                        isError: false
                    )
                }
                let formatted = formatRemainingTime(quitRemaining)
                return AppAutomationStatus(
                    text: localized(
                        automationEnabled
                            ? .statusHideHiddenRemaining
                            : .statusAutomationPausedRemaining,
                        replacements: ["time": formatted]
                    ),
                    isError: false
                )
            }
            if preHideState?.stage == .inFlight {
                return AppAutomationStatus(text: localized(.statusHideInProgress), isError: false)
            }
            if let preHideState, preHideState.retryState.failureCount > 0 {
                return AppAutomationStatus(
                    text: localized(.statusHideFailedWillQuit),
                    isError: true
                )
            }

            let hideRemaining = preQuitHideDelaySeconds - elapsed
            if hideRemaining > 0 {
                let formatted = formatRemainingTime(hideRemaining)
                return AppAutomationStatus(
                    text: localized(
                        automationEnabled
                            ? .statusActionRemaining
                            : .statusAutomationPausedRemaining,
                        replacements: [
                            "time": formatted,
                            "action": actionTitle(for: .hide)
                        ]
                    ),
                    isError: false
                )
            }
        }

        let remaining = actionDelay - elapsed
        if remaining <= 0 {
            return AppAutomationStatus(
                text: localized(.statusActionAboutToRun, replacements: [
                    "action": actionTitle(for: action)
                ]),
                isError: false
            )
        }

        let formatted = formatRemainingTime(remaining)
        if !automationEnabled {
            return AppAutomationStatus(
                text: localized(.statusAutomationPausedRemaining, replacements: [
                    "time": formatted
                ]),
                isError: false
            )
        }
        return AppAutomationStatus(
            text: localized(.statusActionRemaining, replacements: [
                "time": formatted,
                "action": actionTitle(for: action)
            ]),
            isError: false
        )
    }

    func immediateTargetCount(for action: AutoAction) -> Int {
        guard isRuleRegistryWritable else { return 0 }
        return immediateTargets(for: action).count
    }

    func immediateTargetHelp(for action: AutoAction) -> String {
        guard isRuleRegistryWritable else {
            return localized(.helpRuleRegistryBatchUnavailable)
        }
        let names = immediateTargets(for: action).map(\.name)
        let actionName = actionTitle(for: action)
        guard !names.isEmpty else {
            return localized(.helpImmediateNoTargets, replacements: ["action": actionName])
        }
        return localized(.helpImmediateTargets, replacements: [
            "action": actionName,
            "names": localizedList(names)
        ])
    }

    func performConfiguredApps(_ action: AutoAction) {
        guard isRuleRegistryWritable else {
            statusMessage = "规则来自更高版本，不能执行依赖规则的批量操作"
            return
        }
        let targets = immediateTargets(for: action)
        guard !targets.isEmpty else {
            statusMessage = "没有可立即\(action.title)的 App"
            return
        }

        let progress = BatchProgress(total: targets.count)
        statusMessage = "正在\(action.title) \(targets.count) 个 App…"

        for item in targets {
            perform(
                action,
                on: item.app,
                named: item.name,
                bundleIdentifier: item.bundleIdentifier,
                runtimeIdentifier: item.id,
                source: .configuredBatch
            ) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    progress.succeeded += 1
                } else {
                    progress.failed += 1
                }
                progress.remaining -= 1

                if progress.remaining == 0 {
                    let successText = action == .quit ? "已请求退出" : "已\(action.title)"
                    if progress.failed == 0 {
                        self.statusMessage = "\(successText) \(progress.succeeded) 个 App"
                    } else {
                        self.statusMessage = "\(successText) \(progress.succeeded) 个，\(progress.failed) 个失败"
                    }
                }
            }
        }
    }

    func immediateTargetCount(for action: AutoAction, in item: CatalogAppItem) -> Int {
        rowImmediateTargets(
            for: action,
            bundleIdentifier: item.bundleIdentifier,
            snapshotRuntimeIdentifiers: Set(item.runningInstances.map(\.id))
        ).count
    }

    func performImmediately(_ action: AutoAction, for item: CatalogAppItem) {
        guard action == .hide || action == .quit else { return }

        let snapshotRuntimeIdentifiers = Set(item.runningInstances.map(\.id))
        refreshApps()
        let targets = rowImmediateTargets(
            for: action,
            bundleIdentifier: item.bundleIdentifier,
            snapshotRuntimeIdentifiers: snapshotRuntimeIdentifiers
        )
        guard !targets.isEmpty else {
            statusMessage = "没有可立即\(action.title)的 \(item.name) 实例"
            return
        }

        let progress = BatchProgress(total: targets.count)
        statusMessage = targets.count == 1
            ? "正在\(action.title)：\(item.name)"
            : "正在\(action.title) \(item.name) 的 \(targets.count) 个实例…"

        for target in targets {
            perform(
                action,
                on: target.app,
                named: target.name,
                bundleIdentifier: target.bundleIdentifier,
                runtimeIdentifier: target.id,
                source: .rowOverride
            ) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    progress.succeeded += 1
                } else {
                    progress.failed += 1
                }
                progress.remaining -= 1

                guard progress.remaining == 0 else { return }
                if progress.failed == 0 {
                    if targets.count == 1 {
                        self.statusMessage = action == .quit
                            ? "已请求退出：\(item.name)"
                            : "已隐藏：\(item.name)"
                    } else {
                        let result = action == .quit ? "已请求退出" : "已隐藏"
                        self.statusMessage = "\(result) \(item.name) 的 \(progress.succeeded) 个实例"
                    }
                } else {
                    let result = action == .quit ? "已请求退出" : "已隐藏"
                    self.statusMessage = "\(result) \(progress.succeeded) 个，\(progress.failed) 个失败"
                }
            }
        }
    }

    func liveForceQuitTargets(from requestedTargets: [RunningAppItem]) -> [RunningAppItem] {
        let currentRuntimeIdentifiers = Set(apps.map(\.id))
        return requestedTargets.filter {
            currentRuntimeIdentifiers.contains($0.id) && !$0.app.isTerminated
        }
    }

    func forceQuitImmediately(
        named name: String,
        requestedTargets: [RunningAppItem]
    ) {
        refreshApps()
        let targets = liveForceQuitTargets(from: requestedTargets)
        guard !targets.isEmpty else {
            statusMessage = "没有可强制退出的 \(name) 实例"
            return
        }

        let progress = BatchProgress(total: targets.count)
        statusMessage = targets.count == 1
            ? "正在强制退出：\(name)"
            : "正在强制退出 \(name) 的 \(targets.count) 个实例…"

        for target in targets {
            let token = UUID()
            preQuitHideStates.removeValue(forKey: target.id)
            quitRequestStates.removeValue(forKey: target.id)
            actionOperationTokens.removeValue(forKey: target.id)
            forceQuitFailures.remove(target.id)
            forceQuitOperationTokens[target.id] = token
            alreadyHandled.insert(target.id)
            actionFailures.removeValue(forKey: target.id)
            retryStates.removeValue(forKey: target.id)
            oneShotActionStates[target.id] = OneShotActionState(
                action: .quit,
                token: token
            )

            let requestAccepted = target.app.forceTerminate()
            if !requestAccepted {
                Self.logger.error("Force quit request was not accepted: \(target.bundleIdentifier, privacy: .public)")
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.forceQuitVerificationDelay
            ) { [weak self, app = target.app] in
                guard let self else { return }
                guard self.forceQuitOperationTokens[target.id] == token else {
                    self.refreshApps()
                    return
                }

                self.forceQuitOperationTokens.removeValue(forKey: target.id)
                let succeeded = app.isTerminated
                if succeeded {
                    self.forceQuitFailures.remove(target.id)
                    progress.succeeded += 1
                    Self.logger.notice("Force quit succeeded: \(target.bundleIdentifier, privacy: .public)")
                } else {
                    if self.oneShotActionStates[target.id]?.token == token {
                        self.oneShotActionStates.removeValue(forKey: target.id)
                    }
                    self.alreadyHandled.remove(target.id)
                    self.forceQuitFailures.insert(target.id)
                    progress.failed += 1
                    Self.logger.error("Force quit failed: \(target.bundleIdentifier, privacy: .public)")
                }
                progress.remaining -= 1

                if progress.remaining == 0 {
                    if progress.failed == 0 {
                        self.statusMessage = targets.count == 1
                            ? "已强制退出：\(name)"
                            : "已强制退出 \(name) 的 \(progress.succeeded) 个实例"
                    } else {
                        self.statusMessage = "已强制退出 \(progress.succeeded) 个，\(progress.failed) 个失败"
                    }
                }
                self.refreshApps()
            }
        }
        refreshApps()
    }

    func refreshApps() {
        let ownBundleID = Bundle.main.bundleIdentifier
        let runningApplications = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                app.bundleIdentifier != ownBundleID &&
                app.localizedName != nil
            }
        let running = runningApplications
            .compactMap { app -> RunningAppItem? in
                guard let bundleID = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                let icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: name) ?? NSImage()
                return RunningAppItem(
                    id: runtimeIdentifier(for: app),
                    bundleIdentifier: bundleID,
                    processIdentifier: app.processIdentifier,
                    name: name,
                    icon: icon,
                    isHidden: app.isHidden,
                    isActive: app.isActive,
                    app: app
                )
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        let runningRuntimeIDs = Set(running.map(\.id))
        for item in running {
            let action = effectivePolicy(for: item.bundleIdentifier)
            if action == .hide, item.isHidden {
                alreadyHandled.insert(item.id)
                actionFailures.removeValue(forKey: item.id)
                retryStates.removeValue(forKey: item.id)
            }

            if item.isActive || !action.isAutomated {
                inactiveSince.removeValue(forKey: item.id)
            } else if inactiveSince[item.id] == nil {
                inactiveSince[item.id] = effectiveNow
            }
        }
        inactiveSince = inactiveSince.filter { runningRuntimeIDs.contains($0.key) }
        alreadyHandled.formIntersection(runningRuntimeIDs)
        actionFailures = actionFailures.filter { runningRuntimeIDs.contains($0.key) }
        retryStates = retryStates.filter { runningRuntimeIDs.contains($0.key) }
        oneShotActionStates = oneShotActionStates.filter { runningRuntimeIDs.contains($0.key) }
        quitRequestStates = quitRequestStates.filter { runningRuntimeIDs.contains($0.key) }
        forceQuitFailures.formIntersection(runningRuntimeIDs)
        quitDeadlineAttempted.formIntersection(runningRuntimeIDs)
        preQuitHideStates = preQuitHideStates.filter { runningRuntimeIDs.contains($0.key) }
        fallbackRuntimeGenerations = fallbackRuntimeGenerations.filter { entry in
            runningApplications.contains {
                $0.launchDate == nil && $0.isEqual(entry.application)
            }
        }
        apps = running
        rebuildCatalog()
    }

    private func rebuildCatalog() {
        let runningByBundleIdentifier = Dictionary(grouping: apps, by: \.bundleIdentifier)
        let descriptors = AppRuleRegistry.catalogDescriptors(
            registry: ruleRegistry,
            runningSnapshots: apps.map {
                RunningRuleSnapshot(
                    bundleIdentifier: $0.bundleIdentifier,
                    runtimeIdentifier: $0.id
                )
            }
        )
        var metadataChanged = false

        let rebuilt = descriptors.map { descriptor -> CatalogAppItem in
            let bundleIdentifier = descriptor.bundleIdentifier
            let runningInstances = (runningByBundleIdentifier[bundleIdentifier] ?? []).sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                if lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
                return lhs.processIdentifier < rhs.processIdentifier
            }
            let existingRule = ruleRegistry.rules[bundleIdentifier]
            let bundleURL = resolvedBundleURL(
                for: bundleIdentifier,
                storedPath: existingRule?.lastKnownAppPath,
                runningInstances: runningInstances
            )
            let name = runningInstances.first?.name
                ?? displayName(at: bundleURL)
                ?? existingRule?.displayName.nonEmpty
                ?? AppRuleRegistry.fallbackDisplayName(for: bundleIdentifier)
            let icon = runningInstances.first?.icon
                ?? bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: name)
                ?? NSImage()

            if var rule = existingRule {
                let resolvedPath = bundleURL?.path
                if rule.displayName != name || (resolvedPath != nil && rule.lastKnownAppPath != resolvedPath) {
                    rule.displayName = name
                    if let resolvedPath {
                        rule.lastKnownAppPath = resolvedPath
                    }
                    ruleRegistry.rules[bundleIdentifier] = rule
                    metadataChanged = true
                }
            }

            return CatalogAppItem(
                bundleIdentifier: bundleIdentifier,
                name: name,
                icon: icon,
                explicitAction: descriptor.explicitAction,
                bundleURL: bundleURL,
                runningInstances: runningInstances
            )
        }

        if metadataChanged {
            persistRuleRegistry()
        }
        catalogApps = sortedByName(rebuilt)
    }

    private func sortedByName(_ items: [CatalogAppItem]) -> [CatalogAppItem] {
        items.sorted { lhs, rhs in
            AppRuleRegistry.isNameOrderedBefore(
                lhsDisplayName: lhs.name,
                lhsBundleIdentifier: lhs.bundleIdentifier,
                rhsDisplayName: rhs.name,
                rhsBundleIdentifier: rhs.bundleIdentifier
            )
        }
    }

    private func resolvedBundleURL(
        for bundleIdentifier: String,
        storedPath: String?,
        runningInstances: [RunningAppItem]
    ) -> URL? {
        if let runningURL = runningInstances.compactMap({ $0.app.bundleURL }).first,
           validatedBundleURL(runningURL, bundleIdentifier: bundleIdentifier) != nil {
            return runningURL
        }
        if let storedPath,
           let storedURL = validatedBundleURL(
               URL(fileURLWithPath: storedPath),
               bundleIdentifier: bundleIdentifier
           ) {
            return storedURL
        }
        if let workspaceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           let validatedURL = validatedBundleURL(workspaceURL, bundleIdentifier: bundleIdentifier) {
            return validatedURL
        }
        return nil
    }

    private func validatedBundleURL(_ url: URL, bundleIdentifier: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              Bundle(url: url)?.bundleIdentifier == bundleIdentifier else { return nil }
        return url
    }

    private func displayName(at bundleURL: URL?) -> String? {
        guard let bundleURL, let bundle = Bundle(url: bundleURL) else { return nil }
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return displayName?.nonEmpty
            ?? bundleName?.nonEmpty
            ?? bundleURL.deletingPathExtension().lastPathComponent.nonEmpty
    }

    private static func loadRuleRegistry(
        from defaults: UserDefaults,
        fileStore: RuleRegistryFileStore,
        legacyPolicies: [String: String],
        legacyPolicyIdleMinutes: [String: Int],
        legacyDefaultIdleMinutes: Int
    ) -> LoadedRuleRegistry {
        switch fileStore.load(fallbackIdleMinutes: legacyDefaultIdleMinutes) {
        case let .current(registry):
            return LoadedRuleRegistry(
                registry: registry,
                isWritable: true,
                requiresAutomationPause: false
            )
        case let .recoveredFromBackup(registry):
            Self.logger.notice("Recovered the rule registry from its verified file backup")
            return LoadedRuleRegistry(
                registry: registry,
                isWritable: true,
                requiresAutomationPause: false
            )
        case let .unsupported(schemaVersion):
            Self.logger.error("File rule registry schema \(schemaVersion, privacy: .public) is newer; automation paused")
            return LoadedRuleRegistry(
                registry: StoredRuleRegistry(),
                isWritable: false,
                requiresAutomationPause: true
            )
        case .invalid:
            Self.logger.error("File rule registry was unreadable; preserved it and falling back to legacy preferences")
        case .missing:
            break
        }

        func migrateToFileStore(_ registry: StoredRuleRegistry) {
            do {
                try fileStore.save(
                    registry,
                    fallbackIdleMinutes: legacyDefaultIdleMinutes
                )
            } catch {
                Self.logger.error("Failed to migrate rule registry to the atomic file store: \(error.localizedDescription, privacy: .public)")
            }
        }

        let primaryData = defaults.data(forKey: Keys.ruleRegistry)
        if let primaryData {
            switch AppRuleRegistry.decodeRegistry(
                from: primaryData,
                fallbackIdleMinutes: legacyDefaultIdleMinutes
            ) {
            case let .current(registry):
                migrateToFileStore(registry)
                return LoadedRuleRegistry(
                    registry: registry,
                    isWritable: true,
                    requiresAutomationPause: false
                )
            case let .unsupported(schemaVersion):
                Self.logger.error("Stored rule registry schema \(schemaVersion, privacy: .public) is newer; automation paused")
                return LoadedRuleRegistry(
                    registry: StoredRuleRegistry(),
                    isWritable: false,
                    requiresAutomationPause: true
                )
            case .invalid:
                defaults.set(primaryData, forKey: Keys.corruptRuleRegistryBackup)
                Self.logger.error("Stored rule registry was unreadable; preserved the original data and started recovery")
            }
        }

        let backupData = defaults.data(forKey: Keys.ruleRegistryBackup)
        if let backupData {
            switch AppRuleRegistry.decodeRegistry(
                from: backupData,
                fallbackIdleMinutes: legacyDefaultIdleMinutes
            ) {
            case let .current(registry):
                defaults.set(backupData, forKey: Keys.ruleRegistry)
                migrateToFileStore(registry)
                return LoadedRuleRegistry(
                    registry: registry,
                    isWritable: true,
                    requiresAutomationPause: false
                )
            case let .unsupported(schemaVersion):
                Self.logger.error("Backup rule registry schema \(schemaVersion, privacy: .public) is newer; automation paused")
                return LoadedRuleRegistry(
                    registry: StoredRuleRegistry(),
                    isWritable: false,
                    requiresAutomationPause: true
                )
            case .invalid:
                break
            }
        }

        let migrated = AppRuleRegistry.migrateLegacyRules(
            policies: legacyPolicies,
            policyIdleMinutes: legacyPolicyIdleMinutes,
            legacyDefaultIdleMinutes: legacyDefaultIdleMinutes
        )
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: Keys.ruleRegistry)
        }
        migrateToFileStore(migrated)
        return LoadedRuleRegistry(
            registry: migrated,
            isWritable: true,
            requiresAutomationPause: false
        )
    }

    private func persistRuleRegistry() {
        guard isRuleRegistryWritable else { return }
        do {
            try ruleStore.save(
                ruleRegistry,
                fallbackIdleMinutes: defaultHideMinutes
            )
            let encoded = try JSONEncoder().encode(ruleRegistry)
            if let currentData = defaults.data(forKey: Keys.ruleRegistry),
               currentData != encoded,
               case .current = AppRuleRegistry.decodeRegistry(
                   from: currentData,
                   fallbackIdleMinutes: defaultHideMinutes
               ) {
                defaults.set(currentData, forKey: Keys.ruleRegistryBackup)
            }
            defaults.set(encoded, forKey: Keys.ruleRegistry)
            rulePersistenceWarningKey = nil
        } catch {
            Self.logger.error("Failed to persist rule registry: \(error.localizedDescription, privacy: .public)")
            statusMessage = "保存规则失败"
            rulePersistenceWarningKey = .warningRuleRegistrySaveFailed
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                if !enabled {
                    try service.unregister()
                }
            case .notRegistered:
                if enabled {
                    try service.register()
                }
            case .requiresApproval:
                if enabled {
                    refreshLoginStatus()
                    statusMessage = localized(.warningLoginItemRequiresApproval)
                    return
                }
                try service.unregister()
            case .notFound:
                refreshLoginStatus()
                statusMessage = localized(.warningLoginItemNotFound)
                return
            @unknown default:
                refreshLoginStatus()
                loginItemWarningKey = .warningLoginItemFailed
                statusMessage = localized(.warningLoginItemFailed)
                return
            }
            refreshLoginStatus()
            statusMessage = launchAtLogin ? "已设置登录时启动" : "已取消登录时启动"
        } catch {
            refreshLoginStatus()
            statusMessage = localized(.warningLoginItemFailed)
            loginItemWarningKey = .warningLoginItemFailed
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refreshSettingsStatus() {
        refreshSystemLanguageIfNeeded()
        refreshLoginStatus()
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != nil else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let runtimeID = self.runtimeIdentifier(for: app)
                self.inactiveSince.removeValue(forKey: runtimeID)
                self.alreadyHandled.remove(runtimeID)
                self.actionFailures.removeValue(forKey: runtimeID)
                self.retryStates.removeValue(forKey: runtimeID)
                self.oneShotActionStates.removeValue(forKey: runtimeID)
                self.actionOperationTokens.removeValue(forKey: runtimeID)
                self.quitDeadlineAttempted.remove(runtimeID)
                self.preQuitHideStates.removeValue(forKey: runtimeID)
                self.refreshApps()
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let runtimeID = self.runtimeIdentifier(for: app)
                if self.effectivePolicy(for: bundleID).isAutomated {
                    self.inactiveSince[runtimeID] = self.effectiveNow
                }
                self.alreadyHandled.remove(runtimeID)
                self.actionFailures.removeValue(forKey: runtimeID)
                self.retryStates.removeValue(forKey: runtimeID)
                self.refreshApps()
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != nil else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleApplicationUnhidden(app, at: self.automationClock.now)
            }
        })

        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshApps()
                }
            })
        }

        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let eventInstant = self.automationClock.now
                self.suspendTiming(for: .systemSleep, at: eventInstant)
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let eventInstant = self.automationClock.now
                self.resumeTiming(for: .systemSleep, at: eventInstant)
            }
        })
    }

    private func installTimer() {
        let refreshTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleApps()
            }
        }
        timer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)
    }

    private func scheduleAutomaticUpdateCheck(now: Date = Date()) {
        automaticUpdateTimer?.invalidate()
        automaticUpdateTimer = nil
        guard automaticUpdateChecksEnabled, updateCheckTask == nil else { return }

        let fireDate = UpdateReminderPolicy.nextAutomaticCheckDate(
            now: now,
            lastCheckAt: defaults.object(forKey: Keys.lastAutomaticUpdateCheckAt) as? Date
        )
        let delay = max(fireDate.timeIntervalSince(now), 0.1)
        let updateTimer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.automaticUpdateTimer = nil
                guard self.automaticUpdateChecksEnabled else { return }
                self.startUpdateCheck(manual: false)
            }
        }
        automaticUpdateTimer = updateTimer
        RunLoop.main.add(updateTimer, forMode: .common)
    }

    private func startUpdateCheck(manual: Bool) {
        if updateCheckTask != nil {
            if manual {
                updateCheckShouldReport = true
                updateState = .checking
            }
            return
        }

        automaticUpdateTimer?.invalidate()
        automaticUpdateTimer = nil
        updateCheckShouldReport = manual
        updateCheckBeganAutomatically = !manual
        updateCheckInProgress = true
        if manual {
            updateState = .checking
        }

        let now = Date()
        if let remindAfter = defaults.object(forKey: Keys.updateRemindAfter) as? Date,
           remindAfter <= now {
            defaults.removeObject(forKey: Keys.updateRemindAfter)
        }
        if !manual {
            // Failed background checks count as attempts so an offline Mac does
            // not retry GitHub every time the menu opens.
            defaults.set(now, forKey: Keys.lastAutomaticUpdateCheckAt)
        }
        updateCheckTask = Task { [weak self] in
            do {
                let result = try await UpdateChecker.check()
                guard !Task.isCancelled, let self else { return }
                self.completeUpdateCheck(with: result)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.completeUpdateCheckAfterFailure()
            }
        }
    }

    private func completeUpdateCheck(with result: UpdateCheckResult) {
        if !updateCheckBeganAutomatically {
            defaults.set(Date(), forKey: Keys.lastAutomaticUpdateCheckAt)
        }
        switch result {
        case .upToDate:
            latestAvailableUpdate = nil
            pendingUpdatePrompt = nil
            updateState = .upToDate
            defaults.removeObject(forKey: Keys.cachedAvailableUpdate)
            let installedVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.0.0"
            let installedBuild = Int(
                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            ) ?? 0
            if UpdateReminderPolicy.shouldClearSkippedUpdate(
                installedVersion: installedVersion,
                installedBuild: installedBuild,
                skipped: skippedUpdateIdentity
            ) {
                defaults.removeObject(forKey: Keys.skippedUpdateIdentity)
            }
            defaults.removeObject(forKey: Keys.updateRemindAfter)
        case let .updateAvailable(update):
            latestAvailableUpdate = update
            cacheAvailableUpdate(update)
            updateState = .available(update)
        }
        finishUpdateCheck()
    }

    private func completeUpdateCheckAfterFailure() {
        if updateCheckShouldReport {
            updateState = .failed
        }
        finishUpdateCheck()
    }

    private func finishUpdateCheck() {
        updateCheckTask = nil
        updateCheckInProgress = false
        updateCheckShouldReport = false
        updateCheckBeganAutomatically = false
        scheduleAutomaticUpdateCheck()
    }

    private func postponeUpdatePrompt(_ update: AvailableUpdate, until date: Date) {
        latestAvailableUpdate = update
        cacheAvailableUpdate(update)
        pendingUpdatePrompt = nil
        defaults.set(date, forKey: Keys.updateRemindAfter)
        defaults.removeObject(forKey: Keys.skippedUpdateIdentity)
        scheduleAutomaticUpdateCheck()
    }

    private var skippedUpdateIdentity: UpdateReleaseIdentity? {
        guard let data = defaults.data(forKey: Keys.skippedUpdateIdentity) else { return nil }
        return try? JSONDecoder().decode(UpdateReleaseIdentity.self, from: data)
    }

    private func cacheAvailableUpdate(_ update: AvailableUpdate) {
        guard let data = try? JSONEncoder().encode(update) else { return }
        defaults.set(data, forKey: Keys.cachedAvailableUpdate)
    }

    private func restoreCachedAvailableUpdate() {
        guard let data = defaults.data(forKey: Keys.cachedAvailableUpdate),
              let update = try? JSONDecoder().decode(AvailableUpdate.self, from: data),
              let validatedUpdate = UpdateChecker.validatedAvailableUpdate(update),
              UpdateChecker.isUpdateNewer(validatedUpdate) else {
            defaults.removeObject(forKey: Keys.cachedAvailableUpdate)
            return
        }
        latestAvailableUpdate = validatedUpdate
        updateState = .available(validatedUpdate)
    }

    private func checkIdleApps() {
        refreshApps()
        guard automationEnabled else { return }

        let now = effectiveNow

        for item in apps {
            let bundleID = item.bundleIdentifier
            let runtimeID = item.id
            let action = effectivePolicy(for: bundleID)
            guard action.isAutomated,
                  oneShotActionStates[runtimeID] == nil,
                  quitRequestStates[runtimeID] == nil,
                  forceQuitOperationTokens[runtimeID] == nil,
                  !item.isActive,
                  let inactiveAt = inactiveSince[runtimeID] else { continue }

            let elapsed = now - inactiveAt
            let actionDelay = thresholdSeconds(for: bundleID)

            if action == .quit {
                let preHideState = preQuitHideStates[runtimeID] ?? PreQuitHideRuntimeState()
                let decision = QuitAutomationTiming.decision(
                    enabled: preQuitHideEnabled,
                    elapsed: elapsed,
                    hideDelay: preQuitHideDelaySeconds,
                    quitDelay: actionDelay,
                    isHidden: item.isHidden,
                    hideStage: preHideState.stage,
                    canAttemptHide: preHideState.retryState.canAttempt(at: now)
                )

                switch decision {
                case .wait:
                    continue
                case .preHide:
                    guard !alreadyHandled.contains(runtimeID) else { continue }
                    performPreQuitHide(on: item, state: preHideState)
                    continue
                case .quit:
                    preQuitHideStates.removeValue(forKey: runtimeID)
                    let isFirstDeadlineAttempt = !quitDeadlineAttempted.contains(runtimeID)
                    guard QuitAutomationTiming.shouldAttemptQuit(
                        isFirstDeadlineAttempt: isFirstDeadlineAttempt,
                        isAlreadyHandled: alreadyHandled.contains(runtimeID),
                        hasActionFailure: actionFailures[runtimeID] != nil,
                        canRetry: retryStates[runtimeID]?.canAttempt(at: now) != false
                    ) else {
                        continue
                    }
                    if isFirstDeadlineAttempt {
                        // A failed manual batch request before Q must not delay or
                        // consume retries from the rule's first deadline attempt.
                        alreadyHandled.remove(runtimeID)
                        actionFailures.removeValue(forKey: runtimeID)
                        retryStates.removeValue(forKey: runtimeID)
                    }
                    quitDeadlineAttempted.insert(runtimeID)
                }
            } else {
                guard !alreadyHandled.contains(runtimeID),
                      retryStates[runtimeID]?.canAttempt(at: now) != false,
                      elapsed >= actionDelay else { continue }
            }

            perform(
                action,
                on: item.app,
                named: item.name,
                bundleIdentifier: bundleID,
                runtimeIdentifier: runtimeID,
                source: .automatic
            )
        }
    }

    private func performPreQuitHide(
        on item: RunningAppItem,
        state: PreQuitHideRuntimeState
    ) {
        let token = UUID()
        var inFlightState = state
        inFlightState.stage = .inFlight
        inFlightState.token = token
        preQuitHideStates[item.id] = inFlightState
        statusMessage = "正在预先隐藏：\(item.name)"
        _ = item.app.hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, app = item.app] in
            guard let self else { return }
            guard var currentState = self.preQuitHideStates[item.id],
                  currentState.token == token else {
                self.refreshApps()
                return
            }

            currentState.token = nil
            if app.isHidden || app.isTerminated {
                currentState.stage = .completed
                currentState.retryState = ActionRetryState()
                self.preQuitHideStates[item.id] = currentState
                self.statusMessage = "已预先隐藏：\(item.name)，仍将按时退出"
                Self.logger.notice("Pre-quit hide succeeded: \(item.bundleIdentifier, privacy: .public)")
            } else {
                currentState.stage = .pending
                currentState.retryState.recordFailure(at: self.effectiveNow, delay: Self.retryDelay)
                self.preQuitHideStates[item.id] = currentState
                self.statusMessage = currentState.retryState.hasAttemptsRemaining
                    ? "无法预先隐藏：\(item.name)，稍后重试"
                    : "无法预先隐藏：\(item.name)，仍将按时退出"
                Self.logger.error("Pre-quit hide failed: \(item.bundleIdentifier, privacy: .public) attempt=\(currentState.retryState.failureCount, privacy: .public)")
            }
            self.refreshApps()
        }
    }

    private func rowImmediateTargets(
        for action: AutoAction,
        bundleIdentifier: String,
        snapshotRuntimeIdentifiers: Set<String>
    ) -> [RunningAppItem] {
        let runtimeIdentifiers = AppRuleRegistry.rowImmediateTargetRuntimeIdentifiers(
            action: action,
            bundleIdentifier: bundleIdentifier,
            snapshotRuntimeIdentifiers: snapshotRuntimeIdentifiers,
            candidates: apps.map {
                ImmediateActionSnapshot(
                    runtimeIdentifier: $0.id,
                    bundleIdentifier: $0.bundleIdentifier,
                    isHidden: $0.isHidden,
                    isAlreadyHandled: alreadyHandled.contains($0.id)
                )
            }
        )
        return apps.filter {
            runtimeIdentifiers.contains($0.id) && !$0.app.isTerminated
        }
    }

    private func immediateTargets(for action: AutoAction) -> [RunningAppItem] {
        let runtimeIdentifiers = AppRuleRegistry.immediateTargetRuntimeIdentifiers(
            action: action,
            candidates: apps.map {
                ImmediateActionSnapshot(
                    runtimeIdentifier: $0.id,
                    bundleIdentifier: $0.bundleIdentifier,
                    isHidden: $0.isHidden,
                    isAlreadyHandled: alreadyHandled.contains($0.id)
                )
            },
            registry: ruleRegistry,
            defaultHideEnabled: defaultHideEnabled
        )
        return apps.filter { runtimeIdentifiers.contains($0.id) }
    }

    private func perform(
        _ action: AutoAction,
        on app: NSRunningApplication,
        named name: String,
        bundleIdentifier: String,
        runtimeIdentifier: String,
        source: ActionSource,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard action == .hide || action == .quit else { return }
        // Any real action supersedes a pending pre-quit hide callback for this process.
        preQuitHideStates.removeValue(forKey: runtimeIdentifier)
        quitRequestStates.removeValue(forKey: runtimeIdentifier)
        forceQuitOperationTokens.removeValue(forKey: runtimeIdentifier)
        forceQuitFailures.remove(runtimeIdentifier)
        let operationToken = UUID()
        actionOperationTokens[runtimeIdentifier] = operationToken
        if source.isRowOverride {
            oneShotActionStates[runtimeIdentifier] = OneShotActionState(
                action: action,
                token: operationToken
            )
        } else {
            // A later batch/automatic action supersedes an unfinished row action.
            oneShotActionStates.removeValue(forKey: runtimeIdentifier)
        }

        let requestAccepted: Bool
        switch action {
        case .hide:
            requestAccepted = app.hide()
        case .quit:
            requestAccepted = app.terminate()
        case .unset, .ignore:
            return
        }

        if !source.isRowOverride {
            alreadyHandled.insert(runtimeIdentifier)
            actionFailures.removeValue(forKey: runtimeIdentifier)
        }
        statusMessage = "正在\(action.title)：\(name)"

        // A successful terminate() means macOS accepted the normal quit request.
        // The target may remain alive while it asks the user to save or confirm;
        // that is not an automation failure and should not trigger repeated prompts.
        if action == .quit, requestAccepted {
            quitRequestStates[runtimeIdentifier] = QuitRequestRuntimeState(
                requestedAt: Date(),
                token: operationToken
            )
            finishAction(
                action,
                succeeded: true,
                name: name,
                bundleIdentifier: bundleIdentifier,
                runtimeIdentifier: runtimeIdentifier,
                source: source,
                operationToken: operationToken,
                completion: completion
            )
            return
        }

        // NSRunningApplication actions are asynchronous on recent macOS versions.
        // Verify the resulting state instead of trusting the immediate return value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, app] in
            guard let self else { return }
            let succeeded: Bool
            switch action {
            case .hide:
                succeeded = app.isHidden || app.isTerminated
            case .quit:
                succeeded = app.isTerminated
            case .unset, .ignore:
                return
            }

            self.finishAction(
                action,
                succeeded: succeeded,
                name: name,
                bundleIdentifier: bundleIdentifier,
                runtimeIdentifier: runtimeIdentifier,
                source: source,
                operationToken: operationToken,
                completion: completion
            )
        }
    }

    private func finishAction(
        _ action: AutoAction,
        succeeded: Bool,
        name: String,
        bundleIdentifier: String,
        runtimeIdentifier: String,
        source: ActionSource,
        operationToken: UUID,
        completion: ((Bool) -> Void)?
    ) {
        guard actionOperationTokens[runtimeIdentifier] == operationToken else {
            refreshApps()
            return
        }

        if source.isRowOverride {
            guard oneShotActionStates[runtimeIdentifier]?.token == operationToken else {
                actionOperationTokens.removeValue(forKey: runtimeIdentifier)
                refreshApps()
                return
            }
            actionOperationTokens.removeValue(forKey: runtimeIdentifier)
            if succeeded {
                statusMessage = action == .quit
                    ? "已请求退出：\(name)"
                    : "已\(action.title)：\(name)"
                Self.logger.notice("Row action succeeded: \(action.rawValue, privacy: .public) \(bundleIdentifier, privacy: .public)")
            } else {
                oneShotActionStates.removeValue(forKey: runtimeIdentifier)
                statusMessage = "无法\(action.title)：\(name)"
                Self.logger.error("Row action failed: \(action.rawValue, privacy: .public) \(bundleIdentifier, privacy: .public)")
            }
            completion?(succeeded)
            refreshApps()
            return
        }

        actionOperationTokens.removeValue(forKey: runtimeIdentifier)
        let automatic = source.isAutomatic
        if succeeded {
            actionFailures.removeValue(forKey: runtimeIdentifier)
            retryStates.removeValue(forKey: runtimeIdentifier)
            statusMessage = action == .quit
                ? "\(automatic ? "自动" : "已")请求退出：\(name)"
                : "\(automatic ? "自动" : "已")\(action.title)：\(name)"
            Self.logger.notice("Action succeeded: \(action.rawValue, privacy: .public) \(bundleIdentifier, privacy: .public) automatic=\(automatic, privacy: .public)")
        } else {
            actionFailures[runtimeIdentifier] = action
            var retryState = retryStates[runtimeIdentifier] ?? ActionRetryState()
            retryState.recordFailure(at: effectiveNow, delay: Self.retryDelay)
            retryStates[runtimeIdentifier] = retryState

            if retryState.hasAttemptsRemaining {
                alreadyHandled.remove(runtimeIdentifier)
                statusMessage = "无法\(action.title)：\(name)，稍后重试"
            } else {
                statusMessage = "无法\(action.title)：\(name)，请手动重试"
            }
            Self.logger.error("Action failed: \(action.rawValue, privacy: .public) \(bundleIdentifier, privacy: .public) attempt=\(retryState.failureCount, privacy: .public) automatic=\(automatic, privacy: .public)")
        }
        completion?(succeeded)
        refreshApps()
    }

    private func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            loginItemWarningKey = nil
        case .notRegistered:
            launchAtLogin = false
            loginItemWarningKey = nil
        case .requiresApproval:
            launchAtLogin = false
            loginItemWarningKey = .warningLoginItemRequiresApproval
        case .notFound:
            launchAtLogin = false
            loginItemWarningKey = .warningLoginItemNotFound
        @unknown default:
            launchAtLogin = false
            loginItemWarningKey = .warningLoginItemFailed
        }
    }

    private var effectiveNow: TimeInterval {
        timingSuspension.effectiveNow(at: automationClock.now)
    }

    private func suspendTiming(for reason: TimingSuspension.Reason, at instant: TimeInterval) {
        timingSuspension.suspend(for: reason, at: instant)
    }

    private func resumeTiming(for reason: TimingSuspension.Reason, at instant: TimeInterval) {
        guard let suspendedDuration = timingSuspension.resume(for: reason, at: instant) else { return }
        inactiveSince = inactiveSince.mapValues { $0 + suspendedDuration }
        retryStates = retryStates.mapValues { state in
            var shifted = state
            shifted.shiftRetryDate(by: suspendedDuration)
            return shifted
        }
        preQuitHideStates = preQuitHideStates.mapValues { state in
            var shifted = state
            shifted.retryState.shiftRetryDate(by: suspendedDuration)
            return shifted
        }
    }

    private func handleApplicationUnhidden(
        _ app: NSRunningApplication,
        at eventInstant: TimeInterval
    ) {
        guard let bundleIdentifier = app.bundleIdentifier else { return }
        let runtimeIdentifier = runtimeIdentifier(for: app)

        alreadyHandled.remove(runtimeIdentifier)
        actionFailures.removeValue(forKey: runtimeIdentifier)
        retryStates.removeValue(forKey: runtimeIdentifier)
        oneShotActionStates.removeValue(forKey: runtimeIdentifier)
        actionOperationTokens.removeValue(forKey: runtimeIdentifier)
        quitRequestStates.removeValue(forKey: runtimeIdentifier)
        forceQuitFailures.remove(runtimeIdentifier)
        quitDeadlineAttempted.remove(runtimeIdentifier)
        preQuitHideStates.removeValue(forKey: runtimeIdentifier)

        let shouldRestartTimer = ApplicationUnhidePolicy.shouldRestartTimer(
            actionIsAutomated: effectivePolicy(for: bundleIdentifier).isAutomated,
            applicationIsActive: app.isActive
        )
        if shouldRestartTimer {
            inactiveSince[runtimeIdentifier] = timingSuspension.effectiveNow(at: eventInstant)
        } else {
            inactiveSince.removeValue(forKey: runtimeIdentifier)
        }
        refreshApps()
    }

    private func resetRuntimeState(for bundleIdentifier: String, restartTimer: Bool) {
        for item in apps where item.bundleIdentifier == bundleIdentifier {
            alreadyHandled.remove(item.id)
            actionFailures.removeValue(forKey: item.id)
            retryStates.removeValue(forKey: item.id)
            oneShotActionStates.removeValue(forKey: item.id)
            actionOperationTokens.removeValue(forKey: item.id)
            quitRequestStates.removeValue(forKey: item.id)
            forceQuitOperationTokens.removeValue(forKey: item.id)
            forceQuitFailures.remove(item.id)
            quitDeadlineAttempted.remove(item.id)
            preQuitHideStates.removeValue(forKey: item.id)
            if restartTimer, !item.isActive {
                inactiveSince[item.id] = effectiveNow
            } else {
                inactiveSince.removeValue(forKey: item.id)
            }
        }
    }

    private func clearActionState(for bundleIdentifier: String) {
        for item in apps where item.bundleIdentifier == bundleIdentifier {
            alreadyHandled.remove(item.id)
            actionFailures.removeValue(forKey: item.id)
            retryStates.removeValue(forKey: item.id)
            oneShotActionStates.removeValue(forKey: item.id)
            actionOperationTokens.removeValue(forKey: item.id)
            quitRequestStates.removeValue(forKey: item.id)
            forceQuitOperationTokens.removeValue(forKey: item.id)
            forceQuitFailures.remove(item.id)
            quitDeadlineAttempted.remove(item.id)
            preQuitHideStates.removeValue(forKey: item.id)
        }
    }

    private func resetDefaultPolicyRuntimeState(restartTimer: Bool) {
        for item in apps where policy(for: item.bundleIdentifier) == .unset {
            alreadyHandled.remove(item.id)
            actionFailures.removeValue(forKey: item.id)
            retryStates.removeValue(forKey: item.id)
            oneShotActionStates.removeValue(forKey: item.id)
            actionOperationTokens.removeValue(forKey: item.id)
            quitRequestStates.removeValue(forKey: item.id)
            forceQuitOperationTokens.removeValue(forKey: item.id)
            forceQuitFailures.remove(item.id)
            quitDeadlineAttempted.remove(item.id)
            preQuitHideStates.removeValue(forKey: item.id)
            if restartTimer, !item.isActive {
                inactiveSince[item.id] = effectiveNow
            } else {
                inactiveSince.removeValue(forKey: item.id)
            }
        }
    }

    private func resetPreQuitHideRuntimeState() {
        preQuitHideStates.removeAll()
    }

    private func runtimeIdentifier(for app: NSRunningApplication) -> String {
        let fallbackGeneration: UUID?
        if app.launchDate == nil {
            if let existing = fallbackRuntimeGenerations.first(where: {
                $0.application.isEqual(app)
            }) {
                fallbackGeneration = existing.generation
            } else {
                let created = UUID()
                fallbackRuntimeGenerations.append(FallbackRuntimeGeneration(
                    application: app,
                    generation: created
                ))
                fallbackGeneration = created
            }
        } else {
            fallbackGeneration = nil
        }

        return RuntimeApplicationIdentity.identifier(
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            processIdentifier: app.processIdentifier,
            launchDate: app.launchDate,
            fallbackGeneration: fallbackGeneration
        )
    }

    private func thresholdSeconds(for bundleIdentifier: String) -> TimeInterval {
        if let testSeconds = ProcessInfo.processInfo.environment["QUITHIDE_TEST_IDLE_SECONDS"],
           let parsed = TimeInterval(testSeconds), parsed > 0 {
            return parsed
        }
        return TimeInterval(idleMinutes(for: bundleIdentifier) * 60)
    }

    private var preQuitHideDelaySeconds: TimeInterval {
        if let testSeconds = ProcessInfo.processInfo.environment["QUITHIDE_TEST_PRE_QUIT_HIDE_SECONDS"],
           let parsed = TimeInterval(testSeconds), parsed > 0 {
            return parsed
        }
        return TimeInterval(preQuitHideMinutes * 60)
    }

    private func formatRemainingTime(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(ceil(interval)), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct AppRow: View {
    @EnvironmentObject private var model: AppModel
    let item: CatalogAppItem
    let onRequestForceQuit: (CatalogAppItem) -> Void

    private var explicitAction: AutoAction {
        model.policy(for: item.bundleIdentifier)
    }

    private var effectiveAction: AutoAction {
        model.effectivePolicy(for: item.bundleIdentifier)
    }

    private var minuteOptions: [Int] {
        let presets = [2, 5, 10, 20, 60, 120, 300, 1_440]
        return Array(Set(presets + [model.idleMinutes(for: item.bundleIdentifier)])).sorted()
    }

    private func immediateMenuTitle(for action: AutoAction) -> String {
        let targetCount = model.immediateTargetCount(for: action, in: item)
        guard item.runningInstances.count > 1 else {
            if action == .hide, targetCount == 0 {
                return model.localized(.contextHideAlreadyHidden)
            }
            return model.localized(.contextActionImmediate, replacements: [
                "action": model.actionTitle(for: action)
            ])
        }

        if action == .hide {
            return targetCount == 0
                ? model.localized(.contextHideAllHidden)
                : model.localized(.contextHideVisibleInstances, replacements: [
                    "count": String(targetCount)
                ])
        }
        return model.localized(.contextQuitAllInstances, replacements: [
            "count": String(targetCount)
        ])
    }

    private var forceQuitMenuTitle: String {
        guard item.runningInstances.count > 1 else {
            return model.localized(.contextForceQuit)
        }
        return model.localized(.contextForceQuitAllInstances, replacements: [
            "count": String(item.runningInstances.count)
        ])
    }

    private var displayStatus: AppAutomationStatus? {
        if item.runningInstances.count > 1 {
            let statuses = item.runningInstances.compactMap { model.automationStatus(for: $0) }
            if let errorStatus = statuses.first(where: \.isError) {
                let errorCount = statuses.filter(\.isError).count
                return AppAutomationStatus(
                    text: model.localized(.statusInstancesErrorSummary, replacements: [
                        "count": String(item.runningInstances.count),
                        "errorCount": String(errorCount),
                        "status": errorStatus.text
                    ]),
                    isError: true,
                    helpText: errorStatus.helpText
                )
            }
            let warningCount = statuses.filter(\.isWarning).count
            if warningCount > 0 {
                return AppAutomationStatus(
                    text: model.localized(.statusInstancesQuitNotCompleted, replacements: [
                        "count": String(item.runningInstances.count),
                        "warningCount": String(warningCount)
                    ]),
                    isWarning: true,
                    helpText: model.localized(.statusInstancesQuitNotCompletedHelp)
                )
            }
            if statuses.count == item.runningInstances.count,
               let firstStatus = statuses.first,
                statuses.allSatisfy({ $0.text == firstStatus.text }) {
                return AppAutomationStatus(
                    text: model.localized(.statusInstancesSameStatus, replacements: [
                        "count": String(item.runningInstances.count),
                        "status": firstStatus.text
                    ]),
                    helpText: firstStatus.helpText
                )
            }
            return AppAutomationStatus(
                text: model.localized(
                    !model.automationEnabled && effectiveAction.isAutomated
                        ? .statusInstancesPausedSeparateTimers
                        : .statusInstancesSeparateTimers,
                    replacements: ["count": String(item.runningInstances.count)]
                ),
                isError: false
            )
        }
        if let runningItem = item.primaryRunningItem {
            return model.automationStatus(for: runningItem)
        }
        return AppAutomationStatus(
            text: model.localized(
                item.isInstalled ? .rowStatusNotRunning : .rowStatusAppNotFound
            ),
            isError: false
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 28, height: 28)
                .saturation(item.isRunning ? 1 : 0)
                .opacity(item.isRunning ? 1 : 0.48)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .foregroundStyle(item.isRunning ? Color.primary : Color.secondary)
                if let status = displayStatus {
                    Text(status.text)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            status.isError
                                ? Color.red
                                : status.isWarning ? Color.orange : Color.secondary
                        )
                        .lineLimit(1)
                        .help(status.helpText ?? status.text)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Picker(model.localized(.rowRuleLabel), selection: Binding(
                get: { explicitAction },
                set: { model.setPolicy($0, for: item.bundleIdentifier) }
            )) {
                ForEach(AutoAction.rulePickerOrder, id: \.self) { option in
                    Label {
                        Text(model.rulePickerTitle(for: option))
                    } icon: {
                        Image(systemName: option.symbol)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(ruleIconTint(for: option))
                    }
                    .tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 116)
            .disabled(!model.rulesAreEditable)
            .help(model.localized(.rowRuleHelp, replacements: ["name": item.name]))
            .accessibilityLabel(model.localized(.a11yRuleForApp, replacements: [
                "name": item.name
            ]))

            Group {
                if explicitAction == .unset, effectiveAction == .hide {
                    Text(model.durationTitle(model.defaultHideMinutes))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .help(model.localized(.rowDelayInherited))
                } else if !explicitAction.isAutomated {
                    Text("—")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(model.localized(.a11yDelayNotSet))
                } else {
                    Picker(model.localized(.rowDelayLabel), selection: Binding(
                        get: { model.idleMinutes(for: item.bundleIdentifier) },
                        set: { model.setIdleMinutes($0, for: item.bundleIdentifier) }
                    )) {
                        ForEach(minuteOptions, id: \.self) { minutes in
                            Text(model.durationTitle(minutes)).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .help(model.localized(.rowDelayHelp))
                    .accessibilityLabel(model.localized(.a11yDelayForApp, replacements: [
                        "name": item.name
                    ]))
                    .disabled(!model.rulesAreEditable)
                }
            }
            .frame(width: 90)
        }
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .contextMenu {
            if item.isRunning {
                Button {
                    model.performImmediately(.hide, for: item)
                } label: {
                    Label(immediateMenuTitle(for: .hide), systemImage: AutoAction.hide.symbol)
                }
                .disabled(model.immediateTargetCount(for: .hide, in: item) == 0)
                .accessibilityLabel(model.localized(.a11yActionForApp, replacements: [
                    "action": immediateMenuTitle(for: .hide),
                    "name": item.name
                ]))

                Divider()

                Button {
                    model.performImmediately(.quit, for: item)
                } label: {
                    Label(immediateMenuTitle(for: .quit), systemImage: AutoAction.quit.symbol)
                }
                .disabled(model.immediateTargetCount(for: .quit, in: item) == 0)
                .accessibilityLabel(model.localized(.a11yActionForApp, replacements: [
                    "action": immediateMenuTitle(for: .quit),
                    "name": item.name
                ]))

                Divider()

                Button(role: .destructive) {
                    onRequestForceQuit(item)
                } label: {
                    Label(forceQuitMenuTitle, systemImage: "exclamationmark.octagon")
                }
                .disabled(model.immediateTargetCount(for: .quit, in: item) == 0)
                .accessibilityLabel(model.localized(.a11yActionForApp, replacements: [
                    "action": forceQuitMenuTitle,
                    "name": item.name
                ]))
            }
        }
    }

    private func ruleIconTint(for action: AutoAction) -> Color {
        switch action {
        case .ignore: return .green
        case .unset: return .orange
        case .hide: return .blue
        case .quit: return .red
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return model.localized(.settingsAboutVersion, replacements: ["version": version])
    }

    private var defaultMinuteOptions: [Int] {
        let presets = [2, 5, 10, 20, 60]
        return Array(Set(presets + [model.defaultHideMinutes])).sorted()
    }

    private var preQuitHideMinuteOptions: [Int] {
        let presets = [1, 2, 5, 10, 20, 60]
        return Array(Set(presets + [model.preQuitHideMinutes])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.localized(.settingsTitle))
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text(model.localized(.settingsLoginLaunch))
                        .font(.callout.weight(.medium))
                        .accessibilityHidden(true)

                    Spacer(minLength: 12)

                    Toggle(model.localized(.settingsLoginLaunch), isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                HStack(spacing: 12) {
                    Text(model.localized(.languagePickerLabel))
                        .font(.callout.weight(.medium))
                        .accessibilityHidden(true)

                    Spacer(minLength: 12)

                    Picker(model.localized(.languagePickerLabel), selection: Binding(
                        get: { model.languagePreference },
                        set: { model.setLanguagePreference($0) }
                    )) {
                        ForEach(AppLanguagePreference.allCases) { preference in
                            Text(model.localized(preference.labelKey)).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
            }

            ForEach(model.settingsWarnings) { warning in
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(warning.message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    if warning.showsLoginItemsSettingsButton {
                        Button(model.localized(.settingsLoginOpen)) {
                            model.openLoginItemsSettings()
                        }
                        .controlSize(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.orange.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 0.5)
                }
                .accessibilityElement(children: .contain)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(model.localized(.settingsAdditionalRulesTitle))
                    .font(.headline)

                HStack(spacing: 10) {
                    Toggle(model.localized(.settingsDefaultHideEnabled), isOn: Binding(
                        get: { model.defaultHideEnabled },
                        set: { model.setDefaultHideEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.rulesAreEditable)

                    Text(model.localized(.settingsDefaultHideEnabled))
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 6)

                    if model.defaultHideEnabled {
                        Picker(model.localized(.settingsDefaultHideDelay), selection: Binding(
                            get: { model.defaultHideMinutes },
                            set: { model.setDefaultHideMinutes($0) }
                        )) {
                            ForEach(defaultMinuteOptions, id: \.self) { minutes in
                                Text(model.durationTitle(minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        .help(model.localized(.settingsDefaultHideHelp))
                        .disabled(!model.rulesAreEditable)
                    }
                }

                HStack(spacing: 10) {
                    Toggle(model.localized(.settingsPreQuitHideEnabled), isOn: Binding(
                        get: { model.preQuitHideEnabled },
                        set: { model.setPreQuitHideEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.rulesAreEditable)

                    Text(model.localized(.settingsPreQuitHideEnabled))
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 6)

                    if model.preQuitHideEnabled {
                        Picker(model.localized(.settingsPreQuitHideDelay), selection: Binding(
                            get: { model.preQuitHideMinutes },
                            set: { model.setPreQuitHideMinutes($0) }
                        )) {
                            ForEach(preQuitHideMinuteOptions, id: \.self) { minutes in
                                Text(model.durationTitle(minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        .help(model.localized(.settingsPreQuitHideHelp))
                        .disabled(!model.rulesAreEditable)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(model.localized(.settingsAboutTitle))
                    .font(.headline)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.localized(.settingsAboutAuthor))
                    Text(model.localized(.settingsAboutFeedback))
                        .textSelection(.enabled)
                    Text(versionText)
                        .foregroundStyle(.secondary)
                    Label(
                        model.localized(.settingsAboutNotarized),
                        systemImage: "checkmark.shield"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                HStack(spacing: 12) {
                    Toggle(model.localized(.settingsUpdateAutomatic), isOn: Binding(
                        get: { model.automaticUpdateChecksEnabled },
                        set: { model.setAutomaticUpdateChecksEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Spacer(minLength: 8)

                    Button(updateButtonTitle) {
                        handleUpdateButton()
                    }
                    .disabled(isChecking)
                    .suppressFocusEffect()
                }

                if let statusText = updateStatusText {
                    HStack(spacing: 7) {
                        Image(systemName: updateStatusSymbol)
                            .foregroundStyle(updateStatusColor)

                        Text(statusText)
                            .foregroundStyle(.primary)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        updateStatusColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(updateStatusColor.opacity(0.22), lineWidth: 0.5)
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Link(
                    model.localized(.settingsGitHubProject),
                    destination: URL(string: "https://github.com/jiangsir-tech/QuitHide")!
                )
                .font(.caption)
            }
            .animation(.easeOut(duration: 0.18), value: model.updateState)
        }
        .padding(24)
        .frame(width: 410)
        .environment(\.locale, model.effectiveLocale)
        .background {
            SettingsWindowConfigurator(title: model.localized(.settingsTitle))
                .frame(width: 0, height: 0)
        }
        .onAppear {
            model.refreshSettingsStatus()
        }
    }

    private var isChecking: Bool {
        model.updateCheckInProgress
    }

    private var updateButtonTitle: String {
        if case .available = model.updateState {
            return model.localized(.updateActionDownload)
        }
        return model.localized(isChecking ? .updateStatusChecking : .updateActionCheck)
    }

    private var updateStatusText: String? {
        switch model.updateState {
        case .idle, .checking:
            return nil
        case .upToDate:
            return model.localized(.updateStatusUpToDate)
        case let .available(update):
            return model.localized(.updateStatusAvailable, replacements: [
                "version": update.version
            ])
        case .failed:
            return model.localized(.updateStatusFailed)
        }
    }

    private var updateStatusSymbol: String {
        switch model.updateState {
        case .upToDate:
            return "checkmark.circle.fill"
        case .available:
            return "arrow.up.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        case .idle, .checking:
            return "info.circle.fill"
        }
    }

    private var updateStatusColor: Color {
        switch model.updateState {
        case .upToDate:
            return .green
        case .available:
            return .blue
        case .failed:
            return .red
        case .idle, .checking:
            return .secondary
        }
    }

    private func handleUpdateButton() {
        if case let .available(update) = model.updateState {
            model.openAvailableUpdate(update)
            return
        }
        model.checkForUpdatesManually()
    }
}

private final class SettingsWindowTrackingView: NSView {
    var configureWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            configureWindow?(window)
        }
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> SettingsWindowTrackingView {
        let view = SettingsWindowTrackingView(frame: .zero)
        view.configureWindow = { window in
            Self.configure(window, title: title)
        }
        return view
    }

    func updateNSView(_ nsView: SettingsWindowTrackingView, context: Context) {
        nsView.configureWindow = { window in
            Self.configure(window, title: title)
        }
        if let window = nsView.window {
            Self.configure(window, title: title)
        }
    }

    private static func configure(_ window: NSWindow, title: String) {
        window.identifier = NSUserInterfaceItemIdentifier("QuitHide.Settings")
        window.title = title
    }
}

private extension View {
    @ViewBuilder
    func suppressFocusEffect() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

private final class MenuWindowTrackingView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}

private struct MenuWindowLifecycleObserver: NSViewRepresentable {
    let onPresented: () -> Void
    let onHidden: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPresented: onPresented, onHidden: onHidden)
    }

    func makeNSView(context: Context) -> MenuWindowTrackingView {
        let view = MenuWindowTrackingView(frame: .zero)
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window)
        }
        return view
    }

    func updateNSView(_ nsView: MenuWindowTrackingView, context: Context) {
        context.coordinator.onPresented = onPresented
        context.coordinator.onHidden = onHidden
        context.coordinator.observe(nsView.window)
    }

    static func dismantleNSView(_ nsView: MenuWindowTrackingView, coordinator: Coordinator) {
        nsView.windowDidChange = nil
        coordinator.stopObserving()
    }

    final class Coordinator {
        var onPresented: () -> Void
        var onHidden: () -> Void

        private weak var observedWindow: NSWindow?
        private var becameKeyObserver: NSObjectProtocol?
        private var resignedKeyObserver: NSObjectProtocol?
        private var confirmedHidden = false
        private var visibilityCheckGeneration = 0

        init(onPresented: @escaping () -> Void, onHidden: @escaping () -> Void) {
            self.onPresented = onPresented
            self.onHidden = onHidden
        }

        deinit {
            stopObserving()
        }

        func observe(_ window: NSWindow?) {
            guard observedWindow !== window else { return }
            stopObserving()
            observedWindow = window
            guard let window else { return }
            confirmedHidden = !window.isVisible

            let center = NotificationCenter.default
            becameKeyObserver = center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.visibilityCheckGeneration += 1
                guard self.confirmedHidden else { return }
                self.confirmedHidden = false
                self.onPresented()
            }
            resignedKeyObserver = center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self else { return }
                self.visibilityCheckGeneration += 1
                let generation = self.visibilityCheckGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                    guard let self,
                          let window,
                          generation == self.visibilityCheckGeneration,
                          self.observedWindow === window,
                          !window.isVisible else { return }
                    self.confirmedHidden = true
                    self.onHidden()
                }
            }
        }

        func stopObserving() {
            visibilityCheckGeneration += 1
            let center = NotificationCenter.default
            if let becameKeyObserver {
                center.removeObserver(becameKeyObserver)
            }
            if let resignedKeyObserver {
                center.removeObserver(resignedKeyObserver)
            }
            becameKeyObserver = nil
            resignedKeyObserver = nil
            observedWindow = nil
            confirmedHidden = false
        }
    }
}

private struct ForceQuitRequest: Identifiable {
    let id = UUID()
    let appName: String
    let requestedTargets: [RunningAppItem]
}

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var catalogScope: RuleCatalogScope = .running
    @State private var pendingForceQuitRequest: ForceQuitRequest?
    @FocusState private var isSearchFocused: Bool

    private enum AppSection {
        case ignored
        case unconfigured
        case autoHide
        case autoQuit
        case searchResults

        var titleKey: L10n.Key {
            switch self {
            case .ignored: return .menuSectionIgnore
            case .unconfigured: return .menuSectionUnconfigured
            case .autoHide: return .menuSectionAutomaticHide
            case .autoQuit: return .menuSectionAutomaticQuit
            case .searchResults: return .menuSectionSearchResults
            }
        }
    }

    private var scopedApps: [CatalogAppItem] {
        model.filteredCatalogApps.filter {
            AppRuleRegistry.isVisible(
                explicitAction: $0.explicitAction,
                isRunning: $0.isRunning,
                in: catalogScope
            )
        }
    }

    private var pinnedApps: [CatalogAppItem] {
        sortedRunningFirst(
            scopedApps.filter { AppRuleRegistry.section(for: $0.explicitAction) == .pin }
        )
    }

    private var unconfiguredApps: [CatalogAppItem] {
        sortedByName(
            scopedApps.filter {
                AppRuleRegistry.section(for: $0.explicitAction) == .unconfigured
            }
        )
    }

    private var autoHideApps: [CatalogAppItem] {
        sortedRunningFirst(
            scopedApps.filter {
                AppRuleRegistry.section(for: $0.explicitAction) == .autoHide
            }
        )
    }

    private var autoQuitApps: [CatalogAppItem] {
        sortedRunningFirst(
            scopedApps.filter {
                AppRuleRegistry.section(for: $0.explicitAction) == .autoQuit
            }
        )
    }

    private var normalizedSearchText: String {
        model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    private var searchResultApps: [CatalogAppItem] {
        sortedRunningFirst(scopedApps)
    }

    private var listIdentity: String {
        let scopeID = catalogScope == .running ? "running" : "all-rules"
        if isSearching {
            return "search-\(scopeID)-\(normalizedSearchText)"
        }
        return "catalog-\(scopeID)"
    }

    private var runningMenuSectionCount: Int {
        RuleDisplaySection.allCases.filter { section in
            model.catalogApps.contains { item in
                item.isRunning
                    && AppRuleRegistry.section(for: item.explicitAction) == section
            }
        }.count
    }

    private var menuHeight: CGFloat {
        CGFloat(MenuHeightPolicy.windowHeight(
            runningAppCount: model.runningAppCount,
            runningSectionCount: runningMenuSectionCount
        ))
    }

    private var pendingForceQuitLiveTargetCount: Int {
        guard let request = pendingForceQuitRequest else { return 0 }
        return model.liveForceQuitTargets(from: request.requestedTargets).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("QuitHide")
                        .font(.system(size: 20, weight: .semibold))
                    Text(model.localized(.menuSubtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(model.automationEnabled ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(model.localized(
                        model.automationEnabled
                            ? .menuAutomationEnabled
                            : .menuAutomationPaused
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Button {
                    model.automationEnabled.toggle()
                } label: {
                    Image(systemName: model.automationEnabled ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.automationEnabled ? Color.secondary : Color.orange)
                        .frame(width: 28, height: 28)
                        .background(
                            Color.primary.opacity(0.07),
                            in: Circle()
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .suppressFocusEffect()
                .help(model.localized(
                    model.automationEnabled
                        ? .menuAutomationPause
                        : .menuAutomationResume
                ))
                .accessibilityLabel(model.localized(
                    model.automationEnabled
                        ? .a11yAutomationPause
                        : .a11yAutomationResume
                ))
                .disabled(!model.rulesAreEditable)

                Button {
                    presentSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.localized(.menuSettings))
                .accessibilityLabel(model.localized(.a11ySettings))
            }
            .padding(16)

            HStack(spacing: 4) {
                scopeButton(
                    .running,
                    title: model.localized(.menuScopeRunning),
                    count: model.runningAppCount
                )
                scopeButton(
                    .allRules,
                    title: model.localized(.menuScopeAllRules),
                    count: model.explicitRuleCount
                )
                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button {
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(isSearching ? Color.accentColor : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: .command)
                    .help(model.localized(.menuSearchShortcut))
                    .accessibilityLabel(model.localized(.a11ySearchFocus))

                    TextField(
                        model.localized(
                            catalogScope == .running
                                ? .menuSearchRunningPlaceholder
                                : .menuSearchRulesPlaceholder
                        ),
                        text: $model.searchText
                    )
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .onExitCommand {
                            model.searchText = ""
                            isSearchFocused = false
                        }

                    if isSearching {
                        Button {
                            model.searchText = ""
                            isSearchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(model.localized(.menuSearchClear))
                        .accessibilityLabel(model.localized(.a11ySearchClear))
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 174, height: 28)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if let update = model.pendingUpdatePrompt {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.blue)
                        Text(model.localized(.menuUpdateAvailable, replacements: [
                            "version": update.version
                        ]))
                            .font(.callout.weight(.semibold))
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Button(model.localized(.menuUpdateDownload)) {
                            model.openAvailableUpdate(update)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(model.localized(.menuUpdateLater)) {
                            model.remindAboutUpdateLater(update)
                        }
                        .buttonStyle(.bordered)

                        Spacer(minLength: 0)

                        Button(model.localized(.menuUpdateSkip)) {
                            model.skipUpdateVersion(update)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    Color.blue.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.blue.opacity(0.20), lineWidth: 0.5)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            if scopedApps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)

                    Text(emptyStateTitle)
                        .foregroundStyle(.secondary)

                    if !isSearching,
                       catalogScope == .running,
                       model.explicitRuleCount > 0 {
                        Button(model.localized(.menuViewAllRules)) {
                            selectScope(.allRules)
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isSearching {
                            sectionHeader(.searchResults, count: searchResultApps.count)
                            appRows(searchResultApps)
                        } else {
                            if !pinnedApps.isEmpty {
                                sectionHeader(
                                    .ignored,
                                    count: pinnedApps.count,
                                    runningCount: catalogScope == .allRules
                                        ? pinnedApps.filter(\.isRunning).count
                                        : nil
                                )
                                appRows(pinnedApps)
                            }

                            if catalogScope == .running, !unconfiguredApps.isEmpty {
                                sectionHeader(.unconfigured, count: unconfiguredApps.count)
                                appRows(unconfiguredApps)
                            }

                            if !autoHideApps.isEmpty {
                                sectionHeader(
                                    .autoHide,
                                    count: autoHideApps.count,
                                    runningCount: catalogScope == .allRules
                                        ? autoHideApps.filter(\.isRunning).count
                                        : nil
                                )
                                appRows(autoHideApps)
                            }

                            if !autoQuitApps.isEmpty {
                                sectionHeader(
                                    .autoQuit,
                                    count: autoQuitApps.count,
                                    runningCount: catalogScope == .allRules
                                        ? autoQuitApps.filter(\.isRunning).count
                                        : nil
                                )
                                appRows(autoQuitApps)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
                    .padding(.bottom, 9)
                }
                .frame(minHeight: 0)
                .id(listIdentity)
            }

            if catalogScope == .running {
                Divider()

                VStack(spacing: 8) {
                    if !isSearching {
                        HStack {
                            Text(model.localized(.menuBatchHeading))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            Button {
                                model.performConfiguredApps(.hide)
                            } label: {
                                HStack(spacing: 6) {
                                    ActionSymbol(action: .hide)
                                    Text(model.localized(.menuBatchHide, replacements: [
                                        "count": String(model.immediateTargetCount(for: .hide))
                                    ]))
                                        .foregroundStyle(.primary)
                                }
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.regular)
                            .disabled(model.immediateTargetCount(for: .hide) == 0)
                            .help(model.immediateTargetHelp(for: .hide))

                            Button {
                                model.performConfiguredApps(.quit)
                            } label: {
                                HStack(spacing: 6) {
                                    ActionSymbol(action: .quit)
                                    Text(model.localized(.menuBatchQuit, replacements: [
                                        "count": String(model.immediateTargetCount(for: .quit))
                                    ]))
                                        .foregroundStyle(.primary)
                                }
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.regular)
                            .disabled(model.immediateTargetCount(for: .quit) == 0)
                            .help(model.immediateTargetHelp(for: .quit))
                        }
                    }

                    HStack(spacing: 8) {
                        Text(model.localized(.menuRowActionHint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Spacer(minLength: 8)

                        Button(model.localized(.menuQuitApp)) {
                            NSApp.terminate(nil)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(model.localized(.menuQuitApp))
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 410, height: menuHeight, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .environment(\.locale, model.effectiveLocale)
        .animation(.easeOut(duration: 0.18), value: model.pendingUpdatePrompt)
        .alert(item: $pendingForceQuitRequest) { request in
            Alert(
                title: Text(model.localized(.dialogForceQuitTitle, replacements: [
                    "name": request.appName
                ])),
                message: Text(model.localized(.dialogForceQuitMessage)),
                primaryButton: .destructive(Text(model.localized(.dialogForceQuitConfirm))) {
                    pendingForceQuitRequest = nil
                    model.forceQuitImmediately(
                        named: request.appName,
                        requestedTargets: request.requestedTargets
                    )
                },
                secondaryButton: .cancel(Text(model.localized(.dialogCancel))) {
                    pendingForceQuitRequest = nil
                }
            )
        }
        .onChange(of: pendingForceQuitLiveTargetCount) { targetCount in
            guard pendingForceQuitRequest != nil, targetCount == 0 else { return }
            pendingForceQuitRequest = nil
        }
        .background {
            MenuWindowLifecycleObserver(
                onPresented: {
                    resetForMenuPresentation(refreshApps: true)
                },
                onHidden: {
                    pendingForceQuitRequest = nil
                    resetForMenuPresentation(refreshApps: false)
                }
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            resetForMenuPresentation(refreshApps: true)
        }
        .onDisappear {
            pendingForceQuitRequest = nil
            resetForMenuPresentation(refreshApps: false)
        }
    }

    private func resetForMenuPresentation(refreshApps: Bool) {
        pendingForceQuitRequest = nil
        catalogScope = .running
        model.searchText = ""
        isSearchFocused = false
        model.refreshSystemLanguageIfNeeded()
        if refreshApps {
            model.refreshApps()
            model.prepareUpdatePromptForMenuPresentation()
        }
    }

    private var emptyStateTitle: String {
        if isSearching { return model.localized(.menuEmptySearch) }
        switch catalogScope {
        case .running:
            return model.localized(.menuEmptyRunning)
        case .allRules:
            return model.localized(.menuEmptyRules)
        }
    }

    private func scopeButton(
        _ scope: RuleCatalogScope,
        title: String,
        count: Int
    ) -> some View {
        let isSelected = catalogScope == scope
        return Button {
            selectScope(scope)
        } label: {
            Text(model.localized(.menuScopeCount, replacements: [
                "title": title,
                "count": String(count)
            ]))
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    isSelected ? Color.primary.opacity(0.09) : Color.clear,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.localized(.a11yScopeAppCount, replacements: [
            "title": title,
            "count": String(count)
        ]))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectScope(_ scope: RuleCatalogScope) {
        guard catalogScope != scope else { return }
        model.searchText = ""
        isSearchFocused = false
        withAnimation(.easeInOut(duration: 0.16)) {
            catalogScope = scope
        }
    }

    private func sectionHeader(
        _ section: AppSection,
        count: Int,
        runningCount: Int? = nil
    ) -> some View {
        let sectionTitle = model.localized(section.titleKey)
        return HStack(spacing: 5) {
            Text(model.localized(.menuSectionCount, replacements: [
                "section": sectionTitle,
                "count": String(count)
            ]))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if let runningCount {
                Text(model.localized(.menuSectionRunningCount, replacements: [
                    "count": String(runningCount)
                ]))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(height: 24)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func sortedRunningFirst(_ items: [CatalogAppItem]) -> [CatalogAppItem] {
        items.sorted { lhs, rhs in
            AppRuleRegistry.isAppOrderedBefore(
                lhsDisplayName: lhs.name,
                lhsBundleIdentifier: lhs.bundleIdentifier,
                lhsIsRunning: lhs.isRunning,
                rhsDisplayName: rhs.name,
                rhsBundleIdentifier: rhs.bundleIdentifier,
                rhsIsRunning: rhs.isRunning
            )
        }
    }

    private func sortedByName(_ items: [CatalogAppItem]) -> [CatalogAppItem] {
        items.sorted { lhs, rhs in
            AppRuleRegistry.isNameOrderedBefore(
                lhsDisplayName: lhs.name,
                lhsBundleIdentifier: lhs.bundleIdentifier,
                rhsDisplayName: rhs.name,
                rhsBundleIdentifier: rhs.bundleIdentifier
            )
        }
    }

    private func presentSettingsWindow() {
        openWindow(id: "settings")

        // Menu-bar-only apps do not automatically become active when SwiftUI
        // opens a window. Activate after the scene has created the NSWindow so
        // the settings window appears in front without making it permanently
        // float above every other app.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let settingsIdentifier = NSUserInterfaceItemIdentifier("QuitHide.Settings")
            let settingsWindow = NSApp.windows.first { $0.identifier == settingsIdentifier }
                ?? NSApp.windows.first { $0.styleMask.contains(.titled) }
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @ViewBuilder
    private func appRows(_ items: [CatalogAppItem]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            AppRow(item: item) { selectedItem in
                DispatchQueue.main.async {
                    let requestedTargets = model.liveForceQuitTargets(
                        from: selectedItem.runningInstances
                    )
                    guard !requestedTargets.isEmpty else { return }
                    pendingForceQuitRequest = ForceQuitRequest(
                        appName: selectedItem.name,
                        requestedTargets: requestedTargets
                    )
                }
            }
            if index < items.count - 1 {
                Divider()
                    .opacity(0.55)
                    .padding(.leading, 38)
            }
        }
    }
}

@main
struct QuitHideApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            Label("QuitHide", systemImage: "rectangle.on.rectangle.slash")
        }
        .menuBarExtraStyle(.window)
        .windowResizability(.contentSize)

        Window(model.localized(.settingsTitle), id: "settings") {
            SettingsSheet()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
