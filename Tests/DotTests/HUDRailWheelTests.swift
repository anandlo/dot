import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

/// The style rail under a wheel or trackpad.
///
/// The rail is the row of style chips. A gesture that begins over it belongs to
/// it for its whole life: through diagonal travel, a pointer that drifts off
/// the row, and the momentum that follows the fingers. It never pages a version
/// or moves the transcript's body. A version that completes, or a chip that is
/// clicked, must not move the rail: its position belongs to the person
/// reading it. Only the two version arrows ask the row to reveal a style.
@MainActor
final class HUDRailWheelTests: XCTestCase {
    private let pointAway: CGFloat = 1_000

    /// Legacy line wheels need a source whose scroll state no other event can change.
    private static let lineWheelSource = CGEventSource(stateID: .privateState)

    // MARK: - The events

    /// A wheel event whose phase, momentum and precision are really set.
    ///
    /// `CGScrollPhase` and `NSEvent.Phase` do not share raw values: Core
    /// Graphics counts `changed` as 2 and `ended` as 4, while AppKit's option
    /// set has them at 4 and 8. The event is built with the Core Graphics
    /// constants and asserted through AppKit's values in
    /// ``testTheWheelEventsCarryTheirPhaseAndMomentum`` so no other test can be
    /// fooled by a phase that was never applied.
    private func wheel(
        dx: CGFloat = 0,
        dy: CGFloat = 0,
        phase: CGScrollPhase? = nil,
        momentum: CGMomentumScrollPhase = .none,
        precise: Bool = true,
        units: CGScrollEventUnit = .pixel,
        timestamp: TimeInterval? = nil,
        at point: CGPoint
    ) throws -> NSEvent {
        let isLineWheel = !precise && units == .line
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: isLineWheel ? Self.lineWheelSource : nil,
                units: units,
                wheelCount: 2,
                wheel1: Int32(dy),
                wheel2: Int32(dx),
                wheel3: 0
            ),
            "the synthetic wheel could not be built"
        )
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(phase?.rawValue ?? 0)
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: Int64(momentum.rawValue)
        )
        if isLineWheel {
            // A nil source shares its scroll state with every other synthetic
            // or real event in the session, and AppKit reads the axis set at
            // conversion. Restate the lines in the fields it reads so a line
            // wheel always carries exactly the requested delta.
            let axis1 = Int64(Int32(dy))
            let axis2 = Int64(Int32(dx))
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: axis1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: axis2)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: axis1 << 16)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: axis2 << 16)
        }
        if let timestamp {
            event.timestamp = CGEventTimestamp(timestamp * 1_000_000_000)
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: point.x, y: screenHeight - point.y)
        return try XCTUnwrap(NSEvent(cgEvent: event), "the wheel is not an NSEvent")
    }

    func testTheWheelEventsCarryTheirPhaseAndMomentum() throws {
        let point = CGPoint(x: 120, y: 240)
        let event = try wheel(
            dx: -12,
            dy: -4,
            phase: .began,
            momentum: .begin,
            at: point
        )
        XCTAssertTrue(event.hasPreciseScrollingDeltas, "the event is not a precise wheel")
        XCTAssertEqual(event.phase, .began)
        XCTAssertEqual(event.phase.rawValue, NSEvent.Phase.began.rawValue)
        XCTAssertEqual(event.momentumPhase, .began)
        XCTAssertEqual(event.momentumPhase.rawValue, NSEvent.Phase.began.rawValue)
        XCTAssertEqual(event.scrollingDeltaX, -12, accuracy: 0.001)
        XCTAssertEqual(event.scrollingDeltaY, -4, accuracy: 0.001)
        XCTAssertEqual(HUD.screenPoint(of: event), point)

        // Every phase the rail distinguishes maps to the AppKit value the
        // production code reads, not to the Core Graphics raw value.
        let phases: [(CGScrollPhase, NSEvent.Phase)] = [
            (.began, .began),
            (.changed, .changed),
            (.ended, .ended),
            (.cancelled, .cancelled),
            (.mayBegin, .mayBegin),
        ]
        for (coreGraphics, appKit) in phases {
            let phased = try wheel(phase: coreGraphics, at: point)
            XCTAssertEqual(phased.phase, appKit, "\(coreGraphics) did not arrive as \(appKit)")
        }
        let momentums: [(CGMomentumScrollPhase, NSEvent.Phase)] = [
            (.begin, .began),
            (.continuous, .changed),
            (.end, .ended),
        ]
        for (coreGraphics, appKit) in momentums {
            let phased = try wheel(momentum: coreGraphics, at: point)
            XCTAssertEqual(
                phased.momentumPhase,
                appKit,
                "\(coreGraphics) did not arrive as \(appKit)"
            )
        }
    }

    // MARK: - The gesture

    func testAVerticalPreciseWheelOverTheRailMovesIt() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let point = fixture.point

        // A trackpad pushed down the page: the rail has no vertical travel, so
        // the travel is mapped onto its own.
        XCTAssertTrue(
            fixture.hud.debugDeliverWheel(
                try wheel(dy: -30, phase: .began, at: point),
                at: point
            ),
            "the card did not take a delivered vertical rail gesture"
        )
        XCTAssertEqual(railOffset(fixture), 30, accuracy: 0.5, "the vertical wheel was dropped")

        // The same gesture, still vertical even though the horizontal delta
        // wins this event's ratio. The axis is the gesture's, not the event's.
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: 4, dy: -10, phase: .changed, at: point),
            at: point
        )
        XCTAssertEqual(railOffset(fixture), 40, accuracy: 0.5, "the latched axis changed mid-gesture")
    }

    func testAMixedAxisGestureMovesTheRailByTheAxisItBeganOn() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let point = fixture.point

        // Begins sideways: every event of the gesture reads its horizontal
        // travel, including the one whose vertical delta is larger.
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -10, dy: -2, phase: .began, at: point),
            at: point
        )
        XCTAssertEqual(railOffset(fixture), 10, accuracy: 0.5)

        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -4, dy: -10, phase: .changed, at: point),
            at: point
        )
        XCTAssertEqual(
            railOffset(fixture),
            14,
            accuracy: 0.5,
            "the diagonal event was rejected on its own"
        )

        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: 6, dy: -20, phase: .changed, at: point),
            at: point
        )
        XCTAssertEqual(railOffset(fixture), 8, accuracy: 0.5, "the reverse did not come back")

        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: 8, dy: 0, phase: .changed, at: point),
            at: point
        )
        XCTAssertEqual(railOffset(fixture), 0, accuracy: 0.5, "the rail scrolled past its start")
    }

    func testAZeroDeltaBeginningDoesNotLatchTheWrongAxis() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let point = fixture.point

        // AppKit can begin a gesture with a stationary event. The direction is
        // still the gesture's, and it arrives on the next event.
        XCTAssertTrue(
            fixture.hud.debugDeliverWheel(
                try wheel(dx: 0, dy: 0, phase: .began, at: point),
                at: point
            ),
            "the card did not take the rail gesture's stationary beginning"
        )
        XCTAssertEqual(railOffset(fixture), 0, accuracy: 0.5)

        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -10, dy: 0, phase: .changed, at: point),
            at: point
        )
        XCTAssertEqual(
            railOffset(fixture),
            10,
            accuracy: 0.5,
            "a stationary beginning latched the vertical axis"
        )
    }

    func testAPhasedGestureSurvivesALongPauseAndPointerDrift() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let point = fixture.point
        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: fixture.hud.debugPanel.frame,
            cardSize: HUD.transcriptSize(text: fixture.card.original, rewrite: fixture.card),
            topInset: HUD.shadowPadding
        )
        let bodyFrame = HUD.rewriteBodyFrame(cardFrame: cardFrame, card: fixture.card)
        let away = CGPoint(x: bodyFrame.midX, y: bodyFrame.midY)

        // The events are more than half a second apart, and by the third one
        // the pointer is over the transcript. A phaseful gesture still belongs
        // to the rail, and its latched vertical axis still reads vertical
        // travel even though this event's horizontal delta is larger.
        let started = ProcessInfo.processInfo.systemUptime
        let secondAt = started + 0.1
        let thirdAt = secondAt + 0.8
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dy: -10, phase: .began, timestamp: started, at: point),
            at: point
        )
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dy: -10, phase: .changed, timestamp: secondAt, at: point),
            at: point
        )
        let third = try wheel(
            dx: -12,
            dy: 4,
            phase: .changed,
            timestamp: thirdAt,
            at: away
        )
        XCTAssertGreaterThan(
            third.timestamp - secondAt,
            0.5,
            "the synthetic event did not carry a pause longer than half a second"
        )
        _ = fixture.hud.debugDeliverWheel(third, at: away)
        XCTAssertEqual(
            railOffset(fixture),
            16,
            accuracy: 0.5,
            "the paused gesture lost its owner or axis when the pointer drifted"
        )
    }

    func testANonPreciseWheelUsesTheRailsLineHeight() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        fixture.rail.horizontalLineScroll = 12
        // The rail is placed at its first style so the travel below is read
        // from a known position: while the opening correction has not been
        // decided the card applies a wheel to the intended origin, so the
        // record is placed with the clip.
        injectResidue(0, into: fixture)
        fixture.hud.debugSetRailIntendedOrigin(.zero)
        let before = railOffset(fixture)
        let event = try wheel(dy: -3, precise: false, units: .line, at: fixture.point)
        XCTAssertFalse(event.hasPreciseScrollingDeltas, "the event is not a line wheel")
        XCTAssertEqual(
            event.scrollingDeltaY,
            -3,
            accuracy: 0.001,
            "the line wheel did not carry three lines"
        )
        XCTAssertTrue(event.phase.isEmpty, "a legacy wheel unexpectedly carried a phase")

        XCTAssertTrue(
            fixture.hud.debugDeliverWheel(event, at: fixture.point),
            "the card left a legacy rail wheel to a native view"
        )
        XCTAssertEqual(
            railOffset(fixture),
            before + 36,
            accuracy: 0.5,
            "three lines did not use the rail's twelve point line height"
        )
    }

    func testANonPreciseBackgroundWheelUsesTheBodysLineHeight() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let clip = fixture.body.contentView
        let maximum = max(
            0,
            (fixture.body.documentView?.frame.height ?? 0) - clip.bounds.height
        )
        XCTAssertGreaterThan(maximum, 100, "the fixture body has no room to scroll")
        clip.scroll(to: NSPoint(x: 0, y: maximum / 2))
        fixture.body.reflectScrolledClipView(clip)
        let middle = clip.bounds.origin.y
        fixture.body.verticalLineScroll = 14

        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: fixture.hud.debugPanel.frame,
            cardSize: HUD.transcriptSize(text: fixture.card.original, rewrite: fixture.card),
            topInset: HUD.shadowPadding
        )
        let bodyFrame = HUD.rewriteBodyFrame(cardFrame: cardFrame, card: fixture.card)
        let point = CGPoint(x: bodyFrame.midX, y: bodyFrame.midY)
        let event = try wheel(dy: -3, precise: false, units: .line, at: point)
        XCTAssertEqual(
            event.scrollingDeltaY,
            -3,
            accuracy: 0.001,
            "the line wheel did not carry three lines"
        )

        _ = fixture.hud.debugHandleScrollEvent(event, at: point)
        XCTAssertEqual(
            clip.bounds.origin.y,
            min(maximum, middle + 42),
            accuracy: 0.5,
            "three lines did not use the body's fourteen point line height"
        )
    }

    func testTheRailKeepsTheGestureWhenThePointerLeavesIt() throws {
        let delivered = try makeFixture()
        defer { close(delivered) }
        let away = CGPoint(x: delivered.point.x, y: delivered.point.y + pointAway)

        _ = delivered.hud.debugDeliverWheel(
            try wheel(dy: -20, phase: .began, at: delivered.point),
            at: delivered.point
        )
        _ = delivered.hud.debugDeliverWheel(
            try wheel(dy: -20, phase: .changed, at: away),
            at: away
        )
        XCTAssertEqual(
            railOffset(delivered),
            40,
            accuracy: 0.5,
            "the delivered gesture was dropped when the pointer left the row"
        )

        let background = try makeFixture()
        defer { close(background) }
        _ = background.hud.debugHandleScrollEvent(
            try wheel(dx: -20, phase: .began, at: background.point),
            at: background.point
        )
        _ = background.hud.debugHandleScrollEvent(
            try wheel(dx: -20, phase: .changed, at: away),
            at: away
        )
        XCTAssertEqual(
            railOffset(background),
            40,
            accuracy: 0.5,
            "the background gesture was dropped when the pointer left the row"
        )
    }

    func testMomentumKeepsTheRailUntilItEndsAndTheNextGestureIsFresh() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let point = fixture.point
        let away = CGPoint(x: point.x, y: point.y + pointAway)

        _ = fixture.hud.debugDeliverWheel(
            try wheel(dy: -20, phase: .began, at: point),
            at: point
        )
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dy: -10, phase: .ended, at: point),
            at: point
        )
        XCTAssertEqual(railOffset(fixture), 30, accuracy: 0.5, "the ended event was dropped")

        // The fingers are gone and the pointer has moved: momentum still
        // belongs to the rail that was flicked.
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dy: -10, momentum: .begin, at: away),
            at: away
        )
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dy: -10, momentum: .continuous, at: away),
            at: away
        )
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dy: -5, momentum: .end, at: away),
            at: away
        )
        XCTAssertEqual(
            railOffset(fixture),
            55,
            accuracy: 0.5,
            "momentum stopped at the pointer instead of the rail"
        )

        // The momentum is over. A new gesture that begins away from the row is
        // the body's, and must not carry the rail's stale ownership.
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -100, dy: 0, phase: .began, at: away),
            at: away
        )
        XCTAssertEqual(
            railOffset(fixture),
            55,
            accuracy: 0.5,
            "a new gesture away from the row kept the old rail ownership"
        )

        // A new gesture that begins on the row is fresh: it reads its own axis.
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: 10, dy: 0, phase: .began, at: point),
            at: point
        )
        XCTAssertEqual(
            railOffset(fixture),
            45,
            accuracy: 0.5,
            "the next rail gesture inherited the previous axis or owner"
        )
    }

    func testTheRailStopsAtBothEndsWithoutOverflow() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let point = fixture.point
        let maximum = railMaximum(fixture)
        XCTAssertGreaterThan(maximum, 500, "the fixture rail has no room to scroll")

        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -10_000, phase: .began, at: point),
            at: point
        )
        XCTAssertEqual(railOffset(fixture), maximum, accuracy: 0.5, "the rail overflowed its end")

        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -10_000, phase: .changed, at: point),
            at: point
        )
        XCTAssertEqual(railOffset(fixture), maximum, accuracy: 0.5, "the rail overflowed again")

        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: 10_000, phase: .changed, at: point),
            at: point
        )
        XCTAssertEqual(railOffset(fixture), 0, accuracy: 0.5, "the rail scrolled past its start")
    }

    func testTheRailHandlesOneTwelveAndLongCustomLabels() throws {
        let one = try makeFixture(choices: [RewriteStyle.builtIns[0]])
        defer { close(one) }
        XCTAssertEqual(railMaximum(one), 0, accuracy: 0.5, "one style needed a scroll")
        XCTAssertTrue(
            one.hud.debugDeliverWheel(
                try wheel(dy: -30, phase: .began, at: one.point),
                at: one.point
            ),
            "the card left a rail gesture to a row that cannot scroll"
        )
        XCTAssertEqual(railOffset(one), 0, accuracy: 0.5)

        let twelve = try makeFixture()
        defer { close(twelve) }
        XCTAssertGreaterThan(railMaximum(twelve), 500, "twelve long labels fit the rail")
        _ = twelve.hud.debugDeliverWheel(
            try wheel(dy: -30, phase: .began, at: twelve.point),
            at: twelve.point
        )
        XCTAssertEqual(
            railOffset(twelve),
            30,
            accuracy: 0.5,
            "the long custom labels broke the vertical mapping"
        )
    }

    // MARK: - Selection and completion

    func testSelectionCompletionAndChipClicksLeaveTheRailAlone() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        setRail(fixture, to: 120)
        XCTAssertEqual(railOffset(fixture), 120, accuracy: 0.5)

        var card = fixture.card
        XCTAssertTrue(card.select(versionID: 1), "the fixture has no first version to select")
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
            text: "A third version, completed while the rail was being read.",
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

        XCTAssertTrue(card.select(versionID: 2), "the fixture has no second version to select")
        fixture.hud.setRewrite(card)
        settle(fixture.hud)
        XCTAssertEqual(
            railOffset(fixture),
            120,
            accuracy: 0.5,
            "a chip selection recentred the rail"
        )
    }

    func testAVersionArrowRevealsItsStyleButACompletionDoesNot() throws {
        var reveal = RewriteChipReveal()
        XCTAssertFalse(reveal.consume(selectedVersionID: 2), "an empty request revealed a style")

        reveal.request(versionID: 2)
        XCTAssertTrue(reveal.consume(selectedVersionID: 2), "the arrow's target was not revealed")
        XCTAssertFalse(reveal.consume(selectedVersionID: 2), "the request was consumed twice")

        reveal.request(versionID: 2)
        XCTAssertFalse(
            reveal.consume(selectedVersionID: 3),
            "a completion that arrived before the arrow's selection was revealed"
        )
        XCTAssertFalse(
            reveal.consume(selectedVersionID: 2),
            "a stale arrow request survived its mismatched selection"
        )

        reveal.request(versionID: 3)
        reveal.clear()
        XCTAssertFalse(
            reveal.consume(selectedVersionID: 3),
            "a cleared request still moved the rail"
        )
    }

    func testTheNextArrowRevealsTheStyleItSelects() throws {
        _ = NSApplication.shared
        let styles = longStyles()
        var versions = [RewriteVersion.original(text: "The words.")]
        for (index, style) in styles.enumerated() {
            versions.append(
                RewriteVersion(
                    id: index + 1,
                    origin: .style(style.id),
                    title: style.title,
                    text: "A rewrite of the words.",
                    ordinal: index + 1
                )
            )
        }
        let initialVersionID = 8
        var selected = initialVersionID
        let moved = expectation(description: "the next arrow moved the selection")
        let rowWidth = HUDState.transcriptWidth - HUDTheme.padding * 2
        let row = ArrowNavigationRow(
            choices: styles,
            versions: versions,
            initialVersionID: initialVersionID,
            onChange: { id in
                selected = id
                moved.fulfill()
            }
        )
        .frame(width: rowWidth, height: HUDRewriteLayout.chipHeight)

        let host = HUDHostingView(rootView: AnyView(row))
        host.frame = NSRect(x: 0, y: 0, width: rowWidth, height: HUDRewriteLayout.chipHeight)
        let panel = OffscreenHUDPanel(size: host.frame.size)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        // The row opens on the selected style. Put it back at its first chip:
        // from here only the arrow's reveal request may move it.
        spin(for: 0.4)
        let rail = try XCTUnwrap(HUD.chipRowScrollView(in: host), "the row has no rail")
        rail.contentView.scroll(to: .zero)
        rail.reflectScrolledClipView(rail.contentView)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            rail.contentView.bounds.origin.x,
            0,
            accuracy: 0.5,
            "the rail did not start at its first chip"
        )

        // The trailing arrow is the last control in the row.
        let point = NSPoint(
            x: rowWidth - HUDRewriteLayout.versionArrowWidth / 2,
            y: HUDRewriteLayout.chipHeight / 2
        )
        XCTAssertNotNil(host.hitTest(point), "the hosting view did not hit-test the next arrow")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )
            )
            panel.sendEvent(event)
        }

        wait(for: [moved], timeout: 2)
        spin(for: 0.4)
        XCTAssertEqual(selected, initialVersionID + 1, "the arrow did not move the selection")
        XCTAssertGreaterThan(
            rail.contentView.bounds.origin.x,
            50,
            "the next arrow changed the selection without revealing its style"
        )
    }

    func testTheRowStillOpensOnTheSelectedStyle() throws {
        _ = NSApplication.shared
        let styles = longStyles()
        let style = styles[10]
        let versions = [
            RewriteVersion.original(text: "The words."),
            RewriteVersion(
                id: 1,
                origin: .style(style.id),
                title: style.title,
                text: "A rewrite of the words.",
                ordinal: 1
            ),
        ]
        let row = RewriteChipRow(
            choices: styles,
            activeStyleID: nil,
            isStreaming: false,
            reduceMotion: true,
            versions: versions,
            selectedVersionID: 1,
            onSelect: { _ in }
        )
        .frame(width: HUDState.transcriptWidth - HUDTheme.padding * 2)
        let host = NSHostingView(rootView: AnyView(row))
        host.frame = NSRect(x: 0, y: 0, width: 528, height: HUDRewriteLayout.chipHeight)
        let panel = OffscreenHUDPanel(size: host.frame.size)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        let rail = try XCTUnwrap(HUD.chipRowScrollView(in: host), "the row has no rail")
        XCTAssertGreaterThan(
            rail.contentView.bounds.origin.x,
            0,
            "the row opened on its first style instead of the selected one"
        )
    }

    // MARK: - Routing

    func testDeliveredAndBackgroundGesturesMoveTheRailTheSameWay() throws {
        let delivered = try makeFixture()
        defer { close(delivered) }
        XCTAssertTrue(
            delivered.hud.debugDeliverWheel(
                try wheel(dy: -30, phase: .began, at: delivered.point),
                at: delivered.point
            ),
            "the delivered vertical gesture was not swallowed"
        )
        XCTAssertEqual(railOffset(delivered), 30, accuracy: 0.5)

        let background = try makeFixture()
        defer { close(background) }
        _ = background.hud.debugHandleScrollEvent(
            try wheel(dy: -30, phase: .began, at: background.point),
            at: background.point
        )
        XCTAssertEqual(
            railOffset(background),
            30,
            accuracy: 0.5,
            "the background vertical gesture did not match the delivered one"
        )

        // A horizontal gesture is applied by the card too, and swallowed, so
        // AppKit cannot apply the same event a second time.
        let horizontal = try makeFixture()
        defer { close(horizontal) }
        XCTAssertTrue(
            horizontal.hud.debugDeliverWheel(
                try wheel(dx: -30, phase: .began, at: horizontal.point),
                at: horizontal.point
            ),
            "the delivered horizontal gesture was left to a native view"
        )
        XCTAssertEqual(
            railOffset(horizontal),
            30,
            accuracy: 0.5,
            "the horizontal gesture was applied twice or not at all"
        )
    }

    /// A gesture delivered while the card is arriving lands on the person's
    /// position, not on the appearance's residue.
    ///
    /// The card's appearance leaves the rail's clip a residue inside its
    /// content, and at the moment a gesture lands that residue is not a
    /// position anybody chose. The card applies the travel to the position the
    /// person last gave the rail, so a wheel of 30 points from a rail that
    /// started at zero lands on 30 whatever residue the clip was carrying. The
    /// residue is injected here rather than waited for, so the test covers both
    /// scales the card is measured on: one device pixel is a point at 1x and
    /// half a point at 2x.
    func testAGestureThroughTheOpeningResidueLandsOnThePersonsPosition() throws {
        for residue in [1.0, 0.5] {
            let fixture = try makeFixture(holdTheEntrance: true)
            defer { close(fixture) }
            XCTAssertFalse(
                fixture.hud.debugAppearanceAtRest,
                "the card arrived before the residue could be injected, so the gesture did not meet the appearance"
            )
            let intended = fixture.hud.debugRailIntendedOrigin.x
            injectResidue(residue, into: fixture)
            XCTAssertEqual(
                railOffset(fixture),
                residue,
                accuracy: 1e-9,
                "the injected residue did not reach the clip"
            )
            XCTAssertTrue(
                fixture.hud.debugDeliverWheel(
                    try wheel(dy: -30, phase: .began, at: fixture.point),
                    at: fixture.point
                ),
                "the delivered vertical gesture was not swallowed"
            )
            fixture.hud.debugHoldTheEntrance = false
            XCTAssertTrue(
                waitForTheRailToSettle(fixture.hud),
                "the card never came to rest with its opening correction decided"
            )
            XCTAssertEqual(
                railOffset(fixture),
                intended + 30,
                accuracy: 0.05,
                "the gesture inherited the appearance's \(residue) point residue"
            )
        }
    }

    /// A one-pixel wheel through its own residue is still the person's choice.
    ///
    /// The appearance can leave exactly one device pixel on the clip while the
    /// card intends the first style. A wheel of that same travel targets the
    /// position the clip already shows, but it is a logical movement and the
    /// card has to record it or the opening correction will take it back.
    func testAOnePixelWheelThroughItsOwnResidueBecomesThePersonsPosition() throws {
        let fixture = try makeFixture(holdTheEntrance: true)
        defer { close(fixture) }
        let pixel = 1 / fixture.hud.debugPanel.backingScaleFactor
        XCTAssertFalse(
            fixture.hud.debugRailPositionRestored,
            "the card decided the opening correction before the wheel could meet the residue"
        )
        injectResidue(pixel, into: fixture)
        fixture.hud.debugSetRailIntendedOrigin(.zero)
        XCTAssertEqual(
            railOffset(fixture),
            pixel,
            accuracy: 1e-9,
            "the clip does not carry exactly one device pixel of residue"
        )
        XCTAssertEqual(
            fixture.hud.debugRailIntendedOrigin.x,
            0,
            accuracy: 1e-9,
            "the card does not intend the first style while the clip carries the residue"
        )
        let event = ExactRailWheelEvent(
            deltaX: -pixel,
            deltaY: 0,
            phase: .began,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        XCTAssertTrue(
            fixture.hud.debugDeliverWheel(event, at: fixture.point),
            "the routed one-pixel wheel was left to a native view"
        )
        XCTAssertEqual(
            fixture.hud.debugRailIntendedOrigin.x,
            pixel,
            accuracy: 1e-9,
            "the one-pixel wheel was not recorded as the person's position"
        )
        fixture.hud.debugHoldTheEntrance = false
        XCTAssertTrue(
            waitForTheRailToSettle(fixture.hud),
            "the card never came to rest with its opening correction decided"
        )
        XCTAssertEqual(
            railOffset(fixture),
            pixel,
            accuracy: 0.05,
            "the opening correction swallowed the one-pixel wheel"
        )
    }

    /// An explicit wheel ends the reveal follow, so later residue is corrected.
    ///
    /// A far write arms the card's short follow of a reveal. An explicit wheel
    /// after it is the person's position, and a later in-window write is
    /// residue: the opening correction must return the rail to the wheel's
    /// position rather than keep the residue.
    func testAWheelEndsTheRevealFollowSoLaterResidueIsNotKept() throws {
        let fixture = try makeFixture(holdTheEntrance: true)
        defer { close(fixture) }
        XCTAssertGreaterThanOrEqual(
            railMaximum(fixture),
            120,
            "the rail cannot hold the far write and the wheel's travel"
        )
        XCTAssertFalse(
            fixture.hud.debugRailPositionRestored,
            "the card decided the opening correction before the reveal could be armed"
        )
        injectResidue(100, into: fixture)
        XCTAssertEqual(
            fixture.hud.debugRailIntendedOrigin.x,
            100,
            accuracy: 1e-9,
            "the far write did not arm the card's follow"
        )
        XCTAssertTrue(
            fixture.hud.debugRailFollowsWrites,
            "the card was not following writes after the far write"
        )
        let event = ExactRailWheelEvent(
            deltaX: -10,
            deltaY: 0,
            phase: .began,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        XCTAssertTrue(
            fixture.hud.debugDeliverWheel(event, at: fixture.point),
            "the routed wheel was left to a native view"
        )
        XCTAssertEqual(
            railOffset(fixture),
            110,
            accuracy: 1e-9,
            "the wheel did not move the rail ten points from the far write"
        )
        XCTAssertEqual(
            fixture.hud.debugRailIntendedOrigin.x,
            110,
            accuracy: 1e-9,
            "the wheel did not record its landing position"
        )
        XCTAssertFalse(
            fixture.hud.debugRailFollowsWrites,
            "the explicit wheel did not end the reveal follow"
        )
        XCTAssertLessThanOrEqual(
            1.0,
            HUD.railResidueWindow(backingScale: 2),
            "one point is not inside the residue window on a 2x display"
        )
        XCTAssertLessThanOrEqual(
            1.0,
            HUD.railResidueWindow(backingScale: 1),
            "one point is not inside the residue window on a 1x display"
        )
        injectResidue(111, into: fixture)
        XCTAssertEqual(
            fixture.hud.debugRailIntendedOrigin.x,
            110,
            accuracy: 1e-9,
            "the in-window write overwrote the wheel's position"
        )
        fixture.hud.debugHoldTheEntrance = false
        XCTAssertTrue(
            waitForTheRailToSettle(fixture.hud),
            "the card never came to rest with its opening correction decided"
        )
        XCTAssertEqual(
            railOffset(fixture),
            110,
            accuracy: 0.05,
            "the opening correction kept the residue instead of the wheel's position"
        )
    }

    /// A wheel after an unobserved reveal starts from the revealed position.
    ///
    /// A style the row reveals before the card has recorded it can leave the
    /// clip far from the intended origin while the opening correction is still
    /// undecided. That distance is a position somebody chose, not appearance
    /// residue, so a wheel has to continue from it.
    func testAWheelOnAnUnobservedRevealKeepsTheRevealedPosition() throws {
        _ = NSApplication.shared
        var card = RewriteCard(
            original: HUDPreview.longTranscript,
            choices: longStyles()
        )
        let first = card.choices[0]
        let second = card.choices[1]
        card.append(id: 1, style: first, text: HUDPreview.longTranscript, warning: nil)
        card.append(id: 2, style: second, text: HUDPreview.longTranscript, warning: nil)
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        hud.debugHoldTheOpeningCorrection = true
        hud.showTranscript(
            text: card.original,
            delivery: .copied,
            elapsed: "4:18"
        )
        hud.setRewrite(card)
        hud.debugPointer(inside: true)
        defer {
            hud.hide()
            spin(for: 0.4)
        }

        // The card comes to rest while the opening correction is held
        // undecided. The reveal is placed at rest rather than earlier in the
        // entrance, so no later appearance frame can move the clip before the
        // wheel is routed.
        let restDeadline = Date().addingTimeInterval(4)
        while Date() < restDeadline, !hud.debugAppearanceAtRest {
            hud.debugRootView.layoutSubtreeIfNeeded()
            RunLoop.main.run(
                mode: .default,
                before: min(restDeadline, Date().addingTimeInterval(0.002))
            )
        }
        XCTAssertTrue(
            hud.debugAppearanceAtRest,
            "the card never came to rest with its opening correction undecided"
        )
        hud.debugRootView.layoutSubtreeIfNeeded()
        let rail = try XCTUnwrap(
            HUD.chipRowScrollView(in: hud.debugRootView),
            "the card has no rail while its opening correction is undecided"
        )
        let size = HUD.transcriptSize(text: card.original, rewrite: card)
        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: hud.debugPanel.frame,
            cardSize: size,
            topInset: HUD.shadowPadding
        )
        let band = HUD.rewriteChipRowFrame(cardFrame: cardFrame, card: card)
        let point = CGPoint(x: band.midX, y: band.midY)
        let maximum = max(
            0,
            (rail.documentView?.frame.width ?? 0) - rail.contentView.bounds.width
        )
        XCTAssertLessThanOrEqual(
            130,
            maximum,
            "the rail cannot hold the revealed position and the wheel's travel"
        )

        rail.contentView.scroll(to: NSPoint(x: 100, y: 0))
        rail.reflectScrolledClipView(rail.contentView)
        hud.debugSetRailIntendedOrigin(.zero)
        XCTAssertEqual(
            rail.contentView.bounds.origin.x,
            100,
            accuracy: 1e-9,
            "the revealed position did not reach the clip"
        )
        XCTAssertEqual(
            hud.debugRailIntendedOrigin.x,
            0,
            accuracy: 1e-9,
            "the card recorded the reveal before this wheel"
        )
        XCTAssertFalse(
            hud.debugRailPositionRestored,
            "the opening correction decided before the wheel could meet the undecided reveal"
        )

        let event = ExactRailWheelEvent(
            deltaX: -30,
            deltaY: 0,
            phase: .began,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        XCTAssertTrue(
            hud.debugDeliverWheel(event, at: point),
            "the routed wheel after the reveal was left to a native view"
        )
        XCTAssertEqual(
            rail.contentView.bounds.origin.x,
            130,
            accuracy: 1e-9,
            "the wheel reset the reveal instead of moving from it"
        )
        XCTAssertEqual(
            hud.debugRailIntendedOrigin.x,
            130,
            accuracy: 1e-9,
            "the wheel did not record the revealed position plus its travel"
        )
        hud.debugHoldTheOpeningCorrection = false
        XCTAssertTrue(
            waitForTheRailToSettle(hud),
            "the card never came to rest with its opening correction decided"
        )
        XCTAssertEqual(
            rail.contentView.bounds.origin.x,
            130,
            accuracy: 0.05,
            "the opening correction did not keep the reveal plus the wheel"
        )
    }

    /// A logical x move clears a vertical residue already held by the clip.
    ///
    /// The style rail has no vertical travel to hold a y residue. A scroll view
    /// with both ranges does, and it shows the full clip origin that has to be
    /// compared before an AppKit write is skipped.
    func testScrollRailComparesTheFullClipOriginBeforeSkippingTheWrite() {
        let document = NSView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200)
        )
        let clipRect = NSRect(x: 0, y: 0, width: 100, height: 50)
        let scrollView = NSScrollView(frame: clipRect)
        scrollView.documentView = document
        scrollView.contentView.scroll(to: NSPoint(x: 1, y: 0.5))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin,
            NSPoint(x: 1, y: 0.5),
            "the vertical residue did not reach the clip"
        )
        XCTAssertTrue(
            HUD.scrollRail(scrollView: scrollView, step: -1, base: 0),
            "the logical x move was not accepted"
        )
        XCTAssertEqual(
            scrollView.contentView.bounds.origin,
            NSPoint(x: 1, y: 0),
            "the scroll left the clip's vertical residue in place"
        )
    }

    /// A three-pixel residue on a 1x display is the appearance's, and is corrected.
    ///
    /// The residue's reach is a function of the backing scale, so a three-pixel
    /// residue is inside the window on a 1x display, where three pixels is
    /// three points, and outside it on a 2x display, where the window is 2.5
    /// points. The residue is left on the clip once the appearance has stopped
    /// while the correction is held undecided, so the correction reads it.
    func testTheCorrectionRestoresAThreePixelResidueOnAOneXDisplay() throws {
        let fixture = try makeFixture(holdTheOpeningCorrection: true)
        defer { close(fixture) }
        try XCTSkipUnless(
            fixture.hud.debugPanel.backingScaleFactor == 1,
            "a three-pixel residue is only the appearance's on a 1x display"
        )
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, !fixture.hud.debugAppearanceAtRest {
            fixture.hud.debugRootView.layoutSubtreeIfNeeded()
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.002))
            )
        }
        XCTAssertTrue(
            fixture.hud.debugAppearanceAtRest,
            "the card's appearance never came to rest, so the correction could not be tested"
        )
        XCTAssertFalse(
            fixture.hud.debugRailPositionRestored,
            "the opening correction decided before the residue could be left for it"
        )
        injectResidue(3.0, into: fixture)
        XCTAssertEqual(
            railOffset(fixture),
            3.0,
            accuracy: 1e-9,
            "the injected residue did not reach the clip"
        )
        fixture.hud.debugHoldTheOpeningCorrection = false
        XCTAssertTrue(
            waitForTheRailToSettle(fixture.hud),
            "the card never came to rest with its opening correction decided"
        )
        XCTAssertEqual(
            railOffset(fixture),
            0,
            accuracy: 0.05,
            "the opening correction left a three-pixel residue on a 1x display"
        )
    }

    func testARailGestureNeverPagesVersionsOrScrollsTheBody() throws {
        var previous = 0
        var next = 0
        var actions = HUDActions()
        actions.previousVersion = { previous += 1 }
        actions.nextVersion = { next += 1 }
        let fixture = try makeFixture(actions: actions)
        defer { close(fixture) }
        let bodyBefore = fixture.body.contentView.bounds.origin.y

        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -4, dy: -30, phase: .began, at: fixture.point),
            at: fixture.point
        )
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -30, dy: -4, phase: .changed, at: fixture.point),
            at: fixture.point
        )
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -30, dy: 0, momentum: .begin, at: fixture.point),
            at: fixture.point
        )
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dx: -30, dy: 0, momentum: .end, at: fixture.point),
            at: fixture.point
        )

        XCTAssertEqual(previous, 0, "a rail gesture paged to the previous version")
        XCTAssertEqual(next, 0, "a rail gesture paged to the next version")
        XCTAssertEqual(
            fixture.body.contentView.bounds.origin.y,
            bodyBefore,
            accuracy: 0.5,
            "a rail gesture moved the transcript body"
        )
    }

    func testHidingOrReplacingTheTranscriptCancelsRailOwnership() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dy: -20, phase: .began, at: fixture.point),
            at: fixture.point
        )
        XCTAssertEqual(railOffset(fixture), 20, accuracy: 0.5)

        // A new take is a new card: the gesture that belonged to the old rail
        // cannot move the new one.
        fixture.hud.showTranscript(
            text: HUDPreview.longTranscript,
            delivery: .copied,
            elapsed: "4:18"
        )
        var nextCard = RewriteCard(
            original: HUDPreview.longTranscript,
            choices: fixture.card.choices
        )
        nextCard.append(id: 1, style: nextCard.choices[0], text: "New words.", warning: nil)
        fixture.hud.setRewrite(nextCard)
        settle(fixture.hud)
        let newRail = try XCTUnwrap(HUD.chipRowScrollView(in: fixture.hud.debugRootView))
        let beforeTail = newRail.contentView.bounds.origin.x
        let away = CGPoint(x: fixture.point.x, y: fixture.point.y + pointAway)
        _ = fixture.hud.debugDeliverWheel(
            try wheel(dy: -40, momentum: .continuous, at: away),
            at: away
        )
        XCTAssertEqual(
            newRail.contentView.bounds.origin.x,
            beforeTail,
            accuracy: 0.5,
            "a momentum tail moved the new transcript's rail"
        )

        fixture.hud.hide()
        spin(for: 0.4)
        XCTAssertFalse(
            fixture.hud.debugPointerTrackingInstalled,
            "hiding the card left its pointer monitors installed"
        )
    }

    // MARK: - The countdown

    func testAResetCountdownKeepsTheLiveMonitors() throws {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        defer {
            hud.hide()
            spin(for: 0.4)
        }
        hud.showTranscript(text: "A transcript.", delivery: .copied, elapsed: "0:04")
        XCTAssertTrue(hud.debugPointerTrackingInstalled)
        XCTAssertEqual(hud.debugPointerTrackingInstallCount, 1)

        var card = RewriteCard(original: "A transcript.", choices: RewriteStyle.builtIns)
        hud.setRewrite(card)
        XCTAssertEqual(
            hud.debugPointerTrackingInstallCount,
            1,
            "setting the layer reinstalled the monitors"
        )

        hud.debugPointer(inside: false)
        hud.debugAdvanceDwell(by: 5)
        XCTAssertLessThan(try XCTUnwrap(hud.debugDwellRemaining), 58)

        card.phase = .rewriting(styleID: RewriteStyle.concise.id, title: RewriteStyle.concise.title)
        hud.setRewrite(card)
        XCTAssertEqual(
            hud.debugPointerTrackingInstallCount,
            1,
            "a phase change reinstalled the monitors"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(hud.debugDwellRemaining),
            55,
            "a phase change did not reset the countdown"
        )

        card.note = "Copied."
        hud.setRewrite(card)
        XCTAssertEqual(
            hud.debugPointerTrackingInstallCount,
            1,
            "a note reinstalled the monitors"
        )

        hud.hide()
        spin(for: 0.4)
        XCTAssertFalse(hud.debugPointerTrackingInstalled)
        hud.showTranscript(text: "Another transcript.", delivery: .copied, elapsed: "0:05")
        XCTAssertEqual(
            hud.debugPointerTrackingInstallCount,
            2,
            "a new presentation did not install a fresh pair of monitors"
        )
    }

    // MARK: - Fixtures

    private struct Fixture {
        let hud: HUD
        let card: RewriteCard
        let band: CGRect
        let rail: NSScrollView
        let body: NSScrollView

        var point: CGPoint { CGPoint(x: band.midX, y: band.midY) }
    }

    private func makeFixture(
        choices: [RewriteStyle]? = nil,
        actions: HUDActions = HUDActions(),
        holdTheEntrance: Bool = false,
        holdTheOpeningCorrection: Bool = false
    ) throws -> Fixture {
        _ = NSApplication.shared
        var card = RewriteCard(
            original: HUDPreview.longTranscript,
            choices: choices ?? longStyles()
        )
        let first = card.choices[0]
        let second = card.choices.count > 1 ? card.choices[1] : first
        card.append(
            id: 1,
            style: first,
            text: HUDPreview.longTranscript,
            warning: nil
        )
        card.append(
            id: 2,
            style: second,
            text: HUDPreview.longTranscript,
            warning: nil
        )
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        hud.actions = actions
        hud.debugHoldTheEntrance = holdTheEntrance
        hud.debugHoldTheOpeningCorrection = holdTheOpeningCorrection
        hud.showTranscript(
            text: card.original,
            delivery: .copied,
            elapsed: "4:18"
        )
        hud.setRewrite(card)
        hud.debugPointer(inside: true)
        settle(hud)

        let size = HUD.transcriptSize(text: card.original, rewrite: card)
        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: hud.debugPanel.frame,
            cardSize: size,
            topInset: HUD.shadowPadding
        )
        let band = HUD.rewriteChipRowFrame(cardFrame: cardFrame, card: card)
        XCTAssertFalse(band.isEmpty, "the fixture card drew no rail")
        let rail = try XCTUnwrap(
            HUD.chipRowScrollView(in: hud.debugRootView),
            "the fixture card has no rail"
        )
        let body = try XCTUnwrap(
            HUD.transcriptScrollView(in: hud.debugRootView),
            "the fixture card has no transcript body"
        )
        rail.contentView.scroll(to: .zero)
        rail.reflectScrolledClipView(rail.contentView)
        settle(hud)
        return Fixture(hud: hud, card: card, band: band, rail: rail, body: body)
    }

    /// The longest row the catalogue allows: every shipped style and six custom
    /// ones at the title cap.
    private func longStyles() -> [RewriteStyle] {
        let custom = (0 ..< 6).map { index in
            RewriteStyle(
                CustomRewriteStyle(
                    id: "custom-\(index)",
                    title: String(repeating: "W", count: CustomRewriteStyle.maximumTitleLength),
                    instruction: "Rewrite."
                )
            )
        }
        return RewriteStyle.builtIns + custom
    }

    private func railOffset(_ fixture: Fixture) -> CGFloat {
        fixture.rail.contentView.bounds.origin.x
    }

    private func railMaximum(_ fixture: Fixture) -> CGFloat {
        max(
            0,
            (fixture.rail.documentView?.frame.width ?? 0)
                - fixture.rail.contentView.bounds.width
        )
    }

    /// Leaves a known residue in the rail's clip, as the appearance does.
    ///
    /// - Parameters:
    ///   - x: the residue, in points.
    ///   - fixture: the card and its rail.
    private func injectResidue(_ x: CGFloat, into fixture: Fixture) {
        fixture.rail.contentView.scroll(to: NSPoint(x: x, y: 0))
        fixture.rail.reflectScrolledClipView(fixture.rail.contentView)
        fixture.hud.debugRootView.layoutSubtreeIfNeeded()
    }

    /// Waits, bounded, for the appearance to rest and the opening correction to be decided.
    ///
    /// The correction decides on the second frame on which the springs are at
    /// rest and the rail's frame is unchanged, so a rail that has come to rest
    /// has not necessarily been corrected yet.
    ///
    /// - Parameters:
    ///   - hud: the card.
    ///   - seconds: the longest to wait.
    /// - Returns: whether both happened inside the budget.
    private func waitForTheRailToSettle(_ hud: HUD, within seconds: TimeInterval = 4) -> Bool {
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

    private func setRail(_ fixture: Fixture, to x: CGFloat) {
        fixture.rail.contentView.scroll(to: NSPoint(x: x, y: 0))
        fixture.rail.reflectScrolledClipView(fixture.rail.contentView)
        settle(fixture.hud)
    }

    private func close(_ fixture: Fixture) {
        fixture.hud.hide()
        spin(for: 0.4)
    }

    private func settle(_ hud: HUD, for seconds: TimeInterval = 0.3) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            hud.debugRootView.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
        hud.debugRootView.layoutSubtreeIfNeeded()
    }

    private func spin(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }
}

