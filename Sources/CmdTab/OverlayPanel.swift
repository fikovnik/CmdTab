import AppKit

/// Reuses an overlay only while the display setup is unchanged. After a
/// display disconnect, macOS can leave an old panel attached to one Space,
/// even though AppKit still reports `canJoinAllSpaces` and `isVisible`.
@MainActor
final class OverlayPanel {
    struct Display: Equatable {
        let id: UInt32
        let frame: NSRect
        let scale: CGFloat
    }

    private(set) var panel: NSPanel?
    private var displays: [Display]?
    private let currentDisplays: @MainActor () -> [Display]

    init(currentDisplays: @escaping @MainActor () -> [Display] = OverlayPanel.displayConfiguration) {
        self.currentDisplays = currentDisplays
    }

    static func displayConfiguration() -> [Display] {
        NSScreen.screens.map {
            Display(id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                    frame: $0.frame, scale: $0.backingScaleFactor)
        }.sorted { $0.id < $1.id }
    }

    func ensurePanel(containing view: NSView) -> NSPanel {
        let current = currentDisplays()
        if displays != current { reset() }
        if let panel { return panel }

        let (panel, content) = makeOverlayPanel()
        content.addSubview(view)
        self.panel = panel
        displays = current
        Diagnostics.note("created overlay window=\(panel.windowNumber) displays=\(current.map(\.id))")
        return panel
    }

    /// Called on every screen notification, including a disconnect/reconnect
    /// that returns to the same display IDs before the next shortcut.
    func reset() {
        if let panel {
            Diagnostics.note("discard overlay window=\(panel.windowNumber) after display change")
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        displays = nil
    }
}
