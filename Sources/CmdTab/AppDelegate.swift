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
    /// Appended to the desktop number: "…" until the tap is up, "!" if it
    /// could not be created.
    private var tapMarker = "…"
    /// Appended when the config file has problems, so a typo is visible rather
    /// than just silently costing you a binding.
    private var configMarker = ""
    private var menuIcon = MenuIcon.desktopNumber
    private var configErrors: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Send the config target's complaints to the same ring buffer as
        // everything else, rather than to NSLog.
        // Hops to main because this is called from wherever the complaint
        // came from, including the queue a shell action was spawned on.
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
            // Permission is granted out-of-process. Poll until the user flips it.
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

    /// The event tap holds an unretained pointer to `tap`, so tear it down
    /// deliberately rather than leaving the order to process teardown.
    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
    }

    private func requestAccessibility() -> Bool {
        // Spelled out because `kAXTrustedCheckOptionPrompt` is imported as a
        // mutable global, which Swift 6 will not let us read. Its value has been
        // this string since the option existed.
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
            // A full-screen Space has no desktop number, so it keeps the tab glyph.
            let layout = Spaces.layout()
            let space = layout.display(identifier: Spaces.activeDisplayIdentifier())?.currentSpace
            icon = space.flatMap(layout.desktopNumber(of:)).map(String.init) ?? "⇥"
        case .literal(let text):
            icon = text
        }
        statusItem?.button?.title = icon + configMarker + tapMarker
    }

    /// Read the config and apply it. Safe to call again, which is what the
    /// Reload menu item does.
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

    /// Screen Recording buys thumbnails and `kCGWindowName`, the only source of
    /// a title for an off-Space window. macOS caches the decision per process,
    /// so the grant only takes effect on relaunch, hence a menu item rather
    /// than something done at launch.
    @objc private func enableScreenRecording() {
        WindowPreview.requestPermission()
    }

    /// Opens the config file, creating a starter one the first time so the
    /// feature is discoverable rather than something you have to read the
    /// README to find.
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

    /// Spells out the defaults rather than starting empty, so the shape of the
    /// file and the action names are visible without documentation.
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
