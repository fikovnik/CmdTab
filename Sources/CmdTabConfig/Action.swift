import Foundation

/// The window list that a switcher cycle goes through.
public enum SwitchMode: Sendable {
    /// All windows on all Spaces.
    case allWindows
    /// The windows of the app that was frontmost when the cycle started.
    case currentApp
}

/// The operations that CmdTab can do on a window or a Space.
///
/// The app target implements this protocol because it owns the Accessibility
/// API and the WindowServer private API. The actions call this protocol and do
/// not do the work themselves. Thus, the actions do not use AppKit, and tests
/// can use a mock host.
@MainActor
public protocol WindowActions: AnyObject {
    /// Move the focused window to `edge`. If the window is already at `edge`,
    /// change to the next fraction.
    func tile(_ edge: WindowEdge)
    /// Move the focused window to the center of its screen. See
    /// `Layout.nextCentered(window:in:)`.
    func center()
    /// Toggle native full screen, as the green window button does.
    func toggleFullScreen()
    /// Make the window fill the visible frame of its screen. If the window
    /// already fills it, move the window to its previous frame.
    func toggleMaximize()
    /// Switch the focused display to desktop `number`. The first desktop is 1.
    func activateDesktop(_ number: Int)
    /// Move one desktop to the left or to the right on the focused display.
    func stepDesktop(_ offset: Int)
}

/// The destination of a bound chord. The app target implements this protocol
/// because it owns the event tap. The actions do not know the event tap. Thus,
/// tests can use a recording sink.
public protocol BindingSink: AnyObject {
    /// Match the chord in the CmdTab event tap. When the user presses the
    /// chord, run `command`.
    func registerLocal(chord: Chord, command: any LocalCommand)
    /// Match the chord in the CmdTab event tap as a switcher trigger.
    func registerSwitcher(chord: Chord, mode: SwitchMode)
}

/// A command that CmdTab runs itself when the user presses a chord.
public protocol LocalCommand: AnyObject, Sendable {
    /// The event tap callback calls this function directly. Thus, it must not
    /// block.
    @MainActor func run(on host: any WindowActions)
}

/// An action that the config can bind to a chord.
public protocol Action: AnyObject, Sendable {
    /// The spelling of the action in the config. Error messages use it.
    var name: String { get }
    func bind(_ chord: Chord, into sink: any BindingSink)
}

/// `tile:left`, `tile:right`, `tile:top` and `tile:bottom`. Each press of the
/// chord changes to the next fraction. Thus, the edge is the only parameter.
public final class TileAction: Action, LocalCommand {
    public let edge: WindowEdge
    public var name: String { "tile:\(edge.rawValue)" }

    public init(edge: WindowEdge) { self.edge = edge }

    public func bind(_ chord: Chord, into sink: any BindingSink) {
        sink.registerLocal(chord: chord, command: self)
    }

    public func run(on host: any WindowActions) { host.tile(edge) }
}

/// `tile:center`. The config spells it as a tile action, but it is not a
/// `WindowEdge`. A centered window is not flush with an edge, and the first
/// press keeps the window size.
public final class CenterAction: Action, LocalCommand {
    public var name: String { "tile:center" }

    public init() {}

    public func bind(_ chord: Chord, into sink: any BindingSink) {
        sink.registerLocal(chord: chord, command: self)
    }

    public func run(on host: any WindowActions) { host.center() }
}

/// `toggle-fullscreen` and `toggle-maximize`.
public final class ToggleAction: Action, LocalCommand {
    public enum Kind: String, Sendable { case fullscreen, maximize }

    public let kind: Kind
    public var name: String { "toggle-\(kind.rawValue)" }

    public init(kind: Kind) { self.kind = kind }

    public func bind(_ chord: Chord, into sink: any BindingSink) {
        sink.registerLocal(chord: chord, command: self)
    }

    public func run(on host: any WindowActions) {
        switch kind {
        case .fullscreen: host.toggleFullScreen()
        case .maximize: host.toggleMaximize()
        }
    }
}

/// `switch-desktop:N`, `switch-desktop:previous` and `switch-desktop:next`.
public final class SwitchDesktopAction: Action, LocalCommand {
    public enum Target: Sendable, Equatable {
        /// A desktop number on the focused display. The first desktop is 1.
        case desktop(Int)
        /// A step of one desktop. A negative value moves to the left. The step
        /// does not wrap at the first or the last desktop.
        case step(Int)
    }

    public let target: Target
    public var name: String {
        switch target {
        case .desktop(let n): "switch-desktop:\(n)"
        case .step(let offset): "switch-desktop:\(offset < 0 ? "previous" : "next")"
        }
    }

    public init(target: Target) { self.target = target }

    public func bind(_ chord: Chord, into sink: any BindingSink) {
        sink.registerLocal(chord: chord, command: self)
    }

    public func run(on host: any WindowActions) {
        switch target {
        case .desktop(let n): host.activateDesktop(n)
        case .step(let offset): host.stepDesktop(offset)
        }
    }
}

/// `shell:<command>`. The command runs through `/bin/sh -c`. Thus, pipes, globs
/// and `~` work as in a terminal.
public final class ShellAction: Action, LocalCommand {
    public let command: String
    public var name: String { "shell:\(command)" }

    public init(command: String) { self.command = command }

    public func bind(_ chord: Chord, into sink: any BindingSink) {
        sink.registerLocal(chord: chord, command: self)
    }

    public func run(on host: any WindowActions) {
        Spawn.run(["/bin/sh", "-c", command], label: name)
    }
}

/// `applescript:<source>`. The script runs through `osascript`, not through
/// `NSAppleScript` in the CmdTab process. Thus, it uses the same code path as
/// `shell:` and does not run on the main thread. TCC records CmdTab as the
/// sender of the Apple Event, because CmdTab is the responsible process of the
/// child.
public final class AppleScriptAction: Action, LocalCommand {
    public let source: String
    public var name: String { "applescript:\(source)" }

    public init(source: String) { self.source = source }

    public func bind(_ chord: Chord, into sink: any BindingSink) {
        sink.registerLocal(chord: chord, command: self)
    }

    public func run(on host: any WindowActions) {
        Spawn.run(["/usr/bin/osascript", "-e", source], label: name)
    }
}

/// A switcher trigger. The config sets it in the `trigger` field of a
/// `switch-*` section, not in `keys`, because a switcher has its own settings.
/// It uses the same sink as the other actions.
public final class SwitcherAction: Action {
    public let mode: SwitchMode
    public var name: String { mode == .allWindows ? "switch-all-windows" : "switch-current-app" }

    public init(mode: SwitchMode) { self.mode = mode }

    public func bind(_ chord: Chord, into sink: any BindingSink) {
        sink.registerSwitcher(chord: chord, mode: mode)
    }
}

/// Starts a process and does not wait for it. The caller is the event tap
/// callback. If the callback is too slow, the system disables the tap.
enum Spawn {
    static func run(_ argv: [String], label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                Log.note("\(label) failed to launch: \(error.localizedDescription)")
            }
        }
    }
}

/// The destination of the problems that this target reports. The app target
/// sets it to `Diagnostics.note`, so config and command failures go into the
/// same ring buffer as all other messages. Without a sink, it uses `NSLog`.
public enum Log {
    nonisolated(unsafe) private static var sink: (@Sendable (String) -> Void)?

    public static func use(_ sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    public static func note(_ message: String) {
        if let sink { sink(message) } else { NSLog("CmdTab: %@", message) }
    }
}
