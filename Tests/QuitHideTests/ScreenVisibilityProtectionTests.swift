import Foundation
import Testing
@testable import QuitHide

@Suite("Screen visibility protection")
struct ScreenVisibilityProtectionTests {
    private let target = "com.example.target"
    private let secondTarget = "com.example.second-target"
    private let foreground = "com.example.foreground"

    @Test("Side-by-side apps both remain protected")
    func sideBySideAppsRemainProtected() {
        let result = evaluate(
            windows: [
                window(secondTarget, x: 500, width: 500),
                window(target, width: 500)
            ],
            automaticBundles: [target, secondTarget]
        )

        #expect(result.protectedBundleIdentifiers == [target, secondTarget])
        #expect(result.uncertainBundleIdentifiers.isEmpty)
    }

    @Test("A front opaque normal window can fully cover an automatic app")
    func opaqueWindowFullyCoversTarget() {
        let result = evaluate(
            windows: [
                window(foreground),
                window(target)
            ]
        )

        #expect(result.protectedBundleIdentifiers.isEmpty)
    }

    @Test("Multiple front windows can jointly cover a target")
    func multipleWindowsJointlyCoverTarget() {
        let result = evaluate(
            windows: [
                window(foreground, width: 500),
                window("com.example.other", x: 500, width: 500),
                window(target)
            ]
        )

        #expect(result.protectedBundleIdentifiers.isEmpty)
    }

    @Test("Any uncovered area protects the target")
    func smallUncoveredAreaProtectsTarget() {
        let result = evaluate(
            windows: [
                window(foreground, width: 499),
                window("com.example.other", x: 500, width: 500),
                window(target)
            ]
        )

        #expect(result.protectedBundleIdentifiers == [target])
    }

    @Test("An app without an automatic rule can still be an occluder")
    func nonAutomaticAppCanOcclude() {
        let result = evaluate(
            windows: [
                window(foreground),
                window(target)
            ],
            automaticBundles: [target]
        )

        #expect(result.protectedBundleIdentifiers.isEmpty)
    }

    @Test("Any visible window protects every window of the same bundle")
    func anyVisibleWindowProtectsBundle() {
        let result = evaluate(
            windows: [
                window(foreground),
                window(target),
                window(target, x: 1_100, y: 100, width: 200, height: 200)
            ],
            displays: [
                display(1, width: 1_400)
            ]
        )

        #expect(result.protectedBundleIdentifiers == [target])
    }

    @Test("Windows behind a target cannot occlude it")
    func windowsBehindTargetDoNotOcclude() {
        let result = evaluate(
            windows: [
                window(target),
                window(foreground)
            ]
        )

        #expect(result.protectedBundleIdentifiers == [target])
    }

    @Test("A translucent front window cannot safely release protection")
    func translucentWindowDoesNotOcclude() {
        let result = evaluate(
            windows: [
                window(foreground, isOpaque: false),
                window(target)
            ]
        )

        #expect(result.protectedBundleIdentifiers == [target])
    }

    @Test("A non-normal front window cannot safely release protection")
    func nonNormalWindowDoesNotOcclude() {
        let result = evaluate(
            windows: [
                window(foreground, isNormalLayer: false),
                window(target)
            ]
        )

        #expect(result.protectedBundleIdentifiers == [target])
    }

    @Test("An invalid occluder is ignored conservatively")
    func invalidOccluderDoesNotOcclude() {
        let result = evaluate(
            windows: [
                ScreenVisibilityWindow(
                    bundleIdentifier: foreground,
                    frame: CGRect(
                        x: CGFloat.nan,
                        y: 0,
                        width: 1_000,
                        height: 800
                    ),
                    isOpaque: true,
                    isNormalLayer: true
                ),
                window(target)
            ]
        )

        #expect(result.protectedBundleIdentifiers == [target])
        #expect(result.uncertainBundleIdentifiers.isEmpty)
    }

    @Test("Invalid target geometry protects that bundle as uncertain")
    func invalidTargetGeometryFailsClosed() {
        let result = evaluate(
            windows: [
                ScreenVisibilityWindow(
                    bundleIdentifier: target,
                    frame: CGRect(
                        x: 0,
                        y: 0,
                        width: CGFloat.infinity,
                        height: 800
                    ),
                    isOpaque: true,
                    isNormalLayer: true
                )
            ]
        )

        #expect(result.protectedBundleIdentifiers == [target])
        #expect(result.uncertainBundleIdentifiers == [target])
    }

