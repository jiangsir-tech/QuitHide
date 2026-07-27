import Foundation

/// The reason QuitHide should ask the user to move and reopen the app.
///
/// Raw values are stable localization keys so the UI can map a reason to
/// language-specific copy without deriving presentation text from a path.
enum AppInstallationLocationReminderReason: String, Equatable, Sendable {
    case appTranslocation = "app_installation.reason.app_translocation"
    case volume = "app_installation.reason.volume"
    case downloads = "app_installation.reason.downloads"
    case otherLocation = "app_installation.reason.other_location"
}

enum AppInstallationLocationResult: Equatable, Sendable {
    case installed
    case needsMove(AppInstallationLocationReminderReason)

    var shouldPromptToMove: Bool {
        reminderReason != nil
    }

    var reminderReason: AppInstallationLocationReminderReason? {
        guard case let .needsMove(reason) = self else { return nil }
        return reason
    }
}

/// Decides whether the running app is in one of the two supported application
/// folders. The public entry point is safe to call with `Bundle.main.bundleURL`
/// during app startup and has no side effects.
enum AppInstallationLocationPolicy {
    static func evaluate(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppInstallationLocationResult {
        let bundle = NormalizedPath(bundleURL)
        let systemApplications = NormalizedPath(
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        )
        let userApplications = NormalizedPath(
            homeDirectoryURL.appendingPathComponent("Applications", isDirectory: true)
        )

        if bundle.isDescendant(of: systemApplications)
            || bundle.isDescendant(of: userApplications) {
            return .installed
        }

        // App Translocation is more actionable than its enclosing temporary
        // path, so detect it before other unsupported locations.
        if bundle.containsComponent("AppTranslocation") {
            return .needsMove(.appTranslocation)
        }

        let volumes = NormalizedPath(
            URL(fileURLWithPath: "/Volumes", isDirectory: true)
        )
        if bundle.isDescendant(of: volumes) {
            return .needsMove(.volume)
        }

        let downloads = NormalizedPath(
            homeDirectoryURL.appendingPathComponent("Downloads", isDirectory: true)
        )
        if bundle.isDescendant(of: downloads) {
            return .needsMove(.downloads)
        }

        return .needsMove(.otherLocation)
    }
}

private struct NormalizedPath {
    private let components: [String]

    init(_ url: URL) {
        components = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
            .map { $0.lowercased() }
    }

    func isDescendant(of parent: NormalizedPath) -> Bool {
        components.count > parent.components.count
            && components.starts(with: parent.components)
    }

    func containsComponent(_ component: String) -> Bool {
        components.contains(component.lowercased())
    }
}
