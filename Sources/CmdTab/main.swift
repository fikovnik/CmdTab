import AppKit

let arguments = CommandLine.arguments
// Read window state in this process. The report cannot inspect the menu bar process.
if arguments.contains("--report") {
    _ = NSApplication.shared
    AXUIElement.configureTimeout()
    Task { @MainActor in
        await WindowTracker.shared.refresh()
        print(Diagnostics.report())
        Diagnostics.flush()
        exit(0)
    }
    RunLoop.main.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
