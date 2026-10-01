import Carbon.HIToolbox
import XCTest

@testable import CmdTabConfig

final class ChordTests: XCTestCase {
    func testModifiersParseInAnyOrderAndByEveryAlias() throws {
        let canonical = try Chord(parsing: "ctrl-alt-cmd-h")
        XCTAssertEqual(try Chord(parsing: "control-option-command-h"), canonical)
        XCTAssertEqual(try Chord(parsing: "cmd-alt-ctrl-h"), canonical)
        XCTAssertEqual(try Chord(parsing: "CTRL-ALT-CMD-H"), canonical)
        XCTAssertEqual(try Chord(parsing: "opt-ctrl-cmd-h"), canonical)
    }

    func testKeyIsTheLastComponent() throws {
        XCTAssertEqual(try Chord(parsing: "cmd-tab").keyCode, UInt16(kVK_Tab))
        XCTAssertEqual(try Chord(parsing: "cmd-grave").keyCode, UInt16(kVK_ANSI_Grave))
        XCTAssertEqual(try Chord(parsing: "cmd-`").keyCode, UInt16(kVK_ANSI_Grave))
        XCTAssertEqual(try Chord(parsing: "cmd-left").keyCode, UInt16(kVK_LeftArrow))
        XCTAssertEqual(try Chord(parsing: "cmd-f13").keyCode, UInt16(kVK_F13))
        XCTAssertEqual(try Chord(parsing: "cmd-1").keyCode, UInt16(kVK_ANSI_1))
    }

    func testTrailingSeparatorNamesTheMinusKey() throws {
        XCTAssertEqual(try Chord(parsing: "cmd--").keyCode, UInt16(kVK_ANSI_Minus))
        XCTAssertEqual(try Chord(parsing: "cmd--"), try Chord(parsing: "cmd-minus"))
        XCTAssertEqual(try Chord(parsing: "-").keyCode, UInt16(kVK_ANSI_Minus))
    }

    func testNonsenseIsRejectedRatherThanGuessedAt() {
        assertThrows(Chord.ParseError.unknownModifier("hyper")) { try Chord(parsing: "hyper-h") }
        assertThrows(Chord.ParseError.unknownKey("nope")) { try Chord(parsing: "cmd-nope") }
        assertThrows(Chord.ParseError.empty) { try Chord(parsing: "") }
    }

    /// The expected values come from `com.apple.symbolichotkeys` on a real Mac
    /// and from the Apple `DefaultShortcutsTable.xml`.
    func testEncodingMatchesWhatMacOSStores() throws {
        let cases: [(String, UInt16, UInt16, UInt32)] = [
            ("ctrl-alt-cmd-1", 49, 18, 1_835_008),
            ("fn-ctrl-f", 102, 3, 8_650_752),
            ("fn-ctrl-left", 65535, 123, 8_650_752),
            ("fn-ctrl-shift-left", 65535, 123, 8_781_824),
            ("cmd-space", 32, 49, 1_048_576),
            ("ctrl-alt-cmd-period", 46, 47, 1_835_008),
        ]
        for (spec, char, key, mods) in cases {
            let chord = try Chord(parsing: spec)
            XCTAssertEqual(chord.charCode, char, spec)
            XCTAssertEqual(chord.keyCode, key, spec)
            XCTAssertEqual(chord.modifiers.rawValue, mods, spec)
        }
    }

    func testFunctionIsExcludedFromTheTapMatchableSet() throws {
        let chord = try Chord(parsing: "fn-ctrl-alt-cmd-h")
        XCTAssertTrue(chord.modifiers.contains(.function))
        XCTAssertFalse(Chord.Modifiers.tapMatchable.contains(.function))
        XCTAssertEqual(chord.modifiers.intersection(.tapMatchable),
                       [.control, .option, .command])
    }

    func testDisplayRendersModifiersInApplesOrder() throws {
        XCTAssertEqual(try Chord(parsing: "cmd-tab").modifierDisplay, "\u{2318}")
        XCTAssertEqual(try Chord(parsing: "alt-tab").modifierDisplay, "\u{2325}")
        XCTAssertEqual(try Chord(parsing: "ctrl-alt-shift-cmd-y").modifierDisplay,
                       "\u{2303}\u{2325}\u{21E7}\u{2318}")
        XCTAssertEqual(try Chord(parsing: "ctrl-alt-cmd-h").display,
                       "\u{2303}\u{2325}\u{2318}H")
    }

    func testRemovingAModifierLeavesTheKeyAlone() throws {
        let shifted = try Chord(parsing: "shift-cmd-tab")
        XCTAssertEqual(shifted.removing(.shift), try Chord(parsing: "cmd-tab"))
    }
}

func assertThrows<E: Error & Equatable>(_ expected: E, file: StaticString = #filePath,
                                        line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        XCTFail("expected \(expected), nothing was thrown", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
