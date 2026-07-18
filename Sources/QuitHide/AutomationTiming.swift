import Foundation

struct TimingSuspension {
    enum Reason: Hashable {
        case manualPause
        case systemSleep
    }

    private(set) var reasons: Set<Reason> = []
    private var startedAt: Date?

    var effectiveNow: Date {
        startedAt ?? Date()
    }

    mutating func suspend(for reason: Reason, at date: Date) {
        guard reasons.insert(reason).inserted else { return }
        if reasons.count == 1 {
            startedAt = date
        }
    }

    mutating func resume(for reason: Reason, at date: Date) -> TimeInterval? {
        guard reasons.remove(reason) != nil else { return nil }
        guard reasons.isEmpty, let startedAt else { return nil }
        self.startedAt = nil
        return max(date.timeIntervalSince(startedAt), 0)
    }
}

struct ActionRetryState {
    private(set) var failureCount = 0
    private(set) var retryAfter: Date?

    var hasAttemptsRemaining: Bool {
        failureCount < 3
    }

    func canAttempt(at date: Date) -> Bool {
        guard hasAttemptsRemaining else { return false }
        guard let retryAfter else { return true }
        return date >= retryAfter
    }

    mutating func recordFailure(at date: Date, delay: TimeInterval) {
        failureCount += 1
        retryAfter = hasAttemptsRemaining ? date.addingTimeInterval(delay) : nil
    }

    mutating func shiftRetryDate(by interval: TimeInterval) {
        retryAfter = retryAfter?.addingTimeInterval(interval)
    }
}
