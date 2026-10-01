import AppKit
import os

#if DIAGNOSTICS
/// Read with `log stream --predicate 'subsystem == "net.fikovnik.cmdtab"'`.
private let logger = Logger(subsystem: "net.fikovnik.cmdtab", category: "diagnostics")
#endif

@MainActor
enum Diagnostics {
    /// Rolling log of switcher activity, so a misfire can be read back after
    /// the fact instead of reproduced on demand.
    ///
    /// Only `report` and `trace` ever read it, and both are debug-only, so in a
    /// release build the whole thing is dead weight. Hence the flag below.
    private static var events: [String] = []

    /// One AX failure burst is a dozen lines at 100 ms apart, so a buffer that
    /// only just holds one evicts whatever it was you wanted to see around it.
    private static let capacity = 300

    /// `@autoclosure` so a release build does not even build the string: every
    /// call site interpolates, and the AX failure path runs hundreds of times.
    static func note(_ text: @autoclosure () -> String) {
        #if DIAGNOSTICS
        let now = Date().timeIntervalSince1970
        let message = text()
        logger.notice("\(message, privacy: .public)")
        events.append(String(format: "%9.3f  %@",
                             now.truncatingRemainder(dividingBy: 100_000), message))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        #endif
    }

    static let traceURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CmdTab/trace.log")

    /// Draw the HUD offscreen with synthetic content that exercises the layout:
    /// more rows than fit, long titles, Space badges, varied app counts.
    static func renderHUD(to path: String) {
        // Resolve the accent colour and appearance the panel draws with. Both
        // want an initialized app, and this path runs before `NSApp.run`.
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
        // Both extremes of what can sit behind the blur.
        HUDPanel().render(windows, selected: 2, scope: "All Spaces", rows: 6,
                          backdrop: .white, to: base + "-on-white.png")
        HUDPanel().render(windows, selected: 9, scope: "This Space", rows: 6,
                          backdrop: .black, to: base + "-on-black.png")
    }

    /// Both switcher lists, the preview cache, the recent events and the
    /// windows of each app. Starts with a full refresh.
    static func report() -> String {
        var out = "AXIsProcessTrusted: \(AXIsProcessTrusted())\n"
        out += "ScreenRecording: \(CGPreflightScreenCaptureAccess())\n"

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

    /// Auto-tracing costs a full Accessibility walk per Space change, so it is
    /// off unless the marker file exists. The menu item ignores this.
    static var autoTraceEnabled: Bool {
        FileManager.default.fileExists(atPath:
            traceURL.deletingLastPathComponent().appendingPathComponent("enable-trace").path)
    }

    /// Windows on a Space are only visible to AX while that Space is active, so
    /// a trace written at Space-change time is the only way to see what the
    /// registry learns and when.
    static func trace(_ reason: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: traceURL.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)

        if let size = try? manager.attributesOfItem(atPath: traceURL.path)[.size] as? Int,
           size > 512 * 1024 {
            try? manager.removeItem(at: traceURL)
        }

        var entry = "\n\n===== \(Date()) — \(reason) =====\n"
        entry += report()

        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: traceURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: traceURL)
        }
    }
}
