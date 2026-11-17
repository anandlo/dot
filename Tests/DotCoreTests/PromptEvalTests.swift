import Foundation
import XCTest

@testable import DotCore

/// The live prompt evaluation: how much of each rewrite the speaker never said.
///
/// It is a developer tool rather than part of the suite. It sends ten dictated
/// transcripts, through the real request builder and the real
/// OpenAI-compatible provider, to whatever chat service the environment names,
/// and writes the measurements as a TSV. It asserts nothing: the numbers are
/// read by a person, because how much a rewrite may add is a judgement about a
/// model's output rather than a property of this code.
///
/// The environment:
/// - `DOT_PROMPT_EVAL_BASE_URL`: the service's base URL, for example
///   `http://127.0.0.1:8080/v1`.
/// - `DOT_PROMPT_EVAL_MODEL`: the model id to ask for.
/// - `DOT_PROMPT_EVAL_KEY`: the key the service accepts.
/// - `DOT_PROMPT_EVAL_STYLE_PATH`: optional. A configuration file whose rewrite
///   block decides the styles that run, so a person's own style and edits are
///   measured beside the shipped ones. Without it every shipped style runs.
/// - `DOT_PROMPT_EVAL_OUT`: optional. The TSV's path, default
///   `/tmp/dot-prompt-eval.tsv`.
///
/// The fixture that reports a problem and asks for nothing is measured for the
/// one failure this evaluation is about: an Agent prompt that turns the report
/// into a task. For that fixture alone, and for that style alone, the words a
/// task would use are recorded in a second TSV beside the first. It is a record,
/// not an assertion: the harness still asserts nothing, and the other styles are
/// not measured that way because their answer may quote the transcript.
///
/// With the three required values unset the test skips, so a normal run of the
/// suite never reaches the network.
final class PromptEvalTests: XCTestCase {
    func testThePromptEvalMeasuresTheContentEachStyleAdds() async throws {
        let baseURL = try required("PROMPT_EVAL_BASE_URL")
        let model = try required("PROMPT_EVAL_MODEL")
        let key = try required("PROMPT_EVAL_KEY")
        let url = try EndpointPolicy.url(from: baseURL)
        let configuration = try styles()
        let fixtures = try transcripts()
        XCTAssertFalse(fixtures.isEmpty, "no transcript fixtures were found")

        let provider = OpenAIChatProvider(
            baseURL: url,
            apiKey: key,
            session: Self.session()
        )
        let stopWords = try Self.stopWords()

        var rows: [String] = ["style\tfixture\tratio\tadded"]
        var taskWordRows: [String] = ["style\tfixture\twords"]
        for style in configuration.choices {
            for fixture in fixtures {
                let output = try await answer(
                    provider: provider,
                    style: style,
                    transcript: fixture.text,
                    model: model
                )
                let measurement = PromptEval.measure(
                    output: output,
                    transcript: fixture.text,
                    stopWords: stopWords
                )
                rows.append(
                    [
                        style.id,
                        fixture.name,
                        String(format: "%.4f", measurement.ratio),
                        measurement.added.joined(separator: " "),
                    ].joined(separator: "\t")
                )
                if style.kind == .builtIn(.prompt),
                   fixture.name == PromptEval.observationFixture {
                    let hits = PromptEval.matches(of: PromptEval.taskWords, in: output)
                    taskWordRows.append(
                        [style.id, fixture.name, hits.joined(separator: " ")].joined(separator: "\t")
                    )
                    print("PromptEvalTests task words in \(style.id) for \(fixture.name): \(hits.joined(separator: " "))")
                }
            }
        }

        let destination = DotMigration.environment("PROMPT_EVAL_OUT")
            .map { URL(fileURLWithPath: $0, isDirectory: false) }
            ?? URL(fileURLWithPath: "/tmp/dot-prompt-eval.tsv")
        try rows.joined(separator: "\n").appending("\n")
            .write(to: destination, atomically: true, encoding: .utf8)
        let observationURL = destination.deletingPathExtension()
            .appendingPathExtension("task-words.tsv")
        try taskWordRows.joined(separator: "\n").appending("\n")
            .write(to: observationURL, atomically: true, encoding: .utf8)
        print("PromptEvalTests wrote \(rows.count - 1) rows to \(destination.path)")
        print("PromptEvalTests wrote the task-word record to \(observationURL.path)")
    }

