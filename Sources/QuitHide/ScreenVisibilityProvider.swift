import AppKit
import CoreGraphics
import Foundation

enum ScreenVisibilityState: Sendable, Equatable {
    case available(
        snapshot: ScreenVisibilitySnapshot,
        fingerprint: ScreenVisibilityFingerprint
    )
    case unavailable
}

struct ScreenVisibilityWindowFingerprint: Sendable, Equatable {
    let windowID: UInt32
    let ownerPID: pid_t
    let bundleIdentifier: String
    let frame: CGRect
    let isOpaque: Bool
    let isNormalLayer: Bool

    var visibilityWindow: ScreenVisibilityWindow {
        ScreenVisibilityWindow(
            bundleIdentifier: bundleIdentifier,
            frame: frame,
            isOpaque: isOpaque,
            isNormalLayer: isNormalLayer
        )
    }
}

struct ScreenVisibilityFingerprint: Sendable, Equatable {
    let windowsFrontToBack: [ScreenVisibilityWindowFingerprint]
    let displays: [ScreenVisibilityDisplay]
    let frontmostPID: pid_t?

    var visibilitySnapshot: ScreenVisibilitySnapshot {
        ScreenVisibilitySnapshot(
            windowsFrontToBack: windowsFrontToBack.map(\.visibilityWindow),
            displays: displays
        )
    }
}

enum ScreenVisibilityInteractionState {
    static var isPointerInteractionInProgress: Bool {
        CGEventSource.buttonState(
            .combinedSessionState,
            button: .left
        ) || CGEventSource.buttonState(
            .combinedSessionState,
            button: .right
        ) || CGEventSource.buttonState(
            .combinedSessionState,
            button: .center
        )
    }
}

protocol ScreenVisibilityProviding: Sendable {
    func readVisibilityState() async -> ScreenVisibilityState
    func readCurrentFingerprint() async -> ScreenVisibilityFingerprint?
}

