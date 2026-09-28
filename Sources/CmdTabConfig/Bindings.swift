/// The chord table CmdTab's own event tap matches against.
///
/// Every configured binding lands here, tiling and desktop chords included:
/// CmdTab implements those itself rather than registering them with the
/// system. The two halves differ in what the tap does next. A `switchers`
/// chord opens a cycle, after which the tap owns the keyboard until the
/// trigger's modifiers are released. A `locals` chord fires once and is
/// swallowed. A chord in neither table falls through untouched.
public struct Bindings: Sendable {
    public var switchers: [Chord: SwitchMode] = [:]
    public var locals: [Chord: any LocalCommand] = [:]

    public init() {}
}
