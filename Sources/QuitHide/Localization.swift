import Foundation

enum AppLanguagePreference: String, CaseIterable, Identifiable, Codable {
    case system
    case simplifiedChinese
    case english

    var id: String { rawValue }

    var labelKey: L10n.Key {
        switch self {
        case .system: return .languageSystem
        case .simplifiedChinese: return .languageSimplifiedChinese
        case .english: return .languageEnglish
        }
    }
}

enum ResolvedAppLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    fileprivate init?(localizationIdentifier: String) {
        let normalized = localizationIdentifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if normalized == "en" || normalized.hasPrefix("en-") {
            self = .en
        } else if normalized == "zh" || normalized.hasPrefix("zh-") {
            self = .zhHans
        } else {
            return nil
        }
    }
}

enum L10n {
    enum Key: String, CaseIterable {
        case languagePickerLabel = "language.picker.label"
        case languageSystem = "language.system"
        case languageSimplifiedChinese = "language.simplified_chinese"
        case languageEnglish = "language.english"

        case actionUseDefault = "action.use_default"
        case actionHide = "action.hide"
        case actionQuit = "action.quit"
        case actionIgnore = "action.ignore"
        case ruleIgnore = "rule.ignore"
        case ruleUnconfigured = "rule.unconfigured"
        case ruleAutomaticHide = "rule.automatic_hide"
        case ruleAutomaticQuit = "rule.automatic_quit"

        case warningRuleRegistryNewerReadOnly = "warning.rule_registry.newer_read_only"
        case warningRuleRegistrySaveFailed = "warning.rule_registry.save_failed"
        case warningLoginItemFailed = "warning.login_item.failed"
        case warningLoginItemRequiresApproval = "warning.login_item.requires_approval"
        case warningLoginItemNotFound = "warning.login_item.not_found"

        case appInstallationTitle = "app_installation.title"
        case appInstallationReasonAppTranslocation = "app_installation.reason.app_translocation"
        case appInstallationReasonVolume = "app_installation.reason.volume"
        case appInstallationReasonDownloads = "app_installation.reason.downloads"
        case appInstallationReasonOtherLocation = "app_installation.reason.other_location"
        case appInstallationRevealAndQuit = "app_installation.action.reveal_and_quit"
        case appInstallationOpenApplicationsAndQuit = "app_installation.action.open_applications_and_quit"
        case appInstallationContinue = "app_installation.action.continue"

        case menuSubtitle = "menu.subtitle"
        case menuAutomationEnabled = "menu.automation.enabled"
        case menuAutomationPaused = "menu.automation.paused"
        case menuAutomationPause = "menu.automation.pause"
        case menuAutomationResume = "menu.automation.resume"
        case menuSettings = "menu.settings"
        case menuScopeRunning = "menu.scope.running"
        case menuScopeAllRules = "menu.scope.all_rules"
        case menuScopeCount = "menu.scope.count"
        case menuSearchShortcut = "menu.search.shortcut"
        case menuSearchFocus = "menu.search.focus"
        case menuSearchRunningPlaceholder = "menu.search.running_placeholder"
        case menuSearchRulesPlaceholder = "menu.search.rules_placeholder"
        case menuSearchClear = "menu.search.clear"
        case menuSectionIgnore = "menu.section.ignore"
        case menuSectionUnconfigured = "menu.section.unconfigured"
        case menuSectionAutomaticHide = "menu.section.automatic_hide"
        case menuSectionAutomaticQuit = "menu.section.automatic_quit"
        case menuSectionSearchResults = "menu.section.search_results"
        case menuSectionCount = "menu.section.count"
        case menuSectionRunningCount = "menu.section.running_count"
        case menuUpdateAvailable = "menu.update.available"
        case menuUpdateDownload = "menu.update.download"
        case menuUpdateLater = "menu.update.later"
        case menuUpdateSkip = "menu.update.skip"
        case menuEmptySearch = "menu.empty.search"
        case menuEmptyRunning = "menu.empty.running"
        case menuEmptyRules = "menu.empty.rules"
        case menuViewAllRules = "menu.view_all_rules"
        case menuBatchHeading = "menu.batch.heading"
        case menuBatchHide = "menu.batch.hide"
        case menuBatchQuit = "menu.batch.quit"
        case menuRowActionHint = "menu.row_action_hint"
        case menuQuitApp = "menu.quit_app"

