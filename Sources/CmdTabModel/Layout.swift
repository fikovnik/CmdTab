import CoreGraphics

/// A screen edge that a window can tile to.
public enum WindowEdge: String, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// Window geometry in AX coordinates: top left origin, with y increasing downward.
public enum Layout {
    /// Cycle through one half, two thirds, and one third.
    public static let fractions: [CGFloat] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0]

    /// Accept a difference of 20 points. Terminals can resize in character cells.
    public static let tolerance: CGFloat = 20

    /// Convert between AppKit and AX coordinates. Use the primary display height for all displays.
    /// Applying the conversion twice returns the original frame.
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

    /// Advance a matching edge fraction. Otherwise, start with one half.
    public static func next(edge: WindowEdge, window: CGRect, in visible: CGRect) -> CGRect {
        let current = fractions.firstIndex { fraction in
            matches(window, frame(edge: edge, fraction: fraction, in: visible))
        }
        guard let current else { return frame(edge: edge, fraction: fractions[0], in: visible) }
        let next = fractions[(current + 1) % fractions.count]
        return frame(edge: edge, fraction: next, in: visible)
    }

    /// The window frame, moved to the center of `visible`, with the same size.
    /// The first press of `tile:center` uses this frame.
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

    /// Move an unmatched window to the center without a size change. Advance matching fractions on subsequent presses.
    public static func nextCentered(window: CGRect, in visible: CGRect) -> CGRect {
        if let current = fractions.firstIndex(where: { fraction in
            matches(window, centered(fraction: fraction, in: visible))
        }) {
            return centered(fraction: fractions[(current + 1) % fractions.count], in: visible)
        }
        let moved = centered(window, in: visible)
        // The window is centered, but its size is not a fraction. A move does
        // not change the frame, so start the cycle here.
        return matches(window, moved) ? centered(fraction: fractions[0], in: visible) : moved
    }

    /// True if the window fills `visible`. Maximize uses this value to decide
    /// the direction of the toggle.
    public static func isMaximized(_ window: CGRect, in visible: CGRect) -> Bool {
        matches(window, visible)
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
