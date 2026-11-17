import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

/// The bounded motion polish: the shared press, the streaming status, and the
/// frames that prove both.
///
/// The card is drawn through the same native path the app uses: an
/// `NSHostingView` in an ``OffscreenWindow`` parked off every display, cached
/// into a 2x bitmap. A browser cannot inspect AppKit, so the evidence here is
/// pixels, written to ``evidence`` for a reviewer to open beside the assertions
/// that measured them.
@MainActor
final class HUDMotionPolishTests: XCTestCase {
    /// The app's typeface, registered before the first view is built.
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// Where every fixture is written, at two pixels per point.
    ///
    /// A run gets its own directory under the system's temporary one, so two
    /// runs never overwrite each other's evidence. A reviewer can point
    /// `DOT_HUD_FRAMES_DIR` at a directory to keep the frames somewhere they
    /// will look; the path the run used is printed by ``setUp()``.
    static let evidence: URL = {
        if let override = ProcessInfo.processInfo.environment["DOT_HUD_FRAMES_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-hud-frames-\(UUID().uuidString)", isDirectory: true)
    }()
    /// The pixels per point of every render.
    static let scale = 2
    /// The colours the card is drawn in, at 8 bits per channel.
    private static let live = (red: 0.961, green: 0.725, blue: 0.267)
    /// A rendered card: the bitmap, the size it was drawn at and the file.
    private struct Rendered {
        let bitmap: NSBitmapImageRep
        let size: CGSize
        let url: URL
    }

    // MARK: - The shared press

    func testAPressShrinksAnEnabledControlToNinetyEightPercent() {
        XCTAssertEqual(DotPressFeedback.pressedScale, 0.98)
        XCTAssertEqual(
            DotPressFeedback.scale(isPressed: true, isEnabled: true, reduceMotion: false),
            0.98
        )
        XCTAssertEqual(
            DotPressFeedback.opacity(isPressed: true, isEnabled: true, reduceMotion: false),
            1,
            "the scale carries the press; the fill keeps its colour"
        )
    }

    func testAReleaseOrADisabledControlDoesNotMove() {
        XCTAssertEqual(
            DotPressFeedback.scale(isPressed: false, isEnabled: true, reduceMotion: false),
            1
        )
        XCTAssertEqual(
            DotPressFeedback.scale(isPressed: true, isEnabled: false, reduceMotion: false),
            1,
            "a control that cannot act has nothing to answer"
        )
        XCTAssertEqual(
            DotPressFeedback.opacity(isPressed: true, isEnabled: false, reduceMotion: true),
            1
        )
    }

    func testReducedMotionKeepsThePressColourAndDropsTheMovement() {
        XCTAssertEqual(
            DotPressFeedback.scale(isPressed: true, isEnabled: true, reduceMotion: true),
            1,
            "no spatial movement at all"
        )
        XCTAssertEqual(
            DotPressFeedback.opacity(isPressed: true, isEnabled: true, reduceMotion: true),
            DotPressFeedback.pressedOpacity
        )
        XCTAssertLessThan(DotPressFeedback.pressedOpacity, 1)
    }

    func testThePressRunsOnTheStrongEaseOutForOneHundredAndTwentyMilliseconds() {
        XCTAssertEqual(DotPressFeedback.duration, 0.12)
        XCTAssertEqual(DotPressFeedback.curvePoints.x1, 0.23)
        XCTAssertEqual(DotPressFeedback.curvePoints.y1, 1.0)
        XCTAssertEqual(DotPressFeedback.curvePoints.x2, 0.32)
        XCTAssertEqual(DotPressFeedback.curvePoints.y2, 1.0)
        XCTAssertNotNil(DotPressFeedback.animation(reduceMotion: false))
        XCTAssertNil(
            DotPressFeedback.animation(reduceMotion: true),
            "nothing may animate when the motion is reduced"
        )
    }

    // MARK: - The arc

    /// The head travels at one constant rate, one turn every 1.9 seconds.
    ///
    /// The travel is linear on purpose: an eased arc makes the work look like it
    /// started fast and gave up, and at this size the head is the only thing that
    /// says the request is still moving. A whole period returns the same angle,
    /// which is what lets the header's ring and the chip's arc be one movement
    /// drawn twice.
    func testTheArcHeadTravelsLinearlyOnAOnePointNineSecondPeriod() {
        XCTAssertEqual(HUDRewriteActivity.arcPeriod, 1.9)
        XCTAssertEqual(HUDRewriteActivity.arcTrailDegrees, 120)
        for time in [0.0, 0.15, 0.5, 0.95, 1.4, 1.89] {
            XCTAssertEqual(
                HUDRewriteActivity.arcHeadAngle(time: time, reduceMotion: false),
                360 * time / HUDRewriteActivity.arcPeriod,
                accuracy: 1e-9,
                "the head is not at \(time) s of the turn"
            )
        }
        // Linear means evenly spaced: half a period is half a turn, and a quarter
        // is a quarter, so no easing hides in the function.
        XCTAssertEqual(
            HUDRewriteActivity.arcHeadAngle(time: 0.95, reduceMotion: false),
            180,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            HUDRewriteActivity.arcHeadAngle(time: 0.475, reduceMotion: false),
            90,
            accuracy: 1e-9
        )
        for time in [0.0, 0.3, 0.95, 1.42, 2.7] {
            XCTAssertEqual(
                HUDRewriteActivity.arcHeadAngle(time: time + 1.9, reduceMotion: false),
                HUDRewriteActivity.arcHeadAngle(time: time, reduceMotion: false),
                accuracy: 1e-9,
                "one period did not return the head to where it was at \(time) s"
            )
        }
        // The turn is folded into one turn, so nothing can ask for an angle the
        // gradient cannot place.
        for time in stride(from: 0.0, through: 12.0, by: 0.07) {
            let angle = HUDRewriteActivity.arcHeadAngle(time: time, reduceMotion: false)
            XCTAssertGreaterThanOrEqual(angle, 0)
            XCTAssertLessThan(angle, 360)
        }
        XCTAssertEqual(HUDRewriteActivity.arcHeadAngle(time: 0, reduceMotion: false), 0, accuracy: 1e-12)
        XCTAssertEqual(HUDRewriteActivity.arcHeadAngle(time: -0.475, reduceMotion: false), 270, accuracy: 1e-9)
    }

    /// Reduced motion parks the arc on the top-right quarter and reads nothing.
    ///
    /// The parked arc is 90 degrees centred on the top of the shape, so the head
    /// sits at its top-right end. Every reading of the clock returns the same
    /// angle, including a clock that is not a number: a frozen arc that drifted
    /// with the clock would be a slow animation, which is the one thing reduced
    /// motion may not have.
    func testReducedMotionParksTheArcAndNeverReadsTheClock() {
        XCTAssertEqual(HUDRewriteActivity.reducedMotionHeadDegrees, 45)
        XCTAssertEqual(HUDRewriteActivity.reducedMotionTrailDegrees, 90)
        XCTAssertEqual(HUDRewriteActivity.arcTrail(reduceMotion: true), 90)
        XCTAssertEqual(HUDRewriteActivity.arcTrail(reduceMotion: false), 120)
        // A quarter of the rim, centred on the top: 45 degrees before it and 45
        // after it, with the head at the end the trail leads to.
        XCTAssertEqual(
            HUDRewriteActivity.arcHeadAngle(time: 0, reduceMotion: true) - 45,
            HUDRewriteActivity.reducedMotionHeadDegrees
                - HUDRewriteActivity.reducedMotionTrailDegrees / 2,
            accuracy: 1e-12
        )
        for time in [0.0, 0.4, 0.95, 3.8, 12.6, -2.1, .nan, .infinity] {
            XCTAssertEqual(
                HUDRewriteActivity.arcHeadAngle(time: time, reduceMotion: true),
                45,
                accuracy: 1e-12,
                "reduced motion moved the arc at t = \(time) s"
            )
        }
        // A clock that is not a number is parked rather than placed at infinity.
        XCTAssertEqual(HUDRewriteActivity.arcHeadAngle(time: .nan, reduceMotion: false), 45)
        XCTAssertEqual(HUDRewriteActivity.arcHeadAngle(time: .infinity, reduceMotion: false), 45)
    }

    /// One angle lands on the capsule's outline, for every shape the card draws.
    ///
    /// The four cardinal directions are exact, and a tall capsule — a chip is 26
    /// points of label plus 20 of padding and 24 tall, so both proportions exist —
    /// is walked the whole way round and every point is held to the outline it
    /// claims: on the flat within the flat's span, and on its own cap circle past
    /// it.
    func testTheRimPointLandsOnTheCapsuleOutline() {
        let cases: [(CGSize, [Double: CGPoint])] = [
            (
                CGSize(width: 80, height: 26),
                [
                    0: CGPoint(x: 40, y: 0),
                    90: CGPoint(x: 80, y: 13),
                    180: CGPoint(x: 40, y: 26),
                    270: CGPoint(x: 0, y: 13),
                ]
            ),
            (
                CGSize(width: 26, height: 80),
                [
                    0: CGPoint(x: 13, y: 0),
                    90: CGPoint(x: 26, y: 40),
                    180: CGPoint(x: 13, y: 80),
                    270: CGPoint(x: 0, y: 40),
                ]
            ),
        ]
        for (size, expected) in cases {
            for (angle, point) in expected {
                let landed = HUDRewriteActivity.capsuleRimPoint(angleDegrees: angle, size: size)
                XCTAssertEqual(landed.x, point.x, accuracy: 1e-6, "x at \(angle) deg")
                XCTAssertEqual(landed.y, point.y, accuracy: 1e-6, "y at \(angle) deg")
            }
        }

        let tall = CGSize(width: 26, height: 80)
        let radius = min(tall.width, tall.height) / 2
        for step in 0 ..< 360 {
            let angle = Double(step)
            let point = HUDRewriteActivity.capsuleRimPoint(angleDegrees: angle, size: tall)
            XCTAssertGreaterThanOrEqual(point.x, -1e-6, "the point left the capsule at \(angle) deg")
            XCTAssertLessThanOrEqual(point.x, tall.width + 1e-6, "the point left the capsule at \(angle) deg")
            XCTAssertGreaterThanOrEqual(point.y, -1e-6, "the point left the capsule at \(angle) deg")
            XCTAssertLessThanOrEqual(point.y, tall.height + 1e-6, "the point left the capsule at \(angle) deg")
            // A tall capsule is two half-circles of radius 13 joined by two flat
            // sides, so a point is on the rim when it is on a flat — and then it
            // is inside the cap's span — or exactly the radius from the cap it
            // belongs to.
            let onFlat = abs(point.x) < 1e-6 || abs(point.x - tall.width) < 1e-6
            if onFlat {
                XCTAssertGreaterThanOrEqual(
                    point.y,
                    radius - 1e-6,
                    "the flat runs past its cap at \(angle) deg"
                )
                XCTAssertLessThanOrEqual(
                    point.y,
                    tall.height - radius + 1e-6,
                    "the flat runs past its cap at \(angle) deg"
                )
            } else {
                let capCentre = CGPoint(
                    x: tall.width / 2,
                    y: point.y < tall.height / 2 ? radius : tall.height - radius
                )
                XCTAssertEqual(
                    hypot(point.x - capCentre.x, point.y - capCentre.y),
                    radius,
                    accuracy: 1e-6,
                    "the point is not on the rim at \(angle) deg"
                )
            }
        }
        // A capsule with no room for a flat is a circle, and the centre is what
        // every ray is cast from.
        let square = CGSize(width: 24, height: 24)
        for step in stride(from: 0, to: 360, by: 10) {
            let point = HUDRewriteActivity.capsuleRimPoint(
                angleDegrees: Double(step),
                size: square
            )
            XCTAssertEqual(hypot(point.x - 12, point.y - 12), 12, accuracy: 1e-6)
        }
        // A size the card cannot have is not a place to divide by zero.
        XCTAssertEqual(
            HUDRewriteActivity.capsuleRimPoint(angleDegrees: 90, size: .zero),
            .zero
        )
    }

    /// The falloff runs from the head to nothing over the trail, and stops there.
    ///
    /// The stops are read the way the gradient reads them: a piecewise-linear
    /// sweep of the rim. Behind the head the amber falls linearly to nothing over
    /// the trail; ahead of the head, and past the tail, there is no ink at all —
    /// which is what stops the stroke ending in a cut tick at the head.
    func testTheGradientFallsFromTheHeadToNothingOverTheTrail() {
        /// The opacity the gradient draws at one angle of the card's own space.
        func opacity(at angle: Double, in stops: [HUDRewriteActivity.ArcStop]) -> Double {
            // The gradient measures from three o'clock; the card from the top.
            let turns = (angle - 90) / 360
            let location = turns - turns.rounded(.down)
            guard let first = stops.first, let last = stops.last else { return 0 }
            if location <= first.location { return first.opacity }
            if location >= last.location { return last.opacity }
            for (lower, upper) in zip(stops, stops.dropFirst())
            where location >= lower.location && location <= upper.location {
                let span = upper.location - lower.location
                guard span > 0 else { return upper.opacity }
                let fraction = (location - lower.location) / span
                return lower.opacity + (upper.opacity - lower.opacity) * fraction
            }
            return 0
        }

        for head in [0.0, 90, 200, 275] {
            let stops = HUDRewriteActivity.arcStops(head: head, trail: 120)
            XCTAssertEqual(stops.first?.location, 0, "the sweep does not start at zero")
            XCTAssertEqual(stops.last?.location, 1, "the sweep does not end at the whole turn")
            XCTAssertEqual(
                stops.map(\.location),
                stops.map(\.location).sorted(),
                "the stops are not in the order a gradient reads them"
            )
            // The head is full amber and the tail is nothing: the falloff is
            // linear in the angle behind the head, and ahead of it there is no
            // ink at all.
            XCTAssertEqual(opacity(at: head, in: stops), 1, accuracy: 0.01, "the head is not full amber")
            XCTAssertEqual(
                opacity(at: head - 60, in: stops),
                0.5,
                accuracy: 0.02,
                "the trail is not half spent 60 degrees behind the head"
            )
            XCTAssertEqual(
                opacity(at: head - 119, in: stops),
                1.0 / 120,
                accuracy: 0.02,
                "the trail does not fall linearly"
            )
            XCTAssertEqual(
                opacity(at: head - 121, in: stops),
                0,
                accuracy: 0.001,
                "the trail reaches past 120 degrees behind the head"
            )
            XCTAssertEqual(
                opacity(at: head + 60, in: stops),
                0,
                accuracy: 0.001,
                "the rim ahead of the head carries ink"
            )
            // One head and one head only: the sweep wraps, so the head is the
            // same point at zero and at a whole turn, and nowhere else is full.
            var full: [Double] = []
            for angle in stride(from: 0.0, to: 360.0, by: 1) where opacity(at: angle, in: stops) > 0.999 {
                full.append(angle)
            }
            XCTAssertEqual(full.count, 1, "the arc has more than one head at \(head) deg: \(full)")
            // Every angle is covered: the gradient has no gap it would draw black.
            for angle in stride(from: 0.0, to: 360.0, by: 5) {
                let value = opacity(at: angle, in: stops)
                XCTAssertGreaterThanOrEqual(value, -1e-9, "the gradient dips below nothing at \(angle) deg")
                XCTAssertLessThanOrEqual(value, 1 + 1e-9, "the gradient is over full amber at \(angle) deg")
            }
        }
        XCTAssertTrue(
            HUDRewriteActivity.arcStops(head: 90, trail: 0).allSatisfy { $0.opacity == 0 },
            "a trail of nothing still draws an arc"
        )
    }

