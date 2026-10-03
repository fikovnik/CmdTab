import XCTest

@testable import CmdTabModel

/// `CGSCopyManagedDisplaySpaces` as recorded on the development machine:
/// display 1 has seven desktops and shows Space 7 (desktop 6), display 2 has
/// one desktop. `withFullScreen` adds the full-screen Space 99 after desktop 3.
private enum Fixture {
    static let display1 = "361EA19E-2B84-4B64-9FCA-5FE5CCC6B00C"
    static let display2 = "DEF21301-D53F-477B-92F2-9C695BAF0396"

    static func space(_ id: Int, type: Int = 0) -> [String: Any] {
        ["id64": id, "ManagedSpaceID": id, "type": type, "uuid": ""]
    }

    static func raw(display1Spaces: [[String: Any]]) -> [[String: Any]] {
        [
            ["Current Space": space(7), "Display Identifier": display1, "Spaces": display1Spaces],
            ["Current Space": space(282), "Display Identifier": display2, "Spaces": [space(282)]],
        ]
    }

    static let recorded = SpaceLayout(managedDisplaySpaces: raw(display1Spaces:
        [space(1), space(3), space(4), space(5), space(6), space(7), space(8)]))

    static let withFullScreen = SpaceLayout(managedDisplaySpaces: raw(display1Spaces:
        [space(1), space(3), space(4), space(99, type: 4), space(5), space(6), space(7), space(8)]))
}

final class SpaceLayoutParsingTests: XCTestCase {
    func testReadsBothDisplaysInOrder() {
        let layout = Fixture.recorded
        XCTAssertEqual(layout.displays.map(\.identifier), [Fixture.display1, Fixture.display2])
        XCTAssertEqual(layout.displays[0].spaces.map(\.id), [1, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(layout.displays.map(\.currentSpace), [7, 282])
    }

    func testMarksNonZeroTypeAsFullScreen() {
        let spaces = Fixture.withFullScreen.displays[0].spaces
        XCTAssertEqual(spaces.filter(\.isFullScreen).map(\.id), [99])
    }

    func testVisibleSpacesAreTheCurrentSpaceOfEachDisplay() {
        XCTAssertEqual(Fixture.recorded.visibleSpaces, [7, 282])
    }

    func testEmptyInputGivesNoDisplays() {
        XCTAssertEqual(SpaceLayout(managedDisplaySpaces: []).displays, [])
    }
}

final class SpaceLayoutLookupTests: XCTestCase {
    func testDesktopNumbersSkipFullScreenSpaces() {
        let layout = Fixture.withFullScreen
        XCTAssertEqual(layout.desktopNumber(of: 4), 3)
        XCTAssertNil(layout.desktopNumber(of: 99))
        XCTAssertEqual(layout.desktopNumber(of: 5), 4)
        XCTAssertEqual(layout.desktopNumber(of: 282), 1)
    }

    func testLabelsNameTheDisplayWhenThereAreTwo() {
        let layout = Fixture.withFullScreen
        XCTAssertEqual(layout.label(of: 1), "Desktop 1 · Display 1")
        XCTAssertEqual(layout.label(of: 99), "Full Screen · Display 1")
        XCTAssertEqual(layout.label(of: 282), "Desktop 1 · Display 2")
        XCTAssertNil(layout.label(of: 12345))
    }

    func testLabelsOmitTheDisplayWhenThereIsOne() {
        let single = SpaceLayout(displays: [Fixture.recorded.displays[0]])
        XCTAssertEqual(single.label(of: 3), "Desktop 2")
    }

    func testOrderPutsDisplaysInSequence() {
        XCTAssertEqual(Fixture.recorded.order(of: 1), 0)
        XCTAssertEqual(Fixture.recorded.order(of: 282), 7)
    }

    func testFindsTheDisplayOfASpace() {
        XCTAssertEqual(Fixture.recorded.display(containing: 282)?.identifier, Fixture.display2)
        XCTAssertNil(Fixture.recorded.display(containing: 12345))
    }

    func testFindsADisplayByIdentifier() {
        XCTAssertEqual(Fixture.recorded.display(identifier: Fixture.display2)?.currentSpace, 282)
        XCTAssertNil(Fixture.recorded.display(identifier: nil))
    }

    func testSharedSpacesDisplayMatchesEveryIdentifier() {
        let shared = SpaceLayout(displays: [
            .init(identifier: "Main", spaces: [.init(id: 1, isFullScreen: false)], currentSpace: 1),
        ])
        XCTAssertEqual(shared.display(identifier: Fixture.display1)?.identifier, "Main")
    }
}

final class SpaceLayoutSwipeTests: XCTestCase {
    private var display1: SpaceLayout.Display { Fixture.withFullScreen.displays[0] }

    func testSwipesToADesktopCountTheFullScreenSpaceBetween() {
        // Space 7 is at index 6 and desktop 1 is at index 0.
        XCTAssertEqual(display1.swipes(toDesktop: 1), -6)
        // Desktop 4 is Space 5, at index 4, after the full-screen Space.
        XCTAssertEqual(display1.swipes(toDesktop: 4), -2)
        XCTAssertEqual(display1.swipes(toDesktop: 7), 1)
    }

    func testSwipesToTheCurrentDesktopAreZero() {
        XCTAssertEqual(display1.swipes(toDesktop: 6), 0)
    }

    func testSwipesToAMissingDesktopAreNil() {
        XCTAssertNil(display1.swipes(toDesktop: 0))
        XCTAssertNil(display1.swipes(toDesktop: 8))
    }

    func testSwipesToASpaceIncludeFullScreenSpaces() {
        XCTAssertEqual(display1.swipes(to: 99), -3)
        XCTAssertNil(display1.swipes(to: 282))
    }

    func testSwipesByAnOffsetStopAtTheEnds() {
        XCTAssertEqual(display1.swipes(by: 1), 1)
        XCTAssertEqual(display1.swipes(by: 5), 1)
        XCTAssertEqual(display1.swipes(by: -10), -6)
    }

    func testExtremeOffsetsAndDesktopNumbersDoNotOverflow() {
        XCTAssertEqual(display1.swipes(by: Int.max), 1)
        XCTAssertEqual(display1.swipes(by: Int.min), -6)
        XCTAssertNil(display1.swipes(toDesktop: Int.min))
        XCTAssertNil(display1.swipes(toDesktop: Int.max))
    }

    func testSwipesWithoutACurrentSpaceAreNil() {
        let unknown = SpaceLayout.Display(identifier: "x", spaces: display1.spaces, currentSpace: nil)
        XCTAssertNil(unknown.swipes(toDesktop: 1))
        XCTAssertNil(unknown.swipes(by: 1))
    }
}
