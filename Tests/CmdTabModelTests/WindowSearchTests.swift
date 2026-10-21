import XCTest
@testable import CmdTabModel

final class WindowSearchTests: XCTestCase {
    func testMatchesEitherFieldAnywhereIgnoringCase() {
        let search = WindowSearch("edit")
        XCTAssertTrue(search.matches(appName: "TextEdit", title: "Untitled"))
        XCTAssertTrue(search.matches(appName: "Browser", title: "How to EDIT a file"))
        XCTAssertFalse(search.matches(appName: "Terminal", title: "Build output"))
        XCTAssertFalse(WindowSearch("edit  file").matches(appName: "TextEdit", title: "file"))
    }

    func testSpacesAndPunctuationAreLiteralAndAccentsRemainDistinct() {
        let search = WindowSearch("main.swift — ")
        XCTAssertTrue(search.matches(appName: "Editor", title: "src/main.swift — CmdTab"))
        XCTAssertFalse(search.matches(appName: "Editor", title: "src/mainXswift — CmdTab"))
        XCTAssertFalse(WindowSearch("cafe").matches(appName: "Café", title: ""))
        XCTAssertTrue(WindowSearch("CAFÉ").matches(appName: "Café", title: ""))
    }

    func testEmptyQueryMatchesEveryWindowWithoutHighlightRanges() {
        let search = WindowSearch()
        XCTAssertTrue(search.matches(appName: "", title: ""))
        XCTAssertTrue(search.matches(appName: "Terminal", title: "Build"))
        XCTAssertEqual(search.ranges(in: "Terminal"), [])
        XCTAssertEqual(WindowSearch("x").ranges(in: ""), [])
    }

    func testFindsAllOccurrencesIncludingOverlaps() {
        XCTAssertEqual(WindowSearch("edit").ranges(in: "Edit EDIT editor"), [
            NSRange(location: 0, length: 4),
            NSRange(location: 5, length: 4),
            NSRange(location: 10, length: 4),
        ])
        XCTAssertEqual(WindowSearch("ana").ranges(in: "banana"), [
            NSRange(location: 1, length: 3), NSRange(location: 3, length: 3),
        ])
    }

    func testRangesUseOriginalUTF16OffsetsAndCanonicalUnicode() {
        XCTAssertEqual(WindowSearch("café").ranges(in: "😀 Cafe\u{301}"), [NSRange(location: 3, length: 5)])
        XCTAssertEqual(WindowSearch("👩‍💻").ranges(in: "Go 👩‍💻!"), [NSRange(location: 3, length: 5)])
    }

    func testBackspaceRemovesOneWholeCharacterAndStopsAtEmpty() {
        var search = WindowSearch("a")
        search.append("e\u{301}👩‍💻")
        search.deleteLastCharacter()
        XCTAssertEqual(search.query, "ae\u{301}")
        search.deleteLastCharacter()
        XCTAssertEqual(search.query, "a")
        search.deleteLastCharacter()
        search.deleteLastCharacter()
        XCTAssertEqual(search.query, "")
    }
}
