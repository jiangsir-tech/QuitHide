import Foundation
import Testing
@testable import QuitHide

@Suite("Stored app rule registry")
struct AppRuleRegistryTests {
    @Test("Legacy rules migrate actions and independent timing")
    func migratesLegacyRules() {
        let registry = AppRuleRegistry.migrateLegacyRules(
            policies: [
                "com.example.keep": "never",
                "com.example.hide": "hide",
                "com.example.quit": "quit",
                "com.example.unset": "unset",
                "com.example.invalid": "surprise"
            ],
            policyIdleMinutes: ["com.example.hide": 7],
            legacyDefaultIdleMinutes: 20
        )

        #expect(registry.rules["com.example.keep"]?.action == .ignore)
        #expect(registry.rules["com.example.keep"]?.idleMinutes == nil)
        #expect(registry.rules["com.example.hide"]?.idleMinutes == 7)
        #expect(registry.rules["com.example.quit"]?.idleMinutes == 20)
        #expect(registry.rules["com.example.unset"] == nil)
        #expect(registry.rules["com.example.invalid"] == nil)
    }

    @Test("Explicit rules stay visible while unconfigured apps require a running instance")
    func buildsVisibleBundleIdentifierUnion() {
        let registry = StoredRuleRegistry(rules: [
            "com.example.offline": StoredAppRule(
                action: .hide,
                idleMinutes: 5,
                displayName: "Offline",
                lastKnownAppPath: nil
            )
        ])

        let visible = AppRuleRegistry.visibleBundleIdentifiers(
            runningBundleIdentifiers: ["com.example.running"],
            registry: registry
        )
        #expect(visible == Set(["com.example.offline", "com.example.running"]))
    }

