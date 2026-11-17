import Foundation
import XCTest

@testable import DotCore

/// The Markdown copy of a day's takes.
///
/// The archive is the one file of Dot's that a person reads and edits: it is
/// opened in an editor, searched, and added to by hand. So the tests are about
/// bytes. The two things a rewrite must never do are move the words it was not
/// asked about and lose a sentence that was only ever said - a take whose line
/// looks like the file's own structure is escaped on the way in and matched on
/// the way out.
final class TranscriptArchiveTests: XCTestCase {
    private var calendar: Calendar!
    private var root: URL!
    private var home: URL!
    /// The zone the archive reads on every write, so a test can change it the
    /// way a flight changes it.
    private let zone = Box(Calendar(identifier: .gregorian))

    override func setUpWithError() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 60 * 60))
        self.calendar = calendar
        zone.value = calendar
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-archive-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - A, B and C: bytes

    /// Two takes, then the first one's rewrites, in one exact file.
    func testATakesAndTheirRewritesMakeOneExactFile() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        try await archive.recordTake("First take.", at: at(16, 14, 32, 5, 123), folder: folder)
        try await archive.recordTake("Second take.", at: at(16, 14, 40, 0, 0), folder: folder)
        try await archive.recordVersions(
            of: "First take.",
            takenAt: at(16, 14, 32, 5, 123),
            versions: [concise(), conciseSecond()],
            folder: folder
        )

        let content = try text(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(content, Self.twoTakesWithTwoRewrites)
    }

    /// A rewrite made after a later take still lands under the words it was
    /// made from.
    func testARewriteMadeAfterALaterTakeLandsUnderTheFirstOne() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        try await archive.recordTake("First take.", at: at(16, 14, 32, 5, 123), folder: folder)
        try await archive.recordTake("Second take.", at: at(16, 14, 40, 0, 0), folder: folder)
        try await archive.recordVersions(
            of: "First take.",
            takenAt: at(16, 14, 32, 5, 123),
            versions: [concise()],
            folder: folder
        )

        let content = try text(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(content, Self.twoTakesWithOneRewrite)
    }

    /// The same versions recorded again leave the file alone.
    func testBRecordingTheSameVersionsTwiceWritesTheSameBytes() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        let takenAt = at(16, 14, 32, 5, 123)
        try await archive.recordTake("First take.", at: takenAt, folder: folder)
        let versions = [concise(), conciseSecond()]
        try await archive.recordVersions(of: "First take.", takenAt: takenAt, versions: versions, folder: folder)
        let once = try data(of: "2026-11-16.md", in: folder)
        try await archive.recordVersions(of: "First take.", takenAt: takenAt, versions: versions, folder: folder)

        let twice = try data(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(twice, once)
    }

    // MARK: - D: lookup

    /// A fresh archive finds the take it was not the one to write.
    func testAFreshArchiveFindsTheNewestSectionHoldingTheWords() async throws {
        let folder = try chosenFolder()
        let writer = makeArchive()
        try await writer.recordTake("Same words.", at: at(16, 14, 32, 5, 123), folder: folder)
        try await writer.recordTake("Same words.", at: at(16, 14, 40, 0, 0), folder: folder)

        let reader = makeArchive()
        try await reader.recordVersions(
            of: "Same words.",
            takenAt: at(16, 14, 40, 0, 0),
            versions: [concise()],
            folder: folder
        )

        let content = try text(of: "2026-11-16.md", in: folder)
        let first = try XCTUnwrap(content.range(of: "<!-- dot-take 2026-11-16T14:32:05.123+03:00 -->"))
        let second = try XCTUnwrap(content.range(of: "<!-- dot-take 2026-11-16T14:40:00.000+03:00 -->"))
        XCTAssertFalse(
            content[first.upperBound..<second.lowerBound].contains("### "),
            "the older section was rewritten"
        )
        XCTAssertTrue(content[second.upperBound...].contains("### Concise"))
    }

    /// A rewrite for words the file does not hold appends a section of its own.
    func testAMissingOriginalIsAppendedStampedWithTheGivenDate() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        try await archive.recordTake("First take.", at: at(16, 14, 32, 5, 123), folder: folder)
        try await archive.recordVersions(
            of: "Words written elsewhere.",
            takenAt: at(16, 9, 5, 0, 0),
            versions: [concise()],
            folder: folder
        )

        let content = try text(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(content, Self.appendedSection)
    }

    // MARK: - E: days

    /// Two takes either side of midnight are two files.
    func testTakesEitherSideOfMidnightAreTwoFiles() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        try await archive.recordTake("Late words.", at: at(16, 23, 59, 59, 0), folder: folder)
        try await archive.recordTake("Early words.", at: at(17, 0, 0, 1, 0), folder: folder)

        let late = try text(of: "2026-11-16.md", in: folder)
        let early = try text(of: "2026-11-17.md", in: folder)
        XCTAssertTrue(late.contains("Late words."))
        XCTAssertFalse(late.contains("Early words."))
        XCTAssertTrue(early.contains("Early words."))
        XCTAssertTrue(early.hasPrefix("# 17 November 2026\n\n"))
    }

    // MARK: - F: escaping

    /// Words that look like the file's own structure survive the round trip.
    func testTakeTextThatLooksLikeStructureIsEscapedAndStillMatches() async throws {
        let folder = try chosenFolder()
        let text = "line one\n# not a heading\n<!-- dot-take x -->\nline four"
        let writer = makeArchive()
        try await writer.recordTake(text, at: at(16, 14, 32, 5, 123), folder: folder)

        let escaped = try self.text(of: "2026-11-16.md", in: folder)
        XCTAssertTrue(escaped.contains("\n\\# not a heading\n"), "the heading line was not escaped")
        XCTAssertTrue(
            escaped.contains("\n\\<!-- dot-take x -->\n"),
            "the anchor-shaped line was not escaped"
        )
        XCTAssertEqual(Self.anchorLines(in: escaped).count, 1)

        let reader = makeArchive()
        try await reader.recordVersions(
            of: text,
            takenAt: at(16, 14, 32, 5, 123),
            versions: [concise()],
            folder: folder
        )

        let updated = try self.text(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(Self.anchorLines(in: updated).count, 1, "the escaped line became a section")
        XCTAssertTrue(updated.contains("### Concise"))
        XCTAssertEqual(Self.takeLines(in: updated).count, 4)
    }

    // MARK: - G: what the person wrote

    /// Notes around and inside the file are not the archive's to lose.
    func testOwnerNotesAboveAndInsideTheFileSurviveAnUpdate() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        try await archive.recordTake("First take.", at: at(16, 14, 32, 5, 123), folder: folder)
        try await archive.recordTake("Second take.", at: at(16, 14, 40, 0, 0), folder: folder)

        let file = folder.appendingPathComponent("2026-11-16.md")
        let written = try String(contentsOf: file, encoding: .utf8)
        let annotated = "My own notes.\n\n" + written + "A note I typed.\n"
        try Data(annotated.utf8).write(to: file)

        try await archive.recordVersions(
            of: "First take.",
            takenAt: at(16, 14, 32, 5, 123),
            versions: [concise()],
            folder: folder
        )

        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.hasPrefix("My own notes.\n\n# 16 November 2026\n\n"))
        XCTAssertTrue(updated.hasSuffix("Second take.\nA note I typed.\n"))
        XCTAssertTrue(updated.contains("### Concise"))
        XCTAssertTrue(updated.contains("First take."))
    }

    // MARK: - H: the folder and the permissions

    /// A chosen folder is the person's: never invented, never restricted.
    func testAChosenFolderThatIsMissingIsAnErrorAndIsNotCreated() async throws {
        let folder = root.appendingPathComponent("not-there", isDirectory: true)
        let archive = makeArchive()

        do {
            try await archive.recordTake("Words.", at: at(16, 14, 32, 5, 123), folder: folder)
            XCTFail("a missing chosen folder was written to")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the folder was created")
        }
    }

    /// The default folder is Dot's own, so Dot creates it and only its owner may
    /// read it.
    func testTheDefaultFolderIsCreatedForItsOwnerOnly() async throws {
        let archive = makeArchive()
        let folder = TranscriptArchiveFolder.defaultURL(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        try await archive.recordTake("Words.", at: at(16, 14, 32, 5, 123), folder: folder)

        XCTAssertEqual(SecureFile.permissions(of: folder), 0o700)
        XCTAssertEqual(SecureFile.permissions(of: folder.appendingPathComponent("2026-11-16.md")), 0o600)
    }

    /// A chosen folder keeps the mode it had, and the file in it is still Dot's.
    func testAnExistingChosenFolderKeepsItsModeAndItsFileIsRestricted() async throws {
        let folder = try chosenFolder()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: folder.path
        )
        let archive = makeArchive()

        try await archive.recordTake("Words.", at: at(16, 14, 32, 5, 123), folder: folder)

        XCTAssertEqual(SecureFile.permissions(of: folder), 0o755, "a folder the person picked was restricted")
        XCTAssertEqual(SecureFile.permissions(of: folder.appendingPathComponent("2026-11-16.md")), 0o600)
    }

    // MARK: - I: the configuration

    func testAnOldConfigWithoutTheBlockDecodesWithTheDefault() throws {
        let data = Data(#"{"provider":"groq"}"#.utf8)

        let config = try JSONDecoder().decode(DotConfig.self, from: data)

        XCTAssertEqual(config.transcriptArchive, TranscriptArchiveSettings.default)
        XCTAssertEqual(config.provider, ProviderIdentifier.groq)
    }

    func testAMalformedBlockDecodesWithTheDefaultAndKeepsEveryOtherField() throws {
        let data = Data(#"{"provider":"groq","historyLimit":42,"transcriptArchive":5}"#.utf8)

        let config = try JSONDecoder().decode(DotConfig.self, from: data)

        XCTAssertEqual(config.transcriptArchive, TranscriptArchiveSettings.default)
        XCTAssertEqual(config.provider, ProviderIdentifier.groq)
        XCTAssertEqual(config.historyLimit, 42)
    }

    func testOneMalformedFieldInTheBlockKeepsTheOthers() throws {
        let data = Data(#"{"transcriptArchive":{"enabled":true,"folderPath":5}}"#.utf8)

        let config = try JSONDecoder().decode(DotConfig.self, from: data)

        XCTAssertTrue(config.transcriptArchive.enabled)
        XCTAssertNil(config.transcriptArchive.folderPath)
        XCTAssertNil(config.transcriptArchive.folderBookmark)
    }

    func testTheBlockRoundTripsThroughTheConfigFile() throws {
        var config = DotConfig.default
        config.transcriptArchive = TranscriptArchiveSettings(
            enabled: true,
            folderPath: "/Users/someone/Notes",
            folderBookmark: Data([1, 2, 3, 4])
        )

        let decoded = try JSONDecoder().decode(DotConfig.self, from: JSONEncoder().encode(config))

        XCTAssertEqual(decoded, config)
    }

    // MARK: - J: the folder that moved

    func testAMovedFolderIsStillFoundThroughItsBookmark() throws {
        let original = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let bookmark = try original.bookmarkData(options: [])
        let moved = root.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)

        let settings = TranscriptArchiveSettings(
            enabled: true,
            folderPath: original.path,
            folderBookmark: bookmark
        )
        let resolved = TranscriptArchiveFolder.resolve(settings, home: home)

        // `/var` is a firmlink to `/private/var`, so the two spellings of the
        // same folder differ as strings: the name and the identity are what say
        // the bookmark followed the move.
        XCTAssertTrue(resolved.url.path.hasSuffix("/Renamed"), "the bookmark did not follow the move")
        XCTAssertFalse(resolved.url.path.hasSuffix("/Archive"))
        XCTAssertEqual(try identity(of: resolved.url), try identity(of: moved))
        if let refreshed = resolved.refreshedBookmark {
            var stale = false
            let resolvedAgain = try URL(
                resolvingBookmarkData: refreshed,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            XCTAssertTrue(resolvedAgain.path.hasSuffix("/Renamed"))
            XCTAssertEqual(try identity(of: resolvedAgain), try identity(of: moved))
        }
    }

    func testTheChosenPathIsUsedWhenThereIsNoBookmarkAndTheDefaultOtherwise() throws {
        let chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        let withPath = TranscriptArchiveFolder.resolve(
            TranscriptArchiveSettings(enabled: true, folderPath: chosen.path),
            home: home
        )
        XCTAssertEqual(withPath.url.path, chosen.path)
        XCTAssertNil(withPath.refreshedBookmark)

        let fallback = TranscriptArchiveFolder.resolve(TranscriptArchiveSettings(), home: home)
        XCTAssertEqual(fallback.url, TranscriptArchiveFolder.defaultURL(home: home))
        XCTAssertNil(fallback.refreshedBookmark)
    }

    func testABookmarkThatDoesNotResolveFallsBackToThePath() throws {
        let chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        let settings = TranscriptArchiveSettings(
            enabled: true,
            folderPath: chosen.path,
            folderBookmark: Data([0, 1, 2, 3, 4])
        )

        let resolved = TranscriptArchiveFolder.resolve(settings, home: home)

        XCTAssertEqual(resolved.url.path, chosen.path)
    }

    // MARK: - Fail closed

    /// Bytes that are not text are not a day Dot may replace.
    func testADayFileThatIsNotTextIsLeftAlone() async throws {
        let folder = try chosenFolder()
        let file = folder.appendingPathComponent("2026-11-16.md")
        let bytes = Data([0xFF, 0xFE, 0x00, 0x41])
        try bytes.write(to: file)
        let archive = makeArchive()

        do {
            try await archive.recordTake("Words.", at: at(16, 14, 32, 5, 123), folder: folder)
            XCTFail("a day file Dot could not read was replaced")
        } catch {
            XCTAssertEqual(error as? TranscriptArchiveError, .unreadableDay(file.path))
        }
        let after = try Data(contentsOf: file)
        XCTAssertEqual(after, bytes)
    }

    /// A day the account cannot read is not a day Dot may replace either.
    func testADayFileThatCannotBeReadIsLeftAlone() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        try await archive.recordTake("Words.", at: at(16, 14, 32, 5, 123), folder: folder)
        let file = folder.appendingPathComponent("2026-11-16.md")
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: file.path
        )

        do {
            try await archive.recordTake("More words.", at: at(16, 15, 0, 0, 0), folder: folder)
            XCTFail("a day file Dot could not read was replaced")
        } catch {
            XCTAssertEqual(error as? TranscriptArchiveError, .unreadableDay(file.path))
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: file.path
        )
        let after = try Data(contentsOf: file)
        XCTAssertEqual(after, before)
    }

    // MARK: - Finding the take again

    /// A take that already carries a version is still found by its words.
    func testASecondRewriteFindsATakeThatAlreadyHasOne() async throws {
        let folder = try chosenFolder()
        let takenAt = at(16, 14, 32, 5, 123)
        let writer = makeArchive()
        try await writer.recordTake("First take.", at: takenAt, folder: folder)
        try await writer.recordVersions(of: "First take.", takenAt: takenAt, versions: [concise()], folder: folder)

        let later = makeArchive()
        try await later.recordVersions(
            of: "First take.",
            takenAt: takenAt,
            versions: [concise(), conciseSecond()],
            folder: folder
        )

        let content = try text(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(Self.anchorLines(in: content).count, 1, "a second section was appended")
        XCTAssertEqual(content.components(separatedBy: "### Concise\n").count - 1, 1)
        XCTAssertTrue(content.contains("### Concise 2"))
    }

    /// The same words on another day are another take.
    func testTheSameWordsOnAnotherDayAreNotTheTakeBeingRewritten() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        try await archive.recordTake("Thank you.", at: at(16, 10, 0, 0, 0), folder: folder)
        try await archive.recordTake("Thank you.", at: at(17, 10, 0, 0, 0), folder: folder)
        let otherDay = try text(of: "2026-11-17.md", in: folder)

        try await archive.recordVersions(
            of: "Thank you.",
            takenAt: at(16, 10, 0, 0, 0),
            versions: [concise()],
            folder: folder
        )

        let otherDayAfter = try text(of: "2026-11-17.md", in: folder)
        XCTAssertEqual(otherDayAfter, otherDay, "the other day was rewritten")
        XCTAssertFalse(otherDayAfter.contains("### "))
        let firstDay = try text(of: "2026-11-16.md", in: folder)
        XCTAssertTrue(firstDay.contains("### Concise"))
    }

    /// A snapshot that arrives after a newer one is dropped, not written.
    func testAnOlderSnapshotDoesNotReplaceANewerOne() async throws {
        let folder = try chosenFolder()
        let takenAt = at(16, 14, 32, 5, 123)
        let archive = makeArchive()
        try await archive.recordTake("First take.", at: takenAt, folder: folder)
        try await archive.recordVersions(
            of: "First take.",
            takenAt: takenAt,
            versions: [concise(), conciseSecond()],
            folder: folder
        )
        let newest = try data(of: "2026-11-16.md", in: folder)

        try await archive.recordVersions(
            of: "First take.",
            takenAt: takenAt,
            versions: [concise()],
            folder: folder
        )

        let after = try data(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(after, newest, "the older snapshot replaced the newer list")
        XCTAssertTrue(try text(of: "2026-11-16.md", in: folder).contains("### Concise 2"))
    }

    // MARK: - A backslash the person typed

    /// A line that starts with a backslash is a line like any other.
    func testLinesThatStartWithABackslashOrAHeadingRoundTrip() async throws {
        let folder = try chosenFolder()
        let text = "a\n\\# x\n## y\n<!-- dot-take z\nb"
        let takenAt = at(16, 14, 32, 5, 123)
        let writer = makeArchive()
        try await writer.recordTake(text, at: takenAt, folder: folder)

        let escaped = try self.text(of: "2026-11-16.md", in: folder)
        XCTAssertTrue(escaped.contains("\n\\\\# x\n"), escaped)
        XCTAssertTrue(escaped.contains("\n\\## y\n"), escaped)
        XCTAssertTrue(escaped.contains("\n\\<!-- dot-take z\n"), escaped)

        let reader = makeArchive()
        try await reader.recordVersions(of: text, takenAt: takenAt, versions: [concise()], folder: folder)

        let updated = try self.text(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(Self.anchorLines(in: updated).count, 1, "an escaped line became a section")
        XCTAssertEqual(Self.takeLines(in: updated).count, 5, "a line of the take was lost")
        XCTAssertTrue(updated.contains("### Concise"))
    }

    // MARK: - Another writer

    /// A line written while Dot was rebuilding the file is kept, not lost.
    func testAnEditMadeDuringTheWriteIsKept() async throws {
        let folder = try chosenFolder()
        let writer = makeArchive()
        try await writer.recordTake("First take.", at: at(16, 14, 32, 5, 123), folder: folder)

        let once = OneShot()
        let archive = makeArchive(beforeCommit: { file in
            guard once.take() else { return }
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? (existing + "A line from elsewhere.\n").write(to: file, atomically: false, encoding: .utf8)
        })
        try await archive.recordTake("Second take.", at: at(16, 14, 40, 0, 0), folder: folder)

        let content = try text(of: "2026-11-16.md", in: folder)
        XCTAssertTrue(content.contains("A line from elsewhere."), "the edit made during the write was lost")
        XCTAssertTrue(content.contains("First take."))
        XCTAssertTrue(content.contains("Second take."))
    }

    /// A file that moves twice is refused, because Dot and the other writer
    /// disagree about what the day holds.
    func testASecondEditDuringTheWriteIsRefused() async throws {
        let folder = try chosenFolder()
        let file = folder.appendingPathComponent("2026-11-16.md")
        let archive = makeArchive(beforeCommit: { url in
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (existing + "x\n").write(to: url, atomically: false, encoding: .utf8)
        })

        do {
            try await archive.recordTake("Words.", at: at(16, 14, 32, 5, 123), folder: folder)
            XCTFail("a file that moved twice was replaced")
        } catch {
            XCTAssertEqual(error as? TranscriptArchiveError, .concurrentWrite(file.path))
        }
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(content, "x\nx\n", "the refused write left bytes of its own behind")
    }

    // MARK: - The same take in another time zone

    /// A take filed in one zone is the same take after the person flies.
    func testATakeIsFoundAfterTheZoneChanges() async throws {
        let folder = try chosenFolder()
        let instant = at(16, 0, 30, 0, 0, in: at(0))
        zone.value = at(0)
        let archive = makeArchive()
        try await archive.recordTake("Words.", at: instant, folder: folder)
        let original = try text(of: "2026-11-16.md", in: folder)
        XCTAssertTrue(original.contains("<!-- dot-take 2026-11-16T00:30:00.000Z -->"), original)

        zone.value = at(-8 * 3_600)
        try await archive.recordVersions(of: "Words.", takenAt: instant, versions: [concise()], folder: folder)

        let updated = try text(of: "2026-11-16.md", in: folder)
        XCTAssertTrue(updated.contains("### Concise"), updated)
        XCTAssertEqual(Self.anchorLines(in: updated).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-11-15.md").path))
    }

    /// A process that has never seen the take finds it by its instant, in the
    /// file the zone it was written in named.
    func testAFreshArchiveFindsATakeFiledInAnotherZone() async throws {
        let folder = try chosenFolder()
        let instant = at(16, 0, 30, 0, 0, in: at(0))
        zone.value = at(0)
        try await makeArchive().recordTake("Words.", at: instant, folder: folder)

        zone.value = at(-8 * 3_600)
        let reader = makeArchive()
        try await reader.recordVersions(of: "Words.", takenAt: instant, versions: [concise()], folder: folder)

        let content = try text(of: "2026-11-16.md", in: folder)
        XCTAssertTrue(content.contains("### Concise"), content)
        XCTAssertEqual(Self.anchorLines(in: content).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-11-15.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-11-17.md").path))
    }

    // MARK: - The commit boundary

    /// The competing edit is looked for after the replacement is on disk.
    func testTheEditIsCheckedAfterTheReplacementIsWritten() async throws {
        let folder = try chosenFolder()
        try await makeArchive().recordTake("First take.", at: at(16, 14, 32, 5, 123), folder: folder)

        let sawReplacement = Box(false)
        let archive = makeArchive(beforeCommit: { file in
            let siblings = (try? FileManager.default.contentsOfDirectory(
                atPath: file.deletingLastPathComponent().path
            )) ?? []
            if siblings.contains(where: { $0.hasSuffix(".tmp") }) {
                sawReplacement.value = true
            }
        })
        try await archive.recordTake("Second take.", at: at(16, 14, 40, 0, 0), folder: folder)

        XCTAssertTrue(sawReplacement.value, "the check ran before the replacement was written")
    }

    /// A take two calendar days away is still the same take.
    func testATakeTwoDaysAwayIsFoundAfterTheZoneChanges() async throws {
        let folder = try chosenFolder()
        // 10:30Z is 00:30 on the 17th at UTC+14 and 23:30 on the 15th at UTC-11.
        let instant = at(16, 10, 30, 0, 0, in: at(0))
        zone.value = at(14 * 3_600)
        try await makeArchive().recordTake("Words.", at: instant, folder: folder)
        let original = try text(of: "2026-11-17.md", in: folder)
        XCTAssertFalse(original.contains("### Concise"))

        zone.value = at(-11 * 3_600)
        let reader = makeArchive()
        try await reader.recordVersions(of: "Words.", takenAt: instant, versions: [concise()], folder: folder)

        let updated = try text(of: "2026-11-17.md", in: folder)
        XCTAssertTrue(updated.contains("### Concise"), updated)
        XCTAssertEqual(Self.anchorLines(in: updated).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-11-15.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-11-16.md").path))
    }

    /// Two sections claiming one instant are not guessed between.
    ///
    /// The writer no longer makes them: a second take of the same words at the
    /// same instant is dropped, and the sequence keeps a rewrite behind its own
    /// take. A file written before those two rules can still hold them, and the
    /// reader has to refuse rather than attach a version to one of two takes the
    /// person did not choose between.
    func testTwoSectionsClaimingOneInstantRefuseToChoose() async throws {
        let folder = try chosenFolder()
        let file = folder.appendingPathComponent("2026-11-16.md")
        try Data(Self.twoSectionsAtOneInstant.utf8).write(to: file)
        let before = try data(of: "2026-11-16.md", in: folder)

        let archive = makeArchive()
        do {
            try await archive.recordVersions(
                of: "Same words.",
                takenAt: at(16, 14, 32, 5, 123),
                versions: [concise()],
                folder: folder
            )
            XCTFail("a version was attached to one of two takes sharing an instant")
        } catch {
            XCTAssertEqual(error as? TranscriptArchiveError, .ambiguous(file.path))
            XCTAssertEqual((error as? TranscriptArchiveError)?.logReason, "ambiguous")
        }
        let after = try data(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(after, before, "the refused write changed the file")
        XCTAssertEqual(Self.anchorLines(in: String(decoding: after, as: UTF8.self)).count, 2)
    }

    // MARK: - The order the changes were made in

    /// Work submitted to the sequence runs in that order, however slow the
    /// first piece is.
    func testArchiveWorkRunsInSubmissionOrder() async throws {
        let sequence = ArchiveSequence()
        let order = Box<[String]>([])
        let take = sequence.submit {
            try? await Task.sleep(for: .milliseconds(80))
            order.value.append("take")
        }
        let rewrite = sequence.submit {
            order.value.append("rewrite")
        }

        await take.value
        await rewrite.value

        XCTAssertEqual(order.value, ["take", "rewrite"], "the rewrite ran before the take it belongs to")
    }

    /// A take and its rewrite submitted together end up as one section.
    ///
    /// The delay stands in for the one part of a change that happens outside the
    /// actor: resolving the folder's bookmark. Without the sequence the rewrite
    /// reaches the actor first, writes the section with its versions, and the
    /// take appends a second section claiming the same instant.
    func testARewriteSubmittedBehindItsTakeDoesNotOvertakeIt() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        let instant = at(16, 14, 32, 5, 123)
        let versions = [concise()]
        let sequence = ArchiveSequence()

        let take = sequence.submit {
            try? await Task.sleep(for: .milliseconds(120))
            try? await archive.recordTake("First take.", at: instant, folder: folder)
        }
        let rewrite = sequence.submit {
            try? await archive.recordVersions(
                of: "First take.",
                takenAt: instant,
                versions: versions,
                folder: folder
            )
        }

        await take.value
        await rewrite.value

        let content = try text(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(Self.anchorLines(in: content).count, 1, "the take and its rewrite made two sections")
        XCTAssertTrue(content.contains("### Concise"), content)
    }

    /// The same take recorded twice is written once.
    func testATakeAlreadyInTheFileIsNotWrittenTwice() async throws {
        let folder = try chosenFolder()
        let archive = makeArchive()
        let instant = at(16, 14, 32, 5, 123)
        try await archive.recordTake("First take.", at: instant, folder: folder)
        let once = try data(of: "2026-11-16.md", in: folder)

        try await archive.recordTake("First take.", at: instant, folder: folder)

        let twice = try data(of: "2026-11-16.md", in: folder)
        XCTAssertEqual(twice, once, "the second delivery of the same take wrote a second section")
        XCTAssertEqual(Self.anchorLines(in: String(decoding: twice, as: UTF8.self)).count, 1)
    }

    // MARK: - A folder that cannot be reached

    /// The bookmark is resolved without a panel and without mounting a volume.
    func testTheBookmarkIsResolvedWithoutUIOrMounting() throws {
        let settings = TranscriptArchiveSettings(
            enabled: true,
            folderPath: "/Users/someone/Elsewhere",
            folderBookmark: Data([1, 2])
        )
        let target = URL(fileURLWithPath: "/Users/someone/Archive", isDirectory: true)
        let seen = Box<URL.BookmarkResolutionOptions?>(nil)

        let resolved = TranscriptArchiveFolder.resolve(settings, home: home) { _, options, stale in
            seen.value = options
            stale = false
            return target
        }

        XCTAssertEqual(seen.value, [.withoutUI, .withoutMounting])
        XCTAssertEqual(resolved.url, target)
        XCTAssertNil(resolved.refreshedBookmark)
    }

    /// A folder that cannot be reached takes the missing-folder path.
    func testAFolderThatCannotBeResolvedTakesTheMissingFolderPath() async throws {
        let folder = root.appendingPathComponent("Unmounted", isDirectory: true)
        let settings = TranscriptArchiveSettings(
            enabled: true,
            folderPath: folder.path,
            folderBookmark: Data([9, 9])
        )

        let resolved = TranscriptArchiveFolder.resolve(settings, home: home)

        XCTAssertEqual(resolved.url.path, folder.path, "an unreachable bookmark did not fall back to the path")
        XCTAssertNil(resolved.refreshedBookmark)
        let archive = makeArchive()
        do {
            try await archive.recordTake("Words.", at: at(16, 14, 32, 5, 123), folder: resolved.url)
            XCTFail("a folder that cannot be reached was written to")
        } catch {
            XCTAssertEqual(error as? SecureFileError, .cannotCreate(folder.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// A real bookmark whose folder was deleted leaves nothing to write.
    func testABookmarkToADeletedFolderLeavesNothingToWrite() async throws {
        let folder = root.appendingPathComponent("Gone", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData(options: [])
        try FileManager.default.removeItem(at: folder)
        let settings = TranscriptArchiveSettings(
            enabled: true,
            folderPath: folder.path,
            folderBookmark: bookmark
        )

        let resolved = TranscriptArchiveFolder.resolve(settings, home: home)

        // Whether the system hands back the old location or refuses it, the
        // folder is not there and the write takes the missing-folder path.
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.url.path))
        let archive = makeArchive()
        do {
            try await archive.recordTake("Words.", at: at(16, 14, 32, 5, 123), folder: resolved.url)
            XCTFail("a folder that no longer exists was written to")
        } catch {
            XCTAssertEqual(error as? SecureFileError, .cannotCreate(resolved.url.path))
        }
    }

    // MARK: - A folder chosen while a refresh was running

    func testARefreshedBookmarkIsKeptWhenTheFolderHasNotMoved() {
        let started = TranscriptArchiveSettings(
            enabled: true,
            folderPath: "/Users/someone/Archive",
            folderBookmark: Data([1, 2])
        )
        let refreshed = Data([9, 9, 9])

        XCTAssertEqual(
            TranscriptArchiveFolder.refresh(refreshed, resolvedFrom: started, current: started),
            refreshed
        )
    }

    func testARefreshedBookmarkIsDroppedWhenAnotherFolderWasChosen() {
        let started = TranscriptArchiveSettings(
            enabled: true,
            folderPath: "/Users/someone/Archive",
            folderBookmark: Data([1, 2])
        )
        let otherPath = TranscriptArchiveSettings(enabled: true, folderPath: "/Users/someone/Notes")
        let otherBookmark = TranscriptArchiveSettings(
            enabled: true,
            folderPath: "/Users/someone/Archive",
            folderBookmark: Data([7, 7])
        )

        XCTAssertNil(
            TranscriptArchiveFolder.refresh(Data([9]), resolvedFrom: started, current: otherPath),
            "a bookmark for the folder the person moved away from was kept"
        )
        XCTAssertNil(TranscriptArchiveFolder.refresh(Data([9]), resolvedFrom: started, current: otherBookmark))
        XCTAssertNil(TranscriptArchiveFolder.refresh(nil, resolvedFrom: started, current: started))
    }

    // MARK: - The exact files

    private static let twoTakesWithTwoRewrites = """
    # 16 November 2026

    <!-- dot-take 2026-11-16T14:32:05.123+03:00 -->
    ## 14:32:05

    First take.

    ### Concise

    First concise.

    ### Concise 2

    First concise again.

    <!-- dot-take 2026-11-16T14:40:00.000+03:00 -->
    ## 14:40:00

    Second take.

    """

    private static let twoTakesWithOneRewrite = """
    # 16 November 2026

    <!-- dot-take 2026-11-16T14:32:05.123+03:00 -->
    ## 14:32:05

    First take.

    ### Concise

    First concise.

    <!-- dot-take 2026-11-16T14:40:00.000+03:00 -->
    ## 14:40:00

    Second take.

    """

    private static let twoSectionsAtOneInstant = """
    # 16 November 2026

    <!-- dot-take 2026-11-16T14:32:05.123+03:00 -->
    ## 14:32:05

    Same words.

    <!-- dot-take 2026-11-16T14:32:05.123+03:00 -->
    ## 14:32:05

    Same words.

    """

    private static let appendedSection = """
    # 16 November 2026

    <!-- dot-take 2026-11-16T14:32:05.123+03:00 -->
    ## 14:32:05

    First take.

    <!-- dot-take 2026-11-16T09:05:00.000+03:00 -->
    ## 09:05:00

    Words written elsewhere.

    ### Concise

    First concise.

    """

    // MARK: - Helpers

    private func makeArchive(beforeCommit: (@Sendable (URL) -> Void)? = nil) -> TranscriptArchive {
        let zone = self.zone
        return TranscriptArchive(
            calendar: { zone.value },
            now: { Date() },
            home: home,
            beforeCommit: beforeCommit
        )
    }

    private func chosenFolder() throws -> URL {
        let folder = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func at(
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int,
        _ millisecond: Int,
        in calendar: Calendar? = nil
    ) -> Date {
        let used = calendar ?? self.calendar!
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = millisecond * 1_000_000
        guard let date = used.date(from: components) else {
            XCTFail("the calendar could not build \(components)")
            return Date()
        }
        return date
    }

    /// A calendar in a zone of its own, for the tests that move the person
    /// between zones.
    private func at(_ secondsFromGMT: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = TimeZone(secondsFromGMT: secondsFromGMT) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    private func concise() -> RewriteVersion {
        RewriteVersion(id: 1, origin: .style("concise"), title: "Concise", text: "First concise.", ordinal: 1)
    }

    private func conciseSecond() -> RewriteVersion {
        RewriteVersion(
            id: 2,
            origin: .style("concise"),
            title: "Concise",
            text: "First concise again.",
            ordinal: 2
        )
    }

    private func data(of name: String, in folder: URL) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(name))
    }

    private func text(of name: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    /// A value a test closure can carry across isolation domains.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) {
            stored = value
        }

        var value: Value {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }

    /// A flag a test closure can use once, across two isolation domains.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !used else { return false }
            used = true
            return true
        }
    }

    /// The device and inode a path names, so two spellings of one folder
    /// compare equal.
    private func identity(of url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let device = (attributes[.systemNumber] as? NSNumber)?.intValue ?? -1
        let node = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? -1
        return "\(device):\(node)"
    }

    /// The anchor lines the parser regards as sections.
    private static func anchorLines(in content: String) -> [String] {
        content
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("<!-- dot-take ") && $0.hasSuffix(" -->") }
    }

    /// The lines of the take in the first section, without its heading or its
    /// version blocks.
    private static func takeLines(in content: String) -> [String] {
        var lines: [String] = []
        var afterHeading = false
        for line in content.components(separatedBy: "\n") {
            guard afterHeading else {
                afterHeading = line.hasPrefix("## ")
                continue
            }
            if lines.isEmpty, line.isEmpty { continue }
            if line.isEmpty || line.hasPrefix("### ") { break }
            lines.append(line)
        }
        return lines
    }
}
