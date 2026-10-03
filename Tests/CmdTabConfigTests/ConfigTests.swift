import XCTest
@testable import CmdTabConfig

private func parse(_ json: String) -> Config { Config.parse(Data(json.utf8)) }
private func action(_ config: Config, _ chord: String) throws -> Action? {
    config.bindings[try Chord(parsing: chord)]
}

final class ConfigTests: XCTestCase {
    func testMissingFileAndEmptyObjectUseDefaults() throws {
        let missing = Config.load(from: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for config in [missing, parse("{}")] {
            XCTAssertEqual(config.errors, [])
            XCTAssertEqual(config.menuIcon, .desktopNumber)
            XCTAssertEqual(config.bindings.count, 2)
            XCTAssertEqual(try action(config, "cmd-tab"), .switcher(.allWindows))
            XCTAssertEqual(try action(config, "cmd-grave"), .switcher(.currentApp))
        }
    }

    func testActionsAndCustomTriggerParseTogether() throws {
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
        XCTAssertEqual(config.menuIcon, .literal("⇥"))
        XCTAssertEqual(try action(config, "ctrl-alt-cmd-1"), .desktop(.number(1)))
        XCTAssertEqual(try action(config, "shift-ctrl-alt-cmd-left"), .tile(.left))
        XCTAssertEqual(try action(config, "ctrl-alt-cmd-e"), .shell("open -a Finder ~"))
        XCTAssertEqual(try action(config, "ctrl-alt-cmd-s"), .appleScript("tell app \"Finder\" to activate"))
        XCTAssertEqual(try action(config, "alt-tab"), .switcher(.allWindows))
        XCTAssertNil(try action(config, "cmd-tab"))
        XCTAssertEqual(try action(config, "cmd-grave"), .switcher(.currentApp))
    }

    func testUnknownFieldsAndSectionsProduceErrors() throws {
        let config = parse(#"""
        { "kesy": {}, "menu": { "icons": "x" }, "switch-all-windows": { "triger": "alt-tab" } }
        """#)
        XCTAssertEqual(config.errors.count, 3)
        for text in ["kesy", "icons", "triger"] {
            XCTAssertTrue(config.errors.contains { $0.contains(text) }, "\(config.errors)")
        }
        XCTAssertEqual(try action(config, "cmd-tab"), .switcher(.allWindows))
    }

    func testInvalidEntriesDoNotRemoveValidBindings() throws {
        let config = parse(#"""
        { "keys": {
            "ctrl-h": "tile:left", "hyper-j": "tile:right",
            "ctrl-k": "tile:sideways", "ctrl-l": 42
        } }
        """#)
        XCTAssertEqual(config.errors.count, 3)
        XCTAssertEqual(try action(config, "ctrl-h"), .tile(.left))
        XCTAssertEqual(try action(config, "cmd-tab"), .switcher(.allWindows))
    }

    func testLocalBindingsCannotReplaceForwardOrReverseTriggers() throws {
        for trigger in ["cmd-tab", "shift-cmd-tab"] {
            let config = parse("{\"keys\":{\"\(trigger)\":\"toggle-maximize\"}}")
            XCTAssertEqual(config.errors.count, 1)
            XCTAssertTrue(config.errors[0].contains("already bound"))
            XCTAssertEqual(try action(config, "cmd-tab"), .switcher(.allWindows))
            XCTAssertNil(try action(config, "shift-cmd-tab"))
        }
    }

    func testInvalidTriggersRestoreDefaults() throws {
        for trigger in ["f13", "shift-tab", "shift-cmd-tab", "fn-ctrl-tab", "unknown-tab", "cmd-grave"] {
            let config = parse("{\"switch-all-windows\":{\"trigger\":\"\(trigger)\"}}")
            XCTAssertEqual(config.errors.count, 1, trigger)
            XCTAssertEqual(try action(config, "cmd-tab"), .switcher(.allWindows), trigger)
            XCTAssertEqual(try action(config, "cmd-grave"), .switcher(.currentApp), trigger)
        }
    }

    func testTriggerKeysCanBeSwappedWhenTheyRemainDistinct() throws {
        let config = parse(#"""
        { "switch-all-windows": { "trigger": "alt-grave" },
          "switch-current-app": { "trigger": "ctrl-tab" } }
        """#)
        XCTAssertEqual(config.errors, [])
        XCTAssertEqual(try action(config, "alt-grave"), .switcher(.allWindows))
        XCTAssertEqual(try action(config, "ctrl-tab"), .switcher(.currentApp))
    }

    func testTwoModifiersOnTheSameTriggerKeyStillConflict() throws {
        let config = parse(#"""
        { "switch-all-windows": { "trigger": "alt-tab" },
          "switch-current-app": { "trigger": "ctrl-tab" } }
        """#)
        XCTAssertEqual(config.errors.count, 1)
        XCTAssertEqual(config.bindings, Config.defaults.bindings)
    }

    func testFunctionBindingsAreRejected() throws {
        let config = parse(#"""
        { "keys": { "fn-ctrl-e": "shell:ls" }, "switch-current-app": { "trigger": "fn-ctrl-grave" } }
        """#)
        XCTAssertEqual(config.errors.count, 2)
        XCTAssertTrue(config.errors.allSatisfy { $0.contains("fn cannot be bound") })
        XCTAssertNil(try action(config, "fn-ctrl-e"))
        XCTAssertEqual(try action(config, "cmd-grave"), .switcher(.currentApp))
    }

    func testDuplicateChordAliasesHaveADeterministicResult() throws {
        let config = parse(#"""
        { "keys": { "ctrl-alt-cmd-h": "tile:left", "cmd-alt-ctrl-h": "toggle-maximize" } }
        """#)
        XCTAssertEqual(config.errors.count, 1)
        XCTAssertEqual(try action(config, "ctrl-alt-cmd-h"), .toggleMaximize)
    }

    func testMalformedJSONAndInvalidSectionTypesPreserveSwitchers() throws {
        for json in ["not json", "[]", #"{"keys":"nope"}"#,
                     #"{"switch-all-windows":{"trigger":42}}"#, #"{"menu":{"icon":false}}"#] {
            let config = parse(json)
            XCTAssertFalse(config.errors.isEmpty, json)
            XCTAssertEqual(try action(config, "cmd-tab"), .switcher(.allWindows), json)
            XCTAssertEqual(try action(config, "cmd-grave"), .switcher(.currentApp), json)
        }
    }

    func testUnreadableFileReportsAnError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = Config.load(from: directory)
        XCTAssertEqual(config.errors.count, 1)
        XCTAssertEqual(config.bindings, Config.defaults.bindings)
    }

    func testParsedActionValuesPreserveParameters() throws {
        let cases: [(String, Action)] = [
            ("tile:bottom", .tile(.bottom)), ("tile:center", .center),
            ("toggle-fullscreen", .toggleFullScreen), ("toggle-maximize", .toggleMaximize),
            ("switch-desktop:7", .desktop(.number(7))), ("switch-desktop:16", .desktop(.number(16))),
            ("switch-desktop:previous", .desktop(.previous)), ("switch-desktop:next", .desktop(.next)),
            ("shell: echo a:b", .shell("echo a:b")), ("applescript: beep", .appleScript("beep")),
        ]
        for (spec, expected) in cases { XCTAssertEqual(try Config.action(for: spec), expected, spec) }
    }

    func testActionErrorsIdentifyInvalidParameters() {
        for spec in ["tile:sideways", "tile:", "tile:Left"] {
            XCTAssertThrowsError(try Config.action(for: spec)) { error in
                XCTAssertTrue("\(error)".contains("expected left/right/top/bottom/center"))
            }
        }
        for spec in ["switch-desktop:0", "switch-desktop:17", "switch-desktop:two"] {
            XCTAssertThrowsError(try Config.action(for: spec)) { error in
                XCTAssertTrue("\(error)".contains("expected 1-16, previous or next"))
            }
        }
        for spec in ["shell:", "applescript: \n", "unknown"] {
            XCTAssertThrowsError(try Config.action(for: spec))
        }
    }
}
