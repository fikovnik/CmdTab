import AppKit
import CmdTabConfig

/// How long Cmd must be held before the list appears. A deliberate Cmd+Tab tap
/// runs 120-200 ms, so this has to clear that or the panel flashes on every
/// quick switch. The extra margin here costs nothing, because the list is only
/// ever a hint, because releasing Cmd switches either way.
private let revealDelay: TimeInterval = 0.25

/// How long the selection must sit still, once the list is up, before the first
/// thumbnail appears. Cycling straight past ten windows should not flash ten
/// previews, because a preview is what you get for stopping. Paid per cycle:
/// after the first one is up, the preview follows the selection immediately.
private let previewDelay: TimeInterval = 0.2

@MainActor
final class Switcher {
    /// Everything one Cmd-held pass owns, bundled into a single value so that
    /// ending a cycle is one assignment and cannot leave a field behind.
    private struct Session {
        let mode: SwitchMode
        /// Set in `.currentApp` mode: only this process's windows are listed.
        let appFilter: pid_t?
        /// Unbounded step counter, folded into `windows` only when rendering.
        /// Lets steps arrive before the (deferred) window scan has finished.
        var offset: Int
        var scope = WindowScope.allSpaces
        /// `nil` until the scan lands, distinct from an empty list, which means
        /// the scan ran and found nothing worth switching to.
        var windows: [WindowRef]?
        /// Set once Cmd has been held past `revealDelay`. The list is shown as
        /// soon as both this and a scanned list are true, in whichever order
        /// they happen to arrive.
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
    /// A committed session waiting for its switch to run off the event tap
    /// callback. Parked here rather than captured by the closure so the cycle
    /// can end immediately, because the keyboard must not stay swallowed for it.
    private var pendingSwitch: Session?

    var isCycling: Bool { session != nil }
    var mode: SwitchMode? { session?.mode }

    /// Rows the panel can show at once, so PgUp/PgDn move by exactly one
    /// screenful. Derived from the screen and the current list rather than from
    /// what the HUD last drew, so it is right even while the panel is hidden.
    var pageSize: Int { max(1, min(session?.windows?.count ?? 1, hud.rowCapacity)) }

    func start(_ mode: SwitchMode, reversed: Bool) {
        guard session == nil else { return }
        session = Session(
            mode: mode,
            appFilter: mode == .currentApp ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil,
            offset: reversed ? -1 : 1
        )
        Diagnostics.note("start \(mode) reversed=\(reversed)")

        // .common, not the default mode: the event tap's run loop source uses
        // common modes, and the timer must still fire while it is pumping.
        let timer = Timer(timeInterval: revealDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reveal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer

        // Scanning windows over the Accessibility API can take tens of
        // milliseconds. Defer it so the event tap callback returns immediately
        // and the system never disables the tap for exceeding its budget.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// `delta` is +1 forward through the list, -1 backward. Page moves clamp at
    /// the ends. Single steps wrap, the way a switcher is expected to.
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

    /// Right arrow: narrow the list to this Space and back again. The
    /// highlighted window is preserved by id across the flip (see `reload`), so
    /// the selection never moves under you.
    func toggleScope() {
        guard var session else { return }
        session.scope = session.scope == .allSpaces ? .currentSpace : .allSpaces
        self.session = session
        // Same reason as `start`: rescanning talks to the Accessibility API,
        // far too slow to do inside the event tap callback.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Switch to the highlighted window and end the cycle.
    ///
    /// Called from the event tap callback, so the switch itself is deferred: an
    /// AX scan or a focus round-trip inside the callback is exactly what gets a
    /// tap disabled for overrunning its budget, and a disabled tap drops the
    /// events this switcher needs to see.
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

        // A quick enough Cmd+Tab releases the key before the deferred scan has
        // landed. Finish it here rather than silently dropping the switch.
        if session.windows == nil { session.windows = Switcher.scan(session) }

        guard let windows = session.windows, !windows.isEmpty else {
            Diagnostics.note("commit: nothing to switch to")
            return
        }
        Diagnostics.note("commit index=\(session.index) of \(windows.count)")
        WindowEnumerator.focus(windows[session.index])
    }

    private func reveal() {
        guard var session else { return }
        session.wantsHUD = true
        self.session = session
        // Whether the deferred scan has landed by now is the whole question
        // when the panel fails to appear: "nil" means it has not.
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

    /// Move the preview to the selected row, or start the dwell timer if there
    /// is no preview up yet. The delay guards the *first* thumbnail of a cycle.
    /// Once one is on screen, waiting again only makes the panel blink.
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

        // Same run loop mode as the reveal timer: the event tap pumps common
        // modes while Cmd is held, and a default-mode timer would never fire.
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
        preview.show(windows[session.index], anchor: anchor.frame, on: anchor.screen)
    }

    /// Drop the cycle. One assignment, so no field can be left behind.
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

        // Keep the highlight on the same window across a scope change. If it
        // fell out of the narrowed list, fall back to the frontmost window.
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

    /// The window list for a session's scope, most-recently-used first. Talks
    /// to the Accessibility API, so it never runs on the tap callback. A list of
    /// one is returned empty: there is nothing to switch to.
    private static func scan(_ session: Session) -> [WindowRef] {
        // Stamp the window being left first. Runs on the turn after the keypress,
        // so nothing can have stolen focus in between, and it is what lets the
        // next cycle find this window one below the top, on any Space.
        WindowRegistry.shared.promoteFrontWindow()

        var found = WindowEnumerator.windows(session.scope)
        if let pid = session.appFilter {
            found = found.filter { $0.pid == pid }
        }
        return found.count > 1 ? found : []
    }
}
