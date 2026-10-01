import CoreGraphics
import Foundation

/// The windows in the order of their last focus, most recent first.
///
/// Only the answer of the OS to "which window has focus" changes the order,
/// as in alt-tab. Such an answer is an app activation, or an app that reports
/// a new focused window. A switch that CmdTab requests does not change the
/// order. Thus, a focus that did not occur cannot change it (alt-tab #6055).
public struct RecentWindows: Sendable {
    /// An app that raises all its windows reports each of them as focused.
    /// Thus, an answer becomes final only if the same app sends no newer
    /// answer in this time (alt-tab #5974).
    public static let settleTime: TimeInterval = 0.06

    public private(set) var order: [CGWindowID] = []
    private var pending: [pid_t: (window: CGWindowID, time: TimeInterval)] = [:]

    public init() {}

    /// Puts the window first immediately.
    public mutating func promote(_ id: CGWindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// Records that app `pid` reports `id` as its focused window at `time`.
    /// A newer answer from the same app replaces this answer.
    public mutating func report(_ id: CGWindowID, pid: pid_t, at time: TimeInterval) {
        pending[pid] = (id, time)
    }

    public var hasPendingAnswers: Bool { !pending.isEmpty }

    /// Promotes each answer that is `settleTime` old or older, the oldest
    /// first. Thus, the newest answer is first in the order.
    public mutating func settle(at time: TimeInterval) {
        let due = pending.filter { time - $0.value.time >= Self.settleTime }
        for (pid, answer) in due.sorted(by: { $0.value.time < $1.value.time }) {
            promote(answer.window)
            pending[pid] = nil
        }
    }

    /// Promotes all answers now, without the settle time.
    public mutating func settleAll() {
        settle(at: .infinity)
    }

    /// Removes the windows that are not in `live`.
    public mutating func retain(_ live: Set<CGWindowID>) {
        order.removeAll { !live.contains($0) }
    }

    /// `ids` in switcher order: first the windows that had focus, most recent
    /// first, then the other windows in their order in `ids`.
    public func sorted(_ ids: [CGWindowID]) -> [CGWindowID] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let (seen, unseen) = ids.reduce(into: ([CGWindowID](), [CGWindowID]())) { result, id in
            if rank[id] != nil { result.0.append(id) } else { result.1.append(id) }
        }
        return seen.sorted { rank[$0]! < rank[$1]! } + unseen
    }
}
