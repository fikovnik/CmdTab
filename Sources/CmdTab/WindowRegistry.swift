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
/// Consequence worth knowing: a Space this app has never seen contributes
/// nothing until you visit it once.
final class WindowRegistry {
    static let shared = WindowRegistry()

    private var known: [CGWindowID: WindowRef] = [:]
    private var pendingRefresh: Timer?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
            }
        }
        refresh()
    }

    /// Activating a window fires an activation notification, and a refresh walks
    /// every app over the Accessibility API. Doing that inline would block the
    /// main thread (and so the event tap) right when someone is switching
    /// windows in a hurry. Coalesce instead.
    private func scheduleRefresh() {
        pendingRefresh?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingRefresh = timer
    }

    /// Forget dead windows, then learn whatever AX is willing to show right now.
    func refresh() {
        let live = WindowEnumerator.liveWindowIDs()
        known = known.filter { live.contains($0.key) }
        for window in WindowEnumerator.axWindowsOfAllApps() {
            known[window.id] = window
        }
    }

    var all: [WindowRef] { Array(known.values) }
}
