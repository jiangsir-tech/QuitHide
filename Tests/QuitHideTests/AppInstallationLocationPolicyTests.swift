import Foundation
import Testing
@testable import QuitHide

@Suite("App installation location policy")
struct AppInstallationLocationPolicyTests {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    @Test("The system Applications folder is a recommended location")
    func systemApplications() {
        let result = evaluate("/Applications/QuitHide.app")

        #expect(result == .installed)
        #expect(result.shouldPromptToMove == false)
        #expect(result.reminderReason == nil)
    }

    @Test("Subfolders of the system Applications folder are supported")
    func systemApplicationsSubfolder() {
        #expect(evaluate(
            "/Applications/Utilities/QuitHide.app"
        ) == .installed)
    }

    @Test("The current user's Applications folder is recommended")
    func userApplications() {
        #expect(evaluate(
            "/Users/example/Applications/QuitHide.app"
        ) == .installed)
    }

    @Test("Path comparison is standardized and case insensitive")
    func standardizedCaseInsensitivePath() {
        #expect(evaluate(
            "/aPpLiCaTiOnS/Temporary/../QuitHide.app/"
        ) == .installed)
        #expect(evaluate(
            "/uSeRs/ExAmPlE/aPpLiCaTiOnS/QuitHide.app"
        ) == .installed)
    }

    @Test("A similarly named folder is not treated as Applications")
    func applicationsNameMustBeAWholeComponent() {
        #expect(evaluate(
            "/Applications Backup/QuitHide.app"
        ) == .needsMove(.otherLocation))
    }

    @Test("Apps launched from a mounted volume need to move")
    func mountedVolume() {
        let result = evaluate("/Volumes/QuitHide/QuitHide.app")

        #expect(result == .needsMove(.volume))
        #expect(result.shouldPromptToMove)
        #expect(result.reminderReason == .volume)
    }

    @Test("Apps launched from Downloads need to move")
    func downloads() {
        #expect(evaluate(
            "/Users/example/Downloads/QuitHide/QuitHide.app"
        ) == .needsMove(.downloads))
    }

    @Test("App Translocation has a dedicated reason")
    func appTranslocation() {
        #expect(evaluate(
            "/private/var/folders/xy/random/AppTranslocation/ABC/d/QuitHide.app"
        ) == .needsMove(.appTranslocation))
    }

    @Test("An unrelated AppTranslocation substring is not misclassified")
    func appTranslocationMustBeAWholeComponent() {
        #expect(evaluate(
            "/Users/example/Desktop/AppTranslocation-Notes/QuitHide.app"
        ) == .needsMove(.otherLocation))
    }

    @Test("Desktop and arbitrary paths need to move")
    func otherLocations() {
        #expect(evaluate(
            "/Users/example/Desktop/QuitHide.app"
        ) == .needsMove(.otherLocation))
        #expect(evaluate(
            "/opt/apps/QuitHide.app"
        ) == .needsMove(.otherLocation))
    }

    @Test("A symbolic link is resolved before classifying the location")
    func symbolicLink() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let temporaryHome = temporaryRoot.appendingPathComponent(
            "Home",
            isDirectory: true
        )
        let applications = temporaryHome.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        let app = applications.appendingPathComponent(
            "QuitHide.app",
            isDirectory: true
        )
        let alias = temporaryRoot.appendingPathComponent(
            "Applications Alias",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: app,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: alias,
            withDestinationURL: applications
        )

        let result = AppInstallationLocationPolicy.evaluate(
            bundleURL: alias.appendingPathComponent(
                "QuitHide.app",
                isDirectory: true
            ),
            homeDirectoryURL: temporaryHome
        )

        #expect(result == .installed)
    }

    @Test("Reminder reasons expose stable localization keys")
    func localizationKeys() {
        #expect(
            AppInstallationLocationReminderReason.appTranslocation.rawValue
                == "app_installation.reason.app_translocation"
        )
        #expect(
            AppInstallationLocationReminderReason.volume.rawValue
                == "app_installation.reason.volume"
        )
        #expect(
            AppInstallationLocationReminderReason.downloads.rawValue
                == "app_installation.reason.downloads"
        )
        #expect(
            AppInstallationLocationReminderReason.otherLocation.rawValue
                == "app_installation.reason.other_location"
        )
    }

    private func evaluate(_ path: String) -> AppInstallationLocationResult {
        AppInstallationLocationPolicy.evaluate(
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            homeDirectoryURL: home
        )
    }
}
