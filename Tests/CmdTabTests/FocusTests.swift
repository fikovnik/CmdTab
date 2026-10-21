import CmdTabModel
import Foundation
import XCTest
@testable import CmdTab

final class FocusTests: XCTestCase {
    private let layout = SpaceLayout(displays: [
        .init(identifier: "first", spaces: [.init(id: 1, isFullScreen: false), .init(id: 2, isFullScreen: true)],
              currentSpace: 1),
        .init(identifier: "second", spaces: [.init(id: 3, isFullScreen: false), .init(id: 4, isFullScreen: false)],
              currentSpace: 3),
    ])

    func testCrossSpaceFocusRepairsThePreviousAppOnTheSameDisplay() {
        XCTAssertEqual(Focus.originToRestore(targetSpaces: [2], targetPID: 20, layout: layout,
                                             activeDisplay: "first", frontPID: 10),
                       Focus.Origin(space: 1, pid: 10))
    }

    func testVisibleAndUnknownTargetsDoNotRestoreThePreviousApp() {
        for spaces: [SpaceID] in [[1], [], [1, 2], [3]] {
            XCTAssertNil(Focus.originToRestore(targetSpaces: spaces, targetPID: 20, layout: layout,
                                               activeDisplay: "first", frontPID: 10))
        }
    }

    func testAHiddenTargetOnAnotherDisplayDoesNotRepairTheVisibleOrigin() {
        XCTAssertNil(Focus.originToRestore(targetSpaces: [4], targetPID: 20, layout: layout,
                                           activeDisplay: "first", frontPID: 10))
    }

    func testFocusWithinTheSameAppDoesNotRestoreThatApp() {
        XCTAssertNil(Focus.originToRestore(targetSpaces: [2], targetPID: 10, layout: layout,
                                           activeDisplay: "first", frontPID: 10))
    }

    func testSharedSpacesUseTheMainDisplayLayout() {
        let shared = SpaceLayout(displays: [
            .init(identifier: "Main", spaces: [.init(id: 1, isFullScreen: false), .init(id: 2, isFullScreen: false)],
                  currentSpace: 1),
        ])
        XCTAssertEqual(Focus.originToRestore(targetSpaces: [2], targetPID: 20, layout: shared,
                                             activeDisplay: "display-uuid", frontPID: 10),
                       Focus.Origin(space: 1, pid: 10))
    }

    func testABlockedCommandStopsAndQueuedRequestsCollapseToTheLatest() {
        let queue = FocusQueue()
        let entered = expectation(description: "The first command entered its worker")
        let stopped = expectation(description: "The first command stopped before its next step")
        let latest = expectation(description: "The latest command ran")
        let release = DispatchSemaphore(value: 0)

        queue.submit { _, isCurrent in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else {
                XCTFail("The test did not release the first command")
                return
            }
            XCTAssertFalse(isCurrent())
            stopped.fulfill()
        }
        wait(for: [entered], timeout: 5)
        queue.submit { _, _ in XCTFail("An obsolete command ran") }
        queue.submit { _, isCurrent in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertTrue(isCurrent())
            latest.fulfill()
        }
        release.signal()
        wait(for: [stopped, latest], timeout: 5, enforceOrder: true)
    }
}
