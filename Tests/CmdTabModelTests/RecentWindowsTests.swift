import XCTest

@testable import CmdTabModel

final class RecentWindowsOrderTests: XCTestCase {
    func testPromotePutsTheWindowFirst() {
        var recent = RecentWindows()
        recent.promote(1)
        recent.promote(2)
        recent.promote(1)
        XCTAssertEqual(recent.order, [1, 2])
    }

    func testSortedPutsFocusedWindowsFirstAndKeepsTheOthersInOrder() {
        var recent = RecentWindows()
        recent.promote(30)
        recent.promote(10)
        XCTAssertEqual(recent.sorted([5, 30, 6, 10, 7]), [10, 30, 5, 6, 7])
    }

    func testSortedIgnoresRecentWindowsThatAreNotListed() {
        var recent = RecentWindows()
        recent.promote(99)
        recent.promote(1)
        XCTAssertEqual(recent.sorted([2, 1]), [1, 2])
    }

    func testMinimizedWindowsFollowAllOtherWindowsAndKeepTheirOrder() {
        var recent = RecentWindows()
        recent.promote(30)
        recent.promote(10)
        XCTAssertEqual(recent.sorted([5, 30, 6, 10, 7], minimized: [10, 6]), [30, 5, 7, 10, 6])
    }

    func testAllMinimizedWindowsKeepFocusAndFallbackOrder() {
        var recent = RecentWindows()
        recent.promote(30)
        recent.promote(10)
        XCTAssertEqual(recent.sorted([5, 30, 6, 10, 7], minimized: [5, 30, 6, 10, 7]), [10, 30, 5, 6, 7])
    }

    func testRestoredWindowsReturnToTheirFocusOrder() {
        var recent = RecentWindows()
        recent.promote(1)
        recent.promote(2)
        XCTAssertEqual(recent.sorted([1, 2, 3], minimized: [2]), [1, 3, 2])
        XCTAssertEqual(recent.order, [2, 1])
        XCTAssertEqual(recent.sorted([1, 2, 3]), [2, 1, 3])
    }

    func testRetainRemovesClosedWindows() {
        var recent = RecentWindows()
        recent.promote(1)
        recent.promote(2)
        recent.retain([1])
        XCTAssertEqual(recent.order, [1])
    }
}

final class RecentWindowsSettleTests: XCTestCase {
    func testAnAnswerIsNotFinalBeforeTheSettleTime() {
        var recent = RecentWindows()
        recent.report(1, pid: 100, at: 0)
        recent.settle(at: 0.03)
        XCTAssertEqual(recent.order, [])
        XCTAssertTrue(recent.hasPendingAnswers)
    }

    func testAnAnswerIsFinalAfterTheSettleTime() {
        var recent = RecentWindows()
        recent.report(1, pid: 100, at: 0)
        recent.settle(at: 0.06)
        XCTAssertEqual(recent.order, [1])
        XCTAssertFalse(recent.hasPendingAnswers)
    }

    func testABurstFromOneAppPromotesOnlyItsLastAnswer() {
        var recent = RecentWindows()
        recent.promote(7)
        recent.report(1, pid: 100, at: 0)
        recent.report(2, pid: 100, at: 0.03)
        recent.report(3, pid: 100, at: 0.05)
        recent.settle(at: 0.08)
        XCTAssertEqual(recent.order, [7])
        recent.settle(at: 0.11)
        XCTAssertEqual(recent.order, [3, 7])
    }

    func testAnswersFromTwoAppsArePromotedInTimeOrder() {
        var recent = RecentWindows()
        recent.report(2, pid: 200, at: 0.01)
        recent.report(1, pid: 100, at: 0)
        recent.settle(at: 0.1)
        XCTAssertEqual(recent.order, [2, 1])
    }

    func testClosedWindowsCannotReturnThroughAPendingFocusAnswer() {
        var recent = RecentWindows()
        recent.promote(1)
        recent.report(2, pid: 100, at: 0)
        recent.retain([1])
        recent.settleAll()
        XCTAssertEqual(recent.order, [1])
        XCTAssertFalse(recent.hasPendingAnswers)
    }

    func testSettleAllIgnoresTheSettleTime() {
        var recent = RecentWindows()
        recent.report(1, pid: 100, at: 0)
        recent.settleAll()
        XCTAssertEqual(recent.order, [1])
    }
}
