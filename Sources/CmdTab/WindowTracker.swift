import AppKit
import CmdTabModel

/// One window that the switcher can show.
struct Window: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    var title = ""
    /// The Spaces for this window, in layout order.
    var spaces: [SpaceID] = []
    /// The stack position on a visible Space, or on the first Space.
    var zOrder = 0
    /// Nil until AX returns the window.
    var element: AXUIElement?
    /// False if AX gives a subrole other than a standard window or a dialog.
    var isStandard = true
    /// Keep the last known AX state when a window leaves a visible Space.
    var isMinimized = false
    /// "Desktop 2", "All Desktops". Only `list` in the all-Spaces scope sets it.
    var spaceLabel: String?
}

/// Which windows the switcher lists.
enum WindowScope {
    /// All windows on all Spaces. "Go back to the previous window" must also
    /// work across Spaces.
    case allSpaces
    /// The windows on the visible Spaces of all displays.
    case currentSpace
}

/// The window records and observed focus order. The WindowServer supplies IDs and Space membership.
/// AX supplies elements, titles, subroles, and minimized state. Keep AX data when a window leaves a visible Space.
@MainActor
final class WindowTracker {
    static let shared = WindowTracker()

    private(set) var windows: [CGWindowID: Window] = [:]
    private(set) var recent = RecentWindows()
    private var refreshTimer: Timer?
    private var settleTimer: Timer?
    /// The ID captured before a switch. Avoid another capture after the window becomes covered.
    private var capturedBeforeSwitch: CGWindowID?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] notification in
            // `Notification` is not `Sendable`. Read the pid before the main actor hop.
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

    /// Update server records and AX descriptions after workspace events.
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
        // This runs on the main thread, which also handles the event tap.
        Diagnostics.note(String(format: "refresh: %.0f ms", Date().timeIntervalSince(started) * 1000))
    }

    /// Use one refresh for a group of workspace events.
    func scheduleRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // `.common`, so that the timer also fires while the event tap is busy.
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

    /// Keep the element, title, and minimized state from a window notification.
    func update(_ id: CGWindowID, element: AXUIElement, title: String?, isMinimized: Bool? = nil) {
        guard windows[id] != nil else { return }
        if windows[id]?.element == nil { windows[id]?.element = element }
        if let title { windows[id]?.title = title }
        if let isMinimized { windows[id]?.isMinimized = isMinimized }
    }

    // MARK: - Switcher list

    /// List windows in observed focus order, with minimized windows last.
    /// Append unseen windows in each group by visibility, Space order, and stack position.
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

    /// Reads the focused window of app `pid` as a focus answer.
    func readFocus(of pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let id = AXUIElement.application(pid).element(kAXFocusedWindowAttribute)?.windowID
        else { return }
        focusReported(id, pid: pid)
    }

    /// App `pid` reports `id` as its focused window.
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

    /// The running apps that can have windows in the switcher, without CmdTab.
    static func regularApps() -> [pid_t: NSRunningApplication] {
        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = app
        }
        apps[ProcessInfo.processInfo.processIdentifier] = nil
        return apps
    }
}
