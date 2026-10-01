import XCTest

@testable import CmdTabConfig

/// Stands in for the app target, which is where the real sink lives.
final class RecordingSink: BindingSink {
    var locals: [(chord: Chord, command: any LocalCommand)] = []
    var switchers: [(chord: Chord, mode: SwitchMode)] = []

    func registerLocal(chord: Chord, command: any LocalCommand) {
        locals.append((chord, command))
    }
    func registerSwitcher(chord: Chord, mode: SwitchMode) {
        switchers.append((chord, mode))
    }
}

/// Records what the app target would have been asked to do.
@MainActor
final class RecordingHost: WindowActions {
    var tiled: [WindowEdge] = []
    var centered = 0
    var fullScreenToggles = 0
    var maximizeToggles = 0
    var desktops: [Int] = []
    var steps: [Int] = []

    func tile(_ edge: WindowEdge) { tiled.append(edge) }
    func center() { centered += 1 }
    func toggleFullScreen() { fullScreenToggles += 1 }
    func toggleMaximize() { maximizeToggles += 1 }
    func activateDesktop(_ number: Int) { desktops.append(number) }
    func stepDesktop(_ offset: Int) { steps.append(offset) }
}

private func parse(_ json: String) -> Config {
    Config.parse(Data(json.utf8))
}

private func binding(_ config: Config, _ spec: String) -> Binding? {
    guard let chord = try? Chord(parsing: spec) else { return nil }
    return config.bindings.first { $0.chord == chord }
}

final class ActionTests: XCTestCase {
    func testOnlyTheTogglesAreBareNames() throws {
        XCTAssertEqual(Config.builtins.count, 2)
        for name in ["toggle-fullscreen", "toggle-maximize",
                     "tile:left", "tile:right", "tile:top", "tile:bottom",
                     "switch-desktop:1", "switch-desktop:16",
                     "switch-desktop:previous", "switch-desktop:next"] {
            XCTAssertNoThrow(try Config.action(for: name), name)
        }
    }

    func testEachPrefixProducesItsOwnClass() throws {
        XCTAssertTrue(try Config.action(for: "tile:left") is TileAction)
        XCTAssertTrue(try Config.action(for: "tile:center") is CenterAction)
        XCTAssertTrue(try Config.action(for: "toggle-maximize") is ToggleAction)
        XCTAssertTrue(try Config.action(for: "switch-desktop:3") is SwitchDesktopAction)
        XCTAssertTrue(try Config.action(for: "shell:open -a Finder") is ShellAction)
        XCTAssertTrue(try Config.action(for: "applescript:beep") is AppleScriptAction)
    }

    func testActionsCarryTheRightPayload() throws {
        XCTAssertEqual((try Config.action(for: "tile:bottom") as? TileAction)?.edge, .bottom)
        XCTAssertEqual((try Config.action(for: "toggle-fullscreen") as? ToggleAction)?.kind,
                       .fullscreen)
        XCTAssertEqual((try Config.action(for: "switch-desktop:7") as? SwitchDesktopAction)?.target,
                       .desktop(7))
        XCTAssertEqual((try Config.action(for: "switch-desktop:previous")
                            as? SwitchDesktopAction)?.target, .step(-1))
        XCTAssertEqual((try Config.action(for: "switch-desktop:next")
                            as? SwitchDesktopAction)?.target, .step(1))
    }

    /// The name is what a duplicate-chord error prints, so it has to round-trip
    /// back to the spelling the config used.
    func testNamesRoundTripToTheConfigSpelling() throws {
        for spec in ["tile:left", "tile:bottom", "tile:center", "toggle-maximize",
                     "switch-desktop:9", "switch-desktop:previous",
                     "switch-desktop:next"] {
            XCTAssertEqual(try Config.action(for: spec).name, spec)
        }
    }

    func testActionsAreFreshInstancesNotSharedOnes() throws {
        for spec in ["toggle-maximize", "tile:left", "switch-desktop:2"] {
            let a = try Config.action(for: spec)
            let b = try Config.action(for: spec)
            XCTAssertFalse(a === b, spec)
        }
    }

    func testSpaceAfterThePrefixIsTolerated() throws {
        XCTAssertEqual((try Config.action(for: "shell: open -a Finder") as? ShellAction)?.command,
                       "open -a Finder")
        XCTAssertEqual((try Config.action(for: "tile: left") as? TileAction)?.edge, .left)
    }

    func testUnknownAndEmptySpecsAreErrors() {
        for spec in ["left-half", "desktop-1", "space-previous", "tile-left"] {
            assertThrows(Config.ActionError.unknownAction(spec)) {
                _ = try Config.action(for: spec)   // the old, removed names
            }
        }
        assertThrows(Config.ActionError.emptyCommand("shell")) {
            _ = try Config.action(for: "shell:")
        }
    }

