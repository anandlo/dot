import XCTest

@testable import DotCore

/// The dwell of the transcript card, and the migration that brought it here.
final class HUDDwellTests: XCTestCase {
    func testTheTranscriptStaysForTenSeconds() {
        XCTAssertEqual(HUDDwell.defaultSeconds, 10)
        XCTAssertEqual(DotConfig.default.hudDwellSeconds, 10)
        XCTAssertEqual(DotConfig.firstRun().hudDwellSeconds, 10)
        XCTAssertEqual(DotConfig.default.hudDwellRevision, HUDDwell.revision)

        // The slider has to be able to reach the dwell the card starts with,
        // and the old range stopped at it.
        XCTAssertEqual(HUDDwell.legacyDefaultSeconds, 4)
        XCTAssertLessThan(HUDDwell.minimumSeconds, HUDDwell.defaultSeconds)
        XCTAssertGreaterThan(HUDDwell.maximumSeconds, HUDDwell.defaultSeconds)
    }

    func testAnUntouchedConfigurationMovesToTheNewDefault() {
        // Four seconds is what every configuration that never moved the slider
        // holds: the old default was written into the file, so it cannot be told
        // apart from a choice, and it is the value that vanished too fast.
        XCTAssertEqual(HUDDwell.migrated(4, revision: 0), 10)
        XCTAssertEqual(HUDDwell.migrated(4.0, revision: 0), HUDDwell.defaultSeconds)
    }

    func testAChosenDwellIsKept() {
        // Anything else in the file was chosen by hand and stays as it was.
        XCTAssertEqual(HUDDwell.migrated(2, revision: 0), 2)
        XCTAssertEqual(HUDDwell.migrated(3.5, revision: 0), 3.5)
        XCTAssertEqual(HUDDwell.migrated(12, revision: 0), 12)
        XCTAssertEqual(HUDDwell.migrated(20, revision: 0), 20)
        // A value the slider cannot show is held at its ends, not thrown away.
        XCTAssertEqual(HUDDwell.migrated(0.5, revision: 0), HUDDwell.minimumSeconds)
        XCTAssertEqual(HUDDwell.migrated(90, revision: 0), HUDDwell.maximumSeconds)
        XCTAssertEqual(HUDDwell.migrated(.nan, revision: 0), HUDDwell.defaultSeconds)
    }

    func testAFileThatCarriesTheRevisionIsNotMigratedAgain() {
        XCTAssertEqual(HUDDwell.migrated(4, revision: HUDDwell.revision), 4)
        XCTAssertEqual(HUDDwell.migrated(7, revision: HUDDwell.revision), 7)
        XCTAssertEqual(HUDDwell.migrated(4, revision: HUDDwell.revision + 1), 4)
    }

    func testTheMigrationRewritesAConfigurationOnce() {
        var config = DotConfig.default
        config.hudDwellSeconds = HUDDwell.legacyDefaultSeconds
        config.hudDwellRevision = 0

        XCTAssertTrue(HUDDwellMigration.apply(to: &config))
        XCTAssertEqual(config.hudDwellSeconds, 10)
        XCTAssertEqual(config.hudDwellRevision, HUDDwell.revision)

        XCTAssertFalse(HUDDwellMigration.apply(to: &config), "the second launch must not migrate")
        XCTAssertEqual(config.hudDwellSeconds, 10)

        // A dwell chosen after the migration survives the next launch.
        config.hudDwellSeconds = 6
        XCTAssertFalse(HUDDwellMigration.apply(to: &config))
        XCTAssertEqual(config.hudDwellSeconds, 6)
    }

    func testTheRevisionIsWrittenIntoTheFileAndAnOldFileHasNone() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-dwell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("config.json")
        try DotConfig.default.save(to: url)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(payload["hudDwellRevision"] as? Int, HUDDwell.revision)
        XCTAssertEqual(payload["hudDwellSeconds"] as? Double, 10)

        // A file from a build that did not know the revision decodes as zero,
        // which is what makes the migration run.
        let legacy = directory.appendingPathComponent("legacy.json")
        try #"{"hudDwellSeconds": 4}"#.write(to: legacy, atomically: true, encoding: .utf8)
        let loaded = DotConfig.load(from: legacy)
        XCTAssertEqual(loaded.hudDwellSeconds, 4)
        XCTAssertEqual(loaded.hudDwellRevision, 0)
    }

    func testAScrollSuspendsTheDwellForItsGrace() {
        XCTAssertTrue(HUDDwell.isInteracting(pointerInside: true, lastScroll: nil, now: 100))
        XCTAssertFalse(HUDDwell.isInteracting(pointerInside: false, lastScroll: nil, now: 100))

        let scrolledAt = 100.0
        XCTAssertTrue(
            HUDDwell.isInteracting(pointerInside: false, lastScroll: scrolledAt, now: 100.1)
        )
        XCTAssertTrue(
            HUDDwell.isInteracting(
                pointerInside: false,
                lastScroll: scrolledAt,
                now: 100 + HUDDwell.scrollGrace - 0.01
            )
        )
        XCTAssertFalse(
            HUDDwell.isInteracting(
                pointerInside: false,
                lastScroll: scrolledAt,
                now: 100 + HUDDwell.scrollGrace
            )
        )
        // A clock that went backwards must not suspend the dwell for ever.
        XCTAssertFalse(
            HUDDwell.isInteracting(pointerInside: false, lastScroll: scrolledAt, now: 99)
        )
        XCTAssertFalse(
            HUDDwell.isInteracting(pointerInside: false, lastScroll: .nan, now: 100)
        )
    }
}

