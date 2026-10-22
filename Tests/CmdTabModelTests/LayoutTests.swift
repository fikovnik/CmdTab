import XCTest

@testable import CmdTabModel

/// Use a portrait display to test negative AppKit coordinates.
/// Its top edge is above the primary display.
private enum Fixture {
    static let primaryMaxY: CGFloat = 1440

    static let mainAppKitFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    static let mainAppKitVisible = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    static let portraitAppKitFrame = CGRect(x: -1440, y: -580, width: 1440, height: 2560)

    /// Use AX coordinates for these values.
    static var mainVisible: CGRect { Layout.flip(mainAppKitVisible, primaryMaxY: primaryMaxY) }
    static var portrait: CGRect { Layout.flip(portraitAppKitFrame, primaryMaxY: primaryMaxY) }
}

final class FlipTests: XCTestCase {
    func testMainDisplayVisibleFrameLandsUnderTheMenuBar() {
        // The menu bar moves the top edge of the visible frame down by 30 points in AX coordinates.
        XCTAssertEqual(Fixture.mainVisible, CGRect(x: 0, y: 30, width: 2560, height: 1410))
    }

    func testMainDisplayFullFrameIsUnchangedByTheFlip() {
        XCTAssertEqual(Layout.flip(Fixture.mainAppKitFrame, primaryMaxY: Fixture.primaryMaxY),
                       CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    func testPortraitDisplaySitsAboveAndLeftOfTheMainOne() {
        // The portrait top edge is 1980 in AppKit coordinates.
        // Subtract this value from the primary display height to get -540.
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
        var window = CGRect(x: 900, y: 400, width: 600, height: 500)

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
        let result = Layout.next(edge: .right, window: leftHalf, in: v)
        XCTAssertEqual(result, Layout.frame(edge: .right, fraction: 0.5, in: v))
    }

    /// Terminals can resize only to whole character cells.
    func testAWindowAFewPointsOffStillCounts() {
        let v = Fixture.mainVisible
        var nearly = Layout.frame(edge: .left, fraction: 0.5, in: v)
        nearly.size.width -= 9
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

    func testCenteringMatchesTheHandComputedFrame() {
        XCTAssertEqual(Layout.centered(CGRect(x: 0, y: 0, width: 1210, height: 672),
                                       in: Fixture.mainVisible),
                       CGRect(x: 675, y: 399, width: 1210, height: 672))
    }

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
        var window = CGRect(x: 7, y: 13, width: 1210, height: 672)

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

final class DisplayMoveTests: XCTestCase {
    private let displays = [
        Fixture.mainAppKitFrame,
        Fixture.portrait,
        CGRect(x: 2560, y: 0, width: 1920, height: 1080),
        CGRect(x: 0, y: -1080, width: 1920, height: 1080),
    ]

    func testDisplaySelectionUsesTheLargestIntersection() {
        let window = CGRect(x: -200, y: 100, width: 800, height: 500)
        XCTAssertEqual(Layout.displayIndex(containing: window, in: displays), 0)
        XCTAssertEqual(Layout.displayIndex(containing: window.offsetBy(dx: -500, dy: 0), in: displays), 1)
    }

    func testDisplaySelectionRejectsOffscreenWindowsAndEmptyDisplays() {
        XCTAssertNil(Layout.displayIndex(containing: CGRect(x: 8000, y: 8000, width: 300, height: 200),
                                        in: displays))
        XCTAssertNil(Layout.displayIndex(containing: .zero, in: displays))
        XCTAssertNil(Layout.displayIndex(containing: Fixture.mainVisible, in: []))
    }

    func testDisplayOrderUsesPositionAndWrapsAtBothEnds() {
        XCTAssertEqual(Layout.adjacentDisplay(to: 1, toward: .next, in: displays), 3)
        XCTAssertEqual(Layout.adjacentDisplay(to: 3, toward: .next, in: displays), 0)
        XCTAssertEqual(Layout.adjacentDisplay(to: 0, toward: .next, in: displays), 2)
        XCTAssertEqual(Layout.adjacentDisplay(to: 2, toward: .next, in: displays), 1)
        XCTAssertEqual(Layout.adjacentDisplay(to: 1, toward: .previous, in: displays), 2)
        XCTAssertEqual(Layout.adjacentDisplay(to: 0, toward: .previous, in: displays), 3)
    }

    func testNoMoveExistsWithoutAnotherDisplay() {
        for direction in [DisplayDirection.previous, .next] {
            XCTAssertNil(Layout.adjacentDisplay(to: 0, toward: direction, in: []))
            XCTAssertNil(Layout.adjacentDisplay(to: 0, toward: direction, in: [Fixture.mainVisible]))
            XCTAssertNil(Layout.adjacentDisplay(to: -1, toward: direction, in: displays))
            XCTAssertNil(Layout.adjacentDisplay(to: displays.count, toward: direction, in: displays))
        }
    }

    func testMovePreservesSizeAndCenterOnAPortraitDisplay() {
        let window = Layout.centered(CGRect(x: 0, y: 0, width: 600, height: 400), in: Fixture.mainVisible)
        let moved = Layout.moved(window, from: Fixture.mainVisible, to: Fixture.portrait)
        XCTAssertEqual(moved, CGRect(x: -1020, y: 540, width: 600, height: 400))
    }

    func testMovePreservesRelativePositionBetweenDifferentDisplaySizes() {
        let source = CGRect(x: 0, y: 30, width: 2000, height: 1200)
        let destination = CGRect(x: -1000, y: -800, width: 1000, height: 800)
        let moved = Layout.moved(CGRect(x: 400, y: 230, width: 400, height: 400),
                                 from: source, to: destination)
        XCTAssertEqual(moved, CGRect(x: -850, y: -700, width: 400, height: 400))
    }

    func testMoveKeepsAWindowAtTheRightAndBottomEdges() {
        let source = Fixture.mainVisible
        let window = CGRect(x: source.maxX - 600, y: source.maxY - 400, width: 600, height: 400)
        let moved = Layout.moved(window, from: source, to: Fixture.portrait)
        XCTAssertEqual(moved.size, window.size)
        XCTAssertEqual(moved.maxX, Fixture.portrait.maxX)
        XCTAssertEqual(moved.maxY, Fixture.portrait.maxY)
    }

    func testMoveShrinksOnlyDimensionsThatExceedTheDestination() {
        let destination = CGRect(x: 3000, y: 40, width: 800, height: 600)
        let window = CGRect(x: 100, y: 100, width: 1200, height: 400)
        let moved = Layout.moved(window, from: Fixture.mainVisible, to: destination)
        XCTAssertEqual(moved.width, 800)
        XCTAssertEqual(moved.height, 400)
        XCTAssertTrue(destination.contains(moved))
    }

    func testMoveBringsAPartlyOffscreenWindowInsideTheDestination() {
        let window = CGRect(x: -300, y: 1300, width: 600, height: 400)
        let moved = Layout.moved(window, from: Fixture.mainVisible, to: Fixture.portrait)
        XCTAssertEqual(moved.minX, Fixture.portrait.minX)
        XCTAssertEqual(moved.maxY, Fixture.portrait.maxY)
        XCTAssertTrue(Fixture.portrait.contains(moved))
    }

    func testMoveCentersAWindowThatFillsTheSource() {
        let destination = CGRect(x: 2560, y: 0, width: 3840, height: 2160)
        let moved = Layout.moved(Fixture.mainVisible, from: Fixture.mainVisible, to: destination)
        XCTAssertEqual(moved.size, Fixture.mainVisible.size)
        XCTAssertEqual(moved.midX, destination.midX, accuracy: 0.5)
        XCTAssertEqual(moved.midY, destination.midY, accuracy: 0.5)
    }
}
