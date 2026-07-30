import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

protocol StageManagerGroupingProviding: Sendable {
    func readGroupingState() async -> StageManagerGroupingState
}

enum StageManagerAccessibility {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

enum StageManagerAXAttributeReadPolicy {
    static func shouldTreatAsMissing(
        attributeName: CFString,
        error: AXError,
        required: Bool
    ) -> Bool {
        guard !required else { return false }

        switch error {
        case .attributeUnsupported, .noValue:
            return true
        case .illegalArgument:
            // WindowManager's Stage Manager buttons can report this instead
            // of noValue when the optional AXIdentifier is absent.
            return attributeName as String ==
                (kAXIdentifierAttribute as String)
        default:
            return false
        }
    }
}

actor SystemStageManagerGroupingProvider: StageManagerGroupingProviding {
    private static let logger = Logger(
        subsystem: "com.jiangsir.quithide",
        category: "stage-manager"
    )

    private enum StageManagerEnabledState {
        case enabled
        case disabled
        case unavailable
    }

    private struct AXSpaceSnapshot: Equatable {
        let frame: CGRect
        let sidebarWindowIDGroups: [[UInt32]]
    }

    private struct AXSnapshot: Equatable {
        let spaces: [AXSpaceSnapshot]
    }

    private struct WindowRecord {
        let windowID: UInt32
        let ownerPID: pid_t
        let bundleIdentifier: String
        let bounds: CGRect
        let layer: Int
        let alpha: Double
        let isOnscreen: Bool
    }

    private struct SidebarCache {
        let groups: [StageManagerAppGroup]
        let capturedAt: TimeInterval
    }

    private struct FullscreenFallbackSession {
        let context: StageManagerFullscreenContext
        let snapshot: StageManagerGroupingSnapshot
    }

    private enum ReadError: Error {
        case windowManagerUnavailable
        case accessibilityFailure(AXError)
        case stageManagerSpacesUnavailable
        case malformedAccessibilityTree
        case windowListUnavailable
        case unmappedWindow
        case ambiguousDisplay
        case unstableSnapshot
    }

    private enum UnavailableReason: String {
        case stageManagerStateUnavailable = "stage_manager_state_unavailable"
        case pointerInteraction = "pointer_interaction"
        case unstableSnapshot = "unstable_snapshot"
        case windowManagerUnavailable = "window_manager_unavailable"
        case accessibilityFailure = "accessibility_failure"
        case stageManagerSpacesUnavailable = "stage_manager_spaces_unavailable"
        case malformedAccessibilityTree = "malformed_accessibility_tree"
        case windowListUnavailable = "window_list_unavailable"
        case unmappedWindow = "unmapped_window"
        case ambiguousDisplay = "ambiguous_display"
        case fullscreenCacheUnavailable = "fullscreen_cache_unavailable"
        case cancelled = "cancelled"
        case unexpectedFailure = "unexpected_failure"
        case showingDesktop = "showing_desktop"
    }

    private var sidebarCache: SidebarCache?
    private var fullscreenFallbackSession: FullscreenFallbackSession?
    private var lastUnavailableReason: UnavailableReason?

    func readGroupingState() async -> StageManagerGroupingState {
        switch Self.stageManagerEnabledState {
        case .disabled:
            sidebarCache = nil
            fullscreenFallbackSession = nil
            clearUnavailableReasonIfNeeded()
            return .disabled
        case .unavailable:
            return unavailable(.stageManagerStateUnavailable)
        case .enabled:
            break
        }
        guard StageManagerAccessibility.isTrusted else { return .permissionRequired }

        do {
            guard !CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            ) else {
                return unavailable(.pointerInteraction)
            }
            let frontmostPIDBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let firstAXSnapshot = try readAXSnapshot()
            let firstWindowRecords = try readWindowRecords()
            let firstFocusedWindowID = try focusedWindowID(
                for: frontmostPIDBefore,
                windowRecords: firstWindowRecords
            )
            try await Task.sleep(nanoseconds: 250_000_000)
            let secondWindowRecords = try readWindowRecords()
            let secondAXSnapshot = try readAXSnapshot()
            let frontmostPIDAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let secondFocusedWindowID = try focusedWindowID(
                for: frontmostPIDAfter,
                windowRecords: secondWindowRecords
            )

            guard firstAXSnapshot == secondAXSnapshot,
                  frontmostPIDBefore == frontmostPIDAfter,
                  firstFocusedWindowID == secondFocusedWindowID,
                  !CGEventSource.buttonState(
                      .combinedSessionState,
                      button: .left
                  ) else {
                throw ReadError.unstableSnapshot
            }

            let firstGroupingSnapshot = try makeGroupingSnapshot(
                axSnapshot: firstAXSnapshot,
                windowRecords: firstWindowRecords
            )
            let secondGroupingSnapshot = try makeGroupingSnapshot(
                axSnapshot: secondAXSnapshot,
                windowRecords: secondWindowRecords
            )
            guard firstGroupingSnapshot == secondGroupingSnapshot else {
                throw ReadError.unstableSnapshot
            }
            try validateFrontmostApplication(
                processIdentifier: frontmostPIDAfter,
                focusedWindowID: secondFocusedWindowID,
                axSnapshot: secondAXSnapshot,
                windowRecords: secondWindowRecords,
                groupingSnapshot: secondGroupingSnapshot
            )
            guard case .enabled = Self.stageManagerEnabledState else {
                return unavailable(.stageManagerStateUnavailable)
            }
            cacheStableSidebarGroups(from: secondGroupingSnapshot)
            fullscreenFallbackSession = nil
            clearUnavailableReasonIfNeeded()
            return .available(secondGroupingSnapshot)
        } catch is CancellationError {
            return unavailable(.cancelled)
        } catch let error as ReadError {
            return await fullscreenFallbackAfterNormalFailure(
                reason: reason(for: error),
                detail: String(describing: error)
            )
        } catch {
            return await fullscreenFallbackAfterNormalFailure(
                reason: .unexpectedFailure,
                detail: String(describing: error)
            )
        }
    }

