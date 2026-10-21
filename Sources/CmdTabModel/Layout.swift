import CoreGraphics

public enum WindowEdge: String, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// Use AX coordinates with the origin at the top left. The y coordinate increases down.
public enum Layout {
    public static let fractions: [CGFloat] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0]

    /// Allow small position and size differences from apps that resize in character cells.
    public static let tolerance: CGFloat = 20

    /// Use the primary display height for every display.
    /// Two conversions restore the original coordinates.
    public static func flip(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    public static func frame(edge: WindowEdge, fraction: CGFloat, in visible: CGRect) -> CGRect {
        let width = (visible.width * fraction).rounded()
        let height = (visible.height * fraction).rounded()
        switch edge {
        case .left:
            return CGRect(x: visible.minX, y: visible.minY, width: width, height: visible.height)
        case .right:
            return CGRect(x: visible.maxX - width, y: visible.minY,
                          width: width, height: visible.height)
        case .top:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
        case .bottom:
            return CGRect(x: visible.minX, y: visible.maxY - height,
                          width: visible.width, height: height)
        }
    }

    /// If the frame matches an edge fraction, use the next fraction. Otherwise, start with one half.
    public static func next(edge: WindowEdge, window: CGRect, in visible: CGRect) -> CGRect {
        let current = fractions.firstIndex { fraction in
            matches(window, frame(edge: edge, fraction: fraction, in: visible))
        }
        guard let current else { return frame(edge: edge, fraction: fractions[0], in: visible) }
        let next = fractions[(current + 1) % fractions.count]
        return frame(edge: edge, fraction: next, in: visible)
    }

    /// Keep the window size when you move the window to the center.
    public static func centered(_ window: CGRect, in visible: CGRect) -> CGRect {
        CGRect(x: (visible.minX + (visible.width - window.width) / 2).rounded(),
               y: (visible.minY + (visible.height - window.height) / 2).rounded(),
               width: window.width, height: window.height)
    }

    /// Apply the fraction to both dimensions and keep the window in the center.
    public static func centered(fraction: CGFloat, in visible: CGRect) -> CGRect {
        centered(CGRect(origin: .zero,
                        size: CGSize(width: (visible.width * fraction).rounded(),
                                     height: (visible.height * fraction).rounded())),
                 in: visible)
    }

    /// Center the window before the fraction cycle.
    /// If the frame already matches a centered fraction, advance to the next fraction.
    public static func nextCentered(window: CGRect, in visible: CGRect) -> CGRect {
        if let current = fractions.firstIndex(where: { fraction in
            matches(window, centered(fraction: fraction, in: visible))
        }) {
            return centered(fraction: fractions[(current + 1) % fractions.count], in: visible)
        }
        let moved = centered(window, in: visible)
        // If the window is already at the center, start the fraction cycle.
        return matches(window, moved) ? centered(fraction: fractions[0], in: visible) : moved
    }

    /// Use the frame tolerance to check whether the window fills the visible display area.
    public static func isMaximized(_ window: CGRect, in visible: CGRect) -> Bool {
        matches(window, visible)
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
