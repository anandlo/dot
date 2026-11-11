import AppKit
import DotCore
import SwiftUI

/// Draws the card as a short film, one frame at a time, without showing it.
///
/// A screen recording is not always possible — a locked screen, a headless
/// builder, a display that would film the rest of the desktop with it — and a
/// re-creation of the card in another toolkit is not the card. This draws the
/// very same `HUDView` the screen draws, into a bitmap, on a fixed 60 Hz clock:
/// no wall clock, no `Date`, no random number, so one binary writes the same
/// three hundred and sixty frames on every run.
///
/// Every value the card reads is the product's own. The presence and content
/// springs are the ones `HUD` presents and re-settles the card with, advanced
/// through the closed-form solution in ``Spring``; the levels are the ones
/// ``VoiceMeter`` keeps and the columns the ones ``Waveform`` shapes; the
/// measurements are ``HUDState``'s and ``HUD``'s. There is no second animation
/// written to look like the first.
///
/// The film is the loop the landing page plays: the card arrives, the recording
/// runs with a live waveform and a clock, the second press ends it, the
/// transcript lands, and the finished card is held until the last frame.
@MainActor
enum DemoRender {
    /// The argument that renders the film and exits.
    static let argument = "--render-demo"

    /// The environment variable that does the same, named without the product
    /// prefix that ``DotMigration/environment(_:in:)`` adds. That reader accepts
    /// the pre-rename spelling of the prefix as well.
    static let environmentKey = "RENDER_DEMO"

    // MARK: - The film

    /// The rate the film is drawn at.
    static let framesPerSecond = 60

    /// The length of the film, in frames: six seconds.
    static let frameCount = 360

    /// The scale every frame is drawn at.
    ///
    /// Two pixels per point, so a frame is sharp on a retina display and the
    /// encoder has something to resample rather than something to upscale.
    static let scale: CGFloat = 2

    /// The canvas the card is placed in, in points.
    ///
    /// The transcript card is the widest shape the island takes, and its shadow
    /// spreads past it: the canvas leaves a wide margin around both, so the card
    /// reads as a card on a ground rather than as a crop of one.
    static let canvas = CGSize(width: 1120, height: 560)

    /// The ground the card is drawn on.
    ///
    /// The page's own dark ground, so the film sits in the hero instead of
    /// floating on a second black that does not match it.
    static let ground = Color(red: 18.0 / 255, green: 16.0 / 255, blue: 13.0 / 255)

    // MARK: - The timeline

    /// When the card has arrived, in seconds.
    ///
    /// The presence spring is at rest here. The constant is what the recording
    /// clock counts from, because the take starts when the card has settled.
    static let arrival = 0.42

    /// When the second press ends the recording, in seconds.
    static let stopPress = 3.1

    /// When the transcript lands, in seconds.
    ///
    /// The app waits on the provider between the two presses; the film's
    /// provider takes a tenth of a second, which is the part of that wait that
    /// belongs to the card rather than to the network.
    static let transcriptLands = 3.2

    /// The sentence the card commits.
    static let sentence = "Send the Q3 numbers to Priya before the standup, and copy me on the reply."

    /// The application the card names as the destination of that sentence.
    static let destination = "Mail"

    /// The actions the card is given.
    ///
    /// The same set `AppDelegate.installHUDActions` hands the island, so every
    /// button the app draws is drawn where the app draws it. The closures are
    /// empty: a render never sends a click.
    static var actions: HUDActions {
        var actions = HUDActions()
        actions.stop = {}
        actions.cancel = {}
        actions.copy = {}
        actions.paste = {}
        actions.history = {}
        actions.settings = {}
        actions.close = {}
        return actions
    }

    /// The directory the render was asked for, if any.
    static func requestedDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> URL? {
        if let index = arguments.firstIndex(of: argument), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let value = DotMigration.environment(Self.environmentKey, in: environment) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return nil
    }

