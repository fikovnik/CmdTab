import Foundation

/// The text filter for one traversal. Match each label independently.
public struct WindowSearch: Sendable {
    public private(set) var query: String

    public init(_ query: String = "") { self.query = query }

    public mutating func append(_ text: String) { query.append(contentsOf: text) }

    public mutating func deleteLastCharacter() {
        if !query.isEmpty { query.removeLast() }
    }

    public func matches(appName: String, title: String) -> Bool {
        query.isEmpty || !ranges(in: appName).isEmpty || !ranges(in: title).isEmpty
    }

    /// UTF-16 ranges for attributed text. Include overlapping occurrences.
    public func ranges(in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var result: [NSRange] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            result.append(NSRange(range, in: text))
            start = text.index(after: range.lowerBound)
        }
        return result
    }
}
