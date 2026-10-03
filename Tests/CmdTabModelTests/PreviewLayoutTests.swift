import CoreGraphics
import XCTest
@testable import CmdTabModel

final class PreviewLayoutTests: XCTestCase {
    private let screen = CGRect(x: -1440, y: -580, width: 1440, height: 2560)
    private let anchor = CGRect(x: -1020, y: 500, width: 600, height: 450)

    func testPreviewFitsAboveTheListAndStaysInsideTheDisplay() throws {
        let frame = try XCTUnwrap(PreviewLayout.frame(for: CGSize(width: 1200, height: 800),
                                                    anchor: anchor, in: screen))
        XCTAssertTrue(screen.contains(frame))
        XCTAssertGreaterThanOrEqual(frame.minY, anchor.maxY + 12)
        XCTAssertFalse(frame.intersects(anchor))
        XCTAssertEqual(frame.midX, anchor.midX)
        XCTAssertEqual(frame.width, 912)
        XCTAssertEqual(frame.height, 612)
    }

    func testPreviewUsesBelowWhenThereIsNoSpaceAbove() throws {
        let anchor = CGRect(x: -1020, y: 1720, width: 600, height: 240)
        let frame = try XCTUnwrap(PreviewLayout.frame(for: CGSize(width: 800, height: 600),
                                                    anchor: anchor, in: screen))
        XCTAssertLessThanOrEqual(frame.maxY, anchor.minY - 12)
        XCTAssertTrue(screen.contains(frame))
    }

    func testPreviewUsesTheSideWhenVerticalSpaceIsTooSmall() throws {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 600)
        let anchor = CGRect(x: 500, y: 100, width: 600, height: 400)
        let frame = try XCTUnwrap(PreviewLayout.frame(for: CGSize(width: 400, height: 300),
                                                    anchor: anchor, in: screen))
        XCTAssertGreaterThanOrEqual(frame.minX, anchor.maxX + 12)
        XCTAssertTrue(screen.contains(frame))
    }

    func testPreviewIsHiddenWhenItWouldBeTooSmall() {
        XCTAssertNil(PreviewLayout.frame(for: CGSize(width: 900, height: 700),
                                        anchor: CGRect(x: 100, y: 100, width: 600, height: 500),
                                        in: CGRect(x: 0, y: 0, width: 800, height: 700)))
        XCTAssertNil(PreviewLayout.frame(for: .zero, anchor: anchor, in: screen))
    }

    func testSmallImagesAreNotEnlarged() throws {
        let frame = try XCTUnwrap(PreviewLayout.frame(for: CGSize(width: 200, height: 150),
                                                    anchor: anchor, in: screen))
        XCTAssertEqual(frame.size, CGSize(width: 212, height: 162))
    }
}
