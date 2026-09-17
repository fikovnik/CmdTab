import AppKit

/// The WindowServer's own view of the windows on every Space.
///
/// This exists because `kAXWindowsAttribute` only ever describes the Space you
/// are standing on, verified on a live session: sitting on Desktop 3, AX
/// returns `count=0, status=success` for all nine apps whose windows are on
/// Desktop 1, and neither a 5 s messaging timeout nor `AXManualAccessibility`
/// changes that. So the all-Spaces list cannot come from AX.
///
/// `SLSWindowQueryWindows` can see every Space, but its raw output is noisy:
/// Chrome contributes one compositing surface per window, Lightroom's panels
/// come through as windows. The iterator also exposes the per-window flags that
/// tell them apart. See `isReal`. Checked against AX as ground truth on the
/// current Space, this filter reproduces its list exactly.
///
/// Everything here is SkyLight SPI. It is the same set yabai uses, and
/// it has been stable across releases, but it is private, so each call is
/// written to degrade to "no windows" rather than to trap.
@MainActor
enum WindowServer {

    struct Window {
        let id: CGWindowID
        let pid: pid_t
        /// Set only when `CGWindowList` will say, i.e. with Screen Recording
        /// granted. The WindowServer's own `kCGSWindowTitle` is empty for every
        /// app window. Only its internal windows ("Menubar") carry one.
        let title: String?
    }

    /// Real windows on `space`, front to back, ignoring compositing surfaces
    /// and child panels.
    static func windows(onSpace space: CGSSpaceID, titles: [CGWindowID: String]) -> [Window] {
        let ids = windowIDs(onSpace: space)
        guard !ids.isEmpty else { return [] }

        guard let query = SLSWindowQueryWindows(connection, ids as CFArray, Int32(ids.count))?
                .takeRetainedValue(),
              let iterator = SLSWindowQueryResultCopyWindows(query)?.takeRetainedValue()
        else { return [] }

        var result: [Window] = []
        while SLSWindowIteratorAdvance(iterator) {
            guard isReal(iterator) else { continue }
            let id = SLSWindowIteratorGetWindowID(iterator)
            result.append(Window(id: id,
                                 pid: SLSWindowIteratorGetPID(iterator),
                                 title: titles[id]))
        }
        return result
    }

    /// Every window id the WindowServer lists on `space`, real or not.
    /// Option `0x7` includes minimized windows, and `0x2` would leave them out.
    private static func windowIDs(onSpace space: CGSSpaceID) -> [NSNumber] {
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let raw = SLSCopyWindowsWithOptionsAndTags(
            connection, 0, [NSNumber(value: space)] as CFArray, 0x7, &setTags, &clearTags
        )?.takeRetainedValue()
        return raw as? [NSNumber] ?? []
    }

    /// Whether the iterator is parked on something a person would call a window.
    ///
    /// - `attributes & 0x2` is the test yabai uses, and it alone drops Chrome's
    ///   twenty compositing surfaces, which carry `attributes = 0`.
    /// - a non-zero parent is a panel attached to another window: Lightroom's
    ///   toolbars and filmstrip, eleven rows that collapse to one without it.
    /// - level 0 is the normal window layer. The menu bar sits at 24, Control
    ///   Center at 25, this app's own HUD at 101.
    /// - zero alpha is a window that is present but invisible.
    private static func isReal(_ iterator: CFTypeRef) -> Bool {
        SLSWindowIteratorGetAttributes(iterator) & 0x2 != 0
            && SLSWindowIteratorGetParentID(iterator) == 0
            && SLSWindowIteratorGetLevel(iterator) == 0
            && SLSWindowIteratorGetAlpha(iterator) > 0
    }

    /// Window titles from `CGWindowList`, for every window on every Space.
    ///
    /// Empty unless Screen Recording is granted, as `kCGWindowName` is gated on
    /// it, and without the grant a full scan reports a name for three windows
    /// out of three hundred. The switcher falls back to app name plus Space.
    static func titles() -> [CGWindowID: String] {
        guard CGPreflightScreenCaptureAccess(),
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [:] }

