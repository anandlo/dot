import Foundation
import XCTest

@testable import DotCore

/// The interaction setting: what it defaults to, what it survives, and what it
/// does to the state machine.
///
/// The mode is one key in `config.json`, so the two things that can go wrong are
/// silent: a file written before the key existed must load as press-twice, and a
/// file that names a mode no build knows must not take the whole configuration
/// down with it. Both are asserted against a real file on disk, because that is
/// the only place they matter.
final class RecordingModeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-recording-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, named name: String = "config.json") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The setting

    func testTheDefaultIsPressTwice() {
        XCTAssertEqual(DotConfig.default.recordingMode, .toggle)
        XCTAssertEqual(DotConfig().recordingMode, .toggle)
    }

    func testAFileWithoutTheKeyLoadsAsPressTwice() throws {
        // A file written by the hold-to-talk build has no field at all.
        let url = try write(#"{"provider": "openai", "autoPaste": false}"#)
        let loaded = DotConfig.load(from: url)
        XCTAssertEqual(loaded.recordingMode, .toggle)
        XCTAssertFalse(loaded.autoPaste, "the field the file did set is still read")
    }

    func testAnExplicitModeSurvivesTheRoundTrip() throws {
        for mode in RecordingMode.allCases {
            var config = DotConfig.default
            config.recordingMode = mode
            let url = directory.appendingPathComponent("mode-\(mode.rawValue).json")
            try config.save(to: url)

            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("\"recordingMode\" : \"\(mode.rawValue)\""), text)
            XCTAssertEqual(DotConfig.load(from: url).recordingMode, mode)
        }
    }

    func testAKeyTheBuildDoesNotKnowLoadsAsPressTwice() throws {
        // A hand-edited file, or a file written by a newer build: the rest of
        // the configuration has to survive, so this may not throw.
        let url = try write(#"{"provider": "openai", "recordingMode": "wave"}"#)
        let loaded = DotConfig.load(from: url)
        XCTAssertEqual(loaded.recordingMode, .toggle)
        XCTAssertEqual(loaded.provider, "openai", "an unknown mode may not reset the file")
    }

    func testAnExplicitNullLoadsAsPressTwice() throws {
        let url = try write(#"{"recordingMode": null}"#)
        XCTAssertEqual(DotConfig.load(from: url).recordingMode, .toggle)
    }

    // MARK: - The words on the surfaces

    func testEveryModeIsNamedAndExplained() {
        let titles = RecordingMode.allCases.map(\.title)
        let details = RecordingMode.allCases.map(\.detail)
        XCTAssertEqual(titles, ["Press to start, press to stop", "Hold while speaking"])
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(Set(details).count, details.count)
        for detail in details {
            XCTAssertGreaterThan(detail.count, 20, "one line that states the interaction: \(detail)")
            XCTAssertFalse(detail.contains("\n"), detail)
        }
    }

    // MARK: - The state machine

    /// The interaction as the app sees it: one edge at a time.
    ///
    /// The `phase` is carried from action to action the way the delegate carries
    /// its `state`, so this is the same loop the app runs rather than a table
    /// read in isolation.
    private func run(
        _ edges: [RecordKeyGesture],
        mode: RecordingMode
    ) -> [RecordingAction] {
        var phase = RecordingPhase.idle
        var log: [RecordingAction] = []
        for edge in edges {
            let action = RecordKeyInteraction.action(for: edge, mode: mode, phase: phase)
            log.append(action)
            switch action {
            case .start: phase = .recording
            case .stop: phase = .idle
            case .ignore: break
            }
        }
        return log
    }

    func testPressTwiceIsStartThenStopThenStart() {
        let actions = run([.press, .release, .press, .release, .press], mode: .toggle)
        XCTAssertEqual(actions, [.start, .ignore, .stop, .ignore, .start])
    }

    func testPressTwiceDoesNotStopOnRelease() {
        // The release after the starting press is the one that used to end a
        // recording. It is not an instruction in this mode.
        XCTAssertEqual(
            RecordKeyInteraction.action(for: .release, mode: .toggle, phase: .recording),
            .ignore
        )
        // The recording is still running until the next press.
        XCTAssertEqual(
            RecordKeyInteraction.action(for: .press, mode: .toggle, phase: .recording),
            .stop
        )
    }

    func testHoldStopsOnRelease() {
        let actions = run([.press, .release, .press, .release], mode: .hold)
        XCTAssertEqual(actions, [.start, .stop, .start, .stop])
    }

    func testASecondPressStopsInBothModes() {
        // The fallback for a release the keyboard state could not read. In hold
        // mode this is the way out of a recording whose key-up Dot never saw.
        for mode in RecordingMode.allCases {
            XCTAssertEqual(
                RecordKeyInteraction.action(for: .press, mode: mode, phase: .recording),
                .stop,
                mode.rawValue
            )
        }
    }

    func testAPressWhileTheWordsAreBeingWrittenIsIgnored() {
        for mode in RecordingMode.allCases {
            XCTAssertEqual(
                RecordKeyInteraction.action(for: .press, mode: mode, phase: .working),
                .ignore,
                mode.rawValue
            )
            XCTAssertEqual(
                RecordKeyInteraction.action(for: .release, mode: mode, phase: .working),
                .ignore,
                mode.rawValue
            )
        }
    }

    func testNothingStartsOnARelease() {
        for mode in RecordingMode.allCases {
            XCTAssertEqual(
                RecordKeyInteraction.action(for: .release, mode: mode, phase: .idle),
                .ignore,
                mode.rawValue
            )
        }
    }

    func testTheToggleLoopSurvivesARecordingThatWaits() {
        // A tap that outlives the microphone prompt: the release arrives while
        // the prompt is up, and the recording still has to run until the next
        // press. Five seconds of edges between the two presses change nothing.
        var phase = RecordingPhase.idle
        XCTAssertEqual(
            RecordKeyInteraction.action(for: .press, mode: .toggle, phase: phase),
            .start
        )
        phase = .recording
        for _ in 0..<5 {
            XCTAssertEqual(
                RecordKeyInteraction.action(for: .release, mode: .toggle, phase: phase),
                .ignore
            )
        }
        XCTAssertEqual(
            RecordKeyInteraction.action(for: .press, mode: .toggle, phase: phase),
            .stop
        )
    }
}
