import Foundation
import Testing
@testable import QuitHide

@Suite("Sparkle update preference migration")
struct SparkleUpdateControllerTests {
    @Test("A legacy disabled preference is preserved and obsolete state is cleared")
    func preservesDisabledLegacyPreference() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: LegacyAutomaticUpdateChecksMigration.automaticChecksKey)
        defaults.set(Date(), forKey: "lastAutomaticUpdateCheckAt")
        defaults.set(Data([1, 2, 3]), forKey: "cachedAvailableUpdate")
        var migratedValue: Bool?

        LegacyAutomaticUpdateChecksMigration.migrate(defaults: defaults) {
            migratedValue = $0
        }

        #expect(migratedValue == false)
        #expect(defaults.bool(forKey: LegacyAutomaticUpdateChecksMigration.completionKey))
        #expect(defaults.object(
            forKey: LegacyAutomaticUpdateChecksMigration.automaticChecksKey
        ) == nil)
        #expect(defaults.object(forKey: "lastAutomaticUpdateCheckAt") == nil)
        #expect(defaults.object(forKey: "cachedAvailableUpdate") == nil)
    }

    @Test("A fresh install keeps Sparkle's Info.plist default")
    func freshInstallDoesNotOverrideSparkleDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var applyCount = 0

        LegacyAutomaticUpdateChecksMigration.migrate(defaults: defaults) { _ in
            applyCount += 1
        }

        #expect(applyCount == 0)
        #expect(defaults.bool(forKey: LegacyAutomaticUpdateChecksMigration.completionKey))
    }

    @Test("Migration runs only once")
    func migrationIsOneShot() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: LegacyAutomaticUpdateChecksMigration.automaticChecksKey)
        var migratedValues: [Bool] = []

        LegacyAutomaticUpdateChecksMigration.migrate(defaults: defaults) {
            migratedValues.append($0)
        }
        defaults.set(false, forKey: LegacyAutomaticUpdateChecksMigration.automaticChecksKey)
        LegacyAutomaticUpdateChecksMigration.migrate(defaults: defaults) {
            migratedValues.append($0)
        }

        #expect(migratedValues == [true])
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "QuitHideTests.SparkleMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
