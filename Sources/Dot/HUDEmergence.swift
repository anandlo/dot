import CoreGraphics
import Foundation
import SwiftUI

/// The geometry of the card pouring out of the notch and back into it.
///
/// The island is the notch's own black, stretched down the screen, pinched off
/// through a liquid neck and settled as the card. Every value here is pure
/// geometry in one coordinate space: x in screen coordinates, and y measured
/// DOWN from the screen's top edge. That is why a rectangle's `minY` is its top
/// edge and its `maxY` its bottom edge, and why the notch is a rectangle at
/// y = 0.
///
/// One progress value drives all of it. ``shape(progress:source:rest:)`` turns
/// that progress into the card's rectangle, its corner radius, the bridge that
/// joins it to the notch and how much of the card's own surface has replaced
/// the black it poured out as. The sub-progresses inside it are what make the
/// motion read as a liquid rather than as a rectangle being resized: the height
/// leads, the width follows, and the drop trails them both, so the shape leaves
/// the notch as the notch and only becomes the card once it has fallen clear of
/// it.
enum HUDEmergence {
    // MARK: - The two ends

    /// The shape the card pours out of.
    ///
    /// On a display with a notch it is the notch itself: the gap between the two
    /// auxiliary top areas, `safeAreaInsets.top` deep, with a bottom corner
    /// radius of a quarter of its height. On a display without one it is the top
    /// edge of the screen, ``plainWidth`` wide and centred, with no height at
    /// all: the shape grows out of the edge instead of out of a hole in it.
    struct Source: Equatable {
        /// The notch, or the strip of the top edge a plain display grows from.
        var rect: CGRect
        /// The radius of the source's bottom corners.
        var cornerRadius: CGFloat

        /// The width of the source on a display without a notch.
        static let plainWidth: CGFloat = 185
    }

    /// The card where it comes to rest.
    struct Rest: Equatable {
        /// The card's rectangle.
        var rect: CGRect
        /// The card's corner radius.
        var cornerRadius: CGFloat
    }

    // MARK: - One frame

    /// The liquid bridge between the notch's bottom edge and the card's top.
    ///
    /// The neck is two quadratic sides and the two edges they join. Each side
    /// runs from a point on the notch's bottom edge, through a point on the
    /// waist, to a point on the card's top edge, so the sides are concave and
    /// the shape reads as poured rather than as drawn.
    struct Neck: Equatable {
        /// How wide the waist is, in points.
        var waistWidth: CGFloat
        /// The height of the waist, measured down from the screen's top edge.
        var waistY: CGFloat
        /// Where the left side leaves the notch's bottom edge.
        var topLeft: CGPoint
        /// Where the right side leaves the notch's bottom edge.
        var topRight: CGPoint
        /// Where the left side meets the card's top edge.
        var bottomLeft: CGPoint
        /// Where the right side meets the card's top edge.
        var bottomRight: CGPoint
        /// The waist's left end, which the left side passes through.
        var waistLeft: CGPoint
        /// The waist's right end, which the right side passes through.
        var waistRight: CGPoint
        /// The control point of the left side.
        var leftControl: CGPoint
        /// The control point of the right side.
        var rightControl: CGPoint
    }

    /// Everything one frame of the emergence draws.
    struct Shape: Equatable {
        /// The card's rectangle. Its `minY` is the top edge.
        var card: CGRect
        /// The card's corner radius, held inside the shape's own size.
        var cornerRadius: CGFloat
        /// The bridge to the notch, or `nil` when the card has fallen clear of
        /// it, is still touching it, or is not yet narrow enough to pinch.
        var neck: Neck?
        /// How much of the card's own surface has replaced the black: `0` is the
        /// notch's own black, `1` is the card's material.
        var mix: Double

        /// Whether the shape is the resting card and nothing else.
        ///
        /// - Parameter rest: the card at rest.
        /// - Returns: `true` when the card is at its rest rectangle with its
        ///   rest radius and no bridge to the notch.
        func isRest(_ rest: Rest) -> Bool {
            neck == nil
                && abs(card.minX - rest.rect.minX) < 0.001
                && abs(card.minY - rest.rect.minY) < 0.001
                && abs(card.width - rest.rect.width) < 0.001
                && abs(card.height - rest.rect.height) < 0.001
                && abs(cornerRadius - rest.cornerRadius) < 0.001
        }
    }

