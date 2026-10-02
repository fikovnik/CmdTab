import Foundation
import XCTest

@testable import CmdTab

final class DiagnosticLogTests: XCTestCase {
    private func withLog(maxBytes: Int = 512 * 1024, _ body: (DiagnosticLog) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = DiagnosticLog(url: directory.appendingPathComponent("nested/trace.log"), maxBytes: maxBytes)
        defer {
            log.flush()
            try? FileManager.default.removeItem(at: directory)
        }
        try body(log)
    }

    func testReportWaitsForQueuedEventsAndPreservesUnicode() throws {
        try withLog { log in
            log.append("first event\n")
            log.append("HUD on Příliš žluťoučký\n")
            try log.appendAndWait("report\n")
            XCTAssertEqual(try String(contentsOf: log.url, encoding: .utf8),
                           "first event\nHUD on Příliš žluťoučký\nreport\n")
        }
    }

    func testRotationKeepsThePreviousEvents() throws {
        try withLog(maxBytes: 8) { log in
            log.append("one\n")
            log.append("two\n")
            log.append("new\n")
            log.flush()
            XCTAssertEqual(try String(contentsOf: log.previousURL, encoding: .utf8), "one\ntwo\n")
            XCTAssertEqual(try String(contentsOf: log.url, encoding: .utf8), "new\n")
        }
    }

    func testRepeatedRotationKeepsOnlyTheLatestTwoFiles() throws {
        try withLog(maxBytes: 4) { log in
            log.append("one\n")
            log.append("two\n")
            log.append("new\n")
            log.flush()
            XCTAssertEqual(try String(contentsOf: log.previousURL, encoding: .utf8), "two\n")
            XCTAssertEqual(try String(contentsOf: log.url, encoding: .utf8), "new\n")
        }
    }

    func testExportReportsAnUnwritableDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)
        let log = DiagnosticLog(url: directory.appendingPathComponent("trace.log"))
        XCTAssertThrowsError(try log.appendAndWait("report\n"))
    }
}
