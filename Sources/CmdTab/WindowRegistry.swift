import AppKit

/// Everything we have ever seen, because you cannot ask for it all at once.
///
/// `kAXWindowsAttribute` only reports an app's windows on the *current* Space,
/// plus its minimized ones. Windows sitting on another Space are invisible to
/// it, verified on a live session: Slack's 2560x1410 window on Desktop 1 is
/// plainly there in `CGWindowList`, and AX reports zero windows for Slack.
///
/// So the widened switcher list cannot be enumerated on demand. Instead we
/// learn windows whenever macOS is willing to show them: every Space change,
/// app activation, and launch, and hold onto the `AXUIElement` afterwards.
/// Entries are dropped once the WindowServer stops listing the window at all.
///
/// The registry also keeps the use stamps that order the list, and the Space
/// map that labels it, so all per-window state lives in one place.
///
/// Consequence worth knowing: a Space this app has never seen contributes
/// nothing until you visit it once.
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

    /// One row per app that has windows on a Space no AX walk has described.
    ///
    /// Without these the all-Spaces default cannot bootstrap itself: a Space is
    /// invisible to `kAXWindowsAttribute` until you are standing on it, so a
    /// freshly launched CmdTab would list only the current Space, and you could
    /// not use the switcher to get anywhere else. The WindowServer *will* say
    /// which apps own windows on which Space, just not what those windows are,
    /// so offer the app. Committing to one activates it, which lands on that
    /// Space and lets the following refresh learn its windows properly.
    ///
    /// Keyed on app-and-Space rather than per window because the WindowServer
    /// counts utility panels as windows: Lightroom reports twelve where AX
    /// reports one. One honest row beats eleven phantoms.
    func placeholders(besides known: [WindowRef], owners: [CGWindowID: pid_t]) -> [WindowRef] {
        struct AppSpace: Hashable {
            let pid: pid_t
            let space: CGSSpaceID
        }

        var described = Set<AppSpace>()
        for window in known {
            guard let space = spaces.space(forWindow: window.id) else { continue }
            described.insert(AppSpace(pid: window.pid, space: space))
        }

        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = app
        }
        apps[ProcessInfo.processInfo.processIdentifier] = nil

        var result: [WindowRef] = []
        var added = Set<AppSpace>()
        for (space, ids) in spaces.windowsPerSpace() {
            // CGS lists a Space front to back, so the first id an app owns here
            // is the window activating it will land on.
            for id in ids {
                guard let pid = owners[id], let app = apps[pid] else { continue }
                let key = AppSpace(pid: pid, space: space)
                guard !described.contains(key), added.insert(key).inserted else { continue }
                result.append(WindowRef(id: id,
                                        pid: pid,
                                        appName: app.localizedName ?? "?",
                                        title: "",
                                        element: nil,
                                        icon: app.icon,
                                        spaceLabel: spaces.label(forSpace: space)))
            }
        }
        return result
    }

    /// Forget dead windows, then learn whatever AX is willing to show right now.
    /// Walks every app, so it stays on the notification path, never on a keypress.
    func refresh() {
        evictClosed(live: Set(WindowEnumerator.liveWindowOwners().keys))
        for window in WindowEnumerator.axWindowsOfAllApps() {
            known[window.id] = window
        }
    }

    /// Activating a window fires an activation notification, and a refresh walks
    /// every app over the Accessibility API. Doing that inline would block the
    /// main thread (and so the event tap) right when someone is switching
    /// windows in a hurry. Coalesce instead.
    private func scheduleRefresh() {
        pendingRefresh?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingRefresh = timer
    }
}
