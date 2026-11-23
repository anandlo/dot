import AppKit
import CryptoKit
import DotCore
import SwiftUI
import XCTest
@testable import Dot

/// The shape the card pours out of the notch with, and the frames it does it on.
///
/// The geometry is pure and is measured against the display the design was drawn
/// on: 1470 by 956 points, a 32 point notch 179 points wide, and a 33 point menu
/// bar. The timing runs the HUD's own springs through the clock a test can move
/// itself, and the pictures are rendered through the product's own tree, off
/// every display, at two pixels per point.
@MainActor
final class HUDEmergenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    // MARK: - The display

    /// The display the design's numbers were taken from.
    static let notched = HUDEmergence.Screen(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923),
        safeTop: 32,
        leftArea: CGRect(x: 0, y: 924, width: 645.5, height: 32),
        rightArea: CGRect(x: 824.5, y: 924, width: 645.5, height: 32)
    )

    /// A display with no notch at all: a second screen or an external one.
    static let plain = HUDEmergence.Screen(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
        safeTop: 0,
        leftArea: nil,
        rightArea: nil
    )

    /// The same display, moved off every screen.
    ///
    /// The HUD's own placement is exercised on it, so a panel ordered front is
    /// still nowhere the window server draws.
    static let offscreenNotch = HUDEmergence.Screen(
        frame: CGRect(x: -20_000, y: -20_000, width: 1470, height: 956),
        visibleFrame: CGRect(x: -20_000, y: -20_000, width: 1470, height: 923),
        safeTop: 32,
        leftArea: CGRect(x: -20_000, y: -20_000, width: 645.5, height: 32),
        rightArea: CGRect(x: -19_175.5, y: -20_000, width: 645.5, height: 32)
    )

    /// The fixed size of the panel.
    static let panelSize = CGSize(width: 640, height: 340)
    /// The inset the card's panel used to keep below the usable frame.
    static let topInset: CGFloat = 10
    /// The room the card keeps above it for its shadow.
    static let shadowPadding: CGFloat = 28

    /// The card the strips are drawn with.
    static let recordingCard = HUDState.recordingCard.size
    /// The words the transcript card is drawn with.
    static let transcript = "Send the Q3 numbers to Priya before the standup, and copy me on the "
        + "reply so the thread stays in one place for the finance review next week."

    /// The panel's place and its notch on one display.
    ///
    /// - Parameter screen: the display.
    /// - Returns: the placement the product would compute for it.
    static func placement(_ screen: HUDEmergence.Screen) -> HUDEmergence.Placement {
        HUDEmergence.placement(
            screen: screen,
            panelSize: Self.panelSize,
            topInset: Self.topInset,
            shadowPadding: Self.shadowPadding
        )
    }

    /// The card at rest, in the shape's coordinates: y down from the screen's top.
    ///
    /// - Parameters:
    ///   - screen: the display the panel is on.
    ///   - card: the card's size.
    /// - Returns: the card's rest rectangle and radius.
    static func rest(
        _ screen: HUDEmergence.Screen,
        card: CGSize
    ) -> HUDEmergence.Rest {
        let placement = Self.placement(screen)
        let frame = HUDPlacement.cardFrame(
            panelFrame: placement.panelFrame,
            cardSize: card,
            topInset: placement.cardTopInset
        )
        let top = screen.frame.maxY - frame.maxY
        return HUDEmergence.Rest(
            rect: CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height),
            cornerRadius: HUDTheme.cornerRadius
        )
    }

    // MARK: - N1: the source

    /// The notch is the gap between the two auxiliary top areas.
    func testTheNotchSourceIsTheGapBetweenTheTopAreas() {
        let source = Self.placement(Self.notched).source
        XCTAssertEqual(source.rect.minX, 645.5, accuracy: 0.001)
        XCTAssertEqual(source.rect.width, 179, accuracy: 0.001)
        XCTAssertEqual(source.rect.height, 32, accuracy: 0.001)
        XCTAssertEqual(source.rect.minY, 0, "the notch starts at the top of the screen")
        XCTAssertEqual(source.cornerRadius, 8, accuracy: 0.001)
    }

    /// A display without a notch grows the shape out of its top edge, centred.
    func testADisplayWithoutANotchGrowsFromItsTopEdge() {
        let source = Self.placement(Self.plain).source
        XCTAssertEqual(source.rect.width, 185, accuracy: 0.001)
        XCTAssertEqual(source.rect.midX, 960, accuracy: 0.001)
        XCTAssertEqual(source.rect.height, 0, "a plain display has no hole to pour out of")
        XCTAssertEqual(source.rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(source.cornerRadius, 0)
    }

    // MARK: - N2: the card does not move

    /// The panel reaches the top of the screen and the card stays where it was.
    func testThePanelKeepsTheCardsRestRectangleOnBothDisplays() {
        for screen in [Self.notched, Self.plain] {
            let placement = Self.placement(screen)
            let card = CGSize(width: HUDState.transcriptWidth, height: 225)
            let today = HUDPlacement.cardFrame(
                panelFrame: HUDPlacement.frame(
                    visibleFrame: screen.visibleFrame,
                    panelSize: Self.panelSize,
                    topInset: Self.topInset
                ),
                cardSize: card,
                topInset: Self.shadowPadding
            )
            let now = HUDPlacement.cardFrame(
                panelFrame: placement.panelFrame,
                cardSize: card,
                topInset: placement.cardTopInset
            )
            XCTAssertEqual(now, today, "the card's rest rectangle moved on \(screen.frame)")
            XCTAssertEqual(
                placement.panelFrame.maxY,
                screen.frame.maxY,
                accuracy: 0.001,
                "the panel did not reach the top of the screen"
            )
            XCTAssertEqual(
                placement.panelFrame.height,
                Self.panelSize.height
                    + (screen.frame.maxY - screen.visibleFrame.maxY + Self.topInset),
                accuracy: 0.001,
                "the panel did not grow by the menu bar and the card's old inset"
            )
            XCTAssertEqual(
                placement.cardTopInset,
                Self.shadowPadding + (screen.frame.maxY - screen.visibleFrame.maxY + Self.topInset),
                accuracy: 0.001
            )
        }
    }

    // MARK: - N3: the shape

    /// The shape starts as the notch and ends as the card.
    func testTheShapeStartsAtTheNotchAndEndsAtTheCard() {
        for screen in [Self.notched, Self.plain] {
            let source = Self.placement(screen).source
            let rest = Self.rest(screen, card: Self.recordingCard)
            let start = HUDEmergence.shape(progress: 0, source: source, rest: rest)
            let edges: [(CGFloat, CGFloat)] = [
                (start.card.minX, source.rect.minX),
                (start.card.minY, source.rect.minY),
                (start.card.width, source.rect.width),
                (start.card.height, source.rect.height),
                (start.cornerRadius, source.cornerRadius),
            ]
            for (measured, expected) in edges {
                XCTAssertEqual(measured, expected, accuracy: 0.01, "the shape did not start at the notch")
            }
            XCTAssertNil(start.neck, "the shape starts as the notch, with no neck")
            XCTAssertEqual(start.mix, 0, accuracy: 0.0001)

            let end = HUDEmergence.shape(progress: 1, source: source, rest: rest)
            XCTAssertEqual(end.card.minX, rest.rect.minX, accuracy: 0.01)
            XCTAssertEqual(end.card.minY, rest.rect.minY, accuracy: 0.01)
            XCTAssertEqual(end.card.width, rest.rect.width, accuracy: 0.01)
            XCTAssertEqual(end.card.height, rest.rect.height, accuracy: 0.01)
            XCTAssertEqual(end.cornerRadius, HUDTheme.cornerRadius, accuracy: 0.01)
            XCTAssertNil(end.neck, "the card is pinched off the notch before it rests")
            XCTAssertEqual(end.mix, 1, accuracy: 0.0001, "the card's surface never took over")
            XCTAssertTrue(end.isRest(rest), "the shape did not arrive at the rest rectangle")
        }
    }

    /// The shape only grows: no edge ever goes back the way it came.
    func testTheShapeOnlyGrowsTowardsTheCard() {
        for screen in [Self.notched, Self.plain] {
            let source = Self.placement(screen).source
            let rest = Self.rest(screen, card: Self.recordingCard)
            var previous = HUDEmergence.shape(progress: 0, source: source, rest: rest)
            var progress = 0.0
            while progress <= 1.0001 {
                let piece = HUDEmergence.shape(progress: progress, source: source, rest: rest)
                XCTAssertGreaterThanOrEqual(
                    piece.card.width, previous.card.width - 0.0001,
                    "the card's width went backwards at e = \(progress)"
                )
                XCTAssertGreaterThanOrEqual(
                    piece.card.height, previous.card.height - 0.0001,
                    "the card's height went backwards at e = \(progress)"
                )
                XCTAssertGreaterThanOrEqual(
                    piece.card.minY, previous.card.minY - 0.0001,
                    "the card's top edge went upwards at e = \(progress)"
                )
                previous = piece
                progress += 0.001
            }
        }
    }

    /// No edge of the shape jumps between two points a thousandth apart.
    func testNoEdgeOfTheShapeJumps() {
        for screen in [Self.notched, Self.plain] {
            let source = Self.placement(screen).source
            let rest = Self.rest(screen, card: Self.transcriptSizeForTest)
            var previous = HUDEmergence.shape(progress: 0, source: source, rest: rest)
            var progress = 0.001
            while progress <= 1.0001 {
                let piece = HUDEmergence.shape(progress: progress, source: source, rest: rest)
                let edges: [(CGFloat, CGFloat, String)] = [
                    (piece.card.minX, previous.card.minX, "left"),
                    (piece.card.minY, previous.card.minY, "top"),
                    (piece.card.maxX, previous.card.maxX, "right"),
                    (piece.card.maxY, previous.card.maxY, "bottom"),
                    (piece.cornerRadius, previous.cornerRadius, "radius"),
                ]
                for (now, before, name) in edges {
                    XCTAssertLessThanOrEqual(
                        abs(now - before), 1.5,
                        "the \(name) edge moved \(abs(now - before)) points in one step at e = \(progress)"
                    )
                }
                if let waist = piece.neck?.waistWidth, let before = previous.neck?.waistWidth {
                    XCTAssertLessThanOrEqual(
                        abs(waist - before), 1.5,
                        "the waist moved \(abs(waist - before)) points in one step at e = \(progress)"
                    )
                }
                if previous.neck == nil, piece.neck != nil {
                    // The neck arrives with no height at all: its two edges are
                    // the notch's bottom edge and the card's top edge, which meet.
                    XCTAssertLessThanOrEqual(
                        piece.card.minY - source.rect.maxY, 0.6,
                        "the neck arrived with a gap of \(piece.card.minY - source.rect.maxY) points"
                    )
                }
                previous = piece
                progress += 0.001
            }
        }
    }

    /// The neck is pinched off before the card has fallen into its rest place.
    func testTheNeckIsGoneBeforeTheCardLands() {
        let source = Self.placement(Self.notched).source
        let rest = Self.rest(Self.notched, card: Self.recordingCard)
        let restGap = rest.rect.minY - source.rect.maxY
        XCTAssertEqual(restGap, 39, accuracy: 0.001, "the rest gap this display gives the design")
        var progress = 0.0
        var waist = CGFloat.greatestFiniteMagnitude
        while progress <= 1.0001 {
            let piece = HUDEmergence.shape(progress: progress, source: source, rest: rest)
            let gap = piece.card.minY - source.rect.maxY
            if gap >= 0.85 * restGap {
                XCTAssertNil(
                    piece.neck,
                    "a neck is still drawn with a gap of \(gap) points at e = \(progress)"
                )
            }
            if let neck = piece.neck {
                XCTAssertLessThanOrEqual(
                    neck.waistWidth, waist + 0.0001,
                    "the waist widened as the card fell, at e = \(progress)"
                )
                XCTAssertGreaterThanOrEqual(neck.waistWidth, 0.5)
                waist = neck.waistWidth
            }
            progress += 0.001
        }
    }

    /// No point of the outline leaves the notch and the card, or the screen.
    func testTheOutlineStaysInsideTheNotchAndTheCard() {
        for screen in [Self.notched, Self.plain] {
            let source = Self.placement(screen).source
            let rest = Self.rest(screen, card: Self.recordingCard)
            let hull = source.rect.union(rest.rect).insetBy(dx: -2, dy: -2)
            var progress = 0.0
            while progress <= 1.0001 {
                let piece = HUDEmergence.shape(progress: progress, source: source, rest: rest)
                HUDEmergence.path(piece).forEach { element in
                    for point in Self.points(of: element) {
                        XCTAssertGreaterThanOrEqual(
                            point.y, -0.001,
                            "the outline was drawn above the top of the screen at e = \(progress)"
                        )
                        XCTAssertTrue(
                            hull.contains(point) || abs(point.x - hull.minX) < 0.001,
                            "the outline left the notch and the card at e = \(progress): \(point)"
                        )
                    }
                }
                progress += 0.005
            }
        }
    }

    /// The spring's overshoot is spent on the card's own height, at its bottom.
    func testTheOvershootStretchesOnlyTheBottomEdge() {
        let source = Self.placement(Self.notched).source
        let rest = Self.rest(Self.notched, card: Self.recordingCard)
        let restPiece = HUDEmergence.shape(progress: 1, source: source, rest: rest)
        let small = HUDEmergence.shape(progress: 1.04, source: source, rest: rest)
        let large = HUDEmergence.shape(progress: 1.12, source: source, rest: rest)
        XCTAssertEqual(small.card.minY, restPiece.card.minY, accuracy: 0.001)
        XCTAssertEqual(small.card.maxY - restPiece.card.maxY, 1, accuracy: 0.001)
        XCTAssertEqual(large.card.maxY - restPiece.card.maxY, 3, accuracy: 0.001)
        XCTAssertEqual(large.card.minY, restPiece.card.minY, accuracy: 0.001)
        XCTAssertEqual(large.card.width, restPiece.card.width, accuracy: 0.001)
    }

    // MARK: - N4: the timing

    /// The card has arrived inside the spring's own budget.
    func testTheCardArrivesWithinItsBudget() {
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        defer {
            hud.hide()
            spin(for: 1.2)
        }
        hud.debugPlace(on: Self.offscreenNotch)
        hud.showRecording(elapsed: "0:00")
        hud.debugStopRenderLoop()

        var elapsed = 0.0
        var arrived: Double?
        while elapsed < 0.70 {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            elapsed += 1.0 / 240
            if arrived == nil, hud.debugEmergence >= 0.999 { arrived = elapsed }
        }
        let reached = try? XCTUnwrap(arrived)
        XCTAssertNotNil(reached, "the shape never arrived")
        XCTAssertLessThanOrEqual(
            reached ?? .infinity, 0.70,
            "the shape arrived at \(reached ?? .nan) s, past the 0.70 s the present gives it"
        )
        XCTAssertGreaterThanOrEqual(hud.debugPresence, 0.999)
        XCTAssertEqual(hud.debugPresence, min(hud.debugEmergence, 1), accuracy: 0.0001)
    }

    /// The card has gone back into the notch inside the departure's budget, and
    /// the panel is ordered out only after it has.
    func testTheCardLeavesBeforeThePanelIsOrderedOut() {
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        defer {
            hud.hide()
            spin(for: 1.2)
        }
        hud.debugPlace(on: Self.offscreenNotch)
        hud.showRecording(elapsed: "0:00")
        hud.debugStopRenderLoop()
        advance(hud, for: 0.70)
        XCTAssertTrue(hud.debugPanelVisible, "the panel was not up before the departure")
        XCTAssertGreaterThanOrEqual(hud.debugEmergence, 0.999)
        hud.hide()
        // The shape leaves on the frames, and nothing else may order the window
        // out: while no frame has drawn the card it is still in the notch, and a
        // fixed delay would take the window away underneath it.
        spin(for: 0.5)
        XCTAssertTrue(
            hud.debugPanelVisible,
            "the panel was ordered out before a frame had moved the shape"
        )
        XCTAssertGreaterThan(
            hud.debugEmergence, 0.99,
            "the shape left the notch without a frame to draw it"
        )

        var elapsed = 0.0
        var left: Double?
        var orderedOut: Double?
        var orderedOutWhileMoving = false
        while elapsed < 1.2 {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            elapsed += 1.0 / 240
            if left == nil, hud.debugEmergence <= 0.001 { left = elapsed }
            if orderedOut == nil, !hud.debugPanelVisible { orderedOut = elapsed }
            if left == nil, !hud.debugPanelVisible { orderedOutWhileMoving = true }
        }
        let went = try? XCTUnwrap(left)
        XCTAssertNotNil(went, "the shape never went back into the notch")
        XCTAssertGreaterThanOrEqual(
            hud.debugContent, 0,
            "the content was read after the card left"
        )
        XCTAssertLessThanOrEqual(
            went ?? .infinity, 0.12 + 0.70,
            "the shape took \(went ?? .nan) s to leave, past the 0.12 s content fade, the 0.45 s "
                + "departure and the settle a critically damped spring needs to reach the notch"
        )
        XCTAssertFalse(orderedOutWhileMoving, "the panel was ordered out while the shape was still there")
        let out = try? XCTUnwrap(orderedOut)
        XCTAssertNotNil(out, "the panel was never ordered out")
        XCTAssertGreaterThanOrEqual(
            out ?? 0, went ?? .infinity,
            "the panel was ordered out at \(out ?? .nan) s, before the shape had left at "
                + "\(went ?? .nan) s"
        )
        print(String(
            format: "EMERGENCE departure left at %.4f s, ordered out at %.4f s",
            went ?? .nan,
            out ?? .nan
        ))
    }

    /// The words are not drawn while the black is still coming out of the notch.
    ///
    /// One progress value gates the content, and it is not the content's own
    /// spring: the words belong to the card, and while the shape is still half
    /// way out of the notch there is nothing on it to read. The two frames below
    /// are the same moment drawn with the content settled and with it gone; they
    /// can only be the same picture if the arrival is holding the words back.
    func testTheCardShowsNoWordsBeforeItHasArrived() throws {
        try WindowCapture.requireFullMotion()
        XCTAssertEqual(HUDEmergence.contentOpacity(content: 1, progress: 0.5), 0)
        XCTAssertEqual(HUDEmergence.contentOpacity(content: 1, progress: 0.85), 0)
        XCTAssertEqual(HUDEmergence.contentOpacity(content: 1, progress: 1), 1, accuracy: 0.0001)

        let arriving = try Self.render(emergence: 0.5, content: 1, fixture: .recording, material: .black)
        let nothing = try Self.render(emergence: 0.5, content: 0, fixture: .recording, material: .black)
        XCTAssertTrue(
            Self.identical(arriving, nothing),
            "the card drew its words while the shape was only half out of the notch"
        )
        let resting = try Self.render(emergence: 1, content: 1, fixture: .recording, material: .black)
        let bare = try Self.render(emergence: 1, content: 0, fixture: .recording, material: .black)
        Self.writeCIFrame(arriving, named: "words-half-arrived")
        Self.writeCIFrame(nothing, named: "words-half-nothing")
        Self.writeCIFrame(resting, named: "words-resting")
        Self.writeCIFrame(bare, named: "words-resting-bare")
        XCTAssertFalse(
            Self.identical(resting, bare),
            "the rested card draws the same picture with and without its words, so the check is blind"
        )
    }

    /// The longer notched springs change the shape the panel draws, not just a number.
    ///
    /// At a fifth of a second the 0.65 s pour is still a narrow shape near the
    /// notch: 291 pt wide with its bottom at 111 pt. The old 0.55 s pour had
    /// already widened to 309 pt and dropped to 119 pt, so the comparator below
    /// fails on a shape, not on a duration constant. The same injected clock
    /// bounds the arrival, follows the shape all the way back before the panel
    /// is ordered out, reopens mid-retraction without a jump or a fresh start,
    /// and checks that reduced motion still draws the card at rest.
    func testNotchedSpringsKeepTheShapeAndPanelInStep() {
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        hud.debugSetReduceMotion(false)
        hud.debugPlace(on: Self.offscreenNotch)
        hud.showRecording(elapsed: "0:00")
        hud.debugStopRenderLoop()
        XCTAssertTrue(hud.debugPanelVisible, "the panel was not up for the arrival")

        // The comparator is read from the same shape the panel draws, at the
        // same frame the render loop would have reached.
        advance(hud, for: 0.20)
        let source = Self.placement(Self.notched).source
        let rest = Self.rest(Self.notched, card: Self.recordingCard)
        let piece = HUDEmergence.shape(
            progress: hud.debugEmergence, source: source, rest: rest
        )
        XCTAssertLessThan(
            piece.card.width, 300,
            "at 0.200 s the shape was \(piece.card.width) pt wide, the earlier pour's width"
        )
        XCTAssertLessThan(
            piece.card.maxY, 116,
            "at 0.200 s the shape's bottom was at \(piece.card.maxY) pt, the earlier pour's drop"
        )
        XCTAssertNotNil(piece.neck, "the shape had already left the notch at 0.200 s")
        print(String(
            format: "NOTCH comparator t=0.200 e=%.6f width=%.3f bottom=%.3f",
            hud.debugEmergence,
            piece.card.width,
            piece.card.maxY
        ))

        var arrival = 0.20
        var arrived: Double?
        while arrival < 0.70 {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            arrival += 1.0 / 240
            if arrived == nil, hud.debugEmergence >= 0.999 { arrived = arrival }
        }
        let reached = arrived ?? .infinity
        XCTAssertLessThanOrEqual(
            reached, 0.70,
            "the shape arrived at \(reached) s, past the 0.70 s the present gives it"
        )
        XCTAssertGreaterThanOrEqual(
            reached, 0.55,
            "the shape arrived at \(reached) s, too soon for the 0.65 s pour"
        )
        XCTAssertTrue(hud.debugPanelVisible, "the panel went out while the card was arriving")

        // A card reopened during the retraction keeps the value and the velocity
        // the departure had: no jump on the frame it is shown, no fresh start
        // from the notch on the frames after it.
        hud.hide()
        var retraction = 0.0
        while retraction < 0.6, hud.debugEmergence > 0.55 {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            retraction += 1.0 / 240
        }
        let held = hud.debugEmergence
        XCTAssertLessThanOrEqual(held, 0.55, "the retraction never reached a revisable shape")
        XCTAssertGreaterThan(held, 0.35, "the retraction was already inside the notch")
        XCTAssertTrue(hud.debugPanelVisible, "the panel left before the shape was back")
        hud.showRecording(elapsed: "0:01")
        hud.debugStopRenderLoop()
        XCTAssertEqual(
            hud.debugEmergence, held, accuracy: 1e-12,
            "reopening jumped the shape from \(held) to \(hud.debugEmergence)"
        )
        XCTAssertTrue(hud.debugPanelVisible, "reopening did not bring the panel back")
        var lowest = held
        for _ in 0 ..< 48 {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            lowest = min(lowest, hud.debugEmergence)
        }
        XCTAssertLessThan(lowest, held, "reopening dropped the departure's velocity")
        XCTAssertGreaterThan(
            lowest, held - 0.2,
            "reopening restarted the shape at \(lowest) instead of turning it around"
        )
        XCTAssertGreaterThan(
            hud.debugEmergence, held + 0.1,
            "the reopened shape never recovered from \(held)"
        )
        print(String(
            format: "NOTCH reopen held=%.6f lowest=%.6f after=%.6f",
            held, lowest, hud.debugEmergence
        ))

        var secondArrival = 0.0
        var secondArrived = false
        while secondArrival < 0.70 {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            secondArrival += 1.0 / 240
            if hud.debugEmergence >= 0.999 { secondArrived = true; break }
        }
        XCTAssertTrue(secondArrived, "the reopened card never settled")

        // The second departure is the one the window has to wait for. Its shape
        // reaches the notch inside the 1.0 s and 1.05 s deadlines with room to
        // spare, and the panel is not ordered out one frame before it does.
        hud.hide()
        var departed = 0.0
        var left: Double?
        var orderedOutWhileMoving = false
        while departed < 1.0 {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            departed += 1.0 / 240
            if left == nil, hud.debugEmergence <= 0.001 { left = departed }
            if left == nil, !hud.debugPanelVisible { orderedOutWhileMoving = true }
        }
        let went = left ?? .infinity
        XCTAssertGreaterThan(
            went, 0.72,
            "the shape left at \(went) s, too soon for the 0.45 s departure"
        )
        XCTAssertLessThanOrEqual(
            went, 0.82,
            "the shape took \(went) s to leave, with no room left before the deadlines"
        )
        XCTAssertLessThanOrEqual(went, 1.0 - 0.15, "no headroom before the 1.0 s deadline")
        XCTAssertLessThanOrEqual(went, 1.05 - 0.15, "no headroom before the 1.05 s deadline")
        XCTAssertFalse(orderedOutWhileMoving, "the panel was ordered out while the shape was moving")
        XCTAssertFalse(hud.debugPanelVisible, "the panel was never ordered out")
        print(String(format: "NOTCH departure left=%.6f panel_visible=%d", went, hud.debugPanelVisible))

        // Reduce motion has no shape to retime: every frame of the fade still
        // draws the card at rest.
        let reduced = HUD(offscreen: true)
        reduced.dwell = 60
        reduced.debugSetReduceMotion(true)
        reduced.debugPlace(on: Self.offscreenNotch)
        reduced.showRecording(elapsed: "0:00")
        reduced.debugStopRenderLoop()
        let restingCard = Self.rest(Self.notched, card: Self.recordingCard).rect
        var shown: Double?
        for frame in 1 ... 48 {
            reduced.debugAdvanceAppearance(by: 1.0 / 240)
            if shown == nil, reduced.debugPresence >= 0.999 { shown = Double(frame) / 240 }
            let progress = HUDEmergence.progress(reduced.debugEmergence, reduceMotion: true)
            XCTAssertEqual(progress, 1, "reduced motion moved the shape")
            XCTAssertEqual(
                HUDEmergence.shape(progress: progress, source: source, rest: rest).card,
                restingCard,
                "reduced motion moved the card off its rest rectangle"
            )
        }
        XCTAssertLessThanOrEqual(
            shown ?? .infinity, 0.20,
            "reduced motion did not finish its crossfade in within 0.20 s"
        )
        reduced.hide()
        var faded: Double?
        for frame in 1 ... 48 {
            reduced.debugAdvanceAppearance(by: 1.0 / 240)
            if faded == nil, reduced.debugPresence <= 0.001, !reduced.debugPanelVisible {
                faded = Double(frame) / 240
            }
            let progress = HUDEmergence.progress(reduced.debugEmergence, reduceMotion: true)
            XCTAssertEqual(progress, 1, "reduced motion moved the shape on the way out")
            XCTAssertEqual(
                HUDEmergence.shape(progress: progress, source: source, rest: rest).card,
                restingCard,
                "reduced motion moved the card during the fade out"
            )
        }
        XCTAssertLessThanOrEqual(
            faded ?? .infinity, 0.20,
            "reduced motion did not fade out and order the panel out within 0.20 s"
        )
    }

    // MARK: - N7: reduced motion

    /// Reduced motion keeps the card where it rests and crossfades it.
    func testReducedMotionKeepsTheCardAndCrossfadesTheOpacity() {
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        defer {
            hud.hide()
            spin(for: 1.2)
        }
        hud.debugSetReduceMotion(true)
        defer { hud.debugSetReduceMotion(nil) }
        hud.debugPlace(on: Self.offscreenNotch)
        hud.showRecording(elapsed: "0:00")
        hud.debugStopRenderLoop()

        let source = Self.placement(Self.notched).source
        let rest = Self.rest(Self.notched, card: Self.recordingCard)
        var elapsed = 0.0
        var reachedOne: Double?
        while elapsed < 0.20 {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            elapsed += 1.0 / 240
            let progress = HUDEmergence.progress(hud.debugEmergence, reduceMotion: true)
            XCTAssertEqual(progress, 1, "reduced motion moved the shape")
            let piece = HUDEmergence.shape(progress: progress, source: source, rest: rest)
            XCTAssertEqual(piece.card, rest.rect, "the card moved under reduced motion")
            if reachedOne == nil, hud.debugPresence >= 0.999 { reachedOne = elapsed }
        }
        XCTAssertNotNil(reachedOne, "the card never reached full opacity")
        XCTAssertLessThanOrEqual(
            reachedOne ?? .infinity, 0.20,
            "the card took \(reachedOne ?? .nan) s to become opaque"
        )

        hud.hide()
        var gone: Double?
        elapsed = 0.0
        while elapsed < 0.20 {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            elapsed += 1.0 / 240
            if gone == nil, hud.debugPresence <= 0.001 { gone = elapsed }
        }
        XCTAssertNotNil(gone, "the card never faded out")
        XCTAssertLessThanOrEqual(
            gone ?? .infinity, 0.20,
            "the card took \(gone ?? .nan) s to fade out"
        )
    }

    // MARK: - N8: the pointer

    /// Only the resting card takes the mouse, and only where the card is.
    func testOnlyTheRestedCardTakesTheMouse() throws {
        // Nothing is presented: the pointer's rules are the panel's, and the
        // panel is placed on a display that exists only for this test.
        let hud = HUD(offscreen: true)
        hud.debugPlace(on: Self.offscreenNotch)
        hud.debugSetEmergence(1)

        let panel = hud.debugPanel.frame
        let expected = HUDEmergence.placement(
            screen: Self.offscreenNotch,
            panelSize: Self.panelSize,
            topInset: Self.topInset,
            shadowPadding: Self.shadowPadding
        )
        XCTAssertEqual(
            panel,
            expected.panelFrame,
            "the panel is not on the frame the placement gives it"
        )
        XCTAssertEqual(panel.height, 383, accuracy: 0.001, "the panel does not reach the top of the display")
        XCTAssertEqual(panel.maxY, Self.offscreenNotch.frame.maxY, accuracy: 0.001)

        let card = hud.debugCardFrame
        XCTAssertEqual(card.size, Self.recordingCard, "the card is not the size the product draws")
        XCTAssertEqual(card.midX, panel.midX, accuracy: 0.001, "the card is not centred in the panel")
        XCTAssertEqual(
            card.maxY,
            panel.maxY - Self.shadowPadding - 43,
            accuracy: 0.001,
            "the card does not hang below the top of the display where it always did"
        )

        // Inside the panel, over the menu bar's strip, and outside the card.
        hud.debugUpdatePointer(at: CGPoint(x: panel.midX, y: panel.maxY - 10))
        XCTAssertTrue(hud.debugPanel.ignoresMouseEvents, "the menu bar's strip took the click")
        // Inside the panel, beside the card.
        hud.debugUpdatePointer(at: CGPoint(x: panel.minX + 8, y: card.midY))
        XCTAssertTrue(hud.debugPanel.ignoresMouseEvents, "the shadow margin took the click")
        // Inside the card.
        hud.debugUpdatePointer(at: CGPoint(x: card.midX, y: card.midY))
        XCTAssertFalse(hud.debugPanel.ignoresMouseEvents, "the card did not take the click")
        // Inside the card's rectangle, but before the card has arrived.
        hud.debugSetEmergence(0.5)
        hud.debugUpdatePointer(at: CGPoint(x: card.midX, y: card.midY))
        XCTAssertTrue(hud.debugPanel.ignoresMouseEvents, "a card still arriving took the click")
        hud.debugSetEmergence(0.98)
        hud.debugUpdatePointer(at: CGPoint(x: card.midX, y: card.midY))
        XCTAssertFalse(hud.debugPanel.ignoresMouseEvents, "the rested card stopped taking the click")
    }

    // MARK: - The clock

    /// Moves the HUD's appearance by `seconds`, a quarter of a millisecond at a
    /// time, the way the frame loop would.
    private func advance(_ hud: HUD, for seconds: TimeInterval) {
        var elapsed = 0.0
        while elapsed < seconds {
            hud.debugAdvanceAppearance(by: 1.0 / 240)
            elapsed += 1.0 / 240
        }
    }

    /// Spins the main run loop so timers can fire.
    private func spin(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }
}

