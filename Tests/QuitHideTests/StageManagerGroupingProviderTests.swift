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
