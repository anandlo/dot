import Foundation
import XCTest

@testable import DotCore

/// The policy a tool call runs under.
///
/// Two invariants carry the safety of the whole assistant: a read is allowed
/// without a decision, and a destructive or external call can never be approved
/// without a person seeing it, whatever the stored settings say.
final class ConnectorPolicyTests: XCTestCase {
    func testAReadRunsWithoutAsking() {
        XCTAssertEqual(ToolPolicy.derived(from: .read), .allow)
    }

    func testAWriteAsks() {
        XCTAssertEqual(ToolPolicy.derived(from: .write), .ask)
    }

    func testDestructiveAndExternalToolsAsk() {
        XCTAssertEqual(ToolPolicy.derived(from: .destructive), .ask)
        XCTAssertEqual(ToolPolicy.derived(from: .external), .ask)
    }

    func testNothingIsApprovedAutomatically() {
        for risk in ToolRisk.allCases {
            XCTAssertNotEqual(
                ToolPolicy.derived(from: risk),
                .never,
                "A shipped default must not hide a tool the person enabled"
            )
        }
    }

    func testADestructiveToolCannotBeAllowedByASetting() {
        // A hand-edited file, or a future settings bug, must not be able to
        // approve sending a message without a confirmation.
        XCTAssertEqual(ToolPolicy.allow.enforced(for: .destructive), .ask)
        XCTAssertEqual(ToolPolicy.allow.enforced(for: .external), .ask)
    }

    func testANeverPolicyOutranksTheSafetyFloor() {
        XCTAssertEqual(ToolPolicy.never.enforced(for: .destructive), .never)
        XCTAssertEqual(ToolPolicy.never.enforced(for: .read), .never)
    }

    func testAWriteMayBeAllowedOnPurpose() {
        XCTAssertEqual(ToolPolicy.allow.enforced(for: .write), .allow)
        XCTAssertEqual(ToolPolicy.ask.enforced(for: .write), .ask)
    }

    func testTheTableUsesTheRiskDefaultWithoutAnOverride() {
        let table = ToolPolicyTable()
        XCTAssertEqual(table.policy(for: makeTool(name: "a.read", risk: .read)), .allow)
        XCTAssertEqual(table.policy(for: makeTool(name: "a.write", risk: .write)), .ask)
        XCTAssertEqual(table.policy(for: makeTool(name: "a.trash", risk: .destructive)), .ask)
        XCTAssertEqual(table.policy(for: makeTool(name: "a.open", risk: .external)), .ask)
    }

    func testTheTableHonoursAnOverride() {
        let table = ToolPolicyTable(overrides: ["a.write": .allow, "a.read": .never])
        XCTAssertEqual(table.policy(for: makeTool(name: "a.write", risk: .write)), .allow)
        XCTAssertEqual(table.policy(for: makeTool(name: "a.read", risk: .read)), .never)
    }

    func testAnOverrideCannotApproveADestructiveTool() {
        let table = ToolPolicyTable(overrides: ["a.trash": .allow])
        XCTAssertEqual(table.policy(for: makeTool(name: "a.trash", risk: .destructive)), .ask)
    }

    func testADecisionSaysWhetherSomethingRan() {
        XCTAssertTrue(ToolDecision.allowed.ran)
        XCTAssertTrue(ToolDecision.confirmed.ran)
        XCTAssertFalse(ToolDecision.declined.ran)
        XCTAssertFalse(ToolDecision.blockedByPolicy.ran)
        XCTAssertFalse(ToolDecision.invalidArguments.ran)
        XCTAssertFalse(ToolDecision.unavailable.ran)
    }
}