/// The countdown that dismisses the card, and the pause that reading gives it.
final class HUDDwellClockTests: XCTestCase {
    func testTheCountdownStartsAtTheWholeDwell() {
        let clock = HUDDwellClock(duration: 10, now: 500)

        XCTAssertEqual(clock.duration, 10)
        XCTAssertEqual(clock.remaining, 10)
        XCTAssertFalse(clock.isExpired)
        XCTAssertFalse(clock.isPaused)
    }

    func testTheCountdownExpiresWhenTheDwellIsSpent() {
        var clock = HUDDwellClock(duration: 10, now: 500)

        XCTAssertFalse(clock.advance(to: 503, interacting: false))
        XCTAssertEqual(clock.remaining, 7, accuracy: 0.0001)

        XCTAssertFalse(clock.advance(to: 509.5, interacting: false))
        XCTAssertEqual(clock.remaining, 0.5, accuracy: 0.0001)

        XCTAssertTrue(clock.advance(to: 510, interacting: false))
        XCTAssertTrue(clock.isExpired)
        XCTAssertEqual(clock.remaining, 0)
    }

    func testHoverSuspendsWithoutResettingTheCountdown() {
        var clock = HUDDwellClock(duration: 10, now: 0)

        clock.advance(to: 3, interacting: false)
        XCTAssertEqual(clock.remaining, 7, accuracy: 0.0001)

        // A hundred seconds of reading must neither spend the dwell nor give
        // the card a fresh one.
        clock.advance(to: 60, interacting: true)
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.remaining, 7, accuracy: 0.0001)

        clock.advance(to: 103, interacting: true)
        XCTAssertEqual(clock.remaining, 7, accuracy: 0.0001)
        XCTAssertFalse(clock.isExpired)

        // The pointer leaves: the countdown resumes where it stopped.
        XCTAssertFalse(clock.advance(to: 109.9, interacting: false))
        XCTAssertEqual(clock.remaining, 0.1, accuracy: 0.0001)

        XCTAssertTrue(clock.advance(to: 110, interacting: false))
        XCTAssertTrue(clock.isExpired)
    }

    func testThePauseIsThePointersAndNotTheClocks() {
        var clock = HUDDwellClock(duration: 4, now: 0)

        clock.advance(to: 4.5, interacting: true)
        XCTAssertTrue(clock.isPaused)
        XCTAssertFalse(clock.isExpired)

        // Leaving the card spends nothing that was not left.
        clock.advance(to: 5, interacting: false)
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.remaining, 3.5, accuracy: 0.0001)
    }

    func testABackwardsOrFrozenClockAddsNoTime() {
        var clock = HUDDwellClock(duration: 10, now: 100)

        clock.advance(to: 104, interacting: false)
        XCTAssertEqual(clock.remaining, 6, accuracy: 0.0001)

        clock.advance(to: 104, interacting: false)
        XCTAssertEqual(clock.remaining, 6, accuracy: 0.0001)

        clock.advance(to: 90, interacting: false)
        XCTAssertEqual(clock.remaining, 6, accuracy: 0.0001)
    }

    func testADwellCanBeRestartedForTheNextCard() {
        var clock = HUDDwellClock(duration: 10, now: 0)
        clock.advance(to: 20, interacting: true)

        clock.restart(duration: 5, now: 30)

        XCTAssertEqual(clock.duration, 5)
        XCTAssertEqual(clock.remaining, 5)
        XCTAssertFalse(clock.isPaused)
        XCTAssertFalse(clock.advance(to: 34, interacting: false))
        XCTAssertEqual(clock.remaining, 1, accuracy: 0.0001)
    }

    func testATimeThatIsNotANumberNeverHangsTheClock() {
        var clock = HUDDwellClock(duration: 10, now: 0)

        XCTAssertFalse(clock.advance(to: .nan, interacting: false))
        XCTAssertFalse(clock.advance(to: 4, interacting: false))
        XCTAssertEqual(clock.remaining, 6, accuracy: 0.0001)
        XCTAssertFalse(clock.advance(to: .infinity, interacting: false))
        XCTAssertEqual(clock.remaining, 6, accuracy: 0.0001)
        XCTAssertTrue(clock.advance(to: 20, interacting: false))
    }

    func testADwellThatIsNotANumberNeverHangs() {
        var clock = HUDDwellClock(duration: .nan, now: 0)

        XCTAssertEqual(clock.duration, 0)
        XCTAssertTrue(clock.isExpired)
        XCTAssertTrue(clock.advance(to: 1, interacting: false))
        XCTAssertTrue(clock.advance(to: 2, interacting: true))
    }
}
