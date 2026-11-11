import DotCore
import XCTest

@testable import Dot

/// The connector symbols, in the two places they are declared.
///
/// A card that has only a connector's id cannot ask the connector for its
/// symbol, so the ids carry a table of their own. This test is what keeps the
/// table and the connectors from drifting apart.
final class ConnectorSymbolTests: XCTestCase {
    func testEveryConnectorSymbolMatchesItsID() async {
        let registry = ConnectorCatalog.registry(
            settings: .default,
            gate: .denyAll,
            log: .silent
        )
        let summaries = await registry.summaries()
        XCTAssertEqual(summaries.count, ConnectorID.builtIn.count)
        for summary in summaries {
            XCTAssertEqual(
                summary.id.symbol,
                summary.symbol,
                "the table for \(summary.id.rawValue) disagrees with the connector"
            )
        }
    }

    func testAnUnknownConnectorHasAPlainSymbol() {
        XCTAssertEqual(ConnectorID("something-new").symbol, "puzzlepiece.extension")
    }
}
