import AppKit
import Foundation
import DotCore

/// Watches the physical key that starts a recording.
///
/// The Carbon hot key tells Dot that the key went down, but it never says
/// that it came back up. The release is read from the keyboard state of the
/// window server: the state is the only thing that still answers when
/// secure input swallows the events.
///
/// Who cares about the release is a setting. In ``RecordingMode/hold`` it ends
/// the recording. In ``RecordingMode/toggle`` it changes nothing at all, and the
/// watcher is kept for the two things it still owes: the ``onBlocked`` report,
/// and the press that stops a recording whose release never arrived.
///
/// The state is not always readable. An application that launchd started
/// cannot see synthetic key events, and a keyboard that is not the one the
/// window server knows about reports nothing either. When the state stays
/// quiet, the shortcut falls back to *toggling*: the next press stops the
/// recording. Either way the recording always ends, and it never runs away.
///
/// The watcher also notices the case macOS hides: when secure input is on,
/// the hot key never arrives at all. The key still goes down, so Dot can say
/// `HOTKEY BLOCKED` instead of looking dead.
@MainActor
final class KeyWatcher {
    /// How often the keyboard state is read.
    static let pollInterval: TimeInterval = 1.0 / 60.0
    /// How long the key has to be down before Dot gives up on the hot key.
    static let blockedAfter: TimeInterval = 0.45

    /// The key that is watched.
    private var keyCode: CGKeyCode = 0
    private var timer: Timer?
    /// The keyboard state said the key was down during this press.
    private var pressStateSeen = false
    /// The keyboard state is currently down.
    private var wasDown = false
    private var downSince: Date?
    /// The moment the press started; `nil` when there is no press.
    private var pressStartedAt: Date?
    private var lastHotkeyAt: Date = .distantPast
    private var didReportBlocked = false
    /// Whether a press the hot key never announced still counts as one.
    ///
    /// The record key is announced by the Carbon hot key, so a press Dot never
    /// heard is not a press it can act on. The Escape key has no hot key behind
    /// it at all: the keyboard state is the only witness it has.
    private var reportsUnannouncedPresses = false

    /// Called when the key comes up.
    var onRelease: (() -> Void)?
    /// Called when the key is down but the hot key never arrived.
    var onBlocked: (() -> Void)?

    /// Starts watching a key.
    ///
    /// The state of the press is kept: the recording may only start after the
    /// microphone prompt is answered, and by then the key may already be up.
    ///
    /// - Parameters:
    ///   - keyCode: the virtual key code to read from the keyboard state.
    ///   - reportsUnannouncedPresses: whether a down-then-up the hot key never
    ///     announced is reported through ``onRelease``. It is off for the record
    ///     key, whose presses arrive as hot key events, and on for Escape, whose
    ///     only witness is the keyboard state.
    func watch(keyCode: Int, reportsUnannouncedPresses: Bool = false) {
        self.keyCode = CGKeyCode(keyCode)
        self.reportsUnannouncedPresses = reportsUnannouncedPresses
        wasDown = false
        downSince = nil
        didReportBlocked = false
        startPolling()
    }

    /// Stops watching the key.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Told that the hot key arrived.
    func noteHotkeyFired() {
        lastHotkeyAt = Date()
        pressStartedAt = Date()
        pressStateSeen = false
        didReportBlocked = false
        startPolling()
    }

    /// Whether a press is still going on.
    ///
    /// A press that has ended is over, whether the keyboard state said so or
    /// the keyboard state could not be read at all.
    var isPressActive: Bool { pressStartedAt != nil }

    /// Whether the key is physically down right now.
    func isKeyDownNow() -> Bool {
        Self.keyIsDown(keyCode)
    }

    private func startPolling() {
        guard timer == nil else { return }
        // The timer is added to the main run loop, so the tick is already on
        // the main thread: it runs in place instead of allocating a task sixty
        // times a second.
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainThreadTick.run {
                self?.poll()
            }
        }
        timer.tolerance = Self.pollInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let down = Self.keyIsDown(keyCode)
        let now = Date()

        if down {
            pressStateSeen = true
            if !wasDown {
                downSince = now
            }
        } else if wasDown {
            wasDown = false
            downSince = nil
            // The key came up: the press is over. A press counts when the hot
            // key announced it, or when this watcher was told that the keyboard
            // state is its only witness.
            if pressStateSeen, pressStartedAt != nil || reportsUnannouncedPresses {
                pressStateSeen = false
                pressStartedAt = nil
                Log.shared.info("hotkey.released")
                onRelease?()
            }
        }
        wasDown = down

        // The key is down but the hot key never arrived: secure input is
        // swallowing it.
        if down, !didReportBlocked,
           let downSince,
           now.timeIntervalSince(downSince) > Self.blockedAfter,
           now.timeIntervalSince(lastHotkeyAt) > Self.blockedAfter {
            didReportBlocked = true
            onBlocked?()
        }
    }

    /// Whether the key is physically down right now.
    ///
    /// The keyboard state is global: it is the only way to see the release of
    /// a key, because the Carbon hot key never reports one.
    private static func keyIsDown(_ keyCode: CGKeyCode) -> Bool {
        if CGEventSource.keyState(.combinedSessionState, key: keyCode) { return true }
        return CGEventSource.keyState(.hidSystemState, key: keyCode)
    }
}
