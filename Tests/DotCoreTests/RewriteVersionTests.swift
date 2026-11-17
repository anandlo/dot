import CoreGraphics
import XCTest

@testable import DotCore

/// The version list, the swipe recogniser and the transition constants.
///
/// These are pure values, so the order, the boundaries, the threshold and the
/// reduced-motion rule are checked without a window, a trackpad or a clock.
final class RewriteVersionTests: XCTestCase {
    private let original = "Send the report to Priya by 5 pm."
    private let concise = "Send Priya the report by 5 pm."
    private let formal = "Please send the report to Priya by 5 pm."

    private func card() -> RewriteCard {
        RewriteCard(original: original, choices: RewriteStyle.builtIns)
    }

    // MARK: - The list

    func testTheOriginalIsVersionZeroAndIsNeverReplaced() {
        let card = card()
        XCTAssertEqual(card.versions.count, 1)
        XCTAssertEqual(card.versions[0].id, 0)
        XCTAssertEqual(card.versions[0].text, original)
        XCTAssertTrue(card.versions[0].isOriginal)
        XCTAssertEqual(card.selectedVersionID, 0)
        XCTAssertFalse(card.canGoPrevious)
        XCTAssertFalse(card.canGoNext)
    }

    func testAppendingKeepsRequestOrderAndSelectsTheNewVersion() {
        var card = card()
        card.append(id: 1, style: .concise, text: concise, warning: nil)
        card.append(id: 2, style: .prompt, text: formal, warning: nil)
        XCTAssertEqual(card.versions.map(\.id), [0, 1, 2])
        XCTAssertEqual(card.versions.map(\.title), ["Original", "Concise", "Agent prompt"])
        XCTAssertEqual(card.versions.map(\.text), [original, concise, formal])
        XCTAssertEqual(card.selectedVersionID, 2)
        XCTAssertEqual(card.lastNavigation, .next)
    }

    func testARepeatedStyleGetsADistinctIdAndOrdinal() {
        var card = card()
        card.append(id: 1, style: .concise, text: concise, warning: nil)
        card.append(id: 2, style: .concise, text: "Priya gets the report by 5 pm.", warning: nil)
        let repeats = card.versions.filter { $0.styleID == "concise" }
        XCTAssertEqual(repeats.map(\.id), [1, 2])
        XCTAssertEqual(repeats.map(\.ordinal), [1, 2])
        XCTAssertEqual(repeats.map(\.label), ["Concise", "Concise 2"])
        XCTAssertEqual(card.versionCount(styleID: "concise"), 2)
        XCTAssertEqual(card.latestVersion(styleID: "concise")?.id, 2)
    }

    func testNavigationStopsAtBothEndsAndNeverWraps() {
        var card = card()
        card.append(id: 1, style: .concise, text: concise, warning: nil)
        card.append(id: 2, style: .prompt, text: formal, warning: nil)
        XCTAssertEqual(card.selectedVersionID, 2)
        XCTAssertFalse(card.canGoNext)
        XCTAssertFalse(card.goNext())
        XCTAssertEqual(card.selectedVersionID, 2)
        XCTAssertTrue(card.goPrevious())
        XCTAssertEqual(card.selectedVersionID, 1)
        XCTAssertTrue(card.goPrevious())
        XCTAssertEqual(card.selectedVersionID, 0)
        XCTAssertFalse(card.goPrevious())
        XCTAssertEqual(card.selectedVersionID, 0)
        XCTAssertTrue(card.goNext())
        XCTAssertEqual(card.selectedVersionID, 1)
    }

    func testSelectingAVersionClearsADeliveryOutcomeButNotTheVersions() {
        var card = card()
        card.append(id: 1, style: .concise, text: concise, warning: nil)
        card.phase = .copied(versionID: 1)
        card.note = RewriteCard.clipboardNote
        XCTAssertTrue(card.select(versionID: 0))
        XCTAssertEqual(card.selectedVersionID, 0)
        XCTAssertEqual(card.phase, .offered)
        XCTAssertEqual(card.versions.count, 2)
        XCTAssertTrue(card.showsChips)
    }