    // MARK: - Setup

    /// A value the run cannot do without.
    ///
    /// The message names the variable and what it is for, so a run that was
    /// meant to happen and did not says which setting is missing rather than
    /// reporting a passing suite.
    private func required(_ suffix: String) throws -> String {
        guard let value = DotMigration.environment(suffix),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip(
                "Set DOT_\(suffix) to run the prompt evaluation "
                    + "(with DOT_PROMPT_EVAL_BASE_URL, DOT_PROMPT_EVAL_MODEL and DOT_PROMPT_EVAL_KEY)."
            )
        }
        return value
    }

    /// The styles that run: the shipped ones, or the ones a file names.
    private func styles() throws -> RewriteConfiguration {
        guard let path = DotMigration.environment("PROMPT_EVAL_STYLE_PATH") else {
            return .default
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let configuration = try? JSONDecoder().decode(RewriteConfiguration.self, from: data),
           !configuration.choices.isEmpty {
            return configuration
        }
        if let configuration = try? JSONDecoder().decode(DotConfig.self, from: data),
           !configuration.assistant.rewrite.choices.isEmpty {
            return configuration.assistant.rewrite
        }
        throw XCTSkip("DOT_PROMPT_EVAL_STYLE_PATH does not name a rewrite configuration: \(path)")
    }

    /// The dictated transcripts, in name order.
    private func transcripts() throws -> [(name: String, text: String)] {
        let directory = try XCTUnwrap(
            Bundle.module.url(
                forResource: "transcripts",
                withExtension: nil,
                subdirectory: "Fixtures/PromptEval"
            ),
            "the transcript fixtures are missing from the test bundle"
        )
        let names = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "txt" }
        .map { $0.deletingPathExtension().lastPathComponent }
        .sorted()
        return try names.map { name in
            (name, try String(contentsOf: directory.appendingPathComponent("\(name).txt"), encoding: .utf8))
        }
    }

    /// The words that carry no content of their own.
    private static func stopWords() throws -> Set<String> {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "stopwords",
                withExtension: "txt",
                subdirectory: "Fixtures/PromptEval"
            ),
            "the stop list is missing from the test bundle"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(PromptEval.words(in: text))
    }

    /// One style's answer to one transcript.
    private func answer(
        provider: OpenAIChatProvider,
        style: RewriteStyle,
        transcript: String,
        model: String
    ) async throws -> String {
        var text = ""
        let stream = provider.stream(
            messages: RewritePrompt.messages(for: style, text: transcript),
            tools: [],
            model: model
        )
        for try await event in stream {
            if case .textDelta(let delta) = event { text += delta }
        }
        return text
    }

    /// A session that fails fast and never caches.
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }
}

/// The check the observation fixture is measured with, and the fixture itself.
///
/// The numbers the live run produces are read by a person. What the code does
/// with them is not: a word is matched whole, and the fixture holds exactly the
/// report the reviewer named.
final class PromptEvalFixtureTests: XCTestCase {
    func testTheTaskWordsAreTheFiveVerbsAndModalsOfATask() {
        XCTAssertEqual(PromptEval.taskWords, ["fix", "implement", "add", "should", "must"])
    }

