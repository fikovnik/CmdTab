import AppKit
import CmdTabModel

struct WindowDescription: Sendable {
    let id: CGWindowID
    let pid: pid_t
    let element: AXReference
    let subrole: String?
    let title: String?
    let isMinimized: Bool?
    let spaces: [SpaceID]?
}

/// Read AX data on one worker. The main actor owns the window records and app icons.
enum WindowDescriptions {
    struct Snapshot: Sendable {
        let descriptions: [WindowDescription]
        let titles: [CGWindowID: String]
    }

    private static let queue = DispatchQueue(label: "net.fikovnik.cmdtab.window-descriptions", qos: .userInitiated)

    static func read(pids: Set<pid_t>, known: Set<CGWindowID>) async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let descriptions = pids.flatMap { readApp($0, known: known) }
                continuation.resume(returning: Snapshot(descriptions: descriptions, titles: WindowServer.titles()))
            }
        }
    }

    /// Focused and main window attributes can include windows on other Spaces.
    private static func readApp(_ pid: pid_t, known: Set<CGWindowID>) -> [WindowDescription] {
        let values = AXUIElement.application(pid)
            .values([kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute])
        let list = values[0] as? [AXUIElement] ?? []
        let single = values.dropFirst().compactMap { value in
            value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        var seen = Set<CGWindowID>()
        return (list + single).compactMap { element in
            guard let id = element.windowID, seen.insert(id).inserted else { return nil }
            let attributes = element.values([kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute])
            let minimized = attributes[2] as? Bool
            return WindowDescription(id: id, pid: pid, element: AXReference(element: element),
                                     subrole: attributes[0] as? String, title: attributes[1] as? String,
                                     isMinimized: minimized,
                                     spaces: !known.contains(id) && minimized == true
                                         ? WindowServer.spaces(ofWindow: id) : nil)
        }
    }
}
