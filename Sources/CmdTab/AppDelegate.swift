import AppKit
import ApplicationServices

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
            Diagnostics.trace("activeSpaceDidChange")
        }

        if requestAccessibility() {
            startTap()
        } else {
            // Permission is granted out-of-process. Poll until the user flips it.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.permissionTimer = nil
                self?.startTap()
            }
        }
    }

    private func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
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

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