    func testTheObservationFixtureIsTheReportedProblemAndNothingElse() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "coding-observation-only",
                withExtension: "txt",
                subdirectory: "Fixtures/PromptEval/transcripts"
            ),
            "the observation fixture is missing from the test bundle"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(text, "The crash happens on macOS 14. I have not decided what change I want.")
        XCTAssertEqual(PromptEval.observationFixture, "coding-observation-only")
    }

    func testTheTaskWordCheckMatchesWholeWordsOnly() {
        XCTAssertEqual(
            PromptEval.matches(
                of: PromptEval.taskWords,
                in: "Fix it, implement the retry, add a flag, we should and we must."
            ),
            ["fix", "implement", "add", "should", "must"]
        )
        XCTAssertEqual(
            PromptEval.matches(
                of: PromptEval.taskWords,
                in: "The fixed build was addressed by adding a field; it shouldered nothing."
            ),
            [],
            "an inflected form was read as the word"
        )
        XCTAssertEqual(
            PromptEval.matches(of: PromptEval.taskWords, in: "The crash happens on macOS 14."),
            []
        )
        XCTAssertEqual(
            PromptEval.matches(of: PromptEval.taskWords, in: ""),
            []
        )
    }
}

/// How many of an answer's content words the speaker never said.
///
/// A word is content when it is at least three characters of letters and digits
/// and is not one of the stop words stored with the fixtures. Markdown heading
/// lines are dropped before counting, because a style that asks for sections
/// names them itself and those labels are not words the model invented.
enum PromptEval {
    /// One answer's measurement.
    struct Measurement: Equatable, Sendable {
        /// The added content words, in the order they first appear.
        var added: [String]
        /// Added content words divided by the answer's content words.
        var ratio: Double
    }

    /// The words of a text, lowercased.
    ///
    /// - Parameter text: the text to split.
    /// - Returns: runs of letters and digits, each folded to lower case.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split { character in
                !(character.isLetter || character.isNumber)
            }
            .map(String.init)
    }

    /// The content words of a text.
    ///
    /// - Parameters:
    ///   - text: the text to read.
    ///   - stopWords: the words that carry no content.
    /// - Returns: the content words, each once, in the order they first appear.
    static func contentWords(in text: String, stopWords: Set<String>) -> [String] {
        var seen: [String] = []
        var known = Set<String>()
        for word in words(in: text) where word.count >= 3 && !stopWords.contains(word) {
            if known.insert(word).inserted { seen.append(word) }
        }
        return seen
    }

    /// The words a task made out of an observation would use.
    ///
    /// A report says what happens; a task says what to do about it. These are
    /// the verbs and modals of the second, so their presence in an Agent prompt
    /// written from a report is the added content this evaluation looks for.
    static let taskWords = ["fix", "implement", "add", "should", "must"]

    /// The fixture that reports a problem and asks for nothing.
    static let observationFixture = "coding-observation-only"

    /// Which of a list of words a text carries, matched whole.
    ///
    /// A word is matched as the token it is: "fixed" is not "fix", and "adding"
    /// is not "add", so an inflected form the transcript itself carries cannot
    /// be read as an invented task.
    ///
    /// - Parameters:
    ///   - candidates: the words to look for, lowercased.
    ///   - text: the text to read.
    /// - Returns: the candidates the text carries, in the order they were given.
    static func matches(of candidates: [String], in text: String) -> [String] {
        let carried = Set(words(in: text))
        return candidates.filter { carried.contains($0) }
    }

    /// The text an answer is measured on: everything except its heading lines.
    ///
    /// - Parameter text: the model's answer.
    /// - Returns: the answer with every Markdown heading line removed.
    static func measuredText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            }
            .joined(separator: "\n")
    }

    /// Measures one answer against the transcript it was written from.
    ///
    /// - Parameters:
    ///   - output: the model's answer.
    ///   - transcript: the words the speaker dictated.
    ///   - stopWords: the words that carry no content.
    /// - Returns: the added words and the ratio they stand at.
    static func measure(
        output: String,
        transcript: String,
        stopWords: Set<String>
    ) -> Measurement {
        let spoken = Set(words(in: transcript))
        let content = contentWords(in: measuredText(output), stopWords: stopWords)
        let added = content.filter { !spoken.contains($0) }
        guard !content.isEmpty else { return Measurement(added: added, ratio: 0) }
        return Measurement(added: added, ratio: Double(added.count) / Double(content.count))
    }
}
