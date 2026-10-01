import AppKit
import CmdTabConfig

/// Performs the window and Space actions the config binds.
///
/// This is the app-target half of `WindowActions`: the actions themselves carry
/// only what was configured, and everything that needs Accessibility, AppKit or
/// the WindowServer happens here.
@MainActor
final class WindowActionHost: WindowActions {
    /// Frames to put windows back to when maximize is toggled off.
    ///
    /// Keyed by window id and never pruned on purpose. An entry is a few bytes
    /// and the alternative is either a timer or a notification subscription for
    /// something that costs nothing to leave alone.
    private var restoreFrames: [CGWindowID: CGRect] = [:]

    func tile(_ edge: WindowEdge) {
        guard let target = WindowGeometry.focused(),
              let current = WindowGeometry.frame(of: target.window),
              let visible = WindowGeometry.visibleFrame(containing: current)
        else { return }

        // Tiling a full-screen window would fight the Space it lives in, so
        // bring it out first and tile the restored frame.
        if WindowGeometry.isFullScreen(target.window) == true {
            _ = WindowGeometry.setFullScreen(false, for: target.window)
        }

        WindowGeometry.setFrame(Layout.next(edge: edge, window: current, in: visible),
                                on: target)
    }

    /// Unlike tiling, this leaves a full-screen window alone: such a window
    /// fills the display, so centering the size it has is a no-op and there is
    /// no fraction it can match to start cycling from.
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

    /// Maximize fills the screen's *visible* frame, so the menu bar and Dock
    /// stay reachable. That is what makes it worth having alongside full
    /// screen, which takes the whole display and its own Space.
    func toggleMaximize() {
        guard let target = WindowGeometry.focused(),
              let current = WindowGeometry.frame(of: target.window),
              let visible = WindowGeometry.visibleFrame(containing: current)
        else { return }

        if Layout.isMaximized(current, in: visible) {
            guard let restore = restoreFrames.removeValue(forKey: target.id) else {
                // Maximized by something other than us, so there is nothing to
                // go back to. Half the screen is a more useful answer than
                // doing nothing.
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
