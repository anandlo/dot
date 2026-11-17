import XCTest

@testable import Dot

/// What a configuration notification asks a running take to do.
///
/// The decision is pure, so it is tested without an input device: the engine's
/// `isRunning`, the tap and the format are read in `Recorder` and handed here.
final class CaptureRouteChangeTests: XCTestCase {
    private func decision(
        hasInput: Bool = true,
        formatMatches: Bool = true,
        tapInstalled: Bool = true,
        engineIsRunning: Bool = true
    ) -> CaptureRouteChange.Decision {
        CaptureRouteChange.decision(
            hasInput: hasInput,
            formatMatches: formatMatches,
            tapInstalled: tapInstalled,
            engineIsRunning: engineIsRunning
        )
    }

    func testNoInputEndsTheTakeEvenWhenTheRestLooksHealthy() {
        XCTAssertEqual(decision(hasInput: false), .endTake)
        XCTAssertEqual(
            decision(hasInput: false, formatMatches: false, tapInstalled: false, engineIsRunning: false),
            .endTake
        )
    }

    func testAChangedFormatRebuildsTheConverter() {
        XCTAssertEqual(decision(formatMatches: false), .rebuild)
        XCTAssertEqual(decision(formatMatches: false, engineIsRunning: false), .rebuild)
    }

    func testAMissingTapRebuildsEvenWhenTheFormatMatches() {
        // Starting the engine with no tap would report a take that captures
        // nothing; the tap has to be installed again with a converter.
        XCTAssertEqual(decision(tapInstalled: false), .rebuild)
        XCTAssertEqual(decision(tapInstalled: false, engineIsRunning: false), .rebuild)
    }

    func testAStoppedEngineWithTheSameFormatIsRestartedOnTheSameConverter() {
        XCTAssertEqual(decision(engineIsRunning: false), .restartEngine)
    }

    func testARunningEngineWithTheSameFormatIsLeftAlone() {
        XCTAssertEqual(decision(), .ignore)
    }
}
