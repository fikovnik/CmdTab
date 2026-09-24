import AppKit

/// Windows on every Space, from the WindowServer.
///
/// `kAXWindowsAttribute` only describes the active Space, so the all-Spaces
/// list cannot come from AX. Measured from Desktop 3: AX returns
/// `status=success count=0` for all nine apps whose windows are on Desktop 1,
/// unchanged by a 5 s messaging timeout or `AXManualAccessibility`.
///
/// `SLSWindowQueryWindows` sees every Space, but reports compositing surfaces
/// and child panels as windows. `isReal` filters those out. On the active Space
/// the filtered list matches AX exactly.
///
/// SkyLight SPI throughout. Every call degrades to an empty result on failure.
@MainActor
enum WindowServer {

    struct Window {
        let id: CGWindowID
        let pid: pid_t
        /// Only set with Screen Recording granted. The WindowServer's own
        /// `kCGSWindowTitle` is empty for app windows. Only its internal ones
        /// ("Menubar") carry it.
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

    /// Whether the iterator is on a real window.
    ///
    /// - `attributes & 0x2`: drops Chrome's 20 compositing surfaces, which
    ///   carry `attributes = 0`.
    /// - zero parent: drops panels attached to another window, e.g. Lightroom's
    ///   11 toolbars and filmstrip.
    /// - level 0: the normal window layer. Menu bar is 24, Control Center 25,
    ///   this app's HUD 101.
    /// - non-zero alpha: present but invisible windows.
    private static func isReal(_ iterator: CFTypeRef) -> Bool {
        SLSWindowIteratorGetAttributes(iterator) & 0x2 != 0
            && SLSWindowIteratorGetParentID(iterator) == 0
            && SLSWindowIteratorGetLevel(iterator) == 0
            && SLSWindowIteratorGetAlpha(iterator) > 0
    }

    /// Window titles from `CGWindowList`, for every Space.
    ///
    /// Empty without Screen Recording: `kCGWindowName` is gated on it, and a
    /// full scan then names 3 windows out of 296. Callers fall back to app name
    /// plus Space label.
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

    static var activeSpace: CGSSpaceID { SLSGetActiveSpace(connection) }

    /// Real windows on the active Space, and which of them nothing is covering.
    ///
    /// Whether a window is covered decides how much to trust a capture of it.
    /// Some apps drop the drawing surface the moment a window is occluded.
    /// Chrome does, and measured, activating an app over two of its windows
    /// took their frames from 36 and 15 distinct colours to 7 and 8. A
    /// terminal keeps drawing and captures fine underneath three others. There
    /// is no flag that says which kind an app is, so a covered window is
    /// captured and the result judged on its contents.
    ///
    /// `uncovered` is approximated by "no single window in front of it contains
    /// its frame" rather than by unioning everything in front, because that is
    /// the case that occurs: same-size windows stacked on one Space.
    static func activeSpaceWindows() -> (all: Set<CGWindowID>, uncovered: Set<CGWindowID>) {
        let frames = bounds()
        var all = Set<CGWindowID>()
        var uncovered = Set<CGWindowID>()
        var inFront: [CGRect] = []
        for window in windows(onSpace: activeSpace, titles: [:]) {
            all.insert(window.id)
            guard let frame = frames[window.id] else { continue }
            if !inFront.contains(where: { $0.contains(frame) }) { uncovered.insert(window.id) }
            inFront.append(frame)
        }
        return (all, uncovered)
    }

    /// Every window's frame, from one `CGWindowList` scan.
    private static func bounds() -> [CGWindowID: CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [:] }

        var result: [CGWindowID: CGRect] = [:]
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let raw = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            result[id] = CGRect(x: raw["X"] ?? 0, y: raw["Y"] ?? 0,
                                width: raw["Width"] ?? 0, height: raw["Height"] ?? 0)
        }
        return result
    }

    /// The size in points the WindowServer says a window is.
    static func size(ofWindow id: CGWindowID) -> CGSize? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
                as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"], let height = bounds["Height"]
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// One window's pixels from the WindowServer's frame store, at the window's
    /// size in points. 3-18 ms, synchronous.
    ///
    /// Not `SCScreenshotManager`: that needs an `SCShareableContent` enumeration
    /// of all 299 windows before it can filter to one, and returns nothing for
    /// some windows, Lightroom's included, which this captures fine.
    ///
    /// Returns an empty frame for a window whose app released its drawing
    /// surface while occluded. See `WindowPreview.warm`.
    static func capture(window id: CGWindowID) -> CGImage? {
        var target = id
        let raw = SLSHWCaptureWindowList(connection, &target, 1, captureOptions)?
            .takeRetainedValue()
        return (raw as? [CGImage])?.first
    }

    /// Name which window of an app comes forward, by id.
    ///
    /// Does *not* switch Space (it only changes the front process) so callers
    /// pair it with an activation. The two synthetic event records tell the app
    /// itself that the window was activated. Without them Cocoa apps come
    /// forward with the wrong window keyed.
    static func raise(window id: CGWindowID) -> Bool {
        var owner: Int32 = 0
        guard SLSGetWindowOwner(connection, id, &owner) == .success else { return false }

        var psn = ProcessSerialNumber()
        guard SLSGetConnectionPSN(owner, &psn) == .success else { return false }

        _SLPSSetFrontProcessWithOptions(&psn, id, kCPSUserGenerated)

        // A synthetic click carrying the window id, which is what makes the
        // window key. Three details are not arbitrary. All three are measured
        // findings:
        //
        //  * 0x100 bytes allocated, though the record still declares 0xf8 at
        //    0x04. Since macOS 14.7.4 the WindowServer's `CGSEncodeEventRecord`
        //    reads past the end of the record and aborts on whatever it finds.
        //  * A real point far past the bottom-right corner rather than the
        //    `0xff` fill, which is NaN. Some apps sanitize NaN, and the click
        //    then lands somewhere real. Off the corner there is nothing to hit.
        //  * The mouse-down alone. The down is what makes the window key, an
        //    up on its own does nothing, and sending the pair means a control
        //    under the point could be activated.
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var point = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &point) { raw in
            for (index, byte) in raw.enumerated() { bytes[0x20 + index] = byte }
        }
        withUnsafeBytes(of: id) { raw in
            for (index, byte) in raw.enumerated() { bytes[0x3c + index] = byte }
        }
        bytes[0x08] = 0x01  // kCGEventLeftMouseDown
        _ = bytes.withUnsafeMutableBufferPointer { buffer in
            SLPSPostEventRecordTo(&psn, buffer.baseAddress!)
        }
        return true
    }
}

// MARK: - SkyLight SPI

private let connection = SLSMainConnectionID()

private let kCPSUserGenerated: UInt32 = 0x200


/// `kCGSWindowCaptureNominalResolution | kCGSWindowCaptureIgnoreGlobalClipShape`
private let captureOptions: UInt32 = 0x0200 | 0x0800

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

@_silgen_name("SLSGetActiveSpace")
private func SLSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("SLSHWCaptureWindowList")
private func SLSHWCaptureWindowList(_ cid: CGSConnectionID,
                                    _ windows: UnsafeMutablePointer<CGWindowID>,
                                    _ count: Int32,
                                    _ options: UInt32) -> Unmanaged<CFArray>?

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
