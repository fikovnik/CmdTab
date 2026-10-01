import AppKit

/// kCGSSpaceCurrent | kCGSSpaceOther | kCGSSpaceAll
private let allSpacesMask: Int32 = 7

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
    private let connection = CGSMainConnectionID()
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

            for space in spaces {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }

                // type 0 is a normal desktop. Anything else is a full-screen Space.
                var label: String
                if (space["type"] as? NSNumber)?.intValue ?? 0 == 0 {
                    desktopNumber += 1
                    numbers[id] = desktopNumber
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
        }
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
