import AppKit
import CmdTabModel

/// Gives keyboard focus to a window on any Space of any display.
///
/// The sequence is the same as in alt-tab:
/// 1. Restore the window if it is minimized.
/// 2. Make the app the front process, with this window as the key window
///    (`WindowServer.front`).
/// 3. Raise the window in the window stack of its app (`kAXRaiseAction`).
/// 4. If the window is on a different Space, restore the front app of the
///    Space that the user left (alt-tab #4507).
///
/// Do not use `NSRunningApplication.activate()`. Since macOS 14 it is only a
/// request, and macOS can refuse it from an app that is not active. CmdTab is
/// never active. Then the window comes to the front, but the menu bar stays
/// with the previous app.
///
/// A window on a Space that is not visible must become visible first. Thus,
/// `focus` switches to that Space with a Dock swipe, and does the sequence
/// when the Space change occurs.
@MainActor
enum Focus {
    /// The Space and the front app before the focus.
    private struct Origin {
        let space: SpaceID
        let pid: pid_t
    }

    private struct Pending {
        let window: WindowRef
        let space: SpaceID
        let origin: Origin?
        let timer: Timer
    }

    /// If the Space change does not occur in this time, do the sequence
    /// without it. With an AX element, the Dock then switches the Space itself.
    private static let spaceChangeTimeout: TimeInterval = 1

    /// A focus that waits for a Space change. A new focus replaces it.
    private static var pending: Pending?

    static func focus(_ window: WindowRef) {
        pending?.timer.invalidate()
        pending = nil

        let layout = Spaces.layout()
        let origin = origin(in: layout)
        let space = WindowRegistry.shared.space(forWindow: window.id)
        guard let space, !layout.visibleSpaces.contains(space), SpaceSwitcher.show(space, in: layout)
        else {
            run(window, spaces: space.map { [$0] } ?? [], origin: origin)
            return
        }

        let timer = Timer(timeInterval: spaceChangeTimeout, repeats: false) { _ in
            MainActor.assumeIsolated { finishPending() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pending = Pending(window: window, space: space, origin: origin, timer: timer)
    }

    /// Call on each Space change. Continues the pending focus when its Space
    /// is visible.
    static func spaceDidChange() {
        guard let pending, Spaces.layout().visibleSpaces.contains(pending.space) else { return }
        finishPending()
    }

    private static func finishPending() {
        guard let pending else { return }
        self.pending = nil
        pending.timer.invalidate()
        run(pending.window, spaces: [pending.space], origin: pending.origin)
    }

    private static func origin(in layout: SpaceLayout) -> Origin? {
        guard let space = layout.display(identifier: Spaces.activeDisplayIdentifier())?.currentSpace,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }
        return Origin(space: space, pid: pid)
    }

    private static func run(_ window: WindowRef, spaces: [SpaceID], origin: Origin?) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }

        let element = window.element ?? AXUIElement.window(window.id, pid: window.pid)
        if element?.bool(kAXMinimizedAttribute) == true {
            element?.set(kAXMinimizedAttribute, kCFBooleanFalse)
        }

        let fronted = WindowServer.front(window: window.id, pid: window.pid)

        // An app can replace the AX element of a window. Then the old element
        // gives `.invalidUIElement`, and only a new element can raise the window.
        var raise = element?.perform(kAXRaiseAction)
        if raise == .invalidUIElement, let fresh = AXUIElement.window(window.id, pid: window.pid) {
            raise = fresh.perform(kAXRaiseAction)
        }

        // Do not do this for a Space that is still visible, for example on the
        // other display. There the call can bring the old app back to the
        // front (alt-tab #5586).
        if let origin, origin.pid != window.pid, !spaces.isEmpty, !spaces.contains(origin.space),
           !Spaces.layout().visibleSpaces.contains(origin.space) {
            WindowServer.setFrontApp(origin.pid, of: origin.space)
        }

        Diagnostics.note("focus id=\(window.id) fronted=\(fronted) raise=\(raise.map { "\($0.rawValue)" } ?? "no element") \(window.appName) | \(window.title)")
        WindowRegistry.shared.promote(window.id)
    }
}