    @Test("Only the portion intersecting a display needs to be covered")
    func offscreenAreaIsClipped() {
        let result = evaluate(
            windows: [
                window(foreground, width: 500),
                window(target, x: -500)
            ]
        )

        #expect(result.protectedBundleIdentifiers.isEmpty)
    }

    @Test("A window spanning displays is protected if either display remains visible")
    func spanningWindowNeedsCoverageOnEveryDisplay() {
        let result = evaluate(
            windows: [
                window(foreground, width: 1_000),
                window(target, width: 2_000)
            ],
            displays: [
                display(1),
                display(2, x: 1_000)
            ]
        )

        #expect(result.protectedBundleIdentifiers == [target])
    }

    @Test("A window spanning displays is released when both parts are covered")
    func spanningWindowCanBeCoveredAcrossDisplays() {
        let result = evaluate(
            windows: [
                window(foreground, width: 1_000),
                window("com.example.second-foreground", x: 1_000, width: 1_000),
                window(target, width: 2_000)
            ],
            displays: [
                display(1),
                display(2, x: 1_000)
            ]
        )

        #expect(result.protectedBundleIdentifiers.isEmpty)
    }

    @Test("An app with no on-screen window is not protected")
    func noOnscreenWindowIsNotProtected() {
        let result = evaluate(windows: [])

        #expect(result.protectedBundleIdentifiers.isEmpty)
    }

    @Test("An invalid display snapshot protects all automatic bundles")
    func invalidDisplaysFailClosed() {
        let result = evaluate(
            windows: [],
            displays: [],
            automaticBundles: [target, secondTarget]
        )

        #expect(result.protectedBundleIdentifiers == [target, secondTarget])
        #expect(result.uncertainBundleIdentifiers == [target, secondTarget])
    }

    @Test("Same-bundle windows never hide their own app")
    func sameBundleDoesNotOccludeItself() {
        let result = evaluate(
            windows: [
                window(target),
                window(target)
            ]
        )

        #expect(result.protectedBundleIdentifiers == [target])
    }

    @Test("Explicitly invisible or zero-size WindowServer records are skipped")
    func invisibleWindowRecordsAreSkipped() {
        let normalFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        #expect(!ScreenVisibilityWindowEligibility.shouldIncludeOnscreenWindow(
            frame: normalFrame,
            alpha: 0
        ))
        #expect(!ScreenVisibilityWindowEligibility.shouldIncludeOnscreenWindow(
            frame: CGRect(x: 0, y: 0, width: 0, height: 800),
            alpha: 1
        ))
        #expect(ScreenVisibilityWindowEligibility.shouldIncludeOnscreenWindow(
            frame: normalFrame,
            alpha: nil
        ))
        #expect(ScreenVisibilityWindowEligibility.shouldIncludeOnscreenWindow(
            frame: CGRect(
                x: CGFloat.nan,
                y: 0,
                width: 1_000,
                height: 800
            ),
            alpha: 1
        ))
    }

    private func evaluate(
        windows: [ScreenVisibilityWindow],
        displays: [ScreenVisibilityDisplay] = [
            ScreenVisibilityDisplay(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            )
        ],
        automaticBundles: Set<String>? = nil
    ) -> ScreenVisibilityProtectionEvaluation {
        ScreenVisibilityProtectionPolicy.evaluate(
            snapshot: ScreenVisibilitySnapshot(
                windowsFrontToBack: windows,
                displays: displays
            ),
            automaticBundleIdentifiers: automaticBundles ?? [target]
        )
    }

    private func window(
        _ bundleIdentifier: String,
        x: CGFloat = 0,
        y: CGFloat = 0,
        width: CGFloat = 1_000,
        height: CGFloat = 800,
        isOpaque: Bool = true,
        isNormalLayer: Bool = true
    ) -> ScreenVisibilityWindow {
        ScreenVisibilityWindow(
            bundleIdentifier: bundleIdentifier,
            frame: CGRect(x: x, y: y, width: width, height: height),
            isOpaque: isOpaque,
            isNormalLayer: isNormalLayer
        )
    }

    private func display(
        _ displayID: UInt32,
        x: CGFloat = 0,
        y: CGFloat = 0,
        width: CGFloat = 1_000,
        height: CGFloat = 800
    ) -> ScreenVisibilityDisplay {
        ScreenVisibilityDisplay(
            displayID: displayID,
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}
