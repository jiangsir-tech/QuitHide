import Foundation

enum AppAutomationDeferralDuration: Int, CaseIterable {
    case minutes15 = 15
    case minutes30 = 30
    case minutes60 = 60

    var seconds: TimeInterval {
        TimeInterval(rawValue * 60)
    }
}

enum AppAutomationDeferralEligibilityPolicy {
    static func canDefer(
        isRunning: Bool,
        actionIsAutomated: Bool,
        hasUncancelableQuit: Bool
    ) -> Bool {
        isRunning && actionIsAutomated && !hasUncancelableQuit
    }
}

enum AppAutomationActionValidationPolicy {
    static func hasReachedRequiredTimingThreshold(
        isPreQuitHide: Bool,
        elapsed: TimeInterval,
        actionDelay: TimeInterval
    ) -> Bool {
        isPreQuitHide || elapsed >= max(actionDelay, 0)
    }

    static func shouldProceed(
        deferralStateChanged: Bool,
        isDeferredNow: Bool,
        isStillIdleEligible: Bool
    ) -> Bool {
        !deferralStateChanged && !isDeferredNow && isStillIdleEligible
    }
}

struct AppAutomationDeferralReset: Equatable, Sendable {
    let bundleIdentifier: String
    let timerRestartAt: TimeInterval
}

struct AppAutomationDeferralRegistry {
    private var deadlinesByBundleIdentifier: [String: TimeInterval] = [:]
    private var revisionsByBundleIdentifier: [String: UInt64] = [:]

    func revision(for bundleIdentifier: String) -> UInt64 {
        revisionsByBundleIdentifier[bundleIdentifier] ?? 0
    }

    mutating func deferAutomation(
        for bundleIdentifier: String,
        duration: AppAutomationDeferralDuration,
        at now: TimeInterval
    ) {
        deadlinesByBundleIdentifier[bundleIdentifier] = now + duration.seconds
        advanceRevision(for: bundleIdentifier)
    }

    mutating func endDeferral(
        for bundleIdentifier: String,
        at now: TimeInterval
    ) -> AppAutomationDeferralReset? {
        guard deadlinesByBundleIdentifier.removeValue(
            forKey: bundleIdentifier
        ) != nil else {
            return nil
        }
        advanceRevision(for: bundleIdentifier)
        return AppAutomationDeferralReset(
            bundleIdentifier: bundleIdentifier,
            timerRestartAt: now
        )
    }

    func isDeferred(for bundleIdentifier: String, at now: TimeInterval) -> Bool {
        guard let deadline = deadlinesByBundleIdentifier[bundleIdentifier] else {
            return false
        }
        return now < deadline
    }

    func remainingTime(
        for bundleIdentifier: String,
        at now: TimeInterval
    ) -> TimeInterval? {
        guard let deadline = deadlinesByBundleIdentifier[bundleIdentifier],
              now < deadline else {
            return nil
        }
        return deadline - now
    }

    mutating func expire(at now: TimeInterval) -> [AppAutomationDeferralReset] {
        let expiredBundleIdentifiers = deadlinesByBundleIdentifier
            .filter { now >= $0.value }
            .map(\.key)
            .sorted()

        for bundleIdentifier in expiredBundleIdentifiers {
            deadlinesByBundleIdentifier.removeValue(forKey: bundleIdentifier)
        }
        for bundleIdentifier in expiredBundleIdentifiers {
            advanceRevision(for: bundleIdentifier)
        }

        return expiredBundleIdentifiers.map {
            AppAutomationDeferralReset(
                bundleIdentifier: $0,
                timerRestartAt: now
            )
        }
    }

    @discardableResult
    mutating func removeStoppedApps(
        runningBundleIdentifiers: Set<String>
    ) -> Bool {
        let stoppedBundleIdentifiers = deadlinesByBundleIdentifier.keys.filter {
            !runningBundleIdentifiers.contains($0)
        }
        guard !stoppedBundleIdentifiers.isEmpty else {
            return false
        }
        for bundleIdentifier in stoppedBundleIdentifiers {
            deadlinesByBundleIdentifier.removeValue(forKey: bundleIdentifier)
            advanceRevision(for: bundleIdentifier)
        }
        return true
    }

    @discardableResult
    mutating func removeDeferrals(
        for bundleIdentifiers: Set<String>
    ) -> Bool {
        let removedBundleIdentifiers = deadlinesByBundleIdentifier.keys.filter {
            bundleIdentifiers.contains($0)
        }
        guard !removedBundleIdentifiers.isEmpty else { return false }
        for bundleIdentifier in removedBundleIdentifiers {
            deadlinesByBundleIdentifier.removeValue(forKey: bundleIdentifier)
            advanceRevision(for: bundleIdentifier)
        }
        return true
    }

    mutating func shiftDeadlines(by interval: TimeInterval) {
        let shift = max(interval, 0)
        guard shift > 0, !deadlinesByBundleIdentifier.isEmpty else { return }
        let deadlines = deadlinesByBundleIdentifier
        for (bundleIdentifier, deadline) in deadlines {
            deadlinesByBundleIdentifier[bundleIdentifier] = deadline + shift
            advanceRevision(for: bundleIdentifier)
        }
    }

    private mutating func advanceRevision(for bundleIdentifier: String) {
        revisionsByBundleIdentifier[bundleIdentifier, default: 0] &+= 1
    }
}
