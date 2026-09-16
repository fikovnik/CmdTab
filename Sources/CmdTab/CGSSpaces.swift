import AppKit

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

/// kCGSSpaceCurrent | kCGSSpaceOther | kCGSSpaceAll
private let allSpacesMask: Int32 = 7

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: CGSConnectionID,
                                     _ mask: Int32,
                                     _ windowIDs: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
private func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID,
                                              _ owner: UInt32,
                                              _ spaces: CFArray,
                                              _ options: UInt32,
                                              _ setTags: UnsafeMutablePointer<UInt64>,
                                              _ clearTags: UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?

/// Which Space a window lives on, what to call that Space, and how the Spaces
/// are ordered left to right.
///
/// None of this has a public API. These are the same CGS SPIs every macOS
/// window switcher relies on, and they have been stable since Spaces shipped.
///
/// `CGSCopyWindowsWithOptionsAndTags` answers the other half: which windows sit
/// on a Space you are not currently on, which `kAXWindowsAttribute` will not say
/// at all. It omits minimized windows, but that costs nothing here, since AX reports
/// those whatever Space they are on.
@MainActor
final class SpaceMap {
    private let connection = CGSMainConnectionID()
    private var labels: [CGSSpaceID: String] = [:]
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

    /// The WindowServer's own per-Space window list, Spaces left to right.
    ///
    /// Works for Spaces you are not on, which is the whole point, but it counts
    /// every WindowServer window, so an app's utility panels show up as windows
    /// (Lightroom: 12 here against the one real window AX reports). It can say
    /// *which apps* have windows on a Space, not what those windows are, and
    /// that is all the placeholder rows need.
    ///
    /// Options `0x2` is the plain list, and `0x7` would add minimized windows, which
    /// AX already covers on every Space.
    func windowsPerSpace() -> [(space: CGSSpaceID, ids: [CGWindowID])] {
        ordered.map { space in
            var setTags: UInt64 = 0
            var clearTags: UInt64 = 0
            let raw = CGSCopyWindowsWithOptionsAndTags(
                connection, 0, [NSNumber(value: space)] as CFArray, 0x2, &setTags, &clearTags
            )?.takeRetainedValue()
            let ids = (raw as? [NSNumber])?.map { CGWindowID($0.uint32Value) } ?? []
            return (space, ids)
        }
    }
}
