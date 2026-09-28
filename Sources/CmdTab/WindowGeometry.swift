import AppKit
import ApplicationServices
import CmdTabConfig

/// Reading and writing the focused window's frame over the Accessibility API.
///
/// Everything returned and accepted here is in the top-left origin space AX
/// and `CGWindowList` use, so it lines up with `Layout` without further
/// conversion. `NSScreen` rects are the one exception and are flipped on the
/// way through `visibleFrame`.
@MainActor
enum WindowGeometry {
    /// Same 100 ms budget the switcher uses, for the same reason: this runs on
    /// the event tap callback, and a tap that overruns gets disabled.
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

    /// Position, size, then position again.
    ///
    /// Two passes because an app may clamp the size it is given while the
    /// window is still on the old screen, and may shift the window when the
    /// size finally changes. Moving first, then sizing, then correcting the
    /// position is what survives both.
    static func setFrame(_ rect: CGRect, on target: Target) {
        // `AXEnhancedUserInterface` makes position and size writes misbehave in
        // AppKit apps, and it gets switched on by any assistive client,
        // including this app's own debug diagnostics, which never turns it back
        // off. Take it down for the duration and restore it.
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

    /// Spelled out because `kAXFullScreenAttribute` is not exported to Swift,
    /// the same way `AXTrustedCheckOptionPrompt` is spelled out in AppDelegate.
    private static let fullScreenAttribute = "AXFullScreen"

    static func isFullScreen(_ window: AXUIElement) -> Bool? {
        axBool(window, fullScreenAttribute)
    }

    static func setFullScreen(_ on: Bool, for window: AXUIElement) -> Bool {
        setAXBool(window, fullScreenAttribute, on)
    }

    /// The visible frame (menu bar and Dock excluded) of the screen holding
    /// most of `windowFrame`, in AX coordinates.
    static func visibleFrame(containing windowFrame: CGRect) -> CGRect? {
        guard let primaryMaxY = primaryMaxY() else { return nil }
        let screens = NSScreen.screens.map {
            (screen: $0, frame: Layout.flip($0.frame, primaryMaxY: primaryMaxY))
        }
        // Largest overlap, because a window straddling two displays belongs to
        // whichever one it is mostly on, the same rule macOS uses.
        let best = screens.max {
            $0.frame.intersection(windowFrame).area < $1.frame.intersection(windowFrame).area
        }
        guard let best else { return nil }
        if best.frame.intersection(windowFrame).isNull {
            // Entirely off every display. Fall back to wherever the keyboard is.
            guard let main = NSScreen.main else { return nil }
            return Layout.flip(main.visibleFrame, primaryMaxY: primaryMaxY)
        }
        return Layout.flip(best.screen.visibleFrame, primaryMaxY: primaryMaxY)
    }

    /// The height of the display whose origin is zero, which is the reference
    /// for every flip between AppKit and AX coordinates.
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
    /// `.null` has an infinite-ish area, so guard it before comparing.
    var area: CGFloat { isNull ? 0 : width * height }
}
