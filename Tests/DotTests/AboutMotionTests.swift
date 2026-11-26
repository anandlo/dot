import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Dot

/// The About plate's motion is one pure function, so its limits are checked
/// here rather than left to a strip nobody measures.
///
/// Every value the matrix draws comes from ``AboutMotion/presentation(input:plateSize:)``:
/// a render and the live page hand it the same input. These tests pin the
/// entrance's starting values, the settled frame, the pointer patch and its
/// exit, the row fades, the checking fronts, the pause predicate and the spring
/// the live view and the clip renderer share.
@MainActor
final class AboutMotionTests: XCTestCase {
    private let plateSize = CGSize(width: 565, height: 118)

    // MARK: The clock and the spring

    /// A settled held patch is static; a travelling spring keeps the leaf
    /// alive until its deadline.
    func testTheClockStopsOnASettledHeldPatchAndRunsOnATravellingOne() {
        let point = CGPoint(x: 100, y: 20)
        let settled = AboutMotionClock(pointer: AboutPointerTimeline(point: point, at: 0))
        XCTAssertTrue(settled.isSettled(at: 1000), "a settled patch kept the clock")
        XCTAssertLessThanOrEqual(settled.settleDeadline() ?? 0, 1000)

        var travelling = AboutPointerTimeline(point: point, at: 0)
        travelling.retarget(to: CGPoint(x: 400, y: 20), at: 0)
        let moving = AboutMotionClock(pointer: travelling)
        XCTAssertFalse(moving.isSettled(at: 100), "spring travel was called settled")
        let deadline = try? XCTUnwrap(moving.settleDeadline())
        if let deadline {
            XCTAssertFalse(moving.isSettled(at: deadline - 1), "the deadline is early")
            XCTAssertTrue(moving.isSettled(at: deadline), "the deadline is late")
        }
    }

    /// The closed form at a time agrees with stepping, and the settle time
    /// lands inside both thresholds.
    func testTheSpringValueAtATimeMatchesStepping() {
        let spring = AboutSpring(response: 0.23, dampingFraction: 0.90)
        var position = 0.0
        var velocity = 0.0
        let dt = 1.0 / 240.0
        for _ in 0..<240 {
            let next = spring.step(position: position, velocity: velocity, target: 1, dt: dt)
            position = next.position
            velocity = next.velocity
        }
        XCTAssertEqual(
            spring.value(at: 1, position: 0, velocity: 0, target: 1),
            position,
            accuracy: 0.001,
            "one closed-form step disagrees with 240"
        )
        let settle = spring.settleTime(position: 0, velocity: 0, target: 400)
        XCTAssertEqual(
            spring.value(at: settle, position: 0, velocity: 0, target: 400),
            400,
            accuracy: 0.25,
            "the settle time left position error"
        )
        XCTAssertLessThan(
            abs(spring.velocity(at: settle, position: 0, velocity: 0, target: 400)),
            1,
            "the settle time left velocity"
        )
    }

    /// Re-entering during the exit continues the presented centre and ramps
    /// the amplitude back up instead of jumping to full strength.
    func testAReentryDuringTheExitRampsFromThePresentedAmplitude() {
        var pointer = AboutPointerTimeline(point: CGPoint(x: 100, y: 20), at: 0)
        pointer.retarget(to: CGPoint(x: 400, y: 20), at: 0)
        pointer.exit(at: 200)
        let faded = pointer.amplitude(at: 260)
        XCTAssertEqual(faded, 1 - 60.0 / 180.0, accuracy: 0.001, "the fade is not linear")
        let centre = pointer.sprung(at: 260).position
        pointer.retarget(to: CGPoint(x: 200, y: 60), at: 260)
        XCTAssertEqual(pointer.amplitude(at: 260), faded, accuracy: 0.001, "re-entry jumped")
        XCTAssertEqual(pointer.sprung(at: 260).position.x, centre.x, accuracy: 0.001)
        XCTAssertEqual(pointer.sprung(at: 260).position.y, centre.y, accuracy: 0.001)
        XCTAssertGreaterThan(pointer.amplitude(at: 300), faded, "the amplitude did not ramp up")
        XCTAssertFalse(pointer.isSettled(at: 300), "the ramp was called settled")
    }

    /// A move during the exit or during the ramp back up keeps the presented
    /// strength: a retarget may not make the patch brighter than it was a
    /// millisecond earlier.
    func testAMoveDuringTheAmplitudeRampKeepsTheCurrentStrength() {
        var pointer = AboutPointerTimeline(point: CGPoint(x: 100, y: 20), at: 0)
        pointer.exit(at: 100)
        let faded = pointer.amplitude(at: 190)
        XCTAssertEqual(faded, 0.5, accuracy: 0.001, "the fade is not half over at 90 ms")
        pointer.retarget(to: CGPoint(x: 300, y: 40), at: 190)
        XCTAssertEqual(pointer.amplitude(at: 190), faded, accuracy: 0.001, "the move flashed the patch")
        XCTAssertEqual(pointer.amplitude(at: 191), faded, accuracy: 0.01, "the move jumped")
        XCTAssertGreaterThan(pointer.amplitude(at: 280), faded, "the ramp did not continue")

        let mid = pointer.amplitude(at: 280)
        pointer.retarget(to: CGPoint(x: 200, y: 60), at: 280)
        XCTAssertEqual(pointer.amplitude(at: 280), mid, accuracy: 0.001, "the second move flashed")
    }

