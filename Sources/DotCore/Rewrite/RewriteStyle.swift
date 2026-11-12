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
        case .prompt: "Agent prompt"
        case .concise: "Concise"
        case .plain: "Plain English"
        case .casual: "Casual"
        case .formal: "Formal"
        }
    }

    /// The one sentence Settings puts under the title.
    public var subtitle: String {
        switch self {
        case .prompt: "Turns a spoken request into a structured task for a coding agent."
        case .concise: "Shorter, with every fact kept."
        case .plain: "Simpler words, same meaning."
        case .casual: "Relaxed and conversational, like a text to a friend."
        case .formal: "Clear and professional."
        }
    }

    /// The instruction the model is given.
    public var template: String {
        switch self {
        case .prompt:
            """
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
            Rewrite in a casual, conversational Gen Z register, the way a friend texts: short \
            sentences, contractions, everyday words, lowercase is fine, light slang only where it \
            sounds natural. Keep every fact, name, number and negation. Do not add emoji unless the \
            original had them. Do not add or remove content. Output only the rewrite.
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
