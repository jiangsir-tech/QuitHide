import ApplicationServices
import Testing
@testable import QuitHide

@Suite("Stage Manager accessibility attribute policy")
struct StageManagerGroupingProviderTests {
    @Test("Normal missing optional attributes remain non-fatal")
    func normalMissingOptionalAttributes() {
        #expect(StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXRoleAttribute as CFString,
            error: .attributeUnsupported,
            required: false
        ))
        #expect(StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXRoleAttribute as CFString,
            error: .noValue,
            required: false
        ))
    }

    @Test("WindowManager's missing optional identifier is non-fatal")
    func windowManagerIdentifierCompatibility() {
        #expect(StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXIdentifierAttribute as CFString,
            error: .illegalArgument,
            required: false
        ))
    }

    @Test("Illegal argument remains fatal outside the observed compatibility case")
    func illegalArgumentIsStillStrict() {
        #expect(!StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXIdentifierAttribute as CFString,
            error: .illegalArgument,
            required: true
        ))
        #expect(!StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXRoleAttribute as CFString,
            error: .illegalArgument,
            required: false
        ))
        #expect(!StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXIdentifierAttribute as CFString,
            error: .cannotComplete,
            required: false
        ))
    }
}

@Suite("Show Desktop detection policy")
struct StageManagerShowDesktopDetectionPolicyTests {
    private let desktopObservation = StageManagerShowDesktopObservation(
        frontmostProcessIdentifier: 42,
        frontmostBundleIdentifier: "com.example.frontmost",
        hasOrdinaryOnscreenApplicationWindow: false
    )

    @Test("Stable structural failure without an ordinary workspace window is detected")
    func detectsStableShowDesktopState() {
        #expect(isShowingDesktop(
            first: desktopObservation,
            second: desktopObservation
        ))
    }

    @Test("A non-structural accessibility failure is never relabeled")
    func requiresACompatibleStructureFailure() {
        #expect(!isShowingDesktop(
            compatibleStructureFailure: false,
            first: desktopObservation,
            second: desktopObservation
        ))
    }

    @Test("An ordinary visible application window is rejected")
    func requiresNoOrdinaryVisibleApplicationWindow() {
        #expect(!isShowingDesktop(
            first: StageManagerShowDesktopObservation(
                frontmostProcessIdentifier: 42,
                frontmostBundleIdentifier: "com.example.frontmost",
                hasOrdinaryOnscreenApplicationWindow: true
            ),
            second: StageManagerShowDesktopObservation(
                frontmostProcessIdentifier: 42,
                frontmostBundleIdentifier: "com.example.frontmost",
                hasOrdinaryOnscreenApplicationWindow: true
            )
        ))
    }

    @Test("Changing observations, pointer interaction, and Stage Manager off are rejected")
    func requiresStableIdleStageManagerObservations() {
        #expect(!isShowingDesktop(
            first: desktopObservation,
            second: StageManagerShowDesktopObservation(
                frontmostProcessIdentifier: 43,
                frontmostBundleIdentifier: "com.example.frontmost",
                hasOrdinaryOnscreenApplicationWindow: false
            )
        ))
        #expect(!isShowingDesktop(
            pointerInteraction: true,
            first: desktopObservation,
            second: desktopObservation
        ))
        #expect(!isShowingDesktop(
            stageManagerEnabled: false,
            first: desktopObservation,
            second: desktopObservation
        ))
    }

    private func isShowingDesktop(
        compatibleStructureFailure: Bool = true,
        stageManagerEnabled: Bool = true,
        pointerInteraction: Bool = false,
        first: StageManagerShowDesktopObservation,
        second: StageManagerShowDesktopObservation
    ) -> Bool {
        StageManagerShowDesktopDetectionPolicy.isShowingDesktop(
            normalReadFailedWithCompatibleStructureError:
                compatibleStructureFailure,
            stageManagerIsEnabled: stageManagerEnabled,
            isPointerInteractionInProgress: pointerInteraction,
            firstObservation: first,
            secondObservation: second
        )
    }
}

@Suite("Show Desktop window classification")
struct StageManagerShowDesktopWindowPolicyTests {
    private let displayFrame = CGRect(
        x: 0,
        y: 0,
        width: 2560,
        height: 1440
    )

