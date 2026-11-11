import Foundation

/// The fixed Mail script.
///
/// It creates a visible draft and never sends. Sending stays a person's action:
/// the draft window is the confirmation, and a model cannot press Send.
public enum MailScripts {
    /// Creates an editable draft.
    ///
    /// - Parameters:
    ///   - recipient: a validated email address.
    ///   - subject: the subject line.
    ///   - body: the message body.
    /// - Returns: the program.
    public static func draft(to recipient: String, subject: String, body: String) -> AppleScriptProgram {
        let source = """
        tell application "Mail"
            set theMessage to make new outgoing message with properties {subject:\(AppleScriptText.literal(subject)), content:\(AppleScriptText.literal(body)), visible:true}
            tell theMessage
                make new to recipient at end of to recipients with properties {address:\(AppleScriptText.literal(recipient))}
            end tell
            activate
            return "drafted"
        end tell
        """
        return AppleScriptProgram(target: .mail, source: source)
    }

    /// A script that only proves Dot may talk to Mail.
    ///
    /// - Returns: the program.
    public static func probe() -> AppleScriptProgram {
        AppleScriptProgram(target: .mail, source: "tell application \"Mail\" to return \"ok\"")
    }
}

/// The fixed Messages script.
///
/// Messages has no draft: the dictionary can send, and that is all. The only
/// write Dot offers is therefore a send, it always confirms, and the
/// confirmation names the resolved handle so "text Priya" cannot go to the
/// wrong Priya.
public enum MessagesScripts {
    /// Sends a message to a handle.
    ///
    /// - Parameters:
    ///   - handle: a phone number or an iMessage address, already resolved and
    ///     validated.
    ///   - body: the message.
    /// - Returns: the program.
    public static func send(to handle: String, body: String) -> AppleScriptProgram {
        let source = """
        tell application "Messages"
            set theService to missing value
            try
                set theService to first account whose service type is iMessage
            end try
            if theService is missing value then
                set theService to first account whose service type is SMS
            end if
            set theBuddy to participant \(AppleScriptText.literal(handle)) of theService
            send \(AppleScriptText.literal(body)) to theBuddy
            return "sent"
        end tell
        """
        return AppleScriptProgram(target: .messages, source: source)
    }

    /// Opens the conversation with a handle without sending anything.
    ///
    /// Messages cannot be scripted to open a chat window by handle, so this
    /// brings Messages forward and leaves the person to pick the thread. It is
    /// the honest version of "compose": nothing is sent and nothing is typed.
    ///
    /// - Returns: the program.
    public static func open() -> AppleScriptProgram {
        AppleScriptProgram(target: .messages, source: "tell application \"Messages\" to activate")
    }

    /// A script that only proves Dot may talk to Messages.
    ///
    /// - Returns: the program.
    public static func probe() -> AppleScriptProgram {
        AppleScriptProgram(target: .messages, source: "tell application \"Messages\" to return \"ok\"")
    }
}
