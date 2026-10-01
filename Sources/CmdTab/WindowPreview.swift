import AppKit

private let gap: CGFloat = 12
private let inset: CGFloat = 6
/// Ceiling on the preview, independent of how much room the screen offers. On a
/// laptop the free space beside a centred list binds long before this does. On
/// a large display this is what stops the thumbnail becoming a second window.
private let maxSize = NSSize(width: 900, height: 700)
/// Below this the image is too small to recognise anything in, so no panel at
/// all beats a postage stamp. Height matters as much as width now that above is
/// the preferred side: the space over a tall list is wide and flat, and a 1500pt
/// window squeezed into 90pt of height shows nothing.
private let minWidth: CGFloat = 180
private let minHeight: CGFloat = 130
/// A cached frame of a window on the active Space is re-captured once older
/// than this. Off-Space windows are never re-captured. See `warm`.
private let staleAfter: TimeInterval = 2
/// How long a warmed frame is trusted before the next refresh replaces it.
private let warmAfter: TimeInterval = 15
/// Has to hold every window on a busy Space (28 on one here) plus the Spaces
/// already left. Each frame is a couple of megabytes at the sizes `capture`
/// resamples to.
private let cacheLimit = 48
/// One warm capture per tick. A capture is 3-18 ms on the main thread, so 28 of
/// them back to back would be half a second of stutter.
private let warmInterval: TimeInterval = 0.08
/// Let a Space settle before warming it. A Space change coalesces into a
/// refresh faster than the animation finishes, and a window captured mid-slide
/// comes back cropped: a 2560pt Slack window arrived 296pt wide.
private let warmLeadIn: TimeInterval = 0.7
/// How many times a partial frame is re-queued before giving up on it.
private let partialRetries = 3
/// How long the active-Space window sets are reused before being recomputed.
private let activeSpaceFor: TimeInterval = 0.5

/// The thumbnail that appears beside the switcher list once the selection has
/// settled.
///
/// Window pixels are gated behind Screen Recording permission, unlike every
/// other thing this app reads, so the preview is the one feature that can be
/// missing on a working install. It fails quiet: no permission, no capture, no
/// panel, and the switcher behaves exactly as it did before.
///
/// Shared rather than owned by the switcher: the cache is filled while windows
/// are on the active Space, which is not when the switcher runs. See `warm`.
@MainActor
final class WindowPreview {
    static let shared = WindowPreview()

    private struct Shot {
        let image: NSImage
        let taken: Date
        /// Whether the window was on the active Space when this was taken.
        /// Such a frame is never replaced by one taken from another Space.
        let live: Bool
    }

    private var panel: NSPanel?
    private let imageView = NSImageView()
    /// Captures are kept across cycles: re-cycling shows instantly, and a
    /// window that has since moved to another Space still shows the last frame
    /// we managed to get of it.
    private var cache: [CGWindowID: Shot] = [:]
    private var warmQueue: [CGWindowID] = []
    /// Re-queue counts for windows whose last frame came back partial.
    private var retries: [CGWindowID: Int] = [:]
    /// `WindowServer.activeSpaceWindows`, memoised for the length of a queue
    /// drain: it costs a `CGWindowList` scan and a WindowServer query, and a
    /// drain asks once per window.
    private var activeSpaceIDs: Set<CGWindowID> = []
    private var uncoveredIDs: Set<CGWindowID> = []
    private var activeSpaceAt = Date.distantPast
    /// Set by `warm`, drained on the next tick: the active Space's window list
    /// is read after the Space has settled rather than when the refresh asked.
    private var sweepPending = false
    private var warmTimer: Timer?
    /// The permission prompt is a system dialog, so ask at most once per launch.
    private var askedForPermission = false

    /// Show the preview for `window`, anchored beside the switcher panel.
    ///
    /// The panel shows the selected window or nothing at all. With no frame for
    /// it, it comes down rather than keeping the previous selection's
    /// thumbnail: the panel stays up across a step, so a silent return leaves a
    /// frame that belongs to another window sitting under this one's title,
    /// which reads as two windows sharing one preview.
    func show(_ window: Window, anchor: NSRect, on screen: NSScreen) {
        let live = onActiveSpace().all.contains(window.id)
        let cached = cache[window.id]

        if let shot = cached {
            display(shot.image, anchor: anchor, on: screen)
            // Off-Space with a frame already cached: a new capture cannot
            // improve on it. Either the cached frame was taken on the window's
            // own Space, or it is the same empty frame a new one would return.
            guard live, Date().timeIntervalSince(shot.taken) > staleAfter else { return }
        }

        guard case .image(let image) = capture(window.id, live: live) else {
            if cached == nil { hide() }
            return
        }
        remember(image, for: window.id, live: live)
        display(image, anchor: anchor, on: screen)
    }