    @Test("Small Stage Manager thumbnails at either edge are ignored")
    func edgeThumbnailsAreRecognized() {
        #expect(StageManagerShowDesktopWindowPolicy.isSidebarThumbnail(
            windowFrame: CGRect(x: 15, y: 650, width: 166, height: 161),
            displayFrames: [displayFrame]
        ))
        #expect(StageManagerShowDesktopWindowPolicy.isSidebarThumbnail(
            windowFrame: CGRect(x: 2379, y: 650, width: 166, height: 161),
            displayFrames: [displayFrame]
        ))
    }

    @Test("Central and large edge windows remain ordinary workspace windows")
    func ordinaryWindowsAreNotThumbnails() {
        #expect(!StageManagerShowDesktopWindowPolicy.isSidebarThumbnail(
            windowFrame: CGRect(x: 500, y: 300, width: 166, height: 161),
            displayFrames: [displayFrame]
        ))
        #expect(!StageManagerShowDesktopWindowPolicy.isSidebarThumbnail(
            windowFrame: CGRect(x: 0, y: 100, width: 900, height: 900),
            displayFrames: [displayFrame]
        ))
    }

    @Test("WindowServer records entirely outside every display are ignored")
    func offscreenRecordsAreNotWorkspaceWindows() {
        let offscreenThumbnail = CGRect(
            x: -269,
            y: 1021,
            width: 166,
            height: 184
        )

        #expect(!StageManagerShowDesktopWindowPolicy.isOrdinaryWorkspaceWindow(
            windowFrame: offscreenThumbnail,
            displayFrames: [displayFrame]
        ))
        #expect(StageManagerShowDesktopWindowPolicy.isOrdinaryWorkspaceWindow(
            windowFrame: CGRect(x: 500, y: 300, width: 800, height: 700),
            displayFrames: [displayFrame]
        ))
    }

    @Test("Windows on negative-origin secondary displays remain ordinary")
    func negativeOriginDisplaysAreHandled() {
        let secondaryDisplay = CGRect(
            x: -1920,
            y: 0,
            width: 1920,
            height: 1080
        )

        #expect(StageManagerShowDesktopWindowPolicy.isOrdinaryWorkspaceWindow(
            windowFrame: CGRect(
                x: -1500,
                y: 180,
                width: 900,
                height: 700
            ),
            displayFrames: [displayFrame, secondaryDisplay]
        ))
    }

    @Test("A partially visible window remains ordinary")
    func partiallyVisibleWindowsAreHandled() {
        #expect(StageManagerShowDesktopWindowPolicy.isOrdinaryWorkspaceWindow(
            windowFrame: CGRect(x: -100, y: 300, width: 800, height: 700),
            displayFrames: [displayFrame]
        ))
    }

    @Test("Touching a display edge without visible area remains offscreen")
    func zeroAreaIntersectionsAreIgnored() {
        #expect(!StageManagerShowDesktopWindowPolicy.isOrdinaryWorkspaceWindow(
            windowFrame: CGRect(x: -200, y: 300, width: 200, height: 700),
            displayFrames: [displayFrame]
        ))
    }

    @Test("Sidebar thumbnails are recognized on offset displays")
    func offsetDisplayThumbnailsAreRecognized() {
        let secondaryDisplay = CGRect(
            x: 2560,
            y: 100,
            width: 1920,
            height: 1080
        )

        #expect(StageManagerShowDesktopWindowPolicy.isSidebarThumbnail(
            windowFrame: CGRect(x: 2575, y: 650, width: 166, height: 161),
            displayFrames: [displayFrame, secondaryDisplay]
        ))
        #expect(StageManagerShowDesktopWindowPolicy.isSidebarThumbnail(
            windowFrame: CGRect(x: 4299, y: 650, width: 166, height: 161),
            displayFrames: [displayFrame, secondaryDisplay]
        ))
    }
}

@Suite("Stage Manager fullscreen fallback policy")
struct StageManagerFullscreenFallbackPolicyTests {
    private let chromeBundleIdentifier = "com.google.Chrome"
    private let ignoreBundleIdentifier = "com.example.ignore"
    private let hideBundleIdentifier = "com.example.hide"

