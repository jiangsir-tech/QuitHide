import Foundation
import Testing
@testable import QuitHide

@Suite("Normal quit request response timeout")
struct QuitRequestPolicyTests {
    private let requestedAt = Date(timeIntervalSince1970: 1_000)

    @Test("The response timeout is fixed at 30 seconds")
    func timeoutDuration() {
        #expect(QuitRequestPolicy.responseTimeout == 30)
    }

    @Test("A new request is waiting")
    func newlyRequested() {
        #expect(QuitRequestPolicy.status(
            requestedAt: requestedAt,
            now: requestedAt
        ) == .waiting)
    }

    @Test("A request remains waiting immediately before the timeout")
    func immediatelyBeforeTimeout() {
        #expect(QuitRequestPolicy.status(
            requestedAt: requestedAt,
            now: requestedAt.addingTimeInterval(29.999)
        ) == .waiting)
    }

    @Test("The exact 30-second boundary is timed out")
    func exactTimeoutBoundary() {
        #expect(QuitRequestPolicy.status(
            requestedAt: requestedAt,
            now: requestedAt.addingTimeInterval(30)
        ) == .timedOut)
    }

    @Test("A request remains timed out after the boundary")
    func afterTimeoutBoundary() {
        #expect(QuitRequestPolicy.status(
            requestedAt: requestedAt,
            now: requestedAt.addingTimeInterval(300)
        ) == .timedOut)
    }

    @Test("A backwards clock remains waiting")
    func backwardsClock() {
        #expect(QuitRequestPolicy.status(
            requestedAt: requestedAt,
            now: requestedAt.addingTimeInterval(-60)
        ) == .waiting)
    }
}
