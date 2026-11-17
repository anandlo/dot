import Foundation

/// The clock a quit measures its wait with.
///
/// The app uses ``live``: the monotonic clock and a real sleep. A test passes a
/// clock it moves by hand, so the arithmetic of the wait is asserted exactly
/// rather than measured against a runner whose speed nobody controls.
public struct ShutdownClock: Sendable {
    /// The time now, measured from a fixed point.
    public let now: @Sendable () -> Duration
    /// Suspends for at least `duration`.
    public let sleep: @Sendable (Duration) async -> Void

    /// Creates a clock from the two things the wait needs.
    public init(
        now: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// The clock and the sleep the app uses.
    public static let live: ShutdownClock = {
        let origin = ContinuousClock.now
        return ShutdownClock(
            now: { origin.duration(to: ContinuousClock.now) },
            sleep: { duration in try? await Task.sleep(for: duration) }
        )
    }()
}

/// The last thing the app does: let the archive finish, then answer the quit.
///
/// A day file is replaced whole, so a write cut off by the process ending is a
/// write that did not happen. The archive's in-flight writes are therefore
/// waited for before AppKit is told the app may go.
///
/// The wait is bounded. A folder on a network volume, or one on a disk that has
/// gone to sleep, can take longer than a person will wait for a quit, and the
/// words are already in the history: a write that has not finished in two
/// seconds is one the next launch does not miss.
public enum Shutdown {
    /// How long a quit waits for the archive.
    public static let archiveLimit = Duration.seconds(2)

    /// Waits for every write `pending` hands over, including the ones that
    /// arrive while it waits, then answers the termination request.
    ///
    /// The loop is what makes the quit complete rather than prompt. A write can
    /// be registered during the drain - the card's last versions, a rewrite that
    /// landed as the person quit - and it is waited for too, because the answer
    /// is what lets the process end.
    ///
    /// The whole loop shares one limit, so a folder that never answers costs the
    /// quit two seconds rather than two seconds per write.
    ///
    /// The last look and the answer are one synchronous step on the main actor,
    /// with no suspension between them. A suspension there would be a turn in
    /// which a rewrite finishing on the main actor could register a write the
    /// answer never waits for, so the quit would proceed with that write still
    /// running. With the two in one step the set of writes the quit waits for is
    /// exactly the set registered when the look is made, and a write registered
    /// after the answer is one the archive started after the app was told to go,
    /// which is a boundary no wait can move.
    ///
    /// - Parameters:
    ///   - limit: the longest the answer waits, in total.
    ///   - clock: what the limit is measured with.
    ///   - pending: the writes not waited for yet, read on the main actor and
    ///     synchronously. Taking them is what tells a later pass that they are
    ///     done.
    ///   - reply: the answer to the request,
    ///     `NSApplication.reply(toApplicationShouldTerminate:)` in the app.
    public static func drain(
        limit: Duration = archiveLimit,
        clock: ShutdownClock = .live,
        pending: @MainActor @Sendable () -> [Task<Void, Never>],
        reply: @MainActor @Sendable (Bool) -> Void
    ) async {
        let deadline = clock.now() + limit
        while true {
            let step = await MainActor.run { () -> Step in
                let tasks = pending()
                guard !tasks.isEmpty else {
                    reply(true)
                    return .answered
                }
                let remaining = deadline - clock.now()
                guard remaining > .zero else {
                    reply(true)
                    return .answered
                }
                return .waiting(tasks, remaining)
            }
            switch step {
            case .answered:
                return
            case .waiting(let tasks, let remaining):
                await wait(for: tasks, limit: remaining, clock: clock)
            }
        }
    }

    /// What one synchronous step on the main actor decided.
    private enum Step: Sendable {
        /// The request was answered, so the drain is finished.
        case answered
        /// These writes have not been waited for, and the limit leaves this much
        /// of itself.
        case waiting([Task<Void, Never>], Duration)
    }

    /// Waits for the tasks, or for the limit, whichever comes first.
    ///
    /// - Parameters:
    ///   - tasks: the work to wait for.
    ///   - limit: the longest the wait lasts.
    ///   - clock: what the limit is measured with.
    public static func wait(
        for tasks: [Task<Void, Never>],
        limit: Duration,
        clock: ShutdownClock = .live
    ) async {
        if !tasks.isEmpty {
            // Whichever arrives first wins: the last task finishing, or the
            // limit running out. A group cannot express this, because a child
            // waiting on a task's value ignores cancellation and the group would
            // still wait for it at the end of its scope.
            let race = FirstOf()
            let finished = Task {
                for task in tasks {
                    await task.value
                }
                await race.arrive()
            }
            let expiry = Task {
                await clock.sleep(limit)
                await race.arrive()
            }
            await race.wait()
            expiry.cancel()
            finished.cancel()
        }
    }
}

/// Answers once, whichever of two tasks gets there first.
private actor FirstOf {
    private var answered = false
    private var waiting: CheckedContinuation<Void, Never>?

    func arrive() {
        guard !answered else { return }
        answered = true
        waiting?.resume()
        waiting = nil
    }

    func wait() async {
        guard !answered else { return }
        await withCheckedContinuation { continuation in
            waiting = continuation
        }
    }
}
