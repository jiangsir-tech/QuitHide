import ApplicationServices
import Foundation

enum ApplicationMinimizedWindowProtectionStatus: Sendable, Equatable {
    case active
    case permissionRequired
    case unavailable
}

struct ApplicationMinimizedWindowSnapshot: Sendable, Equatable {
    let minimizedProcessIdentifiers: Set<pid_t>
    let unavailableProcessIdentifiers: Set<pid_t>
    let status: ApplicationMinimizedWindowProtectionStatus
}

protocol ApplicationMinimizedWindowProviding: Sendable {
    func readSnapshot(
        processIdentifiers: Set<pid_t>
    ) async -> ApplicationMinimizedWindowSnapshot
}

actor SystemApplicationMinimizedWindowProvider:
    ApplicationMinimizedWindowProviding {
    private enum WindowState {
        case minimized
        case notMinimized
        case unavailable
    }

    func readSnapshot(
        processIdentifiers: Set<pid_t>
    ) async -> ApplicationMinimizedWindowSnapshot {
        guard AXIsProcessTrusted() else {
            return ApplicationMinimizedWindowSnapshot(
                minimizedProcessIdentifiers: [],
                unavailableProcessIdentifiers: [],
                status: .permissionRequired
            )
        }

        var minimizedProcessIdentifiers: Set<pid_t> = []
        var unavailableProcessIdentifiers: Set<pid_t> = []

        for processIdentifier in processIdentifiers {
            switch windowState(for: processIdentifier) {
            case .minimized:
                minimizedProcessIdentifiers.insert(processIdentifier)
            case .notMinimized:
                break
            case .unavailable:
                unavailableProcessIdentifiers.insert(processIdentifier)
            }
        }

        return ApplicationMinimizedWindowSnapshot(
            minimizedProcessIdentifiers: minimizedProcessIdentifiers,
            unavailableProcessIdentifiers: unavailableProcessIdentifiers,
            status: unavailableProcessIdentifiers.isEmpty
                ? .active
                : .unavailable
        )
    }

    private func windowState(for processIdentifier: pid_t) -> WindowState {
        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.25)

        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
        let windows = rawWindows as? [AXUIElement] else {
            return .unavailable
        }

        for window in windows {
            _ = AXUIElementSetMessagingTimeout(window, 0.25)
            var rawMinimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                &rawMinimized
            ) == .success,
            let minimized = rawMinimized as? NSNumber else {
                return .unavailable
            }
            if minimized.boolValue {
                return .minimized
            }
        }

        return .notMinimized
    }
}
