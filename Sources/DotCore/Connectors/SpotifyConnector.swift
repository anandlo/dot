import Foundation

/// Spotify, through its AppleScript dictionary.
///
/// The dictionary controls playback and plays a URI. It cannot search: that
/// needs the Web API and an OAuth consent, which is a separate connector this
/// build does not ship. The tool says so rather than pretending a name will
/// work, and a URI is checked before a script sees it.
public struct SpotifyConnector: Connector {
    public let id: ConnectorID = .spotify
    public let displayName = "Spotify"
    public let symbol = "music.note.list"
    public let detail = "Play, pause, skip, or play a Spotify link you paste."
    private let bridge: AppleScriptBridge

    /// Creates the connector.
    ///
    /// - Parameter bridge: the script runner for Spotify.
    public init(bridge: AppleScriptBridge) {
        self.bridge = bridge
    }

    public func tools() -> [ConnectorTool] {
        [playbackTool, uriTool, currentTool]
    }

    private var playbackTool: ConnectorTool {
        ConnectorTool(
            name: "spotify_playback",
            title: "Control playback",
            description: "Play, pause, or skip in Spotify.",
            risk: .write,
            schema: ToolSchema([
                .init(
                    name: "action",
                    description: "What to do.",
                    field: .choice(PlaybackAction.allCases.map(\.rawValue))
                ),
            ]),
            confirmation: { arguments in
                let action = PlaybackAction(rawValue: arguments.string("action") ?? "") ?? .toggle
                return "\(action.label) in Spotify?"
            }
        )
    }

    private var uriTool: ConnectorTool {
        ConnectorTool(
            name: "spotify_playURI",
            title: "Play a Spotify link",
            description: """
            Play a Spotify URI, for example spotify:playlist:37i9dQZF1DXcBWIGoYBM5M. \
            Spotify's dictionary cannot search the catalogue, so a name or a link \
            that is not a spotify: URI is refused.
            """,
            risk: .write,
            schema: ToolSchema([
                .init(name: "uri", description: "The spotify: URI.", field: .string(maxLength: 200)),
            ]),
            confirmation: { arguments in
                "Play the Spotify link \(arguments.string("uri") ?? "")?"
            }
        )
    }

    private var currentTool: ConnectorTool {
        ConnectorTool(
            name: "spotify_current",
            title: "What is playing",
            description: "Read the song and artist Spotify is playing.",
            risk: .read,
            schema: ToolSchema([]),
            confirmation: { _ in "Check what Spotify is playing." }
        )
    }

    public func permission() async -> ConnectorPermission {
        await bridge.permission()
    }

    public func requestAccess() async -> ConnectorPermission {
        await bridge.requestAccess(probe: SpotifyScripts.probe(), timeout: .seconds(30))
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        let program: AppleScriptProgram
        switch call.name {
        case "spotify_playback":
            let action = PlaybackAction(rawValue: call.arguments.string("action") ?? "") ?? .toggle
            program = SpotifyScripts.playback(action)
        case "spotify_playURI":
            let text = call.arguments.string("uri") ?? ""
            guard Self.isSpotifyURI(text) else {
                return .failure("That is not a spotify: link.")
            }
            program = SpotifyScripts.playURI(text)
        case "spotify_current":
            program = SpotifyScripts.currentTrack()
        default:
            return .failure("Spotify has no tool called '\(call.name)'.")
        }
        let outcome = await bridge.run(program, timeout: call.tool.timeout)
        switch outcome {
        case .ok(let text) where call.name == "spotify_current":
            return .ok(text.isEmpty ? "Spotify is stopped." : text)
        case .ok:
            return .ok("Done.")
        case .failed:
            return .failure(bridge.failureText(outcome))
        }
    }

    /// Whether a string is a Spotify URI for a kind the app can play.
    ///
    /// The constructor is fixed and the identifier is limited to characters a
    /// URI uses, so the value that reaches the script has no room to be
    /// anything else.
    static func isSpotifyURI(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == text, text.count <= 200 else { return false }
        let kinds = ["track", "album", "playlist", "artist", "episode", "show"]
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify" else { return false }
        guard kinds.contains(String(parts[1])), !parts[2].isEmpty else { return false }
        return parts[2].allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber)
        }
    }
}
