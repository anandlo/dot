import DotCore
import Foundation

/// Runs a fixed AppleScript program off the main thread, inside a deadline.
///
/// `NSAppleScript` blocks until the target application answers, and a busy or
/// modal target can take seconds. It is therefore never compiled or run on the
/// main actor and never on the caller's actor: ``BoundedWork`` puts it on a
/// utility queue and resumes the caller when the deadline passes, so a stuck
/// app cannot hold a conversation open.
///
/// A script cannot be cancelled once it is running. When the deadline wins, the
/// caller is told so and the abandoned script is left to finish on its own; it
/// is a fixed, harmless script, and the alternative (killing another app's
/// Apple event thread) is not available.
final class AppleScriptExecutor: ScriptRunning, @unchecked Sendable {
    func run(_ program: AppleScriptProgram, timeout: Duration) async -> ScriptOutcome {
        let outcome = await BoundedWork.run(within: timeout) {
            Self.execute(program)
        }
        switch outcome {
        case .finished(let result):
            return result
        case .timedOut:
            return .failed("The app did not answer in time.", code: nil)
        }
    }

    /// Compiles and runs one program.
    ///
    /// - Parameter program: the fixed source.
    /// - Returns: the result or the failure, with the AppleScript error number
    ///   when there was one.
    private static func execute(_ program: AppleScriptProgram) -> ScriptOutcome {
        guard let script = NSAppleScript(source: program.source) else {
            return .failed("The script could not be compiled.", code: nil)
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "The app refused the script."
            return .failed(shorten(message), code: code)
        }
        return .ok(descriptor.stringValue ?? "")
    }

    /// Keeps an error sentence inside a size a tool result can carry.
    ///
    /// A compiler error can quote the whole script, which includes the text a
    /// person dictated; it is cut before it reaches the model.
    private static func shorten(_ message: String) -> String {
        let flattened = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > 300 else { return flattened }
        return String(flattened.prefix(297)) + "..."
    }
}
