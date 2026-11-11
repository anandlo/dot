import Foundation

/// Builds the argument vector for `/usr/bin/shortcuts`.
///
/// The CLI is called with an array, never through a shell. A shortcut named
/// `Focus; rm -rf ~` is one argument here, and the worst it can do is not exist.
/// The name is also checked before it is used: a leading `-` would be read by
/// the tool as an option rather than a name, which is the one way an argument
/// can change what a process does.
public enum ShortcutCommand {
    /// The tool macOS ships.
    public static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// A shortcut name may not be longer than this.
    public static let maximumNameLength = 200

    /// The arguments that list the library.
    ///
    /// - Parameter folder: one folder, when the caller wants a subset.
    /// - Returns: the argument vector.
    public static func listArguments(folder: String? = nil) -> [String] {
        guard let folder, !folder.isEmpty else { return ["list"] }
        return ["list", "--folder-name", folder]
    }

    /// The arguments that run one shortcut.
    ///
    /// - Parameters:
    ///   - name: the shortcut's name, already checked by ``validName(_:)``.
    ///   - inputPath: a file for the shortcut to read, when there is one.
    /// - Returns: the argument vector.
    public static func runArguments(name: String, inputPath: String? = nil) -> [String] {
        guard let inputPath, !inputPath.isEmpty else { return ["run", name] }
        return ["run", name, "--input-path", inputPath]
    }

    /// Whether a name is safe to pass as an argument.
    ///
    /// The checks are about the process, not the person: a name Dot refuses is
    /// one the CLI could mistake for an option, or one that is not a name at
    /// all.
    ///
    /// - Parameter name: the name from the tool call.
    /// - Returns: whether it may be used.
    public static func validName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == name, !name.isEmpty else { return false }
        guard name.count <= maximumNameLength else { return false }
        guard !name.hasPrefix("-") else { return false }
        return !name.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    /// Reads the output of `shortcuts list`.
    ///
    /// - Parameter output: standard output.
    /// - Returns: the names, trimmed, without blanks, in the order printed.
    public static func parseList(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
