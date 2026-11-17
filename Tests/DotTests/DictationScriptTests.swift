import AppKit
import CoreGraphics
import DotCore
@testable import Dot
import XCTest

/// Guards the dictation the visualiser previews are drawn from.
///
/// The demonstration used to be a nine syllable sentence of near identical
/// syllables at a fixed tempo, with the five bands faked from four sine waves.
/// What replaced it is a script: thirty three syllables over twenty six words in
/// five phrases, with the lengths, the stress, the declination and the pauses of
/// a person dictating, and bands that come from which syllable is sounding. These
/// tests hold that structure, because it is the whole reason the preview reads as
/// a dictation rather than as an animation.
final class DictationScriptTests: XCTestCase {
    // MARK: - The script itself

    /// The script is written once and read by every surface, so two calls have to
    /// be the same take: no clock, no generator with state, no dependence on the
    /// order the surfaces ask.
    func testTheScriptIsTheSameOnEveryRun() {
        for time in [0.0, 0.37, 3.1, 6.93, 11.0, DictationScript.loop] {
            XCTAssertEqual(DictationScript.level(at: time), DictationScript.level(at: time))
            let first = DictationScript.bands(at: time)
            let second = DictationScript.bands(at: time)
            XCTAssertEqual(first, second)
        }
        XCTAssertEqual(
            DictationScript.history(endingAt: 6.4),
            DictationScript.history(endingAt: 6.4)
        )
        XCTAssertEqual(
            DictationScript.spectrumHistory(endingAt: 6.4),
            DictationScript.spectrumHistory(endingAt: 6.4)
        )
        XCTAssertEqual(DictationScript.phase(at: 4.2), DictationScript.phase(at: 4.2))
        XCTAssertEqual(DictationScript.stillTime, DictationScript.stillTime)
        XCTAssertEqual(DictationScript.syllables, DictationScript.syllables)
    }

    /// Thirty three syllables over twenty six words, and every word is said.
    func testTheScriptIsThirtyThreeSyllablesOverTwentySixWords() {
        let syllables = DictationScript.syllables
        XCTAssertEqual(syllables.count, 33)
        XCTAssertEqual(DictationScript.wordCount, 26)
        let groups = Dictionary(grouping: syllables, by: \.wordIndex)
        XCTAssertEqual(groups.count, 26, "every word is said")
        for word in 0..<26 {
            XCTAssertGreaterThanOrEqual(groups[word]?.count ?? 0, 1, "word \(word) has no syllable")
        }
        XCTAssertGreaterThan(syllables.count, DictationScript.wordCount, "one burst per word is not speech")
        XCTAssertEqual(Set(syllables.map(\.phrase)), [0, 1, 2, 3, 4], "five phrases")
        XCTAssertEqual(DictationScript.pauses.count, 4, "a breath after every phrase but the last")
        XCTAssertEqual(DictationScript.pauses.filter { $0.kind == .clause }.count, 2)
        XCTAssertEqual(DictationScript.pauses.filter { $0.kind == .sentence }.count, 2)
    }

    /// Every length and every peak is inside the band its stress is written from,
    /// and the whole line runs forward in time.
    func testEverySyllableIsInsideItsOwnBands() {
        var previousStart = -Double.greatestFiniteMagnitude
        for syllable in DictationScript.syllables {
            XCTAssertTrue(
                syllable.stress.durationRange.contains(syllable.duration),
                "\(syllable.text) is \(syllable.duration) s"
            )
            XCTAssertTrue(
                syllable.stress.peakRange.contains(syllable.drawnPeak),
                "\(syllable.text) drew \(syllable.drawnPeak)"
            )
            XCTAssertGreaterThanOrEqual(syllable.position, 0)
            XCTAssertLessThanOrEqual(syllable.position, 1)
            XCTAssertGreaterThan(syllable.peak, 0)
            XCTAssertLessThanOrEqual(syllable.peak, DictationScript.loudest)
            XCTAssertGreaterThan(syllable.start, previousStart, "the script runs backwards at \(syllable.text)")
            previousStart = syllable.start
        }
        XCTAssertEqual(DictationScript.syllables.first?.start, DictationScript.leadIn)
        XCTAssertEqual(DictationScript.speechStart, DictationScript.leadIn)
    }