        case rowRuleLabel = "row.rule.label"
        case rowRuleHelp = "row.rule.help"
        case rowDelayInherited = "row.delay.inherited"
        case rowDelayNotSet = "row.delay.not_set"
        case rowDelayLabel = "row.delay.label"
        case rowDelayHelp = "row.delay.help"
        case rowStatusNotRunning = "row.status.not_running"
        case rowStatusAppNotFound = "row.status.app_not_found"

        case contextActionImmediate = "context.action.immediate"
        case contextHideAlreadyHidden = "context.hide.already_hidden"
        case contextHideAllHidden = "context.hide.all_hidden"
        case contextHideVisibleInstances = "context.hide.visible_instances"
        case contextQuitAllInstances = "context.quit.all_instances"
        case contextForceQuit = "context.force_quit"
        case contextForceQuitAllInstances = "context.force_quit.all_instances"

        case statusForceQuitInProgress = "status.force_quit.in_progress"
        case statusForceQuitFailed = "status.force_quit.failed"
        case statusForceQuitFailedHelp = "status.force_quit.failed_help"
        case statusQuitInProgress = "status.quit.in_progress"
        case statusQuitWaitingHelp = "status.quit.waiting_help"
        case statusQuitNotCompleted = "status.quit.not_completed"
        case statusQuitNotCompletedHelp = "status.quit.not_completed_help"
        case statusHideHidden = "status.hide.hidden"
        case statusHideInProgress = "status.hide.in_progress"
        case statusQuitRequestedWaiting = "status.quit.requested_waiting"
        case statusActionFailedRetry = "status.action.failed_retry"
        case statusActionFailedManual = "status.action.failed_manual"
        case statusActive = "status.active"
        case statusStageManagerGroupProtected = "status.stage_manager.group_protected"
        case statusStageManagerUnavailablePaused = "status.stage_manager.unavailable_paused"
        case statusScreenVisibilityProtected = "status.screen_visibility.protected"
        case statusWindowProtectionUnavailablePaused = "status.window_protection.unavailable_paused"
        case statusWaitingForBackground = "status.waiting_for_background"
        case statusActionAboutToRun = "status.action.about_to_run"
        case statusHideHiddenRemaining = "status.hide.hidden_remaining"
        case statusAutomationPausedRemaining = "status.automation.paused_remaining"
        case statusHideFailedWillQuit = "status.hide.failed_will_quit"
        case statusActionRemaining = "status.action.remaining"
        case statusInstancesErrorSummary = "status.instances.error_summary"
        case statusInstancesQuitNotCompleted = "status.instances.quit_not_completed"
        case statusInstancesQuitNotCompletedHelp = "status.instances.quit_not_completed_help"
        case statusInstancesSameStatus = "status.instances.same_status"
        case statusInstancesSeparateTimers = "status.instances.separate_timers"
        case statusInstancesPausedSeparateTimers = "status.instances.paused_separate_timers"

        case helpRuleRegistryBatchUnavailable = "help.rule_registry.batch_unavailable"
        case helpImmediateNoTargets = "help.immediate.no_targets"
        case helpImmediateTargets = "help.immediate.targets"

