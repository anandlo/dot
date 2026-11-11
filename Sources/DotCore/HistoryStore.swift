import Foundation

/// The transcripts Dot remembers between launches.
///
/// The file holds the last few transcripts, newest first. It is written on a
/// background queue and read once at launch; it never holds audio and never
/// holds a credential.
///
/// Each entry also carries when it was added, because the palette shows an age
/// next to a transcript and an age cannot be reconstructed from text. A file
/// written before the age existed still loads: its entries simply have no date,
/// and the palette says nothing rather than inventing one.
public enum HistoryStore {
    /// How many transcripts are kept.
    public static let limit = 20

    /// One remembered transcript.
    public struct Entry: Codable, Equatable, Sendable {
        /// The transcript.
        public var text: String
        /// When it was added; `nil` for an entry that was written before the
        /// history kept dates.
        public var addedAt: Date?

        /// Creates an entry.
        public init(text: String, addedAt: Date? = nil) {
            self.text = text
            self.addedAt = addedAt
        }
    }

    /// The file the history lives in.
    ///
    /// It sits beside the configuration, so both move together when the
    /// product's folder is migrated.
    public static func defaultURL() -> URL {
        DotConfig.directoryURL().appendingPathComponent("history.json")
    }

    /// Reads the history with its dates.
    ///
    /// Two shapes decode: the current one, a list of entries, and the one every
    /// earlier build wrote, a list of strings. A file that is neither gives an
    /// empty history rather than an error: a broken file must never stop a
    /// recording.
    public static func loadEntries(from url: URL = defaultURL()) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // A file an older build wrote is still `0644`. Reading it is the moment
        // to restrict it, so the words stop being readable by every other
        // account on the Mac.
        SecureFile.tighten(url)
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            return Array(entries.prefix(limit))
        }
        if let texts = try? JSONDecoder().decode([String].self, from: data) {
            return Array(texts.prefix(limit).map { Entry(text: $0) })
        }
        return []
    }

    /// Writes the history with its dates.
    ///
    /// The file holds what was dictated, so it is written `0600` in a folder
    /// that is `0700`. It is replaced atomically: a crash cannot leave a
    /// truncated history behind.
    public static func saveEntries(_ entries: [Entry], to url: URL = defaultURL()) {
        let trimmed = Array(entries.prefix(limit))
        do {
            let data = try JSONEncoder().encode(trimmed)
            try SecureFile.write(data, to: url)
        } catch {
            Log.shared.error("history.save.failed", ["error": .string(error.localizedDescription)])
        }
    }

    /// Reads the history as text only.
    public static func load(from url: URL = defaultURL()) -> [String] {
        loadEntries(from: url).map(\.text)
    }

    /// Writes the history as text only.
    ///
    /// An entry that is already in the file keeps the date it had; a new one
    /// gets `now`, because the caller that only has strings cannot know better
    /// and a missing date would make a fresh transcript look old.
    public static func save(_ items: [String], to url: URL = defaultURL()) {
        let existing = loadEntries(from: url)
        var dates: [String: Date] = [:]
        for entry in existing {
            guard let date = entry.addedAt else { continue }
            dates[entry.text] = date
        }
        let now = Date()
        let entries = items.map { Entry(text: $0, addedAt: dates[$0] ?? now) }
        saveEntries(entries, to: url)
    }

    /// The history with one more transcript at the front, and its date.
    ///
    /// A transcript that is already in the history is not added twice: pasting
    /// the same text again should not fill the menu with copies. It moves to
    /// the front instead, and keeps the date it was first heard, because that
    /// is when the words were spoken.
    public static func adding(
        _ text: String,
        at date: Date = Date(),
        to entries: [Entry]
    ) -> [Entry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let existing = entries.first { $0.text == trimmed }
        var next = entries.filter { $0.text != trimmed }
        next.insert(Entry(text: trimmed, addedAt: existing?.addedAt ?? date), at: 0)
        return Array(next.prefix(limit))
    }

    /// The history with one more transcript at the front.
    public static func adding(_ text: String, to items: [String]) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        var next = items.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        return Array(next.prefix(limit))
    }
}
