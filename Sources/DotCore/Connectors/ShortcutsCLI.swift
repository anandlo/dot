import Foundation

/// The `shortcuts` command line tool.
///
/// A read of the library is the only read a shortcut connector does, and it is
/// what turns a free-text name into one the library actually holds. `run` hands
/// the shortcut its input as a temporary file, created `0600` and removed in the
/// same call.
public final class ShortcutsCLI: ShortcutRunning, @unchecked Sendable {
    private let commands: any CommandRunning

    /// Creates the runner.
    ///
    /// - Parameter commands: the process runner, injected so the argument
    ///   building can be tested without starting a process.
    public init(commands: any CommandRunning) {
        self.commands = commands
    }

    public func list() async throws -> [String] {
        let outcome = await commands.run(
            ShortcutCommand.executable,
            arguments: ShortcutCommand.listArguments(),
            timeout: .seconds(15)
        )
        guard outcome.succeeded else {
            throw StoreError("The shortcut library could not be read.")
        }
        return ShortcutCommand.parseList(outcome.standardOutput)
    }

    public func run(name: String, input: String?) async throws -> String {
        guard ShortcutCommand.validName(name) else {
            throw StoreError("That is not a shortcut name.")
        }
        var temporary: URL?
        defer {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
        }
        var inputPath: String?
        if let input, !input.isEmpty {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dot-shortcut-\(UUID().uuidString).txt")
            do {
                try SecureFile.write(Data(input.utf8), to: url)
            } catch {
                throw StoreError("The shortcut input could not be prepared.")
            }
            temporary = url
            inputPath = url.path
        }
        let outcome = await commands.run(
            ShortcutCommand.executable,
            arguments: ShortcutCommand.runArguments(name: name, inputPath: inputPath),
            timeout: .seconds(60)
        )
        guard outcome.succeeded else {
            if outcome.timedOut {
                throw StoreError("The shortcut did not finish in time.")
            }
            let detail = outcome.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw StoreError(detail.isEmpty ? "The shortcut failed." : String(detail.prefix(300)))
        }
        return outcome.standardOutput
    }
}
