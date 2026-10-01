import AppKit
import ApplicationServices
import CmdTabConfig

/// Reads and writes the frame of the focused window with AX.
///
/// All rects here use the coordinates of AX and `CGWindowList`, with the origin
/// at the top left. `Layout` uses the same coordinates. `visibleFrame` flips
/// the `NSScreen` rects, which have the origin at the bottom left.
@MainActor
enum WindowGeometry {
    /// The AX timeout. This code runs in the event tap callback, and the system
    /// disables a slow tap.
    private static let timeout: Float = 0.1

    struct Target {
        let window: AXUIElement
        let app: AXUIElement
        let id: CGWindowID
    }

    /// The focused window of the frontmost app.
    static func focused() -> Target? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            Log.note("no frontmost application")
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            Log.note("no focused window for pid \(pid)")
            return nil
        }
        let window = value as! AXUIElement

        var id = CGWindowID(0)
        guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else {
            Log.note("could not resolve a window id for pid \(pid)")
            return nil
        }
        return Target(window: window, app: app, id: id)
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = axValue(window, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = axValue(window, kAXSizeAttribute, .cgSize, CGSize.zero)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Sets the position, then the size, then the position again.
    ///
    /// An app can limit the size to the old screen while the window is still
    /// on that screen. An app can also move the window when the size changes.
    /// This sequence gives the correct frame in the two cases.
    static func setFrame(_ rect: CGRect, on target: Target) {
        // If `AXEnhancedUserInterface` is on, AppKit apps do not set the
        // position and the size correctly. An assistive app can set it and not
        // clear it. Thus, clear it for the change, then restore it.
        let enhanced = axBool(target.app, "AXEnhancedUserInterface")
        if enhanced == true {
            setAXBool(target.app, "AXEnhancedUserInterface", false)
        }
        defer {
            if enhanced == true { setAXBool(target.app, "AXEnhancedUserInterface", true) }
        }

        setPosition(rect.origin, on: target.window)
        setSize(rect.size, on: target.window)
        setPosition(rect.origin, on: target.window)
    }

    /// A string, because Swift does not import `kAXFullScreenAttribute`.
    private static let fullScreenAttribute = "AXFullScreen"

    static func isFullScreen(_ window: AXUIElement) -> Bool? {
        axBool(window, fullScreenAttribute)
    }

    static func setFullScreen(_ on: Bool, for window: AXUIElement) -> Bool {
        setAXBool(window, fullScreenAttribute, on)
    }

    /// The visible frame of the screen that contains most of `windowFrame`, in
    /// AX coordinates. The visible frame does not include the menu bar and the
    /// Dock.
    static func visibleFrame(containing windowFrame: CGRect) -> CGRect? {
        guard let primaryMaxY = primaryMaxY() else { return nil }
        let screens = NSScreen.screens.map {
            (screen: $0, frame: Layout.flip($0.frame, primaryMaxY: primaryMaxY))
        }
        // A window on two displays belongs to the display with the largest
        // part of the window, as in macOS.
        let best = screens.max {
            $0.frame.intersection(windowFrame).area < $1.frame.intersection(windowFrame).area
        }
        guard let best else { return nil }
        if best.frame.intersection(windowFrame).isNull {
            // The window is on no display. Use the screen with the key window.
            guard let main = NSScreen.main else { return nil }
            return Layout.flip(main.visibleFrame, primaryMaxY: primaryMaxY)
        }
        return Layout.flip(best.screen.visibleFrame, primaryMaxY: primaryMaxY)
    }

    /// The height of the display at the zero origin. Each flip between AppKit
    /// and AX coordinates uses it.
    static func primaryMaxY() -> CGFloat? {
        let zero = NSScreen.screens.first { $0.frame.origin == .zero }
        return (zero ?? NSScreen.screens.first)?.frame.maxY
    }

    // MARK: - AX plumbing

    private static func axValue<T>(_ element: AXUIElement, _ attribute: String,
                                   _ type: AXValueType, _ empty: T) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var out = empty
        guard AXValueGetValue(raw as! AXValue, type, &out) else { return nil }
        return out
    }

    private static func setPosition(_ point: CGPoint, on window: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        let err = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        if err != .success { Log.note("set position failed: \(err.rawValue)") }
    }

    private static func setSize(_ size: CGSize, on window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        let err = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        if err != .success { Log.note("set size failed: \(err.rawValue)") }
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success
        else { return nil }
        return raw as? Bool
    }

    @discardableResult
    private static func setAXBool(_ element: AXUIElement, _ attribute: String,
                                  _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString,
                                     on as CFBoolean) == .success
    }
}

private extension CGRect {
    /// Zero for `.null`, the result of an intersection with no overlap.
    var area: CGFloat { isNull ? 0 : width * height }
}
