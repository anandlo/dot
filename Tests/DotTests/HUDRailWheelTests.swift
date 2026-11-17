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
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
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
        actions: HUDActions = HUDActions()
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
