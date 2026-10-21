import Carbon.HIToolbox
import XCTest
@testable import CmdTabConfig

final class HotkeyStateTests: XCTestCase {
    private func keyboard() -> HotkeyState {
        var state = HotkeyState()
        state.bindings = Config.defaults.bindings
        return state
    }

    func testShiftStartsReverseTraversalAndItsReleaseDoesNotCommit() throws {
        var state = keyboard()
        let trigger = try Chord(parsing: "cmd-tab")
        XCTAssertEqual(state.handle(.keyDown, key: trigger.keyCode, modifiers: [.command, .shift]),
                       .start(.allWindows, trigger, reversed: true))
        XCTAssertEqual(state.handle(.flagsChanged, key: 0, modifiers: .command), .pass)
        XCTAssertEqual(state.handle(.flagsChanged, key: 0, modifiers: []), .finish(commit: true, consume: false))
    }

    func testTriggerKeysMoveInBothDirections() {
        var state = keyboard()
        _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command)
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command), .step(1, wrap: true))
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_ANSI_Grave), modifiers: .command), .step(-1, wrap: true))
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_ANSI_Grave), modifiers: [.command, .shift]),
                       .step(1, wrap: true))
    }

    func testCustomSwitcherActionsStartTheirModesAndShareNavigationKeys() throws {
        let config = Config.parse(Data(#"""
        { "keys": { "ctrl-a": "switch-all-windows", "alt-b": "switch-app-windows" } }
        """#.utf8))
        XCTAssertEqual(config.errors, [])
        var state = HotkeyState()
        state.bindings = config.bindings
        let appTrigger = try Chord(parsing: "alt-b")
        let allTrigger = try Chord(parsing: "ctrl-a")

        XCTAssertEqual(state.handle(.keyDown, key: appTrigger.keyCode, modifiers: .option),
                       .start(.currentApp, appTrigger, reversed: false))
        XCTAssertEqual(state.handle(.keyDown, key: allTrigger.keyCode, modifiers: .option),
                       .step(-1, wrap: true))
        XCTAssertEqual(state.handle(.keyDown, key: appTrigger.keyCode, modifiers: .option),
                       .step(1, wrap: true))
        XCTAssertEqual(state.handle(.flagsChanged, key: 0, modifiers: []),
                       .finish(commit: true, consume: false))
        XCTAssertEqual(state.handle(.keyDown, key: allTrigger.keyCode, modifiers: .control),
                       .start(.allWindows, allTrigger, reversed: false))
        XCTAssertEqual(state.handle(.keyDown, key: appTrigger.keyCode, modifiers: .control),
                       .step(-1, wrap: true))
    }

    func testCancellationConsumesItsKeyReleaseAndClearsTheHold() {
        var state = keyboard()
        _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command)
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_Escape), modifiers: .command),
                       .finish(commit: false, consume: true))
        XCTAssertNil(state.hold)
        XCTAssertEqual(state.handle(.keyUp, key: UInt16(kVK_Escape), modifiers: .command), .consume)
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_ANSI_A), modifiers: .command), .pass)
    }

    func testMissedModifierReleaseCommitsAndPassesTheNextKey() {
        var state = keyboard()
        _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command)
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_ANSI_A), modifiers: []),
                       .finish(commit: true, consume: false))
        XCTAssertNil(state.hold)
        XCTAssertEqual(state.handle(.keyUp, key: UInt16(kVK_Tab), modifiers: []), .consume)
    }

    func testLocalActionsConsumeBothKeyEventsAndPassUnboundKeys() throws {
        var state = keyboard()
        let chord = try Chord(parsing: "ctrl-h")
        state.bindings[chord] = .tile(.left)
        XCTAssertEqual(state.handle(.keyDown, key: chord.keyCode, modifiers: .control), .perform(.tile(.left)))
        XCTAssertEqual(state.handle(.keyUp, key: chord.keyCode, modifiers: []), .consume)
        XCTAssertEqual(state.handle(.keyUp, key: UInt16(kVK_ANSI_A), modifiers: []), .pass)
    }

    func testReloadEndsTraversalButStillConsumesTheTriggerRelease() {
        var state = keyboard()
        _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command)
        state.bindings = Config.defaults.bindings
        XCTAssertNil(state.hold)
        XCTAssertEqual(state.handle(.keyUp, key: UInt16(kVK_Tab), modifiers: []), .consume)
    }

    func testNavigationAndImmediateCommit() {
        var state = keyboard()
        _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command)
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_RightArrow), modifiers: .command), .toggleScope)
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_PageDown), modifiers: .command), .step(1, wrap: false))
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_PageUp), modifiers: .command), .step(-1, wrap: false))
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_Return), modifiers: .command),
                       .finish(commit: true, consume: true))
    }

    func testMultiModifierTriggerCommitsWhenEitherModifierIsReleased() throws {
        let config = Config.parse(Data(#"{"keys":{"ctrl-alt-tab":"switch-all-windows"}}"#.utf8))
        var state = HotkeyState()
        state.bindings = config.bindings
        let trigger = try Chord(parsing: "ctrl-alt-tab")
        XCTAssertEqual(state.handle(.keyDown, key: trigger.keyCode, modifiers: [.control, .option]),
                       .start(.allWindows, trigger, reversed: false))
        XCTAssertEqual(state.handle(.flagsChanged, key: 0, modifiers: .option),
                       .finish(commit: true, consume: false))
    }

    func testFilterInputWaitsForTheHUDAndRequiresAnActiveTraversal() {
        var state = keyboard()
        let key = UInt16(kVK_ANSI_A)
        XCTAssertEqual(state.handle(.keyDown, key: key, modifiers: .command,
                                    text: "a", acceptsFilterInput: true), .pass)
        _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command)
        XCTAssertEqual(state.handle(.keyDown, key: key, modifiers: .command, text: "a"), .consume)
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_Delete), modifiers: .command), .consume)
        XCTAssertEqual(state.handle(.keyDown, key: key, modifiers: .command,
                                    text: "a", acceptsFilterInput: true), .appendFilterText("a"))
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_Delete), modifiers: .command,
                                    acceptsFilterInput: true), .deleteFilterCharacter)
    }

    func testPrintableTextIncludesPeriodSpacesShiftAndJoinedEmoji() {
        var state = keyboard()
        _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command)
        for (key, text) in [(kVK_ANSI_Period, "."), (kVK_Space, " "), (kVK_ANSI_A, "É👩‍💻")] {
            XCTAssertEqual(state.handle(.keyDown, key: UInt16(key), modifiers: [.command, .shift],
                                        text: text, acceptsFilterInput: true), .appendFilterText(text))
        }
        XCTAssertNotNil(state.hold)
    }

    func testControlAndFunctionCharactersDoNotEnterTheQuery() {
        var state = keyboard()
        _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command)
        for text: String? in [nil, "", "\t", "\n", "\u{0}", "\u{2028}", "\u{F700}", "a\u{F704}"] {
            XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_F1), modifiers: .command,
                                        text: text, acceptsFilterInput: true), .consume)
        }
    }

    func testNavigationAndConfiguredLetterTriggersTakePrecedenceOverText() {
        var state = HotkeyState()
        state.bindings = Config.parse(Data(#"{"keys":{"cmd-a":"switch-all-windows"}}"#.utf8)).bindings
        _ = state.handle(.keyDown, key: UInt16(kVK_ANSI_A), modifiers: .command)
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_ANSI_A), modifiers: .command,
                                    text: "a", acceptsFilterInput: true), .step(1, wrap: true))
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_DownArrow), modifiers: .command,
                                    text: "\u{F701}", acceptsFilterInput: true), .step(1, wrap: true))
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_RightArrow), modifiers: .command,
                                    acceptsFilterInput: true), .toggleScope)
    }

    func testFilterKeysStillConsumeTheirReleasesAfterEverySessionEnding() {
        for ending in ["commit", "cancel", "reload"] {
            var state = keyboard()
            _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: .command)
            _ = state.handle(.keyDown, key: UInt16(kVK_ANSI_A), modifiers: .command,
                             text: "a", acceptsFilterInput: true)
            _ = state.handle(.keyDown, key: UInt16(kVK_Delete), modifiers: .command, acceptsFilterInput: true)
            switch ending {
            case "commit":
                XCTAssertEqual(state.handle(.flagsChanged, key: 0, modifiers: []),
                               .finish(commit: true, consume: false))
            case "cancel":
                XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_Escape), modifiers: .command),
                               .finish(commit: false, consume: true))
            default: state.bindings = Config.defaults.bindings
            }
            XCTAssertEqual(state.handle(.keyUp, key: UInt16(kVK_ANSI_A), modifiers: []), .consume)
            XCTAssertEqual(state.handle(.keyUp, key: UInt16(kVK_Delete), modifiers: []), .consume)
        }
    }

    func testCurrentAppAndCustomModifierSwitchersAcceptFilterText() {
        var state = keyboard()
        _ = state.handle(.keyDown, key: UInt16(kVK_ANSI_Grave), modifiers: .command)
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_ANSI_S), modifiers: .command,
                                    text: "s", acceptsFilterInput: true), .appendFilterText("s"))
        state.bindings = Config.parse(Data(#"{"keys":{"ctrl-alt-tab":"switch-all-windows"}}"#.utf8)).bindings
        _ = state.handle(.keyDown, key: UInt16(kVK_Tab), modifiers: [.control, .option])
        XCTAssertEqual(state.handle(.keyDown, key: UInt16(kVK_ANSI_S), modifiers: [.control, .option],
                                    text: "s", acceptsFilterInput: true), .appendFilterText("s"))
    }
}
