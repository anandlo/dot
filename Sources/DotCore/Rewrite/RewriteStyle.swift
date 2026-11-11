import Foundation

/// One of the rewrites Dot ships.
///
/// The template is data, not copy assembled at run time: the same sentence is
/// what the model is told and what the tests check, so a reworded instruction
/// is a visible change rather than a prompt that quietly drifted.
public enum RewriteStyleID: String, Codable, Sendable, CaseIterable {
    case prompt
    case concise
    case plain
    case casual
    case formal

    /// The label on the chip, and the title of the row in Settings.
    public var title: String {
        switch self {
        case .prompt: "Prompt"
        case .concise: "Concise"
        case .plain: "Plain English"
        case .casual: "Casual"
        case .formal: "Formal"
        }
    }

    /// Whether the Settings sentence is written on two lines.
    ///
    /// The long descriptions are broken where the sentence reads as two lines
    /// rather than as a widow, because a two-line description under a one-line
    /// title is what keeps the row's ink level with its switch.
    public var wrapsSubtitle: Bool { subtitle.contains("\n") }

    /// The one sentence Settings puts under the title.
    public var subtitle: String {
        switch self {
        case .prompt: "Turns a spoken request into an instruction\nfor a coding agent."
        case .concise: "Shorter,\nsame facts."
        case .plain: "Simpler words."
        case .casual: "Relaxed, like a text\nto a friend."
        case .formal: "Clear and\nprofessional."
        }
    }

    /// The instruction the model is given.
    public var template: String {
        switch self {
        case .prompt:
            """
            Rewrite the spoken request as an instruction for a coding agent. Keep every fact, name, \
            path, number, library and constraint the speaker said. Do not add requirements, steps, \
            tools or libraries that were not said. Use this shape: Goal, Context, Constraints, Done \
            when. If a required detail was not said, write [missing: what] instead of inventing it. \
            Output only the rewritten instruction.
            """
        case .concise:
            """
            Rewrite the transcript more concisely. Keep every fact, name, number, negation and \
            qualifier. Remove filler, repetition and hesitation. Do not add anything. Aim for 50 to \
            70 percent of the original length. Output only the rewrite.
            """
        case .plain:
            """
            Rewrite in plain English. Prefer short common words and the active voice. Keep technical \
            terms that have no plain equivalent. Do not explain, summarise or add examples. Output \
            only the rewrite.
            """
        case .casual:
            """
            Rewrite in a relaxed texting register, the way a Gen Z friend would write it: short \
            sentences, contractions, lowercase is fine. Keep every fact, name, number and negation. \
            Do not add emoji unless the original had them. Do not add or remove content. Output only \
            the rewrite.
            """
        case .formal:
            """
            Rewrite in a clear, formal register suitable for work email. Keep every fact, name, \
            number and negation. Do not add or remove content. Output only the rewrite.
            """
        }
    }

    /// The range a rewrite of this style may fall into, relative to its input.
    public var lengthRatio: ClosedRange<Double> {
        switch self {
        case .prompt: 0.8 ... 3.0
        case .concise: 0.35 ... 0.85
        case .plain, .casual: 0.5 ... 1.3
        case .formal: 0.7 ... 1.5
        }
    }

    /// Whether a warning is raised for a capitalised word that disappeared.
    ///
    /// The prompt style restructures the text into its own sections, so a name
    /// that moved into a heading is not a name that changed.
    public var checksNames: Bool { self != .prompt }
}
