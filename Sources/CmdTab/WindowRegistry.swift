import AppKit

/// Every window AX has ever described, plus the state that orders them.
///
/// `kAXWindowsAttribute` only reports an app's windows on the current Space,
/// plus its minimized ones. Off-Space windows come from `WindowServer` instead.
/// What this cache adds is the `AXUIElement` and the live title, learned
/// whenever macOS hands them over: every Space change, app activation, and
/// launch. Entries are dropped once the WindowServer stops listing the window.
///
/// Also holds the use stamps that order the list and the Space map that labels
/// it, so all per-window state lives in one place.
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()

    private var known: [CGWindowID: WindowRef] = [:]
    private var pendingRefresh: Timer?

    /// Monotonic counter behind the use stamps. This is the whole cross-Space
    /// MRU mechanism: z-order can only rank windows that are on screen
    /// together, and windows on different Spaces never are. Mutter makes the
    /// same trade: `meta_display_get_tab_list(.., NULL)` sorts every window by
    /// `meta_window_get_user_time()` rather than by stacking order.
    ///
    /// Held apart from `WindowRef` deliberately: `refresh()` replaces those
    /// values wholesale, which would throw a stamp stored inside them away.
    private var clock: UInt64 = 0
    private var stamps: [CGWindowID: UInt64] = [:]

    private var spaces = SpaceMap()

    func start() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Labels and left-to-right ranks can both have changed.
                self.spaces = SpaceMap()
                // Whatever is in front on the Space just entered is in use now.
                self.promoteFrontWindow()
                self.scheduleRefresh()
            }
        }

        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] notification in
            // Read the pid out here: Notification is not Sendable, so it must
            // not be the thing that crosses onto the main actor.
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pid { self.promoteFocusedWindow(of: pid) }
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

    // MARK: - Use stamps

    /// Mark a window as the most recently used one.
    func promote(_ id: CGWindowID) {
        clock += 1
        stamps[id] = clock
    }

    func stamp(of id: CGWindowID) -> UInt64? { stamps[id] }

    /// Promote whatever is frontmost on the Space in front of you.
    ///
    /// Called as a switcher cycle opens, which is what makes "go back" work
    /// across Spaces: the window being left is stamped at the moment the key is
    /// pressed, so the next cycle finds it one below the top wherever it lives.
    /// Idempotent, because the front window already holds the newest stamp.
    func promoteFrontWindow() {
        guard let front = WindowEnumerator.candidates(onScreenOnly: true).first else { return }
        // Stamped even if not yet known: eviction is keyed on the WindowServer's
        // list, so the stamp survives until the entry is learned.
        promote(front.id)
    }

    /// Promote the window AX says is focused in `pid`. Catches switches made
    /// outside CmdTab: Dock clicks, Mission Control, the system switcher.
    private func promoteFocusedWindow(of pid: pid_t) {
        guard let id = WindowEnumerator.focusedWindowID(pid: pid) else { return }
        promote(id)
    }

    // MARK: - Spaces

    func spaceLabel(forWindow id: CGWindowID) -> String? { spaces.label(forWindow: id) }

    func spaceRank(forWindow id: CGWindowID) -> Int { spaces.rank(forWindow: id) }

    // MARK: - Contents

    var all: [WindowRef] { Array(known.values) }

    /// What the registry last learned about one window, if anything. The
    /// fallback for an app that misses its messaging timeout.
    func remembered(_ id: CGWindowID) -> WindowRef? { known[id] }

    /// Fold a freshly scanned list in. The scan's titles and icons are newer
    /// than anything held here, so they win.
    func learn(_ windows: [WindowRef]) {
        for window in windows { known[window.id] = window }
    }


    /// Forget windows the WindowServer no longer lists.
    func evictClosed(live: Set<CGWindowID>) {
        known = known.filter { live.contains($0.key) }
        stamps = stamps.filter { live.contains($0.key) }
    }

    /// One row per real window the WindowServer reports, minus the ids AX has
    /// already described, i.e. the off-Space windows.
    ///
    /// They carry no `AXUIElement`, so `WindowEnumerator.focus` routes them
    /// through the WindowServer. Titles come from `CGWindowList`, which needs
    /// Screen Recording. Without it a row is app name plus Space label until
    /// the first visit to that Space.
    func serverWindows(besides described: Set<CGWindowID>,
                       titles: [CGWindowID: String]) -> [WindowRef] {
        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = app
        }
        apps[ProcessInfo.processInfo.processIdentifier] = nil

        var result: [WindowRef] = []
        for space in spaces.orderedSpaces {
            for window in WindowServer.windows(onSpace: space, titles: titles) {
                // Noted whether described or not: this scan is the cheapest
                // and freshest answer to which Space a window is on.
                spaces.note(window: window.id, onSpace: space)
                guard !described.contains(window.id), let app = apps[window.pid] else { continue }
                result.append(WindowRef(id: window.id,
                                        pid: window.pid,
                                        appName: app.localizedName ?? "?",
                                        title: window.title ?? "",
                                        element: nil,
                                        icon: app.icon,
                                        spaceLabel: spaces.label(forSpace: space)))
            }
        }
        return result
    }

    /// Forget dead windows, then learn whatever AX is willing to show right now.
    /// Walks every app, so it stays on the notification path, never on a keypress.
    ///
    /// Also the only useful moment to fill the preview cache: the windows on
    /// the active Space now are the ones that become un-capturable once we
    /// leave it.
    func refresh() {
        evictClosed(live: Set(WindowEnumerator.liveWindowOwners().keys))
        for window in WindowEnumerator.axWindowsOfAllApps() {
            known[window.id] = window
        }
        AXWatcher.sync()
        WindowPreview.shared.warm()
    }

    /// Activating a window fires an activation notification, and a refresh walks
    /// every app over the Accessibility API. Doing that inline would block the
    /// main thread (and so the event tap) right when someone is switching
    /// windows in a hurry. Coalesce instead.
    func scheduleRefresh() {
        pendingRefresh?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingRefresh = timer
    }
}