    /// The arc and the glow leave over 140 ms when the run ends.
    ///
    /// The reading is the card's clock against the timestamp of the end, so the
    /// fade is the same on the frame the phase changed and on the frame 70 ms
    /// later, whatever the display did in between. Reduced motion does not fade:
    /// the arc is there for the run and gone with it.
    func testTheArcAndTheGlowLeaveOverOneHundredAndFortyMilliseconds() {
        XCTAssertEqual(HUDRewriteActivity.endFadeDuration, 0.14)
        XCTAssertEqual(
            HUDRewriteActivity.arcFade(
                isRunning: true,
                endedAt: 10,
                time: 10.07,
                reduceMotion: false
            ),
            1,
            "the arc faded while the run was still going"
        )
        let endedAt = 10.0
        XCTAssertEqual(
            HUDRewriteActivity.arcFade(
                isRunning: false,
                endedAt: endedAt,
                time: endedAt,
                reduceMotion: false
            ),
            1,
            accuracy: 1e-12,
            "the arc jumped instead of starting its fade at full strength"
        )
        XCTAssertEqual(
            HUDRewriteActivity.arcFade(
                isRunning: false,
                endedAt: endedAt,
                time: endedAt + 0.07,
                reduceMotion: false
            ),
            0.5,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            HUDRewriteActivity.arcFade(
                isRunning: false,
                endedAt: endedAt,
                time: endedAt + 0.14,
                reduceMotion: false
            ),
            0,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            HUDRewriteActivity.arcFade(
                isRunning: false,
                endedAt: endedAt,
                time: endedAt + 3,
                reduceMotion: false
            ),
            0
        )
        // No timestamp, no ink: a card that never ran draws no arc.
        XCTAssertEqual(
            HUDRewriteActivity.arcFade(
                isRunning: false,
                endedAt: nil,
                time: 10,
                reduceMotion: false
            ),
            0
        )
        // Reduced motion takes the arc with the run and reads no clock.
        for time in [endedAt, endedAt + 0.07, endedAt + 0.5] {
            XCTAssertEqual(
                HUDRewriteActivity.arcFade(
                    isRunning: false,
                    endedAt: endedAt,
                    time: time,
                    reduceMotion: true
                ),
                0
            )
        }
        XCTAssertEqual(
            HUDRewriteActivity.arcFade(
                isRunning: true,
                endedAt: nil,
                time: 10,
                reduceMotion: true
            ),
            1
        )
    }

    /// The header names the style while it runs, and nothing else does.
    ///
    /// The sentence that used to be drawn above the body is gone; what is left is
    /// the one VoiceOver reads for the ring, and it names the style the click
    /// chose.
    func testTheHeaderNamesTheStyleOnlyToVoiceOver() {
        let card = Self.streamingCard(draft: "")
        XCTAssertEqual(card.activeStyleTitle, RewriteStyle.concise.title)
        XCTAssertEqual(
            HUDView.rewritingAccessibilityLabel(RewriteStyle.concise.title),
            "Rewriting as \(RewriteStyle.concise.title)"
        )
        var done = card
        done.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        XCTAssertNil(done.activeStyleTitle, "a finished rewrite still names a style")
        var cancelled = card
        cancelled.keepOriginal()
        XCTAssertNil(cancelled.activeStyleTitle)
    }

    // MARK: - The layout budget

    /// The click does not resize the card, and nothing sits above the draft.
    ///
    /// The body is the selected version's words until the first token lands, so
    /// the same text is measured on both sides of the click. The status block that
    /// used to sit above the draft is gone, and with it the seventy points that
    /// made the card grow the moment a style was chosen and shrink when the
    /// request ended.
    func testTheClickKeepsTheCardHeightAndNothingSitsAboveTheDraft() {
        let text = HUDPreview.transcript
        let offered = Self.baseCard()
        var running = offered
        running.phase = .rewriting(styleID: RewriteStyle.concise.id, title: RewriteStyle.concise.title)
        let before = HUD.transcriptSize(text: text, rewrite: offered)
        let after = HUD.transcriptSize(text: text, rewrite: running)
        XCTAssertEqual(
            after.height,
            before.height,
            accuracy: 0.001,
            "the card moved at the click: \(before.height) pt before, \(after.height) pt after"
        )
        XCTAssertEqual(
            HUDRewriteLayout.streamingContentHeight(
                originalContentHeight: HUD.transcriptContentHeight(text: text)
            ),
            HUD.transcriptContentHeight(text: text),
            accuracy: 0.001,
            "the streaming body still pays for something above the draft"
        )
        // The chip row is still what the card pays for under the body.
        XCTAssertEqual(
            after.height - HUD.transcriptSize(text: text).height,
            HUDRewriteLayout.extraHeight(showsChips: true, showsActions: false, noteLines: 0),
            accuracy: 0.001
        )
        // An original that cannot be measured still gets a body.
        XCTAssertEqual(
            HUDRewriteLayout.streamingContentHeight(originalContentHeight: .nan),
            HUDRewriteLayout.streamingDraftMinHeight,
            accuracy: 0.001
        )
    }

    /// A stream of tokens never makes the card shorter.
    ///
    /// The height is measured from the words that were there before the request,
    /// so the hundredth token produces the number the first one did. The oracle is
    /// every height the card passed through while a draft arrived: a card that
    /// shrank once under the reader's eyes fails here.
    func testTheStreamingCardNeverShrinksWhileTheDraftArrives() {
        let text = HUDPreview.transcript
        var card = Self.streamingCard(draft: "")
        let sizes = [
            HUD.transcriptSize(text: text, rewrite: card),
            HUD.transcriptSize(text: text, rewrite: Self.baseCard()),
        ]
        XCTAssertEqual(
            sizes[0].height,
            sizes[1].height,
            accuracy: 0.001,
            "the click frame is not the frame before it"
        )
        for length in [1, 4, 12, 40, 120, 400, 1_200] {
            card.appendDraft(String(repeating: "Dot records the microphone. ", count: length), at: 1)
            let size = HUD.transcriptSize(text: text, rewrite: card)
            XCTAssertGreaterThanOrEqual(
                size.height,
                sizes[0].height - 0.001,
                "the card shrank to \(size.height) pt on a draft of \(length) sentences"
            )
            XCTAssertEqual(size.width, HUDState.transcriptWidth)
        }
    }

    // MARK: - The ink of the idle layer

    /// The idle note and the idle chip labels clear 4.5:1 on the card.
    ///
    /// The reading is the card's own pixels in the dark material. The note is
    /// compared with a twin render whose note is a blank line of the same
    /// height, so every pixel the note changed is measured against the surface
    /// the twin draws there. The chips are read inside their capsules, where the
    /// label is the brightest ink and the fill is the commonest value.
    func testTheIdleNoteAndChipLabelsClearFourPointFiveToOne() throws {
        var noted = Self.doneCard()
        noted.phase = .copied(versionID: 1)
        noted.note = RewriteCard.clipboardNote
        var blank = noted
        blank.note = " "
        let inked = try render(noted, text: HUDPreview.transcript, named: "contrast-noted")
        let surface = try render(blank, text: HUDPreview.transcript, named: "contrast-blank-note")
        XCTAssertEqual(inked.size, surface.size, "the twin render is not the same card")

        // The note's band, measured from the card's bottom edge: the padding,
        // the chip row and the gap above it.
        let noteBottom = HUDTheme.verticalPadding
            + HUDRewriteLayout.chipHeight
            + HUDRewriteLayout.rowGap
        var glyphs = 0
        var noteInk = 0.0
        var noteBackdrop = 0.0
        var deepestRow = 0
        for y in 0 ..< inked.bitmap.pixelsHigh {
            for x in 0 ..< inked.bitmap.pixelsWide {
                guard let one = inked.bitmap.colorAt(x: x, y: y),
                      let two = surface.bitmap.colorAt(x: x, y: y) else { continue }
                let delta = abs(one.redComponent - two.redComponent)
                    + abs(one.greenComponent - two.greenComponent)
                    + abs(one.blueComponent - two.blueComponent)
                guard delta > 0.02 else { continue }
                glyphs += 1
                deepestRow = max(deepestRow, y)
                let ink = relativeLuminance(of: one)
                if ink > noteInk {
                    noteInk = ink
                    noteBackdrop = relativeLuminance(of: two)
                }
            }
        }
        XCTAssertGreaterThan(glyphs, 200, "the note was not drawn, so nothing was measured")
        XCTAssertEqual(
            CGFloat(inked.bitmap.pixelsHigh - deepestRow) / CGFloat(Self.scale),
            noteBottom,
            accuracy: 3,
            "the note is not drawn in the band the layout budgets for it"
        )
        print(
            "idle contrast: note \(contrastRatio(ink: noteInk, backdrop: noteBackdrop)):1"
        )
        XCTAssertGreaterThanOrEqual(
            contrastRatio(ink: noteInk, backdrop: noteBackdrop),
            4.5,
            "the note's ink is \(noteInk) on \(noteBackdrop)"
        )

        // The chip row's own band, and the first style chip in it.
        let chipRows = (inked.bitmap.pixelsHigh - Int((noteBottom - HUDRewriteLayout.rowGap)
            * CGFloat(Self.scale)))
            ..< min(
                inked.bitmap.pixelsHigh,
                inked.bitmap.pixelsHigh - Int(HUDTheme.verticalPadding * CGFloat(Self.scale))
            )
        let leading = HUDTheme.padding
            + HUDRewriteLayout.versionArrowWidth
            + HUDRewriteLayout.chipGap
            + RewriteChipMetrics.chipWidth("Original")
            + HUDRewriteLayout.chipGap
        let style = RewriteStyle.builtIns[0]
        let firstChip = Int((leading * CGFloat(Self.scale)).rounded())
            ..< Int(((leading + RewriteChipMetrics.chipWidth(style.title))
                * CGFloat(Self.scale)).rounded())
        let label = luminances(in: chipRows, cols: firstChip, of: inked.bitmap)
        XCTAssertGreaterThan(label.count, 500, "the first chip is not drawn in the band")
        let labelInk = label.max() ?? 0
        let labelFill = median(of: label)
        XCTAssertGreaterThan(labelInk, labelFill, "the chip label is not ink on a fill")
        print(
            "idle contrast: never-run chip label \(contrastRatio(ink: labelInk, backdrop: labelFill)):1"
        )
        XCTAssertGreaterThanOrEqual(
            contrastRatio(ink: labelInk, backdrop: labelFill),
            4.5,
            "the never-run chip's label is \(labelInk) on \(labelFill)"
        )

        // The selected chip keeps its dark type on the light fill.
        let selectedX = firstChip.upperBound + Int((HUDRewriteLayout.chipGap
            * CGFloat(Self.scale)).rounded())
        let selected = selectedX
            ..< (selectedX + Int((RewriteChipMetrics.chipWidth(RewriteStyle.builtIns[1].title)
                * CGFloat(Self.scale)).rounded()))
        let chosen = luminances(in: chipRows, cols: selected, of: inked.bitmap)
        XCTAssertGreaterThan(chosen.count, 500, "the selected chip is not drawn in the band")
        print(
            "idle contrast: selected chip label \(contrastRatio(ink: chosen.min() ?? 0, backdrop: median(of: chosen))):1"
        )
        XCTAssertGreaterThanOrEqual(
            contrastRatio(ink: chosen.min() ?? 0, backdrop: median(of: chosen)),
            4.5,
            "the selected chip's type is not readable on its fill"
        )
    }

    // MARK: - The height of a streaming card

    func testTheStreamingBodyIsTheSameHeightForNoTokensAndForALongDraft() {
        let before = HUD.transcriptSize(text: HUDPreview.transcript, rewrite: Self.streamingCard(draft: ""))
        let first = HUD.transcriptSize(
            text: HUDPreview.transcript,
            rewrite: Self.streamingCard(draft: "Dot records")
        )
        let deep = HUD.transcriptSize(
            text: HUDPreview.transcript,
            rewrite: Self.streamingCard(
                draft: String(repeating: HUDPreview.longTranscript, count: 3)
            )
        )
        XCTAssertEqual(before.height, first.height, accuracy: 0.001)
        XCTAssertEqual(before.height, deep.height, accuracy: 0.001)
        XCTAssertEqual(before.width, HUDState.transcriptWidth)
    }

    func testEveryRewriteStateStaysInsideTheThreeHundredAndTwelvePointBudget() {
        var streaming = Self.streamingCard(draft: HUDPreview.rewrite)
        streaming.draft = String(repeating: HUDPreview.longTranscript, count: 2)
        var blocked = Self.streamingCard(draft: HUDPreview.transcript)
        blocked.phase = .blocked(styleID: RewriteStyle.concise.id, error: FaithfulnessCheck.numberChanged)
        var failed = Self.streamingCard(draft: "")
        failed.phase = .failed
        failed.note = RewriteCard.failureNote
        var noted = Self.baseCard()
        noted.append(id: 1, style: .concise, text: HUDPreview.transcript, warning: nil)
        noted.phase = .copied(versionID: 1)
        noted.note = RewriteCard.clipboardNote
        var long = Self.baseCard(longOriginal: true)
        long.append(id: 1, style: .concise, text: HUDPreview.longTranscript, warning: nil)
        long.phase = .copied(versionID: 1)
        long.note = RewriteCard.clipboardNote

        let cards = [Self.baseCard(), streaming, blocked, failed, noted, long]
        for card in cards {
            let size = HUD.transcriptSize(
                text: card.original.isEmpty ? HUDPreview.transcript : card.original,
                rewrite: card
            )
            XCTAssertLessThanOrEqual(
                size.height,
                HUDRewriteLayout.maximumCardHeight,
                "the card grew past its budget in \(card.phase)"
            )
            let body = size.height - HUDState.headerHeight - 1 - HUD.rewriteExtraHeight(card)
            XCTAssertGreaterThanOrEqual(
                body,
                HUDTranscript.minBodyHeight,
                "the body collapsed in \(card.phase)"
            )
        }
    }

    // MARK: - The body before the first token

    /// The click keeps the words the person was reading.
    ///
    /// The body is the selected version's text until the draft has a word, so the
    /// first second of a request is not an empty surface: the version the cream
    /// pill names is still drawn, at full ink, in the place it was. The oracle is
    /// the pixels of the body: the same card, the same words, the same frame
    /// except for the header, the chip that is arriving and the chip row's amber.
    func testTheBodyKeepsTheSelectedVersionUntilTheFirstToken() throws {
        let waiting = Self.streamingCard(draft: "")
        XCTAssertEqual(waiting.bodyText, "", "the draft is not the body while it is empty")
        XCTAssertEqual(waiting.visibleBodyText, waiting.selectedVersion.text)
        XCTAssertEqual(waiting.visibleBodyText, HUDPreview.transcript)
        var first = waiting
        first.appendDraft("Dot", at: 1)
        XCTAssertEqual(first.visibleBodyText, "Dot", "the draft did not take the body over")

        let offered = try render(Self.baseCard(), text: HUDPreview.transcript, time: 1.1, named: "body-offered")
        let running = try render(waiting, text: HUDPreview.transcript, time: 1.1, named: "body-waiting")
        XCTAssertEqual(running.size, offered.size, "the click changed the card's size")
        let body = Self.bodyRows(waiting, cardHeight: running.size.height)
        print(
            "body before the first token: "
                + "\(differingPixels(in: body, offered.bitmap, running.bitmap)) pixels differ in the body"
        )
        XCTAssertEqual(
            differingPixels(in: body, offered.bitmap, running.bitmap),
            0,
            "the body did not draw the selected version at the click"
        )
        XCTAssertGreaterThan(
            neutralInkPixels(in: body, cols: 0 ..< running.bitmap.pixelsWide, of: running.bitmap),
            200,
            "the body is empty before the first token"
        )
    }

