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
    func numericPrereleaseComparison() throws {
        let betaNine = try #require(SemanticVersion("v0.3.0-beta.9"))
        let betaTen = try #require(SemanticVersion("v0.3.0-beta.10"))
        #expect(betaNine < betaTen)
    }

    @Test("Minor versions compare correctly")
    func minorVersionComparison() throws {
        let current = try #require(SemanticVersion("0.2.9"))
        let update = try #require(SemanticVersion("0.3.0"))
        #expect(current < update)
    }

    @Test("Invalid versions are rejected")
    func invalidVersionIsRejected() {
        #expect(SemanticVersion("beta") == nil)
        #expect(SemanticVersion("0.x.1") == nil)
    }
}
