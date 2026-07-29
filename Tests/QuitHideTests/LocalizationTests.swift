import Foundation
import Testing
@testable import QuitHide

private enum LocalizationTestError: Error {
    case missingLocalization(String)
    case invalidStringsFile(String)
}

private func localization(
    _ preference: AppLanguagePreference,
    preferredLanguages: [String] = []
) -> AppLocalization {
    AppLocalization(
        preference: preference,
        resourceBundle: AppLocalization.defaultResourceBundle,
        preferredLanguages: preferredLanguages
    )
}

private func localizedKeys(for language: ResolvedAppLanguage) throws -> Set<String> {
    let resourceBundle = AppLocalization.defaultResourceBundle
    guard let resourceURL = resourceBundle.resourceURL else {
        throw LocalizationTestError.missingLocalization(language.rawValue)
    }

    let stringsURL = resourceURL
        .appendingPathComponent("\(language.rawValue).lproj", isDirectory: true)
        .appendingPathComponent("Localizable.strings", isDirectory: false)
    guard FileManager.default.fileExists(atPath: stringsURL.path) else {
        throw LocalizationTestError.missingLocalization(language.rawValue)
    }
    let data = try Data(contentsOf: stringsURL)
    var format = PropertyListSerialization.PropertyListFormat.openStep
    let propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: &format
    )
    guard let strings = propertyList as? [String: String] else {
        throw LocalizationTestError.invalidStringsFile(language.rawValue)
    }
    return Set(strings.keys)
}

@Suite("App language resolution")
struct AppLanguageResolutionTests {
    @Test("Manual language choices ignore system preferences")
    func manualPreferencesWin() {
        #expect(AppLocalization.resolve(
            .simplifiedChinese,
            preferredLanguages: ["en-US"]
        ) == .zhHans)
        #expect(AppLocalization.resolve(
            .english,
            preferredLanguages: ["zh-Hans-CN"]
        ) == .en)
    }

    @Test("System language recognizes regional language identifiers")
    func systemLanguageRecognizesRegionalIdentifiers() {
        #expect(AppLocalization.resolve(
            .system,
            preferredLanguages: ["zh-Hans-CN"]
        ) == .zhHans)
        #expect(AppLocalization.resolve(
            .system,
            preferredLanguages: ["zh-Hant-TW"]
        ) == .zhHans)
        #expect(AppLocalization.resolve(
            .system,
            preferredLanguages: ["en-GB"]
        ) == .en)
    }

    @Test("System language honors a supported secondary preference")
    func systemLanguageUsesSupportedSecondaryPreference() {
        #expect(AppLocalization.resolve(
            .system,
            preferredLanguages: ["fr-FR", "en-US"]
        ) == .en)
    }

    @Test("The product website follows the app language")
    func productWebsiteFollowsAppLanguage() {
        #expect(
            ResolvedAppLanguage.zhHans.productWebsiteURL.absoluteString ==
                "https://quithide.com/"
        )
        #expect(
            ResolvedAppLanguage.en.productWebsiteURL.absoluteString ==
                "https://quithide.com/en/"
        )
    }

    @Test("An unsupported system language falls back to Simplified Chinese")
    func unsupportedSystemLanguageUsesChineseFallback() {
        #expect(AppLocalization.resolve(
            .system,
            preferredLanguages: ["fr-FR"]
        ) == .zhHans)
        #expect(AppLocalization.resolve(
            .system,
            preferredLanguages: []
        ) == .zhHans)
    }

    @Test("An invalid persisted raw value can fall back to system")
    func invalidPersistedValueFallsBackToSystem() {
        let decoded = AppLanguagePreference(rawValue: "damaged-value")
        #expect(decoded == nil)
        #expect((decoded ?? .system) == .system)
    }
}

@Suite("Localization resources")
struct LocalizationResourceTests {
    @Test("Chinese and English contain every declared localization key")
    func languageKeySetsAreComplete() throws {
        let declaredKeys = Set(L10n.Key.allCases.map(\.rawValue))
        let chineseKeys = try localizedKeys(for: .zhHans)
        let englishKeys = try localizedKeys(for: .en)

        #expect(chineseKeys == declaredKeys)
        #expect(englishKeys == declaredKeys)
        #expect(chineseKeys == englishKeys)
    }

