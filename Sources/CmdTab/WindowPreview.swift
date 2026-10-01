import AppKit

private let gap: CGFloat = 12
private let inset: CGFloat = 6
/// The largest preview. On a large display, a larger preview looks like a
/// second window.
private let maxSize = NSSize(width: 900, height: 700)
/// The smallest legible preview. If there is less space, there is no preview.
private let minWidth: CGFloat = 180
private let minHeight: CGFloat = 130
/// A frame of a window on a visible Space is used for this time. After it,
/// the next show captures the window again.
private let liveFrameAge: TimeInterval = 2
/// A frame is approximately 2 MB at the resampled size.
private let cacheLimit = 48

/// The window image next to the switcher list.
///
/// A capture needs Screen Recording permission. Without it, there is no
/// preview, and the switcher operates as before.
///
/// Some apps, for example Chrome, release the drawing surface of a window
/// that is covered or on another Space. A capture then shows a toolbar above
/// a grey area. Thus, CmdTab captures a window when it loses focus, because
/// then it is in front and drawn. A window on a visible Space gets a new
/// capture when it is shown.
@MainActor
final class WindowPreview {
    static let shared = WindowPreview()

    private struct Frame {
        let image: NSImage
        let taken: Date
    }

    private var panel: NSPanel?
    private let imageView = NSImageView()
    private var cache: [CGWindowID: Frame] = [:]
    /// The permission dialog is a system dialog. Show it once per launch.
    private var askedForPermission = false

    var isShowing: Bool { panel?.isVisible == true }

    /// Captures a window that loses focus. Call this while the window is still
    /// in front. A burst of focus changes captures a window only once.
    func capture(_ id: CGWindowID) {
        if let frame = cache[id], Date().timeIntervalSince(frame.taken) < 0.5 { return }
        guard CGPreflightScreenCaptureAccess(), let image = grab(id) else { return }
        store(image, for: id)
    }

    /// Shows the frame of `window` next to the switcher list.
    ///
    /// Without a frame, the panel goes down. A frame of the previous selection
    /// below the title of this window shows the wrong window.
    func show(_ window: Window, isVisible: Bool, anchor: NSRect, on screen: NSScreen) {
        let cached = cache[window.id]
        let stale = cached.map { Date().timeIntervalSince($0.taken) > liveFrameAge } ?? true
        // A window on another Space gets a capture only if it has no frame. A
        // new capture from another Space is not better than a frame from its
        // own Space.
        if cached == nil || (isVisible && stale), hasPermission(prompt: isVisible),
           let image = grab(window.id) {
            store(image, for: window.id)
        }
        guard let frame = cache[window.id] else {
            hide()
            return
        }
        display(frame.image, anchor: anchor, on: screen)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Asks for Screen Recording permission. Off-Space titles use the same
    /// permission. macOS applies it only after a relaunch.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Diagnostics: the age and the size of each frame.
    func cacheReport() -> String {
        let now = Date()
        return cache.sorted { $0.key < $1.key }.map { id, frame in
            String(format: "  id=%u %.0fs %dx%d\n", id, now.timeIntervalSince(frame.taken),
                   Int(frame.image.size.width), Int(frame.image.size.height))
        }.joined()
    }

    // MARK: - Capture

    /// Shows the permission dialog only for a capture that the user waits for,
    /// not for a capture in the background.
    private func hasPermission(prompt: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if prompt, !askedForPermission {
            askedForPermission = true
            _ = CGRequestScreenCaptureAccess()
        }
        return false
    }

    /// One frame of a window, resampled for the panel. Nil if the window is
    /// gone, if there is no frame, or if the frame is smaller than the window.
    /// A smaller frame was captured during an animation or a resize.
    private func grab(_ id: CGWindowID) -> NSImage? {
        guard let expected = WindowServer.size(ofWindow: id),
              let image = WindowServer.capture(window: id),
              abs(CGFloat(image.width) - expected.width) <= 2,
              abs(CGFloat(image.height) - expected.height) <= 2
        else { return nil }

        // The frame has the size of the window in points. The panel can use
        // at most two pixels per point of `maxSize`.
        let points = NSSize(width: image.width, height: image.height)
        let width = Int(min(points.width, maxSize.width) * 2)
        let scaled = width < image.width ? downscale(image, toWidth: width) ?? image : image
        return NSImage(cgImage: scaled, size: points)
    }

    private func downscale(_ image: CGImage, toWidth width: Int) -> CGImage? {
        let height = max(1, image.height * width / image.width)
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: image.bitmapInfo.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Keeps the newest `cacheLimit` frames.
    private func store(_ image: NSImage, for id: CGWindowID) {
        cache[id] = Frame(image: image, taken: Date())
        while cache.count > cacheLimit,
              let oldest = cache.min(by: { $0.value.taken < $1.value.taken })?.key {
            cache[oldest] = nil
        }
    }

    // MARK: - Placement

    private func display(_ image: NSImage, anchor: NSRect, on screen: NSScreen) {
        guard let frame = place(image.size, anchor: anchor, on: screen.visibleFrame) else {
            hide()
            return
        }
        let panel = ensurePanel()
        panel.setFrame(frame, display: false)
        imageView.frame = NSRect(origin: .zero, size: frame.size).insetBy(dx: inset, dy: inset)
        imageView.image = image
        panel.orderFrontRegardless()
    }

    /// Puts the preview above the list. If there is no space above, it uses
    /// the first other side with space: below, right, left. The first side
    /// that fits is used, not the largest one, so the preview does not move
    /// from side to side.
    private func place(_ size: NSSize, anchor: NSRect, on screen: NSRect) -> NSRect? {
        let sides = [
            NSRect(x: screen.minX + gap, y: anchor.maxY + gap,
                   width: screen.width - gap * 2, height: screen.maxY - anchor.maxY - gap * 2),
            NSRect(x: screen.minX + gap, y: screen.minY + gap,
                   width: screen.width - gap * 2, height: anchor.minY - screen.minY - gap * 2),
            NSRect(x: anchor.maxX + gap, y: screen.minY + gap,
                   width: screen.maxX - anchor.maxX - gap * 2, height: screen.height - gap * 2),
            NSRect(x: screen.minX + gap, y: screen.minY + gap,
                   width: anchor.minX - screen.minX - gap * 2, height: screen.height - gap * 2),
        ]

        for box in sides where box.width > 0 && box.height > 0 {
            // Do not make the image larger than the window.
            let scale = min(box.width / size.width, box.height / size.height,
                            maxSize.width / size.width, maxSize.height / size.height, 1)
            let fitted = NSSize(width: (size.width * scale).rounded(),
                                height: (size.height * scale).rounded())
            guard fitted.width >= minWidth, fitted.height >= minHeight else { continue }
            return NSRect(origin: centred(fitted, in: box, on: anchor), size: fitted)
                .insetBy(dx: -inset, dy: -inset)
        }
        return nil
    }

    /// Aligns the preview with the centre of the list, inside the box.
    private func centred(_ size: NSSize, in box: NSRect, on anchor: NSRect) -> NSPoint {
        NSPoint(x: min(max(anchor.midX - size.width / 2, box.minX), box.maxX - size.width),
                y: min(max(anchor.midY - size.height / 2, box.minY), box.maxY - size.height))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let (panel, content) = makeOverlayPanel()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        content.addSubview(imageView)
        self.panel = panel
        return panel
    }
}