    /// The gaps are the ones a person leaves: a breath inside a word, a shorter
    /// one between words, and the two sizes of pause between phrases.
    func testTheGapsAreTheOnesAPersonLeaves() {
        let syllables = DictationScript.syllables
        for (syllable, next) in zip(syllables, syllables.dropFirst()) where syllable.wordIndex != next.wordIndex {
            let gap = next.start - (syllable.start + syllable.duration)
            if syllable.phrase != next.phrase {
                let pause = DictationScript.pauses.first { $0.start == syllable.start + syllable.duration }
                XCTAssertNotNil(pause, "no pause between the phrases after \(syllable.text)")
                guard let pause else { continue }
                let range = pause.kind == .clause ? DictationScript.clausePause : DictationScript.sentencePause
                XCTAssertTrue(range.contains(pause.duration), "a \(pause.kind) pause of \(pause.duration) s")
                XCTAssertEqual(gap, pause.duration, accuracy: 1e-12)
            } else {
                XCTAssertTrue(
                    DictationScript.wordGap.contains(gap),
                    "a breath of \(gap) s between \(syllable.text) and \(next.text)"
                )
            }
        }
    }

    /// The level is a level: nothing outside the script sounds, and nothing inside
    /// it leaves the range the card draws.
    func testTheLevelStaysInsideZeroAndOne() {
        var time = -1.0
        while time <= DictationScript.loop + 1 {
            let level = DictationScript.level(at: time)
            XCTAssertGreaterThanOrEqual(level, 0, "level \(level) at \(time) s")
            XCTAssertLessThanOrEqual(level, 1, "level \(level) at \(time) s")
            time += 0.005
        }
        XCTAssertEqual(DictationScript.level(at: -0.2), 0)
        XCTAssertEqual(DictationScript.level(at: DictationScript.loop + 0.2), 0)
    }

    /// The room is heard before the first syllable and after the last, and it is
    /// quiet: a microphone never hears nothing, and a demonstration that opens on
    /// a cut opens on a sound effect.
    func testTheRoomIsHeardBeforeAndAfterTheVoice() {
        for time in [0.0, 0.25, DictationScript.leadIn - 0.05] {
            let level = DictationScript.level(at: time)
            XCTAssertGreaterThan(level, 0, "the lead-in is a cut at \(time) s")
            XCTAssertLessThan(level, 0.08, "the lead-in is loud at \(time) s: \(level)")
        }
        for time in [DictationScript.duration - 0.4, DictationScript.duration, DictationScript.loop] {
            let level = DictationScript.level(at: time)
            XCTAssertGreaterThan(level, 0, "the tail is a cut at \(time) s")
            XCTAssertLessThan(level, 0.08, "the tail is loud at \(time) s: \(level)")
        }
    }

    /// The script has one loudest syllable, `send`, and its peak is the value the
    /// design names.
    func testTheLoudestSyllableIsTheScriptsPeak() {
        let send = DictationScript.syllables.first { $0.text == "send" }
        XCTAssertNotNil(send)
        guard let send else { return }
        XCTAssertEqual(send.peak, DictationScript.loudest)
        XCTAssertEqual(DictationScript.level(at: send.crest), DictationScript.loudest, accuracy: 0.02)

        // Nothing anywhere in the loop is louder, and no other syllable's crest
        // reaches the peak.
        var loudest = 0.0
        var time = 0.0
        while time <= DictationScript.loop {
            loudest = max(loudest, DictationScript.level(at: time))
            time += 0.001
        }
        XCTAssertEqual(loudest, DictationScript.loudest, accuracy: 0.02, "the loudest moment is \(loudest)")
        for syllable in DictationScript.syllables where syllable.text != "send" {
            XCTAssertLessThan(syllable.peak, DictationScript.loudest)
        }
    }

    /// The pace and the length of the demonstration, measured.
    ///
    /// A dictation is spoken at a hundred and thirty to a hundred and sixty words
    /// a minute, and the loop the preview draws is twelve to fifteen seconds. The
    /// old demonstration was a four and a half second loop, which is what made it
    /// look like an animation: a person does not finish a sentence that fast.
    func testThePaceIsADictationPace() {
        let pace = Double(DictationScript.wordCount) / DictationScript.speech * 60
        print(String(
            format: "DICTATION pace %.1f wpm over %.3f s of speech, %d syllables, %d words, duration %.3f s, loop %.3f s, still %.3f s",
            pace,
            DictationScript.speech,
            DictationScript.syllables.count,
            DictationScript.wordCount,
            DictationScript.duration,
            DictationScript.loop,
            DictationScript.stillTime
        ))
        XCTAssertTrue((130...160).contains(pace), "the script is spoken at \(pace) words a minute")
        XCTAssertTrue(
            (12...15).contains(DictationScript.duration),
            "the loop is \(DictationScript.duration) s"
        )
        XCTAssertEqual(DictationScript.duration, DictationScript.leadIn + DictationScript.speech + DictationScript.trailing)
        XCTAssertEqual(DictationScript.loop, DictationScript.duration + DictationScript.resting)
    }

