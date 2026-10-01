import AppKit
import ApplicationServices

struct WindowRef: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    var title: String
    /// `nil` for a window that AX has not returned yet, for example a window
    /// on a Space that the user has not visited.
    let element: AXUIElement?
    let icon: NSImage?
    /// "Desktop 2", "Full Screen", … Only populated in all-Spaces mode.
    var spaceLabel: String?
}

/// Which windows the switcher lists.
enum WindowScope {
    /// Every window on every Space, newest-used first. The default: "go back to
    /// the window I came from" has to keep working across a Space boundary.
    case allSpaces
    /// Only what is on the Space in front of you, across all screens.
    case currentSpace
}

@MainActor
enum WindowEnumerator {

    /// The switcher list for `scope`, most-recently-used first.
    ///
    /// Both scopes start from a live `CGWindowList` scan of the current Space.
    /// That scan is the only source that sees windows created since the last
    /// registry refresh, and within one Space its front-to-back z-order *is*
    /// MRU, because macOS raises a window when it is focused.
    ///
    /// Across Spaces there is no z-order to read (two windows on different
    /// Spaces are never on screen together), so ordering falls to the use
    /// stamps the registry keeps. See `Rank` below.
    ///
    /// Off-Space windows come from `WindowServer`, the only source that sees
    /// them. AX wins where it has an answer (its entries carry a live title
    /// and a usable `AXUIElement`), so the merge asks the WindowServer only for
    /// the ids AX left out.
    static func windows(_ scope: WindowScope) -> [WindowRef] {
        let candidates = candidates(onScreenOnly: true)
        let onSpace = resolve(candidates)

        let registry = WindowRegistry.shared
        registry.learn(onSpace)

        guard scope == .allSpaces else { return onSpace }

        // Cheap enough for a keypress: CGWindowList plus one WindowServer
        // query per Space, no AX traffic. The full AX walk stays on the
        // notification path, so a title can lag by one refresh. The window
        // itself cannot, since the WindowServer sees it immediately.
        registry.evictClosed(live: Set(liveWindowOwners().keys))

        var zOrder: [CGWindowID: Int] = [:]
        for (position, candidate) in candidates.enumerated() {
            zOrder[candidate.id] = position
        }

        // One CGWindowList scan, shared: it names the windows only the
        // WindowServer can see, and re-titles the remembered ones below.
        let titles = WindowServer.titles()
        let known = registry.all
        var result = (known + registry.serverWindows(besides: Set(known.map(\.id)), titles: titles))
            .map { (rank: rank(of: $0, zOrder: zOrder, registry: registry), window: $0) }
            .sorted { $0.rank < $1.rank }
            .map(\.window)

        let described = Set(onSpace.map(\.id))
        for index in result.indices {
            let id = result[index].id
            result[index].spaceLabel = registry.spaceLabel(forWindow: id)
            // A remembered window keeps the title AX gave it when it was last
            // on the active Space, for a browser whichever tab was open
            // then. CGWindowList sees every Space, so it holds the fresher
            // answer for the rows AX could not re-read. Empty without Screen
            // Recording, which leaves the remembered title in place.
            if !described.contains(id), let title = titles[id], !title.isEmpty {
                result[index].title = title
            }
        }
        return result
    }

    /// Sort key for the merged list.
    ///
    /// Windows that have been seen in use come first, newest first. Everything
    /// else keeps the ordering this app shipped with (current-Space z-order,
    /// then Space left to right, then app), which is exactly what a freshly
    /// launched CmdTab shows before any stamp exists. So the list starts out
    /// looking like it always did and converges on true MRU as you use it.
    private struct Rank: Comparable {
        /// 0 = seen in use, 1 = never seen. Not a Bool: Bool is not Comparable.
        let tier: Int
        /// Inverted stamp, so the newest use sorts first.
        let recency: UInt64
        let zOrder: Int
        let spaceRank: Int
        let appName: String
        let id: CGWindowID

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.tier, lhs.recency, lhs.zOrder, lhs.spaceRank, lhs.appName, lhs.id)
                < (rhs.tier, rhs.recency, rhs.zOrder, rhs.spaceRank, rhs.appName, rhs.id)
        }
    }

    private static func rank(of window: WindowRef,
                             zOrder: [CGWindowID: Int],
                             registry: WindowRegistry) -> Rank {
        let stamp = registry.stamp(of: window.id)
        return Rank(tier: stamp == nil ? 1 : 0,
                    recency: stamp.map { UInt64.max - $0 } ?? 0,
                    zOrder: zOrder[window.id] ?? .max,
                    spaceRank: registry.spaceRank(forWindow: window.id),
                    appName: window.appName.lowercased(),
                    id: window.id)
    }

    /// Every window the WindowServer still knows about, in any state, with its
    /// owning process. The registry's eviction list: an id missing here is a
    /// window that is gone. One call, no AX traffic.
    static func liveWindowOwners() -> [CGWindowID: pid_t] {
        guard let infoList = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [CGWindowID: pid_t] = [:]
        for info in infoList {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            result[id] = pid
        }
        return result
    }

    /// Every real window AX is willing to report right now, across all apps.
    ///
    /// Bounded by the same `CGWindowList` filter the switcher's own candidate
    /// scan uses, because `axWindows` trusts AX's subrole and AX calls an 84x77
    /// layer-3 drag image an `AXDialog`. Unbounded, those entered the registry,
    /// and the all-Spaces list is built from everything the registry knows, so
    /// they became rows. The list here covers every state and every Space, so
    /// bounding by it costs no off-Space or minimized window.
    static func axWindowsOfAllApps() -> [WindowRef] {
        var pids = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            pids.insert(app.processIdentifier)
        }
        pids.remove(ProcessInfo.processInfo.processIdentifier)

        var real: [pid_t: Set<CGWindowID>] = [:]
        for candidate in candidates(onScreenOnly: false) {
            real[candidate.pid, default: []].insert(candidate.id)
        }

        var result: [WindowRef] = []
        for pid in pids.sorted() {
            result += axWindows(pid: pid, keeping: real[pid] ?? [])
        }
        return result
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

        // An app that misses the 100 ms messaging timeout answers with
        // nothing, which would drop every one of its windows from the list at
        // once, and with twenty windows open Chrome is the likeliest to miss
        // it. These are on screen right now, so fall back to what the registry
        // remembers: a stale title beats a missing row. A window it has never
        // described is still dropped, which is what filters out the panels and
        // popups `isRealWindow` rejects.
        let registry = WindowRegistry.shared
        return candidates.compactMap { byID[$0.id] ?? registry.remembered($0.id) }
    }

    /// `ids == nil` returns every real window of the process, on any Space.
    private static func axWindows(pid: pid_t, keeping ids: Set<CGWindowID>?) -> [WindowRef] {
        let app = AXUIElementCreateApplication(pid)
        // Bound the damage a hung app can do to the event tap's callback budget.
        AXUIElementSetMessagingTimeout(app, 0.1)

        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard status == .success, let windows = raw as? [AXUIElement] else {
            // -25204 is kAXErrorCannotComplete, what the timeout above reports.
            Diagnostics.note("ax windows failed pid=\(pid) status=\(status.rawValue)")
            return []
        }

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

    /// The CGWindowID of a process's focused window, or nil if AX will not say.
    /// Used to stamp switches made outside CmdTab.
    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)

        // AX hands back an untyped CFTypeRef, and a misbehaving app can put
        // anything in an attribute, so check before trusting it.
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = value as! AXUIElement

        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
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
