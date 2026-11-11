import Foundation

/// Apple Music, through its AppleScript dictionary.
public struct MusicConnector: Connector {
    public let id: ConnectorID = .music
    public let displayName = "Music"
    public let symbol = "music.note"
    public let detail = "Play, pause, skip, or play a playlist or song from your library."
    private let bridge: AppleScriptBridge

    /// Creates the connector.
    ///
    /// - Parameter bridge: the script runner for Music.
    public init(bridge: AppleScriptBridge) {
        self.bridge = bridge
    }

    public func tools() -> [ConnectorTool] {
        [playbackTool, playlistTool, trackTool, currentTool]
    }

    private var playbackTool: ConnectorTool {
        ConnectorTool(
            name: "music_playback",
            title: "Control playback",
            description: "Play, pause, or skip in Music.",
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
                return "\(action.label) in Music?"
            }
        )
    }

    private var playlistTool: ConnectorTool {
        ConnectorTool(
            name: "music_playPlaylist",
            title: "Play a playlist",
            description: "Play a playlist from the person's Music library by its name.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "name", description: "The playlist's name.", field: .string(maxLength: 200)),
            ]),
            confirmation: { arguments in
                "Play the playlist \"\(arguments.string("name") ?? "")\"?"
            }
        )
    }

    private var trackTool: ConnectorTool {
        ConnectorTool(
            name: "music_playTrack",
            title: "Play a song",
            description: "Find a song in the library by name and play it.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "query", description: "Words in the song's name.", field: .string(maxLength: 200)),
            ]),
            confirmation: { arguments in
                "Play the song matching \"\(arguments.string("query") ?? "")\"?"
            }
        )
    }

    private var currentTool: ConnectorTool {
        ConnectorTool(
            name: "music_current",
            title: "What is playing",
            description: "Read the song and artist Music is playing.",
            risk: .read,
            schema: ToolSchema([]),
            confirmation: { _ in "Check what Music is playing." }
        )
    }

    public func permission() async -> ConnectorPermission {
        await bridge.permission()
    }

    public func requestAccess() async -> ConnectorPermission {
        await bridge.requestAccess(probe: MusicScripts.probe(), timeout: .seconds(30))
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        let program: AppleScriptProgram
        switch call.name {
        case "music_playback":
            let action = PlaybackAction(rawValue: call.arguments.string("action") ?? "") ?? .toggle
            program = MusicScripts.playback(action)
        case "music_playPlaylist":
            program = MusicScripts.playPlaylist(named: call.arguments.string("name") ?? "")
        case "music_playTrack":
            program = MusicScripts.playTrack(matching: call.arguments.string("query") ?? "")
        case "music_current":
            program = MusicScripts.currentTrack()
        default:
            return .failure("Music has no tool called '\(call.name)'.")
        }
        let outcome = await bridge.run(program, timeout: call.tool.timeout)
        switch outcome {
        case .ok("missing"):
            return .failure("Nothing in the library matched that name.")
        case .ok(let text) where call.name == "music_current":
            return .ok(text.isEmpty ? "Music is stopped." : text)
        case .ok(let text) where call.name == "music_playTrack":
            return .ok("Playing \(text).")
        case .ok:
            return .ok("Done.")
        case .failed:
            return .failure(bridge.failureText(outcome))
        }
    }
}