    /// The loudness falls through every phrase, by the declination the script
    /// names: that is what makes a phrase read as one arc instead of as a row of
    /// equally loud words.
    func testTheDeclinationFallsThroughEveryPhrase() {
        // The brief's own number: a phrase loses eighteen per cent of its
        // loudness from its first syllable to its last.
        XCTAssertEqual(DictationScript.declination, 0.18, accuracy: 1e-12)

        for syllable in DictationScript.syllables where syllable.text != "send" {
            let noise = syllable.fricative ? DictationScript.fricativeScale : 1
            XCTAssertEqual(
                syllable.peak,
                syllable.drawnPeak * (1 - DictationScript.declination * syllable.position) * noise,
                accuracy: 1e-12,
                "\(syllable.text) at \(syllable.position) of its phrase"
            )
            // And the fall is a fall rather than a formula: every syllable that
            // is not the first of its phrase is quieter than the peak its stress
            // drew.
            if syllable.position > 0 {
                XCTAssertLessThan(
                    syllable.peak,
                    syllable.drawnPeak * noise,
                    "\(syllable.text) is at \(syllable.position) of its phrase and has not fallen"
                )
            }
        }

        // The position is the syllable's own place in its phrase, from nothing at
        // the first to one at the last, so a phrase of `n` syllables falls in `n`
        // steps.
        for (phrase, syllables) in Dictionary(grouping: DictationScript.syllables, by: \.phrase) {
            let ordered = syllables.sorted { $0.start < $1.start }
            XCTAssertEqual(ordered.first?.position, 0, "phrase \(phrase) does not open on its first syllable")
            XCTAssertEqual(ordered.last?.position, 1, "phrase \(phrase) does not end on its last syllable")
            for (syllable, next) in zip(ordered, ordered.dropFirst()) {
                XCTAssertGreaterThan(next.position, syllable.position)
            }
        }
    }

    /// A pause is a breath and a sentence pause is a longer one.
    ///
    /// The level at the middle of every pause is under half the quieter of the two
    /// syllables it sits between. A sentence pause is lower still: the release
    /// that crosses into a pause is the same length whatever the pause is, so over
    /// a longer pause it is a smaller share of the silence and the mean level
    /// across it is lower.
    func testThePausesAreBreaths() {
        let syllables = DictationScript.syllables
        func meanLevel(over pause: DictationScript.Pause) -> Double {
            var sum = 0.0
            var count = 0
            var time = pause.start
            while time <= pause.start + pause.duration {
                sum += DictationScript.level(at: time)
                count += 1
                time += 0.005
            }
            return sum / Double(max(1, count))
        }

        var clauseMeans: [Double] = []
        var sentenceMeans: [Double] = []
        for pause in DictationScript.pauses {
            let mid = pause.start + pause.duration / 2
            let before = syllables.last { $0.start < pause.start }
            let after = syllables.first { $0.start > mid }
            XCTAssertNotNil(before)
            XCTAssertNotNil(after)
            guard let before, let after else { continue }
            let quieter = min(before.peak, after.peak)
            XCTAssertLessThan(
                DictationScript.level(at: mid),
                0.5 * quieter,
                "the middle of a \(pause.kind) pause is not a breath"
            )
            let mean = meanLevel(over: pause)
            if pause.kind == .clause {
                clauseMeans.append(mean)
            } else {
                sentenceMeans.append(mean)
            }
        }
        print("DICTATION pause means clause \(clauseMeans) sentence \(sentenceMeans)")
        XCTAssertEqual(clauseMeans.count, 2)
        XCTAssertEqual(sentenceMeans.count, 2)
        for sentence in sentenceMeans {
            for clause in clauseMeans {
                XCTAssertLessThan(sentence, clause, "a sentence pause is not the deeper of the two")
            }
        }
    }