    @Test("Fullscreen detection requires the complete display bounds")
    func fullscreenDetectionIsStrict() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        #expect(StageManagerFullscreenDetectionPolicy.matchesDisplayBounds(
            windowFrame: displayFrame,
            displayFrame: displayFrame
        ))
        #expect(StageManagerFullscreenDetectionPolicy.matchesDisplayBounds(
            windowFrame: displayFrame.insetBy(dx: -1, dy: -1),
            displayFrame: displayFrame
        ))
        #expect(!StageManagerFullscreenDetectionPolicy.matchesDisplayBounds(
            windowFrame: CGRect(x: 0, y: 25, width: 1512, height: 957),
            displayFrame: displayFrame
        ))
        #expect(!StageManagerFullscreenDetectionPolicy.matchesDisplayBounds(
            windowFrame: CGRect(x: 0, y: 0, width: 1482, height: 982),
            displayFrame: displayFrame
        ))
    }

    @Test("Fullscreen keeps only cached sidebar groups and adds the fullscreen app")
    func keepsSidebarGroupsAndReplacesForeground() throws {
        let cachedGroups = [
            StageManagerAppGroup(
                displayID: 1,
                placement: .foreground,
                bundleIdentifiers: ["com.example.old-foreground"]
            ),
            StageManagerAppGroup(
                displayID: 1,
                placement: .sidebar,
                bundleIdentifiers: [
                    ignoreBundleIdentifier,
                    hideBundleIdentifier
                ]
            )
        ]

        let snapshot = try #require(
            StageManagerFullscreenFallbackPolicy.snapshot(
                cachedSidebarGroups: cachedGroups,
                cacheAge: 5,
                fullscreenContext: StageManagerFullscreenContext(
                    bundleIdentifier: chromeBundleIdentifier,
                    displayID: 1
                )
            )
        )

        #expect(snapshot.groups == [
            StageManagerAppGroup(
                displayID: 1,
                placement: .foreground,
                bundleIdentifiers: [chromeBundleIdentifier]
            ),
            StageManagerAppGroup(
                displayID: 1,
                placement: .sidebar,
                bundleIdentifiers: [
                    ignoreBundleIdentifier,
                    hideBundleIdentifier
                ]
            )
        ])
    }

    @Test("A known empty sidebar still permits fullscreen protection")
    func knownEmptySidebarIsValid() throws {
        let snapshot = try #require(
            StageManagerFullscreenFallbackPolicy.snapshot(
                cachedSidebarGroups: [],
                cacheAge: 5,
                fullscreenContext: StageManagerFullscreenContext(
                    bundleIdentifier: chromeBundleIdentifier,
                    displayID: 2
                )
            )
        )

        #expect(snapshot.groups == [
            StageManagerAppGroup(
                displayID: 2,
                placement: .foreground,
                bundleIdentifiers: [chromeBundleIdentifier]
            )
        ])
    }

    @Test("Fullscreen preserves Ignore anchors without holding unrelated sidebar apps")
    func preservesOnlySidebarIgnoreProtection() throws {
        let unrelatedBundleIdentifier = "com.example.unrelated"
        let snapshot = try #require(
            StageManagerFullscreenFallbackPolicy.snapshot(
                cachedSidebarGroups: [
                    StageManagerAppGroup(
                        displayID: 1,
                        placement: .sidebar,
                        bundleIdentifiers: [
                            ignoreBundleIdentifier,
                            hideBundleIdentifier
                        ]
                    ),
                    StageManagerAppGroup(
                        displayID: 1,
                        placement: .sidebar,
                        bundleIdentifiers: [unrelatedBundleIdentifier]
                    )
                ],
                cacheAge: 5,
                fullscreenContext: StageManagerFullscreenContext(
                    bundleIdentifier: chromeBundleIdentifier,
                    displayID: 1
                )
            )
        )
        let evaluation = StageManagerGroupProtectionPolicy.evaluate(
            featureEnabled: true,
            groupingState: .available(snapshot),
            explicitActions: [
                ignoreBundleIdentifier: .ignore,
                hideBundleIdentifier: .hide,
                unrelatedBundleIdentifier: .quit
            ]
        )

        #expect(evaluation.protectedBundleIdentifiers == [
            chromeBundleIdentifier,
            ignoreBundleIdentifier,
            hideBundleIdentifier
        ])
        #expect(!evaluation.protectedBundleIdentifiers.contains(
            unrelatedBundleIdentifier
        ))
    }

    @Test("Fullscreen fails closed without a recent reliable sidebar snapshot")
    func requiresRecentSidebarSnapshot() {
        let context = StageManagerFullscreenContext(
            bundleIdentifier: chromeBundleIdentifier,
            displayID: 1
        )

        #expect(StageManagerFullscreenFallbackPolicy.snapshot(
            cachedSidebarGroups: nil,
            cacheAge: 0,
            fullscreenContext: context
        ) == nil)
        #expect(StageManagerFullscreenFallbackPolicy.snapshot(
            cachedSidebarGroups: [],
            cacheAge:
                StageManagerFullscreenFallbackPolicy.maximumInitialCacheAge + 0.1,
            fullscreenContext: context
        ) == nil)
        #expect(StageManagerFullscreenFallbackPolicy.snapshot(
            cachedSidebarGroups: [],
            cacheAge: -0.1,
            fullscreenContext: context
        ) == nil)
    }
}
