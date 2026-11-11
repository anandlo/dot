import XCTest

@testable import DotCore

/// The styles Dot ships, as data.
///
/// The templates are the feature's prompt: a reworded sentence changes what the
/// model is asked for, so every one of them is compared against the sentence it
/// was specified with rather than against its own source.
final class RewriteStyleTests: XCTestCase {
    func testTheTemplatesAreTheSpecifiedSentences() {
        XCTAssertEqual(RewriteStyleID.prompt.template, """
        Rewrite the spoken request as an instruction for a coding agent. Keep every fact, name, \
        path, number, library and constraint the speaker said. Do not add requirements, steps, \
        tools or libraries that were not said. Use this shape: Goal, Context, Constraints, Done \
        when. If a required detail was not said, write [missing: what] instead of inventing it. \
        Output only the rewritten instruction.
        """)
        XCTAssertEqual(RewriteStyleID.concise.template, """
        Rewrite the transcript more concisely. Keep every fact, name, number, negation and \
        qualifier. Remove filler, repetition and hesitation. Do not add anything. Aim for 50 to \
        70 percent of the original length. Output only the rewrite.
        """)
        XCTAssertEqual(RewriteStyleID.plain.template, """
        Rewrite in plain English. Prefer short common words and the active voice. Keep technical \
        terms that have no plain equivalent. Do not explain, summarise or add examples. Output \
        only the rewrite.
        """)
        XCTAssertEqual(RewriteStyleID.casual.template, """
        Rewrite in a relaxed texting register, the way a Gen Z friend would write it: short \
        sentences, contractions, lowercase is fine. Keep every fact, name, number and negation. \
        Do not add emoji unless the original had them. Do not add or remove content. Output only \
        the rewrite.
        """)
        XCTAssertEqual(RewriteStyleID.formal.template, """
        Rewrite in a clear, formal register suitable for work email. Keep every fact, name, \
        number and negation. Do not add or remove content. Output only the rewrite.
        """)
    }

    func testTheChipLabelsAreTheSpecifiedWords() {
        XCTAssertEqual(RewriteStyleID.allCases.map(\.title), [
            "Prompt", "Concise", "Plain English", "Casual", "Formal",
        ])
    }

    func testTheSettingsSentenceOfEveryStyleIsOneSentence() {
        // A single sentence ends with one full stop and has no second one.
        for style in RewriteStyleID.allCases {
            let subtitle = style.subtitle.replacingOccurrences(of: "\n", with: " ")
            XCTAssertEqual(
                subtitle.filter { $0 == "." }.count,
                1,
                "\(style.rawValue) has a second sentence: \(subtitle)"
            )
            XCTAssertTrue(subtitle.hasSuffix("."), style.rawValue)
        }
    }

    func testOnlyTheLongDescriptionsWrap() {
        let wrapped = RewriteStyleID.allCases.filter(\.wrapsSubtitle)
        XCTAssertEqual(wrapped, [.prompt, .concise, .casual, .formal])
        XCTAssertFalse(RewriteStyleID.plain.wrapsSubtitle)
        for style in wrapped {
            XCTAssertTrue(style.subtitle.contains("\n"), style.rawValue)
            XCTAssertEqual(style.subtitle.split(separator: "\n").count, 2, style.rawValue)
        }
    }

    func testTheLengthBandsAreTheSpecifiedOnes() {
        XCTAssertEqual(RewriteStyleID.prompt.lengthRatio, 0.8 ... 3.0)
        XCTAssertEqual(RewriteStyleID.concise.lengthRatio, 0.35 ... 0.85)
        XCTAssertEqual(RewriteStyleID.plain.lengthRatio, 0.5 ... 1.3)
        XCTAssertEqual(RewriteStyleID.casual.lengthRatio, 0.5 ... 1.3)
        XCTAssertEqual(RewriteStyleID.formal.lengthRatio, 0.7 ... 1.5)
        XCTAssertEqual(CustomRewriteStyle.lengthRatio, 0.3 ... 3.0)
    }

    func testOnlyThePromptStyleSkipsTheNameCheck() {
        XCTAssertFalse(RewriteStyleID.prompt.checksNames)
        for style in RewriteStyleID.allCases where style != .prompt {
            XCTAssertTrue(style.checksNames, style.rawValue)
        }
        XCTAssertTrue(RewriteStyle(CustomRewriteStyle(title: "Mine", instruction: "x")).checksNames)
    }

    func testACustomInstructionCarriesTheFixedSuffix() {
        let custom = CustomRewriteStyle(title: "Mine", instruction: "  Rewrite as a haiku.  ")
        XCTAssertEqual(custom.wrappedInstruction, """
        Rewrite as a haiku. Keep every fact, name, number and negation. Do not add anything that \
        was not said. Output only the rewrite.
        """)
        XCTAssertTrue(custom.wrappedInstruction.hasSuffix(CustomRewriteStyle.suffix))
        XCTAssertFalse(custom.wrappedInstruction.contains("  "))
    }

    func testTheBuiltInChoicesAreInTheShippedOrder() {
        XCTAssertEqual(RewriteStyle.builtIns.map(\.id), ["prompt", "concise", "plain", "casual", "formal"])
        XCTAssertEqual(RewriteStyle.concise.title, "Concise")
        XCTAssertEqual(RewriteStyle(.casual).id, "casual")
        XCTAssertEqual(RewriteStyle(.formal).kind, .builtIn(.formal))
    }
}