    /// Two syllables of a word overlap, so the level does not return to nothing
    /// inside a word: a word is one gesture and not two beats.
    func testTheSyllablesOfAWordOverlap() {
        let syllables = DictationScript.syllables
        for (syllable, next) in zip(syllables, syllables.dropFirst()) where syllable.wordIndex == next.wordIndex {
            let shorter = min(syllable.duration, next.duration)
            let overlap = syllable.duration - (next.start - syllable.start)
            XCTAssertGreaterThan(overlap, 0, "\(syllable.text)\(next.text) do not overlap")
            XCTAssertLessThanOrEqual(
                overlap,
                DictationScript.coarticulation * shorter + 1e-12,
                "\(syllable.text)\(next.text) overlap by more than the coarticulation"
            )
            XCTAssertGreaterThanOrEqual(
                overlap,
                DictationScript.coarticulation * shorter - DictationScript.intraWordGap.upperBound,
                "\(syllable.text)\(next.text) are separated by a breath"
            )
            var lowest = 1.0
            var time = syllable.crest
            while time <= next.crest {
                lowest = min(lowest, DictationScript.level(at: time))
                time += 0.001
            }
            XCTAssertGreaterThan(
                lowest,
                0.35 * min(syllable.peak, next.peak),
                "the level falls to \(lowest) between \(syllable.text) and \(next.text)"
            )
        }
    }

    // MARK: - The five bands

    /// A fricative is noise and a vowel is voice: the top row of the grid carries
    /// an `s` and the bottom row carries the vowel under it.
    func testFricativesAreNoiseAndVowelsAreVoice() {
        for syllable in DictationScript.syllables {
            let frame = DictationScript.bands(at: syllable.crest)
            if syllable.fricative {
                XCTAssertGreaterThan(
                    frame.bands.4,
                    frame.bands.0,
                    "\(syllable.text) is a fricative and its bands do not say so"
                )
            } else if syllable.stress != .function {
                XCTAssertGreaterThan(
                    frame.bands.0,
                    frame.bands.4,
                    "\(syllable.text) is a vowel and its bands do not say so"
                )
            }
            for band in 0..<5 {
                XCTAssertGreaterThanOrEqual(frame[band], 0)
                XCTAssertLessThanOrEqual(frame[band], 1)
            }
        }
    }

    /// The five rows are not one envelope drawn five times: which bands carry the
    /// level changes with the words, and the top row lifts by more than an order
    /// of magnitude on the syllables with an `s` in them.
    func testTheBandsAreNotTheEnvelopeDrawnFiveTimes() {
        var ratios: [Double] = []
        var time = 0.0
        while time <= DictationScript.loop {
            let frame = DictationScript.bands(at: time)
            if frame.bands.0 > 0.02 {
                ratios.append(frame.bands.4 / frame.bands.0)
            }
            time += 0.01
        }
        let lowest = ratios.min() ?? 0
        let highest = ratios.max() ?? 0
        print(String(format: "DICTATION band4/band0 over the loop %.3f to %.3f", lowest, highest))
        XCTAssertGreaterThan(highest, 2 * lowest, "the bands move together: \(lowest) to \(highest)")
        XCTAssertLessThan(lowest, 0.5, "no moment is dominated by the top row")
        XCTAssertGreaterThan(highest, 2, "no moment is dominated by the bottom row")
    }

    /// The bands are quiet exactly where the voice is: silence is the room, and
    /// the room has no spectrum to draw.
    func testSilenceHasNoBands() {
        for time in [0.0, 0.5, DictationScript.leadIn - 0.02, DictationScript.loop] {
            XCTAssertEqual(DictationScript.bands(at: time), .zero, "bands at \(time) s")
        }
        XCTAssertEqual(DictationScript.bands(at: -1), .zero)
        XCTAssertEqual(DictationScript.bands(at: DictationScript.loop + 1), .zero)
        XCTAssertNotEqual(DictationScript.bands(at: DictationScript.stillTime), .zero)
    }

    // MARK: - What the card draws

