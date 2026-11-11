import DotCore
import Foundation

/// Runs an executable with an argument array, inside a deadline.
///
/// The process never sees a shell: `executableURL` plus `arguments` is the
/// whole interface, so a shortcut name cannot become a second command no matter
/// what it contains. Output is drained continuously by a readability handler,
/// so a process that writes more than a pipe buffer cannot deadlock, and a
/// deadline sends `SIGTERM` and then `SIGKILL`.
final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
    /// The environment a tool is given: a predictable PATH, no inherited
    /// secrets, and a UTF-8 locale.
    private static var environment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
    }

    func run(_ executable: URL, arguments: [String], timeout: Duration) async -> CommandOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<CommandOutcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.execute(executable, arguments: arguments, timeout: timeout))
            }
        }
    }

    /// Starts the process, waits for the deadline, and collects its output.
    private static func execute(_ executable: URL, arguments: [String], timeout: Duration) -> CommandOutcome {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return CommandOutcome(
                exitCode: -1,
                standardOutput: "",
                standardError: "The tool is not installed.",
                timedOut: false
            )
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let collector = ProcessOutput()
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, isError: false)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, isError: true)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            return CommandOutcome(
                exitCode: -1,
                standardOutput: "",
                standardError: "The tool could not be started.",
                timedOut: false
            )
        }

        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1_000_000_000_000_000_000
        let deadline = Date().addingTimeInterval(max(0.1, seconds))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let hardDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < hardDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let collected = collector.snapshot()
        return CommandOutcome(
            exitCode: timedOut ? -1 : process.terminationStatus,
            standardOutput: collected.output,
            standardError: collected.errors,
            timedOut: timedOut
        )
    }
}

/// Collects a process's output from its readability handlers.
///
/// The handlers run on a queue of the pipe's choosing, so the buffer is behind a
/// lock. Each stream is capped: a tool that prints a gigabyte is a tool whose
/// output cannot be used anyway, and the cap keeps the reader from growing the
/// process.
private final class ProcessOutput: @unchecked Sendable {
    private static let limit = 256 * 1_024
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if isError {
            if errorData.count < Self.limit {
                errorData.append(data.prefix(Self.limit - errorData.count))
            }
        } else if outputData.count < Self.limit {
            outputData.append(data.prefix(Self.limit - outputData.count))
        }
    }

    func snapshot() -> (output: String, errors: String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            String(decoding: outputData, as: UTF8.self),
            String(decoding: errorData, as: UTF8.self)
        )
    }
}
