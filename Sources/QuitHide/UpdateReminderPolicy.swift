import Foundation

struct UpdateReleaseIdentity: Codable, Equatable {
    let version: String
    let build: Int?

    init(version: String, build: Int?) {
        self.version = SemanticVersion(version)?.normalizedString
            ?? version.trimmingCharacters(in: .whitespacesAndNewlines)
        self.build = build
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decode(String.self, forKey: .version),
            build: try container.decodeIfPresent(Int.self, forKey: .build)
        )
    }
}

enum UpdateReminderPolicy {
    static let automaticChecksDefaultEnabled = true
    static let launchDelay: TimeInterval = 10
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let reminderInterval: TimeInterval = 24 * 60 * 60

    static func shouldPresent(
        available: UpdateReleaseIdentity,
        skipped: UpdateReleaseIdentity?,
        remindAfter: Date?,
        now: Date
    ) -> Bool {
        if let skipped, skipped.version == available.version {
            switch (skipped.build, available.build) {
            case let (.some(skippedBuild), .some(availableBuild)):
                guard availableBuild > skippedBuild else { return false }
            case (.none, _), (_, .none):
                // The Releases fallback has no build metadata. Treat the same
                // semantic version as the same release instead of re-prompting.
                return false
            }
        }
        guard let remindAfter else { return true }
        return remindAfter <= now
    }

    static func shouldClearSkippedUpdate(
        installedVersion: String,
        installedBuild: Int,
        skipped: UpdateReleaseIdentity?
    ) -> Bool {
        guard let skipped,
              let installedSemanticVersion = SemanticVersion(installedVersion),
              let skippedSemanticVersion = SemanticVersion(skipped.version) else {
            return false
        }
        if installedSemanticVersion != skippedSemanticVersion {
            return skippedSemanticVersion < installedSemanticVersion
        }
        guard let skippedBuild = skipped.build else {
            return true
        }
        return installedBuild >= skippedBuild
    }

    static func nextAutomaticCheckDate(
        now: Date,
        lastCheckAt: Date?
    ) -> Date {
        let routineDate = lastCheckAt.map { $0.addingTimeInterval(checkInterval) } ?? now
        return routineDate <= now ? now.addingTimeInterval(launchDelay) : routineDate
    }
}
