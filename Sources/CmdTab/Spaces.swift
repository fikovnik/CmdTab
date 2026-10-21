import AppKit
import CmdTabModel

/// Read Space data from the WindowServer and display geometry from Core Graphics.
@MainActor
enum Spaces {
    static func layout() -> SpaceLayout {
        let raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue()
        return SpaceLayout(managedDisplaySpaces: raw as? [[String: Any]] ?? [])
    }

    /// Return the UUID of the display with the active menu bar.
    static func activeDisplayIdentifier() -> String? {
        CGSCopyActiveMenuBarDisplayIdentifier(CGSMainConnectionID())?.takeRetainedValue() as String?
    }

    /// Return a frame in global coordinates with the origin at the top left.
    static func frame(of display: SpaceLayout.Display) -> CGRect? {
        // For shared Spaces, use the primary display because all displays switch together.
        if display.identifier == "Main" { return CGDisplayBounds(CGMainDisplayID()) }

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        for id in ids.prefix(Int(count)) {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  CFUUIDCreateString(nil, uuid) as String == display.identifier
            else { continue }
            return CGDisplayBounds(id)
        }
        return nil
    }
}
