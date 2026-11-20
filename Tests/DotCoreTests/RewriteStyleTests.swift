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
        - Use only what the speaker said. Keep every name, file, path, library, version, command and constraint, and every meaningful number.
        - Add nothing the speaker did not say: no requirements, features, steps, checks, tools, libraries, rules, placeholders, questions or opinions.
        - Where the speaker corrected themselves, keep only the final intent. Drop filler and repetition.
        - Write plainly, as a senior engineer briefing another engineer. Use the imperative only for what the speaker asked to be done.
        Output these sections, in this order, as Markdown headings. Goal is always present. Every other section appears only when the speaker said something for it; never write a section to say it is empty.
        ## Goal
        One or two sentences stating what the speaker asked for. If they asked for nothing, state what they reported and do not turn it into a request.
        ## Context
        The facts the speaker gave: current behaviour, files, errors, environment.
        ## Requirements
        A numbered list, one requirement per line, only as stated.
        ## Constraints
        What must not change or must be respected, only as stated.
        ## Done when
        The checks the speaker named for knowing the task is complete.
        Output only the prompt.
        """)
    }

    func testThePromptTemplateAsksForTheFiveSectionsInOrder() {
        let template = RewriteStyleID.prompt.template
        let headings = ["## Goal", "## Context", "## Requirements", "## Constraints",
                        "## Done when"]
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
        // Goal is the one section that is always written; every other one is
        // drawn only when the speaker gave something for it.
        XCTAssertTrue(template.contains("Goal is always present."))
        XCTAssertTrue(
            template.contains("never write a section to say it is empty"),
            "the template still asks for a section that names what is missing"
        )
        for retired in ["[missing", "## Open questions", "## Working rules"] {
            XCTAssertFalse(template.contains(retired), "the template still asks for: \(retired)")
        }
    }

    func testTheTemplatesAreTheSpecifiedSentences() {
        XCTAssertEqual(RewriteStyleID.concise.template, """
        Rewrite the transcript more concisely in plain, direct language. Prefer short common \
        words and the active voice, while keeping technical terms that have no plain \
        equivalent. Keep every fact, name, negation and qualifier, and every meaningful number. \
        Remove filler, repetition and hesitation. Do not add anything. Aim for 50 to 70 percent \
        of the original length. Output only the rewrite.
        """)
        XCTAssertEqual(RewriteStyleID.plain.template, """
        Rewrite in plain English. Prefer short common words and the active voice. Keep technical \
        terms that have no plain equivalent. Do not explain, summarise or add examples. Output \
        only the rewrite.
        """)
        XCTAssertEqual(RewriteStyleID.casual.template, """
        Rewrite in the casual, conversational register of an everyday personal message or DM. \
        Use natural contractions and plain, common words, in short sentences. Do not add an \
        email greeting, sign-off or heading unless the original needs one, and do not force \
        slang or emoji. Keep every fact, name and negation, and every meaningful number. Do not \
        add content or remove anything the speaker meant. Output only the rewrite.
        """)
        XCTAssertEqual(RewriteStyleID.formal.template, """
        Rewrite in a clear, respectful, professional register suitable for work. Be direct and \
        constructive, using plain words and the active voice. Keep every fact, name and \
        negation, and every meaningful number. Remove filler, hedging and repetition. Do not \
        add praise, apologies, thanks or any detail that was not said. Output only the rewrite.
        """)
        XCTAssertEqual(RewriteStyleID.warm.template, """
        Rewrite in a warm, respectful, direct register. Sound like a considerate colleague: \
        friendly without being chummy, certain without being blunt. Address the reader as you, \
        use plain words and the active voice. Keep every fact, name and negation, and every \
        meaningful number. Remove filler, hedging and repetition, so each point is said once. \
        Do not add praise, apologies, thanks, promises, opinions or any detail that was not \
        said. Do not soften a refusal, a deadline or a condition. Output only the rewrite.
        """)
        XCTAssertEqual(RewriteStyleID.genZ.template, """
        Rewrite in a casual, conversational Gen Z register, the way a friend texts: short \
        sentences, contractions, everyday words, lowercase is fine, light slang only where it \
        sounds natural. Keep every fact, name and negation, and every meaningful number. Do not \
        add emoji unless the original had them. Do not add content or remove anything the \
        speaker meant. Output only the rewrite.
        """)
    }

    /// The five styles this build offers are the ones a fresh file carries.
    ///
    /// Concise absorbed Plain English, and Professional absorbed Formal and
    /// Warm, so each shipped choice does a different job, and Casual and Gen Z
    /// are two registers rather than one: plain English, and the texting voice
    /// with its slang. The retired ids stay decodable, which is why they are not
    /// part of this list.
    func testTheShippedCasesAreTheFiveDistinctStyles() {
        XCTAssertEqual(
            RewriteStyleID.shippedCases,
            [.prompt, .concise, .formal, .casual, .genZ]
        )
        XCTAssertEqual(
            RewriteStyleID.shippedCases.map(\.title),
            ["Agent prompt", "Concise", "Professional", "Casual", "Gen Z"]
        )
        XCTAssertEqual(
            RewriteStyleID.shippedCases.map(\.subtitle),
            [
                "Turns what you said into a structured task for a coding agent, adding nothing.",
                "Shorter and plain, with every fact kept.",
                "Clear, direct, and respectful for work.",
                "Natural, everyday chat messages and DMs.",
                "Casual Gen Z texting style with light natural slang.",
            ]
        )
        for id in [RewriteStyleID.plain, .warm] {
            XCTAssertFalse(
                RewriteStyleID.shippedCases.contains(id),
                "\(id.rawValue) is offered beside the style that absorbed it"
            )
            XCTAssertTrue(RewriteStyleID.allCases.contains(id), "\(id.rawValue) no longer decodes")
        }
        XCTAssertEqual(RewriteStyleID.genZ.rawValue, "gen-z", "the stored spelling")
        XCTAssertTrue(
            RewriteStyleID.genZ.template.contains("light slang only where it sounds natural")
        )
        XCTAssertFalse(
            RewriteStyleID.casual.template.contains("Gen Z"),
            "the plain conversational style still asks for slang"
        )
    }

    /// The warm style is asked for the same facts-first rewrite as every other.
    ///
    /// The register changes; the data sentence does not. A style that invited
    /// the model to fill a gap would be a style the faithfulness check has to
    /// catch after the fact, and the check cannot see a plausible invention.
    func testTheWarmTemplateKeepsEveryFactAndInventsNothing() {
        let template = RewriteStyleID.warm.template
        for rule in [
            "Keep every fact, name and negation, and every meaningful number",
            "Do not add praise, apologies, thanks, promises, opinions or any detail that was not said",
            "each point is said once",
            "Output only the rewrite.",
        ] {
            XCTAssertTrue(template.contains(rule), "the warm prompt lost: \(rule)")
        }
        XCTAssertTrue(template.contains("warm, respectful, direct"))
        XCTAssertFalse(template.contains("You are a"), "the template speaks as an instruction, not a persona")
        XCTAssertEqual(template.filter { $0 == "\n" }.count, 0, "the warm instruction is one paragraph")
    }

    /// Casual is everyday chat, not a work email.
    ///
    /// It asks for a personal message or DM, keeps contractions, refuses an
    /// added greeting or sign-off, and does not force slang: that is what makes
    /// it a register of its own rather than a milder Gen Z.
    func testTheCasualTemplateAsksForEverydayChatWithoutForcedSlang() {
        let template = RewriteStyleID.casual.template
        for phrase in [
            "casual, conversational register",
            "everyday personal message or DM",
            "natural contractions",
            "Do not add an email greeting, sign-off or heading unless the original needs one",
            "do not force slang or emoji",
            "Output only the rewrite.",
        ] {
            XCTAssertTrue(template.contains(phrase), "the casual prompt lost: \(phrase)")
        }
        XCTAssertFalse(template.contains("Gen Z"), "casual is not the Gen Z register")
        XCTAssertFalse(template.contains("light slang"), "casual does not ask for slang")
        XCTAssertEqual(
            template.filter { $0 == "\n" }.count,
            0,
            "the casual instruction is one paragraph"
        )
    }

    /// Only numbers are qualified: facts, names and negations are kept whole.
    ///
    /// The shared cleanup sentence is what allows a clear misrecognition to be
    /// repaired. A template that said "meaningful fact" would license dropping
    /// a fact the speaker meant, which is the failure a rewrite must not have.
    func testNoTemplateQualifiesFactsNamesOrNegationsAsMeaningful() {
        for id in RewriteStyleID.allCases {
            let template = id.template
            for weakened in ["meaningful fact", "meaningful name", "meaningful negation"] {
                XCTAssertFalse(template.contains(weakened), "\(id.rawValue) weakens: \(weakened)")
            }
            if template.contains("number") {
                XCTAssertTrue(
                    template.contains("meaningful number"),
                    "\(id.rawValue) keeps numbers without saying which ones matter"
                )
            }
            XCTAssertFalse(
                template.contains("Do not add or remove content"),
                "\(id.rawValue) forbids the narrow cleanup"
            )
        }
    }

    /// The shared sentence is Dot's, not part of a template.
    func testNoTemplateRepeatsTheSharedCleanupSentence() {
        for id in RewriteStyleID.allCases {
            XCTAssertFalse(
                id.template.contains(RewritePrompt.transcriptionCleanupInstruction),
                "\(id.rawValue) repeats the cleanup sentence"
            )
        }
    }

    func testTheChipLabelsAreTheSpecifiedWords() {
        XCTAssertEqual(RewriteStyleID.shippedCases.map(\.title), [
            "Agent prompt", "Concise", "Professional", "Casual", "Gen Z",
        ])
        XCTAssertEqual(RewriteStyleID.plain.title, "Plain English", "a retired id keeps its label")
        XCTAssertEqual(RewriteStyleID.warm.title, "Warm")
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
        XCTAssertEqual(RewriteStyleID.genZ.lengthRatio, 0.5 ... 1.3)
        XCTAssertEqual(RewriteStyleID.formal.lengthRatio, 0.7 ... 1.5)
        XCTAssertEqual(RewriteStyleID.warm.lengthRatio, 0.4 ... 1.05)
        XCTAssertLessThanOrEqual(
            RewriteStyleID.warm.lengthRatio.upperBound,
            1.05,
            "a style that says each point once may not reward padding"
        )
        XCTAssertEqual(CustomRewriteStyle.lengthRatio, 0.3 ... 3.0)
    }

    func testOnlyThePromptStyleSkipsTheNameCheck() {
        XCTAssertFalse(RewriteStyleID.prompt.checksNames)
        for style in RewriteStyleID.allCases where style != .prompt {
            XCTAssertTrue(style.checksNames, style.rawValue)
        }
        XCTAssertTrue(RewriteStyleID.warm.checksNames, "a warm rewrite keeps the names it was given")
        XCTAssertTrue(RewriteStyle(CustomRewriteStyle(title: "Mine", instruction: "x")).checksNames)
    }

    func testACustomInstructionCarriesTheFixedSuffix() {
        let custom = CustomRewriteStyle(title: "Mine", instruction: "  Rewrite as a haiku.  ")
        XCTAssertEqual(custom.wrappedInstruction, """
        Rewrite as a haiku. Keep every fact, name and negation, and every meaningful number. Do \
        not add anything that was not said. Output only the rewrite.
        """)
        XCTAssertTrue(custom.wrappedInstruction.hasSuffix(CustomRewriteStyle.suffix))
        XCTAssertFalse(custom.wrappedInstruction.contains("  "))
        XCTAssertEqual(custom.instruction, "  Rewrite as a haiku.  ", "the saved text was changed")
        XCTAssertFalse(CustomRewriteStyle.suffix.contains("meaningful fact"))
        XCTAssertFalse(CustomRewriteStyle.suffix.contains("meaningful name"))
        XCTAssertFalse(CustomRewriteStyle.suffix.contains("meaningful negation"))
        XCTAssertFalse(
            CustomRewriteStyle.suffix.contains(RewritePrompt.transcriptionCleanupInstruction),
            "the suffix repeats the shared cleanup sentence"
        )
    }

    func testTheBuiltInChoicesAreInTheShippedOrder() {
        XCTAssertEqual(
            RewriteStyle.builtIns.map(\.id),
            ["prompt", "concise", "formal", "casual", "gen-z"]
        )
        XCTAssertEqual(RewriteStyle.concise.title, "Concise")
        XCTAssertEqual(RewriteStyle(.casual).id, "casual")
        XCTAssertEqual(RewriteStyle(.formal).kind, .builtIn(.formal))
        XCTAssertEqual(RewriteStyle(.formal).title, "Professional")
        XCTAssertEqual(RewriteStyle(.warm).kind, .builtIn(.warm))
        XCTAssertEqual(RewriteStyle(.warm).title, "Warm")
        XCTAssertEqual(RewriteStyle(.genZ).kind, .builtIn(.genZ))
        XCTAssertEqual(RewriteStyle(.genZ).title, "Gen Z")
    }
}
