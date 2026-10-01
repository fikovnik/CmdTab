import CoreGraphics

/// A screen edge that a window can tile to.
public enum WindowEdge: String, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// The target frame of a window. This type contains only geometry, so tests
/// can examine it without real windows.
///
/// All values use the *top-left origin* coordinates of the Accessibility API
/// and `CGWindowList`. The y value increases downward from the top-left corner
/// of the display with origin zero. AppKit `NSScreen` uses the opposite
/// vertical direction. Thus, convert each `NSScreen` rect with `flip` first.
public enum Layout {
    /// The fractions for repeated presses on the same edge, as in Raycast. The
    /// cycle is one half, two thirds, one third, and then one half again.
    public static let fractions: [CGFloat] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0]

    /// The maximum difference, in points, between a window frame and a
    /// fraction frame that still counts as a match.
    ///
    /// A terminal resizes in whole character cells, so it does not stop on an
    /// exact fraction. Ghostty can be approximately 10 points off. On a display
    /// that is 1440 points wide, the smallest difference between two fractions
    /// is 240 points. Thus, this tolerance does not confuse two fractions.
    public static let tolerance: CGFloat = 20

    /// Converts between the AppKit bottom-left origin and the AX top-left
    /// origin. The function is its own inverse.
    ///
    /// `primaryMaxY` is the height of the display with origin `(0, 0)`, not the
    /// height of the converted screen. If there is only one display, an
    /// incorrect value is not visible. On other displays, the result is
    /// incorrect.
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

    /// The next frame for `edge`. If the window is at one of the fractions for
    /// `edge`, the result is the next fraction. If not, the result is a half.
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

    /// A centered frame that takes `fraction` of `visible` on both axes. An
    /// edge tile fills one axis. A centered frame is not flush with an edge, so
    /// the fraction applies to both axes.
    public static func centered(fraction: CGFloat, in visible: CGRect) -> CGRect {
        centered(CGRect(origin: .zero,
                        size: CGSize(width: (visible.width * fraction).rounded(),
                                     height: (visible.height * fraction).rounded())),
                 in: visible)
    }

    /// `next(edge:window:in:)` for the center. The cycle is the same as for an
    /// edge, with one difference. If the window is not at one of the fractions,
    /// the window keeps its size and only moves. Thus, the first press centers
    /// the window, and each press after it changes to the next fraction.
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
