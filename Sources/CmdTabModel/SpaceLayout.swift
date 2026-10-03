import Foundation

/// A Space identifier, as the WindowServer reports it.
public typealias SpaceID = UInt64

/// A snapshot of all display Spaces. Read a new snapshot for each operation.
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
        /// The display UUID. Main denotes one shared set of Spaces.
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

        /// The signed count of Space moves to the target. Include full screen Spaces.
        public func swipes(to space: SpaceID) -> Int? {
            guard let currentSpace,
                  let from = spaces.firstIndex(where: { $0.id == currentSpace }),
                  let to = spaces.firstIndex(where: { $0.id == space })
            else { return nil }
            return to - from
        }

        /// The moves to desktop `number` (1-based). Nil if there is no such desktop.
        public func swipes(toDesktop number: Int) -> Int? {
            let desktops = desktops
            guard number > 0, number <= desktops.count else { return nil }
            return swipes(to: desktops[number - 1])
        }

        /// Limit the Space offset to the first and last Space.
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

    /// Read the private server dictionary. Type zero denotes a desktop. Other types denote full screen Spaces.
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

    /// Find the UUID. A shared Main display matches every UUID.
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

    /// The Space label. Include the display number when more than one display is present.
    public func label(of space: SpaceID) -> String? {
        guard let index = displays.firstIndex(where: { display in
            display.spaces.contains { $0.id == space }
        }) else { return nil }
        var label = desktopNumber(of: space).map { "Desktop \($0)" } ?? "Full Screen"
        if displays.count > 1 { label += " · Display \(index + 1)" }
        return label
    }
}
