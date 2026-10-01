import CmdTabConfig

/// Puts the bindings of a parsed config into the chord table of the event tap.
///
/// Not `@MainActor`, so that it can conform to `BindingSink` and the actions do
/// not need to know about isolation. It changes only its own fields.
final class ConfigInstaller: BindingSink {
    private(set) var bindings = Bindings()

    func registerLocal(chord: Chord, command: any LocalCommand) {
        bindings.locals[chord] = command
    }

    func registerSwitcher(chord: Chord, mode: SwitchMode) {
        bindings.switchers[chord] = mode
    }
}
