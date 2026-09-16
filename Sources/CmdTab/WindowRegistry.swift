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

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
        refresh()
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
