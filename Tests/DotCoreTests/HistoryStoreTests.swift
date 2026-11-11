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
}
