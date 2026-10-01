import AppKit
import CmdTabConfig

/// Does the window and Space actions that the config binds.
///
/// The actions in `CmdTabConfig` contain only the config values. This type does
/// all the work that needs AX, AppKit or the WindowServer.
@MainActor
final class WindowActionHost: WindowActions {
    /// The frames before maximize, by window ID. `toggleMaximize` restores them.
    ///
    /// The dictionary keeps the entries of closed windows. An entry is only a
    /// few bytes, and a cleanup needs a timer or a notification observer.
    private var restoreFrames: [CGWindowID: CGRect] = [:]

    func tile(_ edge: WindowEdge) {
        guard let target = WindowGeometry.focused(),
              let current = WindowGeometry.frame(of: target.window),
              let visible = WindowGeometry.visibleFrame(containing: current)
        else { return }

        // A full-screen window has its own Space. Thus, end full screen first,
        // then set the frame.
        if WindowGeometry.isFullScreen(target.window) == true {
            _ = WindowGeometry.setFullScreen(false, for: target.window)
        }

        WindowGeometry.setFrame(Layout.next(edge: edge, window: current, in: visible),
                                on: target)
    }

    /// Unlike `tile`, this does not end full screen. A full-screen window fills
    /// the display. Thus, it has no size to center and no fraction to start the
    /// cycle from.
    func center() {
        guard let target = WindowGeometry.focused(),
              let current = WindowGeometry.frame(of: target.window),
              let visible = WindowGeometry.visibleFrame(containing: current)
        else { return }

        WindowGeometry.setFrame(Layout.nextCentered(window: current, in: visible), on: target)
    }

    func toggleFullScreen() {
        guard let target = WindowGeometry.focused() else { return }
        guard let isFullScreen = WindowGeometry.isFullScreen(target.window) else {
            Log.note("this window does not support full screen")
            return
        }
        if !WindowGeometry.setFullScreen(!isFullScreen, for: target.window) {
            Log.note("full screen toggle was refused")
        }
    }

    /// Maximize fills the visible frame of the screen, so that the menu bar and
    /// the Dock stay visible. Full screen uses the full display and its own
    /// Space.
    func toggleMaximize() {
        guard let target = WindowGeometry.focused(),
              let current = WindowGeometry.frame(of: target.window),
              let visible = WindowGeometry.visibleFrame(containing: current)
        else { return }

        if Layout.isMaximized(current, in: visible) {
            guard let restore = restoreFrames.removeValue(forKey: target.id) else {
                // CmdTab did not maximize the window, so there is no frame to
                // restore. Use the left half, which is better than no change.
                WindowGeometry.setFrame(Layout.frame(edge: .left, fraction: Layout.fractions[0],
                                                     in: visible), on: target)
                return
            }
            WindowGeometry.setFrame(restore, on: target)
        } else {
            restoreFrames[target.id] = current
            WindowGeometry.setFrame(visible, on: target)
        }
    }

    func activateDesktop(_ number: Int) { SpaceSwitcher.activate(desktop: number) }

    func stepDesktop(_ offset: Int) { SpaceSwitcher.step(offset) }
}
