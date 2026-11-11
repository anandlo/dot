import CoreGraphics
import Foundation

/// What the HUD is showing.
public enum HUDMode: Equatable, Sendable {
    /// The microphone is running.
    case recording(elapsed: String)
    /// The recording is being transcribed.
    case working
    /// The transcript is on screen.
    ///
    /// - Parameters:
    ///   - text: the words that were transcribed.
    ///   - delivery: how the words were delivered.
    ///   - elapsed: the clock of the recording they came from.
    ///   - destination: the localized name of the application the words were
    ///     aimed at, when it is known. The header names it only when the words
    ///     were pasted.
    case transcript(
        text: String,
        delivery: HUDDelivery,
        elapsed: String,
        destination: String? = nil
    )
    /// Something went wrong, or something was said.
    case message(text: String, symbol: String)
    /// Dot is up and waiting for the record shortcut.
    case ready(shortcut: String)
    /// The microphone is running for a question to the assistant.
    ///
    /// It is the recording card with the live dot replaced by the assistant's
    /// mark; nothing else moves.
    case assistantRecording(elapsed: String)
    /// A question has been sent and no answer has arrived yet.
    case assistantThinking(question: String)
    /// The answer is using one of the connected apps.
    case assistantTool(connectorName: String)
    /// The answer is arriving, or has been delivered.
    case assistantAnswer(text: String, state: AssistantAnswerState)
    /// A connected app is waiting for a yes or a no.
    case assistantConfirm(ConfirmationRequest)
}

/// What became of an answer.
public enum AssistantAnswerState: Equatable, Sendable {
    /// The answer is still arriving.
    case streaming
    /// The answer was pasted into the named application.
    ///
    /// The name is absent when the application could not be named, and the card
    /// then says only that the answer was pasted.
    case pasted(String?)
    /// The answer is on the clipboard.
    case copied
    /// The answer is being read out loud.
    case speaking
    /// The answer was read out loud and the reading has finished.
    case spoken

    /// The header of the card, in the small caps the card uses.
    public var label: String {
        switch self {
        case .streaming, .spoken: return "ANSWER"
        case .copied: return "COPIED"
        case .speaking: return "SPEAKING"
        case .pasted(let app):
            guard let app, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "PASTED"
            }
            return "PASTED INTO \(app.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())"
        }
    }

    /// Whether the label names an application and therefore has to be cut to
    /// the room the header has.
    public var namesApplication: Bool {
        if case .pasted(let app) = self {
            return !(app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
        return false
    }
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
/// One declaration per measurement, because the layout, the renderer and the
/// tests all read them: a card that is 316 points wide in the layout and 300 in
/// the renderer does not fit its own contents.
public enum HUDState {
    /// The width of the card while it records, in points.
    public static let recordingWidth: CGFloat = 316
    /// The height of the card while it records, in points.
    public static let recordingHeight: CGFloat = 54
    /// The width of the launch card, in points.
    ///
    /// Wide enough for the service name, the masked key hint and two buttons. A
    /// wider card leaves the sentence stranded at the left with nothing to say
    /// beside it.
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

    /// The width of an assistant card that carries one line, in points.
    public static let assistantWidth: CGFloat = 520

    /// The card of an assistant state that carries one line: a question
    /// arriving, or a connected app being used.
    public static var assistantCard: HUDCardSpec {
        HUDCardSpec(width: assistantWidth, height: recordingHeight)
    }

    /// The card of the assistant's answer.
    ///
    /// - Parameter bodyHeight: the height of the answer body.
    public static func assistantAnswerCard(bodyHeight: CGFloat) -> HUDCardSpec {
        HUDCardSpec(width: transcriptWidth, height: headerHeight + 1 + bodyHeight)
    }
}

/// The measurements of the confirmation card.
///
/// They are declared here rather than in the view because the card's size is
/// chosen before it is laid out, and the height has to leave three lines of the
/// request on screen: the sentence is the whole of what the person is deciding
/// on, and a request cut to one line asks for a yes or a no without saying what
/// for.
public enum HUDConfirmLayout {
    /// The width of the confirmation card, in points.
    public static let width: CGFloat = 520
    /// The most lines the request is drawn on.
    public static let maximumSummaryLines = 3
    /// The height of one line of the request, in points.
    public static let summaryLineHeight: CGFloat = 18
    /// The height of the connector row, in points.
    public static let headerHeight: CGFloat = 16
    /// The height of the two buttons, in points.
    public static let buttonHeight: CGFloat = 30
    /// The gap between the two buttons, in points.
    public static let buttonGap: CGFloat = 8
    /// The gap between the rows of the card, in points.
    public static let rowGap: CGFloat = 8

    /// The height of the card for a request.
    ///
    /// - Parameter summaryLines: how many lines the request needs.
    /// - Returns: the height of the card, with the request held between one and
    ///   ``maximumSummaryLines`` lines.
    public static func height(summaryLines: Int) -> CGFloat {
        let lines = min(max(summaryLines, 1), maximumSummaryLines)
        return HUDState.verticalPadding * 2
            + headerHeight
            + rowGap
            + CGFloat(lines) * summaryLineHeight
            + rowGap + 4
            + buttonHeight
    }

    /// The width the request text is drawn in.
    public static var summaryWidth: CGFloat {
        width - HUDState.padding * 2
    }
}

/// What the card says about the work it is doing.
///
/// A spinner says only that something is happening. The transcribing card also
/// says which request of how many is in flight, which is the difference between
/// "almost done" and "stuck".
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
/// The card grows with the words up to a limit, past which the body scrolls
/// instead: a long recording may neither stretch the island down the screen nor
/// lose its ending. Both limits are declared here, in points, so the layout and
/// the tests agree about the height at which scrolling starts.
public enum HUDTranscript {
    /// The tallest body the card shows before the text scrolls, in points.
    ///
    /// Seven lines of transcript plus the padding above and below them. With the
    /// header that is a card of 225 points, which stays clear of the bottom of the
    /// panel on the smallest screen Dot runs on.
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
    /// A body that exactly fits does not scroll and draws no scroller.
    ///
    /// - Parameter contentHeight: the height the text needs, with its padding.
    /// - Returns: `true` when the body is taller than ``maxBodyHeight``.
    public static func scrolls(contentHeight: CGFloat) -> Bool {
        guard !contentHeight.isNaN else { return false }
        return contentHeight > maxBodyHeight
    }
}
