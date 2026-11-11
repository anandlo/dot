import Foundation

/// Runs scripts for one connector and keeps its Automation status current.
///
/// Every scripting connector needs the same three things: run a fixed program
/// inside a deadline, fold the result into the permission the settings page
/// shows, and turn a refusal into a sentence a person can act on. Doing it once
/// keeps each connector to its own tools and templates.
public struct AppleScriptBridge: Sendable {
    private let runner: any ScriptRunning
    private let automation: AutomationPermission

    /// Creates a bridge.
    ///
    /// - Parameters:
    ///   - runner: the process that compiles and runs the script.
    ///   - automation: the status tracker for this app.
    public init(runner: any ScriptRunning, automation: AutomationPermission) {
        self.runner = runner
        self.automation = automation
    }

    /// The current permission.
    public func permission() async -> ConnectorPermission {
        await automation.current()
    }

    /// Runs a probe to make macOS show its Automation prompt.
    ///
    /// This is the only way to ask for Automation access: the prompt appears
    /// when an event is sent, not before. It runs only when a person presses
    /// Connect.
    ///
    /// - Parameters:
    ///   - probe: the harmless script to send.
    ///   - timeout: how long to wait.
    /// - Returns: the resulting permission.
    public func requestAccess(probe: AppleScriptProgram, timeout: Duration) async -> ConnectorPermission {
        _ = await run(probe, timeout: timeout)
        return await automation.current()
    }

    /// Runs a program and records what it means for the permission.
    ///
    /// - Parameters:
    ///   - program: the fixed script.
    ///   - timeout: how long to wait.
    /// - Returns: the outcome.
    public func run(_ program: AppleScriptProgram, timeout: Duration) async -> ScriptOutcome {
        let outcome = await runner.run(program, timeout: timeout)
        await automation.observe(outcome)
        return outcome
    }

    /// The sentence a failed script becomes in a tool result.
    ///
    /// - Parameter outcome: the failure.
    /// - Returns: the sentence.
    public func failureText(_ outcome: ScriptOutcome) -> String {
        guard outcome.isPermissionRefusal else { return outcome.text }
        return """
        Dot is not allowed to control this app. Allow it in System Settings, \
        Privacy and Security, Automation.
        """
    }
}