    /// The newest words come up from 62 per cent over 380 ms.
    ///
    /// Only the appends of the last 380 ms are affected, so a body that has been
    /// streaming for a second carries its older words at the card's own ink and
    /// only the tail is dimmed. The ramp is a function of the clock and the
    /// recorded arrival, so it is read here without a window.
    func testTheArrivingDraftComesUpFromSixtyTwoPercentOverThreeHundredAndEightyMilliseconds() {
        XCTAssertEqual(RewriteDraftRamp.duration, 0.38)
        XCTAssertEqual(RewriteDraftRamp.minimumOpacity, 0.62)
        XCTAssertEqual(RewriteDraftRamp.opacity(elapsed: 0), 0.62, accuracy: 1e-12)
        XCTAssertEqual(RewriteDraftRamp.progress(elapsed: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(RewriteDraftRamp.progress(elapsed: 0.38), 1, accuracy: 1e-12)
        XCTAssertEqual(RewriteDraftRamp.opacity(elapsed: 0.38), 1, accuracy: 1e-12)
        // Ease-out: most of the ramp is done in the first half of the time.
        XCTAssertGreaterThan(
            RewriteDraftRamp.progress(elapsed: 0.19),
            0.8,
            "the ramp is not an ease-out"
        )
        for elapsed in stride(from: 0.0, through: 0.38, by: 0.01) {
            XCTAssertGreaterThanOrEqual(RewriteDraftRamp.opacity(elapsed: elapsed), 0.62)
            XCTAssertLessThanOrEqual(RewriteDraftRamp.opacity(elapsed: elapsed), 1)
        }

        let chunks = [
            RewriteDraftChunk(count: 5, time: 10),
            RewriteDraftChunk(count: 12, time: 10.5),
        ]
        // At 10.6 s the first append is 600 ms old and at full ink; the second is
        // 100 ms old and still coming up.
        let runs = RewriteDraftRamp.runs(chunks: chunks, length: 12, time: 10.6, reduceMotion: false)
        XCTAssertEqual(runs.count, 1, "an old append is still being ramped")
        XCTAssertEqual(runs.first?.range, 5 ..< 12)
        XCTAssertEqual(
            runs.first?.opacity ?? 0,
            RewriteDraftRamp.opacity(elapsed: 0.1),
            accuracy: 1e-12
        )
        // Nothing ramps once the last append has settled.
        XCTAssertTrue(
            RewriteDraftRamp.runs(chunks: chunks, length: 12, time: 11.2, reduceMotion: false).isEmpty
        )
        // Reduced motion draws every word at the body's ink, and reads no clock.
        XCTAssertTrue(
            RewriteDraftRamp.runs(chunks: chunks, length: 12, time: 10.5, reduceMotion: true).isEmpty
        )
        // A chunk left over from a longer draft cannot name characters that are
        // no longer there.
        XCTAssertTrue(
            RewriteDraftRamp.runs(chunks: chunks, length: 3, time: 10.5, reduceMotion: false)
                .allSatisfy { $0.range.upperBound <= 3 }
        )
        XCTAssertTrue(
            RewriteDraftRamp.runs(chunks: chunks, length: 0, time: 10.5, reduceMotion: false).isEmpty
        )
    }

    /// The ramp reaches the pixels: the newest words are dimmer than the rest.
    ///
    /// Two cards carry the same draft in the same place; one has the append dated
    /// the moment of the frame and the other has no arrivals at all. The words are
    /// identical in both frames and the newest ones are dimmer in the first, which
    /// is the whole of the ramp: no movement, no colour, no caret. The reading is
    /// one channel rather than the luminance, because the ramp is one alpha on one
    /// ink and the channel is what that alpha scales.
    func testTheDraftRampDimsOnlyTheNewestWords() throws {
        let draft = Self.midDraft
        var ramped = Self.streamingCard(draft: draft)
        ramped.draftChunks = [RewriteDraftChunk(count: draft.count, time: 1.1)]
        var settled = ramped
        settled.draftChunks = []
        let dim = try render(ramped, text: HUDPreview.transcript, time: 1.1, named: "draft-ramp-0ms")
        let full = try render(settled, text: HUDPreview.transcript, time: 1.1, named: "draft-ramp-settled")
        XCTAssertEqual(dim.size, full.size, "the arrival resized the card")
        let rows = Self.bodyRows(ramped, cardHeight: dim.size.height)
        let cols = 0 ..< dim.bitmap.pixelsWide
        let peak = peakChannel(in: rows, cols: cols, of: dim.bitmap)
        let settledPeak = peakChannel(in: rows, cols: cols, of: full.bitmap)
        print(String(format: "draft ramp: peak %.4f at 0 ms, %.4f settled", peak, settledPeak))
        XCTAssertGreaterThan(settledPeak, 0.5, "the settled draft is not drawn")
        XCTAssertLessThan(peak, settledPeak, "the newest words are not dimmed at all")
        XCTAssertEqual(
            peak / settledPeak,
            RewriteDraftRamp.minimumOpacity,
            accuracy: 0.06,
            "the newest words are not drawn at the ramp's floor"
        )
        XCTAssertGreaterThan(peak / settledPeak, 0.5, "the ramp fell below half the ink")
    }

    /// Both body branches replace each other without an implicit fade.
    ///
    /// The size spring is attached above the body, so a branch that inherits
    /// the transaction would fade the outgoing body under the incoming one.
    /// The two branches are read as the contract they are: an identity
    /// transition on each keeps the spring on the frame and off the swap.
    func testBothBodyBranchesSwitchWithoutAnImplicitTransition() throws {
        let text = try String(
            contentsOf: Self.root.appendingPathComponent("Sources/Dot/HUDView.swift"),
            encoding: .utf8
        )
        let transcript = try XCTUnwrap(
            region(of: text, from: "            if let card, showsDraftBody(card) {", to: "private func headerTitle"),
            "the transcript body is not in the file"
        )
        let branches = transcript.components(separatedBy: "} else {")
        XCTAssertEqual(branches.count, 2, "the transcript body is no longer one if/else")
        for branch in branches {
            XCTAssertTrue(
                branch.contains(".transition(.identity)"),
                "a body branch still inherits the card's implicit transition"
            )
        }
    }

    /// The card never draws the original above the draft.
    ///
    /// The owner rejected the dimmed copy of the original that used to sit over
    /// a streaming rewrite: the words the person just said were drawn a second
    /// time, cut to two dull lines, under the answer arriving. The block, the
    /// card's flag and the layout tokens are gone, and this is the guard that
    /// keeps them gone: nothing in the package may read the flag or the tokens
    /// again, and the body may not draw the original at all.
    func testTheCardDrawsNoDimmedOriginalAboveTheDraft() throws {
        let sources = Self.root.appendingPathComponent("Sources", isDirectory: true)
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 20, "the source tree was not found")
        for file in files {
            let text = try String(
                contentsOf: sources.appendingPathComponent(file),
                encoding: .utf8
            )
            for token in [
                "dimsOriginal",
                "dimmedOriginal",
                "dimmedFontSize",
                "dimmedLineHeight",
                "dimmedGap",
            ] {
                XCTAssertFalse(
                    text.contains(token),
                    "\(file) still reads \(token)"
                )
            }
        }
        let views = try String(
            contentsOf: sources.appendingPathComponent("Dot/HUDRewriteViews.swift"),
            encoding: .utf8
        )
        let body = try XCTUnwrap(
            region(of: views, from: "func draftBody", to: "func rampedText"),
            "the rewrite body is not in the file"
        )
        XCTAssertFalse(
            body.contains("Text(card.original)"),
            "the body still draws the original above the draft"
        )
        XCTAssertEqual(
            occurrences(of: "card.visibleBodyText", in: body),
            1,
            "the body no longer draws exactly one set of words"
        )
        XCTAssertEqual(
            occurrences(of: "Text(text)", in: body),
            1,
            "the body draws more than one paragraph"
        )
        XCTAssertEqual(
            occurrences(of: "Text(", in: body) - occurrences(of: "rampedText(", in: body),
            1,
            "the body draws more than one paragraph"
        )
    }

    // MARK: - The arc on the chip

    /// The arc travels the running chip's rim and stays inside the capsule.
    ///
    /// The capsule's rectangle is pinned to the capsule the card actually drew,
    /// not to the arithmetic: the fill's own edges are found in the bitmap and
    /// held to the box the row's measurements predict. Then the amber on the
    /// outline is read at two times half a period apart: it exists, its centroid
    /// moves, the cream pill does not, and no amber is drawn outside the running
    /// chip's capsule anywhere in the row.
    func testTheArcTravelsTheRunningChipsRim() throws {
        var card = Self.streamingCard(draft: Self.midDraft)
        card.draftChunks = []
        XCTAssertEqual(card.activeStyleID, RewriteStyle.concise.id)
        let runningChip = 1
        let first = try render(card, text: HUDPreview.transcript, time: 0, named: "arc-t0000")
        let second = try render(card, text: HUDPreview.transcript, time: 0.95, named: "arc-t0950")
        let rows = Self.chipRowRows(cardHeight: first.size.height)
        let hint = Self.chipColumns(runningChip)
        let bounds = try XCTUnwrap(
            capsuleLandmark(in: first.bitmap, rows: rows, hint: hint),
            "the running chip's capsule is not drawn"
        )
        // The drawn capsule is where the row's own measurements put it.
        XCTAssertEqual(Double(bounds.cols.lowerBound), Double(hint.lowerBound), accuracy: 2)
        XCTAssertEqual(Double(bounds.cols.upperBound), Double(hint.upperBound), accuracy: 2)
        XCTAssertEqual(Double(bounds.rows.lowerBound), Double(rows.lowerBound), accuracy: 2)
        XCTAssertEqual(Double(bounds.rows.upperBound), Double(rows.upperBound), accuracy: 2)

        let firstRim = rimAmber(of: first.bitmap, bounds: bounds)
        let secondRim = rimAmber(of: second.bitmap, bounds: bounds)
        print("arc evidence (d): \(firstRim.count) and \(secondRim.count) amber pixels on the running chip's rim")
        XCTAssertGreaterThan(firstRim.count, 20, "the running chip's rim carries no amber")
        XCTAssertGreaterThan(secondRim.count, 20, "the running chip's rim lost its amber")

        let moved = hypot(firstRim.centroid.x - secondRim.centroid.x, firstRim.centroid.y - secondRim.centroid.y)
        print(String(format: "arc evidence (d): the rim's amber moved %.1f pt in 0.95 s", moved / CGFloat(Self.scale)))
        XCTAssertGreaterThan(
            moved,
            10 * CGFloat(Self.scale),
            "the arc did not travel: its centroid moved \(moved / CGFloat(Self.scale)) pt"
        )

        // Nothing outside the running chip is amber anywhere in the row.
        var outside = 0
        for y in rows {
            for x in 0 ..< first.bitmap.pixelsWide where !bounds.cols.contains(x) {
                guard let colour = first.bitmap.colorAt(x: x, y: y), isCardAmber(colour) else { continue }
                outside += 1
            }
        }
        print("arc evidence (d): \(outside) amber pixels outside the running chip's capsule")
        XCTAssertEqual(outside, 0, "the arc was drawn outside the capsule it belongs to")

        // The pill stays on the version the card is showing: the Original.
        let selected = Self.originalChipColumns()
        let whiteFirst = whitePixels(in: rows, cols: selected, of: first.bitmap)
        let whiteSecond = whitePixels(in: rows, cols: selected, of: second.bitmap)
        XCTAssertGreaterThan(whiteFirst, 400, "the selected chip lost its cream pill")
        XCTAssertEqual(whiteFirst, whiteSecond, "the cream pill moved between two frames")
        XCTAssertLessThan(
            whitePixels(in: rows, cols: bounds.cols, of: first.bitmap),
            60,
            "the running chip took the cream pill"
        )
        try writeCrop(first, rows: rows, named: "evidence-d-chip-row-t0000")
        try writeCrop(second, rows: rows, named: "evidence-d-chip-row-t0950")
    }

    /// The arc comes up over the trail's falloff, not only at one point.
    ///
    /// A single lit pixel would pass a count of one. The arc is read as the amber
    /// on the capsule's outline at one moment: it must cover more than a sliver of
    /// the perimeter — a stroke that is cut, or a head with no trail — and less
    /// than half of it, which is what a ring would cover. The perimeter is the
    /// capsule's own length, not a guess, and the stroke is 1.5 points wide, so
    /// the ink a whole ring would draw is the perimeter times the stroke.
    func testTheArcIsARunOnTheRimRatherThanARing() throws {
        var card = Self.streamingCard(draft: Self.midDraft)
        card.draftChunks = []
        let rendered = try render(card, text: HUDPreview.transcript, time: 0.3, named: "arc-run")
        let rows = Self.chipRowRows(cardHeight: rendered.size.height)
        let bounds = try XCTUnwrap(
            capsuleLandmark(in: rendered.bitmap, rows: rows, hint: Self.chipColumns(1)),
            "the running chip's capsule is not drawn"
        )
        let lit = rimAmber(of: rendered.bitmap, bounds: bounds).count
        let ring = ringInk(bounds: bounds)
        print("arc run: \(lit) amber pixels of the \(ring) a whole ring would draw")
        XCTAssertGreaterThan(lit, ring / 20, "the arc is not drawn on the rim")
        XCTAssertLessThan(lit, ring / 2, "the arc covers half the rim: it is a ring rather than a run")
    }

    /// A re-run of the style the person is reading still shows the work.
    ///
    /// This is the case the old design missed: the running chip was also the
    /// selected one, so everything that said "working" was suppressed to keep the
    /// cream pill. The pill keeps its dark ink and its fill, and the arc and the
    /// glow are drawn on it.
    func testTheRerunOfTheSelectedStyleDrawsTheArcOnThePill() throws {
        var card = Self.baseCard()
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.phase = .rewriting(
            styleID: RewriteStyle.concise.id,
            title: RewriteStyle.concise.title
        )
        XCTAssertEqual(card.activeStyleID, card.selectedVersion.styleID)
        let rendered = try render(card, text: HUDPreview.transcript, time: 0.4, named: "arc-rerun")
        let rows = Self.chipRowRows(cardHeight: rendered.size.height)
        let hint = Self.chipColumns(1)
        let bounds = try XCTUnwrap(
            capsuleLandmark(in: rendered.bitmap, rows: rows, hint: hint),
            "the selected chip's capsule is not drawn"
        )
        let rim = bounds.rows.lowerBound ..< (bounds.rows.lowerBound + 3 * Self.scale)
        let amber = amberPixels(of: rendered.bitmap, rows: rim, cols: bounds.cols)
        print("arc rerun: \(amber) amber pixels on the selected chip's rim")
        XCTAssertGreaterThan(amber, 4, "the re-run draws no arc on the selected chip")
        let white = whitePixels(in: rows, cols: bounds.cols, of: rendered.bitmap)
        print("arc rerun: \(white) white pixels under the pill")
        XCTAssertGreaterThan(white, 400, "the re-run took the cream pill away")
        // The label keeps the pill's dark ink: the brightest pixel inside the
        // capsule is the fill, not an amber glyph.
        let inner = (bounds.rows.lowerBound + 4) ..< (bounds.rows.upperBound - 4)
        let innerCols = (bounds.cols.lowerBound + 4) ..< (bounds.cols.upperBound - 4)
        let bright = brightAmberPixels(in: inner, cols: innerCols, of: rendered.bitmap)
        print("arc rerun: \(bright) bright amber pixels under the label")
        XCTAssertLessThan(bright, 40, "the rerun's label is amber on the cream pill")

        // The ring's ink against the cream fill. The card's amber is a light
        // colour and read at about 1.5:1 on the pill, so the selected chip
        // draws the darker amber; the thin 1.5 point line has to clear 3:1.
        let rimBand = bounds.rows.lowerBound ..< (bounds.rows.lowerBound + 3 * Self.scale)
        var ringInk = 1.0
        for y in rimBand {
            for x in bounds.cols {
                guard let colour = rendered.bitmap.colorAt(x: x, y: y),
                      isCardAmber(colour)
                else { continue }
                ringInk = min(ringInk, relativeLuminance(of: colour))
            }
        }
        var fillInk = 0.0
        for y in (bounds.rows.lowerBound + 4 * Self.scale) ..< (bounds.rows.upperBound - 4 * Self.scale) {
            for x in (bounds.cols.lowerBound + 4 * Self.scale) ..< (bounds.cols.upperBound - 4 * Self.scale) {
                guard let colour = rendered.bitmap.colorAt(x: x, y: y) else { continue }
                fillInk = max(fillInk, relativeLuminance(of: colour))
            }
        }
        let ratio = contrastRatio(ink: ringInk, backdrop: fillInk)
        print("arc rerun contrast: ring \(ringInk) on pill \(fillInk) = \(ratio):1")
        XCTAssertGreaterThanOrEqual(
            ratio,
            3.0,
            "the arc on the cream pill reads at \(ratio):1"
        )
    }

    /// The running chip is amber while the previous selection keeps its pill.
    ///
    /// The card is opened on a completed Concise version and asked for a Casual
    /// one, so the same frame carries both states: the selected chip is dark type
    /// on the cream fill, and the running chip is the card's amber label with the
    /// arc round its rim. A click must not move the cream pill: it moves when the
    /// version arrives, which is the frame after this one.
    func testTheRunningChipIsAmberWhileTheSelectedChipStaysWhite() throws {
        let card = Self.reviewingCard()
        XCTAssertEqual(card.activeStyleID, RewriteStyle.casual.id)
        XCTAssertEqual(card.selectedVersion.styleID, RewriteStyle.concise.id)
        let rendered = try render(
            card,
            text: HUDPreview.transcript,
            time: 1.1,
            named: "evidence-e-chip-processing-2x"
        )
        let rows = Self.chipRowRows(cardHeight: rendered.size.height)
        try writeCrop(rendered, rows: rows, named: "evidence-e-chip-row-crop-2x")

        let selected = Self.chipColumns(1)
        let running = Self.chipColumns(3)
        let white = whitePixels(in: rows, cols: selected, of: rendered.bitmap)
        print("chip evidence (e): \(white) white pixels under the selected chip")
        XCTAssertGreaterThan(white, 400, "the previously selected chip lost its white fill")

        let inner = (rows.lowerBound + 4) ..< (rows.upperBound - 4)
        let innerCols = (running.lowerBound + 4) ..< (running.upperBound - 4)
        let label = brightAmberPixels(in: inner, cols: innerCols, of: rendered.bitmap)
        print("chip evidence (e): \(label) amber pixels on the running chip's label")
        XCTAssertGreaterThan(label, 40, "the running chip's label is not amber")
        XCTAssertLessThan(
            whitePixels(in: rows, cols: running, of: rendered.bitmap),
            60,
            "the running chip took the white pill"
        )
    }

    /// The running chip keeps its neighbours' fill, and the arc is on its rim.
    ///
    /// The amber tint made the running chip a second solid capsule beside the
    /// white pill, so in stills only hue separated "working" from "selected". The
    /// fill is the card's own control fill, exactly like the chips either side of
    /// it. The frame is read with the head at the top of the capsule, so the
    /// glow — which is centred on the rim where the head is — is further from the
    /// fill sample than its own radius.
    func testTheRunningChipKeepsItsNeighboursFill() throws {
        let card = Self.reviewingCard()
        let rendered = try render(card, text: HUDPreview.transcript, time: 0, named: "chip-fill")
        let rows = Self.chipRowRows(cardHeight: rendered.size.height)
        let running = Self.chipColumns(3)
        let idle = Self.chipColumns(2)
        let scale = CGFloat(Self.scale)
        // The fill is read in the chip's own leading padding: four to seven points
        // inside the capsule's edge, at its vertical centre, which is left of the
        // first glyph (ten points in) and clear of the 1.5 point arc.
        let middle = rows.lowerBound
            + Int((HUDRewriteLayout.chipHeight / 2 * scale).rounded())
        func fillBox(_ chip: Range<Int>) -> (rows: Range<Int>, cols: Range<Int>) {
            let lower = chip.lowerBound + Int((4 * scale).rounded())
            return (middle - 2 ..< middle + 2, lower ..< (lower + Int((3 * scale).rounded())))
        }
        func fill(_ chip: Range<Int>) -> (red: Double, green: Double, blue: Double) {
            let box = fillBox(chip)
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var count = 0.0
            for y in box.rows {
                for x in box.cols {
                    guard let colour = rendered.bitmap.colorAt(x: x, y: y) else { continue }
                    red += Double(colour.redComponent)
                    green += Double(colour.greenComponent)
                    blue += Double(colour.blueComponent)
                    count += 1
                }
            }
            guard count > 0 else { return (0, 0, 0) }
            return (red / count, green / count, blue / count)
        }
        let runningFill = fill(running)
        let idleFill = fill(idle)
        print(String(
            format: "chip fill: running (%.4f, %.4f, %.4f), idle (%.4f, %.4f, %.4f)",
            runningFill.red,
            runningFill.green,
            runningFill.blue,
            idleFill.red,
            idleFill.green,
            idleFill.blue
        ))
        for (name, pair) in [
            ("red", (runningFill.red, idleFill.red)),
            ("green", (runningFill.green, idleFill.green)),
            ("blue", (runningFill.blue, idleFill.blue)),
        ] {
            XCTAssertEqual(
                pair.0,
                pair.1,
                accuracy: 0.01,
                "the running chip's \(name) fill is not its neighbour's: \(runningFill) against \(idleFill)"
            )
        }
        for (name, chip) in [("running", running), ("idle neighbour", idle)] {
            let box = fillBox(chip)
            let amber = amberPixels(of: rendered.bitmap, rows: box.rows, cols: box.cols)
            print("chip fill: \(amber) amber pixels in the \(name) chip's fill")
            XCTAssertEqual(
                amber,
                0,
                "the \(name) chip's fill is amber-tinted: \(amber) amber pixels in it"
            )
        }
        let rimCols = (running.lowerBound + running.count / 4)
            ..< (running.upperBound - running.count / 4)
        let rim = amberPixels(
            of: rendered.bitmap,
            rows: rows.lowerBound ..< (rows.lowerBound + 2),
            cols: rimCols
        )
        print("chip fill: \(rim) amber pixels on the rim")
        XCTAssertGreaterThan(rim, 4, "the running chip has no amber arc")
        try writeCrop(rendered, rows: rows, named: "chip-row-processing")
    }

    /// The first token may not move the arc.
    ///
    /// Both frames are drawn at the same clock and differ only in whether the
    /// service has sent a token, so every pixel of the chip row must be
    /// identical: the arc is driven by the clock, not by the words, and the draft
    /// arriving must not restart it or dim it.
    func testTheFirstTokenDoesNotMoveTheArc() throws {
        let waiting = try render(
            Self.streamingCard(draft: ""),
            text: HUDPreview.transcript,
            time: 1.1,
            named: "arc-waiting-t1100"
        )
        let arriving = try render(
            Self.streamingCard(draft: Self.midDraft),
            text: HUDPreview.transcript,
            time: 1.1,
            named: "arc-arriving-t1100"
        )
        let rows = Self.chipRowRows(cardHeight: waiting.size.height)
        XCTAssertEqual(waiting.size, arriving.size)
        XCTAssertGreaterThan(
            amberPixels(of: waiting.bitmap, rows: rows, cols: 0 ..< waiting.bitmap.pixelsWide),
            20,
            "the waiting chip row is not drawn"
        )
        XCTAssertEqual(
            differingPixels(in: rows, waiting.bitmap, arriving.bitmap),
            0,
            "the first token moved the chip row instead of leaving it to the clock"
        )
    }

    /// Everything a person reads stays still while the arc travels.
    ///
    /// The card's clock is the only difference between the two renders. Two
    /// things may move with it — the chip's arc and the header's ring, which is
    /// the same arc drawn a second time — so the oracle is the body between them:
    /// the words, the typography and the card's own geometry may not change by a
    /// pixel, and the arc must have moved, or the comparison proves nothing.
    func testTheArcMovesNothingButItselfAboveTheChipRow() throws {
        let cases: [(String, String)] = [
            ("waiting", ""),
            ("midstream", Self.midDraft),
        ]
        for (name, draft) in cases {
            var card = Self.streamingCard(draft: draft)
            card.draftChunks = []
            let first = try render(card, text: HUDPreview.transcript, time: 0.183, named: "still-\(name)-t0183")
            let second = try render(card, text: HUDPreview.transcript, time: 1.1, named: "still-\(name)-t1100")
            XCTAssertEqual(first.size, second.size, "the card moved between two phases")
            let chipRows = Self.chipRowRows(cardHeight: first.size.height)
            let body = Self.bodyRows(card, cardHeight: first.size.height)
            XCTAssertLessThan(body.upperBound, chipRows.lowerBound, "the body is not above the chips")
            let moved = differingPixels(in: body, first.bitmap, second.bitmap)
            print("arc \(name): \(moved) pixels moved in the body")
            XCTAssertEqual(moved, 0, "\(name) moved the body with the clock")
            XCTAssertGreaterThan(
                differingPixels(in: chipRows, first.bitmap, second.bitmap),
                0,
                "\(name) drew the same arc at two readings of the clock"
            )
        }
    }

    // MARK: - The header

    /// While a style runs the header draws the ring, not the check mark.
    ///
    /// The check mark belongs to a delivery that has already happened; drawing it
    /// over a request that is still arriving claims an answer. The title's slot is
    /// empty — the row that spelled the style out was the status line the owner
    /// rejected — and the ring is the card's amber. When nothing runs the header
    /// is what it always was: the badge with its glyph and the caps title.
    func testTheHeaderDrawsTheRingInsteadOfTheBadgeWhileARewriteRuns() throws {
        let running = try render(
            Self.streamingCard(draft: Self.midDraft),
            text: HUDPreview.transcript,
            time: 1.1,
            named: "header-running"
        )
        let idle = try render(Self.doneCard(), text: HUDPreview.transcript, time: 1.1, named: "header-idle")
        let scale = CGFloat(Self.scale)
        let badgeBox = Self.pixels(HUDTheme.padding) ..< Self.pixels(HUDTheme.padding + HUDTheme.badgeSize)
        let headerRows = 0 ..< Self.pixels(HUDTheme.headerHeight)

        let ringAmber = amberPixels(of: running.bitmap, rows: headerRows, cols: badgeBox)
        let idleAmber = amberPixels(of: idle.bitmap, rows: headerRows, cols: badgeBox)
        print("header evidence (f): \(ringAmber) amber pixels in the running badge, \(idleAmber) idle")
        XCTAssertGreaterThan(ringAmber, 8, "the running header draws no ring")
        XCTAssertEqual(idleAmber, 0, "the idle header's badge is amber")

        // The title's slot: from past the badge to the clock. It carries the
        // caps title when nothing runs, and nothing at all while one does.
        let titleCols = (badgeBox.upperBound + Int(10 * scale)) ..< (running.bitmap.pixelsWide / 2)
        let titleRows = Int((HUDTheme.headerHeight / 2 - 6) * scale)
            ..< Int((HUDTheme.headerHeight / 2 + 8) * scale)
        let runningTitle = neutralInkPixels(
            in: titleRows,
            cols: titleCols,
            of: running.bitmap
        )
        let idleTitle = neutralInkPixels(in: titleRows, cols: titleCols, of: idle.bitmap)
        print("header evidence (f): \(runningTitle) title pixels running, \(idleTitle) idle")
        XCTAssertEqual(runningTitle, 0, "the running header still draws a title")
        XCTAssertGreaterThan(idleTitle, 20, "the idle header draws no title")

        // The glyph is gone: the idle badge carries the check mark's own ink, the
        // running one carries only the ring's amber and no fill under it.
        XCTAssertGreaterThan(
            whitePixels(in: headerRows, cols: badgeBox, of: idle.bitmap),
            4,
            "the idle badge draws no glyph"
        )
        XCTAssertEqual(
            whitePixels(in: headerRows, cols: badgeBox, of: running.bitmap),
            0,
            "the running badge still draws a glyph or its fill"
        )

        // Stop is the header's own 24 point icon button, in the amber, with its
        // own name. It is drawn only while the request runs.
        XCTAssertEqual(HUDAction.stopRewrite.symbol, "stop.fill")
        XCTAssertEqual(HUDAction.stopRewrite.label(), "Stop rewriting")
        XCTAssertEqual(HUDAction.stopRewrite.restingColor, HUDTheme.live)
        XCTAssertEqual(HUDAction.stopRewrite.hoverColor, HUDTheme.live)
        XCTAssertTrue(HUDAction.stopRewrite.isAvailable(in: HUDPreview.previewActions))
        // The header's trailing run, from the card's trailing edge: the controls
        // the transcript card draws (24 pt each, 4 pt between), the divider and
        // its 8 pt either side, and one 10 pt stack space before Stop's frame.
        let controls = HUDAction.available(
            [.copy, .paste, .history, .settings, .close],
            in: HUDPreview.previewActions,
            versioned: true
        )
        let controlsWidth = CGFloat(controls.count) * HUDTheme.actionSize
            + CGFloat(max(0, controls.count - 1)) * 4
        let stopRight = running.size.width
            - HUDTheme.padding
            - (1 + 2 * 8)
            - controlsWidth
            - 10
        let stopCols = Int((stopRight - HUDTheme.actionSize) * scale) ..< Int(stopRight * scale)
        XCTAssertGreaterThan(
            amberPixels(of: running.bitmap, rows: headerRows, cols: stopCols),
            20,
            "the header draws no Stop button while the request runs"
        )
        XCTAssertEqual(
            amberPixels(of: idle.bitmap, rows: headerRows, cols: stopCols),
            0,
            "the idle header draws the Stop button"
        )
        try writeCrop(running, rows: headerRows, named: "evidence-f-header-running")
        try writeCrop(idle, rows: headerRows, named: "evidence-f-header-idle")
    }

    /// A Copy is acknowledged once: the owner's Review-after-Copy bug.
    ///
    /// The same card, with the same mechanical warning on its selected version,
    /// drawn before and after the Copy click. Before, the header says PREVIEW and
    /// the badge says Review. After, the header says COPIED and the badge is
    /// gone — but the warning is still on the version, and moving to another
    /// warned version brings the check back.
    func testTheCopiedCardDoesNotAlsoSayReview() throws {
        var card = Self.warnedCard()
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PREVIEW"
        )
        XCTAssertTrue(HUDView.showsCheckBadge(card), "the fixture draws no check before the click")
        let before = try render(
            card,
            text: HUDPreview.transcript,
            time: 1.1,
            named: "t119-before-review"
        )

        card.phase = .copied(versionID: 1)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "COPIED"
        )
        XCTAssertEqual(card.warning, Self.warning, "the Copy erased the mechanical warning")
        XCTAssertFalse(
            HUDView.showsCheckBadge(card),
            "the card draws Review beside its own COPIED acknowledgement"
        )
        let after = try render(
            card,
            text: HUDPreview.transcript,
            time: 1.1,
            named: "t119-after-copied"
        )
        XCTAssertGreaterThan(
            differingPixels(before.bitmap, after.bitmap),
            0,
            "the Copy click changed nothing in the drawn header"
        )

