import Foundation
import XCTest

@testable import DotCore

/// What the log file costs and what it is readable by.
///
/// A line is written on the path between a key press and a recording, so the
/// write is kept to the work a line needs: the size is counted, not read from
/// disk on every write, and the file is `0600` like the other files Dot keeps.
final class LogFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-log-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var url: URL { directory.appendingPathComponent("Dot.log") }

    func testTheLogIsReadableOnlyByItsOwner() throws {
        let log = Log()
        XCTAssertTrue(log.openFile(at: url))
        log.info("app.started")

        XCTAssertEqual(SecureFile.permissions(of: url), 0o600)
        XCTAssertEqual(
            SecureFile.permissions(of: directory),
            0o700,
            "the folder holds the log as well as the file"
        )
    }

    func testEveryLineIsJSON() throws {
        let log = Log()
        XCTAssertTrue(log.openFile(at: url))
        log.info("recording.started")
        log.error("recording.failed", ["error": .string("the microphone is busy")])

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
        XCTAssertTrue(lines[1].contains("the microphone is busy"))
    }

    func testARegisteredSecretIsWrittenAsStars() throws {
        let log = Log()
        XCTAssertTrue(log.openFile(at: url))
        log.registerSecret("sk-live-0123456789")
        log.info("credential.read", ["detail": .string("the key sk-live-0123456789 was used")])

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("sk-live-0123456789"))
        XCTAssertTrue(written.contains("***"))
    }

    func testTheFileIsRotatedAndTheNewestLinesSurvive() throws {
        // The real limits are five megabytes and one. A test that wrote them
        // would be a five megabyte test.
        let log = Log(limitBytes: 1_024, retainBytes: 512)
        XCTAssertTrue(log.openFile(at: url))
        for index in 0..<80 {
            log.info("line-\(String(format: "%03d", index))", ["filler": .string(String(repeating: "x", count: 40))])
        }

        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(size, 1_024, "the log grew past its limit")

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("line-079"), "the newest line was the one dropped")
        XCTAssertFalse(written.contains("line-000"), "the oldest line survived a rotation")

        // Every surviving line is still a whole line.
        let lines = written.split(separator: "\n").map(String.init)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)), line)
        }
        XCTAssertEqual(SecureFile.permissions(of: url), 0o600, "a rotation must not widen the file")
    }

    func testALogWithNoFileWritesNothing() {
        // No handle, no file, no work: the payload is not built for a line that
        // has nowhere to go.
        let log = Log(limitBytes: 1_024, retainBytes: 512)
        log.info("recording.started")
        XCTAssertNil(log.url)
    }
}