    @Test("Every declared key resolves in both languages")
    func everyKeyResolves() {
        let chinese = localization(.simplifiedChinese)
        let english = localization(.english)

        for key in L10n.Key.allCases {
            #expect(chinese.text(key) != key.rawValue)
            #expect(english.text(key) != key.rawValue)
        }
    }

    @Test("Critical interface translations are language-specific")
    func criticalTranslations() {
        let chinese = localization(.simplifiedChinese)
        let english = localization(.english)

        #expect(chinese.text(.languageSystem) == "跟随系统")
        #expect(english.text(.languageSystem) == "System")
        #expect(chinese.text(.languageSimplifiedChinese) == "简体中文")
        #expect(english.text(.languageSimplifiedChinese) == "简体中文")
        #expect(chinese.text(.ruleAutomaticHide) == "自动隐藏")
        #expect(english.text(.ruleAutomaticHide) == "Auto Hide")
        #expect(chinese.text(.settingsTitle) == "QuitHide 设置")
        #expect(english.text(.settingsTitle) == "QuitHide Settings")
        #expect(chinese.text(.settingsWebsite) == "QuitHide 官网")
        #expect(english.text(.settingsWebsite) == "QuitHide Website")
        #expect(chinese.text(.statusQuitNotCompleted) == "退出未完成")
        #expect(english.text(.statusQuitNotCompleted) == "Quit Not Completed")
        #expect(chinese.text(.statusInUse) == "使用中")
        #expect(english.text(.statusInUse) == "In Use")
        #expect(
            chinese.text(.statusStageManagerGroupProtected) ==
                "台前调度分组保护中"
        )
        #expect(
            !chinese.text(.warningLoginItemNotFound).contains("应用程序")
        )
        #expect(
            !english.text(.warningLoginItemNotFound).contains("Applications")
        )
        #expect(chinese.text(.appInstallationTitle) == "请先安装 QuitHide")
        #expect(english.text(.appInstallationTitle) == "Install QuitHide First")
    }

    @Test("Named tokens are replaced without changing unknown tokens")
    func namedTokenReplacement() {
        let chinese = localization(.simplifiedChinese)
        let english = localization(.english)

        #expect(chinese.text(
            .dialogForceQuitTitle,
            replacements: ["name": "备忘录"]
        ) == "强制退出“备忘录”？")
        #expect(english.text(
            .dialogForceQuitTitle,
            replacements: ["name": "Notes"]
        ) == "Force Quit “Notes”?")
        #expect(english.text(
            .statusInstancesErrorSummary,
            replacements: [
                "count": "3",
                "status": "Hide Failed",
                "errorCount": "2"
            ]
        ) == "Running instances: 3 · Hide Failed: 2")
        #expect(english.text(
            .statusActionRemaining,
            replacements: ["action": "Hide", "time": "19:58"]
        ) == "Hide in 19:58")
        #expect(english.text(.rowRuleHelp) == "Change the rule for {name}")
    }

    @Test("List formatting follows the selected app language")
    func listFormatting() {
        let values = ["Safari", "Mail", "Notes"]
        let chinese = localization(.simplifiedChinese)
        let english = localization(.english)

        #expect(chinese.list([]) == "")
        #expect(english.list(["Safari"]) == "Safari")
        #expect(chinese.list(values) == "Safari、Mail和Notes")
        #expect(english.list(values) == "Safari, Mail, and Notes")
    }

    @Test("Duration keys cover singular plural and mixed durations")
    func durationKeys() {
        let chinese = localization(.simplifiedChinese)
        let english = localization(.english)

        #expect(chinese.text(.durationMinute) == "1 分钟")
        #expect(chinese.text(
            .durationMinutes,
            replacements: ["count": "5"]
        ) == "5 分钟")
        #expect(chinese.text(
            .durationHoursMinutes,
            replacements: ["hours": "2", "minutes": "5"]
        ) == "2时5分")

        #expect(english.text(.durationMinute) == "1 min")
        #expect(english.text(
            .durationMinutes,
            replacements: ["count": "5"]
        ) == "5 min")
        #expect(english.text(
            .durationHoursMinutes,
            replacements: ["hours": "2", "minutes": "5"]
        ) == "2 hr 5 min")
    }
}
