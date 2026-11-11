import Foundation

/// One edge of the key that starts a recording.
///
/// The Carbon hot key reports the press. The release never arrives as an event:
/// it is read from the keyboard state, which is why the two edges are separate
/// facts here rather than one gesture.
public enum RecordKeyGesture: Sendable, Equatable {
    /// The key went down.
    case press
    /// The key came back up.
    case release
}

/// What an edge of the record key asks the app to do.
public enum RecordingAction: Sendable, Equatable {
    /// Open the microphone and start a take.
    case start
    /// Close the take and transcribe it.
    case stop
    /// The edge belongs to no recording: leave everything as it is.
    case ignore
}

/// The state a recording is in when the key is answered.
public enum RecordingPhase: Sendable, Equatable {
    /// Nothing is running.
    case idle
    /// The microphone is open.
    case recording
    /// The audio is being transcribed.
    case working
}

/// The transition table of the record key.
///
/// The interaction is one setting and no more: a press while idle starts, a
/// press while recording stops, and a press while the words are being
/// transcribed is ignored because there is nothing left to press for.
///
/// The release is the only row the mode changes. In ``RecordingMode/hold`` the
/// release ends the take, which is the whole gesture. In
/// ``RecordingMode/toggle`` the release is not an instruction at all: the take
/// ends on the next press, and the release is ignored.
///
/// A press while recording stops the take in *both* modes. That is not a
/// convenience: the keyboard state can be unreadable — an app launchd started
/// cannot see key events, and a secure-input field swallows them — and when the
/// release never reaches Dot the next press is the only way out. It is the
/// stated fallback of ``KeyWatcher``, kept here so it is tested rather than
/// remembered.
public enum RecordKeyInteraction {
    /// What one edge of the record key means.
    ///
    /// - Parameters:
    ///   - gesture: whether the key went down or came up.
    ///   - mode: how the person chose to start and end a recording.
    ///   - phase: what the app is doing right now.
    /// - Returns: the action the app takes, if any.
    public static func action(
        for gesture: RecordKeyGesture,
        mode: RecordingMode,
        phase: RecordingPhase
    ) -> RecordingAction {
        switch gesture {
        case .press:
            switch phase {
            case .idle: return .start
            case .recording: return .stop
            case .working: return .ignore
            }
        case .release:
            switch phase {
            case .recording: return mode == .hold ? .stop : .ignore
            case .idle, .working: return .ignore
            }
        }
    }
}
