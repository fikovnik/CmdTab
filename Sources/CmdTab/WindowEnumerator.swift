import AppKit
import ApplicationServices

struct WindowRef {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    var title: String
    let element: AXUIElement
    let icon: NSImage?
    /// "Desktop 2", "Full Screen", … Only populated in all-Spaces mode.
    var spaceLabel: String?
}

enum WindowEnumerator {

    /// Windows visible on the current Space, across all screens, most-recently-used first.
    ///
    /// MRU is derived from the `CGWindowList` front-to-back z-order rather than
    /// from bookkeeping of focus events: macOS raises a window when it is
    /// focused, so z-order *is* MRU, and it cannot go stale or leak.
    static func currentSpaceWindowsMRU() -> [WindowRef] {
        resolve(candidates(onScreenOnly: true))
    }

    /// Every window on every Space, including minimized ones.
    ///
    /// The current Space's windows keep their z-order MRU and stay at the head
    /// of the list, so widening the scope mid-cycle never moves the selection.
    /// Everything else comes from the Accessibility API, grouped by Space.
    ///
    /// AX has to be the source of truth here, not `CGWindowList`. Off-screen
    /// `CGWindowList` entries are mostly compositing surfaces whose IDs match no
    /// AX window at all (a single Chrome window can show up as twenty of them)
    /// and a minimized window's real ID does not appear on screen in any form.
    static func allSpacesWindowsMRU() -> [WindowRef] {
        WindowRegistry.shared.refresh()

        var zOrder: [CGWindowID: Int] = [:]
        for (position, candidate) in candidates(onScreenOnly: true).enumerated() {
            zOrder[candidate.id] = position
        }

        let known = WindowRegistry.shared.all
        let front = known
            .filter { zOrder[$0.id] != nil }
            .sorted { zOrder[$0.id]! < zOrder[$1.id]! }

        // Nothing off-Space has a meaningful z-order, so group by Space and keep
        // each app's windows together.
        let spaces = SpaceMap()
        let rest = known
            .filter { zOrder[$0.id] == nil }
            .sorted { lhs, rhs in
                let left = spaces.rank(forWindow: lhs.id)
                let right = spaces.rank(forWindow: rhs.id)
                if left != right { return left < right }
                if lhs.appName != rhs.appName {
                    return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
                }
                return lhs.id < rhs.id
            }

        var result = front + rest
        for index in result.indices {
            result[index].spaceLabel = spaces.label(forWindow: result[index].id)
        }
        return result
    }

    /// Every window the WindowServer still knows about, in any state. Used to
    /// evict registry entries for windows that have been closed.
    static func liveWindowIDs() -> Set<CGWindowID> {
        guard let infoList = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(infoList.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// Every real window AX is willing to report right now, across all apps.
    static func axWindowsOfAllApps() -> [WindowRef] {
        var pids = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            pids.insert(app.processIdentifier)
        }
        pids.remove(ProcessInfo.processInfo.processIdentifier)

        var result: [WindowRef] = []
        for pid in pids.sorted() {
            result += axWindows(pid: pid, keeping: nil)
        }
        return result
    }

    /// Bring a window to the front and give it keyboard focus, switching Spaces
    /// and un-minimizing as needed.
    static func focus(_ window: WindowRef) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }

        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window.element, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        // Mark it main *before* activating, so the app comes forward on this
        // window instead of flashing whatever its previous main window was.
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        app?.activate()
    }

    // MARK: - CGWindowList

    struct Candidate {
        let id: CGWindowID
        let pid: pid_t
        let order: Int
    }

    static func candidates(onScreenOnly: Bool) -> [Candidate] {
        var options: CGWindowListOption = [.excludeDesktopElements]
        if onScreenOnly { options.insert(.optionOnScreenOnly) }

        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var result: [Candidate] = []

        for (order, info) in infoList.enumerated() {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != selfPID
            else { continue }

            // Drop tiny helper windows (tooltips, popovers, status shims).
            if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
               let width = bounds["Width"], let height = bounds["Height"],
               width < 80 || height < 80 {
                continue
            }

            result.append(Candidate(id: id, pid: pid, order: order))
        }
        return result
    }

    // MARK: - Accessibility

    /// Turn ordered CGWindowIDs into `WindowRef`s, preserving the given order.
    /// Titles come from the Accessibility API rather than `kCGWindowName`, so
    /// the app never needs Screen Recording permission.
    private static func resolve(_ candidates: [Candidate]) -> [WindowRef] {
        var wanted: [pid_t: Set<CGWindowID>] = [:]
        for candidate in candidates {
            wanted[candidate.pid, default: []].insert(candidate.id)
        }

        var byID: [CGWindowID: WindowRef] = [:]
        for (pid, ids) in wanted {
            for window in axWindows(pid: pid, keeping: ids) {
                byID[window.id] = window
            }
        }

        return candidates.compactMap { byID[$0.id] }
    }

    /// `ids == nil` returns every real window of the process, on any Space.
    private static func axWindows(pid: pid_t, keeping ids: Set<CGWindowID>?) -> [WindowRef] {
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
            guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { continue }
            if let ids, !ids.contains(id) { continue }
            guard isRealWindow(window) else { continue }

            refs.append(WindowRef(
                id: id,
                pid: pid,
                appName: appName,
                title: string(window, kAXTitleAttribute) ?? "",
                element: window,
                icon: icon,
                spaceLabel: nil
            ))
        }
        return refs
    }

    /// Diagnostics only: what AX says about one process, with error codes.
    struct AXReport {
        var status = ""
        var count = -1
        var retryStatus = ""
        var retryCount = -1
        var focused = ""
        var enhancedUI = ""
        var roles: [String] = []
    }

    static func axReport(pid: pid_t, timeout: Float) -> AXReport {
        var report = AXReport()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)

        func windows() -> (String, Int, [AXUIElement]) {
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
            let list = raw as? [AXUIElement]
            return ("\(status.rawValue)", list?.count ?? -1, list ?? [])
        }

        (report.status, report.count, _) = windows()

        var focusedRaw: CFTypeRef?
        report.focused = "\(AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRaw).rawValue)"

        // Some toolkits only build an AX tree once a client announces itself.
        var enhancedRaw: CFTypeRef?
        report.enhancedUI = "\(AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &enhancedRaw).rawValue)"
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.3)

        let retry = windows()
        report.retryStatus = retry.0
        report.retryCount = retry.1
        for window in retry.2.prefix(6) {
            report.roles.append(string(window, kAXSubroleAttribute) ?? string(window, kAXRoleAttribute) ?? "<none>")
        }
        return report
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
}
