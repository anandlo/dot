import Foundation

/// Owns the one continuation a tool call waits on, and ends the race once.
///
/// Two tasks compete to finish a call: the connector and the deadline. Both
/// hand their outcome here, and the gate resumes the caller for the first one
/// and refuses the second. Keeping the continuation inside the gate rather than
/// in both tasks means no copy of it outlives the resume, which is the shape a
/// checked continuation is meant to have.
///
/// The losing task is cancelled when the winner finishes, so a deadline sleep
/// does not linger for the rest of a long timeout after a fast call, and a slow
/// connector is asked to stop as soon as the deadline passes.
private final class DeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ConnectorOutcome, Never>?
    private var siblings: [@Sendable () -> Void] = []

    init(_ continuation: CheckedContinuation<ConnectorOutcome, Never>) {
        self.continuation = continuation
    }

    /// Registers a task to cancel when the race ends.
    ///
    /// A task that finishes before it is registered is cancelled immediately,
    /// which happens when a connector answers in the time it takes the second
    /// task to be created.
    func addSibling(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            cancel()
            return
        }
        siblings.append(cancel)
        lock.unlock()
    }

    /// Resumes the caller, or does nothing when the other task already did.
    func resume(with outcome: ConnectorOutcome) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let cancels = siblings
        siblings = []
        lock.unlock()
        continuation.resume(returning: outcome)
        for cancel in cancels {
            cancel()
        }
    }
}

