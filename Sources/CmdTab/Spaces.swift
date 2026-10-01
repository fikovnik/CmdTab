import AppKit
import CmdTabModel

/// Reads the Space layout and the display geometry from the WindowServer.
@MainActor
enum Spaces {
    /// The Spaces of all displays. One WindowServer call.
    static func layout() -> SpaceLayout {
        let raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue()
        return SpaceLayout(managedDisplaySpaces: raw as? [[String: Any]] ?? [])
    }

    /// The UUID of the display with the active menu bar, that is, the display
    /// that has keyboard focus.
    static func activeDisplayIdentifier() -> String? {
        CGSCopyActiveMenuBarDisplayIdentifier(CGSMainConnectionID())?.takeRetainedValue() as String?
    }

    /// The frame of a display in global coordinates, origin at the top left.
    static func frame(of display: SpaceLayout.Display) -> CGRect? {
        // With shared Spaces, all displays switch together. Any display is correct.
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
