import Foundation
import XCTest

@testable import DotCore

final class MouseTriggerButtonTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-mouse-trigger-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertEqual(DotConfig.default.mouseTriggerButton, .off)
        XCTAssertEqual(DotConfig().mouseTriggerButton, .off)
    }

    func testButtonNumbers() {
        XCTAssertNil(MouseTriggerButton.off.buttonNumber)
        XCTAssertEqual(MouseTriggerButton.middle.buttonNumber, 2)
        XCTAssertEqual(MouseTriggerButton.back.buttonNumber, 3)
        XCTAssertEqual(MouseTriggerButton.forward.buttonNumber, 4)
    }

    func testTitles() {
        XCTAssertEqual(MouseTriggerButton.off.title, "Off")
        XCTAssertEqual(MouseTriggerButton.middle.title, "Middle button")
        XCTAssertEqual(MouseTriggerButton.back.title, "Back button")
        XCTAssertEqual(MouseTriggerButton.forward.title, "Forward button")
    }

    func testAFileWithoutTheKeyLoadsAsOff() throws {
        let url = try write(#"{"provider": "openai", "autoPaste": false}"#)
        let loaded = DotConfig.load(from: url)
        XCTAssertEqual(loaded.mouseTriggerButton, .off)
        XCTAssertFalse(loaded.autoPaste)
    }

    func testAnUnknownValueLoadsAsOff() throws {
        let url = try write(#"{"provider": "openai", "mouseTriggerButton": "thumb"}"#)
        let loaded = DotConfig.load(from: url)
        XCTAssertEqual(loaded.mouseTriggerButton, .off)
        XCTAssertEqual(loaded.provider, "openai")
    }

    func testExplicitNullLoadsAsOff() throws {
        let url = try write(#"{"mouseTriggerButton": null}"#)
        XCTAssertEqual(DotConfig.load(from: url).mouseTriggerButton, .off)
    }

    func testEveryValueSurvivesTheRoundTrip() throws {
        for button in MouseTriggerButton.allCases {
            var config = DotConfig.default
            config.mouseTriggerButton = button
            let url = directory.appendingPathComponent("button-\(button.rawValue).json")
            try config.save(to: url)

            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("\"mouseTriggerButton\" : \"\(button.rawValue)\""), text)
            XCTAssertEqual(DotConfig.load(from: url).mouseTriggerButton, button)
        }
    }
}
