import Foundation
import os

/// Write files on a serial worker queue.
/// Keep one previous file when the log exceeds the size limit.
final class DiagnosticLog: Sendable {
    let url: URL
    let previousURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "net.fikovnik.cmdtab.diagnostic-log", qos: .utility)
    private let logger = Logger(subsystem: "net.fikovnik.cmdtab", category: "diagnostic-log")

    init(url: URL, maxBytes: Int = 512 * 1024) {
        self.url = url
        self.previousURL = url.deletingPathExtension().appendingPathExtension("previous.log")
        self.maxBytes = maxBytes
    }

    func append(_ text: String) {
        queue.async {
            do { try self.write(text) }
            catch { self.logger.error("Could not write diagnostics: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Wait for earlier writes before you add the report.
    func appendAndWait(_ text: String) throws {
        try queue.sync { try write(text) }
    }

    func flush() {
        queue.sync {}
    }

    private func write(_ text: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        if manager.fileExists(atPath: url.path) {
            let size = (try manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0, size + data.count > maxBytes {
                if manager.fileExists(atPath: previousURL.path) { try manager.removeItem(at: previousURL) }
                try manager.moveItem(at: url, to: previousURL)
            }
        }
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
