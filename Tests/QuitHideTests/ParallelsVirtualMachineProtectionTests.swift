import Foundation
import Testing
@testable import QuitHide

@Suite("Parallels virtual machine protection")
struct ParallelsVirtualMachineProtectionTests {
    private let desktopBundleIdentifier =
        ParallelsVirtualMachineProtectionPolicy.desktopBundleIdentifier

    @Test("A running VM keeps Parallels Desktop open while the VM has its own timer")
    func runningVirtualMachineHoldsDesktopUntilVMStops() {
        let processState = ParallelsVirtualMachineProtectionPolicy.processState(
            executableNames: Set(["prl_vm_app"])
        )
        let isProtected = ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: desktopBundleIdentifier,
            processState: processState,
            virtualMachineIsInUse: false
        )

        #expect(isProtected)
        #expect(ApplicationIdleTimerPolicy.directive(
            actionIsAutomated: true,
            applicationIsActive: false,
            applicationIsHeld: isProtected,
            hasTimer: false
        ) == .clear)
        #expect(!ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: desktopBundleIdentifier,
            processState: .stopped,
            virtualMachineIsInUse: false
        ))
        #expect(ApplicationIdleTimerPolicy.directive(
            actionIsAutomated: true,
            applicationIsActive: false,
            applicationIsHeld: false,
            hasTimer: false
        ) == .startNow)
    }

    @Test("An idle VM process gets its own countdown while Parallels stays open")
    func virtualMachineProcessGetsTheIdleTimer() {
        let processState = ParallelsVirtualMachineProtectionPolicy.processState(
            executableNames: Set(["prl_vm_app"])
        )
        let vmIsProtected = ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: desktopBundleIdentifier,
            processState: processState,
            virtualMachineIsInUse: false,
            isVirtualMachineProcess: true
        )

        #expect(!vmIsProtected)
        #expect(ApplicationIdleTimerPolicy.directive(
            actionIsAutomated: true,
            applicationIsActive: false,
            applicationIsHeld: vmIsProtected,
            hasTimer: false
        ) == .startNow)
        #expect(ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: desktopBundleIdentifier,
            processState: processState,
            virtualMachineIsInUse: true,
            isVirtualMachineProcess: true
        ))
    }

    @Test("A Windows app keeps Parallels protected while the VM process runs")
    func runningWindowsAppProtectsParallelsDesktop() {
        let processState = ParallelsVirtualMachineProtectionPolicy.processState(
            executableNames: Set(["prl_vm_app"])
        )

        #expect(ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: desktopBundleIdentifier,
            processState: processState,
            virtualMachineIsInUse: true
        ))
    }

    @Test("A Windows app protects Parallels before its VM process appears")
    func sharedAppProtectsParallelsDuringVMStartup() {
        #expect(ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: desktopBundleIdentifier,
            processState: .stopped,
            virtualMachineIsInUse: true
        ))
    }

    @Test("A running Parallels shared app is protected while its VM is in use")
    func runningSharedAppIsProtectedFromItsBundleIdentifier() {
        #expect(ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier:
                "com.parallels.winapp.07a094a210794e74a0e5e1a1457a92ee.3ee4fe402df84873871f0f278370168d",
            processState: .running,
            virtualMachineIsInUse: true
        ))
    }

    @Test("A running VM's shared Windows app is recognized from its path")
    func recognizesSharedWindowsApp() {
        #expect(ParallelsVirtualMachineProtectionPolicy
            .isVirtualMachineApplication(
                applicationURL: URL(
                    fileURLWithPath:
                        "/Users/test/Applications (Parallels)/{vm-id} Applications.localized/Microsoft Word.app"
                )
            ))
        #expect(ParallelsVirtualMachineProtectionPolicy
            .isVirtualMachineApplication(
                bundleIdentifier:
                    "com.parallels.winapp.07a094a210794e74a0e5e1a1457a92ee.3ee4fe402df84873871f0f278370168d",
                applicationURL: nil
            ))
        #expect(!ParallelsVirtualMachineProtectionPolicy
            .isVirtualMachineApplication(
                applicationURL: URL(
                    fileURLWithPath: "/Applications/Microsoft Word.app"
                )
            ))
    }

    @Test("The Parallels Windows Dock Helper is not a guest application")
    func ignoresParallelsWindowsDockHelper() {
        #expect(ParallelsVirtualMachineProtectionPolicy.isWindowsDockHelper(
            bundleIdentifier:
                "com.parallels.winapp.8c4731f1a5288444bb2510ff8d967cc3.3ee4fe402df84873871f0f278370168d.fs",
            applicationURL: nil
        ))
        #expect(ParallelsVirtualMachineProtectionPolicy.isWindowsDockHelper(
            bundleIdentifier: nil,
            applicationURL: URL(
                fileURLWithPath:
                    "/Users/test/Applications (Parallels)/{vm-id} Applications.localized/Windows 11 Dock Helper.app/Contents/MacOS/Windows 11 Dock Helper"
            )
        ))
        #expect(!ParallelsVirtualMachineProtectionPolicy
            .isVirtualMachineApplication(
                bundleIdentifier:
                    "com.parallels.winapp.8c4731f1a5288444bb2510ff8d967cc3.3ee4fe402df84873871f0f278370168d.fs"
            ))
        #expect(!ParallelsVirtualMachineProtectionPolicy
            .isVirtualMachineApplication(
                applicationURL: URL(
                    fileURLWithPath:
                        "/Users/test/Applications (Parallels)/{vm-id} Applications.localized/Windows 11 Dock Helper.app/Contents/MacOS/Windows 11 Dock Helper"
                )
            ))
    }

    @Test("A running VM with no shared Windows apps is idle")
    func runningVMWithoutSharedAppsDoesNotCountAsInUse() {
        #expect(!ParallelsVirtualMachineProtectionPolicy
            .virtualMachineIsInUse(
                runningSharedApplicationProcessIdentifiers: []
            ))
    }

    @Test("An empty Windows app list does not shut down the VM")
    func lastWindowsAppExitLeavesTheVMsOwnTimerInControl() {
        #expect(!ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier:
                "com.parallels.winapp.07a094a210794e74a0e5e1a1457a92ee.3ee4fe402df84873871f0f278370168d",
            processState: .running,
            virtualMachineIsInUse: false
        ))
        #expect(ApplicationIdleTimerPolicy.directive(
            actionIsAutomated: true,
            applicationIsActive: false,
            applicationIsHeld: false,
            hasTimer: false
        ) == .startNow)
    }

    @Test("A VM stop remains pending until the last Windows app disappears")
    func postStopCleanupWaitsForGuestApps() {
        var tracker = ParallelsDesktopStopCleanupTracker()

        #expect(tracker.observe(.running) == .none)
        #expect(tracker.observe(.stopped) == .schedule)
        #expect(tracker.verify(
            processState: .stopped,
            runningSharedApplicationProcessIdentifiers: [102]
        ) == .retry)
        #expect(tracker.verify(
            processState: .stopped,
            runningSharedApplicationProcessIdentifiers: []
        ) == .quit)
        #expect(tracker.verify(
            processState: .stopped,
            runningSharedApplicationProcessIdentifiers: []
        ) == .none)
    }

    @Test("An unavailable snapshot keeps pending VM stop cleanup alive")
    func unavailableSnapshotRetriesPostStopCleanup() {
        var tracker = ParallelsDesktopStopCleanupTracker()
        #expect(tracker.observe(.running) == .none)
        #expect(tracker.observe(.stopped) == .schedule)
        #expect(tracker.verify(
            processState: .unavailable,
            runningSharedApplicationProcessIdentifiers: []
        ) == .retry)
        #expect(tracker.verify(
            processState: .stopped,
            runningSharedApplicationProcessIdentifiers: []
        ) == .quit)
    }

    @Test("A VM restart cancels pending Parallels quit cleanup")
    func virtualMachineRestartCancelsPostStopCleanup() {
        var tracker = ParallelsDesktopStopCleanupTracker()
        #expect(tracker.observe(.running) == .none)
        #expect(tracker.observe(.stopped) == .schedule)
        #expect(tracker.verify(
            processState: .running,
            runningSharedApplicationProcessIdentifiers: []
        ) == .cancel)
        #expect(tracker.verify(
            processState: .stopped,
            runningSharedApplicationProcessIdentifiers: []
        ) == .none)
    }

    @Test("A running shared Windows app counts as VM use")
    func runningSharedAppCountsAsInUse() {
        #expect(ParallelsVirtualMachineProtectionPolicy
            .virtualMachineIsInUse(
                runningSharedApplicationProcessIdentifiers: [105]
            ))
    }

    @Test("A running Windows app keeps Windows and its VM open in the background")
    func backgroundSharedAppKeepsWindowsAndVMOpen() {
        let virtualMachineIsInUse =
            ParallelsVirtualMachineProtectionPolicy.virtualMachineIsInUse(
                runningSharedApplicationProcessIdentifiers: [105]
            )

        #expect(virtualMachineIsInUse)
        #expect(ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: desktopBundleIdentifier,
            processState: .running,
            virtualMachineIsInUse: virtualMachineIsInUse
        ))
        #expect(ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier:
                "com.parallels.winapp.8c4731f1a5288444bb2510ff8d967cc3.3ee4fe402df84873871f0f278370168d.fs",
            processState: .running,
            virtualMachineIsInUse: virtualMachineIsInUse
        ))
    }

    @Test("A running Windows Dock Helper stays open while guest apps are open")
    func protectsWindowsDockHelperWhileGuestAppsRun() {
        let dockHelperBundleIdentifier =
            "com.parallels.winapp.8c4731f1a5288444bb2510ff8d967cc3.3ee4fe402df84873871f0f278370168d.fs"

        #expect(ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: dockHelperBundleIdentifier,
            processState: .running,
            virtualMachineIsInUse: true
        ))
        #expect(!ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: dockHelperBundleIdentifier,
            processState: .running,
            virtualMachineIsInUse: false
        ))
        #expect(ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: "com.example.parallels-helper",
            applicationURL: URL(
                fileURLWithPath:
                    "/Users/test/Applications (Parallels)/{vm-id} Applications.localized/Windows 11 Dock Helper.app"
            ),
            processState: .running,
            virtualMachineIsInUse: true
        ))
    }

    @Test("A Parallels window on another desktop does not block an idle timer")
    func parallelsWindowOnAnotherDesktopDoesNotBlockIdleTimer() {
        let shouldDefer =
            ParallelsVirtualMachineProtectionPolicy
                .shouldDeferAutomaticActionForInactiveSpaceWindow(
                    bundleIdentifier: desktopBundleIdentifier,
                    hasVisibleWindowOnAnotherSpace: true
                )
        #expect(!shouldDefer)
        #expect(ApplicationIdleTimerPolicy.directive(
            actionIsAutomated: true,
            applicationIsActive: false,
            applicationIsHeld: false,
            applicationHasVisibleWindowOnAnotherSpace: shouldDefer,
            hasTimer: false
        ) == .startNow)
        #expect(!ParallelsVirtualMachineProtectionPolicy
            .shouldDeferAutomaticActionForInactiveSpaceWindow(
                bundleIdentifier:
                    "com.parallels.winapp.8c4731f1a5288444bb2510ff8d967cc3.3ee4fe402df84873871f0f278370168d.fs",
                hasVisibleWindowOnAnotherSpace: true
            ))
        #expect(ParallelsVirtualMachineProtectionPolicy
            .shouldDeferAutomaticActionForInactiveSpaceWindow(
                bundleIdentifier:
                    "com.parallels.winapp.07a094a210794e74a0e5e1a1457a92ee.3ee4fe402df84873871f0f278370168d",
                hasVisibleWindowOnAnotherSpace: true
            ))
    }

    @Test("An unknown VM process scan holds Parallels Desktop")
    func unavailableProcessScanFailsClosed() {
        let processState = ParallelsVirtualMachineProtectionPolicy.processState(
            executableNames: nil
        )

        #expect(processState == .unavailable)
        #expect(ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: desktopBundleIdentifier,
            processState: processState,
            virtualMachineIsInUse: false
        ))
    }

    @Test("An idle Parallels shared app can still reach its timer")
    func idleSharedAppIsNotProtected() {
        #expect(!ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier:
                "com.parallels.winapp.07a094a210794e74a0e5e1a1457a92ee.3ee4fe402df84873871f0f278370168d",
            processState: .running,
            virtualMachineIsInUse: false
        ))
    }

    @Test("A VM does not hold unrelated applications")
    func runningVirtualMachineDoesNotProtectOtherApps() {
        #expect(!ParallelsVirtualMachineProtectionPolicy.shouldProtect(
            bundleIdentifier: "com.example.editor",
            processState: .running,
            virtualMachineIsInUse: true
        ))
    }

    @Test("The Parallels Desktop app path is recognized when its bundle ID differs")
    func appPathRecognizesAlternateBundleIdentifier() {
        #expect(ParallelsVirtualMachineProtectionPolicy.isParallelsDesktop(
            bundleIdentifier: "com.example.parallels-edition",
            applicationURL: URL(
                fileURLWithPath: "/Applications/Parallels Desktop.app"
            )
        ))
    }

}
