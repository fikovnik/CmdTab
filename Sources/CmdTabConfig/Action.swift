import Foundation

/// Which window list a switcher cycle walks.
public enum SwitchMode: Sendable {
    /// Every window on the current Space, across all screens.
    case allWindows
    /// Windows of the app that was frontmost when cycling began.
    case currentApp
}

/// What CmdTab can do to a window or a Space.
///
/// Implemented by the app target, which owns the Accessibility API and the
/// WindowServer SPI. Actions reach it through this protocol rather than doing
/// the work themselves, which keeps the action vocabulary (the part with a
/// config format attached to it) free of AppKit and testable against a mock.
@MainActor
public protocol WindowActions: AnyObject {
    /// Move the focused window to `edge`, cycling its fraction if it is
    /// already there.
    func tile(_ edge: WindowEdge)
    /// Native full screen, the green-button behaviour.
    func toggleFullScreen()
    /// Fill the screen's visible frame, or put the window back if it already does.
    func toggleMaximize()
    /// Switch the focused display to its `number`-th desktop, 1-based.
    func activateDesktop(_ number: Int)
    /// Move one desktop left or right on the focused display.
    func stepDesktop(_ offset: Int)
}

/// Where a bound chord ends up. Implemented by the app target, which owns the
/// event tap. The actions themselves stay ignorant of it, which is what lets
/// them be tested against a recording stand-in.
public protocol BindingSink: AnyObject {
    /// Keep the chord in CmdTab's event tap and run this when it fires.
    func registerLocal(chord: Chord, command: any LocalCommand)
    /// Keep the chord in CmdTab's event tap as a switcher trigger.
    func registerSwitcher(chord: Chord, mode: SwitchMode)
}

/// Something CmdTab runs itself when a chord fires.
public protocol LocalCommand: AnyObject, Sendable {
    /// Called straight from the event tap callback, so this must not block.
    @MainActor func run(on host: any WindowActions)
}

public protocol Action: AnyObject, Sendable {
    /// How the action is written in the config, for error messages.
    var name: String { get }
    func bind(_ chord: Chord, into sink: any BindingSink)
}

/// `tile:left` and friends. Repeated presses cycle the fraction, so the
/// direction is the whole parameter: how much of the screen it takes is a
/// function of how many times you have pressed it, not of the config.
public final class TileAction: Action, LocalCommand {
    public let edge: WindowEdge
    public var name: String { "tile:\(edge.rawValue)" }

    public init(edge: WindowEdge) { self.edge = edge }

    public func bind(_ chord: Chord, into sink: any BindingSink) {
        sink.registerLocal(chord: chord, command: self)
    }

    public func run(on host: any WindowActions) { host.tile(edge) }
}

/// `toggle-fullscreen` / `toggle-maximize`. Two shapes of the same idea, so one
/// class with a flag rather than two near-identical ones.
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

/// `switch-desktop:N`, `switch-desktop:previous`, `switch-desktop:next`.
public final class SwitchDesktopAction: Action, LocalCommand {
    public enum Target: Sendable, Equatable {
        /// 1-based, within the desktops of whichever display has focus.
        case desktop(Int)
        /// One desktop along, negative for left. Clamped, not wrapped.
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

/// `shell:<command>` runs through `/bin/sh -c`, so pipes, globs and `~` work
/// the way they do in a terminal.
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

/// `applescript:<source>` runs through `osascript` rather than in-process
/// `NSAppleScript`, which keeps it on the same code path as `shell:` and off
/// the main thread. TCC still attributes the Apple Event to CmdTab, because
/// CmdTab is the responsible process for the child.
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

/// A switcher trigger. Parsed from a `switch-*` section's `trigger` rather than
/// from a `keys` entry, because a switcher is a subsystem with settings rather
/// than a one-shot action, but it is bound through the same sink.
public final class SwitcherAction: Action {
    public let mode: SwitchMode
    public var name: String { mode == .allWindows ? "switch-all-windows" : "switch-current-app" }

    public init(mode: SwitchMode) { self.mode = mode }

    public func bind(_ chord: Chord, into sink: any BindingSink) {
        sink.registerSwitcher(chord: chord, mode: mode)
    }
}

/// Fire and forget. Never waits: the caller is on the event tap callback, and a
/// tap that overruns its budget gets disabled by the system.
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

/// Where this target reports problems. The app target points it at
/// `Diagnostics.note` so config and command failures land in the same ring
/// buffer as everything else. On its own it falls back to `NSLog`.
public enum Log {
    nonisolated(unsafe) private static var sink: (@Sendable (String) -> Void)?

    public static func use(_ sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    public static func note(_ message: String) {
        if let sink { sink(message) } else { NSLog("CmdTab: %@", message) }
    }
}
