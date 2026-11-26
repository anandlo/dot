import Foundation
import XCTest

@testable import DotCore

final class ReduceMotionSettingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-reduce-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, named name: String = "config.json") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTheDefaultIsOff() {
        XCTAssertFalse(DotConfig.default.reduceMotion)
        XCTAssertFalse(DotConfig().reduceMotion)
    }

    func testAFileWithoutTheKeyLoadsAsOff() throws {
        let url = try write(#"{"provider": "openai", "autoPaste": false}"#)
        let loaded = DotConfig.load(from: url)
        XCTAssertFalse(loaded.reduceMotion)
        XCTAssertFalse(loaded.autoPaste)
    }

    func testAnInvalidValueLoadsAsOff() throws {
        let url = try write(#"{"provider": "openai", "reduceMotion": "yes"}"#)
        let loaded = DotConfig.load(from: url)
        XCTAssertFalse(loaded.reduceMotion)
        XCTAssertEqual(loaded.provider, "openai")
    }

    func testBothValuesSurviveTheRoundTrip() throws {
        for value in [true, false] {
            var config = DotConfig.default
            config.reduceMotion = value
            let url = directory.appendingPathComponent("reduce-motion-\(value).json")
            try config.save(to: url)

            XCTAssertEqual(DotConfig.load(from: url).reduceMotion, value)
        }
    }
}
