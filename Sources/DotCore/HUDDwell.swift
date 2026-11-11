import Foundation

/// How long the transcript card stays on screen, and when its countdown stops.
///
/// The card used to stay for four seconds after the transcript landed, which is
/// shorter than it takes to read a transcript of a long recording. It stays for
/// ten by default now, and the countdown stops while the pointer is over the
/// card or the text is being scrolled: a card that can be read must not vanish
/// in the middle of a sentence.
///
/// The numbers live here with the rest of the card's decisions, so the settings
/// slider, the migration and the countdown cannot disagree about them.
public enum HUDDwell {
    /// The default the builds before this one wrote into every configuration.
    ///
    /// The slider used to write a value even when nobody moved it, so a stored
    /// four seconds does not mean "the user chose four seconds": it is what an
    /// untouched configuration holds.
    public static let legacyDefaultSeconds: Double = 4
    /// How long the transcript card stays on screen, in seconds.
    public static let defaultSeconds: Double = 10
    /// The shortest dwell the slider offers, in seconds.
    public static let minimumSeconds: Double = 2
    /// The longest dwell the slider offers, in seconds.
    public static let maximumSeconds: Double = 20
    /// The step the slider lands on, in seconds.
    public static let step: Double = 0.5
    /// How long the wheel keeps the card alive after the last scroll, in
    /// seconds.
    ///
    /// A two-finger scroll keeps moving the text after the fingers have left
    /// the trackpad, and it can outlive the pointer's stay over the card. The
    /// grace is what stops the card from disappearing while its own inertia is
    /// still running.
    public static let scrollGrace: Double = 1.5
    /// The revision of the dwell a configuration file is written with.
    ///
    /// A file that carries an older revision predates this dwell, and
    /// ``HUDDwellMigration`` rewrites it once.
    public static let revision = 1

    /// A dwell that the card can use.
    ///
    /// - Parameter seconds: a dwell, in seconds.
    /// - Returns: `seconds` inside the slider's range, or the default when it is
    ///   not a number at all.
    public static func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultSeconds }
        return min(max(seconds, minimumSeconds), maximumSeconds)
    }

    /// The dwell a configuration file should use.
    ///
    /// - Parameters:
    ///   - stored: the dwell the file holds.
    ///   - revision: the revision the file was written with.
    /// - Returns: the dwell to use. A file from before the revision that holds
    ///   the old default was never moved off it, so it moves to the new default;
    ///   anything else was chosen by hand and is kept, clamped into the range.
    public static func migrated(_ stored: Double, revision: Int) -> Double {
        guard revision < HUDDwell.revision else { return clamped(stored) }
        guard stored.isFinite else { return defaultSeconds }
        if abs(stored - legacyDefaultSeconds) < 0.001 {
            return defaultSeconds
        }
        return clamped(stored)
    }

    /// Whether the card is being read at `now`.
    ///
    /// - Parameters:
    ///   - pointerInside: whether the pointer is over the card.
    ///   - lastScroll: when the card was last scrolled, in any clock the caller
    ///     uses, or `nil` when it never was.
    ///   - now: the current time, in the same clock.
    /// - Returns: `true` while the pointer is over the card, and for
    ///   ``scrollGrace`` after the last scroll.
    public static func isInteracting(
        pointerInside: Bool,
        lastScroll: Double?,
        now: Double
    ) -> Bool {
        if pointerInside { return true }
        guard let lastScroll, lastScroll.isFinite, now.isFinite else { return false }
        let age = now - lastScroll
        return age >= 0 && age < scrollGrace
    }
}

/// Counts down the dwell of the card.
///
/// The clock is a value, and it consumes nothing while the card is being read:
/// a pause keeps what is left instead of restarting the countdown, so moving
/// the pointer across the card cannot buy the card a second life.
public struct HUDDwellClock: Equatable, Sendable {
    /// The whole dwell the clock counts down, in seconds.
    public private(set) var duration: Double
    /// How much of the dwell is left, in seconds.
    public private(set) var remaining: Double
    /// Whether the last advance found the card being read.
    public private(set) var isPaused: Bool
    /// The time of the last advance, in the caller's clock.
    ///
    /// A caller that moves the clock by hand — the headless test, because a
    /// starved run loop can withhold frames for longer than the whole dwell and
    /// then deliver one frame that carries all of it at once — needs to know
    /// where the clock stands. The frame loop reads the time from the system
    /// and does not need this.
    public private(set) var advancedAt: Double

    /// Creates a clock that has just started.
    ///
    /// - Parameters:
    ///   - duration: how long the card stays, in seconds.
    ///   - now: the current time.
    public init(duration: Double, now: Double) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.remaining = self.duration
        self.isPaused = false
        self.advancedAt = now.isFinite ? now : 0
    }

    /// Starts the countdown again.
    ///
    /// - Parameters:
    ///   - duration: a new dwell in seconds, or `nil` to keep the one the clock
    ///     was created with.
    ///   - now: the current time.
    public mutating func restart(duration: Double? = nil, now: Double) {
        if let duration {
            self.duration = duration.isFinite ? max(0, duration) : 0
        }
        remaining = self.duration
        isPaused = false
        if now.isFinite {
            advancedAt = now
        }
    }

    /// Consumes the time since the last advance, unless the card is being read.
    ///
    /// - Parameters:
    ///   - now: the current time, in the same clock as the previous advance.
    ///   - interacting: whether the pointer is over the card or it is being
    ///     scrolled.
    /// - Returns: whether the dwell has run out.
    @discardableResult
    public mutating func advance(to now: Double, interacting: Bool) -> Bool {
        isPaused = interacting
        // A time that is not a number is ignored rather than kept: keeping it
        // would make every later difference invalid, and the card would never
        // be dismissed again.
        guard now.isFinite else { return isExpired }
        let delta = now - advancedAt
        advancedAt = now
        guard !interacting, delta > 0 else { return isExpired }
        remaining = max(0, remaining - delta)
        return isExpired
    }

    /// Whether the dwell has run out.
    public var isExpired: Bool { remaining <= 0 }
}

/// Moves a configuration file to the dwell the card counts down now.
///
/// The migration runs once per file: the revision it writes is what tells a
/// later launch that the file was already read. It is separate from the load,
/// which stays a plain decode, so a value a user chose is never rewritten by
/// opening the app.
public enum HUDDwellMigration {
    /// Applies the migration to a configuration.
    ///
    /// - Parameter config: the configuration to correct.
    /// - Returns: whether the configuration changed and has to be written back.
    @discardableResult
    public static func apply(to config: inout DotConfig) -> Bool {
        guard config.hudDwellRevision < HUDDwell.revision else { return false }
        config.hudDwellSeconds = HUDDwell.migrated(
            config.hudDwellSeconds,
            revision: config.hudDwellRevision
        )
        config.hudDwellRevision = HUDDwell.revision
        return true
    }
}