    /// A move during an amplitude ramp keeps the ramp's original end time; it
    /// does not restart the 180 ms.
    func testARetargetDuringTheAmplitudeRampKeepsItsEndTime() {
        var pointer = AboutPointerTimeline(point: .zero, at: 0)
        pointer.exit(at: 0)
        XCTAssertEqual(pointer.amplitude(at: 90), 0.5, accuracy: 0.001, "the fade is not half over")
        // The re-entry at 90 ms starts a ramp that ends at 270 ms.
        pointer.retarget(to: CGPoint(x: 100, y: 0), at: 90)
        // A second move 45 ms later must not move the end.
        pointer.retarget(to: CGPoint(x: 200, y: 0), at: 135)
        XCTAssertEqual(pointer.amplitude(at: 269), 1, accuracy: 0.01, "the ramp was restarted")
        XCTAssertEqual(pointer.amplitude(at: 270), 1, accuracy: 0.0001, "the ramp did not finish")
        XCTAssertEqual(pointer.amplitude(at: 315), 1, accuracy: 0.0001, "the ramp overshot its end")
    }

    /// Two axes each inside the position threshold can still be outside the
    /// radial one; the deadline has to give that state a non-zero wake.
    func testADiagonalRetargetFromRestGetsANonZeroDeadline() {
        var pointer = AboutPointerTimeline(point: .zero, at: 0)
        pointer.retarget(to: CGPoint(x: 0.2, y: 0.2), at: 100)
        XCTAssertFalse(pointer.isSettled(at: 100), "a 0.28 point diagonal is settled")
        let deadline = pointer.settleDeadline()
        XCTAssertGreaterThan(deadline, 100, "the diagonal retarget has no deadline")
        XCTAssertTrue(pointer.isSettled(at: deadline), "the deadline is early")
    }

