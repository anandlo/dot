import Foundation
import XCTest

@testable import DotCore

/// The history file, and the age the palette shows beside a transcript.
///
/// The file has two shapes in the world: the list of strings every earlier
/// build wrote, and the list of entries with dates that the palette needs.
/// Both have to load, and an entry that was already there must keep the date it
/// was first given.
final class HistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var url: URL { directory.appendingPathComponent("history.json") }

    func testAFileOfStringsStillLoads() throws {
        try #"["newest", "middle", "oldest"]"#
            .write(to: url, atomically: true, encoding: .utf8)

        let entries = HistoryStore.loadEntries(from: url)
        XCTAssertEqual(entries.map(\.text), ["newest", "middle", "oldest"])
        // The age is not known for a file written before dates were kept, and
        // the palette says nothing rather than inventing one.
        XCTAssertTrue(entries.allSatisfy { $0.addedAt == nil })
        XCTAssertEqual(HistoryStore.load(from: url), ["newest", "middle", "oldest"])
    }

    func testEntriesRoundTripWithTheirDates() throws {
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        let entries = [
            HistoryStore.Entry(text: "first", addedAt: date),
            HistoryStore.Entry(text: "second", addedAt: date.addingTimeInterval(60)),
        ]
        HistoryStore.saveEntries(entries, to: url)
        XCTAssertEqual(HistoryStore.loadEntries(from: url), entries)
    }

    func testABrokenFileIsAnEmptyHistoryRatherThanAFailure() throws {
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(HistoryStore.loadEntries(from: url).isEmpty)
        XCTAssertTrue(HistoryStore.load(from: url).isEmpty)
        XCTAssertTrue(HistoryStore.loadEntries(from: directory.appendingPathComponent("missing.json")).isEmpty)
    }

    func testAddingPutsTheNewestFirstAndMovesACopy() {
        let early = Date(timeIntervalSinceReferenceDate: 1_000)
        let late = Date(timeIntervalSinceReferenceDate: 2_000)
        var entries: [HistoryStore.Entry] = []
        entries = HistoryStore.adding("one", at: early, to: entries)
        entries = HistoryStore.adding("two", at: late, to: entries)
        XCTAssertEqual(entries.map(\.text), ["two", "one"])

        // The same words again are not stored twice, and the date is when they
        // were first heard.
        entries = HistoryStore.adding("one", at: late.addingTimeInterval(500), to: entries)
        XCTAssertEqual(entries.map(\.text), ["one", "two"])
        XCTAssertEqual(entries.first?.addedAt, early)
    }

    func testAddingNothingChangesNothing() {
        let entries = [HistoryStore.Entry(text: "one", addedAt: Date())]
        XCTAssertEqual(HistoryStore.adding("   ", at: Date(), to: entries), entries)
    }

    func testTheHistoryKeepsItsLimit() {
        var entries: [HistoryStore.Entry] = []
        for index in 0..<(HistoryStore.limit + 5) {
            entries = HistoryStore.adding(
                "item \(index)",
                at: Date(timeIntervalSinceReferenceDate: Double(index)),
                to: entries
            )
        }
        XCTAssertEqual(entries.count, HistoryStore.limit)
        XCTAssertEqual(entries.first?.text, "item \(HistoryStore.limit + 4)")

        HistoryStore.saveEntries(entries, to: url)
        XCTAssertEqual(HistoryStore.loadEntries(from: url).count, HistoryStore.limit)
    }

    func testSavingTextKeepsTheDatesTheFileAlreadyHas() throws {
        let date = Date(timeIntervalSinceReferenceDate: 5_000)
        HistoryStore.saveEntries([HistoryStore.Entry(text: "known", addedAt: date)], to: url)

        // A caller that only has strings must not reset the age of a transcript
        // that is already stored.
        HistoryStore.save(["known", "new"], to: url)
        let entries = HistoryStore.loadEntries(from: url)
        XCTAssertEqual(entries.map(\.text), ["known", "new"])
        XCTAssertEqual(entries.first?.addedAt, date)
        XCTAssertNotNil(entries.last?.addedAt)
    }

    // MARK: - Versions kept with an entry

    private func version(
        _ id: Int,
        _ text: String,
        style: String = "concise",
        title: String = "Concise",
        ordinal: Int = 1,
        warning: String? = nil
    ) -> RewriteVersion {
        RewriteVersion(
            id: id,
            origin: .style(style),
            title: title,
            text: text,
            ordinal: ordinal,
            warning: warning
        )
    }

    private func json(_ entries: [HistoryStore.Entry]) throws -> String {
        let data = try JSONEncoder().encode(entries)
        return String(decoding: data, as: UTF8.self)
    }

    func testVersionsAndTheSelectionRoundTripWithTheEntry() throws {
        let date = Date(timeIntervalSinceReferenceDate: 9_000)
        let saved = RewriteSnapshot(
            versions: [
                version(1, "Send Priya the report.", warning: "A name changed."),
                version(4, "Please send the report.", style: "formal", title: "Professional", ordinal: 1),
            ],
            selectedVersionID: 4
        )
        let entries = [HistoryStore.Entry(text: "Send the report.", addedAt: date, rewrite: saved)]
        HistoryStore.saveEntries(entries, to: url)

        let loaded = HistoryStore.loadEntries(from: url)
        XCTAssertEqual(loaded, entries)
        XCTAssertEqual(loaded.first?.rewrite?.versions.map(\.id), [1, 4])
        XCTAssertEqual(loaded.first?.rewrite?.selectedVersionID, 4)
        XCTAssertEqual(loaded.first?.rewrite?.versions.first?.ordinal, 1)
        XCTAssertEqual(loaded.first?.rewrite?.versions.first?.warning, "A name changed.")
    }

    /// Only versions and the selection are written. A card's draft, its phase,
    /// where a version was delivered and the insertion anchor are states of one
    /// take, not versions of a transcript.
    func testTheFileHoldsNoDeliveryStateOrDraft() throws {
        let saved = RewriteSnapshot(versions: [version(1, "Shorter words.")], selectedVersionID: 1)
        let text = try json([HistoryStore.Entry(text: "Some words.", rewrite: saved)])
        XCTAssertTrue(text.contains("\"versions\""))
        XCTAssertTrue(text.contains("\"selectedVersionID\""))
        for absent in ["draft", "phase", "destination", "anchor", "insertedText"] {
            XCTAssertFalse(text.contains(absent), "the file carried \(absent): \(text)")
        }
    }

    func testATranscriptWithoutVersionsLoadsAsBefore() throws {
        try #"[{"text":"just words","addedAt":0}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        let entries = HistoryStore.loadEntries(from: url)
        XCTAssertEqual(entries.map(\.text), ["just words"])
        XCTAssertNotNil(entries.first?.addedAt)
        XCTAssertNil(entries.first?.rewrite)
    }

    /// A newer build's payload that this one cannot read costs the entry its
    /// versions, never its transcript, and never its neighbours.
    func testAMalformedRewritePayloadKeepsTheTranscriptAndNeighbours() throws {
        let file = #"""
        [
          {"text":"before","addedAt":0},
          {"text":"bad payload","rewrite":"not a snapshot"},
          {"text":"good","rewrite":{"selectedVersionID":2,"versions":[
            {"id":1,"style":"concise","title":"Concise","text":"short","ordinal":1},
            {"id":2,"style":"formal","title":"Professional","text":"longer","ordinal":1}
          ]}},
          "legacy",
          {"text":"unreadable versions","rewrite":{"versions":[{"style":"concise"}]}},
          {"text":"after","addedAt":0}
        ]
        """#
        try file.write(to: url, atomically: true, encoding: .utf8)
        let entries = HistoryStore.loadEntries(from: url)
        XCTAssertEqual(
            entries.map(\.text),
            ["before", "bad payload", "good", "legacy", "unreadable versions", "after"],
            "an entry or its neighbours were discarded"
        )
        XCTAssertNil(entries[1].rewrite)
        XCTAssertEqual(entries[2].rewrite?.versions.map(\.text), ["short", "longer"])
        XCTAssertEqual(entries[2].rewrite?.selectedVersionID, 2)
        XCTAssertNil(entries[4].rewrite)
    }

    /// One version record that cannot be read must not cost the others, and a
    /// record whose id is impossible keeps its words under a safe id.
    func testAnImpossibleVersionIDKeepsItsWordsAndCannotOverflowTheNextID() throws {
        let file = #"""
        [
          {"text":"words","rewrite":{"selectedVersionID":9223372036854775807,"versions":[
            {"id":9223372036854775807,"style":"gone","title":"Removed style","text":"first","ordinal":3,"warning":"Review this."},
            {"id":-4,"style":"gone","title":"Removed style","text":"second","ordinal":4},
            {"id":1,"style":"concise","title":"Concise","text":"third","ordinal":1},
            {"style":"concise","text":""},
            {"id":"not a number","style":"concise","title":"Concise","text":"fourth"}
          ]}}
        ]
        """#
        try file.write(to: url, atomically: true, encoding: .utf8)
        let entry = try XCTUnwrap(HistoryStore.loadEntries(from: url).first)
        let saved = try XCTUnwrap(entry.rewrite)
        XCTAssertEqual(saved.versions.map(\.text), ["first", "second", "third", "fourth"])
        // The readable id keeps itself; the impossible ones are given the ids
        // above it, in the order they were written. Navigation follows the
        // list, not the numbers.
        XCTAssertEqual(saved.versions.map(\.id), [2, 3, 1, 4])
        XCTAssertEqual(Set(saved.versions.map(\.id)).count, 4, "two versions shared an id")
        XCTAssertTrue(saved.versions.allSatisfy { $0.id > 0 })
        XCTAssertEqual(saved.nextVersionID, 5)
        XCTAssertEqual(saved.selectedVersionID, 0, "an impossible selection did not fall back to the original")
        XCTAssertEqual(saved.versions.first?.title, "Removed style")
        XCTAssertEqual(saved.versions.first?.ordinal, 3)
        XCTAssertEqual(saved.versions.first?.warning, "Review this.")
        XCTAssertEqual(saved.versions.first?.styleID, "gone")
        XCTAssertLessThanOrEqual(saved.nextVersionID, RewriteSnapshot.maximumVersionID + 1)
    }

    func testAddingTheSameTextKeepsTheSavedVersionsAndDate() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_234)
        let saved = RewriteSnapshot(versions: [version(2, "Shorter.")], selectedVersionID: 2)
        let entries = [HistoryStore.Entry(text: "same words", addedAt: date, rewrite: saved)]

        let added = HistoryStore.adding(
            "same words",
            at: date.addingTimeInterval(86_400),
            to: entries
        )
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.addedAt, date)
        XCTAssertEqual(added.first?.rewrite, saved)
    }

    func testSavingTextKeepsTheSavedVersions() throws {
        let saved = RewriteSnapshot(versions: [version(1, "Shorter.")], selectedVersionID: 1)
        HistoryStore.saveEntries([HistoryStore.Entry(text: "known", rewrite: saved)], to: url)
        HistoryStore.save(["known", "new"], to: url)
        let entries = HistoryStore.loadEntries(from: url)
        XCTAssertEqual(entries.first?.rewrite, saved)
        XCTAssertNil(entries.last?.rewrite)
    }

    func testAHundredEntriesKeepTheirVersions() throws {
        let entries = (0 ..< 100).map { index in
            HistoryStore.Entry(
                text: "transcript \(index)",
                addedAt: Date(timeIntervalSinceReferenceDate: Double(index)),
                rewrite: RewriteSnapshot(
                    versions: [version(1, "short \(index)")],
                    selectedVersionID: 1
                )
            )
        }
        HistoryStore.saveEntries(entries, to: url, limit: 100)
        let loaded = HistoryStore.loadEntries(from: url, limit: 100)
        XCTAssertEqual(loaded.count, 100)
        XCTAssertEqual(loaded.map(\.text), entries.map(\.text))
        XCTAssertEqual(loaded.map(\.rewrite), entries.map(\.rewrite))
    }

    // MARK: - The persistence seam

    func testStoringAttachesVersionsOnlyToTheMatchingEntry() {
        let entries = [
            HistoryStore.Entry(text: "first"),
            HistoryStore.Entry(text: "second", addedAt: Date(timeIntervalSinceReferenceDate: 5)),
        ]
        let saved = RewriteSnapshot(versions: [version(1, "short")], selectedVersionID: 1)
        let updated = HistoryStore.storing(saved, for: "second", in: entries)
        XCTAssertEqual(updated?.count, 2)
        XCTAssertNil(updated?.first?.rewrite)
        XCTAssertEqual(updated?[1].rewrite, saved)
        XCTAssertEqual(updated?[1].addedAt, entries[1].addedAt, "storing also rewrote the date")
        XCTAssertEqual(entries[1].rewrite, nil, "the input was mutated")
    }

    func testStoringWritesNothingWhenThereIsNothingNew() {
        let saved = RewriteSnapshot(versions: [version(1, "short")], selectedVersionID: 1)
        let entries = [HistoryStore.Entry(text: "words", rewrite: saved)]
        XCTAssertNil(HistoryStore.storing(saved, for: "words", in: entries), "an unchanged snapshot was written")
        XCTAssertNil(HistoryStore.storing(nil, for: "words", in: entries))
        XCTAssertNil(
            HistoryStore.storing(RewriteSnapshot(versions: [], selectedVersionID: 0), for: "words", in: entries),
            "an empty snapshot was written"
        )
    }

    /// A cleared history, a trimmed one, and a row that was never there must not
    /// come back with versions attached.
    func testStoringCannotResurrectARemovedEntryOrAttachElsewhere() {
        let saved = RewriteSnapshot(versions: [version(1, "short")], selectedVersionID: 1)
        XCTAssertNil(HistoryStore.storing(saved, for: "words", in: []))
        XCTAssertNil(HistoryStore.storing(saved, for: "words", in: [HistoryStore.Entry(text: "different")]))
        XCTAssertNil(HistoryStore.storing(saved, for: "  ", in: [HistoryStore.Entry(text: "words")]))
    }

    /// The card's original is the text it was built from; trimming the card
    /// must still find the entry the history wrote.
    func testStoringMatchesTheEntryThroughSurroundingWhitespace() {
        let saved = RewriteSnapshot(versions: [version(1, "short")], selectedVersionID: 1)
        let entries = [HistoryStore.Entry(text: "words")]
        let updated = HistoryStore.storing(saved, for: " words\n", in: entries)
        XCTAssertEqual(updated?.first?.rewrite, saved)
    }

    // MARK: - The card's snapshot

    func testACardThatIsStreamingOrBlockedHasNothingToSave() {
        var card = RewriteCard(original: "words", choices: RewriteStyle.builtIns)
        XCTAssertNil(RewriteSnapshot(card: card), "a card with no version was saved")

        card.phase = .rewriting(styleID: "concise", title: "Concise")
        card.draft = "shor"
        XCTAssertNil(RewriteSnapshot(card: card), "a streaming draft was saved")

        card.phase = .blocked(styleID: "concise", error: FaithfulnessCheck.numberChanged)
        card.draft = "short"
        XCTAssertNil(RewriteSnapshot(card: card), "a refused draft was saved")

        card.phase = .offered
        card.append(id: 1, style: .concise, text: "short", warning: nil)
        let saved = RewriteSnapshot(card: card)
        XCTAssertEqual(saved?.versions.map(\.id), [1])
        XCTAssertEqual(saved?.selectedVersionID, 1)
        XCTAssertEqual(saved?.versions.first?.styleID, "concise")
    }
}
