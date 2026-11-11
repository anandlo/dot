import Foundation

/// The stable name of a connector.
///
/// A struct rather than an enum so an id written by a newer build survives a
/// round trip through an older one: it decodes, it is simply not matched by any
/// connector this build has, and the person's file is not rewritten without it.
public struct ConnectorID: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral, Comparable, CustomStringConvertible {
    /// The id as it is stored.
    public let rawValue: String

    /// Creates an id from its stored form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an id.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an id from a literal.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// The id, for a log line.
    public var description: String { rawValue }

    public static func < (lhs: ConnectorID, rhs: ConnectorID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let reminders: ConnectorID = "reminders"
    public static let calendar: ConnectorID = "calendar"
    public static let contacts: ConnectorID = "contacts"
    public static let notes: ConnectorID = "notes"
    public static let files: ConnectorID = "files"
    public static let apps: ConnectorID = "apps"
    public static let shortcuts: ConnectorID = "shortcuts"
    public static let music: ConnectorID = "music"
    public static let spotify: ConnectorID = "spotify"
    public static let mail: ConnectorID = "mail"
    public static let messages: ConnectorID = "messages"
    public static let system: ConnectorID = "system"

    /// The SF Symbol this connector is drawn with.
    ///
    /// The connectors declare their own symbol, and a card that has only an id
    /// cannot ask them. The table is kept honest by a test that compares it with
    /// the symbols the connectors themselves report, so the two cannot drift.
    public var symbol: String {
        switch rawValue {
        case "reminders": "checklist"
        case "calendar": "calendar"
        case "contacts": "person.crop.circle"
        case "notes": "note.text"
        case "files": "folder"
        case "apps": "app"
        case "shortcuts": "bolt"
        case "music": "music.note"
        case "spotify": "music.note.list"
        case "mail": "envelope"
        case "messages": "message"
        case "system": "gearshape"
        default: "puzzlepiece.extension"
        }
    }

    /// Every connector this build ships, in the order the settings page lists
    /// them.
    public static let builtIn: [ConnectorID] = [
        .reminders, .calendar, .contacts, .notes, .files,
        .mail, .messages, .apps, .shortcuts, .music, .spotify, .system,
    ]
}

/// One tool a connector offers.
///
/// The tool carries its own schema, risk, timeout and confirmation sentence, so
/// the registry never needs a table of special cases. Everything about a call
/// that needs to be true before it runs is declared next to the call itself.
public struct ConnectorTool: Sendable {
    /// The name the model calls, namespaced by connector: `reminders_create`.
    public let name: String
    /// The name the settings page shows: "Create a reminder".
    public let title: String
    /// The sentence the model reads.
    public let description: String
    /// What the call does, which decides its default policy.
    public let risk: ToolRisk
    /// The only arguments it accepts.
    public let schema: ToolSchema
    /// The longest it may run.
    public let timeout: Duration
    /// Builds the sentence the confirmation shows, from validated arguments.
    ///
    /// It runs only after validation, so a summary can never echo an unvalidated
    /// value, and it is written for a person, not for the model.
    public let confirmation: @Sendable (ValidatedArguments) -> String

    /// Creates a tool.
    public init(
        name: String,
        title: String,
        description: String,
        risk: ToolRisk,
        schema: ToolSchema,
        timeout: Duration = .seconds(10),
        confirmation: @escaping @Sendable (ValidatedArguments) -> String
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.risk = risk
        self.schema = schema
        self.timeout = timeout
        self.confirmation = confirmation
    }

    /// The spec the model is shown.
    public var spec: ChatToolSpec {
        ChatToolSpec(name: name, description: description, parameters: schema.json, risk: risk)
    }
}

/// A validated call, handed to a connector.
///
/// The arguments in here passed the tool's schema, and this is the only way a
/// connector is ever invoked. There is no path from raw model JSON to a side
/// effect that skips validation.
public struct ConnectorCall: Sendable {
    /// The id the model gave the call, echoed in the result.
    public let id: String
    /// The tool being run.
    public let tool: ConnectorTool
    /// The checked arguments.
    public let arguments: ValidatedArguments

    /// Creates a call.
    public init(id: String, tool: ConnectorTool, arguments: ValidatedArguments) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
    }

    /// The tool's name.
    public var name: String { tool.name }
}

/// What a connector did.
public struct ConnectorOutcome: Sendable, Equatable {
    /// The text the model reads, already truncated by the registry.
    public var text: String
    /// Whether the call failed.
    public var isError: Bool

    /// Creates an outcome.
    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    /// A successful outcome.
    public static func ok(_ text: String) -> ConnectorOutcome {
        ConnectorOutcome(text: text)
    }

    /// A failed outcome.
    public static func failure(_ text: String) -> ConnectorOutcome {
        ConnectorOutcome(text: text, isError: true)
    }
}

/// A source of tools that share one permission and one settings row.
///
/// A connector owns no framework object at launch. The store behind it is built
/// on first use and released when idle, so a person who never enables
/// Reminders never pays for EventKit and a person who uses it once does not keep
/// it resident for the rest of the day.
public protocol Connector: Sendable {
    /// The stable id.
    var id: ConnectorID { get }
    /// The name the settings page shows.
    var displayName: String { get }
    /// The SF Symbol the settings page and HUD use.
    var symbol: String { get }
    /// The one sentence under the name.
    var detail: String { get }

    /// The tools, in the order the model reads them.
    func tools() -> [ConnectorTool]

    /// The current permission.
    func permission() async -> ConnectorPermission

    /// Asks macOS for access, prompting if it has not been asked yet.
    func requestAccess() async -> ConnectorPermission

    /// Runs a call whose arguments already passed the schema.
    func invoke(_ call: ConnectorCall) async -> ConnectorOutcome
}

extension Connector {
    /// The tool with that name, when this connector offers it.
    public func tool(named name: String) -> ConnectorTool? {
        tools().first { $0.name == name }
    }
}
