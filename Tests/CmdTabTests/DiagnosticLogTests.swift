import Foundation
import XCTest

@testable import CmdTab

final class DiagnosticLogTests: XCTestCase {
    private func withLog(_ body: (DiagnosticLog) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = DiagnosticLog(directory: directory.appendingPathComponent("nested"),
                                timeZone: TimeZone(secondsFromGMT: 3600)!)
        defer {
            log.flush()
            try? FileManager.default.removeItem(at: directory)
        }
        try body(log)
    }

    func testEventsReachTheFileAsTheyArriveAndPreserveUnicode() throws {
        try withLog { log in
            let date = try Date("2026-10-31T12:00:00Z", strategy: .iso8601)
            log.append("first event\n", at: date)
            log.flush()
            XCTAssertEqual(try String(contentsOf: log.url(for: date), encoding: .utf8), "first event\n")

            log.append("HUD on Příliš žluťoučký\n", at: date)
            log.append("last event\n", at: date)
            log.flush()
            XCTAssertEqual(try String(contentsOf: log.url(for: date), encoding: .utf8),
                           "first event\nHUD on Příliš žluťoučký\nlast event\n")
        }
    }

    func testRolloverUsesTheLocalEventDateAndPreservesThePreviousDay() throws {
        try withLog { log in
            let beforeMidnight = try Date("2026-12-31T22:59:59Z", strategy: .iso8601)
            let afterMidnight = beforeMidnight.addingTimeInterval(1)
            log.append("before midnight\n", at: beforeMidnight)
            log.append("after midnight\n", at: afterMidnight)
            log.flush()
            XCTAssertEqual(log.url(for: beforeMidnight).lastPathComponent, "2026-12-31.log")
            XCTAssertEqual(log.url(for: afterMidnight).lastPathComponent, "2027-01-01.log")
            XCTAssertEqual(log.timestamp(for: beforeMidnight), "2026-12-31T23:59:59.000+01:00")
            XCTAssertEqual(log.timestamp(for: afterMidnight), "2027-01-01T00:00:00.000+01:00")
            XCTAssertEqual(try String(contentsOf: log.url(for: beforeMidnight), encoding: .utf8), "before midnight\n")
            XCTAssertEqual(try String(contentsOf: log.url(for: afterMidnight), encoding: .utf8), "after midnight\n")
        }
    }

    func testTimestampsIncludeTheOffsetAcrossTheDaylightSavingTransition() throws {
        let log = DiagnosticLog(directory: FileManager.default.temporaryDirectory,
                                timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Prague")))
        let summer = try Date("2026-10-25T00:30:00Z", strategy: .iso8601)
        let winter = summer.addingTimeInterval(3600)
        XCTAssertEqual(log.timestamp(for: summer), "2026-10-25T02:30:00.000+02:00")
        XCTAssertEqual(log.timestamp(for: winter), "2026-10-25T02:30:00.000+01:00")
        XCTAssertEqual(log.url(for: summer).lastPathComponent, "2026-10-25.log")
        XCTAssertEqual(log.url(for: winter), log.url(for: summer))
    }

    func testSameDayAppendsAfterRestartWithoutSizeRotation() throws {
        try withLog { log in
            let date = try Date("2026-10-31T12:00:00Z", strategy: .iso8601)
            let text = String(repeating: "event\n", count: 100_000)
            log.append(text, at: date)
            log.flush()

            let directory = log.url(for: date).deletingLastPathComponent()
            let resumed = DiagnosticLog(directory: directory, timeZone: TimeZone(secondsFromGMT: 3600)!)
            resumed.append("restart\n", at: date)
            resumed.flush()
            XCTAssertEqual(try String(contentsOf: log.url(for: date), encoding: .utf8), text + "restart\n")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["2026-10-31.log"])
        }
    }

    func testWritesContinueAfterADestinationError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = DiagnosticLog(directory: directory)
        defer {
            log.flush()
            try? FileManager.default.removeItem(at: directory)
        }
        let date = try Date("2026-10-31T12:00:00Z", strategy: .iso8601)
        try Data().write(to: directory)
        log.append("failed event\n", at: date)
        log.flush()
        try FileManager.default.removeItem(at: directory)
        log.append("next event\n", at: date)
        log.flush()
        XCTAssertEqual(try String(contentsOf: log.url(for: date), encoding: .utf8), "next event\n")
    }
}