/// The toolbox the assistant session talks to.
///
/// It is the one place where a tool call can become a side effect, and it
/// enforces every rule in one order:
///
/// 1. The connector is switched on and macOS has granted it.
/// 2. The tool's policy is not `never`.
/// 3. The arguments match the tool's schema.
/// 4. If the policy is `ask`, a person confirms in the HUD.
/// 5. The call runs inside its timeout.
/// 6. The answer is cut to the byte budget.
/// 7. One line is written to the log.
///
/// A model never sees a tool that fails step 1 or 2, which keeps the prompt
/// small and makes a call to a disabled connector impossible rather than
/// rejected.
public actor ConnectorRegistry: AssistantToolbox {
    private let connectors: [any Connector]
    private var settings: ConnectorSettings
    private let gate: ConfirmationGate
    private let log: ToolCallLog
    private let budget: ToolResultBudget

    /// Creates a registry.
    ///
    /// - Parameters:
    ///   - connectors: the connectors this build has, in settings order.
    ///   - settings: what the person chose.
    ///   - gate: the app's confirmation, shown in the HUD.
    ///   - log: where tool calls are recorded.
    ///   - budget: the result size limit.
    public init(
        connectors: [any Connector],
        settings: ConnectorSettings = .default,
        gate: ConfirmationGate = .denyAll,
        log: ToolCallLog = .silent,
        budget: ToolResultBudget = ToolResultBudget()
    ) {
        self.connectors = connectors
        self.settings = settings
        self.gate = gate
        self.log = log
        self.budget = budget
    }

    /// Replaces the settings, as the Connectors page does when a switch moves.
    public func update(_ settings: ConnectorSettings) {
        self.settings = settings
    }

    /// The settings in force.
    public func currentSettings() -> ConnectorSettings {
        settings
    }

    /// The tools the model may call this turn.
    ///
    /// Only enabled connectors with a granted permission contribute, and a tool
    /// whose policy is `never` is left out entirely.
    public func specs() async -> [ChatToolSpec] {
        var specs: [ChatToolSpec] = []
        let table = settings.policyTable
        for connector in connectors {
            guard settings.isEnabled(connector.id) else { continue }
            guard await connector.permission().allowsTools else { continue }
            for tool in connector.tools() where table.policy(for: tool) != .never {
                specs.append(tool.spec)
            }
        }
        return specs
    }

    /// Runs one call, or refuses it and says why.
    ///
    /// - Parameter call: the call the model asked for.
    /// - Returns: the answer, always as a value: a refusal is an error result
    ///   the model can read, never a thrown error that ends the turn.
    public func invoke(_ call: ToolCall) async -> ToolResult {
        let clock = ContinuousClock()
        let started = clock.now
        let resolved = await resolve(call.name)
        guard let (connector, tool) = resolved else {
            log.record(
                tool: call.name,
                connector: ConnectorID("unknown"),
                risk: .read,
                decision: .unavailable,
                duration: started.duration(to: clock.now),
                failed: true
            )
            return .failure(call.id, "The tool '\(call.name)' is not available.")
        }

        let arguments: ValidatedArguments
        do {
            arguments = try ArgumentValidator.validate(call.arguments, against: tool.schema)
        } catch let error as ArgumentError {
            log.record(
                tool: tool.name,
                connector: connector.id,
                risk: tool.risk,
                decision: .invalidArguments,
                duration: started.duration(to: clock.now),
                failed: true,
                arguments: call.arguments.objectValue ?? [:]
            )
            return .failure(call.id, error.message)
        } catch {
            return .failure(call.id, "The arguments could not be read.")
        }

        let policy = settings.policyTable.policy(for: tool)
        guard policy != .never else {
            log.record(
                tool: tool.name,
                connector: connector.id,
                risk: tool.risk,
                decision: .blockedByPolicy,
                duration: started.duration(to: clock.now),
                failed: true,
                arguments: arguments.all
            )
            return .failure(call.id, "The tool '\(tool.name)' is turned off in Connectors.")
        }

        var decision = ToolDecision.allowed
        if policy == .ask {
            let request = ConfirmationRequest(
                callID: call.id,
                toolName: tool.name,
                connectorID: connector.id,
                connectorName: connector.displayName,
                risk: tool.risk,
                summary: tool.confirmation(arguments)
            )
            guard await gate.confirm(request) else {
                log.record(
                    tool: tool.name,
                    connector: connector.id,
                    risk: tool.risk,
                    decision: .declined,
                    duration: started.duration(to: clock.now),
                    failed: true,
                    arguments: arguments.all
                )
                return .failure(call.id, "The person did not confirm this action.")
            }
            decision = .confirmed
        }

        let outcome = await run(
            ConnectorCall(id: call.id, tool: tool, arguments: arguments),
            on: connector,
            tool: tool
        )
        let fitted = budget.fit(outcome.text)
        log.record(
            tool: tool.name,
            connector: connector.id,
            risk: tool.risk,
            decision: decision,
            duration: started.duration(to: clock.now),
            failed: outcome.isError,
            arguments: arguments.all
        )
        return ToolResult(callID: call.id, content: fitted.text, isError: outcome.isError)
    }

    /// The permission of every connector, for the settings page.
    public func permissions() async -> [ConnectorID: ConnectorPermission] {
        var result: [ConnectorID: ConnectorPermission] = [:]
        for connector in connectors {
            result[connector.id] = await connector.permission()
        }
        return result
    }

    /// Asks one connector for access, prompting if macOS has not asked yet.
    public func requestAccess(_ id: ConnectorID) async -> ConnectorPermission? {
        guard let connector = connectors.first(where: { $0.id == id }) else { return nil }
        return await connector.requestAccess()
    }

    /// Every connector and its tools, enabled or not, for the settings page.
    public func summaries() async -> [ConnectorSummary] {
        var result: [ConnectorSummary] = []
        let table = settings.policyTable
        for connector in connectors {
            let permission = await connector.permission()
            result.append(ConnectorSummary(
                id: connector.id,
                displayName: connector.displayName,
                symbol: connector.symbol,
                detail: connector.detail,
                isEnabled: settings.isEnabled(connector.id),
                permission: permission,
                tools: connector.tools().map { tool in
                    ConnectorSummary.ToolSummary(
                        name: tool.name,
                        title: tool.title,
                        detail: tool.description,
                        risk: tool.risk,
                        policy: table.policy(for: tool)
                    )
                }
            ))
        }
        return result
    }

    /// The tool behind a call, if the connector may be used right now.
    private func resolve(_ name: String) async -> (any Connector, ConnectorTool)? {
        for connector in connectors {
            guard settings.isEnabled(connector.id) else { continue }
            guard let tool = connector.tool(named: name) else { continue }
            guard settings.policyTable.policy(for: tool) != .never else { return nil }
            guard await connector.permission().allowsTools else { return nil }
            return (connector, tool)
        }
        return nil
    }

    /// Runs the connector inside the tool's deadline.
    ///
    /// The losing side of the race is not awaited. That matters: a task group
    /// waits for every child before it returns, so a connector stuck in a
    /// framework call would hold the turn open even after the deadline. Here
    /// the caller is resumed by whichever side claims the gate first, and the
    /// other side's answer is dropped.
    ///
    /// Connectors also bound their own blocking work, so this is the backstop
    /// rather than the only timeout.
    private func run(
        _ call: ConnectorCall,
        on connector: any Connector,
        tool: ConnectorTool
    ) async -> ConnectorOutcome {
        let deadline = tool.timeout + .seconds(1)
        return await withCheckedContinuation { (continuation: CheckedContinuation<ConnectorOutcome, Never>) in
            let gate = DeadlineGate(continuation)
            let work = Task.detached(priority: .userInitiated) {
                let outcome = await connector.invoke(call)
                gate.resume(with: outcome)
            }
            let timer = Task.detached(priority: .utility) {
                try? await Task.sleep(for: deadline)
                gate.resume(with: .failure("The tool '\(tool.name)' did not answer in time."))
            }
            gate.addSibling { work.cancel() }
            gate.addSibling { timer.cancel() }
        }
    }
}
