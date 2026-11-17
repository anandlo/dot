import Foundation

/// One append of the draft, with the reading of the card's clock it arrived on.
///
/// The stream hands the body its words in deltas, and the delta is the only
/// arrival the card can date: it is what the service sent and what the runner
/// wrote. The count is where the chunk ends in the draft, so a run of chunks is
/// a table of character ranges and the time each one landed.
public struct RewriteDraftChunk: Equatable, Sendable {
    /// How many characters the draft holds once this chunk has been appended.
    public let count: Int
    /// When the chunk arrived, on the card's clock, in seconds.
    public let time: Double

    public init(count: Int, time: Double) {
        self.count = count
        self.time = time
    }
}

/// The arrival ramp of a streaming draft.
///
/// A draft that appeared at its final strength reads as a paragraph that was
/// already there; a draft that fades in whole, once, turns the whole body into a
/// transition. The ramp is the smallest movement that says "this is arriving":
/// only the words that landed in the last ``duration`` are dimmed, and each one
/// comes up to the body's own ink, so nothing moves, nothing changes colour, and
/// the reading position of the paragraph above the newest words does not shift.
///
/// The ramp works in chunks rather than in single glyphs because the chunk is
/// the arrival the stream actually reports: every character the service sent in
/// one delta landed at one moment, and there is no honest timestamp that
/// separates them further.
public enum RewriteDraftRamp {
    /// How long one chunk takes to reach the body's ink, in seconds.
    public static let duration: Double = 0.38

    /// The opacity a chunk is drawn at the instant it lands.
    ///
    /// Below two thirds the newest words read as disabled rather than as
    /// arriving, and on this card the amber is the only colour that carries a
    /// state: dim ink has to stay legible on its own.
    public static let minimumOpacity: Double = 0.62

    /// One range of the draft that is still coming up to the body's ink.
    public struct Run: Equatable, Sendable {
        /// The characters this run covers, counted from the start of the draft.
        public let range: Range<Int>
        /// How strongly they are drawn, from ``minimumOpacity`` to `1`.
        public let opacity: Double

        public init(range: Range<Int>, opacity: Double) {
            self.range = range
            self.opacity = opacity
        }
    }

    /// How far one chunk has come up to the body's ink.
    ///
    /// The curve is the strong ease-out the card presses with: the words leave
    /// the dim floor quickly and settle into the ink, so the last third of the
    /// ramp is almost still and two frames a few milliseconds apart cannot be
    /// told apart at the end of it.
    ///
    /// - Parameter elapsed: how long ago the chunk arrived, in seconds.
    /// - Returns: the ramp from `0` to `1`.
    public static func progress(elapsed: Double) -> Double {
        guard elapsed.isFinite else { return 1 }
        guard elapsed > 0 else { return 0 }
        guard elapsed < duration else { return 1 }
        let t = 1 - elapsed / duration
        return 1 - t * t * t
    }

    /// The opacity of a chunk that arrived one time ago.
    ///
    /// - Parameter elapsed: how long ago the chunk arrived, in seconds.
    /// - Returns: the opacity, from ``minimumOpacity`` to `1`.
    public static func opacity(elapsed: Double) -> Double {
        minimumOpacity + (1 - minimumOpacity) * progress(elapsed: elapsed)
    }

    /// The ranges of a draft that are still arriving.
    ///
    /// Older chunks are not returned at all: they are at the body's ink, and a
    /// run that said so with an explicit `1` would make every frame rebuild the
    /// whole paragraph. The runs are ascending, disjoint, and stop at the end of
    /// the draft as it is now, so a chunk left over from a draft that was
    /// cleared or replaced cannot name characters that are no longer there.
    ///
    /// - Parameters:
    ///   - chunks: the appends the draft has been given, oldest first.
    ///   - length: how many characters the draft holds now.
    ///   - time: the card's clock, in seconds.
    ///   - reduceMotion: whether the system asked for reduced motion. Nothing
    ///     ramps then: the words are drawn in the body's ink the moment they
    ///     land, and the clock is not read.
    /// - Returns: the runs that are still ramping, in ascending order.
    public static func runs(
        chunks: [RewriteDraftChunk],
        length: Int,
        time: Double,
        reduceMotion: Bool
    ) -> [Run] {
        guard !reduceMotion, length > 0, time.isFinite else { return [] }
        var runs: [Run] = []
        var previous = 0
        for chunk in chunks {
            let end = min(chunk.count, length)
            defer { previous = max(previous, end) }
            guard chunk.time.isFinite else { continue }
            let elapsed = time - chunk.time
            guard elapsed < duration else { continue }
            let start = min(previous, end)
            guard end > start else { continue }
            runs.append(Run(range: start ..< end, opacity: opacity(elapsed: elapsed)))
        }
        return runs
    }
}
