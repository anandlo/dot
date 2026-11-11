import Foundation

/// The fixed system scripts.
///
/// These are the only controls macOS offers without a private framework. Two
/// deliberate absences: there is no brightness script, because the only way to
/// set it is a private framework; and there is no Do Not Disturb script,
/// because there is no public API. Focus is reached through a Shortcut the
/// person already has, which the Shortcuts connector runs.
public enum SystemScripts {
    /// Sets the output volume.
    ///
    /// - Parameter level: 0 to 100, already validated by the tool.
    /// - Returns: the program.
    public static func volume(_ level: Int) -> AppleScriptProgram {
        let clamped = min(100, max(0, level))
        return AppleScriptProgram(target: nil, source: "set volume output volume \(clamped)")
    }

    /// Mutes or unmutes the output.
    ///
    /// - Parameter muted: whether to mute.
    /// - Returns: the program.
    public static func muted(_ muted: Bool) -> AppleScriptProgram {
        AppleScriptProgram(target: nil, source: "set volume output muted \(muted)")
    }

    /// Turns dark appearance on or off.
    ///
    /// - Parameter on: whether dark mode should be on.
    /// - Returns: the program.
    public static func darkMode(_ on: Bool) -> AppleScriptProgram {
        let source = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(on)
                return dark mode as text
            end tell
        end tell
        """
        return AppleScriptProgram(target: .systemEvents, source: source)
    }

    /// Reads the current appearance.
    ///
    /// - Returns: the program, which returns `true` or `false` as text.
    public static func readDarkMode() -> AppleScriptProgram {
        let source = """
        tell application "System Events"
            tell appearance preferences
                return dark mode as text
            end tell
        end tell
        """
        return AppleScriptProgram(target: .systemEvents, source: source)
    }

    /// A script that only proves Dot may talk to System Events.
    ///
    /// - Returns: the program.
    public static func probe() -> AppleScriptProgram {
        AppleScriptProgram(target: .systemEvents, source: "tell application \"System Events\" to return \"ok\"")
    }
}
