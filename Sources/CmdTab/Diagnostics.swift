import AppKit

enum Diagnostics {
    /// Rolling log of switcher activity, so a misfire can be read back after
    /// the fact instead of reproduced on demand.
    private static var events: [String] = []

    static func note(_ text: String) {
        let now = Date().timeIntervalSince1970
        events.append(String(format: "%9.3f  %@", now.truncatingRemainder(dividingBy: 100_000), text))
        if events.count > 80 { events.removeFirst(events.count - 80) }
    }

    static let traceURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CmdTab/trace.log")

    /// Draw the HUD offscreen with synthetic content that exercises the layout:
    /// more rows than fit, long titles, Space badges, varied app counts.
    static func renderHUD(to path: String) {
        let placeholder = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let samples: [(String, String, String?)] = [
            ("Ghostty", "cmd-tab@pokhara.local: ✳ Claude Code", "Desktop 2"),
            ("Ghostty", "NI-APR-0@kathmandu: ✳ polymorphic-type-analysis", "Desktop 2"),
            ("Google Chrome", "v8/src/codegen/arm64/assembler-arm64.cc at main · v8/v8 — an overlong title that has to be truncated somewhere", "Desktop 1"),
            ("Slack", "#general", "Desktop 1"),
            ("Obsidian", "Daily note", "Desktop 1"),
            ("Spotify", "", "Desktop 1"),
            ("Microsoft Teams", "Calendar", "Desktop 1"),
            ("Zotero", "My Library", "Desktop 1"),
            ("Preview", "paper.pdf", "Desktop 3"),
            ("Finder", "Projects", "Desktop 3"),
        ]
        let windows = samples.enumerated().map { index, sample in
            WindowRef(id: CGWindowID(index + 1), pid: pid_t(1000 + index),
                      appName: sample.0, title: sample.1,
                      element: placeholder,
                      icon: NSWorkspace.shared.icon(for: .applicationBundle),
                      spaceLabel: sample.2)
        }
        let base = (path as NSString).deletingPathExtension
        // Both extremes of what can sit behind the blur.
        HUDPanel().render(windows, selected: 2, scope: "All Spaces", rows: 6,
                          backdrop: .white, to: base + "-on-white.png")
        HUDPanel().render(windows, selected: 9, scope: "This Space", rows: 6,
                          backdrop: .black, to: base + "-on-black.png")
    }

    /// What both switcher scopes currently resolve to, plus per-app AX counts.
    static func report() -> String {
        var out = "AXIsProcessTrusted: \(AXIsProcessTrusted())\n"

        var clock = Date()
        let current = WindowEnumerator.currentSpaceWindowsMRU()
        out += String(format: "\n== Cmd+Tab scope (%d) — %.0f ms ==\n",
                      current.count, Date().timeIntervalSince(clock) * 1000)
        for window in current {
            out += "  \(window.appName) | \(window.title)\n"
        }

        clock = Date()
        let all = WindowEnumerator.allSpacesWindowsMRU()
        out += String(format: "\n== Esc scope (%d) — %.0f ms ==\n",
                      all.count, Date().timeIntervalSince(clock) * 1000)
        for window in all {
            out += "  [\(window.spaceLabel ?? "-")] \(window.appName) | \(window.title)\n"
        }

        out += "\n== recent switcher events ==\n"
        for event in events { out += "  \(event)\n" }

        var onScreenByPID: [pid_t: Int] = [:]
        for candidate in WindowEnumerator.candidates(onScreenOnly: true) {
            onScreenByPID[candidate.pid, default: 0] += 1
        }

        var axByPID: [pid_t: Int] = [:]
        for window in WindowEnumerator.axWindowsOfAllApps() {
            axByPID[window.pid, default: 0] += 1
        }

        out += "\n== apps ==\n"
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let pid = app.processIdentifier
            out += "  \(app.localizedName ?? "?") pid=\(pid) hidden=\(app.isHidden)"
            out += " cgOnScreen=\(onScreenByPID[pid] ?? 0)"
            out += " ax=\(axByPID[pid] ?? 0)"
            out += " inEscScope=\(all.filter { $0.pid == pid }.count)\n"
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
