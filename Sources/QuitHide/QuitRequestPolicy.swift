import Foundation

enum QuitRequestStatus: Equatable {
    case waiting
    case timedOut
}

enum QuitRequestPolicy {
    static let responseTimeout: TimeInterval = 30

    static func status(requestedAt: Date, now: Date) -> QuitRequestStatus {
        guard now >= requestedAt else { return .waiting }

        return now.timeIntervalSince(requestedAt) >= responseTimeout
            ? .timedOut
            : .waiting
    }
}
