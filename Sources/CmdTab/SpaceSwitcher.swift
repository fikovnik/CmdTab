import AppKit
import CmdTabConfig
import CmdTabModel

/// Switches Spaces through the Dock.
///
/// macOS has no public API to switch Spaces. `CGSManagedDisplaySetCurrentSpace`
/// changes the Space in the WindowServer, but the Dock does not do its
/// transition. Then the menu bar of the old Space stays on screen.
///
/// Thus, CmdTab posts a synthetic Dock swipe, and the Dock does the switch as
/// for a trackpad swipe. A very high velocity with almost no progress makes
/// the switch instant. The method comes from InstantSpaceSwitcher.
@MainActor
enum SpaceSwitcher {
    /// Shows desktop `number` (1-based) on the display with the active menu
    /// bar. The system Ctrl+N shortcuts use the same display.
    static func activate(desktop number: Int) {
        guard let display = activeDisplay() else { return }
        guard let swipes = display.swipes(toDesktop: number) else {
            Log.note("desktop-\(number): display has \(display.desktops.count) desktop(s)")
            return
        }
        swipe(swipes, on: display)
    }

    /// Moves `offset` Spaces to the left or right on the display with the
    /// active menu bar. Full-screen Spaces count, as for Ctrl+Left/Right.
    static func step(_ offset: Int) {
        guard let display = activeDisplay(), let swipes = display.swipes(by: offset) else { return }
        swipe(swipes, on: display)
    }

    /// Shows `space` on its display. Returns false if no swipe was necessary
    /// or possible.
    static func show(_ space: SpaceID, in layout: SpaceLayout) -> Bool {
        guard let display = layout.display(containing: space),
              let swipes = display.swipes(to: space), swipes != 0
        else { return false }
        return swipe(swipes, on: display)
    }

    private static func activeDisplay() -> SpaceLayout.Display? {
        let display = Spaces.layout().display(identifier: Spaces.activeDisplayIdentifier())
        if display == nil { Log.note("could not identify the display with the active menu bar") }
        return display
    }

    /// Posts one swipe for each Space to move. A negative count moves left.
    @discardableResult
    private static func swipe(_ count: Int, on display: SpaceLayout.Display) -> Bool {
        guard count != 0, let frame = Spaces.frame(of: display) else { return false }
        // The Dock applies a swipe to the display that contains the event
        // location. The location does not move the pointer.
        let location = CGPoint(x: frame.midX, y: frame.midY)
        let sign: Double = count > 0 ? 1 : -1
        let velocity = sign * DockSwipe.velocity * Double(abs(count))
        for _ in 0..<abs(count) {
            for phase in DockSwipe.phases {
                guard let event = CGEvent(source: nil) else { return false }
                event.location = location
                // The user holds the modifiers of the chord. Do not send them
                // with the gesture.
                event.flags = []
                event.setIntegerValueField(DockSwipe.eventType, value: DockSwipe.dockControl)
                event.setIntegerValueField(DockSwipe.hidType, value: DockSwipe.dockSwipe)
                event.setIntegerValueField(DockSwipe.phase, value: phase)
                event.setIntegerValueField(DockSwipe.motion, value: DockSwipe.horizontal)
                event.setDoubleValueField(DockSwipe.progress, value: sign * DockSwipe.minimumProgress)
                event.setDoubleValueField(DockSwipe.velocityX, value: velocity)
                event.setDoubleValueField(DockSwipe.velocityY, value: velocity)
                event.post(tap: .cgSessionEventTap)
            }
        }
        return true
    }
}

/// The fields of a synthetic Dock swipe. Apple does not document them. The
/// values come from InstantSpaceSwitcher (`Sources/ISS/ISS.c`).
private enum DockSwipe {
    static let eventType = CGEventField(rawValue: 55)!
    static let hidType = CGEventField(rawValue: 110)!
    static let motion = CGEventField(rawValue: 123)!
    static let progress = CGEventField(rawValue: 124)!
    static let velocityX = CGEventField(rawValue: 129)!
    static let velocityY = CGEventField(rawValue: 130)!
    static let phase = CGEventField(rawValue: 132)!

    /// CGS event type `kCGSEventDockControl`.
    static let dockControl: Int64 = 30
    /// IOHID event type `kIOHIDEventTypeDockSwipe`.
    static let dockSwipe: Int64 = 23
    static let horizontal: Int64 = 1
    /// Began, changed, ended. The Dock ignores a swipe that has fewer phases.
    static let phases: [Int64] = [1, 2, 4]
    /// The smallest positive `Float`. With this progress, the switch has no
    /// animation.
    static let minimumProgress = Double(Float.leastNonzeroMagnitude)
    static let velocity: Double = 2000
}
