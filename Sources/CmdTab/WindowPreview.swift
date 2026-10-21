import AppKit
import CmdTabModel

/// Keep one image per window. Retain the previous image if a new capture fails.
@MainActor
final class WindowPreview {
    static let shared = WindowPreview()
    static let byteLimit = 32 * 1024 * 1024
    private static let countLimit = 48

    private struct Frame {
        let image: NSImage
        let taken: TimeInterval
        let bytes: Int
    }

    private let overlay = OverlayPanel()
    private let imageView = NSImageView()
    private var cache: [CGWindowID: Frame] = [:]
    private let snapshot: @MainActor (CGWindowID) -> CGImage?
    private let clock: () -> TimeInterval

    init(snapshot: @escaping @MainActor (CGWindowID) -> CGImage? = WindowPreview.snapshot,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.snapshot = snapshot
        self.clock = clock
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
    }

    var isShowing: Bool { overlay.panel?.isVisible == true }
    var cachedBytes: Int { cache.values.reduce(0) { $0 + $1.bytes } }
    var cachedWindowIDs: Set<CGWindowID> { Set(cache.keys) }

    /// Skip a capture if the cached image is less than 0.5 seconds old.
    func capture(_ id: CGWindowID) {
        if let frame = cache[id], clock() - frame.taken < 0.5 { return }
        guard let image = snapshot(id) else { return }
        store(image, for: id)
    }

    /// Refresh stale images only on visible Spaces.
    /// Capture a window on another Space only if it has no cached image.
    func show(_ window: Window, isVisible: Bool, anchor: NSRect, on screen: NSScreen) {
        let stale = cache[window.id].map { clock() - $0.taken > 2 } ?? true
        if cache[window.id] == nil || (isVisible && stale) {
            capture(window.id)
        }
        guard let frame = cache[window.id],
              let rect = PreviewLayout.frame(for: frame.image.size, anchor: anchor, in: screen.visibleFrame)
        else { hide(); return }

        let panel = overlay.ensurePanel(containing: imageView)
        panel.setFrame(rect, display: false)
        imageView.frame = NSRect(origin: .zero, size: rect.size)
            .insetBy(dx: PreviewLayout.inset, dy: PreviewLayout.inset)
        imageView.image = frame.image
        panel.orderFrontRegardless()
    }

    func hide() {
        overlay.panel?.orderOut(nil)
        imageView.image = nil
    }

    func resetDisplayConfiguration() { overlay.reset() }

    func retain(_ live: Set<CGWindowID>) {
        cache = cache.filter { live.contains($0.key) }
    }

    /// Request permission only from the menu command.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func cacheReport() -> String {
        let now = clock()
        return "  frames=\(cache.count) bytes=\(cachedBytes) limit=\(Self.byteLimit)\n"
            + cache.sorted { $0.key < $1.key }.map { id, frame in
                String(format: "  id=%u %.0fs %@ bytes=%d\n", id, now - frame.taken,
                       "\(frame.image.size)", frame.bytes)
            }.joined()
    }

    /// Compare the nominal pixel dimensions with the window size in points.
    /// Reject a difference of more than two points.
    private static func snapshot(_ id: CGWindowID) -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let expected = WindowServer.size(ofWindow: id),
              let image = WindowServer.capture(window: id),
              abs(CGFloat(image.width) - expected.width) <= 2,
              abs(CGFloat(image.height) - expected.height) <= 2 else {
            Diagnostics.note("preview unavailable or incomplete id=\(id)")
            return nil
        }
        return image
    }

    /// Limit both pixel dimensions. A portrait window can exceed the height limit even when its width is small.
    private static func resample(_ image: CGImage) -> CGImage? {
        let limit = PreviewLayout.maximumSize
        let scale = min(limit.width * 2 / CGFloat(image.width),
                        limit.height * 2 / CGFloat(image.height), 1)
        if scale == 1 { return image }
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func store(_ source: CGImage, for id: CGWindowID) {
        guard let image = Self.resample(source) else { return }
        let size = NSSize(width: source.width, height: source.height)
        cache[id] = Frame(image: NSImage(cgImage: image, size: size), taken: clock(),
                          bytes: image.bytesPerRow * image.height)
        while cache.count > Self.countLimit || cachedBytes > Self.byteLimit {
            guard let oldest = cache.min(by: { ($0.value.taken, $0.key) < ($1.value.taken, $1.key) })?.key else { break }
            cache[oldest] = nil
        }
        Diagnostics.note("preview captured id=\(id) pixels=\(image.width)x\(image.height) cacheBytes=\(cachedBytes)")
    }
}
