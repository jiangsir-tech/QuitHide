import Foundation
import Testing
@testable import QuitHide

@Suite("Update checker version comparison")
struct UpdateCheckerTests {
    @Test("Stable release is newer than its prerelease")
    func stableReleaseIsNewerThanPrerelease() throws {
        let prerelease = try #require(SemanticVersion("0.2.1-beta.2"))
        let stable = try #require(SemanticVersion("0.2.1"))
        #expect(prerelease < stable)
    }

    @Test("Prerelease components use numeric comparison")
    func prereleaseComponentsUseNumericComparison() throws {
        let betaNine = try #require(SemanticVersion("v0.3.0-beta.9"))
        let betaTen = try #require(SemanticVersion("v0.3.0-beta.10"))
        #expect(betaNine < betaTen)
    }

    @Test("Numeric prerelease identifiers sort before text identifiers")
    func numericPrereleaseSortsBeforeText() throws {
        let numeric = try #require(SemanticVersion("1.0.0-1"))
        let text = try #require(SemanticVersion("1.0.0-alpha"))
        #expect(numeric < text)
    }

    @Test("Build metadata does not affect precedence")
    func buildMetadataDoesNotAffectPrecedence() throws {
        let withMetadata = try #require(SemanticVersion("1.2.3+build.9"))
        let plain = try #require(SemanticVersion("1.2.3"))
        #expect(withMetadata == plain)
    }

    @Test("Invalid versions are rejected")
    func invalidVersionsAreRejected() {
        #expect(SemanticVersion("beta") == nil)
        #expect(SemanticVersion("0.x.1") == nil)
        #expect(SemanticVersion("1.0.0-") == nil)
        #expect(SemanticVersion("1.0.0+") == nil)
        #expect(SemanticVersion("1.2") == nil)
        #expect(SemanticVersion("01.2.3") == nil)
        #expect(SemanticVersion("1.02.3") == nil)
        #expect(SemanticVersion("1.2.03") == nil)
        #expect(SemanticVersion("1.0.0-alpha..1") == nil)
        #expect(SemanticVersion("1.0.0-alpha_1") == nil)
        #expect(SemanticVersion("1.0.0-01") == nil)
        #expect(SemanticVersion("1.0.0+build..1") == nil)
    }

    @Test("Prerelease text comparison is case-sensitive and totally ordered")
    func prereleaseTextUsesASCIIPrecedence() throws {
        let uppercase = try #require(SemanticVersion("1.0.0-ALPHA"))
        let lowercase = try #require(SemanticVersion("1.0.0-alpha"))
        #expect(uppercase != lowercase)
        #expect(uppercase < lowercase)
        #expect(!(lowercase < uppercase))
    }

    @Test("Arbitrarily large numeric prerelease identifiers compare without overflow")
    func largeNumericPrereleaseComparison() throws {
        let smaller = try #require(SemanticVersion("1.0.0-999999999999999999999999999999"))
        let larger = try #require(SemanticVersion("1.0.0-1000000000000000000000000000000"))
        #expect(smaller < larger)
    }

    @Test("Semantic versions normalize a tag prefix and discard build metadata")
    func normalizedVersion() throws {
        let version = try #require(SemanticVersion("V1.2.3-beta.4+build.8"))
        #expect(version.normalizedString == "1.2.3-beta.4")
        #expect(version == SemanticVersion("1.2.3-beta.4"))
    }