        var switched = card
        XCTAssertTrue(switched.select(versionID: 2), "the second version could not be selected")
        XCTAssertEqual(
            HUDHeader.title(for: switched, delivery: .pasted, destination: "Mail"),
            "PREVIEW",
            "the header still acknowledges the version that was copied"
        )
        XCTAssertTrue(
            HUDView.showsCheckBadge(switched),
            "the check did not return with the new version's warning"
        )
        _ = try render(
            switched,
            text: HUDPreview.transcript,
            time: 1.1,
            named: "t119-after-switched"
        )
    }

    /// The clock clears 4.5:1 on the card's dark material.
    ///
    /// The header used the secondary ink for the elapsed time, which the judge
    /// measured at 2.93:1. The clock is read at a glance and sits alone in the
    /// header's right half; it is drawn in the primary ink at the same size and
    /// the same place, so the geometry does not move.
    /// The clock's own glyphs clear 4.5:1 against the surface they sit on.
    ///
    /// The rectangle is the clock's bounding box, found from the pixels: the
    /// run of inked columns that ends to the left of the header's divider, and
    /// the inked rows inside it. A rectangle drawn from arithmetic can land
    /// between the digits and read the empty surface, which is how the clock was
    /// once reported at 2.9:1 while its ink cleared the bar.
    func testTheClockClearsFourPointFiveToOne() throws {
        let rendered = try render(
            Self.doneCard(),
            text: HUDPreview.transcript,
            time: 1.1,
            named: "clock-contrast"
        )
        let controls = HUDAction.available(
            [.copy, .paste, .history, .settings, .close],
            in: HUDPreview.previewActions,
            versioned: true
        )
        let controlsWidth = CGFloat(controls.count) * HUDTheme.actionSize
            + CGFloat(max(0, controls.count - 1)) * 4
        let dividerStart = rendered.size.width
            - HUDTheme.padding
            - (1 + 2 * 8)
            - controlsWidth
        let searchRows = Self.pixels(6) ..< Self.pixels(HUDTheme.headerHeight - 6)
        let searchCols = Self.pixels(rendered.size.width * 0.4) ..< Self.pixels(dividerStart - 6)
        func ink(_ x: Int, _ y: Int) -> Double? {
            guard let colour = rendered.bitmap.colorAt(x: x, y: y) else { return nil }
            return relativeLuminance(of: colour)
        }
        var inked: [Int] = []
        for x in searchCols {
            if searchRows.contains(where: { ink(x, $0).map { $0 > 0.08 } ?? false }) {
                inked.append(x)
            }
        }
        guard let right = inked.last else {
            return XCTFail("no clock was drawn left of the divider")
        }
        let maxBlank = Self.pixels(4)
        var left = right
        var previous = right
        for x in inked.reversed().dropFirst() {
            if previous - x - 1 > maxBlank { break }
            left = x
            previous = x
        }
        var top = Int.max
        var bottom = Int.min
        for y in searchRows {
            for x in left ... right where (ink(x, y) ?? 0) > 0.08 {
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard top <= bottom else { return XCTFail("the clock's box has no rows") }
        var brightest = 0.0
        var darkest = 1.0
        for y in top ... bottom {
            for x in left ... right {
                guard let luminance = ink(x, y) else { continue }
                brightest = max(brightest, luminance)
                darkest = min(darkest, luminance)
            }
        }
        let boxWidth = Double(right - left + 1) / Double(Self.scale)
        let boxHeight = Double(bottom - top + 1) / Double(Self.scale)
        let ratio = contrastRatio(ink: brightest, backdrop: darkest)
        print(
            "clock contrast: \(brightest) on \(darkest) = \(ratio):1, "
                + "box \(boxWidth)x\(boxHeight) pt at \(left)...\(right)"
        )
        XCTAssertGreaterThan(boxWidth, 8, "the box is too narrow to be the clock")
        XCTAssertGreaterThan(boxHeight, 6, "the box is too short to be the clock")
        XCTAssertGreaterThan(brightest, 0.2, "the clock was not drawn, so nothing was measured")
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "the clock reads at \(ratio):1")
    }

    /// A failed rewrite names itself in the header and does not draw the check.
    ///
    /// The judge's finding: the failure card said PREVIEW with a check over
    /// "The rewrite didn't finish." The header now carries the failure's own
    /// glyph and words in the card's amber, the check is suppressed, and the
    /// version the person was reading is still on the card and still
    /// deliverable.
    func testTheFailedHeaderNamesTheFailure() throws {
        var card = Self.warnedCard()
        card.phase = .failed
        card.note = RewriteCard.failureNote
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITE FAILED"
        )
        XCTAssertFalse(HUDView.showsCheckBadge(card))
        XCTAssertTrue(card.canDeliverSelected)
        XCTAssertEqual(card.selectedVersion.text, HUDPreview.rewrite)

        let rendered = try render(
            card,
            text: HUDPreview.transcript,
            time: 1.1,
            named: "judge-failed-header"
        )
        let header = 0 ..< Self.pixels(HUDTheme.headerHeight)
        let badge = Self.pixels(HUDTheme.padding)
            ..< Self.pixels(HUDTheme.padding + HUDTheme.badgeSize)
        let amber = amberPixels(of: rendered.bitmap, rows: header, cols: badge)
        print("failed header: \(amber) amber pixels in the failure badge")
        XCTAssertGreaterThan(amber, 8, "the failure badge's triangle is not drawn")
        XCTAssertEqual(
            whitePixels(in: header, cols: badge, of: rendered.bitmap),
            0,
            "the failed header still carries the delivery's silver check mark"
        )

        // The note is still drawn in its band, and the chips stay inside the
        // card: the failure is reported without pushing the row past the edge.
        let cardHeight = rendered.size.height
        let noteBottom = cardHeight - HUDTheme.verticalPadding
            - HUDRewriteLayout.chipHeight - HUDRewriteLayout.rowGap
        let noteRows = Self.pixels(noteBottom - HUDRewriteLayout.noteHeight) ..< Self.pixels(noteBottom)
        XCTAssertGreaterThan(
            neutralInkPixels(in: noteRows, cols: 0 ..< rendered.bitmap.pixelsWide, of: rendered.bitmap),
            20,
            "the failure note is not drawn in its band"
        )
        let bottom = (rendered.bitmap.pixelsHigh - Self.pixels(10)) ..< rendered.bitmap.pixelsHigh
        XCTAssertEqual(
            neutralInkPixels(in: bottom, cols: 0 ..< rendered.bitmap.pixelsWide, of: rendered.bitmap),
            0,
            "the failure note pushed the chip row past the card's bottom edge"
        )
    }

    /// The failure note takes its line from the body, not from the card's edge.
    ///
    /// The judge caught the first failed frame with the chips cut by the card's
    /// bottom corner. The note is now paid for out of the body's viewport, so a
    /// card that fails does not grow past the frame the person is already
    /// looking at, and the chips keep their place.
    func testTheFailureNoteTakesItsLineFromTheBodyBudget() {
        var failed = Self.streamingCard(draft: Self.midDraft)
        failed.phase = .failed
        failed.note = RewriteCard.failureNote
        var running = failed
        running.phase = .rewriting(styleID: RewriteStyle.concise.id, title: RewriteStyle.concise.title)
        running.note = nil
        var withoutNote = failed
        withoutNote.note = nil

        let failedSize = HUD.transcriptSize(text: HUDPreview.transcript, rewrite: failed)
        let runningSize = HUD.transcriptSize(text: HUDPreview.transcript, rewrite: running)
        let noNoteSize = HUD.transcriptSize(text: HUDPreview.transcript, rewrite: withoutNote)
        XCTAssertEqual(
            failedSize.height,
            runningSize.height,
            accuracy: 0.5,
            "the failure grew the card past the running frame"
        )
        XCTAssertEqual(
            failedSize.height,
            noNoteSize.height,
            accuracy: 0.5,
            "the note grew the card instead of taking the body's line"
        )

        // The note costs the row gap that the chips already paid, so the
        // marginal height is the note's line plus the difference between the
        // gap above it and the gap a bare chip row keeps.
        let noteSpace = HUDRewriteLayout.extraHeight(
            showsChips: failed.showsChips,
            showsActions: false,
            noteLines: 1
        ) - HUDRewriteLayout.extraHeight(
            showsChips: failed.showsChips,
            showsActions: false,
            noteLines: 0
        )
        let body = failedSize.height - HUDTheme.headerHeight - 1 - HUD.rewriteExtraHeight(failed)
        print(
            "failure budget: failed \(failedSize.height), running \(runningSize.height), "
                + "without note \(noNoteSize.height), body \(body), extra \(HUD.rewriteExtraHeight(failed))"
        )
        let bodyWithoutNote = noNoteSize.height
            - HUDTheme.headerHeight - 1 - HUD.rewriteExtraHeight(withoutNote)
        XCTAssertEqual(
            body,
            bodyWithoutNote - noteSpace,
            accuracy: 0.5,
            "the body did not give up the note's height"
        )
        XCTAssertGreaterThanOrEqual(body, 0, "the body has no room left for the words")
    }

    /// The header holds its in-progress face until the arc's teardown ends.
    ///
    /// The judge saw the success mark drawn while the running cue was still on
    /// the card. The ring and the chip's arc share the 140 ms fade, and the
    /// header's title waits for it: the ring leaves and the delivery title
    /// arrives in the same frame.
    func testTheHeaderHoldsTheRingUntilTheTeardownEnds() throws {
        let live = liveCard(Self.doneCard(), text: HUDPreview.transcript)
        defer { live.close() }
        live.model.time = 10
        live.model.rewriteEnding = RewriteEnding(styleID: RewriteStyle.concise.id, at: 10)
        live.host.layoutSubtreeIfNeeded()
        live.window.displayIfNeeded()

        let holding = try capture(live, named: "teardown-holding")
        let header = 0 ..< Self.pixels(HUDTheme.headerHeight)
        let badge = Self.pixels(HUDTheme.padding)
            ..< Self.pixels(HUDTheme.padding + HUDTheme.badgeSize)
        let chipRows = Self.chipRowRows(cardHeight: live.size.height)
        XCTAssertGreaterThan(
            amberPixels(of: holding, rows: header, cols: badge),
            8,
            "the header dropped the ring in the frame the run ended"
        )
        XCTAssertGreaterThan(
            amberPixels(of: holding, rows: chipRows, cols: 0 ..< holding.pixelsWide),
            20,
            "the chip dropped its arc in the frame the run ended"
        )
        let titleCols = (badge.upperBound + Self.pixels(10)) ..< (holding.pixelsWide / 2)
        let titleRows = Self.pixels(HUDTheme.headerHeight / 2 - 6)
            ..< Self.pixels(HUDTheme.headerHeight / 2 + 8)
        XCTAssertEqual(
            neutralInkPixels(in: titleRows, cols: titleCols, of: holding),
            0,
            "the delivery title was drawn while the arc was still leaving"
        )

        live.model.time = 10.15
        live.host.layoutSubtreeIfNeeded()
        live.window.displayIfNeeded()
        let done = try capture(live, named: "teardown-done")
        XCTAssertEqual(
            amberPixels(of: done, rows: header, cols: badge),
            0,
            "the header kept the ring past the teardown"
        )
        XCTAssertEqual(
            amberPixels(of: done, rows: chipRows, cols: 0 ..< done.pixelsWide),
            0,
            "the chip kept its arc past the teardown"
        )
        XCTAssertGreaterThan(
            neutralInkPixels(in: titleRows, cols: titleCols, of: done),
            20,
            "the header did not return when the teardown ended"
        )
    }

    /// An idle card draws nothing on the card's clock.
    func testAnIdleCardDrawsNothingOnItsClock() throws {
        let first = try render(Self.baseCard(), text: HUDPreview.transcript, time: 0, named: "idle-t0000")
        let second = try render(Self.baseCard(), text: HUDPreview.transcript, time: 1.1, named: "idle-t1100")
        XCTAssertEqual(
            differingPixels(first.bitmap, second.bitmap),
            0,
            "an idle card drew something on its clock"
        )
        let rows = Self.chipRowRows(cardHeight: first.size.height)
        XCTAssertEqual(
            amberPixels(of: first.bitmap, rows: rows, cols: 0 ..< first.bitmap.pixelsWide),
            0,
            "an idle card draws the running chip's amber"
        )
    }

    // MARK: - The same view across a phase change

    /// Completion, cancel and failure take the arc off the view that drew it.
    ///
    /// Every case starts on a non-original version and moves the same
    /// `NSHostingView` to its next card. The oracle is the first cached frame
    /// that differs from the running card at all: if that frame still carries the
    /// arc, the work outlived the phase change. The card's fade is recorded where
    /// the phase is mirrored into the model, and none of these cases goes through
    /// it, so the arc is expected to be gone in the frame the phase changed.
    func testThePhaseChangeTakesTheArcOffTheSameView() throws {
        let running = Self.reviewingCard()
        var completed = running
        completed.append(id: 2, style: .casual, text: HUDPreview.rewrite, warning: nil)
        var cancelled = running
        cancelled.phase = .offered
        cancelled.clearDraft()
        cancelled.draftWarning = nil
        cancelled.note = nil
        var failed = running
        failed.phase = .failed
        failed.note = RewriteCard.failureNote

        let cases: [(String, RewriteCard)] = [
            ("completed", completed),
            ("cancelled", cancelled),
            ("failed", failed),
        ]
        for (name, next) in cases {
            let live = liveCard(running, text: HUDPreview.transcript, animated: true)
            defer { live.close() }
            let rows = Self.chipRowRows(cardHeight: live.size.height)
            let before = try capture(live, named: "phase-\(name)-before")
            XCTAssertGreaterThan(
                amberPixels(of: before, rows: rows, cols: 0 ..< before.pixelsWide),
                20,
                "the \(name) case did not start with a visible arc"
            )

            live.model.rewrite = next
            live.model.cardSize = HUD.transcriptSize(text: HUDPreview.transcript, rewrite: next)
            let started = ProcessInfo.processInfo.systemUptime
            let first = try XCTUnwrap(
                firstDrawnFrame(live, after: before),
                "the \(name) card never drew a frame that differed from the running one"
            )
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            try write(first, to: Self.evidence.appendingPathComponent("phase-\(name)-first.png"))
            print(
                "phase \(name): first changed frame drawn "
                    + "\(String(format: "%.1f", elapsed * 1_000)) ms after the card changed"
            )
            let chipRows = Self.chipRowRows(cardHeight: live.size.height)
            XCTAssertEqual(
                amberPixels(of: first, rows: chipRows, cols: 0 ..< first.pixelsWide),
                0,
                "the \(name) state still draws the arc in its first changed frame"
            )
            // The header's own ring is gone with the phase, whatever the row
            // does. A failed card draws its own amber badge, so its first frame
            // is compared with its settled frame below: the badge is static, and
            // a ring in the first frame would be the only difference.
            let badgeCols = Self.pixels(HUDTheme.padding)
                ..< Self.pixels(HUDTheme.padding + HUDTheme.badgeSize)
            if name == "failed" {
                let badgeMiddle = Self.pixels(HUDTheme.headerHeight / 2 - 4)
                    ..< Self.pixels(HUDTheme.headerHeight / 2 + 4)
                XCTAssertGreaterThan(
                    amberPixels(of: first, rows: badgeMiddle, cols: badgeCols),
                    4,
                    "the failed header draws no failure glyph"
                )
            } else {
                let ringTop = Self.pixels(HUDTheme.headerHeight / 2 - 10)
                    ..< Self.pixels(HUDTheme.headerHeight / 2 - 8)
                XCTAssertEqual(
                    amberPixels(of: first, rows: ringTop, cols: badgeCols),
                    0,
                    "the \(name) header still draws the ring"
                )
            }
            if name == "failed" {
                // The note takes its line out of the body, so the chips keep
                // their place above the card's bottom padding in the first
                // frame the failure is drawn.
                let bottom = (first.pixelsHigh - Self.pixels(10)) ..< first.pixelsHigh
                XCTAssertEqual(
                    neutralInkPixels(
                        in: bottom,
                        cols: 0 ..< first.pixelsWide,
                        of: first
                    ),
                    0,
                    "the failure note pushed the chip row past the card's bottom edge"
                )
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            live.host.layoutSubtreeIfNeeded()
            live.window.displayIfNeeded()
            let settled = try capture(live, named: "phase-\(name)-settled")
            XCTAssertEqual(
                amberPixels(of: settled, rows: chipRows, cols: 0 ..< settled.pixelsWide),
                0,
                "the \(name) state draws the arc once settled"
            )
            if name == "failed" {
                // The failure badge is static, so the first frame and the
                // settled frame must agree in its box; a ring would make them
                // differ.
                var changed = 0
                for y in 0 ..< Self.pixels(HUDTheme.headerHeight) {
                    for x in badgeCols where x < first.pixelsWide {
                        guard let one = first.colorAt(x: x, y: y),
                              let two = settled.colorAt(x: x, y: y)
                        else { continue }
                        let delta = abs(one.redComponent - two.redComponent)
                            + abs(one.greenComponent - two.greenComponent)
                            + abs(one.blueComponent - two.blueComponent)
                        if delta > 0.01 { changed += 1 }
                    }
                }
                XCTAssertEqual(
                    changed,
                    0,
                    "the failed header's first frame still draws the ring"
                )
            }
        }
    }

    /// Keep Original takes the arc off in the frame that changes the phase.
    func testKeepOriginalTakesTheArcOffImmediately() throws {
        let running = Self.streamingCard(draft: Self.midDraft)
        let live = liveCard(running, text: HUDPreview.transcript, animated: true)
        defer { live.close() }
        let rows = Self.chipRowRows(cardHeight: live.size.height)

        let before = try capture(live, named: "keep-original-before")
        XCTAssertGreaterThan(
            amberPixels(of: before, rows: rows, cols: 0 ..< before.pixelsWide),
            20,
            "the running card did not start with a visible arc"
        )

        var next = running
        next.keepOriginal()
        live.model.rewrite = next
        live.model.cardSize = HUD.transcriptSize(text: HUDPreview.transcript, rewrite: next)
        let started = ProcessInfo.processInfo.systemUptime
        let first = try XCTUnwrap(
            firstDrawnFrame(live, after: before),
            "the original card never drew a frame that differed from the running one"
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try write(first, to: Self.evidence.appendingPathComponent("keep-original-first.png"))
        print(
            "keep-original first: amber=\(amberPixels(of: first, rows: rows, cols: 0 ..< first.pixelsWide)) "
                + "drawn \(String(format: "%.1f", elapsed * 1_000)) ms after the card changed"
        )
        let chipRows = Self.chipRowRows(cardHeight: live.size.height)
        XCTAssertEqual(
            amberPixels(of: first, rows: chipRows, cols: 0 ..< first.pixelsWide),
            0,
            "the original card still draws the arc in its first changed frame"
        )
        // The chips stay — the person can pick another style without asking
        // twice — and the row is exactly the row it was before the click.
        XCTAssertEqual(
            HUD.rewriteExtraHeight(next),
            HUD.rewriteExtraHeight(Self.baseCard()),
            "the cancel changed the rows under the body"
        )
    }

    // MARK: - The evidence

    /// The frames a reviewer opens, at two pixels per point.
    ///
    /// The direction's times, the card before the first token, the re-run of the
    /// selected style, reduced motion, the header on its own, the 140 ms the work
    /// takes to leave and the idle card whose header is what it always was. Every
    /// frame is written where ``evidence`` points and the path is printed.
    func testTheRewriteStatesAreWrittenOffscreen() throws {
        var card = Self.streamingCard(draft: Self.midDraft)
        card.draftChunks = []
        for (time, name) in [
            (0.0, "card-t0000"),
            (0.475, "card-t0475"),
            (0.95, "card-t0950"),
            (1.425, "card-t1425"),
        ] {
            let rendered = try render(card, text: HUDPreview.transcript, time: time, named: name)
            XCTAssertEqual(rendered.size.width, HUDState.transcriptWidth)
            XCTAssertEqual(
                rendered.size.height,
                HUD.transcriptSize(text: HUDPreview.transcript, rewrite: card).height,
                accuracy: 0.001
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: rendered.url.path))
        }
        _ = try render(
            Self.streamingCard(draft: ""),
            text: HUDPreview.transcript,
            time: 0.3,
            named: "card-before-first-token"
        )
        var rerun = Self.baseCard()
        rerun.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        rerun.phase = .rewriting(
            styleID: RewriteStyle.concise.id,
            title: RewriteStyle.concise.title
        )
        _ = try render(rerun, text: HUDPreview.transcript, time: 0.4, named: "card-rerun-selected")
        _ = try render(
            card,
            text: HUDPreview.transcript,
            time: 0.4,
            reduceMotion: true,
            named: "card-reduced-motion"
        )

        // The completion: the same card, at 0, 70 and 140 ms after the run ends.
        let ended = Self.doneCard()
        for (offset, name) in [
            (0.0, "card-completion-000ms"),
            (0.07, "card-completion-070ms"),
            (0.14, "card-completion-140ms"),
        ] {
            _ = try render(
                ended,
                text: HUDPreview.transcript,
                time: 10 + offset,
                ending: RewriteEnding(styleID: RewriteStyle.concise.id, at: 10),
                named: name
            )
        }
        _ = try render(Self.doneCard(), text: HUDPreview.transcript, time: 1.1, named: "card-idle")
        print("HUDMotionPolishTests renders: \(Self.evidence.path)")
    }

    /// The arc leaves over 140 ms on the card's clock, in pixels.
    ///
    /// The run's last frame, the moment it ended, and the two frames of the fade.
    /// Each fade frame is read against the same card rendered without the run
    /// behind it, so the count is the arc's own contribution rather than a hue:
    /// the selected chip's arc is the dark amber that a half fade blends into the
    /// pill's cream, where an amber test reads nothing while the line is still
    /// drawn. The contribution only ever goes down, and the third frame carries
    /// none of it.
    func testTheArcFadesOutInThePixelsOfTheCard() throws {
        var running = Self.baseCard()
        running.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        running.phase = .rewriting(
            styleID: RewriteStyle.concise.id,
            title: RewriteStyle.concise.title
        )
        let live = try render(running, text: HUDPreview.transcript, time: 10, named: "fade-before")
        let ending = RewriteEnding(styleID: RewriteStyle.concise.id, at: 10)
        let rows = Self.chipRowRows(cardHeight: live.size.height)
        let atEnd = try render(
            running,
            text: HUDPreview.transcript,
            time: 10,
            ending: ending,
            named: "fade-0ms"
        )
        var stopped = running
        stopped.phase = .offered
        stopped.clearDraft()
        func frame(at time: Double, ending: RewriteEnding?, named name: String) throws -> Rendered {
            try render(stopped, text: HUDPreview.transcript, time: time, ending: ending, named: name)
        }
        let endMoment = try frame(at: 10, ending: ending, named: "fade-0ms-stopped")
        let half = try frame(at: 10.07, ending: ending, named: "fade-70ms")
        let gone = try frame(at: 10.14, ending: ending, named: "fade-140ms")
        let bareEnd = try frame(at: 10, ending: nil, named: "fade-bare-000ms")
        let bareHalf = try frame(at: 10.07, ending: nil, named: "fade-bare-070ms")
        let bareGone = try frame(at: 10.14, ending: nil, named: "fade-bare-140ms")
        func arc(_ rendered: Rendered, over bare: Rendered) -> Int {
            differingPixels(in: rows, rendered.bitmap, bare.bitmap)
        }
        let liveAmber = amberPixels(of: atEnd.bitmap, rows: rows, cols: 0 ..< atEnd.bitmap.pixelsWide)
        let start = arc(endMoment, over: bareEnd)
        let middle = arc(half, over: bareHalf)
        let end = arc(gone, over: bareGone)
        let startMass = inkMass(in: rows, endMoment.bitmap, over: bareEnd.bitmap)
        let middleMass = inkMass(in: rows, half.bitmap, over: bareHalf.bitmap)
        let endMass = inkMass(in: rows, gone.bitmap, over: bareGone.bitmap)
        print(
            "fade: \(liveAmber) amber at the end, arc \(start) at the end, "
                + "\(middle) at 70 ms, \(end) at 140 ms"
        )
        print(
            "fade mass: \(startMass) at the end, \(middleMass) at 70 ms, \(endMass) at 140 ms"
        )
        XCTAssertGreaterThan(liveAmber, 20, "the arc is not drawn at the end of the run")
        XCTAssertGreaterThan(start, 20, "the arc is not drawn at the moment the run ends")
        XCTAssertGreaterThan(middle, 0, "the arc jumped instead of fading")
        XCTAssertLessThan(middleMass, startMass * 0.75, "the arc is not fading out")
        XCTAssertEqual(end, 0, "the arc is still drawn 140 ms after the run")
        XCTAssertEqual(endMass, 0, accuracy: 1e-9, "the arc's light is still on the card")
    }

    /// The arc returns to its start after one period.
    func testTheArcReturnsToItsStartAfterOnePeriod() throws {
        var card = Self.streamingCard(draft: Self.midDraft)
        card.draftChunks = []
        let start = try render(card, text: HUDPreview.transcript, time: 0.55, named: "arc-period-start")
        let end = try render(
            card,
            text: HUDPreview.transcript,
            time: 0.55 + HUDRewriteActivity.arcPeriod,
            named: "arc-period-end"
        )
        XCTAssertEqual(
            differingPixels(start.bitmap, end.bitmap),
            0,
            "a whole period did not return the arc to its start"
        )
    }

    func testReducedMotionDrawsIdenticalFrames() throws {
        let first = try render(
            Self.streamingCard(draft: Self.midDraft),
            text: HUDPreview.transcript,
            time: 2.4,
            reduceMotion: true,
            named: "reduced-motion-t240"
        )
        let second = try render(
            Self.streamingCard(draft: Self.midDraft),
            text: HUDPreview.transcript,
            time: 3.0,
            reduceMotion: true,
            named: "reduced-motion-t300"
        )
        XCTAssertEqual(
            differingPixels(first.bitmap, second.bitmap),
            0,
            "reduced motion drew two different frames"
        )
        // The parked arc is a still picture: amber on the chip's rim and in the
        // header's badge, at one fixed angle, with no glow motion.
        let rows = Self.chipRowRows(cardHeight: first.size.height)
        let chipAmber = amberPixels(of: first.bitmap, rows: rows, cols: 0 ..< first.bitmap.pixelsWide)
        let headerAmber = amberPixels(
            of: first.bitmap,
            rows: 0 ..< Self.pixels(HUDTheme.headerHeight),
            cols: Self.pixels(HUDTheme.padding) ..< Self.pixels(HUDTheme.padding + HUDTheme.badgeSize)
        )
        print("reduced motion: \(chipAmber) amber on the chip, \(headerAmber) in the header")
        XCTAssertGreaterThan(chipAmber, 20, "reduced motion dropped the arc")
        XCTAssertGreaterThan(headerAmber, 8, "reduced motion dropped the header's ring")
    }

    /// A timed sequence from one live view, for a reviewer to play beside the
    /// clock.
    ///
    /// This is capture, not interpolation: the model's clock is set from the
    /// wall clock the loop is scheduled on, the run loop draws the card, and
    /// each file is cached from that view at that moment. The timestamps and
    /// cadence are written beside the frames, so a slow machine reports a slow
    /// machine instead of a smooth one.
    ///
    /// `DOT_HUD_CAPTURE_SEQUENCE=1` runs it: it draws two full turns of the arc,
    /// waiting and midstream.
    func testTheArcIsCapturedFromTheRunLoop() throws {
        guard ProcessInfo.processInfo.environment["DOT_HUD_CAPTURE_SEQUENCE"] == "1" else {
            throw XCTSkip("set DOT_HUD_CAPTURE_SEQUENCE=1 to capture the timed sequence")
        }
        let directory = Self.evidence.appendingPathComponent("motion-sequence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let live = liveCard(Self.streamingCard(draft: ""), text: HUDPreview.transcript)
        defer { live.close() }

        let waiting = try runSequence(live, name: "waiting", into: directory, runningChip: 1)
        try write(cachedBitmap(live, scale: 1), to: directory.appendingPathComponent("waiting-1x.png"))

        live.model.rewrite = Self.streamingCard(draft: Self.midDraft)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let streaming = try runSequence(live, name: "streaming", into: directory, runningChip: 1)
        try write(cachedBitmap(live, scale: 1), to: directory.appendingPathComponent("streaming-1x.png"))

        for sequence in [waiting, streaming] {
            XCTAssertEqual(
                sequence.frames.count,
                sequence.updateCount,
                "\(sequence.name) did not cache every update it drew"
            )
            XCTAssertGreaterThan(sequence.updateCount, 1, "\(sequence.name) drew no updates")
            XCTAssertGreaterThan(
                sequence.visibleFrames,
                sequence.frames.count * 2 / 3,
                "\(sequence.name) drew no arc in too many frames"
            )
            let signatures = Set(sequence.frames.map { $0.arcSignature.rounded() })
            XCTAssertGreaterThan(
                signatures.count,
                1,
                "\(sequence.name) drew the same arc in every frame of two turns"
            )
        }
    }

    // MARK: - The source

    /// The layer is one arc and one Stop button, and the status block is gone.
    ///
    /// The owner rejected the dot band, the sentence and the Stop capsule under
    /// the body. This is the guard that keeps them gone: the sentence is not
    /// drawn anywhere, the lattice and its symbols are not in the package, the
    /// layout tokens that paid for the block are not declared, and the views do
    /// not own a clock, a timer or a repeating animation.
    func testTheRewriteLayerHasOneArcAndNoStatusBlock() throws {
        let sources = Self.root.appendingPathComponent("Sources", isDirectory: true)
        let views = try String(
            contentsOf: sources.appendingPathComponent("Dot/HUDRewriteViews.swift"),
            encoding: .utf8
        )
        for token in [
            "RewriteActivityLattice",
            "rewriteStatusLine",
            "rewriteStatusBlock",
            "RewriteStopButton",
            "processingRingWidth",
            "processingRingOpacity",
            "processingLabelOpacity",
            "TimelineView",
            "repeatForever",
            "Timer",
            "Canvas(",
        ] {
            XCTAssertFalse(views.contains(token), "HUDRewriteViews.swift still reads \(token)")
        }
        // The lattice's own geometry is gone with it. The words it used are
        // ordinary: a waveform has columns and a circle has a centre, so the guard
        // is the file that drew the band rather than the whole package.
        let activity = try String(
            contentsOf: sources.appendingPathComponent("DotCore/HUDRewriteActivity.swift"),
            encoding: .utf8
        )
        for token in ["columnCount", "centreX", "centreY", "lattice", "Lattice"] {
            XCTAssertFalse(activity.contains(token), "HUDRewriteActivity.swift still reads \(token)")
        }
        // The one sentence that names the style is an accessibility label now,
        // and it is the only "Rewriting as" in the package.
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        var sentences: [String] = []
        for file in files {
            let text = try String(
                contentsOf: sources.appendingPathComponent(file),
                encoding: .utf8
            )
            for token in [
                "statusLineHeight",
                "statusStopHeight",
                "statusLatticeGap",
                "statusLatticeHeight",
                "statusBodyGap",
                "statusBlockHeight",
                "frozenHeat",
                "bandHeight",
            ] {
                XCTAssertFalse(text.contains(token), "\(file) still reads \(token)")
            }
            if text.contains("Rewriting as") {
                sentences.append(file)
            }
        }
        XCTAssertEqual(
            sentences,
            ["Dot/HUDView.swift"],
            "the running sentence is drawn somewhere other than the header's label"
        )
        // The header's ring and the chip's arc are one movement because both ask
        // the model for the angle: neither file computes a phase of its own.
        XCTAssertTrue(
            views.contains("HUDRewriteActivity.arcHeadAngle(time: time"),
            "the chip does not take its angle from the model"
        )
        XCTAssertTrue(
            views.contains("HUDRewriteActivity.reducedMotionHeadDegrees"),
            "the chip has no parked angle for reduced motion"
        )
        let header = try String(
            contentsOf: sources.appendingPathComponent("Dot/HUDView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            header.contains("HUDRewriteActivity.arcHeadAngle("),
            "the header's ring does not take its angle from the same function"
        )
        XCTAssertTrue(
            header.contains("RewriteArcRing("),
            "the header does not draw the chip's arc"
        )
    }

    // MARK: - Fixtures

    /// The sentence the streaming body is holding mid-request.
    private static let midDraft =
        "Dot records the microphone, transcribes the words and pastes them back where you were."

    private static func baseCard(longOriginal: Bool = false) -> RewriteCard {
        RewriteCard(
            original: longOriginal ? HUDPreview.longTranscript : HUDPreview.transcript,
            choices: RewriteStyle.builtIns,
            destination: "Mail"
        )
    }

    /// A card in the middle of a request, with the draft it has so far.
    private static func streamingCard(draft: String, longOriginal: Bool = false) -> RewriteCard {
        var card = baseCard(longOriginal: longOriginal)
        card.phase = .rewriting(styleID: RewriteStyle.concise.id, title: RewriteStyle.concise.title)
        card.draft = draft
        return card
    }

    /// A card that already shows a non-original version and is running another
    /// style: the state a completion, a cancel or a failure leaves from.
    private static func reviewingCard() -> RewriteCard {
        var card = baseCard()
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.phase = .rewriting(
            styleID: RewriteStyle.casual.id,
            title: RewriteStyle.casual.title
        )
        card.draft = "Dot records the microphone and"
        return card
    }

    private static func doneCard() -> RewriteCard {
        var card = baseCard()
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        return card
    }

    /// A card whose selected version carries a mechanical warning.
    private static func warnedCard() -> RewriteCard {
        var card = doneCard()
        card.versions[1] = RewriteVersion(
            id: 1,
            origin: .style(RewriteStyle.concise.id),
            title: RewriteStyle.concise.title,
            text: HUDPreview.rewrite,
            ordinal: 1,
            warning: warning
        )
        card.versions.append(
            RewriteVersion(
                id: 2,
                origin: .style(RewriteStyle.casual.id),
                title: RewriteStyle.casual.title,
                text: HUDPreview.rewrite,
                ordinal: 1,
                warning: "A negation was dropped."
            )
        )
        return card
    }

    /// The first warning the mechanical check can report, for the Copy cases.
    private static let warning = "A number changed: 12 to 13."

    private static func cancelledCard() -> RewriteCard {
        var card = streamingCard(draft: midDraft)
        card.keepOriginal()
        return card
    }

    private static func errorCard() -> RewriteCard {
        var card = streamingCard(draft: "")
        card.phase = .failed
        card.note = RewriteCard.failureNote
        return card
    }

    /// A completed version, mounted with its words already in it.
    private static func restoredCard(text: String) -> RewriteCard {
        var card = baseCard()
        card.versions = [
            RewriteVersion.original(text: card.original),
            RewriteVersion(
                id: 1,
                origin: .style(RewriteStyle.concise.id),
                title: RewriteStyle.concise.title,
                text: text,
                ordinal: 1
            ),
        ]
        card.selectedVersionID = 1
        return card
    }

    // MARK: - Rendering

    /// Draws one card through the app's own view, off every display.
    ///
    /// The window is an ``OffscreenWindow``: it is ordered front where no
    /// display exists, so the window server never draws it on the owner's
    /// screen, and `cacheDisplay` fills the bitmap at ``scale`` pixels per
    /// point.
    private func render(
        _ card: RewriteCard,
        text: String,
        time: Double = 2.4,
        reduceMotion: Bool = false,
        ending: RewriteEnding? = nil,
        named name: String
    ) throws -> Rendered {
        _ = NSApplication.shared
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.time = time
        model.material = .black
        model.mode = .transcript(
            text: text,
            delivery: .pasted,
            elapsed: "0:07",
            destination: "Mail"
        )
        model.rewrite = card
        model.rewriteEnding = ending
        model.cardSize = HUD.transcriptSize(text: text, rewrite: card)
        let size = model.cardSize
        let view = HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions,
            reduceMotionOverride: reduceMotion
        )
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * Self.scale,
                pixelsHigh: Int(size.height) * Self.scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            "the render could not be allocated"
        )
        bitmap.size = size
        host.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)

        let firstWrite = !FileManager.default.fileExists(atPath: Self.evidence.path)
        try? FileManager.default.createDirectory(
            at: Self.evidence,
            withIntermediateDirectories: true
        )
        if firstWrite {
            print("HUDMotionPolishTests renders: \(Self.evidence.path)")
        }
        let url = Self.evidence.appendingPathComponent("\(name).png")
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: url, options: .atomic)
        }
        window.contentView = nil
        return Rendered(bitmap: bitmap, size: size, url: url)
    }

    // MARK: - One live view

    /// A card kept in one hosting view, off every display, whose model a test
    /// can change without rebuilding the view.
    private struct LiveCard {
        let model: HUDModel
        let host: NSHostingView<AnyView>
        let window: OffscreenWindow
        let size: CGSize

        @MainActor func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    private func liveCard(_ card: RewriteCard, text: String, animated: Bool = false) -> LiveCard {
        _ = NSApplication.shared
        let size = HUD.transcriptSize(text: text, rewrite: card)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.time = 1.1
        model.material = .black
        model.mode = .transcript(
            text: text,
            delivery: .pasted,
            elapsed: "0:07",
            destination: "Mail"
        )
        model.rewrite = card
        model.cardSize = size
        let view = HUDView(
            model: model,
            showsShadow: false,
            animated: animated,
            actions: HUDPreview.previewActions,
            reduceMotionOverride: false
        )
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return LiveCard(model: model, host: host, window: window, size: size)
    }

    /// The first cached frame that differs from the frame before a change.
    ///
    /// The run loop is pumped in small turns until the hosting view has drawn
    /// something new, so the reading is the first frame the person could see,
    /// not a fixed delay that a slow layout pass can miss.
    private func firstDrawnFrame(
        _ live: LiveCard,
        after before: NSBitmapImageRep,
        timeout: TimeInterval = 1
    ) -> NSBitmapImageRep? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
            live.host.layoutSubtreeIfNeeded()
            live.window.displayIfNeeded()
            guard let frame = cachedBitmap(live, scale: Self.scale) else { continue }
            if differingPixels(before, frame) > 0 { return frame }
        }
        return nil
    }

    private func cachedBitmap(_ live: LiveCard, scale: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(live.size.width) * scale,
            pixelsHigh: Int(live.size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = live.size
        live.host.cacheDisplay(in: NSRect(origin: .zero, size: live.size), to: bitmap)
        return bitmap
    }

    private func capture(_ live: LiveCard, named name: String) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(
            cachedBitmap(live, scale: Self.scale),
            "the render could not be allocated"
        )
        try write(bitmap, to: Self.evidence.appendingPathComponent("\(name).png"))
        return bitmap
    }

    private func write(_ bitmap: NSBitmapImageRep?, to url: URL) throws {
        let bitmap = try XCTUnwrap(bitmap, "the frame \(url.lastPathComponent) could not be drawn")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url, options: .atomic)
        print("HUDMotionPolishTests frame: \(url.path)")
    }

    // MARK: - The timed sequence

    private struct SequenceUpdate {
        let tick: Int
        let scheduled: Double
        let sampled: Double
        let drawn: Double
    }

    private struct SequenceFrame {
        let tick: Int
        let scheduled: Double
        let sampled: Double
        let drawn: Double
        /// How much amber the running chip's capsule carries in this frame.
        let arcAmber: Int
        /// Where that amber sits, as the centroid's two coordinates added: one
        /// number that changes as the arc travels, kept instead of the frame.
        let arcSignature: Double
    }

    private struct Sequence {
        let name: String
        let duration: Double
        let updates: [SequenceUpdate]
        let frames: [SequenceFrame]
        let first: NSBitmapImageRep?
        let last: NSBitmapImageRep?

        var updateCount: Int { updates.count }

        var visibleFrames: Int { frames.filter { $0.arcAmber > 0 }.count }

        var meanGap: TimeInterval {
            guard let first = updates.first, let last = updates.last, updates.count > 1 else {
                return 0
            }
            return (last.drawn - first.drawn) / Double(updates.count - 1)
        }

        var meanSampleLag: TimeInterval {
            guard !updates.isEmpty else { return 0 }
            return updates.map { $0.drawn - $0.sampled }.reduce(0, +) / Double(updates.count)
        }
    }

    /// Draws the card's clock from the wall clock at up to sixty updates a
    /// second, caches every drawn update, and records what actually happened
    /// instead of the rate it aimed for.
    ///
    /// The schedule is the grid; the clock is the time the update was really
    /// drawn. A capture pass that makes the loop late therefore produces a
    /// late, slower sequence with honest timestamps, not a re-timed one.
    private func runSequence(
        _ live: LiveCard,
        name: String,
        into directory: URL,
        runningChip: Int,
        cycles: Double = 2
    ) throws -> Sequence {
        let interval = 1.0 / 60.0
        let duration = cycles * HUDRewriteActivity.arcPeriod
        let origin = ProcessInfo.processInfo.systemUptime
        var updates: [SequenceUpdate] = []
        var frames: [SequenceFrame] = []
        var first: NSBitmapImageRep?
        var last: NSBitmapImageRep?
        var tick = 0
        while true {
            let now = ProcessInfo.processInfo.systemUptime - origin
            if now >= duration { break }
            tick = Int(now / interval) + 1
            let scheduled = Double(tick) * interval
            if scheduled > duration { break }
            let wait = scheduled - (ProcessInfo.processInfo.systemUptime - origin)
            if wait > 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(wait))
            }
            let sampled = ProcessInfo.processInfo.systemUptime - origin
            live.model.time = sampled
            live.host.layoutSubtreeIfNeeded()
            live.window.displayIfNeeded()
            let drawn = ProcessInfo.processInfo.systemUptime - origin
            updates.append(
                SequenceUpdate(tick: tick, scheduled: scheduled, sampled: sampled, drawn: drawn)
            )

            let bitmap = try XCTUnwrap(
                cachedBitmap(live, scale: Self.scale),
                "the \(name) update at \(String(format: "%.3f", sampled)) s could not be drawn"
            )
            let chipRows = Self.chipRowRows(cardHeight: live.size.height)
            let bounds = capsuleLandmark(
                in: bitmap,
                rows: chipRows,
                hint: Self.chipColumns(runningChip)
            )
            let centroid = bounds.flatMap {
                amberCentroid(rows: $0.rows, cols: $0.cols, of: bitmap)
            }
            frames.append(
                SequenceFrame(
                    tick: tick,
                    scheduled: scheduled,
                    sampled: sampled,
                    drawn: drawn,
                    arcAmber: bounds.map {
                        amberPixels(of: bitmap, rows: $0.rows, cols: $0.cols)
                    } ?? 0,
                    arcSignature: (centroid?.x ?? 0) + (centroid?.y ?? 0)
                )
            )
            if first == nil { first = bitmap }
            last = bitmap
            try write(
                bitmap,
                to: directory.appendingPathComponent(
                    String(format: "%@-%05d-%07.3fs.png", name, tick, sampled)
                )
            )
        }
        let sequence = Sequence(
            name: name,
            duration: duration,
            updates: updates,
            frames: frames,
            first: first,
            last: last
        )
        try writeTimeline(sequence, to: directory)
        return sequence
    }

    private func writeTimeline(_ sequence: Sequence, to directory: URL) throws {
        var updates = "tick,scheduled_s,sampled_s,drawn_s,gap_ms\n"
        var previous: Double?
        for update in sequence.updates {
            let gap = previous.map { (update.drawn - $0) * 1_000 } ?? 0
            updates += String(
                format: "%d,%.4f,%.4f,%.4f,%.2f\n",
                update.tick,
                update.scheduled,
                update.sampled,
                update.drawn,
                gap
            )
            previous = update.drawn
        }
        try updates.write(
            to: directory.appendingPathComponent("\(sequence.name)-updates.csv"),
            atomically: true,
            encoding: .utf8
        )

        var frames = "tick,scheduled_s,sampled_s,drawn_s,arc_amber,arc_centroid\n"
        for frame in sequence.frames {
            frames += String(
                format: "%d,%.4f,%.4f,%.4f,%d,%.2f\n",
                frame.tick,
                frame.scheduled,
                frame.sampled,
                frame.drawn,
                frame.arcAmber,
                frame.arcSignature
            )
        }
        try frames.write(
            to: directory.appendingPathComponent("\(sequence.name)-frames.csv"),
            atomically: true,
            encoding: .utf8
        )

        let gaps = zip(sequence.updates, sequence.updates.dropFirst())
            .map { $1.drawn - $0.drawn }
        let worst = gaps.max() ?? 0
        let achievedFPS = sequence.meanGap > 0 ? 1 / sequence.meanGap : 0
        let summary = """
        state: \(sequence.name)
        duration: \(String(format: "%.3f", sequence.duration)) s
        updates: \(sequence.updateCount)
        mean update gap: \(String(format: "%.2f", sequence.meanGap * 1_000)) ms
        achieved update rate: \(String(format: "%.1f", achievedFPS)) Hz
        worst update gap: \(String(format: "%.2f", worst * 1_000)) ms
        mean model-time lag at draw: \(String(format: "%.2f", sequence.meanSampleLag * 1_000)) ms
        captured frames: \(sequence.frames.count)
        frames with an arc: \(sequence.visibleFrames)
        note: frames are cacheDisplay snapshots of the offscreen hosting view,
              not a compositor recording. The update rate is what the run loop
              actually achieved at \(String(format: "%.4f", 1.0 / 60.0)) s scheduling.
        """
        try summary.write(
            to: directory.appendingPathComponent("\(sequence.name)-summary.txt"),
            atomically: true,
            encoding: .utf8
        )
        print("motion sequence \(sequence.name):\n\(summary)")
    }

    // MARK: - Pixels

    /// The package root, found from this file.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The part of a file between two markers, when both are in it.
    private func region(of text: String, from start: String, to end: String) -> String? {
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound ..< text.endIndex) else {
            return nil
        }
        return String(text[startRange.lowerBound ..< endRange.lowerBound])
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The relative luminance of one drawn pixel, in the space the contrast
    /// rules name.
    private func relativeLuminance(of colour: NSColor) -> Double {
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.redComponent)
            + 0.7152 * linear(colour.greenComponent)
            + 0.0722 * linear(colour.blueComponent)
    }

    /// The contrast ratio of two relative luminances.
    private func contrastRatio(ink: Double, backdrop: Double) -> Double {
        let lighter = max(ink, backdrop)
        let darker = min(ink, backdrop)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The luminances of the pixels in a rectangle of the bitmap.
    private func luminances(
        in rows: Range<Int>,
        cols: Range<Int>,
        of bitmap: NSBitmapImageRep
    ) -> [Double] {
        var values: [Double] = []
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                values.append(relativeLuminance(of: colour))
            }
        }
        return values
    }

    private func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    /// The pixels of the card's neutral ink: bright enough to be type, and not
    /// the amber of the status.
    private func neutralInkPixels(
        in rows: Range<Int>,
        cols: Range<Int>,
        of bitmap: NSBitmapImageRep
    ) -> Int {
        var count = 0
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                guard let low = channels.min(), let high = channels.max() else { continue }
                if low > 0.25 && high - low < 0.12 { count += 1 }
            }
        }
        return count
    }

    /// Whether a pixel is drawn in the card's amber rather than its white ink.
    ///
    /// `colorAt` returns the colour unpremultiplied, so the alpha is asked for
    /// separately and the hue is read from the channels the amber is made of. The
    /// card's ink is nearly white and the cream pill is warm white, so a test that
    /// only asks for a reddish pixel counts glyph antialiasing as amber: the arc
    /// is the only strongly saturated warm thing the card draws, and the ratio of
    /// the warm and cool channels is what separates it from both.
    private func isCardAmber(_ colour: NSColor) -> Bool {
        let red = Double(colour.redComponent)
        let green = Double(colour.greenComponent)
        let blue = Double(colour.blueComponent)
        guard colour.alphaComponent > 0.5, red > 0.18, red >= green, green >= blue else {
            return false
        }
        return (red - blue) / red > 0.40
    }

    /// Whether a pixel is the arc's own stroke rather than its glow.
    ///
    /// The stroke is the amber at up to full strength: even at the end of the
    /// trail it is 40 per cent of the amber over the chip's fill, which is a red
    /// channel of about 0.43. The glow is the same amber at a fifth, which over
    /// the same fill is 0.27 at its very centre and less everywhere else. The
    /// floor is what tells the line from the light it throws.
    private func isArcInk(_ colour: NSColor) -> Bool {
        isCardAmber(colour) && Double(colour.redComponent) > 0.33
    }

    /// Whether a pixel is a strong amber rather than a wash of it.
    ///
    /// The running chip's label and the header's Stop icon are the amber almost at
    /// full strength; the glow at the arc's head is the same amber at a fifth. The
    /// floor is what separates the ink from the light.
    private func isBrightAmber(_ colour: NSColor) -> Bool {
        let red = Double(colour.redComponent)
        let green = Double(colour.greenComponent)
        let blue = Double(colour.blueComponent)
        guard red > 0.55, red >= green, green >= blue else { return false }
        return (red - blue) / red > 0.40
    }

    /// How many pixels of a rectangle are drawn in the card's amber.
    private func amberPixels(
        of bitmap: NSBitmapImageRep,
        rows: Range<Int>,
        cols: Range<Int>
    ) -> Int {
        var count = 0
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y), isCardAmber(colour) else { continue }
                count += 1
            }
        }
        return count
    }

    /// Where the amber of a rectangle sits, weighted by how much amber it is.
    ///
    /// A count says the arc exists; the centroid says where it is, which is what
    /// separates a travelling arc from a ring that is lit at one fixed place. The
    /// weight is one amber pixel per unit of the warm-minus-cool difference, so a
    /// bright part of the trail pulls harder than its tail.
    private func amberCentroid(
        rows: Range<Int>,
        cols: Range<Int>,
        of bitmap: NSBitmapImageRep
    ) -> CGPoint? {
        var sum = 0.0
        var xSum = 0.0
        var ySum = 0.0
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y), isCardAmber(colour) else { continue }
                let weight = Double(colour.redComponent - colour.blueComponent)
                sum += weight
                xSum += weight * Double(x)
                ySum += weight * Double(y)
            }
        }
        guard sum > 0 else { return nil }
        return CGPoint(x: xSum / sum, y: ySum / sum)
    }

    /// The amber drawn on a capsule's outline, and where it sits.
    ///
    /// The stroke lies inside the shape by half its width, so a pixel counts when
    /// its centre is within two points of the outline the model's own geometry
    /// names. The label is further in than that, and the glow's wash is weaker
    /// than the amber the outline is drawn in, so what is read here is the arc.
    ///
    /// - Parameters:
    ///   - bitmap: the rendered card.
    ///   - bounds: the drawn capsule, in pixels.
    /// - Returns: how many outline pixels carry amber, and their weighted centre.
    private func rimAmber(
        of bitmap: NSBitmapImageRep,
        bounds: (rows: Range<Int>, cols: Range<Int>)
    ) -> (count: Int, centroid: CGPoint) {
        let size = capsuleSize(bounds)
        var count = 0
        var sum = 0.0
        var xSum = 0.0
        var ySum = 0.0
        for y in bounds.rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in bounds.cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y), isArcInk(colour) else { continue }
                let point = CGPoint(
                    x: (Double(x) + 0.5 - Double(bounds.cols.lowerBound)) / Double(Self.scale),
                    y: (Double(y) + 0.5 - Double(bounds.rows.lowerBound)) / Double(Self.scale)
                )
                guard abs(outlineDistance(point, size: size)) <= 2 else { continue }
                count += 1
                let weight = Double(colour.redComponent - colour.blueComponent)
                sum += weight
                xSum += weight * Double(x)
                ySum += weight * Double(y)
            }
        }
        guard sum > 0 else { return (count, .zero) }
        return (count, CGPoint(x: xSum / sum, y: ySum / sum))
    }

    /// How many amber pixels a stroke of the arc's width would draw all the way
    /// round a capsule: the perimeter times the stroke, in pixels.
    private func ringInk(bounds: (rows: Range<Int>, cols: Range<Int>)) -> Int {
        let size = capsuleSize(bounds)
        let width = Double(size.width)
        let height = Double(size.height)
        let radius = min(width, height) / 2
        let perimeter = 2 * (width - 2 * radius) + 2 * (height - 2 * radius) + 2 * .pi * radius
        return Int((perimeter * Double(HUDRewriteActivity.arcLineWidth)
            * Double(Self.scale) * Double(Self.scale)).rounded())
    }

    /// A drawn capsule's size in points.
    private func capsuleSize(_ bounds: (rows: Range<Int>, cols: Range<Int>)) -> CGSize {
        CGSize(
            width: CGFloat(bounds.cols.count) / CGFloat(Self.scale),
            height: CGFloat(bounds.rows.count) / CGFloat(Self.scale)
        )
    }

    /// How far a point is from a capsule's outline, in points: positive outside.
    ///
    /// A capsule is every point within one radius of the segment between its two
    /// cap centres, so the distance to the outline is the distance to that
    /// segment less the radius.
    private func outlineDistance(_ point: CGPoint, size: CGSize) -> Double {
        let radius = Double(min(size.width, size.height)) / 2
        let first: CGPoint
        let second: CGPoint
        if size.width >= size.height {
            first = CGPoint(x: radius, y: Double(size.height) / 2)
            second = CGPoint(x: Double(size.width) - radius, y: Double(size.height) / 2)
        } else {
            first = CGPoint(x: Double(size.width) / 2, y: radius)
            second = CGPoint(x: Double(size.width) / 2, y: Double(size.height) - radius)
        }
        let dx = Double(second.x - first.x)
        let dy = Double(second.y - first.y)
        let lengthSquared = dx * dx + dy * dy
        let along = lengthSquared == 0 ? 0 : min(
            max(
                ((Double(point.x) - Double(first.x)) * dx
                    + (Double(point.y) - Double(first.y)) * dy) / lengthSquared,
                0
            ),
            1
        )
        let nearest = CGPoint(
            x: Double(first.x) + along * dx,
            y: Double(first.y) + along * dy
        )
        return hypot(Double(point.x) - Double(nearest.x), Double(point.y) - Double(nearest.y)) - radius
    }

    /// The brightest red channel of a rectangle.
    ///
    /// The ramp is one alpha on one ink, so the channel is what the alpha scales;
    /// the luminance would apply the display curve and report a ratio that is not
    /// the ramp's.
    private func peakChannel(
        in rows: Range<Int>,
        cols: Range<Int>,
        of bitmap: NSBitmapImageRep
    ) -> Double {
        var peak = 0.0
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                peak = max(peak, Double(colour.redComponent))
            }
        }
        return peak
    }

    /// How many pixels of a rectangle are a strong amber.
    private func brightAmberPixels(
        in rows: Range<Int>,
        cols: Range<Int>,
        of bitmap: NSBitmapImageRep
    ) -> Int {
        var count = 0
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y), isBrightAmber(colour) else { continue }
                count += 1
            }
        }
        return count
    }

    /// How many pixels of a rectangle are the card's near-white ink: bright and
    /// almost colourless, which the amber of a dot is not.
    private func whitePixels(
        in rows: Range<Int>,
        cols: Range<Int>,
        of bitmap: NSBitmapImageRep
    ) -> Int {
        var count = 0
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                guard let low = channels.min(), let high = channels.max() else { continue }
                if low > 0.6 && high - low < 0.12 { count += 1 }
            }
        }
        return count
    }

    /// Writes a crop of a rendered frame, so a reviewer can look at one band of
    /// the card at the size the card drew it.
    private func writeCrop(
        _ rendered: Rendered,
        rows: Range<Int>,
        named name: String
    ) throws {
        let source = rendered.bitmap
        let lower = max(0, rows.lowerBound)
        let upper = min(source.pixelsHigh, rows.upperBound)
        let crop = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: source.pixelsWide,
                pixelsHigh: max(1, upper - lower),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            "the crop could not be allocated"
        )
        for y in lower ..< upper {
            for x in 0 ..< source.pixelsWide {
                guard let colour = source.colorAt(x: x, y: y) else { continue }
                crop.setColor(colour, atX: x, y: y - lower)
            }
        }
        try write(crop, to: Self.evidence.appendingPathComponent("\(name).png"))
    }

    /// The columns one style chip is drawn in, from the card's leading edge.
    ///
    /// The row is an `HStack` of fixed parts and one scroll view, so the first
    /// style starts one gap past the pinned Original and every style after it one
    /// gap past its neighbour. The widths come from the row's own measurement,
    /// which is the number the layout test uses, so this rect is not a copy of the
    /// view's arithmetic.
    private static func chipColumns(_ index: Int) -> Range<Int> {
        let leading = HUDTheme.padding
            + HUDRewriteLayout.versionArrowWidth
            + HUDRewriteLayout.chipGap
            + RewriteChipMetrics.chipWidth("Original")
            + HUDRewriteLayout.chipGap
        let before = RewriteStyle.builtIns.prefix(index)
        let width = before.map { RewriteChipMetrics.chipWidth($0.title) }.reduce(0, +)
        let gaps = HUDRewriteLayout.chipGap * CGFloat(index)
        let origin = leading + width + gaps
        return Int((origin * CGFloat(scale)).rounded())
            ..< Int(((origin + RewriteChipMetrics.chipWidth(
                RewriteStyle.builtIns[index].title
            )) * CGFloat(scale)).rounded())
    }

    /// The columns the pinned Original chip is drawn in.
    private static func originalChipColumns() -> Range<Int> {
        let upper = chipColumns(0).lowerBound
            - Int((HUDRewriteLayout.chipGap * CGFloat(scale)).rounded())
        return upper - Int((RewriteChipMetrics.chipWidth("Original") * CGFloat(scale)).rounded())
            ..< upper
    }

    /// The rows of the chip row, measured from the card's bottom edge.
    private static func chipRowRows(cardHeight: CGFloat) -> Range<Int> {
        let top = cardHeight - HUDTheme.verticalPadding - HUDRewriteLayout.chipHeight
        let bottom = top + HUDRewriteLayout.chipHeight
        return Int((top * CGFloat(scale)).rounded()) ..< Int((bottom * CGFloat(scale)).rounded())
    }

    /// The rows the body occupies: under the header's hairline and above
    /// everything the rewrite layer adds.
    private static func bodyRows(_ card: RewriteCard, cardHeight: CGFloat) -> Range<Int> {
        let top = HUDTheme.headerHeight + 1
        let bottom = cardHeight - HUD.rewriteExtraHeight(card)
        return pixels(top) ..< pixels(bottom)
    }

    /// One measurement in points, in the bitmap's pixels.
    private static func pixels(_ points: CGFloat) -> Int {
        Int((points * CGFloat(scale)).rounded())
    }

    /// The drawn capsule of one chip, read from the pixels rather than assumed.
    ///
    /// The row's arithmetic predicts the chip's rectangle; this is the reading it
    /// is pinned to. The capsule is a wash of white on the card's surface, so the
    /// run of columns through the chip's vertical centre that carries any ink
    /// above the bare surface is the capsule's own width, and the run of rows
    /// through its horizontal centre is its height. Starting from the middle means
    /// the gaps either side, and the neighbouring chips past them, cannot be
    /// joined onto the reading.
    ///
    /// - Parameters:
    ///   - bitmap: the rendered card.
    ///   - rows: the rows the chip row is expected to occupy.
    ///   - hint: the columns the row's own measurement predicts for this chip.
    /// - Returns: the drawn capsule's rows and columns, or `nil` when nothing is
    ///   drawn there.
    private func capsuleLandmark(
        in bitmap: NSBitmapImageRep,
        rows: Range<Int>,
        hint: Range<Int>
    ) -> (rows: Range<Int>, cols: Range<Int>)? {
        let reach = 2 * Self.scale
        let rowWindow = max(0, rows.lowerBound - reach) ..< min(bitmap.pixelsHigh, rows.upperBound + reach)
        let colWindow = max(0, hint.lowerBound - 2 * reach)
            ..< min(bitmap.pixelsWide, hint.upperBound + 2 * reach)
        // The capsule's fill is a five per cent wash of white, which is almost
        // nothing once the display curve is applied: the reading is the brightest
        // channel as drawn, against the darkest pixel of the same window.
        func brightness(_ colour: NSColor) -> Double {
            Double(max(colour.redComponent, max(colour.greenComponent, colour.blueComponent)))
        }
        var surface = 1.0
        for y in rowWindow {
            for x in colWindow {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                surface = min(surface, brightness(colour))
            }
        }
        let floor = surface + 0.015
        func lit(x: Int) -> Bool {
            for y in rowWindow {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                if brightness(colour) > floor { return true }
            }
            return false
        }
        func lit(y: Int) -> Bool {
            for x in colWindow {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                if brightness(colour) > floor { return true }
            }
            return false
        }

        let middleColumn = (hint.lowerBound + hint.upperBound) / 2
        guard middleColumn >= 0, middleColumn < bitmap.pixelsWide, lit(x: middleColumn) else {
            return nil
        }
        var left = middleColumn
        var right = middleColumn
        while left > 0, lit(x: left - 1) { left -= 1 }
        while right + 1 < bitmap.pixelsWide, lit(x: right + 1) { right += 1 }

        let middleRow = rows.lowerBound + rows.count / 2
        guard middleRow >= 0, middleRow < bitmap.pixelsHigh, lit(y: middleRow) else { return nil }
        var top = middleRow
        var bottom = middleRow
        while top > 0, lit(y: top - 1) { top -= 1 }
        while bottom + 1 < bitmap.pixelsHigh, lit(y: bottom + 1) { bottom += 1 }
        return (top ..< (bottom + 1), left ..< (right + 1))
    }

    /// How many pixels of a band of rows two frames of the same size disagree
    /// about.
    private func differingPixels(
        in rows: Range<Int>,
        _ first: NSBitmapImageRep,
        _ second: NSBitmapImageRep
    ) -> Int {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
            return rows.count * first.pixelsWide
        }
        var count = 0
        for y in rows where y >= 0 && y < first.pixelsHigh {
            for x in 0 ..< first.pixelsWide {
                guard let one = first.colorAt(x: x, y: y),
                      let two = second.colorAt(x: x, y: y) else { continue }
                let delta = abs(one.redComponent - two.redComponent)
                    + abs(one.greenComponent - two.greenComponent)
                    + abs(one.blueComponent - two.blueComponent)
                if delta > 0.01 { count += 1 }
            }
        }
        return count
    }

    /// How much ink one frame adds to a rectangle over another.
    ///
    /// A count of changed pixels saturates: the glow spreads, so a half-faded arc
    /// still touches nearly as many pixels as a full one. The summed channel
    /// difference follows the arc's opacity, which is what the fade moves.
    private func inkMass(
        in rows: Range<Int>,
        _ first: NSBitmapImageRep,
        over second: NSBitmapImageRep
    ) -> Double {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
            return .infinity
        }
        var total = 0.0
        for y in rows where y >= 0 && y < first.pixelsHigh {
            for x in 0 ..< first.pixelsWide {
                guard let one = first.colorAt(x: x, y: y),
                      let two = second.colorAt(x: x, y: y) else { continue }
                total += Double(
                    abs(one.redComponent - two.redComponent)
                        + abs(one.greenComponent - two.greenComponent)
                        + abs(one.blueComponent - two.blueComponent)
                )
            }
        }
        return total
    }

    /// How many pixels two frames of the same size disagree about.
    private func differingPixels(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Int {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
            return first.pixelsWide * first.pixelsHigh
        }
        var count = 0
        var y = 0
        while y < first.pixelsHigh {
            var x = 0
            while x < first.pixelsWide {
                if let one = first.colorAt(x: x, y: y), let two = second.colorAt(x: x, y: y) {
                    let delta = abs(one.redComponent - two.redComponent)
                        + abs(one.greenComponent - two.greenComponent)
                        + abs(one.blueComponent - two.blueComponent)
                    if delta > 0.01 { count += 1 }
                }
                x += 1
            }
            y += 1
        }
        return count
    }
}
