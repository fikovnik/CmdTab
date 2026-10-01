import AppKit
import CmdTabConfig

/// The time that the user must hold the trigger before the list shows. A
/// quick Cmd+Tab takes 120-200 ms. A shorter delay shows the list for a
/// moment on each quick switch.
private let revealDelay: TimeInterval = 0.25

/// The time that the selection must stay on one row before the first preview
/// shows. Thus, the user can step fast past many rows without a preview for
/// each row. After the first preview, the preview follows the selection
/// immediately.
private let previewDelay: TimeInterval = 0.2

@MainActor
final class Switcher {
    /// All state of one cycle. Thus, one assignment ends a cycle and clears
    /// all fields.
    private struct Session {
        let mode: SwitchMode
        /// Only in `.currentApp` mode: the list shows only the windows of this
        /// process.
        let appFilter: pid_t?
        /// The sum of all steps, with no limit. `index` gets the row from it.
        /// Thus, steps can come before the window scan is complete.
        var offset: Int
        var scope = WindowScope.allSpaces
        /// `nil` until the scan is complete. An empty list means that the scan
        /// found no window to switch to.
        var windows: [Window]?
        /// True after the user holds the trigger for `revealDelay`. The list
        /// shows when this is true and `windows` is set, in either order.
        var wantsHUD = false

        var scopeLabel: String { scope == .allSpaces ? "All Spaces" : "This Space" }

        var index: Int {
            guard let windows, !windows.isEmpty else { return 0 }
            return ((offset % windows.count) + windows.count) % windows.count
        }
    }

    private let hud = HUDPanel()
    private let preview = WindowPreview.shared
    private var session: Session?
    private var revealTimer: Timer?
    private var previewTimer: Timer?
    /// A committed session that waits for its switch outside the event tap
    /// callback. The cycle ends immediately, so that the tap does not discard
    /// keys while the switch waits.
    private var pendingSwitch: Session?

    var isCycling: Bool { session != nil }
    var mode: SwitchMode? { session?.mode }

    /// The number of rows that the panel can show, so that PgUp and PgDn move
    /// by one page. It uses the screen and the list, not the HUD. Thus, it is
    /// also correct while the HUD is hidden.
    var pageSize: Int { max(1, min(session?.windows?.count ?? 1, hud.rowCapacity)) }

    func start(_ mode: SwitchMode, reversed: Bool) {
        guard session == nil else { return }
        session = Session(
            mode: mode,
            appFilter: mode == .currentApp ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil,
            offset: reversed ? -1 : 1
        )
        Diagnostics.note("start \(mode) reversed=\(reversed)")

        // `.common`, so that the timer also fires while the event tap is busy.
        let timer = Timer(timeInterval: revealDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reveal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer

        // A window scan can take tens of milliseconds. Do it after the event
        // tap callback returns. If the callback is too slow, the system
        // disables the tap.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// `delta` is +1 for forward and -1 for back. If `wrap` is false, as for a
    /// page move, the selection stops at the first or the last row.
    func step(_ delta: Int, wrap: Bool = true) {
        guard var session else { return }
        if !wrap, let windows = session.windows, !windows.isEmpty {
            session.offset = max(0, min(session.index + delta, windows.count - 1))
        } else {
            session.offset += delta
        }
        self.session = session
        if session.wantsHUD {
            hud.update(selected: session.index)
            armPreview()
        }
    }

    /// Changes the list between all Spaces and the visible Spaces. `reload`
    /// keeps the same window selected.
    func toggleScope() {
        guard var session else { return }
        session.scope = session.scope == .allSpaces ? .currentSpace : .allSpaces
        self.session = session
        // Do the scan after the callback, as in `start`.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Switches to the selected window and ends the cycle.
    ///
    /// The event tap callback calls this function. Thus, the switch occurs
    /// later. An AX scan or a focus in the callback can make the system disable
    /// the tap. A disabled tap does not get the events that the switcher needs.
    func commit() {
        guard let session else { return }
        pendingSwitch = session
        end()

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.performSwitch() }
        }
    }

    func cancel() {
        end()
    }

    private func performSwitch() {
        guard var session = pendingSwitch else { return }
        pendingSwitch = nil

        // After a fast Cmd+Tab, `windows` can still be `nil`. Do the scan now,
        // so that the switch occurs.
        if session.windows == nil { session.windows = Switcher.scan(session) }

        guard let windows = session.windows, !windows.isEmpty else {
            Diagnostics.note("commit: nothing to switch to")
            return
        }
        Diagnostics.note("commit index=\(session.index) of \(windows.count)")
        Focus.focus(windows[session.index])
    }

    private func reveal() {
        guard var session else { return }
        session.wantsHUD = true
        self.session = session
        // If the panel does not show, this tells if the scan is complete.
        // "nil" means that it is not complete.
        Diagnostics.note("reveal timer: windows=\(session.windows?.count.description ?? "nil")")
        showHUD()
    }

    private func showHUD() {
        guard let session, session.wantsHUD,
              let windows = session.windows, !windows.isEmpty
        else { return }
        Diagnostics.note("reveal \(windows.count) windows")
        hud.show(windows, selected: session.index, scope: session.scopeLabel)
        armPreview()
    }

    /// Shows the preview of the selected row. If no preview shows yet, starts
    /// `previewTimer` first.
    private func armPreview() {
        previewTimer?.invalidate()
        previewTimer = nil

        if preview.isShowing {
            showPreview()
            return
        }

        guard let session, session.wantsHUD,
              let windows = session.windows, !windows.isEmpty
        else { return }

        // `.common`, for the same reason as the reveal timer.
        let timer = Timer(timeInterval: previewDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPreview() }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func showPreview() {
        guard let session, let windows = session.windows, !windows.isEmpty,
              let anchor = hud.anchor
        else { return }
        let window = windows[session.index]
        let visible = Spaces.layout().visibleSpaces
        preview.show(window, isVisible: window.spaces.contains(where: visible.contains),
                     anchor: anchor.frame, on: anchor.screen)
    }

    private func end() {
        revealTimer?.invalidate()
        revealTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        session = nil
        preview.hide()
        hud.hide()
    }

    private func reload() {
        guard var session else { return }

        let previous = session.windows.flatMap { $0.isEmpty ? nil : $0[session.index].id }
        let found = Switcher.scan(session)
        session.windows = found
        Diagnostics.note("loaded \(found.count) (scope=\(session.scope))")

        // Keep the same window selected after a scope change. If the new list
        // does not contain it, select the first window.
        if let previous {
            session.offset = found.firstIndex { $0.id == previous } ?? 0
        }
        self.session = session

        if found.isEmpty {
            preview.hide()
            hud.hide()
        } else {
            showHUD()
        }
    }

    /// The windows in the scope of `session`, in switcher order. It uses AX, so
    /// it must not run in the event tap callback. If it finds only one window,
    /// it returns an empty list, because there is no window to switch to.
    private static func scan(_ session: Session) -> [Window] {
        let tracker = WindowTracker.shared
        // The window that the user leaves goes first. Then the next window in
        // the list is the previous window, on any Space.
        tracker.promoteFrontWindow()
        let layout = Spaces.layout()
        tracker.syncWithServer(layout)

        var found = tracker.list(session.scope, in: layout)
        if let pid = session.appFilter {
            found = found.filter { $0.pid == pid }
        }
        return found.count > 1 ? found : []
    }
}
