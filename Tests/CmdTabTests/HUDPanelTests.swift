import AppKit
import CmdTabModel
import XCTest
@testable import CmdTab

final class HUDPanelTests: XCTestCase {
    @MainActor
    func testEveryMatchHasYellowBackgroundAndBlackTextOnEitherSelectionState() async {
        let window = Window(id: 1, pid: 1, appName: "Editor", icon: nil, title: "EDITOR main.swift editor")
        let view = HUDView()
        view.search = WindowSearch("editor")
        for selected in [false, true] {
            let text = view.title(window, selected: selected)
            var ranges: [NSRange] = []
            text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let color = value as? NSColor {
                    XCTAssertEqual(color, .yellow)
                    ranges.append(range)
                }
            }
            XCTAssertEqual(ranges, [NSRange(location: 0, length: 6), NSRange(location: 8, length: 6),
                                    NSRange(location: 26, length: 6)])
            for range in ranges {
                for index in range.location..<NSMaxRange(range) {
                    XCTAssertEqual(text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, .black)
                }
            }
            XCTAssertNil(text.attribute(.backgroundColor, at: 6, effectiveRange: nil))
            XCTAssertEqual(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                           NSFont.systemFont(ofSize: 13, weight: .semibold))
            XCTAssertEqual(text.attribute(.font, at: 8, effectiveRange: nil) as? NSFont,
                           NSFont.systemFont(ofSize: 13))
        }
    }

    @MainActor
    func testTitleHighlightOffsetsIncludeUnicodeAppNameAndSeparator() async {
        let window = Window(id: 1, pid: 1, appName: "😀 Editor", icon: nil, title: "😀 editor")
        let view = HUDView()
        view.search = WindowSearch("EDITOR")
        let text = view.title(window)
        for index in [3, 14] {
            var range = NSRange()
            XCTAssertEqual(text.attribute(.backgroundColor, at: index, effectiveRange: &range) as? NSColor, .yellow)
            XCTAssertEqual(range, NSRange(location: index, length: 6))
        }
        view.search = WindowSearch("editor  😀")
        let acrossFields = view.title(window)
        XCTAssertNil(acrossFields.attribute(.backgroundColor, at: 3, effectiveRange: nil))
    }

    @MainActor
    func testEmptyQueryAndEmptyTitlesDoNotAddHighlightAttributes() async {
        let view = HUDView()
        let window = Window(id: 1, pid: 1, appName: "Editor", icon: nil)
        let text = view.title(window)
        XCTAssertEqual(text.string, "Editor")
        XCTAssertNil(text.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        view.search = WindowSearch("edit")
        XCTAssertEqual(view.title(window).attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor, .yellow)
    }

    @MainActor
    func testOpenHUDCanShowNoMatchesAndRestoreItsRows() async throws {
        guard CGSessionCopyCurrentDictionary() != nil else {
            throw XCTSkip("Overlay windows need a WindowServer session")
        }
        _ = NSApplication.shared
        let hud = HUDPanel()
        defer { hud.hide() }
        let window = Window(id: 1, pid: 1, appName: "Editor", icon: nil, title: "main.swift")
        hud.show([window], selected: 0, scope: "All Spaces", search: WindowSearch("swift"))
        let full = try XCTUnwrap(hud.anchor)
        hud.show([], selected: 0, scope: "All Spaces", search: WindowSearch("swiftx"))
        let empty = try XCTUnwrap(hud.anchor)
        XCTAssertLessThan(empty.frame.height, full.frame.height)
        hud.show([window], selected: 0, scope: "All Spaces", search: WindowSearch("swift"))
        XCTAssertEqual(hud.anchor?.frame.height, full.frame.height)
    }
}
