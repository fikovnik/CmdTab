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
        let config = Config.parse(Data(#"{"switch-all-windows":{"trigger":"ctrl-alt-tab"}}"#.utf8))
        var state = HotkeyState()
        state.bindings = config.bindings
        let trigger = try Chord(parsing: "ctrl-alt-tab")
        XCTAssertEqual(state.handle(.keyDown, key: trigger.keyCode, modifiers: [.control, .option]),
                       .start(.allWindows, trigger, reversed: false))
        XCTAssertEqual(state.handle(.flagsChanged, key: 0, modifiers: .option),
                       .finish(commit: true, consume: false))
    }
}
