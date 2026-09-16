import ApplicationServices

/// Private but long-stable AX SPI: maps an AXUIElement window to its CGWindowID.
/// This is the only way to correlate the Accessibility window tree with the
/// CGWindowList z-order without requesting Screen Recording permission.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
