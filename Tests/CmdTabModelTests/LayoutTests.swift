import XCTest

@testable import CmdTabModel

/// A real two-display setup. The main display is 2560x1440 with a 30-point menu
/// bar. A rotated portrait display is on its left, and its bottom edge is lower.
/// The portrait display finds coordinate conversion errors. Its AppKit origin is
/// negative on both axes, and its top edge is *above* the top edge of the main
/// display.
private enum Fixture {
    static let primaryMaxY: CGFloat = 1440

    static let mainAppKitFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    static let mainAppKitVisible = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    static let portraitAppKitFrame = CGRect(x: -1440, y: -580, width: 1440, height: 2560)

    /// These values use AX coordinates.
    static var mainVisible: CGRect { Layout.flip(mainAppKitVisible, primaryMaxY: primaryMaxY) }
    static var portrait: CGRect { Layout.flip(portraitAppKitFrame, primaryMaxY: primaryMaxY) }
}

final class FlipTests: XCTestCase {
    func testMainDisplayVisibleFrameLandsUnderTheMenuBar() {
        // `visibleFrame` does not include the 30-point menu bar at the *top*.
        // Thus, in top-left coordinates, the rect starts at y=30, not y=0.
        XCTAssertEqual(Fixture.mainVisible, CGRect(x: 0, y: 30, width: 2560, height: 1410))
    }

    func testMainDisplayFullFrameIsUnchangedByTheFlip() {
        XCTAssertEqual(Layout.flip(Fixture.mainAppKitFrame, primaryMaxY: Fixture.primaryMaxY),
                       CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    func testPortraitDisplaySitsAboveAndLeftOfTheMainOne() {
        // The AppKit top edge is -580 + 2560 = 1980. This is 540 points above the
        // top of the main display. Thus, the AX y value is -540.
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

    func testRepeatedPressesCycleTheFraction() {
        let v = Fixture.mainVisible
        var window = CGRect(x: 900, y: 400, width: 600, height: 500)   // not tiled

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
        // A left half is not a right half. Thus, a press on the right edge gives
        // a right half, not two thirds.
        let result = Layout.next(edge: .right, window: leftHalf, in: v)
        XCTAssertEqual(result, Layout.frame(edge: .right, fraction: 0.5, in: v))
    }

    /// A terminal resizes in whole character cells, so it does not stop on an
    /// exact fraction.
    func testAWindowAFewPointsOffStillCounts() {
        let v = Fixture.mainVisible
        var nearly = Layout.frame(edge: .left, fraction: 0.5, in: v)
        nearly.size.width -= 9        // approximately one Ghostty cell
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

    func testCenteringKeepsTheSizeAndCentersOnBothDisplays() {
        for visible in [Fixture.mainVisible, Fixture.portrait] {
            let window = CGRect(x: 7, y: 13, width: 1210, height: 672)
            let centered = Layout.centered(window, in: visible)
            XCTAssertEqual(centered.size, window.size, "size is untouched")
            XCTAssertEqual(centered.midX, visible.midX, accuracy: 0.5)
            XCTAssertEqual(centered.midY, visible.midY, accuracy: 0.5)
        }
    }

    /// A 120x30 Ghostty window is 1210x672 points. The visible frame of the main
    /// display starts below the 30-point menu bar.
    func testCenteringMatchesTheHandComputedFrame() {
        XCTAssertEqual(Layout.centered(CGRect(x: 0, y: 0, width: 1210, height: 672),
                                       in: Fixture.mainVisible),
                       CGRect(x: 675, y: 399, width: 1210, height: 672))
    }

    /// A centered fraction changes both axes, because it is not flush with an
    /// edge.
    func testCenteredFractionsShrinkBothAxesAndStayCentered() {
        for visible in [Fixture.mainVisible, Fixture.portrait] {
            for fraction in Layout.fractions {
                let box = Layout.centered(fraction: fraction, in: visible)
                XCTAssertEqual(box.width, (visible.width * fraction).rounded())
                XCTAssertEqual(box.height, (visible.height * fraction).rounded())
                XCTAssertEqual(box.midX, visible.midX, accuracy: 0.5, "\(fraction) midX")
                XCTAssertEqual(box.midY, visible.midY, accuracy: 0.5, "\(fraction) midY")
            }
        }
    }

    func testFirstCenterOnlyMovesThenPressesCycleTheFraction() {
        let v = Fixture.mainVisible
        var window = CGRect(x: 7, y: 13, width: 1210, height: 672)   // not tiled

        window = Layout.nextCentered(window: window, in: v)
        XCTAssertEqual(window, CGRect(x: 675, y: 399, width: 1210, height: 672),
                       "first press moves without resizing")

        window = Layout.nextCentered(window: window, in: v)
        XCTAssertEqual(window, Layout.centered(fraction: 1.0 / 2.0, in: v), "then a half")

        window = Layout.nextCentered(window: window, in: v)
        XCTAssertEqual(window, Layout.centered(fraction: 2.0 / 3.0, in: v), "then two thirds")

        window = Layout.nextCentered(window: window, in: v)
        XCTAssertEqual(window, Layout.centered(fraction: 1.0 / 3.0, in: v), "then one third")

        window = Layout.nextCentered(window: window, in: v)
        XCTAssertEqual(window, Layout.centered(fraction: 1.0 / 2.0, in: v), "then back to a half")
    }

    /// A centered window with a size that is not a fraction cannot move to a new
    /// position. Thus, it must start the cycle and not stay at the same frame.
    func testAnAlreadyCenteredWindowEntersTheCycleInsteadOfStandingStill() {
        let v = Fixture.mainVisible
        let odd = Layout.centered(CGRect(x: 0, y: 0, width: 1210, height: 672), in: v)
        XCTAssertEqual(Layout.nextCentered(window: odd, in: v),
                       Layout.centered(fraction: 1.0 / 2.0, in: v))
    }

    func testCenterCyclesOnThePortraitDisplayToo() {
        let v = Fixture.portrait
        var window = CGRect(x: v.midX, y: v.midY, width: 301, height: 299)
        var sizes: [CGSize] = []
        for _ in 0..<4 {
            window = Layout.nextCentered(window: window, in: v)
            sizes.append(window.size)
        }
        XCTAssertEqual(sizes[0], CGSize(width: 301, height: 299), "first press keeps the size")
        XCTAssertEqual(Set(sizes.dropFirst().map(\.width)).count, 3, "then three distinct sizes")
    }

    func testMaximizeDetection() {
        let v = Fixture.mainVisible
        XCTAssertTrue(Layout.isMaximized(v, in: v))
        XCTAssertTrue(Layout.isMaximized(v.insetBy(dx: 5, dy: 5), in: v), "within tolerance")
        XCTAssertFalse(Layout.isMaximized(v.insetBy(dx: 100, dy: 100), in: v))
        XCTAssertFalse(Layout.isMaximized(Layout.frame(edge: .left, fraction: 0.5, in: v), in: v))
    }
}
