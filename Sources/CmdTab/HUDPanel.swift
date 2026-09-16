import AppKit

private let rowHeight: CGFloat = 28
private let iconSize: CGFloat = 20
private let padding: CGFloat = 10
private let badgeGap: CGFloat = 16
private let footerHeight: CGFloat = 26
private let scrollBarWidth: CGFloat = 4
private let minWidth: CGFloat = 300
private let maxWidth: CGFloat = 760
/// Long enough to scan, short enough to never dominate the screen. Beyond this
/// the list scrolls around the selection.
private let rowCap = 14

/// The panel sits on a translucent blur, so whatever is behind it bleeds
/// through, so a white browser page turns a dark HUD pale and washes out light
/// text. A scrim pins the floor on how light the background can get, and fixed
/// light-on-dark colours keep the text legible regardless of system appearance.
private enum Palette {
    static let scrim = NSColor.black.withAlphaComponent(0.68)
    static let primary = NSColor.white
    static let secondary = NSColor.white.withAlphaComponent(0.72)
    static let tertiary = NSColor.white.withAlphaComponent(0.58)
    static let separator = NSColor.white.withAlphaComponent(0.16)
    static let scrollTrack = NSColor.white.withAlphaComponent(0.16)
    static let scrollThumb = NSColor.white.withAlphaComponent(0.58)
    static var selection: NSColor { .controlAccentColor }

    /// Accent colours run from navy to yellow depending on the user's setting,
    /// so pick the highlight's text colour from its luminance rather than
    /// assuming white reads on it.
    static var onSelection: NSColor {
        guard let rgb = selection.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }
}

private final class HUDView: NSView {
    var items: [WindowRef] = []
    var selected = 0
    var scope = ""
    var maxRows = rowCap
    private var firstVisible = 0

    override var isFlipped: Bool { true }

    var visibleRows: Int { min(items.count, maxRows) }
    private var scrolls: Bool { items.count > visibleRows }
    private var listHeight: CGFloat { CGFloat(visibleRows) * rowHeight }

    func measure() -> NSSize {
        let width = items.reduce(max(minWidth, footer().size().width + padding * 3)) {
            max($0, rowWidth(for: $1))
        }
        return NSSize(width: min(width, maxWidth),
                      height: listHeight + footerHeight + padding * 2)
    }

    /// Keep the selection inside the rendered window of the list.
    func scrollToSelection() {
        let rows = visibleRows
        guard rows > 0 else { return }
        if selected < firstVisible { firstVisible = selected }
        if selected >= firstVisible + rows { firstVisible = selected - rows + 1 }
        firstVisible = max(0, min(firstVisible, items.count - rows))
    }

    // MARK: - Text

    private func rowWidth(for window: WindowRef) -> CGFloat {
        let badge = badge(window)?.size().width ?? 0
        return padding * 3 + iconSize + 8 + title(window).size().width
            + (badge > 0 ? badgeGap + badge : 0)
            + (scrolls ? scrollBarWidth + 8 : 0)
    }

