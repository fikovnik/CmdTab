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
        offset = 1

        // Scanning windows over the Accessibility API can take tens of
        // milliseconds. Defer it so the event tap callback returns immediately
        // and the system never disables the tap for exceeding its budget.
        DispatchQueue.main.async { [weak self] in
            self?.loadWindows(for: mode)
        }
    }

    /// `delta` is +1 forward through the MRU list, -1 backward.
    func step(_ delta: Int) {
        guard mode != nil else { return }
        offset += delta
        hud.update(selected: index)
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
        offset = 0
        hud.hide()
    }

    private func loadWindows(for mode: SwitchMode) {
        guard self.mode != nil else { return }

        switch mode {
        case .allWindows:
            windows = WindowEnumerator.currentSpaceWindowsMRU()
        case .currentApp:
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                windows = []
                return
            }
            windows = WindowEnumerator.windowsMRU(forPID: pid)
        }

        guard windows.count > 1 else {
            // Nothing to switch to. Stay silent rather than flashing an empty HUD.
            windows = []
            return
        }
        hud.show(windows, selected: index)
    }
}
