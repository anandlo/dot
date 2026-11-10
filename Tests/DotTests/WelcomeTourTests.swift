import CoreGraphics
@testable import Dot
import DotCore
import XCTest

/// Guards the welcome tour's demonstration.
///
/// Five earlier versions of this card were rejected because the wave was noise
/// with a shape on top. What replaced it is a recording model: syllables with
/// attacks and decays, words with breaths between them, and a sentence that is
/// written as it is said. These tests hold that structure, because it is the
/// only reason the animation reads as a voice.
final class WelcomeTourTests: XCTestCase {
    // MARK: - The voice

    /// Speech is bursts, not a slope: the schedule has to have more syllables
    /// than words, and every word has to have at least one.
    func testTheUtteranceIsMadeOfSyllables() {
        var perWord: [Int: Int] = [:]
        for syllable in SpeechSchedule.syllables {
            perWord[syllable.word, default: 0] += 1
        }
        XCTAssertEqual(perWord.count, TourFrame.words.count, "a word is never said")
        XCTAssertTrue(perWord.values.allSatisfy { $0 >= 1 })
        XCTAssertGreaterThan(
            SpeechSchedule.syllables.count,
            TourFrame.words.count,
            "one burst per word is not speech"
        )
        XCTAssertGreaterThan(SpeechSchedule.spoken, 1.5)
        XCTAssertLessThan(SpeechSchedule.spoken, 8.0)
    }

    /// Inside a word the sound does not return to nothing: the vowel is still
    /// sounding when the next consonant starts. A shape that dips to zero
    /// between syllables draws beads on a wire.
    func testTheSoundDoesNotBreakBetweenSyllablesOfAWord() {
        let words = Dictionary(grouping: SpeechSchedule.syllables, by: \.word)
        for (_, syllables) in words where syllables.count > 1 {
            let ordered = syllables.sorted { $0.start < $1.start }
            for pair in zip(ordered, ordered.dropFirst()) {
                let gapStart = pair.0.start + pair.0.duration
                let gapEnd = pair.1.start
                guard gapEnd > gapStart else { continue }
                var lowest = Double.greatestFiniteMagnitude
                var moment = gapStart
                while moment <= gapEnd {
                    lowest = min(lowest, SpeechSchedule.level(at: moment))
                    moment += 0.002
                }
                XCTAssertGreaterThan(lowest, 0.03, "the word breaks in the middle")
            }
        }
    }

    /// Silence before and after the utterance, and real sound inside it.
    func testTheUtteranceHasSilenceAroundIt() {
        XCTAssertEqual(SpeechSchedule.level(at: -0.2), 0, accuracy: 1e-9)
        XCTAssertEqual(SpeechSchedule.level(at: SpeechSchedule.spoken + 0.2), 0, accuracy: 1e-9)

        var loud = 0
        var quiet = 0
        var moment = 0.0
        while moment < SpeechSchedule.spoken {
            if SpeechSchedule.level(at: moment) > 0.5 { loud += 1 }
            if SpeechSchedule.level(at: moment) < 0.15 { quiet += 1 }
            moment += 0.01
        }
        XCTAssertGreaterThan(loud, 20, "the voice is never loud")
        XCTAssertGreaterThan(quiet, 20, "the voice never pauses for breath")
    }

    // MARK: - The line

    /// The line is exactly the words that have been said, in order.
    func testTheLineFollowsTheUtterance() {
        let finished = TourFrame.at(phase: 0.0, time: SpeechSchedule.spoken + 0.1)
        XCTAssertEqual(finished.spoken, TourFrame.words)
        XCTAssertEqual(finished.typed, TourFrame.sentence)

        let silent = TourFrame.at(phase: 0.0, time: 0.05)
        XCTAssertTrue(silent.spoken.isEmpty)
        XCTAssertEqual(silent.typed, "")

        var previous = 0
        var moment = 0.0
        while moment < SpeechSchedule.spoken {
            let frame = TourFrame.at(phase: 0.0, time: moment)
            XCTAssertGreaterThanOrEqual(frame.spoken.count, previous, "a word was taken back")
            previous = frame.spoken.count
            moment += 0.02
        }
    }

