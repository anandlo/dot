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

    /// Called when the key comes up.
    var onRelease: (() -> Void)?
    /// Called when the key is down but the hot key never arrived.
    var onBlocked: (() -> Void)?

    /// Starts watching a key.
    ///
    /// The state of the press is kept: the recording may only start after the
    /// microphone prompt is answered, and by then the key may already be up.
    func watch(keyCode: Int) {
        self.keyCode = CGKeyCode(keyCode)
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
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
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
            // The key came up: the press is over.
            if pressStateSeen, pressStartedAt != nil {
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
