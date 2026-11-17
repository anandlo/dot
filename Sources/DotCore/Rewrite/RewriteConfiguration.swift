import Foundation

/// The styles a person chose, and whether the card offers them after dictation.
///
/// It is one block of the assistant's configuration. Every field decodes the
/// tolerant way the rest of the file does: a bad value resets only its own
/// field, and a style id this build does not know is dropped rather than being
/// fatal.
public struct RewriteConfiguration: Codable, Sendable, Equatable {
    /// The most characters a built-in instruction may carry.
    public static let maximumBuiltInInstructionLength = 4_000

    /// The most characters the standing rules may carry.
    ///
    /// The block is appended to every Agent prompt verbatim, so it is a short
    /// set of rules rather than a second instruction: a longer text belongs in
    /// the prompt itself, where the model can read it.
    public static let maximumStandingRulesLength = 2_000

    /// Whether the card offers the chips at all.
    public var enabled: Bool
    /// The built-in styles that are offered, in the order the person kept them.
    public var styles: [RewriteStyleID]
    /// The styles the person wrote.
    public var custom: [CustomRewriteStyle]
    /// The built-in styles the person removed from the page.
    ///
    /// A shipped style is a starting point, not a rule: the page offers its
    /// switch, its instruction and the control that removes it, and a style
    /// removed here is gone from the chips and from the card until it is
    /// restored. The ids stay in the file rather than being inferred from a
    /// missing ``styles`` entry, so a later build that ships one of them again
    /// can keep it off the page the person hid it from.
    public var deletedBuiltIns: [RewriteStyleID]
    /// The instruction the person wrote for a built-in style.
    ///
    /// Keyed by ``RewriteStyleID/rawValue``. Only edited styles are here, so a
    /// file written before this field existed is read as the shipped
    /// instructions, and a key this build does not know is carried through a
    /// save instead of being dropped: a newer build's style keeps its
    /// instruction when an older build rewrites the file.
    public var builtInInstructions: [String: String]
    /// Whether Dot puts the standing rules under an Agent prompt.
    public var standingRulesEnabled: Bool
    /// The text Dot appends to an Agent prompt, word for word.
    ///
    /// The model never reads it and never writes it: it is copied under the
    /// answer after the faithfulness check has read the answer alone, so the
    /// rules cannot change what the model says or how the check measures it.
    /// The block belongs to the version Dot keeps, so the saved versions and a
    /// Paste carry it too.
    public var standingRules: String

    /// A fresh configuration: every built-in style, no custom ones.
    public static let `default` = RewriteConfiguration()

    public init(
        enabled: Bool = true,
        styles: [RewriteStyleID] = RewriteStyleID.shippedCases,
        custom: [CustomRewriteStyle] = [],
        deletedBuiltIns: [RewriteStyleID] = [],
        builtInInstructions: [String: String] = [:],
        standingRulesEnabled: Bool = false,
        standingRules: String = ""
    ) {
        self.enabled = enabled
        self.styles = styles.filter { !deletedBuiltIns.contains($0) }
        self.custom = custom
        self.deletedBuiltIns = deletedBuiltIns
        self.builtInInstructions = builtInInstructions.mapValues {
            String($0.prefix(Self.maximumBuiltInInstructionLength))
        }
        self.standingRulesEnabled = standingRulesEnabled
        self.standingRules = Self.cappedStandingRules(standingRules)
    }

    /// The text Dot appends under an Agent prompt, or `nil` when it is off.
    ///
    /// The switch is what decides whether the block is part of the delivery,
    /// and a block with no text in it is the same as no block: a person who
    /// turned the switch on before writing anything does not get a blank line
    /// under every answer. The stored text is returned as it was written, so
    /// the block is the person's own lines rather than a reformatted copy.
    public var standingRulesText: String? {
        guard standingRulesEnabled,
              !standingRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return standingRules
    }

    /// Replaces the standing rules, capped at ``maximumStandingRulesLength``.
    ///
    /// - Parameter rules: the text to store.
    public mutating func setStandingRules(_ rules: String) {
        standingRules = Self.cappedStandingRules(rules)
    }

    /// The text held to the length the block keeps.
    private static func cappedStandingRules(_ rules: String) -> String {
        String(rules.prefix(maximumStandingRulesLength))
    }

