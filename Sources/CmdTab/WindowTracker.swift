import AppKit
import CmdTabModel

struct Window: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    var title = ""
    /// Keep the Spaces for this window in layout order.
    var spaces: [SpaceID] = []
    /// Use the stack position on the first visible Space. If none is visible, use the first Space.
    var zOrder = 0
    /// Keep this value nil until AX returns a window element.
    var element: AXUIElement?
    /// If AX reports a subrole other than a standard window or dialog, set this value to false.
    var isStandard = true
    /// If AX omits the window, keep its last known minimized state.
    var isMinimized = false
    /// Only all-Spaces lists include this label.
    var spaceLabel: String?
}

enum WindowScope {
    /// Include windows on other Spaces so the previous window stays available.
    case allSpaces
    /// Include the visible Space of each display.
    case currentSpace
}

/// The WindowServer supplies IDs and Space membership.
/// AX supplies elements, titles, subroles, and minimized state.
/// If a window leaves the visible Spaces, keep its AX data.
@MainActor
final class WindowTracker {
    static let shared = WindowTracker()

    private(set) var windows: [CGWindowID: Window] = [:]
    private(set) var recent = RecentWindows()
    private var refreshTimer: Timer?
    private var settleTimer: Timer?
    /// Keep the ID of the window captured before a switch.
    /// Avoid another capture after the window becomes covered.
    private var capturedBeforeSwitch: CGWindowID?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] notification in
            // Read the process ID before the actor isolation scope. `Notification` does not conform to `Sendable`.
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pid { self.readFocus(of: pid) }
                self.scheduleRefresh()
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        refresh()
    }

    // MARK: - Windows

    /// Update IDs and Space membership without an AX scan.
    func syncWithServer(_ layout: SpaceLayout) {
        guard !layout.displays.isEmpty else {
            Diagnostics.error("Space layout unavailable; kept existing window records")
            return
        }
        let apps = Self.regularApps()
        let visible = layout.visibleSpaces
        let minimized = Set(windows.values.filter(\.isMinimized).map(\.id))
        var found: [CGWindowID: Window] = [:]

        for space in layout.displays.flatMap(\.spaces) {
            for (position, server) in WindowServer.windows(onSpace: space.id, includingMinimized: minimized).enumerated() {
                if var window = found[server.id] {
                    if visible.contains(space.id), !window.spaces.contains(where: visible.contains) {
                        window.zOrder = position
                    }
                    window.spaces.append(space.id)
                    found[server.id] = window
                    continue
                }
                guard let app = apps[server.pid] else { continue }
                var window = windows[server.id]
                    ?? Window(id: server.id, pid: server.pid,
                              appName: app.localizedName ?? "?", icon: app.icon)
                window.spaces = [space.id]
                window.zOrder = position
                found[server.id] = window
            }
        }
        // Keep known windows of hidden apps. The server query omits them.
        for (id, window) in windows where found[id] == nil && apps[window.pid]?.isHidden == true {
            found[id] = window
        }
        windows = found
        let live = Set(found.keys)
        recent.retain(live)
        WindowPreview.shared.retain(live)
    }

    func refresh() {
        let started = Date()
        let layout = Spaces.layout()
        syncWithServer(layout)

        let apps = Self.regularApps()
        var described = Set<CGWindowID>()
        // An app can have only minimized windows, none of which passed the server filter.
        for app in apps.values {
            described.formUnion(learn(app, in: layout))
        }
        // Use server titles when AX cannot describe a window. Screen Recording is necessary.
        for (id, title) in WindowServer.titles() where !described.contains(id) {
            windows[id]?.title = title
        }

        AXEvents.sync(Set(apps.keys))
        // AX scans share the main thread with the event tap.
        Diagnostics.note(String(format: "refresh: %.0f ms", Date().timeIntervalSince(started) * 1000))
    }

    /// Combine a group of workspace events into one refresh.
    func scheduleRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Keep the refresh timer active while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Read AX window descriptions. Focused and main window attributes can include windows on other Spaces.
    private func learn(_ app: NSRunningApplication, in layout: SpaceLayout) -> Set<CGWindowID> {
        let pid = app.processIdentifier
        let values = AXUIElement.application(pid)
            .values([kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute])
        let list = values[0] as? [AXUIElement] ?? []
        let single = values.dropFirst().compactMap { value in
            value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        if values.allSatisfy({ $0 == nil }) { Diagnostics.note("AX windows unavailable pid=\(pid)") }

        var described = Set<CGWindowID>()
        for element in list + single {
            guard let id = element.windowID, !described.contains(id) else { continue }
            let attributes = element.values([kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute])
            if windows[id] == nil {
                guard attributes[2] as? Bool == true else { continue }
                var window = Window(id: id, pid: pid, appName: app.localizedName ?? "?", icon: app.icon)
                window.spaces = WindowServer.spaces(ofWindow: id).sorted {
                    (layout.order(of: $0) ?? .max) < (layout.order(of: $1) ?? .max)
                }
                window.zOrder = .max
                windows[id] = window
            }
            let subrole = attributes[0] as? String
            windows[id]?.element = element
            if let subrole {
                windows[id]?.isStandard = subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
            }
            if let title = attributes[1] as? String { windows[id]?.title = title }
            if let minimized = attributes[2] as? Bool { windows[id]?.isMinimized = minimized }
            described.insert(id)
        }
        return described
    }

    /// Keep the existing AX element if one is available.
    func update(_ id: CGWindowID, element: AXUIElement, title: String?, isMinimized: Bool? = nil) {
        guard windows[id] != nil else { return }
        if windows[id]?.element == nil { windows[id]?.element = element }
        if let title { windows[id]?.title = title }
        if let isMinimized { windows[id]?.isMinimized = isMinimized }
    }

    // MARK: - Switcher list

    /// Keep focus order within the normal and minimized groups. Put minimized windows last.
    /// Order unseen windows by visibility, Space, and stack position.
    func list(_ scope: WindowScope, in layout: SpaceLayout) -> [Window] {
        let visible = layout.visibleSpaces
        func isVisible(_ window: Window) -> Bool { window.spaces.contains(where: visible.contains) }

        let candidates = windows.values.filter { window in
            window.isStandard && (scope == .allSpaces || isVisible(window))
        }
        let fallback = candidates.sorted { a, b in
            let keyA = (isVisible(a) ? 0 : 1, a.spaces.first.flatMap(layout.order(of:)) ?? .max, a.zOrder, a.id)
            let keyB = (isVisible(b) ? 0 : 1, b.spaces.first.flatMap(layout.order(of:)) ?? .max, b.zOrder, b.id)
            return keyA < keyB
        }
        let minimized = Set(candidates.filter(\.isMinimized).map(\.id))
        return recent.sorted(fallback.map(\.id), minimized: minimized).compactMap { id in
            guard var window = windows[id] else { return nil }
            if scope == .allSpaces {
                window.spaceLabel = window.spaces.count > 1
                    ? "All Desktops"
                    : window.spaces.first.flatMap(layout.label(of:))
            }
            return window
        }
    }

    // MARK: - Focus order

    /// Put the actual focused window first and capture it before a switch.
    func promoteFrontWindow() {
        recent.settleAll()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let id = AXUIElement.application(pid).element(kAXFocusedWindowAttribute)?.windowID
        else { return }
        recent.promote(id)
        WindowPreview.shared.capture(id)
        capturedBeforeSwitch = id
    }

    /// Read focus only if `pid` identifies the frontmost app.
    func readFocus(of pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let id = AXUIElement.application(pid).element(kAXFocusedWindowAttribute)?.windowID
        else { return }
        focusReported(id, pid: pid)
    }

    func focusReported(_ id: CGWindowID, pid: pid_t) {
        // Capture the previous window before its app releases the image surface.
        if let leaving = recent.order.first, leaving != id, leaving != capturedBeforeSwitch,
           let window = windows[leaving],
           window.spaces.contains(where: Spaces.layout().visibleSpaces.contains) {
            WindowPreview.shared.capture(leaving)
        }
        recent.report(id, pid: pid, at: ProcessInfo.processInfo.systemUptime)
        scheduleSettle()
    }

    private func scheduleSettle() {
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: RecentWindows.settleTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recent.settle(at: ProcessInfo.processInfo.systemUptime)
                if self.recent.order.first != self.capturedBeforeSwitch { self.capturedBeforeSwitch = nil }
                if self.recent.hasPendingAnswers { self.scheduleSettle() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// Exclude accessory apps and CmdTab.
    static func regularApps() -> [pid_t: NSRunningApplication] {
        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = app
        }
        apps[ProcessInfo.processInfo.processIdentifier] = nil
        return apps
    }
}
