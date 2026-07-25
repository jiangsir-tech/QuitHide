import Foundation

enum MenuHeightPolicy {
    static let minimumWindowHeight = 380.0
    static let maximumWindowHeight = 620.0

    private static let fixedChromeHeight = 198.0
    private static let listVerticalPadding = 14.0
    private static let appRowHeight = 40.0
    private static let sectionHeaderHeight = 28.0
    private static let rowDividerHeight = 1.0
    private static let maximumSectionCount = 4

    static func windowHeight(
        runningAppCount: Int,
        runningSectionCount: Int
    ) -> Double {
        let appCount = max(runningAppCount, 0)
        let sectionCount = min(
            max(runningSectionCount, 0),
            min(appCount, maximumSectionCount)
        )
        let dividerCount = max(appCount - sectionCount, 0)
        let desiredHeight = fixedChromeHeight
            + listVerticalPadding
            + Double(appCount) * appRowHeight
            + Double(sectionCount) * sectionHeaderHeight
            + Double(dividerCount) * rowDividerHeight

        return min(
            maximumWindowHeight,
            max(minimumWindowHeight, desiredHeight)
        )
    }
}