    /// Capture every window on the active Space, so leaving it leaves usable
    /// frames behind. Driven by the coalesced registry refresh.
    ///
    /// An app that releases its drawing surface while occluded cannot be
    /// captured from another Space by any API. One Chrome window measured 36
    /// distinct colours on its own Space and 6 from one Space over: a toolbar
    /// above flat grey. Slack, on that same unvisited Space, captured at 79.
    func warm() {
        guard CGPreflightScreenCaptureAccess() else { return }
        sweepPending = true
        startWarming(after: warmLeadIn)
    }

    /// Re-capture one window whose contents are known to have changed, ignoring
    /// `warmAfter`. Driven by `AXWatcher`: without it a frame goes stale while
    /// the row's title, which comes from AX, stays current, and the two
    /// disagree. Nothing to wait for here, so no lead-in.
    func recapture(_ id: CGWindowID) {
        guard CGPreflightScreenCaptureAccess() else { return }
        warmQueue.removeAll { $0 == id }
        warmQueue.append(id)
        startWarming(after: 0)
    }

    private func startWarming(after delay: TimeInterval) {
        guard warmTimer == nil else { return }
        // .common, so it fires while the event tap pumps its own run loop
        // source.
        let timer = Timer(timeInterval: warmInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.warmTick() }
        }
        timer.fireDate = Date().addingTimeInterval(delay)
        RunLoop.main.add(timer, forMode: .common)
        warmTimer = timer
    }

    /// Windows on the active Space, and which of them nothing is covering.
    private func onActiveSpace() -> (all: Set<CGWindowID>, uncovered: Set<CGWindowID>) {
        if Date().timeIntervalSince(activeSpaceAt) > activeSpaceFor {
            (activeSpaceIDs, uncoveredIDs) = WindowServer.activeSpaceWindows()
            activeSpaceAt = Date()
        }
        return (activeSpaceIDs, uncoveredIDs)
    }

    private func warmTick() {
        // Up to 18 ms on the main thread, so not while the list is being
        // stepped through.
        guard !isShowing else { return }

        if sweepPending {
            sweepPending = false
            let now = Date()
            warmQueue += onActiveSpace().all
                .filter { id in
                    guard let shot = cache[id], shot.live else { return true }
                    return now.timeIntervalSince(shot.taken) > warmAfter
                }
        }

        guard let id = warmQueue.popLast() else {
            warmTimer?.invalidate()
            warmTimer = nil
            return
        }
        // Checked per capture rather than per queue: a window can leave the
        // active Space between being queued and being reached, and a frame
        // taken then would replace a good one with an empty one.
        guard onActiveSpace().all.contains(id) else { return }

        switch capture(id, live: true) {
        case .image(let image):
            remember(image, for: id, live: true)
            retries[id] = nil
        case .partial:
            // The cached frame stays: stale beats a sliver. Come back for this
            // one, but bounded, since a window mid-resize would re-queue forever.
            let attempts = (retries[id] ?? 0) + 1
            retries[id] = attempts <= partialRetries ? attempts : nil
            if retries[id] != nil { warmQueue.append(id) }
        case .unavailable:
            retries[id] = nil
        }
    }

    var isShowing: Bool { panel?.isVisible == true }

    /// Diagnostics: cache contents, and whether each frame was taken on the
    /// window's own Space.
    ///
    /// `colours` is what distinguishes an empty frame from a good one. Size and
    /// capture status are identical either way. A single-digit count on a large
    /// window means the app had released its drawing surface.
    func cacheReport() -> String {
        let now = Date()
        return cache.sorted { $0.key < $1.key }.map { id, shot in
            String(format: "  id=%u %@ %.0fs %dx%d colours=%d\n",
                   id, shot.live ? "live" : "off-Space", now.timeIntervalSince(shot.taken),
                   Int(shot.image.size.width), Int(shot.image.size.height), colours(shot.image))
        }.joined()
    }

    /// Distinct colours on a 20x20 grid over the frame. Stands in for "how much
    /// is in this frame": an app that dropped its drawing surface captures as a
    /// toolbar above flat grey, single digits against tens for the same window
    /// drawn.
    private func colours(_ image: NSImage) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data), cgImage.bytesPerRow > 0
        else { return -1 }

        let length = CFDataGetLength(data)
        var seen = Set<UInt32>()
        for row in 0..<20 {
            for column in 0..<20 {
                let offset = (cgImage.height * row / 20) * cgImage.bytesPerRow
                    + (cgImage.width * column / 20) * 4
                guard offset + 2 < length else { continue }
                seen.insert(UInt32(bytes[offset]) << 16
                            | UInt32(bytes[offset + 1]) << 8
                            | UInt32(bytes[offset + 2]))
            }
        }
        return seen.count
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Prompt for Screen Recording, for the menu item. Off-Space titles ride on
    /// the same grant. Takes effect on relaunch only, which is macOS's rule.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Keep the newest `cacheLimit` frames and drop the rest.
    ///
    /// A frame of a *covered* window is refused if it holds less than the one it
    /// would replace: that is what an app which dropped its drawing surface
    /// hands back, and it is worse than the older frame. An uncovered window is
    /// always trusted, because its contents may legitimately have gone blank.
    private func remember(_ image: NSImage, for id: CGWindowID, live: Bool) {
        if let shot = cache[id], !onActiveSpace().uncovered.contains(id),
           colours(image) < colours(shot.image) {
            return
        }
        cache[id] = Shot(image: image, taken: Date(), live: live)
        while cache.count > cacheLimit,
              let oldest = cache.min(by: { $0.value.taken < $1.value.taken })?.key {
            cache[oldest] = nil
        }
    }

    // MARK: - Capture

    /// `prompt` only for a capture someone is waiting on. The dialog makes the
    /// feature discoverable, but must not come out of a background refresh.
    private func hasPermission(prompt: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if prompt, !askedForPermission {
            askedForPermission = true
            _ = CGRequestScreenCaptureAccess()
            Diagnostics.note("preview: no Screen Recording permission")
        }
        return false
    }

    /// One window's contents, sized for the panel. `nil` if the window is gone,
    /// the WindowServer has no frame for it, or the permission was revoked.
    ///
    /// Frames arrive at the window's size in points. Anything wider than twice
    /// `maxSize` is more pixels than the panel can use, so the excess is
    /// resampled away rather than cached. Narrower windows are kept as they
    /// arrive (there is no higher-resolution frame to ask for) and drawn at
    /// their own size, which `place` will not exceed.
    private enum Capture {
        case image(NSImage)
        /// Frame smaller than the window: caught mid-animation or mid-resize.
        /// Worth another try shortly, unlike `unavailable`.
        case partial
        case unavailable
    }

    private func capture(_ id: CGWindowID, live: Bool) -> Capture {
        guard hasPermission(prompt: live),
              let expected = WindowServer.size(ofWindow: id),
              let image = WindowServer.capture(window: id),
              image.width > 0, image.height > 0
        else { return .unavailable }

        // A frame smaller than the window was caught mid-Space animation,
        // composited only as far as it had got. See `warmLeadIn`.
        guard abs(CGFloat(image.width) - expected.width) <= 2,
              abs(CGFloat(image.height) - expected.height) <= 2
        else { return .partial }

        let points = NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let target = Int(min(points.width, maxSize.width) * 2)
        let scaled = target < image.width ? downscale(image, toWidth: target) ?? image : image
        return .image(NSImage(cgImage: scaled, size: points))
    }

    /// Resample to `width`, keeping the aspect ratio. Takes a 2560pt window's
    /// frame from 14 MB of bitmap to 2 MB.
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

    // MARK: - Placement

    private func display(_ image: NSImage, anchor: NSRect, on screen: NSScreen) {
        // Too little room to draw this one legibly. Same rule as `show`: what
        // the panel is holding belongs to the previous selection, so take it
        // down instead of leaving it under the wrong title.
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

    /// Put the preview above the list, and take the first fallback that fits if
    /// there is no room there.
    ///
    /// Above is where it belongs: the list is the thing being read, and a panel
    /// over it is in the same place your eyes already are. The other three
    /// sides exist for the cases that leave nothing above: a full-height list,
    /// or a screen short enough that the gap above the list is not worth
    /// drawing in. First fit wins rather than biggest fit, so the preview does
    /// not hop to the side merely because the side is roomier.
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
            // Never upscale: a 300pt utility window drawn at 900 is mush.
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

    /// Line the preview up with the middle of the switcher on the axis the side
    /// does not constrain, then keep it inside the box.
    private func centred(_ size: NSSize, in box: NSRect, on anchor: NSRect) -> NSPoint {
        NSPoint(x: min(max(anchor.midX - size.width / 2, box.minX), box.maxX - size.width),
                y: min(max(anchor.midY - size.height / 2, box.minY), box.maxY - size.height))
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
        panel.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true

        blur.addSubview(imageView)
        panel.contentView = blur

        self.panel = panel
        return panel
    }
}