    /// The three sub-progresses the card's rectangle is drawn from.
    struct Steps: Equatable {
        /// How far the shape has stretched down, from `0` to `1`.
        var height: Double
        /// How far it has widened from the notch to the card, from `0` to `1`.
        var width: Double
        /// How far it has fallen away from the notch, from `0` to `1`.
        var drop: Double
    }

    // MARK: - The screen

    /// The near geometry of one display.
    ///
    /// It mirrors the four values of `NSScreen` the emergence reads, so a test
    /// can describe a display that exists only for it.
    struct Screen: Equatable {
        /// The display's frame, in screen coordinates (y up).
        var frame: CGRect
        /// The display's usable frame, in screen coordinates (y up).
        var visibleFrame: CGRect
        /// `NSScreen.safeAreaInsets.top`.
        var safeTop: CGFloat
        /// `NSScreen.auxiliaryTopLeftArea`, in screen coordinates.
        var leftArea: CGRect?
        /// `NSScreen.auxiliaryTopRightArea`, in screen coordinates.
        var rightArea: CGRect?
    }

    /// The panel and the notch of one display.
    struct Placement: Equatable {
        /// The panel's frame, in screen coordinates.
        var panelFrame: CGRect
        /// The distance from the panel's top edge to the top of the card at rest.
        var cardTopInset: CGFloat
        /// The display the panel was placed on.
        var screen: Screen
        /// The notch, in the display's coordinates (y down from its top edge).
        var source: Source

        /// Where the shape is drawn, in the panel's own coordinates.
        var scene: Scene {
            var source = self.source
            source.rect = source.rect.offsetBy(dx: -panelFrame.minX, dy: 0)
            return Scene(
                source: source,
                panelWidth: panelFrame.width,
                cardTopInset: cardTopInset
            )
        }
    }

    /// Where a card draws its emergence inside the panel.
    ///
    /// The source is given in the panel's coordinates, where y is measured down
    /// from the panel's top edge, which is the screen's. The card is centred in
    /// the panel and hangs ``cardTopInset`` below its top edge, so the source's
    /// place in the card's own coordinates is found from the card's size.
    struct Scene: Equatable {
        /// The notch, in the panel's coordinates.
        var source: Source
        /// The width of the panel the card is centred in.
        var panelWidth: CGFloat
        /// The distance from the panel's top edge to the top of the card at rest.
        var cardTopInset: CGFloat

        /// The notch in the coordinates of a card of `size`.
        ///
        /// - Parameter size: the card's size, in points.
        /// - Returns: the source with its origin moved into the card's space.
        func source(inCardOf size: CGSize) -> Source {
            var source = self.source
            let left = (panelWidth - size.width) / 2
            source.rect = source.rect.offsetBy(dx: -left, dy: -cardTopInset)
            return source
        }
    }

    // MARK: - Reading

    /// The panel, its card inset and the notch of one display.
    ///
    /// - Parameters:
    ///   - screen: the display.
    ///   - panelSize: the fixed size of the panel.
    ///   - topInset: how far below the top of the usable screen the card's own
    ///     panel used to sit.
    ///   - shadowPadding: the room the card keeps above it for its shadow.
    /// - Returns: the placement, in screen coordinates.
    static func placement(
        screen: Screen,
        panelSize: CGSize,
        topInset: CGFloat,
        shadowPadding: CGFloat
    ) -> Placement {
        Placement(
            panelFrame: HUDPlacement.emergenceFrame(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                panelSize: panelSize,
                topInset: topInset
            ),
            cardTopInset: HUDPlacement.emergenceCardTopInset(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                topInset: topInset,
                shadowPadding: shadowPadding
            ),
            screen: screen,
            source: source(
                screenFrame: screen.frame,
                safeTop: screen.safeTop,
                leftArea: screen.leftArea,
                rightArea: screen.rightArea
            )
        )
    }

