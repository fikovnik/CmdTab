import AppKit
import ApplicationServices

/// One AX observer per app. AX reports focus changes within an app.
@MainActor
enum AXEvents {
    /// Start new observers and remove observers for apps that stopped.
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
        // `.commonModes`, so that notifications also arrive while the event tap is busy.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }
}

@MainActor private var observers: [pid_t: AXObserver] = [:]

/// Use a C function. Swift 6 can fail to compile a closure as an AXObserverCallback.
private func axEventsCallback(_ observer: AXObserver, _ element: AXUIElement,
                              _ name: CFString, _ context: UnsafeMutableRawPointer?) {
    let name = name as String
    // AX observers use the main run loop. Keep the C element reference within this synchronous call.
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
        // Ignore title changes from controls inside a window.
        guard window.string(kAXRoleAttribute) == kAXWindowRole,
              let id = window.windowID, let pid = window.pid else { return }
        tracker.update(id, element: window, title: window.string(kAXTitleAttribute))
        if name == kAXFocusedWindowChangedNotification,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            tracker.focusReported(id, pid: pid)
        }
    }
}
