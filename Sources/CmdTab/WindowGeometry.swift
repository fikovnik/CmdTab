import AppKit
import ApplicationServices
import CmdTabModel

/// Read and set AX window frames. AX coordinates have a top left origin.
/// Convert AppKit screen frames with Layout.flip before use.
@MainActor
enum WindowGeometry {
    struct Target {
        let window: AXUIElement
        let app: AXUIElement
        let id: CGWindowID
    }

    /// The focused window of the frontmost app.
    static func focused() -> Target? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            Diagnostics.error("no frontmost application")
            return nil
        }
        let app = AXUIElement.application(pid)
        guard let window = app.element(kAXFocusedWindowAttribute), let id = window.windowID else {
            Diagnostics.error("no focused window for pid \(pid)")
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

    /// Set position, size, then position. Apps can constrain size on the old display or move the window during a resize.
    static func setFrame(_ rect: CGRect, on target: Target) {
        // Temporarily clear AXEnhancedUserInterface. It can prevent position and size changes in AppKit apps.
        let enhanced = target.app.bool("AXEnhancedUserInterface")
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
        window.bool(fullScreenAttribute)
    }

    static func setFullScreen(_ on: Bool, for window: AXUIElement) -> Bool {
        setAXBool(window, fullScreenAttribute, on)
    }

    /// The visible frame of the display with the largest window intersection, in AX coordinates.
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

    /// The maximum y coordinate of the AppKit primary display. Use it for every coordinate conversion.
    static func primaryMaxY() -> CGFloat? {
        let zero = NSScreen.screens.first { $0.frame.origin == .zero }
        return (zero ?? NSScreen.screens.first)?.frame.maxY
    }

    // MARK: - AX plumbing

    private static func axValue<T: BitwiseCopyable>(_ element: AXUIElement, _ attribute: String,
                                   _ type: AXValueType, _ empty: T) -> T? {
        guard let raw = element.value(attribute), CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var out = empty
        guard AXValueGetValue(raw as! AXValue, type, &out) else { return nil }
        return out
    }

    private static func setPosition(_ point: CGPoint, on window: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        let err = window.set(kAXPositionAttribute, value)
        if err != .success { Diagnostics.error("set position failed: \(err.rawValue)") }
    }

    private static func setSize(_ size: CGSize, on window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        let err = window.set(kAXSizeAttribute, value)
        if err != .success { Diagnostics.error("set size failed: \(err.rawValue)") }
    }

    @discardableResult
    private static func setAXBool(_ element: AXUIElement, _ attribute: String,
                                  _ on: Bool) -> Bool {
        element.set(attribute, on as CFBoolean) == .success
    }
}

private extension CGRect {
    /// Zero for `.null`, the result of an intersection with no overlap.
    var area: CGFloat { isNull ? 0 : width * height }
}
