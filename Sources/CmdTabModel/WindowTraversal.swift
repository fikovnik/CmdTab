/// A nil window list means that the scan is incomplete.
public struct WindowTraversal<Item: Identifiable> {
    public private(set) var windows: [Item]?
    private var offset: Int

    public init(reversed: Bool = false) { offset = reversed ? -1 : 1 }

    public var index: Int {
        guard let windows, !windows.isEmpty else { return 0 }
        return ((offset % windows.count) + windows.count) % windows.count
    }

    public var selected: Item? {
        guard let windows, !windows.isEmpty else { return nil }
        return windows[index]
    }

    /// Before the scan, collect steps in the offset. After the scan, page steps stop at the list limits.
    public mutating func step(_ delta: Int, wrap: Bool = true) {
        if !wrap, let windows, !windows.isEmpty {
            offset = max(0, min(index + delta, windows.count - 1))
        } else { offset += delta }
    }

    /// Keep the offset until the first scan completes.
    /// For subsequent lists, keep the selected window by ID or select the first row.
    public mutating func replace(with windows: [Item]) {
        let pending = self.windows == nil
        let previous = selected?.id
        self.windows = windows
        if !pending { offset = previous.flatMap { id in windows.firstIndex { $0.id == id } } ?? 0 }
    }
}
