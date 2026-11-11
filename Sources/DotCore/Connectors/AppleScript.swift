import Foundation

/// An application a fixed script may talk to.
///
/// The name is a constant from this list, never a string the model supplied, so
/// the `tell application` line of every script is fixed source.
public enum ScriptTarget: String, Sendable, CaseIterable {
    case notes = "Notes"
    case mail = "Mail"
    case messages = "Messages"
    case music = "Music"
    case spotify = "Spotify"
    case systemEvents = "System Events"
}

/// A script to run: a fixed template and the app it talks to.
public struct AppleScriptProgram: Sendable, Equatable {
    /// The target application, when the script names one.
    public let target: ScriptTarget?
    /// The complete source, already safe: model text reached it only through
    /// ``AppleScriptText/literal(_:)``.
    public let source: String

    /// Creates a program.
    public init(target: ScriptTarget?, source: String) {
        self.target = target
        self.source = source
    }
}

/// What a script did.
public enum ScriptOutcome: Sendable, Equatable {
    /// It ran, and this is what it returned.
    case ok(String)
    /// It failed. The code is the AppleScript error number when there was one.
    case failed(String, code: Int?)

    /// The text to show, either way.
    public var text: String {
        switch self {
        case .ok(let text): text
        case .failed(let message, _): message
        }
    }

    /// Whether the failure was a refused Automation permission.
    ///
    /// `-1743` is "not authorized to send Apple events" and `-1744` is the
    /// older "the user has not consented"; both mean the person said no, which
    /// the settings page should say out loud rather than blame the script.
    public var isPermissionRefusal: Bool {
        if case .failed(_, let code) = self {
            return code == -1743 || code == -1744
        }
        return false
    }
}

/// Runs one fixed script.
///
/// The real implementation compiles on the calling queue, inside a bounded
/// wait, and never on the main actor: `NSAppleScript` blocks while the target
/// app answers, and a target that is busy can take seconds.
public protocol ScriptRunning: Sendable {
    /// Runs a program.
    ///
    /// - Parameters:
    ///   - program: the source and its target.
    ///   - timeout: how long to wait before giving up.
    /// - Returns: the result, or the reason it failed.
    func run(_ program: AppleScriptProgram, timeout: Duration) async -> ScriptOutcome
}

/// Tracks an Automation permission from what actually happened.
///
/// macOS has no API that reports "may Dot drive Notes" without either prompting
/// or sending an event, so the status is learned: it starts undetermined, a
/// successful script makes it granted, and a refusal makes it denied. That is
/// enough for the settings page to explain a connector that used to work.
public actor AutomationPermission {
    private let service: String
    private var status: ConnectorPermissionStatus = .notDetermined

    /// Creates a tracker.
    ///
    /// - Parameter service: the app the scripts talk to, for the settings text.
    public init(service: String) {
        self.service = service
    }

    /// The current permission.
    public func current() -> ConnectorPermission {
        ConnectorPermission(
            status: status,
            service: service,
            remedy: remedy,
            settingsURL: ConnectorPermission.Pane.automation.url
        )
    }

    /// Folds one script result into the status.
    public func observe(_ outcome: ScriptOutcome) {
        switch outcome {
        case .ok:
            status = .granted
        case .failed where outcome.isPermissionRefusal:
            status = .denied
        case .failed:
            break
        }
    }

    /// Records that the person refused a prompt.
    public func markDenied() {
        status = .denied
    }

    /// The sentence that says what to do about the current status.
    private var remedy: String? {
        switch status {
        case .granted:
            nil
        case .notDetermined:
            "Press Connect to let Dot control \(service)."
        case .denied:
            "Allow Dot to control \(service) in System Settings, Privacy and Security, Automation."
        case .restricted:
            "Automation is controlled by a profile on this Mac."
        }
    }
}
