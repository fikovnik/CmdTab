import AppKit

enum SwitchMode {
    /// Cmd+Tab: every window on the current Space, across all screens.
    case allWindows
    /// Cmd+`: windows of the app that was frontmost when cycling began.
    case currentApp
}

final class Switcher {
    private let hud = HUDPanel()
    private(set) var mode: SwitchMode?
    private var windows: [WindowRef] = []
    /// False: current Space only. True: every Space, set by Esc mid-cycle.
    private var allSpaces = false
    private var appFilter: pid_t?
    /// Unbounded step counter, wrapped into `windows` only when rendering.
    /// Lets steps arrive before the (async) window scan has finished.
    private var offset = 0

    var isCycling: Bool { mode != nil }

    private var index: Int {
        guard !windows.isEmpty else { return 0 }
        return ((offset % windows.count) + windows.count) % windows.count
    }

    func start(_ mode: SwitchMode) {
        guard self.mode == nil else { return }
        self.mode = mode
        allSpaces = false
        offset = 1
        appFilter = mode == .currentApp ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil

        // Scanning windows over the Accessibility API can take tens of
        // milliseconds. Defer it so the event tap callback returns immediately
        // and the system never disables the tap for exceeding its budget.
        DispatchQueue.main.async { [weak self] in
            self?.reload()
        }
    }

    /// `delta` is +1 forward through the MRU list, -1 backward.
    func step(_ delta: Int) {
        guard mode != nil else { return }
        offset += delta
        hud.update(selected: index)
    }

    /// Esc: widen the list to every Space and back again. The current Space's
    /// windows stay at the head of the widened list, so the highlighted window
    /// never moves under you.
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
        guard mode != nil, !windows.isEmpty else { return }
        WindowEnumerator.focus(windows[index])
    }

    func cancel() {
        reset()
    }

    private func reset() {
        mode = nil
        windows = []
        allSpaces = false
        appFilter = nil
        offset = 0
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
            // Nothing to switch to. Stay silent rather than flashing an empty HUD.
            windows = []
            hud.hide()
            return
        }
        windows = found

        // Keep the highlight on the same window across a scope change. If it
        // fell out of the narrowed list, fall back to the frontmost window.
        if let selectedID {
            offset = windows.firstIndex(where: { $0.id == selectedID }) ?? 0
        }
        hud.show(windows, selected: index)
    }
}
