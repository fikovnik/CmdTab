import AppKit

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render-hud") {
    let path = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "/tmp/cmdtab-hud.png"
    Diagnostics.renderHUD(to: path)
    exit(0)
}

// Same report the menu item writes, on stdout. The menu needs a GUI session.
// This does not, so it works over ssh and in a build script.
if arguments.contains("--report") {
    _ = NSApplication.shared
    print(Diagnostics.report())
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