    /// The shape the card pours out of.
    ///
    /// - Parameters:
    ///   - screenFrame: the display's frame, in screen coordinates.
    ///   - safeTop: `NSScreen.safeAreaInsets.top`.
    ///   - leftArea: `NSScreen.auxiliaryTopLeftArea`.
    ///   - rightArea: `NSScreen.auxiliaryTopRightArea`.
    /// - Returns: the notch's rectangle, in screen x and y measured down from
    ///   the top edge of the screen.
    static func source(
        screenFrame: CGRect,
        safeTop: CGFloat,
        leftArea: CGRect?,
        rightArea: CGRect?
    ) -> Source {
        let frame = screenFrame.standardized
        let depth = safeTop.isFinite ? max(0, safeTop) : 0
        if let leftArea, let rightArea, depth > 0 {
            let left = max(leftArea.minX, leftArea.maxX)
            let right = min(rightArea.minX, rightArea.maxX)
            if right - left > 0.5, right.isFinite, left.isFinite {
                return Source(
                    rect: CGRect(x: left, y: 0, width: right - left, height: depth),
                    cornerRadius: 0.25 * depth
                )
            }
        }
        let width = Source.plainWidth
        let midX = frame.midX.isFinite ? frame.midX : 0
        return Source(
            rect: CGRect(x: midX - width / 2, y: 0, width: width, height: 0),
            cornerRadius: 0
        )
    }

    // MARK: - The shape

