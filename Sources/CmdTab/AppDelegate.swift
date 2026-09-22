import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let switcher = Switcher()
    private lazy var tap = HotkeyTap(switcher: switcher)
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var spaces = SpaceMap()
    /// Appended to the desktop number: "…" until the tap is up, "!" if it
    /// could not be created.
    private var tapMarker = "…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        WindowRegistry.shared.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Desktops come and go, so renumber rather than just re-read.
                self?.spaces = SpaceMap()
                self?.updateStatusTitle()
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

    /// A full-screen Space has no desktop number, so it keeps the tab glyph.
    private func updateStatusTitle() {
        let desktop = spaces.number(forSpace: WindowServer.activeSpace).map(String.init) ?? "⇥"
        statusItem?.button?.title = desktop + tapMarker
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

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
