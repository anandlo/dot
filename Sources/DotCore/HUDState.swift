import CoreGraphics
import Foundation

/// What the HUD is showing.
public enum HUDMode: Equatable, Sendable {
    /// The microphone is running.
    case recording(elapsed: String)
    /// The recording is being transcribed.
    case working
    /// The transcript is on screen.
    case transcript(text: String, delivery: HUDDelivery, elapsed: String)
    /// Something went wrong, or something was said.
    case message(text: String, symbol: String)
    /// Dot is up and waiting for the record shortcut.
    case ready(shortcut: String)
}

/// How the transcript was delivered.
public enum HUDDelivery: Equatable, Sendable {
    /// The transcript is on the clipboard.
    case copied
    /// The transcript was pasted into the application the user was in.
    case pasted
    /// The transcription failed.
    case failed
}

/// The shape of the card in one state.
public struct HUDCardSpec: Equatable, Sendable {
    /// The width of the card, in points.
    public var width: CGFloat
    /// The height of the card, in points.
    public var height: CGFloat

    /// Creates a card.
    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    /// The card as a Core Graphics size.
    public var size: CGSize {
        CGSize(width: width, height: height)
    }
}

/// The measurements of the card, and the timings of its motion.
///
/// The numbers live here, in one place, because the card, the renderer and
/// the tests must agree on them: a card that is 316 points wide in the
/// layout and 300 points wide in the renderer is a card that does not fit
/// its own contents.
public enum HUDState {
    /// The width of the card while it records, in points.
    public static let recordingWidth: CGFloat = 316
    /// The height of the card while it records, in points.
    public static let recordingHeight: CGFloat = 54
    /// The width of the launch card, in points.
    ///
    /// Narrowed with the launch card's mark: the card used to carry a 26 point
    /// tile at the left, and without it 396 left two hundred points of empty
    /// card between the sentence and the buttons.
    public static let readyWidth: CGFloat = 300
    /// The height of the launch card, in points.
    public static let readyHeight: CGFloat = 54
    /// The width of the recording card while it shows a live partial, in points.
    public static let liveWidth: CGFloat = 520
    /// The height of the recording card while it shows a live partial, in points.
    public static let liveHeight: CGFloat = 84
    /// The number of lines of the live partial the card shows.
    public static let liveTextMaxLines = 2
    /// The width of the card once it shows a transcript, in points.
    public static let transcriptWidth: CGFloat = 560
    /// The height of the header row of the transcript card, in points.
    public static let headerHeight: CGFloat = 44
    /// The padding inside the card, on the left and the right, in points.
    public static let padding: CGFloat = 16
    /// The padding inside the card, at the top and the bottom, in points.
    public static let verticalPadding: CGFloat = 13
    /// The corner radius of the card, in points.
    public static let cornerRadius: CGFloat = 17
    /// The height of the scrolling waveform, in points.
    public static let waveformHeight: CGFloat = 26
    /// The gap between the live dot and the label, in points.
    public static let dotGap: CGFloat = 10
    /// The gap between the label and the clock, in points.
    public static let labelGap: CGFloat = 10
    /// The gap between the clock and the waveform, in points.
    public static let clockGap: CGFloat = 14
    /// The diameter of the live dot, in points.
    public static let liveDotDiameter: CGFloat = 8
    /// The radius of the live dot, in points.
    public static let liveDotRadius: CGFloat = 4
    /// The leading of the transcript text, in points.
    public static let transcriptLeading: CGFloat = 20

    /// How long the card takes to arrive, in seconds.
    public static let entryDuration: Double = 0.32
    /// How long the card takes to leave, in seconds.
    public static let exitDuration: Double = 0.18
    /// How long the card takes to open into another shape, in seconds.
    public static let openDuration: Double = 0.34
    /// How much the card overshoots when it opens.
    public static let openBounce: Double = 0.14
    /// How long a cross-fade takes when the motion is reduced, in seconds.
    public static let reducedMotionDuration: Double = 0.15

    /// The card of the recording state.
    public static var recordingCard: HUDCardSpec {
        HUDCardSpec(width: recordingWidth, height: recordingHeight)
    }

    /// The card of the launch state.
    public static var readyCard: HUDCardSpec {
        HUDCardSpec(width: readyWidth, height: readyHeight)
    }

    /// The card of the recording state once a live partial has arrived.
    public static var liveCard: HUDCardSpec {
        HUDCardSpec(width: liveWidth, height: liveHeight)
    }

    /// The card of the transcript state.
    ///
    /// - Parameter bodyHeight: the height of the transcript body.
    public static func transcriptCard(bodyHeight: CGFloat) -> HUDCardSpec {
        HUDCardSpec(width: transcriptWidth, height: headerHeight + bodyHeight)
    }

    /// The card of the message state.
    ///
    /// - Parameter width: the width the message needs.
    public static func messageCard(width: CGFloat) -> HUDCardSpec {
        HUDCardSpec(width: width, height: recordingHeight)
    }
}