    /// Renders every frame into `directory`.
    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let film = Film()
        for index in 0 ..< frameCount {
            let image = try film.render(index)
            guard let data = image.representation(using: .png, properties: [:]) else {
                throw RenderError.couldNotEncode
            }
            let name = String(format: "frame-%04d.png", index)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    /// The render could not be made.
    enum RenderError: Error {
        case couldNotRender
        case couldNotEncode
    }
}

// MARK: - The film

/// The state the film moves through, one frame at a time.
///
/// The springs are carried between frames rather than evaluated per frame from
/// a formula, because that is what the app does: `HUD` keeps two springs and
/// advances them on every tick, so a retarget keeps the velocity and the motion
/// stays continuous. The film runs the same way, with the frame interval
/// standing in for the display link's.
@MainActor
private final class Film {
    /// How present the card is, on the spring `HUD` presents it with.
    ///
    /// The two springs below are declared inline in `HUD.present` and
    /// `HUD.setMode` and are private there, so their durations are restated
    /// here. `HUD` is where they are defined and where they must move together
    /// with this pair.
    private var presence = DotCore.Spring(value: 0, target: 0, duration: 0.36, bounce: 0.16)

    /// How settled the card's content is, on the spring `HUD.setMode` restarts.
    private var content = DotCore.Spring(value: 0, target: 0, duration: 0.34, bounce: 0.10)

    /// The card's width and height, each on the spring the island opens into a
    /// new shape with.
    private var width: DotCore.Spring
    private var height: DotCore.Spring

    /// The microphone, kept the way `HUD` keeps it: the app's own meter.
    private let meter = VoiceMeter()

    /// The card.
    private let model = HUDModel()

    /// The card the sentence needs.
    private let transcriptCard: CGSize

    /// How long the recording ran when the second press ended it, as the card
    /// writes a clock.
    private let taken: String

    /// The level the card's dot reads.
    ///
    /// It is carried because a recording that ends leaves the dot to fall, which
    /// is what `HUD.tick` does when the card is no longer recording.
    private var level: Double = 0

    /// The bar heights of the visualiser, kept between frames the way `HUD`
    /// keeps them.
    private var bars: [Double] = []

    /// Whether the second press has happened, and whether the words have landed.
    private var didPress = false
    private var didLand = false

    /// Whether the transcript's content is waiting for its card to open.
    ///
    /// The app draws the card at the size it is going to be and lets the window
    /// server animate the frame, so the body is never laid out narrower than the
    /// words. A film has one bitmap per frame and no window server, so the body
    /// follows the card's size here — and a body shorter than a line clips the
    /// text and shows a scroller. The words therefore wait the few frames the
    /// opening takes, which is also what lets the card be the only thing that
    /// moves while it opens.
    private var wordsWaitForShape = false

    init() {
        let recording = HUDState.recordingCard.size
        transcriptCard = HUD.transcriptSize(text: DemoRender.sentence)
        taken = HUDClock.string(for: DemoRender.stopPress - DemoRender.arrival)

        // Both springs and the shape start where the app starts them: a fresh
        // card at rest in the pill's shape, presented at the first frame.
        width = DotCore.Spring(
            value: recording.width,
            target: recording.width,
            duration: HUDState.openDuration,
            bounce: HUDState.openBounce
        )
        height = DotCore.Spring(
            value: recording.height,
            target: recording.height,
            duration: HUDState.openDuration,
            bounce: HUDState.openBounce
        )
        presence.to(target: 1, duration: 0.36, bounce: 0.16)
        content.to(target: 1, duration: 0.34, bounce: 0.10)
    }

    /// Draws one frame of the film.
    ///
    /// - Parameter index: the frame's number; frame zero is the first frame.
    /// - Returns: the frame, at ``DemoRender/scale``.
    func render(_ index: Int) throws -> NSBitmapImageRep {
        let time = Double(index) / Double(DemoRender.framesPerSecond)
        step(to: time)
        return try picture()
    }

    /// Moves the card to `time`, then leaves it there to be drawn.
    private func step(to time: Double) {
        let dt = 1.0 / Double(DemoRender.framesPerSecond)

        // The second press, and the transcript that lands a tenth of a second
        // later: the two state changes the app makes. Each one restarts the
        // content reveal and opens the card into its new shape, exactly as
        // `HUD.setMode` and the view's shape spring do.
        if !didPress, time >= DemoRender.stopPress {
            didPress = true
            settle()
            open(to: CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight))
        }
        if !didLand, time >= DemoRender.transcriptLands {
            didLand = true
            settle()
            open(to: transcriptCard)
            wordsWaitForShape = true
        }

