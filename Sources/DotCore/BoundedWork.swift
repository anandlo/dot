import Foundation

/// Runs work that can block for an unbounded time without blocking the
/// caller.
///
/// A Keychain read may put a system prompt on screen and wait for it; the
/// answer can take as long as the person takes. That must never stop the main
/// actor, so the work runs on a background queue and the caller waits at most
/// for the deadline. When the deadline passes first, the caller is resumed
/// with ``Outcome/timedOut`` and the abandoned queue item is left where it is:
/// a late answer is dropped, because the continuation has already been
/// resumed.
public enum BoundedWork {
    /// What the bounded call produced.
    public enum Outcome<Value: Sendable>: Sendable {
        /// The work finished before the deadline.
        case finished(Value)
        /// The deadline passed first; the result is unknown.
        case timedOut

        /// The value, when the work finished in time.
        public var value: Value? {
            if case .finished(let value) = self { return value }
            return nil
        }
    }

    /// The longest a call is ever allowed to wait, whatever the caller asks
    /// for. It keeps the dispatch deadline arithmetic in range.
    public static let maximumTimeout: Duration = .seconds(3600)

    /// Runs `work` on a background queue and waits at most `timeout`.
    ///
    /// - Parameters:
    ///   - timeout: how long the caller is willing to wait.
    ///   - work: the blocking work, run off the caller's actor.
    /// - Returns: the value, or ``Outcome/timedOut`` when the deadline won.
    public static func run<Value: Sendable>(
        within timeout: Duration,
        _ work: @escaping @Sendable () -> Value
    ) async -> Outcome<Value> {
        let gate = ResumeGate()
        let deadline = DispatchTime.now() + .nanoseconds(nanoseconds(of: timeout))
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<Value>, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let value = work()
                if gate.claim() {
                    continuation.resume(returning: .finished(value))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                if gate.claim() {
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }

    /// The timeout in nanoseconds, clamped so the dispatch arithmetic is safe.
    static func nanoseconds(of timeout: Duration) -> Int {
        let clamped = min(max(timeout, .zero), maximumTimeout)
        let components = clamped.components
        let (seconds, overflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return Int.max }
        let remainder = Int(components.attoseconds / 1_000_000_000)
        return max(0, Int(seconds) + remainder)
    }

    /// Makes exactly one of the two racing paths the one that resumes.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
