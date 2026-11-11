import Foundation
import XCTest

@testable import DotCore

/// The checks that sit between a model and a side effect.
///
/// Argument validation, the timeout and the byte budget all run inside the
/// registry, so each of these tests fails if a bad call can reach a connector or
/// if a result can arrive unbounded.
final class ConnectorRegistrySafetyTests: XCTestCase {
    private func schemaTool() -> ConnectorTool {
        makeTool(
            name: "fake.write",
            risk: .write,
            schema: ToolSchema([
                .init(name: "title", description: "A title.", field: .string(maxLength: 10)),
                .init(name: "count", description: "A count.", field: .integer(1...5), isRequired: false),
            ])
        )
    }

    func testAnInvalidArgumentNeverReachesTheConnector() async {
        let connector = FakeConnector(id: "fake", tools: [schemaTool()])
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: .allowAll
        )
        let result = await registry.invoke(makeCall(arguments: [:]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("title"))
        let effects = await connector.effects.count
        XCTAssertEqual(effects, 0)
    }

    func testAnUnknownFieldIsRefused() async {
        let connector = FakeConnector(id: "fake", tools: [schemaTool()])
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: .allowAll
        )
        let result = await registry.invoke(makeCall(arguments: [
            "title": .string("ok"),
            "extra": .string("nope"),
        ]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("extra"))
        let effects = await connector.effects.count
        XCTAssertEqual(effects, 0)
    }

    func testAnInvalidCallIsLoggedAsInvalid() async {
        let connector = FakeConnector(id: "fake", tools: [schemaTool()])
        let log = RecordingLog()
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: .allowAll,
            log: log.log
        )
        _ = await registry.invoke(makeCall(arguments: [:]))
        XCTAssertEqual(log.records.last?.decision, .invalidArguments)
    }

    func testAToolThatNeverAnswersIsReportedAsATimeout() async {
        let connector = SlowConnector()
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["slow"]),
            gate: .allowAll
        )
        let start = ContinuousClock.now
        let result = await registry.invoke(makeCall(name: "slow.write"))
        let elapsed = start.duration(to: .now)
        XCTAssertTrue(result.isError)
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    func testAResultIsCutToTheByteBudget() async {
        let long = String(repeating: "a", count: 10_000)
        let connector = FakeConnector(id: "fake", outcome: .ok(long))
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: .allowAll,
            budget: ToolResultBudget(bytes: 512)
        )
        let result = await registry.invoke(makeCall())
        XCTAssertLessThanOrEqual(result.content.utf8.count, 512)
        XCTAssertTrue(result.content.contains("[truncated"))
    }

    func testTheLogNeverCarriesArgumentValuesByDefault() async {
        let log = RecordingLog()
        let connector = FakeConnector(id: "fake", tools: [schemaTool()])
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: .allowAll,
            log: log.log
        )
        _ = await registry.invoke(makeCall(arguments: ["title": .string("My private note")]))
        let record = log.records.last
        XCTAssertNotNil(record)
        XCTAssertNil(record?.arguments, "Argument values must not be written unless transcripts are on")
        XCTAssertEqual(record?.tool, "fake.write")
    }

    func testTheLogKeepsValuesWhenTranscriptsAreOn() async {
        let log = RecordingLog()
        let connector = FakeConnector(id: "fake", tools: [schemaTool()])
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: .allowAll,
            log: log.argumentLog
        )
        _ = await registry.invoke(makeCall(arguments: ["title": .string("Shared note")]))
        XCTAssertEqual(log.records.last?.arguments, #"{"title":"Shared note"}"#)
    }

    func testAnAllowedCallIsLoggedWithItsDuration() async {
        let log = RecordingLog()
        let connector = FakeConnector(id: "fake")
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: .allowAll,
            log: log.log
        )
        _ = await registry.invoke(makeCall())
        let record = log.records.last
        XCTAssertEqual(record?.decision, .confirmed)
        XCTAssertEqual(record?.risk, .write)
        XCTAssertEqual(record?.connector, "fake")
        XCTAssertNotNil(record?.duration)
    }
}

/// A connector that outlives its tool's deadline.
private final class SlowConnector: Connector, @unchecked Sendable {
    let id: ConnectorID = "slow"
    let displayName = "Slow"
    let symbol = "tortoise"
    let detail = "Never answers."

    func tools() -> [ConnectorTool] {
        [makeTool(name: "slow.write", risk: .write, timeout: .milliseconds(100))]
    }

    func permission() async -> ConnectorPermission {
        ConnectorPermission(status: .granted, service: "Slow")
    }

    func requestAccess() async -> ConnectorPermission {
        await permission()
    }

    func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        try? await Task.sleep(for: .seconds(30))
        return .ok("late")
    }
}

/// The race under the registry's deadline.
///
/// A tool call waits on one checked continuation that two tasks compete to
/// finish. If both could resume it, the process would abort the moment a call
/// was both fast and late, so these tests make the race run many times at once
/// and prove the losing connector is cancelled rather than left behind.
final class ConnectorDeadlineRaceTests: XCTestCase {
    func testManyConcurrentCallsEachFinishExactlyOnce() async {
        let connector = FakeConnector(id: "fake")
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: .allowAll
        )
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let call = makeCall(id: "call-\(index)")
                    let result = await registry.invoke(call)
                    return result.callID == "call-\(index)" && !result.isError
                }
            }
            var passed = 0
            for await ok in group where ok {
                passed += 1
            }
            return passed
        }
        XCTAssertEqual(results, 200)
        let effects = await connector.effects.count
        XCTAssertEqual(effects, 200)
    }

    func testTheDeadlineCancelsTheConnectorItAbandoned() async {
        let connector = CancellationProbeConnector()
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["probe"]),
            gate: .allowAll
        )
        let result = await registry.invoke(makeCall(name: "probe_write"))
        XCTAssertTrue(result.isError)
        var cancelled = false
        for _ in 0..<100 {
            if await connector.wasCancelled {
                cancelled = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(cancelled, "The losing connector must be asked to stop")
    }
}

/// A connector that would outlive the tool's deadline by a wide margin.
private final class CancellationProbeConnector: Connector, @unchecked Sendable {
    let id: ConnectorID = "probe"
    let displayName = "Probe"
    let symbol = "hourglass"
    let detail = "Sleeps until cancelled."
    private let cancelled = CancelledFlag()

    var wasCancelled: Bool {
        get async { await cancelled.isSet() }
    }

    func tools() -> [ConnectorTool] {
        [makeTool(name: "probe_write", risk: .write, timeout: .milliseconds(50))]
    }

    func permission() async -> ConnectorPermission {
        ConnectorPermission(status: .granted, service: "Probe")
    }

    func requestAccess() async -> ConnectorPermission {
        await permission()
    }

    func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            await cancelled.set()
            return .ok("cancelled")
        }
        return .ok("finished")
    }
}

/// A one-way flag a cancelled task can set.
private actor CancelledFlag {
    private var value = false

    func set() {
        value = true
    }

    func isSet() -> Bool {
        value
    }
}
