import CoreGraphics
import Foundation

/// Recognises a deliberate horizontal trackpad swipe.
///
/// The island never gets a `swipeWithEvent:` of its own: the panel is not key,
/// and a two-finger swipe over the text arrives as a precise scroll. This type
/// turns those deltas into at most one direction per gesture, ignores a scroll
/// that is mostly vertical (so reading a long transcript is never stolen), and
/// stops at the first trigger so momentum after the fingers lift cannot page
/// through every version.
///
/// The deltas it is fed are *finger* deltas: positive when the fingers move
/// right, negative when they move left, whatever the system's natural-scrolling
/// preference does to the raw event.
/// ``fingerDeltas(rawHorizontal:rawVertical:directionInverted:)`` is the one
/// place an event's `scrollingDeltaX` and `scrollingDeltaY` become them.
public struct RewriteSwipeGesture: Equatable, Sendable {
    /// Which way the person asked to move through the versions.
    public enum Direction: Equatable, Sendable {
        /// The version before the current one.
        case previous
        /// The version after the current one.
        case next
    }

    /// How far the fingers must travel sideways, in points, before it is a swipe.
    public static let threshold: CGFloat = 42
    /// How much more vertical than horizontal a scroll may be before it is a
    /// vertical scroll rather than a swipe.
    public static let verticalRatio: CGFloat = 1.15
    /// The movement below which the axis is not decided yet, in points.
    public static let axisSlop: CGFloat = 6

    public private(set) var horizontal: CGFloat = 0
    public private(set) var vertical: CGFloat = 0
    public private(set) var isTracking = false
    public private(set) var hasTriggered = false
    private var isVertical = false

    public init() {}

    /// Starts a gesture, or restarts one that was left open.
    public mutating func begin() {
        horizontal = 0
        vertical = 0
        isTracking = true
        hasTriggered = false
        isVertical = false
    }

    /// The finger deltas behind one scroll event.
    ///
    /// `NSEvent` inverts `scrollingDeltaX` and `scrollingDeltaY` according to
    /// the person's scrolling preference — "deltaX/Y and scrollingDeltaX/Y are
    /// automatically inverted … according to the user's preferences" — and
    /// reports that it did so in `isDirectionInvertedFromDevice`, so a reader
    /// that means the fingers rather than the content undoes it with `-1`.
    ///
    /// The flip is applied to both axes. The direction is decided by the sign
    /// of the sideways travel, and a vertical scroll has to stay vertical
    /// whichever way the system reported the two axes, so an event is
    /// normalised once, here, and the classifier sees one convention on every
    /// Mac.
    ///
    /// - Parameters:
    ///   - rawHorizontal: the event's `scrollingDeltaX`.
    ///   - rawVertical: the event's `scrollingDeltaY`.
    ///   - directionInverted: the event's `isDirectionInvertedFromDevice`.
    /// - Returns: the same travel in finger deltas: sideways positive to the
    ///   right, which is what ``add(horizontal:vertical:)`` expects.
    public static func fingerDeltas(
        rawHorizontal: CGFloat,
        rawVertical: CGFloat,
        directionInverted: Bool
    ) -> (horizontal: CGFloat, vertical: CGFloat) {
        let sign: CGFloat = directionInverted ? -1 : 1
        return (horizontal: rawHorizontal * sign, vertical: rawVertical * sign)
    }

    /// Adds one event's finger deltas.
    ///
    /// - Parameters:
    ///   - horizontal: the sideways movement, positive to the right.
    ///   - vertical: the up-and-down movement, positive downward.
    /// - Returns: the direction when this event crossed the threshold, else
    ///   `nil`. A gesture returns a direction at most once.
    public mutating func add(horizontal deltaX: CGFloat, vertical deltaY: CGFloat) -> Direction? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }
        if !isTracking {
            // A gesture that already resolved or was cancelled stays closed
            // until the next `begin()`; a device that sends no phase can still
            // start one from rest.
            guard horizontal == 0, vertical == 0, !hasTriggered, !isVertical else {
                return nil
            }
            begin()
        }
        guard !hasTriggered, !isVertical else { return nil }
        horizontal += deltaX
        vertical += deltaY

        if abs(vertical) > Self.axisSlop,
           abs(vertical) > abs(horizontal) * Self.verticalRatio {
            isVertical = true
            isTracking = false
            return nil
        }
        guard abs(horizontal) >= Self.threshold else { return nil }
        hasTriggered = true
        isTracking = false
        return horizontal < 0 ? .next : .previous
    }

    /// Ends the gesture, accepting a single large event that never repeated.
    ///
    /// - Returns: the direction when the accumulated travel crossed the
    ///   threshold, else `nil`.
    public mutating func end() -> Direction? {
        defer {
            isTracking = false
        }
        guard !hasTriggered, !isVertical, abs(horizontal) >= Self.threshold else {
            return nil
        }
        hasTriggered = true
        return horizontal < 0 ? .next : .previous
    }

    /// Drops the gesture without a direction.
    public mutating func cancel() {
        horizontal = 0
        vertical = 0
        isTracking = false
        hasTriggered = false
        isVertical = false
    }
}

/// The brief directional transition between two versions.
///
/// The values are here rather than in the view so the direction and the
/// reduced-motion rule can be checked without a window. The view uses the same
/// 180 ms ease-out as the chip row's own scroll.
public enum RewriteVersionMotion {
    /// How long the transition takes, in seconds.
    public static let duration: Double = 0.18
    /// How far the incoming version starts from its final place, in points.
    public static let distance: CGFloat = 10

    /// Where the incoming version starts.
    ///
    /// - Parameters:
    ///   - direction: which way the selection moved.
    ///   - reduceMotion: whether the person asked for reduced motion.
    /// - Returns: `0` for reduced motion, otherwise a small offset in the
    ///   direction of travel.
    public static func insertionOffset(
        direction: RewriteCard.Navigation?,
        reduceMotion: Bool
    ) -> CGFloat {
        guard !reduceMotion else { return 0 }
        switch direction {
        case .next: return distance
        case .previous: return -distance
        case nil: return 0
        }
    }

    /// Whether the view should slide at all.
    public static func slides(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}
