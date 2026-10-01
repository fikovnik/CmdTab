import AppKit
import CmdTabModel

/// One window that the switcher can show.
struct Window {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    var title = ""
    /// The Spaces that show the window, in layout order. A window that is
    /// assigned to all desktops is on each of them.
    var spaces: [SpaceID] = []
    /// The position from the front: on a visible Space if possible, else on
    /// its first Space.
    var zOrder = 0
    /// Nil until AX returns the window.
    var element: AXUIElement?
    /// False if AX gives a subrole other than a standard window or a dialog.
    var isStandard = true
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

/// All windows, and the order of their last focus.
///
/// The WindowServer gives each window and its Spaces. AX gives the element,
/// the title and the subrole, but `kAXWindows` contains only the windows on
/// visible Spaces. A window keeps its element and title when it leaves a
/// visible Space.
@MainActor
final class WindowTracker {
    static let shared = WindowTracker()

    private(set) var windows: [CGWindowID: Window] = [:]
    private(set) var recent = RecentWindows()
    private var refreshTimer: Timer?
    private var settleTimer: Timer?
    /// The window that `promoteFrontWindow` captured before a switch. That
    /// frame is better than a capture after the switch, when the window can be
    /// covered. Cleared when the focus order moves to a different window.
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

    /// Updates the windows and their Spaces. Only the WindowServer is asked,
    /// not AX: a few milliseconds.
    func syncWithServer(_ layout: SpaceLayout) {
        let apps = Self.regularApps()
        let visible = layout.visibleSpaces
        var found: [CGWindowID: Window] = [:]

        for space in layout.displays.flatMap(\.spaces) {
            for (position, server) in WindowServer.windows(onSpace: space.id).enumerated() {
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
        // The query does not give the windows of a hidden app. Keep them, so
        // that the switcher lists them. `Focus` shows the app again.
        for (id, window) in windows where found[id] == nil && apps[window.pid]?.isHidden == true {
            found[id] = window
        }
        windows = found
        recent.retain(Set(found.keys))
    }

    /// Updates the windows, then asks AX for the elements, titles and subroles.
    /// This asks every app with windows, so it runs after notifications, not
    /// on a key press.
    func refresh() {
        let started = Date()
        syncWithServer(Spaces.layout())

        var described = Set<CGWindowID>()
        for pid in Set(windows.values.map(\.pid)) {
            described.formUnion(learn(pid))
        }
        // The AX title of a window on another Space is from the last visit.
        // `CGWindowList` has the current title, with Screen Recording permission.
        for (id, title) in WindowServer.titles() where !described.contains(id) {
            windows[id]?.title = title
        }

        AXEvents.sync(Set(Self.regularApps().keys))
        // This runs on the main thread, which also handles the event tap.
        Diagnostics.note(String(format: "refresh: %.0f ms", Date().timeIntervalSince(started) * 1000))
    }

    /// Coalesces the refreshes that a burst of notifications asks for.
    func scheduleRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // `.common`, so that the timer also fires while the event tap is busy.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Reads the AX windows of one app and returns the IDs that AX described.
    ///
    /// `kAXWindows` contains the windows on visible Spaces and the minimized
    /// windows. `kAXFocusedWindow` and `kAXMainWindow` do not depend on the
    /// Space. Thus, they also give the key and main windows on other Spaces.
    private func learn(_ pid: pid_t) -> Set<CGWindowID> {
        let values = AXUIElement.application(pid)
            .values([kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute])
        guard let list = values[0] as? [AXUIElement] else {
            // The status is `.cannotComplete` when the app does not answer in time.
            Diagnostics.note("ax windows failed pid=\(pid)")
            return []
        }
        let single = values.dropFirst().compactMap { value in
            value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }

        var described = Set<CGWindowID>()
        for element in list + single {
            guard let id = element.windowID, windows[id] != nil, !described.contains(id) else { continue }
            let attributes = element.values([kAXSubroleAttribute, kAXTitleAttribute])
            let subrole = attributes[0] as? String
            windows[id]?.element = element
            windows[id]?.isStandard = subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
            if let title = attributes[1] as? String { windows[id]?.title = title }
            described.insert(id)
        }
        return described
    }

    /// Keeps the element and the title from an AX notification. AX sends
    /// notifications also for windows on Spaces that are not visible.
    func update(_ id: CGWindowID, element: AXUIElement, title: String?) {
        guard windows[id] != nil else { return }
        if windows[id]?.element == nil { windows[id]?.element = element }
        if let title { windows[id]?.title = title }
    }

    // MARK: - Switcher list

    /// The windows in switcher order. First the windows that had focus, most
    /// recent first. Then the windows on visible Spaces, front to back. Then
    /// the other windows, by Space.
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
        return recent.sorted(fallback.map(\.id)).compactMap { id in
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

    /// Promotes the focused window of the front app immediately, and
    /// captures it for the preview. This is the window that the user leaves
    /// when a switcher cycle starts.
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
        guard let id = AXUIElement.application(pid).element(kAXFocusedWindowAttribute)?.windowID
        else { return }
        focusReported(id, pid: pid)
    }

    /// App `pid` reports `id` as its focused window.
    func focusReported(_ id: CGWindowID, pid: pid_t) {
        // The window that had focus is still drawn now. Later, its app can
        // release the drawing surface.
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
