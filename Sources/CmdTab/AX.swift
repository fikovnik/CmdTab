import ApplicationServices

/// Typed access to the AXUIElement C API.
///
/// An attribute value comes back as an untyped `CFTypeRef`. A cast to a CF
/// type always succeeds in Swift, so an element value must have its type ID
/// checked before use.
extension AXUIElement {
    /// The element of an application. Each call to it waits for at most
    /// `timeout` seconds, so a hung app cannot block CmdTab for longer.
    static func application(_ pid: pid_t, timeout: Float = 0.1) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    func value(_ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }

    func bool(_ attribute: String) -> Bool? { value(attribute) as? Bool }

    func element(_ attribute: String) -> AXUIElement? {
        guard let raw = value(attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement]? { value(attribute) as? [AXUIElement] }

    /// Several attributes in one call to the app. A missing attribute gives nil.
    func values(_ attributes: [String]) -> [CFTypeRef?] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, attributes as CFArray, [], &raw) == .success,
              let values = raw as? [CFTypeRef], values.count == attributes.count
        else { return attributes.map { _ in nil } }
        // The call puts an `AXValue` of type `.axError` where an attribute is missing.
        return values.map { value in
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                return nil
            }
            return value
        }
    }

    /// The WindowServer ID of a window element. A descendant of a window, for
    /// example a button, gives the ID of its window.
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(self, &id) == .success, id != 0 else { return nil }
        return id
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(self, &pid) == .success else { return nil }
        return pid
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    /// The window of app `pid` with this ID, if it is on a visible Space.
    /// `kAXWindows` contains only the windows on visible Spaces, and the
    /// minimized windows.
    static func window(_ id: CGWindowID, pid: pid_t) -> AXUIElement? {
        application(pid).elements(kAXWindowsAttribute)?.first { $0.windowID == id }
    }
}
