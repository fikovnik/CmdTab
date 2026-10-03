import CmdTabModel

/// The window list for one traversal.
public enum SwitchMode: Sendable, Equatable {
    case allWindows
    case currentApp
}

/// A parsed action. The app executes these values after the event tap returns.
public enum Action: Sendable, Equatable {
    public enum Desktop: Sendable, Equatable {
        case number(Int)
        case previous
        case next
    }

    case tile(WindowEdge)
    case center
    case toggleFullScreen
    case toggleMaximize
    case desktop(Desktop)
    case shell(String)
    case appleScript(String)
    case switcher(SwitchMode)
}