        case settingsTitle = "settings.title"
        case settingsLoginOpen = "settings.login.open"
        case settingsLoginLaunch = "settings.login.launch"
        case settingsAdditionalRulesTitle = "settings.additional_rules.title"
        case settingsDefaultHideEnabled = "settings.default_hide.enabled"
        case settingsDefaultHideDelay = "settings.default_hide.delay"
        case settingsDefaultHideHelp = "settings.default_hide.help"
        case settingsPreQuitHideEnabled = "settings.pre_quit_hide.enabled"
        case settingsPreQuitHideDelay = "settings.pre_quit_hide.delay"
        case settingsPreQuitHideHelp = "settings.pre_quit_hide.help"
        case settingsStageManagerProtectionEnabled = "settings.stage_manager_protection.enabled"
        case settingsStageManagerProtectionHelp = "settings.stage_manager_protection.help"
        case settingsStageManagerProtectionChecking = "settings.stage_manager_protection.checking"
        case settingsStageManagerProtectionDormant = "settings.stage_manager_protection.dormant"
        case settingsStageManagerProtectionActive = "settings.stage_manager_protection.active"
        case settingsStageManagerProtectionActiveCount = "settings.stage_manager_protection.active_count"
        case settingsStageManagerProtectionPermissionRequired = "settings.stage_manager_protection.permission_required"
        case settingsStageManagerProtectionUnavailable = "settings.stage_manager_protection.unavailable"
        case settingsStageManagerProtectionGrantPermission = "settings.stage_manager_protection.grant_permission"
        case settingsScreenVisibilityProtectionEnabled = "settings.screen_visibility_protection.enabled"
        case settingsScreenVisibilityProtectionHelp = "settings.screen_visibility_protection.help"
        case settingsScreenVisibilityProtectionChecking = "settings.screen_visibility_protection.checking"
        case settingsScreenVisibilityProtectionDormant = "settings.screen_visibility_protection.dormant"
        case settingsScreenVisibilityProtectionActive = "settings.screen_visibility_protection.active"
        case settingsScreenVisibilityProtectionActiveCount = "settings.screen_visibility_protection.active_count"
        case settingsScreenVisibilityProtectionUnavailable = "settings.screen_visibility_protection.unavailable"
        case settingsAboutTitle = "settings.about.title"
        case settingsAboutAuthor = "settings.about.author"
        case settingsAboutFeedback = "settings.about.feedback"
        case settingsAboutVersion = "settings.about.version"
        case settingsAboutNotarized = "settings.about.notarized"
        case settingsUpdateAutomatic = "settings.update.automatic"
        case settingsGitHubProject = "settings.github_project"

        case updateActionDownload = "update.action.download"
        case updateActionCheck = "update.action.check"
        case updateStatusChecking = "update.status.checking"
        case updateStatusUpToDate = "update.status.up_to_date"
        case updateStatusAvailable = "update.status.available"
        case updateStatusFailed = "update.status.failed"
        case updatePromptAvailable = "update.prompt.available"
        case updatePromptLater = "update.prompt.later"
        case updatePromptSkip = "update.prompt.skip"

        case dialogForceQuitTitle = "dialog.force_quit.title"
        case dialogForceQuitMessage = "dialog.force_quit.message"
        case dialogForceQuitConfirm = "dialog.force_quit.confirm"
        case dialogCancel = "dialog.cancel"

        case errorUpdateInvalidResponse = "error.update.invalid_response"
        case errorUpdateNoRelease = "error.update.no_release"

        case a11ySettings = "a11y.settings"
        case a11yAutomationPause = "a11y.automation.pause"
        case a11yAutomationResume = "a11y.automation.resume"
        case a11ySearchFocus = "a11y.search.focus"
        case a11ySearchClear = "a11y.search.clear"
        case a11yScopeAppCount = "a11y.scope.app_count"
        case a11yRuleForApp = "a11y.rule.for_app"
        case a11yDelayForApp = "a11y.delay.for_app"
        case a11yDelayNotSet = "a11y.delay.not_set"
        case a11yActionForApp = "a11y.action.for_app"

        case durationMinute = "duration.minute"
        case durationMinutes = "duration.minutes"
        case durationHour = "duration.hour"
        case durationHours = "duration.hours"
        case durationDay = "duration.day"
        case durationDays = "duration.days"
        case durationHoursMinutes = "duration.hours_minutes"
    }
}

