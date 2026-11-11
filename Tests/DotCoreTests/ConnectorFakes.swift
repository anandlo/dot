import Foundation
import XCTest

@testable import DotCore

/// A connector whose permission and effects a test controls.
///
/// The registry is the only place a tool call can become a side effect, so the
/// tests that matter most are the ones that prove a refused call never reaches
/// a connector. ``EffectRecorder`` is what makes "never reached" checkable.
final class FakeConnector: Connector, @unchecked Sendable {
    let id: ConnectorID
    let displayName: String
    let symbol = "circle.dashed"
    let detail = "A connector that records what it was asked to do."
    let effects = EffectRecorder()
    private let toolList: [ConnectorTool]
    private let permissionBox: PermissionBox
    private let outcome: ConnectorOutcome

    init(
        id: ConnectorID = "fake",
        tools: [ConnectorTool]? = nil,
        permission: ConnectorPermissionStatus = .granted,
        outcome: ConnectorOutcome = .ok("done")
    ) {
        self.id = id
        self.displayName = id.rawValue
        self.toolList = tools ?? [makeTool()]
        self.permissionBox = PermissionBox(permission)
        self.outcome = outcome
    }

    func setPermission(_ status: ConnectorPermissionStatus) async {
        await permissionBox.set(status)
    }

    func tools() -> [ConnectorTool] {
        toolList
    }

    func permission() async -> ConnectorPermission {
        ConnectorPermission(status: await permissionBox.current(), service: "Fake")
    }

    func requestAccess() async -> ConnectorPermission {
        await permission()
    }

    func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        await effects.record(call.name)
        return outcome
    }
}

/// Records the calls that reached a connector.
actor EffectRecorder {
    private(set) var calls: [String] = []

    func record(_ name: String) {
        calls.append(name)
    }

    var count: Int { calls.count }
}

/// A permission a test can change while the registry holds the connector.
actor PermissionBox {
    private var status: ConnectorPermissionStatus

    init(_ status: ConnectorPermissionStatus) {
        self.status = status
    }

    func set(_ status: ConnectorPermissionStatus) {
        self.status = status
    }

    func current() -> ConnectorPermissionStatus {
        status
    }
}

/// A tool with a schema a test can predict.
func makeTool(
    name: String = "fake.write",
    title: String = "Write",
    risk: ToolRisk = .write,
    schema: ToolSchema = ToolSchema([]),
    timeout: Duration = .seconds(5),
    confirmation: @escaping @Sendable (ValidatedArguments) -> String = { _ in "Do it?" }
) -> ConnectorTool {
    ConnectorTool(
        name: name,
        title: title,
        description: "A tool for a test.",
        risk: risk,
        schema: schema,
        timeout: timeout,
        confirmation: confirmation
    )
}

/// A call as the model would send it.
func makeCall(
    id: String = "call-1",
    name: String = "fake.write",
    arguments: [String: JSONValue] = [:]
) -> ToolCall {
    ToolCall(id: id, name: name, arguments: .object(arguments))
}

/// A registry over one fake connector with a gate the test controls.
func makeRegistry(
    connector: FakeConnector,
    settings: ConnectorSettings = ConnectorSettings(enabled: ["fake"]),
    gate: ConfirmationGate = .denyAll,
    log: ToolCallLog = .silent
) -> ConnectorRegistry {
    ConnectorRegistry(connectors: [connector], settings: settings, gate: gate, log: log)
}

/// A log that keeps records for a test to read.
final class RecordingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ToolCallRecord] = []

    var records: [ToolCallRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// A log that never writes argument values.
    var log: ToolCallLog {
        ToolCallLog(allowsArguments: { false }) { [weak self] record in
            self?.append(record)
        }
    }

    /// A log that writes argument values, as transcript logging does.
    var argumentLog: ToolCallLog {
        ToolCallLog(allowsArguments: { true }) { [weak self] record in
            self?.append(record)
        }
    }

    private func append(_ record: ToolCallRecord) {
        lock.lock()
        stored.append(record)
        lock.unlock()
    }
}

/// A call that went through the tool's real schema, as the registry does it.
func validatedCall(
    _ connector: any Connector,
    name: String,
    arguments: [String: JSONValue] = [:],
    id: String = "call-1"
) throws -> ConnectorCall {
    guard let tool = connector.tool(named: name) else {
        throw StoreError("The connector has no tool called \(name).")
    }
    let checked = try ArgumentValidator.validate(.object(arguments), against: tool.schema)
    return ConnectorCall(id: id, tool: tool, arguments: checked)
}
