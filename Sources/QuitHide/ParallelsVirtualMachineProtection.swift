import Darwin
import Foundation

enum ParallelsVirtualMachineProcessState: Equatable {
    case running
    case stopped
    case unavailable
}

struct ParallelsVirtualMachineProcessSnapshot {
    let state: ParallelsVirtualMachineProcessState
    let processIdentifiers: Set<Int32>
    let sharedApplicationProcessIdentifiers: Set<Int32>
}

enum ParallelsDesktopStopCleanupDecision: Equatable {
    case none
    case schedule
    case retry
    case cancel
    case quit
}

struct ParallelsDesktopStopCleanupTracker {
    private(set) var lastKnownProcessState:
        ParallelsVirtualMachineProcessState = .unavailable
    private(set) var isPending = false

    mutating func observe(
        _ currentProcessState: ParallelsVirtualMachineProcessState
    ) -> ParallelsDesktopStopCleanupDecision {
        switch currentProcessState {
        case .unavailable:
            return isPending ? .retry : .none
        case .running:
            lastKnownProcessState = .running
            guard isPending else { return .none }
            isPending = false
            return .cancel
        case .stopped:
            let previousProcessState = lastKnownProcessState
            lastKnownProcessState = .stopped
            guard previousProcessState == .running else {
                return isPending ? .retry : .none
            }
            isPending = true
            return .schedule
        }
    }

    mutating func verify(
        processState: ParallelsVirtualMachineProcessState,
        runningSharedApplicationProcessIdentifiers: Set<Int32>
    ) -> ParallelsDesktopStopCleanupDecision {
        guard isPending else { return .none }

        switch processState {
        case .unavailable:
            return .retry
        case .running:
            lastKnownProcessState = .running
            isPending = false
            return .cancel
        case .stopped:
            lastKnownProcessState = .stopped
            guard runningSharedApplicationProcessIdentifiers.isEmpty else {
                return .retry
            }
            isPending = false
            return .quit
        }
    }
}

enum ParallelsVirtualMachineProtectionPolicy {
    static let desktopBundleIdentifier = "com.parallels.desktop.console"
    static let sharedApplicationBundleIdentifierPrefix = "com.parallels.winapp."
    static let virtualMachineExecutableName = "prl_vm_app"
    static let sharedApplicationsDirectoryName = "Applications (Parallels)"

    static func processState(
        executableNames: Set<String>?
    ) -> ParallelsVirtualMachineProcessState {
        guard let executableNames else { return .unavailable }
        return executableNames.contains(virtualMachineExecutableName)
            ? .running
            : .stopped
    }

    static func processState(
        virtualMachineProcessIdentifiers: Set<Int32>?
    ) -> ParallelsVirtualMachineProcessState {
        guard let virtualMachineProcessIdentifiers else { return .unavailable }
        return virtualMachineProcessIdentifiers.isEmpty ? .stopped : .running
    }

    static func shouldProtect(
        bundleIdentifier: String,
        applicationURL: URL? = nil,
        processState: ParallelsVirtualMachineProcessState,
        virtualMachineIsInUse: Bool = false,
        isVirtualMachineProcess: Bool = false
    ) -> Bool {
        let isDesktop = isParallelsDesktop(
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL
        )
        let isManagedParallelsApplication = isDesktop || isVirtualMachineApplication(
                bundleIdentifier: bundleIdentifier,
                applicationURL: applicationURL
            ) || isWindowsDockHelper(
                bundleIdentifier: bundleIdentifier,
                applicationURL: applicationURL
            )
        guard isManagedParallelsApplication else {
            return false
        }

        // Keep the Parallels UI alive while its VM process exists. The VM's
        // own QuitHide timer gets to finish first; the desktop exits afterward.
        if isDesktop && !isVirtualMachineProcess {
            switch processState {
            case .running, .unavailable:
                return true
            case .stopped:
                return virtualMachineIsInUse
            }
        }

        if isVirtualMachineProcess {
            switch processState {
            case .running, .stopped:
                return virtualMachineIsInUse
            case .unavailable:
                return true
            }
        }

        switch processState {
        case .running, .stopped:
            return virtualMachineIsInUse
        case .unavailable:
            // If the process inventory cannot be read, keep Parallels open.
            return true
        }
    }

    static func isParallelsDesktop(
        bundleIdentifier: String,
        applicationURL: URL? = nil
    ) -> Bool {
        bundleIdentifier == desktopBundleIdentifier ||
            applicationURL?.lastPathComponent
                .localizedCaseInsensitiveCompare("Parallels Desktop.app") == .orderedSame
    }

    static func isVirtualMachineApplication(
        bundleIdentifier: String? = nil,
        applicationURL: URL? = nil
    ) -> Bool {
        guard !isWindowsDockHelper(
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL
        ) else {
            return false
        }

        return bundleIdentifier?.lowercased().hasPrefix(
            sharedApplicationBundleIdentifierPrefix
        ) == true || applicationURL?.pathComponents.contains {
            $0.localizedCaseInsensitiveCompare(
                sharedApplicationsDirectoryName
            ) == .orderedSame
        } == true
    }

