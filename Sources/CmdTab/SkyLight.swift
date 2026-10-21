import AppKit
import CmdTabModel

/// Keep private WindowServer declarations in this file.
@MainActor
enum WindowServer {
    /// Read window IDs and process IDs in stack order.
    /// Minimized windows can lack normal window attributes. Accept windows that AX confirms as minimized.
    static func windows(onSpace space: SpaceID,
                        includingMinimized minimized: Set<CGWindowID> = []) -> [(id: CGWindowID, pid: pid_t)] {
        let ids = windowIDs(onSpace: space)
        guard !ids.isEmpty,
              let query = SLSWindowQueryWindows(connection, ids as CFArray, Int32(ids.count))?
                .takeRetainedValue(),
              let iterator = SLSWindowQueryResultCopyWindows(query)?.takeRetainedValue()
        else { return [] }

        var result: [(id: CGWindowID, pid: pid_t)] = []
        while SLSWindowIteratorAdvance(iterator) {
            let id = SLSWindowIteratorGetWindowID(iterator)
            guard minimized.contains(id) || isReal(iterator) else { continue }
            result.append((id, SLSWindowIteratorGetPID(iterator)))
        }
        return result
    }

    /// Option `0x7` includes minimized windows.
    private static func windowIDs(onSpace space: SpaceID) -> [NSNumber] {
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let raw = SLSCopyWindowsWithOptionsAndTags(
            connection, 0, [NSNumber(value: space)] as CFArray, 0x7, &setTags, &clearTags
        )?.takeRetainedValue()
        return raw as? [NSNumber] ?? []
    }

    /// Require attribute bit `0x2` for normal windows.
    /// Reject attached panels, other window levels, and transparent surfaces.
    private static func isReal(_ iterator: CFTypeRef) -> Bool {
        SLSWindowIteratorGetAttributes(iterator) & 0x2 != 0
            && SLSWindowIteratorGetParentID(iterator) == 0
            && SLSWindowIteratorGetLevel(iterator) == 0
            && SLSWindowIteratorGetAlpha(iterator) > 0
    }

    /// Read titles across all Spaces. Return no titles without the Screen Recording permission.
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

    static func spaces(ofWindow id: CGWindowID) -> [SpaceID] {
        let raw = CGSCopySpacesForWindows(connection, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue()
        return (raw as? [NSNumber] ?? []).map(\.uint64Value)
    }

    /// Return the window size in points.
    static func size(ofWindow id: CGWindowID) -> CGSize? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
                as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"], let height = bounds["Height"]
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Read window pixels at nominal resolution. Covered windows can have incomplete images.
    static func capture(window id: CGWindowID) -> CGImage? {
        var target = id
        let raw = SLSHWCaptureWindowList(connection, &target, 1, captureOptions)?.takeRetainedValue()
        return (raw as? [CGImage])?.first
    }

    /// Make this window the front window, then send the event that makes it key.
    /// The front process call can change the stored front app on other Spaces.
    @discardableResult
    static func front(window id: CGWindowID, pid: pid_t) -> Bool {
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return false }
        let result = _SLPSSetFrontProcessWithOptions(&psn, id, userGenerated)
        guard result == .success else {
            Diagnostics.error("front process failed id=\(id) pid=\(pid) error=\(result.rawValue)")
            return false
        }
        return makeKeyWindow(&psn, id) == .success
    }

    /// Update the front app for `space` without a change to the global front process.
    static func setFrontApp(_ pid: pid_t, of space: SpaceID) {
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return }
        _ = SLSSpaceSetFrontPSN(connection, space, psn)
    }

    /// Send a mouse down event to make the window key. The record layout comes from yabai and AltTab.
    /// Allocate 0x100 bytes for the 0xf8-byte record because newer systems can read beyond the declared length.
    /// Use a distant click point. Some apps replace NaN coordinates with zero.
    /// Omit the mouse up event to prevent a control action.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ id: CGWindowID) -> CGError {
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
        return bytes.withUnsafeMutableBufferPointer { buffer in
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
                                             _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo")
private func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                                   _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

@_silgen_name("SLSSpaceSetFrontPSN")
private func SLSSpaceSetFrontPSN(_ cid: CGSConnectionID, _ space: SpaceID,
                                 _ psn: ProcessSerialNumber) -> CGError
