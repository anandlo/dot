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
    /// A warm register that says each thing once.
    ///
    /// The raw value is appended to the list rather than inserted: the ones
    /// before it are already written into configuration files, and a file that
    /// kept a subset of them keeps exactly that subset. The style reaches an
    /// existing file the way every style does, through its switch on the
    /// Assistant page.
    case warm = "warm"
    /// The register that reads like a text to a friend, slang included.
    ///
    /// It is the one style whose own name says how it sounds, which is why it
    /// was kept apart from the plain conversational register rather than folded
    /// into it.
    case genZ = "gen-z"

    /// The five distinct styles offered in a fresh configuration and in Settings.
    ///
    /// Concise absorbs Plain English, and Professional absorbs Formal and Warm,
    /// so every shipped choice does a clearly different job. `.plain` and `.warm`
    /// stay on the enum to decode older files without failing.
    public static let shippedCases: [RewriteStyleID] = [
        .prompt, .concise, .formal, .casual, .genZ,
    ]

    /// The label on the chip, and the title of the row in Settings.
    public var title: String {
        switch self {
        case .prompt: "Agent prompt"
        case .concise: "Concise"
        case .plain: "Plain English"
        case .casual: "Casual"
        case .formal: "Professional"
        case .warm: "Warm"
        case .genZ: "Gen Z"
        }
    }

    /// The one sentence Settings puts under the title.
    public var subtitle: String {
        switch self {
        case .prompt: "Turns what you said into a structured task for a coding agent, adding nothing."
        case .concise: "Shorter and plain, with every fact kept."
        case .plain: "Simpler words, same meaning."
        case .casual: "Natural, everyday chat messages and DMs."
        case .formal: "Clear, direct, and respectful for work."
        case .warm: "Friendly and respectful, direct, and never padded."
        case .genZ: "Casual Gen Z texting style with light natural slang."
        }
    }

    /// The instruction the model is given.
    ///
    /// The shared cleanup sentence is not part of a template: Dot adds it once
    /// to every system text.
    public var template: String {
        switch self {
        case .prompt:
            """
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
            """
        case .concise:
            """
            Rewrite the transcript more concisely in plain, direct language. Prefer short common \
            words and the active voice, while keeping technical terms that have no plain \
            equivalent. Keep every fact, name, negation and qualifier, and every meaningful number. \
            Remove filler, repetition and hesitation. Do not add anything. Aim for 50 to 70 percent \
            of the original length. Output only the rewrite.
            """
        case .plain:
            """
            Rewrite in plain English. Prefer short common words and the active voice. Keep technical \
            terms that have no plain equivalent. Do not explain, summarise or add examples. Output \
            only the rewrite.
            """
        case .casual:
            """
            Rewrite in the casual, conversational register of an everyday personal message or DM. \
            Use natural contractions and plain, common words, in short sentences. Do not add an \
            email greeting, sign-off or heading unless the original needs one, and do not force \
            slang or emoji. Keep every fact, name and negation, and every meaningful number. Do not \
            add content or remove anything the speaker meant. Output only the rewrite.
            """
        case .formal:
            """
            Rewrite in a clear, respectful, professional register suitable for work. Be direct and \
            constructive, using plain words and the active voice. Keep every fact, name and \
            negation, and every meaningful number. Remove filler, hedging and repetition. Do not \
            add praise, apologies, thanks or any detail that was not said. Output only the rewrite.
            """
        case .warm:
            """
            Rewrite in a warm, respectful, direct register. Sound like a considerate colleague: \
            friendly without being chummy, certain without being blunt. Address the reader as you, \
            use plain words and the active voice. Keep every fact, name and negation, and every \
            meaningful number. Remove filler, hedging and repetition, so each point is said once. \
            Do not add praise, apologies, thanks, promises, opinions or any detail that was not \
            said. Do not soften a refusal, a deadline or a condition. Output only the rewrite.
            """
        case .genZ:
            """
            Rewrite in a casual, conversational Gen Z register, the way a friend texts: short \
            sentences, contractions, everyday words, lowercase is fine, light slang only where it \
            sounds natural. Keep every fact, name and negation, and every meaningful number. Do not \
            add emoji unless the original had them. Do not add content or remove anything the \
            speaker meant. Output only the rewrite.
            """
        }
    }

    /// The range a rewrite of this style may fall into, relative to its input.
    public var lengthRatio: ClosedRange<Double> {
        switch self {
        case .prompt: 0.8 ... 3.0
        case .concise: 0.35 ... 0.85
        case .plain, .casual, .genZ: 0.5 ... 1.3
        case .formal: 0.7 ... 1.5
        // Saying each thing once may not make the text longer: the band stops
        // just above the original so a rewrite that pads is reported.
        case .warm: 0.4 ... 1.05
        }
    }

    /// Whether a warning is raised for a capitalised word that disappeared.
    ///
    /// The prompt style restructures the text into its own sections, so a name
    /// that moved into a heading is not a name that changed.
    public var checksNames: Bool { self != .prompt }
}
