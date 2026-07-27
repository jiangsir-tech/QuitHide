import AppKit

@MainActor
final class QuitHideApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleURL = Bundle.main.bundleURL

        // `swift run` and test executables are not packaged application
        // bundles. Only the distributed .app should present installation UI.
        guard bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              case let .needsMove(reason) = AppInstallationLocationPolicy.evaluate(
                  bundleURL: bundleURL
              ) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.presentInstallationReminder(
                reason: reason,
                bundleURL: bundleURL
            )
        }
    }

    private func presentInstallationReminder(
        reason: AppInstallationLocationReminderReason,
        bundleURL: URL
    ) {
        let savedPreference = UserDefaults.standard.string(
            forKey: "languagePreference"
        ).flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
        let localization = AppLocalization(preference: savedPreference)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = localization.text(.appInstallationTitle)
        alert.informativeText = localization.text(reason.localizationKey)
        let primaryActionKey: L10n.Key = reason == .appTranslocation
            ? .appInstallationOpenApplicationsAndQuit
            : .appInstallationRevealAndQuit
        alert.addButton(withTitle: localization.text(primaryActionKey))
        alert.addButton(withTitle: localization.text(.appInstallationContinue))

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if reason == .appTranslocation {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/Applications", isDirectory: true)
            )
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
        NSApp.terminate(nil)
    }
}

private extension AppInstallationLocationReminderReason {
    var localizationKey: L10n.Key {
        switch self {
        case .appTranslocation:
            return .appInstallationReasonAppTranslocation
        case .volume:
            return .appInstallationReasonVolume
        case .downloads:
            return .appInstallationReasonDownloads
        case .otherLocation:
            return .appInstallationReasonOtherLocation
        }
    }
}
