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
        XCTAssertEqual(rewrite.styles, RewriteStyleID.shippedCases)
        XCTAssertEqual(rewrite.styles, [.prompt, .concise, .formal, .casual, .genZ])
        XCTAssertEqual(rewrite.custom, [])
        XCTAssertEqual(rewrite.deletedBuiltIns, [])
        XCTAssertEqual(rewrite.visibleBuiltIns, RewriteStyleID.shippedCases)
        XCTAssertEqual(rewrite.choices.map(\.title), [
            "Agent prompt", "Concise", "Professional", "Casual", "Gen Z",
        ])
    }

    func testAFileWithoutTheBlockKeepsTheDefaults() throws {
        let config = try load(#"{"provider": "deepgram", "assistant": {"chat": {"provider": "anthropic"}}}"#)
        XCTAssertEqual(config.assistant.rewrite, RewriteConfiguration.default)
        XCTAssertEqual(config.assistant.chat.providerID, "anthropic", "the rest of the block survived")
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
        XCTAssertEqual(
            config.assistant.rewrite.styles,
            [.concise, .formal],
            "the styles survived, with Plain English read as Concise"
        )
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
        XCTAssertEqual(
            rewrite["styles"] as? [String],
            ["prompt", "concise", "formal", "casual", "gen-z"]
        )
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
        XCTAssertEqual(rewrite.choices.map(\.title), ["Professional", "Good"])
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
    // MARK: - The retired working-rules block

    /// A rewrite block read from a fixture file, the way a file on disk is read.
    ///
    /// - Parameter name: the fixture's name, without its extension.
    /// - Returns: the rewrite block it holds.
    private func fixture(_ name: String) throws -> RewriteConfiguration {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/StandingRules"
            ),
            "the fixture \(name).json is missing from the test bundle"
        )
        return DotConfig.load(from: url).assistant.rewrite
    }

    /// The Agent prompt instruction a fixture file holds, read as it is written.
    ///
    /// A kept edit is asserted against these bytes rather than against a copy of
    /// them in the test: the property is that the decoder changed nothing.
    ///
    /// - Parameter name: the fixture's name, without its extension.
    /// - Returns: the instruction the file stores.
    private func fixtureInstruction(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/StandingRules"
            ),
            "the fixture \(name).json is missing from the test bundle"
        )
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let assistant = try XCTUnwrap((payload as? [String: Any])?["assistant"] as? [String: Any])
        let rewrite = try XCTUnwrap(assistant["rewrite"] as? [String: Any])
        let instructions = try XCTUnwrap(rewrite["builtInInstructions"] as? [String: Any])
        return try XCTUnwrap(instructions["prompt"] as? String)
    }

    /// A file whose block carried the person's own rules hands them to the
    /// block the model never sees.
    ///
    /// The text is theirs, so it is not dropped when the editor moves: the
    /// switch comes on and the stored text is carried as it was written. The
    /// Agent prompt's instruction is not rewritten to hold the rules, which is
    /// what the build before this one did.
    func testAFileWithItsOwnRulesTurnsTheStandingBlockOn() throws {
        let rewrite = try fixture("legacy-own-rules-on")
        XCTAssertTrue(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "## Working rules\n- Mine.\n- Keep it short.")
        XCTAssertEqual(rewrite.standingRulesText, rewrite.standingRules)
        XCTAssertTrue(rewrite.enabled)
        XCTAssertEqual(rewrite.styles, [.prompt, .concise])
        XCTAssertNil(
            rewrite.builtInInstructions["prompt"],
            "the migration wrote the rules into the prompt instruction"
        )
        XCTAssertEqual(rewrite.instruction(for: .prompt), RewriteStyleID.prompt.template)
    }

    /// The rules the retired block shipped with were never a choice, so a file
    /// that kept them starts with the block off.
    func testAFileWithTheShippedRulesStartsTheBlockOff() throws {
        let rewrite = try fixture("legacy-default-rules-on")
        XCTAssertFalse(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "")
        XCTAssertNil(rewrite.standingRulesText)
        XCTAssertNil(rewrite.builtInInstructions["prompt"])
        XCTAssertEqual(
            rewrite.instruction(for: .prompt),
            RewriteStyleID.prompt.template,
            "the shipped prompt was replaced by the retired rules"
        )
        XCTAssertEqual(rewrite.styles, [.prompt, .concise, .formal])
    }

    /// A file that turned the block off keeps everything else it stored.
    func testAFileWithTheBlockOffStartsTheBlockOffAndKeepsEverySetting() throws {
        let rewrite = try fixture("legacy-block-off")
        XCTAssertFalse(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "")
        XCTAssertFalse(rewrite.enabled)
        XCTAssertEqual(rewrite.styles, [.prompt, .concise, .formal])
        XCTAssertEqual(rewrite.custom.map(\.id), ["haiku"])
        XCTAssertEqual(rewrite.builtInInstructions["formal"], "Be brief.")
        XCTAssertEqual(rewrite.deletedBuiltIns, [.casual])
        XCTAssertEqual(rewrite.visibleBuiltIns, [.prompt, .concise, .formal, .genZ])
    }

    /// A file that says nothing about either block reads as a fresh record.
    func testAFileWithoutEitherBlockUsesTheDefaults() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {"enabled": true, "styles": ["prompt", "concise"]}}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertFalse(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "")
        XCTAssertNil(rewrite.standingRulesText)
        XCTAssertEqual(rewrite, RewriteConfiguration(
            styles: [.prompt, .concise]
        ))
    }

    /// A stored edit of the Agent prompt is the person's own words and stays
    /// untouched by the migration beside it.
    func testAStoredAgentPromptEditIsNotRewrittenByTheMigration() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {
          "styles": ["prompt"],
          "builtInInstructions": {"prompt": "Write the task as a checklist."},
          "workingRulesEnabled": true,
          "workingRules": "- Mine."
        }}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertEqual(rewrite.builtInInstructions["prompt"], "Write the task as a checklist.")
        XCTAssertEqual(rewrite.instruction(for: .prompt), "Write the task as a checklist.")
        XCTAssertTrue(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "- Mine.")
    }

    /// A file the previous build saved after converting the rules into a prompt
    /// instruction gets the new template back.
    ///
    /// That build removed the rules section from a stamped-in template and
    /// stored the result as the person's instruction, saving nothing else. Read
    /// as an edit, it would outrank the new template for ever, so the exact
    /// value that build generated is recognised and dropped.
    func testAPromptOverrideFromThePreviousBuildWithoutRulesIsRemoved() throws {
        let rewrite = try fixture("previous-build-without-rules")
        XCTAssertNil(
            rewrite.builtInInstructions["prompt"],
            "the value the previous build generated was kept as an edit"
        )
        XCTAssertEqual(rewrite.instruction(for: .prompt), RewriteStyleID.prompt.template)
        XCTAssertFalse(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "")
        XCTAssertEqual(rewrite.styles, [.prompt, .concise])
    }

    /// A file the previous build saved with the person's own rules in the prompt
    /// hands those rules to the block the model never sees.
    ///
    /// The rules were written for exactly that place, and the new template has
    /// no rules section, so they move to standing rules rather than disappear.
    func testAPromptOverrideFromThePreviousBuildWithThePersonsRulesTurnsTheBlockOn() throws {
        let rewrite = try fixture("previous-build-own-rules")
        XCTAssertNil(
            rewrite.builtInInstructions["prompt"],
            "the value the previous build generated was kept as an edit"
        )
        XCTAssertTrue(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "- Mine.\n- Keep it short.")
        XCTAssertEqual(rewrite.instruction(for: .prompt), RewriteStyleID.prompt.template)
    }

    /// An override that is the whole previous template is migrated, because the
    /// previous producer wrote exactly those bytes.
    ///
    /// Its default-rules comparison used the retired text with the heading in
    /// it, and its strip never removed a heading, so a rules payload holding
    /// the shipped bullets without the heading survived that comparison and was
    /// assembled into the full template. Replaying the producer reproduces the
    /// stored bytes, which is what makes it recognisable as machine-written
    /// rather than pasted. The rules the person had become standing rules.
    func testAPromptOverrideThatIsTheWholePreviousTemplateIsMigrated() throws {
        let rewrite = try fixture("previous-build-default-rules")
        XCTAssertNil(
            rewrite.builtInInstructions["prompt"],
            "the value the previous producer wrote was kept as an edit"
        )
        XCTAssertTrue(rewrite.standingRulesEnabled)
        XCTAssertEqual(
            rewrite.standingRules,
            """
            - Read the relevant code before you change it.
            - Keep changes within the scope of this request.
            - Ask before adding a dependency or changing a public interface.
            - Run the build and the tests, and report the results.
            - If something is unclear, ask instead of guessing.
            """
        )
        XCTAssertEqual(rewrite.instruction(for: .prompt), RewriteStyleID.prompt.template)
    }

    /// A lone carriage return inside the rules is migrated.
    ///
    /// The previous producer replaced CRLF pairs and nothing else, so a return
    /// that stood on its own survived into the value it wrote. Recognising the
    /// value is the replay's job, not a scan for a character: a rule here that
    /// rejected every return would throw away a file that build really saved.
    func testAnOverrideWithALoneCarriageReturnIsMigrated() throws {
        let rewrite = try fixture("previous-build-lone-cr-rules")
        XCTAssertNil(
            rewrite.builtInInstructions["prompt"],
            "a value the previous producer wrote was kept as an edit"
        )
        XCTAssertTrue(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "- A.\r- B.")
        XCTAssertEqual(rewrite.instruction(for: .prompt), RewriteStyleID.prompt.template)
    }

    /// An override holding the retired rules with their heading twice over is a
    /// person's edit: that is the payload the previous producer refused.
    ///
    /// It compared the rules against the retired text with the heading in it,
    /// so a payload that still carried the heading matched and produced no
    /// instruction at all. A file holding that value was written by a person.
    func testAnOverrideHoldingTheDefaultRulesUnderTheirHeadingIsKept() throws {
        let rewrite = try fixture("previous-build-heading-default-rules")
        XCTAssertEqual(
            rewrite.builtInInstructions["prompt"],
            try fixtureInstruction("previous-build-heading-default-rules"),
            "a value the previous producer refused was read as its own"
        )
        XCTAssertFalse(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "")
        XCTAssertEqual(rewrite.instruction(for: .prompt), try fixtureInstruction("previous-build-heading-default-rules"))
    }

    /// A rules payload past the retired 1 200-character cap cannot be what the
    /// previous build stored: it cut every payload to that length.
    func testAnOverrideWhoseRulesExceedTheRetiredCapIsKept() throws {
        let rewrite = try fixture("previous-build-long-rules")
        XCTAssertEqual(
            rewrite.builtInInstructions["prompt"],
            try fixtureInstruction("previous-build-long-rules"),
            "a payload the previous build would have cut was read as its own"
        )
        XCTAssertFalse(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "")
    }

    /// A payload with Windows line endings cannot be what the previous build
    /// stored: it rewrote every CRLF pair before writing the rules, so the value
    /// it stored has no pair left.
    func testAnOverrideWithWindowsLineEndingsIsKept() throws {
        let rewrite = try fixture("previous-build-crlf-rules")
        XCTAssertEqual(
            rewrite.builtInInstructions["prompt"],
            try fixtureInstruction("previous-build-crlf-rules"),
            "a payload the previous build would have rewritten was read as its own"
        )
        XCTAssertFalse(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "")
    }

    /// The previous template with one line of it edited is a person's copy, not
    /// the value that build generated.
    func testAnEditedCopyOfThePreviousTemplateIsKept() throws {
        let rewrite = try fixture("previous-build-edited-goal")
        XCTAssertEqual(
            rewrite.builtInInstructions["prompt"],
            try fixtureInstruction("previous-build-edited-goal"),
            "an edited copy of the old template was migrated"
        )
        XCTAssertFalse(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "")
    }

    /// An instruction the person wrote is not one of the generated shapes and is
    /// never touched.
    func testAHandEditedPromptOverrideIsKeptAndNoRulesAreInvented() throws {
        let rewrite = try fixture("previous-build-user-edit")
        XCTAssertEqual(rewrite.builtInInstructions["prompt"], "Write the task as a checklist.")
        XCTAssertEqual(rewrite.instruction(for: .prompt), "Write the task as a checklist.")
        XCTAssertFalse(rewrite.standingRulesEnabled)
        XCTAssertEqual(rewrite.standingRules, "")
    }

    /// A migrated file is saved without the instruction the previous build wrote.
    ///
    /// The migration has to survive its own save: a file that keeps the
    /// generated instruction would be read as an edit next time, and the new
    /// template would be lost again.
    func testAMigratedPreviousFileReEncodesWithoutTheOverride() throws {
        for name in [
            "previous-build-without-rules",
            "previous-build-own-rules",
            "previous-build-default-rules",
        ] {
            let config = DotConfig.load(from: try XCTUnwrap(
                Bundle.module.url(
                    forResource: name,
                    withExtension: "json",
                    subdirectory: "Fixtures/StandingRules"
                ),
                "the fixture \(name).json is missing from the test bundle"
            ))
            XCTAssertNil(config.assistant.rewrite.builtInInstructions["prompt"], name)

            let data = try JSONEncoder().encode(config)
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let assistant = try XCTUnwrap(payload?["assistant"] as? [String: Any])
            let block = try XCTUnwrap(assistant["rewrite"] as? [String: Any], name)
            XCTAssertNil(block["builtInInstructions"], "the generated instruction was written back: \(name)")
            XCTAssertNil(block["workingRulesEnabled"], name)
            XCTAssertNil(block["workingRules"], name)

            let restored = try JSONDecoder().decode(DotConfig.self, from: data)
            XCTAssertEqual(restored.assistant.rewrite, config.assistant.rewrite, name)
            XCTAssertEqual(
                restored.assistant.rewrite.instruction(for: .prompt),
                RewriteStyleID.prompt.template,
                name
            )
        }
    }

    /// A kept override survives the save it is written back in.
    ///
    /// The negatives are the person's text: the migration must not quietly
    /// remove them on the next save either.
    func testAKentOverrideIsWrittenBackUnchanged() throws {
        for name in [
            "previous-build-heading-default-rules",
            "previous-build-long-rules",
            "previous-build-crlf-rules",
            "previous-build-edited-goal",
            "previous-build-user-edit",
        ] {
            let config = DotConfig.load(from: try XCTUnwrap(
                Bundle.module.url(
                    forResource: name,
                    withExtension: "json",
                    subdirectory: "Fixtures/StandingRules"
                ),
                "the fixture \(name).json is missing from the test bundle"
            ))
            let stored = try XCTUnwrap(config.assistant.rewrite.builtInInstructions["prompt"], name)
            let restored = try JSONDecoder().decode(
                DotConfig.self,
                from: JSONEncoder().encode(config)
            )
            XCTAssertEqual(
                restored.assistant.rewrite.builtInInstructions["prompt"],
                stored,
                "\(name) lost its edit on the way back"
            )
        }
    }

    /// The keys this build writes answer for the block even when a generated
    /// instruction is found beside them.
    func testTheStandingKeysWinOverAGeneratedPromptOverride() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {
          "styles": ["prompt"],
          "standingRulesEnabled": false,
          "standingRules": "- Mine now.",
          "builtInInstructions": {"prompt": "Write the task as a checklist."}
        }}}
        """#)
        XCTAssertEqual(config.assistant.rewrite.builtInInstructions["prompt"], "Write the task as a checklist.")
        XCTAssertFalse(config.assistant.rewrite.standingRulesEnabled)
        XCTAssertEqual(config.assistant.rewrite.standingRules, "- Mine now.")
    }

    /// The new keys are written and the retired ones never are.
    func testEncodingWritesTheStandingRulesAndNeverTheRetiredKeys() throws {
        for name in ["legacy-own-rules-on", "legacy-default-rules-on", "legacy-block-off"] {
            let config = DotConfig.load(from: try XCTUnwrap(
                Bundle.module.url(
                    forResource: name,
                    withExtension: "json",
                    subdirectory: "Fixtures/StandingRules"
                ),
                "the fixture \(name).json is missing from the test bundle"
            ))
            let data = try JSONEncoder().encode(config)
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let assistant = try XCTUnwrap(payload?["assistant"] as? [String: Any])
            let block = try XCTUnwrap(assistant["rewrite"] as? [String: Any], name)
            XCTAssertEqual(
                block["standingRulesEnabled"] as? Bool,
                config.assistant.rewrite.standingRulesEnabled,
                name
            )
            XCTAssertEqual(
                block["standingRules"] as? String,
                config.assistant.rewrite.standingRules,
                name
            )
            XCTAssertNil(block["workingRulesEnabled"], "the retired switch is written: \(name)")
            XCTAssertNil(block["workingRules"], "the retired field is written: \(name)")

            let restored = try JSONDecoder().decode(DotConfig.self, from: data)
            XCTAssertEqual(restored.assistant.rewrite, config.assistant.rewrite, name)
        }
    }

    /// The stored text is held to the length the block keeps.
    func testAStoredStandingTextIsCappedOnDecode() throws {
        let long = String(repeating: "a", count: 2_500)
        let config = try load(#"""
        {"assistant": {"rewrite": {"standingRulesEnabled": true, "standingRules": "\#(long)"}}}
        """#)
        XCTAssertEqual(config.assistant.rewrite.standingRules.count, 2_000)
        XCTAssertEqual(config.assistant.rewrite.standingRulesText?.count, 2_000)
    }

    /// A value of the new keys this build cannot read falls back to the default
    /// rather than failing the block.
    func testABadStandingValueDoesNotFailTheBlock() throws {
        for bad in [#""standingRulesEnabled": "yes""#, #""standingRules": 42"#,
                    #""standingRulesEnabled": [true], "standingRules": {"a": 1}"#] {
            let config = try load(#"""
            {"assistant": {"rewrite": {
              "enabled": false,
              "styles": ["concise"],
              \#(bad)
            }}}
            """#)
            XCTAssertFalse(config.assistant.rewrite.enabled, "the value: \(bad)")
            XCTAssertEqual(config.assistant.rewrite.styles, [.concise], "the value: \(bad)")
            XCTAssertFalse(config.assistant.rewrite.standingRulesEnabled, "the value: \(bad)")
            XCTAssertEqual(config.assistant.rewrite.standingRules, "", "the value: \(bad)")
        }
    }

    /// A bad value in either retired key cannot take the block with it.
    func testABadLegacyRulesValueDoesNotFailTheBlock() throws {
        for bad in [#""workingRulesEnabled": "yes""#, #""workingRules": 42"#,
                    #""workingRulesEnabled": [true], "workingRules": {"a": 1}"#] {
            let config = try load(#"""
            {"assistant": {"rewrite": {
              "enabled": false,
              "styles": ["concise"],
              \#(bad)
            }}}
            """#)
            XCTAssertFalse(config.assistant.rewrite.enabled, "the value: \(bad)")
            XCTAssertEqual(config.assistant.rewrite.styles, [.concise], "the value: \(bad)")
            XCTAssertFalse(
                config.assistant.rewrite.standingRulesEnabled,
                "a value this build cannot read turned the block on: \(bad)"
            )
            XCTAssertEqual(
                config.assistant.rewrite.standingRules,
                "",
                "a value this build cannot read became a block: \(bad)"
            )
            XCTAssertNil(
                config.assistant.rewrite.builtInInstructions["prompt"],
                "a value this build cannot read became a prompt edit: \(bad)"
            )
        }
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
          "custom": [{"id": "haiku", "title": "Haiku", "instruction": "Rewrite as a haiku."}]
        }}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertFalse(rewrite.enabled, "the switch the person turned off is still off")
        XCTAssertEqual(
            rewrite.styles,
            [.formal, .prompt, .concise, .casual],
            "the order the person kept, with the retired ids read as the styles that absorbed them"
        )
        XCTAssertEqual(rewrite.custom.map(\.id), ["haiku"])
        XCTAssertEqual(rewrite.choices.map(\.id), ["formal", "prompt", "concise", "casual", "haiku"])
    }

    /// A legacy list consolidated into the shipped styles keeps its order and
    /// its distinct choices.
    ///
    /// A file written before the consolidation names six ids, two of which are
    /// now offered by a style that absorbed them. Decoding maps each retired id
    /// onto its style and drops the repeats, so the chips show four styles in
    /// the order the person kept rather than an empty row or a duplicate.
    func testALegacyStyleListDecodesToTheConsolidatedStyles() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {
          "styles": ["prompt", "concise", "plain", "casual", "formal", "warm"]
        }}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertEqual(rewrite.styles, [.prompt, .concise, .casual, .formal])
        XCTAssertEqual(
            rewrite.styles.count,
            Set(rewrite.styles).count,
            "the migration left a duplicate"
        )
        XCTAssertEqual(
            rewrite.choices.map(\.title),
            ["Agent prompt", "Concise", "Casual", "Professional"]
        )
    }

    /// A retired style is available to a file that names it, never added to one
    /// that does not.
    ///
    /// The stored list is the record of what the person chose. Appending a
    /// style here would rewrite that choice on every launch and change the
    /// order a file carried; the id is stable instead, so the page can show the
    /// switch and the person can turn it on.
    func testARetiredStyleIsNotSilentlyAddedToAList() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {"styles": ["prompt", "concise", "formal"]}}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertTrue(RewriteStyleID.allCases.contains(.warm), "the retired style is in this build")
        XCTAssertTrue(RewriteStyleID.shippedCases.contains(.casual), "the style is in this build")
        XCTAssertEqual(rewrite.styles, [.prompt, .concise, .formal])
        XCTAssertEqual(rewrite.choices.map(\.id), ["prompt", "concise", "formal"])
    }

    /// The raw values are the contract with a stored file.
    func testEveryStyleHasAStableRawValue() {
        XCTAssertEqual(
            RewriteStyleID.allCases.map(\.rawValue),
            ["prompt", "concise", "plain", "casual", "formal", "warm", "gen-z"]
        )
        XCTAssertEqual(RewriteStyleID(rawValue: "warm"), .warm)
        XCTAssertEqual(RewriteStyleID(rawValue: "gen-z"), .genZ)
    }
}

extension RewriteConfigurationTests {
    // MARK: - Instructions the person edited

    private func rewritePayload(of config: DotConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(config)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let assistant = try XCTUnwrap(payload?["assistant"] as? [String: Any])
        return try XCTUnwrap(assistant["rewrite"] as? [String: Any])
    }

    /// A file written before the field existed keeps every shipped instruction.
    func testAFileWithoutInstructionsKeepsEveryShippedTemplate() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {"styles": ["concise"]}}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertEqual(rewrite.builtInInstructions, [:])
        for id in RewriteStyleID.allCases {
            XCTAssertEqual(rewrite.instruction(for: id), id.template, id.rawValue)
        }
        for id in rewrite.styles {
            XCTAssertEqual(
                rewrite.choices.first { $0.id == id.rawValue }?.instruction,
                id.template,
                id.rawValue
            )
        }
        XCTAssertEqual(rewrite.styles, [.concise], "the rest of the block survived")
    }

    /// The edited instruction is stored per style and comes back with the file.
    func testEachEditedInstructionRoundTripsBesideTheCustomStyles() throws {
        var config = DotConfig.default
        config.assistant.rewrite.custom = [
            CustomRewriteStyle(id: "haiku", title: "Haiku", instruction: "Rewrite as a haiku."),
        ]
        config.assistant.rewrite.setInstruction("Write the task as a checklist.", for: .prompt)
        config.assistant.rewrite.setInstruction("Be brief.", for: .concise)

        let restored = try JSONDecoder().decode(DotConfig.self, from: JSONEncoder().encode(config))
        let rewrite = restored.assistant.rewrite
        XCTAssertEqual(rewrite, config.assistant.rewrite)
        XCTAssertEqual(rewrite.builtInInstructions, [
            "prompt": "Write the task as a checklist.",
            "concise": "Be brief.",
        ])
        XCTAssertEqual(rewrite.instruction(for: .prompt), "Write the task as a checklist.")
        XCTAssertEqual(rewrite.instruction(for: .concise), "Be brief.")
        XCTAssertEqual(rewrite.instruction(for: .plain), RewriteStyleID.plain.template)
        XCTAssertEqual(rewrite.choices.first { $0.id == "prompt" }?.instruction, "Write the task as a checklist.")
        XCTAssertEqual(rewrite.custom.map(\.id), ["haiku"], "the stored custom style was not touched")
        XCTAssertEqual(rewrite.custom.first?.instruction, "Rewrite as a haiku.")
    }

    /// Removing one edit restores that template and nothing else.
    func testEachInstructionCanBeResetWithoutTouchingTheOthers() {
        var rewrite = RewriteConfiguration.default
        rewrite.setInstruction("One.", for: .prompt)
        rewrite.setInstruction("Two.", for: .concise)
        rewrite.setInstruction(nil, for: .prompt)
        XCTAssertEqual(rewrite.builtInInstructions, ["concise": "Two."])
        XCTAssertEqual(rewrite.instruction(for: .prompt), RewriteStyleID.prompt.template)
        XCTAssertEqual(rewrite.instruction(for: .concise), "Two.")
        XCTAssertEqual(
            rewrite.choices.first { $0.id == "prompt" }?.instruction,
            RewriteStyleID.prompt.template
        )
    }

    /// Empty, malformed and unknown entries leave every other value alone.
    ///
    /// An empty value is what a field holds while it is being cleared, so it is
    /// kept and falls back when it is used. A value that is not text cannot be
    /// kept as an instruction. A key this build does not know is kept, which is
    /// what lets a newer build's style survive a save from this one.
    func testEmptyMalformedAndUnknownEntriesLeaveTheRestAlone() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {
          "enabled": false,
          "styles": ["prompt", "concise", "plain", "formal"],
          "builtInInstructions": {
            "prompt": "",
            "concise": "   ",
            "plain": "Say it plainly and once.",
            "formal": 42,
            "casual": ["not", "text"],
            "shout": "Write it in capitals.",
            "warm": null
          }
        }}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertEqual(rewrite.builtInInstructions, [
            "prompt": "",
            "concise": "   ",
            "plain": "Say it plainly and once.",
            "shout": "Write it in capitals.",
        ])
        XCTAssertEqual(rewrite.instruction(for: .prompt), RewriteStyleID.prompt.template)
        XCTAssertEqual(rewrite.instruction(for: .concise), RewriteStyleID.concise.template)
        XCTAssertEqual(rewrite.instruction(for: .plain), "Say it plainly and once.")
        XCTAssertEqual(rewrite.instruction(for: .formal), RewriteStyleID.formal.template)
        XCTAssertEqual(rewrite.instruction(for: .casual), RewriteStyleID.casual.template)
        XCTAssertFalse(rewrite.enabled, "the neighbour fields survived the bad entries")
        XCTAssertEqual(rewrite.styles, [.prompt, .concise, .formal])

        let restored = try JSONDecoder().decode(DotConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.assistant.rewrite, rewrite)
        XCTAssertEqual(
            restored.assistant.rewrite.builtInInstructions["shout"],
            "Write it in capitals.",
            "a key this build does not know survives a save"
        )
    }

    /// A field that is not an object resets on its own.
    func testAMalformedInstructionMapResetsOnlyThatField() throws {
        for bad in ["42", "\"text\"", "[\"prompt\"]", "null"] {
            let config = try load(#"""
            {"assistant": {"rewrite": {
              "enabled": false,
              "styles": ["plain", "formal"],
              "builtInInstructions": \#(bad)
            }}}
            """#)
            let rewrite = config.assistant.rewrite
            XCTAssertEqual(rewrite.builtInInstructions, [:], "the value: \(bad)")
            XCTAssertFalse(rewrite.enabled, "the value: \(bad)")
            XCTAssertEqual(rewrite.styles, [.concise, .formal], "the value: \(bad)")
            XCTAssertEqual(rewrite.instruction(for: .plain), RewriteStyleID.plain.template, "the value: \(bad)")
        }
    }

    /// The map is written only when someone edited a style.
    func testTheInstructionMapIsWrittenOnlyWhenItHasAnEdit() throws {
        var config = DotConfig.default
        XCTAssertNil(try rewritePayload(of: config)["builtInInstructions"])

        config.assistant.rewrite.setInstruction("Mine.", for: .prompt)
        let map = try XCTUnwrap(try rewritePayload(of: config)["builtInInstructions"] as? [String: String])
        XCTAssertEqual(map, ["prompt": "Mine."])
    }

    /// An empty edit is held for the field being cleared and falls back at use.
    func testAnEmptyEditIsKeptAndFallsBackToTheTemplate() throws {
        var config = DotConfig.default
        config.assistant.rewrite.setInstruction("", for: .prompt)
        XCTAssertEqual(config.assistant.rewrite.builtInInstructions, ["prompt": ""])
        XCTAssertEqual(
            config.assistant.rewrite.instruction(for: .prompt),
            RewriteStyleID.prompt.template
        )
        let restored = try JSONDecoder().decode(DotConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.assistant.rewrite.builtInInstructions, ["prompt": ""])
    }

    /// The boundary is allowed exactly and everything past it is cut.
    func testInstructionsAreCappedAtTheSharedLimit() throws {
        XCTAssertEqual(RewriteConfiguration.maximumBuiltInInstructionLength, 4_000)
        let exact = String(repeating: "a", count: RewriteConfiguration.maximumBuiltInInstructionLength)

        var rewrite = RewriteConfiguration.default
        rewrite.setInstruction(exact, for: .prompt)
        XCTAssertEqual(rewrite.builtInInstructions["prompt"], exact, "the boundary itself is allowed")
        rewrite.setInstruction(exact + "b", for: .concise)
        XCTAssertEqual(rewrite.builtInInstructions["concise"], exact)

        let tooLong = exact + "tail"
        let config = try load(#"""
        {"assistant": {"rewrite": {"builtInInstructions": {"plain": "\#(tooLong)"}}}}
        """#)
        XCTAssertEqual(config.assistant.rewrite.instruction(for: .plain), exact, "the read is capped")

        let built = RewriteConfiguration(builtInInstructions: ["formal": tooLong])
        XCTAssertEqual(built.instruction(for: .formal), exact, "the initializer is capped")
    }

    /// A chip carries the edit and nothing else of its style changes.
    func testAChoiceKeepsItsIdentityAndCarriesOnlyTheInstruction() {
        var rewrite = RewriteConfiguration.default
        rewrite.setInstruction("Write a checklist.", for: .prompt)
        rewrite.setInstruction("Two lines at most.", for: .formal)

        let prompt = rewrite.choices.first { $0.id == "prompt" }
        XCTAssertEqual(prompt?.kind, .builtIn(.prompt))
        XCTAssertEqual(prompt?.title, "Agent prompt")
        XCTAssertEqual(prompt?.instruction, "Write a checklist.")
        XCTAssertEqual(prompt?.lengthRatio, RewriteStyleID.prompt.lengthRatio)
        XCTAssertEqual(prompt?.checksNames, RewriteStyleID.prompt.checksNames)

        let formal = rewrite.choices.first { $0.id == "formal" }
        XCTAssertEqual(formal?.kind, .builtIn(.formal))
        XCTAssertEqual(formal?.title, "Professional")
        XCTAssertEqual(formal?.instruction, "Two lines at most.")

        for id in RewriteStyleID.shippedCases where id != .prompt && id != .formal {
            XCTAssertEqual(
                rewrite.choices.first { $0.id == id.rawValue }?.instruction,
                id.template,
                "\(id.rawValue) kept its shipped instruction"
            )
        }
        XCTAssertEqual(rewrite.style(for: "prompt")?.instruction, "Write a checklist.")
        XCTAssertEqual(rewrite.style(for: "prompt")?.title, "Agent prompt")
    }

    /// Editing an instruction is not a style decision.
    func testAnEditDoesNotChangeTheStoredStylesOrTheirOrder() {
        var rewrite = RewriteConfiguration.default
        rewrite.setInstruction("Mine.", for: .concise)
        XCTAssertEqual(rewrite.styles, RewriteStyleID.shippedCases)
        XCTAssertEqual(
            rewrite.choices.map(\.id),
            ["prompt", "concise", "formal", "casual", "gen-z"]
        )
        XCTAssertEqual(
            rewrite.choices.map(\.title),
            ["Agent prompt", "Concise", "Professional", "Casual", "Gen Z"]
        )
    }
}

extension RewriteConfigurationTests {
    // MARK: - Removing a shipped style

    /// A shipped style can be removed, and the removal is what the chips and
    /// the file both follow.
    func testABuiltInStyleCanBeDeleted() {
        var rewrite = RewriteConfiguration.default
        rewrite.setInstruction("Say it simply.", for: .casual)
        rewrite.deleteBuiltIn(.casual)

        XCTAssertEqual(rewrite.deletedBuiltIns, [.casual])
        XCTAssertFalse(rewrite.visibleBuiltIns.contains(.casual))
        XCTAssertFalse(rewrite.styles.contains(.casual))
        XCTAssertNil(
            rewrite.builtInInstructions["casual"],
            "deleting a style kept the edit it carried"
        )
        XCTAssertEqual(
            rewrite.choices.map(\.id),
            ["prompt", "concise", "formal", "gen-z"],
            "a removed style is still offered"
        )
        XCTAssertEqual(
            rewrite.instruction(for: .casual),
            RewriteStyleID.casual.template,
            "the edit outlived the style"
        )
    }

    /// The removal is written under its own key and comes back with the file.
    func testADeletedStyleStaysDeletedAcrossAFile() throws {
        var config = DotConfig.default
        config.assistant.rewrite.deleteBuiltIn(.formal)
        config.assistant.rewrite.deleteBuiltIn(.prompt)
        config.assistant.rewrite.deleteBuiltIn(.formal)

        let payload = try rewritePayload(of: config)
        XCTAssertEqual(payload["deletedBuiltIns"] as? [String], ["prompt", "formal"])
        XCTAssertEqual(
            payload["styles"] as? [String],
            ["concise", "casual", "gen-z"],
            "the removed styles are still in the stored list"
        )

        let restored = try JSONDecoder().decode(DotConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.assistant.rewrite.deletedBuiltIns, [.prompt, .formal])
        XCTAssertEqual(restored.assistant.rewrite.visibleBuiltIns, [.concise, .casual, .genZ])
        XCTAssertEqual(restored.assistant.rewrite.choices.map(\.id), ["concise", "casual", "gen-z"])
        XCTAssertEqual(restored.assistant.rewrite, config.assistant.rewrite)
    }

    /// A list that still names a removed style cannot bring it back.
    func testARemovedStyleIsFilteredOutOfAStoredList() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {
          "styles": ["prompt", "concise", "professional", "casual", "formal", "gen-z"],
          "deletedBuiltIns": ["casual", "gen-z"]
        }}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertEqual(rewrite.deletedBuiltIns, [.casual, .genZ])
        XCTAssertEqual(rewrite.styles, [.prompt, .concise, .formal])
        XCTAssertEqual(rewrite.choices.map(\.id), ["prompt", "concise", "formal"])
    }

    /// Removing every style leaves nothing to offer, and a restore puts the
    /// shipped five back in the build's order with their shipped templates.
    func testRemovingEveryStyleAndRestoringIt() {
        var rewrite = RewriteConfiguration.default
        rewrite.setInstruction("Mine.", for: .prompt)
        for id in RewriteStyleID.shippedCases {
            rewrite.deleteBuiltIn(id)
        }
        XCTAssertEqual(rewrite.visibleBuiltIns, [])
        XCTAssertEqual(rewrite.choices, [], "a page with no styles still offered one")
        XCTAssertEqual(rewrite.builtInInstructions, [:], "a deleted style kept its edit")

        rewrite.restoreBuiltIns()
        XCTAssertEqual(rewrite.deletedBuiltIns, [])
        XCTAssertEqual(rewrite.visibleBuiltIns, RewriteStyleID.shippedCases)
        XCTAssertEqual(rewrite.styles, RewriteStyleID.shippedCases)
        XCTAssertEqual(
            rewrite.choices.map(\.title),
            ["Agent prompt", "Concise", "Professional", "Casual", "Gen Z"]
        )
        XCTAssertEqual(
            rewrite.instruction(for: .prompt),
            RewriteStyleID.prompt.template,
            "a restore brought back an edit from before the removal"
        )
    }

    /// A restore puts back only what was removed, in the build's order, and
    /// keeps a retired id the record still carries.
    ///
    /// A file's retired ids are read as the styles that absorbed them, so this
    /// record is built in code: it is what a caller that kept an old id looks
    /// like, and a restore must not drop it.
    func testARestoreKeepsALegacyStyleInTheRecord() {
        var rewrite = RewriteConfiguration(styles: [.warm], deletedBuiltIns: [.formal])
        XCTAssertEqual(rewrite.styles, [.warm])
        rewrite.restoreBuiltIns()
        XCTAssertEqual(rewrite.styles, [.formal, .warm])
        XCTAssertEqual(rewrite.deletedBuiltIns, [])
        XCTAssertEqual(Set(rewrite.styles).count, rewrite.styles.count)
        XCTAssertEqual(
            rewrite.style(for: "warm")?.title,
            "Warm",
            "the restore dropped a style the record still carried"
        )
    }

    /// The removed ids are read the tolerant way the rest of the block is.
    func testDeletedIdsAreReadTolerantly() throws {
        let config = try load(#"""
        {"assistant": {"rewrite": {
          "enabled": false,
          "styles": ["concise"],
          "deletedBuiltIns": ["plain", "warm", "casual", "shout", 42, "concise"]
        }}}
        """#)
        let rewrite = config.assistant.rewrite
        XCTAssertEqual(
            rewrite.deletedBuiltIns,
            [.concise, .formal, .casual],
            "the retired ids were read as the styles that absorbed them, without a repeat"
        )
        XCTAssertEqual(rewrite.styles, [], "the deleted style stayed in the stored list")
        XCTAssertEqual(rewrite.choices, [])
        XCTAssertFalse(rewrite.enabled, "the neighbour field survived")

        for bad in ["42", "\"casual\"", "[1, 2]", "null"] {
            let broken = try load(#"""
            {"assistant": {"rewrite": {
              "enabled": false,
              "styles": ["prompt", "concise"],
              "deletedBuiltIns": \#(bad)
            }}}
            """#)
            XCTAssertEqual(broken.assistant.rewrite.deletedBuiltIns, [], "the value: \(bad)")
            XCTAssertEqual(broken.assistant.rewrite.styles, [.prompt, .concise], "the value: \(bad)")
            XCTAssertFalse(broken.assistant.rewrite.enabled, "the value: \(bad)")
        }
    }

    /// The key is absent until a style is removed.
    func testTheDeletedListIsWrittenOnlyWhenItHasAnId() throws {
        var config = DotConfig.default
        XCTAssertNil(try rewritePayload(of: config)["deletedBuiltIns"])
        config.assistant.rewrite.deleteBuiltIn(.genZ)
        XCTAssertEqual(
            try rewritePayload(of: config)["deletedBuiltIns"] as? [String],
            ["gen-z"]
        )
        config.assistant.rewrite.restoreBuiltIns()
        XCTAssertNil(try rewritePayload(of: config)["deletedBuiltIns"])
    }

    /// Deleting a style twice records it once.
    func testDeletingTheSameStyleTwiceRecordsItOnce() {
        var rewrite = RewriteConfiguration.default
        rewrite.deleteBuiltIn(.casual)
        rewrite.deleteBuiltIn(.casual)
        XCTAssertEqual(rewrite.deletedBuiltIns, [.casual])
        XCTAssertEqual(rewrite.visibleBuiltIns.count, RewriteStyleID.shippedCases.count - 1)
    }

    /// Removing a style does not touch the person's own styles.
    func testRemovingABuiltInLeavesTheCustomStylesAlone() {
        var rewrite = RewriteConfiguration.default
        rewrite.custom = [
            CustomRewriteStyle(id: "haiku", title: "Haiku", instruction: "Rewrite as a haiku."),
        ]
        rewrite.deleteBuiltIn(.concise)
        XCTAssertEqual(rewrite.custom.map(\.id), ["haiku"])
        XCTAssertEqual(rewrite.choices.map(\.id), ["prompt", "formal", "casual", "gen-z", "haiku"])
    }
}