    /// The history is the card's own: three seconds at sixty samples a second,
    /// ending on this moment.
    func testTheHistoryIsTheCardsHistory() {
        for time in [2.9, 6.93, DictationScript.duration - 0.1] {
            let history = DictationScript.history(endingAt: time)
            XCTAssertEqual(history.count, Waveform.historyLength)
            XCTAssertEqual(history.last ?? -1, DictationScript.level(at: time), accuracy: 1e-12)
            let oldest = time - Double(Waveform.historyLength - 1) / Waveform.sampleRate
            XCTAssertEqual(history.first ?? -1, DictationScript.level(at: oldest), accuracy: 1e-12)
        }
    }

    /// The spectrum history is the same length as the envelope history and is
    /// already on the scale the drawing reads.
    func testTheSpectrumHistoryIsDrawable() {
        let time = DictationScript.stillTime
        let frames = DictationScript.spectrumHistory(endingAt: time)
        XCTAssertEqual(frames.count, Waveform.historyLength)
        var loudest = 0.0
        for frame in frames {
            for band in 0..<5 {
                XCTAssertGreaterThanOrEqual(frame[band], 0)
                XCTAssertLessThanOrEqual(frame[band], 1)
                loudest = max(loudest, frame[band])
            }
        }
        XCTAssertGreaterThan(loudest, 0.5, "the spectrum history is flat")
    }

    /// The loop joins: the room at the end of the script is the room at the start
    /// of it, and the preview's clock wraps on the same measurement.
    func testTheLoopWrapsSeamlessly() {
        XCTAssertEqual(
            DictationScript.level(at: DictationScript.loop),
            DictationScript.level(at: 0),
            accuracy: 0.03,
            "the loop joins with a step"
        )
        XCTAssertEqual(
            DictationScript.level(at: DictationScript.loop - 1 / Waveform.sampleRate),
            DictationScript.level(at: 0),
            accuracy: 0.05
        )
    }

    /// The preview and the tile both draw this script, at its own loop and its own
    /// frozen moment.
    @MainActor
    func testThePreviewAndTheTileDrawTheScript() {
        XCTAssertEqual(HUD.previewDismissDelay, DictationScript.loop)
        XCTAssertEqual(HUD.previewOffset, 0.4)
        XCTAssertEqual(
            HUD.previewPhase(now: 40 + DictationScript.loop, startedAt: 40),
            HUD.previewPhase(now: 40, startedAt: 40),
            accuracy: 1e-9,
            "the preview's clock does not wrap on the script's loop"
        )
        XCTAssertEqual(
            HUD.previewPhase(now: 40 + DictationScript.loop / 2, startedAt: 40),
            0.4 + DictationScript.loop / 2,
            accuracy: 1e-9
        )
        XCTAssertEqual(HUD.wrapped(-0.25, loop: DictationScript.loop), DictationScript.loop - 0.25, accuracy: 1e-12)
        XCTAssertEqual(HUD.wrapped(DictationScript.loop + 0.25, loop: DictationScript.loop), 0.25, accuracy: 1e-12)

        XCTAssertEqual(VisualizerTile.loop, DictationScript.loop, "the tile loops over the script")
        XCTAssertEqual(VisualizerTile.stillTime, DictationScript.stillTime)
        XCTAssertEqual(
            VisualizerTile.history(at: DictationScript.stillTime),
            DictationScript.history(endingAt: DictationScript.stillTime)
        )
        XCTAssertEqual(
            VisualizerTile.spectrum(at: DictationScript.stillTime).count,
            Waveform.historyLength
        )
        let send = DictationScript.syllables.first { $0.text == "send" }
        XCTAssertNotNil(send)
        if let send {
            XCTAssertGreaterThan(VisualizerTile.stillTime, send.crest, "the still is frozen before the peak")
            XCTAssertLessThan(
                VisualizerTile.stillTime,
                send.end + 0.1,
                "the still is frozen after the syllable has gone"
            )
        }
    }
}

// MARK: - Evidence

