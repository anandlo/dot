import Foundation

/// Runs archive work one piece at a time, in the order it was submitted.
///
/// The archive is an actor, so its writes do not interleave, but the work before
/// a write happens outside it: resolving the folder's bookmark, reading the
/// settings, deciding the day. Two changes that each do that first reach the
/// actor in whatever order the machine feels like, and a rewrite that overtakes
/// its own take writes a second section where there should be one. Every later
/// rewrite of those words is then ambiguous and refused.
///
/// The chain is over whole changes rather than over the actor's turns, so the
/// order a person produced the changes in is the order they are written in.
public final class ArchiveSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    /// Creates an empty sequence.
    public init() {}

    /// Adds `work` to the end of the sequence.
    ///
    /// The task is detached: the work reads and writes a day file, and the
    /// submitter is usually the main actor.
    ///
    /// - Parameter work: the change to make.
    /// - Returns: the task that runs it after everything submitted before it, so
    ///   a quit can wait for the chain.
    @discardableResult
    public func submit(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        let task = Task.detached(priority: .utility) {
            await previous?.value
            await work()
        }
        tail = task
        return task
    }
}
