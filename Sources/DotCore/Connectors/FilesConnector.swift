import Foundation

/// Files: search with Spotlight, open, reveal, move, rename and trash.
///
/// Every path a tool here touches goes through ``PathSafety`` first, in the
/// intent that matches the operation, and the connector uses the canonical URL
/// the check returns rather than the string the model supplied. Trash is
/// `FileManager.trashItem`, so "delete" is always recoverable; there is no
/// permanent delete tool.
public struct FilesConnector: Connector {
    public let id: ConnectorID = .files
    public let displayName = "Files"
    public let symbol = "folder"
    public let detail = "Search your files, open them, move them, or put them in the Trash."
    private let safety: PathSafety
    private let searcher: any FileSearching
    private let files: any FileOperating

    /// Creates the connector.
    ///
    /// - Parameters:
    ///   - safety: the path rules. The default confines writes to the home
    ///     folder and refuses system locations.
    ///   - searcher: the Spotlight adapter.
    ///   - files: the file operations.
    public init(
        safety: PathSafety = PathSafety(),
        searcher: any FileSearching,
        files: any FileOperating
    ) {
        self.safety = safety
        self.searcher = searcher
        self.files = files
    }

    public func tools() -> [ConnectorTool] {
        [searchTool, openTool, revealTool, moveTool, renameTool, trashTool]
    }

    private var searchTool: ConnectorTool {
        ConnectorTool(
            name: "files_search",
            title: "Search files",
            description: "Search the home folder by file name, kind and when it changed.",
            risk: .read,
            schema: ToolSchema([
                .init(name: "query", description: "Words in the file name.", field: .string(maxLength: 200)),
                .init(
                    name: "kind",
                    description: "The kind of file.",
                    field: .choice(FileQuery.Kind.allCases.map(\.rawValue)),
                    isRequired: false
                ),
                .init(
                    name: "changedWithinDays",
                    description: "Only files changed in this many days.",
                    field: .integer(1...3_650),
                    isRequired: false
                ),
                .init(
                    name: "limit",
                    description: "The most files to return, 1 to 50.",
                    field: .integer(1...50),
                    isRequired: false
                ),
            ]),
            confirmation: { _ in "Search your files." }
        )
    }

    private var openTool: ConnectorTool {
        ConnectorTool(
            name: "files_open",
            title: "Open a file",
            description: "Open a file or folder with its default application.",
            risk: .external,
            schema: ToolSchema([
                .init(name: "path", description: "The file path.", field: .string(maxLength: 1_024)),
            ]),
            confirmation: { arguments in
                "Open \"\(ResultText.shortPath(arguments.string("path") ?? ""))\"?"
            }
        )
    }

    private var revealTool: ConnectorTool {
        ConnectorTool(
            name: "files_reveal",
            title: "Show in Finder",
            description: "Show a file in a Finder window.",
            risk: .read,
            schema: ToolSchema([
                .init(name: "path", description: "The file path.", field: .string(maxLength: 1_024)),
            ]),
            confirmation: { _ in "Show that file in Finder." }
        )
    }

    private var moveTool: ConnectorTool {
        ConnectorTool(
            name: "files_move",
            title: "Move a file",
            description: "Move a file or folder into another folder inside your home folder.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "path", description: "The item to move.", field: .string(maxLength: 1_024)),
                .init(name: "folder", description: "The folder to move it into.", field: .string(maxLength: 1_024)),
            ]),
            confirmation: { arguments in
                "Move \"\(ResultText.shortPath(arguments.string("path") ?? ""))\" into \"\(ResultText.shortPath(arguments.string("folder") ?? ""))\"?"
            }
        )
    }

    private var renameTool: ConnectorTool {
        ConnectorTool(
            name: "files_rename",
            title: "Rename a file",
            description: "Rename a file or folder where it is.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "path", description: "The item to rename.", field: .string(maxLength: 1_024)),
                .init(name: "name", description: "The new name, without a slash.", field: .string(maxLength: 200)),
            ]),
            confirmation: { arguments in
                "Rename \"\(ResultText.shortPath(arguments.string("path") ?? ""))\" to \"\(arguments.string("name") ?? "")\"?"
            }
        )
    }

    private var trashTool: ConnectorTool {
        ConnectorTool(
            name: "files_trash",
            title: "Move to the Trash",
            description: """
            Move a file or folder to the Trash. It stays recoverable there; Dot \
            never deletes anything permanently.
            """,
            risk: .destructive,
            schema: ToolSchema([
                .init(name: "path", description: "The item to trash.", field: .string(maxLength: 1_024)),
            ]),
            confirmation: { arguments in
                "Move \"\(ResultText.shortPath(arguments.string("path") ?? ""))\" to the Trash?"
            }
        )
    }
}

