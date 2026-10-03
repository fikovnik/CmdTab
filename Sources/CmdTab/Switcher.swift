import AppKit
import CmdTabConfig
import CmdTabModel

/// Delay the list to prevent a flash during a quick switch.
private let revealDelay: TimeInterval = 0.25

/// Delay the first preview until the selection stays on one row.
private let previewDelay: TimeInterval = 0.2

@MainActor
final class Switcher {
    /// The state of one traversal. Clear the session to end the traversal.
    private struct Session {
        let mode: SwitchMode
        /// The process filter for current app mode.
        let appFilter: pid_t?
        var traversal: WindowTraversal<Window>
        var scope = WindowScope.allSpaces
        /// Show the list after the reveal timer and window scan complete.
        var wantsHUD = false

        var scopeLabel: String { scope == .allSpaces ? "All Spaces" : "This Space" }
    }

    private let hud = HUDPanel()
    private let preview = WindowPreview.shared
    private var session: Session?
    private var revealTimer: Timer?
    private var previewTimer: Timer?

    var diagnosticSummary: String {
        let cycle = session.map {
            "mode=\($0.mode) scope=\($0.scope) wantsHUD=\($0.wantsHUD) windows=\($0.traversal.windows?.count.description ?? "nil") index=\($0.traversal.index)"
        } ?? "idle"
        return "Switcher: \(cycle) revealTimer=\(revealTimer?.isValid == true)\n"
            + hud.diagnosticSummary + "\nPreview: showing=\(preview.isShowing)"
    }

    /// The page size, including when the list is hidden.
    var pageSize: Int {
        let capacity = hud.rowCapacity
        return max(1, min(session?.traversal.windows?.count ?? capacity, capacity))
    }

    func screenParametersChanged() {
        Diagnostics.note("screen parameters changed: \(hud.diagnosticSummary)")
        preview.resetDisplayConfiguration()
        hud.resetDisplayConfiguration()
        // Keep the current selection if a display changes while Cmd is held.
        showHUD()
    }

    func start(_ mode: SwitchMode, reversed: Bool) {
        guard session == nil else { return }
        session = Session(
            mode: mode,
            appFilter: mode == .currentApp ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil,
            traversal: WindowTraversal(reversed: reversed)
        )
        Diagnostics.note("start \(mode) reversed=\(reversed)")

        // `.common`, so that the timer also fires while the event tap is busy.
        let timer = Timer(timeInterval: revealDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reveal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer

        // Run the scan after the event tap callback returns.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// `delta` is +1 for forward and -1 for back. If `wrap` is false, as for a
    /// page move, the selection stops at the first or the last row.
    func step(_ delta: Int, wrap: Bool = true) {
        guard var session else { return }
        session.traversal.step(delta, wrap: wrap)
        self.session = session
        if session.wantsHUD {
            hud.update(selected: session.traversal.index)
            armPreview()
        }
    }

    /// Change the Space filter and keep the selected window when possible.
    func toggleScope() {
        guard var session else { return }
        session.scope = session.scope == .allSpaces ? .currentSpace : .allSpaces
        self.session = session
        // Do the scan after the callback, as in `start`.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// End the traversal immediately. Execute its focus request after the event tap returns.
    func commit() {
        guard let session else { return }
        end()

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.performSwitch(session) }
        }
    }

    func cancel() {
        end()
    }

    private func performSwitch(_ committed: Session) {
        var session = committed

        // A quick switch can end before the scan. Complete the scan here.
        if session.traversal.windows == nil { session.traversal.replace(with: Switcher.scan(session)) }

        guard let windows = session.traversal.windows, !windows.isEmpty else {
            Diagnostics.note("commit: nothing to switch to")
            return
        }
        Diagnostics.note("commit index=\(session.traversal.index) of \(windows.count)")
        Focus.focus(windows[session.traversal.index])
    }

    private func reveal() {
        guard var session else { return }
        session.wantsHUD = true
        self.session = session
        // Record whether the scan completed before the reveal timer.
        Diagnostics.note("reveal timer: windows=\(session.traversal.windows?.count.description ?? "nil")")
        showHUD()
    }

    private func showHUD() {
        guard let session, session.wantsHUD,
              let windows = session.traversal.windows, !windows.isEmpty
        else { return }
        Diagnostics.note("reveal \(windows.count) windows")
        hud.show(windows, selected: session.traversal.index, scope: session.scopeLabel)
        armPreview()
    }

    /// Delay the first preview. Update a visible preview immediately.
    private func armPreview() {
        previewTimer?.invalidate()
        previewTimer = nil

        if preview.isShowing {
            // A visible preview can need a capture. Keep it outside the event tap.
            DispatchQueue.main.async { [weak self] in self?.showPreview() }
            return
        }

        guard let session, session.wantsHUD,
              let windows = session.traversal.windows, !windows.isEmpty
        else { return }

        // `.common`, for the same reason as the reveal timer.
        let timer = Timer(timeInterval: previewDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPreview() }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func showPreview() {
        guard let session, let windows = session.traversal.windows, !windows.isEmpty,
              let anchor = hud.anchor
        else { return }
        let window = windows[session.traversal.index]
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

        let found = Switcher.scan(session)
        session.traversal.replace(with: found)
        Diagnostics.note("loaded \(found.count) (scope=\(session.scope))")
        self.session = session

        if found.isEmpty {
            preview.hide()
            hud.hide()
        } else {
            showHUD()
        }
    }

    /// Read the list outside the event tap. A list with one window needs no switch.
    private static func scan(_ session: Session) -> [Window] {
        let tracker = WindowTracker.shared
        // The window that the user leaves goes first. Then the next window in
        // the list is the previous window, on any Space.
        tracker.promoteFrontWindow()
        let layout = Spaces.layout()
        tracker.syncWithServer(layout)

        var found = tracker.list(session.scope, in: layout)
        if session.mode == .currentApp {
            guard let pid = session.appFilter else { return [] }
            found = found.filter { $0.pid == pid }
        }
        return found.count > 1 ? found : []
    }
}
