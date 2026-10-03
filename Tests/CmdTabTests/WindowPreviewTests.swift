import AppKit
import XCTest
@testable import CmdTab

final class WindowPreviewTests: XCTestCase {
    @MainActor
    private final class Source {
        var image: CGImage?
        init(_ image: CGImage) { self.image = image }
    }

    @MainActor
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    func testCapturesAreCoalescedAndClosedWindowsReleaseTheirFrames() async throws {
        let image = try image(width: 100, height: 100)
        var now: TimeInterval = 0
        var captures = 0
        let preview = WindowPreview(snapshot: { _ in captures += 1; return image }, clock: { now })
        preview.capture(1)
        now = 0.2
        preview.capture(1)
        XCTAssertEqual(captures, 1)
        now = 0.6
        preview.capture(1)
        XCTAssertEqual(captures, 2)
        preview.capture(2)
        preview.retain([2])
        XCTAssertEqual(preview.cachedWindowIDs, [2])
        XCTAssertEqual(preview.cachedBytes, image.bytesPerRow * image.height)
    }

    @MainActor
    func testFailedCaptureKeepsThePreviousFrame() async throws {
        let image = try image(width: 100, height: 100)
        var now: TimeInterval = 0
        let source = Source(image)
        let preview = WindowPreview(snapshot: { _ in source.image }, clock: { now })
        preview.capture(1)
        source.image = nil
        now = 1
        preview.capture(1)
        XCTAssertEqual(preview.cachedWindowIDs, [1])
        XCTAssertGreaterThan(preview.cachedBytes, 0)
    }

    @MainActor
    func testCacheEvictsOldestFramesToStayWithinTheByteLimit() async throws {
        let image = try image(width: 1800, height: 1400)
        var now: TimeInterval = 0
        let preview = WindowPreview(snapshot: { _ in image }, clock: { now })
        for id: CGWindowID in 1...5 {
            now += 1
            preview.capture(id)
        }
        XCTAssertLessThanOrEqual(preview.cachedBytes, WindowPreview.byteLimit)
        XCTAssertEqual(preview.cachedWindowIDs, [3, 4, 5])
    }

    @MainActor
    func testPortraitFramesAreLimitedByHeight() async throws {
        let image = try image(width: 100, height: 8000)
        let preview = WindowPreview(snapshot: { _ in image })
        preview.capture(1)
        // A 100x8000 image becomes 17x1400 pixels.
        XCTAssertGreaterThan(preview.cachedBytes, 0)
        XCTAssertLessThan(preview.cachedBytes, 32 * 1400 * 4)
    }

    @MainActor
    func testSmallFramesAlsoHaveACountLimit() async throws {
        let image = try image(width: 10, height: 10)
        var now: TimeInterval = 0
        let preview = WindowPreview(snapshot: { _ in image }, clock: { now })
        for id: CGWindowID in 1...60 {
            now += 1
            preview.capture(id)
        }
        XCTAssertEqual(preview.cachedWindowIDs, Set(13...60))
    }
}
