import AppKit
import Foundation
import Sparkle

enum LegacyAutomaticUpdateChecksMigration {
    static let completionKey = "didMigrateAutomaticUpdateChecksToSparkleV1"
    static let automaticChecksKey = "automaticUpdateChecksEnabled"

    private static let obsoleteKeys = [
        automaticChecksKey,
        "lastAutomaticUpdateCheckAt",
        "skippedUpdateIdentity",
        "updateRemindAfter",
        "cachedAvailableUpdate"
    ]

    static func migrate(
        defaults: UserDefaults,
        applyAutomaticChecksPreference: (Bool) -> Void
    ) {
        guard !defaults.bool(forKey: completionKey) else { return }

        if defaults.object(forKey: automaticChecksKey) != nil {
            applyAutomaticChecksPreference(defaults.bool(forKey: automaticChecksKey))
        }

        for key in obsoleteKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: completionKey)
    }
}

@MainActor
final class SparkleUpdateController: NSObject, ObservableObject {
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var pendingUpdateVersion: String?

    private var automaticChecksObservation: NSKeyValueObservation?
    private var canCheckObservation: NSKeyValueObservation?

    private lazy var standardController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    override init() {
        super.init()

        let updater = standardController.updater
        LegacyAutomaticUpdateChecksMigration.migrate(defaults: .standard) { enabled in
            updater.automaticallyChecksForUpdates = enabled
        }

        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        canCheckForUpdates = updater.canCheckForUpdates
        installObservations(for: updater)
        standardController.startUpdater()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard standardController.updater.automaticallyChecksForUpdates != enabled else { return }
        standardController.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard standardController.updater.canCheckForUpdates else { return }
        pendingUpdateVersion = nil
        NSApp.activate(ignoringOtherApps: true)
        standardController.checkForUpdates(nil)
    }

    private func installObservations(for updater: SPUUpdater) {
        automaticChecksObservation = updater.observe(
            \.automaticallyChecksForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let enabled = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = enabled
            }
        }

        canCheckObservation = updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let canCheck = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = canCheck
            }
        }
    }
}

extension SparkleUpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let Sparkle present urgent/user-relevant scheduled updates in focus.
        // Only quieter background reminders are represented by QuitHide's
        // menu-bar banner.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        pendingUpdateVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdateVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdateVersion = nil
    }
}
