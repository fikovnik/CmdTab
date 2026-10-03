import CoreGraphics

/// Places a preview in AppKit coordinates. The image size excludes the panel border.
public enum PreviewLayout {
    public static let maximumSize = CGSize(width: 900, height: 700)
    public static let inset: CGFloat = 6
    private static let gap: CGFloat = 12

    public static func frame(for size: CGSize, anchor: CGRect, in screen: CGRect) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let sides = [
            CGRect(x: screen.minX + gap, y: anchor.maxY + gap,
                   width: screen.width - gap * 2, height: screen.maxY - anchor.maxY - gap * 2),
            CGRect(x: screen.minX + gap, y: screen.minY + gap,
                   width: screen.width - gap * 2, height: anchor.minY - screen.minY - gap * 2),
            CGRect(x: anchor.maxX + gap, y: screen.minY + gap,
                   width: screen.maxX - anchor.maxX - gap * 2, height: screen.height - gap * 2),
            CGRect(x: screen.minX + gap, y: screen.minY + gap,
                   width: anchor.minX - screen.minX - gap * 2, height: screen.height - gap * 2),
        ]
        // Use the first side that fits: above, below, right, left.
        for box in sides where box.width > inset * 2 && box.height > inset * 2 {
            let scale = min((box.width - inset * 2) / size.width,
                            (box.height - inset * 2) / size.height,
                            maximumSize.width / size.width, maximumSize.height / size.height, 1)
            let image = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
            guard image.width >= 180, image.height >= 130 else { continue }
            let outer = CGSize(width: image.width + inset * 2, height: image.height + inset * 2)
            return CGRect(x: min(max(anchor.midX - outer.width / 2, box.minX), box.maxX - outer.width),
                          y: min(max(anchor.midY - outer.height / 2, box.minY), box.maxY - outer.height),
                          width: outer.width, height: outer.height)
        }
        return nil
    }
}
