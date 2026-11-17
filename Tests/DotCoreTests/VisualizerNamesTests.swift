import XCTest

@testable import DotCore

/// The names the Appearance page shows, and the values it saves.
///
/// The names are copy: each one says what the style draws, so they were rewritten
/// without the styles changing. The raw values are the stored spelling, so they
/// did not move: a configuration written before the rename still loads the style
/// it chose.
final class VisualizerNamesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-visualizer-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEveryVisualizerCarriesItsName() {
        XCTAssertEqual(HUDVisualizer.stretch.title, "Wave")
        XCTAssertEqual(HUDVisualizer.filament.title, "Filament")
        XCTAssertEqual(HUDVisualizer.silk.title, "Ribbons")
        XCTAssertEqual(HUDVisualizer.matrix.title, "Dot matrix")
        XCTAssertEqual(HUDVisualizer.haloEdge.title, "Orbit")
    }

    func testEveryMaterialCarriesItsName() {
        XCTAssertEqual(HUDMaterial.glass.title, "Glass")
        XCTAssertEqual(HUDMaterial.black.title, "Black")
    }

    /// The line under each name says what the style draws, in one sentence.
    func testEveryVisualizerDescribesItself() {
        XCTAssertEqual(
            HUDVisualizer.stretch.detail,
            "One mirrored wave drawn from the right edge, each moment of the voice kept as it was spoken."
        )
        XCTAssertEqual(
            HUDVisualizer.filament.detail,
            "A coiled filament that glows from ember red to white hot with the loudness of the voice."
        )
        XCTAssertEqual(
            HUDVisualizer.silk.detail,
            "Five ribbons twisting through each other, their width the recent voice."
        )
        XCTAssertEqual(
            HUDVisualizer.matrix.detail,
            "A scrolling grid of separate dots, each lit by one band of the voice's spectrum."
        )
        XCTAssertEqual(
            HUDVisualizer.haloEdge.detail,
            "Particles on five rings around a lit core, the rings widening with every syllable."
        )
    }

    /// The raw values are what the configuration file stores, so the rename may
    /// not reach them: every value that was written before still decodes, and
    /// every case still encodes to it.
    func testTheStoredSpellingDidNotMove() {
        XCTAssertEqual(HUDVisualizer.stretch.rawValue, "stretch")
        XCTAssertEqual(HUDVisualizer.filament.rawValue, "filament")
        XCTAssertEqual(HUDVisualizer.silk.rawValue, "silk")
        XCTAssertEqual(HUDVisualizer.matrix.rawValue, "matrix")
        XCTAssertEqual(HUDVisualizer.haloEdge.rawValue, "halo-edge")
        XCTAssertEqual(HUDVisualizer(rawValue: "halo-edge"), .haloEdge)
        XCTAssertEqual(HUDMaterial.glass.rawValue, "glass")
        XCTAssertEqual(HUDMaterial.black.rawValue, "black")

        for visualizer in HUDVisualizer.allCases {
            XCTAssertEqual(
                HUDVisualizer(rawValue: visualizer.rawValue),
                visualizer,
                "\(visualizer) does not round trip through its raw value"
            )
        }
        for material in HUDMaterial.allCases {
            XCTAssertEqual(HUDMaterial(rawValue: material.rawValue), material)
        }
    }

    /// A file that saved two styles before the rename still opens on the same two
    /// styles, not on the defaults.
    func testASavedConfigurationKeepsItsStyles() throws {
        let url = directory.appendingPathComponent("config.json")
        try #"""
        {
          "hudVisualizer": "silk",
          "hudMaterial": "black"
        }
        """#.write(to: url, atomically: true, encoding: .utf8)

        let config = DotConfig.load(from: url)
        XCTAssertEqual(config.hudVisualizer, .silk)
        XCTAssertEqual(config.hudMaterial, .black)
        XCTAssertEqual(config.hudVisualizer.title, "Ribbons")
        XCTAssertEqual(config.hudMaterial.title, "Black")
    }
}