    /// The progress the shape is drawn at.
    ///
    /// Reduced motion keeps the card where it rests: the appearance is then a
    /// crossfade of the card that is already in its place, and no shape ever
    /// moves.
    ///
    /// - Parameters:
    ///   - presence: the value of the emergence's spring.
    ///   - reduceMotion: whether the system asked for reduced motion.
    /// - Returns: `1` when motion is reduced, the presence otherwise.
    static func progress(_ presence: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1 }
        return presence.isFinite ? presence : 1
    }

    /// The three sub-progresses of one progress value.
    ///
    /// - Parameter progress: the emergence's progress. Values above `1` are the
    ///   spring's overshoot and are only carried by the drop, which is clamped.
    /// - Returns: the height, width and drop, each from `0` to `1`.
    static func steps(progress: Double) -> Steps {
        Steps(
            height: easeOut(progress / 0.70),
            width: easeInOut((progress - 0.12) / 0.78),
            drop: easeOut((progress - 0.35) / 0.65)
        )
    }

    /// One frame of the emergence.
    ///
    /// The card's width, its height and its distance from the top of the screen
    /// each follow their own sub-progress, so the shape leaves the notch as the
    /// notch, stretches, and only then falls away from it. The corner radius is
    /// held inside the shape it is drawing, and an overshoot of the spring is
    /// spent on the card's own height, at its bottom edge, so the settle reads
    /// as liquid without the card ever passing its rest position.
    ///
    /// - Parameters:
    ///   - progress: the emergence's progress, from `0` to `1` and past it while
    ///     the spring overshoots.
    ///   - source: the notch, in the same coordinates as `rest`.
    ///   - rest: the card at rest, in the same coordinates.
    /// - Returns: the card, its radius, the bridge to the notch and the mix.
    static func shape(progress: Double, source: Source, rest: Rest) -> Shape {
        let step = steps(progress: progress)
        let height = lerp(source.rect.height, rest.rect.height, step.height)
            + min(3, 25 * max(0, progress - 1))
        let width = lerp(source.rect.width, rest.rect.width, step.width)
        let centreX = lerp(source.rect.midX, rest.rect.midX, step.width)
        let top = lerp(source.rect.minY, rest.rect.minY, step.drop)
        let card = CGRect(x: centreX - width / 2, y: top, width: width, height: height)
        let radius = min(
            lerp(source.cornerRadius, rest.cornerRadius, step.width),
            max(0, height) / 2,
            max(0, width) / 2
        )
        return Shape(
            card: card,
            cornerRadius: radius,
            neck: neck(source: source, rest: rest, card: card, radius: radius),
            mix: mix(drop: step.drop)
        )
    }

    /// The bridge between the notch and the card, when one is drawn.
    ///
    /// The neck exists only while the card's top edge is below the notch's
    /// bottom edge, and it is pinched off before the card reaches its rest
    /// distance: its waist narrows from just over half the notch's width to
    /// nothing as the gap closes on the distance the card rests at. Below half a
    /// point of waist there is no bridge, which is where the shape has been
    /// pinched off rather than merely become thin.
    ///
    /// - Parameters:
    ///   - source: the notch.
    ///   - rest: the card at rest.
    ///   - card: the card at this moment.
    ///   - radius: the card's corner radius.
    /// - Returns: the bridge, or `nil` when none is drawn.
    private static func neck(
        source: Source,
        rest: Rest,
        card: CGRect,
        radius: CGFloat
    ) -> Neck? {
        let gap = card.minY - source.rect.maxY
        let restGap = rest.rect.minY - source.rect.maxY
        guard gap > 0.5, restGap > 0 else { return nil }
        let waistWidth = 0.55 * source.rect.width
            * (1 - smoothstep(0.45 * restGap, 0.85 * restGap, gap))
        guard waistWidth >= 0.5 else { return nil }

        let topLeftX = source.rect.minX + source.cornerRadius
        let topRightX = source.rect.maxX - source.cornerRadius
        let bottomLeftX = max(card.minX + radius, source.rect.minX)
        let bottomRightX = min(card.maxX - radius, source.rect.maxX)
        guard topRightX - topLeftX > 0.5, bottomRightX - bottomLeftX > 0.5 else { return nil }

        let waistY = source.rect.maxY + gap / 2
        let waistLeft = CGPoint(x: source.rect.midX - waistWidth / 2, y: waistY)
        let waistRight = CGPoint(x: source.rect.midX + waistWidth / 2, y: waistY)
        let topLeft = CGPoint(x: topLeftX, y: source.rect.maxY)
        let topRight = CGPoint(x: topRightX, y: source.rect.maxY)
        let bottomLeft = CGPoint(x: bottomLeftX, y: card.minY)
        let bottomRight = CGPoint(x: bottomRightX, y: card.minY)
        return Neck(
            waistWidth: waistWidth,
            waistY: waistY,
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight,
            waistLeft: waistLeft,
            waistRight: waistRight,
            leftControl: controlPoint(from: topLeft, through: waistLeft, to: bottomLeft),
            rightControl: controlPoint(from: topRight, through: waistRight, to: bottomRight)
        )
    }

    /// The control point of a quadratic curve that passes through `waist` at its
    /// halfway point.
    ///
    /// - Parameters:
    ///   - start: where the curve begins.
    ///   - waist: the point the curve has to pass through.
    ///   - end: where the curve ends.
    /// - Returns: the control point.
    private static func controlPoint(from start: CGPoint, through waist: CGPoint, to end: CGPoint) -> CGPoint {
        CGPoint(
            x: 2 * waist.x - (start.x + end.x) / 2,
            y: 2 * waist.y - (start.y + end.y) / 2
        )
    }

    /// The outline of one frame: the card, and the bridge when there is one.
    ///
    /// Both pieces are subpaths of one path, so the black that pours out of the
    /// notch and the black of the card are one fill with one edge.
    ///
    /// - Parameter shape: the frame.
    /// - Returns: the path, in the same coordinates as the frame's rectangles.
    static func path(_ shape: Shape) -> Path {
        var path = Path(roundedRect: shape.card, cornerRadius: shape.cornerRadius)
        guard let neck = shape.neck else { return path }
        var bridge = Path()
        bridge.move(to: neck.topRight)
        bridge.addQuadCurve(to: neck.bottomRight, control: neck.rightControl)
        bridge.addLine(to: neck.bottomLeft)
        bridge.addQuadCurve(to: neck.topLeft, control: neck.leftControl)
        bridge.closeSubpath()
        path.addPath(bridge)
        return path
    }

    // MARK: - The surface and the content

    /// How much of the card's own surface is drawn over the black.
    ///
    /// The black is the notch's own colour, so the card cannot crossfade from a
    /// second colour: it keeps drawing the shape until it is close to where it
    /// rests, and only then lets the material take over. The crossfade is
    /// smoothstepped so its start and its end have no edge.
    ///
    /// - Parameter drop: the drop's sub-progress.
    /// - Returns: the opacity of the card's surface, from `0` to `1`.
    static func mix(drop: Double) -> Double {
        smoothstep(0.70, 0.95, drop)
    }

    /// The opacity of the card's content.
    ///
    /// The content belongs to the card, not to the shape: while the black is
    /// still pouring out of the notch there is nothing on it to read, so the
    /// words wait until the shape has all but arrived.
    ///
    /// - Parameters:
    ///   - content: how settled the content is, as the card's own spring says.
    ///   - progress: the emergence's progress.
    /// - Returns: the content's opacity, from `0` to `1`.
    static func contentOpacity(content: Double, progress: Double) -> Double {
        guard content.isFinite, progress.isFinite else { return 0 }
        return min(max(content, 0), 1) * smoothstep(0.85, 1.0, progress)
    }

    // MARK: - Curves

    /// The ease-out cubic, `1 - (1 - x)^3`.
    ///
    /// - Parameter x: the input, clamped to `0...1`.
    /// - Returns: the eased value.
    static func easeOut(_ x: Double) -> Double {
        let clamped = min(max(x, 0), 1)
        let inverse = 1 - clamped
        return 1 - inverse * inverse * inverse
    }

    /// The ease-in-out cubic: slow, fast and slow again.
    ///
    /// - Parameter x: the input, clamped to `0...1`.
    /// - Returns: the eased value.
    static func easeInOut(_ x: Double) -> Double {
        let clamped = min(max(x, 0), 1)
        if clamped < 0.5 {
            return 4 * clamped * clamped * clamped
        }
        let inverse = 1 - clamped
        return 1 - 4 * inverse * inverse * inverse
    }

    /// The cubic smoothstep between two edges.
    ///
    /// - Parameters:
    ///   - edge0: where the ramp starts.
    ///   - edge1: where it ends.
    ///   - x: the input.
    /// - Returns: `0` below `edge0`, `1` above `edge1`, and a curve with no edge
    ///   at either end between them.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The linear interpolation between two values.
    ///
    /// - Parameters:
    ///   - start: the value at `0`.
    ///   - end: the value at `1`.
    ///   - amount: how far to go, clamped to `0...1`.
    /// - Returns: the interpolated value.
    static func lerp(_ start: CGFloat, _ end: CGFloat, _ amount: Double) -> CGFloat {
        let t = min(max(amount, 0), 1)
        if t == 0 { return start }
        if t == 1 { return end }
        return start + (end - start) * CGFloat(t)
    }
}