    func testTheOriginalAndEveryRewriteAreIndependentlyVisible() {
        var card = card()
        XCTAssertFalse(card.showsRewrite)
        XCTAssertEqual(card.bodyText, original)
        card.append(id: 1, style: .concise, text: concise, warning: nil)
        XCTAssertTrue(card.showsRewrite)
        XCTAssertEqual(card.bodyText, concise)
        card.select(versionID: 0)
        XCTAssertFalse(card.showsRewrite)
        XCTAssertEqual(card.bodyText, original)
        XCTAssertEqual(card.versions.count, 2)
    }

    func testADraftIsShownInsteadOfTheSelectionWhileItStreams() {
        var card = card()
        card.append(id: 1, style: .concise, text: concise, warning: nil)
        card.phase = .rewriting(styleID: "formal", title: "Formal")
        card.draft = "Please send"
        XCTAssertTrue(card.showsRewrite)
        XCTAssertEqual(card.bodyText, "Please send")
        XCTAssertTrue(card.isStreaming, "a draft is only shown while the request runs")
        XCTAssertFalse(card.canDeliverSelected, "an arriving draft can be delivered")
    }

    func testABlockedDraftIsShownAndHidesTheChips() {
        var card = card()
        card.phase = .blocked(styleID: "concise", error: FaithfulnessCheck.numberChanged)
        card.draft = concise
        card.draftWarning = FaithfulnessCheck.nameChanged
        XCTAssertTrue(card.showsRewrite)
        XCTAssertTrue(card.isBlocked)
        XCTAssertFalse(card.showsChips)
        XCTAssertEqual(card.bodyText, concise)
        XCTAssertEqual(card.warning, FaithfulnessCheck.nameChanged)
        XCTAssertFalse(card.canDeliverSelected)
    }

    func testRebaseClearsOlderVersionsAndKeepsTheNewOriginal() {
        var card = card()
        card.append(id: 1, style: .concise, text: concise, warning: nil)
        let changed = "Send the report to Priya tomorrow."
        XCTAssertTrue(card.rebase(original: changed))
        XCTAssertEqual(card.original, changed)
        XCTAssertEqual(card.versions.count, 1)
        XCTAssertEqual(card.versions[0].text, changed)
        XCTAssertEqual(card.selectedVersionID, 0)
        XCTAssertEqual(card.note, RewriteCard.rebaseNote)
        XCTAssertFalse(card.showsRewrite)
    }

    // MARK: - The swipe

    func testFingersLeftAsksForTheNextVersion() {
        var swipe = RewriteSwipeGesture()
        swipe.begin()
        let direction = swipe.add(horizontal: -RewriteSwipeGesture.threshold, vertical: 0)
        XCTAssertEqual(direction, .next)
        XCTAssertNil(
            swipe.add(horizontal: -RewriteSwipeGesture.threshold, vertical: 0),
            "one gesture moved twice"
        )
    }

    func testFingersRightAsksForThePreviousVersion() {
        var swipe = RewriteSwipeGesture()
        swipe.begin()
        XCTAssertEqual(
            swipe.add(horizontal: RewriteSwipeGesture.threshold, vertical: 0),
            .previous
        )
    }

    func testAShortMoveIsNotASwipe() {
        var swipe = RewriteSwipeGesture()
        swipe.begin()
        XCTAssertNil(swipe.add(horizontal: -20, vertical: 0))
        XCTAssertNil(swipe.end())
    }

    func testAMostlyVerticalScrollIsNeverASwipe() {
        var swipe = RewriteSwipeGesture()
        swipe.begin()
        XCTAssertNil(swipe.add(horizontal: -10, vertical: 40))
        XCTAssertNil(
            swipe.add(horizontal: -100, vertical: 40),
            "a vertical scroll turned into a page after it moved sideways"
        )
        XCTAssertNil(swipe.end())
    }

