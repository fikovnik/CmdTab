import ApplicationServices

/// Typed access to AX. Check CF type IDs before casts to CF types.
@MainActor
extension AXUIElement {
    /// Set the timeout for every AX element in this process, including notification elements.
    static func configureTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    func value(_ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(self, attribute as CFString, &raw)
        recordFailure(status, operation: attribute)
        guard status == .success else { return nil }
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
        let status = AXUIElementCopyMultipleAttributeValues(self, attributes as CFArray, [], &raw)
        recordFailure(status, operation: attributes.joined(separator: ","))
        guard status == .success, let values = raw as? [CFTypeRef], values.count == attributes.count
        else { return attributes.map { _ in nil } }
        // The call puts an `AXValue` of type `.axError` where an attribute is missing.
        return values.map { value in
            if CFGetTypeID(value) == CFNullGetTypeID() { return nil }
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
        let status = AXUIElementSetAttributeValue(self, attribute as CFString, value)
        recordFailure(status, operation: attribute)
        return status
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        let status = AXUIElementPerformAction(self, action as CFString)
        recordFailure(status, operation: action)
        return status
    }

    private func recordFailure(_ status: AXError, operation: String) {
        if status == .cannotComplete {
            Diagnostics.error("AX request failed or timed out pid=\(pid ?? 0) operation=\(operation)")
        } else if status != .success {
            Diagnostics.note("AX request pid=\(pid ?? 0) operation=\(operation) error=\(status.rawValue)")
        }
    }

    /// The AX window with this ID. AX can omit windows on other Spaces.
    static func window(_ id: CGWindowID, pid: pid_t) -> AXUIElement? {
        application(pid).elements(kAXWindowsAttribute)?.first { $0.windowID == id }
    }
}
