import AppKit

private let rowHeight: CGFloat = 28
private let iconSize: CGFloat = 20
private let padding: CGFloat = 10
private let minWidth: CGFloat = 220
private let maxWidth: CGFloat = 640

private final class HUDView: NSView {
    var items: [WindowRef] = []
    var selected = 0

    override var isFlipped: Bool { true }

    func measure() -> NSSize {
        let width = items.reduce(minWidth) { max($0, rowWidth(for: $1)) }
        return NSSize(width: min(width, maxWidth),
                      height: CGFloat(items.count) * rowHeight + padding * 2)
    }

    private func rowWidth(for window: WindowRef) -> CGFloat {
        padding * 2 + iconSize + 8 + attributed(window).size().width + padding
    }

    private func attributed(_ window: WindowRef) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: window.appName,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        if !window.title.isEmpty {
            result.append(NSAttributedString(
                string: "  \(window.title)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, window) in items.enumerated() {
            let row = NSRect(x: padding / 2,
                             y: padding + CGFloat(index) * rowHeight,
                             width: bounds.width - padding,
                             height: rowHeight)

            if index == selected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }

            let iconRect = NSRect(x: row.minX + padding / 2,
                                  y: row.midY - iconSize / 2,
                                  width: iconSize, height: iconSize)
            window.icon?.draw(in: iconRect)

            var text = attributed(window)
            if index == selected {
                let highlighted = NSMutableAttributedString(attributedString: text)
                highlighted.addAttribute(.foregroundColor,
                                         value: NSColor.white,
                                         range: NSRange(location: 0, length: highlighted.length))
                text = highlighted
            }

            let available = row.maxX - iconRect.maxX - 8 - padding / 2
            let textRect = NSRect(x: iconRect.maxX + 8,
                                  y: row.midY - text.size().height / 2,
                                  width: max(0, available),
                                  height: text.size().height)
            text.draw(with: textRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }
    }
}

final class HUDPanel {
    private var panel: NSPanel?
    private let view = HUDView()

    func show(_ windows: [WindowRef], selected: Int) {
        view.items = windows
        view.selected = selected

        let panel = ensurePanel()
        let size = view.measure()
        let screen = activeScreen()
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2,
                              y: frame.midY - size.height / 2,
                              width: size.width, height: size.height),
                       display: false)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func update(selected: Int) {
        view.selected = selected
        view.needsDisplay = true
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        blur.addSubview(view)
        panel.contentView = blur

        self.panel = panel
        return panel
    }
}
