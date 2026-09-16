import AppKit

private let rowHeight: CGFloat = 28
private let iconSize: CGFloat = 20
private let padding: CGFloat = 10
private let badgeGap: CGFloat = 16
private let minWidth: CGFloat = 220
private let maxWidth: CGFloat = 720
/// Long enough to scan, short enough to never dominate the screen. Beyond this
/// the list scrolls around the selection.
private let rowCap = 14

private final class HUDView: NSView {
    var items: [WindowRef] = []
    var selected = 0
    var maxRows = rowCap
    private var firstVisible = 0

    override var isFlipped: Bool { true }

    var visibleRows: Int { min(items.count, maxRows) }

    func measure() -> NSSize {
        let width = items.reduce(minWidth) { max($0, rowWidth(for: $1)) }
        return NSSize(width: min(width, maxWidth),
                      height: CGFloat(visibleRows) * rowHeight + padding * 2)
    }

    /// Keep the selection inside the rendered window of the list.
    func scrollToSelection() {
        let rows = visibleRows
        guard rows > 0 else { return }
        if selected < firstVisible { firstVisible = selected }
        if selected >= firstVisible + rows { firstVisible = selected - rows + 1 }
        firstVisible = max(0, min(firstVisible, items.count - rows))
    }

    private func rowWidth(for window: WindowRef) -> CGFloat {
        let badge = badge(window)?.size().width ?? 0
        return padding * 3 + iconSize + 8 + title(window).size().width
            + (badge > 0 ? badgeGap + badge : 0)
    }

    private func title(_ window: WindowRef) -> NSAttributedString {
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

    private func badge(_ window: WindowRef) -> NSAttributedString? {
        guard let label = window.spaceLabel else { return nil }
        return NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    private func whitened(_ text: NSAttributedString, alpha: CGFloat) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.addAttribute(.foregroundColor,
                          value: NSColor.white.withAlphaComponent(alpha),
                          range: NSRange(location: 0, length: copy.length))
        return copy
    }

    override func draw(_ dirtyRect: NSRect) {
        for slot in 0..<visibleRows {
            let index = firstVisible + slot
            guard index < items.count else { break }
            let window = items[index]
            let isSelected = index == selected

            let row = NSRect(x: padding / 2,
                             y: padding + CGFloat(slot) * rowHeight,
                             width: bounds.width - padding,
                             height: rowHeight)

            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }

            let iconRect = NSRect(x: row.minX + padding / 2,
                                  y: row.midY - iconSize / 2,
                                  width: iconSize, height: iconSize)
            window.icon?.draw(in: iconRect)

            var badgeWidth: CGFloat = 0
            if var badge = badge(window) {
                if isSelected { badge = whitened(badge, alpha: 0.75) }
                badgeWidth = badge.size().width
                let rect = NSRect(x: row.maxX - padding / 2 - badgeWidth,
                                  y: row.midY - badge.size().height / 2,
                                  width: badgeWidth, height: badge.size().height)
                badge.draw(with: rect, options: [.usesLineFragmentOrigin])
            }

            var text = title(window)
            if isSelected { text = whitened(text, alpha: 1) }
            let available = row.maxX - padding / 2 - badgeWidth
                - (badgeWidth > 0 ? badgeGap : 0) - iconRect.maxX - 8
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
        let screen = activeScreen()
        view.items = windows
        view.selected = selected
        view.maxRows = maxRows(on: screen)
        view.scrollToSelection()

        let panel = ensurePanel()
        let size = view.measure()
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
        view.scrollToSelection()
        view.needsDisplay = true
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func maxRows(on screen: NSScreen) -> Int {
        let usable = screen.visibleFrame.height - padding * 2 - 80
        return max(3, min(rowCap, Int(usable / rowHeight)))
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
