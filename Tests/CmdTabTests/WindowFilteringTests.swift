import AppKit
import CmdTabModel
import XCTest
@testable import CmdTab

final class WindowFilteringTests: XCTestCase {
    private let windows = [
        Window(id: 1, pid: 1, appName: "Safari", icon: nil, title: "Documentation"),
        Window(id: 2, pid: 2, appName: "Editor", icon: nil, title: "main.swift"),
        Window(id: 3, pid: 3, appName: "Terminal", icon: nil, title: "Swift build"),
        Window(id: 4, pid: 4, appName: "Notes", icon: nil, title: "Shopping"),
    ]

    @MainActor
    private func session() -> Switcher.Session {
        var session = Switcher.Session(mode: .allWindows, appFilter: nil, traversal: WindowTraversal())
        session.replaceCandidates(with: windows)
        session.hasShownHUD = true
        return session
    }

    @MainActor
    func testTypingNarrowsAndBackspaceRestoresCandidatesInOriginalOrder() async {
        var session = session()
        XCTAssertEqual(session.traversal.selected?.id, 2)
        session.search.append("swift")
        session.applyFilter()
        XCTAssertEqual(session.traversal.windows?.map(\.id), [2, 3])
        XCTAssertEqual(session.traversal.selected?.id, 2)
        session.search.append("x")
        session.applyFilter()
        XCTAssertEqual(session.traversal.windows?.count, 0)
        XCTAssertNil(session.traversal.selected)
        session.search.deleteLastCharacter()
        session.applyFilter()
        XCTAssertEqual(session.traversal.windows?.map(\.id), [2, 3])
        XCTAssertEqual(session.traversal.selected?.id, 2)
        for _ in 0..<5 { session.search.deleteLastCharacter() }
        session.applyFilter()
        XCTAssertEqual(session.traversal.windows?.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(session.traversal.selected?.id, 2)
        XCTAssertEqual(session.candidates.map(\.id), [1, 2, 3, 4])
    }

    @MainActor
    func testSelectionSurvivesEditsUntilItsWindowIsRemoved() async {
        var session = session()
        session.traversal.step(1)
        XCTAssertEqual(session.traversal.selected?.id, 3)
        session.search.append("s")
        session.applyFilter()
        XCTAssertEqual(session.traversal.selected?.id, 3)
        session.search.append("hopping")
        session.applyFilter()
        XCTAssertEqual(session.traversal.windows?.map(\.id), [4])
        XCTAssertEqual(session.traversal.selected?.id, 4)
    }

    @MainActor
    func testCandidateReloadsRetainQueryAndPermitSingleAndEmptyResults() async {
        var session = session()
        session.search.append("swift")
        session.applyFilter()
        session.replaceCandidates(with: [windows[2]])
        XCTAssertEqual(session.search.query, "swift")
        XCTAssertEqual(session.traversal.selected?.id, 3)
        session.replaceCandidates(with: [])
        XCTAssertEqual(session.traversal.windows?.count, 0)
        XCTAssertNil(session.traversal.selected)
        XCTAssertTrue(session.hasShownHUD)
        session.replaceCandidates(with: windows)
        XCTAssertEqual(session.traversal.windows?.map(\.id), [2, 3])
        XCTAssertEqual(session.traversal.selected?.id, 2)
    }

    @MainActor
    func testInitialSingletonHasNoSwitchTargetAndInputWaitsForReveal() async {
        var session = Switcher.Session(mode: .allWindows, appFilter: nil, traversal: WindowTraversal())
        session.replaceCandidates(with: [windows[0]])
        XCTAssertNil(session.traversal.selected)
        XCTAssertFalse(session.hasShownHUD)
        let switcher = Switcher()
        XCTAssertFalse(switcher.acceptsFilterInput)
        switcher.appendFilterText("swift")
        switcher.deleteFilterCharacter()
        XCTAssertFalse(switcher.acceptsFilterInput)
    }
}
