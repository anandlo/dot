import Foundation

/// A style the person wrote themselves.
///
/// Only the instruction is theirs. The one sentence that keeps a rewrite honest
/// is appended to every custom style, so a hand-written style cannot ask the
/// model to invent facts and then be applied as if it had not.
public struct CustomRewriteStyle: Codable, Sendable, Equatable, Identifiable {
    /// The suffix every custom instruction carries.
    public static let suffix = """
    Keep every fact, name, number and negation. Do not add anything that was not said. Output only \
    the rewrite.
    """
    /// The longest name a custom style may have.
    public static let maximumTitleLength = 24
    /// The longest instruction a custom style may have.
    public static let maximumInstructionLength = 600
    /// The most custom styles a configuration may carry.
    public static let maximumCount = 6
    /// The range a custom rewrite may fall into, relative to its input.
    public static let lengthRatio: ClosedRange<Double> = 0.3 ... 3.0

    /// The identity written into the configuration.
    public var id: String
    /// The label on the chip.
    public var title: String
    /// What the person asked for, without the suffix.
    public var instruction: String

    public init(id: String = UUID().uuidString, title: String, instruction: String) {
        self.id = id
        self.title = title
        self.instruction = instruction
    }

    /// The instruction with the fixed suffix, as the model reads it.
    public var wrappedInstruction: String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed + " " + Self.suffix
    }

    /// Whether the style can be offered: it needs a name and an instruction.
    public var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The style inside the length limits Settings enforces.
    public var sanitized: CustomRewriteStyle {
        var copy = self
        copy.title = String(
            title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumTitleLength)
        )
        copy.instruction = String(
            instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumInstructionLength)
        )
        if copy.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.id = UUID().uuidString
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case instruction
    }

    // A hand-edited row is read field by field so one bad value cannot take the
    // rest of the configuration with it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil ?? UUID().uuidString
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil ?? ""
        instruction = (try? container.decodeIfPresent(String.self, forKey: .instruction)) ?? nil ?? ""
    }
}

/// A style as the prompt and the card use it: an id, a label and an instruction.
public struct RewriteStyle: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case builtIn(RewriteStyleID)
        case custom
    }

    public var kind: Kind
    /// The id stored in the configuration, and what a chip reports back.
    public var id: String
    /// The label on the chip.
    public var title: String
    /// The instruction the model is given, without the data sentence.
    public var instruction: String
    /// The range a rewrite of this style may fall into.
    public var lengthRatio: ClosedRange<Double>
    /// Whether a disappeared capitalised word is a warning.
    public var checksNames: Bool

    public init(_ id: RewriteStyleID) {
        kind = .builtIn(id)
        self.id = id.rawValue
        title = id.title
        instruction = id.template
        lengthRatio = id.lengthRatio
        checksNames = id.checksNames
    }

    public init(_ custom: CustomRewriteStyle) {
        kind = .custom
        id = custom.id
        title = custom.title
        instruction = custom.wrappedInstruction
        lengthRatio = CustomRewriteStyle.lengthRatio
        checksNames = true
    }

    public static let prompt = RewriteStyle(.prompt)
    public static let concise = RewriteStyle(.concise)
    public static let plain = RewriteStyle(.plain)
    public static let casual = RewriteStyle(.casual)
    public static let formal = RewriteStyle(.formal)

    /// The built-in styles in the order the chips show them.
    public static let builtIns: [RewriteStyle] = RewriteStyleID.allCases.map(RewriteStyle.init)
}