    private func fullscreenFallbackAfterNormalFailure(
        reason normalFailureReason: UnavailableReason,
        detail: String
    ) async -> StageManagerGroupingState {
        do {
            guard !CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            ) else {
                return unavailable(normalFailureReason, detail: detail)
            }
            let firstFrontmostApplication =
                NSWorkspace.shared.frontmostApplication
            let frontmostPIDBefore =
                firstFrontmostApplication?.processIdentifier
            let firstWindowRecords = try readWindowRecords()
            let firstShowDesktopObservation = try showDesktopObservation(
                frontmostApplication: firstFrontmostApplication,
                windowRecords: firstWindowRecords
            )
            let firstFullscreenContext = try fullscreenContext(
                for: frontmostPIDBefore,
                windowRecords: firstWindowRecords
            )
            // WindowManager can expose no sm.space elements, a partially
            // malformed subtree, or sidebar window IDs that temporarily no
            // longer map while Show Desktop is active. None of these errors
            // is sufficient on its own; the policy below also requires two
            // stable observations with no ordinary workspace window before
            // presenting the normal desktop state.
            let normalReadHasShowDesktopCompatibleStructureError =
                normalFailureReason == .stageManagerSpacesUnavailable ||
                normalFailureReason == .malformedAccessibilityTree ||
                normalFailureReason == .unmappedWindow
            guard normalReadHasShowDesktopCompatibleStructureError ||
                    firstFullscreenContext != nil else {
                return unavailable(normalFailureReason, detail: detail)
            }

            try await Task.sleep(nanoseconds: 250_000_000)
            let secondWindowRecords = try readWindowRecords()
            let secondFrontmostApplication =
                NSWorkspace.shared.frontmostApplication
            let frontmostPIDAfter =
                secondFrontmostApplication?.processIdentifier
            let secondShowDesktopObservation = try showDesktopObservation(
                frontmostApplication: secondFrontmostApplication,
                windowRecords: secondWindowRecords
            )
            let secondFullscreenContext = try fullscreenContext(
                for: frontmostPIDAfter,
                windowRecords: secondWindowRecords
            )
            guard frontmostPIDBefore == frontmostPIDAfter,
                  !CGEventSource.buttonState(
                      .combinedSessionState,
                      button: .left
                  ) else {
                return unavailable(.unstableSnapshot)
            }
            guard case .enabled = Self.stageManagerEnabledState else {
                return unavailable(.stageManagerStateUnavailable)
            }
            if StageManagerShowDesktopDetectionPolicy.isShowingDesktop(
                normalReadFailedWithCompatibleStructureError:
                    normalReadHasShowDesktopCompatibleStructureError,
                stageManagerIsEnabled: true,
                isPointerInteractionInProgress: false,
                firstObservation: firstShowDesktopObservation,
                secondObservation: secondShowDesktopObservation
            ) {
                return showingDesktop()
            }
            if normalReadHasShowDesktopCompatibleStructureError,
               firstShowDesktopObservation != secondShowDesktopObservation {
                return unavailable(.unstableSnapshot)
            }
            guard firstFullscreenContext == secondFullscreenContext else {
                return unavailable(.unstableSnapshot)
            }
            guard let firstFullscreenContext else {
                return unavailable(normalFailureReason, detail: detail)
            }
            return fullscreenFallbackState(
                for: firstFullscreenContext,
                normalFailureReason: normalFailureReason
            )
        } catch is CancellationError {
            return unavailable(.cancelled)
        } catch let error as ReadError {
            return unavailable(
                reason(for: error),
                detail: String(describing: error)
            )
        } catch {
            return unavailable(
                .unexpectedFailure,
                detail: String(describing: error)
            )
        }
    }

    private func fullscreenFallbackState(
        for context: StageManagerFullscreenContext,
        normalFailureReason: UnavailableReason
    ) -> StageManagerGroupingState {
        if let fullscreenFallbackSession,
           fullscreenFallbackSession.context == context {
            clearUnavailableReasonIfNeeded()
            return .available(fullscreenFallbackSession.snapshot)
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard let sidebarCache,
              let snapshot = StageManagerFullscreenFallbackPolicy.snapshot(
                  cachedSidebarGroups: sidebarCache.groups,
                  cacheAge: now - sidebarCache.capturedAt,
                  fullscreenContext: context
              ) else {
            return unavailable(
                .fullscreenCacheUnavailable,
                detail: "normal_read=\(normalFailureReason.rawValue)"
            )
        }

        fullscreenFallbackSession = FullscreenFallbackSession(
            context: context,
            snapshot: snapshot
        )
        clearUnavailableReasonIfNeeded()
        Self.logger.notice(
            """
            Using cached Stage Manager sidebar groups while \
            \(context.bundleIdentifier, privacy: .public) is fullscreen; \
            normal_read=\(normalFailureReason.rawValue, privacy: .public)
            """
        )
        return .available(snapshot)
    }

    private func showDesktopObservation(
        frontmostApplication: NSRunningApplication?,
        windowRecords: [WindowRecord]
    ) throws -> StageManagerShowDesktopObservation {
        let displayBounds = try activeDisplayBounds()
        return StageManagerShowDesktopObservation(
            frontmostProcessIdentifier:
                frontmostApplication?.processIdentifier,
            frontmostBundleIdentifier:
                frontmostApplication?.bundleIdentifier,
            hasOrdinaryOnscreenApplicationWindow:
                windowRecords.contains {
                    isOrdinaryWorkspaceWindow(
                        $0,
                        displayBounds: displayBounds
                    )
                }
        )
    }

    private func isOrdinaryWorkspaceWindow(
        _ record: WindowRecord,
        displayBounds: [UInt32: CGRect]
    ) -> Bool {
        guard record.isOnscreen,
              record.layer == 0,
              record.alpha > 0,
              record.bounds.width > 0,
              record.bounds.height > 0 else {
            return false
        }
        return StageManagerShowDesktopWindowPolicy.isOrdinaryWorkspaceWindow(
            windowFrame: record.bounds,
            displayFrames: Array(displayBounds.values)
        )
    }

    private func showingDesktop() -> StageManagerGroupingState {
        fullscreenFallbackSession = nil
        guard lastUnavailableReason != .showingDesktop else {
            return .showingDesktop
        }
        lastUnavailableReason = .showingDesktop
        Self.logger.debug(
            "Stage Manager grouping paused while the desktop is showing"
        )
        return .showingDesktop
    }

    private func cacheStableSidebarGroups(
        from snapshot: StageManagerGroupingSnapshot
    ) {
        sidebarCache = SidebarCache(
            groups: snapshot.groups.filter { $0.placement == .sidebar },
            capturedAt: ProcessInfo.processInfo.systemUptime
        )
    }

    private func unavailable(
        _ reason: UnavailableReason,
        detail: String? = nil
    ) -> StageManagerGroupingState {
        guard lastUnavailableReason != reason else { return .unavailable }
        lastUnavailableReason = reason

        if reason == .pointerInteraction ||
            reason == .unstableSnapshot ||
            reason == .cancelled {
            Self.logger.debug(
                "Stage Manager grouping temporarily unavailable: \(reason.rawValue, privacy: .public)"
            )
        } else if let detail {
            Self.logger.warning(
                "Stage Manager grouping unavailable: \(reason.rawValue, privacy: .public) detail=\(detail, privacy: .public)"
            )
        } else {
            Self.logger.warning(
                "Stage Manager grouping unavailable: \(reason.rawValue, privacy: .public)"
            )
        }
        return .unavailable
    }

    private func clearUnavailableReasonIfNeeded() {
        guard lastUnavailableReason != nil else { return }
        lastUnavailableReason = nil
        Self.logger.notice("Stage Manager grouping recovered")
    }

    private func reason(for error: ReadError) -> UnavailableReason {
        switch error {
        case .windowManagerUnavailable:
            return .windowManagerUnavailable
        case .accessibilityFailure:
            return .accessibilityFailure
        case .stageManagerSpacesUnavailable:
            return .stageManagerSpacesUnavailable
        case .malformedAccessibilityTree:
            return .malformedAccessibilityTree
        case .windowListUnavailable:
            return .windowListUnavailable
        case .unmappedWindow:
            return .unmappedWindow
        case .ambiguousDisplay:
            return .ambiguousDisplay
        case .unstableSnapshot:
            return .unstableSnapshot
        }
    }

    private static var stageManagerEnabledState: StageManagerEnabledState {
        let domain = "com.apple.WindowManager" as CFString
        let key = "GloballyEnabled" as CFString
        guard CFPreferencesAppSynchronize(domain) else {
            return .unavailable
        }
        guard let value = CFPreferencesCopyAppValue(key, domain) else {
            // A Mac that has never enabled Stage Manager commonly has no value.
            return .disabled
        }
        if let number = value as? NSNumber {
            return number.boolValue ? .enabled : .disabled
        }
        return .unavailable
    }

    private func readAXSnapshot() throws -> AXSnapshot {
        guard let windowManager = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.WindowManager"
        ).first else {
            throw ReadError.windowManagerUnavailable
        }

        let application = AXUIElementCreateApplication(windowManager.processIdentifier)
        let systemWide = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWide, 1.0)
        _ = AXUIElementSetMessagingTimeout(application, 1.0)
        let spaces = try matchingElements(
            below: application,
            identifier: "sm.space",
            maximumDepth: 4
        )
        guard !spaces.isEmpty else {
            throw ReadError.stageManagerSpacesUnavailable
        }

        let snapshots = try spaces.map { space -> AXSpaceSnapshot in
            let frame = try frame(of: space)
            let strips = try matchingElements(
                below: space,
                identifier: "sm.strip",
                maximumDepth: 4
            )
            guard strips.count == 1, let strip = strips.first else {
                throw ReadError.malformedAccessibilityTree
            }

            let buttons = try elements(
                below: strip,
                role: kAXButtonRole as String,
                maximumDepth: 4
            )
            var groups: [[UInt32]] = []
            for button in buttons {
                guard let rawIDs = try attribute(
                    "AXWindowsIDs" as CFString,
                    from: button,
                    required: true
                ) as? NSArray else {
                    throw ReadError.malformedAccessibilityTree
                }
                let ids = rawIDs.compactMap { value -> UInt32? in
                    if let number = value as? NSNumber {
                        return number.uint32Value
                    }
                    return nil
                }
                guard ids.count == rawIDs.count, !ids.isEmpty else {
                    throw ReadError.malformedAccessibilityTree
                }
                groups.append(ids.sorted())
            }

            groups.sort { lhs, rhs in
                lhs.lexicographicallyPrecedes(rhs)
            }
            return AXSpaceSnapshot(
                frame: frame,
                sidebarWindowIDGroups: groups
            )
        }

        return AXSnapshot(spaces: snapshots.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            if $0.frame.width != $1.frame.width { return $0.frame.width < $1.frame.width }
            return $0.frame.height < $1.frame.height
        })
    }

    private func matchingElements(
        below root: AXUIElement,
        identifier: String,
        maximumDepth: Int
    ) throws -> [AXUIElement] {
        let candidates = try breadthFirstElements(
            below: root,
            maximumDepth: maximumDepth
        )
        var matches: [AXUIElement] = []
        for element in candidates {
            if try attribute(
                kAXIdentifierAttribute as CFString,
                from: element,
                required: false
            ) as? String == identifier {
                matches.append(element)
            }
        }
        return matches
    }

    private func elements(
        below root: AXUIElement,
        role: String,
        maximumDepth: Int
    ) throws -> [AXUIElement] {
        let candidates = try breadthFirstElements(
            below: root,
            maximumDepth: maximumDepth
        )
        var matches: [AXUIElement] = []
        for element in candidates {
            if try attribute(
                kAXRoleAttribute as CFString,
                from: element,
                required: false
            ) as? String == role {
                matches.append(element)
            }
        }
        return matches
    }

    private func breadthFirstElements(
        below root: AXUIElement,
        maximumDepth: Int
    ) throws -> [AXUIElement] {
        var result: [AXUIElement] = []
        var level: [AXUIElement] = [root]

        for _ in 0...maximumDepth {
            result.append(contentsOf: level)
            var nextLevel: [AXUIElement] = []
            for element in level {
                guard let children = try attribute(
                    kAXChildrenAttribute as CFString,
                    from: element,
                    required: false
                ) as? [AXUIElement] else {
                    continue
                }
                nextLevel.append(contentsOf: children)
            }
            guard !nextLevel.isEmpty else { break }
            level = nextLevel
        }
        return result
    }

    private func attribute(
        _ name: CFString,
        from element: AXUIElement,
        required: Bool
    ) throws -> CFTypeRef? {
        _ = AXUIElementSetMessagingTimeout(element, 1.0)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        switch error {
        case .success:
            if required, value == nil {
                throw ReadError.malformedAccessibilityTree
            }
            return value
        default:
            if StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
                attributeName: name,
                error: error,
                required: required
            ) {
                return nil
            }
            throw ReadError.accessibilityFailure(error)
        }
    }

    private func frame(of element: AXUIElement) throws -> CGRect {
        guard let rawPosition = try attribute(
            kAXPositionAttribute as CFString,
            from: element,
            required: true
        ), let rawSize = try attribute(
            kAXSizeAttribute as CFString,
            from: element,
            required: true
        ), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
           CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            throw ReadError.malformedAccessibilityTree
        }

        let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            throw ReadError.malformedAccessibilityTree
        }
        return CGRect(origin: position, size: size)
    }

    private func readWindowRecords() throws -> [WindowRecord] {
        guard let rawOnscreenWindowList = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw ReadError.windowListUnavailable
        }
        guard let rawWindowList = CGWindowListCopyWindowInfo(
            .optionAll,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw ReadError.windowListUnavailable
        }
        let onscreenWindowIDs = Set(rawOnscreenWindowList.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        return rawWindowList.compactMap { dictionary -> WindowRecord? in
            guard let windowNumber = dictionary[kCGWindowNumber as String] as? NSNumber,
                  let ownerPIDNumber = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                return nil
            }

            let ownerPID = pid_t(ownerPIDNumber.int32Value)
            guard let application = NSRunningApplication(processIdentifier: ownerPID),
                  application.activationPolicy == .regular,
                  let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier != ownBundleIdentifier else {
                return nil
            }

            let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return WindowRecord(
                windowID: windowNumber.uint32Value,
                ownerPID: ownerPID,
                bundleIdentifier: bundleIdentifier,
                bounds: bounds,
                layer: layer,
                alpha: alpha,
                isOnscreen: onscreenWindowIDs.contains(windowNumber.uint32Value)
            )
        }
    }

    private func fullscreenContext(
        for processIdentifier: pid_t?,
        windowRecords: [WindowRecord]
    ) throws -> StageManagerFullscreenContext? {
        guard let processIdentifier else { return nil }
        let displayBounds = try activeDisplayBounds()

        // Only use this after the normal Stage Manager read has failed.
        // CGWindowList is ordered from front to back, and a native fullscreen
        // presentation matches a display's complete bounds. Requiring a
        // near-exact frame avoids confusing a normal maximized window with a
        // fullscreen Space.
        for record in windowRecords where
            record.ownerPID == processIdentifier &&
            isEligibleForegroundWindow(record) {
            for (displayID, displayFrame) in displayBounds {
                guard StageManagerFullscreenDetectionPolicy.matchesDisplayBounds(
                    windowFrame: record.bounds,
                    displayFrame: displayFrame
                ) else {
                    continue
                }
                return StageManagerFullscreenContext(
                    bundleIdentifier: record.bundleIdentifier,
                    displayID: displayID
                )
            }
        }
        return nil
    }

    private func makeGroupingSnapshot(
        axSnapshot: AXSnapshot,
        windowRecords: [WindowRecord]
    ) throws -> StageManagerGroupingSnapshot {
        let displayBounds = try activeDisplayBounds()
        var recordsByWindowID: [UInt32: WindowRecord] = [:]
        for record in windowRecords {
            recordsByWindowID[record.windowID] = record
        }
        let sidebarWindowIDs = Set(
            axSnapshot.spaces.flatMap(\.sidebarWindowIDGroups).flatMap { $0 }
        )
        var groups: [StageManagerAppGroup] = []
        var spaceDisplayIDs: [UInt32] = []

        for space in axSnapshot.spaces {
            let displayID = try uniquelyMatchingDisplay(
                for: space.frame,
                displayBounds: displayBounds
            )
            spaceDisplayIDs.append(displayID)

            for windowIDs in space.sidebarWindowIDGroups {
                var bundleIdentifiers: Set<String> = []
                for windowID in windowIDs {
                    guard let record = recordsByWindowID[windowID] else {
                        throw ReadError.unmappedWindow
                    }
                    bundleIdentifiers.insert(record.bundleIdentifier)
                }
                guard !bundleIdentifiers.isEmpty else {
                    throw ReadError.unmappedWindow
                }
                groups.append(StageManagerAppGroup(
                    displayID: displayID,
                    placement: .sidebar,
                    bundleIdentifiers: bundleIdentifiers
                ))
            }
        }

        var foregroundBundleIdentifiersByDisplay: [UInt32: Set<String>] = [:]
        for record in windowRecords {
            guard isEligibleForegroundWindow(record),
                  !sidebarWindowIDs.contains(record.windowID) else {
                continue
            }

            let displayID = try uniquelyMatchingSpaceDisplay(
                for: record.bounds,
                spaces: axSnapshot.spaces,
                spaceDisplayIDs: spaceDisplayIDs
            )
            guard let displayID else { continue }
            foregroundBundleIdentifiersByDisplay[displayID, default: []]
                .insert(record.bundleIdentifier)
        }

        for (displayID, bundleIdentifiers) in foregroundBundleIdentifiersByDisplay
        where !bundleIdentifiers.isEmpty {
            groups.append(StageManagerAppGroup(
                displayID: displayID,
                placement: .foreground,
                bundleIdentifiers: bundleIdentifiers
            ))
        }

        groups.sort {
            if $0.displayID != $1.displayID { return $0.displayID < $1.displayID }
            if $0.placement != $1.placement {
                return $0.placement == .foreground
            }
            return $0.bundleIdentifiers.sorted().lexicographicallyPrecedes(
                $1.bundleIdentifiers.sorted()
            )
        }
        return StageManagerGroupingSnapshot(groups: groups)
    }

    private func focusedWindowID(
        for processIdentifier: pid_t?,
        windowRecords: [WindowRecord]
    ) throws -> UInt32? {
        guard let processIdentifier else { return nil }
        let candidates = eligibleWindowRecords(
            for: processIdentifier,
            in: windowRecords
        )
        guard !candidates.isEmpty else { return nil }

        let application = AXUIElementCreateApplication(processIdentifier)
        guard let rawFocusedWindow = try attribute(
            kAXFocusedWindowAttribute as CFString,
            from: application,
            required: false
        ), CFGetTypeID(rawFocusedWindow) == AXUIElementGetTypeID() else {
            throw ReadError.malformedAccessibilityTree
        }
        let focusedWindow = unsafeBitCast(rawFocusedWindow, to: AXUIElement.self)

        let focusedRecord: WindowRecord
        if let windowID = try axWindowNumber(of: focusedWindow) {
            let matches = windowRecords.filter {
                $0.ownerPID == processIdentifier &&
                    $0.windowID == windowID
            }
            guard matches.count == 1, let match = matches.first else {
                throw ReadError.unmappedWindow
            }
            focusedRecord = match
        } else {
            let focusedFrame = try frame(of: focusedWindow)
            let matches = windowRecords.filter {
                $0.ownerPID == processIdentifier &&
                    framesApproximatelyMatch($0.bounds, focusedFrame)
            }
            guard matches.count == 1, let match = matches.first else {
                throw ReadError.unmappedWindow
            }
            focusedRecord = match
        }
        guard isEligibleForegroundWindow(focusedRecord) else {
            throw ReadError.malformedAccessibilityTree
        }
        return focusedRecord.windowID
    }

    private func axWindowNumber(of window: AXUIElement) throws -> UInt32? {
        guard let rawValue = try attribute(
            "AXWindowNumber" as CFString,
            from: window,
            required: false
        ) else {
            return nil
        }
        guard CFGetTypeID(rawValue) == CFNumberGetTypeID(),
              let number = rawValue as? NSNumber else {
            throw ReadError.malformedAccessibilityTree
        }
        let candidate = number.uint64Value
        guard candidate > 0,
              candidate <= UInt64(UInt32.max) else {
            throw ReadError.malformedAccessibilityTree
        }
        return UInt32(candidate)
    }

    private func eligibleWindowRecords(
        for processIdentifier: pid_t,
        in windowRecords: [WindowRecord]
    ) -> [WindowRecord] {
        windowRecords.filter {
            $0.ownerPID == processIdentifier &&
                isEligibleForegroundWindow($0)
        }
    }

    private func isEligibleForegroundWindow(_ record: WindowRecord) -> Bool {
        record.isOnscreen &&
            record.layer >= 0 &&
            record.alpha > 0 &&
            record.bounds.width > 0 &&
            record.bounds.height > 0
    }

    private func framesApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        let lhs = lhs.standardized
        let rhs = rhs.standardized
        return abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    private func validateFrontmostApplication(
        processIdentifier: pid_t?,
        focusedWindowID: UInt32?,
        axSnapshot: AXSnapshot,
        windowRecords: [WindowRecord],
        groupingSnapshot: StageManagerGroupingSnapshot
    ) throws {
        guard let processIdentifier else { return }
        let sidebarWindowIDs = Set(
            axSnapshot.spaces.flatMap(\.sidebarWindowIDGroups).flatMap { $0 }
        )
        let eligibleFrontmostWindows = eligibleWindowRecords(
            for: processIdentifier,
            in: windowRecords
        )
        guard !eligibleFrontmostWindows.isEmpty else { return }
        guard let focusedWindowID,
              let focusedWindow = eligibleFrontmostWindows.first(where: {
                  $0.windowID == focusedWindowID
              }),
              !sidebarWindowIDs.contains(focusedWindow.windowID) else {
            throw ReadError.malformedAccessibilityTree
        }

        let displayBounds = try activeDisplayBounds()
        let spaceDisplayIDs = try axSnapshot.spaces.map {
            try uniquelyMatchingDisplay(
                for: $0.frame,
                displayBounds: displayBounds
            )
        }
        guard let displayID = try uniquelyMatchingSpaceDisplay(
            for: focusedWindow.bounds,
            spaces: axSnapshot.spaces,
            spaceDisplayIDs: spaceDisplayIDs
        ) else {
            return
        }
        let hasMappedForegroundWindow = groupingSnapshot.groups.contains {
            $0.displayID == displayID &&
                $0.placement == .foreground &&
                $0.bundleIdentifiers.contains(focusedWindow.bundleIdentifier)
        }
        guard hasMappedForegroundWindow else {
            throw ReadError.malformedAccessibilityTree
        }
    }

    private func activeDisplayBounds() throws -> [UInt32: CGRect] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            throw ReadError.ambiguousDisplay
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let result = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }
        guard result == .success else {
            throw ReadError.ambiguousDisplay
        }

        let canonicalDisplayIDs = Set(displayIDs.prefix(Int(displayCount)).map { displayID in
            let mirroredDisplay = CGDisplayMirrorsDisplay(displayID)
            return mirroredDisplay == kCGNullDirectDisplay ? displayID : mirroredDisplay
        })
        return Dictionary(uniqueKeysWithValues: canonicalDisplayIDs.map {
            (UInt32($0), CGDisplayBounds($0))
        })
    }

    private func uniquelyMatchingDisplay(
        for frame: CGRect,
        displayBounds: [UInt32: CGRect]
    ) throws -> UInt32 {
        let matches = displayBounds.compactMap { displayID, bounds -> (UInt32, CGFloat)? in
            let area = intersectionArea(frame, bounds)
            return area > 0 ? (displayID, area) : nil
        }.sorted { $0.1 > $1.1 }

        guard let best = matches.first else {
            throw ReadError.ambiguousDisplay
        }
        if matches.count > 1,
           matches[1].1 >= best.1 * 0.9 {
            throw ReadError.ambiguousDisplay
        }
        return best.0
    }

    private func uniquelyMatchingSpaceDisplay(
        for windowBounds: CGRect,
        spaces: [AXSpaceSnapshot],
        spaceDisplayIDs: [UInt32]
    ) throws -> UInt32? {
        let windowArea = max(windowBounds.width * windowBounds.height, 1)
        let matches = zip(spaces, spaceDisplayIDs).compactMap {
            space, displayID -> (UInt32, CGFloat)? in
            let area = intersectionArea(windowBounds, space.frame)
            return area > 0 ? (displayID, area / windowArea) : nil
        }.sorted { $0.1 > $1.1 }

        guard let best = matches.first else { return nil }
        if matches.count > 1 {
            let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
            let centerMatches = zip(spaces, spaceDisplayIDs).compactMap {
                space, displayID in
                space.frame.contains(center) ? displayID : nil
            }
            if centerMatches.count == 1 {
                return centerMatches[0]
            }
        }
        return best.0
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
