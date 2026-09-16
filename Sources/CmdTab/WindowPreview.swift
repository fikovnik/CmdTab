import AppKit
import ScreenCaptureKit

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
/// A cached capture older than this is still shown at once (a stale frame
/// beats a blank one) and refreshed behind it.
private let staleAfter: TimeInterval = 2
/// A cached frame is captured at twice `maxSize`, so up to ten megabytes of
/// bitmap each, and a session can hold thirty windows. Keep only enough to make
/// going back and forth feel instant.
private let cacheLimit = 5

/// The thumbnail that appears beside the switcher list once the selection has
/// settled.
///
/// Window pixels are gated behind Screen Recording permission, unlike every
/// other thing this app reads, so the preview is the one feature that can be
/// missing on a working install. It fails quiet: no permission, no capture, no
/// panel, and the switcher behaves exactly as it did before.
@MainActor
final class WindowPreview {
    private struct Shot {
        let image: NSImage
        let taken: Date
    }

    private var panel: NSPanel?
    private let imageView = NSImageView()
    /// Captures are kept across cycles: re-cycling shows instantly, and a
    /// window that has since moved to another Space still shows the last frame
    /// we managed to get of it.
    private var cache: [CGWindowID: Shot] = [:]
    /// A capture that has been asked for but not started yet. Once the preview
    /// is up it follows the selection with no dwell, so stepping fast can ask
    /// for a capture every few milliseconds, far faster than one takes. Only
    /// the newest is worth running, so requests replace each other here rather
    /// than piling up as concurrent captures.
    private struct Request {
        let id: CGWindowID
        let anchor: NSRect
        let screen: NSScreen
        let generation: Int
    }

    private var pending: Request?
    private var capturing = false
    /// Bumped on every show and hide, so a capture that lands after the
    /// selection moved on can tell that it is no longer wanted.
    private var generation = 0
    /// The permission prompt is a system dialog, so ask at most once per launch.
    private var askedForPermission = false

    /// Show the preview for `window`, anchored beside the switcher panel.
    /// Returns immediately. The panel appears when the capture lands, which for
    /// a cached window is the same turn.
    func show(_ window: WindowRef, anchor: NSRect, on screen: NSScreen) {
        generation += 1

        if let shot = cache[window.id] {
            display(shot.image, anchor: anchor, on: screen)
            guard Date().timeIntervalSince(shot.taken) > staleAfter else {
                pending = nil
                return
            }
        }

        pending = Request(id: window.id, anchor: anchor, screen: screen, generation: generation)
        capture()
    }

    var isShowing: Bool { panel?.isVisible == true }

    func hide() {
        generation += 1
        pending = nil
        panel?.orderOut(nil)
    }

    /// Prompt for Screen Recording, for the menu item. The grant only takes
    /// effect on relaunch, which is macOS's rule, not ours.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Keep the newest `cacheLimit` frames and drop the rest.
    private func remember(_ image: NSImage, for id: CGWindowID) {
        cache[id] = Shot(image: image, taken: Date())
        while cache.count > cacheLimit,
              let oldest = cache.min(by: { $0.value.taken < $1.value.taken })?.key {
            cache[oldest] = nil
        }
    }

    // MARK: - Capture

    /// Run the pending request, if any, and then whatever replaced it while it
    /// ran. Serial by construction: one screenshot at a time.
    private func capture() {
        guard !capturing, let request = pending, hasPermission() else { return }
        pending = nil
        capturing = true

        Task { @MainActor [weak self] in
            let image = await WindowPreview.capture(id: request.id)
            guard let self else { return }
            self.capturing = false
            if let image {
                self.remember(image, for: request.id)
                if self.generation == request.generation {
                    self.display(image, anchor: request.anchor, on: request.screen)
                }
            }
            self.capture()
        }
    }

    private func hasPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Asking costs one dialog and makes the feature discoverable. Without it
        // previews are invisible until someone finds the menu item.
        if !askedForPermission {
            askedForPermission = true
            _ = CGRequestScreenCaptureAccess()
            Diagnostics.note("preview: no Screen Recording permission")
        }
        return false
    }

    /// One window's contents, at twice its on-screen size so the panel stays
    /// sharp on Retina. `nil` if the window is gone, on a Space the
    /// WindowServer has no frame for, or the permission was revoked.
    private static func capture(id: CGWindowID) async -> NSImage? {
        guard #available(macOS 14.0, *) else { return nil }
        guard let image = await captureImage(id: id) else { return nil }
        return NSImage(cgImage: image,
                       size: NSSize(width: CGFloat(image.width) / 2,
                                    height: CGFloat(image.height) / 2))
    }

    @available(macOS 14.0, *)
    private static func captureImage(id: CGWindowID) async -> CGImage? {
        // onScreenWindowsOnly: false, since the switcher spans every Space, so most
        // of what it lists is not on screen at the moment it is previewed.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == id }),
              window.frame.width > 0, window.frame.height > 0
        else { return nil }

        let width = min(window.frame.width, maxSize.width) * 2
        let config = SCStreamConfiguration()
        config.width = Int(width)
        config.height = Int(width * window.frame.height / window.frame.width)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config)
    }

    // MARK: - Placement

    private func display(_ image: NSImage, anchor: NSRect, on screen: NSScreen) {
        guard let frame = place(image.size, anchor: anchor, on: screen.visibleFrame) else { return }
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
