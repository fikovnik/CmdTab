import XCTest
@testable import CmdTabModel

private struct Item: Identifiable {
    let id: Int
}
private let windows = [1, 2, 3, 4].map(Item.init)

final class WindowTraversalTests: XCTestCase {
    func testFirstStepSelectsThePreviousWindowAndReverseSelectsTheLast() {
        var forward = WindowTraversal<Item>()
        var reverse = WindowTraversal<Item>(reversed: true)
        forward.replace(with: windows)
        reverse.replace(with: windows)
        XCTAssertEqual(forward.selected?.id, 2)
        XCTAssertEqual(reverse.selected?.id, 4)
    }

    func testStepsBeforeTheScanAreRetainedAndWrapInBothDirections() {
        var traversal = WindowTraversal<Item>()
        traversal.step(5)
        XCTAssertNil(traversal.windows)
        traversal.replace(with: windows)
        XCTAssertEqual(traversal.selected?.id, 3)
        traversal.step(-9)
        XCTAssertEqual(traversal.selected?.id, 2)
    }

    func testPageMovesStopAtBothBoundaries() {
        var traversal = WindowTraversal<Item>()
        traversal.replace(with: windows)
        traversal.step(20, wrap: false)
        XCTAssertEqual(traversal.selected?.id, 4)
        traversal.step(-20, wrap: false)
        XCTAssertEqual(traversal.selected?.id, 1)
    }

    func testScopeChangeKeepsSelectionByWindowIdentity() {
        var traversal = WindowTraversal<Item>()
        traversal.replace(with: windows)
        traversal.replace(with: [Item(id: 4), Item(id: 2)])
        XCTAssertEqual(traversal.selected?.id, 2)
        XCTAssertEqual(traversal.index, 1)
        traversal.replace(with: [Item(id: 4), Item(id: 3)])
        XCTAssertEqual(traversal.selected?.id, 4)
    }

    func testEmptyListsHaveNoSelectionAndCanBecomeNonempty() {
        var traversal = WindowTraversal<Item>()
        traversal.replace(with: [])
        traversal.step(-1)
        XCTAssertNil(traversal.selected)
        XCTAssertEqual(traversal.index, 0)
        traversal.replace(with: [Item(id: 7)])
        XCTAssertEqual(traversal.selected?.id, 7)
    }
}
