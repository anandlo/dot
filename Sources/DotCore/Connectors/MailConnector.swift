import Foundation

/// Mail: a draft, never a send.
///
/// The tool creates a visible, editable draft and stops. A model cannot press
/// Send, and that is the point: the person reads the message before a human
/// receives it. It is also why the connector has no send tool at all, rather
/// than one that is merely risky.
public struct MailConnector: Connector {
    public let id: ConnectorID = .mail
    public let displayName = "Mail"
    public let symbol = "envelope"
    public let detail = "Write a draft in Mail. Dot never sends it for you."
    private let bridge: AppleScriptBridge

    /// Creates the connector.
    ///
    /// - Parameter bridge: the script runner for Mail.
    public init(bridge: AppleScriptBridge) {
        self.bridge = bridge
    }

    public func tools() -> [ConnectorTool] {
        [draftTool]
    }

    private var draftTool: ConnectorTool {
        ConnectorTool(
            name: "mail_draft",
            title: "Write a draft",
            description: """
            Create a draft email in Mail. Use contacts_find first when the person \
            gave a name rather than an address. The draft is never sent.
            """,
            risk: .write,
            schema: ToolSchema([
                .init(name: "to", description: "The recipient's email address.", field: .string(maxLength: 254)),
                .init(name: "subject", description: "The subject line.", field: .string(maxLength: 200)),
                .init(name: "body", description: "The message body.", field: .string(maxLength: 3_000)),
            ]),
            confirmation: { arguments in
                "Write a draft to \(arguments.string("to") ?? "") with the subject \"\(arguments.string("subject") ?? "")\"?"
            }
        )
    }

    public func permission() async -> ConnectorPermission {
        await bridge.permission()
    }

    public func requestAccess() async -> ConnectorPermission {
        await bridge.requestAccess(probe: MailScripts.probe(), timeout: .seconds(30))
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        guard call.name == "mail_draft" else {
            return .failure("Mail has no tool called '\(call.name)'.")
        }
        let recipient = call.arguments.string("to") ?? ""
        guard Self.isEmailAddress(recipient) else {
            return .failure("That is not an email address. Use contacts_find to look one up.")
        }
        let program = MailScripts.draft(
            to: recipient,
            subject: call.arguments.string("subject") ?? "",
            body: call.arguments.string("body") ?? ""
        )
        switch await bridge.run(program, timeout: call.tool.timeout) {
        case .ok:
            return .ok("Draft created in Mail. Read it and press Send when it is right.")
        case .failed(let message, _):
            return .failure(bridge.failureText(.failed(message, code: nil)))
        }
    }

    /// Whether a string is an address Mail can use.
    ///
    /// Deliberately narrow: one `@`, a local part with no spaces or control
    /// characters, and a domain with a dot. A display-name form such as
    /// `Ada <ada@example.com>` is refused, because it is the shape a header
    /// injection uses.
    static func isEmailAddress(_ text: String) -> Bool {
        guard text.count <= 254, !text.contains(where: \.isWhitespace) else { return false }
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        guard parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        let allowedLocal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-")
        guard parts[0].unicodeScalars.allSatisfy({ allowedLocal.contains($0) }) else { return false }
        let allowedHost = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return parts[1].unicodeScalars.allSatisfy { allowedHost.contains($0) }
    }
}
