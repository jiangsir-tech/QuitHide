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
}
