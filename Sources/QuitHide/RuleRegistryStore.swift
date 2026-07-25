import Foundation

enum RuleRegistryFileLoadResult: Equatable {
    case missing
    case current(StoredRuleRegistry)
    case recoveredFromBackup(StoredRuleRegistry)
    case unsupported(schemaVersion: Int)
    case invalid
}

struct RuleRegistryFileStore {
    enum StoreError: Error {
        case invalidEncodedRegistry
    }

    let directoryURL: URL

    var primaryURL: URL {
        directoryURL.appendingPathComponent("rules.json", isDirectory: false)
    }

    var backupURL: URL {
        directoryURL.appendingPathComponent("rules.backup.json", isDirectory: false)
    }

    var corruptBackupURL: URL {
        directoryURL.appendingPathComponent("rules.corrupt.json", isDirectory: false)
    }

    static func live(fileManager: FileManager = .default) -> RuleRegistryFileStore {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return RuleRegistryFileStore(
            directoryURL: applicationSupport
                .appendingPathComponent("QuitHide", isDirectory: true)
        )
    }

    func load(
        fallbackIdleMinutes: Int,
        fileManager: FileManager = .default
    ) -> RuleRegistryFileLoadResult {
        guard fileManager.fileExists(atPath: primaryURL.path) else {
            return loadBackup(
                fallbackIdleMinutes: fallbackIdleMinutes,
                recoverPrimary: true,
                fileManager: fileManager,
                missingResult: .missing
            )
        }

        guard let primaryData = try? Data(contentsOf: primaryURL) else {
            return loadBackup(
                fallbackIdleMinutes: fallbackIdleMinutes,
                recoverPrimary: true,
                fileManager: fileManager,
                missingResult: .invalid
            )
        }

        switch AppRuleRegistry.decodeRegistry(
            from: primaryData,
            fallbackIdleMinutes: fallbackIdleMinutes
        ) {
        case let .current(registry):
            return .current(registry)
        case let .unsupported(schemaVersion):
            // A newer primary file is authoritative. Never replace it with an
            // older backup when this version cannot understand the schema.
            return .unsupported(schemaVersion: schemaVersion)
        case .invalid:
            preserveCorruptPrimary(primaryData, fileManager: fileManager)
            return loadBackup(
                fallbackIdleMinutes: fallbackIdleMinutes,
                recoverPrimary: true,
                fileManager: fileManager,
                missingResult: .invalid
            )
        }
    }

    func save(
        _ registry: StoredRuleRegistry,
        fallbackIdleMinutes: Int,
        fileManager: FileManager = .default
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(registry)
        guard case .current = AppRuleRegistry.decodeRegistry(
            from: encoded,
            fallbackIdleMinutes: fallbackIdleMinutes
        ) else {
            throw StoreError.invalidEncodedRegistry
        }

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        var previousValidData: Data?
        if let currentData = try? Data(contentsOf: primaryURL),
           currentData != encoded,
           case .current = AppRuleRegistry.decodeRegistry(
               from: currentData,
               fallbackIdleMinutes: fallbackIdleMinutes
           ) {
            previousValidData = currentData
            // Only a verified primary may replace the last known-good backup.
            try currentData.write(to: backupURL, options: [.atomic])
        }

        try encoded.write(to: primaryURL, options: [.atomic])

        do {
            let writtenData = try Data(contentsOf: primaryURL)
            guard case let .current(writtenRegistry) = AppRuleRegistry.decodeRegistry(
                from: writtenData,
                fallbackIdleMinutes: fallbackIdleMinutes
            ), writtenRegistry == AppRuleRegistry.normalizedRegistry(
                registry,
                fallbackIdleMinutes: fallbackIdleMinutes
            ) else {
                throw StoreError.invalidEncodedRegistry
            }
        } catch {
            // A failed read-back must not leave the corrupt replacement as the
            // authoritative file for the next launch.
            if let previousValidData {
                try? previousValidData.write(to: primaryURL, options: [.atomic])
            } else {
                try? fileManager.removeItem(at: primaryURL)
            }
            throw error
        }
    }

    private func loadBackup(
        fallbackIdleMinutes: Int,
        recoverPrimary: Bool,
        fileManager: FileManager,
        missingResult: RuleRegistryFileLoadResult
    ) -> RuleRegistryFileLoadResult {
        guard let backupData = try? Data(contentsOf: backupURL) else {
            return missingResult
        }

        switch AppRuleRegistry.decodeRegistry(
            from: backupData,
            fallbackIdleMinutes: fallbackIdleMinutes
        ) {
        case let .current(registry):
            if recoverPrimary {
                try? fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                try? backupData.write(to: primaryURL, options: [.atomic])
            }
            return .recoveredFromBackup(registry)
        case let .unsupported(schemaVersion):
            return .unsupported(schemaVersion: schemaVersion)
        case .invalid:
            return missingResult == .missing ? .missing : .invalid
        }
    }

    private func preserveCorruptPrimary(
        _ data: Data,
        fileManager: FileManager
    ) {
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? data.write(to: corruptBackupURL, options: [.atomic])
    }
}
