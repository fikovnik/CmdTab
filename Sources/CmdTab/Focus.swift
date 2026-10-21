import AppKit
import CmdTabModel

/// Front the target directly so macOS can select its Space without a notification wait.
@MainActor
enum Focus {
    struct Origin: Equatable, Sendable {
        let space: SpaceID
        let pid: pid_t
    }

    private struct Request: Sendable {
        let id: CGWindowID
        let pid: pid_t
        let spaces: [SpaceID]
        let isMinimized: Bool
        let element: AXReference?
        let submitted: TimeInterval
    }

    nonisolated private static let queue = FocusQueue()
    nonisolated private static let verificationQueue = DispatchQueue(
        label: "net.fikovnik.cmdtab.focus-verification", qos: .userInitiated)
    private static var pending: (generation: UInt64, id: CGWindowID)?

    static var diagnosticSummary: String {
        pending.map { "Focus: queued id=\($0.id)" } ?? "Focus: idle"
    }

    static func focus(_ window: Window) {
        let request = Request(id: window.id, pid: window.pid, spaces: window.spaces,
                              isMinimized: window.isMinimized,
                              element: window.element.map { AXReference(element: $0) },
                              submitted: ProcessInfo.processInfo.systemUptime)
        Diagnostics.note("focus requested id=\(window.id) pid=\(window.pid) spaces=\(window.spaces)")
        let generation = queue.submit { generation, isCurrent in
            run(request, generation: generation, isCurrent: isCurrent)
        }
        pending = (generation, window.id)
    }

    /// Repair only a Space that the target will replace on the same display.
    /// A visible target on another display must keep its new front app.
    nonisolated static func originToRestore(targetSpaces: [SpaceID], targetPID: pid_t,
                                           layout: SpaceLayout, activeDisplay: String?, frontPID: pid_t?) -> Origin? {
        guard let display = layout.display(identifier: activeDisplay),
              let space = display.currentSpace, let frontPID, frontPID != targetPID,
              !targetSpaces.isEmpty, !targetSpaces.contains(where: layout.visibleSpaces.contains),
              targetSpaces.contains(where: { target in display.spaces.contains { $0.id == target } })
        else { return nil }
        return Origin(space: space, pid: frontPID)
    }

    nonisolated private static func run(_ request: Request, generation: UInt64,
                                        isCurrent: @escaping @Sendable () -> Bool) {
        let layout = Spaces.layout()
        let origin = originToRestore(targetSpaces: request.spaces, targetPID: request.pid, layout: layout,
                                     activeDisplay: Spaces.activeDisplayIdentifier(),
                                     frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let app = NSRunningApplication(processIdentifier: request.pid)
        guard isCurrent() else { return }
        if app?.isHidden == true { app?.unhide() }

        var element = request.element?.element
        if request.isMinimized {
            if element == nil { element = AXUIElement.window(request.id, pid: request.pid) }
            guard isCurrent() else { return }
            if element?.set(kAXMinimizedAttribute, kCFBooleanFalse) == .invalidUIElement {
                guard isCurrent() else { return }
                element = AXUIElement.window(request.id, pid: request.pid)
                guard isCurrent() else { return }
                element?.set(kAXMinimizedAttribute, kCFBooleanFalse)
            }
        }

        guard isCurrent() else { return }
        let fronted = WindowServer.front(window: request.id, pid: request.pid)
        // A superseded command still repairs the Space that its front call changed.
        defer {
            if let origin { WindowServer.setFrontApp(origin.pid, of: origin.space) }
        }

        guard isCurrent() else { return }
        // Resolve AX only after the private calls have fronted and keyed the window.
        if element == nil { element = AXUIElement.window(request.id, pid: request.pid) }
        guard isCurrent() else { return }
        var raise = element?.perform(kAXRaiseAction)
        if raise == .invalidUIElement {
            guard isCurrent() else { return }
            element = AXUIElement.window(request.id, pid: request.pid)
            guard isCurrent() else { return }
            raise = element?.perform(kAXRaiseAction)
        }

        let reference = element.map { AXReference(element: $0) }
        let raiseCode = raise?.rawValue
        let elapsed = (ProcessInfo.processInfo.systemUptime - request.submitted) * 1000
        Task { @MainActor in
            if pending?.generation == generation { pending = nil }
            if !fronted { Diagnostics.error("could not front window id=\(request.id) pid=\(request.pid)") }
            Diagnostics.note(String(format: "focus id=%u fronted=%@ raise=%@ elapsed=%.0f ms",
                                    request.id, String(fronted), raiseCode.map(String.init) ?? "no element", elapsed))
            guard isCurrent() else { return }
            if let reference { WindowTracker.shared.replaceElement(request.id, with: reference.element) }
        }

        verificationQueue.asyncAfter(deadline: .now() + 0.3) {
            guard isCurrent() else { return }
            let focused = AXUIElement.application(request.pid).element(kAXFocusedWindowAttribute)?.windowID
            Task { @MainActor in
                guard isCurrent() else { return }
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if let focused, front == request.pid {
                    WindowTracker.shared.focusReported(focused, pid: request.pid)
                }
                Diagnostics.note("focus took=\(focused == request.id && front == request.pid) id=\(request.id) focused=\(focused.map(String.init) ?? "nil")")
            }
        }
    }
}