        presence.advance(dt)
        width.advance(dt)
        height.advance(dt)
        if wordsWaitForShape,
           width.value >= transcriptCard.width - 4,
           height.value >= transcriptCard.height - 4 {
            wordsWaitForShape = false
        }
        if !wordsWaitForShape {
            content.advance(dt)
        }

        // The microphone. The app's meter is fed at the display's rate from the
        // recorder's RMS; here it is fed the same way from a voice that is a
        // plausible speech envelope rather than a sine, so the product's
        // attack, release and room floor shape the bars instead of this file.
        if !didPress {
            let decibels = 20 * log10(max(SpeechEnvelope.rms(at: time), 0.00001))
            meter.push(decibels: decibels, now: time)
            level = max(
                meter.envelope,
                LevelScale.level(decibels: decibels, window: LevelScale.fixedWindow)
            )
        } else {
            level = max(0, level - dt * 3)
        }

        var history: [Double] = []
        meter.copyOrderedHistory(into: &history)
        model.isVisible = true
        model.presence = min(max(presence.value, 0), 1)
        model.content = min(max(content.value, 0), 1)
        model.cardSize = CGSize(width: width.value, height: height.value)
        model.visualizer = .stretch
        // A window server is what a glass card samples, and a render has none:
        // `HUDPreview` draws on black for the same reason. Black is a material
        // the app ships, and the one its own documentation stills are drawn in.
        model.material = .black
        model.level = level
        model.ceiling = meter.ceiling
        model.pulse = time.truncatingRemainder(dividingBy: 1.1) / 1.1
        model.shimmer = time.truncatingRemainder(dividingBy: 1.4) / 1.4
        model.time = time
        model.history = history
        model.phase = meter.phase
        model.reveal = didPress ? 0 : min(1, max(0, (time - DemoRender.arrival) / 0.12))
        VisualizerBars.stretch(
            into: &bars,
            history: history,
            spectrum: [],
            reveal: model.reveal
        )
        model.bars = bars
        model.mode = mode(at: time)
    }

    /// Restarts the content reveal, the way a state change does.
    private func settle() {
        content.snap(to: 0)
        content.to(target: 1, duration: 0.34, bounce: 0.10)
    }

    /// Points the card at a new shape on the spring that opens it.
    private func open(to size: CGSize) {
        width.to(target: size.width, duration: HUDState.openDuration, bounce: HUDState.openBounce)
        height.to(target: size.height, duration: HUDState.openDuration, bounce: HUDState.openBounce)
    }

    /// What the card shows at `time`.
    private func mode(at time: Double) -> HUDMode {
        if didLand {
            return .transcript(
                text: DemoRender.sentence,
                delivery: .pasted,
                elapsed: taken,
                destination: DemoRender.destination
            )
        }
        if didPress {
            // One request, so there is no count to show: `HUDProgress.detail`
            // is empty below two, and the app's single pass is below two.
            return .working
        }
        let elapsed = max(0, time - DemoRender.arrival)
        return .recording(elapsed: HUDClock.string(for: elapsed))
    }

    /// Draws the card on its ground, into a bitmap at ``DemoRender/scale``.
    ///
    /// The card is drawn through an offscreen `NSHostingView` for the same
    /// reason `HUDPreview` uses one: the transcript body is an `NSTextView` in a
    /// scroll view, and `ImageRenderer` does not draw the content of one.
    private func picture() throws -> NSBitmapImageRep {
        let padding = HUD.shadowPadding
        let padded = CGSize(
            width: width.value + padding * 2,
            height: height.value + padding * 2
        )
        let canvas = DemoRender.canvas
        let view = ZStack {
            DemoRender.ground
            HUDView(
                model: model,
                showsShadow: true,
                animated: false,
                actions: DemoRender.actions
            )
            .padding(padding)
            .frame(width: padded.width, height: padded.height)
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: canvas)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * DemoRender.scale),
            pixelsHigh: Int(canvas.height * DemoRender.scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw DemoRender.RenderError.couldNotRender
        }
        bitmap.size = canvas
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: canvas), to: bitmap)
        return bitmap
    }
}
