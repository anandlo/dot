import Foundation

/// One tool call, as the log records it.
///
/// The record deliberately holds no argument values. A tool argument can be a
/// name, an address, a message body or a file path, and the log file is written
/// by default. Values are added only when transcript logging is on, which is the
/// same switch that already allows a transcript to be written to disk.
public struct ToolCallRecord: Sendable, Equatable {
    /// The tool's name.
    public let tool: String
    /// The connector it belongs to.
    public let connector: ConnectorID
    /// What it declared it does.
    public let risk: ToolRisk
    /// What actually happened.
    public let decision: ToolDecision
    /// How long the call took, from validation to result.
    public let duration: Duration
    /// Whether the result was an error.
    public let failed: Bool
    /// The argument values, only when transcript logging is enabled.
    public let arguments: String?

    /// Creates a record.
    public init(
        tool: String,
        connector: ConnectorID,
        risk: ToolRisk,
        decision: ToolDecision,
        duration: Duration,
        failed: Bool,
        arguments: String? = nil
    ) {
        self.tool = tool
        self.connector = connector
        self.risk = risk
        self.decision = decision
        self.duration = duration
        self.failed = failed
        self.arguments = arguments
    }
}

/// Writes tool calls to Dot's log.
///
/// A struct with two closures so a test can collect records instead of writing
/// the person's log file, and so the app can decide at call time whether
/// argument values may be written, matching ``DotConfig/logTranscripts``.
public struct ToolCallLog: Sendable {
    /// Whether argument values may be written.
    private let allowsArguments: @Sendable () -> Bool
    /// Where a record goes.
    private let sink: @Sendable (ToolCallRecord) -> Void

    /// Creates a log.
    ///
    /// - Parameters:
    ///   - allowsArguments: reads the current transcript setting. It is a
    ///     closure because the setting can change while Dot runs.
    ///   - sink: receives each record.
    public init(
        allowsArguments: @escaping @Sendable () -> Bool,
        sink: @escaping @Sendable (ToolCallRecord) -> Void
    ) {
        self.allowsArguments = allowsArguments
        self.sink = sink
    }

    /// The log Dot writes: JSON lines through ``Log``, values only when the
    /// transcript setting is on.
    public static func shared(allowsArguments: @escaping @Sendable () -> Bool) -> ToolCallLog {
        ToolCallLog(allowsArguments: allowsArguments) { record in
            var fields: [String: LogValue] = [
                "tool": .string(record.tool),
                "connector": .string(record.connector.rawValue),
                "risk": .string(record.risk.rawValue),
                "decision": .string(record.decision.rawValue),
                "ms": .int(record.duration.milliseconds),
                "failed": .bool(record.failed),
            ]
            if let arguments = record.arguments {
                fields["arguments"] = .string(arguments)
            }
            Log.shared.info("tool.call", fields)
        }
    }

    /// A log that keeps nothing, for a test that does not care.
    public static let silent = ToolCallLog(allowsArguments: { false }) { _ in }

    /// Records a finished call.
    ///
    /// - Parameters:
    ///   - tool: the tool's name.
    ///   - connector: its connector.
    ///   - risk: what it declared.
    ///   - decision: what happened.
    ///   - duration: how long it took.
    ///   - failed: whether the result was an error.
    ///   - arguments: the values, written only when transcript logging is on.
    public func record(
        tool: String,
        connector: ConnectorID,
        risk: ToolRisk,
        decision: ToolDecision,
        duration: Duration,
        failed: Bool,
        arguments: [String: JSONValue] = [:]
    ) {
        let detail: String? = if allowsArguments(), !arguments.isEmpty {
            JSONValue.object(arguments).compactJSON
        } else {
            nil
        }
        sink(ToolCallRecord(
            tool: tool,
            connector: connector,
            risk: risk,
            decision: decision,
            duration: duration,
            failed: failed,
            arguments: detail
        ))
    }

    /// Records a finished call from a prepared record.
    public func record(_ record: ToolCallRecord) {
        sink(record)
    }
}

extension Duration {
    /// The whole milliseconds of a duration, for a log field.
    public var milliseconds: Int {
        let parts = components
        let seconds = Int(parts.seconds) * 1_000
        let fraction = Int(parts.attoseconds / 1_000_000_000_000_000)
        return seconds + fraction
    }
}
