import XCTest

@testable import CmdTabConfig

/// The real geometry of the machine this was built on: a 2560x1440 main
/// display with a 30pt menu bar, plus a rotated portrait display sitting to its
/// left and offset downward. The portrait screen is the one that catches
/// coordinate-conversion mistakes, because its AppKit origin is negative on
/// both axes and its top edge is *above* the main display's.
private enum Fixture {
    static let primaryMaxY: CGFloat = 1440

    static let mainAppKitFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    static let mainAppKitVisible = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    static let portraitAppKitFrame = CGRect(x: -1440, y: -580, width: 1440, height: 2560)

    /// In AX coordinates.
    static var mainVisible: CGRect { Layout.flip(mainAppKitVisible, primaryMaxY: primaryMaxY) }
    static var portrait: CGRect { Layout.flip(portraitAppKitFrame, primaryMaxY: primaryMaxY) }
}

final class FlipTests: XCTestCase {
    func testMainDisplayVisibleFrameLandsUnderTheMenuBar() {
        // visibleFrame excludes the 30pt menu bar, which is at the *top*, so in
        // top-left coordinates the rect must start at y=30, not y=0.
        XCTAssertEqual(Fixture.mainVisible, CGRect(x: 0, y: 30, width: 2560, height: 1410))
    }

    func testMainDisplayFullFrameIsUnchangedByTheFlip() {
        XCTAssertEqual(Layout.flip(Fixture.mainAppKitFrame, primaryMaxY: Fixture.primaryMaxY),
                       CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    func testPortraitDisplaySitsAboveAndLeftOfTheMainOne() {
        // AppKit top edge is -580 + 2560 = 1980, i.e. 540pt above the main
        // display's top, so AX y must be -540.
        XCTAssertEqual(Fixture.portrait, CGRect(x: -1440, y: -540, width: 1440, height: 2560))
        XCTAssertEqual(Fixture.portrait.maxY, 2020)
    }

    func testFlipIsItsOwnInverse() {
        for rect in [Fixture.mainAppKitFrame, Fixture.mainAppKitVisible,
                     Fixture.portraitAppKitFrame, CGRect(x: -7, y: 13, width: 101, height: 37)] {
            let round = Layout.flip(Layout.flip(rect, primaryMaxY: Fixture.primaryMaxY),
                                    primaryMaxY: Fixture.primaryMaxY)
            XCTAssertEqual(round, rect)
        }
    }
}

final class LayoutTests: XCTestCase {
    func testHalvesOnTheMainDisplay() {
        let v = Fixture.mainVisible
        XCTAssertEqual(Layout.frame(edge: .left, fraction: 0.5, in: v),
                       CGRect(x: 0, y: 30, width: 1280, height: 1410))
        XCTAssertEqual(Layout.frame(edge: .right, fraction: 0.5, in: v),
                       CGRect(x: 1280, y: 30, width: 1280, height: 1410))
        XCTAssertEqual(Layout.frame(edge: .top, fraction: 0.5, in: v),
                       CGRect(x: 0, y: 30, width: 2560, height: 705))
        XCTAssertEqual(Layout.frame(edge: .bottom, fraction: 0.5, in: v),
                       CGRect(x: 0, y: 735, width: 2560, height: 705))
    }

    func testEdgesStayFlushAtEveryFraction() {
        for visible in [Fixture.mainVisible, Fixture.portrait] {
            for fraction in Layout.fractions {
                XCTAssertEqual(Layout.frame(edge: .left, fraction: fraction, in: visible).minX,
                               visible.minX, "left flush")
                XCTAssertEqual(Layout.frame(edge: .right, fraction: fraction, in: visible).maxX,
                               visible.maxX, "right flush")
                XCTAssertEqual(Layout.frame(edge: .top, fraction: fraction, in: visible).minY,
                               visible.minY, "top flush")
                XCTAssertEqual(Layout.frame(edge: .bottom, fraction: fraction, in: visible).maxY,
                               visible.maxY, "bottom flush")
            }
        }
    }

    /// The headline behaviour: half, two thirds, one third, back to half.
    func testRepeatedPressesCycleTheFraction() {
        let v = Fixture.mainVisible
        var window = CGRect(x: 900, y: 400, width: 600, height: 500)   // floating

        window = Layout.next(edge: .left, window: window, in: v)
        XCTAssertEqual(window.width, 1280, "first press snaps to a half")

        window = Layout.next(edge: .left, window: window, in: v)
        XCTAssertEqual(window.width, (2560.0 * 2.0 / 3.0).rounded(), "then two thirds")

        window = Layout.next(edge: .left, window: window, in: v)
        XCTAssertEqual(window.width, (2560.0 / 3.0).rounded(), "then one third")

        window = Layout.next(edge: .left, window: window, in: v)
        XCTAssertEqual(window.width, 1280, "then back to a half")
    }

    func testCycleWorksOnEveryEdgeAndBothDisplays() {
        for visible in [Fixture.mainVisible, Fixture.portrait] {
            for edge in WindowEdge.allCases {
                var window = CGRect(x: visible.midX, y: visible.midY, width: 300, height: 300)
                var widths: [CGFloat] = []
                for _ in 0..<4 {
                    window = Layout.next(edge: edge, window: window, in: visible)
                    let along = (edge == .left || edge == .right) ? window.width : window.height
                    widths.append(along)
                }
                XCTAssertEqual(widths[0], widths[3], "\(edge) cycles back after three presses")
                XCTAssertEqual(Set(widths).count, 3, "\(edge) visits three distinct sizes")
            }
        }
    }

    func testTheOppositeEdgeSnapsRatherThanCycling() {
        let v = Fixture.mainVisible
        let leftHalf = Layout.frame(edge: .left, fraction: 0.5, in: v)
        // A left half is not a right half, so pressing right must snap to a
        // right half rather than advance to two thirds.
        let result = Layout.next(edge: .right, window: leftHalf, in: v)
        XCTAssertEqual(result, Layout.frame(edge: .right, fraction: 0.5, in: v))
    }

    /// A terminal resizes in whole character cells, so it never lands exactly.
    func testAWindowAFewPointsOffStillCounts() {
        let v = Fixture.mainVisible
        var nearly = Layout.frame(edge: .left, fraction: 0.5, in: v)
        nearly.size.width -= 9        // about one Ghostty cell
        nearly.size.height -= 14
        let result = Layout.next(edge: .left, window: nearly, in: v)
        XCTAssertEqual(result.width, (2560.0 * 2.0 / 3.0).rounded(),
                       "should advance, not re-snap to a half")
    }

    func testAWindowWellOffDoesNotCount() {
        let v = Fixture.mainVisible
        var off = Layout.frame(edge: .left, fraction: 0.5, in: v)
        off.size.width -= 200
        XCTAssertEqual(Layout.next(edge: .left, window: off, in: v).width, 1280,
                       "should re-snap to a half")
    }

    func testMaximizeDetection() {
        let v = Fixture.mainVisible
        XCTAssertTrue(Layout.isMaximized(v, in: v))
        XCTAssertTrue(Layout.isMaximized(v.insetBy(dx: 5, dy: 5), in: v), "within tolerance")
        XCTAssertFalse(Layout.isMaximized(v.insetBy(dx: 100, dy: 100), in: v))
        XCTAssertFalse(Layout.isMaximized(Layout.frame(edge: .left, fraction: 0.5, in: v), in: v))
    }
}