/// A precise wheel whose point delta is not rounded to integer wheel units.
private final class ExactRailWheelEvent: NSEvent {
    private let exactDeltaX: CGFloat
    private let exactDeltaY: CGFloat
    private let exactPhase: NSEvent.Phase
    private let exactTimestamp: TimeInterval

    init(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase, timestamp: TimeInterval) {
        exactDeltaX = deltaX
        exactDeltaY = deltaY
        exactPhase = phase
        exactTimestamp = timestamp
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("unused")
    }

    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaX: CGFloat { exactDeltaX }
    override var scrollingDeltaY: CGFloat { exactDeltaY }
    override var deltaX: CGFloat { exactDeltaX }
    override var deltaY: CGFloat { exactDeltaY }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { exactPhase }
    override var momentumPhase: NSEvent.Phase { [] }
    override var isDirectionInvertedFromDevice: Bool { false }
    override var timestamp: TimeInterval { exactTimestamp }
}

/// A row whose selection really moves, the way the card's model moves it.
private struct ArrowNavigationRow: View {
    let choices: [RewriteStyle]
    let versions: [RewriteVersion]
    let initialVersionID: Int
    let onChange: (Int) -> Void

    @State private var selected: Int

    init(
        choices: [RewriteStyle],
        versions: [RewriteVersion],
        initialVersionID: Int,
        onChange: @escaping (Int) -> Void
    ) {
        self.choices = choices
        self.versions = versions
        self.initialVersionID = initialVersionID
        self.onChange = onChange
        _selected = State(initialValue: initialVersionID)
    }

    var body: some View {
        RewriteChipRow(
            choices: choices,
            activeStyleID: nil,
            isStreaming: false,
            reduceMotion: true,
            versions: versions,
            selectedVersionID: selected,
            onOriginal: { move(to: 0) },
            onSelect: { style in
                guard let version = versions.last(where: { $0.styleID == style.id }) else { return }
                move(to: version.id)
            },
            onPrevious: { move(to: max(0, selected - 1)) },
            onNext: { move(to: min(versions.count - 1, selected + 1)) }
        )
    }

    private func move(to id: Int) {
        guard id != selected else { return }
        selected = id
        onChange(id)
    }
}
