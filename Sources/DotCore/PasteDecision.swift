import Foundation

/// An application, as far as the paste guard can tell one apart.
///
/// Both halves of the identity are kept. The process identifier separates two
/// launches of the same app, and the bundle identifier still recognises the app
/// when the process that was frontmost at the press is gone by the time the
/// words are ready.
public struct FrontmostApp: Equatable, Sendable {
    /// The process identifier of the running application, when there is one.
    public var processIdentifier: Int32?
    /// The bundle identifier, e.g. `com.apple.mail`.
    public var bundleIdentifier: String?

    /// Creates a reference to an application.
    ///
    /// - Parameters:
    ///   - processIdentifier: the identifier the system gave the process.
    ///   - bundleIdentifier: the identifier the bundle declares.
    public init(processIdentifier: Int32? = nil, bundleIdentifier: String? = nil) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }

    /// Whether two references name the same running application.
    ///
    /// The same bundle identifier in the same process is the same app. A
    /// relaunch of the same bundle is a new process with new windows, so it is
    /// not the app the words were meant for. When both identifiers are missing
    /// the answer is no: an app nothing is known about cannot be trusted with
    /// the words.
    ///
    /// - Parameter other: the application to compare with.
    public func isSameApplication(as other: FrontmostApp) -> Bool {
        if let mine = bundleIdentifier, let theirs = other.bundleIdentifier {
            guard mine == theirs else { return false }
            guard let myPID = processIdentifier, let theirPID = other.processIdentifier else {
                return true
            }
            return myPID == theirPID
        }
        guard let mine = processIdentifier, let theirs = other.processIdentifier else {
            return false
        }
        return mine == theirs
    }
}

/// What happens to a transcript once it is ready.
///
/// The guard exists because the words are spoken into one application and are
/// pasted into another all the time: a notification steals the focus, a browser
/// opens, the person switches back to check something. A paste at the cursor is
/// a keystroke into whatever is frontmost, so the app the words were meant for
/// has to still be there when they are ready; otherwise the transcript is only
/// copied, and the card says so.
public enum PasteDecision: Equatable, Sendable {
    /// Post the paste keystroke.
    case paste
    /// Keep the transcript on the clipboard and leave the cursor alone.
    case copy(CopyReason)

    /// Why the words were copied instead of pasted.
    public enum CopyReason: String, Equatable, Sendable {
        /// Auto-paste is switched off in the settings.
        case autoPasteOff = "autopaste.off"
        /// Dot may not post synthetic key events.
        case accessibilityMissing = "autopaste.skipped.accessibilityMissing"
        /// Nothing was frontmost when the recording started.
        case noApplicationAtPress = "autopaste.skipped.noTarget"
        /// The application that was frontmost at the press is gone.
        case applicationGone = "autopaste.skipped.appGone"
        /// Dot itself is frontmost, so a paste would land in Dot.
        case dotIsFrontmost = "autopaste.skipped.dotFrontmost"
        /// A different application is frontmost now.
        case applicationChanged = "autopaste.skipped.appChanged"

        /// The line the log records for this reason.
        public var logEvent: String { rawValue }

        /// Whether the reason is worth a warning in the log.
        ///
        /// Switching apps or closing the target is a normal part of a dictation
        /// and is recorded as information; a missing permission is a problem the
        /// person has to act on, so it stays a warning.
        public var isWarning: Bool { self == .accessibilityMissing }
    }

    /// Decides how to deliver a finished transcript.
    ///
    /// The order of the checks is the order of what the person would have to fix:
    /// a switched-off setting first, then a missing permission, then where the
    /// words were supposed to go and where they would go now.
    ///
    /// - Parameters:
    ///   - atPress: the application that was frontmost when the recording
    ///     started, or `nil` when nothing was.
    ///   - atDelivery: the application that is frontmost now, or `nil` when
    ///     there is none.
    ///   - accessibilityGranted: whether Dot may post the paste keystroke.
    ///   - autoPasteEnabled: whether auto-paste is switched on in the settings.
    ///   - ownBundleIdentifier: Dot's own bundle identifier, which is never a
    ///     destination.
    /// - Returns: ``paste`` only when the same application is still frontmost.
    public static func decide(
        atPress: FrontmostApp?,
        atDelivery: FrontmostApp?,
        accessibilityGranted: Bool,
        autoPasteEnabled: Bool,
        ownBundleIdentifier: String
    ) -> PasteDecision {
        guard autoPasteEnabled else { return .copy(.autoPasteOff) }
        guard accessibilityGranted else { return .copy(.accessibilityMissing) }
        guard let atPress else { return .copy(.noApplicationAtPress) }
        guard let atDelivery else { return .copy(.applicationGone) }
        if atDelivery.bundleIdentifier == ownBundleIdentifier { return .copy(.dotIsFrontmost) }
        guard atDelivery.isSameApplication(as: atPress) else { return .copy(.applicationChanged) }
        return .paste
    }
}
