import AppKit

/// Reuse the panel while display geometry stays constant. Recreate it after display changes to restore Space membership.
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

    /// Reset on each display notification, even if display IDs return to their previous values.
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

/// Make a nonactivating panel for all Spaces, including full screen Spaces.
@MainActor
private func makeOverlayPanel() -> (panel: NSPanel, content: NSView) {
    let panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
    panel.isFloatingPanel = true
    panel.isReleasedWhenClosed = false
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    // The blur is dark also in Light mode. The palette is light on dark.
    panel.appearance = NSAppearance(named: .darkAqua)

    let blur = NSVisualEffectView()
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = 10
    blur.layer?.masksToBounds = true
    blur.autoresizingMask = [.width, .height]
    panel.contentView = blur
    return (panel, blur)
}
