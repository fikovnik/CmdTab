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
    private var isRefreshing = false
    private var refreshAgain = false
    private var metadataVersion: UInt64 = 0
    private var metadataVersions: [CGWindowID: UInt64] = [:]
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
        Task { await refresh() }
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

    func refresh() async {
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        repeat {
            refreshAgain = false
            let started = ProcessInfo.processInfo.systemUptime
            let layout = Spaces.layout()
            syncWithServer(layout)
            let known = Set(windows.keys)
            let versions = metadataVersions
            let snapshot = await WindowDescriptions.read(pids: Set(Self.regularApps().keys), known: known)
            apply(snapshot, known: known, versions: versions, layout: layout)
            AXEvents.sync(Set(Self.regularApps().keys))
            metadataVersions = metadataVersions.filter { windows[$0.key] != nil }
            Diagnostics.note(String(format: "refresh: %.0f ms (AX worker)",
                                    (ProcessInfo.processInfo.systemUptime - started) * 1000))
        } while refreshAgain
        isRefreshing = false
    }

    /// Combine a group of workspace events into one refresh.
    func scheduleRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // Keep the refresh timer active while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func apply(_ snapshot: WindowDescriptions.Snapshot, known: Set<CGWindowID>,
                       versions: [CGWindowID: UInt64], layout: SpaceLayout) {
        let apps = Self.regularApps()
        var described = Set<CGWindowID>()
        for description in snapshot.descriptions {
            let id = description.id
            guard let app = apps[description.pid], metadataVersions[id] == versions[id] else { continue }
            if windows[id] == nil {
                // Do not restore a known window that a newer server scan removed.
                guard !known.contains(id), description.isMinimized == true else { continue }
                var window = Window(id: id, pid: description.pid, appName: app.localizedName ?? "?", icon: app.icon)
                window.spaces = (description.spaces ?? []).sorted {
                    (layout.order(of: $0) ?? .max) < (layout.order(of: $1) ?? .max)
                }
                window.zOrder = .max
                windows[id] = window
            }
            windows[id]?.element = description.element.element
            if let subrole = description.subrole {
                windows[id]?.isStandard = subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
            }
            if let title = description.title { windows[id]?.title = title }
            if let minimized = description.isMinimized { windows[id]?.isMinimized = minimized }
            described.insert(id)
        }
        // Keep newer title notifications when a worker returns an older snapshot.
        for (id, title) in snapshot.titles where !described.contains(id) && metadataVersions[id] == versions[id] {
            windows[id]?.title = title
        }
    }

    /// Keep the existing AX element if one is available.
    func update(_ id: CGWindowID, element: AXUIElement, title: String?, isMinimized: Bool? = nil) {
        guard windows[id] != nil else { return }
        if windows[id]?.element == nil { windows[id]?.element = element }
        if let title { windows[id]?.title = title }
        if let isMinimized { windows[id]?.isMinimized = isMinimized }
        metadataVersion += 1
        metadataVersions[id] = metadataVersion
    }

    func replaceElement(_ id: CGWindowID, with element: AXUIElement) {
        guard windows[id] != nil else { return }
        windows[id]?.element = element
        metadataVersion += 1
        metadataVersions[id] = metadataVersion
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
