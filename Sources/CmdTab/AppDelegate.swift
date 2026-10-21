import AppKit
import ApplicationServices
import CmdTabConfig

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let switcher = Switcher()
    private let host = WindowActionHost()
    private lazy var tap = HotkeyTap(switcher: switcher, host: host)
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    /// Show "…" before tap creation and "!" after a tap creation failure.
    private var tapMarker = "…"
    /// Show "⚠" when the configuration has errors.
    private var configMarker = ""
    private var menuIcon = MenuIcon.desktopNumber
    private var configErrors: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AXUIElement.configureTimeout()
        applyConfig()
        installStatusItem()
        Diagnostics.note("launch: logging=\(Diagnostics.isLoggingEnabled)")
        WindowTracker.shared.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.switcher.screenParametersChanged()
                WindowTracker.shared.scheduleRefresh()
                self?.updateStatusTitle()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Focus.spaceDidChange()
                WindowTracker.shared.scheduleRefresh()
                self.updateStatusTitle()
                Diagnostics.note("active Space changed")
            }
        }

        if requestAccessibility() {
            startTap()
        } else {
            // Wait for the user to permit Accessibility access.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                MainActor.assumeIsolated {
                    self?.permissionTimer = nil
                    self?.startTap()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        Diagnostics.flush()
    }

    private func requestAccessibility() -> Bool {
        // Use the constant string. Swift imports the C constant as a mutable global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func startTap() {
        guard tap.start() else {
            tapMarker = "!"
            updateStatusTitle()
            Diagnostics.error("could not create event tap")
            return
        }
        WindowTracker.shared.scheduleRefresh()
        tapMarker = ""
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        let icon: String
        switch menuIcon {
        case .desktopNumber:
            // Full screen Spaces have no desktop number. Use the tab glyph for these Spaces.
            let layout = Spaces.layout()
            let space = layout.display(identifier: Spaces.activeDisplayIdentifier())?.currentSpace
            icon = space.flatMap(layout.desktopNumber(of:)).map(String.init) ?? "⇥"
        case .literal(let text):
            icon = text
        }
        statusItem?.button?.title = icon + configMarker + tapMarker
    }

    /// Replace the configuration snapshot on launch and reload.
    private func applyConfig() {
        let config = Config.load()
        tap.bindings = config.bindings
        menuIcon = config.menuIcon
        configErrors = config.errors
        configMarker = config.errors.isEmpty ? "" : "⚠"
        for error in config.errors { Diagnostics.error("config: \(error)") }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        let logging = menu.addItem(withTitle: "Diagnostic Logging",
                                   action: #selector(toggleDiagnosticLogging(_:)),
                                   keyEquivalent: "")
        logging.target = self
        logging.state = Diagnostics.isLoggingEnabled ? .on : .off
        menu.addItem(withTitle: "Write Diagnostics",
                     action: #selector(writeDiagnostics),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Accessibility Settings…",
                     action: #selector(openAccessibilitySettings),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Enable Titles & Previews…",
                     action: #selector(enableScreenRecording),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Configuration…",
                     action: #selector(openConfiguration),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload Configuration",
                     action: #selector(reloadConfiguration),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CmdTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        statusItem = item
        updateStatusTitle()
    }

    @objc private func toggleDiagnosticLogging(_ sender: NSMenuItem) {
        Diagnostics.setLoggingEnabled(!Diagnostics.isLoggingEnabled)
        sender.state = Diagnostics.isLoggingEnabled ? .on : .off
        if Diagnostics.isLoggingEnabled {
            Diagnostics.note(tap.diagnosticSummary)
            Diagnostics.note(switcher.diagnosticSummary)
        }
    }

    @objc private func writeDiagnostics() {
        do {
            try Diagnostics.trace("menu", context: tap.diagnosticSummary + "\n" + switcher.diagnosticSummary
                                  + "\nConfiguration errors: " + configErrors.joined(separator: "; "))
            NSWorkspace.shared.selectFile(Diagnostics.traceURL.path,
                                          inFileViewerRootedAtPath: Diagnostics.traceURL.deletingLastPathComponent().path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not write diagnostics"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Screen Recording permits previews and titles from other Spaces. A new permission can require an app restart.
    @objc private func enableScreenRecording() {
        WindowPreview.requestPermission()
    }

    /// If the file does not exist, create the example configuration.
    @objc private func openConfiguration() {
        let url = Config.defaultURL
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(AppDelegate.starterConfig.utf8).write(to: url, options: .withoutOverwriting)
            }
            guard NSWorkspace.shared.open(url) else {
                throw CocoaError(.fileReadUnknown)
            }
        } catch {
            Diagnostics.error("could not open configuration: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Could not open configuration"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func reloadConfiguration() {
        applyConfig()
        updateStatusTitle()
        guard !configErrors.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Configuration problems"
        alert.informativeText = configErrors.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// The example includes local actions. The built-in defaults include only the two switchers.
    private static let starterConfig = """
    {
      "keys": {
        "cmd-tab": "switch-all-windows",
        "cmd-grave": "switch-app-windows",

        "shift-ctrl-alt-cmd-left":  "tile:left",
        "shift-ctrl-alt-cmd-right": "tile:right",
        "shift-ctrl-alt-cmd-up":    "tile:top",
        "shift-ctrl-alt-cmd-down":  "tile:bottom",

        "shift-alt-cmd-f": "toggle-fullscreen",
        "shift-alt-cmd-m": "toggle-maximize",

        "shift-ctrl-alt-cmd-e": "shell:open -a Finder ~"
      },
      "menu": { "icon": "desktop-number" }
    }

    """

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