    /// A known action with a parameter that names nothing reports what it
    /// wanted, rather than the bare "unknown action" a typo used to get.
    func testBadParametersSayWhatWasExpected() {
        for value in ["sideways", "", "Left"] {
            assertThrows(Config.ActionError.badParameter("tile", value,
                                                         "left/right/top/bottom/center")) {
                _ = try Config.action(for: "tile:\(value)")
            }
        }
        for value in ["0", "17", "two", ""] {
            assertThrows(Config.ActionError.badParameter("switch-desktop", value,
                                                         "1-16, previous or next")) {
                _ = try Config.action(for: "switch-desktop:\(value)")
            }
        }
        XCTAssertEqual("\(Config.ActionError.badParameter("tile", "sideways", "left/right/top/bottom/center"))",
                       "tile: expected left/right/top/bottom/center, got \"sideways\"")
    }

    func testBindRoutesEveryActionThroughTheSink() throws {
        let sink = RecordingSink()
        let chord = try Chord(parsing: "shift-ctrl-alt-cmd-left")

        TileAction(edge: .left).bind(chord, into: sink)
        ToggleAction(kind: .maximize).bind(chord, into: sink)
        SwitchDesktopAction(target: .desktop(2)).bind(chord, into: sink)
        ShellAction(command: "ls").bind(chord, into: sink)
        AppleScriptAction(source: "beep").bind(chord, into: sink)
        SwitcherAction(mode: .currentApp).bind(chord, into: sink)

        XCTAssertEqual(sink.locals.count, 5)
        XCTAssertEqual(sink.switchers.count, 1)
        XCTAssertEqual(sink.switchers.first?.mode, .currentApp)
    }

    @MainActor
    func testRunReachesTheHostWithTheRightRequest() {
        let host = RecordingHost()

        TileAction(edge: .top).run(on: host)
        TileAction(edge: .right).run(on: host)
        ToggleAction(kind: .fullscreen).run(on: host)
        ToggleAction(kind: .maximize).run(on: host)
        SwitchDesktopAction(target: .desktop(4)).run(on: host)
        SwitchDesktopAction(target: .step(-1)).run(on: host)

        XCTAssertEqual(host.tiled, [.top, .right])
        XCTAssertEqual(host.fullScreenToggles, 1)
        XCTAssertEqual(host.maximizeToggles, 1)
        XCTAssertEqual(host.desktops, [4])
        XCTAssertEqual(host.steps, [-1])
    }

    func testActionNamesRoundTripToTheirConfigSpelling() throws {
        for name in Config.builtins.keys {
            XCTAssertEqual(try Config.action(for: name).name, name)
        }
    }
}

final class ConfigFileTests: XCTestCase {
    func testNoFileBehavesExactlyAsBeforeThereWasOne() {
        let config = Config.load(from: URL(fileURLWithPath: "/nonexistent/cmdtab.json"))
        XCTAssertEqual(config.errors, [])
        XCTAssertEqual(config.menuIcon, .desktopNumber)
        XCTAssertEqual(config.bindings.count, 2)
        XCTAssertTrue(binding(config, "cmd-tab")?.action is SwitcherAction)
        XCTAssertTrue(binding(config, "cmd-grave")?.action is SwitcherAction)
    }

    func testEmptyObjectIsTheSameAsNoFile() {
        let config = parse("{}")
        XCTAssertEqual(config.errors, [])
        XCTAssertEqual(config.menuIcon, .desktopNumber)
        XCTAssertEqual(config.bindings.count, 2)
    }

