import AppKit
import CmdTabConfig
import CmdTabModel

/// Post Dock swipe events to switch Spaces. Direct WindowServer changes can leave the Dock and menu bar on the old Space.
/// The gesture fields come from InstantSpaceSwitcher.
@MainActor
enum SpaceSwitcher {
    /// Use the display with the active menu bar.
    /// Desktop numbers start at one and exclude full screen Spaces.
    static func activate(desktop number: Int) {
        guard let display = activeDisplay() else { return }
        guard let swipes = display.swipes(toDesktop: number) else {
            Diagnostics.error("desktop-\(number): display has \(display.desktops.count) desktop(s)")
            return
        }
        swipe(swipes, on: display)
    }

    /// Move by Space offset on the active display. Include full screen Spaces and stop at either end.
    static func step(_ offset: Int) {
        guard let display = activeDisplay(), let swipes = display.swipes(by: offset) else { return }
        swipe(swipes, on: display)
    }

    private static func activeDisplay() -> SpaceLayout.Display? {
        let display = Spaces.layout().display(identifier: Spaces.activeDisplayIdentifier())
        if display == nil { Diagnostics.error("could not identify the display with the active menu bar") }
        return display
    }

    /// A negative count moves left. Each move uses one complete swipe sequence.
    @discardableResult
    private static func swipe(_ count: Int, on display: SpaceLayout.Display) -> Bool {
        guard count != 0, let frame = Spaces.frame(of: display) else { return false }
        // The Dock uses the event location to select a display. This location does not move the pointer.
        let location = CGPoint(x: frame.midX, y: frame.midY)
        let sign: Double = count > 0 ? 1 : -1
        let velocity = sign * DockSwipe.velocity * Double(abs(count))
        for _ in 0..<abs(count) {
            for phase in DockSwipe.phases {
                guard let event = CGEvent(source: nil) else { return false }
                event.location = location
                // Keep the held shortcut modifiers out of the gesture.
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

/// Undocumented Dock gesture fields from InstantSpaceSwitcher, Sources/ISS/ISS.c.
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
    /// Use all three gesture phases in order: begin, change, and end.
    static let phases: [Int64] = [1, 2, 4]
    /// Keep gesture progress small to avoid a visible animation.
    static let minimumProgress = Double(Float.leastNonzeroMagnitude)
    static let velocity: Double = 2000
}
