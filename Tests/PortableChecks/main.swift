import Foundation

private var failureCount = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS: \(message)")
    } else {
        failureCount += 1
        print("FAIL: \(message)")
    }
}

let pauseStart = Date(timeIntervalSince1970: 1_000)
var suspension = TimingSuspension()
suspension.suspend(for: .manualPause, at: pauseStart)
suspension.suspend(for: .systemSleep, at: pauseStart.addingTimeInterval(10))
expect(
    suspension.resume(for: .systemSleep, at: pauseStart.addingTimeInterval(100)) == nil,
    "overlapping sleep keeps the manual pause active"
)
expect(
    suspension.resume(for: .manualPause, at: pauseStart.addingTimeInterval(120)) == 120,
    "overlapping suspension shifts timers exactly once"
)

var retry = ActionRetryState()
retry.recordFailure(at: pauseStart, delay: 30)
expect(!retry.canAttempt(at: pauseStart.addingTimeInterval(29)), "retry observes cooldown")
expect(retry.canAttempt(at: pauseStart.addingTimeInterval(30)), "retry resumes after cooldown")
retry.recordFailure(at: pauseStart.addingTimeInterval(30), delay: 30)
retry.recordFailure(at: pauseStart.addingTimeInterval(60), delay: 30)
expect(!retry.canAttempt(at: pauseStart.addingTimeInterval(1_000)), "retry stops after three failures")

let prerelease = SemanticVersion("0.3.0-beta.9")!
let nextPrerelease = SemanticVersion("0.3.0-beta.10")!
expect(prerelease < nextPrerelease, "prerelease identifiers compare numerically")
expect(
    SemanticVersion("1.2.3+build.9") == SemanticVersion("1.2.3"),
    "build metadata does not affect precedence"
)
expect(SemanticVersion("1.0.0-") == nil, "empty prerelease is rejected")

expect(UpdateChecker.isUpdateNewer(
    currentVersion: SemanticVersion("0.2.2")!,
    currentBuild: 40,
    availableVersion: SemanticVersion("0.3.0")!,
    availableBuild: 1
), "newer semantic version wins even with a lower build")
expect(!UpdateChecker.isUpdateNewer(
    currentVersion: SemanticVersion("0.2.2")!,
    currentBuild: 4,
    availableVersion: SemanticVersion("0.2.2")!,
    availableBuild: 4
), "same version and build is up to date")

if failureCount > 0 {
    print("\(failureCount) regression check(s) failed.")
    exit(1)
}

print("All portable regression checks passed.")