    func testTheThreeFamiliesParseTogether() throws {
        let config = parse(#"""
        {
          "keys": {
            "ctrl-alt-cmd-1": "switch-desktop:1",
            "shift-ctrl-alt-cmd-left": "tile:left",
            "ctrl-alt-cmd-e": "shell:open -a Finder ~",
            "ctrl-alt-cmd-s": "applescript:tell app \"Finder\" to activate"
          },
          "switch-all-windows": { "trigger": "alt-tab" },
          "menu": { "icon": "⇥" }
        }
        """#)
        XCTAssertEqual(config.errors, [])
        XCTAssertEqual(config.menuIcon, .literal("\u{21E5}"))

        XCTAssertEqual((binding(config, "ctrl-alt-cmd-1")?.action as? SwitchDesktopAction)?.target,
                       .desktop(1))
        XCTAssertEqual((binding(config, "shift-ctrl-alt-cmd-left")?.action as? TileAction)?.edge,
                       .left)
        XCTAssertEqual((binding(config, "ctrl-alt-cmd-e")?.action as? ShellAction)?.command,
                       "open -a Finder ~")
        XCTAssertTrue(binding(config, "ctrl-alt-cmd-s")?.action is AppleScriptAction)

        // The overridden switcher moved. The unmentioned one kept its default.
        XCTAssertEqual((binding(config, "alt-tab")?.action as? SwitcherAction)?.mode, .allWindows)
        XCTAssertNil(binding(config, "cmd-tab"))
        XCTAssertEqual((binding(config, "cmd-grave")?.action as? SwitcherAction)?.mode, .currentApp)
    }

    func testMisspelledSectionOrFieldIsReportedNotIgnored() {
        let config = parse(#"""
        { "kesy": {}, "menu": { "icons": "x" }, "switch-all-windows": { "triger": "alt-tab" } }
        """#)
        XCTAssertTrue(config.errors.contains { $0.contains("unknown section \"kesy\"") },
                      "\(config.errors)")
        XCTAssertTrue(config.errors.contains { $0.contains("unknown field \"icons\" in menu") },
                      "\(config.errors)")
        XCTAssertTrue(config.errors.contains { $0.contains("unknown field \"triger\"") },
                      "\(config.errors)")
        // ...and the switcher still falls back to its default trigger.
        XCTAssertTrue(binding(config, "cmd-tab")?.action is SwitcherAction)
    }

    func testOneBadEntryCostsOnlyItself() {
        let config = parse(#"""
        {
          "keys": {
            "ctrl-alt-cmd-h": "tile:left",
            "hyper-j": "tile:right",
            "ctrl-alt-cmd-k": "tile-sideways",
            "ctrl-alt-cmd-l": 42
          }
        }
        """#)
        XCTAssertEqual(config.errors.count, 3, "\(config.errors)")
        XCTAssertNotNil(binding(config, "ctrl-alt-cmd-h"))
        // The switcher defaults survive a broken keys table.
        XCTAssertNotNil(binding(config, "cmd-tab"))
    }

    /// Now that CmdTab matches every chord itself, `fn` is unusable
    /// everywhere rather than only outside the system-handled actions.
    func testFunctionIsRefusedEverywhere() {
        let config = parse(#"""
        {
          "keys": { "fn-ctrl-e": "shell:ls", "fn-ctrl-f": "toggle-maximize" },
          "switch-current-app": { "trigger": "fn-ctrl-grave" }
        }
        """#)
        XCTAssertEqual(config.errors.count, 3, "\(config.errors)")
        XCTAssertTrue(config.errors.allSatisfy { $0.contains("fn cannot be bound") })
        XCTAssertNil(binding(config, "fn-ctrl-f"))
        // The switcher falls back to its default, so the keyboard still works.
        XCTAssertTrue(binding(config, "cmd-grave")?.action is SwitcherAction)
    }

    func testSwitcherTriggerWithoutModifiersIsRefused() {
        let config = parse(#"{ "switch-all-windows": { "trigger": "f13" } }"#)
        XCTAssertEqual(config.errors.count, 1, "\(config.errors)")
        XCTAssertTrue(config.errors[0].contains("needs at least one of"))
        XCTAssertNil(binding(config, "f13"))
    }

    func testTwoNamesForOneChordIsAConflictNotACoinToss() {
        let config = parse(#"""
        { "keys": { "ctrl-alt-cmd-h": "tile:left", "cmd-alt-ctrl-h": "toggle-maximize" } }
        """#)
        XCTAssertEqual(config.errors.count, 1, "\(config.errors)")
        XCTAssertTrue(config.errors[0].contains("already bound to"))
        // Exactly one of the two spellings wins. Which one is not interesting,
        // only that the chord is bound once.
        let chord = try? Chord(parsing: "ctrl-alt-cmd-h")
        XCTAssertEqual(config.bindings.filter { $0.chord == chord }.count, 1)
    }

    func testKeysChordMayNotStealTheSwitchersTrigger() {
        let config = parse(#"{ "keys": { "cmd-tab": "toggle-maximize" } }"#)
        XCTAssertEqual(config.errors.count, 1, "\(config.errors)")
        XCTAssertTrue(config.errors[0].contains("already bound to"))
    }

    func testMalformedJSONAndWrongTypesDegradeToDefaults() {
        XCTAssertEqual(parse("not json").errors, ["not a JSON object"])
        XCTAssertEqual(parse("[]").errors, ["not a JSON object"])
        XCTAssertEqual(parse("not json").bindings.count, 2)
        XCTAssertTrue(parse(#"{ "keys": "nope" }"#).errors
            .contains { $0.contains("keys: must be an object") })
    }
}
