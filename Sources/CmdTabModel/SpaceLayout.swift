import Foundation

/// A Space identifier, as the WindowServer reports it.
public typealias SpaceID = UInt64

/// The Spaces of all displays, from one `CGSCopyManagedDisplaySpaces` read.
///
/// A layout is a snapshot. Read a new one for each operation, because the
/// user can add, remove and move Spaces at any time.
public struct SpaceLayout: Equatable, Sendable {
    public struct Space: Equatable, Sendable {
        public let id: SpaceID
        /// A full-screen Space holds one window and has no desktop number.
        public let isFullScreen: Bool

        public init(id: SpaceID, isFullScreen: Bool) {
            self.id = id
            self.isFullScreen = isFullScreen
        }
    }

    public struct Display: Equatable, Sendable {
        /// The display UUID. The value is "Main" when all displays share one
        /// set of Spaces ("Displays have separate Spaces" is off).
        public let identifier: String
        /// Left to right, in the order that Mission Control shows.
        public let spaces: [Space]
        /// The Space that the display shows now.
        public let currentSpace: SpaceID?

        public init(identifier: String, spaces: [Space], currentSpace: SpaceID?) {
            self.identifier = identifier
            self.spaces = spaces
            self.currentSpace = currentSpace
        }

        /// The normal desktops, without the full-screen Spaces.
        public var desktops: [SpaceID] { spaces.filter { !$0.isFullScreen }.map(\.id) }

        /// The number of one-Space moves from the current Space to `space`.
        /// A negative value moves left. The count includes full-screen Spaces,
        /// because a Dock swipe stops on each of them.
        public func swipes(to space: SpaceID) -> Int? {
            guard let currentSpace,
                  let from = spaces.firstIndex(where: { $0.id == currentSpace }),
                  let to = spaces.firstIndex(where: { $0.id == space })
            else { return nil }
            return to - from
        }

        /// The moves to desktop `number` (1-based). Nil if there is no such desktop.
        public func swipes(toDesktop number: Int) -> Int? {
            guard desktops.indices.contains(number - 1) else { return nil }
            return swipes(to: desktops[number - 1])
        }

        /// The moves for `offset` Spaces to the left or right, limited to the
        /// first and the last Space.
        public func swipes(by offset: Int) -> Int? {
            guard let currentSpace,
                  let from = spaces.firstIndex(where: { $0.id == currentSpace })
            else { return nil }
            return min(max(from + offset, 0), spaces.count - 1) - from
        }
    }

    public let displays: [Display]

    public init(displays: [Display]) {
        self.displays = displays
    }

    /// Reads the output of `CGSCopyManagedDisplaySpaces`. Each Space has a
    /// `ManagedSpaceID` and a `type`. Type 0 is a desktop. Other types are
    /// full-screen Spaces.
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

    /// The Spaces that are on screen now, one for each display.
    public var visibleSpaces: Set<SpaceID> { Set(displays.compactMap(\.currentSpace)) }

    /// The display with this UUID. When all displays share one set of Spaces,
    /// the one "Main" display matches every UUID.
    public func display(identifier: String?) -> Display? {
        if displays.count == 1, displays[0].identifier == "Main" { return displays[0] }
        return displays.first { $0.identifier == identifier }
    }

    public func display(containing space: SpaceID) -> Display? {
        displays.first { display in display.spaces.contains { $0.id == space } }
    }

    /// The position of a Space when all displays are put in sequence.
    public func order(of space: SpaceID) -> Int? {
        displays.flatMap(\.spaces).firstIndex { $0.id == space }
    }

    /// The desktop number in Mission Control. Nil for a full-screen Space.
    public func desktopNumber(of space: SpaceID) -> Int? {
        display(containing: space)?.desktops.firstIndex(of: space).map { $0 + 1 }
    }

    /// "Desktop 2", "Full Screen", with " · Display 2" when there are two or
    /// more displays.
    public func label(of space: SpaceID) -> String? {
        guard let index = displays.firstIndex(where: { display in
            display.spaces.contains { $0.id == space }
        }) else { return nil }
        var label = desktopNumber(of: space).map { "Desktop \($0)" } ?? "Full Screen"
        if displays.count > 1 { label += " · Display \(index + 1)" }
        return label
    }
}
