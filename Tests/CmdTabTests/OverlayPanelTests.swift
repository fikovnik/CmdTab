import AppKit
import XCTest

@testable import CmdTab

final class OverlayPanelTests: XCTestCase {
    @MainActor
    private final class DisplaySetup {
        var displays: [OverlayPanel.Display]

        init(_ displays: [OverlayPanel.Display]) {
            self.displays = displays
        }
    }

    @MainActor
    private func requireWindowServer() throws {
        guard CGSessionCopyCurrentDictionary() != nil else {
            throw XCTSkip("Overlay windows need a WindowServer session")
        }
        _ = NSApplication.shared
    }

    @MainActor
    func testAnUnchangedDisplaySetupReusesThePanel() async throws {
        try requireWindowServer()
        let displays = [OverlayPanel.Display(id: 1, frame: NSRect(x: 0, y: 0, width: 1710, height: 1112), scale: 2)]
        let overlay = OverlayPanel(currentDisplays: { displays })
        defer { overlay.reset() }
        let view = NSView()
        let first = overlay.ensurePanel(containing: view)
        XCTAssertTrue(first === overlay.ensurePanel(containing: view))
        XCTAssertTrue(view.window === first)
    }

    @MainActor
    func testDisconnectRecreatesThePanelAndMovesItsContent() async throws {
        try requireWindowServer()
        let setup = DisplaySetup([
            OverlayPanel.Display(id: 1, frame: NSRect(x: 0, y: 0, width: 2560, height: 1440), scale: 1),
            OverlayPanel.Display(id: 2, frame: NSRect(x: -1440, y: 0, width: 1440, height: 2560), scale: 1),
        ])
        let overlay = OverlayPanel(currentDisplays: { setup.displays })
        defer { overlay.reset() }
        let view = NSView()
        let first = overlay.ensurePanel(containing: view)
        first.orderFrontRegardless()
        setup.displays = [OverlayPanel.Display(id: 3, frame: NSRect(x: 0, y: 0, width: 1710, height: 1112), scale: 2)]
        let replacement = overlay.ensurePanel(containing: view)
        XCTAssertFalse(first === replacement)
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(view.window === replacement)
        XCTAssertTrue(replacement.collectionBehavior.contains(.canJoinAllSpaces))
    }

    @MainActor
    func testResolutionAndScaleChangesRecreateThePanelWithTheSameDisplayID() async throws {
        try requireWindowServer()
        let setup = DisplaySetup([OverlayPanel.Display(id: 1, frame: NSRect(x: 0, y: 0, width: 2560, height: 1440), scale: 1)])
        let overlay = OverlayPanel(currentDisplays: { setup.displays })
        defer { overlay.reset() }
        let view = NSView()
        let first = overlay.ensurePanel(containing: view)
        setup.displays = [OverlayPanel.Display(id: 1, frame: NSRect(x: 0, y: 0, width: 1710, height: 1112), scale: 2)]
        XCTAssertFalse(first === overlay.ensurePanel(containing: view))
    }

    @MainActor
    func testResetRecreatesThePanelEvenIfTheDisplayIDsReturnToTheSameValues() async throws {
        try requireWindowServer()
        let displays = [OverlayPanel.Display(id: 1, frame: NSRect(x: 0, y: 0, width: 2560, height: 1440), scale: 1)]
        let overlay = OverlayPanel(currentDisplays: { displays })
        defer { overlay.reset() }
        let view = NSView()
        let first = overlay.ensurePanel(containing: view)
        overlay.reset()
        XCTAssertNil(overlay.panel)
        XCTAssertFalse(first === overlay.ensurePanel(containing: view))
    }
}