extension HUDEmergenceTests {
    /// The transcript card's size for the words above.
    static var transcriptSizeForTest: CGSize {
        HUD.transcriptSize(text: transcript)
    }

    /// The points of one path element.
    static func points(of element: Path.Element) -> [CGPoint] {
        switch element {
        case .move(let point), .line(let point):
            return [point]
        case .quadCurve(let point, let control):
            return [point, control]
        case .curve(let point, let control1, let control2):
            return [point, control1, control2]
        case .closeSubpath:
            return []
        }
    }
}

// MARK: - The pictures

extension HUDEmergenceTests {
    /// What a rendered card shows.
    @MainActor
    enum Fixture {
        case recording
        case transcript

        var size: CGSize {
            switch self {
            case .recording: HUDState.recordingCard.size
            case .transcript: HUDEmergenceTests.transcriptSizeForTest
            }
        }
    }

    /// One frame of the card's appearance.
    struct Sample {
        let time: TimeInterval
        let emergence: Double
        let content: Double
    }

    /// The first arrival frame whose picture is final: the shape has drawn its
    /// rest rectangle and the content has finished fading in, to within half
    /// an 8-bit step.
    static func arrivalRestFrame(_ pieces: [HUDEmergence.Shape], _ samples: [Sample]) -> Int {
        let rest = Self.rest(Self.notched, card: Self.recordingCard)
        return (0 ..< samples.count).first { index in
            pieces[index].isRest(rest)
                && HUDEmergence.contentOpacity(
                    content: samples[index].content, progress: samples[index].emergence
                ) >= 1 - 0.5 / 255
        } ?? (samples.count - 1)
    }