/// A straight crossfade of the card, used when motion is reduced.
///
/// The system's Reduce Motion setting asks for the card to arrive without
/// anything moving, so what is left is its opacity: a linear ramp that reaches
/// its target in ``duration`` and stops there, rather than a spring that only
/// approaches it. A spring is the wrong shape for this answer, because the
/// question is how long the appearance takes, and a spring has no end.
struct HUDCrossfade {
    /// The value now, from `0` to `1`.
    private(set) var value: Double
    /// The value the crossfade is heading for.
    private(set) var target: Double
    /// How long a whole change takes, in seconds.
    let duration: Double

    /// Creates a crossfade.
    ///
    /// - Parameters:
    ///   - value: the starting value.
    ///   - duration: how long a whole change takes, in seconds.
    init(value: Double = 0, duration: Double = 0.15) {
        self.value = value
        self.target = value
        self.duration = max(0.0001, duration)
    }

    /// Heads for a value.
    ///
    /// - Parameter target: where the crossfade should end.
    mutating func to(_ target: Double) {
        self.target = target
    }

    /// Sets the value outright.
    ///
    /// - Parameter value: the value to take.
    mutating func snap(to value: Double) {
        self.value = value
        self.target = value
    }

    /// Whether the crossfade has reached its target.
    var isResting: Bool {
        value == target
    }

    /// Advances the crossfade by `dt` seconds.
    ///
    /// - Parameter dt: the time that passed, in seconds.
    mutating func advance(_ dt: Double) {
        guard dt > 0 else { return }
        let step = dt / duration
        if value < target {
            value = min(target, value + step)
        } else if value > target {
            value = max(target, value - step)
        }
    }
}
