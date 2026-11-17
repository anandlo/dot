import Foundation
import XCTest

/// Where the app touches the archive, and in what order.
///
/// The archive is a second copy of what was delivered, so what it must never do
/// is visible in the order of two statements rather than in a return value: a
/// question asked of the assistant is not archived, the history is written
/// before a day file is opened, and the file work is handed to a task so it can
/// never sit between the stop key and the paste. None of that can be observed
/// from outside, so it is read off the source.
final class TranscriptArchiveHookTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appDelegate() throws -> String {
        try String(
            contentsOf: Self.root.appendingPathComponent("Sources/Dot/AppDelegate.swift"),
            encoding: .utf8
        )
    }

    /// The archive is written from inside a task, never on the delivering
    /// thread.
    func testTheArchiveIsWrittenFromInsideATask() throws {
        let source = try appDelegate()
        let declaration = try XCTUnwrap(source.range(of: "private func archive(_ text: String"))
        let limit = source.range(of: "\n    private func ", range: declaration.upperBound..<source.endIndex)
            .map(\.lowerBound) ?? source.endIndex
        let submit = try XCTUnwrap(
            source.range(of: "archiveSequence.submit {", range: declaration.lowerBound..<limit),
            "the archive is written synchronously"
        )
        let take = try XCTUnwrap(source.range(of: "await archive.recordTake(", range: submit.upperBound..<limit))
        let versions = try XCTUnwrap(
            source.range(of: "await archive.recordVersions(", range: submit.upperBound..<limit)
        )

        XCTAssertLessThan(submit.lowerBound, take.lowerBound)
        XCTAssertLessThan(submit.lowerBound, versions.lowerBound)
        // The sequence is what carries the work off the main actor and keeps it
        // in the order the changes were made.
        let sequence = try String(
            contentsOf: Self.root.appendingPathComponent("Sources/DotCore/ArchiveSequence.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sequence.contains("Task.detached"), "the sequence runs its work on the main actor")
        XCTAssertTrue(sequence.contains("await previous?.value"), "the sequence does not wait for the change before it")
        XCTAssertEqual(occurrences(of: "recordTake(", in: source), 1, "a second take call site")
        XCTAssertEqual(occurrences(of: "recordVersions(", in: source), 1, "a second versions call site")
    }

    /// A question to the assistant leaves before any take is archived.
    func testTheAssistantBranchReturnsBeforeTheArchiveCall() throws {
        let source = try appDelegate()
        let assistant = try XCTUnwrap(source.range(of: "if capturePurpose == .assistant"))
        let dictation = try XCTUnwrap(source.range(of: "capturePurpose = .dictation"))
        let call = try XCTUnwrap(source.range(of: "archive(transcript, at: deliveredAt)"))

        XCTAssertLessThan(assistant.lowerBound, dictation.lowerBound)
        XCTAssertLessThan(dictation.lowerBound, call.lowerBound)
        XCTAssertTrue(
            source[assistant.lowerBound..<call.lowerBound].contains("return"),
            "the assistant branch does not return before the archive call"
        )
    }

    /// The history is on disk before the archive is touched, so a folder Dot
    /// cannot reach costs the person nothing.
    func testTheHistoryIsWrittenBeforeTheArchiveIsCalled() throws {
        let source = try appDelegate()
        let saved = try XCTUnwrap(source.range(of: "history = HistoryStore.adding("))
        let call = try XCTUnwrap(source.range(of: "archive(transcript, at: deliveredAt)"))

        XCTAssertLessThan(saved.lowerBound, call.lowerBound)
        XCTAssertEqual(occurrences(of: "archive(transcript, at: deliveredAt)", in: source), 1)
    }

    /// The archive is off until the person turns it on, at both hooks.
    func testNeitherHookWritesWhenTheArchiveIsOff() throws {
        let source = try appDelegate()
        let gate = "guard config.transcriptArchive.enabled else { return }"

        XCTAssertEqual(occurrences(of: gate, in: source), 1, "the switch is not read at the entry point")
        // Two readers: that gate, and the request that decides whether a card
        // with no delivery instant is reported rather than dropped.
        XCTAssertEqual(occurrences(of: "config.transcriptArchive.enabled", in: source), 2)
    }

    /// The quit waits for the archive before AppKit is told the app may go.
    func testTheQuitWaitsForTheArchiveBeforeReplying() throws {
        let source = try appDelegate()
        let should = try XCTUnwrap(source.range(of: "func applicationShouldTerminate("))
        let limit = source.range(of: "\n    private func ", range: should.upperBound..<source.endIndex)
            .map(\.lowerBound) ?? source.endIndex
        let body = source[should.lowerBound..<limit]

        XCTAssertTrue(body.contains("return .terminateLater"), "the quit does not wait")
        XCTAssertTrue(body.contains("Shutdown.drain("), "the quit does not use the shared drain")
        XCTAssertTrue(body.contains("reply(toApplicationShouldTerminate:"), "the quit never answers")
        XCTAssertLessThan(
            try XCTUnwrap(body.range(of: "Shutdown.drain")).lowerBound,
            try XCTUnwrap(body.range(of: "reply(toApplicationShouldTerminate:")).lowerBound,
            "the quit answers before it drains"
        )
        XCTAssertTrue(
            body.contains("takePendingArchiveWrites()"),
            "the quit does not wait for the writes it tracked"
        )
        let take = try XCTUnwrap(source.range(of: "private func takePendingArchiveWrites("))
        let takeLimit = source.range(of: "\n    private func ", range: take.upperBound..<source.endIndex)
            .map(\.lowerBound) ?? source.endIndex
        XCTAssertTrue(
            source[take.lowerBound..<takeLimit].contains("archiveTasks"),
            "the drain is not fed by the list the writes register in"
        )
        // The last line the app logs stays in `applicationWillTerminate`, which
        // AppKit calls only once the reply has been sent, and not in the method
        // that waits.
        XCTAssertEqual(occurrences(of: "app.stopped", in: source), 1)
        XCTAssertFalse(body.contains("app.stopped"), "the quit logs its last line before it drains")
        let will = try XCTUnwrap(source.range(of: "func applicationWillTerminate("))
        let willLimit = source.range(of: "\n    func ", range: will.upperBound..<source.endIndex)
            .map(\.lowerBound) ?? source.endIndex
        XCTAssertTrue(
            source[will.lowerBound..<willLimit].contains("\"app.stopped\""),
            "the last log line is not in willTerminate"
        )
    }

    /// A bookmark refresh is only stored if the folder it describes is still
    /// the one the configuration names.
    func testARefreshedBookmarkIsCheckedAgainstTheCurrentFolder() throws {
        let source = try appDelegate()

        XCTAssertTrue(source.contains("TranscriptArchiveFolder.refresh("))
        XCTAssertTrue(source.contains("resolvedFrom: settings"))
        XCTAssertTrue(source.contains("current: self.config.transcriptArchive"))
        XCTAssertEqual(occurrences(of: "saveConfiguration()", in: source) > 0, true)
    }

    /// The quit writes the card's last versions itself, then waits for them,
    /// and a second request does nothing.
    func testTheQuitWritesTheLastRewriteBeforeItDrains() throws {
        let source = try appDelegate()
        let should = try XCTUnwrap(source.range(of: "func applicationShouldTerminate("))
        let limit = source.range(of: "\n    private func ", range: should.upperBound..<source.endIndex)
            .map(\.lowerBound) ?? source.endIndex
        let body = source[should.lowerBound..<limit]

        XCTAssertTrue(
            body.contains("guard !archiveShuttingDown else { return .terminateLater }"),
            "a second termination request starts a second drain"
        )
        let flag = try XCTUnwrap(body.range(of: "archiveShuttingDown = true"))
        let persist = try XCTUnwrap(body.range(of: "persistRewrite(rewrite.card)"))
        let drain = try XCTUnwrap(body.range(of: "Shutdown.drain("))

        XCTAssertLessThan(flag.lowerBound, persist.lowerBound)
        XCTAssertLessThan(persist.lowerBound, drain.lowerBound, "the last rewrite is not written before the drain")
        XCTAssertTrue(
            body.contains("takePendingArchiveWrites()"),
            "the drain does not pick up writes registered while it runs"
        )
        // A card with no delivery instant is reported rather than dropped.
        XCTAssertTrue(
            source.contains("RewriteArchiveRequest.file("),
            "a card with no instant is skipped without a word"
        )
        XCTAssertFalse(
            source.contains("no_instant"),
            "the reason is spelled in the app as well as in DotCore"
        )
        // The registry is read synchronously on the main actor. An await there
        // would be the turn this review closed.
        XCTAssertTrue(
            body.contains("pending: { self.takePendingArchiveWrites() }"),
            "the drain does not read the registry synchronously"
        )
        // The last write is only repeated by a termination that never asked.
        let will = try XCTUnwrap(source.range(of: "func applicationWillTerminate("))
        let willLimit = source.range(of: "\n    /// ", range: will.upperBound..<source.endIndex)
            .map(\.lowerBound) ?? source.endIndex
        let willBody = source[will.lowerBound..<willLimit]
        XCTAssertTrue(willBody.contains("if !archiveShuttingDown {"))
        XCTAssertEqual(occurrences(of: "persistRewrite(rewrite.card)", in: source), 2)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