    /// The strip the panel's top edge is rendered into, in points.
    ///
    /// It is the panel's own width, cropped to what the shape can cover: the
    /// notch, the menu bar and the card with the shadow under it.
    ///
    /// - Parameter fixture: what the card shows.
    /// - Returns: the size of the picture.
    static func canvas(_ fixture: Fixture) -> CGSize {
        CGSize(width: 640, height: fixture == .recording ? 200 : 340)
    }

    /// The pixels per point of every cached render.
    static let scale = 2

    /// One card, drawn the way the panel draws it, off every display.
    ///
    /// - Parameters:
    ///   - emergence: where the card is between the notch and its rest.
    ///   - content: how settled the content is.
    ///   - fixture: what the card shows.
    ///   - material: the card's surface.
    ///   - screen: the display whose notch it pours out of.
    ///   - desktop: what is behind the card.
    /// - Returns: the bitmap, at two pixels per point.
    static func render(
        emergence: Double,
        content: Double,
        fixture: Fixture,
        material: HUDMaterial,
        screen: HUDEmergence.Screen = notched,
        desktop: Backdrop.Desktop = .plain
    ) throws -> NSBitmapImageRep {
        let view = strip(
            emergence: emergence,
            content: content,
            fixture: fixture,
            material: material,
            screen: screen,
            desktop: desktop
        )
        return try rasterise(view, size: canvas(fixture))
    }

