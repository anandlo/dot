import Foundation

/// Contacts, read only.
///
/// The connector resolves a name to the handle or address another tool needs.
/// That resolution is the safety mechanism for Messages: the assistant may not
/// pick a recipient itself, it asks Contacts and the confirmation shows what
/// came back.
public struct ContactsConnector: Connector {
    public let id: ConnectorID = .contacts
    public let displayName = "Contacts"
    public let symbol = "person.crop.circle"
    public let detail = "Look up a person's number or address so another tool can use it."
    private let directory: any ContactsDirectory

    /// Creates the connector.
    ///
    /// - Parameter directory: the Contacts adapter.
    public init(directory: any ContactsDirectory) {
        self.directory = directory
    }

    public func tools() -> [ConnectorTool] {
        [findTool]
    }

    private var findTool: ConnectorTool {
        ConnectorTool(
            name: "contacts_find",
            title: "Find a contact",
            description: """
            Find people by name and return their phone numbers and email addresses. \
            Use this before messaging or emailing somebody, and never guess a handle.
            """,
            risk: .read,
            schema: ToolSchema([
                .init(
                    name: "name",
                    description: "The name to look for, as the person said it.",
                    field: .string(maxLength: 100)
                ),
                .init(
                    name: "limit",
                    description: "The most people to return, 1 to 20.",
                    field: .integer(1...20),
                    isRequired: false
                ),
            ]),
            confirmation: { _ in "Look up a contact." }
        )
    }

    public func permission() async -> ConnectorPermission {
        await directory.permission()
    }

    public func requestAccess() async -> ConnectorPermission {
        await directory.requestAccess()
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        guard call.name == "contacts_find" else {
            return .failure("Contacts has no tool called '\(call.name)'.")
        }
        do {
            let matches = try await directory.find(
                name: call.arguments.string("name") ?? "",
                limit: call.arguments.int("limit") ?? 5
            )
            let lines = matches.map { match in
                ResultText.line([
                    match.name,
                    match.handles.isEmpty ? nil : match.handles.joined(separator: ", "),
                    match.emails.isEmpty ? nil : match.emails.joined(separator: ", "),
                ])
            }
            return .ok(ResultText.list(heading: "contact", items: lines, empty: "No contact matched that name."))
        } catch let error as StoreError {
            return .failure(error.message)
        } catch {
            return .failure("Contacts could not be read.")
        }
    }
}