extension FilesConnector {
    public func permission() async -> ConnectorPermission {
        // No permission of its own, but a write into Desktop, Documents or
        // Downloads still triggers a folder prompt, so the row links to the
        // pane that owns it.
        .notNeeded(
            service: "Files and Folders",
            settingsURL: ConnectorPermission.Pane.filesAndFolders.url
        )
    }

    public func requestAccess() async -> ConnectorPermission {
        await permission()
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        do {
            switch call.name {
            case "files_search": return .ok(try await search(call.arguments))
            case "files_open": return .ok(try await open(call.arguments))
            case "files_reveal": return .ok(try await reveal(call.arguments))
            case "files_move": return .ok(try await move(call.arguments))
            case "files_rename": return .ok(try await rename(call.arguments))
            case "files_trash": return .ok(try await trash(call.arguments))
            default: return .failure("Files has no tool called '\(call.name)'.")
            }
        } catch let failure as PathSafety.Failure {
            return .failure(failure.message)
        } catch let error as StoreError {
            return .failure(error.message)
        } catch {
            return .failure("The file operation failed.")
        }
    }

    private func search(_ arguments: ValidatedArguments) async throws -> String {
        let query = FileQuery(
            text: arguments.string("query") ?? "",
            kind: FileQuery.Kind(rawValue: arguments.string("kind") ?? "any") ?? .any,
            modifiedWithinDays: arguments.int("changedWithinDays"),
            limit: arguments.int("limit") ?? 10
        )
        let found = try await searcher.search(query)
        // Spotlight's index can hold an item the path rules would refuse, and a
        // result is a path the model will ask to open next: the same check runs
        // here so a refused path never reaches the conversation.
        let safe = found.filter { hit in
            (try? safety.check(hit.path, intent: .read)) != nil
        }
        let lines = safe.prefix(query.limit).map { hit in
            ResultText.line([
                ResultText.shortPath(hit.path),
                hit.isFolder ? "folder" : nil,
                hit.modified.map { "changed \(ToolDate.describeDay($0))" },
            ])
        }
        return ResultText.list(heading: "file", items: Array(lines), empty: "No file matched.")
    }

    private func open(_ arguments: ValidatedArguments) async throws -> String {
        let url = try safety.check(arguments.string("path") ?? "", intent: .read)
        guard await files.exists(url) else { throw StoreError("There is no file at that path.") }
        try await files.open(url)
        return "Opened \(ResultText.shortPath(url.path))."
    }

    private func reveal(_ arguments: ValidatedArguments) async throws -> String {
        let url = try safety.check(arguments.string("path") ?? "", intent: .read)
        guard await files.exists(url) else { throw StoreError("There is no file at that path.") }
        try await files.reveal(url)
        return "Showing \(ResultText.shortPath(url.path)) in Finder."
    }

    private func move(_ arguments: ValidatedArguments) async throws -> String {
        let source = try safety.check(arguments.string("path") ?? "", intent: .moveSource)
        let folder = try safety.check(arguments.string("folder") ?? "", intent: .moveDestination)
        guard await files.exists(source) else { throw StoreError("There is no file at that path.") }
        guard await files.exists(folder) else { throw StoreError("There is no folder at that path.") }
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        guard !(await files.exists(destination)) else {
            throw StoreError("A file with that name is already in the folder.")
        }
        let moved = try await files.move(source, to: destination)
        return "Moved to \(ResultText.shortPath(moved.path))."
    }

    private func rename(_ arguments: ValidatedArguments) async throws -> String {
        let source = try safety.check(arguments.string("path") ?? "", intent: .moveSource)
        let name = try validName(arguments.string("name") ?? "")
        let destination = try safety.check(
            source.deletingLastPathComponent().appendingPathComponent(name).path,
            intent: .moveDestination
        )
        guard await files.exists(source) else { throw StoreError("There is no file at that path.") }
        guard !(await files.exists(destination)) else {
            throw StoreError("A file with that name already exists.")
        }
        let moved = try await files.move(source, to: destination)
        return "Renamed to \(moved.lastPathComponent)."
    }

    private func trash(_ arguments: ValidatedArguments) async throws -> String {
        let url = try safety.check(arguments.string("path") ?? "", intent: .trash)
        guard await files.exists(url) else { throw StoreError("There is no file at that path.") }
        let trashed = try await files.trash(url)
        return "Moved \(ResultText.shortPath(url.path)) to the Trash."
            + (trashed.path == url.path ? "" : " It is at \(ResultText.shortPath(trashed.path)).")
    }

    /// A new name that is one path component and nothing else.
    private func validName(_ name: String) throws -> String {
        guard !name.isEmpty, name.count <= 200 else {
            throw StoreError("The new name must be 1 to 200 characters.")
        }
        guard name != ".", name != ".." else { throw StoreError("That is not a file name.") }
        guard !name.contains("/"), !name.contains(":") else {
            throw StoreError("The new name cannot contain a slash or a colon.")
        }
        return name
    }
}
