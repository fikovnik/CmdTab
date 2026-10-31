import Foundation
import os

/// Write files on a serial worker queue.
/// Use the event date to select the daily file.
final class DiagnosticLog: Sendable {
    private let directory: URL
    private let timestampFormat: Date.ISO8601FormatStyle
    private let queue = DispatchQueue(label: "net.fikovnik.cmdtab.diagnostic-log", qos: .utility)
    private let logger = Logger(subsystem: "net.fikovnik.cmdtab", category: "diagnostic-log")

    init(directory: URL, timeZone: TimeZone = .current) {
        self.directory = directory
        self.timestampFormat = Date.ISO8601FormatStyle(timeZoneSeparator: .colon,
                                                      includingFractionalSeconds: true, timeZone: timeZone)
    }

    func url(for date: Date = Date()) -> URL {
        directory.appendingPathComponent("\(date.formatted(timestampFormat.year().month().day())).log")
    }

    func timestamp(for date: Date) -> String {
        date.formatted(timestampFormat)
    }

    func append(_ text: String, at date: Date = Date()) {
        let url = url(for: date)
        queue.async {
            do { try self.write(text, to: url) }
            catch { self.logger.error("Could not write diagnostics: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func write(_ text: String, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(text.utf8)
        if manager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
