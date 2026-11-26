import Foundation

/// The 16 kHz mono samples of one recording.
///
/// A take outlives the converter that feeds it. When the microphone changes
/// format, `Recorder` builds a new `AudioTapProcessor`, and the audio collected
/// before the change has to keep its place: the live loop and the transcript
/// ledger address the take by absolute offsets. The store is the piece the
/// successive processors share, so appending after a rebuild continues where
/// the previous processor stopped instead of starting a second recording at
/// zero.
///
/// The store also fences the processor a rebuild replaced. A tap callback can
/// still be running on the audio thread while the main actor installs the new
/// converter; the old processor keeps the generation it was built with, so its
/// late samples are dropped instead of landing after the new processor's. The
/// samples accepted before the swap keep their order.
///
/// Every access is guarded by the same lock: the audio thread appends while the
/// live loop reads ranges on the main actor.
final class AudioSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var generation = 0

    /// How many samples the take holds.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// The generation appends are currently accepted from.
    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Closes the current generation and returns the one that follows.
    ///
    /// Called once per rebuild, on the main actor, before the new tap is
    /// installed. The processor that fed the take up to this point cannot
    /// append after the swap: its generation is no longer the live one.
    ///
    /// - Returns: the generation the new processor must append with.
    func beginGeneration() -> Int {
        lock.lock()
        generation += 1
        let current = generation
        lock.unlock()
        return current
    }

    /// Adds the samples one buffer produced, when they belong to the live
    /// generation.
    ///
    /// The check and the append happen under one lock, so a processor that was
    /// fenced out cannot interleave a late buffer into the new processor's
    /// audio.
    ///
    /// - Parameters:
    ///   - chunk: the samples to add at the end of the take.
    ///   - generation: the generation the processor was built with.
    /// - Returns: `true` when the samples were accepted.
    @discardableResult
    func append(_ chunk: [Int16], from generation: Int) -> Bool {
        guard !chunk.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return false }
        samples.append(contentsOf: chunk)
        return true
    }

    /// Adds samples produced by a gated start after its identity was verified.
    ///
    /// The append happens on the audio control queue, before the gate starts
    /// feeding the accepted processor, so no converter can interleave with it.
    func append(contentsOf chunk: [Int16]) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    /// Every sample collected so far.
    func all() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// A copy of one range of the samples collected so far.
    ///
    /// The range is clamped to what has arrived, so a caller that raced the
    /// audio thread gets a shorter range instead of a crash. Only the range is
    /// copied: the live loop asks for one chunk, not for the whole take.
    func samples(in range: Range<Int>) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let lower = min(max(range.lowerBound, 0), samples.count)
        let upper = min(max(range.upperBound, lower), samples.count)
        guard lower < upper else { return [] }
        return Array(samples[lower..<upper])
    }
}
