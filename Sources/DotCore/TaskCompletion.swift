import Foundation

/// Waits for a task that was cancelled, without letting it hold the take open.
///
/// `Task.cancel()` only asks a request to stop. A provider call that is already
/// on the wire can take a moment to settle, and a tail sent while it is still
/// open would overlap it at the service. The caller waits for the live task to
/// finish — but only for `bound`, the same second the stop allows the last
/// partial. The wait is bounded even when the task ignores cancellation: the
/// caller returns at the deadline, and the abandoned waiter is resumed exactly
/// once.
public enum TaskCompletion {
    /// Waits for `task` to finish, or for `bound` to pass.
    ///
    /// The task is not cancelled here; the caller cancels it before waiting.
    /// Neither the task nor its value is changed by the result.
    ///
    /// - Parameters:
    ///   - task: the task to wait for.
    ///   - bound: the longest the caller will wait.
    /// - Returns: `true` when the task finished before the bound passed.
    public static func wait(for task: Task<Void, Never>, upTo bound: Duration) async -> Bool {
        let gate = ResumeGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task {
                await task.value
                if gate.claim() {
                    continuation.resume(returning: true)
                }
            }
            Task {
                try? await Task.sleep(for: bound)
                if gate.claim() {
                    continuation.resume(returning: false)
                }
            }
        }
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
