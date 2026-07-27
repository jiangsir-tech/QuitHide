import Foundation

enum StageManagerSystemState: Sendable, Equatable {
    case enabled
    case disabled
    case unavailable
}

protocol StageManagerSystemStateProviding: Sendable {
    func readSystemState() async -> StageManagerSystemState
}

actor SystemStageManagerSystemStateProvider: StageManagerSystemStateProviding {
    func readSystemState() async -> StageManagerSystemState {
        let first = Self.currentState
        do {
            try await Task.sleep(nanoseconds: 150_000_000)
        } catch {
            return .unavailable
        }
        let second = Self.currentState
        return first == second ? second : .unavailable
    }

    static var currentState: StageManagerSystemState {
        let domain = "com.apple.WindowManager" as CFString
        let key = "GloballyEnabled" as CFString
        guard CFPreferencesAppSynchronize(domain) else {
            return .unavailable
        }
        guard let value = CFPreferencesCopyAppValue(key, domain) else {
            // Macs that have never enabled Stage Manager commonly have no value.
            return .disabled
        }
        guard let number = value as? NSNumber else {
            return .unavailable
        }
        return number.boolValue ? .enabled : .disabled
    }
}
