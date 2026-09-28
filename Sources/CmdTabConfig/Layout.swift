import CoreGraphics

public enum WindowEdge: String, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// Where a window should go. Pure geometry, so the part most likely to be
/// wrong is the part that can be tested.
///
/// Everything here works in the *top-left origin* space that the Accessibility
/// API and `CGWindowList` use: y grows downward from the top-left corner of the
/// display whose origin is zero. AppKit's `NSScreen` uses the opposite vertical
/// convention, so screen rects have to come through `flip` on the way in.
public enum Layout {
    /// Repeated presses on the same edge walk these, the way Raycast does:
    /// half, then two thirds, then one third, then back to half.
    public static let fractions: [CGFloat] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0]

    /// How far a frame may differ from a fraction and still count as already
    /// being there.
    ///
    /// Generous on purpose. A terminal resizes in whole character cells, so it
    /// never lands on an exact fraction, and Ghostty can be ~10pt off. The
    /// smallest gap between two fractions on the narrower of the two displays
    /// here is 240pt, so there is a lot of room before this could confuse one
    /// fraction for another.
    public static let tolerance: CGFloat = 20

    /// AppKit's bottom-left origin to the top-left origin AX uses, and back.
    /// The function is its own inverse.
    ///
    /// `primaryMaxY` is the height of the display whose origin is `(0, 0)`, not
    /// of the screen being converted. Getting that wrong is invisible on a
    /// single display and badly wrong on any other.
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

    /// The frame to apply next. If the window is already sitting at one of the
    /// fractions for this edge, advance to the following one. Otherwise snap to
    /// a half, wherever the window happens to be now.
    public static func next(edge: WindowEdge, window: CGRect, in visible: CGRect) -> CGRect {
        let current = fractions.firstIndex { fraction in
            matches(window, frame(edge: edge, fraction: fraction, in: visible))
        }
        guard let current else { return frame(edge: edge, fraction: fractions[0], in: visible) }
        let next = fractions[(current + 1) % fractions.count]
        return frame(edge: edge, fraction: next, in: visible)
    }

    /// Whether the window is already filling `visible`, which is what makes
    /// maximize a toggle.
    public static func isMaximized(_ window: CGRect, in visible: CGRect) -> Bool {
        matches(window, visible)
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