    /// The panel's own tree over the synthetic top of the screen.
    ///
    /// - Returns: the view the frames are drawn from.
    static func strip(
        emergence: Double,
        content: Double,
        fixture: Fixture,
        material: HUDMaterial,
        screen: HUDEmergence.Screen,
        desktop: Backdrop.Desktop
    ) -> some View {
        let placement = HUDEmergence.placement(
            screen: screen,
            panelSize: panelSize,
            topInset: topInset,
            shadowPadding: shadowPadding
        )
        let model = self.model(
            fixture: fixture,
            material: material,
            emergence: emergence,
            content: content
        )
        let notch = CGRect(
            x: placement.source.rect.minX - placement.panelFrame.minX,
            y: 0,
            width: placement.source.rect.width,
            height: placement.source.rect.height
        )
        return ZStack(alignment: .topLeading) {
            Backdrop(
                desktop: desktop,
                notch: notch,
                notchRadius: placement.source.cornerRadius,
                menuBar: screen.frame.maxY - screen.visibleFrame.maxY,
                size: canvas(fixture)
            )
            HUD.rootView(
                model: model,
                actions: HUDPreview.previewActions,
                animated: false,
                placement: placement,
                size: canvas(fixture)
            )
        }
        .frame(width: canvas(fixture).width, height: canvas(fixture).height)
        .environment(\.colorScheme, .dark)
    }

