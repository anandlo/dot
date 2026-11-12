import XCTest

@testable import DotCore

/// The styles Dot ships, as data.
///
/// The templates are the feature's prompt: a reworded sentence changes what the
/// model is asked for, so every one of them is compared against the sentence it
/// was specified with rather than against its own source.
final class RewriteStyleTests: XCTestCase {
    func testThePromptTemplateIsTheSpecifiedTaskBrief() {
        XCTAssertEqual(RewriteStyleID.prompt.template, """
        You turn a developer's spoken request into a precise task prompt for an AI coding agent.
        Rules:
        - Use only what the speaker said. Keep every name, file, path, number, library, version, command and constraint exactly as said.
        - Do not add requirements, features, steps, tools, libraries or opinions the speaker did not state.
        - Where the speaker corrected themselves, keep only the final intent. Drop filler and repetition.
        - Write in the imperative, plainly, as a senior engineer briefing another engineer.
        Output these sections, in this order, as Markdown headings. Leave out a section only when the speaker said nothing for it, except Goal, which is always present:
        ## Goal
        One or two sentences.
        ## Context
        The facts the speaker gave: current behaviour, files, errors, environment.
        ## Requirements
        A numbered list, one testable requirement per line, only as stated.
        ## Constraints
        What must not change or must be respected, only as stated.
        ## Done when
        The checks that show the task is complete, taken from what was said. If none were said, write: [missing: how to verify]
        ## Open questions
        Each detail the task needs that was not said, written as [missing: what]. Leave the section out if there are none.
        Output only the prompt.
        """)
    }

    func testThePromptTemplateAsksForTheSixSectionsInOrder() {
        let template = RewriteStyleID.prompt.template
        let headings = ["## Goal", "## Context", "## Requirements", "## Constraints",
                        "## Done when", "## Open questions"]
        var searchStart = template.startIndex
        for heading in headings {
            guard let range = template.range(of: heading, range: searchStart ..< template.endIndex)
            else {
                XCTFail("\(heading) is missing or out of order")
                return
            }
            searchStart = range.upperBound
        }
        XCTAssertTrue(template.hasSuffix("Output only the prompt."))
        XCTAssertTrue(template.contains("[missing: how to verify]"))
        XCTAssertTrue(template.contains("[missing: what]"))
    }

    func testTheTemplatesAreTheSpecifiedSentences() {
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
        Rewrite in a casual, conversational Gen Z register, the way a friend texts: short \
        sentences, contractions, everyday words, lowercase is fine, light slang only where it \
        sounds natural. Keep every fact, name, number and negation. Do not add emoji unless the \
        original had them. Do not add or remove content. Output only the rewrite.
        """)
        XCTAssertEqual(RewriteStyleID.formal.template, """
        Rewrite in a clear, formal register suitable for work email. Keep every fact, name, \
        number and negation. Do not add or remove content. Output only the rewrite.
        """)
    }

    func testTheChipLabelsAreTheSpecifiedWords() {
        XCTAssertEqual(RewriteStyleID.allCases.map(\.title), [
            "Agent prompt", "Concise", "Plain English", "Casual", "Formal",
        ])
    }

    func testTheSettingsSentenceOfEveryStyleIsOneSentence() {
        // A single sentence ends with one full stop and has no second one.
        for style in RewriteStyleID.allCases {
            XCTAssertEqual(
                style.subtitle.filter { $0 == "." }.count,
                1,
                "\(style.rawValue) has a second sentence: \(style.subtitle)"
            )
            XCTAssertTrue(style.subtitle.hasSuffix("."), style.rawValue)
        }
    }

    func testNoSettingsSentenceCarriesALineBreak() {
        // The row wraps a subtitle where the row's width ends, not where the
        // sentence was broken by hand: a stored break shortened the line to a
        // fragment of the space the row has.
        for style in RewriteStyleID.allCases {
            XCTAssertFalse(style.subtitle.contains("\n"), style.rawValue)
        }
    }

    func testNoTemplateLineIsIndented() {
        // The template is sent as written: a line that kept the source's own
        // indentation would put spaces inside a heading or a bullet.
        for style in RewriteStyleID.allCases {
            for line in style.template.split(separator: "\n", omittingEmptySubsequences: false) {
                XCTAssertNotEqual(line.first, " ", "\(style.rawValue) is indented: \(line)")
            }
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