    static func shouldDeferAutomaticActionForInactiveSpaceWindow(
        bundleIdentifier: String,
        applicationURL: URL? = nil,
        hasVisibleWindowOnAnotherSpace: Bool
    ) -> Bool {
        guard hasVisibleWindowOnAnotherSpace else { return false }

        // These Parallels infrastructure windows can remain on another Space
        // after all shared Windows apps have closed. Active shared apps hold
        // Parallels through virtualMachineIsInUse instead.
        return !isParallelsDesktop(
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL
        ) && !isWindowsDockHelper(
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL
        )
    }

    static func isWindowsDockHelper(
        bundleIdentifier: String?,
        applicationURL: URL?
    ) -> Bool {
        let normalizedBundleIdentifier = bundleIdentifier?.lowercased() ?? ""
        let isHelperBundleIdentifier =
            normalizedBundleIdentifier.hasPrefix(
                sharedApplicationBundleIdentifierPrefix
            ) && normalizedBundleIdentifier.hasSuffix(".fs")
        let isHelperApplicationPath = applicationURL?.pathComponents.contains {
            $0.localizedCaseInsensitiveContains("Dock Helper.app")
        } == true

        return isHelperBundleIdentifier || isHelperApplicationPath
    }

    static func virtualMachineIsInUse(
        runningSharedApplicationProcessIdentifiers: Set<Int32>
    ) -> Bool {
        // Only a running shared Windows app means the guest is actively in
        // use. A VM process or a Parallels window can exist while Windows is
        // idle, in which case the normal timer should be allowed to run.
        !runningSharedApplicationProcessIdentifiers.isEmpty
    }

}

enum SystemParallelsVirtualMachineProcessProvider {
    private static let processPathBufferSize = 4_096
    private static let processCountBufferPadding = 32

    static func snapshot() -> ParallelsVirtualMachineProcessSnapshot {
        guard let inventory = runningProcessIdentifiers() else {
            return ParallelsVirtualMachineProcessSnapshot(
                state: .unavailable,
                processIdentifiers: [],
                sharedApplicationProcessIdentifiers: []
            )
        }

        return ParallelsVirtualMachineProcessSnapshot(
            state: ParallelsVirtualMachineProtectionPolicy.processState(
                virtualMachineProcessIdentifiers:
                    inventory.virtualMachineProcessIdentifiers
            ),
            processIdentifiers: inventory.virtualMachineProcessIdentifiers,
            sharedApplicationProcessIdentifiers:
                inventory.sharedApplicationProcessIdentifiers
        )
    }

    static func processState() -> ParallelsVirtualMachineProcessState {
        snapshot().state
    }

    private static func runningProcessIdentifiers() -> (
        virtualMachineProcessIdentifiers: Set<Int32>,
        sharedApplicationProcessIdentifiers: Set<Int32>
    )? {
        let initialCount = Int(proc_listallpids(nil, 0))
        guard initialCount > 0 else { return nil }

        var capacity = initialCount + processCountBufferPadding
        for _ in 0..<2 {
            let byteCount = capacity * MemoryLayout<pid_t>.stride
            guard byteCount <= Int(Int32.max) else { return nil }

            var processIdentifiers = [pid_t](repeating: 0, count: capacity)
            let processCount = processIdentifiers.withUnsafeMutableBufferPointer {
                proc_listallpids($0.baseAddress, Int32(byteCount))
            }
            guard processCount > 0 else { return nil }

            let actualCount = Int(processCount)
            guard actualCount <= processIdentifiers.count else {
                capacity = actualCount + processCountBufferPadding
                continue
            }

            var virtualMachineProcessIdentifiers: Set<Int32> = []
            var sharedApplicationProcessIdentifiers: Set<Int32> = []
            for processIdentifier in processIdentifiers.prefix(actualCount)
            where processIdentifier > 0 {
                var path = [CChar](
                    repeating: 0,
                    count: processPathBufferSize
                )
                let pathLength = path.withUnsafeMutableBufferPointer {
                    proc_pidpath(
                        processIdentifier,
                        $0.baseAddress,
                        UInt32($0.count)
                    )
                }
                guard pathLength > 0,
                      let baseAddress = path.withUnsafeBufferPointer(
                        { $0.baseAddress }
                      ) else {
                    continue
                }
                let executableURL = URL(
                    fileURLWithPath: String(cString: baseAddress)
                )
                let executableName = executableURL.lastPathComponent
                if executableName ==
                    ParallelsVirtualMachineProtectionPolicy
                        .virtualMachineExecutableName {
                    virtualMachineProcessIdentifiers.insert(
                        Int32(processIdentifier)
                    )
                }
                if ParallelsVirtualMachineProtectionPolicy
                    .isVirtualMachineApplication(
                        applicationURL: executableURL
                    ) {
                    sharedApplicationProcessIdentifiers.insert(
                        Int32(processIdentifier)
                    )
                }
            }
            return (
                virtualMachineProcessIdentifiers,
                sharedApplicationProcessIdentifiers
            )
        }

        return nil
    }
}
