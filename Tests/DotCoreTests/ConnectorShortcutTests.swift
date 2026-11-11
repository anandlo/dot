import Foundation
import XCTest

@testable import DotCore

/// How the shortcuts CLI is called.
///
/// The tool is handed an argument array and nothing else, so a shortcut named
/// `Focus; rm -rf ~` is one argument that will not be found, not a second
/// command. The name checks exist because a leading `-` would be read as an
/// option rather than a name.
final class ConnectorShortcutTests: XCTestCase {
    func testTheToolIsTheSystemOne() {
        XCTAssertEqual(ShortcutCommand.executable.path, "/usr/bin/shortcuts")
    }

    func testListArguments() {
        XCTAssertEqual(ShortcutCommand.listArguments(), ["list"])
        XCTAssertEqual(
            ShortcutCommand.listArguments(folder: "Work"),
            ["list", "--folder-name", "Work"]
        )
    }

    func testRunArgumentsWithoutInput() {
        XCTAssertEqual(
            ShortcutCommand.runArguments(name: "Morning routine"),
            ["run", "Morning routine"]
        )
    }

    func testRunArgumentsWithAnInputFile() {
        XCTAssertEqual(
            ShortcutCommand.runArguments(name: "Morning routine", inputPath: "/tmp/dot input.txt"),
            ["run", "Morning routine", "--input-path", "/tmp/dot input.txt"]
        )
    }

    func testANameWithShellCharactersIsStillOneArgument() {
        let name = "Focus; rm -rf ~"
        XCTAssertEqual(ShortcutCommand.runArguments(name: name), ["run", name])
        XCTAssertTrue(ShortcutCommand.validName(name))
    }

    func testAnOptionIsNotAName() {
        XCTAssertFalse(ShortcutCommand.validName("--input-path"))
        XCTAssertFalse(ShortcutCommand.validName("-r"))
    }

    func testAnEmptyOrControlCharacterNameIsRefused() {
        XCTAssertFalse(ShortcutCommand.validName(""))
        XCTAssertFalse(ShortcutCommand.validName("two\nlines"))
        XCTAssertFalse(ShortcutCommand.validName(String(repeating: "a", count: 201)))
    }

    func testListOutputIsRead() {
        let output = "Morning\n\n  Speak Text  \nNew Note with Date\n"
        XCTAssertEqual(
            ShortcutCommand.parseList(output),
            ["Morning", "Speak Text", "New Note with Date"]
        )
    }

    func testTheCLIPassesAnArgumentArray() async throws {
        let commands = FakeCommandRunner(output: "Morning\nEvening\n")
        let cli = ShortcutsCLI(commands: commands)
        let names = try await cli.list()
        XCTAssertEqual(names, ["Morning", "Evening"])
        let calls = await commands.calls
        XCTAssertEqual(calls.first?.executable.path, "/usr/bin/shortcuts")
        XCTAssertEqual(calls.first?.arguments, ["list"])
    }

    func testRunningAShortcutWritesInputToAFileAndRemovesIt() async throws {
        let commands = FakeCommandRunner(output: "done")
        let cli = ShortcutsCLI(commands: commands)
        let output = try await cli.run(name: "Speak Text", input: "hello")
        XCTAssertEqual(output, "done")
        let calls = await commands.calls
        let arguments = try XCTUnwrap(calls.last?.arguments)
        XCTAssertEqual(arguments.first, "run")
        XCTAssertEqual(arguments[1], "Speak Text")
        let index = try XCTUnwrap(arguments.firstIndex(of: "--input-path"))
        let path = arguments[index + 1]
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "The input file must be removed")
    }

    func testAFailedShortcutBecomesAStoreError() async {
        let commands = FakeCommandRunner(output: "", exitCode: 1, errors: "No shortcut found")
        let cli = ShortcutsCLI(commands: commands)
        do {
            _ = try await cli.run(name: "Missing", input: nil)
            XCTFail("A failed shortcut must throw")
        } catch let error as StoreError {
            XCTAssertTrue(error.message.contains("No shortcut found"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

/// A command runner that records its argument vectors.
actor FakeCommandRunner: CommandRunning {
    struct Call {
        let executable: URL
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private let output: String
    private let exitCode: Int32
    private let errors: String

    init(output: String, exitCode: Int32 = 0, errors: String = "") {
        self.output = output
        self.exitCode = exitCode
        self.errors = errors
    }

    func run(_ executable: URL, arguments: [String], timeout: Duration) async -> CommandOutcome {
        calls.append(Call(executable: executable, arguments: arguments))
        return CommandOutcome(
            exitCode: exitCode,
            standardOutput: output,
            standardError: errors,
            timedOut: false
        )
    }
}