/// What the card says about the work it is doing.
///
/// A spinner that never changes says "something is happening"; it does not say
/// what, or how much is left. The transcribing card carries the stage instead:
/// which request of how many is in flight, and whether the audio is the tail of
/// a recording that was already partly transcribed.
public enum HUDProgress {
    /// The line under the transcribing label.
    ///
    /// - Parameters:
    ///   - done: how many requests have been sent, `0` before the first one.
    ///   - total: how many there are in all.
    /// - Returns: `"2 of 3"`, or an empty string when there is nothing to count.
    public static func detail(done: Int, total: Int) -> String {
        guard total > 1 else { return "" }
        return "\(min(max(done, 0), total)) of \(total)"
    }
}

/// How tall the transcript body is, and when it scrolls.
///
/// The card grows with the words and stops growing at a limit: a long
/// recording must not stretch the island down the screen, and it must not be
/// cut off either, so the body scrolls inside the card once it is taller than
/// ``maxBodyHeight``. Both decisions are here, in points, so the layout and the
/// tests agree about the height at which a transcript starts to scroll.
public enum HUDTranscript {
    /// The tallest body the card shows before the text scrolls, in points.
    ///
    /// Seven lines of the transcript and the padding above and below them: with
    /// the header that is a card of 225 points, which stays clear of the bottom
    /// of the panel and of the screen under it.
    public static let maxBodyHeight: CGFloat = 180
    /// The shortest body the card shows, in points.
    public static let minBodyHeight: CGFloat = 20

    /// The height of the body for a text that needs `contentHeight` points.
    ///
    /// - Parameter contentHeight: the height the text needs, with its padding.
    /// - Returns: that height, held between ``minBodyHeight`` and
    ///   ``maxBodyHeight``. A height that is not a number gives the smallest
    ///   body rather than a card that cannot be drawn.
    public static func bodyHeight(contentHeight: CGFloat) -> CGFloat {
        guard !contentHeight.isNaN else { return minBodyHeight }
        return min(max(contentHeight, minBodyHeight), maxBodyHeight)
    }

    /// Whether a text that needs `contentHeight` points scrolls.
    ///
    /// A body that exactly fits does not scroll: the card shows the whole text
    /// and no scroller, so a one-line transcript looks like it always did.
    ///
    /// - Parameter contentHeight: the height the text needs, with its padding.
    /// - Returns: `true` when the body is taller than ``maxBodyHeight``.
    public static func scrolls(contentHeight: CGFloat) -> Bool {
        guard !contentHeight.isNaN else { return false }
        return contentHeight > maxBodyHeight
    }
}

/// The HUD's state machine: what the card shows, and how it gets there.
///
/// The states are the four the design names — recording, transcribing,
/// transcript and message — and every one of them knows the shape of its
/// card and the timing of its transition. The HUD itself only plays the
/// animation; the decisions live here, where they can be tested.
public struct HUDStateMachine: Equatable, Sendable {
    /// The state the card is in.
    public private(set) var mode: HUDMode
    /// The shape the card is heading for.
    public private(set) var card: HUDCardSpec

    /// Creates a state machine in the message state.
    public init() {
        mode = .message(text: "", symbol: "info.circle")
        card = HUDState.messageCard(width: HUDState.recordingWidth)
    }

    /// The card of the recording state.
    public mutating func showRecording(elapsed: String) {
        mode = .recording(elapsed: elapsed)
        card = HUDState.recordingCard
    }

    /// Updates the clock of the recording state.
    ///
    /// - Parameter elapsed: the clock of the recording.
    public mutating func updateRecordingElapsed(_ elapsed: String) {
        if case .recording = mode {
            mode = .recording(elapsed: elapsed)
        }
    }

    /// The card of the transcribing state.
    public mutating func showTranscribing() {
        mode = .working
        card = HUDState.recordingCard
    }

    /// The card of the transcript state.
    ///
    /// - Parameters:
    ///   - text: the transcript.
    ///   - delivery: how the transcript was delivered.
    ///   - elapsed: the clock of the recording.
    ///   - bodyHeight: the height of the transcript body.
    public mutating func showTranscript(
        text: String,
        delivery: HUDDelivery,
        elapsed: String,
        bodyHeight: CGFloat
    ) {
        mode = .transcript(text: text, delivery: delivery, elapsed: elapsed)
        card = HUDState.transcriptCard(bodyHeight: bodyHeight)
    }

    /// The card of the message state.
    ///
    /// - Parameters:
    ///   - text: the message.
    ///   - symbol: the symbol that goes with the message.
    ///   - width: the width the message needs.
    public mutating func showMessage(text: String, symbol: String, width: CGFloat) {
        mode = .message(text: text, symbol: symbol)
        card = HUDState.messageCard(width: width)
    }

    /// The card of the launch state.
    ///
    /// - Parameter shortcut: the label of the record shortcut.
    public mutating func showReady(shortcut: String) {
        mode = .ready(shortcut: shortcut)
        card = HUDState.readyCard
    }

    /// Whether the state is the recording state.
    public var isRecording: Bool {
        if case .recording = mode { return true }
        return false
    }

    /// Whether the state is the transcribing state.
    public var isWorking: Bool {
        if case .working = mode { return true }
        return false
    }

    /// Whether the state shows a transcript.
    public var showsTranscript: Bool {
        if case .transcript = mode { return true }
        return false
    }

    /// Whether the state is the launch state.
    public var isReady: Bool {
        if case .ready = mode { return true }
        return false
    }
}
