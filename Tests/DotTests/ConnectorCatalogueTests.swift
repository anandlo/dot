import DotCore
import XCTest

@testable import Dot

/// The catalogue the app actually ships.
///
/// A guard rather than a behaviour test: every connector is present, every tool
/// name is unique and valid for both providers, and every tool is namespaced by
/// its connector. A duplicate name would make the registry resolve the wrong
/// tool; an invalid name would make a provider reject the whole request.
final class ConnectorCatalogueTests: XCTestCase {
    func testTheCatalogueCoversEveryConnectorInOrder() {
        let connectors = ConnectorCatalog.make()
        XCTAssertEqual(connectors.map(\.id), ConnectorID.builtIn)
    }

    func testEveryConnectorIsDescribedAndOffersTools() {
        for connector in ConnectorCatalog.make() {
            XCTAssertFalse(connector.displayName.isEmpty, "\(connector.id) has no name")
            XCTAssertFalse(connector.symbol.isEmpty, "\(connector.id) has no symbol")
            XCTAssertFalse(connector.detail.isEmpty, "\(connector.id) has no detail")
            XCTAssertFalse(connector.tools().isEmpty, "\(connector.id) has no tools")
        }
    }

    func testEveryToolNameIsUniqueAndValid() {
        var seen: Set<String> = []
        for connector in ConnectorCatalog.make() {
            for tool in connector.tools() {
                XCTAssertTrue(tool.spec.hasValidName, "\(tool.name) is not a valid tool name")
                XCTAssertTrue(seen.insert(tool.name).inserted, "\(tool.name) is offered twice")
            }
        }
    }

    func testEveryToolNameIsNamespacedByItsConnector() {
        for connector in ConnectorCatalog.make() {
            for tool in connector.tools() {
                XCTAssertTrue(
                    tool.name.hasPrefix(connector.id.rawValue + "_"),
                    "\(tool.name) does not belong to \(connector.id)"
                )
            }
        }
    }

    func testEveryToolIsDescribedAndSaysNothingExtraIsAllowed() {
        for connector in ConnectorCatalog.make() {
            for tool in connector.tools() {
                XCTAssertFalse(tool.title.isEmpty, "\(tool.name) has no title")
                XCTAssertFalse(tool.description.isEmpty, "\(tool.name) has no description")
                XCTAssertEqual(
                    tool.schema.json["additionalProperties"],
                    .bool(false),
                    "\(tool.name) accepts fields it does not declare"
                )
            }
        }
    }

    func testNoDestructiveOrExternalToolDefaultsToAllow() {
        for connector in ConnectorCatalog.make() {
            for tool in connector.tools() {
                let policy = ToolPolicy.derived(from: tool.risk)
                if tool.risk == .destructive || tool.risk == .external {
                    XCTAssertEqual(policy, .ask, "\(tool.name) would run without a confirmation")
                }
            }
        }
    }

    func testTheDangerousToolsAreWhereTheyBelong() {
        let connectors = ConnectorCatalog.make()
        func tool(_ name: String) -> ConnectorTool? {
            connectors.flatMap { $0.tools() }.first { $0.name == name }
        }
        XCTAssertEqual(tool("files_trash")?.risk, .destructive)
        XCTAssertEqual(tool("messages_send")?.risk, .destructive)
        XCTAssertEqual(tool("mail_draft")?.risk, .write)
        XCTAssertEqual(tool("shortcuts_run")?.risk, .external)
        XCTAssertEqual(tool("apps_openURL")?.risk, .external)
        XCTAssertNil(tool("mail_send"), "Mail must not be able to send")
        XCTAssertNil(tool("system_setBrightness"), "Brightness has no public API and must not ship")
    }
}
