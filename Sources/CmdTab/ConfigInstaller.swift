import CmdTabConfig

/// Collects a parsed config into the chord table the event tap matches against.
///
/// Not `@MainActor`, so that it can satisfy `BindingSink` without the actions
/// needing to know about isolation. It touches nothing but its own fields.
final class ConfigInstaller: BindingSink {
    private(set) var bindings = Bindings()

    func registerLocal(chord: Chord, command: any LocalCommand) {
        bindings.locals[chord] = command
    }

    func registerSwitcher(chord: Chord, mode: SwitchMode) {
        bindings.switchers[chord] = mode
    }
}