    @Test("Registry survives a Codable round trip")
    func codableRoundTrip() throws {
        let original = StoredRuleRegistry(rules: [
            "com.example.app": StoredAppRule(
                action: .quit,
                idleMinutes: 12,
                displayName: "Example",
                lastKnownAppPath: "/Applications/Example.app"
            )
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredRuleRegistry.self, from: data)
        #expect(decoded == original)
    }

    @Test("Section order matches the main menu")
    func sectionOrder() {
        #expect(RuleDisplaySection.allCases == [.pin, .unconfigured, .autoHide, .autoQuit])
        #expect(AppRuleRegistry.section(for: .ignore) == .pin)
        #expect(AppRuleRegistry.section(for: .unset) == .unconfigured)
        #expect(AppRuleRegistry.section(for: .hide) == .autoHide)
        #expect(AppRuleRegistry.section(for: .quit) == .autoQuit)
    }

    @Test("Names use one natural Latin and Pinyin order")
    func sortsNamesByLatinAndPinyin() {
        let apps = [
            (name: "微信 2", bundleIdentifier: "com.example.wechat"),
            (name: "Arc", bundleIdentifier: "com.example.arc"),
            (name: "访达", bundleIdentifier: "com.example.finder"),
            (name: "ChatGPT", bundleIdentifier: "com.example.chatgpt"),
            (name: "App 10", bundleIdentifier: "com.example.app10"),
            (name: "App 2", bundleIdentifier: "com.example.app2")
        ]

        let sorted = apps.sorted { lhs, rhs in
            AppRuleRegistry.isNameOrderedBefore(
                lhsDisplayName: lhs.name,
                lhsBundleIdentifier: lhs.bundleIdentifier,
                rhsDisplayName: rhs.name,
                rhsBundleIdentifier: rhs.bundleIdentifier
            )
        }

        #expect(sorted.map { $0.name } == ["App 2", "App 10", "Arc", "ChatGPT", "访达", "微信 2"])
        #expect(AppRuleRegistry.nameSortKey(for: "访达") == "fang da")
        #expect(AppRuleRegistry.nameSortKey(for: "微信") == "wei xin")
    }

    @Test("Equal display names use bundle identifier as a stable tie breaker")
    func sameNameUsesBundleIdentifier() {
        #expect(AppRuleRegistry.isNameOrderedBefore(
            lhsDisplayName: "Example",
            lhsBundleIdentifier: "com.example.a",
            rhsDisplayName: "Example",
            rhsBundleIdentifier: "com.example.b"
        ))
        #expect(!AppRuleRegistry.isNameOrderedBefore(
            lhsDisplayName: "Example",
            lhsBundleIdentifier: "com.example.b",
            rhsDisplayName: "Example",
            rhsBundleIdentifier: "com.example.a"
        ))
    }

    @Test("Running apps sort before offline apps within a rule group")
    func runningAppsSortFirst() {
        #expect(AppRuleRegistry.isAppOrderedBefore(
            lhsDisplayName: "微信",
            lhsBundleIdentifier: "com.example.wechat",
            lhsIsRunning: true,
            rhsDisplayName: "Arc",
            rhsBundleIdentifier: "com.example.arc",
            rhsIsRunning: false
        ))
        #expect(!AppRuleRegistry.isAppOrderedBefore(
            lhsDisplayName: "Arc",
            lhsBundleIdentifier: "com.example.arc",
            lhsIsRunning: false,
            rhsDisplayName: "微信",
            rhsBundleIdentifier: "com.example.wechat",
            rhsIsRunning: true
        ))
        #expect(AppRuleRegistry.isAppOrderedBefore(
            lhsDisplayName: "Arc",
            lhsBundleIdentifier: "com.example.arc",
            lhsIsRunning: true,
            rhsDisplayName: "微信",
            rhsBundleIdentifier: "com.example.wechat",
            rhsIsRunning: true
        ))
    }

    @Test("Running scope includes every running app and excludes offline rules")
    func runningScopeVisibility() {
        for action in AutoAction.allCases {
            #expect(AppRuleRegistry.isVisible(
                explicitAction: action,
                isRunning: true,
                in: .running
            ))
        }
        #expect(!AppRuleRegistry.isVisible(
            explicitAction: .hide,
            isRunning: false,
            in: .running
        ))
    }

    @Test("All-rules scope includes explicit rules and excludes unconfigured apps")
    func allRulesScopeVisibility() {
        #expect(!AppRuleRegistry.isVisible(
            explicitAction: .unset,
            isRunning: true,
            in: .allRules
        ))
        for action in [AutoAction.ignore, .hide, .quit] {
            #expect(AppRuleRegistry.isVisible(
                explicitAction: action,
                isRunning: false,
                in: .allRules
            ))
        }
    }

    @Test("A newer registry schema is readable but not treated as current")
    func detectsUnsupportedSchema() throws {
        let newer = StoredRuleRegistry(
            schemaVersion: StoredRuleRegistry.currentSchemaVersion + 1,
            rules: [
                "com.example.future": StoredAppRule(
                    action: .hide,
                    idleMinutes: 5,
                    displayName: "Future",
                    lastKnownAppPath: nil
                )
            ]
        )
        let data = try JSONEncoder().encode(newer)

        guard case let .unsupported(schemaVersion) = AppRuleRegistry.decodeRegistry(
            from: data,
            fallbackIdleMinutes: 20
        ) else {
            Issue.record("A newer schema must not be treated as writable current data")
            return
        }
        #expect(schemaVersion == StoredRuleRegistry.currentSchemaVersion + 1)

        let futurePayloadWithUnknownAction = Data(
            """
            {"schemaVersion":2,"rules":{"com.example.future":{"action":"hibernate"}}}
            """.utf8
        )
        #expect(
            AppRuleRegistry.decodeRegistry(
                from: futurePayloadWithUnknownAction,
                fallbackIdleMinutes: 20
            ) == .unsupported(schemaVersion: 2)
        )
    }

    @Test("Registry normalization removes invalid entries and clamps timing")
    func normalizesRegistry() throws {
        let unnormalized = StoredRuleRegistry(rules: [
            "": StoredAppRule(action: .hide, idleMinutes: 5, displayName: "Empty", lastKnownAppPath: nil),
            "com.example.unset": StoredAppRule(action: .unset, idleMinutes: nil, displayName: "Unset", lastKnownAppPath: nil),
            "com.example.hide": StoredAppRule(action: .hide, idleMinutes: 0, displayName: "", lastKnownAppPath: nil)
        ])
        let data = try JSONEncoder().encode(unnormalized)

        guard case let .current(decoded) = AppRuleRegistry.decodeRegistry(
            from: data,
            fallbackIdleMinutes: 20
        ) else {
            Issue.record("A current registry should decode")
            return
        }
        #expect(decoded.rules[""] == nil)
        #expect(decoded.rules["com.example.unset"] == nil)
        #expect(decoded.rules["com.example.hide"]?.idleMinutes == 1)
        #expect(decoded.rules["com.example.hide"]?.displayName == "hide")
        #expect(AppRuleRegistry.decodeRegistry(from: Data("broken".utf8), fallbackIdleMinutes: 20) == .invalid)
    }

    @Test("Loading current explicit rules preserves their saved timing")
    func explicitRuleTimingIsNotMigrated() throws {
        let stored = StoredRuleRegistry(rules: [
            "com.example.hide": StoredAppRule(
                action: .hide,
                idleMinutes: 5,
                displayName: "Hide",
                lastKnownAppPath: nil
            ),
            "com.example.quit": StoredAppRule(
                action: .quit,
                idleMinutes: 20,
                displayName: "Quit",
                lastKnownAppPath: nil
            )
        ])
        let data = try JSONEncoder().encode(stored)

        guard case let .current(decoded) = AppRuleRegistry.decodeRegistry(
            from: data,
            fallbackIdleMinutes: AutomationDefaults.defaultHideMinutes
        ) else {
            Issue.record("A current registry should decode without migrating explicit timing")
            return
        }
        #expect(decoded.rules["com.example.hide"]?.idleMinutes == 5)
        #expect(decoded.rules["com.example.quit"]?.idleMinutes == 20)
    }

    @Test("Entering an automated action uses that action's default timing")
    func actionChangesUseTargetDefaults() {
        let hidden = AppRuleRegistry.updatedRule(
            existingRule: nil,
            action: .hide,
            defaultHideMinutes: AutomationDefaults.defaultHideMinutes,
            defaultQuitMinutes: AutomationDefaults.defaultQuitMinutes,
            displayName: "Example",
            lastKnownAppPath: nil
        )
        let quitting = AppRuleRegistry.updatedRule(
            existingRule: nil,
            action: .quit,
            defaultHideMinutes: AutomationDefaults.defaultHideMinutes,
            defaultQuitMinutes: AutomationDefaults.defaultQuitMinutes,
            displayName: "Example",
            lastKnownAppPath: nil
        )
        let switchedToQuit = AppRuleRegistry.updatedRule(
            existingRule: StoredAppRule(
                action: .hide,
                idleMinutes: 7,
                displayName: "Example",
                lastKnownAppPath: nil
            ),
            action: .quit,
            defaultHideMinutes: AutomationDefaults.defaultHideMinutes,
            defaultQuitMinutes: AutomationDefaults.defaultQuitMinutes,
            displayName: "Example",
            lastKnownAppPath: nil
        )
        let switchedToHide = AppRuleRegistry.updatedRule(
            existingRule: StoredAppRule(
                action: .quit,
                idleMinutes: 240,
                displayName: "Example",
                lastKnownAppPath: nil
            ),
            action: .hide,
            defaultHideMinutes: AutomationDefaults.defaultHideMinutes,
            defaultQuitMinutes: AutomationDefaults.defaultQuitMinutes,
            displayName: "Example",
            lastKnownAppPath: nil
        )
        let restoredFromIgnore = AppRuleRegistry.updatedRule(
            existingRule: StoredAppRule(
                action: .ignore,
                idleMinutes: 7,
                displayName: "Example",
                lastKnownAppPath: nil
            ),
            action: .hide,
            defaultHideMinutes: AutomationDefaults.defaultHideMinutes,
            defaultQuitMinutes: AutomationDefaults.defaultQuitMinutes,
            displayName: "Example",
            lastKnownAppPath: nil
        )

        #expect(hidden?.idleMinutes == 30)
        #expect(quitting?.idleMinutes == 120)
        #expect(switchedToQuit?.idleMinutes == 120)
        #expect(switchedToHide?.idleMinutes == 30)
        #expect(restoredFromIgnore?.idleMinutes == 30)
    }

    @Test("Keeping the same automated action preserves its explicit timing")
    func sameActionPreservesTiming() {
        let hidden = StoredAppRule(
            action: .hide,
            idleMinutes: 7,
            displayName: "Example",
            lastKnownAppPath: "/Applications/Example.app"
        )
        let quitting = StoredAppRule(
            action: .quit,
            idleMinutes: 240,
            displayName: "Example",
            lastKnownAppPath: "/Applications/Example.app"
        )
        let hiddenAgain = AppRuleRegistry.updatedRule(
            existingRule: hidden,
            action: .hide,
            defaultHideMinutes: AutomationDefaults.defaultHideMinutes,
            defaultQuitMinutes: AutomationDefaults.defaultQuitMinutes,
            displayName: "Example",
            lastKnownAppPath: nil
        )
        let quittingAgain = AppRuleRegistry.updatedRule(
            existingRule: quitting,
            action: .quit,
            defaultHideMinutes: AutomationDefaults.defaultHideMinutes,
            defaultQuitMinutes: AutomationDefaults.defaultQuitMinutes,
            displayName: "Example",
            lastKnownAppPath: nil
        )

        #expect(hiddenAgain?.idleMinutes == 7)
        #expect(quittingAgain?.idleMinutes == 240)
    }

    @Test("Catalog keeps offline rules and merges multiple running instances")
    func buildsCatalogDescriptors() {
        let registry = StoredRuleRegistry(rules: [
            "com.example.pin": StoredAppRule(action: .ignore, idleMinutes: nil, displayName: "Pin", lastKnownAppPath: nil),
            "com.example.hide": StoredAppRule(action: .hide, idleMinutes: 5, displayName: "Hide", lastKnownAppPath: nil),
            "com.example.offlinehide": StoredAppRule(action: .hide, idleMinutes: 8, displayName: "Offline Hide", lastKnownAppPath: nil),
            "com.example.quit": StoredAppRule(action: .quit, idleMinutes: 5, displayName: "Quit", lastKnownAppPath: nil)
        ])
        let descriptors = AppRuleRegistry.catalogDescriptors(
            registry: registry,
            runningSnapshots: [
                RunningRuleSnapshot(bundleIdentifier: "com.example.running", runtimeIdentifier: "running#1"),
                RunningRuleSnapshot(bundleIdentifier: "com.example.hide", runtimeIdentifier: "hide#2"),
                RunningRuleSnapshot(bundleIdentifier: "com.example.hide", runtimeIdentifier: "hide#1")
            ]
        )
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.bundleIdentifier, $0) })

        #expect(byID["com.example.pin"]?.section == .pin)
        #expect(byID["com.example.pin"]?.isRunning == false)
        #expect(byID["com.example.running"]?.section == .unconfigured)
        #expect(byID["com.example.hide"]?.runtimeIdentifiers == ["hide#1", "hide#2"])
        #expect(byID["com.example.offlinehide"]?.section == .autoHide)
        #expect(byID["com.example.offlinehide"]?.isRunning == false)
        #expect(byID["com.example.quit"]?.section == .autoQuit)
    }

    @Test("Immediate targets include only eligible running instances")
    func selectsImmediateTargets() {
        let registry = StoredRuleRegistry(rules: [
            "com.example.hide": StoredAppRule(action: .hide, idleMinutes: 5, displayName: "Hide", lastKnownAppPath: nil),
            "com.example.quit": StoredAppRule(action: .quit, idleMinutes: 5, displayName: "Quit", lastKnownAppPath: nil)
        ])
        let candidates = [
            ImmediateActionSnapshot(runtimeIdentifier: "hide#1", bundleIdentifier: "com.example.hide", isHidden: false, isAlreadyHandled: false),
            ImmediateActionSnapshot(runtimeIdentifier: "hide#2", bundleIdentifier: "com.example.hide", isHidden: false, isAlreadyHandled: false),
            ImmediateActionSnapshot(runtimeIdentifier: "hide#3", bundleIdentifier: "com.example.hide", isHidden: true, isAlreadyHandled: false),
            ImmediateActionSnapshot(runtimeIdentifier: "quit#1", bundleIdentifier: "com.example.quit", isHidden: false, isAlreadyHandled: false),
            ImmediateActionSnapshot(runtimeIdentifier: "default#1", bundleIdentifier: "com.example.default", isHidden: false, isAlreadyHandled: false),
            ImmediateActionSnapshot(runtimeIdentifier: "handled#1", bundleIdentifier: "com.example.hide", isHidden: false, isAlreadyHandled: true)
        ]

        #expect(AppRuleRegistry.immediateTargetRuntimeIdentifiers(
            action: .hide,
            candidates: candidates,
            registry: registry,
            defaultHideEnabled: true
        ) == Set(["hide#1", "hide#2", "default#1"]))
        #expect(AppRuleRegistry.immediateTargetRuntimeIdentifiers(
            action: .quit,
            candidates: candidates,
            registry: registry,
            defaultHideEnabled: true
        ) == Set(["quit#1"]))
        #expect(AppRuleRegistry.immediateTargetRuntimeIdentifiers(
            action: .hide,
            candidates: candidates,
            registry: registry,
            defaultHideEnabled: false
        ) == Set(["hide#1", "hide#2"]))
    }

    @Test("Row actions use the visible runtime snapshot and bypass rule state")
    func selectsRowImmediateTargets() {
        let candidates = [
            ImmediateActionSnapshot(runtimeIdentifier: "target#1", bundleIdentifier: "com.example.target", isHidden: false, isAlreadyHandled: true),
            ImmediateActionSnapshot(runtimeIdentifier: "target#2", bundleIdentifier: "com.example.target", isHidden: true, isAlreadyHandled: false),
            ImmediateActionSnapshot(runtimeIdentifier: "target#3", bundleIdentifier: "com.example.target", isHidden: false, isAlreadyHandled: false),
            ImmediateActionSnapshot(runtimeIdentifier: "other#1", bundleIdentifier: "com.example.other", isHidden: false, isAlreadyHandled: false)
        ]
        let snapshotRuntimeIdentifiers: Set<String> = ["target#1", "target#2"]

        #expect(AppRuleRegistry.rowImmediateTargetRuntimeIdentifiers(
            action: .hide,
            bundleIdentifier: "com.example.target",
            snapshotRuntimeIdentifiers: snapshotRuntimeIdentifiers,
            candidates: candidates
        ) == Set(["target#1"]))
        #expect(AppRuleRegistry.rowImmediateTargetRuntimeIdentifiers(
            action: .quit,
            bundleIdentifier: "com.example.target",
            snapshotRuntimeIdentifiers: snapshotRuntimeIdentifiers,
            candidates: candidates
        ) == Set(["target#1", "target#2"]))
        #expect(AppRuleRegistry.rowImmediateTargetRuntimeIdentifiers(
            action: .ignore,
            bundleIdentifier: "com.example.target",
            snapshotRuntimeIdentifiers: snapshotRuntimeIdentifiers,
            candidates: candidates
        ).isEmpty)
    }
}
