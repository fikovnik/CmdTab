/// The chord table that the CmdTab event tap matches.
///
/// All configured bindings go into this table, also the tile and desktop
/// chords. CmdTab does these actions itself and does not register them with
/// the system. A `switchers` chord starts a cycle. Then the tap keeps the
/// keyboard until the user releases the trigger modifiers. A `locals` chord
/// runs one time, and no other app gets the key event. The tap does not change
/// other chords.
public struct Bindings: Sendable {
    public var switchers: [Chord: SwitchMode] = [:]
    public var locals: [Chord: any LocalCommand] = [:]

    public init() {}
}
