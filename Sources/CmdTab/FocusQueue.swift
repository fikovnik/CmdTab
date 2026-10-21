import Foundation

/// Serialize focus commands. A new request prevents obsolete commands from reaching their next step.
final class FocusQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.fikovnik.cmdtab.focus", qos: .userInteractive)
    private let lock = NSLock()
    private var generation: UInt64 = 0

    @discardableResult
    func submit(_ operation: @escaping @Sendable (UInt64, @escaping @Sendable () -> Bool) -> Void) -> UInt64 {
        lock.lock()
        generation += 1
        let request = generation
        lock.unlock()

        queue.async {
            let isCurrent: @Sendable () -> Bool = {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.generation == request
            }
            guard isCurrent() else { return }
            operation(request, isCurrent)
        }
        return request
    }
}