    /// The built-in styles the page still offers, in the build's order.
    ///
    /// A style the person removed is not here even though the enum still names
    /// it: the switch that removes a style and the chips that follow it have to
    /// answer from one list.
    public var visibleBuiltIns: [RewriteStyleID] {
        RewriteStyleID.shippedCases.filter { !deletedBuiltIns.contains($0) }
    }

    /// Removes a built-in style from the page.
    ///
    /// The style leaves the chips, its instruction is cleared so a later
    /// restore starts from the shipped template, and its id is remembered so a
    /// list that still named it cannot bring it back. The canonical order keeps
    /// the file stable however the person deleted them.
    ///
    /// - Parameter id: the style to remove.
    public mutating func deleteBuiltIn(_ id: RewriteStyleID) {
        styles.removeAll { $0 == id }
        builtInInstructions[id.rawValue] = nil
        let shipped = RewriteStyleID.shippedCases
        let order = shipped + RewriteStyleID.allCases.filter { !shipped.contains($0) }
        let removed = deletedBuiltIns + (deletedBuiltIns.contains(id) ? [] : [id])
        deletedBuiltIns = order.filter { removed.contains($0) }
    }

    /// Puts every removed built-in style back in the build's order.
    ///
    /// The instructions those styles carried were cleared when they were
    /// removed, so a restore is a restore: the shipped template comes back, not
    /// a half-remembered edit.
    public mutating func restoreBuiltIns() {
        guard !deletedBuiltIns.isEmpty else { return }
        let shipped = RewriteStyleID.shippedCases
        let legacy = RewriteStyleID.allCases.filter { !shipped.contains($0) }
        var kept = styles
        for id in shipped where deletedBuiltIns.contains(id) && !kept.contains(id) {
            kept.append(id)
        }
        deletedBuiltIns = []
        styles = (shipped + legacy).filter { kept.contains($0) }
    }

    /// The styles the chips show: the built-ins first, then the custom ones.
    ///
    /// A built-in style carries the instruction the person set for it, when
    /// there is one. Its id, title, kind and measurements are the shipped ones,
    /// so a chip and the version it produces cannot disagree about which style
    /// ran. A custom style without a name or an instruction is not a style that
    /// can be run, so it is not offered.
    public var choices: [RewriteStyle] {
        styles.map(builtInChoice(for:)) + custom.filter(\.isUsable).map(RewriteStyle.init)
    }

    /// The instruction to use for a built-in style.
    ///
    /// The stored override wins only when it has text: an edit that was
    /// cleared, or a value made of whitespace, falls back to the shipped
    /// template, so a half-finished edit cannot send an empty instruction. The
    /// person's words are returned as they were written.
    ///
    /// - Parameter id: the style whose instruction is wanted.
    public func instruction(for id: RewriteStyleID) -> String {
        guard let stored = builtInInstructions[id.rawValue] else { return id.template }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id.template : stored
    }

    /// Replaces the instruction of one built-in style, or restores the shipped one.
    ///
    /// - Parameters:
    ///   - instruction: the new instruction, capped at
    ///     ``maximumBuiltInInstructionLength``. `nil` removes the override, so
    ///     the shipped template is used again. An empty or whitespace-only
    ///     value is kept as typed and falls back to the template when it is
    ///     used, which lets a field be cleared while it is being edited.
    ///   - id: the style to change.
    public mutating func setInstruction(_ instruction: String?, for id: RewriteStyleID) {
        guard let instruction else {
            builtInInstructions[id.rawValue] = nil
            return
        }
        builtInInstructions[id.rawValue] = String(
            instruction.prefix(Self.maximumBuiltInInstructionLength)
        )
    }

    /// A built-in style with the person's instruction, when they set one.
    private func builtInChoice(for id: RewriteStyleID) -> RewriteStyle {
        var style = RewriteStyle(id)
        style.instruction = instruction(for: id)
        return style
    }

    /// The style under an id, when it is offered.
    public func style(for id: String) -> RewriteStyle? {
        choices.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case styles
        case custom
        case builtInInstructions
        case deletedBuiltIns
        case standingRulesEnabled
        case standingRules
        // Read once, never written: the build before this one kept a block of
        // working rules that the model wove into its answer, and the block the
        // model never sees replaces it. They stay on the enum so a file that
        // carries them still opens and its text is not dropped.
        case workingRulesEnabled
        case workingRules
    }

