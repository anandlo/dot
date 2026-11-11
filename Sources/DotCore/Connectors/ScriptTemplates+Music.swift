import Foundation

/// The playback verbs both music players share.
public enum PlaybackAction: String, Sendable, CaseIterable {
    case play
    case pause
    case toggle
    case next
    case previous

    /// The words a confirmation uses.
    public var label: String {
        switch self {
        case .play: "Play"
        case .pause: "Pause"
        case .toggle: "Play or pause"
        case .next: "Skip to the next track"
        case .previous: "Go back a track"
        }
    }
}

/// The fixed Music scripts.
public enum MusicScripts {
    /// Builds the AppleScript command for a playback verb.
    ///
    /// - Parameter action: the verb.
    /// - Returns: the line of source, from a fixed set.
    static func command(for action: PlaybackAction) -> String {
        switch action {
        case .play: "play"
        case .pause: "pause"
        case .toggle: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
    }

    /// Plays, pauses or skips in Music.
    ///
    /// - Parameter action: the verb.
    /// - Returns: the program.
    public static func playback(_ action: PlaybackAction) -> AppleScriptProgram {
        let source = """
        tell application "Music"
            \(command(for: action))
            return "ok"
        end tell
        """
        return AppleScriptProgram(target: .music, source: source)
    }

    /// Plays a playlist by name from the person's library.
    ///
    /// - Parameter name: the playlist's name.
    /// - Returns: the program, which returns `missing` when there is no such
    ///   playlist.
    public static func playPlaylist(named name: String) -> AppleScriptProgram {
        let source = """
        tell application "Music"
            set playlistName to \(AppleScriptText.literal(name))
            if (count of (every playlist whose name is playlistName)) is 0 then return "missing"
            play (first playlist whose name is playlistName)
            return "playing"
        end tell
        """
        return AppleScriptProgram(target: .music, source: source)
    }

    /// Finds a track by name and plays it.
    ///
    /// - Parameter query: the words in the track's name.
    /// - Returns: the program, which returns `missing` when nothing matches.
    public static func playTrack(matching query: String) -> AppleScriptProgram {
        let source = """
        tell application "Music"
            set queryText to \(AppleScriptText.literal(query))
            set matches to (every track whose name contains queryText)
            if (count of matches) is 0 then return "missing"
            set theTrack to item 1 of matches
            play theTrack
            return (name of theTrack) & " by " & (artist of theTrack)
        end tell
        """
        return AppleScriptProgram(target: .music, source: source)
    }

    /// Reads what Music is playing.
    ///
    /// - Returns: the program, which returns an empty string when stopped.
    public static func currentTrack() -> AppleScriptProgram {
        let source = """
        tell application "Music"
            if player state is stopped then return ""
            return (name of current track) & " by " & (artist of the current track)
        end tell
        """
        return AppleScriptProgram(target: .music, source: source)
    }

    /// A script that only proves Dot may talk to Music.
    ///
    /// - Returns: the program.
    public static func probe() -> AppleScriptProgram {
        AppleScriptProgram(target: .music, source: "tell application \"Music\" to return \"ok\"")
    }
}

/// The fixed Spotify scripts.
///
/// Spotify's dictionary is small: playback verbs, `play track` with a URI, and
/// the current track's properties. It has no search command and no library
/// query, so a playlist or track is played from a URI. Searching the catalogue
/// needs the Web API and an OAuth consent, which is a separate connector that
/// this build does not ship.
public enum SpotifyScripts {
    /// Plays, pauses or skips in Spotify.
    ///
    /// - Parameter action: the verb.
    /// - Returns: the program.
    public static func playback(_ action: PlaybackAction) -> AppleScriptProgram {
        let source = """
        tell application "Spotify"
            \(MusicScripts.command(for: action))
            return "ok"
        end tell
        """
        return AppleScriptProgram(target: .spotify, source: source)
    }

    /// Plays a Spotify URI.
    ///
    /// - Parameter uri: a `spotify:` URI, checked by the connector before this
    ///   is called.
    /// - Returns: the program.
    public static func playURI(_ uri: String) -> AppleScriptProgram {
        let source = """
        tell application "Spotify"
            play track \(AppleScriptText.literal(uri))
            return "playing"
        end tell
        """
        return AppleScriptProgram(target: .spotify, source: source)
    }

    /// Reads what Spotify is playing.
    ///
    /// - Returns: the program, which returns an empty string when stopped.
    public static func currentTrack() -> AppleScriptProgram {
        let source = """
        tell application "Spotify"
            if player state is stopped then return ""
            return (name of current track) & " by " & (artist of the current track)
        end tell
        """
        return AppleScriptProgram(target: .spotify, source: source)
    }

    /// A script that only proves Dot may talk to Spotify.
    ///
    /// - Returns: the program.
    public static func probe() -> AppleScriptProgram {
        AppleScriptProgram(target: .spotify, source: "tell application \"Spotify\" to return \"ok\"")
    }
}
