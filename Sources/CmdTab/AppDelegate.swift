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
    /// The suffix of the menu bar title. "…" until the event tap starts, "!"
    /// if the event tap cannot start.
    private var tapMarker = "…"
    /// "⚠" if the config file has errors. Else a typo removes a binding, and
    /// the user does not see why.
    private var configMarker = ""
    private var menuIcon = MenuIcon.desktopNumber
    private var configErrors: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Send the messages of `CmdTabConfig` to `Diagnostics`, not to `NSLog`.
        // `Log` can call the sink on any queue, for example the queue of a
        // shell action. Thus, the sink continues on the main queue.
        Log.use { message in
            DispatchQueue.main.async { MainActor.assumeIsolated { Diagnostics.note(message) } }
        }

        applyConfig()
        installStatusItem()
        WindowTracker.shared.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Focus.spaceDidChange()
                WindowTracker.shared.scheduleRefresh()
                self.updateStatusTitle()
                #if DIAGNOSTICS
                guard Diagnostics.autoTraceEnabled else { return }
                Diagnostics.trace("activeSpaceDidChange")
                #endif
            }
        }

        if requestAccessibility() {
            startTap()
        } else {
            // The user gives the permission in System Settings, which is a
            // different process. Thus, poll until `AXIsProcessTrusted` is true.
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

    /// The event tap keeps an unretained pointer to `tap`. Thus, stop the tap
    /// before the process ends.
    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
    }

    private func requestAccessibility() -> Bool {
        // Swift imports `kAXTrustedCheckOptionPrompt` as a mutable global, and
        // Swift 6 does not let code read it. Its value is always this string.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func startTap() {
        guard tap.start() else {
            tapMarker = "!"
            updateStatusTitle()
            NSLog("CmdTab: failed to create event tap")
            return
        }
        tapMarker = ""
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        let icon: String
        switch menuIcon {
        case .desktopNumber:
            // A full-screen Space has no desktop number. It shows the tab glyph.
            let layout = Spaces.layout()
            let space = layout.display(identifier: Spaces.activeDisplayIdentifier())?.currentSpace
            icon = space.flatMap(layout.desktopNumber(of:)).map(String.init) ?? "⇥"
        case .literal(let text):
            icon = text
        }
        statusItem?.button?.title = icon + configMarker + tapMarker
    }

    /// Reads the config and applies it. Each call replaces all config state,
    /// so the Reload menu item can call it again.
    private func applyConfig() {
        let config = Config.load()
        let installer = ConfigInstaller()
        for binding in config.bindings {
            binding.action.bind(binding.chord, into: installer)
        }

        tap.bindings = installer.bindings
        menuIcon = config.menuIcon
        configErrors = config.errors
        configMarker = config.errors.isEmpty ? "" : "⚠"
        for error in config.errors { Diagnostics.note("config: \(error)") }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        #if DIAGNOSTICS
        menu.addItem(withTitle: "Write Diagnostics",
                     action: #selector(writeDiagnostics),
                     keyEquivalent: "").target = self
        #endif
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

    #if DIAGNOSTICS
    @objc private func writeDiagnostics() {
        Diagnostics.trace("menu")
        NSWorkspace.shared.selectFile(Diagnostics.traceURL.path,
                                      inFileViewerRootedAtPath: Diagnostics.traceURL.deletingLastPathComponent().path)
    }
    #endif

    /// Screen Recording gives the previews and `kCGWindowName`, the current
    /// title of a window on another Space. macOS keeps the decision for the
    /// life of the process, so a grant has an effect only after a relaunch.
    /// Thus, CmdTab asks from a menu item, not at launch.
    @objc private func enableScreenRecording() {
        WindowPreview.requestPermission()
    }

    /// Opens the config file. If the file does not exist, writes a starter
    /// config first, so that the user does not need the README.
    @objc private func openConfiguration() {
        let url = Config.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                      withIntermediateDirectories: true)
            try? Data(AppDelegate.starterConfig.utf8).write(to: url)
        }
        NSWorkspace.shared.open(url)
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

    /// Contains the defaults, not an empty object, so that the user sees the
    /// file format and the action names without documentation.
    private static let starterConfig = """
    {
      "keys": {
        "shift-ctrl-alt-cmd-left":  "tile:left",
        "shift-ctrl-alt-cmd-right": "tile:right",
        "shift-ctrl-alt-cmd-up":    "tile:top",
        "shift-ctrl-alt-cmd-down":  "tile:bottom",

        "shift-alt-cmd-f": "toggle-fullscreen",
        "shift-alt-cmd-m": "toggle-maximize",

        "shift-ctrl-alt-cmd-e": "shell:open -a Finder ~"
      },
      "switch-all-windows": { "trigger": "cmd-tab" },
      "switch-current-app": { "trigger": "cmd-grave" },
      "menu": { "icon": "desktop-number" }
    }

    """

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
