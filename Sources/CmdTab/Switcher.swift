import AppKit

enum SwitchMode {
    /// Cmd+Tab: every window on the current Space, across all screens.
    case allWindows
    /// Cmd+`: windows of the app that was frontmost when cycling began.
    case currentApp
}

/// How long Cmd must be held before the list appears. A deliberate Cmd+Tab tap
/// runs 120-200 ms, so this has to clear that or the panel flashes on every
/// quick switch. The extra margin here costs nothing, because the list is only
/// ever a hint, because releasing Cmd switches either way.
private let revealDelay: TimeInterval = 0.25

final class Switcher {
    private let hud = HUDPanel()
    private(set) var mode: SwitchMode?
    private var windows: [WindowRef] = []
    private var allSpaces = false
    private var appFilter: pid_t?
    /// Unbounded step counter, wrapped into `windows` only when rendering.
    /// Lets steps arrive before the (async) window scan has finished.
    private var offset = 0
    private var revealTimer: Timer?

    /// Set once Cmd has been held past `revealDelay`. The list is shown as soon
    /// as both this and a loaded window list are true, in whichever order they
    /// happen to arrive.
    private var wantsHUD = false

    var isCycling: Bool { mode != nil }
    var pageSize: Int { hud.pageSize }

    private var index: Int {
        guard !windows.isEmpty else { return 0 }
        return ((offset % windows.count) + windows.count) % windows.count
    }

    private var scopeLabel: String { allSpaces ? "All Spaces" : "This Space" }

    func start(_ mode: SwitchMode) {
        guard self.mode == nil else { return }
        self.mode = mode
        allSpaces = false
        wantsHUD = false
        offset = 1
        appFilter = mode == .currentApp ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        Diagnostics.note("start \(mode)")

        // .common, not the default mode: the event tap's run loop source uses
        // common modes, and the timer must still fire while it is pumping.
        let timer = Timer(timeInterval: revealDelay, repeats: false) { [weak self] _ in
            self?.reveal()
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer

        // Scanning windows over the Accessibility API can take tens of
        // milliseconds. Defer it so the event tap callback returns immediately
        // and the system never disables the tap for exceeding its budget.
        DispatchQueue.main.async { [weak self] in
            self?.reload()
        }
    }

    /// `delta` is +1 forward through the list, -1 backward. Page moves clamp at
    /// the ends. Single steps wrap, the way a switcher is expected to.
    func step(_ delta: Int, wrap: Bool = true) {
        guard mode != nil else { return }
        if wrap || windows.isEmpty {
            offset += delta
        } else {
            offset = max(0, min(index + delta, windows.count - 1))
        }
        if wantsHUD { hud.update(selected: index) }
    }

    /// Right arrow: widen the list to every Space and back again. The current
    /// Space's windows stay at the head of the widened list, so the highlighted
    /// window never moves under you.
    func toggleAllSpaces() {
        guard mode != nil else { return }
        allSpaces.toggle()
        // Same reason as `start`: widening walks every app over the
        // Accessibility API, far too slow to do inside the event tap callback.
        DispatchQueue.main.async { [weak self] in
            self?.reload()
        }
    }

    func commit() {
        defer { reset() }
        guard mode != nil else { return }

        // The scan is deferred off the event tap callback, so a quick enough
        // Cmd+Tab can release the key before it has landed. Finish it here
        // rather than silently dropping the switch.
        if windows.isEmpty { reload() }

        guard !windows.isEmpty else {
            Diagnostics.note("commit: nothing to switch to")
            return
        }
        Diagnostics.note("commit index=\(index) of \(windows.count)")
        WindowEnumerator.focus(windows[index])
    }

    func cancel() {
        reset()
    }

    private func reveal() {
        guard mode != nil else { return }
        wantsHUD = true
        showHUD()
    }

    private func showHUD() {
        guard wantsHUD, !windows.isEmpty else { return }
        Diagnostics.note("reveal \(windows.count) windows")
        hud.show(windows, selected: index, scope: scopeLabel)
    }

    private func reset() {
        revealTimer?.invalidate()
        revealTimer = nil
        mode = nil
        windows = []
        allSpaces = false
        appFilter = nil
        offset = 0
        wantsHUD = false
        hud.hide()
    }

    private func reload() {
        guard mode != nil else { return }

        let selectedID = windows.isEmpty ? nil : windows[index].id

        var found = allSpaces
            ? WindowEnumerator.allSpacesWindowsMRU()
            : WindowEnumerator.currentSpaceWindowsMRU()
        if let appFilter { found = found.filter { $0.pid == appFilter } }

        guard found.count > 1 else {
            windows = []
            hud.hide()
            return
        }
        windows = found
        Diagnostics.note("loaded \(windows.count) (allSpaces=\(allSpaces))")

        // Keep the highlight on the same window across a scope change. If it
        // fell out of the narrowed list, fall back to the frontmost window.
        if let selectedID {
            offset = windows.firstIndex(where: { $0.id == selectedID }) ?? 0
        }
        showHUD()
    }
}
