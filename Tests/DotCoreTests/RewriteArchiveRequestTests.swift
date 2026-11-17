import Foundation
import XCTest

@testable import DotCore

/// What the archive does with a card that has versions but no day to file them
/// under.
///
/// An entry the history decoded without `addedAt` can still be restored and
/// rewritten. Filing that rewrite under today's date would put words in a day
/// they were not said, so nothing is written and one line is logged instead. The
/// line is the only trace, so it names the reason and nothing the person said.
final class RewriteArchiveRequestTests: XCTestCase {
    private var directory: URL!
    private var log: Log!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-archive-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = Log()
        log.openFile(at: directory.appendingPathComponent("Dot.log"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func card(takenAt: Date?, versioned: Bool = true) -> RewriteCard {
        var card = RewriteCard(original: "Sounds good.", choices: [], takenAt: takenAt)
        if versioned {
            card.versions.append(
                RewriteVersion(
                    id: 1,
                    origin: .style("concise"),
                    title: "Concise",
                    text: "Sounds good indeed.",
                    ordinal: 1
                )
            )
        }
        return card
    }

    private func rawLog() throws -> String {
        let url = try XCTUnwrap(log.url)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func logLines() throws -> [[String: Any]] {
        try rawLog()
            .split(separator: "\n")
            .compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
    }

    /// Versions with no instant write nothing and log one line that says why.
    func testACardWithNoInstantIsSkippedAndSaysSo() throws {
        var written: [RewriteArchiveRecord] = []

        RewriteArchiveRequest.file(
            card(takenAt: nil),
            enabled: true,
            with: { written.append($0) },
            log: log
        )

        XCTAssertTrue(written.isEmpty, "a card with no day was filed anyway")
        let lines = try logLines()
        XCTAssertEqual(lines.count, 1, "the skip was silent, or logged twice")
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line["event"] as? String, "archive.write.skipped")
        XCTAssertEqual(line["reason"] as? String, "no_instant")
        XCTAssertFalse(line.keys.contains("text"))
        XCTAssertFalse(line.keys.contains("characters"))

        let raw = try rawLog()
        XCTAssertFalse(raw.contains("Sounds good"), "the line carried the words")
    }

    /// A card with an instant is filed, and nothing is logged.
    func testACardWithAnInstantIsFiled() throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        var written: [RewriteArchiveRecord] = []

        RewriteArchiveRequest.file(
            card(takenAt: instant),
            enabled: true,
            with: { written.append($0) },
            log: log
        )

        let record = try XCTUnwrap(written.first)
        XCTAssertEqual(record.takenAt, instant)
        XCTAssertEqual(record.text, "Sounds good.")
        XCTAssertEqual(record.versions.count, 1)
        XCTAssertTrue(try logLines().isEmpty)
    }

    /// A card that never ran a style has nothing to file and nothing to report.
    func testACardWithNoVersionsIsSilent() throws {
        var written: [RewriteArchiveRecord] = []

        RewriteArchiveRequest.file(
            card(takenAt: nil, versioned: false),
            enabled: true,
            with: { written.append($0) },
            log: log
        )

        XCTAssertTrue(written.isEmpty)
        XCTAssertTrue(try logLines().isEmpty, "a card with no versions reported a skip")
    }

    /// With the archive switched off nothing was skipped, so nothing is said.
    func testNothingIsLoggedWhenTheArchiveIsOff() throws {
        RewriteArchiveRequest.file(
            card(takenAt: nil),
            enabled: false,
            with: { _ in XCTFail("the archive is off and still wrote") },
            log: log
        )

        XCTAssertTrue(try logLines().isEmpty)
    }
}