    /// The rules the retired block shipped with.
    ///
    /// A file whose rules are exactly these never chose anything: the block was
    /// the default, so the block the model never sees starts off rather than
    /// repeating the shipped list under every answer.
    private static let legacyDefaultWorkingRules = """
    ## Working rules
    - Read the relevant code before you change it.
    - Keep changes within the scope of this request.
    - Ask before adding a dependency or changing a public interface.
    - Run the build and the tests, and report the results.
    - If something is unclear, ask instead of guessing.
    """

    /// The most characters the retired working rules could carry.
    private static let maximumLegacyWorkingRulesLength = 1_200

    /// The Agent prompt the build before this one shipped.
    ///
    /// It exists only to recognise the files that build wrote. It converted the
    /// retired working rules into a stored instruction for this style, and a
    /// stored instruction outlives the template it replaced: without this copy,
    /// the template that build generated would be read as the person's own edit
    /// and the new template would never reach them. Nothing sends this text to a
    /// model; ``RewriteStyleID/prompt`` is the template that does.
    private static let previousPromptTemplate = """
    You turn a developer's spoken request into a precise task prompt for an AI coding agent.
    Rules:
    - Use only what the speaker said. Keep every name, file, path, library, version, command and constraint, and every meaningful number.
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
    ## Working rules
    Include the relevant working rules for the task, drawing from:
    - Read the relevant code before you change it.
    - Keep changes within the scope of this request.
    - Ask before adding a dependency or changing a public interface.
    - Run the build and the tests, and report the results.
    - If something is unclear, ask instead of guessing.
    Output only the prompt.
    """

    /// The heading the previous build wrote its rules section under.
    private static let previousWorkingRulesHeading = "## Working rules"

    /// The last line of the previous template, where its rules section ended.
    private static let previousPromptOutputLine = "\nOutput only the prompt."

    /// The sentence the previous build wrote over the person's rules.
    private static let previousWorkingRulesIntro =
        "\nInclude the relevant working rules for the task, drawing from:\n"

    /// The previous template with its rules section taken out.
    ///
    /// Built with the same split the previous build used, so the value a file
    /// carries can be recognised as that build's own.
    private static let previousPromptWithoutWorkingRules: String = {
        guard let split = previousPromptRulesSplit else { return previousPromptTemplate }
        return split.prefix + split.suffix
    }()

    /// The two ends of the previous template's rules section.
    ///
    /// `prefix` is everything before the heading and `suffix` is the closing
    /// line, so a stored instruction that begins and ends with them was written
    /// by the previous build rather than by a person.
    private static let previousPromptRulesSplit: (prefix: String, suffix: String)? = {
        guard let start = previousPromptTemplate.range(of: previousWorkingRulesHeading),
              let end = previousPromptTemplate.range(
                  of: previousPromptOutputLine,
                  range: start.upperBound ..< previousPromptTemplate.endIndex
              )
        else { return nil }
        return (
            String(previousPromptTemplate[..<start.lowerBound]),
            String(previousPromptTemplate[end.lowerBound...])
        )
    }()

    /// A stored Agent prompt instruction the build before this one generated.
    private enum GeneratedPromptOverride {
        /// The template with its rules section removed.
        case withoutRules
        /// The person's rules, under the section the previous template had.
        case withRules(String)
    }

    // MARK: - The previous build's producer, copied

    /// The instruction the previous build assembled from a rules payload.
    ///
    /// It reproduces the previous build's output so its files can be recognised:
    /// the same strip, the same 1 200-character cap, the same refusal to write
    /// an instruction for the rules it shipped with, and the same text around
    /// the rules. Nothing calls it to produce anything; it answers only whether
    /// a stored instruction is one this build's predecessor could have written.
    ///
    /// - Parameter payload: the rules as a file held them.
    /// - Returns: the instruction that build wrote, or `nil` when it wrote none.
    private static func previousProducerPrompt(rules payload: String) -> String? {
        let rules = previousProducerRules(payload)
        guard !rules.isEmpty else { return nil }
        guard normalizedRules(rules) != normalizedRules(legacyDefaultWorkingRules) else {
            return nil
        }
        guard let split = previousPromptRulesSplit else { return nil }
        return split.prefix
            + previousWorkingRulesHeading
            + previousWorkingRulesIntro
            + rules
            + split.suffix
    }