        var result: [CGWindowID: String] = [:]
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let name = info[kCGWindowName as String] as? String, !name.isEmpty
            else { continue }
            result[id] = name
        }
        return result
    }

    /// Focus a window we have no `AXUIElement` for, which is every window on a
    /// Space this app has not visited.
    ///
    /// `_SLPSSetFrontProcessWithOptions` takes a window id, so unlike
    /// `NSRunningApplication.activate()` it names *which* window comes forward,
    /// and it switches Space to get there. The two synthetic event records that
    /// follow are what tells the app itself that the window was activated,
    /// without them Cocoa apps come forward with the wrong window keyed. This
    /// is yabai's sequence.
    static func raise(window id: CGWindowID) -> Bool {
        var owner: Int32 = 0
        guard SLSGetWindowOwner(connection, id, &owner) == .success else { return false }

        var psn = ProcessSerialNumber()
        guard SLSGetConnectionPSN(owner, &psn) == .success else { return false }

        _SLPSSetFrontProcessWithOptions(&psn, id, kCPSUserGenerated)

        // A synthesised window-activated record. The offsets are the layout of
        // the event record struct, and only the window id inside it varies.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        for offset in 0x20..<0x30 { bytes[offset] = 0xff }
        withUnsafeBytes(of: id) { raw in
            for (index, byte) in raw.enumerated() { bytes[0x3c + index] = byte }
        }

        // 0x01 is "window activated", 0x02 "window deactivated". The pair is
        // what a real click produces, and apps that only watch one still react.
        for phase in [UInt8(0x01), UInt8(0x02)] {
            bytes[0x08] = phase
            _ = bytes.withUnsafeMutableBufferPointer { buffer in
                SLPSPostEventRecordTo(&psn, buffer.baseAddress!)
            }
        }
        return true
    }
}

// MARK: - SkyLight SPI

private let connection = SLSMainConnectionID()

private let kCPSUserGenerated: UInt32 = 0x200

@_silgen_name("SLSMainConnectionID")
private func SLSMainConnectionID() -> CGSConnectionID

@_silgen_name("SLSCopyWindowsWithOptionsAndTags")
private func SLSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID,
                                              _ owner: UInt32,
                                              _ spaces: CFArray,
                                              _ options: UInt32,
                                              _ setTags: UnsafeMutablePointer<UInt64>,
                                              _ clearTags: UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?

@_silgen_name("SLSWindowQueryWindows")
private func SLSWindowQueryWindows(_ cid: CGSConnectionID,
                                   _ windows: CFArray,
                                   _ count: Int32) -> Unmanaged<CFTypeRef>?

@_silgen_name("SLSWindowQueryResultCopyWindows")
private func SLSWindowQueryResultCopyWindows(_ query: CFTypeRef) -> Unmanaged<CFTypeRef>?

@_silgen_name("SLSWindowIteratorAdvance")
private func SLSWindowIteratorAdvance(_ iterator: CFTypeRef) -> Bool

@_silgen_name("SLSWindowIteratorGetWindowID")
private func SLSWindowIteratorGetWindowID(_ iterator: CFTypeRef) -> CGWindowID

@_silgen_name("SLSWindowIteratorGetPID")
private func SLSWindowIteratorGetPID(_ iterator: CFTypeRef) -> pid_t

@_silgen_name("SLSWindowIteratorGetParentID")
private func SLSWindowIteratorGetParentID(_ iterator: CFTypeRef) -> CGWindowID

@_silgen_name("SLSWindowIteratorGetLevel")
private func SLSWindowIteratorGetLevel(_ iterator: CFTypeRef) -> Int32

@_silgen_name("SLSWindowIteratorGetAttributes")
private func SLSWindowIteratorGetAttributes(_ iterator: CFTypeRef) -> UInt64

@_silgen_name("SLSWindowIteratorGetAlpha")
private func SLSWindowIteratorGetAlpha(_ iterator: CFTypeRef) -> Float

@_silgen_name("SLSGetWindowOwner")
private func SLSGetWindowOwner(_ cid: CGSConnectionID,
                               _ wid: CGWindowID,
                               _ owner: UnsafeMutablePointer<Int32>) -> CGError

@_silgen_name("SLSGetConnectionPSN")
private func SLSGetConnectionPSN(_ cid: CGSConnectionID,
                                 _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> CGError

@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                                             _ wid: CGWindowID,
                                             _ mode: UInt32)

@_silgen_name("SLPSPostEventRecordTo")
private func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                                   _ bytes: UnsafeMutablePointer<UInt8>) -> OSStatus
