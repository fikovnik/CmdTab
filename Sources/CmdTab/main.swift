import AppKit

let arguments = CommandLine.arguments
// This report belongs to a new process, not to the running menu bar app.
if arguments.contains("--report") {
    _ = NSApplication.shared
    AXUIElement.configureTimeout()
    WindowTracker.shared.refresh()
    print(Diagnostics.report())
    Diagnostics.flush()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
