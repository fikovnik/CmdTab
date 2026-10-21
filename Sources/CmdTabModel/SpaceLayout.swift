import Foundation

/// Use Space identifiers from the WindowServer.
public typealias SpaceID = UInt64

/// Read a new snapshot of all display Spaces for each operation.
public struct SpaceLayout: Equatable, Sendable {
    public struct Space: Equatable, Sendable {
        public let id: SpaceID
        /// A full screen Space has no desktop number.
        public let isFullScreen: Bool

        public init(id: SpaceID, isFullScreen: Bool) {
            self.id = id
            self.isFullScreen = isFullScreen
        }
    }

    public struct Display: Equatable, Sendable {
        /// Use the display UUID. `Main` identifies one shared set of Spaces.
        public let identifier: String
        /// Keep Spaces in the order that Mission Control shows.
        public let spaces: [Space]
        public let currentSpace: SpaceID?

        public init(identifier: String, spaces: [Space], currentSpace: SpaceID?) {
            self.identifier = identifier
            self.spaces = spaces
            self.currentSpace = currentSpace
        }

        public var desktops: [SpaceID] { spaces.filter { !$0.isFullScreen }.map(\.id) }

        /// Return the signed number of Space moves. Include full screen Spaces. A negative value moves left.
        public func swipes(to space: SpaceID) -> Int? {
            guard let currentSpace,
                  let from = spaces.firstIndex(where: { $0.id == currentSpace }),
                  let to = spaces.firstIndex(where: { $0.id == space })
            else { return nil }
            return to - from
        }

        /// Desktop numbers start at one. Return nil if the desktop does not exist.
        public func swipes(toDesktop number: Int) -> Int? {
            let desktops = desktops
            guard number > 0, number <= desktops.count else { return nil }
            return swipes(to: desktops[number - 1])
        }

        /// Stop at the first or last Space.
        public func swipes(by offset: Int) -> Int? {
            guard let currentSpace,
                  let from = spaces.firstIndex(where: { $0.id == currentSpace })
            else { return nil }
            return min(max(offset, -from), spaces.count - 1 - from)
        }
    }

    public let displays: [Display]

    public init(displays: [Display]) {
        self.displays = displays
    }

    /// Treat type zero as a desktop. Treat other types as full screen Spaces.
    public init(managedDisplaySpaces: [[String: Any]]) {
        displays = managedDisplaySpaces.map { display in
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> Space? in
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                return Space(id: id, isFullScreen: type != 0)
            }
            let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
            return Display(identifier: display["Display Identifier"] as? String ?? "",
                           spaces: spaces,
                           currentSpace: current?.uint64Value)
        }
    }

    /// Include the visible Space of each display.
    public var visibleSpaces: Set<SpaceID> { Set(displays.compactMap(\.currentSpace)) }

    /// A shared `Main` display matches every UUID.
    public func display(identifier: String?) -> Display? {
        if displays.count == 1, displays[0].identifier == "Main" { return displays[0] }
        return displays.first { $0.identifier == identifier }
    }

    public func display(containing space: SpaceID) -> Display? {
        displays.first { display in display.spaces.contains { $0.id == space } }
    }

    /// Use display order, then Space order, for one global index.
    public func order(of space: SpaceID) -> Int? {
        displays.flatMap(\.spaces).firstIndex { $0.id == space }
    }

    /// Return the Mission Control desktop number. Return nil for a full screen Space or an unknown Space.
    public func desktopNumber(of space: SpaceID) -> Int? {
        display(containing: space)?.desktops.firstIndex(of: space).map { $0 + 1 }
    }

    /// If there is more than one display, include the display number in the label.
    public func label(of space: SpaceID) -> String? {
        guard let index = displays.firstIndex(where: { display in
            display.spaces.contains { $0.id == space }
        }) else { return nil }
        var label = desktopNumber(of: space).map { "Desktop \($0)" } ?? "Full Screen"
        if displays.count > 1 { label += " · Display \(index + 1)" }
        return label
    }
}