actor SystemScreenVisibilityProvider: ScreenVisibilityProviding {
    private enum ReadError: Error {
        case windowListUnavailable
        case malformedWindowList
        case displayListUnavailable
    }

    func readVisibilityState() async -> ScreenVisibilityState {
        do {
            guard !ScreenVisibilityInteractionState
                .isPointerInteractionInProgress else {
                return .unavailable
            }

            let frontmostPIDBefore =
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            let first = try readFingerprint(
                frontmostPID: frontmostPIDBefore
            )

            try await Task.sleep(nanoseconds: 250_000_000)

            let secondWindowsAndDisplays = try readWindowsAndDisplays()
            let frontmostPIDAfter =
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            let second = ScreenVisibilityFingerprint(
                windowsFrontToBack:
                    secondWindowsAndDisplays.windowsFrontToBack,
                displays: secondWindowsAndDisplays.displays,
                frontmostPID: frontmostPIDAfter
            )
            guard first == second,
                  !ScreenVisibilityInteractionState
                    .isPointerInteractionInProgress else {
                return .unavailable
            }
            return .available(
                snapshot: second.visibilitySnapshot,
                fingerprint: second
            )
        } catch {
            return .unavailable
        }
    }

    func readCurrentFingerprint() async -> ScreenVisibilityFingerprint? {
        do {
            guard !ScreenVisibilityInteractionState
                .isPointerInteractionInProgress else {
                return nil
            }
            let frontmostPIDBefore =
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            let fingerprint = try readFingerprint(
                frontmostPID: frontmostPIDBefore
            )
            let frontmostPIDAfter =
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard frontmostPIDBefore == frontmostPIDAfter,
                  !ScreenVisibilityInteractionState
                    .isPointerInteractionInProgress else {
                return nil
            }
            return fingerprint
        } catch {
            return nil
        }
    }

    private func readFingerprint(
        frontmostPID: pid_t?
    ) throws -> ScreenVisibilityFingerprint {
        let snapshot = try readWindowsAndDisplays()
        return ScreenVisibilityFingerprint(
            windowsFrontToBack: snapshot.windowsFrontToBack,
            displays: snapshot.displays,
            frontmostPID: frontmostPID
        )
    }

    private func readWindowsAndDisplays() throws -> (
        windowsFrontToBack: [ScreenVisibilityWindowFingerprint],
        displays: [ScreenVisibilityDisplay]
    ) {
        let displays = try readDisplays()
        let windowOptions = CGWindowListOption.optionOnScreenOnly.union(
            .excludeDesktopElements
        )
        guard let rawWindowList = CGWindowListCopyWindowInfo(
            windowOptions,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw ReadError.windowListUnavailable
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let regularApplicationsByPID = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications
                .compactMap { application -> (pid_t, String)? in
                    guard application.activationPolicy == .regular,
                          let bundleIdentifier = application.bundleIdentifier,
                          bundleIdentifier != ownBundleIdentifier else {
                        return nil
                    }
                    return (application.processIdentifier, bundleIdentifier)
                }
        )

        var windows: [ScreenVisibilityWindowFingerprint] = []
        for dictionary in rawWindowList {
            guard let windowNumber =
                    dictionary[kCGWindowNumber as String] as? NSNumber,
                  let ownerPIDNumber =
                    dictionary[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDictionary =
                    dictionary[kCGWindowBounds as String] as? NSDictionary,
                  let rawFrame = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                throw ReadError.malformedWindowList
            }

            let ownerPID = pid_t(ownerPIDNumber.int32Value)
            guard let bundleIdentifier = regularApplicationsByPID[ownerPID] else {
                continue
            }

            let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
            guard ScreenVisibilityWindowEligibility.shouldIncludeOnscreenWindow(
                frame: rawFrame,
                alpha: alpha
            ) else {
                continue
            }
            windows.append(ScreenVisibilityWindowFingerprint(
                windowID: windowNumber.uint32Value,
                ownerPID: ownerPID,
                bundleIdentifier: bundleIdentifier,
                frame: quantized(rawFrame),
                // WindowServer exposes only whole-window alpha here, not a
                // per-pixel opaque region. This feature deliberately uses
                // frame geometry so it can work without Screen Recording.
                isOpaque: alpha.map { $0 >= 0.999 } ?? false,
                isNormalLayer: layer == 0
            ))
        }

        return (
            windowsFrontToBack: windows,
            displays: displays
        )
    }

    private func readDisplays() throws -> [ScreenVisibilityDisplay] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            throw ReadError.displayListUnavailable
        }

        var displayIDs = [CGDirectDisplayID](
            repeating: kCGNullDirectDisplay,
            count: Int(displayCount)
        )
        let result = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(
                displayCount,
                buffer.baseAddress,
                &displayCount
            )
        }
        guard result == .success else {
            throw ReadError.displayListUnavailable
        }

        let canonicalDisplayIDs = Set(
            displayIDs.prefix(Int(displayCount)).map { displayID in
                let mirroredDisplay = CGDisplayMirrorsDisplay(displayID)
                return mirroredDisplay == kCGNullDirectDisplay
                    ? displayID
                    : mirroredDisplay
            }
        )
        guard !canonicalDisplayIDs.isEmpty else {
            throw ReadError.displayListUnavailable
        }

        return canonicalDisplayIDs.map {
            ScreenVisibilityDisplay(
                displayID: UInt32($0),
                frame: quantized(CGDisplayBounds($0))
            )
        }.sorted { lhs, rhs in
            lhs.displayID < rhs.displayID
        }
    }

    private func quantized(_ rectangle: CGRect) -> CGRect {
        CGRect(
            x: quantized(rectangle.origin.x),
            y: quantized(rectangle.origin.y),
            width: quantized(rectangle.width),
            height: quantized(rectangle.height)
        )
    }

    private func quantized(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return value }
        return (value * 2).rounded() / 2
    }
}
