import AppKit
import ApplicationServices

/// Use one AX observer per app to receive focus changes within the app.
@MainActor
enum AXEvents {
    static func sync(_ pids: Set<pid_t>) {
        for pid in observers.keys where !pids.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        for pid in pids where observers[pid] == nil {
            observers[pid] = observe(pid)
        }
    }

    private static func observe(_ pid: pid_t) -> AXObserver? {
        guard AXIsProcessTrusted() else { return nil }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axEventsCallback, &observer) == .success, let observer else { return nil }
        let app = AXUIElement.application(pid)
        for name in [kAXFocusedWindowChangedNotification,
                     kAXWindowCreatedNotification,
                     kAXUIElementDestroyedNotification,
                     kAXWindowMiniaturizedNotification,
                     kAXWindowDeminiaturizedNotification,
                     kAXTitleChangedNotification] {
            let result = AXObserverAddNotification(observer, app, name as CFString, nil)
            if result != .success && result != .notificationUnsupported {
                Diagnostics.note("AX observer pid=\(pid) notification=\(name) error=\(result.rawValue)")
            }
        }
        // Keep notifications active while a menu is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }
}

@MainActor private var observers: [pid_t: AXObserver] = [:]

private func axEventsCallback(_ observer: AXObserver, _ element: AXUIElement,
                              _ name: CFString, _ context: UnsafeMutableRawPointer?) {
    let name = name as String
    // Keep the AX element in this synchronous call on the main run loop.
    nonisolated(unsafe) let window = element
    MainActor.assumeIsolated {
        let tracker = WindowTracker.shared
        if name == kAXWindowMiniaturizedNotification || name == kAXWindowDeminiaturizedNotification,
           let id = window.windowID {
            tracker.update(id, element: window, title: nil,
                           isMinimized: name == kAXWindowMiniaturizedNotification)
        }
        if name != kAXFocusedWindowChangedNotification && name != kAXTitleChangedNotification {
            tracker.scheduleRefresh()
            return
        }
        // Window controls can also emit title notifications. Accept only window elements.
        guard window.string(kAXRoleAttribute) == kAXWindowRole,
              let id = window.windowID, let pid = window.pid else { return }
        tracker.update(id, element: window, title: window.string(kAXTitleAttribute))
        if name == kAXFocusedWindowChangedNotification,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            tracker.focusReported(id, pid: pid)
        }
    }
}
