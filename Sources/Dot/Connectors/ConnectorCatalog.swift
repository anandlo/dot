import DotCore
import Foundation

/// Builds the connectors the app ships.
///
/// Nothing here touches a framework. Each connector holds protocols, and each
/// adapter holds a ``LazyResource`` that is empty until the first call, so
/// constructing the catalogue at launch costs no XPC connection, no compiled
/// script and no process. The event store, the contact store, a script and a
/// `shortcuts` process are all created on the call that needs them.
enum ConnectorCatalog {
    /// The connectors, in the order the settings page lists them.
    ///
    /// - Returns: one connector per id in ``ConnectorID/builtIn``.
    static func make() -> [any Connector] {
        let scripts = AppleScriptExecutor()
        let commands = ProcessCommandRunner()
        let shortcuts = ShortcutsCLI(commands: commands)
        let files = FileSystemOperations()
        let safety = PathSafety()
        // One contact store shared by the two connectors that resolve people,
        // so a lookup for a message does not open a second connection.
        let contacts = ContactsStore()

        func bridge(_ service: String) -> AppleScriptBridge {
            AppleScriptBridge(
                runner: scripts,
                automation: AutomationPermission(service: service)
            )
        }

        return [
            RemindersConnector(store: EventKitReminderStore()),
            CalendarConnector(store: EventKitCalendarStore()),
            ContactsConnector(directory: contacts),
            NotesConnector(bridge: bridge("Notes")),
            FilesConnector(safety: safety, searcher: SpotlightFileSearch(), files: files),
            MailConnector(bridge: bridge("Mail")),
            MessagesConnector(bridge: bridge("Messages"), contacts: contacts),
            AppsConnector(launcher: WorkspaceLauncher(), files: files, safety: safety),
            ShortcutsConnector(shortcuts: shortcuts),
            MusicConnector(bridge: bridge("Music")),
            SpotifyConnector(bridge: bridge("Spotify")),
            SystemConnector(bridge: bridge("System Events"), shortcuts: shortcuts),
        ]
    }

    /// The toolbox the assistant session uses.
    ///
    /// - Parameters:
    ///   - settings: what the person chose on the Connectors page.
    ///   - gate: the HUD confirmation.
    ///   - log: where tool calls are recorded.
    /// - Returns: a registry over the built-in connectors.
    static func registry(
        settings: ConnectorSettings,
        gate: ConfirmationGate,
        log: ToolCallLog
    ) -> ConnectorRegistry {
        ConnectorRegistry(
            connectors: make(),
            settings: settings,
            gate: gate,
            log: log
        )
    }
}
