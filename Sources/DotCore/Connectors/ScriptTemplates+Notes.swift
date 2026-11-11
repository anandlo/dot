import Foundation

/// The fixed Notes scripts.
///
/// Every script is a constant except for literals that went through
/// ``AppleScriptText/literal(_:)``. A caller cannot build source by hand,
/// because these functions take text, escape it, and return a program: there is
/// no public way to pass raw source into a Notes call.
public enum NotesScripts {
    /// Creates a note in a folder, making the folder when it is missing.
    ///
    /// - Parameters:
    ///   - title: the note's name.
    ///   - body: the note's text.
    ///   - folder: the folder to put it in.
    /// - Returns: the program.
    public static func create(title: String, body: String, folder: String) -> AppleScriptProgram {
        let source = """
        tell application "Notes"
            set folderName to \(AppleScriptText.literal(folder))
            if not (exists folder folderName) then
                make new folder with properties {name:folderName}
            end if
            make new note at folder folderName with properties {name:\(AppleScriptText.literal(title)), body:\(AppleScriptText.literal(body))}
            return "created"
        end tell
        """
        return AppleScriptProgram(target: .notes, source: source)
    }

    /// Appends text to the first note whose name matches.
    ///
    /// - Parameters:
    ///   - title: the note's name.
    ///   - body: the text to add.
    /// - Returns: the program.
    public static func append(title: String, body: String) -> AppleScriptProgram {
        let source = """
        tell application "Notes"
            set noteName to \(AppleScriptText.literal(title))
            if (count of (every note whose name is noteName)) is 0 then return "missing"
            set theNote to first note whose name is noteName
            set body of theNote to ((body of theNote) & \(AppleScriptText.literal(body)))
            return "appended"
        end tell
        """
        return AppleScriptProgram(target: .notes, source: source)
    }

    /// Lists notes whose name contains a query.
    ///
    /// - Parameters:
    ///   - query: the words to look for.
    ///   - limit: the most titles to return.
    /// - Returns: the program, whose output is one `title | folder` per line.
    public static func search(query: String, limit: Int) -> AppleScriptProgram {
        let source = """
        tell application "Notes"
            set queryText to \(AppleScriptText.literal(query))
            set outText to ""
            set found to 0
            repeat with theNote in (every note whose name contains queryText)
                if found is greater than or equal to \(max(1, limit)) then exit repeat
                set outText to outText & (name of theNote) & " | " & (name of container of theNote) & (ASCII character 10)
                set found to found + 1
            end repeat
            return outText
        end tell
        """
        return AppleScriptProgram(target: .notes, source: source)
    }

    /// A script that only proves Dot may talk to Notes.
    ///
    /// It runs when a person presses Connect, because that is the only way
    /// macOS will show the Automation prompt for an app that has not been used
    /// yet.
    ///
    /// - Returns: the program.
    public static func probe() -> AppleScriptProgram {
        AppleScriptProgram(target: .notes, source: "tell application \"Notes\" to return \"ok\"")
    }
}
