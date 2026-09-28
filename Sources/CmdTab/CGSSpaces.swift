import AppKit

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

/// kCGSSpaceCurrent | kCGSSpaceOther | kCGSSpaceAll
private let allSpacesMask: Int32 = 7

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: CGSConnectionID,
                                     _ mask: Int32,
                                     _ windowIDs: CFArray) -> Unmanaged<CFArray>?

/// Which Space a window lives on, what to call that Space, and how the Spaces
/// are ordered left to right.
///
/// None of this has a public API. These are the same CGS SPIs every macOS
/// window switcher relies on, and they have been stable since Spaces shipped.
///
/// The windows themselves come from `WindowServer`, which needs the ordered
/// Space ids this class produces.
@MainActor
final class SpaceMap {
    /// One physical display and the desktops on it, in left-to-right order.
    /// Switching Spaces needs both halves: the identifier names the display,
    /// and desktop numbers are per-display because "Displays have separate
    /// Spaces" is the default.
    struct Display {
        let identifier: String
        /// Normal desktops only, because a full-screen Space has no number.
        let desktops: [CGSSpaceID]
        let currentSpace: CGSSpaceID?
    }

    private let connection = CGSMainConnectionID()
    private(set) var displays: [Display] = []
    private var labels: [CGSSpaceID: String] = [:]
    private var numbers: [CGSSpaceID: Int] = [:]
    private var ranks: [CGSSpaceID: Int] = [:]
    private var ordered: [CGSSpaceID] = []
    private var cache: [CGWindowID: CGSSpaceID?] = [:]

    init() {
        guard let raw = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue(),
              let displays = raw as? [[String: Any]]
        else { return }

        let multipleDisplays = displays.count > 1
        var rank = 0

        for (displayIndex, display) in displays.enumerated() {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            var desktopNumber = 0
            var desktops: [CGSSpaceID] = []

            for space in spaces {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }

                // type 0 is a normal desktop. Anything else is a full-screen Space.
                var label: String
                if (space["type"] as? NSNumber)?.intValue ?? 0 == 0 {
                    desktopNumber += 1
                    numbers[id] = desktopNumber
                    desktops.append(id)
                    label = "Desktop \(desktopNumber)"
                } else {
                    label = "Full Screen"
                }
                if multipleDisplays { label += " · Display \(displayIndex + 1)" }

                labels[id] = label
                ranks[id] = rank
                ordered.append(id)
                rank += 1
            }

            if let identifier = display["Display Identifier"] as? String {
                let current = (display["Current Space"] as? [String: Any])
                    .flatMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
                self.displays.append(Display(identifier: identifier,
                                             desktops: desktops,
                                             currentSpace: current))
            }
        }
    }

    /// The Space showing on each display right now.
    ///
    /// Read fresh from the WindowServer rather than off an instance: this
    /// decides how a window gets focused, and a stale answer picks the wrong
    /// route. With "Displays have separate Spaces" (the macOS default) more
    /// than one Space is visible at a time, so the focused display's active
    /// Space is not the whole answer.
    static func visibleSpaces() -> Set<CGSSpaceID> {
        guard let raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue(),
              let displays = raw as? [[String: Any]]
        else { return [] }

        var result: Set<CGSSpaceID> = []
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any],
                  let id = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value
            else { continue }
            result.insert(id)
        }
        return result
    }

    /// The display whose current Space is the active one, i.e. the display the
    /// keyboard is talking to. Desktop numbers are relative to it.
    func activeDisplay(activeSpace: CGSSpaceID) -> Display? {
        displays.first { $0.currentSpace == activeSpace }
            ?? displays.first { $0.desktops.contains(activeSpace) }
    }

    func space(forWindow window: CGWindowID) -> CGSSpaceID? {
        if let cached = cache[window] { return cached }
        let ids = CGSCopySpacesForWindows(connection, allSpacesMask, [window] as CFArray)?
            .takeRetainedValue() as? [NSNumber]
        let result = ids?.first?.uint64Value
        cache[window] = result
        return result
    }

    func label(forWindow window: CGWindowID) -> String? {
        space(forWindow: window).flatMap { labels[$0] }
    }

    /// Left-to-right position of a window's Space, used to group the list.
    func rank(forWindow window: CGWindowID) -> Int {
        space(forWindow: window).flatMap { ranks[$0] } ?? .max
    }

    func label(forSpace space: CGSSpaceID) -> String? { labels[space] }

    /// The Space's position within its display, as Mission Control numbers it.
    /// Nil for a full-screen Space, which has no desktop number.
    func number(forSpace space: CGSSpaceID) -> Int? { numbers[space] }

    /// Every Space, left to right.
    var orderedSpaces: [CGSSpaceID] { ordered }

    /// Record which Space a window was found on, from a scan that already
    /// knows. Saves a `CGSCopySpacesForWindows` round trip per window, and
    /// keeps the map current for a window dragged to another Space.
    func note(window: CGWindowID, onSpace space: CGSSpaceID) {
        cache[window] = space
    }
}
