import AppKit
import CmdTabConfig
import CmdTabModel

/// Run window, desktop, shell, and AppleScript actions after the event tap returns.
@MainActor
final class WindowActionHost {
    /// Keep the position and size before maximize so the next press can restore them.
    private var restoreFrames: [CGWindowID: CGRect] = [:]
    private var frameRequest = 0

    func run(_ action: Action) {
        frameRequest += 1
        Diagnostics.note("action: \(action)")
        switch action {
        case .tile(let edge):
            changeFrame { [weak self] in self?.applyTile(edge, target: $0) }
        case .center: center()
        case .toggleFullScreen: toggleFullScreen()
        case .toggleMaximize: toggleMaximize()
        case .moveToDisplay(let direction):
            guard NSScreen.screens.count > 1 else { return }
            changeFrame { [weak self] in self?.moveToDisplay(direction, target: $0) }
        case .desktop(.number(let number)): SpaceSwitcher.activate(desktop: number)
        case .desktop(.previous): SpaceSwitcher.step(-1)
        case .desktop(.next): SpaceSwitcher.step(1)
        case .shell(let command): spawn("/bin/sh", arguments: ["-c", command])
        case .appleScript(let source): spawn("/usr/bin/osascript", arguments: ["-e", source])
        case .switcher: break
        }
    }

    /// Start external commands on a worker queue. Record launch and exit failures.
    private func spawn(_ executable: String, arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus != 0 {
                    let status = process.terminationStatus
                    Task { @MainActor in Diagnostics.error("command \(executable) exited with status \(status)") }
                }
            }
            do { try process.run() }
            catch {
                let message = error.localizedDescription
                Task { @MainActor in Diagnostics.error("could not start \(executable): \(message)") }
            }
        }
    }

    private func changeFrame(_ apply: @escaping @MainActor (WindowGeometry.Target) -> Void) {
        guard let target = WindowGeometry.focused() else { return }
        if WindowGeometry.isFullScreen(target.window) == true {
            guard WindowGeometry.setFullScreen(false, for: target.window) else {
                Diagnostics.error("could not exit full screen id=\(target.id)")
                return
            }
            finishFrameChange(target: target, request: frameRequest,
                              deadline: ProcessInfo.processInfo.systemUptime + 3, apply: apply)
        } else { apply(target) }
    }

    /// Wait for full screen exit before you read the display frame.
    private func finishFrameChange(target: WindowGeometry.Target, request: Int, deadline: TimeInterval,
                                   apply: @escaping @MainActor (WindowGeometry.Target) -> Void) {
        guard request == frameRequest else { return }
        if WindowGeometry.isFullScreen(target.window) == false {
            apply(target)
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
            Diagnostics.error("full screen exit timed out id=\(target.id)")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finishFrameChange(target: target, request: request, deadline: deadline, apply: apply)
            }
        }
    }

    private func applyTile(_ edge: WindowEdge, target: WindowGeometry.Target) {
        guard let current = WindowGeometry.frame(of: target.window),
              let visible = WindowGeometry.visibleFrame(containing: current) else { return }
        WindowGeometry.setFrame(Layout.next(edge: edge, window: current, in: visible), on: target)
    }

    private func moveToDisplay(_ direction: DisplayDirection, target: WindowGeometry.Target) {
        guard let current = WindowGeometry.frame(of: target.window),
              let displays = WindowGeometry.adjacentDisplay(containing: current, toward: direction)
        else { return }
        if let restore = restoreFrames[target.id] {
            restoreFrames[target.id] = Layout.moved(restore, from: displays.source, to: displays.destination)
        }
        WindowGeometry.setFrame(Layout.moved(current, from: displays.source, to: displays.destination), on: target)
    }

    /// Apply center actions only to windows outside full screen.
    private func center() {
        guard let target = WindowGeometry.focused(),
              WindowGeometry.isFullScreen(target.window) != true,
              let current = WindowGeometry.frame(of: target.window),
              let visible = WindowGeometry.visibleFrame(containing: current)
        else { return }

        WindowGeometry.setFrame(Layout.nextCentered(window: current, in: visible), on: target)
    }

    private func toggleFullScreen() {
        guard let target = WindowGeometry.focused() else { return }
        guard let isFullScreen = WindowGeometry.isFullScreen(target.window) else {
            Diagnostics.error("this window does not support full screen")
            return
        }
        if !WindowGeometry.setFullScreen(!isFullScreen, for: target.window) {
            Diagnostics.error("full screen toggle was refused")
        }
    }

    /// Maximize uses the display area outside the menu bar and Dock.
    /// Native full screen uses a separate Space.
    private func toggleMaximize() {
        guard let target = WindowGeometry.focused(),
              WindowGeometry.isFullScreen(target.window) != true,
              let current = WindowGeometry.frame(of: target.window),
              let visible = WindowGeometry.visibleFrame(containing: current)
        else { return }

        let tracker = WindowTracker.shared
        tracker.syncWithServer(Spaces.layout())
        restoreFrames = restoreFrames.filter { tracker.windows[$0.key] != nil || $0.key == target.id }

        if Layout.isMaximized(current, in: visible) {
            guard let restore = restoreFrames.removeValue(forKey: target.id) else {
                // If CmdTab has no previous frame, restore the window to the left half.
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
}
