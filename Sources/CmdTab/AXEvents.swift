import AppKit
import ApplicationServices

/// One AX observer for each app, for focus changes, new windows and title
/// changes.
///
/// An observer on the application element receives the notifications of all
/// windows of the app. `NSWorkspace` reports only app activations. Thus, AX
/// is the only report of a switch between two windows of the same app.
@MainActor
enum AXEvents {
    /// Starts an observer for each new app, and stops the observers of the
    /// apps that quit.
    static func sync(_ pids: Set<pid_t>) {
        for pid in observers.keys where !pids.contains(pid) {
            observers[pid] = nil
        }
        for pid in pids where observers[pid] == nil {
            observers[pid] = observe(pid)
        }
    }

    private static func observe(_ pid: pid_t) -> AXObserver? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, axEventsCallback, &observer) == .success, let observer else { return nil }
        let app = AXUIElementCreateApplication(pid)
        for name in [kAXFocusedWindowChangedNotification,
                     kAXWindowCreatedNotification,
                     kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, nil)
        }
        // `.commonModes`, so that notifications also arrive while the event tap is busy.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }
}

@MainActor private var observers: [pid_t: AXObserver] = [:]

/// A C function, not a closure: the Swift 6 compiler crashes when it converts
/// a closure of this type to `AXObserverCallback`.
private func axEventsCallback(_ observer: AXObserver, _ element: AXUIElement,
                              _ name: CFString, _ context: UnsafeMutableRawPointer?) {
    let name = name as String
    // The run loop source of the observer is on the main thread.
    if name == kAXWindowCreatedNotification {
        // A new window has no WindowServer ID yet. The refresh comes later.
        MainActor.assumeIsolated { WindowTracker.shared.scheduleRefresh() }
        return
    }

    // Apps also send `AXTitleChanged` for buttons and text fields. They give
    // the ID of their window, so only an element with the window role counts.
    guard element.string(kAXRoleAttribute) == kAXWindowRole,
          let id = element.windowID, let pid = element.pid
    else { return }
    let title = element.string(kAXTitleAttribute)
    let focused = name == kAXFocusedWindowChangedNotification

    // `AXUIElement` is not `Sendable`. The hop is synchronous and this
    // function keeps no other reference, so no race can occur.
    nonisolated(unsafe) let window = element
    MainActor.assumeIsolated {
        let tracker = WindowTracker.shared
        tracker.update(id, element: window, title: title)
        WindowPreview.shared.recapture(id)
        // A background app can change its key window. That is not a switch.
        if focused, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            tracker.focusReported(id, pid: pid)
        }
    }
}
