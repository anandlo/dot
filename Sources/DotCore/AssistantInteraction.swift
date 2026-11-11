import Foundation

/// Which key was pressed while the assistant was in some state.
public enum AssistantKey: Sendable, Equatable {
    /// The shortcut that starts, sends and stops a question.
    case assistant
    /// The key that backs out of whatever is on screen.
    case escape
    /// The shortcut that starts a dictation.
    case dictation
}

/// What the assistant is doing right now.
///
/// It is not ``RecordingPhase``: the assistant has three states after the audio
/// has been transcribed, and the card says something different in each. A
/// dictation take never reaches this table.
public enum AssistantPhase: Sendable, Equatable {
    /// Nothing is running, so the assistant key starts a question.
    case idle
    /// The microphone is open for a question.
    case recording
    /// A request has been sent and no text has arrived yet.
    case thinking
    /// The answer is arriving.
    case streaming
    /// A connected app is being used.
    case tool
    /// The answer is being read out loud.
    case speaking
    /// A connected app is waiting for a yes or a no.
    case confirming
}

/// What an edge of a key asks the app to do about the assistant.
public enum AssistantAction: Sendable, Equatable {
    /// Open the microphone and start a question.
    case startCapture
    /// Close the question and send it.
    case stopCapture
    /// Throw the recording away without sending it.
    case cancelCapture
    /// Stop the turn and drop the answer.
    case cancelTurn
    /// Silence the voice, keeping the turn.
    case stopSpeech
    /// Refuse the connected app's request.
    case decline
    /// The assistant has nothing to do about this key, so whatever the key
    /// meant before it still stands.
    case ignore
}

/// The transition table of the assistant's keys.
///
/// It is pure and it is the whole interaction: a press of the assistant
/// shortcut starts a question, the next press sends it, and a press while the
/// answer is arriving stops it. The same key therefore means stop in three
/// states, which is why the table is written down rather than spread over the
/// app's event handlers.
///
/// Escape backs out of one thing at a time: it throws away a question that has
/// not been sent, stops a turn that is running, silences an answer that is
/// being read, and refuses a connected app's request. There is no state where
/// it approves anything.
///
/// The dictation shortcut is answered here only because it must not start a
/// recording on top of an assistant turn: while a turn is active it is ignored.
/// In ``AssistantPhase/idle`` the row returns ``AssistantAction/ignore`` as
/// well, because the assistant is not the thing that answers it.
public enum AssistantInteraction {
    /// What one key means in one phase.
    ///
    /// - Parameters:
    ///   - key: the key that was pressed.
    ///   - phase: what the assistant is doing.
    /// - Returns: the action the app takes.
    public static func action(for key: AssistantKey, phase: AssistantPhase) -> AssistantAction {
        switch key {
        case .assistant:
            switch phase {
            case .idle: return .startCapture
            case .recording: return .stopCapture
            case .thinking, .streaming, .tool: return .cancelTurn
            case .speaking: return .stopSpeech
            case .confirming: return .ignore
            }
        case .escape:
            switch phase {
            case .recording: return .cancelCapture
            case .thinking, .streaming, .tool: return .cancelTurn
            case .speaking: return .stopSpeech
            case .confirming: return .decline
            case .idle: return .ignore
            }
        case .dictation:
            return .ignore
        }
    }
}
