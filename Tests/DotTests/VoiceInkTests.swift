import AppKit
@testable import Dot
import SwiftUI
import XCTest

/// The welcome's voice drawing.
///
/// It replaced a stroke that was measured, on the user's own screen, as a
/// scribble: a thin line wandering a fraction of the strip. The drawing is now
/// clusters of ink, and these tests hold the three properties that make it read
/// as speech rather than as decoration: it fills the strip, it has silence in it,
/// and it moves.
final class VoiceInkTests: XCTestCase {
    private let size = CGSize(width: 190, height: 46)

    func testTheStrokeFillsTheStrip() {
        var tallest: CGFloat = 0
        for time in stride(from: 0.0, through: 8.0, by: 0.5) {
            let box = VoiceInkFigure.figure(size: size, time: time).ink.boundingRect
            tallest = max(tallest, box.height)
        }
        // Speech reaches most of the strip; the drawing before this one kept to
        // 37 of its 46 points and read as a thread.
        XCTAssertGreaterThan(tallest, size.height * 0.55, "the stroke never fills the strip")
        XCTAssertLessThanOrEqual(tallest, size.height, "the stroke escapes the strip")
    }

    func testTheStrokeHasSilenceInIt() {
        // A lozenge is the failure mode: one continuous band with no gaps. Words
        // with pauses between them means some column is nearly flat, and some
        // column is not, at the same moment.
        let time = 2.4
        let steps = 400
        var flat = 0
        var full = 0
        for index in 0...steps {
            let u = Double(index) / Double(steps)
            let loud = VoiceInkFigure.speech(at: u * VoiceInkFigure.window - time * VoiceInkFigure.speed)
            if loud < 0.12 { flat += 1 }
            if loud > 0.60 { full += 1 }
        }
        XCTAssertGreaterThan(flat, steps / 12, "no pauses: the drawing is one band")
        XCTAssertGreaterThan(full, steps / 8, "no words: the drawing is a hairline")
    }

    func testTheStrokeMoves() {
        let first = points(of: VoiceInkFigure.figure(size: size, time: 2.4).ink)
        let second = points(of: VoiceInkFigure.figure(size: size, time: 2.9).ink)
        XCTAssertEqual(first.count, second.count)
        XCTAssertNotEqual(first, second, "the drawing is frozen; a half second of voice changed nothing")
    }

    /// Every vertex of a path, so two moments can be compared without a bitmap.
    private func points(of path: Path) -> [CGPoint] {
        var out: [CGPoint] = []
        path.cgPath.applyWithBlock { element in
            let command = element.pointee
            switch command.type {
            case .moveToPoint, .addLineToPoint:
                out.append(command.points[0])
            default:
                break
            }
        }
        return out
    }

    func testTheNibSitsInsideTheStrip() {
        for time in stride(from: 0.0, through: 6.0, by: 0.75) {
            let (_, nib, radius) = VoiceInkFigure.figure(size: size, time: time)
            XCTAssertGreaterThan(nib.x - radius, 0)
            XCTAssertLessThan(nib.x + radius, size.width, "the nib is clipped by the strip")
            XCTAssertEqual(nib.y, size.height / 2, accuracy: 0.001)
        }
    }
    /// The ink is what the voice has already said, so it has to travel away from
    /// the nib. Drawn the other way it reads as a wave arriving at a pen that is
    /// writing it, and the fade - which makes the far end the old end - argues
    /// with the motion.
    func testTheInkTravelledAwayFromTheNib() {
        let column = 0.5
        let before = VoiceInkFigure.material(at: column, time: 2.4)
        let after = VoiceInkFigure.material(at: column, time: 3.0)
        XCTAssertGreaterThan(
            after,
            before,
            "at a fixed column the voice read gets older with time, so the ink travels towards the nib"
        )
        // The nib reads the newest material there is.
        XCTAssertEqual(
            VoiceInkFigure.material(atRightOf: 3.0),
            VoiceInkFigure.material(at: 1, time: 3.0),
            accuracy: 1e-12
        )
    }

    /// A still frame is what a screenshot, a Reduce Motion user and a preview
    /// render all see, so it has to be a whole voice and not a hairline with a
    /// word at one end.
    func testTheStillFrameIsNotMostlySilence() {
        let time = VoiceInkFigure.stillTime
        var inked = 0
        for index in 0...200 {
            let u = Double(index) / 200
            if VoiceInkFigure.speech(at: VoiceInkFigure.material(at: u, time: time)) > 0.12 {
                inked += 1
            }
        }
        XCTAssertGreaterThan(inked, 80, "the still frame is under 40 percent ink")
    }
}
