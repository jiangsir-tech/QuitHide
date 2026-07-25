import Foundation

protocol AutomationClock {
    var now: TimeInterval { get }
}

struct SystemAutomationClock: AutomationClock {
    var now: TimeInterval {
        // Uptime is monotonic, so NTP or a manual wall-clock correction cannot
        // make an idle deadline fire early.
        ProcessInfo.processInfo.systemUptime
    }
}

enum RuntimeApplicationIdentity {
    static func identifier(
        bundleIdentifier: String,
        processIdentifier: Int32,
        launchDate: Date?,
        fallbackGeneration: UUID?
    ) -> String {
        let generation: String
        if let launchDate {
            // Preserve every bit of the NSDate value without locale-dependent
            // formatting or lossy decimal rounding.
            generation = "launch-\(String(launchDate.timeIntervalSinceReferenceDate.bitPattern, radix: 16))"
        } else {
            guard let fallbackGeneration else {
                preconditionFailure("A fallback process generation is required when launchDate is unavailable")
            }
            generation = "fallback-\(fallbackGeneration.uuidString.lowercased())"
        }
        return "\(bundleIdentifier)#\(processIdentifier)#\(generation)"
    }
}

enum ApplicationUnhidePolicy {
    static func shouldRestartTimer(
        actionIsAutomated: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        actionIsAutomated && !applicationIsActive
    }
}

enum PreQuitHideStage: Equatable {
    case pending
    case inFlight
    case completed
}

enum QuitAutomationDecision: Equatable {
    case wait
    case preHide
    case quit
}

enum QuitAutomationTiming {
    static func decision(
        enabled: Bool,
        elapsed: TimeInterval,
        hideDelay: TimeInterval,
        quitDelay: TimeInterval,
        isHidden: Bool,
        hideStage: PreQuitHideStage,
        canAttemptHide: Bool
    ) -> QuitAutomationDecision {
        // Quitting is the rule's final deadline, so it must never be delayed by
        // an unfinished, failed, or currently in-flight pre-hide attempt.
        if elapsed >= quitDelay {
            return .quit
        }

        guard enabled,
              hideDelay < quitDelay,
              elapsed >= hideDelay,
              !isHidden,
              hideStage == .pending,
              canAttemptHide else {
            return .wait
        }

        return .preHide
    }

    static func shouldAttemptQuit(
        isFirstDeadlineAttempt: Bool,
        isAlreadyHandled: Bool,
        hasActionFailure: Bool,
        canRetry: Bool
    ) -> Bool {
        if isFirstDeadlineAttempt {
            // An accepted pre-deadline quit request is already doing the work.
            // A failed one, even after exhausting its manual retries, must not
            // consume or delay the rule's first attempt at the real deadline.
            return !isAlreadyHandled || hasActionFailure
        }

        return !isAlreadyHandled && canRetry
    }
}

struct TimingSuspension {
    enum Reason: Hashable {
        case manualPause
        case systemSleep
    }

    private(set) var reasons: Set<Reason> = []
    private var startedAt: TimeInterval?

    func effectiveNow(at clockNow: TimeInterval) -> TimeInterval {
        startedAt ?? clockNow
    }

    mutating func suspend(for reason: Reason, at instant: TimeInterval) {
        guard reasons.insert(reason).inserted else { return }
        if reasons.count == 1 {
            startedAt = instant
        }
    }

    mutating func resume(for reason: Reason, at instant: TimeInterval) -> TimeInterval? {
        guard reasons.remove(reason) != nil else { return nil }
        guard reasons.isEmpty, let startedAt else { return nil }
        self.startedAt = nil
        return max(instant - startedAt, 0)
    }
}

struct ActionRetryState {
    private(set) var failureCount = 0
    private(set) var retryAfter: TimeInterval?

    var hasAttemptsRemaining: Bool {
        failureCount < 3
    }

    func canAttempt(at instant: TimeInterval) -> Bool {
        guard hasAttemptsRemaining else { return false }
        guard let retryAfter else { return true }
        return instant >= retryAfter
    }

    mutating func recordFailure(at instant: TimeInterval, delay: TimeInterval) {
        failureCount += 1
        retryAfter = hasAttemptsRemaining ? instant + delay : nil
    }

    mutating func shiftRetryDate(by interval: TimeInterval) {
        retryAfter = retryAfter.map { $0 + interval }
    }
}
