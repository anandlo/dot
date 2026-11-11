import Foundation
import XCTest

@testable import DotCore

/// The pure half of the dictation palette.
///
/// The panel is a window; what makes the palette work is this: a filter that
/// answers the query a person actually types, a ranking that puts the obvious
/// answer first, a selection that wraps, and a key map with one behaviour for
/// Escape.
final class TranscriptSearchTests: XCTestCase {
    private let history = [
        "Ship the palette on Thursday and tell Priya before the sync.",
        "Remind me to water the fig tree tomorrow and pick up oat milk.",
        "Meeting notes: the retry loop should stop after three attempts.",
        "Café order for the team offsite: two flat whites and a pastry.",
    ]

    // MARK: - Filtering

    func testAnEmptyQueryReturnsTheHistoryNewestFirst() {
        let matches = TranscriptSearch.matches("", in: history)
        XCTAssertEqual(matches.map(\.index), Array(0..<history.count))
        XCTAssertEqual(matches.first?.text, history[0])
        XCTAssertEqual(TranscriptSearch.matches("   ", in: history).count, history.count)
    }

    func testAnEmptyHistoryHasNoMatches() {
        XCTAssertTrue(TranscriptSearch.matches("anything", in: []).isEmpty)
        XCTAssertTrue(TranscriptSearch.matches("", in: []).isEmpty)
    }

