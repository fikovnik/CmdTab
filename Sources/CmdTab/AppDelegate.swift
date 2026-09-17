import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let switcher = Switcher()
    private lazy var tap = HotkeyTap(switcher: switcher)
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        WindowRegistry.shared.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard Diagnostics.autoTraceEnabled else { return }
                Diagnostics.trace("activeSpaceDidChange")
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
            statusItem?.button?.title = "⇥!"
            NSLog("CmdTab: failed to create event tap")
            return
        }
        statusItem?.button?.title = "⇥"
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⇥…"

        let menu = NSMenu()
        menu.addItem(withTitle: "Write Diagnostics",
                     action: #selector(writeDiagnostics),
                     keyEquivalent: "").target = self
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
    }

    @objc private func writeDiagnostics() {
        Diagnostics.trace("menu")
        NSWorkspace.shared.selectFile(Diagnostics.traceURL.path,
                                      inFileViewerRootedAtPath: Diagnostics.traceURL.deletingLastPathComponent().path)
    }

    /// Screen Recording buys two things: thumbnails, and `kCGWindowName`, the
    /// only source of a title for a window on a Space AX cannot describe. The
    /// grant only takes effect on relaunch, because macOS caches the decision
    /// per process, so this is a menu item rather than something done at launch.
    @objc private func enableScreenRecording() {
        WindowPreview.requestPermission()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
