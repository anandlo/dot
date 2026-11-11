import Foundation
import XCTest

@testable import DotCore

/// What the model is allowed to see, and what the gate stops.
///
/// The registry is the only place a call can become a side effect. These tests
/// use a fake connector that records every call, so "the tool was not there" and
/// "the person said no, so nothing happened" are observable rather than
/// asserted from a return value alone.
final class ConnectorRegistryTests: XCTestCase {
    func testOnlyEnabledConnectorsAreOffered() async {
        let enabled = FakeConnector(id: "enabled", tools: [makeTool(name: "enabled.read", risk: .read)])
        let disabled = FakeConnector(id: "disabled", tools: [makeTool(name: "disabled.read", risk: .read)])
        let registry = ConnectorRegistry(
            connectors: [enabled, disabled],
            settings: ConnectorSettings(enabled: ["enabled"]),
            gate: .denyAll
        )
        let names = await registry.specs().map(\.name)
        XCTAssertEqual(names, ["enabled.read"])
    }

    func testAConnectorWithoutPermissionIsNotOffered() async {
        let undetermined = FakeConnector(id: "a", permission: .notDetermined)
        let denied = FakeConnector(id: "b", permission: .denied)
        let restricted = FakeConnector(id: "c", permission: .restricted)
        let registry = ConnectorRegistry(
            connectors: [undetermined, denied, restricted],
            settings: ConnectorSettings(enabled: ["a", "b", "c"]),
            gate: .denyAll
        )
        let specs = await registry.specs()
        XCTAssertTrue(specs.isEmpty, "A connector macOS has not granted must not be offered")
    }

    func testAToolSetToNeverIsNotOffered() async {
        let connector = FakeConnector(id: "fake", tools: [makeTool(name: "fake.write", risk: .write)])
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"], policies: ["fake.write": .never]),
            gate: .denyAll
        )
        let specs = await registry.specs()
        XCTAssertTrue(specs.isEmpty)
    }

    func testPermissionRevokedAfterTheTurnStartsHidesTheTool() async throws {
        let connector = FakeConnector(id: "fake")
        let registry = makeRegistry(connector: connector)
        let before = await registry.specs()
        XCTAssertEqual(before.count, 1)
        await connector.setPermission(.denied)
        let after = await registry.specs()
        XCTAssertTrue(after.isEmpty)
        let result = await registry.invoke(makeCall())
        XCTAssertTrue(result.isError)
        let effects = await connector.effects.count
        XCTAssertEqual(effects, 0)
    }

    func testARefusedConfirmationHasNoSideEffect() async {
        let connector = FakeConnector(id: "fake")
        let log = RecordingLog()
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: .denyAll,
            log: log.log
        )
        let result = await registry.invoke(makeCall())
        XCTAssertTrue(result.isError)
        let effects = await connector.effects.count
        XCTAssertEqual(effects, 0, "A declined confirmation must never reach the connector")
        XCTAssertEqual(log.records.last?.decision, .declined)
    }

    func testAConfirmedCallRunsOnce() async {
        let connector = FakeConnector(id: "fake")
        let requests = RequestRecorder()
        let gate = ConfirmationGate { request in
            await requests.record(request)
            return true
        }
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: gate
        )
        let result = await registry.invoke(makeCall())
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "done")
        let effects = await connector.effects.count
        XCTAssertEqual(effects, 1)
        let summaries = await requests.summaries
        XCTAssertEqual(summaries, ["Do it?"])
    }

    func testTheGateIsAwaitedBeforeTheConnectorRuns() async {
        let connector = FakeConnector(id: "fake")
        let gate = ConfirmationGate { _ in
            // While the person is deciding, nothing may have run yet.
            let effects = await connector.effects.count
            XCTAssertEqual(effects, 0)
            try? await Task.sleep(for: .milliseconds(30))
            let afterWaiting = await connector.effects.count
            XCTAssertEqual(afterWaiting, 0)
            return true
        }
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: gate
        )
        _ = await registry.invoke(makeCall())
        let effects = await connector.effects.count
        XCTAssertEqual(effects, 1)
    }

    func testAReadRunsWithoutTheGate() async {
        let connector = FakeConnector(id: "fake", tools: [makeTool(name: "fake.read", risk: .read)])
        let gateCalls = RequestRecorder()
        let gate = ConfirmationGate { request in
            await gateCalls.record(request)
            return false
        }
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["fake"]),
            gate: gate
        )
        let result = await registry.invoke(makeCall(name: "fake.read"))
        XCTAssertFalse(result.isError)
        let effects = await connector.effects.count
        XCTAssertEqual(effects, 1)
        let summaries = await gateCalls.summaries
        XCTAssertTrue(summaries.isEmpty, "A read must not ask")
    }

    func testOnlyTheToolsOfGrantedAndEnabledConnectorsReachTheModel() async {
        let reminders = FakeConnector(
            id: .reminders,
            tools: [makeTool(name: "reminders_create", risk: .write)]
        )
        let contacts = FakeConnector(
            id: .contacts,
            tools: [makeTool(name: "contacts_find", risk: .read)],
            permission: .granted
        )
        let notes = FakeConnector(id: .notes, permission: .notDetermined)
        let registry = ConnectorRegistry(
            connectors: [reminders, contacts, notes],
            settings: ConnectorSettings(enabled: [.reminders, .contacts, .notes]),
            gate: .denyAll
        )
        let names = Set(await registry.specs().map(\.name))
        XCTAssertEqual(names, ["reminders_create", "contacts_find"])
    }
}