    /// A word appears when its last syllable ends, and not one moment earlier.
    func testAWordAppearsWhenItIsSaid() {
        for index in TourFrame.words.indices {
            let end = SpeechSchedule.finished(index)
            let before = TourFrame.at(phase: 0.0, time: end - 0.015)
            let after = TourFrame.at(phase: 0.0, time: end + 0.015)
            XCTAssertEqual(before.spoken.count, index, "word \(index) appeared before it was said")
            XCTAssertEqual(after.spoken.count, index + 1, "word \(index) did not appear when it was said")
        }
    }

    func testAStillFrameIsDeterministic() {
        XCTAssertEqual(TourFrame.at(phase: 0.40, time: 1.2), TourFrame.at(phase: 0.40, time: 1.2))
    }

    func testEveryStepSaysSomethingAndNoneOfThemRepeats() {
        let titles = TourStep.allCases.map { $0.title(shortcut: Hotkey.defaultRecord.label) }
        let details = TourStep.allCases.map(\.detail)

        for text in titles + details {
            XCTAssertGreaterThan(text.count, 12, "a tour line is too short to say anything: \(text)")
        }
        XCTAssertEqual(Set(titles).count, titles.count, "two steps share a title")
        XCTAssertEqual(Set(details).count, details.count, "two steps share a sentence")
        XCTAssertEqual(TourStep.allCases.count, 3, "the tour is three steps long")
    }

    func testTheShortcutInTheTitleFollowsARebind() {
        let rebound = "⌃⇧R"
        XCTAssertTrue(TourStep.hold.title(shortcut: rebound).contains(rebound))
    }

    // MARK: - The voice on the card is the island's voice

    /// The welcome card draws the island's waveform from the demonstration's own
    /// level, so the two surfaces cannot drift into different drawings of a
    /// voice.
    func testTheCardUsesTheIslandsWaveform() {
        let time = SpeechSchedule.spoken * 0.5
        let history = SpeechSchedule.history(endingAt: time)
        XCTAssertEqual(history.count, Waveform.historyLength)
        XCTAssertEqual(history.last ?? -1, SpeechSchedule.level(at: time), accuracy: 1e-12)

        let heights = Waveform.halfHeights(
            history: history,
            phase: SpeechSchedule.phase(at: time),
            count: Waveform.columnCount,
            maximum: 9,
            breath: time * 0.35
        )
        XCTAssertEqual(heights.count, Waveform.columnCount)
        XCTAssertTrue(heights.allSatisfy { $0 >= Waveform.minimumHalfHeight })
        XCTAssertGreaterThan(heights.max() ?? 0, Waveform.minimumHalfHeight * 2, "the voice is flat")
    }

    /// The history travels at the island's rate and ends at this moment.
    func testTheHistoryEndsAtThisMoment() {
        let time = 1.4
        let history = SpeechSchedule.history(endingAt: time)
        XCTAssertEqual(history.last ?? -1, SpeechSchedule.level(at: time), accuracy: 1e-12)
        let oldest = time - Double(Waveform.historyLength - 1) / Waveform.sampleRate
        XCTAssertEqual(history.first ?? -1, SpeechSchedule.level(at: oldest), accuracy: 1e-12)
    }

    @MainActor
    func testAllFiveHUDVisualizersRenderDistinctFrames() throws {
        var encoded: [HUDVisualizer: Data] = [:]
        for visualizer in HUDVisualizer.allCases {
            let rep = try HUDPreview.render(state: .recording, visualizer: visualizer)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2_000)
            encoded[visualizer] = data
        }
        let unique = Set(encoded.values)
        XCTAssertEqual(unique.count, HUDVisualizer.allCases.count, "every visualizer must draw a distinct waveform")
    }

    func testLaunchAtLoginAgentLifecycle() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-login-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plistURL = tempDir.appendingPathComponent("com.local.dot.plist")
        XCTAssertFalse(LaunchAtLogin.isAgentEnabled(at: plistURL))

        try LaunchAtLogin.writeAgent(at: plistURL, executablePath: "/Applications/Dot.app/Contents/MacOS/Dot")
        XCTAssertTrue(LaunchAtLogin.isAgentEnabled(at: plistURL))

        try LaunchAtLogin.removeAgent(at: plistURL)
        XCTAssertFalse(LaunchAtLogin.isAgentEnabled(at: plistURL))
    }
}
