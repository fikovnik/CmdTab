import AppKit
import CmdTabModel

/// Focus a window on any Space. First show its Space, then restore, front, and raise the window.
/// Restore the previous front app only when its Space is no longer visible.
/// Use private focus calls because macOS can refuse activation from an accessory app.
@MainActor
enum Focus {
    private struct Origin {
        let space: SpaceID
        let pid: pid_t
    }

    private struct Pending {
        let window: Window
        let space: SpaceID
        let origin: Origin?
        let timer: Timer
    }

    /// If the Space notification does not arrive, continue after one second.
    private static let spaceChangeTimeout: TimeInterval = 1

    /// A new focus request replaces the request that waits for a Space change.
    private static var pending: Pending?

    static var diagnosticSummary: String {
        pending.map { "Focus: pending id=\($0.window.id) space=\($0.space)" } ?? "Focus: idle"
    }

    static func focus(_ window: Window) {
        pending?.timer.invalidate()
        pending = nil

        let layout = Spaces.layout()
        let origin = origin(in: layout)
        let isVisible = window.spaces.contains(where: layout.visibleSpaces.contains)
        guard !isVisible, let space = window.spaces.first, SpaceSwitcher.show(space, in: layout) else {
            run(window, origin: origin)
            return
        }

        Diagnostics.note("focus waiting id=\(window.id) space=\(space)")
        let timer = Timer(timeInterval: spaceChangeTimeout, repeats: false) { _ in
            MainActor.assumeIsolated {
                Diagnostics.error("Space change timed out")
                finishPending()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pending = Pending(window: window, space: space, origin: origin, timer: timer)
    }

    /// Continue only after the target Space becomes visible.
    static func spaceDidChange() {
        guard let pending, Spaces.layout().visibleSpaces.contains(pending.space) else { return }
        finishPending()
    }

    private static func finishPending() {
        guard let pending else { return }
        self.pending = nil
        pending.timer.invalidate()
        run(pending.window, origin: pending.origin)
    }

    private static func origin(in layout: SpaceLayout) -> Origin? {
        guard let space = layout.display(identifier: Spaces.activeDisplayIdentifier())?.currentSpace,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }
        return Origin(space: space, pid: pid)
    }

    private static func run(_ window: Window, origin: Origin?) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }

        let element = window.element ?? AXUIElement.window(window.id, pid: window.pid)
        if element?.bool(kAXMinimizedAttribute) == true {
            element?.set(kAXMinimizedAttribute, kCFBooleanFalse)
        }

        let fronted = WindowServer.front(window: window.id, pid: window.pid)
        if !fronted { Diagnostics.error("could not front window id=\(window.id) pid=\(window.pid)") }

        // If the cached AX element is invalid, retry once with a new element.
        var raise = element?.perform(kAXRaiseAction)
        if raise == .invalidUIElement, let fresh = AXUIElement.window(window.id, pid: window.pid) {
            raise = fresh.perform(kAXRaiseAction)
        }

        // If the previous Space remains visible, keep its current front app.
        if let origin, origin.pid != window.pid, !window.spaces.isEmpty,
           !window.spaces.contains(origin.space),
           !Spaces.layout().visibleSpaces.contains(origin.space) {
            WindowServer.setFrontApp(origin.pid, of: origin.space)
        }

        Diagnostics.note("focus id=\(window.id) fronted=\(fronted) raise=\(raise.map { "\($0.rawValue)" } ?? "no element") \(window.appName) | \(window.title)")

        // Update focus order from observed focus after the request completes.
        let (id, pid) = (window.id, window.pid)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { WindowTracker.shared.readFocus(of: pid) }
        }
        if Diagnostics.isLoggingEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    guard Diagnostics.isLoggingEnabled else { return }
                    let focused = AXUIElement.application(pid).element(kAXFocusedWindowAttribute)?.windowID
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    Diagnostics.note("focus took=\(focused == id && front == pid) id=\(id) focused=\(focused.map(String.init) ?? "nil")")
                }
            }
        }
    }
}
