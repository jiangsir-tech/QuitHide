import CoreGraphics
import Foundation

struct ScreenVisibilityDisplay: Sendable, Equatable {
    let displayID: UInt32
    let frame: CGRect
}

struct ScreenVisibilityWindow: Sendable, Equatable {
    let bundleIdentifier: String
    let frame: CGRect
    let isOpaque: Bool
    let isNormalLayer: Bool
}

struct ScreenVisibilitySnapshot: Sendable, Equatable {
    /// Windows in the order returned by the window server: front to back.
    let windowsFrontToBack: [ScreenVisibilityWindow]
    let displays: [ScreenVisibilityDisplay]
}

struct ScreenVisibilityProtectionEvaluation: Sendable, Equatable {
    let protectedBundleIdentifiers: Set<String>
    let uncertainBundleIdentifiers: Set<String>
}

enum ScreenVisibilityWindowEligibility {
    static func shouldIncludeOnscreenWindow(
        frame: CGRect,
        alpha: Double?
    ) -> Bool {
        if let alpha, alpha <= 0 {
            return false
        }
        if frame.width.isFinite,
           frame.height.isFinite,
           (frame.width <= 0 || frame.height <= 0) {
            return false
        }
        return true
    }
}

enum ScreenVisibilityProtectionPolicy {
    private static let maximumUncoveredFragmentCount = 4_096

    static func evaluate(
        snapshot: ScreenVisibilitySnapshot,
        automaticBundleIdentifiers: Set<String>
    ) -> ScreenVisibilityProtectionEvaluation {
        let automaticBundles = Set(
            automaticBundleIdentifiers.filter { !$0.isEmpty }
        )
        guard !automaticBundles.isEmpty else {
            return ScreenVisibilityProtectionEvaluation(
                protectedBundleIdentifiers: [],
                uncertainBundleIdentifiers: []
            )
        }

        let displayFrames = snapshot.displays.map(\.frame)
        guard !displayFrames.isEmpty,
              displayFrames.allSatisfy(isValidRectangle) else {
            return ScreenVisibilityProtectionEvaluation(
                protectedBundleIdentifiers: automaticBundles,
                uncertainBundleIdentifiers: automaticBundles
            )
        }

        var protectedBundles: Set<String> = []
        var uncertainBundles: Set<String> = []

        for bundleIdentifier in automaticBundles {
            let targetWindowIndices = snapshot.windowsFrontToBack.indices.filter {
                snapshot.windowsFrontToBack[$0].bundleIdentifier == bundleIdentifier
            }

            for targetIndex in targetWindowIndices {
                let targetWindow = snapshot.windowsFrontToBack[targetIndex]
                guard isValidRectangle(targetWindow.frame) else {
                    protectedBundles.insert(bundleIdentifier)
                    uncertainBundles.insert(bundleIdentifier)
                    break
                }

                let visibleTargetParts = clippedParts(
                    of: targetWindow.frame,
                    to: displayFrames
                )
                guard !visibleTargetParts.isEmpty else { continue }

                let definiteOccluders = snapshot.windowsFrontToBack[..<targetIndex]
                    .filter {
                        $0.bundleIdentifier != bundleIdentifier &&
                            !$0.bundleIdentifier.isEmpty &&
                            $0.isOpaque &&
                            $0.isNormalLayer &&
                            isValidRectangle($0.frame)
                    }
                    .map(\.frame)

                switch coverage(
                    of: visibleTargetParts,
                    by: definiteOccluders
                ) {
                case .fullyCovered:
                    continue
                case .visible:
                    protectedBundles.insert(bundleIdentifier)
                    break
                case .uncertain:
                    protectedBundles.insert(bundleIdentifier)
                    uncertainBundles.insert(bundleIdentifier)
                    break
                }
            }
        }

        return ScreenVisibilityProtectionEvaluation(
            protectedBundleIdentifiers: protectedBundles,
            uncertainBundleIdentifiers: uncertainBundles
        )
    }

    private enum Coverage {
        case fullyCovered
        case visible
        case uncertain
    }

    private static func coverage(
        of targetParts: [CGRect],
        by occluders: [CGRect]
    ) -> Coverage {
        var uncovered = targetParts

        for occluder in occluders {
            var nextUncovered: [CGRect] = []
            for fragment in uncovered {
                nextUncovered.append(contentsOf: subtract(
                    occluder,
                    from: fragment
                ))
                guard nextUncovered.count <= maximumUncoveredFragmentCount else {
                    return .uncertain
                }
            }
            uncovered = nextUncovered
            if uncovered.isEmpty {
                return .fullyCovered
            }
        }

        return uncovered.isEmpty ? .fullyCovered : .visible
    }

    private static func subtract(
        _ occluder: CGRect,
        from target: CGRect
    ) -> [CGRect] {
        let intersection = target.intersection(occluder)
        guard isValidRectangle(intersection) else {
            return [target]
        }

        var fragments: [CGRect] = []

        appendIfValid(
            CGRect(
                x: target.minX,
                y: target.minY,
                width: target.width,
                height: intersection.minY - target.minY
            ),
            to: &fragments
        )
        appendIfValid(
            CGRect(
                x: target.minX,
                y: intersection.maxY,
                width: target.width,
                height: target.maxY - intersection.maxY
            ),
            to: &fragments
        )
        appendIfValid(
            CGRect(
                x: target.minX,
                y: intersection.minY,
                width: intersection.minX - target.minX,
                height: intersection.height
            ),
            to: &fragments
        )
        appendIfValid(
            CGRect(
                x: intersection.maxX,
                y: intersection.minY,
                width: target.maxX - intersection.maxX,
                height: intersection.height
            ),
            to: &fragments
        )

        return fragments
    }

    private static func clippedParts(
        of frame: CGRect,
        to displayFrames: [CGRect]
    ) -> [CGRect] {
        displayFrames.compactMap {
            let intersection = frame.intersection($0)
            return isValidRectangle(intersection) ? intersection : nil
        }
    }

    private static func appendIfValid(
        _ rectangle: CGRect,
        to rectangles: inout [CGRect]
    ) {
        if isValidRectangle(rectangle) {
            rectangles.append(rectangle)
        }
    }

    private static func isValidRectangle(_ rectangle: CGRect) -> Bool {
        !rectangle.isNull &&
            !rectangle.isInfinite &&
            rectangle.origin.x.isFinite &&
            rectangle.origin.y.isFinite &&
            rectangle.width.isFinite &&
            rectangle.height.isFinite &&
            rectangle.width > 0 &&
            rectangle.height > 0
    }
}
