import Foundation

/// Whether Dot may use a connector right now.
///
/// The four states are the ones macOS reports, plus the meaning Dot gives them:
/// a connector that needs no permission is ``granted``, so the registry has one
/// rule for what to show the model instead of a special case per connector.
public enum ConnectorPermissionStatus: String, Codable, Sendable, CaseIterable {
    /// macOS has not asked yet. The first tool call, or the Connect button,
    /// triggers the prompt.
    case notDetermined
    /// Dot may use it.
    case granted
    /// The person said no, or a parent process controls it.
    case denied
    /// Policy blocks it: parental controls, a managed Mac, or Screen Time.
    case restricted

    /// Whether the tools may be shown to the model.
    public var allowsTools: Bool {
        self == .granted
    }
}

/// A connector's permission, and how to fix it when it is missing.
///
/// A denied permission is the failure mode a settings page must be able to
/// explain. "Calendar was working, now it is not, click here" is the sentence
/// that saves the support thread, so every connector carries the deep link to
/// the exact System Settings pane and the sentence that says what to do there.
public struct ConnectorPermission: Sendable, Equatable {
    /// What macOS reports.
    public var status: ConnectorPermissionStatus
    /// The privacy service, as System Settings names it, for example "Reminders".
    public var service: String
    /// How to fix it, in one sentence, when the status is not granted.
    public var remedy: String?
    /// The System Settings pane that holds the switch.
    public var settingsURL: URL?

    /// Creates a permission value.
    public init(
        status: ConnectorPermissionStatus,
        service: String,
        remedy: String? = nil,
        settingsURL: URL? = nil
    ) {
        self.status = status
        self.service = service
        self.remedy = remedy
        self.settingsURL = settingsURL
    }

    /// A connector that needs no permission at all.
    ///
    /// - Parameters:
    ///   - service: the privacy service the settings page names.
    ///   - settingsURL: the pane that explains a folder prompt this connector
    ///     can still trigger, when one exists.
    /// - Returns: a granted permission.
    public static func notNeeded(service: String, settingsURL: URL? = nil) -> ConnectorPermission {
        ConnectorPermission(status: .granted, service: service, settingsURL: settingsURL)
    }

    /// Whether the registry may expose the connector's tools.
    public var allowsTools: Bool { status.allowsTools }

    /// The privacy pane anchors System Settings uses.
    ///
    /// They are the documented deep links a Mac app uses to send a person to
    /// the switch they need; each connector names its own service.
    public enum Pane: String, Sendable {
        case reminders = "Privacy_Reminders"
        case calendars = "Privacy_Calendars"
        case contacts = "Privacy_Contacts"
        case automation = "Privacy_Automation"
        case filesAndFolders = "Privacy_FilesAndFolders"

        /// The URL that opens this pane.
        public var url: URL? {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
        }
    }
}

extension ConnectorPermission {
    /// A permission read from EventKit or Contacts, with the pane that fixes a
    /// refusal.
    public static func from(
        granted: Bool,
        denied: Bool,
        service: String,
        pane: Pane
    ) -> ConnectorPermission {
        if granted {
            return ConnectorPermission(status: .granted, service: service, settingsURL: pane.url)
        }
        if denied {
            return ConnectorPermission(
                status: .denied,
                service: service,
                remedy: "Allow Dot in System Settings, Privacy and Security, \(service).",
                settingsURL: pane.url
            )
        }
        return ConnectorPermission(
            status: .notDetermined,
            service: service,
            remedy: "Dot asks the first time you use it.",
            settingsURL: pane.url
        )
    }
}
