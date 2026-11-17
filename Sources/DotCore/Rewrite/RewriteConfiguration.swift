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

    /// A fresh configuration: every built-in style, no custom ones.
    public static let `default` = RewriteConfiguration()

    public init(
        enabled: Bool = true,
        styles: [RewriteStyleID] = RewriteStyleID.shippedCases,
        custom: [CustomRewriteStyle] = [],
        deletedBuiltIns: [RewriteStyleID] = [],
        builtInInstructions: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.styles = styles.filter { !deletedBuiltIns.contains($0) }
        self.custom = custom
        self.deletedBuiltIns = deletedBuiltIns
        self.builtInInstructions = builtInInstructions.mapValues {
            String($0.prefix(Self.maximumBuiltInInstructionLength))
        }
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
        // Read once, never written: the build before this one kept the working
        // rules in their own block, and the rules live in the prompt template
        // now. They stay on the enum so a file that carries them still opens.
        case workingRulesEnabled
        case workingRules
    }

    /// The rules the retired block shipped with.
    ///
    /// They are the same words that are in the agent prompt's template now, so
    /// a file that never edited them needs no migration at all: the shipped
    /// prompt already says them.
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

    /// The heading the rules section is written under.
    private static let workingRulesHeading = "## Working rules"

    /// The last line of the prompt style, and the end of its rules section.
    private static let promptOutputLine = "\nOutput only the prompt."

    /// The prompt template with the rules section taken out.
    ///
    /// It is built once from the shipped template, so a reworded template can
    /// never leave a stale copy of the section behind.
    private static let promptTemplateWithoutWorkingRules: String = {
        let template = RewriteStyleID.prompt.template
        guard let start = template.range(of: workingRulesHeading),
              let end = template.range(
                  of: promptOutputLine,
                  range: start.upperBound ..< template.endIndex
              )
        else { return template }
        return String(template[..<start.lowerBound]) + String(template[end.lowerBound...])
    }()

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

    /// The prompt a file written with a separate working-rules block asks for.
    ///
    /// The two retired keys are read only when the person changed something.
    /// A file that turned the block off gets the template with the section
    /// removed; a file that wrote its own rules gets those rules under the
    /// section's sentence, so the person's words survive the move. The shipped
    /// rules need no migration because the template already carries them, and a
    /// prompt edit this build already stored wins over a legacy value: it is
    /// the newer statement of the same intent.
    ///
    /// - Parameter container: the rewrite block being decoded.
    /// - Returns: the prompt instruction to store, or `nil` when the shipped
    ///   template is already right.
    private static func migratedLegacyPrompt(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        let hasEnabled = container.contains(.workingRulesEnabled)
        let hasRules = container.contains(.workingRules)
        guard hasEnabled || hasRules else { return nil }
        let enabled = (try? container.decodeIfPresent(Bool.self, forKey: .workingRulesEnabled)) ?? nil
        let stored = (try? container.decodeIfPresent(String.self, forKey: .workingRules)) ?? nil
        // A value this build cannot read says nothing about the rules, and the
        // shipped template stands rather than being replaced by a guess.
        if hasEnabled, enabled == nil { return nil }
        if hasRules, stored == nil { return nil }
        guard enabled ?? true else { return promptTemplateWithoutWorkingRules }
        guard let stored else { return nil }
        let rules = stripWorkingRulesHeading(
            String(stored.prefix(maximumLegacyWorkingRulesLength))
        )
        guard !rules.isEmpty else { return promptTemplateWithoutWorkingRules }
        guard normalizedRules(rules) != normalizedRules(legacyDefaultWorkingRules) else {
            return nil
        }
        let template = RewriteStyleID.prompt.template
        guard let start = template.range(of: workingRulesHeading),
              let end = template.range(
                  of: promptOutputLine,
                  range: start.upperBound ..< template.endIndex
              )
        else { return nil }
        let prefix = String(template[..<start.lowerBound])
        let suffix = String(template[end.lowerBound...])
        return prefix
            + workingRulesHeading
            + "\nInclude the relevant working rules for the task, drawing from:\n"
            + rules
            + suffix
    }

    /// A rules block without the heading the person may have written twice.
    ///
    /// - Parameter text: the rules as the retired block stored them.
    /// - Returns: the rules, trimmed, with a leading heading removed.
    private static func stripWorkingRulesHeading(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespaces).lowercased() == workingRulesHeading {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
        var instructions = Self.decodeBuiltInInstructions(from: container)
        if instructions[RewriteStyleID.prompt.rawValue] == nil,
           let migrated = Self.migratedLegacyPrompt(from: container) {
            instructions[RewriteStyleID.prompt.rawValue] = String(
                migrated.prefix(Self.maximumBuiltInInstructionLength)
            )
        }
        builtInInstructions = instructions
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
