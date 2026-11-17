import DotCore
import Foundation

/// One demonstration voice, advanced the way the card advances a real one.
///
/// The island's preview and the Settings tile are two views of one performance,
/// and they used to be two performances: the island pushed decibels into a real
/// meter at sixty frames a second, while the tile rebuilt a history from the
/// script's levels at thirty and drew it through a spectrum ring of its own. A
/// style therefore moved at two rates and with two spectra, and a grid measured on
/// one of them was not the grid the owner saw in the other.
///
/// This is the one performance. It owns the meter, the spectrum's per-band filter
/// and its stamped ring, and it advances them from the script at a fixed sixtieth
/// of a second however often it is asked, so the state it hands out for a moment
/// is the state the card itself would hold at that moment.
@MainActor
final class VisualizerFeed {
    /// How long one step of the feed is, in seconds.
    nonisolated static let step: Double = 1.0 / 60
    /// The decibels a silent moment of the script is pushed at.
    nonisolated static let quietestDecibels: Double = -58
    /// The decibels the loudest moment of the script is pushed at.
    nonisolated static let loudestDecibels: Double = -8

    /// The meter the feed pushes into.
    ///
    /// It is handed in rather than made here so the island's preview can seed its
    /// own meter with the opening of the script and then go on pushing to the same
    /// one: the preview's first live frame continues the take the feed began.
    let meter: VoiceMeter
    /// The spectrum the feed has measured, filter and ring together.
    private(set) var spectrum: VisualizerSpectrum
    /// The moment the feed has advanced to, in seconds.
    private(set) var time: Double
    /// The level of the demonstration at a moment of its own timeline.
    private let level: (Double) -> Double
    /// The bands of the demonstration at a moment of its own timeline.
    private let bands: (Double) -> AudioSpectrumFrame

    /// Creates a feed standing at a moment, holding silence.
    ///
    /// - Parameters:
    ///   - meter: the meter to push into.
    ///   - spectrum: the bands' filter and ring, which a measurement may build with
    ///     other times than the card ships.
    ///   - start: the moment the feed stands at before it is advanced.
    ///   - level: the demonstration's level, from `0` to `1`.
    ///   - bands: the demonstration's bands, on the recorder's own scale.
    init(
        meter: VoiceMeter = VoiceMeter(),
        spectrum: VisualizerSpectrum = VisualizerSpectrum(),
        from start: Double = 0,
        level: @escaping (Double) -> Double = VisualizerFeed.scriptLevel,
        bands: @escaping (Double) -> AudioSpectrumFrame = VisualizerFeed.scriptBands
    ) {
        self.meter = meter
        self.spectrum = spectrum
        self.time = start
        self.level = level
        self.bands = bands
        meter.setCalibration(nil)
    }

    /// Empties the feed and stands it at a moment.
    ///
    /// - Parameter start: the moment the feed stands at afterwards.
    func reset(from start: Double) {
        meter.reset()
        meter.setCalibration(nil)
        spectrum.reset()
        time = start
    }

    /// Advances the feed to a moment, one sixtieth of a second at a time.
    ///
    /// A moment close to the one the feed stands at is walked to; one that is not,
    /// which is the first frame of a preview or the loop of the script running
    /// round, restarts the feed two seconds earlier so the styles that draw a
    /// history open on a full one.
    ///
    /// - Parameter moment: the moment to advance to, in seconds.
    func advance(to moment: Double) {
        guard moment.isFinite else { return }
        if moment < time || moment - time > 1 {
            reset(from: moment - 2)
        }
        while time + Self.step <= moment {
            time += Self.step
            meter.push(decibels: Self.decibels(for: level(time)), now: time)
            spectrum.advance(target: bands(time), writtenSamples: meter.writtenSamples, dt: Self.step)
        }
    }

    /// The envelope of the demonstration, oldest first, at sixty a second.
    var history: [Double] { meter.orderedHistory }

    /// The spectrum of the demonstration, oldest first, stamped by tick.
    var ring: [AudioSpectrumFrame] { spectrum.ring }

    /// Where inside the newest sample the feed stands, from `0` to `1`.
    var phase: Double { meter.phase }

    /// The decibels a level of the demonstration is pushed at.
    ///
    /// - Parameter level: the level, from `0` to `1`.
    /// - Returns: the decibels to push.
    nonisolated static func decibels(for level: Double) -> Double {
        quietestDecibels + min(1, max(0, level)) * (loudestDecibels - quietestDecibels)
    }

    /// The demonstration's level at a moment, brought back inside its loop.
    nonisolated static func scriptLevel(at moment: Double) -> Double {
        DictationScript.level(at: wrapped(moment))
    }

    /// The demonstration's bands at a moment, brought back inside its loop.
    nonisolated static func scriptBands(at moment: Double) -> AudioSpectrumFrame {
        DictationScript.bands(at: wrapped(moment))
    }

    /// A moment of the demonstration, brought back inside its loop.
    ///
    /// - Parameter moment: the moment, possibly negative or past the loop.
    /// - Returns: the same moment, from `0` up to ``DictationScript/loop``.
    nonisolated static func wrapped(_ moment: Double) -> Double {
        let loop = DictationScript.loop
        guard loop > 0 else { return 0 }
        let wrapped = moment.truncatingRemainder(dividingBy: loop)
        return wrapped < 0 ? wrapped + loop : wrapped
    }
}