    func testASingleLargeEventCanResolveOnEnd() {
        var swipe = RewriteSwipeGesture()
        swipe.begin()
        XCTAssertNil(swipe.add(horizontal: -10, vertical: 0))
        XCTAssertEqual(swipe.end(), nil)
        swipe.begin()
        _ = swipe.add(horizontal: -RewriteSwipeGesture.threshold - 1, vertical: 0)
        XCTAssertEqual(swipe.end(), nil, "the event already resolved")
    }

    func testCancelDropsTheGesture() {
        var swipe = RewriteSwipeGesture()
        swipe.begin()
        _ = swipe.add(horizontal: -30, vertical: 0)
        swipe.cancel()
        XCTAssertNil(swipe.end())
        XCTAssertEqual(swipe.horizontal, 0)
    }

    func testANonFiniteDeltaIsIgnored() {
        var swipe = RewriteSwipeGesture()
        swipe.begin()
        XCTAssertNil(swipe.add(horizontal: .nan, vertical: 0))
        XCTAssertNil(swipe.add(horizontal: .infinity, vertical: 0))
    }

    // MARK: - The scrolling preference

    /// The raw deltas AppKit sends for a finger movement.
    ///
    /// `NSEvent` inverts `scrollingDeltaX` and `scrollingDeltaY` for the
    /// person's scrolling preference and reports that it did in
    /// `isDirectionInvertedFromDevice`, so an event for a movement of the
    /// fingers is the movement with that sign applied.
    private func rawDeltas(
        ofFingers fingers: (horizontal: CGFloat, vertical: CGFloat),
        directionInverted: Bool
    ) -> (horizontal: CGFloat, vertical: CGFloat) {
        let sign: CGFloat = directionInverted ? -1 : 1
        return (fingers.horizontal * sign, fingers.vertical * sign)
    }

    /// One event, normalised the way the card normalises it.
    private func fingerDeltas(
        ofFingers fingers: (horizontal: CGFloat, vertical: CGFloat),
        directionInverted: Bool
    ) -> (horizontal: CGFloat, vertical: CGFloat) {
        let event = rawDeltas(ofFingers: fingers, directionInverted: directionInverted)
        return RewriteSwipeGesture.fingerDeltas(
            rawHorizontal: event.horizontal,
            rawVertical: event.vertical,
            directionInverted: directionInverted
        )
    }

    func testTheNormalisationRecoversTheFingerDeltasEitherWay() {
        for inverted in [false, true] {
            let event = rawDeltas(ofFingers: (-60, 12), directionInverted: inverted)
            let fingers = RewriteSwipeGesture.fingerDeltas(
                rawHorizontal: event.horizontal,
                rawVertical: event.vertical,
                directionInverted: inverted
            )
            XCTAssertEqual(
                fingers.horizontal,
                -60,
                accuracy: 0.001,
                "the sideways travel stayed in the event's convention with natural scrolling \(inverted ? "on" : "off")"
            )
            XCTAssertEqual(
                fingers.vertical,
                12,
                accuracy: 0.001,
                "the vertical travel stayed in the event's convention with natural scrolling \(inverted ? "on" : "off")"
            )
        }
    }

    /// One physical gesture, two Macs with different scrolling settings: the
    /// card pages the same way on both.
    func testOnePhysicalSwipePagesTheSameWayInBothPreferences() {
        for inverted in [false, true] {
            var swipe = RewriteSwipeGesture()
            swipe.begin()
            let fingers = fingerDeltas(ofFingers: (-60, 4), directionInverted: inverted)
            XCTAssertEqual(
                swipe.add(horizontal: fingers.horizontal, vertical: fingers.vertical),
                .next,
                "a leftward finger movement with natural scrolling \(inverted ? "on" : "off")"
            )
        }
    }

