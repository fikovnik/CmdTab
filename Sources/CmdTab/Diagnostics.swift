import AppKit

enum Diagnostics {
    static let traceURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CmdTab/trace.log")

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

    /// Appended on every Space change. Windows on a Space are only visible to
    /// AX while that Space is active, so this is the only way to see what the
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