/// Collects confirmation requests for a test.
actor RequestRecorder {
    private(set) var summaries: [String] = []

    func record(_ request: ConfirmationRequest) {
        summaries.append(request.summary)
    }
}

/// The settings page's view of the same registry.
///
/// Switched on and permitted are separate facts, and the page has to show both:
/// "I turned it off" and "macOS is blocking it" are different problems with
/// different fixes.
final class ConnectorSummaryTests: XCTestCase {
    func testASummarySeparatesEnabledFromPermitted() async {
        let enabledAndGranted = FakeConnector(id: "a", tools: [makeTool(name: "a.write", risk: .write)])
        let enabledAndDenied = FakeConnector(id: "b", permission: .denied)
        let disabled = FakeConnector(id: "c")
        let registry = ConnectorRegistry(
            connectors: [enabledAndGranted, enabledAndDenied, disabled],
            settings: ConnectorSettings(enabled: ["a", "b"]),
            gate: .denyAll
        )
        let summaries = await registry.summaries()
        XCTAssertEqual(summaries.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(summaries[0].isEnabled, true)
        XCTAssertEqual(summaries[0].permission.status, .granted)
        XCTAssertTrue(summaries[0].isAvailable)
        XCTAssertEqual(summaries[1].isEnabled, true)
        XCTAssertEqual(summaries[1].permission.status, .denied)
        XCTAssertFalse(summaries[1].isAvailable, "Enabled but refused is not available")
        XCTAssertEqual(summaries[2].isEnabled, false)
        XCTAssertFalse(summaries[2].isAvailable)
    }

    func testASummaryCarriesThePolicyInForce() async {
        let connector = FakeConnector(id: "a", tools: [makeTool(name: "a.write", risk: .write)])
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["a"], policies: ["a.write": .never]),
            gate: .denyAll
        )
        let summaries = await registry.summaries()
        XCTAssertEqual(summaries.first?.tools.first?.policy, .never)
        XCTAssertEqual(summaries.first?.tools.first?.risk, .write)
    }

    func testRequestingAccessReachesTheConnector() async {
        let connector = FakeConnector(id: "a", permission: .notDetermined)
        let registry = ConnectorRegistry(
            connectors: [connector],
            settings: ConnectorSettings(enabled: ["a"]),
            gate: .denyAll
        )
        let permission = await registry.requestAccess("a")
        XCTAssertEqual(permission?.status, .notDetermined)
        let missing = await registry.requestAccess("nope")
        XCTAssertNil(missing)
    }
}
