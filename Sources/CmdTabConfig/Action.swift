import CmdTabModel

public enum SwitchMode: Sendable, Equatable {
    case allWindows
    case currentApp
}

/// Switcher actions start a traversal. Other actions run after the event tap returns.
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
    case moveToDisplay(DisplayDirection)
    case desktop(Desktop)
    case shell(String)
    case appleScript(String)
    case switcher(SwitchMode)
}