    func testAPhysicalSwipeToTheRightAsksForThePreviousVersionEitherWay() {
        for inverted in [false, true] {
            var swipe = RewriteSwipeGesture()
            swipe.begin()
            let fingers = fingerDeltas(ofFingers: (60, -3), directionInverted: inverted)
            XCTAssertEqual(
                swipe.add(horizontal: fingers.horizontal, vertical: fingers.vertical),
                .previous,
                "a rightward finger movement with natural scrolling \(inverted ? "on" : "off")"
            )
        }
    }

    /// A vertical scroll is reading, not paging, whichever way the system
    /// reported the two axes.
    func testAMostlyVerticalScrollIsRejectedInBothScrollingPreferences() {
        for inverted in [false, true] {
            var swipe = RewriteSwipeGesture()
            swipe.begin()
            let first = fingerDeltas(ofFingers: (-10, 40), directionInverted: inverted)
            XCTAssertNil(swipe.add(horizontal: first.horizontal, vertical: first.vertical))
            let second = fingerDeltas(ofFingers: (-100, 40), directionInverted: inverted)
            XCTAssertNil(
                swipe.add(horizontal: second.horizontal, vertical: second.vertical),
                "a vertical scroll turned into a page with natural scrolling \(inverted ? "on" : "off")"
            )
            XCTAssertNil(swipe.end())
        }
    }

    /// The card drops momentum before the classifier; this is the classifier's
    /// half of the same promise — a gesture that already resolved stays closed
    /// while the stream continues after the fingers lift.
    func testTheStreamAfterTheLiftCannotPageAgainEitherWay() {
        for inverted in [false, true] {
            var swipe = RewriteSwipeGesture()
            swipe.begin()
            let lift = fingerDeltas(ofFingers: (-60, 0), directionInverted: inverted)
            XCTAssertEqual(swipe.add(horizontal: lift.horizontal, vertical: lift.vertical), .next)
            let momentum = fingerDeltas(ofFingers: (-90, 0), directionInverted: inverted)
            XCTAssertNil(
                swipe.add(horizontal: momentum.horizontal, vertical: momentum.vertical),
                "an event after the lift paged again with natural scrolling \(inverted ? "on" : "off")"
            )
            XCTAssertNil(swipe.end())
        }
    }

    // MARK: - Motion

    func testTheTransitionIsBriefAndDirectional() {
        XCTAssertEqual(RewriteVersionMotion.duration, 0.18)
        XCTAssertEqual(
            RewriteVersionMotion.insertionOffset(direction: .next, reduceMotion: false),
            RewriteVersionMotion.distance
        )
        XCTAssertEqual(
            RewriteVersionMotion.insertionOffset(direction: .previous, reduceMotion: false),
            -RewriteVersionMotion.distance
        )
        XCTAssertEqual(
            RewriteVersionMotion.insertionOffset(direction: nil, reduceMotion: false),
            0
        )
    }

    func testReducedMotionHasNoSlide() {
        XCTAssertEqual(
            RewriteVersionMotion.insertionOffset(direction: .next, reduceMotion: true),
            0
        )
        XCTAssertEqual(
            RewriteVersionMotion.insertionOffset(direction: .previous, reduceMotion: true),
            0
        )
        XCTAssertFalse(RewriteVersionMotion.slides(reduceMotion: true))
        XCTAssertTrue(RewriteVersionMotion.slides(reduceMotion: false))
    }

    func testTheReviewWindowIsAMinute() {
        XCTAssertEqual(HUDDwell.rewriteSeconds, 60)
        XCTAssertEqual(HUDDwell.rewriteLeaveSeconds, 60)
        XCTAssertGreaterThan(HUDDwell.rewriteSeconds, HUDDwell.maximumSeconds * 2)
    }

    // MARK: - The saved snapshot

