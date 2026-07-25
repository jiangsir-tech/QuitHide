import Foundation
import Testing
@testable import QuitHide

@Suite("Update reminder policy")
struct UpdateReminderPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Automatic checks are enabled by default")
    func automaticCheckDefault() {
        #expect(UpdateReminderPolicy.automaticChecksDefaultEnabled)
    }

    @Test("A new unskipped version is presented immediately")
    func presentsAvailableVersion() {
        #expect(UpdateReminderPolicy.shouldPresent(
            available: UpdateReleaseIdentity(version: "1.1.0", build: 10),
            skipped: nil,
            remindAfter: nil,
            now: now
        ))
    }

    @Test("Skipping applies only to the exact version")
    func exactSkipOnly() {
        #expect(!UpdateReminderPolicy.shouldPresent(
            available: UpdateReleaseIdentity(version: "1.1.0", build: 10),
            skipped: UpdateReleaseIdentity(version: "1.1.0", build: 10),
            remindAfter: nil,
            now: now
        ))
        #expect(UpdateReminderPolicy.shouldPresent(
            available: UpdateReleaseIdentity(version: "1.1.0", build: 11),
            skipped: UpdateReleaseIdentity(version: "1.1.0", build: 10),
            remindAfter: nil,
            now: now
        ))
        #expect(!UpdateReminderPolicy.shouldPresent(
            available: UpdateReleaseIdentity(version: "1.1.0", build: nil),
            skipped: UpdateReleaseIdentity(version: "1.1.0", build: 10),
            remindAfter: nil,
            now: now
        ))
        #expect(UpdateReminderPolicy.shouldPresent(
            available: UpdateReleaseIdentity(version: "1.2.0", build: nil),
            skipped: UpdateReleaseIdentity(version: "1.1.0", build: 10),
            remindAfter: nil,
            now: now
        ))
    }

    @Test("Reminder identities normalize equivalent semantic version spellings")
    func identityNormalizesVersion() throws {
        let original = UpdateReleaseIdentity(version: "v1.2.0+build.7", build: 10)
        #expect(original.version == "1.2.0")
        #expect(original == UpdateReleaseIdentity(version: "1.2.0", build: 10))

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UpdateReleaseIdentity.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("A skipped update is cleared only after that version is installed")
    func clearSkipOnlyAfterInstallation() {
        let skipped = UpdateReleaseIdentity(version: "0.3.0", build: 10)
        #expect(!UpdateReminderPolicy.shouldClearSkippedUpdate(
            installedVersion: "0.2.4",
            installedBuild: 99,
            skipped: skipped
        ))
        #expect(!UpdateReminderPolicy.shouldClearSkippedUpdate(
            installedVersion: "0.3.0",
            installedBuild: 9,
            skipped: skipped
        ))
        #expect(UpdateReminderPolicy.shouldClearSkippedUpdate(
            installedVersion: "v0.3.0",
            installedBuild: 10,
            skipped: skipped
        ))
        #expect(UpdateReminderPolicy.shouldClearSkippedUpdate(
            installedVersion: "0.4.0",
            installedBuild: 1,
            skipped: skipped
        ))
    }

    @Test("A reminder stays hidden until its date")
    func reminderDate() {
        #expect(!UpdateReminderPolicy.shouldPresent(
            available: UpdateReleaseIdentity(version: "1.1.0", build: 10),
            skipped: nil,
            remindAfter: now.addingTimeInterval(60),
            now: now
        ))
        #expect(UpdateReminderPolicy.shouldPresent(
            available: UpdateReleaseIdentity(version: "1.1.0", build: 10),
            skipped: nil,
            remindAfter: now,
            now: now
        ))
    }

    @Test("A first or overdue check waits for the launch delay")
    func overdueCheckWaitsBriefly() {
        let expected = now.addingTimeInterval(UpdateReminderPolicy.launchDelay)
        #expect(UpdateReminderPolicy.nextAutomaticCheckDate(
            now: now,
            lastCheckAt: nil
        ) == expected)
        #expect(UpdateReminderPolicy.nextAutomaticCheckDate(
            now: now,
            lastCheckAt: now.addingTimeInterval(-UpdateReminderPolicy.checkInterval)
        ) == expected)
    }

    @Test("A recent check is scheduled at the 24-hour boundary")
    func recentCheckUsesRoutineBoundary() {
        let lastCheck = now.addingTimeInterval(-60 * 60)
        #expect(UpdateReminderPolicy.nextAutomaticCheckDate(
            now: now,
            lastCheckAt: lastCheck
        ) == lastCheck.addingTimeInterval(UpdateReminderPolicy.checkInterval))
    }
}
