import Foundation

/// Messages: a send, always confirmed.
///
/// Messages has no draft in its scripting dictionary, so there is no safe write
/// to offer instead: the connector either sends or does nothing. Three rules
/// make that acceptable. The recipient is resolved through Contacts and the
/// handle the model supplies must belong to that person; the confirmation names
/// the person, the handle and the start of the message; and the connector ships
/// off, so reaching a send takes two deliberate choices.
public struct MessagesConnector: Connector {
    public let id: ConnectorID = .messages
    public let displayName = "Messages"
    public let symbol = "message"
    public let detail = "Send a message to someone, after you confirm the number and the text."
    private let bridge: AppleScriptBridge
    private let contacts: any ContactsDirectory

    /// Creates the connector.
    ///
    /// - Parameters:
    ///   - bridge: the script runner for Messages.
    ///   - contacts: the directory used to check the recipient.
    public init(bridge: AppleScriptBridge, contacts: any ContactsDirectory) {
        self.bridge = bridge
        self.contacts = contacts
    }

    public func tools() -> [ConnectorTool] {
        [sendTool]
    }

    private var sendTool: ConnectorTool {
        ConnectorTool(
            name: "messages_send",
            title: "Send a message",
            description: """
            Send an iMessage or SMS. Resolve the person with contacts_find first, \
            then pass the name and the handle it returned. Never guess a handle.
            """,
            risk: .destructive,
            schema: ToolSchema([
                .init(name: "name", description: "The person's name.", field: .string(maxLength: 120)),
                .init(name: "handle", description: "The number or address from contacts_find.", field: .string(maxLength: 120)),
                .init(name: "body", description: "The message.", field: .string(maxLength: 1_000)),
            ]),
            confirmation: { arguments in
                let preview = Self.preview(arguments.string("body") ?? "")
                return """
                Send "\(preview)" to \(arguments.string("name") ?? "") \
                at \(arguments.string("handle") ?? "")?
                """
            }
        )
    }

    public func permission() async -> ConnectorPermission {
        await bridge.permission()
    }

    public func requestAccess() async -> ConnectorPermission {
        await bridge.requestAccess(probe: MessagesScripts.probe(), timeout: .seconds(30))
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        guard call.name == "messages_send" else {
            return .failure("Messages has no tool called '\(call.name)'.")
        }
        let name = call.arguments.string("name") ?? ""
        let handle = call.arguments.string("handle") ?? ""
        let body = call.arguments.string("body") ?? ""

        guard let normalized = Self.normalizedHandle(handle) else {
            return .failure("That is not a phone number or an iMessage address.")
        }
        do {
            let matches = try await contacts.find(name: name, limit: 20)
            guard let person = Self.recipient(named: name, handle: normalized, in: matches) else {
                return .failure("No contact named \(name) has that number. Use contacts_find and try again.")
            }
            let program = MessagesScripts.send(to: handle, body: body)
            switch await bridge.run(program, timeout: call.tool.timeout) {
            case .ok:
                return .ok("Sent to \(person.name).")
            case .failed(let message, _):
                return .failure(bridge.failureText(.failed(message, code: nil)))
            }
        } catch let error as StoreError {
            return .failure(error.message)
        } catch {
            return .failure("Contacts could not be read, so the recipient could not be checked.")
        }
    }

    /// The contact the handle belongs to, when exactly one matches.
    ///
    /// A name that matches more than one person is refused rather than guessed:
    /// "text Sam" with two Sams in the address book must become a question, not
    /// a message to the wrong one.
    static func recipient(named name: String, handle: String, in matches: [ContactMatch]) -> ContactMatch? {
        let named = matches.filter { contact in
            contact.name.localizedCaseInsensitiveContains(name)
        }
        let withHandle = named.filter { contact in
            contact.handles.contains { Self.normalizedHandle($0) == handle }
        }
        guard withHandle.count == 1 else { return nil }
        return withHandle[0]
    }

    /// The comparable form of a phone number or an iMessage address.
    ///
    /// - Parameter text: a handle as Contacts stores it or as the model wrote it.
    /// - Returns: digits with an optional leading `+`, or a lowercased address.
    static func normalizedHandle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return nil }
        if trimmed.contains("@") {
            return MailConnector.isEmailAddress(trimmed) ? trimmed.lowercased() : nil
        }
        let allowed = CharacterSet(charactersIn: "0123456789 -().+")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        var digits = trimmed.filter(\.isNumber)
        if digits.count < 7 || digits.count > 15 { return nil }
        if trimmed.hasPrefix("+") { digits = "+" + digits }
        return digits
    }

    /// The first line of a message, short enough for a confirmation.
    static func preview(_ body: String) -> String {
        let flattened = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > 60 else { return flattened }
        return String(flattened.prefix(57)) + "..."
    }
}