struct AppLocalization {
    static let fallbackLanguage: ResolvedAppLanguage = .zhHans

    #if QUITHIDE_APP_BUNDLE
    static let defaultResourceBundle = Bundle.main
    #else
    static let defaultResourceBundle = Bundle.module
    #endif

    let preference: AppLanguagePreference
    let resolvedLanguage: ResolvedAppLanguage

    private let resourceBundle: Bundle
    private let localizedBundle: Bundle
    private let fallbackBundle: Bundle

    init(
        preference: AppLanguagePreference = .system,
        resourceBundle: Bundle = AppLocalization.defaultResourceBundle,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.preference = preference
        self.resourceBundle = resourceBundle
        resolvedLanguage = Self.resolve(
            preference,
            preferredLanguages: preferredLanguages
        )
        localizedBundle = Self.languageBundle(
            for: resolvedLanguage,
            in: resourceBundle
        ) ?? resourceBundle
        fallbackBundle = Self.languageBundle(
            for: Self.fallbackLanguage,
            in: resourceBundle
        ) ?? resourceBundle
    }

    static func resolve(
        _ preference: AppLanguagePreference,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> ResolvedAppLanguage {
        switch preference {
        case .simplifiedChinese:
            return .zhHans
        case .english:
            return .en
        case .system:
            return preferredLanguages
                .compactMap(ResolvedAppLanguage.init(localizationIdentifier:))
                .first ?? fallbackLanguage
        }
    }

    func text(
        _ key: L10n.Key,
        replacements: [String: String] = [:]
    ) -> String {
        let template = localizedTemplate(for: key)
        return Self.replacingNamedTokens(in: template, with: replacements)
    }

    func list(_ values: [String]) -> String {
        guard !values.isEmpty else { return "" }
        let formatter = ListFormatter()
        formatter.locale = resolvedLanguage.locale
        return formatter.string(from: values) ?? values.joined(
            separator: resolvedLanguage == .zhHans ? "、" : ", "
        )
    }

    private func localizedTemplate(for key: L10n.Key) -> String {
        let localized = localizedBundle.localizedString(
            forKey: key.rawValue,
            value: nil,
            table: "Localizable"
        )
        if localized != key.rawValue || resolvedLanguage == Self.fallbackLanguage {
            return localized
        }
        return fallbackBundle.localizedString(
            forKey: key.rawValue,
            value: key.rawValue,
            table: "Localizable"
        )
    }

    private static func languageBundle(
        for language: ResolvedAppLanguage,
        in resourceBundle: Bundle
    ) -> Bundle? {
        // Bundle.path(forResource:ofType:) may apply the host's preferred
        // localization before resolving an .lproj directory. On an English
        // system that can return en.lproj even when zh-Hans was requested.
        // Build the locale directory URL explicitly so a manual language
        // choice always wins over the host environment.
        guard let resourceURL = resourceBundle.resourceURL else { return nil }
        let languageURL = resourceURL.appendingPathComponent(
            "\(language.rawValue).lproj",
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: languageURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return Bundle(url: languageURL)
    }

    private static func replacingNamedTokens(
        in template: String,
        with replacements: [String: String]
    ) -> String {
        guard !replacements.isEmpty else { return template }

        var result = ""
        var cursor = template.startIndex
        while let openingBrace = template[cursor...].firstIndex(of: "{") {
            result.append(contentsOf: template[cursor..<openingBrace])
            guard let closingBrace = template[openingBrace...].firstIndex(of: "}") else {
                result.append(contentsOf: template[openingBrace...])
                return result
            }

            let tokenStart = template.index(after: openingBrace)
            let token = String(template[tokenStart..<closingBrace])
            if let replacement = replacements[token] {
                result.append(replacement)
            } else {
                result.append(contentsOf: template[openingBrace...closingBrace])
            }
            cursor = template.index(after: closingBrace)
        }
        result.append(contentsOf: template[cursor...])
        return result
    }
}
