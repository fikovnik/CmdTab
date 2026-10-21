/// The selection in one window list. A nil list means that the scan is pending.
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

    /// Accumulate steps before the scan. Page steps stop at the list boundaries.
    public mutating func step(_ delta: Int, wrap: Bool = true) {
        if !wrap, let windows, !windows.isEmpty {
            offset = max(0, min(index + delta, windows.count - 1))
        } else { offset += delta }
    }

    /// Keep the initial offset until the first scan. Later lists keep the selected
    /// window by ID, or select the first row if there is no matching selection.
    public mutating func replace(with windows: [Item]) {
        let pending = self.windows == nil
        let previous = selected?.id
        self.windows = windows
        if !pending { offset = previous.flatMap { id in windows.firstIndex { $0.id == id } } ?? 0 }
    }
}
