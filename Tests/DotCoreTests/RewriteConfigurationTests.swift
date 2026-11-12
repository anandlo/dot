import XCTest

@testable import DotCore

/// The rewrite block of the configuration file.
///
/// It follows the rule every block follows: a value this build cannot read
/// resets only its own field, and a style id it does not know is dropped
/// instead of taking the file with it.
final class RewriteConfigurationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-rewrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func load(_ json: String) throws -> DotConfig {
        let url = directory.appendingPathComponent("config-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return DotConfig.load(from: url)
    }

    func testTheShippedDefaults() {
        let rewrite = DotConfig.default.assistant.rewrite
        XCTAssertTrue(rewrite.enabled)
        XCTAssertEqual(rewrite.styles, [.prompt, .concise, .plain, .casual, .formal])
        XCTAssertEqual(rewrite.custom, [])
        XCTAssertEqual(rewrite.choices.map(\.title), [
            "Agent prompt", "Concise", "Plain English", "Casual", "Formal",
        ])
    }

    func testAFileWithoutTheBlockKeepsTheDefaults() throws {
        let config = try load(#"{"provider": "deepgram", "assistant": {"delivery": "speak"}}"#)
        XCTAssertEqual(config.assistant.rewrite, RewriteConfiguration.default)
        XCTAssertEqual(config.assistant.delivery, .speak, "the rest of the block survived")
    }

    func testAnUnknownStyleIDIsDroppedAndTheRestStays() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {"enabled": false, "styles": ["concise", "shout", "casual"]}}}
        """#)
        XCTAssertFalse(config.assistant.rewrite.enabled)
        XCTAssertEqual(config.assistant.rewrite.styles, [.concise, .casual])
        XCTAssertEqual(config.assistant.rewrite.choices.map(\.id), ["concise", "casual"])
    }

    func testABadTypeResetsOnlyThatField() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {"enabled": "yes", "styles": ["plain", "formal"]}}}
        """#)
        XCTAssertTrue(config.assistant.rewrite.enabled, "the bad boolean fell back to its default")
        XCTAssertEqual(config.assistant.rewrite.styles, [.plain, .formal], "the styles survived")
    }

    func testABadStylesValueResetsOnlyTheStyles() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {"enabled": false, "styles": "all"}}}
        """#)
        XCTAssertFalse(config.assistant.rewrite.enabled)
        XCTAssertEqual(config.assistant.rewrite.styles, RewriteConfiguration.default.styles)
    }

    func testTheBlockRoundTrips() throws {
        var config = DotConfig.default
        config.assistant.rewrite = RewriteConfiguration(
            enabled: false,
            styles: [.formal, .prompt],
            custom: [
                CustomRewriteStyle(id: "one", title: "Haiku", instruction: "Rewrite as a haiku."),
                CustomRewriteStyle(id: "two", title: "Email", instruction: "Rewrite for email."),
            ]
        )
        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(DotConfig.self, from: data)
        XCTAssertEqual(restored.assistant.rewrite, config.assistant.rewrite)
        XCTAssertEqual(restored.assistant, config.assistant)
    }

    func testTheBlockIsWrittenUnderTheAssistantKey() throws {
        var config = DotConfig.default
        config.assistant.rewrite.enabled = false
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        let assistant = try XCTUnwrap(payload?["assistant"] as? [String: Any])
        let rewrite = try XCTUnwrap(assistant["rewrite"] as? [String: Any])
        XCTAssertEqual(rewrite["enabled"] as? Bool, false)
        XCTAssertEqual(rewrite["styles"] as? [String], ["prompt", "concise", "plain", "casual", "formal"])
        XCTAssertNil(rewrite["custom"])
    }

    func testACustomStyleIsSanitizedWhenItIsRead() throws {
        let longTitle = String(repeating: "a", count: 40)
        let longInstruction = String(repeating: "b", count: 700)
        let config = try load(#"""
        {"assistant": {"rewrite": {"custom": [
          {"id": "one", "title": "\#(longTitle)", "instruction": "\#(longInstruction)"}
        ]}}}
        """#)
        let custom = try XCTUnwrap(config.assistant.rewrite.custom.first)
        XCTAssertEqual(custom.title.count, CustomRewriteStyle.maximumTitleLength)
        XCTAssertEqual(custom.instruction.count, CustomRewriteStyle.maximumInstructionLength)
        XCTAssertEqual(custom.id, "one")
    }

    func testMoreThanSixCustomStylesAreTruncated() throws {
        let rows = (0 ..< 9).map {
            #"{"id": "s\#($0)", "title": "Style \#($0)", "instruction": "Do it."}"#
        }
        let config = try load(#"""
        {"assistant": {"rewrite": {"custom": [\#(rows.joined(separator: ","))]}}}
        """#)
        XCTAssertEqual(config.assistant.rewrite.custom.count, CustomRewriteStyle.maximumCount)
        XCTAssertEqual(config.assistant.rewrite.custom.last?.id, "s5")
    }

    func testACustomStyleWithoutTextIsNotOffered() {
        let rewrite = RewriteConfiguration(
            enabled: true,
            styles: [.formal],
            custom: [
                CustomRewriteStyle(title: "", instruction: "Rewrite."),
                CustomRewriteStyle(title: "Mine", instruction: "   "),
                CustomRewriteStyle(title: "Good", instruction: "Rewrite as a table."),
            ]
        )
        XCTAssertEqual(rewrite.choices.map(\.title), ["Formal", "Good"])
        XCTAssertNil(rewrite.style(for: "missing"))
        XCTAssertNil(rewrite.style(for: "good"))
    }

    func testTheStyleLookupFindsACustomStyleByID() {
        let custom = CustomRewriteStyle(id: "mine", title: "Mine", instruction: "Rewrite.")
        let rewrite = RewriteConfiguration(styles: [.concise], custom: [custom])
        XCTAssertEqual(rewrite.style(for: "mine")?.title, "Mine")
        XCTAssertEqual(rewrite.style(for: "concise")?.title, "Concise")
        XCTAssertNil(rewrite.style(for: "formal"), "a style that is off is not offered")
    }
}

extension RewriteConfigurationTests {
    // MARK: - Working rules

    func testTheWorkingRulesAreTheShippedOnes() {
        let rewrite = DotConfig.default.assistant.rewrite
        XCTAssertTrue(rewrite.workingRulesEnabled)
        XCTAssertEqual(rewrite.workingRules, """
        ## Working rules
        - Read the relevant code before you change it.
        - Keep changes within the scope of this request.
        - Ask before adding a dependency or changing a public interface.
        - Run the build and the tests, and report the results.
        - If something is unclear, ask instead of guessing.
        """)
        XCTAssertEqual(
            RewriteConfiguration.maximumWorkingRulesLength,
            1_200,
            "the cap the field and the decoder share"
        )
    }

    func testNoWorkingRulesLineIsIndented() {
        for line in RewriteConfiguration.defaultWorkingRules
            .split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertNotEqual(line.first, " ", "the shipped rules are indented: \(line)")
        }
    }

    func testACallerThatOmitsTheRulesGetsTheShippedOnes() {
        let rewrite = RewriteConfiguration(styles: [.concise])
        XCTAssertTrue(rewrite.workingRulesEnabled)
        XCTAssertEqual(rewrite.workingRules, RewriteConfiguration.defaultWorkingRules)
    }

    func testTheRulesFollowThePromptStyleOnly() {
        let rewrite = RewriteConfiguration.default
        XCTAssertEqual(
            rewrite.workingRulesBlock(for: RewriteStyle(.prompt)),
            RewriteConfiguration.defaultWorkingRules
        )
        for style in RewriteStyle.builtIns where style.kind != .builtIn(.prompt) {
            XCTAssertNil(rewrite.workingRulesBlock(for: style), style.id)
        }
        let custom = RewriteStyle(CustomRewriteStyle(title: "Mine", instruction: "Rewrite."))
        XCTAssertNil(rewrite.workingRulesBlock(for: custom))
    }

    func testTheBlockIsAbsentWhenTheSwitchIsOffOrTheFieldIsEmpty() {
        var rewrite = RewriteConfiguration.default
        rewrite.workingRulesEnabled = false
        XCTAssertNil(rewrite.workingRulesBlock(for: RewriteStyle(.prompt)))
        rewrite.workingRulesEnabled = true
        rewrite.workingRules = "   \n  "
        XCTAssertNil(
            rewrite.workingRulesBlock(for: RewriteStyle(.prompt)),
            "an empty field is how the block is turned off without turning off the style"
        )
    }

    func testAFileWithoutTheRulesKeepsTheDefaults() throws {
        let config = try load(#"{"assistant": {"rewrite": {"styles": ["concise"]}}}"#)
        XCTAssertTrue(config.assistant.rewrite.workingRulesEnabled)
        XCTAssertEqual(
            config.assistant.rewrite.workingRules,
            RewriteConfiguration.defaultWorkingRules
        )
        XCTAssertEqual(config.assistant.rewrite.styles, [.concise], "the rest of the block survived")
    }

    func testABadWorkingRulesValueResetsOnlyThatField() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {
          "enabled": false,
          "styles": ["plain", "formal"],
          "workingRulesEnabled": "yes",
          "workingRules": 42
        }}}
        """#)
        XCTAssertTrue(config.assistant.rewrite.workingRulesEnabled, "the bad boolean fell back")
        XCTAssertEqual(config.assistant.rewrite.workingRules, RewriteConfiguration.defaultWorkingRules)
        XCTAssertFalse(config.assistant.rewrite.enabled, "the neighbour field survived")
        XCTAssertEqual(config.assistant.rewrite.styles, [.plain, .formal])
    }

    func testTheRulesAreCappedWhenTheyAreRead() throws {
        let long = String(repeating: "a", count: 2_000)
        let config = try load(#"{"assistant": {"rewrite": {"workingRules": "\#(long)"}}}"#)
        XCTAssertEqual(
            config.assistant.rewrite.workingRules.count,
            RewriteConfiguration.maximumWorkingRulesLength
        )
    }

    func testTheRulesRoundTripAndAreWrittenUnderTheRewriteKey() throws {
        var config = DotConfig.default
        config.assistant.rewrite.workingRulesEnabled = false
        config.assistant.rewrite.workingRules = "## Rules\n- Keep it short."
        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(DotConfig.self, from: data)
        XCTAssertEqual(restored.assistant.rewrite, config.assistant.rewrite)

        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let assistant = try XCTUnwrap(payload?["assistant"] as? [String: Any])
        let rewrite = try XCTUnwrap(assistant["rewrite"] as? [String: Any])
        XCTAssertEqual(rewrite["workingRulesEnabled"] as? Bool, false)
        XCTAssertEqual(rewrite["workingRules"] as? String, "## Rules\n- Keep it short.")
    }

    /// A file written before the styles changed still opens with its settings.
    ///
    /// The five ids this feature shipped with are read as they are, an id this
    /// build does not know is dropped, and every other field of the block keeps
    /// the value the person stored.
    func testAFileWithTheOldStyleIDsKeepsEverySetting() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {
          "enabled": false,
          "styles": ["formal", "prompt", "concise", "plain", "casual", "shout"],
          "custom": [{"id": "haiku", "title": "Haiku", "instruction": "Rewrite as a haiku."}],
          "workingRulesEnabled": false,
          "workingRules": "## Working rules\n- Mine."
        }}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertFalse(rewrite.enabled, "the switch the person turned off is still off")
        XCTAssertEqual(
            rewrite.styles,
            [.formal, .prompt, .concise, .plain, .casual],
            "the order the person kept, without the id this build does not know"
        )
        XCTAssertEqual(rewrite.custom.map(\.id), ["haiku"])
        XCTAssertFalse(rewrite.workingRulesEnabled)
        XCTAssertEqual(rewrite.workingRules, "## Working rules\n- Mine.")
        XCTAssertEqual(rewrite.choices.map(\.id), ["formal", "prompt", "concise", "plain", "casual", "haiku"])
    }
}
