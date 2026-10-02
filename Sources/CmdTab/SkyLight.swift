import AppKit
import CmdTabModel

/// Windows, Spaces and focus from the WindowServer, through private SkyLight
/// and CGS functions. Every macOS window switcher uses these functions. A
/// failed call gives an empty result.
@MainActor
enum WindowServer {
    /// The real windows on `space`, front to back.
    ///
    /// `kAXWindows` gives only the windows on visible Spaces. This query gives
    /// the windows on every Space. On a visible Space, its result after
    /// `isReal` is the same as the AX result.
    static func windows(onSpace space: SpaceID) -> [(id: CGWindowID, pid: pid_t)] {
        let ids = windowIDs(onSpace: space)
        guard !ids.isEmpty,
              let query = SLSWindowQueryWindows(connection, ids as CFArray, Int32(ids.count))?
                .takeRetainedValue(),
              let iterator = SLSWindowQueryResultCopyWindows(query)?.takeRetainedValue()
        else { return [] }

        var result: [(id: CGWindowID, pid: pid_t)] = []
        while SLSWindowIteratorAdvance(iterator) {
            guard isReal(iterator) else { continue }
            result.append((SLSWindowIteratorGetWindowID(iterator), SLSWindowIteratorGetPID(iterator)))
        }
        return result
    }

    /// All window IDs on `space`. Option 0x7 includes minimized windows.
    private static func windowIDs(onSpace space: SpaceID) -> [NSNumber] {
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let raw = SLSCopyWindowsWithOptionsAndTags(
            connection, 0, [NSNumber(value: space)] as CFArray, 0x7, &setTags, &clearTags
        )?.takeRetainedValue()
        return raw as? [NSNumber] ?? []
    }

    /// The query also gives compositing surfaces, attached panels and hidden
    /// windows. A real window has all of these properties:
    /// - attribute bit 0x2 (a Chrome compositing surface has attributes 0),
    /// - no parent window (an attached panel has a parent),
    /// - level 0, the normal window level (the menu bar is level 24),
    /// - an alpha value above 0.
    private static func isReal(_ iterator: CFTypeRef) -> Bool {
        SLSWindowIteratorGetAttributes(iterator) & 0x2 != 0
            && SLSWindowIteratorGetParentID(iterator) == 0
            && SLSWindowIteratorGetLevel(iterator) == 0
            && SLSWindowIteratorGetAlpha(iterator) > 0
    }

    /// The titles of all windows on all Spaces, from `CGWindowList`.
    /// Empty without Screen Recording permission, because macOS removes
    /// `kCGWindowName` then.
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

    /// Space membership also describes CmdTab's overlays. A panel that lost
    /// its all-Spaces assignment can be visible to AppKit but off screen.
    static func spaces(ofWindow id: CGWindowID) -> [SpaceID] {
        let raw = CGSCopySpacesForWindows(connection, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue()
        return (raw as? [NSNumber] ?? []).map(\.uint64Value)
    }

    /// The size of a window in points.
    static func size(ofWindow id: CGWindowID) -> CGSize? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
                as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"], let height = bounds["Height"]
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The pixels of one window, at its size in points. The call is
    /// synchronous and takes 3-18 ms.
    ///
    /// An app can release the drawing surface of a window that is covered or
    /// on another Space. Chrome does this. The capture of such a window shows
    /// the toolbar above a flat grey area.
    static func capture(window id: CGWindowID) -> CGImage? {
        var target = id
        let raw = SLSHWCaptureWindowList(connection, &target, 1, captureOptions)?.takeRetainedValue()
        return (raw as? [CGImage])?.first
    }

    /// Makes `id` the front window of the front app.
    ///
    /// 1. `_SLPSSetFrontProcessWithOptions` makes the app the front process.
    ///    The window ID makes it bring only this window to the front.
    /// 2. `makeKeyWindow` makes the window the key window of the app.
    ///
    /// The front process is global. Thus, step 1 can also change the front app
    /// that macOS keeps for other Spaces (alt-tab #4507).
    @discardableResult
    static func front(window id: CGWindowID, pid: pid_t) -> Bool {
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return false }
        _SLPSSetFrontProcessWithOptions(&psn, id, userGenerated)
        makeKeyWindow(&psn, id)
        return true
    }

    /// Sets the front app that macOS keeps for `space`. This does not change
    /// the global front process.
    static func setFrontApp(_ pid: pid_t, of space: SpaceID) {
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return }
        _ = SLSSpaceSetFrontPSN(connection, space, psn)
    }

    /// Sends a synthetic mouse-down event to the window. The event makes the
    /// window key. No public API can make the window of another app key.
    ///
    /// The record layout comes from yabai and alt-tab (`CGSEventRecord`):
    /// - The buffer has 0x100 bytes, but the record declares 0xf8 bytes at
    ///   offset 0x04. Since macOS 14.7.4 the WindowServer reads past the end of
    ///   the record, and it stops the process on random data there.
    /// - The click point at 0x20 is far from the window. Some apps change a NaN
    ///   point to (0, 0), and then the click operates a control there.
    /// - CmdTab sends only the mouse-down. It makes the window key. Without a
    ///   mouse-up, no control can operate.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ id: CGWindowID) {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x01  // kCGEventLeftMouseDown
        bytes[0x3a] = 0x10
        var point = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &point) { raw in
            for (index, byte) in raw.enumerated() { bytes[0x20 + index] = byte }
        }
        withUnsafeBytes(of: id) { raw in
            for (index, byte) in raw.enumerated() { bytes[0x3c + index] = byte }
        }
        _ = bytes.withUnsafeMutableBufferPointer { buffer in
            SLPSPostEventRecordTo(&psn, buffer.baseAddress!)
        }
    }
}

// MARK: - Declarations

typealias CGSConnectionID = Int32

private let connection = CGSMainConnectionID()

/// `kCPSUserGenerated`: the system handles the change as a user action.
private let userGenerated: UInt32 = 0x200

/// `kCGSWindowCaptureNominalResolution | kCGSWindowCaptureIgnoreGlobalClipShape`
private let captureOptions: UInt32 = 0x0200 | 0x0800

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ windows: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyActiveMenuBarDisplayIdentifier")
func CGSCopyActiveMenuBarDisplayIdentifier(_ cid: CGSConnectionID) -> Unmanaged<CFString>?

/// Gives the WindowServer ID of an AX element. This is the only link from
/// the AX tree to the WindowServer.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement,
                           _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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

@_silgen_name("SLSHWCaptureWindowList")
private func SLSHWCaptureWindowList(_ cid: CGSConnectionID,
                                    _ windows: UnsafeMutablePointer<CGWindowID>,
                                    _ count: Int32,
                                    _ options: UInt32) -> Unmanaged<CFArray>?

@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                                             _ wid: CGWindowID,
                                             _ mode: UInt32)

@_silgen_name("SLPSPostEventRecordTo")
private func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                                   _ bytes: UnsafeMutablePointer<UInt8>) -> OSStatus

@_silgen_name("SLSSpaceSetFrontPSN")
private func SLSSpaceSetFrontPSN(_ cid: CGSConnectionID, _ space: SpaceID,
                                 _ psn: ProcessSerialNumber) -> CGError
