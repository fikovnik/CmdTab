import AppKit
import ApplicationServices

struct WindowRef {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let element: AXUIElement
    let icon: NSImage?
}

enum WindowEnumerator {

    /// Windows that are visible on the current Space, across all screens,
    /// ordered most-recently-used first.
    ///
    /// MRU is derived from the CGWindowList z-order rather than from bookkeeping
    /// of focus events: macOS raises a window when it is focused, so front-to-back
    /// z-order *is* the MRU order, and it can never go stale or leak.
    static func currentSpaceWindowsMRU() -> [WindowRef] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var zOrder: [CGWindowID: Int] = [:]
        var pids: [pid_t] = []

        for (z, info) in infoList.enumerated() {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != selfPID
            else { continue }

            // Drop tiny helper windows (tooltips, popovers, status shims).
            if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
               let w = bounds["Width"], let h = bounds["Height"], w < 80 || h < 80 {
                continue
            }

            zOrder[id] = z
            if !pids.contains(pid) { pids.append(pid) }
        }

        var found: [WindowRef] = []
        for pid in pids {
            found.append(contentsOf: axWindows(pid: pid, keeping: zOrder))
        }

        return found.sorted { (zOrder[$0.id] ?? .max) < (zOrder[$1.id] ?? .max) }
    }

    /// Windows of a single process, in MRU order.
    static func windowsMRU(forPID pid: pid_t) -> [WindowRef] {
        currentSpaceWindowsMRU().filter { $0.pid == pid }
    }

    private static func axWindows(pid: pid_t, keeping zOrder: [CGWindowID: Int]) -> [WindowRef] {
        let app = AXUIElementCreateApplication(pid)
        // Bound the damage a hung app can do to the event tap's callback budget.
        AXUIElementSetMessagingTimeout(app, 0.1)

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement]
        else { return [] }

        let running = NSRunningApplication(processIdentifier: pid)
        let appName = running?.localizedName ?? "?"
        let icon = running?.icon

        var refs: [WindowRef] = []
        for window in windows {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &id) == .success, zOrder[id] != nil else { continue }
            guard isRealWindow(window) else { continue }

            refs.append(WindowRef(
                id: id,
                pid: pid,
                appName: appName,
                title: string(window, kAXTitleAttribute) ?? "",
                element: window,
                icon: icon
            ))
        }
        return refs
    }

    private static func isRealWindow(_ window: AXUIElement) -> Bool {
        guard let subrole = string(window, kAXSubroleAttribute) else { return false }
        return subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    /// Bring a window to the front and give it keyboard focus.
    static func focus(_ window: WindowRef) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }

        // Mark it main *before* activating, so the app comes forward on this
        // window instead of flashing whatever its previous main window was.
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        app?.activate()
    }
}