    private func title(_ window: WindowRef) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: window.appName,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: Palette.primary,
            ])
        if !window.title.isEmpty {
            result.append(NSAttributedString(
                string: "  \(window.title)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: Palette.secondary,
                ]))
        }
        return result
    }

    private func badge(_ window: WindowRef) -> NSAttributedString? {
        guard let label = window.spaceLabel else { return nil }
        return NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: Palette.tertiary,
        ])
    }

    private func footer() -> NSAttributedString {
        let apps = Set(items.map(\.pid)).count
        let position = items.isEmpty ? 0 : selected + 1
        let text = "\(position)/\(items.count) window\(items.count == 1 ? "" : "s") · "
            + "\(apps) app\(apps == 1 ? "" : "s")   ·   \(scope)   ·   \(HUDPanel.keyHint)"
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: Palette.secondary,
        ])
    }

    private func highlighted(_ text: NSAttributedString, alpha: CGFloat) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.addAttribute(.foregroundColor,
                          value: Palette.onSelection.withAlphaComponent(alpha),
                          range: NSRange(location: 0, length: copy.length))
        return copy
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Palette.scrim.setFill()
        bounds.fill()

        let rightInset = padding / 2 + (scrolls ? scrollBarWidth + 8 : 0)

        for slot in 0..<visibleRows {
            let index = firstVisible + slot
            guard index < items.count else { break }
            draw(items[index], at: slot, selected: index == selected, rightInset: rightInset)
        }

        if scrolls { drawScrollBar() }
        drawFooter()
    }

    private func draw(_ window: WindowRef, at slot: Int, selected isSelected: Bool, rightInset: CGFloat) {
        let row = NSRect(x: padding / 2,
                         y: padding + CGFloat(slot) * rowHeight,
                         width: bounds.width - padding / 2 - rightInset,
                         height: rowHeight)

        if isSelected {
            Palette.selection.setFill()
            NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
        }

        let iconRect = NSRect(x: row.minX + padding / 2,
                              y: row.midY - iconSize / 2,
                              width: iconSize, height: iconSize)
        window.icon?.draw(in: iconRect)

        var badgeWidth: CGFloat = 0
        if var badge = badge(window) {
            if isSelected { badge = highlighted(badge, alpha: 0.75) }
            badgeWidth = badge.size().width
            badge.draw(with: NSRect(x: row.maxX - padding / 2 - badgeWidth,
                                    y: row.midY - badge.size().height / 2,
                                    width: badgeWidth, height: badge.size().height),
                       options: [.usesLineFragmentOrigin])
        }

        var text = title(window)
        if isSelected { text = highlighted(text, alpha: 1) }
        let available = row.maxX - padding / 2 - badgeWidth
            - (badgeWidth > 0 ? badgeGap : 0) - iconRect.maxX - 8
        text.draw(with: NSRect(x: iconRect.maxX + 8,
                               y: row.midY - text.size().height / 2,
                               width: max(0, available),
                               height: text.size().height),
                  options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    private func drawScrollBar() {
        let track = NSRect(x: bounds.width - padding / 2 - scrollBarWidth,
                           y: padding,
                           width: scrollBarWidth,
                           height: listHeight)
        Palette.scrollTrack.setFill()
        NSBezierPath(roundedRect: track, xRadius: scrollBarWidth / 2, yRadius: scrollBarWidth / 2).fill()

        let proportion = CGFloat(visibleRows) / CGFloat(items.count)
        let thumbHeight = max(24, track.height * proportion)
        let travel = track.height - thumbHeight
        let progress = CGFloat(firstVisible) / CGFloat(max(1, items.count - visibleRows))
        let thumb = NSRect(x: track.minX,
                           y: track.minY + travel * progress,
                           width: scrollBarWidth,
                           height: thumbHeight)
        Palette.scrollThumb.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: scrollBarWidth / 2, yRadius: scrollBarWidth / 2).fill()
    }

    private func drawFooter() {
        let separator = NSRect(x: padding, y: padding + listHeight + 3,
                               width: bounds.width - padding * 2, height: 1)
        Palette.separator.setFill()
        separator.fill()

        let text = footer()
        text.draw(with: NSRect(x: padding,
                               y: separator.maxY + (footerHeight - 4 - text.size().height) / 2,
                               width: bounds.width - padding * 2,
                               height: text.size().height),
                  options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }
}

@MainActor
final class HUDPanel {
    private var panel: NSPanel?
    private let view = HUDView()

    static let keyHint = "↑↓ move · → this Space · release ⌘ to switch · esc cancel"

    /// How many rows the panel can fit on the active screen, whether or not it
    /// is on screen right now. `Switcher` pages by this.
    var rowCapacity: Int { maxRows(on: activeScreen()) }

    func show(_ windows: [WindowRef], selected: Int, scope: String) {
        let screen = activeScreen()
        view.items = windows
        view.selected = selected
        view.scope = scope
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

    /// Render the HUD offscreen to a PNG. Lets layout be checked without
    /// capturing the screen, and so without Screen Recording permission.
    func render(_ windows: [WindowRef], selected: Int, scope: String, rows: Int,
                backdrop: NSColor, to path: String) {
        view.items = windows
        view.selected = selected
        view.scope = scope
        view.maxRows = rows
        view.scrollToSelection()

        let size = view.measure()
        view.frame = NSRect(origin: .zero, size: size)
        view.wantsLayer = true
        // Worst case: assume the blur passes the backdrop through untouched.
        view.layer?.backgroundColor = backdrop.cgColor

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func maxRows(on screen: NSScreen) -> Int {
        let usable = screen.visibleFrame.height - padding * 2 - footerHeight - 80
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
        // Pin the appearance so the blur uses its dark variant in Light mode
        // too. The palette above is light-on-dark either way.
        panel.appearance = NSAppearance(named: .darkAqua)

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
