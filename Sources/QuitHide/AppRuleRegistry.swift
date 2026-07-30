import Foundation

struct StoredRuleRegistry: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var rules: [String: StoredAppRule] = [:]
}

struct StoredAppRule: Codable, Equatable {
    var action: AutoAction
    var idleMinutes: Int?
    var displayName: String
    var lastKnownAppPath: String?
}

enum RuleRegistryDecodeResult: Equatable {
    case current(StoredRuleRegistry)
    case unsupported(schemaVersion: Int)
    case invalid
}

struct RunningRuleSnapshot: Equatable {
    let bundleIdentifier: String
    let runtimeIdentifier: String
}

struct RuleCatalogDescriptor: Equatable {
    let bundleIdentifier: String
    let explicitAction: AutoAction
    let runtimeIdentifiers: [String]

    var isRunning: Bool { !runtimeIdentifiers.isEmpty }
    var section: RuleDisplaySection { AppRuleRegistry.section(for: explicitAction) }
}

struct ImmediateActionSnapshot: Equatable {
    let runtimeIdentifier: String
    let bundleIdentifier: String
    let isHidden: Bool
    let isAlreadyHandled: Bool
}

enum RuleDisplaySection: Int, CaseIterable, Codable {
    case pin
    case unconfigured
    case autoHide
    case autoQuit
}

enum RuleCatalogScope: CaseIterable, Equatable {
    case running
    case allRules
}

