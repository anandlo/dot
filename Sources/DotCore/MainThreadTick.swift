import Foundation

/// Runs a timer tick on the main actor without allocating a task for it.
///
/// The key watcher and the recording clock tick many times a second on the main
/// run loop. Wrapping each tick in a `Task` allocated one task per tick: sixty a
/// second while the app is idle, five million in a day, for work that is already
/// on the main thread. A tick that is already there runs in place; one that is
/// not is handed to the main queue.
public enum MainThreadTick {
    /// Runs `block` on the main actor.
    ///
    /// - Parameter block: the tick. It is `@Sendable` so a timer, which is not
    ///   actor isolated, can be built around it.
    public static func run(_ block: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { block() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { block() }
            }
        }
    }
}
