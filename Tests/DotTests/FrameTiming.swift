import Foundation

/// Wall-clock frame budgets are enforced on this Mac, in `scripts/install.sh`
/// and `scripts/fluidity-gate.sh`. Hosted CI runners miss them by 2-5x for
/// reasons unrelated to the code, so the CI gate sets `DOT_FRAME_TIMING=report`:
/// the numbers are still printed, every structural check still runs, and rate
/// and gap checks are scaled by that factor instead of dropped.
enum FrameTiming {
    static let isEnforced = ProcessInfo.processInfo.environment["DOT_FRAME_TIMING"] != "report"

    /// How much slower than this Mac a hosted runner may be.
    static let reportSlowdown = 5.0

    /// The count a rate check requires: `local` when budgets are enforced,
    /// otherwise `local` scaled by ``reportSlowdown`` and never below two, so
    /// an animation that draws once and freezes still fails.
    static func minimumCount(_ local: Int) -> Int {
        isEnforced ? local : max(2, Int((Double(local) / reportSlowdown).rounded(.up)))
    }

    /// The longest an animation may go without drawing: 100 ms here, 250 ms
    /// on a hosted runner, whose swatch intervals reach a p95 of about 105 ms.
    /// Watched over ``observationSeconds(_:)``, either fails a swatch that
    /// stops drawing. On a hosted runner this is a liveness check on draw
    /// callbacks (about 4 fps passes); no check here compares rendered pixels.
    static var maximumGapMS: Double { isEnforced ? 100 : 250 }

    /// How long an animation is watched: `local` here, three times that on a
    /// hosted runner, so a freeze outlasts ``maximumGapMS`` by a wide margin
    /// instead of hiding in the tail of a window barely longer than the gap.
    static func observationSeconds(_ local: Double) -> Double {
        isEnforced ? local : local * 3
    }

    /// The longest stretch of `start...end` with no draw, counting the lead
    /// before the first draw and the tail after the last, in milliseconds.
    static func longestGapMS(draws: [CFTimeInterval], start: CFTimeInterval, end: CFTimeInterval) -> Double {
        var previous = start
        var longest = 0.0
        for draw in draws.sorted() where draw >= start {
            longest = max(longest, draw - previous)
            previous = draw
        }
        longest = max(longest, end - previous)
        return longest * 1000
    }
}
