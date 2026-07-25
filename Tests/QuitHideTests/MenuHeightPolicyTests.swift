import Testing
@testable import QuitHide

@Suite("Menu window height policy")
struct MenuHeightPolicyTests {
    @Test("The menu keeps a usable minimum and the existing maximum")
    func bounds() {
        #expect(MenuHeightPolicy.minimumWindowHeight == 380)
        #expect(MenuHeightPolicy.maximumWindowHeight == 620)
    }

    @Test("An empty or very short running list uses the minimum height")
    func minimumHeight() {
        #expect(MenuHeightPolicy.windowHeight(
            runningAppCount: 0,
            runningSectionCount: 0
        ) == 380)
        #expect(MenuHeightPolicy.windowHeight(
            runningAppCount: 3,
            runningSectionCount: 1
        ) == 380)
    }

    @Test("Rows and visible running groups grow the menu predictably")
    func contentHeight() {
        #expect(MenuHeightPolicy.windowHeight(
            runningAppCount: 4,
            runningSectionCount: 1
        ) == 403)
        #expect(MenuHeightPolicy.windowHeight(
            runningAppCount: 6,
            runningSectionCount: 2
        ) == 512)
        #expect(MenuHeightPolicy.windowHeight(
            runningAppCount: 8,
            runningSectionCount: 2
        ) == 594)
    }

    @Test("Long running lists stop at the scrolling height")
    func maximumHeight() {
        #expect(MenuHeightPolicy.windowHeight(
            runningAppCount: 9,
            runningSectionCount: 2
        ) == 620)
        #expect(MenuHeightPolicy.windowHeight(
            runningAppCount: 100,
            runningSectionCount: 100
        ) == 620)
    }

    @Test("Several running groups can reach the scrolling height sooner")
    func groupedMaximumHeight() {
        #expect(MenuHeightPolicy.windowHeight(
            runningAppCount: 8,
            runningSectionCount: 4
        ) == 620)
    }

    @Test("Invalid negative inputs behave like an empty running list")
    func invalidInputs() {
        #expect(MenuHeightPolicy.windowHeight(
            runningAppCount: -2,
            runningSectionCount: -1
        ) == 380)
    }
}