    func testASnapshotKeepsOnlyCompletedRewrites() {
        let snapshot = RewriteSnapshot(
            versions: [
                RewriteVersion.original(text: original),
                RewriteVersion(id: 1, origin: .style("concise"), title: "Concise", text: concise, ordinal: 1),
                RewriteVersion(id: 2, origin: .style("concise"), title: "Concise", text: "   ", ordinal: 2),
            ],
            selectedVersionID: 2
        )
        let normalized = snapshot.normalized()
        XCTAssertEqual(normalized?.versions.map(\.id), [1])
        XCTAssertEqual(normalized?.selectedVersionID, 0, "a selection of a version nobody kept survived")
    }

    func testAReadableVersionWithAnImpossibleIDIsKeptUnderASafeOne() {
        let snapshot = RewriteSnapshot(
            versions: [
                RewriteVersion(id: 3, origin: .style("gone"), title: "Removed", text: "kept", ordinal: 2, warning: "w"),
                RewriteVersion(id: 3, origin: .style("concise"), title: "Concise", text: "duplicate", ordinal: 1),
                RewriteVersion(id: Int.max, origin: .style("concise"), title: "Concise", text: "huge", ordinal: 1),
            ],
            selectedVersionID: 3
        )
        let normalized = snapshot.normalized()
        XCTAssertEqual(normalized?.versions.map(\.text), ["kept", "duplicate", "huge"])
        XCTAssertEqual(normalized?.versions.map(\.id), [3, 4, 5])
        XCTAssertEqual(normalized?.versions.first?.title, "Removed")
        XCTAssertEqual(normalized?.versions.first?.ordinal, 2)
        XCTAssertEqual(normalized?.versions.first?.warning, "w")
        XCTAssertEqual(normalized?.selectedVersionID, 3)
        XCTAssertEqual(normalized?.nextVersionID, 6)
    }

    func testAStoredSnapshotWithOneUnreadableVersionKeepsTheRest() throws {
        let file = #"""
        {"selectedVersionID":2,"versions":[
          {"id":1,"style":"concise","title":"Concise","text":"first","ordinal":1},
          {"id":"nonsense","style":"concise","text":""},
          {"id":2,"style":"formal","title":"Professional","text":"second","ordinal":1}
        ]}
        """#
        let saved = try JSONDecoder().decode(RewriteSnapshot.self, from: Data(file.utf8))
        XCTAssertEqual(saved.versions.map(\.text), ["first", "second"])
        XCTAssertEqual(saved.versions.map(\.id), [1, 2])
        XCTAssertEqual(saved.selectedVersionID, 2)
        XCTAssertEqual(saved.versions.last?.title, "Professional")
    }

    // MARK: - A remembered transcript

    func testASavedEntryIsRestoredEvenWhenNothingCanRunNow() {
        let saved = RewriteSnapshot(
            versions: [RewriteVersion(id: 1, origin: .style("concise"), title: "Concise", text: concise)],
            selectedVersionID: 1
        )
        XCTAssertEqual(RewriteRestorePlan.of(saved: saved, eligible: true), .saved(saved))
        XCTAssertEqual(
            RewriteRestorePlan.of(saved: saved, eligible: false),
            .saved(saved),
            "saved words were hidden because the rewrite is switched off"
        )
    }

    func testAnEntryWithoutVersionsOffersItsStylesWhenARequestCouldRun() {
        XCTAssertEqual(RewriteRestorePlan.of(saved: nil, eligible: true), .choices)
    }

    func testAnEntryShowsTheTranscriptAloneWhenNoRequestCouldRun() {
        XCTAssertEqual(RewriteRestorePlan.of(saved: nil, eligible: false), .none)
    }

    func testAnUnreadableSavedSnapshotFallsBackToTheChoices() {
        let empty = RewriteSnapshot(versions: [], selectedVersionID: 3)
        XCTAssertEqual(RewriteRestorePlan.of(saved: empty, eligible: true), .choices)
        XCTAssertEqual(RewriteRestorePlan.of(saved: empty, eligible: false), .none)
    }
}
