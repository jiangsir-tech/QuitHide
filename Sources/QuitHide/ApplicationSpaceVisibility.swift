import AppKit
import CoreGraphics
import Foundation

enum ApplicationInactiveSpaceVisibilityPolicy {
    static func processIdentifiersWithVisibleWindowsOnInactiveSpaces(
        activeSpaceWindowIDs: Set<UInt32>,
        allSpaceWindowIDs: Set<UInt32>,
        windowOwners: [UInt32: Int32]
    ) -> Set<Int32> {
        Set(allSpaceWindowIDs.subtracting(activeSpaceWindowIDs).compactMap {
            windowOwners[$0]
        })
    }
}

enum ApplicationInactiveSpaceVisibilityProvider {
    static func processIdentifiersWithVisibleWindowsOnInactiveSpaces()
        -> Set<Int32> {
        let activeSpaceWindowIDs = Set(
            (NSWindow.windowNumbers(options: [.allApplications]) ?? [])
                .map(\.uint32Value)
        )
        let allSpaceWindowIDs = Set(
            (NSWindow.windowNumbers(
                options: [.allApplications, .allSpaces]
            ) ?? []).map(\.uint32Value)
        )
        let inactiveSpaceWindowIDs =
            allSpaceWindowIDs.subtracting(activeSpaceWindowIDs)
        guard !inactiveSpaceWindowIDs.isEmpty,
              let rawWindowList = CGWindowListCopyWindowInfo(
                .optionAll,
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return []
        }

        var windowOwners: [UInt32: Int32] = [:]
        for dictionary in rawWindowList {
            guard let windowID =
                    (dictionary[kCGWindowNumber as String] as? NSNumber)?
                        .uint32Value,
                  inactiveSpaceWindowIDs.contains(windowID),
                  let ownerPID =
                    (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?
                        .int32Value else {
                continue
            }
            windowOwners[windowID] = ownerPID
        }

        return ApplicationInactiveSpaceVisibilityPolicy
            .processIdentifiersWithVisibleWindowsOnInactiveSpaces(
                activeSpaceWindowIDs: activeSpaceWindowIDs,
                allSpaceWindowIDs: allSpaceWindowIDs,
                windowOwners: windowOwners
            )
    }
}
