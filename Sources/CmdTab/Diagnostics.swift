import AppKit
import Carbon.HIToolbox
import os

/// Use log stream with subsystem net.fikovnik.cmdtab. Include debug events for routine traces.
private let logger = Logger(subsystem: "net.fikovnik.cmdtab", category: "diagnostics")

@MainActor
enum Diagnostics {
    /// Keep recent events in memory. Routine events require the menu logging setting.
    private static var events: [String] = []
    private static let preferenceKey = "diagnosticLoggingEnabled"
    private(set) static var isLoggingEnabled = UserDefaults.standard.bool(forKey: preferenceKey)

    /// Keep the last 300 recorded events.
    private static let capacity = 300

    /// Build routine messages only when diagnostic logging is on.
    static func note(_ text: @autoclosure () -> String) {
        guard isLoggingEnabled else { return }
        let message = text()
        logger.debug("\(message, privacy: .private)")
        record(message, level: "trace")
    }

    /// Errors remain available in Console and the report when routine logging is off.
    static func error(_ text: String) {
        logger.error("\(text, privacy: .public)")
        record(text, level: "error")
    }

    private static func record(_ message: String, level: String) {
        let entry = "\(Date().ISO8601Format(.init(includingFractionalSeconds: true))) [\(level)] \(message)"
        events.append(entry)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        if isLoggingEnabled { log.append(entry + "\n") }
    }

    static func setLoggingEnabled(_ enabled: Bool) {
        guard enabled != isLoggingEnabled else { return }
        if !enabled { note("diagnostic logging disabled") }
        isLoggingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        if enabled { note("diagnostic logging enabled") }
    }

    static func flush() {
        log.flush()
    }

    static let traceURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CmdTab/trace.log")
    private static let log = DiagnosticLog(url: traceURL)

    /// Read the tracked state without a refresh. A refresh can erase the failure state.
    static func report(context: String = "") -> String {
        var out = "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Process: pid=\(ProcessInfo.processInfo.processIdentifier) executable=\(Bundle.main.executableURL?.path ?? "unknown")\n"
        out += "DiagnosticLogging: \(isLoggingEnabled)\n"
        out += "AXIsProcessTrusted: \(AXIsProcessTrusted())\n"
        out += "ScreenRecording: \(CGPreflightScreenCaptureAccess())\n"
        out += "SecureInput: \(IsSecureEventInputEnabled())\n"
        out += "AppHidden: \(NSApp.isHidden)\n"
        out += "Mouse: \(NSEvent.mouseLocation)\n"
        for screen in NSScreen.screens {
            out += "Screen: \(screen.localizedName) frame=\(screen.frame) visible=\(screen.visibleFrame)\n"
        }
        if !context.isEmpty { out += "\n== switcher and configuration state ==\n\(context)\n" }

        let tracker = WindowTracker.shared
        out += "\n\(Focus.diagnosticSummary)\n"
        let layout = Spaces.layout()
        for scope in [WindowScope.currentSpace, .allSpaces] {
            let list = tracker.list(scope, in: layout)
            out += "\n== \(scope) (\(list.count)) ==\n"
            // `recent=-`: the window never had focus, so it comes after the
            // windows that had. `server`: AX has not returned the window yet.
            for window in list {
                let rank = tracker.recent.order.firstIndex(of: window.id).map(String.init) ?? "-"
                let kind = window.element == nil ? "server" : "ax"
                out += "  recent=\(rank) \(kind) id=\(window.id) pid=\(window.pid) spaces=\(window.spaces) [\(window.spaceLabel ?? "-")] \(window.appName) | \(window.title)\n"
            }
        }

        out += "\n== preview cache ==\n"
        out += WindowPreview.shared.cacheReport()

        out += "\n== recent events ==\n"
        for event in events { out += "  \(event)\n" }

        out += "\n== apps ==\n"
        let windows = Array(tracker.windows.values)
        for (pid, app) in WindowTracker.regularApps().sorted(by: { $0.key < $1.key }) {
            let own = windows.filter { $0.pid == pid }
            out += "  \(app.localizedName ?? "?") pid=\(pid) hidden=\(app.isHidden)"
            out += " windows=\(own.count) withElement=\(own.filter { $0.element != nil }.count)"
            out += " nonStandard=\(own.filter { !$0.isStandard }.count)\n"
        }
        return out
    }

    /// Save the current report after all queued events, regardless of the logging setting.
    static func trace(_ reason: String, context: String = "") throws {
        var entry = "\n\n===== \(Date()) — \(reason) =====\n"
        entry += report(context: context)
        try log.appendAndWait(entry)
    }
}
