import CoreGraphics
import Foundation

/// The observed focus order, most recent first. A focus request does not change this order.
public struct RecentWindows: Sendable {
    /// Wait 60 ms for the last focus report from an app. Apps can report several windows during activation.
    public static let settleTime: TimeInterval = 0.06

    public private(set) var order: [CGWindowID] = []
    private var pending: [pid_t: (window: CGWindowID, time: TimeInterval)] = [:]

    public init() {}

    /// Puts the window first immediately.
    public mutating func promote(_ id: CGWindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// Keep the last focus report per app.
    public mutating func report(_ id: CGWindowID, pid: pid_t, at time: TimeInterval) {
        pending[pid] = (id, time)
    }

    public var hasPendingAnswers: Bool { !pending.isEmpty }

    /// Apply reports that reached the settle time, oldest first.
    public mutating func settle(at time: TimeInterval) {
        let due = pending.filter { time - $0.value.time >= Self.settleTime }
        for (pid, answer) in due.sorted(by: { $0.value.time < $1.value.time }) {
            promote(answer.window)
            pending[pid] = nil
        }
    }

    /// Apply all pending reports immediately.
    public mutating func settleAll() {
        settle(at: .infinity)
    }

    /// Remove closed windows from the order and pending reports.
    public mutating func retain(_ live: Set<CGWindowID>) {
        order.removeAll { !live.contains($0) }
        pending = pending.filter { live.contains($0.value.window) }
    }

    /// Put known windows first. Keep unseen windows in their input order.
    public func sorted(_ ids: [CGWindowID]) -> [CGWindowID] {
        let live = Set(ids)
        let known = Set(order)
        return order.filter(live.contains) + ids.filter { !known.contains($0) }
    }
}
