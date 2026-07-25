import Foundation
import Testing
@testable import QuitHide

@Suite("Atomic rule registry file store")
struct RuleRegistryStoreTests {
    @Test("A saved registry survives a verified round trip")
    func saveAndLoad() throws {
        let fixture = try Fixture()
        let registry = sampleRegistry(name: "Current")

        try fixture.store.save(registry, fallbackIdleMinutes: 20)

        #expect(
            fixture.store.load(fallbackIdleMinutes: 20) == .current(registry)
        )
    }

    @Test("Only a valid primary becomes the backup")
    func rotatesOnlyValidPrimary() throws {
        let fixture = try Fixture()
        let first = sampleRegistry(name: "First")
        let second = sampleRegistry(name: "Second")

        try fixture.store.save(first, fallbackIdleMinutes: 20)
        try fixture.store.save(second, fallbackIdleMinutes: 20)

        let backupData = try Data(contentsOf: fixture.store.backupURL)
        #expect(
            AppRuleRegistry.decodeRegistry(
                from: backupData,
                fallbackIdleMinutes: 20
            ) == .current(first)
        )
    }

    @Test("A corrupt primary is preserved and recovered from backup")
    func recoversFromBackup() throws {
        let fixture = try Fixture()
        let first = sampleRegistry(name: "First")
        let second = sampleRegistry(name: "Second")
        try fixture.store.save(first, fallbackIdleMinutes: 20)
        try fixture.store.save(second, fallbackIdleMinutes: 20)
        try Data("broken".utf8).write(to: fixture.store.primaryURL, options: [.atomic])

        #expect(
            fixture.store.load(fallbackIdleMinutes: 20) == .recoveredFromBackup(first)
        )
        #expect(try Data(contentsOf: fixture.store.corruptBackupURL) == Data("broken".utf8))
        #expect(
            fixture.store.load(fallbackIdleMinutes: 20) == .current(first)
        )
    }

    @Test("A future primary remains authoritative and read only")
    func preservesFutureSchema() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(
            at: fixture.store.directoryURL,
            withIntermediateDirectories: true
        )
        let future = StoredRuleRegistry(
            schemaVersion: StoredRuleRegistry.currentSchemaVersion + 1,
            rules: [:]
        )
        let futureData = try JSONEncoder().encode(future)
        try futureData.write(to: fixture.store.primaryURL, options: [.atomic])
        try JSONEncoder().encode(sampleRegistry(name: "Old")).write(
            to: fixture.store.backupURL,
            options: [.atomic]
        )

        #expect(
            fixture.store.load(fallbackIdleMinutes: 20) == .unsupported(
                schemaVersion: StoredRuleRegistry.currentSchemaVersion + 1
            )
        )
        #expect(try Data(contentsOf: fixture.store.primaryURL) == futureData)
    }

    @Test("A missing primary can recover a valid backup")
    func missingPrimaryRecoversBackup() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(
            at: fixture.store.directoryURL,
            withIntermediateDirectories: true
        )
        let registry = sampleRegistry(name: "Backup")
        try JSONEncoder().encode(registry).write(
            to: fixture.store.backupURL,
            options: [.atomic]
        )

        #expect(
            fixture.store.load(fallbackIdleMinutes: 20) == .recoveredFromBackup(registry)
        )
    }

    private func sampleRegistry(name: String) -> StoredRuleRegistry {
        StoredRuleRegistry(rules: [
            "com.example.app": StoredAppRule(
                action: .hide,
                idleMinutes: 5,
                displayName: name,
                lastKnownAppPath: "/Applications/Example.app"
            )
        ])
    }

    private final class Fixture {
        let directoryURL: URL
        let store: RuleRegistryFileStore

        init() throws {
            directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuitHideRuleStoreTests-\(UUID().uuidString)", isDirectory: true)
            store = RuleRegistryFileStore(directoryURL: directoryURL)
        }

        deinit {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }
}