    /// The renderer multiplies the front energy by the failure fade, so a
    /// failure ends when the earlier of the front's life and the fade ends.
    func testAFailureEndsWhenTheFrontsOrTheFadeEnds() {
        let at = 1000.0
        let expired = AboutUpdateTimeline.unreachable(at: at, frontsElapsed: 540)
        XCTAssertEqual(expired.settleDeadline(), at, "an expired-front failure extended the clock")
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(update: .unreachable(elapsed: 0, frontsElapsed: 540))),
            "an expired-front failure is not settled"
        )

        // A front 250 ms in has 290 ms left, but the fade is over at 120, so
        // the visible end is the fade's.
        let alive = AboutUpdateTimeline.unreachable(at: at, frontsElapsed: 250)
        XCTAssertEqual(alive.settleDeadline(), at + 120, "the fade did not end the failure")
        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(update: .unreachable(elapsed: 0, frontsElapsed: 250))),
            "a live front's failure fade is settled at once"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(update: .unreachable(elapsed: 119, frontsElapsed: 250))),
            "the fade ended early"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(update: .unreachable(elapsed: 120, frontsElapsed: 250))),
            "the fade kept the clock"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(update: .unreachable(elapsed: 290, frontsElapsed: 250))),
            "a settled failure woke again at the front's old end"
        )

        // A front 500 ms in has only 40 ms left, so the front ends first.
        let short = AboutUpdateTimeline.unreachable(at: at, frontsElapsed: 500)
        XCTAssertEqual(short.settleDeadline(), at + 40, "the front's own end was missed")
        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(update: .unreachable(elapsed: 39, frontsElapsed: 500))),
            "the short front ended early"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(update: .unreachable(elapsed: 40, frontsElapsed: 500))),
            "the short front kept the clock"
        )

        let none = AboutUpdateTimeline.unreachable(at: at, frontsElapsed: nil)
        XCTAssertEqual(none.settleDeadline(), at, "a failure with no check extended the clock")
    }

    /// Keyboard intent wins until the pointer moves.
    func testTheRowArbiterGivesKeyboardIntentUntilThePointerMoves() {
        XCTAssertEqual(
            AboutRowArbiter.activeRow(lastInput: .keyboard, hovered: 0, focused: 1),
            1,
            "a resting pointer beat the keyboard"
        )
        XCTAssertEqual(
            AboutRowArbiter.activeRow(lastInput: .pointer, hovered: 0, focused: 1),
            0,
            "a moved pointer did not beat the keyboard"
        )
        XCTAssertNil(AboutRowArbiter.activeRow(lastInput: .keyboard, hovered: 0, focused: nil))
    }

    // MARK: The lattice

    /// The lattice covers the whole plate, and its colophon text is a
    /// knockout too.
    func testTheLatticeCoversTheWholePlateAndTheColophonText() {
        let points = AboutMotion.Matrix.lattice(plateSize: plateSize)
        XCTAssertEqual(points.count, 70 * 14, "the lattice is not the whole plate")
        XCTAssertEqual(
            points.filter { $0.y > AboutMotion.Plate.upperBandHeight }.count,
            70 * 5,
            "the colophon band has no lattice"
        )

        let frame = CGRect(x: 300, y: 80, width: 80, height: 20)
        let point = CGPoint(x: 340, y: 90)
        let motion = AboutMotion.Matrix.motion(
            input: AboutMotionInput(pointer: point),
            plateSize: plateSize,
            knockoutFrames: ["systemValue": frame]
        )
        for dot in motion.dots {
            XCTAssertGreaterThanOrEqual(
                distance(from: CGPoint(x: dot.x, y: dot.y), to: frame),
                1,
                "a dot sits under the colophon value"
            )
        }
    }

    /// The disc hole and the entrance front start from the painted disc's
    /// offset, not from the settled centre.
    func testTheDiscHoleAndFrontFollowThePaintedDiscOffset() {
        let input = AboutMotionInput(entranceElapsed: 0)
        let offset = AboutMotion.Matrix.discOffset(input)
        XCTAssertNotEqual(offset, .zero, "the disc has no entrance offset")
        let centre = AboutMotion.Plate.discCentre(plateSize: plateSize)
        let motion = AboutMotion.Matrix.motion(
            input: input,
            plateSize: plateSize,
            knockoutFrames: [:]
        )
        for dot in motion.dots {
            let distance = hypot(dot.x - (centre.x + offset.x), dot.y - (centre.y + offset.y))
            XCTAssertGreaterThanOrEqual(
                distance,
                AboutMotion.Plate.discDiameter / 2,
                "a dot survived inside the painted disc"
            )
        }

        let elapsed = 100.0
        let entrance = AboutMotionInput(entranceElapsed: elapsed)
        let painted = AboutMotion.Matrix.discOffset(entrance)
        let radius = AboutMotion.Matrix.frontRadius(entranceElapsed: elapsed)
        let onFront = CGPoint(x: centre.x + painted.x - radius, y: centre.y + painted.y)
        XCTAssertGreaterThan(
            AboutMotion.Matrix.energy(at: onFront, input: entrance, plateSize: plateSize),
            0.9,
            "the front does not start at the painted disc"
        )
    }

    // MARK: The feather

    /// Zero through one point clear, full strength at six.
    func testTheKnockoutFeatherIsZeroAtOnePointAndFullAtSix() {
        let frame = CGRect(x: 100, y: 10, width: 40, height: 30)
        for (distance, expected) in [(1.0, 0.0), (6.0, 1.0)] {
            let point = CGPoint(x: 100 - distance, y: 20)
            let raw = AboutMotion.Matrix.energy(
                at: point,
                input: AboutMotionInput(pointer: point),
                plateSize: plateSize
            )
            XCTAssertEqual(raw, 1, accuracy: 0.01, "no raw energy at \(distance)")
            let knocked = AboutMotion.Matrix.energy(
                at: point,
                input: AboutMotionInput(pointer: point),
                plateSize: plateSize,
                knockoutFrames: [frame]
            )
            XCTAssertEqual(
                knocked,
                expected,
                accuracy: 0.001,
                "the feather at \(distance) points"
            )
        }
    }

    // MARK: Helpers

    private func present(_ input: AboutMotionInput) -> AboutMotionPresentation {
        AboutMotion.presentation(input: input, plateSize: plateSize)
    }

    /// The sampled inputs the contact sheets use, plus the reduced-motion
    /// copies of all of them.
    private func sampledInputs(reduceMotion: Bool) -> [AboutMotionInput] {
        var inputs: [AboutMotionInput] = [
            AboutMotionInput(),
            AboutMotionInput(entranceElapsed: 0),
            AboutMotionInput(entranceElapsed: 167),
            AboutMotionInput(entranceElapsed: 633),
            AboutMotionInput(pointer: CGPoint(x: 0, y: 0)),
            AboutMotionInput(pointer: CGPoint(x: plateSize.width, y: 0)),
            AboutMotionInput(pointer: CGPoint(x: 0, y: plateSize.height)),
            AboutMotionInput(pointer: CGPoint(x: plateSize.width, y: plateSize.height)),
            AboutMotionInput(pointer: CGPoint(x: plateSize.width / 2, y: plateSize.height / 2)),
            AboutMotionInput(pointer: CGPoint(x: 100, y: 20), pointerExitElapsed: 90),
            AboutMotionInput(focusedControl: .update),
            AboutMotionInput(focusedControl: .copy),
            AboutMotionInput(update: .checking(elapsed: 0)),
            AboutMotionInput(update: .checking(elapsed: 280)),
            AboutMotionInput(update: .checking(elapsed: 800)),
            AboutMotionInput(update: .upToDate(elapsed: 100, frontsElapsed: 250)),
            AboutMotionInput(update: .upToDate(elapsed: 400, frontsElapsed: nil)),
            AboutMotionInput(update: .available(elapsed: 400, frontsElapsed: nil)),
            AboutMotionInput(update: .unreachable(elapsed: 60, frontsElapsed: 250)),
            AboutMotionInput(engagedRow: 3, engagedElapsed: 40),
            AboutMotionInput(releasedRow: 2, releasedElapsed: 40),
        ]
        inputs.append(contentsOf: (0..<7).map { AboutMotionInput(engagedRow: $0) })
        return inputs.map { input in
            var copy = input
            copy.reduceMotion = reduceMotion
            return copy
        }
    }

    // MARK: Entrance

    /// The first frame starts where the matrix says it does, and the shared
    /// content starts 6 or 5 points low at 65 percent.
    func testTheEntranceStartsAtTheFirstFrame() {
        let presentation = present(AboutMotionInput(entranceElapsed: 0))
        XCTAssertEqual(presentation.discOffset, CGPoint(x: 18, y: -14), "first disc offset")
        for (name, group) in [
            ("title", presentation.title),
            ("update", presentation.update),
            ("colophon", presentation.colophon),
        ] {
            XCTAssertEqual(group.offset.y, 6, accuracy: 0.0001, "\(name) rise")
            XCTAssertEqual(group.opacity, 0.65, accuracy: 0.0001, "\(name) opacity")
        }
        for (index, row) in presentation.rows.enumerated() {
            XCTAssertEqual(row.contentOffset.y, 5, accuracy: 0.0001, "row \(index) rise")
            XCTAssertEqual(row.contentOpacity, 0.65, accuracy: 0.0001, "row \(index) opacity")
        }
    }

    /// A long entrance is the settled frame: the clock stops and the page is
    /// the same as an input that never had an entrance.
    func testAnElapsedEntranceIsTheSettledPresentation() {
        XCTAssertEqual(
            present(AboutMotionInput(entranceElapsed: 1000)),
            present(AboutMotionInput()),
            "1000 ms is not the settled frame"
        )
    }

    /// With no entrance, no pointer and no check, the plate is exactly the page
    /// the owner already has: content at rest, nothing drawn on the plate.
    func testTheSettledFrameHasNoMotion() {
        let presentation = present(AboutMotionInput())
        XCTAssertEqual(presentation.discOffset, .zero, "disc moved")
        for (name, group) in [
            ("title", presentation.title),
            ("update", presentation.update),
            ("colophon", presentation.colophon),
        ] {
            XCTAssertEqual(group.offset, .zero, "\(name) offset")
            XCTAssertEqual(group.opacity, 1, "\(name) opacity")
        }
        for (index, row) in presentation.rows.enumerated() {
            XCTAssertEqual(row.contentOffset, .zero, "row \(index) offset")
            XCTAssertEqual(row.contentOpacity, 1, "row \(index) opacity")
            XCTAssertEqual(row.fillOpacity, 0, "row \(index) fill")
            XCTAssertEqual(row.accentOffset, .zero, "row \(index) accent")
            XCTAssertTrue(
                row.dotOpacities.allSatisfy { $0 == 0 },
                "row \(index) dots"
            )
        }
        XCTAssertTrue(presentation.matrix.dots.isEmpty, "matrix dots")
        XCTAssertEqual(presentation.matrix.packetOpacity, 0, "packet")
        for point in AboutMotion.Matrix.lattice(plateSize: plateSize) {
            XCTAssertEqual(
                AboutMotion.Matrix.energy(
                    at: point,
                    input: AboutMotionInput(),
                    plateSize: plateSize
                ),
                0,
                accuracy: 0.0001,
                "energy at \(point)"
            )
        }
    }

    // MARK: The matrix

    /// The entrance front is a Gaussian ring: one radius away from the disc
    /// centre, with the front at that radius, a point carries full energy.
    func testTheMatrixFrontCarriesFullEnergyAtItsRadius() {
        let point = CGPoint(x: 100, y: 68)
        let centre = AboutMotion.Plate.discCentre(plateSize: plateSize)
        let radius = hypot(point.x - centre.x, point.y - centre.y)
        let elapsed = AboutMotion.Matrix.frontStart
            + AboutMotion.Matrix.frontTravel * Double(radius) / AboutMotion.Matrix.frontReach
        let energy = AboutMotion.Matrix.energy(
            at: point,
            input: AboutMotionInput(entranceElapsed: elapsed),
            plateSize: plateSize
        )
        XCTAssertEqual(energy, 1, accuracy: 0.01, "energy on the front")
    }

    /// Dots do not sit under the title, the tagline, the control or the status:
    /// a point inside one of their frames loses all of its energy.
    func testTheMatrixKnocksDotsOutFromUnderText() {
        let title = CGRect(x: 16, y: 8, width: 49, height: 38)
        let inside = CGPoint(x: 20, y: 20)
        let centre = AboutMotion.Plate.discCentre(plateSize: plateSize)
        let radius = hypot(inside.x - centre.x, inside.y - centre.y)
        let elapsed = AboutMotion.Matrix.frontStart
            + AboutMotion.Matrix.frontTravel * Double(radius) / AboutMotion.Matrix.frontReach
        let input = AboutMotionInput(entranceElapsed: elapsed)

        let raw = AboutMotion.Matrix.energy(
            at: inside,
            input: input,
            plateSize: plateSize
        )
        XCTAssertGreaterThan(raw, 0.2, "the front does not reach the title point")
        let knocked = AboutMotion.Matrix.energy(
            at: inside,
            input: input,
            plateSize: plateSize,
            knockoutFrames: [title]
        )
        XCTAssertEqual(knocked, 0, accuracy: 0.0001, "a dot under the title survived")
    }

    /// The control and the status line are knockouts like the title: a lattice
    /// point inside either frame draws no dot, even when a checking front and a
    /// held patch both carry full energy there.
    func testTheMatrixKeepsDotsOutOfTheControlAndStatusFrames() throws {
        FontFixture.register()
        let box = FrameBox()
        let page = AboutPage(
            version: "1.0",
            build: "1",
            previewUpdate: .upToDate,
            onLayout: { box.frames = $0.frames },
            previewMotion: AboutMotionInput()
        )
        let hosting = NSHostingView(
            rootView: ScrollView(.vertical) {
                page.frame(width: plateSize.width)
            }
            .frame(width: plateSize.width, height: 600)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: plateSize.width, height: 600)
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        hosting.layoutSubtreeIfNeeded()

        let control = try XCTUnwrap(box.frames["control"], "the control frame was not measured")
        let status = try XCTUnwrap(box.frames["status"], "the status frame was not measured")
        let frames = [control, status]
        let centre = AboutMotion.Plate.discCentre(plateSize: plateSize)
        var tested = 0
        for frame in frames {
            for point in AboutMotion.Matrix.lattice(plateSize: plateSize) {
                guard distance(from: point, to: frame) <= 1 else { continue }
                tested += 1
                let radius = hypot(point.x - centre.x, point.y - centre.y)
                let elapsed = min(
                    330,
                    Double(radius) / Double(AboutMotion.Matrix.checkingReach)
                        * AboutMotion.Matrix.checkingTravel
                )
                let input = AboutMotionInput(
                    pointer: point,
                    update: .checking(elapsed: elapsed)
                )
                let raw = AboutMotion.Matrix.energy(
                    at: point,
                    input: input,
                    plateSize: plateSize
                )
                XCTAssertGreaterThan(raw, 0.5, "no energy to knock out at \(point)")
                let knocked = AboutMotion.Matrix.energy(
                    at: point,
                    input: input,
                    plateSize: plateSize,
                    knockoutFrames: frames
                )
                XCTAssertEqual(
                    knocked,
                    0,
                    accuracy: 0.0001,
                    "a dot survived inside \(frame) at \(point)"
                )
            }
        }
        XCTAssertGreaterThan(tested, 0, "no lattice point fell in the control or the status")
    }

    /// The patch centres on the plate point it is given, including on the y
    /// axis, and it is gone once the input stops carrying one.
    func testThePointerPatchCentresOnThePlatePoint() {
        let low = AboutMotionInput(pointer: CGPoint(x: 100, y: 20))
        let high = AboutMotionInput(pointer: CGPoint(x: 100, y: 98))
        let lowEnergy = AboutMotion.Matrix.energy(
            at: CGPoint(x: 100, y: 20),
            input: low,
            plateSize: plateSize
        )
        let lowAtHigh = AboutMotion.Matrix.energy(
            at: CGPoint(x: 100, y: 98),
            input: low,
            plateSize: plateSize
        )
        // The patch centre follows the plate point anywhere on the plate; it
        // is not pinned to the upper band.
        let highEnergy = AboutMotion.Matrix.energy(
            at: CGPoint(x: 100, y: 98),
            input: high,
            plateSize: plateSize
        )
        let highAtLow = AboutMotion.Matrix.energy(
            at: CGPoint(x: 100, y: 20),
            input: high,
            plateSize: plateSize
        )
        XCTAssertEqual(lowEnergy, 1, accuracy: 0.01, "patch centre at y 20")
        XCTAssertGreaterThan(lowEnergy, lowAtHigh, "the patch is not centred at y 20")
        XCTAssertEqual(highEnergy, 1, accuracy: 0.01, "patch centre at y 98")
        XCTAssertGreaterThan(highEnergy, highAtLow, "the patch is not centred at y 98")
        let far = AboutMotion.Matrix.energy(
            at: CGPoint(x: 400, y: 68),
            input: low,
            plateSize: plateSize
        )
        XCTAssertLessThan(far, 0.001, "the patch reaches the far side of the plate")
    }

    /// Leaving fades the patch over 180 ms at the centre it left from.
    func testThePointerExitFadesThePatch() {
        let point = CGPoint(x: 100, y: 20)
        func energy(_ exit: Double?) -> Double {
            AboutMotion.Matrix.energy(
                at: point,
                input: AboutMotionInput(pointer: point, pointerExitElapsed: exit),
                plateSize: plateSize
            )
        }
        XCTAssertEqual(energy(nil), 1, accuracy: 0.01, "held patch")
        XCTAssertEqual(energy(0), 1, accuracy: 0.01, "exit start")
        XCTAssertEqual(energy(90), 0.5, accuracy: 0.02, "mid fade")
        XCTAssertLessThan(energy(179), 0.01, "fade end")
        XCTAssertEqual(energy(180), 0, accuracy: 0.0001, "faded out")

        let presentation = present(
            AboutMotionInput(pointer: point, pointerExitElapsed: 180)
        )
        XCTAssertTrue(presentation.matrix.dots.isEmpty, "a dot survived the exit")
    }

    // MARK: Rows

    /// The five dots fade in over 100 ms each, staggered 24 ms left to right,
    /// and fade out over a flat 120 ms.
    func testTheRowDotsFadeInWithAStagger() {
        let settled = present(AboutMotionInput(engagedRow: 3))
        XCTAssertEqual(settled.rows[3].dotOpacities.count, 5)
        XCTAssertTrue(
            settled.rows[3].dotOpacities.allSatisfy { abs($0 - 0.42) < 0.0001 },
            "settled dots"
        )

        let start = present(AboutMotionInput(engagedRow: 3, engagedElapsed: 0))
        XCTAssertTrue(start.rows[3].dotOpacities.allSatisfy { $0 == 0 }, "dots start lit")

        let quarter = present(AboutMotionInput(engagedRow: 3, engagedElapsed: 100))
        XCTAssertEqual(quarter.rows[3].dotOpacities[0], 0.42, accuracy: 0.0001)
        XCTAssertLessThan(quarter.rows[3].dotOpacities[4], 0.06, "last dot is not staggered")

        let end = present(AboutMotionInput(engagedRow: 3, engagedElapsed: 196))
        XCTAssertTrue(
            end.rows[3].dotOpacities.allSatisfy { abs($0 - 0.42) < 0.0001 },
            "dots do not finish"
        )

        let release = present(AboutMotionInput(releasedRow: 3, releasedElapsed: 60))
        XCTAssertEqual(release.rows[3].dotOpacities[0], 0.21, accuracy: 0.01)
        let gone = present(AboutMotionInput(releasedRow: 3, releasedElapsed: 120))
        XCTAssertTrue(gone.rows[3].dotOpacities.allSatisfy { $0 == 0 }, "dots survived release")
    }

    /// The row fill and accent follow the 0.22/0.88 engage spring and the
    /// 0.28/0.92 release spring, expressed as a zero through one factor.
    func testTheRowFillSpringsToItsTarget() {
        let settled = present(AboutMotionInput(engagedRow: 0))
        XCTAssertEqual(settled.rows[0].fillOpacity, 0.09, accuracy: 0.0001)
        XCTAssertEqual(settled.rows[0].accentOffset, CGPoint(x: 3, y: -2))
        let action = present(AboutMotionInput(engagedRow: 6))
        XCTAssertEqual(action.rows[6].accentOffset, CGPoint(x: 3, y: 0))

        let start = present(AboutMotionInput(engagedRow: 0, engagedElapsed: 0))
        XCTAssertEqual(start.rows[0].fillOpacity, 0, accuracy: 0.0001, "fill starts lit")
        let late = present(AboutMotionInput(engagedRow: 0, engagedElapsed: 1120))
        XCTAssertEqual(late.rows[0].fillOpacity, 0.09, accuracy: 0.0005, "fill did not arrive")

        let release = present(AboutMotionInput(releasedRow: 0, releasedElapsed: 0))
        XCTAssertEqual(release.rows[0].fillOpacity, 0.09, accuracy: 0.0001, "release jumps")
        let gone = present(AboutMotionInput(releasedRow: 0, releasedElapsed: 1120))
        XCTAssertLessThan(gone.rows[0].fillOpacity, 0.0005, "release did not fade")
    }

    // MARK: Update

    /// A result that arrives while the checking fronts are alive lets them
    /// finish their own fade; a failure also fades them out over 120 ms.
    func testTheCheckingFrontsFinishAfterAResultArrives() {
        let disc = AboutMotion.Plate.discCentre(plateSize: plateSize)
        // The first front at 250 ms sits 131 points from the disc centre.
        let onFront = CGPoint(x: disc.x - 131, y: disc.y)
        func energy(_ update: AboutUpdatePhase) -> Double {
            AboutMotion.Matrix.energy(
                at: onFront,
                input: AboutMotionInput(update: update),
                plateSize: plateSize
            )
        }
        let checking = energy(.checking(elapsed: 250))
        XCTAssertGreaterThan(checking, 0.9, "no front to continue")
        XCTAssertEqual(
            energy(.upToDate(elapsed: 0, frontsElapsed: 250)),
            checking,
            accuracy: 0.0001,
            "a result cut the fronts"
        )
        XCTAssertEqual(
            energy(.available(elapsed: 0, frontsElapsed: 250)),
            checking,
            accuracy: 0.0001,
            "a result cut the fronts"
        )
        XCTAssertEqual(
            energy(.unreachable(elapsed: 0, frontsElapsed: 250)),
            checking,
            accuracy: 0.0001,
            "a failure cut the fronts instead of fading them"
        )
        XCTAssertEqual(
            energy(.upToDate(elapsed: 100, frontsElapsed: 250)),
            energy(.checking(elapsed: 350)),
            accuracy: 0.0001,
            "the fronts did not continue their schedule"
        )

        // The second front at 310 ms sits 99.5 points from the disc centre.
        let onSecond = CGPoint(x: disc.x - 99.5, y: disc.y)
        let alive = AboutMotion.Matrix.energy(
            at: onSecond,
            input: AboutMotionInput(update: .checking(elapsed: 310)),
            plateSize: plateSize
        )
        XCTAssertGreaterThan(alive, 0.9)
        let half = AboutMotion.Matrix.energy(
            at: onSecond,
            input: AboutMotionInput(update: .unreachable(elapsed: 60, frontsElapsed: 250)),
            plateSize: plateSize
        )
        XCTAssertEqual(half, alive * 0.5, accuracy: 0.01, "the failure fade is not half at 60 ms")
        let gone = AboutMotion.Matrix.energy(
            at: onSecond,
            input: AboutMotionInput(update: .unreachable(elapsed: 120, frontsElapsed: 250)),
            plateSize: plateSize
        )
        XCTAssertEqual(gone, 0, accuracy: 0.0001, "the failed plate kept its dots")
    }

    /// A failure fades the checking fronts only: a held patch and a running
    /// entrance keep their energy.
    func testAFailureFadesTheFrontsAndNotTheHeldPatch() {
        let point = CGPoint(x: 100, y: 20)
        let held = AboutMotion.Matrix.energy(
            at: point,
            input: AboutMotionInput(pointer: point),
            plateSize: plateSize
        )
        let failing = AboutMotion.Matrix.energy(
            at: point,
            input: AboutMotionInput(
                pointer: point,
                update: .unreachable(elapsed: 60, frontsElapsed: 250)
            ),
            plateSize: plateSize
        )
        XCTAssertEqual(failing, held, accuracy: 0.001, "a failure faded the held patch")

        let disc = AboutMotion.Plate.discCentre(plateSize: plateSize)
        let frontPoint = CGPoint(x: disc.x - 252, y: disc.y)
        let entering = AboutMotion.Matrix.energy(
            at: frontPoint,
            input: AboutMotionInput(entranceElapsed: 300),
            plateSize: plateSize
        )
        let enteringDuringFailure = AboutMotion.Matrix.energy(
            at: frontPoint,
            input: AboutMotionInput(
                entranceElapsed: 300,
                update: .unreachable(elapsed: 60, frontsElapsed: 250)
            ),
            plateSize: plateSize
        )
        XCTAssertEqual(
            enteringDuringFailure,
            entering,
            accuracy: 0.001,
            "a failure faded the running entrance"
        )
    }

    /// The packet is a triangle for an up-to-date result and a held packet for
    /// a release.
    func testTheUpdatePacketFollowsItsResult() {
        let rising = present(
            AboutMotionInput(update: .upToDate(elapsed: 100, frontsElapsed: nil))
        )
        XCTAssertEqual(rising.matrix.packetOpacity, 0.42, accuracy: 0.0001)
        let over = present(
            AboutMotionInput(update: .upToDate(elapsed: 400, frontsElapsed: nil))
        )
        XCTAssertEqual(over.matrix.packetOpacity, 0, accuracy: 0.0001)
        let held = present(
            AboutMotionInput(update: .available(elapsed: 400, frontsElapsed: nil))
        )
        XCTAssertEqual(held.matrix.packetOpacity, 0.30, accuracy: 0.0001)
    }

    // MARK: The pause predicate

    /// The live clock pauses only when every effect has finished: at rest and
    /// at the end time of each effect, and never while one is still running.
    func testTheClockIsSettledOnlyWhenEveryEffectHasFinished() {
        XCTAssertTrue(AboutMotion.isSettled(AboutMotionInput()), "rest is not settled")

        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(entranceElapsed: 0)),
            "the entrance did not hold the clock"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(entranceElapsed: 614)),
            "the entrance ended early"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(entranceElapsed: 615)),
            "the entrance kept the clock"
        )

        XCTAssertTrue(
            AboutMotion.isSettled(
                AboutMotionInput(pointer: CGPoint(x: 100, y: 20))
            ),
            "a settled held patch keeps the clock awake"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(
                AboutMotionInput(
                    pointer: CGPoint(x: 100, y: 20),
                    pointerSettled: false
                )
            ),
            "a travelling spring was called settled"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(
                AboutMotionInput(pointer: CGPoint(x: 100, y: 20), pointerExitElapsed: 179)
            ),
            "the exit fade ended early"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(
                AboutMotionInput(pointer: CGPoint(x: 100, y: 20), pointerExitElapsed: 180)
            ),
            "the exit fade kept the clock"
        )

        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(update: .checking(elapsed: 0))),
            "the checking fronts are not settled"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(update: .checking(elapsed: 539))),
            "the checking fronts ended early"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(update: .checking(elapsed: 540))),
            "the checking fronts kept the clock"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(
                AboutMotionInput(update: .upToDate(elapsed: 100, frontsElapsed: 250))
            ),
            "a front still alive was called settled"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(
                AboutMotionInput(update: .upToDate(elapsed: 300, frontsElapsed: 250))
            ),
            "the front end kept the clock"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(
                AboutMotionInput(update: .upToDate(elapsed: 100, frontsElapsed: nil))
            ),
            "the packet is not settled"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(
                AboutMotionInput(update: .upToDate(elapsed: 200, frontsElapsed: nil))
            ),
            "the packet kept the clock"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(
                AboutMotionInput(update: .available(elapsed: 100, frontsElapsed: nil))
            ),
            "the release packet is not settled"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(
                AboutMotionInput(update: .available(elapsed: 160, frontsElapsed: nil))
            ),
            "the release packet kept the clock"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(
                AboutMotionInput(update: .unreachable(elapsed: 0, frontsElapsed: 250))
            ),
            "the failure fade is not settled"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(
                AboutMotionInput(update: .unreachable(elapsed: 120, frontsElapsed: 250))
            ),
            "the fade's end kept the clock"
        )

        // Row feedback is SwiftUI animation in the rows; it never keeps the
        // matrix clock alive.
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(engagedRow: 2, engagedElapsed: 0)),
            "a row fade kept the matrix clock"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(releasedRow: 2, releasedElapsed: 0)),
            "a row release kept the matrix clock"
        )

        // Damped harmonic ripples keep the clock alive until rippleDuration, then settle.
        let origin = CGPoint(x: 200, y: 60)
        let activeRipple = AboutRipple(origin: origin, elapsed: 200)
        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(ripples: [activeRipple])),
            "an active acoustic ripple was called settled"
        )
        XCTAssertGreaterThan(
            AboutMotion.Matrix.energy(
                at: CGPoint(x: 200 + AboutMotion.Matrix.rippleSpeed * 200, y: 60),
                input: AboutMotionInput(ripples: [activeRipple]),
                plateSize: plateSize
            ),
            0.2,
            "the ripple wavefront did not energize the lattice"
        )
        let expiredRipple = AboutRipple(origin: origin, elapsed: AboutMotion.Matrix.rippleDuration)
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(ripples: [expiredRipple])),
            "an expired ripple kept the clock"
        )
        XCTAssertEqual(
            AboutMotion.Matrix.energy(
                at: origin,
                input: AboutMotionInput(ripples: [expiredRipple]),
                plateSize: plateSize
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AboutMotion.Matrix.energy(
                at: CGPoint(x: 200 + AboutMotion.Matrix.rippleSpeed * 200, y: 60),
                input: AboutMotionInput(ripples: [activeRipple], reduceMotion: true),
                plateSize: plateSize
            ),
            0,
            accuracy: 0.0001,
            "reduceMotion did not suppress ripples"
        )
        let rippleClock = AboutMotionClock(ripples: [AboutRippleAnchor(origin: origin, startedAt: 500)])
        XCTAssertEqual(rippleClock.settleDeadline(), 500 + AboutMotion.Matrix.rippleDuration)
        XCTAssertFalse(rippleClock.isSettled(at: 500 + AboutMotion.Matrix.rippleDuration - 1))
        XCTAssertTrue(rippleClock.isSettled(at: 500 + AboutMotion.Matrix.rippleDuration))
    }

    // MARK: Reduce motion

    /// Reduced motion keeps the final geometry: no offset, no patch, no front,
    /// no packet and no row spring. Only the row fill's 120 ms feedback stays.
    func testReducedMotionKeepsEveryOffsetAndSweepStill() {
        for input in sampledInputs(reduceMotion: true) {
            let presentation = present(input)
            XCTAssertEqual(presentation.discOffset, .zero, "disc offset")
            XCTAssertEqual(presentation.title.offset, .zero, "title offset")
            XCTAssertEqual(presentation.update.offset, .zero, "update offset")
            XCTAssertEqual(presentation.colophon.offset, .zero, "colophon offset")
            XCTAssertEqual(presentation.title.opacity, 1, accuracy: 0.0001)
            for (index, row) in presentation.rows.enumerated() {
                XCTAssertEqual(row.contentOffset, .zero, "row \(index) content")
                XCTAssertEqual(row.accentOffset, .zero, "row \(index) accent")
                XCTAssertTrue(
                    row.dotOpacities.allSatisfy { $0 == 0 },
                    "row \(index) dots"
                )
            }
            XCTAssertTrue(presentation.matrix.dots.isEmpty, "matrix dots")
            XCTAssertEqual(presentation.matrix.packetOpacity, 0, "packet")
        }

        // Reduce Motion has no elapsed path: an engaged row is at its fill,
        // and the live leaf animates only that opacity over 120 ms.
        let engaged = present(
            AboutMotionInput(engagedRow: 0, engagedElapsed: 60, reduceMotion: true)
        )
        XCTAssertEqual(engaged.rows[0].fillOpacity, 0.09, accuracy: 0.0001, "engaged fill")
        let gone = present(
            AboutMotionInput(releasedRow: 0, releasedElapsed: 60, reduceMotion: true)
        )
        XCTAssertEqual(gone.rows[0].fillOpacity, 0, accuracy: 0.0001, "released fill")
    }

    // MARK: Spring

    /// Four responses is the settle window the live view budgets for; the
    /// spring has to be there without an overshoot that survives it.
    func testTheSpringConvergesWithinFourResponses() {
        for entry in [
            AboutSpring(response: 0.24, dampingFraction: 0.85),
            AboutSpring(response: 0.23, dampingFraction: 0.90),
            AboutSpring(response: 0.25, dampingFraction: 0.84),
        ] {
            var position = 0.0
            var velocity = 0.0
            let steps = 200
            let total = 4 * entry.response
            for _ in 0..<steps {
                let next = entry.step(
                    position: position,
                    velocity: velocity,
                    target: 1,
                    dt: total / Double(steps)
                )
                position = next.position
                velocity = next.velocity
            }
            XCTAssertEqual(position, 1, accuracy: 0.005, "settle at four responses")
            XCTAssertEqual(velocity, 0, accuracy: 0.01, "velocity at four responses")
        }
    }

    /// An underdamped spring overshoots, and the overshoot stays inside the
    /// analytic bound for its damping fraction.
    func testAnUnderdampedSpringOvershootsWithinItsBound() {
        let spring = AboutSpring(response: 0.3, dampingFraction: 0.5)
        var position = 0.0
        var velocity = 0.0
        var peak = 0.0
        for _ in 0..<240 {
            let next = spring.step(
                position: position,
                velocity: velocity,
                target: 1,
                dt: 1.0 / 240.0
            )
            position = next.position
            velocity = next.velocity
            peak = max(peak, position)
        }
        let bound = exp(-Double.pi * spring.dampingFraction
            / sqrt(1 - spring.dampingFraction * spring.dampingFraction))
        XCTAssertLessThanOrEqual(peak, 1 + bound + 0.005, "overshoot above the analytic bound")
        XCTAssertEqual(position, 1, accuracy: 0.005, "final position")
    }

    /// The closed form gives the same place at one second whatever the frame
    /// step was, which is what lets the clip and the live view agree.
    func testTheSpringEndsAtTheSamePlaceAtSixtyAndTwoFortySteps() {
        let spring = AboutSpring(response: 0.24, dampingFraction: 0.85)
        func run(dt: Double) -> Double {
            var position = 0.0
            var velocity = 0.0
            let steps = Int((1.0 / dt).rounded())
            for _ in 0..<steps {
                let next = spring.step(
                    position: position,
                    velocity: velocity,
                    target: 1,
                    dt: dt
                )
                position = next.position
                velocity = next.velocity
            }
            return position
        }
        XCTAssertEqual(run(dt: 1.0 / 60.0), run(dt: 1.0 / 240.0), accuracy: 0.01)
    }

    // MARK: The page's clock

    /// The page's live entrance is a function of elapsed milliseconds, so its
    /// start frame and its settled frame are the same values the strips show.
    func testTheLiveEntranceInputMatchesTheModel() {
        XCTAssertEqual(AboutMotion.entranceDuration, 200)
        XCTAssertEqual(AboutMotion.titleEntranceStart, 35)
        XCTAssertEqual(AboutMotion.updateEntranceStart, 65)
        XCTAssertEqual(AboutMotion.colophonEntranceStart, 90)
        XCTAssertEqual(AboutMotion.rowEntranceStart, 100)
        XCTAssertEqual(AboutMotion.rowEntranceStep, 16)
        XCTAssertEqual(AboutMotion.rowEntranceDuration, 170)
    }

    // MARK: The frame budget

    /// The matrix canvas is one leaf and draws the lattice, the patch and the
    /// fronts inside the frame budget.
    func testTheMatrixCanvasDrawMeetsTheFrameBudget() throws {
        let durations = try UIPreview.measureMatrixDraw(frames: 300)
        XCTAssertEqual(durations.count, 300, "frames without a canvas draw")
        let sorted = durations.sorted()
        let middle = sorted[sorted.count / 2]
        let high = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let maximum = sorted.last ?? 0
        print(
            String(
                format: "MATRIX-DRAW p50 %.4f p95 %.4f max %.4f",
                middle,
                high,
                maximum
            )
        )
        XCTAssertLessThanOrEqual(high, 2.0, "the matrix canvas draw misses the frame budget")
    }

    // MARK: Helpers

    private func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, max(0, point.x - frame.maxX))
        let dy = max(frame.minY - point.y, max(0, point.y - frame.maxY))
        return hypot(dx, dy)
    }

    @MainActor
    private final class FrameBox {
        var frames: [String: CGRect] = [:]
    }
}