enum AppRuleRegistry {
    static func nameSortKey(for displayName: String) -> String {
        let latinName = displayName.applyingTransform(.toLatin, reverse: false) ?? displayName
        let foldedName = latinName.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return foldedName
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func isNameOrderedBefore(
        lhsDisplayName: String,
        lhsBundleIdentifier: String,
        rhsDisplayName: String,
        rhsBundleIdentifier: String
    ) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let keyComparison = nameSortKey(for: lhsDisplayName).compare(
            nameSortKey(for: rhsDisplayName),
            options: [.caseInsensitive, .numeric],
            range: nil,
            locale: locale
        )
        if keyComparison != .orderedSame {
            return keyComparison == .orderedAscending
        }

        let nameComparison = lhsDisplayName.compare(
            rhsDisplayName,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric],
            range: nil,
            locale: locale
        )
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhsBundleIdentifier < rhsBundleIdentifier
    }

    static func isAppOrderedBefore(
        lhsDisplayName: String,
        lhsBundleIdentifier: String,
        lhsIsRunning: Bool,
        rhsDisplayName: String,
        rhsBundleIdentifier: String,
        rhsIsRunning: Bool
    ) -> Bool {
        if lhsIsRunning != rhsIsRunning {
            return lhsIsRunning
        }
        return isNameOrderedBefore(
            lhsDisplayName: lhsDisplayName,
            lhsBundleIdentifier: lhsBundleIdentifier,
            rhsDisplayName: rhsDisplayName,
            rhsBundleIdentifier: rhsBundleIdentifier
        )
    }

    static func isVisible(
        explicitAction: AutoAction,
        isRunning: Bool,
        in scope: RuleCatalogScope
    ) -> Bool {
        switch scope {
        case .running:
            return isRunning
        case .allRules:
            return explicitAction != .unset
        }
    }

    static func decodeRegistry(
        from data: Data,
        fallbackIdleMinutes: Int
    ) -> RuleRegistryDecodeResult {
        struct SchemaEnvelope: Decodable {
            let schemaVersion: Int
        }

        guard let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data) else {
            return .invalid
        }
        guard envelope.schemaVersion == StoredRuleRegistry.currentSchemaVersion else {
            return .unsupported(schemaVersion: envelope.schemaVersion)
        }
        guard let decoded = try? JSONDecoder().decode(StoredRuleRegistry.self, from: data) else {
            return .invalid
        }
        let normalized = normalizedRegistry(decoded, fallbackIdleMinutes: fallbackIdleMinutes)
        return .current(normalized)
    }

    static func normalizedRegistry(
        _ registry: StoredRuleRegistry,
        fallbackIdleMinutes: Int
    ) -> StoredRuleRegistry {
        var normalized = registry
        normalized.rules = registry.rules.reduce(into: [:]) { result, entry in
            let bundleIdentifier = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            var rule = entry.value
            guard !bundleIdentifier.isEmpty, rule.action != .unset else { return }

            if rule.displayName.isEmpty {
                rule.displayName = fallbackDisplayName(for: bundleIdentifier)
            }
            if let storedMinutes = rule.idleMinutes {
                rule.idleMinutes = max(storedMinutes, 1)
            } else if rule.action.isAutomated {
                rule.idleMinutes = max(fallbackIdleMinutes, 1)
            }
            result[bundleIdentifier] = rule
        }
        return normalized
    }

    static func updatedRule(
        existingRule: StoredAppRule?,
        action: AutoAction,
        defaultHideMinutes: Int,
        defaultQuitMinutes: Int,
        displayName: String,
        lastKnownAppPath: String?
    ) -> StoredAppRule? {
        guard action != .unset else { return nil }
        let preservedMinutes = existingRule?.idleMinutes.map { max($0, 1) }
        let targetDefaultMinutes: Int?
        switch action {
        case .hide:
            targetDefaultMinutes = max(defaultHideMinutes, 1)
        case .quit:
            targetDefaultMinutes = max(defaultQuitMinutes, 1)
        case .unset, .ignore:
            targetDefaultMinutes = nil
        }
        let idleMinutes: Int?
        if action.isAutomated {
            idleMinutes = existingRule?.action == action
                ? preservedMinutes ?? targetDefaultMinutes
                : targetDefaultMinutes
        } else {
            idleMinutes = preservedMinutes
        }
        return StoredAppRule(
            action: action,
            idleMinutes: idleMinutes,
            displayName: displayName.isEmpty
                ? existingRule?.displayName ?? "App"
                : displayName,
            lastKnownAppPath: lastKnownAppPath ?? existingRule?.lastKnownAppPath
        )
    }

    static func section(for explicitAction: AutoAction) -> RuleDisplaySection {
        switch explicitAction {
        case .ignore: return .pin
        case .unset: return .unconfigured
        case .hide: return .autoHide
        case .quit: return .autoQuit
        }
    }

    static func visibleBundleIdentifiers(
        runningBundleIdentifiers: some Sequence<String>,
        registry: StoredRuleRegistry
    ) -> Set<String> {
        Set(runningBundleIdentifiers).union(registry.rules.keys)
    }

    static func catalogDescriptors(
        registry: StoredRuleRegistry,
        runningSnapshots: [RunningRuleSnapshot]
    ) -> [RuleCatalogDescriptor] {
        let runtimeIdentifiersByBundle = Dictionary(
            grouping: runningSnapshots,
            by: \.bundleIdentifier
        ).mapValues { snapshots in
            snapshots.map(\.runtimeIdentifier).sorted()
        }
        let bundleIdentifiers = visibleBundleIdentifiers(
            runningBundleIdentifiers: runningSnapshots.map(\.bundleIdentifier),
            registry: registry
        )

        return bundleIdentifiers.map { bundleIdentifier in
            RuleCatalogDescriptor(
                bundleIdentifier: bundleIdentifier,
                explicitAction: registry.rules[bundleIdentifier]?.action ?? .unset,
                runtimeIdentifiers: runtimeIdentifiersByBundle[bundleIdentifier] ?? []
            )
        }
    }

    static func immediateTargetRuntimeIdentifiers(
        action: AutoAction,
        candidates: [ImmediateActionSnapshot],
        registry: StoredRuleRegistry,
        defaultHideEnabled: Bool
    ) -> Set<String> {
        guard action == .hide || action == .quit else { return [] }
        return Set(candidates.compactMap { candidate in
            let explicitAction = registry.rules[candidate.bundleIdentifier]?.action ?? .unset
            let effectiveAction = AutomationPolicy.effectiveAction(
                explicitAction: explicitAction,
                defaultHideEnabled: defaultHideEnabled
            )
            guard effectiveAction == action, !candidate.isAlreadyHandled else { return nil }
            if action == .hide, candidate.isHidden { return nil }
            return candidate.runtimeIdentifier
        })
    }

    static func rowImmediateTargetRuntimeIdentifiers(
        action: AutoAction,
        bundleIdentifier: String,
        snapshotRuntimeIdentifiers: Set<String>,
        candidates: [ImmediateActionSnapshot]
    ) -> Set<String> {
        guard action == .hide || action == .quit else { return [] }
        return Set(candidates.compactMap { candidate in
            guard candidate.bundleIdentifier == bundleIdentifier,
                  snapshotRuntimeIdentifiers.contains(candidate.runtimeIdentifier) else {
                return nil
            }
            if action == .hide, candidate.isHidden { return nil }
            return candidate.runtimeIdentifier
        })
    }

    static func migrateLegacyRules(
        policies: [String: String],
        policyIdleMinutes: [String: Int],
        legacyDefaultIdleMinutes: Int
    ) -> StoredRuleRegistry {
        var rules: [String: StoredAppRule] = [:]
        let fallbackMinutes = max(legacyDefaultIdleMinutes, 1)

        for (bundleIdentifier, rawAction) in policies {
            let trimmedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBundleIdentifier.isEmpty else { continue }

            let action: AutoAction?
            if rawAction == "never" {
                action = .ignore
            } else {
                action = AutoAction(rawValue: rawAction)
            }
            guard let action, action != .unset else { continue }

            rules[trimmedBundleIdentifier] = StoredAppRule(
                action: action,
                idleMinutes: policyIdleMinutes[trimmedBundleIdentifier].map { max($0, 1) }
                    ?? (action.isAutomated ? fallbackMinutes : nil),
                displayName: fallbackDisplayName(for: trimmedBundleIdentifier),
                lastKnownAppPath: nil
            )
        }

        return StoredRuleRegistry(rules: rules)
    }

    static func fallbackDisplayName(for bundleIdentifier: String) -> String {
        let candidate = bundleIdentifier.split(separator: ".").last.map(String.init) ?? ""
        return candidate.isEmpty ? bundleIdentifier : candidate
    }
}
