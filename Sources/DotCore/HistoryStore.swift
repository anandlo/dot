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
///
/// An entry may also carry the rewrites it has completed. They are versions of
/// the entry's own text, so the original is never stored twice and a file
/// cannot claim a different transcript than the one it keeps. A file written
/// before versions existed, an entry without them, and an entry whose version
/// payload is malformed all load the same way: the transcript and its date are
/// kept, and the versions are simply absent.
public enum HistoryStore {
    /// How many transcripts are kept when no configuration names a number.
    ///
    /// The store still owns a bound, because a file has to be bounded even when
    /// no configuration was read yet; ``DotConfig/historyLimit`` is what the
    /// app passes in, and the page writes it.
    public static let limit = 20

    /// One remembered transcript.
    public struct Entry: Codable, Equatable, Sendable {
        /// The transcript.
        public var text: String
        /// When it was added; `nil` for an entry that was written before the
        /// history kept dates.
        public var addedAt: Date?
        /// The completed rewrites of this transcript, when it has any.
        ///
        /// The words are the entry's own: version 0 is rebuilt from ``text``
        /// when the card is restored, so the list here starts at the first
        /// requested rewrite.
        public var rewrite: RewriteSnapshot?

        /// Creates an entry.
        public init(text: String, addedAt: Date? = nil, rewrite: RewriteSnapshot? = nil) {
            self.text = text
            self.addedAt = addedAt
            self.rewrite = rewrite
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case addedAt
            case rewrite
        }

        /// Reads one entry, keeping the transcript whatever the rest holds.
        ///
        /// A date or a version payload that cannot be read is dropped on its
        /// own: the transcript is the one field the history exists for, and a
        /// file that a newer build wrote half of must never cost a person the
        /// words they dictated.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            addedAt = (try? container.decodeIfPresent(Date.self, forKey: .addedAt)) ?? nil
            rewrite = (try? container.decodeIfPresent(RewriteSnapshot.self, forKey: .rewrite)) ?? nil
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
    /// Three shapes decode: the current one, a list of entries; the one every
    /// earlier build wrote, a list of strings; and a list that mixes the two,
    /// which is what a file half-written by two builds looks like. Each element
    /// is read on its own, so one malformed entry cannot take its neighbours
    /// with it. A file that is neither gives an empty history rather than an
    /// error: a broken file must never stop a recording.
    public static func loadEntries(
        from url: URL = defaultURL(),
        limit: Int = HistoryStore.limit
    ) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // A file an older build wrote is still `0644`. Reading it is the moment
        // to restrict it, so the words stop being readable by every other
        // account on the Mac.
        SecureFile.tighten(url)
        return Array(decodeEntries(data).prefix(max(1, limit)))
    }

    /// Decodes a history file element by element.
    ///
    /// It is internal so a test can feed the decoder a shape without writing a
    /// file, and it is the only place the three element shapes are decided.
    static func decodeEntries(_ data: Data) -> [Entry] {
        guard let elements = try? JSONDecoder().decode([LossyEntry].self, from: data) else {
            return []
        }
        return elements.compactMap(\.entry)
    }

    /// One element of the history file, either shape, or nothing.
    private struct LossyEntry: Decodable {
        let entry: Entry?

        init(from decoder: Decoder) throws {
            if let entry = try? Entry(from: decoder) {
                self.entry = entry
                return
            }
            // The shape every earlier build wrote: the transcript alone.
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self.entry = Entry(text: text)
                return
            }
            self.entry = nil
        }
    }

    /// Writes the history with its dates.
    ///
    /// The file holds what was dictated, so it is written `0600` in a folder
    /// that is `0700`. It is replaced atomically: a crash cannot leave a
    /// truncated history behind.
    public static func saveEntries(
        _ entries: [Entry],
        to url: URL = defaultURL(),
        limit: Int = HistoryStore.limit
    ) {
        let trimmed = Array(entries.prefix(max(1, limit)))
        do {
            let data = try JSONEncoder().encode(trimmed)
            try SecureFile.write(data, to: url)
        } catch {
            Log.shared.error("history.save.failed", ["error": .string(error.localizedDescription)])
        }
    }

    /// Reads the history as text only.
    public static func load(from url: URL = defaultURL(), limit: Int = HistoryStore.limit) -> [String] {
        loadEntries(from: url, limit: limit).map(\.text)
    }

    /// Writes the history as text only.
    ///
    /// An entry that is already in the file keeps the date it had and the
    /// versions it kept; a new one gets `now`, because the caller that only has
    /// strings cannot know better and a missing date would make a fresh
    /// transcript look old. A caller that names only the text must never be the
    /// reason a saved rewrite disappears.
    public static func save(_ items: [String], to url: URL = defaultURL(), limit: Int = HistoryStore.limit) {
        let existing = loadEntries(from: url, limit: limit)
        var stored: [String: Entry] = [:]
        for entry in existing {
            stored[entry.text] = entry
        }
        let now = Date()
        let entries = items.map {
            Entry(
                text: $0,
                addedAt: stored[$0]?.addedAt ?? now,
                rewrite: stored[$0]?.rewrite
            )
        }
        saveEntries(entries, to: url, limit: limit)
    }

    /// The history with one more transcript at the front, and its date.
    ///
    /// A transcript that is already in the history is not added twice: pasting
    /// the same text again should not fill the menu with copies. It moves to
    /// the front instead, and keeps the date it was first heard, because that
    /// is when the words were spoken. It also keeps the versions it already
    /// had: dictating the same sentence again is not a reason to throw away
    /// rewrites of that exact sentence.
    public static func adding(
        _ text: String,
        at date: Date = Date(),
        to entries: [Entry],
        limit: Int = HistoryStore.limit
    ) -> [Entry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let existing = entries.first { $0.text == trimmed }
        var next = entries.filter { $0.text != trimmed }
        next.insert(
            Entry(text: trimmed, addedAt: existing?.addedAt ?? date, rewrite: existing?.rewrite),
            at: 0
        )
        return Array(next.prefix(max(1, limit)))
    }

    /// The history with the versions of one transcript stored, or `nil`.
    ///
    /// The card that produced `rewrite` names the transcript it was built from.
    /// The versions are attached only to an entry with exactly that text, which
    /// is what keeps a clear, a trim, a rebase or a reset from bringing an entry
    /// back or from writing one transcript's rewrites onto another's. Nothing
    /// is written when the entry already holds this snapshot, which is what
    /// makes persisting on every card change free of disk work while a rewrite
    /// streams: a streaming card has no snapshot at all.
    ///
    /// - Parameters:
    ///   - rewrite: the completed versions and the selection to store.
    ///   - text: the transcript the card was built from.
    ///   - entries: the history as it stands in memory.
    /// - Returns: the updated history, or `nil` when nothing has to be written.
    public static func storing(
        _ rewrite: RewriteSnapshot?,
        for text: String,
        in entries: [Entry]
    ) -> [Entry]? {
        guard let rewrite, let normalized = rewrite.normalized(), !normalized.versions.isEmpty else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = entries.firstIndex(where: { $0.text == trimmed }) else { return nil }
        guard entries[index].rewrite != normalized else { return nil }
        var next = entries
        next[index].rewrite = normalized
        return next
    }

    /// The history with one more transcript at the front.
    public static func adding(
        _ text: String,
        to items: [String],
        limit: Int = HistoryStore.limit
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        var next = items.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        return Array(next.prefix(max(1, limit)))
    }
}