    func testTheFilterIgnoresCase() {
        let matches = TranscriptSearch.matches("MEETING", in: history)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.text, history[2])
    }

    func testTheFilterIgnoresDiacritics() {
        // Typed without the accent, found in a transcript with it, and the
        // other way round.
        XCTAssertEqual(TranscriptSearch.matches("cafe", in: history).first?.text, history[3])
        XCTAssertEqual(TranscriptSearch.matches("CAFÉ", in: history).first?.text, history[3])
    }

    func testEveryWordOfAQueryHasToAppearSomewhere() {
        // Words in any order, as long as all of them are in the transcript.
        XCTAssertEqual(TranscriptSearch.matches("fig tree", in: history).count, 1)
        XCTAssertEqual(TranscriptSearch.matches("tree fig", in: history).count, 1)
        XCTAssertTrue(TranscriptSearch.matches("fig zebra", in: history).isEmpty)
    }

    func testAWordPrefixMatches() {
        // A half-remembered word is the common case, so a prefix is a match.
        XCTAssertEqual(TranscriptSearch.matches("remind", in: history).first?.text, history[1])
        XCTAssertEqual(TranscriptSearch.matches("Thu", in: history).first?.text, history[0])
    }

    func testAtMostTheResultLimitIsReturned() {
        let many = (0..<200).map { "note \($0)" }
        XCTAssertEqual(
            TranscriptSearch.matches("note", in: many).count,
            TranscriptSearch.maximumResults
        )
    }

    // MARK: - Ranking

    func testAnExactPrefixBeatsASubstring() {
        let transcripts = [
            "I will meet you at the pier after lunch.",
            "Meeting notes from the design review.",
        ]
        let matches = TranscriptSearch.matches("meet", in: transcripts)
        XCTAssertEqual(matches.first?.text, transcripts[1], "a prefix is the better answer")
        XCTAssertEqual(matches.count, 2)
    }

    func testAWholePhrasePrefixBeatsTheSameWordsLater() {
        let transcripts = [
            "Remind me to book the room for the fig tree review.",
            "Fig tree review: the room is booked.",
        ]
        let matches = TranscriptSearch.matches("fig tree", in: transcripts)
        XCTAssertEqual(matches.first?.text, transcripts[1])
        XCTAssertGreaterThan(
            matches[0].score,
            matches[1].score,
            "the phrase at the start has to outrank the same words in the middle"
        )
    }

    func testATieGoesToTheNewerTranscript() {
        let transcripts = [
            "same words here",
            "same words here",
        ]
        let matches = TranscriptSearch.matches("same words", in: transcripts)
        XCTAssertEqual(matches.map(\.index), [0, 1])
    }

    func testTheScoreIsOnlyMeaningfulAgainstTheSameQuery() {
        // A transcript with no match has no rank at all, which is how the
        // caller tells "did not match" from "matched badly".
        XCTAssertNil(TranscriptSearch.rank(text: "hello", tokens: ["zebra"], query: "zebra"))
        XCTAssertNotNil(TranscriptSearch.rank(text: "hello", tokens: [], query: ""))
    }

    // MARK: - Selection

    func testTheSelectionWrapsAtBothEnds() {
        XCTAssertEqual(TranscriptSearch.advanced(0, by: 1, count: 3), 1)
        XCTAssertEqual(TranscriptSearch.advanced(2, by: 1, count: 3), 0)
        XCTAssertEqual(TranscriptSearch.advanced(0, by: -1, count: 3), 2)
        XCTAssertEqual(TranscriptSearch.advanced(1, by: -1, count: 3), 0)
        XCTAssertEqual(TranscriptSearch.advanced(1, by: 5, count: 3), 0)
        XCTAssertEqual(TranscriptSearch.advanced(0, by: 0, count: 3), 0)
    }

    func testAnEmptyListHasOneSelection() {
        XCTAssertEqual(TranscriptSearch.advanced(0, by: 1, count: 0), 0)
        XCTAssertEqual(TranscriptSearch.advanced(4, by: -1, count: 0), 0)
    }

    // MARK: - Keys

    func testEscapeDismissesWhateverIsSelected() {
        XCTAssertEqual(PaletteKeyboard.command(for: .escape, hasSelection: true), .dismiss)
        XCTAssertEqual(PaletteKeyboard.command(for: .escape, hasSelection: false), .dismiss)
    }

    func testReturnInsertsAndShiftReturnCopies() {
        XCTAssertEqual(PaletteKeyboard.command(for: .returnKey, hasSelection: true), .insert)
        XCTAssertEqual(PaletteKeyboard.command(for: .shiftReturn, hasSelection: true), .copyOnly)
    }

    func testNothingIsActedOnWithoutASelection() {
        XCTAssertEqual(PaletteKeyboard.command(for: .returnKey, hasSelection: false), .ignore)
        XCTAssertEqual(PaletteKeyboard.command(for: .shiftReturn, hasSelection: false), .ignore)
    }

    func testTheArrowsMoveAndAnUnknownKeyIsLeftAlone() {
        XCTAssertEqual(PaletteKeyboard.command(for: .up, hasSelection: true), .moveUp)
        XCTAssertEqual(PaletteKeyboard.command(for: .down, hasSelection: false), .moveDown)
        XCTAssertEqual(PaletteKeyboard.command(for: .other, hasSelection: true), .ignore)
    }

    // MARK: - Presentation

    func testAPreviewIsOneLine() {
        let text = "First paragraph.\n\nSecond paragraph with a  double space."
        let preview = TranscriptSearch.preview(of: text)
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertEqual(preview, "First paragraph. Second paragraph with a  double space.")
    }

    func testTheAgeOfATranscriptReadsInTheUnitThatFits() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertEqual(PaletteAge.string(since: now, now: now), "just now")
        XCTAssertEqual(
            PaletteAge.string(since: now.addingTimeInterval(-30), now: now),
            "just now"
        )
        XCTAssertEqual(PaletteAge.string(since: now.addingTimeInterval(-90), now: now), "1m ago")
        XCTAssertEqual(PaletteAge.string(since: now.addingTimeInterval(-3_600), now: now), "1h ago")
        XCTAssertEqual(PaletteAge.string(since: now.addingTimeInterval(-2 * 3_600), now: now), "2h ago")
        XCTAssertEqual(PaletteAge.string(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
        XCTAssertEqual(PaletteAge.string(since: now.addingTimeInterval(-14 * 86_400), now: now), "2w ago")
        XCTAssertNil(PaletteAge.string(since: nil, now: now), "an entry with no date has no age")
    }

    func testTheAgeNeverCountsBackwards() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        // A clock that moved backwards is not a negative age.
        XCTAssertEqual(
            PaletteAge.string(since: now.addingTimeInterval(120), now: now),
            "just now"
        )
    }
}