    /// The rules the previous build read out of a payload.
    ///
    /// Copied from that build exactly, including its heading test: it lowercased
    /// the first line and compared it with the mixed-case heading, so the test
    /// never matched and a heading the person had written stayed in the rules.
    /// Reading a payload the same way is what makes the recognised text the text
    /// that build stored.
    ///
    /// - Parameter payload: the rules as a file held them.
    /// - Returns: the rules after that build's cap, CRLF repair and trim.
    private static func previousProducerRules(_ payload: String) -> String {
        var lines = String(payload.prefix(maximumLegacyWorkingRulesLength))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespaces).lowercased() == previousWorkingRulesHeading {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the previous build wrote into the prompt's instruction, if that is
    /// what a stored value is.
    ///
    /// Only values that build could have written are recognised, and they are
    /// recognised by rebuilding them with its own producer and requiring the
    /// stored instruction to match byte for byte. Its template without the rules
    /// section is compared the way that build compared rules, line by line and
    /// trimmed, so a trailing newline an editor added does not turn its own
    /// value into a person's. A user who typed exactly what the previous build
    /// generated cannot be told apart from it; such an instruction is migrated.
    /// Everything else is a person's edit and is returned as `nil`.
    ///
    /// - Parameter stored: the instruction the file holds for the Agent prompt.
    /// - Returns: the generated value it is, or `nil` when it is a person's.
    private static func generatedPromptOverride(
        in stored: String
    ) -> GeneratedPromptOverride? {
        if normalizedRules(stored) == normalizedRules(previousPromptWithoutWorkingRules) {
            return .withoutRules
        }
        guard let split = previousPromptRulesSplit else { return nil }
        let opening = split.prefix
            + previousWorkingRulesHeading
            + previousWorkingRulesIntro
        guard stored.count > opening.count + split.suffix.count,
              stored.hasPrefix(opening),
              stored.hasSuffix(split.suffix)
        else { return nil }
        let rules = String(stored.dropFirst(opening.count).dropLast(split.suffix.count))
        // The producer's own limits, stated before the rebuild: a payload past
        // its cap was cut, a payload with space at its ends was trimmed, and the
        // rules it shipped with produced no instruction at all. None of those
        // can be a value it wrote.
        //
        // A carriage return is not one of the limits. The producer replaced
        // CRLF pairs and nothing else, so a lone return inside a payload
        // survived into the value it wrote; the replay below is what tells that
        // value from one a person typed, and it rejects the CRLF pair on its
        // own because the producer would have rewritten it.
        guard !rules.isEmpty,
              rules.count <= maximumLegacyWorkingRulesLength,
              previousProducerRules(rules) == rules,
              previousProducerPrompt(rules: rules) == stored
        else { return nil }
        return .withRules(rules)
    }

    /// One entry of the removed-style list, read without failing the list.
    ///
    /// A hand-edited array can hold a number or a null beside its ids. Reading
    /// the entries one at a time keeps the ids that are text instead of losing
    /// every removal to one bad element.
    private struct TextEntry: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            text = (try? container.decode(String.self)) ?? ""
        }
    }

    /// Reads the ids of the styles a person removed.
    ///
    /// An entry that is not text is skipped rather than failing the block, and
    /// an id this build does not know is dropped: the list only ever names a
    /// style this build can show a restore row for. A value that is not an
    /// array at all reads as no removals, which leaves the rest of the
    /// configuration untouched.
    private static func decodeDeletedBuiltIns(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [RewriteStyleID] {
        guard let stored = ((try? container.decodeIfPresent(
            [TextEntry].self,
            forKey: .deletedBuiltIns
        )) ?? nil)
        else { return [] }
        var seen = Set<RewriteStyleID>()
        return stored.map(\.text)
            .compactMap(RewriteStyleID.init(rawValue:))
            .map(Self.migrated)
            .filter { seen.insert($0).inserted }
    }

    /// The keys of the instruction map, which a future build may add to.
    private struct InstructionKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    /// Reads the instruction map one entry at a time.
    ///
    /// A value that is not text is skipped rather than failing the block, and a
    /// key this build does not know is kept as it was: the map is keyed by the
    /// stored style id, not by the enum, so a newer build's style survives a
    /// save from this one. A map that is not an object at all reads as empty,
    /// which leaves every other field of the configuration untouched.
    private static func decodeBuiltInInstructions(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [String: String] {
        guard let stored = try? container.nestedContainer(
            keyedBy: InstructionKey.self,
            forKey: .builtInInstructions
        ) else { return [:] }
        var decoded: [String: String] = [:]
        for key in stored.allKeys {
            guard let value = ((try? stored.decodeIfPresent(String.self, forKey: key)) ?? nil) else {
                continue
            }
            decoded[key.stringValue] = String(value.prefix(maximumBuiltInInstructionLength))
        }
        return decoded
    }

    /// The standing rules a file written with a separate working-rules block
    /// asks for.
    ///
    /// The retired block held the same kind of text: rules Dot put under the
    /// answer, never words of the speaker. A file that wrote its own rules and
    /// left the block on becomes a file with the block the model never sees on,
    /// carrying the person's text as it was stored. A file that turned the
    /// block off, or that never changed the rules it shipped with, becomes a
    /// file with the block off: there is nothing the person chose to keep.
    ///
    /// - Parameter container: the rewrite block being decoded.
    /// - Returns: the settings to adopt, or `nil` when the file says nothing
    ///   about the retired block or a value cannot be read.
    private static func migratedLegacyStandingRules(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> (enabled: Bool, text: String)? {
        let hasEnabled = container.contains(.workingRulesEnabled)
        let hasRules = container.contains(.workingRules)
        guard hasEnabled || hasRules else { return nil }
        let enabled = (try? container.decodeIfPresent(Bool.self, forKey: .workingRulesEnabled)) ?? nil
        let stored = (try? container.decodeIfPresent(String.self, forKey: .workingRules)) ?? nil
        // A value this build cannot read says nothing about the rules, and a
        // block written from a guess would be worse than none.
        if hasEnabled, enabled == nil { return nil }
        if hasRules, stored == nil { return nil }
        guard enabled ?? true else { return (false, "") }
        guard let stored else { return (false, "") }
        let rules = String(stored.prefix(maximumLegacyWorkingRulesLength))
        guard !normalizedRules(rules).isEmpty else { return (false, "") }
        guard normalizedRules(rules) != normalizedRules(legacyDefaultWorkingRules) else {
            return (false, "")
        }
        return (true, cappedStandingRules(rules))
    }

    /// Rules compared by their lines rather than their spacing.
    ///
    /// - Parameter text: a rules block.
    /// - Returns: the non-empty lines, trimmed and joined.
    private static func normalizedRules(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The style a stored id stands for in this build.
    ///
    /// Concise absorbed Plain English, and Professional absorbed Formal and
    /// Warm, so a file written with a retired id keeps the choice it recorded
    /// instead of showing fewer styles than the person picked. The retired ids
    /// stay on ``RewriteStyleID``, so a file this build writes still opens in an
    /// older one.
    ///
    /// - Parameter id: the id as it was stored.
    /// - Returns: the id that offers the same choice today.
    static func migrated(_ id: RewriteStyleID) -> RewriteStyleID {
        switch id {
        case .plain: .concise
        case .warm: .formal
        default: id
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RewriteConfiguration.default
        enabled = ((try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil)
            ?? fallback.enabled
        // A style id this build does not know is dropped: a file written by a
        // newer build still opens, and the styles it kept still run. The array
        // is read as text first for exactly that reason: decoding it as ids
        // would throw on the one id it does not know and lose the rest.
        if let stored = ((try? container.decodeIfPresent([String].self, forKey: .styles)) ?? nil) {
            var seen = Set<RewriteStyleID>()
            styles = stored
                .compactMap(RewriteStyleID.init(rawValue:))
                .map(Self.migrated)
                .filter { seen.insert($0).inserted }
        } else {
            styles = fallback.styles
        }
        let storedCustom = ((try? container.decodeIfPresent([CustomRewriteStyle].self, forKey: .custom)) ?? nil)
            ?? []
        custom = Array(storedCustom.map(\.sanitized).prefix(CustomRewriteStyle.maximumCount))
        builtInInstructions = Self.decodeBuiltInInstructions(from: container)
        // The build before this one turned the retired rules into a stored
        // instruction for this style and saved no retired keys beside it. Left
        // alone, that instruction would outrank every template this build
        // ships, so a file it saved would never see the new prompt. The two
        // values that build generated are therefore recognised and removed;
        // anything else in the field is the person's own edit and stays.
        let generated = builtInInstructions[RewriteStyleID.prompt.rawValue]
            .flatMap(Self.generatedPromptOverride(in:))
        if generated != nil {
            builtInInstructions[RewriteStyleID.prompt.rawValue] = nil
        }
        // The retired block is read only for a file that does not carry either
        // of the keys that replaced it: a file this build wrote is answered by
        // its own values, not by what an older build left beside them.
        if container.contains(.standingRulesEnabled) || container.contains(.standingRules) {
            standingRulesEnabled = ((try? container.decodeIfPresent(
                Bool.self,
                forKey: .standingRulesEnabled
            )) ?? nil) ?? fallback.standingRulesEnabled
            let stored = ((try? container.decodeIfPresent(String.self, forKey: .standingRules)) ?? nil)
                ?? fallback.standingRules
            standingRules = Self.cappedStandingRules(stored)
        } else if let generated {
            switch generated {
            case .withoutRules:
                standingRulesEnabled = false
                standingRules = ""
            case .withRules(let rules):
                standingRulesEnabled = true
                standingRules = Self.cappedStandingRules(rules)
            }
        } else if let migrated = Self.migratedLegacyStandingRules(from: container) {
            standingRulesEnabled = migrated.enabled
            standingRules = migrated.text
        } else {
            standingRulesEnabled = fallback.standingRulesEnabled
            standingRules = fallback.standingRules
        }
        deletedBuiltIns = Self.decodeDeletedBuiltIns(from: container)
        // A style the person removed is not offered, even by a list that still
        // names it: the list is read first, so a file written before the
        // removal existed cannot bring the style back.
        styles.removeAll { deletedBuiltIns.contains($0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(styles, forKey: .styles)
        if !custom.isEmpty {
            try container.encode(custom, forKey: .custom)
        }
        if !builtInInstructions.isEmpty {
            try container.encode(builtInInstructions, forKey: .builtInInstructions)
        }
        if !deletedBuiltIns.isEmpty {
            try container.encode(deletedBuiltIns, forKey: .deletedBuiltIns)
        }
        try container.encode(standingRulesEnabled, forKey: .standingRulesEnabled)
        try container.encode(standingRules, forKey: .standingRules)
    }
}

/// Whether a finished take gets the chips.
///
/// The rule is one function so the card, the paste path that captures the
/// anchor and Settings cannot disagree about when a rewrite is offered. It asks
/// ``AssistantAvailability/isUsable(config:hasKey:)`` rather than keeping a
/// second opinion about a key: an install that never set the assistant up is
/// offered no chips, whatever the speech provider stored. None of it touches
/// the Accessibility API: an ineligible take never captures an anchor, which is
/// what keeps an install without a chat service identical to the build before
/// this feature.
public enum RewriteOffer {
    /// The most characters a take may have and still be offered.
    public static let maximumInputCharacters = RewritePrompt.maximumInputCharacters
    /// The shortest take that is worth rewriting.
    public static let minimumInputCharacters = 1

    /// Whether the card should carry the chip row.
    ///
    /// - Parameters:
    ///   - rewrite: the person's rewrite settings.
    ///   - assistant: the assistant's block, which names the service and says
    ///     whether the person set it up.
    ///   - hasKey: whether a key is stored for that service.
    ///   - text: the transcript.
    ///   - delivery: how the words were delivered. A failed take is not
    ///     rewritten, and a copy is still offered: its rewrite goes to the
    ///     clipboard.
    public static func shouldOffer(
        rewrite: RewriteConfiguration,
        assistant: AssistantConfiguration,
        hasKey: Bool,
        text: String,
        delivery: HUDDelivery
    ) -> Bool {
        guard rewrite.enabled, !rewrite.choices.isEmpty else { return false }
        guard delivery != .failed else { return false }
        guard AssistantAvailability.isUsable(config: assistant, hasKey: hasKey) else { return false }
        let length = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return (minimumInputCharacters ... maximumInputCharacters).contains(length)
    }
}
