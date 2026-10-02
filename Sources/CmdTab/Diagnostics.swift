import AppKit
import Carbon.HIToolbox
import os

/// Read with `log stream --predicate 'subsystem == "net.fikovnik.cmdtab"'`.
private let logger = Logger(subsystem: "net.fikovnik.cmdtab", category: "diagnostics")

@MainActor
enum Diagnostics {
    /// The recent switcher events. After a failure, the user can read them and
    /// does not need to reproduce the failure.
    ///
    /// Logging is opt-in in release builds. The menu setting survives a
    /// relaunch, so an intermittent failure can be captured across restarts.
    private static var events: [String] = []
    private static let preferenceKey = "diagnosticLoggingEnabled"
    private(set) static var isLoggingEnabled: Bool = {
        if let saved = UserDefaults.standard.object(forKey: preferenceKey) as? Bool { return saved }
        #if DIAGNOSTICS
        return true
        #else
        return false
        #endif
    }()

    /// A burst of AX failures gives about 12 lines. The buffer must also keep
    /// the events before and after a burst.
    private static let capacity = 300

    /// `@autoclosure`, so that disabled logging does not make the string. Each
    /// call interpolates, and the AX failure path can run hundreds of times.
    static func note(_ text: @autoclosure () -> String) {
        guard isLoggingEnabled else { return }
        let now = Date()
        let message = text()
        logger.notice("\(message, privacy: .public)")
        events.append(String(format: "%9.3f  %@",
                             now.timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000), message))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        log.append("\(now.ISO8601Format(.init(includingFractionalSeconds: true)))  \(message)\n")
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

    /// Draws the HUD offscreen with sample windows. The samples test the layout
    /// with more rows than fit, a long title and Space labels.
    static func renderHUD(to path: String) {
        // The accent color and the appearance need an `NSApplication`. This
        // path runs before `NSApp.run`.
        _ = NSApplication.shared
        let samples: [(String, String, String?)] = [
            ("Ghostty", "cmd-tab@pokhara.local: ✳ Claude Code", "Desktop 2"),
            ("Ghostty", "NI-APR-0@kathmandu: ✳ polymorphic-type-analysis", "Desktop 2"),
            ("Google Chrome", "v8/src/codegen/arm64/assembler-arm64.cc at main · v8/v8 — an overlong title that has to be truncated somewhere", "Desktop 1"),
            ("Slack", "#general", "Desktop 1"),
            ("Obsidian", "Daily note", "All Desktops"),
            ("Spotify", "", "Desktop 1"),
            ("Microsoft Teams", "Calendar", "Desktop 1"),
            ("Zotero", "My Library", "Desktop 1"),
            ("Preview", "paper.pdf", "Desktop 3"),
            ("Finder", "Projects", "Desktop 3"),
        ]
        let windows = samples.enumerated().map { index, sample in
            var window = Window(id: CGWindowID(index + 1), pid: pid_t(1000 + index),
                                appName: sample.0, icon: NSWorkspace.shared.icon(for: .applicationBundle))
            window.title = sample.1
            window.spaceLabel = sample.2
            return window
        }
        let base = (path as NSString).deletingPathExtension
        // The two extremes of the content behind the blur.
        HUDPanel().render(windows, selected: 2, scope: "All Spaces", rows: 6,
                          backdrop: .white, to: base + "-on-white.png")
        HUDPanel().render(windows, selected: 9, scope: "This Space", rows: 6,
                          backdrop: .black, to: base + "-on-black.png")
    }

    /// Starts with a full refresh. Then returns a report with:
    /// - the two switcher lists,
    /// - the preview cache,
    /// - the recent events,
    /// - the windows of each app.
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
        if !context.isEmpty { out += "\n== switcher state before refresh ==\n\(context)\n" }

        let tracker = WindowTracker.shared
        var clock = Date()
        tracker.refresh()
        out += String(format: "refresh: %.0f ms\n", Date().timeIntervalSince(clock) * 1000)

        let layout = Spaces.layout()
        for scope in [WindowScope.currentSpace, .allSpaces] {
            clock = Date()
            let list = tracker.list(scope, in: layout)
            out += String(format: "\n== %@ (%d) — %.1f ms ==\n", "\(scope)", list.count,
                          Date().timeIntervalSince(clock) * 1000)
            // `recent=-`: the window never had focus, so it comes after the
            // windows that had. `server`: AX has not returned the window yet.
            for window in list {
                let rank = tracker.recent.order.firstIndex(of: window.id).map(String.init) ?? "-"
                let kind = window.element == nil ? "server" : "ax"
                out += "  recent=\(rank) \(kind) id=\(window.id) [\(window.spaceLabel ?? "-")] \(window.appName) | \(window.title)\n"
            }
        }

        out += "\n== preview cache ==\n"
        out += WindowPreview.shared.cacheReport()

        out += "\n== recent switcher events ==\n"
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

    /// An automatic trace does a full AX scan on each Space change. Thus, it is
    /// off if the file `enable-trace` does not exist. The menu item always
    /// writes a trace.
    static var autoTraceEnabled: Bool {
        FileManager.default.fileExists(atPath:
            traceURL.deletingLastPathComponent().appendingPathComponent("enable-trace").path)
    }

    /// AX gives the windows of a Space only while that Space is visible. Thus,
    /// only a trace at each Space change shows what `WindowTracker` learns, and
    /// when.
    static func trace(_ reason: String, context: String = "") throws {
        var entry = "\n\n===== \(Date()) — \(reason) =====\n"
        entry += report(context: context)
        try log.appendAndWait(entry)
    }
}
