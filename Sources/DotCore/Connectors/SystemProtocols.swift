import Foundation

/// What a file search asks for.
public struct FileQuery: Sendable, Equatable {
    /// The kinds of file a search can narrow to.
    public enum Kind: String, Sendable, CaseIterable {
        case any
        case folder
        case document
        case image
        case audio
        case video
        case presentation
        case spreadsheet
    }

    /// The words to look for in the name.
    public let text: String
    /// The kind to narrow to.
    public let kind: Kind
    /// Only files changed in this many days, when set.
    public let modifiedWithinDays: Int?
    /// The most results to return.
    public let limit: Int

    /// Creates a query.
    public init(text: String, kind: Kind = .any, modifiedWithinDays: Int? = nil, limit: Int = 10) {
        self.text = text
        self.kind = kind
        self.modifiedWithinDays = modifiedWithinDays
        self.limit = limit
    }
}

/// One file a search found.
public struct FileHit: Sendable, Equatable {
    /// The canonical path.
    public let path: String
    /// The display name.
    public let name: String
    /// When it last changed.
    public let modified: Date?
    /// Its size, when it could be read.
    public let sizeBytes: Int64?
    /// Whether it is a folder.
    public let isFolder: Bool

    /// Creates a hit.
    public init(path: String, name: String, modified: Date?, sizeBytes: Int64?, isFolder: Bool) {
        self.path = path
        self.name = name
        self.modified = modified
        self.sizeBytes = sizeBytes
        self.isFolder = isFolder
    }
}

/// Finds files with Spotlight.
public protocol FileSearching: Sendable {
    /// Runs a query.
    ///
    /// - Parameter query: what to look for.
    /// - Returns: at most ``FileQuery/limit`` hits.
    /// - Throws: ``StoreError`` when the index cannot be queried at all.
    func search(_ query: FileQuery) async throws -> [FileHit]
}

/// The file operations a tool may perform, after the path check.
///
/// ``FileOperating`` never decides whether a path is allowed; that is
/// ``PathSafety``, which runs first. This protocol only performs the operation,
/// which is what lets the connector be tested with a fake that records calls.
public protocol FileOperating: Sendable {
    /// Opens a file or folder with its default application.
    func open(_ url: URL) async throws
    /// Shows a file in Finder.
    func reveal(_ url: URL) async throws
    /// Moves or renames an item, refusing to overwrite.
    func move(_ source: URL, to destination: URL) async throws -> URL
    /// Moves an item to the Trash and returns where it went.
    func trash(_ url: URL) async throws -> URL
    /// Whether an item exists.
    func exists(_ url: URL) async -> Bool
    /// The size of a file, when it can be read.
    func size(of url: URL) async -> Int64?
}

/// Opens applications, URLs and files.
public protocol AppLaunching: Sendable {
    /// Opens an application by name or bundle identifier.
    func openApp(named name: String) async throws
    /// Opens a URL in the default handler.
    func open(_ url: URL) async throws
    /// The applications that are running.
    func runningApplications() async -> [RunningApp]
}

/// One running application.
public struct RunningApp: Sendable, Equatable {
    /// The localized name.
    public let name: String
    /// The bundle identifier, when it has one.
    public let bundleID: String?
    /// Whether it is frontmost.
    public let isActive: Bool

    /// Creates a running application.
    public init(name: String, bundleID: String?, isActive: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.isActive = isActive
    }
}

/// One command's result.
public struct CommandOutcome: Sendable, Equatable {
    /// The exit status.
    public let exitCode: Int32
    /// What it wrote to standard output.
    public let standardOutput: String
    /// What it wrote to standard error.
    public let standardError: String
    /// Whether the deadline killed it.
    public let timedOut: Bool

    /// Creates an outcome.
    public init(exitCode: Int32, standardOutput: String, standardError: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    /// Whether it succeeded.
    public var succeeded: Bool {
        exitCode == 0 && !timedOut
    }
}

/// Runs an executable with argument arrays.
///
/// Arguments only, never a shell string: a shortcut name with a space, a quote
/// or a `;` is one argument here and can never become a second command.
public protocol CommandRunning: Sendable {
    /// Runs an executable.
    ///
    /// - Parameters:
    ///   - executable: the absolute path to the tool.
    ///   - arguments: the argument vector.
    ///   - timeout: how long it may run before it is terminated.
    /// - Returns: what it did.
    func run(_ executable: URL, arguments: [String], timeout: Duration) async -> CommandOutcome
}

/// Reads and runs the person's shortcuts.
public protocol ShortcutRunning: Sendable {
    /// The names in the library.
    func list() async throws -> [String]
    /// Runs one shortcut, optionally with text as its input.
    func run(name: String, input: String?) async throws -> String
}