extension DictationScriptTests {
    /// Where the plot and the syllable table are written, when the run asks for
    /// them.
    static var evidence: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_SCRIPT_EVIDENCE"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Writes the plot of the level and the five bands and the table of syllables.
    ///
    /// Skipped unless `DOT_SCRIPT_EVIDENCE` names a directory. The plot is drawn
    /// into a bitmap, so no window is ever created.
    @MainActor
    func testEvidencePlotAndCSV() throws {
        guard let directory = Self.evidence else {
            throw XCTSkip("DOT_SCRIPT_EVIDENCE is not set")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.plot().write(to: directory.appendingPathComponent("dictation-script.png"))
        try Self.table().write(
            to: directory.appendingPathComponent("dictation-syllables.csv"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// The syllables of the script as a table.
    static func table() -> String {
        var lines = ["word,syllable,stress,fricative,start,duration,peak"]
        for syllable in DictationScript.syllables {
            let stress = switch syllable.stress {
            case .stressed: "stressed"
            case .weak: "weak"
            case .function: "function"
            }
            lines.append(String(
                format: "%@,%@,%@,%@,%.3f,%.3f,%.3f",
                syllable.word,
                syllable.text,
                stress,
                syllable.fricative ? "fricative" : "voice",
                syllable.start,
                syllable.duration,
                syllable.peak
            ))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A plot of the level and the five bands over one loop, with the axes in
    /// seconds.
    @MainActor
    static func plot() throws -> Data {
        let scale = 2
        let size = CGSize(width: 640, height: 430)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw PlotError.couldNotDraw }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw PlotError.couldNotDraw }
        NSGraphicsContext.current = graphics
        // The context of a bitmap representation is already scaled from points to
        // pixels, so the layout below is written in points. Its origin is the
        // bottom left, as every other drawing in this app's renders is.
        let context = graphics.cgContext
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let left = 52.0
        let right = Double(size.width) - 16
        let width = right - left
        let levelTop = 376.0
        let levelBottom = 244.0
        let bandTop = 178.0
        let bandBottom = 58.0
        let loop = DictationScript.loop

        func x(_ time: Double) -> CGFloat { CGFloat(left + width * time / loop) }
        func levelY(_ value: Double) -> CGFloat {
            CGFloat(levelBottom + (levelTop - levelBottom) * value)
        }
        func bandY(_ value: Double) -> CGFloat {
            CGFloat(bandBottom + (bandTop - bandBottom) * value)
        }

        // The pauses, shaded so the shape of the speech is visible behind the
        // traces.
        for pause in DictationScript.pauses {
            context.setFillColor(NSColor(white: 0.94, alpha: 1).cgColor)
            context.fill(CGRect(
                x: x(pause.start),
                y: CGFloat(bandBottom),
                width: x(pause.start + pause.duration) - x(pause.start),
                height: CGFloat(levelTop - bandBottom)
            ))
        }

        func axis(top: Double, bottom: Double) {
            context.setStrokeColor(NSColor(white: 0.72, alpha: 1).cgColor)
            context.setLineWidth(0.7)
            for value in [0.0, 0.5, 1.0] {
                let y = CGFloat(bottom + (top - bottom) * value)
                context.move(to: CGPoint(x: CGFloat(left), y: y))
                context.addLine(to: CGPoint(x: CGFloat(right), y: y))
                context.strokePath()
                label(
                    String(format: "%.1f", value),
                    at: CGPoint(x: CGFloat(left) - 8, y: y - 5),
                    size: 8,
                    alignRight: true
                )
            }
        }
        axis(top: levelTop, bottom: levelBottom)
        axis(top: bandTop, bottom: bandBottom)
        for second in stride(from: 0.0, through: loop, by: 2.0) {
            let px = x(second)
            context.setStrokeColor(NSColor(white: 0.86, alpha: 1).cgColor)
            context.setLineWidth(0.6)
            context.move(to: CGPoint(x: px, y: CGFloat(bandBottom)))
            context.addLine(to: CGPoint(x: px, y: CGFloat(levelTop)))
            context.strokePath()
            label(String(format: "%.0f s", second), at: CGPoint(x: px - 6, y: CGFloat(bandBottom) - 14), size: 8)
        }

        // The level.
        context.setStrokeColor(NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.55, alpha: 1).cgColor)
        context.setLineWidth(1.1)
        context.beginPath()
        var time = 0.0
        var first = true
        while time <= loop {
            let here = CGPoint(x: x(time), y: levelY(DictationScript.level(at: time)))
            if first {
                context.move(to: here)
                first = false
            } else {
                context.addLine(to: here)
            }
            time += 1 / Waveform.sampleRate
        }
        context.strokePath()

        // The five bands, through the card's own window: the same normalisation
        // and the same sixty hertz smoothing the island's preview applies.
        let colours: [NSColor] = [
            NSColor(calibratedRed: 0.48, green: 0.12, blue: 0.64, alpha: 1),
            NSColor(calibratedRed: 0.76, green: 0.09, blue: 0.36, alpha: 1),
            NSColor(calibratedRed: 0.90, green: 0.42, blue: 0.00, alpha: 1),
            NSColor(calibratedRed: 0.18, green: 0.49, blue: 0.20, alpha: 1),
            NSColor(calibratedRed: 0.01, green: 0.47, blue: 0.74, alpha: 1),
        ]
        var scaleWindow = SpectrumScale()
        var smoothed = AudioSpectrumFrame.zero
        var series: [[Double]] = Array(repeating: [], count: 5)
        var moment = 0.0
        let step = 1 / Waveform.sampleRate
        while moment <= loop {
            let scaled = scaleWindow.normalise(DictationScript.bands(at: moment), dt: step)
            let settle = 1 - exp(-step / 0.014)
            func follow(_ current: Double, _ target: Double) -> Double {
                current + (target - current) * (target > current ? settle : 1 - exp(-step / 0.03))
            }
            smoothed = AudioSpectrumFrame(bands: (
                follow(smoothed.bands.0, scaled.bands.0),
                follow(smoothed.bands.1, scaled.bands.1),
                follow(smoothed.bands.2, scaled.bands.2),
                follow(smoothed.bands.3, scaled.bands.3),
                follow(smoothed.bands.4, scaled.bands.4)
            ))
            for band in 0..<5 {
                series[band].append(smoothed[band])
            }
            moment += step
        }
        for band in 0..<5 {
            context.setStrokeColor(colours[band].cgColor)
            context.setLineWidth(0.9)
            context.beginPath()
            for (index, value) in series[band].enumerated() {
                let here = CGPoint(x: x(Double(index) * step), y: bandY(value))
                if index == 0 {
                    context.move(to: here)
                } else {
                    context.addLine(to: here)
                }
            }
            context.strokePath()
            // A key down the right edge of the panel.
            let keyY = Double(bandTop) - 10 - Double(band) * 12
            context.setFillColor(colours[band].cgColor)
            context.fill(CGRect(x: CGFloat(right) - 74, y: CGFloat(keyY), width: 9, height: 2.4))
            label("band \(band)", at: CGPoint(x: CGFloat(right) - 61, y: CGFloat(keyY) - 4.5), size: 8)
        }

        // The frozen moment the Settings tiles are drawn at.
        context.setStrokeColor(NSColor(calibratedRed: 0.70, green: 0.10, blue: 0.10, alpha: 1).cgColor)
        context.setLineWidth(0.8)
        context.setLineDash(phase: 0, lengths: [3, 3])
        context.move(to: CGPoint(x: x(DictationScript.stillTime), y: CGFloat(bandBottom)))
        context.addLine(to: CGPoint(x: x(DictationScript.stillTime), y: CGFloat(levelTop)))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        label(
            "tile still",
            at: CGPoint(x: x(DictationScript.stillTime) + 4, y: CGFloat(levelTop) - 10),
            size: 8
        )

        label(
            "DictationScript: one loop of the preview",
            at: CGPoint(x: CGFloat(left), y: size.height - 20),
            size: 11,
            bold: true
        )
        label(
            String(
                format: "%d syllables, %d words, %.1f wpm, %.2f s of speech, %.2f s loop",
                DictationScript.syllables.count,
                DictationScript.wordCount,
                Double(DictationScript.wordCount) / DictationScript.speech * 60,
                DictationScript.speech,
                loop
            ),
            at: CGPoint(x: CGFloat(left), y: size.height - 34),
            size: 8
        )
        label("level", at: CGPoint(x: CGFloat(left), y: CGFloat(levelTop) + 6), size: 9)
        label("bands", at: CGPoint(x: CGFloat(left), y: CGFloat(bandTop) + 6), size: 9)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PlotError.couldNotDraw
        }
        return data
    }

    /// Draws one line of text.
    private static func label(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        bold: Bool = false,
        alignRight: Bool = false
    ) {
        let font = bold
            ? NSFont.systemFont(ofSize: size, weight: .semibold)
            : NSFont.systemFont(ofSize: size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.25, alpha: 1),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let box = string.size()
        let origin = alignRight ? CGPoint(x: point.x - box.width, y: point.y) : point
        string.draw(at: origin)
    }

    enum PlotError: Error {
        case couldNotDraw
    }
}