    @Test("A newer version wins even when its build is lower")
    func newerVersionWinsWithLowerBuild() throws {
        #expect(UpdateChecker.isUpdateNewer(
            currentVersion: try #require(SemanticVersion("0.2.2")),
            currentBuild: 40,
            availableVersion: try #require(SemanticVersion("0.3.0")),
            availableBuild: 1
        ))
    }

    @Test("The same version requires a newer build")
    func sameVersionRequiresNewerBuild() throws {
        let version = try #require(SemanticVersion("0.2.2"))
        #expect(UpdateChecker.isUpdateNewer(
            currentVersion: version,
            currentBuild: 4,
            availableVersion: version,
            availableBuild: 5
        ))
        #expect(!UpdateChecker.isUpdateNewer(
            currentVersion: version,
            currentBuild: 4,
            availableVersion: version,
            availableBuild: 4
        ))
    }

    @Test("Update reminder identity includes the build when available")
    func reminderIdentityIncludesBuild() throws {
        let url = try #require(URL(string: "https://example.com/download"))
        let buildUpdate = AvailableUpdate(
            version: "0.2.4",
            build: 10,
            releaseNotes: "",
            downloadURL: url
        )
        let releaseUpdate = AvailableUpdate(
            version: "0.2.5",
            build: nil,
            releaseNotes: "",
            downloadURL: url
        )
        #expect(buildUpdate.reminderIdentity == UpdateReleaseIdentity(
            version: "0.2.4",
            build: 10
        ))
        #expect(releaseUpdate.reminderIdentity == UpdateReleaseIdentity(
            version: "0.2.5",
            build: nil
        ))
    }

    @Test("An available update can be cached and restored")
    func availableUpdateCodableRoundTrip() throws {
        let update = AvailableUpdate(
            version: "0.3.0",
            build: 12,
            releaseNotes: "修复问题",
            downloadURL: try #require(URL(string: "https://example.com/download"))
        )
        let data = try JSONEncoder().encode(update)
        #expect(try JSONDecoder().decode(AvailableUpdate.self, from: data) == update)
    }

    @Test("Only this repository's HTTPS Releases URLs are accepted")
    func validatesDownloadURL() throws {
        #expect(UpdateChecker.isAllowedDownloadURL(try #require(URL(
            string: "https://github.com/jiangsir-tech/QuitHide/releases/tag/v0.3.0"
        ))))
        #expect(!UpdateChecker.isAllowedDownloadURL(try #require(URL(
            string: "http://github.com/jiangsir-tech/QuitHide/releases/tag/v0.3.0"
        ))))
        #expect(!UpdateChecker.isAllowedDownloadURL(try #require(URL(
            string: "https://github.com/attacker/QuitHide/releases/tag/v0.3.0"
        ))))
        #expect(!UpdateChecker.isAllowedDownloadURL(try #require(URL(
            string: "https://github.com/jiangsir-tech/QuitHide/issues"
        ))))
        #expect(!UpdateChecker.isAllowedDownloadURL(try #require(URL(
            string: "file:///Applications/Calculator.app"
        ))))
    }

    @Test("Cached updates require a known compatible system and allowed URL")
    func validatesCachedUpdate() throws {
        let validURL = try #require(URL(
            string: "https://github.com/jiangsir-tech/QuitHide/releases/tag/v0.3.0"
        ))
        let compatible = AvailableUpdate(
            version: "v0.3.0",
            build: 10,
            minimumSystemVersion: "13.0",
            releaseNotes: "",
            downloadURL: validURL
        )
        let macOS13 = try #require(MacOSVersion("13.0"))
        let validated = try #require(UpdateChecker.validatedAvailableUpdate(
            compatible,
            currentSystemVersion: macOS13
        ))
        #expect(validated.version == "0.3.0")

        let incompatible = AvailableUpdate(
            version: "0.3.0",
            build: 10,
            minimumSystemVersion: "14.0",
            releaseNotes: "",
            downloadURL: validURL
        )
        let macOS13Point6 = try #require(MacOSVersion("13.6"))
        #expect(UpdateChecker.validatedAvailableUpdate(
            incompatible,
            currentSystemVersion: macOS13Point6
        ) == nil)

        let unknownCompatibility = AvailableUpdate(
            version: "0.3.0",
            build: 10,
            releaseNotes: "",
            downloadURL: validURL
        )
        #expect(UpdateChecker.validatedAvailableUpdate(
            unknownCompatibility,
            currentSystemVersion: macOS13Point6
        ) == nil)
    }
}
