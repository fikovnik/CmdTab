import CmdTabConfig
import CoreFoundation

// Switching Spaces has no public API. This is the same SPI System Settings'
// own shortcuts end up in, and it applies immediately, verified by switching
// away and back and watching `SLSGetActiveSpace` follow.
//
// `CGSMainConnectionID` is shared with `CGSSpaces.swift` rather than declared
// twice: two @_silgen_name declarations of one symbol in a single module is
// asking for trouble.
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID,
                                              _ display: CFString,
                                              _ space: CGSSpaceID)
@MainActor
enum SpaceSwitcher {
    /// Switch the focused display to its `number`-th desktop, 1-based.
    ///
    /// Desktop numbers are per-display, because "Displays have separate
    /// Spaces" is the macOS default, so this means the same thing the system's
    /// own shortcuts mean: the Nth desktop of the display you are looking at.
    static func activate(desktop number: Int) {
        guard let display = focusedDisplay() else { return }
        guard number >= 1, number <= display.desktops.count else {
            Log.note("desktop-\(number): display has \(display.desktops.count) desktop(s)")
            return
        }
        switchTo(display.desktops[number - 1], on: display.identifier)
    }

    /// Move `offset` desktops along on the focused display. Clamped, not
    /// wrapped, matching how macOS treats its own next/previous shortcuts.
    static func step(_ offset: Int) {
        guard let display = focusedDisplay(),
              let current = display.currentSpace,
              let index = display.desktops.firstIndex(of: current)
        else { return }
        let target = index + offset
        guard target >= 0, target < display.desktops.count else { return }
        switchTo(display.desktops[target], on: display.identifier)
    }

    /// Rebuilt per call rather than cached: desktops are created and destroyed
    /// while the app runs, and a stale map here would switch to the wrong one.
    private static func focusedDisplay() -> SpaceMap.Display? {
        let display = SpaceMap().activeDisplay(activeSpace: WindowServer.activeSpace)
        if display == nil { Log.note("could not identify the focused display") }
        return display
    }

    private static func switchTo(_ space: CGSSpaceID, on display: String) {
        guard space != WindowServer.activeSpace else { return }
        CGSManagedDisplaySetCurrentSpace(CGSMainConnectionID(), display as CFString, space)
    }
}
