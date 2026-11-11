import Foundation

/// A framework object that is built when it is first needed and dropped when it
/// has been idle.
///
/// Every connector adapter needs this. An `EKEventStore` costs an XPC
/// connection to `eventd`; a `CNContactStore` costs one to `contactsd`; neither
/// should exist in a process that only records dictation, and neither should
/// stay resident all day after one reminder was read. The value is created on
/// the first acquire, and a detached task drops it once it has gone unused for
/// the idle interval.
///
/// The generation counter is what makes the release safe: a task scheduled by
/// an old acquire compares its generation with the current one and does
/// nothing when another acquire has happened since. No timer is kept, so an
/// idle resource costs nothing at all while it waits.
public final class LazyResource<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var generation = 0
    private let make: @Sendable () -> Value
    private let dispose: (@Sendable (Value) -> Void)?
    private let idle: Duration

    /// Creates a resource.
    ///
    /// - Parameters:
    ///   - idle: how long it may sit unused before it is dropped.
    ///   - make: builds the value. It runs once per load, under the lock.
    ///   - dispose: runs when the value is dropped, for a framework object that
    ///     has something to close.
    public init(
        idle: Duration = .seconds(120),
        make: @escaping @Sendable () -> Value,
        dispose: (@Sendable (Value) -> Void)? = nil
    ) {
        self.idle = idle
        self.make = make
        self.dispose = dispose
    }

    /// The value, building it if this is the first call since it was dropped.
    ///
    /// - Returns: the loaded value.
    public func acquire() -> Value {
        lock.lock()
        let loaded: Value
        if let value {
            loaded = value
        } else {
            loaded = make()
            value = loaded
        }
        generation += 1
        let scheduled = generation
        lock.unlock()
        scheduleRelease(for: scheduled)
        return loaded
    }

    /// Drops the value now, if there is one.
    public func release() {
        lock.lock()
        let dropped = value
        value = nil
        generation += 1
        lock.unlock()
        if let dropped, let dispose {
            dispose(dropped)
        }
    }

    /// Whether a value is loaded, for a test and for Diagnostics.
    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != nil
    }

    /// Schedules the release that follows one acquire.
    ///
    /// The task is detached and holds only the generation it was made for, so a
    /// resource that is used again before the interval passes survives.
    private func scheduleRelease(for scheduled: Int) {
        let interval = idle
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: interval)
            self?.releaseIfUnused(scheduled)
        }
    }

    /// Drops the value when nothing has acquired it since `scheduled`.
    private func releaseIfUnused(_ scheduled: Int) {
        lock.lock()
        guard generation == scheduled else {
            lock.unlock()
            return
        }
        let dropped = value
        value = nil
        generation += 1
        lock.unlock()
        if let dropped, let dispose {
            dispose(dropped)
        }
    }
}