    /// The model a rendered frame reads, with every value pinned so two frames
    /// differ only by the shape.
    ///
    /// - Parameters:
    ///   - fixture: what the card shows.
    ///   - material: the card's surface.
    ///   - emergence: where the card is between the notch and its rest.
    ///   - content: how settled the content is.
    /// - Returns: the model.
    static func model(
        fixture: Fixture,
        material: HUDMaterial,
        emergence: Double,
        content: Double
    ) -> HUDModel {
        let model = HUDModel()
        model.isVisible = true
        model.material = material
        model.emergence = emergence
        model.presence = min(max(emergence, 0), 1)
        model.content = content
        model.visualizer = .stretch
        model.time = 1.5
        model.phase = 0
        model.pulse = 0.25
        model.level = 0.42
        model.ceiling = 1
        model.reveal = 1
        switch fixture {
        case .recording:
            model.mode = .recording(elapsed: "0:07")
            model.cardSize = fixture.size
        case .transcript:
            model.mode = .transcript(
                text: transcript,
                delivery: .pasted,
                elapsed: "0:07",
                destination: "Mail"
            )
            model.cardSize = fixture.size
        }
        return model
    }

    /// Rasterises a view at twice the points, off every display.
    ///
    /// - Parameters:
    ///   - view: what to draw.
    ///   - size: the size to draw it at.
    /// - Returns: the bitmap.
    static func rasterise(
        _ view: some View,
        size: CGSize,
        requiresRetinaBacking: Bool = false
    ) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .environment(\.displayScale, CGFloat(scale))
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if requiresRetinaBacking { try WindowCapture.requireRetinaBacking(window) }
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale,
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
        if let data = bitmap.bitmapData {
            memset(data, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        host.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        window.contentView = nil
        window.orderOut(nil)
        return bitmap
    }

    /// The mean absolute difference between two pictures, in levels of 255.
    ///
    /// - Parameters:
    ///   - first: one picture.
    ///   - second: the other.
    /// - Returns: the mean of the three channel differences over every pixel.
    static func mad(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Double {
        guard let a = first.bitmapData, let b = second.bitmapData,
              first.bytesPerRow == second.bytesPerRow,
              first.pixelsHigh == second.pixelsHigh
        else { return .nan }
        var sum = 0.0
        var count = 0
        for y in 0 ..< first.pixelsHigh {
            let row = y * first.bytesPerRow
            for x in 0 ..< first.pixelsWide {
                let index = row + x * 4
                sum += Double(abs(Int(a[index]) - Int(b[index])))
                    + Double(abs(Int(a[index + 1]) - Int(b[index + 1])))
                    + Double(abs(Int(a[index + 2]) - Int(b[index + 2])))
                count += 3
            }
        }
        return count == 0 ? .nan : sum / Double(count)
    }

    /// Whether two pictures are the same bytes.
    static func identical(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Bool {
        guard first.pixelsWide == second.pixelsWide,
              first.pixelsHigh == second.pixelsHigh,
              first.bytesPerRow == second.bytesPerRow,
              let a = first.bitmapData,
              let b = second.bitmapData
        else { return false }
        return memcmp(a, b, first.bytesPerRow * first.pixelsHigh) == 0
    }

    /// The SHA-256 of some bytes.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The synthetic top of the screen a frame is judged on.
///
/// It is what the card is seen against: a dark desktop, the menu bar over it and
/// the display's notch cut out at the top. A frame at the start of the emergence
/// is this picture and nothing else, which is the property that makes the shape
/// pour out of the screen rather than fade in front of it.
struct Backdrop: View {
    /// What the person is working on.
    enum Desktop {
        /// The flat desktop the black frames are drawn on.
        case plain
        /// The reference photograph's blue wave, which the glass samples.
        case wave
    }

    /// What is behind the card.
    var desktop: Desktop
    /// The notch, in points from the top left of the picture.
    var notch: CGRect
    /// The radius of the notch's bottom corners.
    var notchRadius: CGFloat
    /// The height of the menu bar, in points.
    var menuBar: CGFloat
    /// The size of the picture.
    var size: CGSize

    /// The desktop's own colour.
    static let desktopColour = Color(red: 0x2b / 255, green: 0x2f / 255, blue: 0x3a / 255)
    /// The menu bar's colour, drawn over the desktop.
    static let menuBarColour = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
    /// The crop of the reference photograph the glass suite measures it on.
    static let waveCrop = CGRect(x: 0, y: 520, width: 560, height: 460)
    /// The reference photograph.
    static let waveURL = URL(fileURLWithPath: "/tmp/dot-ref-glass.png")

    var body: some View {
        ZStack(alignment: .topLeading) {
            ground
                .frame(width: size.width, height: size.height)
                .clipped()
            Self.menuBarColour
                .opacity(0.9)
                .frame(width: size.width, height: menuBar)
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: notchRadius,
                bottomTrailingRadius: notchRadius,
                topTrailingRadius: 0,
                style: .circular
            )
            .fill(Color(red: 0, green: 0, blue: 0))
            .frame(width: notch.width, height: notch.height)
            .offset(x: notch.minX, y: notch.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var ground: some View {
        switch desktop {
        case .plain:
            Self.desktopColour
        case .wave:
            if let image = Self.wave {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Self.desktopColour
            }
        }
    }

    /// The reference photograph's blue wave, read as pixels.
    static var wave: CGImage? {
        guard let image = NSImage(contentsOf: waveURL) else { return nil }
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let crop = cgImage.cropping(to: waveCrop)
        else { return nil }
        return crop
    }
}

// MARK: - N5: the frames

extension HUDEmergenceTests {
    /// The card's own appearance, sixteen milliseconds at a time.
    ///
    /// The HUD's own springs are moved through the clock a test can carry, so a
    /// frame is the value the product had at that moment rather than whatever a
    /// loaded machine delivered.
    ///
    /// - Parameter presenting: whether the card is arriving or leaving.
    /// - Returns: one sample for the start of the sequence and one per step.
    func timeline(presenting: Bool) -> [Sample] {
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        // The card pours out of the display's notch, so it is placed on one: the
        // appearance this records is the one the product draws, not the fade a
        // card with no display behind it falls back to.
        hud.debugPlace(on: Self.offscreenNotch)
        hud.showRecording(elapsed: "0:00")
        hud.debugStopRenderLoop()
        if !presenting {
            advance(hud, for: 0.70)
            hud.hide()
        }
        var samples = [Sample(time: 0, emergence: hud.debugEmergence, content: hud.debugContent)]
        var elapsed = 0.0
        // The departure is the longer of the two: its 0.45 s spring starts
        // after the 0.12 s content fade and reaches the notch near 0.75 s.
        let length = presenting ? 0.70 : 0.90
        while elapsed < length - 1e-9 {
            hud.debugAdvanceAppearance(by: 0.016)
            elapsed += 0.016
            samples.append(Sample(time: elapsed, emergence: hud.debugEmergence, content: hud.debugContent))
        }
        hud.hide()
        return samples
    }

    /// The frames of one sequence, the shape that drew each of them, and the
    /// change between each pair.
    ///
    /// - Parameter presenting: whether the card is arriving or leaving.
    /// - Returns: the frames, the shapes, the samples and one diff per pair.
    private func motionFrames(
        presenting: Bool
    ) throws -> (
        frames: [NSBitmapImageRep],
        pieces: [HUDEmergence.Shape],
        samples: [Sample],
        diffs: [Double]
    ) {
        let samples = timeline(presenting: presenting)
        let frames = try samples.map { sample in
            try Self.render(
                emergence: sample.emergence,
                content: sample.content,
                fixture: .recording,
                material: .black
            )
        }
        let source = Self.placement(Self.notched).source
        let rest = Self.rest(Self.notched, card: Self.recordingCard)
        let pieces = samples.map {
            HUDEmergence.shape(progress: $0.emergence, source: source, rest: rest)
        }
        var diffs: [Double] = []
        for index in 1 ..< frames.count {
            diffs.append(Self.mad(frames[index - 1], frames[index]))
        }
        return (frames, pieces, samples, diffs)
    }

    /// Every frame of the arrival moves, and none of them jumps.
    func testEveryFrameOfTheArrivalMoves() throws {
        try WindowCapture.requireFullMotion()
        let motion = try motionFrames(presenting: true)
        let restFrame = Self.arrivalRestFrame(motion.pieces, motion.samples)
        if Self.ciEvidence != nil {
            for (index, frame) in motion.frames.enumerated() {
                Self.writeCIFrame(frame, named: String(format: "arrival-%02d", index))
            }
            Self.writeCIFrame(motion.frames[restFrame], named: "arrival-rest")
            Self.describe(motion.frames[min(1, motion.frames.count - 1)], as: "arrival-01")
            Self.describe(motion.frames[restFrame], as: "arrival-rest")
        }
        try assertTheMotion(
            frames: motion.frames,
            pieces: motion.pieces,
            samples: motion.samples,
            diffs: motion.diffs,
            resting: 1,
            sequence: "arrival"
        )
    }

    /// Every frame of the departure moves, and none of them jumps.
    func testEveryFrameOfTheDepartureMoves() throws {
        try WindowCapture.requireFullMotion()
        let motion = try motionFrames(presenting: false)
        try assertTheMotion(
            frames: motion.frames,
            pieces: motion.pieces,
            samples: motion.samples,
            diffs: motion.diffs,
            resting: 0,
            sequence: "departure"
        )
    }

    /// The motion of one sequence, measured on its pictures.
    ///
    /// At twice the points the pixel diff is dominated by the blurred shadow and
    /// by fractional edge crossings: the shape-only render spikes to 0.17277
    /// while the frames around it change by 0.02595 and 0.00784, even though the
    /// geometry moves only 0.132 pt between 0.235 and 0.073. The neighbour rule
    /// is therefore applied to the shape's travel, where a jump is the motion
    /// itself; the pixel diff is still checked for stalls and printed as a
    /// diagnostic.
    ///
    /// - Parameters:
    ///   - frames: the pictures, in order.
    ///   - pieces: the shape each picture was drawn from.
    ///   - samples: the emergence each picture was drawn at.
    ///   - diffs: the mean absolute pixel difference of each pair.
    ///   - resting: the emergence the spring is heading for.
    ///   - sequence: the name of the sequence, for the failure.
    private func assertTheMotion(
        frames: [NSBitmapImageRep],
        pieces: [HUDEmergence.Shape],
        samples: [Sample],
        diffs: [Double],
        resting: Double,
        sequence: String
    ) throws {
        XCTAssertEqual(frames.count, pieces.count)
        XCTAssertEqual(frames.count, samples.count)
        XCTAssertEqual(diffs.count, frames.count - 1)
        XCTAssertGreaterThanOrEqual(diffs.count, 3, "the sequence is too short to judge")

        let travels = (0 ..< diffs.count).map {
            Self.travel(pieces[$0], pieces[$0 + 1])
        }

        // No picture goes nowhere: every pair the shape moves is a pair of
        // different pictures.
        for index in 0 ..< diffs.count where travels[index] >= 0.1 {
            if diffs[index] == 0 {
                XCTFail(
                    "\(sequence): the shape moved \(travels[index]) points between frames \(index) "
                        + "and \(index + 1) and the picture did not change"
                )
            }
        }

        // (a) No frame steps away from its neighbours: what travels more than
        // twice as far as the motion either side of it is a jump, not a spring.
        var worstTravel = 0.0
        var worstTravelTime = 0.0
        for index in 1 ..< (travels.count - 1) where travels[index] >= 0.1 {
            let neighbours = (travels[index - 1] + travels[index + 1]) / 2
            let ratio = neighbours > 0 ? travels[index] / neighbours : .infinity
            if ratio > worstTravel {
                worstTravel = ratio
                worstTravelTime = Double(index + 1) * 0.016
            }
            XCTAssertLessThanOrEqual(
                travels[index],
                2.5 * neighbours,
                String(
                    format: "\(sequence): the shape at %.3f s travelled %.3f pt, %.2f times the "
                        + "mean of its neighbours (%.3f and %.3f)",
                    Double(index + 1) * 0.016,
                    Double(travels[index]),
                    ratio,
                    Double(travels[index - 1]),
                    Double(travels[index + 1])
                )
            )
        }

        // (b) The motion never stops between the first frame that moved and the
        // frame the spring reaches its rest.
        // The spring keeps changing after the shape has already drawn its rest
        // rectangle: its last fractions of a percent move no edge by a pixel.
        // For the arrival the end of the visible motion is the shape's rest,
        // not the spring's numeric tolerance. The departure has no such tail:
        // its shape reaches the notch only when the spring gets there.
        let restFrame: Int
        if resting == 1 {
            restFrame = Self.arrivalRestFrame(pieces, samples)
        } else {
            restFrame = samples.firstIndex { abs($0.emergence - resting) <= 0.001 }
                ?? (samples.count - 1)
        }
        let moving = (0 ..< diffs.count).first { diffs[$0] > 0 } ?? 0
        XCTAssertGreaterThan(restFrame, moving, "\(sequence): the picture never moved before its rest")
        var stalls = 0
        // diffs[index] is the change into frame `index + 1`, so the frames
        // between the first that moved and the rest frame are indices
        // `moving ..< restFrame - 1`.
        for index in moving ..< max(moving, restFrame - 1) where diffs[index] == 0 {
            stalls += 1
            XCTFail(String(
                format: "\(sequence): the picture stopped moving at %.3f s, before the spring "
                    + "reached its rest at %.3f s",
                Double(index + 1) * 0.016,
                Double(restFrame) * 0.016
            ))
        }

        // The pixel series is a diagnostic: its median, its largest change and
        // its own worst neighbour ratio say what the pictures did, even though
        // the rasterisation makes that ratio unfit to judge the motion by.
        var worst = 0.0
        var worstTime = 0.0
        for index in 1 ..< (diffs.count - 1) where diffs[index] > 0.01 {
            let neighbours = (diffs[index - 1] + diffs[index + 1]) / 2
            let ratio = neighbours > 0 ? diffs[index] / neighbours : .infinity
            if ratio > worst {
                worst = ratio
                worstTime = Double(index + 1) * 0.016
            }
        }
        let nonZero = diffs.filter { $0 > 0 }
        let sorted = nonZero.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let largest = nonZero.max() ?? 0
        print(String(
            format: "EMERGENCE %@ %d frames, %d stalls, travel worst neighbour %.2fx at %.3f s, "
                + "pixel median %.4f, max %.4f, worst neighbour %.2fx at %.3f s, rest at %.3f s",
            sequence,
            frames.count,
            stalls,
            worstTravel,
            worstTravelTime,
            median,
            largest,
            worst,
            worstTime,
            Double(restFrame) * 0.016
        ))
        for (index, difference) in diffs.enumerated() {
            print(String(
                format: "EMERGENCE %@ %02d t %.3f top %.4f travel %.3f diff %.4f",
                sequence,
                index + 1,
                Double(index + 1) * 0.016,
                pieces[index + 1].card.minY,
                Double(travels[index]),
                difference
            ))
        }
        XCTAssertGreaterThan(largest, 0, "the \(sequence) never changed the picture")
        XCTAssertEqual(stalls, 0, "the \(sequence) stalled \(stalls) times before its rest")
    }

    /// The furthest any edge of the shape travels between two frames.
    ///
    /// - Parameters:
    ///   - first: one frame.
    ///   - second: the next.
    /// - Returns: the largest change of any edge, in points.
    static func travel(_ first: HUDEmergence.Shape, _ second: HUDEmergence.Shape) -> CGFloat {
        var travel = max(
            abs(second.card.minX - first.card.minX),
            abs(second.card.minY - first.card.minY)
        )
        travel = max(travel, abs(second.card.maxX - first.card.maxX))
        travel = max(travel, abs(second.card.maxY - first.card.maxY))
        travel = max(travel, abs(second.cornerRadius - first.cornerRadius))
        return travel
    }

    // MARK: - N6: the rested card

    /// The card at rest is the card the product always drew, byte for byte.
    ///
    /// The card is drawn on its own at twice the points, with no shadow, so the
    /// bytes are the card's own surface and content. The two hashes were measured
    /// on the tree before the emergence existed, from the same view at the same
    /// size; a single pixel of difference in the clip, the surface or the
    /// content would change them.
    func testTheRestedCardsAreThePixelsTheCardAlwaysDrew() throws {
        let recording = Self.hash(try Self.cardPicture(fixture: .recording))
        let transcript = Self.hash(try Self.cardPicture(fixture: .transcript))
        if Self.ciEvidence != nil {
            let recordingCard = try Self.rasterise(Self.cardView(fixture: .recording), size: Fixture.recording.size)
            let transcriptCard = try Self.rasterise(Self.cardView(fixture: .transcript), size: Fixture.transcript.size)
            Self.writeCIFrame(recordingCard, named: "rested-recording")
            Self.writeCIFrame(transcriptCard, named: "rested-transcript")
            Self.describe(recordingCard, as: "rested-recording")
            Self.describe(transcriptCard, as: "rested-transcript")
        }
        print("REST recording \(recording)")
        print("REST transcript \(transcript)")
        XCTAssertEqual(
            recording,
            Self.baseRecordingHash,
            "the rested recording card is not the picture the tree before the emergence drew"
        )
        XCTAssertEqual(
            transcript,
            Self.baseTranscriptHash,
            "the rested transcript card is not the picture the tree before the emergence drew"
        )
    }

    /// The rested card alone, drawn the way the card draws it, at twice the
    /// points.
    ///
    /// - Parameter fixture: what the card shows.
    /// - Returns: the card's PNG bytes.
    static func cardPicture(fixture: Fixture) throws -> Data {
        png(try rasterise(cardView(fixture: fixture), size: fixture.size, requiresRetinaBacking: true))
    }

    /// The rested card's own view, at the size it rests at.
    static func cardView(fixture: Fixture) -> some View {
        let model = model(fixture: fixture, material: .black, emergence: 1, content: 1)
        let size = fixture.size
        return HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions,
            emergence: placement(notched).scene
        )
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - The evidence

extension HUDEmergenceTests {
    /// The SHA-256 of the rested recording card, measured on the tree before the
    /// emergence existed and re-measured when the typeface and the secondary text tone changed.
    static let baseRecordingHash = "6ffda7a632056d3ac915f109583b87aca123db933e04c88b96a5bf9e64e7533a"
    /// The SHA-256 of the rested transcript card, measured on the tree before the
    /// emergence existed and re-measured when the typeface and the secondary text tone changed.
    static let baseTranscriptHash = "ec7429b8f2d9e2e627936397df0d5ecf09008c3fc7011045a587955df4b9fe54"

    /// The moments the strips are written at, in seconds.
    static let stripTimes: [Double] = [0, 0.064, 0.128, 0.192, 0.256, 0.320, 0.400, 0.480, 0.560, 0.650]

    /// The moments the glass frames are written at, in seconds.
    static let glassTimes: [Double] = [0, 0.160, 0.320, 0.480, 0.650]

    /// Draws the frames the motion is judged on, when the run asks for them.
    ///
    /// Every picture is written at two pixels per point into
    /// `DOT_NOTCH_EVIDENCE`, beside the numbers the frames were drawn from.
    func testTheEvidenceFrames() throws {
        guard let directory = ProcessInfo.processInfo.environment["DOT_NOTCH_EVIDENCE"],
              !directory.isEmpty
        else {
            throw XCTSkip("DOT_NOTCH_EVIDENCE is not set")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let present = timeline(presenting: true)
        let dismiss = timeline(presenting: false)
        for (name, samples) in [("present", present), ("dismiss", dismiss)] {
            var frames: [NSBitmapImageRep] = []
            for time in Self.stripTimes {
                let sample = Self.nearest(samples, to: time)
                let bitmap = try Self.render(
                    emergence: sample.emergence,
                    content: sample.content,
                    fixture: .recording,
                    material: .black
                )
                let stem = String(format: "%@-black-t%03d", name, Int((time * 1000).rounded()))
                try Self.write(Self.png(bitmap), to: root.appendingPathComponent("\(stem).png"))
                frames.append(bitmap)
            }
            let strip = try XCTUnwrap(
                Self.stacked(frames),
                "the \(name) frames could not be stacked"
            )
            try Self.write(
                Self.png(NSBitmapImageRep(cgImage: strip)),
                to: root.appendingPathComponent("\(name)-strip-black.png")
            )
        }

        var glass: [WindowCapture.Pixels] = []
        for time in Self.glassTimes {
            let sample = Self.nearest(present, to: time)
            let view = Self.strip(
                emergence: sample.emergence,
                content: sample.content,
                fixture: .recording,
                material: .glass,
                screen: Self.notched,
                desktop: .wave
            )
            let window = WindowCapture.show(view, size: Self.canvas(.recording))
            defer { WindowCapture.hide(window) }
            let picture = try XCTUnwrap(
                WindowCapture.capture(window),
                "the window server returned no picture of the window"
            )
            try WindowCapture.requireUsableCapture(picture)
            let stem = String(format: "present-glass-t%03d", Int((time * 1000).rounded()))
            XCTAssertTrue(
                WindowCapture.write(picture, to: root.appendingPathComponent("\(stem).png")),
                "\(stem) was not written"
            )
            glass.append(picture)
        }
        if let image = Self.stacked(glass) {
            Self.writeImage(image, to: root.appendingPathComponent("present-strip-glass.png"))
        } else {
            XCTFail("the glass frames could not be stacked")
        }

        let csv = Self.csv(present: present, dismiss: dismiss)
        try csv.write(
            to: root.appendingPathComponent("emergence.csv"),
            atomically: true,
            encoding: .utf8
        )

        let recording = try Self.cardPicture(fixture: .recording)
        let transcript = try Self.cardPicture(fixture: .transcript)
        try Self.write(recording, to: root.appendingPathComponent("rest-recording.png"))
        try Self.write(transcript, to: root.appendingPathComponent("rest-transcript.png"))
        let shas = [
            "rest-recording.png \(Self.hash(recording))",
            "rest-transcript.png \(Self.hash(transcript))",
            "base-rest-recording.png \(Self.fileHash(root.appendingPathComponent("base-rest-recording.png")))",
            "base-rest-transcript.png \(Self.fileHash(root.appendingPathComponent("base-rest-transcript.png")))",
        ].joined(separator: "\n") + "\n"
        try shas.write(
            to: root.appendingPathComponent("rest-sha256.txt"),
            atomically: true,
            encoding: .utf8
        )
        print(shas)
    }

    /// The sample nearest a moment.
    static func nearest(_ samples: [Sample], to time: TimeInterval) -> Sample {
        samples.min { abs($0.time - time) < abs($1.time - time) } ?? Sample(
            time: time,
            emergence: 1,
            content: 1
        )
    }

    /// The shape's numbers for every sample, as a table.
    ///
    /// - Parameters:
    ///   - present: the arrival.
    ///   - dismiss: the departure.
    /// - Returns: the CSV.
    static func csv(present: [Sample], dismiss: [Sample]) -> String {
        let source = placement(notched).source
        let rest = rest(notched, card: recordingCard)
        var rows = ["sequence,t,e,hp,wp,dp,card_x,card_y,card_w,card_h,radius,neck_w,mix,content"]
        for (name, samples) in [("present", present), ("dismiss", dismiss)] {
            for sample in samples {
                let steps = HUDEmergence.steps(progress: sample.emergence)
                let piece = HUDEmergence.shape(
                    progress: sample.emergence,
                    source: source,
                    rest: rest
                )
                let content = HUDEmergence.contentOpacity(
                    content: sample.content,
                    progress: sample.emergence
                )
                rows.append(String(
                    format: "%@,%.3f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.6f,%.6f",
                    name,
                    sample.time,
                    sample.emergence,
                    steps.height,
                    steps.width,
                    steps.drop,
                    piece.card.minX,
                    piece.card.minY,
                    piece.card.width,
                    piece.card.height,
                    piece.cornerRadius,
                    piece.neck?.waistWidth ?? 0,
                    piece.mix,
                    content
                ))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// One bitmap's PNG bytes.
    static func png(_ bitmap: NSBitmapImageRep) -> Data {
        bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    /// Writes bytes, creating the directory if it is missing.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Writes an image as a PNG.
    static func writeImage(_ image: CGImage, to url: URL) {
        writePNG(NSBitmapImageRep(cgImage: image), to: url)
    }

    /// Where a CI run puts the pictures it judged, when it asks for them.
    ///
    /// The runner's own raster is the only picture of a failure there is: the
    /// frames cannot be reproduced on another machine, so a failing run writes
    /// what it measured for the person reading the log.
    static var ciEvidence: URL? {
        ProcessInfo.processInfo.environment["DOT_CI_EVIDENCE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Writes a frame into the CI evidence directory, when one is asked for.
    static func writeCIFrame(_ bitmap: NSBitmapImageRep, named name: String) {
        guard let directory = ciEvidence else { return }
        writePNG(bitmap, to: directory.appendingPathComponent("\(name).png"))
    }

    /// One line saying what a frame's picture is: its size, its darkest and
    /// brightest channel value, and the SHA-256 of its PNG.
    ///
    /// The hash is what the pinned pictures are compared by, and the range says
    /// whether anything was drawn at all, which a byte-identical sequence of
    /// frames leaves in doubt.
    static func describe(_ bitmap: NSBitmapImageRep, as name: String) {
        var low = 255
        var high = 0
        if let data = bitmap.bitmapData, bitmap.samplesPerPixel >= 3 {
            for y in 0 ..< bitmap.pixelsHigh {
                let row = y * bitmap.bytesPerRow
                for x in 0 ..< bitmap.pixelsWide {
                    let index = row + x * bitmap.samplesPerPixel
                    for channel in 0 ..< 3 {
                        let value = Int(data[index + channel])
                        low = min(low, value)
                        high = max(high, value)
                    }
                }
            }
        }
        print(String(
            format: "EMERGENCE frame %@ %dx%d px, channels %d to %d, sha256 %@",
            name,
            bitmap.pixelsWide,
            bitmap.pixelsHigh,
            low,
            high,
            hash(png(bitmap))
        ))
    }

    /// Writes a bitmap as a PNG.
    static func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) {
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The SHA-256 of a file, or `missing`.
    static func fileHash(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "missing" }
        return hash(data)
    }

    /// Frames stacked from the top down, with a thin gap between them.
    static func stacked(_ frames: [NSBitmapImageRep]) -> CGImage? {
        stacked(frames.compactMap(\.cgImage), width: frames.first?.pixelsWide ?? 0)
    }

    /// Pictures stacked from the top down, with a thin gap between them.
    static func stacked(_ pictures: [WindowCapture.Pixels]) -> CGImage? {
        stacked(pictures.compactMap(WindowCapture.image), width: pictures.first?.width ?? 0)
    }

    private static func stacked(_ images: [CGImage], width: Int) -> CGImage? {
        guard let first = images.first, width > 0 else { return nil }
        let height = first.height
        let gap = 8
        let total = height * images.count + gap * max(0, images.count - 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: total,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: total))
        for (index, image) in images.enumerated() {
            let y = total - (index + 1) * height - index * gap
            context.draw(image, in: CGRect(x: 0, y: y, width: width, height: height))
        }
        return context.makeImage()
    }
}
