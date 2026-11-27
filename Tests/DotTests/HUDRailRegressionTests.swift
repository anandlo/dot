import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

/// The two rail regressions that existed before the per-gesture owner.
///
/// These use only the background entry point, so they can run against the old
/// implementation as well: the first drops the mixed-axis event that used to be
/// rejected on its own, and the second sees the unconditional recentring that
/// moved the rail when a version was selected or completed.
@MainActor
final class HUDRailRegressionTests: XCTestCase {
    func testABackgroundDiagonalGestureAppliesEveryEvent() throws {
        let fixture = try makeFixture()
        defer { fixture.hud.hide() }

        // Begins sideways, then a changed event whose vertical delta is larger.
        // The old rule refused that event because |dx| < 0.5 |dy|.
        fixture.hud.debugHandleScrollEvent(
            try wheel(dx: -10, dy: -2, phase: .began, at: fixture.point),
            at: fixture.point
        )
        fixture.hud.debugHandleScrollEvent(
            try wheel(dx: -4, dy: -10, phase: .changed, at: fixture.point),
            at: fixture.point
        )
        XCTAssertEqual(
            railOffset(fixture),
            14,
            accuracy: 0.5,
            "the diagonal event was dropped instead of following the gesture's axis"
        )
    }

    func testABackgroundVerticalGestureMovesTheRail() throws {
        let fixture = try makeFixture()
        defer { fixture.hud.hide() }

        fixture.hud.debugHandleScrollEvent(
            try wheel(dy: -30, phase: .began, at: fixture.point),
            at: fixture.point
        )
        XCTAssertEqual(
            railOffset(fixture),
            30,
            accuracy: 0.5,
            "a precise vertical trackpad gesture over the rail was dropped"
        )
    }

    func testSelectionAndCompletionDoNotRecenterTheRail() throws {
        let fixture = try makeFixture()
        defer { fixture.hud.hide() }
        fixture.rail.contentView.scroll(to: NSPoint(x: 120, y: 0))
        fixture.rail.reflectScrolledClipView(fixture.rail.contentView)
        fixture.hud.debugRootView.layoutSubtreeIfNeeded()
        XCTAssertEqual(railOffset(fixture), 120, accuracy: 0.5)

        var card = fixture.card
        XCTAssertTrue(card.select(versionID: 1))
        fixture.hud.setRewrite(card)
        settle(fixture.hud)
        XCTAssertEqual(
            railOffset(fixture),
            120,
            accuracy: 0.5,
            "selecting a version recentred the rail"
        )

        card.append(
            id: 3,
            style: card.choices[2],
            text: HUDPreview.longTranscript,
            warning: nil
        )
        fixture.hud.setRewrite(card)
        settle(fixture.hud)
        XCTAssertEqual(
            railOffset(fixture),
            120,
            accuracy: 0.5,
            "a completed version recentred the rail"
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        let hud: HUD
        let card: RewriteCard
        let band: CGRect
        let rail: NSScrollView

        var point: CGPoint { CGPoint(x: band.midX, y: band.midY) }
    }

    private func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let custom = (0 ..< 6).map { index in
            RewriteStyle(
                CustomRewriteStyle(
                    id: "custom-\(index)",
                    title: String(repeating: "W", count: CustomRewriteStyle.maximumTitleLength),
                    instruction: "Rewrite."
                )
            )
        }
        var card = RewriteCard(
            original: HUDPreview.longTranscript,
            choices: RewriteStyle.builtIns + custom
        )
        card.append(id: 1, style: card.choices[0], text: HUDPreview.longTranscript, warning: nil)
        card.append(id: 2, style: card.choices[1], text: HUDPreview.longTranscript, warning: nil)

        let hud = HUD(offscreen: true)
        hud.dwell = 60
        hud.showTranscript(text: card.original, delivery: .copied, elapsed: "4:18")
        hud.setRewrite(card)
        hud.debugPointer(inside: true)
        settle(hud)
        // The rail's clip drifts by up to two points while the card opens, and a
        // slow host can still be opening after a fixed pause.
        if !waitForTheRailToSettle(hud) {
            let atRest = hud.debugAppearanceAtRest
            let decided = hud.debugRailPositionRestored
            hud.hide()
            throw FixtureNotReady(
                "the fixture card's opening never came to rest "
                    + "(at rest: \(atRest), correction decided: \(decided))"
            )
        }

        let size = HUD.transcriptSize(text: card.original, rewrite: card)
        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: hud.debugPanel.frame,
            cardSize: size,
            topInset: HUD.shadowPadding
        )
        let band = HUD.rewriteChipRowFrame(cardFrame: cardFrame, card: card)
        XCTAssertFalse(band.isEmpty, "the fixture card drew no rail")
        let rail = try XCTUnwrap(HUD.chipRowScrollView(in: hud.debugRootView))
        rail.contentView.scroll(to: .zero)
        rail.reflectScrolledClipView(rail.contentView)
        settle(hud)
        if abs(rail.contentView.bounds.origin.x) > 0.05 {
            let origin = rail.contentView.bounds.origin.x
            hud.hide()
            throw FixtureNotReady("the fixture rail moved off its start after setup (x: \(origin))")
        }
        return Fixture(hud: hud, card: card, band: band, rail: rail)
    }

    private struct FixtureNotReady: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Waits, bounded, for the appearance to rest and the opening correction to be decided.
    private func waitForTheRailToSettle(_ hud: HUD, within seconds: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var settled = 0
        while Date() < deadline {
            hud.debugRootView.layoutSubtreeIfNeeded()
            if hud.debugAppearanceAtRest, hud.debugRailPositionRestored {
                settled += 1
                if settled >= 2 { return true }
            } else {
                settled = 0
            }
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.02))
            )
        }
        return false
    }

    private func railOffset(_ fixture: Fixture) -> CGFloat {
        fixture.rail.contentView.bounds.origin.x
    }

    private func wheel(
        dx: CGFloat = 0,
        dy: CGFloat = 0,
        phase: CGScrollPhase,
        at point: CGPoint
    ) throws -> NSEvent {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(dy),
                wheel2: Int32(dx),
                wheel3: 0
            )
        )
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(phase.rawValue)
        )
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: point.x, y: screenHeight - point.y)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func settle(_ hud: HUD, for seconds: TimeInterval = 0.3) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            hud.debugRootView.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
        hud.debugRootView.layoutSubtreeIfNeeded()
    }
}
